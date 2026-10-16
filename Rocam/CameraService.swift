import AVFoundation
import CoreImage
import CoreFoundation
import Foundation
import ImageIO
import Photos
import simd
import SwiftUI

struct CameraWhiteBalanceGains: Equatable {
    let values: [Float]

    init?(defaultsValue: Any?, maximum: Float) {
        guard maximum.isFinite, maximum >= 1,
              let rawValues = defaultsValue as? [NSNumber], rawValues.count == 3 else { return nil }
        let parsedValues = rawValues.compactMap(Self.finiteFloat)
        guard parsedValues.count == 3 else { return nil }
        values = parsedValues.map { min(max(1, $0), maximum) }
    }

    init?(red: Float, green: Float, blue: Float, maximum: Float) {
        self.init(defaultsValue: [red, green, blue], maximum: maximum)
    }

    private static func finiteFloat(_ value: Any) -> Float? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.floatValue
        return result.isFinite ? result : nil
    }
}

enum CameraLens: String, CaseIterable, Identifiable {
    case automatic = "Camera"
    case wide = "Wide"
    case ultraWide = "Ultra wide"
    case telephoto = "Telephoto"
    case front = "Front"
    case lidar = "LiDAR"

    var id: String { rawValue }
    var isBack: Bool { self != .front }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .automatic: return .builtInTripleCamera
        case .wide, .front: return .builtInWideAngleCamera
        case .ultraWide: return .builtInUltraWideCamera
        case .telephoto: return .builtInTelephotoCamera
        case .lidar: return .builtInLiDARDepthCamera
        }
    }
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case sd = "480p"
    case hd = "720p"
    case fullHD = "1080p"
    case qhd = "1440p"
    case ultraHD = "4K"

    var id: String { rawValue }

    /// The name shown in Camera controls describes the stream's canonical output,
    /// not the capture format AVFoundation uses while preparing it.
    var displayName: String {
        let dimensions = outputDimensions
        return "\(dimensions.width)×\(dimensions.height)"
    }

    var outputDimensions: CMVideoDimensions {
        switch self {
        case .sd: return CMVideoDimensions(width: 640, height: 480)
        case .hd: return CMVideoDimensions(width: 1280, height: 720)
        case .fullHD: return CMVideoDimensions(width: 1920, height: 1080)
        case .qhd: return CMVideoDimensions(width: 2560, height: 1440)
        case .ultraHD: return CMVideoDimensions(width: 3840, height: 2160)
        }
    }

    var outputLongEdge: CGFloat {
        CGFloat(max(outputDimensions.width, outputDimensions.height))
    }

    var preset: AVCaptureSession.Preset {
        switch self {
        case .sd: return .vga640x480
        case .hd: return .hd1280x720
        case .fullHD: return .hd1920x1080
        case .qhd: return .hd4K3840x2160
        case .ultraHD: return .hd4K3840x2160
        }
    }

    var captureDimensions: CMVideoDimensions {
        switch self {
        case .sd: return CMVideoDimensions(width: 640, height: 480)
        case .hd: return CMVideoDimensions(width: 1280, height: 720)
        case .fullHD: return CMVideoDimensions(width: 1920, height: 1080)
        // QHD is captured from the 4K format, then the stream's long edge is
        // constrained to its canonical 2560×1440 output dimensions.
        case .qhd, .ultraHD: return CMVideoDimensions(width: 3840, height: 2160)
        }
    }
}

/// An explicitly requested stream frame size. This affects the rendered color
/// stream only; it never changes the AVFoundation capture graph or raw robot
/// RGB/depth/calibration buffers.
struct CustomOutputSize: Equatable, Hashable {
    static let minimumDimension = 16
    static let maximumDimension = 4_096
    static let maximumPixelCount = 8_000_000
    static let widthDefaultsKey = "customOutputWidth"
    static let heightDefaultsKey = "customOutputHeight"

    let width: Int
    let height: Int

    init?(width: Int, height: Int) {
        guard width >= Self.minimumDimension, height >= Self.minimumDimension,
              width <= Self.maximumDimension, height <= Self.maximumDimension,
              width.isMultiple(of: 2), height.isMultiple(of: 2),
              width <= height,
              width <= Self.maximumPixelCount / height else {
            return nil
        }
        self.width = width
        self.height = height
    }

    init?(defaults: UserDefaults) {
        self.init(jsonWidth: defaults.object(forKey: Self.widthDefaultsKey),
                  jsonHeight: defaults.object(forKey: Self.heightDefaultsKey))
    }

    init?(jsonWidth: Any?, jsonHeight: Any?) {
        guard let width = Self.strictInteger(jsonWidth),
              let height = Self.strictInteger(jsonHeight) else {
            return nil
        }
        self.init(width: width, height: height)
    }

    func save(to defaults: UserDefaults) {
        defaults.set(width, forKey: Self.widthDefaultsKey)
        defaults.set(height, forKey: Self.heightDefaultsKey)
    }

    static func clear(from defaults: UserDefaults) {
        defaults.removeObject(forKey: Self.widthDefaultsKey)
        defaults.removeObject(forKey: Self.heightDefaultsKey)
    }

    /// Fills this exact size without distortion by centre-cropping first.
    /// Callers apply it only to the rendered SDR stream, never robot packets.
    func centerCropAndScale(_ image: CIImage) -> CIImage {
        let source = image.extent.integral
        guard source.width > 0, source.height > 0 else { return image }
        let targetAspect = CGFloat(width) / CGFloat(height)
        let sourceAspect = source.width / source.height
        let crop: CGRect
        if sourceAspect > targetAspect {
            let cropWidth = source.height * targetAspect
            crop = CGRect(x: source.midX - cropWidth / 2, y: source.minY,
                          width: cropWidth, height: source.height)
        } else {
            let cropHeight = source.width / targetAspect
            crop = CGRect(x: source.minX, y: source.midY - cropHeight / 2,
                          width: source.width, height: cropHeight)
        }
        let normalized = image.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let scale = CGFloat(width) / crop.width
        return normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    }

    /// JSON and persisted defaults can bridge through NSNumber. Validate the
    /// supported range before narrowing so malformed 64-bit values cannot trap.
    static func strictInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let decimal = number.doubleValue
        guard decimal.isFinite, decimal.rounded(.towardZero) == decimal,
              decimal >= Double(Self.minimumDimension),
              decimal <= Double(Self.maximumDimension) else { return nil }
        return Int(decimal)
    }
}

enum PhotoFormat: String, CaseIterable, Identifiable {
    case jpeg = "JPEG"
    case heif = "HEIF"
    case proRAW = "ProRAW"

    var id: String { rawValue }
}

private struct PhotoCaptureResult {
    let expectsRaw: Bool
    let expectsLivePhoto: Bool
    let lidarPhoto: Bool
    let videoStill: Bool
    let temporaryLiveMovieURL: URL?
    var raw: Data?
    var processed: Data?
    var capturedDepth = false
    var liveMovieURL: URL?
    var failure: String?
}

final class CameraService: NSObject, ObservableObject {
    private static let interruptionMessage = "Camera interrupted. Waiting to resume."
    let session = AVCaptureSession()
    let frames = FrameStore()
    let hdrStream = HDRStream()

    @Published private(set) var errorMessage: String?
    @Published private(set) var activeLens: CameraLens = .automatic
    @Published private(set) var activeQuality: VideoQuality = .hd
    @Published private(set) var actualCapturedSize: CGSize?
    @Published private(set) var customOutputSize: CustomOutputSize?
    @Published private(set) var activeFrameRate = 0
    @Published private(set) var availableFrameRates: [Int] = []
    @Published private(set) var availableLiveFrameRates = LiveFrameRatePolicy.choices
    @Published private(set) var activePhotoFormat: PhotoFormat = .jpeg
    @Published private(set) var photoFlashMode: AVCaptureDevice.FlashMode = .auto
    @Published private(set) var availablePhotoFormats: [PhotoFormat] = [.jpeg]
    @Published private(set) var livePhotoEnabled = false
    @Published private(set) var isCapturingLivePhoto = false
    @Published private(set) var hdrRecordingAvailable = false
    @Published private(set) var hdrRecordingEnabled = false
    @Published private(set) var hdrLiveAvailable = false
    @Published private(set) var hdrLiveEnabled = false
    @Published private(set) var streamFPS = 30
    /// The saved user choice. `streamFPS` is the rate actually used after the
    /// current camera or LiDAR format has applied its hardware limit.
    @Published private(set) var requestedStreamFPS = 30
    @Published private(set) var frameRateLimitMessage: String?
    /// The selected stream rate used by rendering and encoders.
    @Published private(set) var effectiveStreamFPS = 30
    @Published private(set) var effectiveCaptureFPS: Int?
    @Published private(set) var thermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var performanceMessage: String?
    @Published private(set) var streamImageQuality: StreamImageQuality = .normal
    @Published private(set) var minZoom: Float = 0.5
    @Published private(set) var maxZoom: Float = 15
    @Published private(set) var currentZoom: Float = 1
    @Published private(set) var zoomStops: [Float] = [0.5, 1, 2]
    @Published private(set) var availableLenses: [CameraLens] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isConfiguring = false
    @Published private(set) var isRecording = false
    @Published private(set) var isRecordingPaused = false
    @Published private(set) var captureMessage: String?
    @Published private(set) var lastPhotoPreview: UIImage?
    @Published private(set) var exposureBias: Float = 0
    /// Published from the active AVCaptureDevice so remote clients never assume
    /// a fixed EV range across iPhone and iPad camera configurations.
    @Published private(set) var minExposureTargetBias: Float = 0
    @Published private(set) var maxExposureTargetBias: Float = 0
    @Published private(set) var focusLocked = false
    @Published private(set) var manualFocusSupported = false
    @Published private(set) var manualFocusEnabled = false
    @Published private(set) var manualFocusPosition: Float = 0
    @Published private(set) var cinematicAvailable = false
    @Published private(set) var cinematicEnabled = false
    @Published private(set) var cinematicAperture: Float = 0
    @Published private(set) var cinematicMinAperture: Float = 0
    @Published private(set) var cinematicMaxAperture: Float = 0
    @Published private(set) var aeAfLocked = false
    @Published private(set) var whiteBalanceLocked = false
    @Published private(set) var torchEnabled = false
    @Published private(set) var effectBrightness: Float = 0
    @Published private(set) var effectContrast: Float = 1
    @Published private(set) var effectMirror = false
    @Published private(set) var effectFlip = false
    @Published private(set) var effectRotation = 0
    @Published private(set) var overlayText = ""

    var recordingDuration: TimeInterval {
        let duration = movieOutput.recordedDuration
        guard isRecording, duration.isNumeric else { return 0 }
        return max(0, duration.seconds)
    }

    var actualCaptureAspect: CGFloat? {
        guard let size = postEffectCaptureSize, size.width > 0, size.height > 0 else { return nil }
        return size.width / size.height
    }

    /// The dimensions delivered to preview and the SDR stream. A custom size is
    /// exact; video-quality presets keep the existing long-edge behavior.
    var currentOutputSize: CGSize? {
        if let customOutputSize {
            return CGSize(width: customOutputSize.width, height: customOutputSize.height)
        }
        guard let captured = postEffectCaptureSize,
              captured.width > 0, captured.height > 0 else { return nil }
        let scale = min(1, activeQuality.outputLongEdge / max(captured.width, captured.height))
        return CGSize(width: (captured.width * scale).rounded(), height: (captured.height * scale).rounded())
    }

    private var postEffectCaptureSize: CGSize? {
        guard let captured = actualCapturedSize else { return nil }
        switch effectRotation {
        case 90, 270:
            return CGSize(width: captured.height, height: captured.width)
        default:
            return captured
        }
    }

    private let sessionQueue = DispatchQueue(label: "rocam.camera.session")
    private let videoQueue = DispatchQueue(label: "rocam.camera.frames")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let photoResultsLock = NSLock()
    private var photoResults: [Int64: PhotoCaptureResult] = [:]
    private var livePhotoCaptureIDs: Set<Int64> = []
    private var depthOutput: AVCaptureDepthDataOutput?
    // Owned by sessionQueue; callbacks identify the current synchronizer through
    // the videoQueue-only identity below so stale queued callbacks are discarded.
    private var dataOutputSynchronizer: AVCaptureDataOutputSynchronizer?
    private var currentDevice: AVCaptureDevice?
    private var cinematicInput: AVCaptureDeviceInput?
    private var configuredLens: CameraLens = .automatic
    private var configuredQuality: VideoQuality = .hd
    private var configuredPhotoFormat: PhotoFormat = .jpeg
    private var configuredHDRLive = false
    private var configuredAvailablePhotoFormats: [PhotoFormat] = [.jpeg]
    private var configuredMinZoom: Float = 0.5
    private var configuredMaxZoom: Float = 15
    private var configuredDepthZoomRanges: [ClosedRange<CGFloat>] = []
    // Access only on sessionQueue. This samples a native zoom ramp's actual factor so
    // the UI never jumps to its target before the capture device gets there.
    private var zoomRampTimer: DispatchSourceTimer?
    private var zoomRampGeneration = 0
    // Access only on sessionQueue. The generation rejects completions from a prior lens or focus mode.
    private var manualFocusGeneration = 0
    private var manualFocusActive = false
    // Access only on sessionQueue. This rejects white-balance completions from a prior camera.
    private var whiteBalanceGeneration = 0
    private var configured = false
    // sessionQueue only. A failed stopped-LiDAR reconfiguration keeps this
    // intent so a later successful request can resume foreground capture.
    private var resumeAfterStoppedLiDARTransition = false
    // Cinematic is intentionally a session-only choice. Do not persist it or its temporary
    // zoom/FPS limits over the user's ordinary per-lens settings.
    private var wantsCinematic = false
    private var cinematicFocusFixed = false
    private var wantsCameraRunning = false // Main thread only.
    private var sessionObservers: [NSObjectProtocol] = []
    // Access only on sessionQueue. These restore the user's selected capture and
    // live rates without exposing session state directly to SwiftUI.
    private var requestedFrameRate = 0
    private var requestedLiveStreamFPS = 30
    private var frameRateStateGeneration = 0
    // Access only on the main thread. It discards delayed UI snapshots from an
    // earlier session configuration.
    private var publishedFrameRateStateGeneration = 0
    private var wantsLivePhoto = UserDefaults.standard.bool(forKey: "livePhoto")
    private var wantsHDRRecording = UserDefaults.standard.bool(forKey: "hdrRecording")
    private var wantsHDRLive = UserDefaults.standard.bool(forKey: "hdrLive")
    private var previousRecordingColorSpace: AVCaptureColorSpace?
    private var previousWideColorAutomatic = true
    // Access only on sessionQueue. AVCaptureMovieFileOutput can report a start asynchronously.
    private var recordingInFlight = false
    private var recordingStartPending = false
    private var stopRequestedWhileStarting = false
    private let effectsLock = NSLock()
    private var brightness: Float = 0
    private var contrast: Float = 1
    private var mirror = false
    private var flip = false
    private var rotation = 0
    private var overlayImage: CIImage?
    private var jpegCompression: CGFloat = StreamImageQuality.normal.jpegCompression
    private var streamImageQualitySnapshot: StreamImageQuality = .normal
    private var streamLongEdge: CGFloat = 0
    private var customOutputSizeSnapshot: CustomOutputSize?
    private var nextFrameTime: CFAbsoluteTime = 0
    private var nextJPEGFrameTime: CFAbsoluteTime = 0
    private var nextDepthFrameTime: CFAbsoluteTime = 0
    // Access only on videoQueue. `nil` means independent output delegates own
    // the normal camera graph; a value means only that synchronizer may render.
    private var activeSynchronizerIdentity: ObjectIdentifier?
    // Access only on videoQueue. The UI only needs a new aspect when delivered
    // buffers change dimensions, never for every captured frame.
    private var lastPublishedCaptureDimensions: CMVideoDimensions?
    // Accessed only on videoQueue. Sessions are created only after an authenticated
    // compressed endpoint has registered demand in FrameStore.
    private var encodedStreams: [RocamVideoCodec: EncodedStream] = [:]
    /// Rocam presents and delivers camera data in portrait regardless of the
    /// physical orientation of the phone. Desktop image effects remain an
    /// explicit computer-controlled transform later in the pipeline.
    private static let portraitRotationAngle: CGFloat = 90
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private weak var backgroundPreviewLayer: AVCaptureVideoPreviewLayer?

    private var hasPendingPhotoCapture: Bool {
        photoResultsLock.lock(); defer { photoResultsLock.unlock() }
        return !photoResults.isEmpty
    }

