import Foundation

@main
struct ScreenDimmingChecks {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAILED: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        checkRemoteViewerDemand()
        checkGraceAndInteraction()
        checkDeferredBrightnessGetterOwnership()
        checkDisconnectAndSheetLifecycle()
        checkLowBrightnessAndManualChanges()
        print("Screen dimming checks passed")
    }

    private static func checkRemoteViewerDemand() {
        let frames = FrameStore()
        require(!frames.hasRemoteViewer(at: 0), "a stopped listener must not count as a receiver")

        frames.setJPEGCaptureEnabled(true)
        require(!frames.hasRemoteViewer(at: 0), "a listener without a client must not count as a receiver")
        frames.setExternalDisplayActive(true)
        frames.beginDepthPreview()
        require(!frames.hasRemoteViewer(at: 0), "local display/preview must not count as a receiver")

        frames.beginImageStream(depth: false)
        require(frames.hasRemoteViewer(at: 0), "color stream must count as a receiver")
        frames.endImageStream(depth: false)
        frames.beginImageStream(depth: true)
        require(frames.hasRemoteViewer(at: 0), "depth stream must count as a receiver")
        frames.endImageStream(depth: true)
        frames.beginEncodedStream(codec: .h264)
        require(frames.hasRemoteViewer(at: 0), "encoded stream must count as a receiver")
        frames.endEncodedStream(codec: .h264)

        frames.markRobotViewer(at: 100)
        require(frames.hasRemoteViewer(at: 101.9), "robot lease must count before expiry")
        require(!frames.hasRemoteViewer(at: 102), "robot lease must expire exactly at its deadline")
        frames.markHDRViewer(at: 200)
        require(frames.hasRemoteViewer(at: 209.9), "HDR lease must count before expiry")
        require(!frames.hasRemoteViewer(at: 210), "HDR lease must expire exactly at its deadline")

        frames.beginImageStream(depth: false)
        frames.setJPEGCaptureEnabled(false)
        require(!frames.hasRemoteViewer(at: 300), "disabled streaming must clear receiver demand")
    }

    private static func checkGraceAndInteraction() {
        var policy = ScreenDimmingPolicy()
        require(policy.advance(eligible: true, brightness: 0.75, at: 0) == .none,
                "receiver connection must begin a grace period")
        require(policy.advance(eligible: true, brightness: 0.75, at: 14.99) == .none,
                "screen must not dim before 15 seconds")
        require(policy.advance(eligible: true, brightness: 0.75, at: 15) == .dim(to: 0.08),
                "screen must dim after the full grace interval")
        policy.recordFeatureBrightness(0.08)
        require(policy.isDimming(at: 0.08), "feature ownership must be visible after dimming")
        require(policy.noteInteraction(eligible: true, brightness: 0.08, at: 16) == .restore(to: 0.75),
                "preview/control interaction must restore the original brightness")
        policy.recordRestoredBrightness(0.75)
        require(policy.advance(eligible: true, brightness: 0.75, at: 30.99) == .none,
                "interaction must restart the full grace interval")
        require(policy.advance(eligible: true, brightness: 0.75, at: 31) == .dim(to: 0.08),
                "dimming must resume only after the restarted interval")
    }

    private static func checkDeferredBrightnessGetterOwnership() {
        var policy = ScreenDimmingPolicy()
        _ = policy.advance(eligible: true, brightness: 0.75, at: 0)
        require(policy.advance(eligible: true, brightness: 0.75, at: 15) == .dim(to: 0.08),
                "setup must request the dim target")

        // The runtime records the requested target before UIKit's getter has
        // necessarily settled; the dedicated runtime harness covers that
        // deferred getter boundary. This policy check covers the next tick.
        policy.recordFeatureBrightness(0.08)
        require(policy.advance(eligible: true, brightness: 0.08, at: 16) == .none,
                "the settled dim target must not be treated as an external change")
        require(policy.isDimming(at: 0.08),
                "the feature must retain dim ownership after a deferred getter")
        require(policy.advance(eligible: false, brightness: 0.08, at: 17) == .restore(to: 0.75),
                "disconnect must restore the original brightness after a deferred getter")

        // Restoration has the same setter/getter ordering requirement. Record
        // the requested baseline even if UIKit still exposes the old target.
        policy.recordRestoredBrightness(0.75)
    }

    private static func checkDisconnectAndSheetLifecycle() {
        var policy = ScreenDimmingPolicy()
        _ = policy.advance(eligible: true, brightness: 0.66, at: 0)
        require(policy.advance(eligible: true, brightness: 0.66, at: 15) == .dim(to: 0.08),
                "setup must reach a dimmed state")
        policy.recordFeatureBrightness(0.08)
        require(policy.advance(eligible: false, brightness: 0.08, at: 16) == .restore(to: 0.66),
                "disconnect or an open sheet must restore brightness")
        policy.recordRestoredBrightness(0.66)
        require(policy.advance(eligible: true, brightness: 0.66, at: 17) == .none,
                "foreground return must begin a new grace interval")
        require(policy.advance(eligible: true, brightness: 0.66, at: 31.99) == .none,
                "sheet lifecycle must retain the restarted delay")
        require(policy.advance(eligible: true, brightness: 0.66, at: 32) == .dim(to: 0.08),
                "screen must dim again after the resumed grace interval")
    }

    private static func checkLowBrightnessAndManualChanges() {
        var alreadyLow = ScreenDimmingPolicy()
        _ = alreadyLow.advance(eligible: true, brightness: 0.05, at: 0)
        require(alreadyLow.advance(eligible: true, brightness: 0.05, at: 15) == .none,
                "an already dim display must not be brightened or rewritten")
        require(!alreadyLow.isDimming(at: 0.05), "feature must not claim ownership of an untouched low display")

        var policy = ScreenDimmingPolicy()
        _ = policy.advance(eligible: true, brightness: 0.65, at: 0)
        require(policy.advance(eligible: true, brightness: 0.65, at: 15) == .dim(to: 0.08),
                "setup must reach a dimmed state")
        policy.recordFeatureBrightness(0.08)
        require(policy.advance(eligible: true, brightness: 0.43, at: 20) == .none,
                "a manual brightness change must not be overwritten immediately")
        require(!policy.isDimming(at: 0.43), "manual brightness change must clear feature ownership")
        require(policy.advance(eligible: true, brightness: 0.43, at: 34.99) == .none,
                "manual brightness change must restart grace")
        require(policy.advance(eligible: true, brightness: 0.43, at: 35) == .dim(to: 0.08),
                "new manual brightness must become the next restore baseline")
        policy.recordFeatureBrightness(0.08)
        require(policy.advance(eligible: false, brightness: 0.08, at: 36) == .restore(to: 0.43),
                "disconnect must restore the user's newer brightness baseline")
    }
}
