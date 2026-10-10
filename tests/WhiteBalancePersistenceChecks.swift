import Foundation

@main
struct WhiteBalancePersistenceChecks {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAILED: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        guard let clamped = CameraWhiteBalanceGains(defaultsValue: [0.25, 2.5, 9], maximum: 4) else {
            require(false, "finite gains must decode")
            return
        }
        require(clamped.values == [1, 2.5, 4], "persisted gains must clamp to the device range")

        let suiteName = "com.rocam.WhiteBalancePersistenceChecks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            require(false, "an isolated defaults suite must be available")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(clamped.values, forKey: "gains")
        guard let roundTripped = CameraWhiteBalanceGains(defaultsValue: defaults.object(forKey: "gains"), maximum: 4) else {
            require(false, "stored gains must round trip")
            return
        }
        require(roundTripped == clamped, "gains changed during a defaults round trip")

        require(CameraWhiteBalanceGains(defaultsValue: nil, maximum: 4) == nil,
                "missing gains must mean automatic white balance")
        require(CameraWhiteBalanceGains(defaultsValue: [1, 2], maximum: 4) == nil,
                "partial gains must not create a white-balance lock")
        require(CameraWhiteBalanceGains(defaultsValue: [1, Float.nan, 3], maximum: 4) == nil,
                "non-finite gains must not create a white-balance lock")
        require(CameraWhiteBalanceGains(defaultsValue: [true, 2, 3], maximum: 4) == nil,
                "non-numeric persisted values must not create a white-balance lock")
        require(CameraWhiteBalanceGains(defaultsValue: [1, 2, 3], maximum: 0) == nil,
                "an invalid device maximum must not create a white-balance lock")

        print("White-balance persistence checks passed")
    }
}