    var canPauseRecording: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    override init() {
        super.init()
        let defaults = UserDefaults.standard
        if let savedFlash = defaults.object(forKey: "photoFlashMode") as? Int,
           let mode = AVCaptureDevice.FlashMode(rawValue: savedFlash) {
            photoFlashMode = mode
        }
        exposureBias = defaults.float(forKey: "cameraExposure")
        effectBrightness = min(0.5, max(-0.5, defaults.float(forKey: "imageBrightness")))
        effectContrast = defaults.object(forKey: "imageContrast") == nil ? 1 : min(1.5, max(0.5, defaults.float(forKey: "imageContrast")))
        effectMirror = defaults.bool(forKey: "imageMirror")
        effectFlip = defaults.bool(forKey: "imageFlip")
        let savedRotation = defaults.integer(forKey: "imageRotation")
        effectRotation = [0, 90, 180, 270].contains(savedRotation) ? savedRotation : 0
        overlayText = String((defaults.string(forKey: "overlayText") ?? "").prefix(64))
        overlayImage = Self.makeOverlayImage(overlayText)
        brightness = effectBrightness
        contrast = effectContrast
        mirror = effectMirror
        flip = effectFlip
        rotation = effectRotation
        customOutputSize = CustomOutputSize(defaults: defaults)
        customOutputSizeSnapshot = customOutputSize
        let savedStreamFPS = UserDefaults.standard.integer(forKey: "streamFPS")
        streamFPS = LiveFrameRatePolicy.choices.contains(savedStreamFPS) ? savedStreamFPS : 30
        requestedStreamFPS = streamFPS
        requestedLiveStreamFPS = streamFPS
        frames.setStreamFPS(streamFPS)
        streamImageQuality = StreamImageQuality(rawValue: defaults.string(forKey: "streamImageQuality") ?? "") ?? .normal
        jpegCompression = streamImageQuality.jpegCompression
        streamImageQualitySnapshot = streamImageQuality
        hdrStream.onError = { [weak self] message in
            guard let self else { return }
            self.report(message)
            DispatchQueue.main.async { self.hdrLiveEnabled = false }
            self.sessionQueue.async {
                self.wantsHDRLive = false
                UserDefaults.standard.set(false, forKey: "hdrLive")
                if !self.recordingInFlight && !self.movieOutput.isRecording {
                    self.configure(lens: self.configuredLens, quality: self.configuredQuality)
                }
            }
        }
        availableLenses = CameraLens.allCases.filter { captureDevice(for: $0) != nil }
        let notifications = NotificationCenter.default
        sessionObservers = [
            notifications.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
                self?.handleSessionInterruption()
            },
            notifications.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
                self?.handleSessionInterruptionEnded()
            },
            notifications.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] notification in
                self?.handleSessionRuntimeError(notification)
            },
            notifications.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                      object: ProcessInfo.processInfo, queue: nil) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.thermalState = ProcessInfo.processInfo.thermalState
                }
            }
        ]
    }

    deinit {
        zoomRampTimer?.cancel()
        for observer in sessionObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func requestAccessAndStart() {
        assert(Thread.isMainThread)
        wantsCameraRunning = true
        let savedLens = CameraLens(rawValue: UserDefaults.standard.string(forKey: "cameraLens") ?? "") ?? .automatic
        let startingLens = availableLenses.contains(savedLens) ? savedLens : .automatic
        let startingQuality = VideoQuality(rawValue: UserDefaults.standard.string(forKey: "videoQuality") ?? "") ?? .hd
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.wantsCameraRunning else { return }
                guard allowed else {
                    self.errorMessage = "Allow camera access in Settings to start streaming."
                    return
                }
                self.sessionQueue.async {
                    if !self.configured { self.configure(lens: startingLens, quality: startingQuality) }
                    guard self.configured else { return }
                    // configure() restores format-dependent settings before returning on this queue.
                    // Start only after those settings, including photo depth delivery, are applied.
                    self.sessionQueue.async {
                        guard DispatchQueue.main.sync(execute: { self.wantsCameraRunning }) else { return }
                        if let depthOutput = self.depthOutput, self.dataOutputSynchronizer == nil {
                            self.installDataOutputSynchronizer(depthOutput)
                        }
                        if !self.session.isRunning && !self.session.isInterrupted { self.session.startRunning() }
                        let running = self.session.isRunning && !self.session.isInterrupted
                        self.updateStreamStatus()
                        DispatchQueue.main.async {
                            guard self.wantsCameraRunning else { return }
                            self.isRunning = running
                            if running && self.errorMessage == Self.interruptionMessage {
                                self.errorMessage = nil
                            }
                        }
                    }
                }
            }
        }
    }

    func stop() {
        assert(Thread.isMainThread)
        wantsCameraRunning = false
        isRunning = false
        sessionQueue.async {
            self.cancelZoomRamp(on: self.currentDevice)
            // AVCaptureDataOutputSynchronizer synchronizes its capture callbacks
            // while changing delegates. Stop those callbacks before detaching the
            // synchronizer so AVFoundation never waits on an active graph handoff.
            if self.session.isRunning { self.session.stopRunning() }
            let retiredSynchronizer = self.removeDataOutputSynchronizer()
            self.resumeAfterStoppedLiDARTransition = false
            // Keep the retired synchronizer alive until the capture graph has
            // stopped consuming its outputs. The new graph may not be built
            // until this reference has been released.
            withExtendedLifetime(retiredSynchronizer) {}
            self.updateStreamStatus()
            self.frames.clearCameraFrames()
            self.videoQueue.async { self.invalidateEncodedStreams() }
        }
    }

    private func handleSessionInterruption() {
        DispatchQueue.main.async {
            guard self.wantsCameraRunning else { return }
            self.frames.clearCameraFrames()
            self.videoQueue.async { self.invalidateEncodedStreams() }
            self.sessionQueue.async {
                self.cancelZoomRamp(on: self.currentDevice)
                let retiredSynchronizer = self.removeDataOutputSynchronizer()
                // This serial queue completes the lifetime fence before an
                // interruption-ended handler can reinstall a synchronizer.
                withExtendedLifetime(retiredSynchronizer) {}
            }
            self.isRunning = false
            self.errorMessage = Self.interruptionMessage
        }
    }

    private func handleSessionInterruptionEnded(clearError: String = CameraService.interruptionMessage) {
        DispatchQueue.main.async {
            guard self.wantsCameraRunning else { return }
            self.sessionQueue.async {
                if let depthOutput = self.depthOutput, self.dataOutputSynchronizer == nil {
                    self.installDataOutputSynchronizer(depthOutput)
                }
                if !self.session.isRunning && !self.session.isInterrupted { self.session.startRunning() }
                let running = self.session.isRunning && !self.session.isInterrupted
                DispatchQueue.main.async {
                    guard self.wantsCameraRunning else { return }
                    self.isRunning = running
                    if running && self.errorMessage == clearError {
                        self.errorMessage = nil
                    }
                }
            }
        }
    }

    private func handleSessionRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
        DispatchQueue.main.async {
            guard self.wantsCameraRunning else { return }
            self.frames.clearCameraFrames()
            self.videoQueue.async { self.invalidateEncodedStreams() }
            self.sessionQueue.async {
                self.cancelZoomRamp(on: self.currentDevice)
                let retiredSynchronizer = self.removeDataOutputSynchronizer()
                // Recovery is queued after this session-queue block, so a
                // replacement synchronizer cannot overlap this retired one.
                withExtendedLifetime(retiredSynchronizer) {}
            }
            self.isRunning = false
            let message = error?.localizedDescription ?? "Camera capture stopped unexpectedly."
            self.errorMessage = message
            if error?.domain == AVFoundationErrorDomain,
               error?.code == AVError.Code.mediaServicesWereReset.rawValue {
                self.handleSessionInterruptionEnded(clearError: message)
            }
        }
    }

    func resetHDRPresentation() {
        videoQueue.async { self.hdrStream.resetPresentation() }
    }

    func select(lens: CameraLens, quality: VideoQuality) {
        sessionQueue.async {
            guard self.configured,
                  self.session.isRunning,
                  self.configuredLens == lens,
                  self.configuredQuality == quality,
                  !self.recordingInFlight,
                  !self.movieOutput.isRecording,
                  !self.hasPendingPhotoCapture else {
                self.configure(lens: lens, quality: quality)
                return
            }
        }
    }

    @available(iOS 26.0, *)
    private func cinematicFormats(for device: AVCaptureDevice, requireHDR: Bool = false) -> [AVCaptureDevice.Format] {
        device.formats.filter {
            $0.isCinematicVideoCaptureSupported &&
                (!requireHDR || $0.supportedColorSpaces.contains(.HLG_BT2020))
        }
    }

    /// Resolves the automatic rear camera to the richest virtual camera each
    /// device exposes. iPhones retain the triple-camera path; LiDAR iPad Pros
    /// use their dual-wide camera when available and otherwise their wide camera.
    private func captureDevice(for lens: CameraLens) -> AVCaptureDevice? {
        let position: AVCaptureDevice.Position = lens.isBack ? .back : .front
        if lens == .automatic {
            let automaticBackCameraTypes: [AVCaptureDevice.DeviceType] = [
                .builtInTripleCamera,
                .builtInDualWideCamera,
                .builtInWideAngleCamera
            ]
            return automaticBackCameraTypes.lazy.compactMap {
                AVCaptureDevice.default($0, for: .video, position: .back)
            }.first
        }
        return AVCaptureDevice.default(lens.deviceType, for: .video, position: position)
    }

    private func cinematicDevice(for lens: CameraLens) -> AVCaptureDevice? {
        guard lens != .lidar else { return nil }
        guard #available(iOS 26.0, *) else { return nil }
        guard let primary = captureDevice(for: lens) else { return nil }
        guard lens == .automatic, cinematicFormats(for: primary).isEmpty else { return primary }
        // Apple's sample uses a virtual camera. On devices whose triple camera lacks an
        // eligible format, the dual-wide virtual camera may still provide Cinematic capture.
        if let dualWide = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back),
           !cinematicFormats(for: dualWide).isEmpty {
            return dualWide
        }
        return primary
    }

    @available(iOS 26.0, *)
    private func cinematicFormat(for device: AVCaptureDevice, target: CMVideoDimensions,
                                 rate: Int, requireHDR: Bool) -> AVCaptureDevice.Format? {
        let eligible = cinematicFormats(for: device, requireHDR: requireHDR).filter { format in
            guard let cinematicRange = format.videoFrameRateRangeForCinematicVideo else { return false }
            return rate == 0 || (cinematicRange.minFrameRate <= Double(rate) && Double(rate) <= cinematicRange.maxFrameRate)
        }
        let sdrEligible = requireHDR ? [] : eligible.filter(isSDRVideoFormat)
        let candidates = sdrEligible.isEmpty ? eligible : sdrEligible
        return candidates.min { lhs, rhs in
            let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let lhsDistance = abs(Int(l.width) - Int(target.width)) + abs(Int(l.height) - Int(target.height))
            let rhsDistance = abs(Int(r.width) - Int(target.width)) + abs(Int(r.height) - Int(target.height))
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            if !requireHDR && isTenBitVideoFormat(lhs) != isTenBitVideoFormat(rhs) {
                return !isTenBitVideoFormat(lhs)
            }
            return Int(l.width) * Int(l.height) > Int(r.width) * Int(r.height)
        }
    }

    private func isCinematicCaptureActive() -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        return cinematicInput?.isCinematicVideoCaptureEnabled == true
    }

    /// sessionQueue only. The returned value deliberately keeps the old graph
    /// participant alive through its enclosing teardown transaction. Callers
    /// stop an active synchronized graph before detaching its delegate; the
    /// synchronous videoQueue fence then rejects callbacks already queued
    /// before releasing the property.
    @discardableResult
    private func removeDataOutputSynchronizer() -> AVCaptureDataOutputSynchronizer? {
        let retiredSynchronizer = dataOutputSynchronizer
        retiredSynchronizer?.setDelegate(nil, queue: nil)
        videoQueue.sync {
            activeSynchronizerIdentity = nil
            frames.clearRobotPacket()
        }
        dataOutputSynchronizer = nil
        return retiredSynchronizer
    }

    /// sessionQueue only, after the LiDAR video/depth outputs are committed.
    private func installDataOutputSynchronizer(_ depthOutput: AVCaptureDepthDataOutput) {
        // Keep LiDAR depth primary so paired RGB uses the same capture timestamp.
        let synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [depthOutput, videoOutput])
        videoQueue.sync {
            activeSynchronizerIdentity = ObjectIdentifier(synchronizer)
            frames.clearRobotPacket()
        }
        synchronizer.setDelegate(self, queue: videoQueue)
        dataOutputSynchronizer = synchronizer
    }

    private func configure(lens: CameraLens, quality: VideoQuality) {
        setConfigurationPresentation(true)
        defer { setConfigurationPresentation(false) }
        cancelZoomRamp(on: currentDevice)
        guard !recordingInFlight && !movieOutput.isRecording else { report("Stop recording before changing cameras."); return }
        guard !hasPendingPhotoCapture else { report("Wait for the photo capture to finish."); return }
        if lens == .lidar && wantsCinematic {
            wantsCinematic = false
            cinematicFocusFixed = false
            report("Cinematic capture is unavailable with LiDAR depth.")
        }
        guard let device = (wantsCinematic ? cinematicDevice(for: lens) : nil) ?? captureDevice(for: lens) else {
            report("This camera is unavailable on this device."); return
        }
        if lens == .lidar && !device.formats.contains(where: { !$0.supportedDepthDataFormats.isEmpty }) {
            report("This device has no usable LiDAR depth format.")
            return
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            report(error.localizedDescription)
            return
        }

        // A source LiDAR graph must be stopped before its synchronizer delegate
        // is changed. A destination LiDAR graph must also be stopped so its
        // format-dependent camera-intrinsics delivery is set before capture starts.
        // Keep one resume intent through a failed transition so a later successful
        // request can restore foreground capture.
        let stoppedForLiDARTransition = session.isRunning &&
            (dataOutputSynchronizer != nil || lens == .lidar)
        let previousConfiguration = (lens: configuredLens, quality: configuredQuality)
        if stoppedForLiDARTransition {
            session.stopRunning()
            frames.clearCameraFrames()
            videoQueue.sync { self.invalidateEncodedStreams() }
            resumeAfterStoppedLiDARTransition = true
            updateStreamStatus()
            DispatchQueue.main.async { self.isRunning = false }
        }

        let configuredRequestedGraph = configureGraph(lens: lens, quality: quality,
                                                       device: device, input: input)
        var restoredPreviousGraph = false
        if !configuredRequestedGraph && stoppedForLiDARTransition {
            // configureGraph's scoped transaction has committed and released the
            // retired synchronizer before this one bounded recovery attempt.
            guard let recoveryDevice = captureDevice(for: previousConfiguration.lens),
                  !(previousConfiguration.lens == .lidar &&
                    !recoveryDevice.formats.contains(where: { !$0.supportedDepthDataFormats.isEmpty })),
                  let recoveryInput = try? AVCaptureDeviceInput(device: recoveryDevice) else {
                configured = false
                report("Could not restore the previous camera configuration.")
                return
            }
            restoredPreviousGraph = configureGraph(lens: previousConfiguration.lens,
                                                   quality: previousConfiguration.quality,
                                                   device: recoveryDevice, input: recoveryInput)
            if restoredPreviousGraph {
                report("Could not change the camera setting; restored the previous configuration.")
            } else {
                configured = false
                report("Could not change the camera setting or restore the previous configuration.")
                return
            }
        }

        guard configuredRequestedGraph || restoredPreviousGraph else { return }
        guard resumeAfterStoppedLiDARTransition else { return }
        // A successful stopped-graph transition queued its HDR presentation
        // restore on videoQueue. Drain that restore before capture resumes.
        videoQueue.sync {}
        let shouldResume = DispatchQueue.main.sync { wantsCameraRunning }
        guard shouldResume, !session.isInterrupted else { return }
        session.startRunning()
        let running = session.isRunning && !session.isInterrupted
        if running { resumeAfterStoppedLiDARTransition = false }
        updateStreamStatus()
        DispatchQueue.main.async {
            guard self.wantsCameraRunning else { return }
            self.isRunning = running
        }
    }

    /// sessionQueue only. This owns the graph transaction after the caller has
    /// validated the target input and, when needed, stopped the old LiDAR graph.
    @discardableResult
    private func configureGraph(lens: CameraLens, quality: VideoQuality,
                                device: AVCaptureDevice, input: AVCaptureDeviceInput) -> Bool {
        do {
            var warning: String?
            invalidateManualFocus()
            whiteBalanceGeneration &+= 1
            videoQueue.sync {
                hdrStream.setEnabled(false)
                invalidateEncodedStreams()
            }
            // A graph transition must make an old synchronized pair unavailable
            // before outputs are removed or their rotation changes.
            // Retain the old synchronizer through old-depth removal and the
            // outer commit. AVFoundation may still hold the removed outputs
            // until that commit completes, even after its delegate is fenced.
            var retiredSynchronizer = removeDataOutputSynchronizer()
            session.beginConfiguration()
            var configurationOpen = true
            defer {
                if configurationOpen { session.commitConfiguration() }
                withExtendedLifetime(retiredSynchronizer) {}
                retiredSynchronizer = nil
            }
            for old in session.inputs { session.removeInput(old) }
            cinematicInput = nil
            if let oldDepth = depthOutput { session.removeOutput(oldDepth); depthOutput = nil }
            if session.outputs.contains(movieOutput) { session.removeOutput(movieOutput) }
            guard session.canAddInput(input) else { report("Cannot open the selected camera."); return false }
            session.addInput(input)
            if wantsLivePhoto && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                addMicrophoneInputIfPossible()
            }
            var actualQuality: VideoQuality = session.canSetSessionPreset(quality.preset) ? quality : .fullHD
            if lens == .lidar {
                let targetWidth: Int32
                switch quality {
                case .sd: targetWidth = 640
                case .hd: targetWidth = 1280
                case .fullHD: targetWidth = 1920
                case .qhd: targetWidth = 2560
                case .ultraHD: targetWidth = 3840
                }
                let depthFormats = device.formats.filter { !$0.supportedDepthDataFormats.isEmpty }
                let eligible = depthFormats.filter { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <= targetWidth }
                guard let format = (eligible.isEmpty ? depthFormats : eligible).max(by: {
                    CMVideoFormatDescriptionGetDimensions($0.formatDescription).width < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
                }) else { report("No LiDAR video and depth format is available."); return false }
                session.sessionPreset = .inputPriority
                try device.lockForConfiguration()
                device.activeFormat = format
                if let depthFormat = format.supportedDepthDataFormats
                    .filter({ CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32 ||
                              CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat16 })
                    .max(by: { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width }) {
                    device.activeDepthDataFormat = depthFormat
                }
                device.unlockForConfiguration()
                let width = CMVideoFormatDescriptionGetDimensions(format.formatDescription).width
                switch quality {
                case .sd: actualQuality = .sd
                case .hd: actualQuality = .hd
                case .fullHD: actualQuality = width >= 1920 ? .fullHD : .hd
                case .qhd: actualQuality = width >= 2560 ? .qhd : width >= 1920 ? .fullHD : .hd
                case .ultraHD: actualQuality = width >= 3840 ? .ultraHD : width >= 2560 ? .qhd : width >= 1920 ? .fullHD : .hd
                }
            } else if session.canSetSessionPreset(actualQuality.preset) {
                session.sessionPreset = actualQuality.preset
            }
            let savedRate = UserDefaults.standard.integer(forKey: "recordingFrameRate")
            let dimensions = lens == .lidar
                ? CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                : actualQuality.captureDimensions
            let hdrFormat: AVCaptureDevice.Format?
            if lens == .lidar {
                hdrFormat = nil
            } else {
                hdrFormat = matchingHDRFormat(for: device, dimensions: dimensions, rate: savedRate) ??
                    matchingHDRFormat(for: device, dimensions: dimensions, rate: 0)
            }
            let sdrFormat: AVCaptureDevice.Format?
            if lens == .lidar {
                sdrFormat = nil
            } else {
                sdrFormat = matchingSDRFormat(for: device, dimensions: dimensions, rate: savedRate) ??
                    matchingSDRFormat(for: device, dimensions: dimensions, rate: 0)
            }
            let cinematicHDRFormat: AVCaptureDevice.Format?
            if wantsCinematic, #available(iOS 26.0, *) {
                cinematicHDRFormat = self.cinematicFormat(for: device, target: dimensions, rate: savedRate,
                                                           requireHDR: true)
                    ?? self.cinematicFormat(for: device, target: dimensions, rate: 0, requireHDR: true)
            } else {
                cinematicHDRFormat = nil
            }
            let cinematicFormat: AVCaptureDevice.Format?
            if wantsCinematic, #available(iOS 26.0, *) {
                cinematicFormat = self.cinematicFormat(for: device, target: dimensions, rate: savedRate,
                                                        requireHDR: wantsHDRLive || wantsHDRRecording)
                    ?? self.cinematicFormat(for: device, target: dimensions, rate: 0,
                                             requireHDR: wantsHDRLive || wantsHDRRecording)
                    ?? self.cinematicFormat(for: device, target: dimensions, rate: savedRate, requireHDR: false)
                    ?? self.cinematicFormat(for: device, target: dimensions, rate: 0, requireHDR: false)
            } else {
                cinematicFormat = nil
            }
            if wantsCinematic && cinematicFormat == nil {
                wantsCinematic = false
                cinematicFocusFixed = false
                warning = "Cinematic capture is unavailable with this camera setting."
            }
            if let cinematicFormat {
                try device.lockForConfiguration()
                device.activeFormat = cinematicFormat
                device.unlockForConfiguration()
                let selectedDimensions = CMVideoFormatDescriptionGetDimensions(cinematicFormat.formatDescription)
                if selectedDimensions.width != dimensions.width || selectedDimensions.height != dimensions.height {
                    warning = "Cinematic capture uses \(selectedDimensions.width)×\(selectedDimensions.height) with this camera."
                }
            } else if (wantsHDRLive || wantsHDRRecording), let hdrFormat {
                try device.lockForConfiguration()
                device.activeFormat = hdrFormat
                device.unlockForConfiguration()
            } else if let sdrFormat {
                try device.lockForConfiguration()
                device.activeFormat = sdrFormat
                device.unlockForConfiguration()
            }
            if !session.outputs.contains(videoOutput) {
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
                guard session.canAddOutput(videoOutput) else { report("Cannot configure video output."); return false }
                session.addOutput(videoOutput)
            }
            if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            }
            let supportedPixels = videoOutput.availableVideoPixelFormatTypes
            let cinematicWillEnable = wantsCinematic && cinematicFormat != nil
            let hdrFormatAvailable = cinematicWillEnable
                ? device.activeFormat.supportedColorSpaces.contains(.HLG_BT2020)
                : hdrFormat != nil || (lens == .lidar && device.activeFormat.supportedColorSpaces.contains(.HLG_BT2020))
            let hdrLiveFormatAvailable = cinematicWillEnable ? cinematicHDRFormat != nil : hdrFormatAvailable
            if wantsHDRRecording && !hdrFormatAvailable {
                if cinematicWillEnable {
                    warning = "HLG HDR recording is unavailable with this Cinematic camera format."
                } else {
                    wantsHDRRecording = false
                    UserDefaults.standard.set(false, forKey: "hdrRecording")
                    warning = "HLG HDR recording is unavailable at this resolution."
                }
            }
            let tenBitAvailable = supportedPixels.contains(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            let hdrAvailable = hdrLiveFormatAvailable && (!wantsHDRLive || tenBitAvailable)
            var useHDR = wantsHDRLive && hdrFormatAvailable && tenBitAvailable
            if useHDR {
                session.automaticallyConfiguresCaptureDeviceForWideColor = false
                do {
                    try device.lockForConfiguration()
                    device.activeColorSpace = .HLG_BT2020
                    device.unlockForConfiguration()
                } catch {
                    useHDR = false
                    warning = "Could not enable live HDR: \(error.localizedDescription)"
                }
            }
            if !useHDR {
                session.automaticallyConfiguresCaptureDeviceForWideColor = true
                if device.activeColorSpace != .sRGB && device.activeFormat.supportedColorSpaces.contains(.sRGB) {
                    try device.lockForConfiguration()
                    device.activeColorSpace = .sRGB
                    device.unlockForConfiguration()
                }
                if wantsHDRLive && !useHDR { warning = "10-bit HDR is unavailable with this camera format." }
            }
            configureVideoOutputPixelFormat(preferHDR: useHDR)
            if lens == .lidar {
                let output = AVCaptureDepthDataOutput()
                output.isFilteringEnabled = true
                if session.canAddOutput(output) {
                    session.addOutput(output)
                    output.setDelegate(self, callbackQueue: videoQueue)
                    depthOutput = output
                } else {
                    warning = "LiDAR depth is unavailable at this video setting."
                }
            } else {
                frames.clearDepth()
            }
            if wantsCinematic, #available(iOS 26.0, *) {
                if !input.isCinematicVideoCaptureSupported {
                    wantsCinematic = false
                    cinematicFocusFixed = false
                    warning = "Cinematic capture is unavailable with this camera setting."
                } else {
                    input.isCinematicVideoCaptureEnabled = true
                    cinematicInput = input
                }
            }
            applyPortraitCaptureRotation()
            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoMirroringSupported { connection.isVideoMirrored = lens == .front }
                connection.preferredVideoStabilizationMode = lens == .lidar ? .off : .auto
                // Apple requires this to be set before the session starts. LiDAR
                // transitions are stopped above; ordinary RGB lens transitions stay
                // live and deliberately leave this format-dependent setting alone.
                if !session.isRunning,
                   connection.isCameraIntrinsicMatrixDeliverySupported {
                    connection.isCameraIntrinsicMatrixDeliveryEnabled = true
                }
            }
            currentDevice = device
            configuredLens = lens
            configuredQuality = actualQuality
            configuredHDRLive = useHDR
            configured = true
            effectsLock.lock()
            streamLongEdge = actualQuality.outputLongEdge
            effectsLock.unlock()
            let finalWarning = warning
            DispatchQueue.main.async {
                self.activeLens = lens
                self.activeQuality = actualQuality
                self.aeAfLocked = false
                self.hdrRecordingAvailable = hdrFormatAvailable
                self.hdrRecordingEnabled = (self.wantsHDRRecording && hdrFormatAvailable) || useHDR
                self.hdrLiveAvailable = hdrAvailable
                self.hdrLiveEnabled = useHDR
                self.errorMessage = finalWarning
            }
            UserDefaults.standard.set(lens.rawValue, forKey: "cameraLens")
            UserDefaults.standard.set(actualQuality.rawValue, forKey: "videoQuality")
            let savedExposure = UserDefaults.standard.float(forKey: "cameraExposure")
            let restoredExposure = max(device.minExposureTargetBias, min(savedExposure, device.maxExposureTargetBias))
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(restoredExposure) { _ in }
                device.unlockForConfiguration()
                publishCameraControls(for: device, exposure: restoredExposure)
            } catch {
                publishCameraControls(for: device)
                report(error.localizedDescription)
            }
            // Format-dependent controls must observe the committed graph before later
            // sessionQueue controls (for example, a combined lens/quality/zoom request).
            // Committing here also lets their own scoped session transactions complete.
            session.commitConfiguration()
            configurationOpen = false

            // Drop the retired graph reference before installing the new
            // synchronizer, after the transaction has released the old outputs.
            withExtendedLifetime(retiredSynchronizer) {}
            retiredSynchronizer = nil

            if let depthOutput {
                installDataOutputSynchronizer(depthOutput)
            }

            let hdrEnabled = useHDR
            restoreManualFocus(for: device, lens: lens)
            restoreWhiteBalance(for: device, lens: lens)
            restoreFrameRate()
            updateStreamStatus()
            refreshFormatDependentControls(for: device, lens: lens)
            refreshCinematicControls(for: device, input: input, lens: lens)
            restorePhotoFormat()
            videoQueue.async { self.hdrStream.setEnabled(hdrEnabled) }
            DispatchQueue.main.async { self.applyPortraitPreviewRotation() }
            return true
        } catch {
            report(error.localizedDescription)
            return false
        }
    }

    private func refreshCinematicControls(for device: AVCaptureDevice, input: AVCaptureDeviceInput,
                                          lens: CameraLens) {
        guard #available(iOS 26.0, *) else {
            DispatchQueue.main.async {
                self.cinematicAvailable = false
                self.cinematicEnabled = false
                self.cinematicAperture = 0
                self.cinematicMinAperture = 0
                self.cinematicMaxAperture = 0
            }
            return
        }
        let available = lens != .lidar && (!cinematicFormats(for: device).isEmpty ||
            (lens == .automatic && cinematicDevice(for: lens).map { !cinematicFormats(for: $0).isEmpty } == true))
        let enabled = input.isCinematicVideoCaptureEnabled
        let minimum = enabled ? device.activeFormat.minSimulatedAperture : 0
        let maximum = enabled ? device.activeFormat.maxSimulatedAperture : 0
        let aperture = enabled ? input.simulatedAperture : 0
        DispatchQueue.main.async {
            self.cinematicAvailable = available
            self.cinematicEnabled = enabled
            self.cinematicAperture = aperture
            self.cinematicMinAperture = minimum
            self.cinematicMaxAperture = maximum
        }
    }

    private func refreshFormatDependentControls(for device: AVCaptureDevice, lens: CameraLens) {
        session.beginConfiguration()
        if session.outputs.contains(photoOutput) {
            photoOutput.maxPhotoQualityPrioritization = .quality
            if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
                Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
            }) {
                photoOutput.maxPhotoDimensions = largest
            }
            photoOutput.isAppleProRAWEnabled = photoOutput.isAppleProRAWSupported
            photoOutput.isLivePhotoCaptureEnabled = wantsLivePhoto &&
                AVCaptureDevice.authorizationStatus(for: .audio) == .authorized &&
                hasMicrophoneInput() && photoOutput.isLivePhotoCaptureSupported
        }
        if !photoOutput.isLivePhotoCaptureEnabled { removeMicrophoneInput() }
        session.commitConfiguration()

        let multiplier = zoomMultiplier(for: device, lens: lens)
        var depthZoomRanges = lens == .lidar && depthOutput != nil ? supportedDepthZoomRanges(for: device) : []
        if lens == .lidar && depthOutput != nil && depthZoomRanges.isEmpty {
            let safeRaw = min(max(1, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            depthZoomRanges = [safeRaw...safeRaw]
            report("LiDAR zoom is limited because this format reports no depth-safe range.")
        }
        configuredDepthZoomRanges = depthZoomRanges
        let cinematicZoomRange: ClosedRange<CGFloat>?
        if isCinematicCaptureActive(), #available(iOS 26.0, *) {
            let minimum = device.activeFormat.videoMinZoomFactorForCinematicVideo
            let maximum = device.activeFormat.videoMaxZoomFactorForCinematicVideo
            cinematicZoomRange = minimum.isFinite && maximum.isFinite && minimum <= maximum ? minimum...maximum : nil
        } else {
            cinematicZoomRange = nil
        }
        let minRaw = max(depthZoomRanges.first?.lowerBound ?? device.minAvailableVideoZoomFactor,
                         cinematicZoomRange?.lowerBound ?? device.minAvailableVideoZoomFactor)
        let minZoom = Float(minRaw * multiplier)
        var maxRaw = depthZoomRanges.map(\.upperBound).max() ?? device.maxAvailableVideoZoomFactor
        if let cinematicZoomRange { maxRaw = min(maxRaw, cinematicZoomRange.upperBound) }
        if lens == .automatic {
            if #available(iOS 18.0, *), let recommended = device.activeFormat.systemRecommendedVideoZoomRange {
                maxRaw = min(maxRaw, recommended.upperBound)
            }
        }
        maxRaw = max(minRaw, maxRaw)
        let maxZoom = Float(maxRaw * multiplier)
        let savedZoom = UserDefaults.standard.float(forKey: zoomStorageKey(for: lens))
        let requestedZoom: Float = savedZoom > 0 ? max(minZoom, min(savedZoom, maxZoom)) : (lens == .automatic ? 1 : minZoom)
        let rawZoom = nearestZoom(CGFloat(requestedZoom) / multiplier, in: depthZoomRanges)
        var actualZoom = Float(device.videoZoomFactor * multiplier)
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = max(device.minAvailableVideoZoomFactor, min(rawZoom, device.maxAvailableVideoZoomFactor))
            actualZoom = Float(device.videoZoomFactor * multiplier)
            device.unlockForConfiguration()
        } catch { report(error.localizedDescription) }
        configuredMinZoom = minZoom
        configuredMaxZoom = maxZoom
        let depthStops = depthZoomRanges.flatMap { [Float($0.lowerBound * multiplier), Float($0.upperBound * multiplier)] }
        let nativeStops = device.activeFormat.secondaryNativeResolutionZoomFactors.map { Float($0 * multiplier) }
        let stops = ([minZoom, 1] + device.virtualDeviceSwitchOverVideoZoomFactors.map { Float($0.doubleValue * Double(multiplier)) } + nativeStops + depthStops)
            .filter { $0 >= minZoom - 0.01 && $0 <= maxZoom + 0.01 }
            .filter { stop in
                let raw = CGFloat(stop) / multiplier
                return depthZoomRanges.isEmpty || depthZoomRanges.contains {
                    raw >= $0.lowerBound - 0.001 && raw <= $0.upperBound + 0.001
                }
            }
            .sorted()
            .reduce(into: [Float]()) { result, value in
                if result.last.map({ abs($0 - value) > 0.1 }) ?? true { result.append(value) }
            }
        let livePhotoEnabled = photoOutput.isLivePhotoCaptureEnabled
        DispatchQueue.main.async {
            self.livePhotoEnabled = livePhotoEnabled
            self.minZoom = minZoom
            self.maxZoom = maxZoom
            self.currentZoom = actualZoom
            self.zoomStops = stops
        }
    }

    private func supportsFrameRate(_ rate: Int, format: AVCaptureDevice.Format) -> Bool {
        let value = Double(rate)
        guard format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= value && value <= $0.maxFrameRate }) else { return false }
        if (wantsCinematic || isCinematicCaptureActive()),
           #available(iOS 26.0, *), format.isCinematicVideoCaptureSupported {
            guard let range = format.videoFrameRateRangeForCinematicVideo else { return false }
            return range.minFrameRate <= value && value <= range.maxFrameRate
        }
        return true
    }

    private func matchingFrameRateFormat(_ rate: Int, for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let matching = device.formats
            .filter {
                CMVideoFormatDescriptionGetDimensions($0.formatDescription).width == dimensions.width &&
                CMVideoFormatDescriptionGetDimensions($0.formatDescription).height == dimensions.height &&
                supportsFrameRate(rate, format: $0)
            }
            .filter { format in
                guard self.wantsCinematic || self.isCinematicCaptureActive() else { return true }
                if #available(iOS 26.0, *) { return format.isCinematicVideoCaptureSupported }
                return false
        }
        let hdrCapable = matching.filter { $0.supportedColorSpaces.contains(.HLG_BT2020) }
        let sdrCapable = matching.filter(isSDRVideoFormat)
        let candidates = requiresHDROnCurrentGraph(device) ? hdrCapable : sdrCapable
        return candidates.min {
            if !requiresHDROnCurrentGraph(device) &&
                isTenBitVideoFormat($0) != isTenBitVideoFormat($1) {
                return !isTenBitVideoFormat($0)
            }
            return abs($0.videoFieldOfView - device.activeFormat.videoFieldOfView) <
            abs($1.videoFieldOfView - device.activeFormat.videoFieldOfView)
        }
    }

    private func isTenBitVideoFormat(_ format: AVCaptureDevice.Format) -> Bool {
        let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        return subtype == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
            subtype == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    }

    private func isSDRVideoFormat(_ format: AVCaptureDevice.Format) -> Bool {
        format.supportedColorSpaces.contains(.sRGB)
    }

    private func matchingSDRFormat(for device: AVCaptureDevice, dimensions: CMVideoDimensions,
                                   rate: Int) -> AVCaptureDevice.Format? {
        device.formats.filter { format in
            let candidate = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return candidate.width == dimensions.width && candidate.height == dimensions.height &&
                isSDRVideoFormat(format) && (rate == 0 || supportsFrameRate(rate, format: format))
        }.min {
            if isTenBitVideoFormat($0) != isTenBitVideoFormat($1) {
                return !isTenBitVideoFormat($0)
            }
            return abs($0.videoFieldOfView - device.activeFormat.videoFieldOfView) <
                abs($1.videoFieldOfView - device.activeFormat.videoFieldOfView)
        }
    }

    private func configureVideoOutputPixelFormat(preferHDR: Bool) {
        let supported = videoOutput.availableVideoPixelFormatTypes
        let preferred: [OSType] = preferHDR
            ? [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]
            : [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
               kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
               kCVPixelFormatType_32BGRA]
        guard let pixelFormat = preferred.first(where: { candidate in
            supported.contains(candidate)
        }) else {
            // nil requests AVCaptureVideoDataOutput's default uncompressed format.
            // Never request a pixel type absent from this graph.
            videoOutput.videoSettings = nil
            return
        }
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
    }

    private func matchingHDRFormat(for device: AVCaptureDevice, dimensions: CMVideoDimensions, rate: Int) -> AVCaptureDevice.Format? {
        return device.formats.filter { format in
            let candidate = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return candidate.width == dimensions.width && candidate.height == dimensions.height &&
                format.supportedColorSpaces.contains(.HLG_BT2020) &&
                (rate == 0 || supportsFrameRate(rate, format: format))
        }.min {
            abs($0.videoFieldOfView - device.activeFormat.videoFieldOfView) <
                abs($1.videoFieldOfView - device.activeFormat.videoFieldOfView)
        }
    }

    // Keep the user's ordinary HDR preference while Cinematic temporarily uses a non-HLG
    // eligible format. Recording and FPS selection must follow the effective graph, not that
    // preserved preference.
    private func requiresHDROnCurrentGraph(_ device: AVCaptureDevice) -> Bool {
        if isCinematicCaptureActive() {
            return configuredHDRLive || (wantsHDRRecording && device.activeFormat.supportedColorSpaces.contains(.HLG_BT2020))
        }
        return configuredHDRLive || wantsHDRRecording
    }

    private func supportedFrameRates(for device: AVCaptureDevice) -> [Int] {
        let depthRanges = configuredLens == .lidar ? device.activeDepthDataFormat?.videoSupportedFrameRateRanges : nil
        let needsHDR = requiresHDROnCurrentGraph(device)
        return [24, 30, 60, 120].filter { rate in
            let value = Double(rate)
            let currentSupportsHDR = !needsHDR || device.activeFormat.supportedColorSpaces.contains(.HLG_BT2020)
            let videoSupported = (currentSupportsHDR && supportsFrameRate(rate, format: device.activeFormat)) ||
                (configuredLens != .lidar && matchingFrameRateFormat(rate, for: device) != nil)
            let depthSupported = depthRanges?.contains { $0.minFrameRate <= value && value <= $0.maxFrameRate } ?? true
            return videoSupported && depthSupported
        }
    }

    private func restoreFrameRate() {
        guard let device = currentDevice else { return }
        let choices = supportedFrameRates(for: device)
        let saved = UserDefaults.standard.integer(forKey: "recordingFrameRate")
        let savedCaptureRate = choices.contains(saved) ? saved : 0
        let requiredCaptureRate = LiveFrameRatePolicy.captureRate(
            forLiveRate: requestedLiveStreamFPS,
            supportedCaptureRates: choices
        )
        // The saved live choice is authoritative for app settings. Preserve a
        // higher explicit capture rate, but never restore one below live output.
        let requested = max(savedCaptureRate, requiredCaptureRate ?? choices.max() ?? 0)
        requestedFrameRate = requested
        let selected = applyFrameRate(requested, to: device) ? requested : 0
        publishFrameRateState(for: device, activeCaptureRate: selected)
    }

    private func publishFrameRateState(for device: AVCaptureDevice, activeCaptureRate: Int) {
        let captureRates = supportedFrameRates(for: device)
        let liveRates = LiveFrameRatePolicy.availableLiveRates(supportedCaptureRates: captureRates)
        let requestedLiveRate = requestedLiveStreamFPS
        let deliveredCaptureRates: [Int]
        if activeCaptureRate > 0 {
            deliveredCaptureRates = [activeCaptureRate]
        } else if let automaticRate = automaticCaptureRate(for: device, ceiling: 30) {
            deliveredCaptureRates = [automaticRate]
        } else {
            deliveredCaptureRates = []
        }
        let effectiveLiveRate = LiveFrameRatePolicy.effectiveLiveRate(
            requested: requestedLiveRate,
            availableRates: LiveFrameRatePolicy.availableLiveRates(supportedCaptureRates: deliveredCaptureRates)
        )
        let limitMessage: String?
        if let effectiveLiveRate {
            frames.setStreamFPS(effectiveLiveRate)
            limitMessage = requestedLiveRate == effectiveLiveRate
                ? nil
                : "\(configuredLens == .lidar ? "LiDAR" : "This camera setting") limits FPS to \(effectiveLiveRate)."
        } else {
            // Capability discovery can briefly be empty while a graph changes.
            // Retain the last usable cadence rather than stopping camera output.
            limitMessage = captureRates.isEmpty
                ? "FPS options are unavailable with this camera setting."
                : "This camera setting cannot deliver the selected FPS."
        }
        let publishedRate = effectiveLiveRate ?? frames.effectiveStreamFPS()
        frameRateStateGeneration += 1
        let generation = frameRateStateGeneration
        DispatchQueue.main.async {
            guard generation >= self.publishedFrameRateStateGeneration else { return }
            self.publishedFrameRateStateGeneration = generation
            self.availableFrameRates = captureRates
            self.activeFrameRate = activeCaptureRate
            self.availableLiveFrameRates = liveRates
            self.requestedStreamFPS = requestedLiveRate
            self.streamFPS = publishedRate
            self.effectiveStreamFPS = publishedRate
            self.frameRateLimitMessage = limitMessage
        }
    }

    private func updateStreamStatus() {
        let selectedFPS = frames.effectiveStreamFPS()
        DispatchQueue.main.async {
            self.thermalState = ProcessInfo.processInfo.thermalState
            self.effectiveStreamFPS = selectedFPS
            self.effectiveCaptureFPS = nil
            self.performanceMessage = nil
        }
    }

    /// Automatic capture stays within the active graph's supported ranges. This is
    /// a format choice for the automatic setting, independent of runtime health.
    private func automaticCaptureRate(for device: AVCaptureDevice, ceiling: Int) -> Int? {
        typealias RateRange = (minimum: Double, maximum: Double)
        let videoRanges: [RateRange] = device.activeFormat.videoSupportedFrameRateRanges.map {
            (minimum: $0.minFrameRate, maximum: $0.maxFrameRate)
        }
        let depthRanges: [RateRange] = configuredLens == .lidar
            ? (device.activeDepthDataFormat?.videoSupportedFrameRateRanges.map {
                (minimum: $0.minFrameRate, maximum: $0.maxFrameRate)
            } ?? []) : []
        let supportedRanges: [RateRange]
        if depthRanges.isEmpty {
            supportedRanges = videoRanges
        } else {
            supportedRanges = videoRanges.flatMap { video in
                depthRanges.compactMap { depth in
                    let minimum = max(video.minimum, depth.minimum)
                    let maximum = min(video.maximum, depth.maximum)
                    return minimum <= maximum ? (minimum, maximum) : nil
                }
            }
        }
        let limit = Double(ceiling)
        if let selected = supportedRanges.compactMap({ range -> Int? in
            guard range.minimum <= limit else { return nil }
            let candidate = Int(min(limit, range.maximum).rounded(.down))
            return candidate >= Int(range.minimum.rounded(.up)) ? candidate : nil
        }).max() {
            return selected
        }
        return supportedRanges.compactMap { range -> Int? in
            let candidate = Int(range.minimum.rounded(.up))
            return candidate <= Int(range.maximum.rounded(.down)) ? candidate : nil
        }.min()
    }

    private func restorePhotoFormat() {
        guard session.outputs.contains(photoOutput) else { return }
        var choices: [PhotoFormat] = [.jpeg]
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) { choices.append(.heif) }
        if photoOutput.isAppleProRAWEnabled && photoOutput.availableRawPhotoPixelFormatTypes.contains(where: {
            AVCapturePhotoOutput.isAppleProRAWPixelFormat($0)
        }) { choices.append(.proRAW) }
        let saved = PhotoFormat(rawValue: UserDefaults.standard.string(forKey: "photoFormat") ?? "") ?? .jpeg
        configuredAvailablePhotoFormats = choices
        configuredPhotoFormat = choices.contains(saved) ? saved : .jpeg
        if configuredPhotoFormat == .proRAW && wantsLivePhoto {
            session.beginConfiguration()
            photoOutput.isLivePhotoCaptureEnabled = false
            removeMicrophoneInput()
            session.commitConfiguration()
            wantsLivePhoto = false
            UserDefaults.standard.set(false, forKey: "livePhoto")
            DispatchQueue.main.async { self.livePhotoEnabled = false }
        }
        updatePhotoDepthDelivery()
        let selected = configuredPhotoFormat
        DispatchQueue.main.async {
            self.availablePhotoFormats = choices
            self.activePhotoFormat = selected
        }
    }

    func setPhotoFormat(_ format: PhotoFormat) {
        sessionQueue.async {
            guard !self.hasPendingPhotoCapture else { self.report("Wait for the photo capture to finish."); return }
            guard !self.recordingInFlight, !self.movieOutput.isRecording else {
                self.report("Stop recording before changing photo format.")
                return
            }
            guard self.configuredAvailablePhotoFormats.contains(format) else { return }
            if format == .proRAW && self.wantsLivePhoto {
                self.session.beginConfiguration()
                self.photoOutput.isLivePhotoCaptureEnabled = false
                self.removeMicrophoneInput()
                self.session.commitConfiguration()
                self.wantsLivePhoto = false
                UserDefaults.standard.set(false, forKey: "livePhoto")
                DispatchQueue.main.async { self.livePhotoEnabled = false }
            }
            self.configuredPhotoFormat = format
            self.updatePhotoDepthDelivery()
            UserDefaults.standard.set(format.rawValue, forKey: "photoFormat")
            DispatchQueue.main.async { self.activePhotoFormat = format }
        }
    }

    private func updatePhotoDepthDelivery() {
        guard session.outputs.contains(photoOutput) else { return }
        session.beginConfiguration()
        photoOutput.isDepthDataDeliveryEnabled = configuredLens == .lidar &&
            configuredPhotoFormat != .proRAW && photoOutput.isDepthDataDeliverySupported
        session.commitConfiguration()
    }

    private func hasMicrophoneInput() -> Bool {
        session.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true })
    }

    private func addMicrophoneInputIfPossible() {
        guard !hasMicrophoneInput(),
              let microphone = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: microphone),
              session.canAddInput(input) else { return }
        session.addInput(input)
    }

    private func removeMicrophoneInput() {
        for input in session.inputs where (input as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true {
            session.removeInput(input)
        }
    }

    func setLivePhotoEnabled(_ enabled: Bool) {
        let update: (Bool) -> Void = { [weak self] audioAllowed in
            guard let self else { return }
            self.sessionQueue.async {
                guard self.configured, !self.recordingInFlight, !self.movieOutput.isRecording else { return }
                guard !self.hasPendingPhotoCapture else {
                    self.report("Wait for the photo capture to finish.")
                    return
                }
                guard self.session.outputs.contains(self.photoOutput) else {
                    self.report("Photo capture is unavailable with this camera setting.")
                    return
                }
                guard !enabled || self.configuredPhotoFormat != .proRAW else {
                    self.report("Turn off ProRAW before enabling Live Photos.")
                    return
                }
                if enabled && !audioAllowed {
                    self.report("Allow microphone access to capture Live Photos with sound.")
                    return
                }
                self.session.beginConfiguration()
                if self.session.outputs.contains(self.movieOutput) { self.session.removeOutput(self.movieOutput) }
                if enabled { self.addMicrophoneInputIfPossible() }
                let available = self.hasMicrophoneInput() && self.photoOutput.isLivePhotoCaptureSupported
                self.photoOutput.isLivePhotoCaptureEnabled = enabled && available
                if !enabled || !available { self.removeMicrophoneInput() }
                self.session.commitConfiguration()
                guard !enabled || available else {
                    self.report("Live Photos are unavailable with this camera setting.")
                    return
                }
                self.wantsLivePhoto = enabled
                UserDefaults.standard.set(enabled, forKey: "livePhoto")
                DispatchQueue.main.async { self.livePhotoEnabled = enabled }
            }
        }
        if enabled {
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: update)
        } else {
            update(false)
        }
    }

    func setFrameRate(_ rate: Int) {
        sessionQueue.async {
            guard let device = self.currentDevice, !self.recordingInFlight, !self.movieOutput.isRecording else { return }
            guard !self.hasPendingPhotoCapture else { self.report("Wait for the photo capture to finish."); return }
            guard rate == 0 || self.supportedFrameRates(for: device).contains(rate) else { return }
            self.requestedFrameRate = rate
            if self.applyFrameRate(rate, to: device) {
                if !self.isCinematicCaptureActive() {
                    UserDefaults.standard.set(rate, forKey: "recordingFrameRate")
                }
                self.refreshFormatDependentControls(for: device, lens: self.configuredLens)
                if let input = self.cinematicInput {
                    self.refreshCinematicControls(for: device, input: input, lens: self.configuredLens)
                }
                self.restorePhotoFormat()
                self.publishFrameRateState(for: device, activeCaptureRate: rate)
                self.updateStreamStatus()
            }
        }
    }

    /// Applies the app's single FPS choice atomically: capture first, then its
    /// live cap. A failed capture transition leaves the existing live cadence intact.
    func setStreamFPS(_ liveRate: Int) {
        guard LiveFrameRatePolicy.choices.contains(liveRate) else { return }
        sessionQueue.async {
            guard !self.recordingInFlight, !self.movieOutput.isRecording else {
                return
            }
            guard let device = self.currentDevice else {
                self.requestedLiveStreamFPS = liveRate
                UserDefaults.standard.set(liveRate, forKey: "streamFPS")
                self.frameRateStateGeneration += 1
                let generation = self.frameRateStateGeneration
                DispatchQueue.main.async {
                    guard generation >= self.publishedFrameRateStateGeneration else { return }
                    self.publishedFrameRateStateGeneration = generation
                    self.requestedStreamFPS = liveRate
                }
                return
            }
            guard !self.hasPendingPhotoCapture else {
                self.report("Wait for the photo capture to finish.")
                return
            }
            let captureRates = self.supportedFrameRates(for: device)
            guard let captureRate = LiveFrameRatePolicy.captureRate(
                forLiveRate: liveRate,
                supportedCaptureRates: captureRates
            ) else {
                self.report("\(liveRate) fps is unavailable with this camera setting.")
                self.publishFrameRateState(for: device, activeCaptureRate: self.requestedFrameRate)
                return
            }
            guard self.applyFrameRate(captureRate, to: device) else { return }

            self.requestedFrameRate = captureRate
            self.requestedLiveStreamFPS = liveRate
            if !self.isCinematicCaptureActive() {
                UserDefaults.standard.set(captureRate, forKey: "recordingFrameRate")
            }
            UserDefaults.standard.set(liveRate, forKey: "streamFPS")
            self.refreshFormatDependentControls(for: device, lens: self.configuredLens)
            if let input = self.cinematicInput {
                self.refreshCinematicControls(for: device, input: input, lens: self.configuredLens)
            }
            self.restorePhotoFormat()
            self.publishFrameRateState(for: device, activeCaptureRate: captureRate)
            self.updateStreamStatus()
        }
    }

    func setStreamImageQuality(_ quality: StreamImageQuality) {
        assert(Thread.isMainThread)
        streamImageQuality = quality
        effectsLock.lock()
        jpegCompression = quality.jpegCompression
        streamImageQualitySnapshot = quality
        effectsLock.unlock()
        UserDefaults.standard.set(quality.rawValue, forKey: "streamImageQuality")
    }

    func setHDRRecordingEnabled(_ enabled: Bool) {
        sessionQueue.async {
            guard !self.recordingInFlight, !self.movieOutput.isRecording,
                  !self.hasPendingPhotoCapture, !self.configuredHDRLive else { return }
            self.wantsHDRRecording = enabled
            UserDefaults.standard.set(enabled, forKey: "hdrRecording")
            if self.configured {
                self.configure(lens: self.configuredLens, quality: self.configuredQuality)
            } else {
                DispatchQueue.main.async { self.hdrRecordingEnabled = enabled }
            }
        }
    }

    func setHDRLiveEnabled(_ enabled: Bool) {
        sessionQueue.async {
            guard self.configured, !self.recordingInFlight, !self.movieOutput.isRecording,
                  !self.hasPendingPhotoCapture else {
                self.report("Stop recording or wait for photo capture before changing live HDR.")
                return
            }
            self.wantsHDRLive = enabled
            UserDefaults.standard.set(enabled, forKey: "hdrLive")
            self.configure(lens: self.configuredLens, quality: self.configuredQuality)
        }
    }

    func setCinematicEnabled(_ enabled: Bool) {
        sessionQueue.async {
            guard !self.recordingInFlight, !self.recordingStartPending, !self.movieOutput.isRecording else {
                self.report("Stop recording before changing Cinematic capture.")
                return
            }
            guard !self.hasPendingPhotoCapture else {
                self.report("Wait for the photo capture to finish.")
                return
            }
            guard self.configured else {
                self.wantsCinematic = enabled
                DispatchQueue.main.async { self.cinematicEnabled = false }
                return
            }
            if enabled, self.configuredLens == .lidar {
                self.report("Cinematic capture is unavailable with LiDAR depth.")
                return
            }
            self.wantsCinematic = enabled
            self.cinematicFocusFixed = false
            self.invalidateManualFocus()
            self.configure(lens: self.configuredLens, quality: self.configuredQuality)
        }
    }

    func setCinematicAperture(_ aperture: Double) {
        guard aperture.isFinite, aperture > 0 else { return }
        sessionQueue.async {
            guard !self.recordingInFlight, !self.recordingStartPending, !self.movieOutput.isRecording else {
                self.report("Stop recording before changing Cinematic aperture.")
                return
            }
            guard !self.hasPendingPhotoCapture else {
                self.report("Wait for the photo capture to finish.")
                return
            }
            guard #available(iOS 26.0, *), let input = self.cinematicInput,
                  input.isCinematicVideoCaptureEnabled else { return }
            let minimum = self.currentDevice?.activeFormat.minSimulatedAperture ?? 0
            let maximum = self.currentDevice?.activeFormat.maxSimulatedAperture ?? 0
            guard minimum.isFinite, maximum.isFinite, minimum > 0, maximum >= minimum,
                  aperture >= Double(minimum), aperture <= Double(maximum) else {
                self.report("That aperture is unavailable with this Cinematic camera format.")
                return
            }
            let narrowed = Float(aperture)
            guard narrowed.isFinite, narrowed >= minimum, narrowed <= maximum else {
                self.report("That aperture is unavailable with this Cinematic camera format.")
                return
            }
            input.simulatedAperture = narrowed
            DispatchQueue.main.async { self.cinematicAperture = narrowed }
        }
    }

    @discardableResult
    private func applyFrameRate(_ rate: Int, to device: AVCaptureDevice) -> Bool {
        var replacement: AVCaptureDevice.Format?
        let requiresHDRFormat = requiresHDROnCurrentGraph(device)
        if rate > 0 && (!supportsFrameRate(rate, format: device.activeFormat) ||
                        (requiresHDRFormat && !device.activeFormat.supportedColorSpaces.contains(.HLG_BT2020))) {
            guard configuredLens != .lidar,
                  let format = matchingFrameRateFormat(rate, for: device) else {
                report("\(rate) fps is unavailable with this camera format.")
                return false
            }
            replacement = format
        }
        do {
            if replacement != nil { session.beginConfiguration() }
            defer { if replacement != nil { session.commitConfiguration() } }
            try device.lockForConfiguration()
            if let replacement {
                device.activeFormat = replacement
                if configuredHDRLive {
                    device.activeColorSpace = .HLG_BT2020
                } else if replacement.supportedColorSpaces.contains(.sRGB) {
                    device.activeColorSpace = .sRGB
                }
                if let input = cinematicInput, #available(iOS 26.0, *) {
                    guard input.isCinematicVideoCaptureSupported else {
                        device.unlockForConfiguration()
                        report("Cinematic capture is unavailable at \(rate) fps.")
                        return false
                    }
                    input.isCinematicVideoCaptureEnabled = true
                }
            }
            if rate == 0, !isCinematicCaptureActive(),
               let automaticRate = automaticCaptureRate(for: device, ceiling: 30) {
                let duration = CMTime(value: 1, timescale: CMTimeScale(automaticRate))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            } else if rate == 0, isCinematicCaptureActive(), #available(iOS 26.0, *),
               let range = device.activeFormat.videoFrameRateRangeForCinematicVideo {
                let minimumRate = max(1, Int32(range.minFrameRate.rounded(.up)))
                let maximumRate = max(minimumRate, Int32(range.maxFrameRate.rounded(.down)))
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: maximumRate)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: minimumRate)
            } else {
                let duration = rate == 0 ? CMTime.invalid : CMTime(value: 1, timescale: CMTimeScale(rate))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            device.unlockForConfiguration()
            if replacement != nil {
                configureVideoOutputPixelFormat(preferHDR: configuredHDRLive)
                let hdrAvailable = device.activeFormat.supportedColorSpaces.contains(.HLG_BT2020)
                DispatchQueue.main.async { self.hdrRecordingAvailable = hdrAvailable }
            }
            return true
        } catch {
            report(error.localizedDescription)
            return false
        }
    }

    func setZoom(_ value: Float, animated: Bool = false) {
        sessionQueue.async {
            guard let device = self.currentDevice else { return }
            let multiplier = self.zoomMultiplier(for: device, lens: self.configuredLens)
            let requested = CGFloat(max(self.configuredMinZoom, min(value, self.configuredMaxZoom))) / multiplier
            let raw = self.nearestZoom(requested, in: self.configuredDepthZoomRanges)
            do {
                try device.lockForConfiguration()
                self.cancelZoomRampTimer()
                if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
                let target = max(device.minAvailableVideoZoomFactor, min(raw, device.maxAvailableVideoZoomFactor))
                let shouldRamp = animated && self.configuredLens != .lidar && self.configuredDepthZoomRanges.isEmpty &&
                    abs(device.videoZoomFactor - target) > 0.001
                if shouldRamp {
                    // AVCaptureDevice applies the rate as powers of two per second; four keeps
                    // lens-stop taps responsive without delaying the next control change.
                    device.ramp(toVideoZoomFactor: target, withRate: 4)
                } else {
                    device.videoZoomFactor = target
                }
                let actual = Float(device.videoZoomFactor * multiplier)
                device.unlockForConfiguration()
                if shouldRamp {
                    self.trackZoomRamp(on: device, multiplier: multiplier)
                } else {
                    self.persistZoom(actual)
                    DispatchQueue.main.async { self.currentZoom = actual }
                }
            } catch { self.report(error.localizedDescription) }
        }
    }

    func setPhotoFlashMode(_ mode: AVCaptureDevice.FlashMode) {
        assert(Thread.isMainThread)
        photoFlashMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "photoFlashMode")
    }

    func takePhoto() {
        takePhoto(flash: photoFlashMode)
    }

    func takePhoto(flash: AVCaptureDevice.FlashMode) {
        sessionQueue.async {
            guard self.configured, self.session.isRunning,
                  self.session.outputs.contains(self.photoOutput) else { return }
            let videoStill = self.recordingInFlight || self.movieOutput.isRecording
            if videoStill && !self.movieOutput.isRecording {
                self.report("Wait for video recording to start.")
                return
            }
            let format: PhotoFormat = videoStill ? .jpeg : self.configuredPhotoFormat
            let settings: AVCapturePhotoSettings
            switch format {
            case .jpeg:
                settings = AVCapturePhotoSettings()
            case .heif:
                guard self.photoOutput.availablePhotoCodecTypes.contains(.hevc) else { self.report("HEIF is unavailable with this camera."); return }
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            case .proRAW:
                guard let rawFormat = self.photoOutput.availableRawPhotoPixelFormatTypes.first(where: {
                    AVCapturePhotoOutput.isAppleProRAWPixelFormat($0)
                }) else { self.report("ProRAW is unavailable with this camera."); return }
                settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat,
                                                  processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            }
            if !videoStill { settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions }
            if format != .proRAW { settings.photoQualityPrioritization = videoStill ? .speed : .quality }
            settings.isDepthDataDeliveryEnabled = !videoStill && self.configuredLens == .lidar &&
                self.photoOutput.isDepthDataDeliveryEnabled
            if settings.isDepthDataDeliveryEnabled { settings.embedsDepthDataInPhoto = true }
            if !videoStill, format != .proRAW, self.currentDevice?.hasFlash == true,
               self.photoOutput.supportedFlashModes.contains(flash) {
                settings.flashMode = flash
            }
            let captureLivePhoto = !videoStill && self.wantsLivePhoto && format != .proRAW &&
                self.photoOutput.isLivePhotoCaptureEnabled && !self.photoOutput.isLivePhotoCaptureSuspended
            if !videoStill && self.wantsLivePhoto && self.photoOutput.isLivePhotoCaptureSuspended {
                self.report("Live Photo capture is temporarily unavailable.")
                return
            }
            let liveMovieURL = captureLivePhoto
                ? FileManager.default.temporaryDirectory.appendingPathComponent("rocam-live-\(UUID().uuidString).mov")
                : nil
            settings.livePhotoMovieFileURL = liveMovieURL
            self.photoResultsLock.lock()
            self.photoResults[settings.uniqueID] = PhotoCaptureResult(
                expectsRaw: format == .proRAW,
                expectsLivePhoto: captureLivePhoto,
                lidarPhoto: !videoStill && self.configuredLens == .lidar && format != .proRAW,
                videoStill: videoStill,
                temporaryLiveMovieURL: liveMovieURL
            )
            self.photoResultsLock.unlock()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func startRecording() {
        sessionQueue.async {
            // Recording inherits audio only from the separately opted-in stream.
            let audioAllowed = self.frames.isAudioActive() &&
                AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            guard self.configured, self.session.isRunning,
                  !self.recordingInFlight, !self.movieOutput.isRecording else { return }
            guard !self.hasPendingPhotoCapture else {
                self.report("Wait for the photo capture to finish.")
                return
            }
            self.session.beginConfiguration()
            if self.session.outputs.contains(self.photoOutput) && self.photoOutput.isLivePhotoCaptureEnabled {
                self.photoOutput.isLivePhotoCaptureEnabled = false
            }
            if self.photoOutput.isDepthDataDeliveryEnabled {
                self.photoOutput.isDepthDataDeliveryEnabled = false
            }
            if audioAllowed { self.addMicrophoneInputIfPossible() }
            else { self.removeMicrophoneInput() }
            if !self.session.outputs.contains(self.movieOutput), self.session.canAddOutput(self.movieOutput) {
                self.session.addOutput(self.movieOutput)
            }
            if let input = self.cinematicInput, #available(iOS 26.0, *) {
                guard input.isCinematicVideoCaptureSupported else {
                    self.session.commitConfiguration()
                    self.restorePhotoCaptureAfterRecording()
                    self.report("Cinematic capture is unavailable for movie recording with this camera setting.")
                    return
                }
                input.isCinematicVideoCaptureEnabled = true
            }
            self.session.commitConfiguration()
            if let input = self.cinematicInput, let device = self.currentDevice {
                self.refreshCinematicControls(for: device, input: input, lens: self.configuredLens)
            }
            guard self.session.outputs.contains(self.movieOutput) else {
                self.restorePhotoCaptureAfterRecording()
                self.report("Video recording is unavailable with this camera mode.")
                return
            }
            guard var connection = self.movieOutput.connection(with: .video) else {
                self.restorePhotoCaptureAfterRecording()
                self.report("Video output has no camera connection.")
                return
            }
            if let device = self.currentDevice, self.requiresHDROnCurrentGraph(device) {
                guard device.activeFormat.supportedColorSpaces.contains(.HLG_BT2020),
                      self.movieOutput.availableVideoCodecTypes.contains(.hevc) else {
                    self.restorePhotoCaptureAfterRecording()
                    self.report("HLG HDR recording is unavailable with this camera setting.")
                    return
                }
                self.session.beginConfiguration()
                self.previousWideColorAutomatic = self.session.automaticallyConfiguresCaptureDeviceForWideColor
                self.previousRecordingColorSpace = device.activeColorSpace
                self.session.automaticallyConfiguresCaptureDeviceForWideColor = false
                do {
                    try device.lockForConfiguration()
                    device.activeColorSpace = .HLG_BT2020
                    device.unlockForConfiguration()
                } catch {
                    self.session.automaticallyConfiguresCaptureDeviceForWideColor = self.previousWideColorAutomatic
                    self.previousRecordingColorSpace = nil
                    self.session.commitConfiguration()
                    self.restorePhotoCaptureAfterRecording()
                    self.report("Could not enable HLG HDR: \(error.localizedDescription)")
                    return
                }
                self.session.commitConfiguration()
                guard let hdrConnection = self.movieOutput.connection(with: .video) else {
                    self.restorePhotoCaptureAfterRecording()
                    self.report("HLG HDR video output is unavailable.")
                    return
                }
                self.movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: hdrConnection)
                connection = hdrConnection
            }
            if connection.isVideoRotationAngleSupported(Self.portraitRotationAngle) {
                connection.videoRotationAngle = Self.portraitRotationAngle
            }
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = self.configuredLens == .front }
            connection.preferredVideoStabilizationMode = self.configuredLens == .lidar ? .off : .auto
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("rocam-\(UUID().uuidString).mov")
            self.recordingInFlight = true
            self.recordingStartPending = true
            self.stopRequestedWhileStarting = false
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
            DispatchQueue.main.async {
                self.isRecording = true
                self.isRecordingPaused = false
                self.captureMessage = nil
            }
        }
    }

    func stopRecording() {
        sessionQueue.async {
            if self.recordingStartPending {
                self.stopRequestedWhileStarting = true
                return
            }
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
        }
    }

    func setRecordingPaused(_ paused: Bool) {
        sessionQueue.async {
            guard #available(iOS 18.0, *) else { return }
            if self.recordingStartPending {
                self.report("Wait for video recording to start.")
                return
            }
            guard self.recordingInFlight, self.movieOutput.isRecording else { return }
            if paused && !self.movieOutput.isRecordingPaused {
                self.movieOutput.pauseRecording()
            } else if !paused && self.movieOutput.isRecordingPaused {
                self.movieOutput.resumeRecording()
            }
        }
    }

    private func restoreRecordingColorSpace() {
        guard let colorSpace = previousRecordingColorSpace, let device = currentDevice else { return }
        session.beginConfiguration()
        do {
            try device.lockForConfiguration()
            device.activeColorSpace = device.activeFormat.supportedColorSpaces.contains(colorSpace) ? colorSpace : .sRGB
            device.unlockForConfiguration()
        } catch {
            report("Could not restore camera color: \(error.localizedDescription)")
        }
        session.automaticallyConfiguresCaptureDeviceForWideColor = previousWideColorAutomatic
        session.commitConfiguration()
        previousRecordingColorSpace = nil
    }

    private func restorePhotoCaptureAfterRecording() {
        restoreRecordingColorSpace()
        session.beginConfiguration()
        if session.outputs.contains(movieOutput) { session.removeOutput(movieOutput) }
        if session.outputs.contains(photoOutput) {
            photoOutput.isLivePhotoCaptureEnabled = wantsLivePhoto &&
                configuredPhotoFormat != .proRAW && hasMicrophoneInput() &&
                photoOutput.isLivePhotoCaptureSupported
        }
        if !photoOutput.isLivePhotoCaptureEnabled { removeMicrophoneInput() }
        session.commitConfiguration()
        updatePhotoDepthDelivery()
        let enabled = photoOutput.isLivePhotoCaptureEnabled
        if let input = cinematicInput, let device = currentDevice {
            refreshCinematicControls(for: device, input: input, lens: configuredLens)
        }
        DispatchQueue.main.async { self.livePhotoEnabled = enabled }
    }

    private func finishRecordingConfiguration() {
        restorePhotoCaptureAfterRecording()
        if !wantsHDRLive && configuredHDRLive {
            configure(lens: configuredLens, quality: configuredQuality)
        }
    }

    private func zoomMultiplier(for device: AVCaptureDevice, lens: CameraLens) -> CGFloat {
        if #available(iOS 18.0, *) { return device.displayVideoZoomFactorMultiplier }
        // On iOS 17, relate physical cameras to the virtual camera's lens transitions.
        guard let virtualCamera = captureDevice(for: .automatic),
              let first = virtualCamera.virtualDeviceSwitchOverVideoZoomFactors.first else { return 1 }
        let virtualMultiplier = 1 / first.doubleValue
        if lens == .automatic { return virtualMultiplier }
        if let index = virtualCamera.constituentDevices.firstIndex(where: { $0.uniqueID == device.uniqueID }) {
            let rawFactor = index == 0 ? 1 : virtualCamera.virtualDeviceSwitchOverVideoZoomFactors[index - 1].doubleValue
            return virtualMultiplier * rawFactor
        }
        return 1
    }

    private func zoomStorageKey(for lens: CameraLens) -> String {
        lens == .automatic ? "cameraZoom" : "cameraZoom.\(lens.rawValue)"
    }

    private func setConfigurationPresentation(_ isConfiguring: Bool) {
        DispatchQueue.main.async { self.isConfiguring = isConfiguring }
    }

    private func cancelZoomRamp(on device: AVCaptureDevice?) {
        cancelZoomRampTimer()
        guard let device, device.isRampingVideoZoom else { return }
        do {
            try device.lockForConfiguration()
            device.cancelVideoZoomRamp()
            device.unlockForConfiguration()
        } catch {
            report(error.localizedDescription)
        }
    }

    private func cancelZoomRampTimer() {
        zoomRampGeneration &+= 1
        zoomRampTimer?.cancel()
        zoomRampTimer = nil
    }

    private func trackZoomRamp(on device: AVCaptureDevice, multiplier: CGFloat) {
        cancelZoomRampTimer()
        let generation = zoomRampGeneration
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(80), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self, weak device] in
            guard let self, let device,
                  self.zoomRampGeneration == generation,
                  self.currentDevice === device else { return }
            let actual = Float(device.videoZoomFactor * multiplier)
            DispatchQueue.main.async { self.currentZoom = actual }
            guard !device.isRampingVideoZoom else { return }
            self.persistZoom(actual)
            self.cancelZoomRampTimer()
        }
        zoomRampTimer = timer
        timer.resume()
    }

    private func persistZoom(_ value: Float) {
        guard !isCinematicCaptureActive() else { return }
        UserDefaults.standard.set(value, forKey: zoomStorageKey(for: configuredLens))
    }

    private func supportedDepthZoomRanges(for device: AVCaptureDevice) -> [ClosedRange<CGFloat>] {
        let ranges: [ClosedRange<CGFloat>]
        if #available(iOS 17.2, *) {
            ranges = device.activeFormat.supportedVideoZoomRangesForDepthDataDelivery
        } else {
            ranges = device.activeFormat.supportedVideoZoomFactorsForDepthDataDelivery.map { $0...$0 }
        }
        return ranges.compactMap { range in
            let lower = max(range.lowerBound, device.minAvailableVideoZoomFactor)
            let upper = min(range.upperBound, device.maxAvailableVideoZoomFactor)
            return lower <= upper ? lower...upper : nil
        }.sorted { $0.lowerBound < $1.lowerBound }
    }

    private func nearestZoom(_ requested: CGFloat, in ranges: [ClosedRange<CGFloat>]) -> CGFloat {
        guard !ranges.isEmpty else { return requested }
        return ranges.map { min(max(requested, $0.lowerBound), $0.upperBound) }
            .min { abs($0 - requested) < abs($1 - requested) } ?? requested
    }

    func setPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        setPreviewLayers(primary: layer, background: nil)
    }

    func setPreviewLayers(primary layer: AVCaptureVideoPreviewLayer,
                          background: AVCaptureVideoPreviewLayer?) {
        assert(Thread.isMainThread)
        guard previewLayer !== layer || backgroundPreviewLayer !== background else { return }
        previewLayer = layer
        backgroundPreviewLayer = background
        // AVCaptureVideoPreviewLayer is a UIKit layer, so bind it on the main thread.
        // The session queue waits while that binding happens, ensuring no graph
        // transaction can overlap the preview-layer association.
        sessionQueue.async { [weak self, weak layer, weak background] in
            guard let self else { return }
            let didBind = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { [weak self, weak layer, weak background] in
                defer { didBind.signal() }
                guard let self, let layer, self.previewLayer === layer,
                      self.backgroundPreviewLayer === background else { return }
                if layer.session !== self.session { layer.session = self.session }
                if let background, background.session !== self.session { background.session = self.session }
                self.applyPortraitPreviewRotation()
            }
            didBind.wait()
        }
    }

    /// UIKit layers must be updated on the main thread. This is called after
    /// preview-layer association and after every camera graph configuration.
    private func applyPortraitPreviewRotation() {
        assert(Thread.isMainThread)
        if let connection = previewLayer?.connection,
           connection.isVideoRotationAngleSupported(Self.portraitRotationAngle) {
            connection.videoRotationAngle = Self.portraitRotationAngle
        }
        if let connection = backgroundPreviewLayer?.connection,
           connection.isVideoRotationAngleSupported(Self.portraitRotationAngle) {
            connection.videoRotationAngle = Self.portraitRotationAngle
        }
    }

    /// All capture connections use the same fixed portrait geometry. Keep this
    /// on sessionQueue alongside graph changes so synchronized RGB/depth bytes,
    /// photos, and movie recording agree with the preview.
    private func applyPortraitCaptureRotation() {
        let angle = Self.portraitRotationAngle
        if let connection = videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        if let connection = photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        if let connection = depthOutput?.connection(with: .depthData), connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        if let connection = movieOutput.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    func setExposure(_ value: Float) {
        guard value.isFinite else { return }
        sessionQueue.async {
            guard let device = self.currentDevice else { return }
            let minimum = device.minExposureTargetBias
            let maximum = device.maxExposureTargetBias
            guard minimum.isFinite, maximum.isFinite, minimum <= maximum else {
                self.publishCameraControls(for: device)
                return
            }
            let actual = max(minimum, min(value, maximum))
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(actual) { _ in }
                device.unlockForConfiguration()
                UserDefaults.standard.set(actual, forKey: "cameraExposure")
                self.publishCameraControls(for: device, exposure: actual)
            } catch {
                self.publishCameraControls(for: device)
                self.report(error.localizedDescription)
            }
        }
    }

    func setFocusLocked(_ locked: Bool) {
        if Thread.isMainThread { focusLocked = locked }
        else { DispatchQueue.main.async { self.focusLocked = locked } }
        if Thread.isMainThread { aeAfLocked = false }
        else { DispatchQueue.main.async { self.aeAfLocked = false } }
        sessionQueue.async {
            guard let device = self.currentDevice else {
                DispatchQueue.main.async { self.focusLocked = false }
                return
            }
            if self.isCinematicCaptureActive(), #available(iOS 26.0, *) {
                let point = CGPoint(x: 0.5, y: 0.5)
                if locked {
                    device.setCinematicVideoFixedFocus(at: point, focusMode: .strong)
                } else {
                    device.setCinematicVideoTrackingFocus(at: point, focusMode: .weak)
                }
                self.cinematicFocusFixed = locked
                self.invalidateManualFocus()
                self.publishCameraControls(for: device)
                return
            }
            self.invalidateManualFocus(persistingFor: self.configuredLens)
            do {
                try device.lockForConfiguration()
                if locked, device.isFocusModeSupported(.locked) {
                    device.focusMode = .locked
                } else if !locked, let autofocus = self.autofocusMode(for: device) {
                    device.focusMode = autofocus
                }
                device.unlockForConfiguration()
                self.publishCameraControls(for: device)
            } catch { self.publishCameraControls(for: device); self.report(error.localizedDescription) }
        }
    }

    func setManualFocusEnabled(_ enabled: Bool) {
        sessionQueue.async {
            guard let device = self.currentDevice else { return }
            if self.isCinematicCaptureActive() {
                self.invalidateManualFocus()
                self.publishCameraControls(for: device)
                if enabled { self.report("Manual focus is unavailable while Cinematic capture is enabled.") }
                return
            }
            if enabled {
                self.applyManualFocus(position: device.lensPosition, to: device, lens: self.configuredLens)
                return
            }
            guard let autofocus = self.autofocusMode(for: device) else {
                self.publishCameraControls(for: device)
                return
            }
            do {
                try device.lockForConfiguration()
                device.focusMode = autofocus
                device.unlockForConfiguration()
                self.invalidateManualFocus(persistingFor: self.configuredLens)
                self.publishCameraControls(for: device)
                DispatchQueue.main.async { self.aeAfLocked = false }
            } catch {
                self.publishCameraControls(for: device)
                self.report(error.localizedDescription)
            }
        }
    }

    func setManualFocusPosition(_ position: Float) {
        guard position.isFinite, (0...1).contains(position) else { return }
        sessionQueue.async {
            guard let device = self.currentDevice else { return }
            self.applyManualFocus(position: position, to: device, lens: self.configuredLens)
        }
    }

    func focus(at point: CGPoint) {
        sessionQueue.async {
            guard let device = self.currentDevice else { return }
            if self.isCinematicCaptureActive(), #available(iOS 26.0, *) {
                self.invalidateManualFocus()
                device.setCinematicVideoTrackingFocus(at: point, focusMode: .weak)
                self.cinematicFocusFixed = false
                do {
                    try device.lockForConfiguration()
                    if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = point }
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    } else if device.isExposureModeSupported(.autoExpose) {
                        device.exposureMode = .autoExpose
                    }
                    device.unlockForConfiguration()
                } catch { self.report(error.localizedDescription) }
                self.publishCameraControls(for: device)
                DispatchQueue.main.async { self.aeAfLocked = false }
                return
            }
            self.invalidateManualFocus(persistingFor: self.configuredLens)
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    if device.isFocusModeSupported(.autoFocus) {
                        device.focusPointOfInterest = point
                        device.focusMode = .autoFocus
                    } else if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusPointOfInterest = point
                        device.focusMode = .continuousAutoFocus
                    }
                }
                if device.isExposurePointOfInterestSupported {
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposurePointOfInterest = point
                        device.exposureMode = .continuousAutoExposure
                    } else if device.isExposureModeSupported(.autoExpose) {
                        device.exposurePointOfInterest = point
                        device.exposureMode = .autoExpose
                    }
                }
                device.unlockForConfiguration()
                self.publishCameraControls(for: device)
                DispatchQueue.main.async { self.aeAfLocked = false }
            } catch { self.publishCameraControls(for: device); self.report(error.localizedDescription) }
        }
    }

    func lockFocusAndExposure(at point: CGPoint) {
        sessionQueue.async {
            guard let device = self.currentDevice else { return }
            if self.isCinematicCaptureActive(), #available(iOS 26.0, *) {
                self.invalidateManualFocus()
                device.setCinematicVideoFixedFocus(at: point, focusMode: .strong)
                self.cinematicFocusFixed = true
                guard device.isExposureModeSupported(.locked) else {
                    self.publishCameraControls(for: device)
                    self.report("Exposure lock is unavailable with this camera.")
                    return
                }
                do {
                    try device.lockForConfiguration()
                    if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = point }
                    device.exposureMode = .locked
                    device.unlockForConfiguration()
                    self.publishCameraControls(for: device)
                    DispatchQueue.main.async { self.aeAfLocked = true }
                } catch { self.report(error.localizedDescription) }
                return
            }
            self.invalidateManualFocus(persistingFor: self.configuredLens)
            let focusMode: AVCaptureDevice.FocusMode = device.isFocusModeSupported(.autoFocus) ? .autoFocus : .locked
            let exposureMode: AVCaptureDevice.ExposureMode = device.isExposureModeSupported(.autoExpose) ? .autoExpose : .locked
            guard device.isFocusModeSupported(focusMode), device.isExposureModeSupported(exposureMode) else {
                self.report("Focus and exposure lock are unavailable with this camera.")
                return
            }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = point }
                if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = point }
                device.focusMode = focusMode
                device.exposureMode = exposureMode
                device.unlockForConfiguration()
                self.publishCameraControls(for: device)
                DispatchQueue.main.async { self.aeAfLocked = true }
            } catch {
                self.report(error.localizedDescription)
            }
        }
    }

    func setWhiteBalanceLocked(_ locked: Bool) {
        sessionQueue.async {
            guard let device = self.currentDevice else {
                DispatchQueue.main.async { self.whiteBalanceLocked = false }
                return
            }
            let lens = self.configuredLens
            self.whiteBalanceGeneration &+= 1
            let generation = self.whiteBalanceGeneration
            if locked {
                self.lockWhiteBalance(on: device, lens: lens, generation: generation,
                                      gains: AVCaptureDevice.currentWhiteBalanceGains, persistAppliedGains: true)
            } else {
                self.enableAutomaticWhiteBalance(on: device, lens: lens, generation: generation,
                                                 clearPersistedGains: true)
            }
        }
    }

    func setTorch(_ enabled: Bool) {
        if Thread.isMainThread { torchEnabled = enabled }
        else { DispatchQueue.main.async { self.torchEnabled = enabled } }
        sessionQueue.async {
            guard let device = self.currentDevice, device.hasTorch,
                  device.isTorchModeSupported(enabled ? .on : .off),
                  (!enabled || device.isTorchAvailable) else {
                DispatchQueue.main.async { self.torchEnabled = false }
                if enabled { self.report("Torch is unavailable with this camera setting.") }
                return
            }
            do {
                try device.lockForConfiguration()
                device.torchMode = enabled ? .on : .off
                device.unlockForConfiguration()
                self.publishCameraControls(for: device)
            } catch { self.publishCameraControls(for: device); self.report(error.localizedDescription) }
        }
    }

    private func publishCameraControls(for device: AVCaptureDevice, exposure: Float? = nil) {
        let reportedMinimumExposure = device.minExposureTargetBias
        let reportedMaximumExposure = device.maxExposureTargetBias
        let hasExposureBounds = reportedMinimumExposure.isFinite && reportedMaximumExposure.isFinite &&
            reportedMinimumExposure <= reportedMaximumExposure
        let minimumExposure = hasExposureBounds ? reportedMinimumExposure : 0
        let maximumExposure = hasExposureBounds ? reportedMaximumExposure : 0
        let currentExposure = min(maximumExposure, max(minimumExposure, exposure ?? device.exposureTargetBias))
        let cinematic = isCinematicCaptureActive()
        let currentFocusLocked = cinematic ? cinematicFocusFixed : device.focusMode == .locked
        let supportsManualFocus = !cinematic && device.isLockingFocusWithCustomLensPositionSupported
        let currentManualFocusEnabled = manualFocusActive && currentFocusLocked && supportsManualFocus
        let currentManualFocusPosition = min(1, max(0, device.lensPosition))
        let currentWhiteBalanceLocked = device.whiteBalanceMode == .locked
        let currentTorchEnabled = device.hasTorch && device.torchMode == .on
        DispatchQueue.main.async {
            self.exposureBias = currentExposure
            self.minExposureTargetBias = minimumExposure
            self.maxExposureTargetBias = maximumExposure
            self.focusLocked = currentFocusLocked
            self.manualFocusSupported = supportsManualFocus
            self.manualFocusEnabled = currentManualFocusEnabled
            self.manualFocusPosition = currentManualFocusPosition
            self.whiteBalanceLocked = currentWhiteBalanceLocked
            self.torchEnabled = currentTorchEnabled
        }
    }

    private func manualFocusStorageKey(for lens: CameraLens) -> String {
        "cameraManualFocusPosition.\(lens.rawValue)"
    }

    private func manualFocusEnabledStorageKey(for lens: CameraLens) -> String {
        "cameraManualFocusEnabled.\(lens.rawValue)"
    }

    // A valid persisted gain triple is the white-balance lock flag. Keeping one per-lens
    // avoids carrying a stale lock from one physical camera to another.
    private func whiteBalanceGainsStorageKey(for lens: CameraLens) -> String {
        "cameraWhiteBalanceGains.\(lens.rawValue)"
    }

    private func automaticWhiteBalanceMode(for device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceMode? {
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { return .continuousAutoWhiteBalance }
        if device.isWhiteBalanceModeSupported(.autoWhiteBalance) { return .autoWhiteBalance }
        return nil
    }

    private func restoreWhiteBalance(for device: AVCaptureDevice, lens: CameraLens) {
        guard device === currentDevice, configuredLens == lens else { return }
        let key = whiteBalanceGainsStorageKey(for: lens)
        let defaults = UserDefaults.standard
        guard let gains = CameraWhiteBalanceGains(defaultsValue: defaults.object(forKey: key),
                                                   maximum: device.maxWhiteBalanceGain) else {
            // Treat missing and corrupt data as automatic white balance. Removing corrupt data
            // prevents a bad legacy value from being retried after every reconfiguration.
            if defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
            enableAutomaticWhiteBalance(on: device, lens: lens, generation: whiteBalanceGeneration,
                                        clearPersistedGains: false)
            return
        }
        guard device.isWhiteBalanceModeSupported(.locked) else {
            report("White-balance lock is unavailable with this camera setting.")
            enableAutomaticWhiteBalance(on: device, lens: lens, generation: whiteBalanceGeneration,
                                        clearPersistedGains: false)
            return
        }
        let supportsExactGains = device.isLockingWhiteBalanceWithCustomDeviceGainsSupported
        lockWhiteBalance(on: device, lens: lens, generation: whiteBalanceGeneration,
                          gains: supportsExactGains
                              ? AVCaptureDevice.WhiteBalanceGains(redGain: gains.values[0],
                                                                  greenGain: gains.values[1],
                                                                  blueGain: gains.values[2])
                              : AVCaptureDevice.currentWhiteBalanceGains,
                          // Preserve the user's exact gains if this temporary device cannot apply them.
                          persistAppliedGains: supportsExactGains)
    }

    private func lockWhiteBalance(on device: AVCaptureDevice, lens: CameraLens, generation: Int,
                                  gains: AVCaptureDevice.WhiteBalanceGains, persistAppliedGains: Bool) {
        guard device === currentDevice, configuredLens == lens,
              device.isWhiteBalanceModeSupported(.locked) else {
            publishCameraControls(for: device)
            return
        }
        do {
            try device.lockForConfiguration()
            device.setWhiteBalanceModeLocked(with: gains) { [weak self, weak device] _ in
                guard let self, let device else { return }
                self.sessionQueue.async {
                    guard self.currentDevice === device,
                          self.configuredLens == lens,
                          self.whiteBalanceGeneration == generation else { return }
                    if device.whiteBalanceMode == .locked, persistAppliedGains,
                       let appliedGains = CameraWhiteBalanceGains(red: device.deviceWhiteBalanceGains.redGain,
                                                                    green: device.deviceWhiteBalanceGains.greenGain,
                                                                    blue: device.deviceWhiteBalanceGains.blueGain,
                                                                    maximum: device.maxWhiteBalanceGain) {
                        UserDefaults.standard.set(appliedGains.values,
                                                  forKey: self.whiteBalanceGainsStorageKey(for: lens))
                    }
                    self.publishCameraControls(for: device)
                }
            }
            device.unlockForConfiguration()
        } catch {
            publishCameraControls(for: device)
            report(error.localizedDescription)
        }
    }

    private func enableAutomaticWhiteBalance(on device: AVCaptureDevice, lens: CameraLens, generation: Int,
                                             clearPersistedGains: Bool) {
        guard device === currentDevice, configuredLens == lens,
              whiteBalanceGeneration == generation else { return }
        guard let mode = automaticWhiteBalanceMode(for: device) else {
            publishCameraControls(for: device)
            report("Automatic white balance is unavailable with this camera setting.")
            return
        }
        do {
            try device.lockForConfiguration()
            device.whiteBalanceMode = mode
            device.unlockForConfiguration()
            if device.whiteBalanceMode != .locked, clearPersistedGains {
                UserDefaults.standard.removeObject(forKey: whiteBalanceGainsStorageKey(for: lens))
            }
            publishCameraControls(for: device)
        } catch {
            publishCameraControls(for: device)
            report(error.localizedDescription)
        }
    }

    private func autofocusMode(for device: AVCaptureDevice) -> AVCaptureDevice.FocusMode? {
        if device.isFocusModeSupported(.continuousAutoFocus) { return .continuousAutoFocus }
        if device.isFocusModeSupported(.autoFocus) { return .autoFocus }
        return nil
    }

    private func invalidateManualFocus(persistingFor lens: CameraLens? = nil) {
        manualFocusGeneration &+= 1
        manualFocusActive = false
        if let lens { UserDefaults.standard.set(false, forKey: manualFocusEnabledStorageKey(for: lens)) }
        DispatchQueue.main.async { self.manualFocusEnabled = false }
    }

    private func restoreManualFocus(for device: AVCaptureDevice, lens: CameraLens) {
        guard !isCinematicCaptureActive() else { return }
        let defaults = UserDefaults.standard
        let enabledKey = manualFocusEnabledStorageKey(for: lens)
        let positionKey = manualFocusStorageKey(for: lens)
        guard defaults.object(forKey: enabledKey) != nil,
              defaults.bool(forKey: enabledKey),
              let number = defaults.object(forKey: positionKey) as? NSNumber else { return }
        let position = number.floatValue
        guard position.isFinite, (0...1).contains(position),
              device.isLockingFocusWithCustomLensPositionSupported else { return }
        applyManualFocus(position: position, to: device, lens: lens)
    }

    private func applyManualFocus(position: Float, to device: AVCaptureDevice, lens: CameraLens) {
        guard position.isFinite, (0...1).contains(position),
              !isCinematicCaptureActive(),
              device === currentDevice,
              device.isLockingFocusWithCustomLensPositionSupported,
              device.isFocusModeSupported(.locked) else {
            publishCameraControls(for: device)
            return
        }
        manualFocusGeneration &+= 1
        let generation = manualFocusGeneration
        // A position update keeps an already locked manual mode active; only first activation waits
        // for AVFoundation's completion before it is published as enabled.
        if !manualFocusActive {
            DispatchQueue.main.async { self.manualFocusEnabled = false }
        }
        do {
            try device.lockForConfiguration()
            device.setFocusModeLocked(lensPosition: position) { [weak self, weak device] _ in
                guard let self, let device else { return }
                self.sessionQueue.async {
                    guard self.currentDevice === device, self.manualFocusGeneration == generation else { return }
                    self.manualFocusActive = device.focusMode == .locked
                    if self.manualFocusActive {
                        UserDefaults.standard.set(device.lensPosition, forKey: self.manualFocusStorageKey(for: lens))
                        UserDefaults.standard.set(true, forKey: self.manualFocusEnabledStorageKey(for: lens))
                    }
                    self.publishCameraControls(for: device)
                    if self.manualFocusActive {
                        DispatchQueue.main.async { self.aeAfLocked = false }
                    }
                }
            }
            device.unlockForConfiguration()
        } catch {
            publishCameraControls(for: device)
            report(error.localizedDescription)
        }
    }

    func setImageEffects(brightness: Float? = nil, contrast: Float? = nil, mirror: Bool? = nil,
                         flip: Bool? = nil, rotation: Int? = nil) {
        assert(Thread.isMainThread)
        if let brightness { effectBrightness = min(0.5, max(-0.5, brightness)) }
        if let contrast { effectContrast = min(1.5, max(0.5, contrast)) }
        if let mirror { effectMirror = mirror }
        if let flip { effectFlip = flip }
        if let rotation, [0, 90, 180, 270].contains(rotation) { effectRotation = rotation }
        effectsLock.lock()
        self.brightness = effectBrightness
        self.contrast = effectContrast
        self.mirror = effectMirror
        self.flip = effectFlip
        self.rotation = effectRotation
        effectsLock.unlock()
        let defaults = UserDefaults.standard
        defaults.set(effectBrightness, forKey: "imageBrightness")
        defaults.set(effectContrast, forKey: "imageContrast")
        defaults.set(effectMirror, forKey: "imageMirror")
        defaults.set(effectFlip, forKey: "imageFlip")
        defaults.set(effectRotation, forKey: "imageRotation")
        if rotation != nil { videoQueue.async { self.invalidateEncodedStreams() } }
    }

    /// Changes only the rendered SDR stream geometry. It intentionally does not
    /// reconfigure the camera, LiDAR synchronizer, HDR HLS stream, or recorder.
    @discardableResult
    func setCustomOutputSize(width: Int, height: Int) -> Bool {
        assert(Thread.isMainThread)
        guard let requested = CustomOutputSize(width: width, height: height) else { return false }
        guard customOutputSize != requested else { return true }
        customOutputSize = requested
        effectsLock.lock()
        customOutputSizeSnapshot = requested
        effectsLock.unlock()
        requested.save(to: UserDefaults.standard)
        videoQueue.async { self.invalidateEncodedStreams() }
        return true
    }

    /// Restores the selected quality preset's long-edge stream behavior.
    func clearCustomOutputSize() {
        assert(Thread.isMainThread)
        guard customOutputSize != nil else { return }
        customOutputSize = nil
        effectsLock.lock()
        customOutputSizeSnapshot = nil
        effectsLock.unlock()
        CustomOutputSize.clear(from: UserDefaults.standard)
        videoQueue.async { self.invalidateEncodedStreams() }
    }

    func setOverlayText(_ text: String) {
        assert(Thread.isMainThread)
        let cleaned = String(text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ").prefix(64))
        guard cleaned != overlayText else { return }
        overlayText = cleaned
        let image = Self.makeOverlayImage(cleaned)
        effectsLock.lock()
        overlayImage = image
        effectsLock.unlock()
        UserDefaults.standard.set(cleaned, forKey: "overlayText")
    }

    private static func makeOverlayImage(_ text: String) -> CIImage? {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let font = UIFont.systemFont(ofSize: 26, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let size = CGSize(width: ceil(textSize.width + 24), height: ceil(textSize.height + 16))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.black.withAlphaComponent(0.65).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8).fill()
            (text as NSString).draw(at: CGPoint(x: 12, y: 8), withAttributes: attributes)
        }
        return rendered.cgImage.map(CIImage.init(cgImage:))
    }

    private static func applyingOverlay(_ overlay: CIImage?, to image: CIImage) -> CIImage {
        guard let overlay else { return image }
        let margin = max(8, image.extent.width * 0.02)
        let preferredScale = max(0.3, min(2, max(image.extent.width, image.extent.height) / 1920))
        let fitScale = max(0, (image.extent.width - 2 * margin) / overlay.extent.width)
        let scale = min(preferredScale, fitScale)
        guard scale > 0 else { return image }
        let placed = overlay.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: image.extent.minX + margin,
                                                 y: image.extent.minY + margin))
        return placed.composited(over: image)
    }

    func compressedClientConnected(codec: RocamVideoCodec) {
        videoQueue.async { self.encodedStreams[codec]?.requestKeyframe() }
    }

    func compressedClientDisconnected(codec: RocamVideoCodec) {
        videoQueue.async {
            guard self.frames.encodedClientCount(codec: codec) == 0 else { return }
            self.encodedStreams.removeValue(forKey: codec)?.invalidate()
        }
    }

    func compressedStatus(codec: RocamVideoCodec) -> EncodedStreamStatus {
        videoQueue.sync { encodedStreams[codec]?.status ?? EncodedStreamStatus(ready: false, error: "", bitRate: 0) }
    }

    private func invalidateEncodedStreams() {
        for stream in encodedStreams.values { stream.invalidate() }
        encodedStreams.removeAll(keepingCapacity: true)
        frames.clearEncodedPackets()
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { self.errorMessage = message }
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard activeSynchronizerIdentity == nil else { return }
        handleVideoSampleBuffer(sampleBuffer)
    }

    /// videoQueue only. The synchronized LiDAR delegate and ordinary camera
    /// delegate both use this once, preserving the existing visual pipeline.
    private func handleVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        publishActualCaptureDimensions(width: width, height: height)
        frames.noteCaptureFrame(width: width, height: height,
                                at: ProcessInfo.processInfo.systemUptime)
        effectsLock.lock()
        let selectedStreamQuality = streamImageQualitySnapshot
        effectsLock.unlock()
        hdrStream.append(sampleBuffer, networkActive: frames.shouldEncodeJPEG(), maxFPS: frames.hdrCaptureFPS(),
                         quality: selectedStreamQuality)
        guard frames.shouldRenderColor() else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let renderFPS = max(frames.colorCaptureFPS(), frames.compressedCaptureFPS())
        guard renderFPS > 0 else { return }
        let interval = 1.0 / Double(renderFPS)
        if nextFrameTime - now > interval { nextFrameTime = now }
        guard now >= nextFrameTime else { return }
        nextFrameTime = now - nextFrameTime > interval ? now + interval : nextFrameTime + interval
        let jpegFPS = frames.colorCaptureFPS()
        let jpegInterval = 1.0 / Double(jpegFPS)
        if nextJPEGFrameTime - now > jpegInterval { nextJPEGFrameTime = now }
        let encodeJPEG = frames.shouldEncodeJPEG() && now >= nextJPEGFrameTime
        if encodeJPEG {
            nextJPEGFrameTime = now - nextJPEGFrameTime > jpegInterval ? now + jpegInterval : nextJPEGFrameTime + jpegInterval
        }
        effectsLock.lock()
        let values = (brightness, contrast, mirror, flip, rotation, streamLongEdge, overlayImage,
                      jpegCompression, customOutputSizeSnapshot)
        effectsLock.unlock()
        let isHDRBuffer = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        var image = CIImage(cvPixelBuffer: buffer, options: isHDRBuffer ? [.toneMapHDRtoSDR: true] : nil)
        if values.0 != 0 || values.1 != 1 {
            image = image.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: values.0, kCIInputContrastKey: values.1])
        }
        if values.2 { image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -image.extent.width, y: 0)) }
        if values.3 { image = image.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -image.extent.height)) }
        if values.4 != 0 { image = image.oriented(forExifOrientation: values.4 == 90 ? 6 : values.4 == 180 ? 3 : 8) }
        if let customOutputSize = values.8 {
            image = customOutputSize.centerCropAndScale(image)
        } else {
            let longestEdge = max(image.extent.width, image.extent.height)
            if values.5 > 0 && longestEdge > values.5 {
                let scale = values.5 / longestEdge
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }
        image = Self.applyingOverlay(values.6, to: image)
        let encodedDemand = frames.encodedDemand()
        if !encodedDemand.isEmpty {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let pixels = max(1, Int(image.extent.width) * Int(image.extent.height))
            let baselineBitRate = min(20_000_000, max(1_000_000, pixels * frames.effectiveStreamFPS() / 10))
            let bitRate = selectedStreamQuality.adjustedBitRate(baselineBitRate)
            for codec in encodedDemand {
                let encoder: EncodedStream
                if let existing = encodedStreams[codec] {
                    encoder = existing
                } else {
                    let created = EncodedStream(codec: codec, callbackQueue: videoQueue, ciContext: ciContext)
                    created.onPacket = { [weak self] packet in self?.frames.appendEncoded(packet) }
                    encodedStreams[codec] = created
                    encoder = created
                }
                encoder.append(image: image, pts: timestamp, fps: frames.effectiveStreamFPS(), bitRate: bitRate)
            }
        }
        let cgImage = frames.needsColorImage() ? ciContext.createCGImage(image, from: image.extent) : nil
        let jpeg: Data?
        if encodeJPEG {
            if let cgImage {
                jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: values.7)
            } else {
                let compressionKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
                jpeg = ciContext.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(),
                                                    options: [compressionKey: values.7]) ??
                    ciContext.createCGImage(image, from: image.extent).flatMap {
                        UIImage(cgImage: $0).jpegData(compressionQuality: values.7)
                    }
            }
        } else {
            jpeg = nil
        }
        frames.setColor(jpeg, image: cgImage, updateJPEG: encodeJPEG)
    }

    private func publishActualCaptureDimensions(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let dimensions = CMVideoDimensions(width: Int32(width), height: Int32(height))
        guard lastPublishedCaptureDimensions?.width != dimensions.width ||
                lastPublishedCaptureDimensions?.height != dimensions.height else { return }
        lastPublishedCaptureDimensions = dimensions
        let size = CGSize(width: CGFloat(width), height: CGFloat(height))
        DispatchQueue.main.async {
            self.actualCapturedSize = size
        }
    }
}

