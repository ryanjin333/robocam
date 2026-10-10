import AVFoundation
import CoreImage
import Foundation

private final class PacketStore {
    private let lock = NSLock()
    private var packets: [EncodedVideoPacket] = []

    func append(_ packet: EncodedVideoPacket) {
        lock.lock(); defer { lock.unlock() }
        packets.append(packet)
    }

    func packets(since count: Int) -> [EncodedVideoPacket] {
        lock.lock(); defer { lock.unlock() }
        return Array(packets.dropFirst(count))
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return packets.count
    }
}

@main
struct StreamQualityChecks {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAILED: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        checkSharedQualityPolicy()
        checkNativeEncoderQualitySwitches()
        print("Stream quality checks passed")
    }

    private static func checkSharedQualityPolicy() {
        require(StreamImageQuality.normal.jpegCompression == 0.75, "Normal JPEG compression changed")
        require(StreamImageQuality.low.jpegCompression == 0.60, "Low JPEG compression changed")
        require(StreamImageQuality.high.jpegCompression == 0.85, "High JPEG compression changed")
        require(StreamImageQuality.veryHigh.jpegCompression == 0.90, "Very high JPEG compression changed")
        require(StreamImageQuality.normal.rawValue == "Normal", "Normal quality name changed")

        let baseline = 4_000_000
        let rates = StreamImageQuality.allCases.map { $0.adjustedBitRate(baseline) }
        require(rates == [2_000_000, 4_000_000, 6_000_000, 8_000_000], "quality multipliers are incorrect")
        require(StreamImageQuality.normal.adjustedBitRate(250_000) == 250_000,
                "Normal must preserve the valid lower bound")
        require(StreamImageQuality.normal.adjustedBitRate(20_000_000) == 20_000_000,
                "Normal must preserve the SDR baseline")
        require(StreamImageQuality.normal.adjustedBitRate(25_000_000) == 25_000_000,
                "Normal must preserve the HDR baseline")
        require(StreamImageQuality.low.adjustedBitRate(-1) == 250_000,
                "negative baselines must not underflow")
        require(StreamImageQuality.veryHigh.adjustedBitRate(Int.max) == 80_000_000,
                "huge baselines must not overflow")
        require(rates == rates.sorted(), "quality rates must be monotonic before saturation")

        let stream = EncodedStream(codec: .h264, callbackQueue: DispatchQueue(label: "quality.initial"))
        require(!stream.status.ready && stream.status.bitRate == 0,
                "inactive encoder status must expose a zero target rate")
    }

    private static func checkNativeEncoderQualitySwitches() {
        let qualities: [StreamImageQuality] = [.low, .normal, .high, .veryHigh]
        let baseline = 2_000_000
        for codec in RocamVideoCodec.allCases {
            let encoderQueue = DispatchQueue(label: "quality.native.\(codec.endpoint)")
            let packets = PacketStore()
            let stream = EncodedStream(codec: codec, callbackQueue: encoderQueue)
            encoderQueue.sync { stream.onPacket = packets.append }
            defer { encoderQueue.sync { stream.invalidate() } }

            var totalSubmitted = 0
            for (phase, quality) in qualities.enumerated() {
                let expectedRate = quality.adjustedBitRate(baseline)
                var startingCount = 0
                var phaseStartPTS: UInt64 = 0
                var attempts = 0
                var selectedTarget = false
                var phaseVerified = false
                let deadline = Date().addingTimeInterval(12)
                while Date() < deadline {
                    let result: (status: EncodedStreamStatus, startingCount: Int?, phaseStartPTS: UInt64?) = encoderQueue.sync {
                        let countBeforeFirstSubmission = attempts == 0 ? packets.count : nil
                        let firstSubmissionPTS = attempts == 0 ? UInt64(totalSubmitted) * 100_000 : nil
                        let color = CIColor(red: CGFloat(phase) / 4, green: 0.35, blue: 0.8, alpha: 1)
                        let image = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
                        let pts = CMTime(value: Int64(totalSubmitted) * 100, timescale: 1_000)
                        stream.append(image: image, pts: pts, fps: 30, bitRate: expectedRate)
                        totalSubmitted += 1
                        return (stream.status, countBeforeFirstSubmission, firstSubmissionPTS)
                    }
                    if let count = result.startingCount { startingCount = count }
                    if let pts = result.phaseStartPTS { phaseStartPTS = pts }
                    selectedTarget = result.status.ready && result.status.bitRate == expectedRate
                    // A prior phase may have a second access unit already in flight
                    // when its first keyframe reaches PacketStore. Restrict this
                    // assertion to access units submitted for this quality phase.
                    let phasePackets = packets.packets(since: startingCount)
                        .filter { $0.pts >= phaseStartPTS }
                    if selectedTarget, let first = phasePackets.first {
                        require(first.isKeyframe && first.flags & 2 != 0,
                                "quality switches must begin with a discontinuity keyframe")
                        require(first.bytes.starts(with: Data([0, 0, 0, 1])), "packet must remain Annex-B")
                        phaseVerified = true
                        break
                    }
                    attempts += 1
                    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                }
                require(selectedTarget,
                        "active \(codec.endpoint) encoder must report \(quality.rawValue)'s target rate")
                require(phaseVerified,
                        "native \(codec.endpoint) did not verify a \(quality.rawValue) packet")
            }
            require(packets.count <= totalSubmitted, "encoder must not build an unbounded output backlog")
        }
    }
}
