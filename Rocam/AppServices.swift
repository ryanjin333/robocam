import Combine
import Foundation
import UIKit

// SCREEN_DIMMING_POLICY_BEGIN
/// State-only policy kept separate from UIKit so the timing and brightness
/// ownership rules can be exercised deterministically.
struct ScreenDimmingPolicy {
    enum Action: Equatable {
        case none
        case dim(to: Double)
        case restore(to: Double)
    }

    static let graceInterval: TimeInterval = 15
    static let targetBrightness = 0.08
    private static let brightnessTolerance = 0.002

    private var baselineBrightness: Double?
    private var lastFeatureBrightness: Double?
    private var lastObservedBrightness: Double?
    private var graceStartedAt: TimeInterval?

    mutating func advance(eligible: Bool, brightness: Double, at now: TimeInterval) -> Action {
        let current = sanitized(brightness)
        observeExternalBrightness(current, eligible: eligible, at: now)

        guard eligible else {
            return restoreAndReset(current)
        }

        guard let baselineBrightness else {
            self.baselineBrightness = current
            graceStartedAt = now
            return .none
        }
        guard let graceStartedAt, now >= graceStartedAt,
              now - graceStartedAt >= Self.graceInterval else {
            return .none
        }

        let target = min(baselineBrightness, Self.targetBrightness)
        guard target + Self.brightnessTolerance < baselineBrightness else {
            return .none
        }
        guard lastFeatureBrightness == nil else { return .none }
        return .dim(to: target)
    }

    /// A direct phone interaction restores a feature-owned dim immediately and
    /// starts the grace period again without cancelling the underlying control.
    mutating func noteInteraction(eligible: Bool, brightness: Double, at now: TimeInterval) -> Action {
        let current = sanitized(brightness)
        observeExternalBrightness(current, eligible: eligible, at: now)
        let action = restoreFeatureDimIfOwned(current)

        guard eligible else {
            reset()
            return action
        }
        if baselineBrightness == nil { baselineBrightness = current }
        graceStartedAt = now
        return action
    }

    /// Record the brightness requested from UIKit, rather than reading
    /// `UIScreen.main.brightness` immediately after assigning it. UIKit can
    /// report the prior value for a short time, which would otherwise make the
    /// next timer tick mistake the feature's own write for an external change.
    mutating func recordFeatureBrightness(_ requestedBrightness: Double) {
        let value = sanitized(requestedBrightness)
        lastFeatureBrightness = value
        lastObservedBrightness = value
    }

    /// As above, retain the requested restore value while the display setter
    /// settles. Physical display status remains read directly from UIKit.
    mutating func recordRestoredBrightness(_ requestedBrightness: Double) {
        lastObservedBrightness = sanitized(requestedBrightness)
    }

    func isDimming(at brightness: Double) -> Bool {
        guard let lastFeatureBrightness else { return false }
        return approximatelyEqual(sanitized(brightness), lastFeatureBrightness)
    }

    private mutating func observeExternalBrightness(_ current: Double, eligible: Bool, at now: TimeInterval) {
        if let lastFeatureBrightness, !approximatelyEqual(current, lastFeatureBrightness) {
            // The display was changed outside this feature. Its value becomes
            // the new baseline and is never overwritten by a stale restore.
            self.lastFeatureBrightness = nil
            baselineBrightness = current
            graceStartedAt = eligible ? now : nil
        } else if lastFeatureBrightness == nil,
                  let lastObservedBrightness,
                  !approximatelyEqual(current, lastObservedBrightness) {
            // A manual brightness change during the grace period also gets a
            // fresh, full grace interval before Rocam dims again.
            baselineBrightness = current
            graceStartedAt = eligible ? now : nil
        }
        lastObservedBrightness = current
    }

    private mutating func restoreAndReset(_ current: Double) -> Action {
        let action = restoreFeatureDimIfOwned(current)
        reset()
        return action
    }

    private mutating func restoreFeatureDimIfOwned(_ current: Double) -> Action {
        guard lastFeatureBrightness != nil else { return .none }
        defer { lastFeatureBrightness = nil }
        guard let baselineBrightness else { return .none }
        // `observeExternalBrightness` cleared ownership before this point when
        // the user or system supplied a different brightness.
        guard !approximatelyEqual(current, baselineBrightness) else { return .none }
        return .restore(to: baselineBrightness)
    }

    private mutating func reset() {
        baselineBrightness = nil
        lastFeatureBrightness = nil
        lastObservedBrightness = nil
        graceStartedAt = nil
    }

    private func sanitized(_ brightness: Double) -> Double {
        guard brightness.isFinite else { return 0 }
        return min(1, max(0, brightness))
    }

    private func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) <= Self.brightnessTolerance
    }
}
// SCREEN_DIMMING_POLICY_END

final class AppServices: ObservableObject {
    static let shared = AppServices()

    let camera = CameraService()
    lazy var audio = AudioCapture(frames: camera.frames)
    lazy var server = StreamServer(camera: camera, audio: audio)

