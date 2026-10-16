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
