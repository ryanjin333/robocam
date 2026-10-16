import Foundation

@main
struct FrameRateChecks {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAILED: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        checkDefaultAndSelectedReservationCadence()
        checkExplicitTwentyFPSCadence()
        checkLiveRateMapsToCaptureCapabilities()
        checkLiDARRateLimitDoesNotClaimAnUnavailableRate()
        checkLeaseAndInvalidation()
        print("Frame rate checks passed")
    }

    private static func reservingFrames(at rate: Int? = nil) -> FrameStore {
        let frames = FrameStore()
        if let rate { frames.setStreamFPS(rate) }
        frames.setJPEGCaptureEnabled(true)
        frames.markRobotViewer(at: 0)
        return frames
    }

    private static func checkDefaultAndSelectedReservationCadence() {
        let defaults = reservingFrames()
        require(defaults.currentStreamFPS() == 30, "the default live rate must be 30 FPS")
        require(defaults.reserveRobotCapture(at: 0) != nil, "the first default-rate capture must reserve")
        require(defaults.reserveRobotCapture(at: 1.0 / 30.0) != nil,
                "the default 30 FPS reservation must not be limited to 20 FPS")

        let sixty = reservingFrames(at: 60)
        require(sixty.reserveRobotCapture(at: 0) != nil, "the first 60 FPS capture must reserve")
        require(sixty.reserveRobotCapture(at: 1.0 / 60.0) != nil,
                "the selected 60 FPS reservation must not be limited to 20 FPS")
    }

    private static func checkExplicitTwentyFPSCadence() {
        let twenty = reservingFrames(at: 20)
        require(twenty.reserveRobotCapture(at: 0) != nil, "the first 20 FPS capture must reserve")
        require(twenty.reserveRobotCapture(at: 1.0 / 30.0) == nil,
                "an explicit 20 FPS choice must remain at its selected cadence")
        require(twenty.reserveRobotCapture(at: 1.0 / 20.0) != nil,
                "an explicit 20 FPS choice must reserve at 20 FPS")
    }

    private static func checkLiveRateMapsToCaptureCapabilities() {
        let captureRates = [24, 30, 60, 120]
        require(LiveFrameRatePolicy.availableLiveRates(supportedCaptureRates: captureRates) == [15, 20, 30, 60, 120],
                "capture capabilities must expose the supported live choices")
        require(LiveFrameRatePolicy.captureRate(forLiveRate: 15, supportedCaptureRates: captureRates) == 24,
                "15 FPS live output must use the lowest sufficient capture rate")
        require(LiveFrameRatePolicy.captureRate(forLiveRate: 20, supportedCaptureRates: captureRates) == 24,
                "20 FPS live output must use the lowest sufficient capture rate")
        require(LiveFrameRatePolicy.captureRate(forLiveRate: 60, supportedCaptureRates: captureRates) == 60,
                "60 FPS live output must request 60 FPS capture")
        let twentyFPSCapture = LiveFrameRatePolicy.captureRate(forLiveRate: 20, supportedCaptureRates: captureRates)
        let deliveredRates = LiveFrameRatePolicy.availableLiveRates(
            supportedCaptureRates: [twentyFPSCapture].compactMap { $0 }
        )
        require(deliveredRates == [15, 20],
                "a 24 FPS capture setting must not claim 30 FPS live delivery")
    }

    private static func checkLiDARRateLimitDoesNotClaimAnUnavailableRate() {
        let lidarCaptureRates = [24, 30]
        let liveRates = LiveFrameRatePolicy.availableLiveRates(supportedCaptureRates: lidarCaptureRates)
        require(liveRates == [15, 20, 30], "LiDAR 24/30 FPS capture must not advertise 60 or 120 FPS live output")
        require(LiveFrameRatePolicy.effectiveLiveRate(requested: 120, availableRates: liveRates) == 30,
                "a saved 120 FPS request must report the LiDAR-compatible 30 FPS rate")
        require(LiveFrameRatePolicy.effectiveLiveRate(requested: 60, availableRates: liveRates) == 30,
                "a 60 FPS request must not claim a rate above the LiDAR capture cadence")
    }

    private static func checkLeaseAndInvalidation() {
        let frames = reservingFrames(at: 30)
        guard let token = frames.reserveRobotCapture(at: 0) else {
            require(false, "a valid lease must reserve a capture")
            return
        }
        frames.setRobotPacket(Data([1]), token: token, at: 0)
        require(frames.latestRobotPacket(at: 0) == Data([1]), "a leased packet must remain readable")

        frames.clearCameraFrames()
        require(frames.latestRobotPacket(at: 0) == nil, "camera invalidation must clear the robot packet")
        frames.setRobotPacket(Data([2]), token: token, at: 0)
        require(frames.latestRobotPacket(at: 0) == nil, "invalidated capture tokens must stay rejected")
        require(frames.reserveRobotCapture(at: 0) != nil, "invalidation must reset reservation timing under the active lease")
        require(frames.reserveRobotCapture(at: 2) == nil, "expired leases must still prevent robot capture")
    }
}
