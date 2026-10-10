import CoreFoundation
import CoreImage
import Foundation

@main
struct CustomOutputSizeChecks {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAILED: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        require(CustomOutputSize(width: 480, height: 640)?.width == 480,
                "480×640 must be accepted")
        require(CustomOutputSize(width: 320, height: 480)?.height == 480,
                "320×480 must be accepted")
        require(CustomOutputSize(width: 512, height: 768) != nil,
                "non-standard even portrait geometry must be accepted")
        require(CustomOutputSize(width: 481, height: 640) == nil,
                "odd width must be rejected")
        require(CustomOutputSize(width: 640, height: 481) == nil,
                "odd height must be rejected")
        require(CustomOutputSize(width: 640, height: 480) == nil,
                "landscape geometry must be rejected")
        require(CustomOutputSize(width: 4_096, height: 4_096) == nil,
                "pixel budget must be enforced")
        require(CustomOutputSize(width: 14, height: 640) == nil,
                "minimum dimension must be enforced")

        require(CustomOutputSize.strictInteger(NSNumber(value: 512)) == 512,
                "whole JSON number must parse")
        require(CustomOutputSize.strictInteger(NSNumber(value: 512.5)) == nil,
                "fractional JSON number must be rejected")
        require(CustomOutputSize.strictInteger(NSNumber(value: Double.infinity)) == nil,
                "non-finite JSON number must be rejected")
        require(CustomOutputSize.strictInteger(NSNumber(value: UInt64.max)) == nil,
                "oversized integer must be rejected before narrowing")
        require(CustomOutputSize.strictInteger(NSNumber(value: Double(Int.max))) == nil,
                "rounded Int maximum must be rejected before narrowing")
        require(CustomOutputSize.strictInteger(NSNumber(value: true)) == nil,
                "JSON boolean must be rejected")
        require(CustomOutputSize(jsonWidth: NSNumber(value: 480), jsonHeight: NSNumber(value: 640)) != nil,
                "strict JSON pair must create a valid size")
        require(CustomOutputSize(jsonWidth: NSNumber(value: 480.5), jsonHeight: NSNumber(value: 640)) == nil,
                "fractional width must not create a size")

        let source = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
        let expectedSizes = [(480, 640), (320, 480), (512, 768)]
        for (width, height) in expectedSizes {
            guard let size = CustomOutputSize(width: width, height: height) else {
                require(false, "test size must validate")
                return
            }
            let output = size.centerCropAndScale(source)
            require(output.extent.integral == CGRect(x: 0, y: 0, width: width, height: height),
                    "centre crop and scale must emit exact \(width)×\(height) geometry")
        }

        let suiteName = "com.rocam.CustomOutputSizeChecks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            require(false, "isolated defaults suite must be available")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(512, forKey: CustomOutputSize.widthDefaultsKey)
        defaults.set(768, forKey: CustomOutputSize.heightDefaultsKey)
        require(CustomOutputSize(defaults: defaults) == CustomOutputSize(width: 512, height: 768),
                "valid persisted output size must restore")
        defaults.set(UInt64.max, forKey: CustomOutputSize.widthDefaultsKey)
        require(CustomOutputSize(defaults: defaults) == nil,
                "corrupt persisted output size must not restore")

        print("Custom output size checks passed")
    }
}
