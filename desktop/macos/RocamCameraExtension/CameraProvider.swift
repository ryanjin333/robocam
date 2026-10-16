import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import IOKit.audio

final class RocamDeviceSource: NSObject, CMIOExtensionDeviceSource, @unchecked Sendable {
    private(set) var device: CMIOExtensionDevice!
    private var source: RocamStreamSource!
    private var sink: RocamStreamSource!
    private let stateQueue = DispatchQueue(label: "com.rocam.camera.state")
    private var sourceClients = 0
    private var sinkClients = 0
    private var pump: DispatchSourceTimer?
    private var consumeOutstanding = false
    private var sinkGeneration: UInt64 = 0
    private var lastInput = Date.distantPast

    private struct PendingSample: @unchecked Sendable {
        let sample: CMSampleBuffer?
        let sequence: UInt64
        let discontinuity: CMIOExtensionStream.DiscontinuityFlags
    }

    override init() {
        super.init()
        device = CMIOExtensionDevice(localizedName: "Rocam", deviceID: RocamCameraIdentity.deviceID, legacyDeviceID: RocamCameraIdentity.legacyDeviceUID, source: self)
        let format = Self.makeFormat()
        source = RocamStreamSource(name: RocamCameraIdentity.sourceName, id: RocamCameraIdentity.sourceID, direction: .source, format: format, owner: self)
        sink = RocamStreamSource(name: RocamCameraIdentity.sinkName, id: RocamCameraIdentity.sinkID, direction: .sink, format: format, owner: self)
        do {
            try device.addStream(source.stream)
            try device.addStream(sink.stream)
        } catch {
            fatalError("Rocam could not create its camera streams: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { result.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { result.model = "Rocam USB Camera" }
        return result
    }

    func setDeviceProperties(_: CMIOExtensionDeviceProperties) throws {}

    func start(_ stream: RocamStreamSource) {
        stateQueue.async { [weak self, stream] in
            guard let self else { return }
            if stream.direction == .source {
                sourceClients += 1
            } else {
                if sinkClients == 0 { sinkGeneration &+= 1 }
                sinkClients += 1
            }
            ensurePump()
        }
    }

    func stop(_ stream: RocamStreamSource) {
        stateQueue.async { [weak self, stream] in
            guard let self else { return }
            if stream.direction == .source {
                sourceClients = max(0, sourceClients - 1)
            } else {
                sinkClients = max(0, sinkClients - 1)
                if sinkClients == 0 {
                    sinkGeneration &+= 1
                    consumeOutstanding = false
                }
            }
            stopPumpIfUnused()
        }
    }

    private func ensurePump() {
        guard pump == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(RocamCameraIdentity.fps))
        timer.setEventHandler { [weak self] in self?.consumeSinkOrSendNeutral() }
        pump = timer
        timer.resume()
    }

    private func stopPumpIfUnused() {
        guard sourceClients == 0, sinkClients == 0 else { return }
        pump?.cancel()
        pump = nil
    }

    private func consumeSinkOrSendNeutral() {
        guard sinkClients > 0, !consumeOutstanding,
              let client = sink.stream.streamingClients.first else {
            sendNeutralIfNeeded()
            return
        }
        consumeOutstanding = true
        let requestGeneration = sinkGeneration
        sink.stream.consumeSampleBuffer(from: client) { [weak self] sample, sequence, discontinuity, _, _ in
            // CoreMedia sample buffers cross this boundary only to the serialized state queue.
            let delivery = PendingSample(sample: sample, sequence: sequence, discontinuity: discontinuity)
            self?.stateQueue.async { [weak self, delivery] in
                self?.handle(delivery, requestGeneration: requestGeneration)
            }
        }
    }

    private func handle(_ delivery: PendingSample, requestGeneration: UInt64) {
        guard requestGeneration == sinkGeneration, sinkClients > 0 else { return }
        consumeOutstanding = false
        if let sample = delivery.sample {
            lastInput = Date()
            let hostTime = Self.nanoseconds(CMSampleBufferGetPresentationTimeStamp(sample))
            if sourceClients > 0 {
                source.stream.send(sample, discontinuity: delivery.discontinuity, hostTimeInNanoseconds: hostTime)
            }
            sink.stream.notifyScheduledOutputChanged(
                CMIOExtensionScheduledOutput(sequenceNumber: delivery.sequence, hostTimeInNanoseconds: hostTime)
            )
        } else {
            sendNeutralIfNeeded()
        }
    }

    private func sendNeutralIfNeeded() {
        guard sourceClients > 0,
              Date().timeIntervalSince(lastInput) >= 1.0 / Double(RocamCameraIdentity.fps),
              let sample = Self.neutralSample() else { return }
        source.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: Self.nanoseconds(CMSampleBufferGetPresentationTimeStamp(sample)))
    }