    private var streamingActive = false
    private var recordingActive = false
    private var screenDimmingViewVisible = false
    private var screenDimmingForegroundActive = false
    private var screenDimmingSheetPresented = false
    private var screenDimmingTimer: Timer?
    private var screenDimmingPolicy = ScreenDimmingPolicy()
    @Published private(set) var externalDisplayActive = false
    @Published private(set) var screenDimmed = false
    @Published private(set) var actualDisplayBrightness: CGFloat

    private init() {
        actualDisplayBrightness = UIScreen.main.brightness
    }

    func setStreamingActive(_ active: Bool) {
        assert(Thread.isMainThread)
        streamingActive = active
        updateIdleTimer()
        updateScreenDimmingLifecycle()
    }

    func setRecordingActive(_ active: Bool) {
        assert(Thread.isMainThread)
        recordingActive = active
        updateIdleTimer()
    }

    func setExternalDisplayActive(_ active: Bool) {
        assert(Thread.isMainThread)
        externalDisplayActive = active
        camera.frames.setExternalDisplayActive(active)
        audio.setExternalDisplayActive(active)
        updateIdleTimer()
    }

    /// ContentView reports visibility independently from the listener. This
    /// makes dismissal, inactive scenes, and backgrounding restore the display
    /// even if the listener has not reported its cancellation yet.
    func setScreenDimmingViewVisible(_ visible: Bool) {
        assert(Thread.isMainThread)
        screenDimmingViewVisible = visible
        updateScreenDimmingLifecycle()
    }

    func setScreenDimmingForegroundActive(_ active: Bool) {
        assert(Thread.isMainThread)
        screenDimmingForegroundActive = active
        updateScreenDimmingLifecycle()
    }

    func setScreenDimmingSheetPresented(_ presented: Bool) {
        assert(Thread.isMainThread)
        screenDimmingSheetPresented = presented
        refreshScreenDimming()
    }

    /// Use a simultaneous SwiftUI gesture so focus, zoom, sliders, and scroll
    /// gestures keep receiving their normal events.
    func noteScreenInteraction() {
        assert(Thread.isMainThread)
        let now = ProcessInfo.processInfo.systemUptime
        let brightness = Double(UIScreen.main.brightness)
        let action = screenDimmingPolicy.noteInteraction(
            eligible: hasEligibleRemoteViewer(at: now),
            brightness: brightness,
            at: now
        )
        applyScreenDimming(action)
    }

    /// StreamServer snapshots this from the main thread. Reading the display
    /// here keeps physical verification tied to UIScreen rather than a cached
    /// timer tick or preview luminance.
    func screenDimmingStatus() -> (screenDimmed: Bool, actualDisplayBrightness: CGFloat) {
        assert(Thread.isMainThread)
        publishScreenDimmingState()
        return (screenDimmed, actualDisplayBrightness)
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = streamingActive || recordingActive || externalDisplayActive
    }

    private func updateScreenDimmingLifecycle() {
        let shouldPoll = streamingActive && screenDimmingViewVisible && screenDimmingForegroundActive
        if shouldPoll {
            if screenDimmingTimer == nil {
                let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    self?.refreshScreenDimming()
                }
                screenDimmingTimer = timer
            }
            refreshScreenDimming()
        } else {
            screenDimmingTimer?.invalidate()
            screenDimmingTimer = nil
            refreshScreenDimming()
        }
    }

    private func refreshScreenDimming() {
        assert(Thread.isMainThread)
        let now = ProcessInfo.processInfo.systemUptime
        let action = screenDimmingPolicy.advance(
            eligible: hasEligibleRemoteViewer(at: now),
            brightness: Double(UIScreen.main.brightness),
            at: now
        )
        applyScreenDimming(action)
    }

    private func hasEligibleRemoteViewer(at now: TimeInterval) -> Bool {
        streamingActive && screenDimmingViewVisible && screenDimmingForegroundActive &&
            !screenDimmingSheetPresented && camera.frames.hasRemoteViewer(at: now)
    }

    private func applyScreenDimming(_ action: ScreenDimmingPolicy.Action) {
        assert(Thread.isMainThread)
        switch action {
        case .none:
            break
        case .dim(let target):
            UIScreen.main.brightness = CGFloat(target)
            screenDimmingPolicy.recordFeatureBrightness(target)
        case .restore(let baseline):
            UIScreen.main.brightness = CGFloat(baseline)
            screenDimmingPolicy.recordRestoredBrightness(baseline)
        }
        publishScreenDimmingState()
    }

    private func publishScreenDimmingState() {
        assert(Thread.isMainThread)
        let brightness = UIScreen.main.brightness
        let dimmed = screenDimmingPolicy.isDimming(at: Double(brightness))
        if actualDisplayBrightness != brightness { actualDisplayBrightness = brightness }
        if screenDimmed != dimmed { screenDimmed = dimmed }
    }
}
