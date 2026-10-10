import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// One shared quality preference for all network video encoders.
enum StreamImageQuality: String, CaseIterable, Identifiable {
    case low = "Low"
    case normal = "Normal"
    case high = "High"
    case veryHigh = "Very high"

    var id: String { rawValue }

    // Kept as the existing JPEG-only values; compressed encoders use adjustedBitRate(_:).
    var jpegCompression: CGFloat {
        switch self {
        case .low: return 0.60
        case .normal: return 0.75
        case .high: return 0.85
        case .veryHigh: return 0.90
        }
    }

    /// Produces a safe encoder target while leaving any valid Normal baseline unchanged.
    func adjustedBitRate(_ baseline: Int) -> Int {
        let safeBaseline = min(80_000_000, max(250_000, baseline))
        let multiplier: Double
        switch self {
        case .low: multiplier = 0.5
        case .normal: multiplier = 1
        case .high: multiplier = 1.5
        case .veryHigh: multiplier = 2
        }
        let adjusted = Int(Double(safeBaseline) * multiplier)
        return min(80_000_000, max(250_000, adjusted))
    }
}

/// Wire codecs for the bounded `/video.h264` and `/video.hevc` HTTP streams.
enum RocamVideoCodec: UInt8, CaseIterable {
    case h264 = 1
    case hevc = 2

    var endpoint: String { self == .h264 ? "/video.h264" : "/video.hevc" }

    var compressionType: CMVideoCodecType {
        self == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
    }
}

/// One independently framed Annex-B access unit. `bytes` is the wire payload only.
struct EncodedVideoPacket {
    let codec: RocamVideoCodec
    var flags: UInt8
    let width: Int
    let height: Int
    var sequence: UInt32
    let pts: UInt64
    let bytes: Data

    var isKeyframe: Bool { flags & 1 != 0 }

    func wireData() -> Data {
        var data = Data("RCV1".utf8)
        data.append(codec.rawValue)
        data.append(flags)
        data.appendBigEndian(UInt16(0))
        data.appendBigEndian(UInt32(bytes.count))
        data.appendBigEndian(UInt32(width))
        data.appendBigEndian(UInt32(height))
        data.appendBigEndian(sequence)
        data.appendBigEndian(pts)
        data.append(bytes)
        return data
    }
}

struct EncodedStreamStatus {
    let ready: Bool
    let error: String
    /// The requested encoder target, or zero while no encoder session exists.
    let bitRate: Int
}

/// A queue-confined SDR Rec.709 VideoToolbox encoder.
///
/// Public probe interface: construct on a serial queue, call `append(image:pts:fps:bitRate:)`
/// with a CIImage, and consume complete Annex-B packets through `onPacket`.  It deliberately
/// imports no UIKit or CameraService types, so a macOS probe can compile this shipping file.
final class EncodedStream {
    private static let maxDimension = 8192
    private static let maxPixels = 16_777_216
    private static let maxPacketBytes = 16 * 1024 * 1024

    let codec: RocamVideoCodec
    var onPacket: ((EncodedVideoPacket) -> Void)?

    private let callbackQueue: DispatchQueue
    private let ciContext: CIContext
    private var session: VTCompressionSession?
    // Retained until each asynchronous VideoToolbox completion. Reusing a rendered
    // pixel buffer before completion corrupts frames on encoders that read lazily.
    private var inFlightBuffers: [UInt64: CVPixelBuffer] = [:]
    private var nextBufferToken: UInt64 = 0
    private var dimensions: (Int, Int) = (0, 0)
    private var configuredFPS = 0
    private var configuredBitRate = 0
    private var generation = 0
    private var inFlight = 0
    private var sequence: UInt32 = 0
    private var pendingDiscontinuity = true
    private var forceKeyframe = true
    private(set) var lastError = ""

    init(codec: RocamVideoCodec, callbackQueue: DispatchQueue, ciContext: CIContext = CIContext()) {
        self.codec = codec
        self.callbackQueue = callbackQueue
        self.ciContext = ciContext
    }

    deinit { invalidate() }

    var status: EncodedStreamStatus {
        EncodedStreamStatus(ready: session != nil, error: lastError,
                            bitRate: session == nil ? 0 : configuredBitRate)
    }

    func requestKeyframe() { forceKeyframe = true }

    func invalidate() {
        generation &+= 1
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        inFlightBuffers.removeAll(keepingCapacity: true)
        dimensions = (0, 0)
        configuredFPS = 0
        configuredBitRate = 0
        inFlight = 0
        sequence = 0
        forceKeyframe = true
        pendingDiscontinuity = true
    }

