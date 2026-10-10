import AVFoundation
import UniformTypeIdentifiers
import VideoToolbox

/// Encodes 10-bit HLG camera buffers as a short rolling HEVC HLS presentation.
/// Writer methods run on CameraService's video queue; segment callbacks can run on any queue.
final class HDRStream: NSObject, AVAssetWriterDelegate {
    private struct Segment {
        let sequence: Int
        let duration: Double
        let data: Data
        let generation: String
        let initialization: Data
        let discontinuity: Bool
        let programDateTime: Date
    }

    var onError: ((String) -> Void)?

    private let lock = NSLock()
    private var generation = UUID().uuidString
    private var initialization: Data?
    private var segments: [Segment] = []
    private var retiredSegments: [(segment: Segment, expires: Date)] = []
    private var nextSequence = 0
    private var discontinuitySequence = 0
    private var pendingDiscontinuity = false
    private var currentWriterID: ObjectIdentifier?
    private var writerStartTimestamp: CMTime = .invalid
    private var writerStartDate = Date()
    private var errorMessage: String?
    private var activeBitRate = 0

    private var enabled = false
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var lastAcceptedTime: CMTime = .invalid
    private var writerQuality: StreamImageQuality?

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        resetWriter()
        lastAcceptedTime = .invalid
        lock.lock()
        generation = UUID().uuidString
        initialization = nil
        segments.removeAll()
        retiredSegments.removeAll()
        nextSequence = 0
        discontinuitySequence = 0
        pendingDiscontinuity = false
        errorMessage = nil
        activeBitRate = 0
        lock.unlock()
    }

    func resetPresentation() {
        guard enabled else { return }
        resetWriter()
        lastAcceptedTime = .invalid
        lock.lock()
        generation = UUID().uuidString
        initialization = nil
        pendingDiscontinuity = !segments.isEmpty
        lock.unlock()
    }

    func append(_ sample: CMSampleBuffer, networkActive: Bool, maxFPS: Int,
                quality: StreamImageQuality = .normal) {
        guard enabled else { return }
        guard networkActive else {
            if writer != nil { resetPresentation() }
            return
        }
        if writer != nil, writerQuality != quality { resetPresentation() }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        guard timestamp.isNumeric else { return }
        if timestamp.isValid && lastAcceptedTime.isValid {
            let elapsed = CMTimeSubtract(timestamp, lastAcceptedTime)
            if CMTimeCompare(elapsed, .zero) < 0 {
                resetPresentation()
            } else if maxFPS > 0 &&
                        CMTimeCompare(elapsed, CMTime(value: 1, timescale: CMTimeScale(maxFPS))) < 0 {
                return
            }
        }
        if writer == nil { startWriter(with: sample, quality: quality) }
        guard let writer, let input else { return }
        if writer.status == .failed {
            fail(writer.error?.localizedDescription ?? "HDR encoding failed.")
        } else if writer.status == .writing && input.isReadyForMoreMediaData {
            if input.append(sample) { lastAcceptedTime = timestamp }
            else { fail(writer.error?.localizedDescription ?? "Could not append an HDR frame.") }
        }
    }

    func playlist(key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !segments.isEmpty else { return nil }
        let target = max(2, Int(ceil(segments.map(\.duration).max() ?? 1)))
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(target)",
                     "#EXT-X-MEDIA-SEQUENCE:\(segments[0].sequence)",
                     "#EXT-X-DISCONTINUITY-SEQUENCE:\(discontinuitySequence)"]
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var mappedGeneration: String?
        for segment in segments {
            if segment.discontinuity { lines.append("#EXT-X-DISCONTINUITY") }
            if segment.generation != mappedGeneration {
                lines.append("#EXT-X-MAP:URI=\"/hdr/init.mp4?key=\(key)&gen=\(segment.generation)\"")
                mappedGeneration = segment.generation
            }
            lines.append("#EXT-X-PROGRAM-DATE-TIME:\(dateFormatter.string(from: segment.programDateTime))")
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            lines.append("/hdr/seg-\(segment.sequence).m4s?key=\(key)&gen=\(segment.generation)")
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    func resource(named name: String, generation requestedGeneration: String?) -> Data? {
        lock.lock(); defer { lock.unlock() }
        retiredSegments.removeAll(where: { $0.expires <= Date() })
        if name == "init.mp4" {
            if requestedGeneration == generation { return initialization }
            return (segments.first(where: { $0.generation == requestedGeneration }) ??
                    retiredSegments.first(where: { $0.segment.generation == requestedGeneration })?.segment)?.initialization
        }
        guard name.hasPrefix("seg-"), name.hasSuffix(".m4s"),
              let sequence = Int(name.dropFirst(4).dropLast(4)) else { return nil }
        return (segments.first(where: { $0.sequence == sequence && $0.generation == requestedGeneration }) ??
                retiredSegments.first(where: { $0.segment.sequence == sequence &&
                                                $0.segment.generation == requestedGeneration })?.segment)?.data
    }

    func status() -> (ready: Bool, error: String?, bitRate: Int) {
        lock.lock(); defer { lock.unlock() }
        return (segments.contains(where: { $0.generation == generation }), errorMessage, activeBitRate)
    }

    private func startWriter(with sample: CMSampleBuffer, quality: StreamImageQuality) {
        guard let buffer = CMSampleBufferGetImageBuffer(sample),
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange else {
            fail("This camera is not delivering 10-bit HDR frames.")
            return
        }
        guard let contentType = UTType(AVFileType.mp4.rawValue) else {
            fail("MPEG-4 streaming is unavailable.")
            return
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let baselineBitRate = min(25_000_000, max(4_000_000, width * height * 2))
        let bitRate = quality.adjustedBitRate(baselineBitRate)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
                AVVideoAverageBitRateKey: bitRate,
                AVVideoMaxKeyFrameIntervalDurationKey: 1
            ]
        ]
        let writer = AVAssetWriter(contentType: contentType)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.initialSegmentStartTime = CMSampleBufferGetPresentationTimeStamp(sample)
        writer.delegate = self
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            fail("This iPhone cannot encode 10-bit HEVC HLS at this camera setting.")
            return
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            fail("Cannot add the HDR video encoder.")
            return
        }
        writer.add(input)
        guard writer.startWriting() else {
            fail(writer.error?.localizedDescription ?? "Could not start HDR encoding.")
            return
        }
        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
        self.writer = writer
        self.input = input
        writerQuality = quality
        lock.lock()
        currentWriterID = ObjectIdentifier(writer)
        writerStartTimestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        writerStartDate = Date()
        activeBitRate = bitRate
        lock.unlock()
    }

    private func resetWriter() {
        lock.lock()
        currentWriterID = nil
        writerStartTimestamp = .invalid
        activeBitRate = 0
        lock.unlock()
        writer?.cancelWriting()
        writer = nil
        input = nil
        writerQuality = nil
    }

    private func fail(_ message: String) {
        enabled = false
        resetWriter()
        lock.lock()
        generation = UUID().uuidString
        initialization = nil
        segments.removeAll()
        retiredSegments.removeAll()
        pendingDiscontinuity = false
        errorMessage = message
        lock.unlock()
        onError?(message)
    }

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data,
                     segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        lock.lock(); defer { lock.unlock() }
        guard currentWriterID == ObjectIdentifier(writer) else { return }
        switch segmentType {
        case .initialization:
            initialization = data
        case .separable:
            guard let initialization else { return }
            let videoTrack = segmentReport?.trackReports.first(where: { $0.mediaType == .video })
            let reportDuration = videoTrack?.duration
            let seconds = reportDuration.map(CMTimeGetSeconds) ?? 1
            let duration = seconds.isFinite && seconds > 0 ? seconds : 1
            let offset = videoTrack.map { CMTimeGetSeconds(CMTimeSubtract($0.earliestPresentationTimeStamp,
                                                                          writerStartTimestamp)) } ?? .nan
            let startDate = offset.isFinite ? writerStartDate.addingTimeInterval(offset) : Date().addingTimeInterval(-duration)
            segments.append(Segment(sequence: nextSequence, duration: duration, data: data,
                                    generation: generation, initialization: initialization,
                                    discontinuity: pendingDiscontinuity, programDateTime: startDate))
            nextSequence += 1
            pendingDiscontinuity = false
            if segments.count > 8 {
                let previousWindowDuration = segments.dropLast().reduce(0) { $0 + $1.duration }
                let removed = segments.removeFirst()
                retiredSegments.append((removed, Date().addingTimeInterval(removed.duration + previousWindowDuration)))
                if removed.discontinuity { discontinuitySequence += 1 }
            }
            retiredSegments.removeAll(where: { $0.expires <= Date() })
        @unknown default:
            break
        }
    }
}
