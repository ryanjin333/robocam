import Foundation

enum RocamCameraIdentity {
    static let deviceID = UUID(uuidString: "4A7A8842-2AB2-4AF7-BDA5-28C7D570C001")!
    static let sourceID = UUID(uuidString: "4A7A8842-2AB2-4AF7-BDA5-28C7D570C002")!
    static let sinkID = UUID(uuidString: "4A7A8842-2AB2-4AF7-BDA5-28C7D570C003")!
    static let legacyDeviceUID = "com.rocam.desktop.device"
    static let sourceName = "Rocam Camera"
    static let sinkName = "Rocam Input"
    static let width = 1280
    static let height = 720
    static let fps: Int32 = 30
}
