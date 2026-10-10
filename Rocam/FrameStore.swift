import Foundation
import CoreGraphics

final class FrameStore {
    private let lock = NSLock()
    private var color: Data?
    private var colorImage: CGImage?
    private var colorSequence: UInt64 = 0
    private var depth: Data?
    private var depthImage: CGImage?
    private var depthSequence: UInt64 = 0
    private var depthRaw: Data?
    // One self-contained synchronized RGB/depth packet. It is deliberately not a
    // history: robotics clients request a fresh observation and retry warm-up.
    private var robotPacket: (createdAt: TimeInterval, body: Data)?
    private var robotViewerUntil: TimeInterval = 0
    private var nextRobotCaptureTime: TimeInterval = 0
    private var robotGeneration: UInt64 = 0
    private var robotSequence: UInt64 = 0
    private var jpegEnabled = false
    private var colorViewers = 0
    private var depthViewers = 0
    private var externalDisplayActive = false
    private var depthPreviewCount = 0
    private var streamFPS = 20
    private var hdrViewerUntil: TimeInterval = 0
    private var sourceWidth = 0
    private var sourceHeight = 0
    private var captureFPS = 0.0
    private var captureWindowStart: TimeInterval?
    private var captureFrameCount = 0
    private var lastCaptureTime: TimeInterval?
    private var audioChunks: [(UInt64, Data)] = []
    private var audioSequence: UInt64 = 0
    private var audioSampleRate: Int = 48000
    private var audioActive = false
    private var encoded: [RocamVideoCodec: [EncodedVideoPacket]] = [:]
    private var encodedViewerCounts: [RocamVideoCodec: Int] = [:]
    private var encodedSequences: [RocamVideoCodec: UInt32] = [:]
    private let encodedPacketLimit = 64
    private let encodedByteLimit = 32 * 1024 * 1024