extension CameraService: AVCaptureDepthDataOutputDelegate {
    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData, timestamp: CMTime, connection: AVCaptureConnection) {
        guard activeSynchronizerIdentity == nil else { return }
        handleDepthData(depthData)
    }

    /// videoQueue only. Rendering remains independent of robot-packet demand.
    private func handleDepthData(_ depthData: AVDepthData) {
        guard frames.shouldRenderDepth() else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let interval = 1.0 / Double(frames.depthCaptureFPS())
        if nextDepthFrameTime - now > interval { nextDepthFrameTime = now }
        guard now >= nextDepthFrameTime else { return }
        nextDepthFrameTime = now - nextDepthFrameTime > interval ? now + interval : nextDepthFrameTime + interval
        let depth = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let buffer = depth.depthDataMap
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float32>.size
        let values = base.assumingMemoryBound(to: Float32.self)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let captureRaw = frames.shouldEncodeJPEG()
        var raw = Data(capacity: captureRaw ? 8 + width * height * 4 : 0)
        if captureRaw {
            var widthLE = UInt32(width).littleEndian
            var heightLE = UInt32(height).littleEndian
            withUnsafeBytes(of: &widthLE) { raw.append(contentsOf: $0) }
            withUnsafeBytes(of: &heightLE) { raw.append(contentsOf: $0) }
        }
        for y in 0..<height {
            if captureRaw {
                raw.append(contentsOf: UnsafeRawBufferPointer(start: values.advanced(by: y * stride), count: width * 4))
            }
            for x in 0..<width {
                let meters = values[y * stride + x]
                let proximity = meters.isFinite && meters > 0 ? UInt8(max(0, min(255, (5 - meters) / 5 * 255))) : 0
                let index = (y * width + x) * 4
                pixels[index] = proximity
                pixels[index + 1] = UInt8(min(255, Int(proximity) * 2))
                pixels[index + 2] = 255 - proximity
                pixels[index + 3] = 255
            }
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
        effectsLock.lock()
        let mirror = self.mirror
        let flip = self.flip
        let rotation = self.rotation
        let overlay = overlayImage
        effectsLock.unlock()
        var image = CIImage(cgImage: cgImage)
        if mirror { image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -image.extent.width, y: 0)) }
        if flip { image = image.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -image.extent.height)) }
        if rotation != 0 { image = image.oriented(forExifOrientation: rotation == 90 ? 6 : rotation == 180 ? 3 : 8) }
        image = Self.applyingOverlay(overlay, to: image)
        guard let displayedDepth = ciContext.createCGImage(image, from: image.extent) else { return }
        let jpeg = captureRaw ? UIImage(cgImage: displayedDepth).jpegData(compressionQuality: 0.7) : nil
        frames.setDepth(jpeg, raw: captureRaw ? raw : nil, image: displayedDepth)
    }
}