    func append(image: CIImage, pts: CMTime, fps: Int, bitRate: Int) {
        guard inFlight < 2 else { return }
        guard pts.isValid, pts.isNumeric, pts.seconds.isFinite, pts.seconds >= 0 else {
            lastError = "Invalid camera timestamp for \(codec.endpoint)."
            return
        }
        guard let prepared = prepare(image: image) else { return }
        let safeFPS = min(120, max(1, fps))
        let safeBitRate = min(80_000_000, max(250_000, bitRate))
        if dimensions != prepared.dimensions || session == nil || configuredFPS != safeFPS || configuredBitRate != safeBitRate {
            invalidate()
            guard createSession(width: prepared.dimensions.0, height: prepared.dimensions.1,
                                fps: safeFPS, bitRate: safeBitRate) else { return }
        }
        guard let session, let buffer = makePixelBuffer(for: session) else { return }
        ciContext.render(prepared.image, to: buffer, bounds: CGRect(x: 0, y: 0,
                                                                      width: prepared.dimensions.0,
                                                                      height: prepared.dimensions.1),
                         colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
        var flags: VTEncodeInfoFlags = []
        let key = forceKeyframe
        let properties: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let callbackGeneration = generation
        nextBufferToken &+= 1
        let bufferToken = nextBufferToken
        inFlightBuffers[bufferToken] = buffer
        inFlight += 1
        let result = VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: properties, infoFlagsOut: &flags
        ) { [weak self] status, _, sampleBuffer in
            self?.callbackQueue.async { [weak self] in
                self?.handleOutput(status: status, sampleBuffer: sampleBuffer, generation: callbackGeneration,
                                   bufferToken: bufferToken)
            }
        }
        guard result == noErr else {
            inFlight = max(0, inFlight - 1)
            inFlightBuffers.removeValue(forKey: bufferToken)
            lastError = "VideoToolbox could not encode \(codec.endpoint) (\(result))."
            forceKeyframe = true
            return
        }
        if key { forceKeyframe = false }
    }

    private func prepare(image: CIImage) -> (image: CIImage, dimensions: (Int, Int))? {
        let extent = image.extent.integral
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width >= 2, extent.height >= 2,
              extent.width <= CGFloat(Self.maxDimension), extent.height <= CGFloat(Self.maxDimension) else {
            lastError = "Camera produced an empty video image."
            return nil
        }
        let width = Int(extent.width) & ~1
        let height = Int(extent.height) & ~1
        guard width > 0, height > 0, width <= Self.maxDimension, height <= Self.maxDimension,
              width <= Self.maxPixels / height else {
            lastError = "Camera video dimensions exceed the encoded stream limit."
            return nil
        }
        // Rendering a normalized origin avoids stride/crop surprises after CI orientation.
        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        return (normalized, (width, height))
    }