    func setJPEGCaptureEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        jpegEnabled = enabled
        if !enabled {
            color = nil
            depth = nil
            depthRaw = nil
            hdrViewerUntil = 0
            invalidateRobotLocked(clearLease: true)
            if !externalDisplayActive { colorImage = nil }
            if !externalDisplayActive && depthPreviewCount == 0 { depthImage = nil }
        }
    }

    func shouldEncodeJPEG() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return jpegEnabled
    }

    /// A remote receiver is present only while one of the streaming routes has
    /// an active client or a short-lived robotics/HDR demand lease. Merely
    /// listening for a connection, rendering the local depth preview, or
    /// driving an external display must not be treated as a receiver.
    func hasRemoteViewer(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard jpegEnabled else { return false }
        return colorViewers > 0 ||
            depthViewers > 0 ||
            encodedViewerCounts.values.contains(where: { $0 > 0 }) ||
            now < robotViewerUntil ||
            now < hdrViewerUntil
    }

    func beginImageStream(depth: Bool) {
        lock.lock(); defer { lock.unlock() }
        if depth { depthViewers += 1 } else { colorViewers += 1 }
    }

    func endImageStream(depth: Bool) {
        lock.lock(); defer { lock.unlock() }
        if depth { depthViewers = max(0, depthViewers - 1) }
        else { colorViewers = max(0, colorViewers - 1) }
    }

    func colorCaptureFPS() -> Int {
        lock.lock(); defer { lock.unlock() }
        return jpegEnabled && colorViewers == 0 && !externalDisplayActive ? 1 : streamFPS
    }

    func compressedCaptureFPS() -> Int {
        lock.lock(); defer { lock.unlock() }
        return encodedViewerCounts.values.contains(where: { $0 > 0 }) ? streamFPS : 0
    }

    func depthCaptureFPS() -> Int {
        lock.lock(); defer { lock.unlock() }
        return jpegEnabled && depthViewers == 0 && !externalDisplayActive && depthPreviewCount == 0 ? 1 : streamFPS
    }

    func setExternalDisplayActive(_ active: Bool) {
        lock.lock(); defer { lock.unlock() }
        externalDisplayActive = active
        if !active { colorImage = nil }
        if !active && depthPreviewCount == 0 { depthImage = nil }
    }

    func beginDepthPreview() {
        lock.lock(); defer { lock.unlock() }
        depthPreviewCount += 1
    }

    func endDepthPreview() {
        lock.lock(); defer { lock.unlock() }
        depthPreviewCount = max(0, depthPreviewCount - 1)
        if depthPreviewCount == 0 && !externalDisplayActive { depthImage = nil }
    }

    func shouldRenderColor() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return jpegEnabled || externalDisplayActive || encodedViewerCounts.values.contains(where: { $0 > 0 })
    }

    func needsColorImage() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return externalDisplayActive
    }

    func shouldRenderDepth() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return jpegEnabled || externalDisplayActive || depthPreviewCount > 0
    }

    func setColor(_ data: Data?, image: CGImage?, updateJPEG: Bool) {
        lock.lock(); defer { lock.unlock() }
        if updateJPEG {
            color = jpegEnabled ? data : nil
            if color != nil { colorSequence &+= 1 }
        }
        colorImage = externalDisplayActive ? image : nil
    }

    func setDepth(_ data: Data?, raw: Data?, image: CGImage) {
        lock.lock(); defer { lock.unlock() }
        depth = jpegEnabled ? data : nil
        if depth != nil { depthSequence &+= 1 }
        depthRaw = jpegEnabled ? raw : nil
        depthImage = externalDisplayActive || depthPreviewCount > 0 ? image : nil
    }

    func latestColor() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return color
    }

    func latestColor(after sequence: UInt64) -> (UInt64, Data)? {
        lock.lock(); defer { lock.unlock() }
        guard colorSequence != sequence, let color else { return nil }
        return (colorSequence, color)
    }

    func latestColorImage() -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return colorImage
    }

    func latestDepth() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return depth
    }

    func latestDepth(after sequence: UInt64) -> (UInt64, Data)? {
        lock.lock(); defer { lock.unlock() }
        guard depthSequence != sequence, let depth else { return nil }
        return (depthSequence, depth)
    }

    func latestDepthImage() -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return depthImage
    }

    func latestDepthRaw() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return depthRaw
    }

    /// An authenticated `/robot.frame` request holds a short demand lease. This
    /// keeps expensive native JPEG/depth packing idle until a robotics client asks.
    func markRobotViewer(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        robotViewerUntil = now + 2
    }

    /// Reserves one robot capture at the effective live rate, capped at 20 FPS.
    /// Call this immediately before the native JPEG/depth copy, on videoQueue.
    func reserveRobotCapture(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard jpegEnabled, now < robotViewerUntil else { return nil }
        let rate = min(streamFPS, 20)
        guard rate > 0, now >= nextRobotCaptureTime else { return nil }
        let interval = 1.0 / Double(rate)
        nextRobotCaptureTime = now - nextRobotCaptureTime > interval ? now + interval : nextRobotCaptureTime + interval
        return robotGeneration
    }

    func setRobotPacket(_ body: Data, token: UInt64, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        // The producer and desktop parser share this practical bound.
        guard body.count <= 32 * 1024 * 1024,
              token == robotGeneration,
              jpegEnabled,
              now < robotViewerUntil else { return }
        robotPacket = (now, body)
    }

    func nextRobotSequence() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        robotSequence &+= 1
        return robotSequence
    }

    func latestRobotPacket(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let robotPacket else { return nil }
        guard now >= robotPacket.createdAt, now - robotPacket.createdAt <= 1 else {
            self.robotPacket = nil
            return nil
        }
        return robotPacket.body
    }

    func clearRobotPacket() {
        lock.lock(); defer { lock.unlock() }
        invalidateRobotLocked()
    }

    func clearDepth() {
        lock.lock(); defer { lock.unlock() }
        depth = nil
        depthRaw = nil
        depthImage = nil
        invalidateRobotLocked()
    }

    func clearCameraFrames() {
        lock.lock(); defer { lock.unlock() }
        color = nil
        colorImage = nil
        depth = nil
        depthRaw = nil
        depthImage = nil
        sourceWidth = 0
        sourceHeight = 0
        captureFPS = 0
        captureWindowStart = nil
        captureFrameCount = 0
        lastCaptureTime = nil
        encoded.removeAll(keepingCapacity: true)
        invalidateRobotLocked()
    }

    func noteCaptureFrame(width: Int, height: Int, at time: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        sourceWidth = width
        sourceHeight = height
        lastCaptureTime = time
        guard let start = captureWindowStart, time >= start else {
            captureWindowStart = time
            captureFrameCount = 1
            captureFPS = 0
            return
        }
        captureFrameCount += 1
        let elapsed = time - start
        if elapsed >= 1 {
            captureFPS = Double(captureFrameCount - 1) / elapsed
            captureWindowStart = time
            captureFrameCount = 1
        }
    }

    func captureInfo(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> (width: Int, height: Int, fps: Double) {
        lock.lock(); defer { lock.unlock() }
        let recent = lastCaptureTime.map { time >= $0 && time - $0 < 2 } ?? false
        return (sourceWidth, sourceHeight, recent ? captureFPS : 0)
    }

    func setStreamFPS(_ rate: Int) {
        lock.lock(); defer { lock.unlock() }
        streamFPS = rate
    }

    func currentStreamFPS() -> Int {
        lock.lock(); defer { lock.unlock() }
        return streamFPS
    }

    /// The selected rate is used directly for rendering and encoding.
    func effectiveStreamFPS() -> Int {
        lock.lock(); defer { lock.unlock() }
        return streamFPS
    }

    func beginEncodedStream(codec: RocamVideoCodec) {
        lock.lock(); defer { lock.unlock() }
        encodedViewerCounts[codec, default: 0] += 1
    }

    func endEncodedStream(codec: RocamVideoCodec) {
        lock.lock(); defer { lock.unlock() }
        encodedViewerCounts[codec] = max(0, (encodedViewerCounts[codec] ?? 0) - 1)
        if encodedViewerCounts[codec] == 0 {
            encoded[codec] = []
        }
    }

    func encodedDemand() -> [RocamVideoCodec] {
        lock.lock(); defer { lock.unlock() }
        return encodedViewerCounts.compactMap { $0.value > 0 ? $0.key : nil }
    }

    func encodedClientCount(codec: RocamVideoCodec) -> Int {
        lock.lock(); defer { lock.unlock() }
        return encodedViewerCounts[codec] ?? 0
    }

    func currentEncodedSequence(codec: RocamVideoCodec) -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        return encoded[codec]?.last?.sequence ?? 0
    }

    func appendEncoded(_ packet: EncodedVideoPacket) {
        lock.lock(); defer { lock.unlock() }
        guard (encodedViewerCounts[packet.codec] ?? 0) > 0 else { return }
        var packet = packet
        var next = (encodedSequences[packet.codec] ?? 0) &+ 1
        if next == 0 {
            // Do not make a wrapped dependent access unit look contiguous. The
            // next keyframe starts the fresh sequence and marks discontinuity.
            guard packet.isKeyframe else { return }
            next = 1
            packet.flags |= 2
        }
        encodedSequences[packet.codec] = next
        packet.sequence = next
        encoded[packet.codec, default: []].append(packet)
        trimEncodedLocked()
    }

    func clearEncodedPackets() {
        lock.lock(); defer { lock.unlock() }
        encoded.removeAll(keepingCapacity: true)
    }

    func encodedPacket(codec: RocamVideoCodec, after sequence: UInt32) -> (packet: EncodedVideoPacket, skipped: Bool)? {
        lock.lock(); defer { lock.unlock() }
        guard let packets = encoded[codec], !packets.isEmpty else { return nil }
        if sequence == 0, let key = packets.first(where: { $0.isKeyframe }) { return (key, false) }
        // Nothing newer: do not replay an old GOP while waiting for the camera.
        guard packets.last?.sequence != sequence else { return nil }
        let expected = sequence == UInt32.max ? 1 : sequence &+ 1
        if let exact = packets.first(where: { $0.sequence == expected }) { return (exact, false) }
        if let key = packets.first(where: { $0.isKeyframe && isNewer($0.sequence, than: sequence) }) {
            return (key, true)
        }
        return nil
    }

    func encodedNeedsKeyframe(codec: RocamVideoCodec, after sequence: UInt32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let packets = encoded[codec], !packets.isEmpty else { return false }
        guard packets.last?.sequence != sequence else { return false }
        let expected = sequence == UInt32.max ? 1 : sequence &+ 1
        return !packets.contains(where: { $0.sequence == expected || ($0.isKeyframe && isNewer($0.sequence, than: sequence)) })
    }

    private func isNewer(_ candidate: UInt32, than cursor: UInt32) -> Bool {
        candidate > cursor || (cursor > UInt32.max - UInt32(encodedPacketLimit) && candidate <= UInt32(encodedPacketLimit))
    }

    private func trimEncodedLocked() {
        func bytes() -> Int { encoded.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.bytes.count } } }
        func count() -> Int { encoded.values.reduce(0) { $0 + $1.count } }
        while count() > encodedPacketLimit || bytes() > encodedByteLimit {
            guard let codec = encoded.compactMap({ pair in pair.value.first.map { (pair.key, $0.pts) } })
                .min(by: { $0.1 < $1.1 })?.0, var packets = encoded[codec], !packets.isEmpty else { return }
            packets.removeFirst()
            while let first = packets.first, !first.isKeyframe { packets.removeFirst() }
            encoded[codec] = packets
        }
    }

    func markHDRViewer(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        hdrViewerUntil = now + 10
    }

    func hdrCaptureFPS() -> Int {
        lock.lock(); defer { lock.unlock() }
        return jpegEnabled && ProcessInfo.processInfo.systemUptime < hdrViewerUntil
            ? streamFPS : 1
    }

    func setAudioSampleRate(_ rate: Int) {
        lock.lock(); defer { lock.unlock() }
        audioSampleRate = rate
    }

    private func invalidateRobotLocked(clearLease: Bool = false) {
        robotGeneration &+= 1
        robotPacket = nil
        nextRobotCaptureTime = 0
        if clearLease { robotViewerUntil = 0 }
    }

    func setAudioActive(_ active: Bool) {
        lock.lock(); defer { lock.unlock() }
        audioActive = active
        if !active { audioChunks.removeAll(keepingCapacity: true) }
    }

    func isAudioActive() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return audioActive
    }

    func sampleRate() -> Int {
        lock.lock(); defer { lock.unlock() }
        return audioSampleRate
    }

    func appendAudio(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard audioActive else { return }
        audioSequence += 1
        audioChunks.append((audioSequence, data))
        if audioChunks.count > 30 { audioChunks.removeFirst(audioChunks.count - 30) }
    }

    func audio(after sequence: UInt64) -> (UInt64, Data)? {
        lock.lock(); defer { lock.unlock() }
        guard audioActive else { return nil }
        return audioChunks.first(where: { $0.0 > sequence })
    }

    func currentAudioSequence() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return audioSequence
    }
}