    private static func makeFormat() -> CMIOExtensionStreamFormat {
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA, width: Int32(RocamCameraIdentity.width), height: Int32(RocamCameraIdentity.height), extensions: nil, formatDescriptionOut: &description)
        return CMIOExtensionStreamFormat(formatDescription: description!, maxFrameDuration: CMTime(value: 1, timescale: RocamCameraIdentity.fps), minFrameDuration: CMTime(value: 1, timescale: RocamCameraIdentity.fps), validFrameDurations: nil)
    }

    private static func neutralSample() -> CMSampleBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        guard CVPixelBufferCreate(kCFAllocatorDefault, RocamCameraIdentity.width, RocamCameraIdentity.height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) { memset(base, 0, CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)) }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &description)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: RocamCameraIdentity.fps), presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    private static func nanoseconds(_ time: CMTime) -> UInt64 {
        let scaled = CMTimeConvertScale(time, timescale: 1_000_000_000, method: .default)
        return scaled.isValid && scaled.value > 0 ? UInt64(scaled.value) : 0
    }
}

final class RocamStreamSource: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
    private(set) var stream: CMIOExtensionStream!
    let direction: CMIOExtensionStream.Direction
    weak var owner: RocamDeviceSource?
    private let format: CMIOExtensionStreamFormat

    init(name: String, id: UUID, direction: CMIOExtensionStream.Direction, format: CMIOExtensionStreamFormat, owner: RocamDeviceSource) {
        self.direction = direction; self.format = format; self.owner = owner
        super.init()
        stream = CMIOExtensionStream(localizedName: name, streamID: id, direction: direction, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var activeFormatIndex = 0
    var availableProperties: Set<CMIOExtensionProperty> {
        direction == .sink ? [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup] : [.streamActiveFormatIndex, .streamFrameDuration]
    }
    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = activeFormatIndex }
        if properties.contains(.streamFrameDuration) { result.frameDuration = CMTime(value: 1, timescale: RocamCameraIdentity.fps) }
        if direction == .sink, properties.contains(.streamSinkBufferQueueSize) { result.sinkBufferQueueSize = 3 }
        if direction == .sink, properties.contains(.streamSinkBuffersRequiredForStartup) { result.sinkBuffersRequiredForStartup = 1 }
        return result
    }
    func setStreamProperties(_ properties: CMIOExtensionStreamProperties) throws { if let index = properties.activeFormatIndex, index == 0 { activeFormatIndex = index } }
    // CMIOExtensionClient exposes no public signing identity or Team ID for sink authorization.
    // The supported API therefore cannot distinguish the host from another local CMIO client here.
    func authorizedToStartStream(for _: CMIOExtensionClient) -> Bool { true }
    func startStream() throws { owner?.start(self) }
    func stopStream() throws { owner?.stop(self) }
}

final class RocamProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: RocamDeviceSource!
    override init() {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: nil)
        deviceSource = RocamDeviceSource()
        do { try provider.addDevice(deviceSource.device) }
        catch { fatalError("Rocam could not register its camera device: \(error.localizedDescription)") }
    }
    func connect(to _: CMIOExtensionClient) throws {}
    func disconnect(from _: CMIOExtensionClient) {}
    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }
    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { result.manufacturer = "Rocam" }
        return result
    }
    func setProviderProperties(_: CMIOExtensionProviderProperties) throws {}
}