extension CameraService: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        // Do not consult sessionQueue-owned output references here. The callback's
        // synchronizer is the authority, and its identity fences old callbacks.
        guard activeSynchronizerIdentity == ObjectIdentifier(synchronizer) else { return }
        let outputs = synchronizer.dataOutputs
        guard let video = outputs.first(where: { $0 is AVCaptureVideoDataOutput }) as? AVCaptureVideoDataOutput,
              let depth = outputs.first(where: { $0 is AVCaptureDepthDataOutput }) as? AVCaptureDepthDataOutput else { return }
        let videoData = synchronizedDataCollection.synchronizedData(for: video) as? AVCaptureSynchronizedSampleBufferData
        let depthData = synchronizedDataCollection.synchronizedData(for: depth) as? AVCaptureSynchronizedDepthData

        if let videoData, !videoData.sampleBufferWasDropped {
            handleVideoSampleBuffer(videoData.sampleBuffer)
        }
        if let depthData, !depthData.depthDataWasDropped {
            handleDepthData(depthData.depthData)
        }
        guard let videoData, let depthData,
              !videoData.sampleBufferWasDropped, !depthData.depthDataWasDropped else { return }
        captureRobotPacket(sampleBuffer: videoData.sampleBuffer, depthData: depthData.depthData,
                           colorTimestamp: videoData.timestamp, depthTimestamp: depthData.timestamp,
                           depthFilteringEnabled: depth.isFilteringEnabled,
                           videoRotationAngle: video.connection(with: .video)?.videoRotationAngle,
                           videoMirrored: video.connection(with: .video)?.isVideoMirrored,
                           depthRotationAngle: depth.connection(with: .depthData)?.videoRotationAngle,
                           depthMirrored: depth.connection(with: .depthData)?.isVideoMirrored)
    }

    /// videoQueue only. This path never uses stream effects, resizing, overlays,
    /// or the visual JPEG throttle; it packs the native synchronized buffers.
    private func captureRobotPacket(sampleBuffer: CMSampleBuffer, depthData: AVDepthData,
                                    colorTimestamp: CMTime, depthTimestamp: CMTime, depthFilteringEnabled: Bool,
                                    videoRotationAngle: CGFloat?, videoMirrored: Bool?,
                                    depthRotationAngle: CGFloat?, depthMirrored: Bool?) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let token = frames.reserveRobotCapture(at: now),
              let colorBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let colorSampleBufferTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard colorTimestamp.isValid, colorTimestamp.isNumeric, colorTimestamp.timescale > 0,
              colorSampleBufferTimestamp.isValid, colorSampleBufferTimestamp.isNumeric, colorSampleBufferTimestamp.timescale > 0,
              depthTimestamp.isValid, depthTimestamp.isNumeric, depthTimestamp.timescale > 0 else { return }
        let colorWidth = CVPixelBufferGetWidth(colorBuffer)
        let colorHeight = CVPixelBufferGetHeight(colorBuffer)
        guard boundedRobotDimensions(width: colorWidth, height: colorHeight, maxPixels: 16 * 1024 * 1024) else { return }
        let depth = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        guard let packedDepth = tightlyPackedDepth(depth.depthDataMap),
              boundedRobotDimensions(width: packedDepth.width, height: packedDepth.height, maxPixels: 8 * 1024 * 1024) else { return }
        let isHDR = CVPixelBufferGetPixelFormatType(colorBuffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let image = CIImage(cvPixelBuffer: colorBuffer, options: isHDR ? [.toneMapHDRtoSDR: true] : nil)
        let compressionKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let jpeg = ciContext.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(),
                                                      options: [compressionKey: 0.85]) else { return }
        let maxPacketBytes = 32 * 1024 * 1024
        guard jpeg.count <= maxPacketBytes - packedDepth.data.count else { return }
        let calibration = robotCalibrationMetadata(depthData.cameraCalibrationData)
        let header: [String: Any] = [
            "schemaVersion": 1,
            "sequence": frames.nextRobotSequence(),
            "colorJPEGBytes": jpeg.count,
            "depthBytes": packedDepth.data.count,
            "colorWidth": colorWidth,
            "colorHeight": colorHeight,
            "depthWidth": packedDepth.width,
            "depthHeight": packedDepth.height,
            "colorTimestamp": robotTimestamp(colorTimestamp),
            "depthTimestamp": robotTimestamp(depthTimestamp),
            "colorSampleBufferTimestamp": robotTimestamp(colorSampleBufferTimestamp),
            "timestampProvenance": [
                "colorTimestamp": "AVCaptureSynchronizedSampleBufferData.timestamp, clocked to AVCaptureSession.synchronizationClock",
                "depthTimestamp": "AVCaptureSynchronizedDepthData.timestamp, clocked to AVCaptureSession.synchronizationClock",
                "colorSampleBufferTimestamp": "CMSampleBufferGetPresentationTimeStamp from the synchronized video sample buffer"
            ],
            "synchronized": true,
            "cameraCalibration": calibration ?? NSNull(),
            "rgbCameraIntrinsicMatrix": robotRGBIntrinsicMatrix(sampleBuffer) ?? NSNull(),
            "depthFilteringEnabled": depthFilteringEnabled,
            "depthAccuracy": depthData.depthDataAccuracy.rawValue,
            "depthQuality": depthData.depthDataQuality.rawValue,
            "captureImageGeometry": [
                "colorBuffer": ["width": colorWidth, "height": colorHeight],
                "depthBuffer": ["width": packedDepth.width, "height": packedDepth.height],
                "videoConnectionRotationAngle": videoRotationAngle.map { $0 as Any } ?? NSNull(),
                "videoConnectionMirrored": videoMirrored.map { $0 as Any } ?? NSNull(),
                "depthConnectionRotationAngle": depthRotationAngle.map { $0 as Any } ?? NSNull(),
                "depthConnectionMirrored": depthMirrored.map { $0 as Any } ?? NSNull(),
                "description": "Native AVCapture video and depth buffer coordinates. Connection rotation and mirroring are observed at synchronized delivery. Robot bytes have no stream effects, overlay, crop, scale, mirror, or software rotation. Calibration remains in its original AVCameraCalibrationData reference geometry and is not transformed for connection rotation or mirroring; physical alignment is unverified."
            ]
        ]
        guard JSONSerialization.isValidJSONObject(header),
              let headerData = try? JSONSerialization.data(withJSONObject: header),
              headerData.count <= 1 * 1024 * 1024,
              headerData.count <= Int(UInt32.max),
              headerData.count <= maxPacketBytes - 8 - jpeg.count - packedDepth.data.count else { return }
        var packet = Data("RCR1".utf8)
        var headerLength = UInt32(headerData.count).bigEndian
        withUnsafeBytes(of: &headerLength) { packet.append(contentsOf: $0) }
        packet.append(headerData)
        packet.append(jpeg)
        packet.append(packedDepth.data)
        frames.setRobotPacket(packet, token: token, at: now)
    }

    private func boundedRobotDimensions(width: Int, height: Int, maxPixels: Int) -> Bool {
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { return false }
        return width <= maxPixels / height
    }

    private func tightlyPackedDepth(_ buffer: CVPixelBuffer) -> (data: Data, width: Int, height: Int)? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard boundedRobotDimensions(width: width, height: height, maxPixels: 8 * 1024 * 1024),
              width <= Int.max / 4 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard rowBytes >= width * MemoryLayout<Float32>.size else { return nil }
        var data = Data(capacity: width * height * MemoryLayout<Float32>.size)
        for row in 0..<height {
            data.append(base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self), count: width * MemoryLayout<Float32>.size)
        }
        return (data, width, height)
    }

    private func robotTimestamp(_ time: CMTime) -> [String: Any] {
        ["value": time.value, "timescale": time.timescale, "epoch": time.epoch]
    }

    private func robotRGBIntrinsicMatrix(_ sampleBuffer: CMSampleBuffer) -> [Double]? {
        guard let data = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                         attachmentModeOut: nil) as? Data,
              data.count == MemoryLayout<simd_float3x3>.size else { return nil }
        return data.withUnsafeBytes { raw in
            let matrix = raw.loadUnaligned(as: simd_float3x3.self)
            let values = rowMajor(matrix)
            return values.allSatisfy { $0.isFinite } ? values : nil
        }
    }

    private func robotCalibrationMetadata(_ calibration: AVCameraCalibrationData?) -> [String: Any]? {
        guard let calibration else { return nil }
        let intrinsic = rowMajor(calibration.intrinsicMatrix)
        let extrinsic = rowMajorExtrinsicMillimeters(calibration.extrinsicMatrix)
        guard intrinsic.allSatisfy({ $0.isFinite }), extrinsic.allSatisfy({ $0.isFinite }), calibration.pixelSize.isFinite else { return nil }
        let distortionCenter = calibration.lensDistortionCenter
        guard distortionCenter.x.isFinite, distortionCenter.y.isFinite else { return nil }
        return [
            "intrinsicMatrix": intrinsic,
            "intrinsicMatrixLayout": "row-major 3x3",
            "intrinsicMatrixReferenceDimensions": [Int(calibration.intrinsicMatrixReferenceDimensions.width),
                                                       Int(calibration.intrinsicMatrixReferenceDimensions.height)],
            "extrinsicMatrix": extrinsic,
            "extrinsicMatrixLayout": "row-major 3x4",
            "extrinsicMatrixTranslationUnits": "millimeters",
            "extrinsicMatrixReferenceCamera": "AVCameraCalibrationData reference-camera semantics (not a world or robot pose)",
            "pixelSizeMillimeters": calibration.pixelSize,
            "distortionCenter": ["x": distortionCenter.x, "y": distortionCenter.y],
            "lensDistortionLookupTable": robotLookupTable(calibration.lensDistortionLookupTable),
            "inverseLensDistortionLookupTable": robotLookupTable(calibration.inverseLensDistortionLookupTable)
        ]
    }

    private func rowMajor(_ matrix: simd_float3x3) -> [Double] {
        [Double(matrix.columns.0.x), Double(matrix.columns.1.x), Double(matrix.columns.2.x),
         Double(matrix.columns.0.y), Double(matrix.columns.1.y), Double(matrix.columns.2.y),
         Double(matrix.columns.0.z), Double(matrix.columns.1.z), Double(matrix.columns.2.z)]
    }

    private func rowMajorExtrinsicMillimeters(_ matrix: simd_float4x3) -> [Double] {
        [Double(matrix.columns.0.x), Double(matrix.columns.1.x), Double(matrix.columns.2.x), Double(matrix.columns.3.x),
         Double(matrix.columns.0.y), Double(matrix.columns.1.y), Double(matrix.columns.2.y), Double(matrix.columns.3.y),
         Double(matrix.columns.0.z), Double(matrix.columns.1.z), Double(matrix.columns.2.z), Double(matrix.columns.3.z)]
    }

    private func robotLookupTable(_ data: Data?) -> Any {
        guard let data else { return NSNull() }
        return ["encoding": "base64", "elementType": "Float32", "endianness": "little", "data": data.base64EncodedString()]
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    private func setLivePhotoCapture(_ id: Int64, active: Bool) {
        DispatchQueue.main.async {
            if active { self.livePhotoCaptureIDs.insert(id) }
            else { self.livePhotoCaptureIDs.remove(id) }
            self.isCapturingLivePhoto = !self.livePhotoCaptureIDs.isEmpty
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        if resolvedSettings.livePhotoMovieDimensions.width > 0 {
            setLivePhotoCapture(resolvedSettings.uniqueID, active: true)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishRecordingLivePhotoMovieForEventualFileAt outputFileURL: URL,
                     resolvedSettings: AVCaptureResolvedPhotoSettings) {
        setLivePhotoCapture(resolvedSettings.uniqueID, active: false)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let id = photo.resolvedSettings.uniqueID
        let data = error == nil ? photo.fileDataRepresentation() : nil
        photoResultsLock.lock()
        if var result = photoResults[id] {
            if let error { result.failure = error.localizedDescription }
            else if let data {
                if photo.isRawPhoto { result.raw = data }
                else {
                    result.processed = data
                    result.capturedDepth = photo.depthData != nil
                }
            } else { result.failure = "Could not create photo." }
            photoResults[id] = result
        }
        photoResultsLock.unlock()
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
                     duration: CMTime,
                     photoDisplayTime: CMTime,
                     resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        photoResultsLock.lock()
        if var result = photoResults[resolvedSettings.uniqueID] {
            if let error { result.failure = error.localizedDescription }
            else { result.liveMovieURL = outputFileURL }
            photoResults[resolvedSettings.uniqueID] = result
        }
        photoResultsLock.unlock()
    }

    private func removeLiveMovieFiles(_ result: PhotoCaptureResult) {
        if let url = result.temporaryLiveMovieURL { try? FileManager.default.removeItem(at: url) }
        if let url = result.liveMovieURL, url != result.temporaryLiveMovieURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        setLivePhotoCapture(resolvedSettings.uniqueID, active: false)
        photoResultsLock.lock()
        let result = photoResults.removeValue(forKey: resolvedSettings.uniqueID)
        photoResultsLock.unlock()
        sessionQueue.async {
            if !self.recordingInFlight, !self.movieOutput.isRecording,
               self.session.outputs.contains(self.movieOutput), !self.hasPendingPhotoCapture {
                self.finishRecordingConfiguration()
            }
        }
        if let failure = error?.localizedDescription ?? result?.failure {
            if let result { removeLiveMovieFiles(result) }
            DispatchQueue.main.async { self.captureMessage = failure }
            return
        }
        guard let result, let processed = result.processed,
              !result.expectsRaw || result.raw != nil,
              !result.expectsLivePhoto || result.liveMovieURL != nil else {
            if let result { removeLiveMovieFiles(result) }
            DispatchQueue.main.async { self.captureMessage = "Photo capture was incomplete." }
            return
        }
        let raw = result.raw
        let liveMovieURL = result.liveMovieURL
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                self.removeLiveMovieFiles(result)
                DispatchQueue.main.async { self.captureMessage = "Allow Photos access to save captures." }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                if let raw {
                    request.addResource(with: .photo, data: raw, options: nil)
                    request.addResource(with: .alternatePhoto, data: processed, options: nil)
                } else {
                    request.addResource(with: .photo, data: processed, options: nil)
                }
                if let liveMovieURL {
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = true
                    request.addResource(with: .pairedVideo, fileURL: liveMovieURL, options: options)
                }
            } completionHandler: { saved, error in
                self.removeLiveMovieFiles(result)
                let photoKind = result.videoStill ? "Video still" : liveMovieURL == nil ? "Photo" : "Live Photo"
                let success = raw != nil ? "ProRAW and JPEG saved to Photos" :
                    result.capturedDepth ? "\(photoKind) with LiDAR depth saved to Photos" :
                    result.lidarPhoto ? "\(photoKind) saved without LiDAR depth" : "\(photoKind) saved to Photos"
                let preview: UIImage? = saved ? {
                    guard let source = CGImageSourceCreateWithData(processed as CFData, nil),
                          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 800
                          ] as CFDictionary) else { return nil }
                    return UIImage(cgImage: thumbnail)
                }() : nil
                DispatchQueue.main.async {
                    self.captureMessage = saved ? success : (error?.localizedDescription ?? "Could not save photo")
                    if let preview { self.lastPhotoPreview = preview }
                }
            }
        }
    }
}

