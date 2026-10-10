import AVFoundation

final class AudioCapture {
    private let engine = AVAudioEngine()
    private let frames: FrameStore
    private var running = false
    private var externalDisplayActive = false
    private var forwardingToHDMI = false
    private var routeObserver: NSObjectProtocol?
    private var microphoneRequested = false
    private var permissionRequestGeneration = 0
    private(set) var microphoneError = ""

    init(frames: FrameStore) {
        self.frames = frames
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateHDMIOutput() }
    }

    deinit {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    var isMicrophoneEnabled: Bool {
        microphoneRequested
    }

    var microphonePermission: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    func setExternalDisplayActive(_ active: Bool) {
        assert(Thread.isMainThread)
        externalDisplayActive = active
        updateHDMIOutput()
    }

    /// Requests microphone capture only after an authenticated remote control action.
    /// The generation check makes a late system-permission callback harmless after stop.
    func setMicrophoneEnabled(_ enabled: Bool) {
        assert(Thread.isMainThread)
        guard enabled else {
            stop()
            return
        }
        guard !microphoneRequested else { return }

        microphoneRequested = true
        microphoneError = ""
        permissionRequestGeneration &+= 1
        let generation = permissionRequestGeneration
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startIfStillRequested(generation)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self,
                          self.microphoneRequested,
                          self.permissionRequestGeneration == generation else { return }
                    guard granted else {
                        self.microphoneRequested = false
                        self.microphoneError = "Microphone permission was denied."
                        return
                    }
                    self.startIfStillRequested(generation)
                }
            }
        case .denied, .restricted:
            microphoneRequested = false
            microphoneError = microphonePermission == "restricted"
                ? "Microphone access is restricted on this device."
                : "Allow microphone access in Settings to enable audio."
        @unknown default:
            microphoneRequested = false
            microphoneError = "Microphone permission is unavailable."
        }
    }

    func start() throws {
        assert(Thread.isMainThread)
        guard !running else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        frames.setAudioSampleRate(Int(format.sampleRate))
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let channels = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            var bytes = Data(count: count * 2)
            bytes.withUnsafeMutableBytes { raw in
                guard let samples = raw.bindMemory(to: Int16.self).baseAddress else { return }
                for i in 0..<count {
                    let value = max(-1, min(1, channels[0][i]))
                    samples[i] = Int16(value * 32767)
                }
            }
            self.frames.appendAudio(bytes)
        }
        engine.prepare()
        do {
            try engine.start()
            running = true
            frames.setAudioActive(true)
            updateHDMIOutput()
        }
        catch { input.removeTap(onBus: 0); throw error }
    }

    func stop() {
        assert(Thread.isMainThread)
        microphoneRequested = false
        permissionRequestGeneration &+= 1
        microphoneError = ""
        guard running else {
            frames.setAudioActive(false)
            return
        }
        if forwardingToHDMI {
            engine.disconnectNodeOutput(engine.inputNode)
            forwardingToHDMI = false
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        frames.setAudioActive(false)
    }

    private func startIfStillRequested(_ generation: Int) {
        assert(Thread.isMainThread)
        guard microphoneRequested, permissionRequestGeneration == generation else { return }
        do {
            try start()
        } catch {
            microphoneRequested = false
            microphoneError = "Could not start microphone: \(error.localizedDescription)"
            frames.setAudioActive(false)
        }
    }

    private func updateHDMIOutput() {
        let hasHDMI = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .HDMI }
        let shouldForward = running && externalDisplayActive && hasHDMI
        guard shouldForward != forwardingToHDMI else { return }
        if shouldForward {
            let input = engine.inputNode
            engine.connect(input, to: engine.mainMixerNode, format: input.outputFormat(forBus: 0))
        } else {
            engine.disconnectNodeOutput(engine.inputNode)
        }
        forwardingToHDMI = shouldForward
    }
}
