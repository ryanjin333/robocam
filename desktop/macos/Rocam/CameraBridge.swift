import CoreImage
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation

final class CameraBridge: @unchecked Sendable {
    private let outputQueue = DispatchQueue(label: "com.rocam.desktop.frames")
    private let frames = LatestFrameStore()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var sink: Sink?

    private struct Sink {
        let device: CMIODeviceID
        let stream: CMIOStreamID
        let queue: CMSimpleQueue
    }

    func publishJPEG(_ jpeg: Data) {
        guard frames.publish(jpeg) else { return }
        outputQueue.async { [weak self] in self?.drainLatestFrames() }
    }

    func clear() {
        frames.clear()
        outputQueue.async { [weak self] in self?.invalidateSink() }
    }

    private func drainLatestFrames() {
        while let jpeg = frames.take() {
            guard let sample = makeSampleBuffer(jpeg) else { continue }
            enqueue(sample)
        }
    }

    private func enqueue(_ sample: CMSampleBuffer) {
        guard let sink = sinkQueue() else { return }
        // CMIO owns this retained reference after a successful enqueue. If full or stopped,
        // release the producer's reference immediately; the latest-frame mailbox drops stale work.
        let retained = Unmanaged.passRetained(sample).toOpaque()
        guard CMSimpleQueueGetCount(sink.queue) < CMSimpleQueueGetCapacity(sink.queue),
              CMSimpleQueueEnqueue(sink.queue, element: retained) == noErr else {
            Unmanaged<CMSampleBuffer>.fromOpaque(retained).release()
            invalidateSink()
            return
        }
    }

    private func sinkQueue() -> Sink? {
        if let sink { return sink }
        for device in cameraDevices() where deviceUID(device) == RocamCameraIdentity.legacyDeviceUID {
            guard let stream = streams(device).first(where: { streamName($0) == RocamCameraIdentity.sinkName }),
                  CMIODeviceStartStream(device, stream) == noErr else { continue }
            var copiedQueue: Unmanaged<CMSimpleQueue>?
            guard CMIOStreamCopyBufferQueue(stream, nil, nil, &copiedQueue) == noErr,
                  let copiedQueue else {
                _ = CMIODeviceStopStream(device, stream)
                continue
            }
            let found = Sink(device: device, stream: stream, queue: copiedQueue.takeRetainedValue())
            sink = found
            return found
        }
        return nil
    }

    private func invalidateSink() {
        guard let sink else { return }
        _ = CMIODeviceStopStream(sink.device, sink.stream)
        self.sink = nil
    }

    private func cameraDevices() -> [CMIODeviceID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: UInt32(kCMIOHardwarePropertyDevices),
            mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
            mElement: UInt32(kCMIOObjectPropertyElementMain)
        )
        var byteCount: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &byteCount) == noErr else {
            return []
        }
        var devices = [CMIODeviceID](repeating: 0, count: Int(byteCount) / MemoryLayout<CMIODeviceID>.size)
        var used = byteCount
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, byteCount, &used, &devices) == noErr else {
            return []
        }
        return devices
    }

    private func propertyString(_ object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
            mElement: UInt32(kCMIOObjectPropertyElementMain)
        )
        // CMIO documents both DeviceUID and Name as caller-released CFObjects.
        // Store the returned reference as an unmanaged pointer, then consume that ownership.
        var value: Unmanaged<CFString>?
        let byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var used = byteCount
        let status = withUnsafeMutablePointer(to: &value) { output in
            CMIOObjectGetPropertyData(object, &address, 0, nil, byteCount, &used, output)
        }
        guard status == noErr, used == byteCount, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private func deviceUID(_ device: CMIODeviceID) -> String? {
        propertyString(device, selector: UInt32(kCMIODevicePropertyDeviceUID))
    }

    private func streamName(_ stream: CMIOStreamID) -> String? {
        propertyString(stream, selector: UInt32(kCMIOObjectPropertyName))
    }

    private func streams(_ device: CMIODeviceID) -> [CMIOStreamID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: UInt32(kCMIODevicePropertyStreams),
            mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
            mElement: UInt32(kCMIOObjectPropertyElementMain)
        )
        var byteCount: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &byteCount) == noErr else { return [] }
        var streams = [CMIOStreamID](repeating: 0, count: Int(byteCount) / MemoryLayout<CMIOStreamID>.size)
        var used = byteCount
        guard CMIOObjectGetPropertyData(device, &address, 0, nil, byteCount, &used, &streams) == noErr else { return [] }
        return streams
    }

    private func makeSampleBuffer(_ jpeg: Data) -> CMSampleBuffer? {
        guard let image = CIImage(data: jpeg),
              image.extent.width <= CGFloat(ProtocolLimits.maxJPEGDimension),
              image.extent.height <= CGFloat(ProtocolLimits.maxJPEGDimension),
              let pixelBuffer = makePixelBuffer() else { return nil }
        clear(pixelBuffer)
        let scale = min(
            CGFloat(RocamCameraIdentity.width) / image.extent.width,
            CGFloat(RocamCameraIdentity.height) / image.extent.height
        )
        let translated = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale).translatedBy(
            x: (CGFloat(RocamCameraIdentity.width) / scale - image.extent.width) / 2 - image.extent.origin.x,
            y: (CGFloat(RocamCameraIdentity.height) / scale - image.extent.height) / 2 - image.extent.origin.y
        ))
        context.render(translated, to: pixelBuffer)
        return sampleBuffer(for: pixelBuffer)
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
        ]
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, RocamCameraIdentity.width, RocamCameraIdentity.height,
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer
        ) == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }

    private func clear(_ pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }

    private func sampleBuffer(for pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var description: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &description
        ) == noErr, let description else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: RocamCameraIdentity.fps),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
            sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }
}