extension CameraService: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        sessionQueue.async {
            self.recordingStartPending = false
            if self.stopRequestedWhileStarting && self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
            self.stopRequestedWhileStarting = false
        }
    }

    @available(iOS 18.0, *)
    func fileOutput(_ output: AVCaptureFileOutput, didPauseRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async {
            if self.isRecording { self.isRecordingPaused = true }
        }
    }

    @available(iOS 18.0, *)
    func fileOutput(_ output: AVCaptureFileOutput, didResumeRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async {
            if self.isRecording { self.isRecordingPaused = false }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        sessionQueue.async {
            self.recordingInFlight = false
            self.recordingStartPending = false
            self.stopRequestedWhileStarting = false
            if !self.hasPendingPhotoCapture { self.finishRecordingConfiguration() }
        }
        DispatchQueue.main.async {
            self.isRecording = false
            self.isRecordingPaused = false
        }
        if let error {
            report(error.localizedDescription)
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                try? FileManager.default.removeItem(at: fileURL)
                self.report("Allow Photos access to save captures.")
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            } completionHandler: { saved, error in
                try? FileManager.default.removeItem(at: fileURL)
                DispatchQueue.main.async { self.captureMessage = saved ? "Video saved to Photos" : (error?.localizedDescription ?? "Could not save video") }
            }
        }
    }
}