    private func createSession(width: Int, height: Int, fps: Int, bitRate: Int) -> Bool {
        var session: VTCompressionSession?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            // Request shareable surfaces so Core Image can render directly into the
            // VideoToolbox source buffers instead of requiring a per-frame copy.
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue,
        ]
        let result = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
                                                codecType: codec.compressionType, encoderSpecification: specification as CFDictionary,
                                                imageBufferAttributes: attributes as CFDictionary,
                                                compressedDataAllocator: nil, outputCallback: nil,
                                                refcon: nil, compressionSessionOut: &session)
        guard result == noErr, let session else {
            lastError = "VideoToolbox could not create \(codec.endpoint) (\(result))."
            return false
        }
        self.session = session
        dimensions = (width, height)
        configuredFPS = fps
        configuredBitRate = bitRate
        let properties: [(CFString, Any)] = [
            (kVTCompressionPropertyKey_RealTime, true),
            (kVTCompressionPropertyKey_AllowFrameReordering, false),
            (kVTCompressionPropertyKey_ExpectedFrameRate, fps),
            (kVTCompressionPropertyKey_AverageBitRate, bitRate),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 1),
            (kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        ]
        for (key, value) in properties where VTSessionSetProperty(session, key: key, value: value as CFTypeRef) != noErr {
            lastError = "VideoToolbox rejected a required \(codec.endpoint) setting."
            invalidate()
            return false
        }
        var supportedProperties: CFDictionary?
        if VTSessionCopySupportedPropertyDictionary(session, supportedPropertyDictionaryOut: &supportedProperties) == noErr,
           let supported = supportedProperties as? [CFString: Any],
           supported[kVTCompressionPropertyKey_MaxFrameDelayCount] != nil {
            let status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 1 as CFTypeRef)
            if status != noErr { lastError = "VideoToolbox could not limit \(codec.endpoint) frame delay (\(status))." }
        }
        let prepare = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepare == noErr else {
            lastError = "VideoToolbox could not prepare \(codec.endpoint) (\(prepare))."
            invalidate()
            return false
        }
        if !lastError.contains("frame delay") { lastError = "" }
        return true
    }

    private func makePixelBuffer(for session: VTCompressionSession) -> CVPixelBuffer? {
        // Ask VideoToolbox on each frame because encoder property changes are allowed
        // to replace its ideal source pool. There is intentionally no standalone
        // CVPixelBufferCreate fallback: it would reintroduce the allocation/copy path.
        guard let pool = VTCompressionSessionGetPixelBufferPool(session) else {
            lastError = "VideoToolbox did not provide a reusable SDR video frame pool."
            return nil
        }
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard result == kCVReturnSuccess, let buffer else {
            lastError = "VideoToolbox could not allocate an SDR video frame from its reusable pool (\(result))."
            return nil
        }
        return buffer
    }

    private func handleOutput(status: OSStatus, sampleBuffer: CMSampleBuffer?, generation: Int, bufferToken: UInt64) {
        guard generation == self.generation else { return }
        inFlight = max(0, inFlight - 1)
        inFlightBuffers.removeValue(forKey: bufferToken)
        guard status == noErr, let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer) else {
            lastError = "VideoToolbox did not return a \(codec.endpoint) access unit."
            forceKeyframe = true
            return
        }
        guard let bytes = annexB(sampleBuffer), bytes.count <= Self.maxPacketBytes else {
            lastError = "VideoToolbox returned an invalid \(codec.endpoint) access unit."
            forceKeyframe = true
            return
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        guard sequence != 0 || keyframe else {
            forceKeyframe = true
            return
        }
        let seconds = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let microseconds = seconds * 1_000_000
        guard seconds.isFinite, seconds >= 0, microseconds.isFinite,
              microseconds < Double(UInt64.max), microseconds.rounded() < Double(UInt64.max) else {
            lastError = "VideoToolbox returned an invalid video timestamp."
            forceKeyframe = true
            return
        }
        sequence &+= 1
        var flags: UInt8 = keyframe ? 1 : 0
        if pendingDiscontinuity { flags |= 2; pendingDiscontinuity = false }
        onPacket?(EncodedVideoPacket(codec: codec, flags: flags, width: dimensions.0, height: dimensions.1,
                                     sequence: sequence, pts: UInt64(microseconds.rounded()), bytes: bytes))
    }

    private func annexB(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 4, length <= Self.maxPacketBytes else { return nil }
        var lengthPrefixed = Data(count: length)
        let copied = lengthPrefixed.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var output = Data()
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        if keyframe, !appendParameterSets(format, to: &output) { return nil }
        var offset = 0
        while offset < length {
            guard length - offset >= 4 else { return nil }
            let nalLength = lengthPrefixed[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            offset += 4
            guard nalLength > 0, nalLength <= UInt32(length - offset) else { return nil }
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(lengthPrefixed[offset..<(offset + Int(nalLength))])
            offset += Int(nalLength)
            guard output.count <= Self.maxPacketBytes else { return nil }
        }
        return output
    }

    private func appendParameterSets(_ format: CMFormatDescription, to output: inout Data) -> Bool {
        let count = codec == .h264 ? 2 : 3
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var length = 0
            var parameterCount = 0
            var nalLength: Int32 = 0
            let result: OSStatus
            if codec == .h264 {
                result = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                                                                              parameterSetPointerOut: &pointer,
                                                                              parameterSetSizeOut: &length,
                                                                              parameterSetCountOut: &parameterCount,
                                                                              nalUnitHeaderLengthOut: &nalLength)
            } else {
                result = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                                                                              parameterSetPointerOut: &pointer,
                                                                              parameterSetSizeOut: &length,
                                                                              parameterSetCountOut: &parameterCount,
                                                                              nalUnitHeaderLengthOut: &nalLength)
            }
            guard result == noErr, let pointer, length > 0, parameterCount >= count, nalLength == 4 else { return false }
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(pointer, count: length)
        }
        return true
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}
