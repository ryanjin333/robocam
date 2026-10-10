import Foundation
import Network
import Darwin

struct StreamAddress: Hashable, Identifiable {
    let interface: String
    let ip: String

    var id: String { "\(interface):\(ip)" }

    private var isMacUSBCandidate: Bool {
        ip.hasPrefix("169.254.") && interface.hasPrefix("en") && interface != "en0"
    }

    var label: String {
        if ip == "172.20.10.1" { return "Personal Hotspot (USB or Wi-Fi)" }
        if isMacUSBCandidate { return "Link-local (possible Mac USB)" }
        if interface == "en0" { return "Wi-Fi" }
        return "Other network (\(interface))"
    }

    private var priority: Int {
        if isMacUSBCandidate { return 0 }
        if ip == "172.20.10.1" { return 1 }
        if interface == "en0" { return 2 }
        return 3
    }

    static func ordered(_ addresses: [StreamAddress]) -> [StreamAddress] {
        addresses.sorted { ($0.priority, $0.interface, $0.ip) < ($1.priority, $1.interface, $1.ip) }
    }
}

// CONNECTION_ACTIVITY_POLICY_BEGIN
/// Tracks confirmed media delivery separately from listener readiness and capture demand.
/// All mutation happens on StreamServer's serial network queue.
struct ConnectionActivityPolicy {
    static let activityTimeout: TimeInterval = 2

    private var clientDeadlines: [UUID: TimeInterval] = [:]
    private var mediaDeadline: TimeInterval?

    mutating func recordClientDelivery(for client: UUID, at now: TimeInterval) {
        clientDeadlines[client] = now + Self.activityTimeout
    }

    mutating func recordMediaDelivery(at now: TimeInterval) {
        mediaDeadline = now + Self.activityTimeout
    }

    @discardableResult
    mutating func endClient(_ client: UUID, at now: TimeInterval) -> Bool {
        clientDeadlines.removeValue(forKey: client)
        return isInUse(at: now)
    }

    mutating func reset() {
        clientDeadlines.removeAll()
        mediaDeadline = nil
    }

    mutating func isInUse(at now: TimeInterval) -> Bool {
        clientDeadlines = clientDeadlines.filter { _, deadline in deadline > now }
        if mediaDeadline ?? 0 <= now { mediaDeadline = nil }
        return !clientDeadlines.isEmpty || mediaDeadline != nil
    }
}
// CONNECTION_ACTIVITY_POLICY_END

final class StreamServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isInUse = false
    /// True only after the Rocam desktop receiver has completed its trusted
    /// localhost USB bootstrap or delivered authenticated media over that path.
    /// iOS does not expose a public API for detecting a physical cable directly.
    @Published private(set) var isUSBConnected = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var addresses: [StreamAddress] = []

    let port: UInt16 = 8765
    let accessKey = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    private let queue = DispatchQueue(label: "rocam.network")
    private var listener: NWListener?
    private var listenerID: UUID?
    private var clients: [UUID: NWConnection] = [:]
    private var imageClients: [UUID: Bool] = [:]
    private var encodedClients: [UUID: RocamVideoCodec] = [:]
    private var connectionActivity = ConnectionActivityPolicy()
    private var usbActivity = ConnectionActivityPolicy()
    private var usbBootstrapExpiresAt: TimeInterval = 0
    private var usbEligibleClients = Set<UUID>()
    private var activityExpiryTimer: DispatchSourceTimer?
    private var lastQueuedInUse = false
    private var lastQueuedUSBConnected = false
    private var activityRevision: UInt64 = 0
    private var publishedActivityRevision: UInt64 = 0
    private var addressTimer: DispatchSourceTimer?
    private let frames: FrameStore
    private weak var camera: CameraService?
    private weak var audio: AudioCapture?

    init(camera: CameraService, audio: AudioCapture? = nil) {
        self.camera = camera
        self.audio = audio
        self.frames = camera.frames
    }

    var primaryURL: String? {
        guard let address = addresses.first else { return nil }
        return "http://\(address.ip):\(port)/?key=\(accessKey)"
    }

    func start() {
        queue.async {
            guard self.listener == nil else { return }
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: self.port)!)
                let listenerID = UUID()
                self.listenerID = listenerID
                listener.service = NWListener.Service(name: "Rocam", type: "_rocam._tcp")
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self, self.listenerID == listenerID else { return }
                    switch state {
                    case .ready:
                        self.resetConnectionActivity()
                        self.frames.setJPEGCaptureEnabled(true)
                        DispatchQueue.main.async {
                            AppServices.shared.setStreamingActive(true)
                            self.isRunning = true
                            self.errorMessage = nil
                            self.addresses = Self.localAddresses()
                        }
                        self.addressTimer?.cancel()
                        let timer = DispatchSource.makeTimerSource(queue: self.queue)
                        timer.schedule(deadline: .now() + 2, repeating: 2)
                        timer.setEventHandler { [weak self] in
                            guard let self else { return }
                            let addresses = Self.localAddresses()
                            DispatchQueue.main.async { self.addresses = addresses }
                        }
                        self.addressTimer = timer
                        timer.resume()
                    case .failed(let error):
                        self.resetConnectionActivity()
                        self.stopAudio()
                        self.frames.setJPEGCaptureEnabled(false)
                        self.camera?.resetHDRPresentation()
                        for depth in self.imageClients.values { self.frames.endImageStream(depth: depth) }
                        self.imageClients.removeAll()
                        self.endAllEncodedStreams()
                        for client in self.clients.values { client.cancel() }
                        self.clients.removeAll()
                        DispatchQueue.main.async {
                            AppServices.shared.setStreamingActive(false)
                            self.isRunning = false
                            self.addresses = []
                            self.errorMessage = error.localizedDescription
                        }
                        self.listener?.cancel()
                        self.listener = nil
                        self.listenerID = nil
                        self.addressTimer?.cancel()
                        self.addressTimer = nil
                    case .cancelled:
                        self.resetConnectionActivity()
                        self.stopAudio()
                        self.frames.setJPEGCaptureEnabled(false)
                        self.camera?.resetHDRPresentation()
                        for depth in self.imageClients.values { self.frames.endImageStream(depth: depth) }
                        self.imageClients.removeAll()
                        self.endAllEncodedStreams()
                        for client in self.clients.values { client.cancel() }
                        self.clients.removeAll()
                        self.listener = nil
                        self.listenerID = nil
                        self.addressTimer?.cancel()
                        self.addressTimer = nil
                        DispatchQueue.main.async {
                            AppServices.shared.setStreamingActive(false)
                            self.isRunning = false
                            self.addresses = []
                        }
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                self.listener = listener
                listener.start(queue: self.queue)
            } catch {
                DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func stop() {
        queue.async {
            self.resetConnectionActivity()
            self.stopAudio()
            self.listener?.cancel()
            self.listener = nil
            self.listenerID = nil
            self.frames.setJPEGCaptureEnabled(false)
            self.camera?.resetHDRPresentation()
            for depth in self.imageClients.values { self.frames.endImageStream(depth: depth) }
            self.imageClients.removeAll()
            self.endAllEncodedStreams()
            self.addressTimer?.cancel()
            self.addressTimer = nil
            for client in self.clients.values { client.cancel() }
            self.clients.removeAll()
            DispatchQueue.main.async {
                AppServices.shared.setStreamingActive(false)
                self.isRunning = false
                self.addresses = []
            }
        }
    }

    private func stopAudio() {
        DispatchQueue.main.async { [weak self] in self?.audio?.stop() }
    }

    /// A green indicator means that an authenticated receiver has received actual
    /// video or media data recently. Listening, request headers, and capture demand
    /// intentionally do not reach this path.
    private func recordClientDelivery(for id: UUID) {
        guard clients[id] != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        connectionActivity.recordClientDelivery(for: id, at: now)
        recordUSBDelivery(for: id, persistent: true, at: now)
        publishConnectionActivity()
        updateActivityExpiryTimer()
    }

    /// Short one-shot deadlines make completed robot-frame or HDR segment responses
    /// visible without treating the request's warm-up or playlist as active use.
    private func recordMediaDelivery(for id: UUID) {
        guard clients[id] != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        connectionActivity.recordMediaDelivery(at: now)
        recordUSBDelivery(for: id, persistent: false, at: now)
        publishConnectionActivity()
        updateActivityExpiryTimer()
    }

    private func finishConnectionActivity(for id: UUID) {
        let now = ProcessInfo.processInfo.systemUptime
        _ = connectionActivity.endClient(id, at: now)
        _ = usbActivity.endClient(id, at: now)
        usbEligibleClients.remove(id)
        publishConnectionActivity()
        updateActivityExpiryTimer()
    }

    private func resetConnectionActivity() {
        connectionActivity.reset()
        usbActivity.reset()
        usbBootstrapExpiresAt = 0
        usbEligibleClients.removeAll()
        publishConnectionActivity()
        activityExpiryTimer?.cancel()
        activityExpiryTimer = nil
    }

    /// A successful `/usb/session` response is the only bootstrap evidence for a
    /// USB receiver. It is intentionally short-lived: an authenticated loopback
    /// request must deliver media to keep the USB state alive.
    private func recordUSBSessionBootstrap(for id: UUID, listenerID expectedListenerID: UUID) {
        guard listenerID == expectedListenerID, clients[id] != nil else { return }
        usbBootstrapExpiresAt = ProcessInfo.processInfo.systemUptime + ConnectionActivityPolicy.activityTimeout
        publishConnectionActivity()
        updateActivityExpiryTimer()
    }

    /// A loopback request can become a USB receiver only while a verified
    /// bootstrap or an already-active USB receiver is fresh. A normal simulator
    /// or local browser stream never gets this eligibility by itself.
    private func markUSBEligibleClient(_ id: UUID, connection: NWConnection) {
        guard isLoopbackPeer(connection) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard usbBootstrapExpiresAt > now || usbActivity.isInUse(at: now) else { return }
        usbEligibleClients.insert(id)
    }

    private func recordUSBDelivery(for id: UUID, persistent: Bool, at now: TimeInterval) {
        guard usbEligibleClients.contains(id) else { return }
        // The bootstrap proves the receiver; delivered bytes take over from it so
        // a later stream disconnect clears this state immediately.
        usbBootstrapExpiresAt = 0
        if persistent {
            usbActivity.recordClientDelivery(for: id, at: now)
        } else {
            usbActivity.recordMediaDelivery(at: now)
        }
    }

    /// One timer bounds idle detection without creating one delayed closure per frame.
    private func updateActivityExpiryTimer() {
        let now = ProcessInfo.processInfo.systemUptime
        guard connectionActivity.isInUse(at: now) || usbActivity.isInUse(at: now) || usbBootstrapExpiresAt > now else {
            activityExpiryTimer?.cancel()
            activityExpiryTimer = nil
            return
        }
        guard activityExpiryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.publishConnectionActivity()
            self.updateActivityExpiryTimer()
        }
        activityExpiryTimer = timer
        timer.resume()
    }

    private func publishConnectionActivity() {
        let now = ProcessInfo.processInfo.systemUptime
        let inUse = connectionActivity.isInUse(at: now)
        let usbConnected = usbActivity.isInUse(at: now) || usbBootstrapExpiresAt > now
        guard inUse != lastQueuedInUse || usbConnected != lastQueuedUSBConnected else { return }
        lastQueuedInUse = inUse
        lastQueuedUSBConnected = usbConnected
        activityRevision &+= 1
        let revision = activityRevision
        DispatchQueue.main.async { [weak self] in
            guard let self, revision >= self.publishedActivityRevision else { return }
            self.publishedActivityRevision = revision
            if self.isInUse != inUse { self.isInUse = inUse }
            if self.isUSBConnected != usbConnected { self.isUSBConnected = usbConnected }
        }
    }

    private func disconnect(_ connection: NWConnection, id: UUID) {
        let wasConnected = clients.removeValue(forKey: id) != nil
        if wasConnected { endStreamingClient(id) }
        connection.cancel()
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        clients[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                guard let self else { return }
                self.disconnect(connection, id: id)
            default: break
            }
        }
        connection.start(queue: queue)
        receiveRequest(connection, id: id, collected: Data())
    }

    private func receiveRequest(_ connection: NWConnection, id: UUID, collected: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { return }
            var bytes = collected
            if let data { bytes.append(data) }
            guard bytes.count <= 16384, error == nil else { connection.cancel(); return }
            guard let headerRange = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if complete { connection.cancel(); return }
                self.receiveRequest(connection, id: id, collected: bytes); return
            }
            let header = String(decoding: bytes[..<headerRange.lowerBound], as: UTF8.self)
            let length = header.components(separatedBy: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("content-length:") })
                .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
            guard length >= 0 && length <= 8192 else { connection.cancel(); return }
            let bodyStart = headerRange.upperBound
            guard bytes.count - bodyStart >= length else {
                if complete { connection.cancel(); return }
                self.receiveRequest(connection, id: id, collected: bytes); return
            }
            guard bytes.count == bodyStart + length else { connection.cancel(); return }
            self.route(header: header, body: bytes.subdata(in: bodyStart..<(bodyStart + length)), connection: connection, id: id)
        }
    }

    private func route(header: String, body: Data, connection: NWConnection, id: UUID) {
        guard let requestLine = header.components(separatedBy: "\r\n").first else { connection.cancel(); return }
        let words = requestLine.split(separator: " ")
        guard words.count >= 2,
              let url = URLComponents(string: "http://localhost\(words[1])") else { respond(connection, status: "400 Bad Request"); return }
        let method = String(words[0])

        // A USB-forwarded desktop client can exchange its localhost-only channel for the
        // current session key. This deliberately trusts the Network peer endpoint rather
        // than HTTP forwarding headers, host names, or a caller-supplied address.
        if url.path == "/usb/session" {
            guard method == "GET",
                  url.query == nil,
                  body.isEmpty,
                  isTrustedUSBSessionRequest(header: header, connection: connection),
                  let listenerID else {
                respond(connection, status: "403 Forbidden")
                return
            }
            let session = Data("{\"protocolVersion\":1,\"key\":\"\(accessKey)\"}".utf8)
            respond(connection, type: "application/json", body: session) { [weak self] in
                self?.recordUSBSessionBootstrap(for: id, listenerID: listenerID)
            }
            return
        }

        let key = url.queryItems?.first(where: { $0.name == "key" })?.value
        guard key == accessKey else { respond(connection, status: "403 Forbidden"); return }
        markUSBEligibleClient(id, connection: connection)
        switch (method, url.path) {
        case ("GET", "/"):
            respond(connection, type: "text/html; charset=utf-8", body: Data(Self.viewerHTML(key: accessKey).utf8))
        case ("GET", "/stream"):
            streamImages(connection, id: id, depth: false)
        case ("GET", "/depth.mjpg"):
            let lidarSelected = DispatchQueue.main.sync { camera?.activeLens == .lidar }
            guard lidarSelected else { respond(connection, status: "404 Not Found"); return }
            streamImages(connection, id: id, depth: true)
        case ("GET", "/video.h264"):
            streamEncoded(connection, id: id, codec: .h264)
        case ("GET", "/video.hevc"):
            streamEncoded(connection, id: id, codec: .hevc)
        case ("GET", "/snapshot.jpg"):
            guard let image = frames.latestColor() else { respond(connection, status: "503 Service Unavailable"); return }
            respond(connection, type: "image/jpeg", body: image, id: id, recordsMediaDelivery: true)
        case ("GET", "/depth.jpg"):
            guard let image = frames.latestDepth() else { respond(connection, status: "404 Not Found"); return }
            respond(connection, type: "image/jpeg", body: image, id: id, recordsMediaDelivery: true)
        case ("GET", "/depth.f32"):
            guard let depth = frames.latestDepthRaw() else { respond(connection, status: "404 Not Found"); return }
            respond(connection, type: "application/octet-stream", body: depth, id: id, recordsMediaDelivery: true)
        case ("GET", "/robot.frame"):
            frames.markRobotViewer()
            guard let packet = frames.latestRobotPacket() else {
                respond(connection, status: "503 Service Unavailable"); return
            }
            respond(connection, type: "application/x-rocam-robot-frame", body: packet,
                    id: id, recordsMediaDelivery: true)
        case ("GET", "/hdr.m3u8"):
            frames.markHDRViewer()
            guard let playlist = camera?.hdrStream.playlist(key: accessKey) else {
                respond(connection, status: "503 Service Unavailable"); return
            }
            respond(connection, type: "application/vnd.apple.mpegurl", body: playlist)
        case ("GET", let path) where path.hasPrefix("/hdr/"):
            frames.markHDRViewer()
            let name = String(path.dropFirst(5))
            guard let resource = camera?.hdrStream.resource(named: name,
                                                            generation: url.queryItems?.first(where: { $0.name == "gen" })?.value) else {
                respond(connection, status: "404 Not Found"); return
            }
            respond(connection, type: name == "init.mp4" ? "video/mp4" : "video/iso.segment", body: resource,
                    id: id, recordsMediaDelivery: true)
        case ("GET", "/audio.wav"):
            guard frames.isAudioActive() else { respond(connection, status: "404 Not Found"); return }
            streamAudio(connection, id: id)
        case ("GET", "/status.json"):
            let status: [String: Any] = DispatchQueue.main.sync {
                let customOutput = camera?.customOutputSize
                let outputSize = camera?.currentOutputSize
                let dimming = AppServices.shared.screenDimmingStatus()
                var status: [String: Any] = ["camera": camera?.activeLens.rawValue ?? "", "quality": camera?.activeQuality.rawValue ?? "",
                 "frameRate": camera?.activeFrameRate ?? 0,
                 "photoFormat": camera?.activePhotoFormat.rawValue ?? "JPEG",
                 "photoFlash": camera?.photoFlashMode == .off ? "off" : camera?.photoFlashMode == .on ? "on" : "auto",
                 "recording": camera?.isRecording ?? false,
                 "recordingPaused": camera?.isRecordingPaused ?? false,
                 "recordingPauseAvailable": camera?.canPauseRecording ?? false,
                 "captureMessage": camera?.captureMessage ?? "",
                 "cameraError": camera?.errorMessage ?? "",
                 "streamFPS": frames.currentStreamFPS(),
                 "effectiveStreamFPS": camera?.effectiveStreamFPS ?? frames.effectiveStreamFPS(),
                 "effectiveCaptureFPS": camera?.effectiveCaptureFPS ?? 0,
                 "thermalState": camera.map { Self.thermalStateName($0.thermalState) } ?? "unknown",
                 "performanceMessage": camera?.performanceMessage ?? "",
                 "streamImageQuality": camera?.streamImageQuality.rawValue ?? StreamImageQuality.normal.rawValue,
                 "availableFrameRates": camera?.availableFrameRates ?? [],
                 "minZoom": camera?.minZoom ?? 1, "maxZoom": camera?.maxZoom ?? 1,
                 "currentZoom": camera?.currentZoom ?? 1,
                 "exposure": camera?.exposureBias ?? 0,
                 "minExposureTargetBias": camera?.minExposureTargetBias ?? 0,
                 "maxExposureTargetBias": camera?.maxExposureTargetBias ?? 0,
                 "availableLenses": camera?.availableLenses.map(\.rawValue) ?? [],
                 "hdrLiveAvailable": camera?.hdrLiveAvailable ?? false,
                 "hdrLiveEnabled": camera?.hdrLiveEnabled ?? false,
                 "focusLocked": camera?.focusLocked ?? false,
                 "manualFocusSupported": camera?.manualFocusSupported ?? false,
                 "manualFocusEnabled": camera?.manualFocusEnabled ?? false,
                 "manualFocusPosition": camera?.manualFocusPosition ?? 0,
                 "cinematicAvailable": camera?.cinematicAvailable ?? false,
                 "cinematicEnabled": camera?.cinematicEnabled ?? false,
                 "cinematicAperture": camera?.cinematicAperture ?? 0,
                 "cinematicMinAperture": camera?.cinematicMinAperture ?? 0,
                 "cinematicMaxAperture": camera?.cinematicMaxAperture ?? 0,
                 "whiteBalanceLocked": camera?.whiteBalanceLocked ?? false,
                 "torch": camera?.torchEnabled ?? false,
                 "brightness": camera?.effectBrightness ?? 0, "contrast": camera?.effectContrast ?? 1,
                 "mirror": camera?.effectMirror ?? false, "flip": camera?.effectFlip ?? false,
                 "overlayText": camera?.overlayText ?? "",
                 "rotation": camera?.effectRotation ?? 0,
                 "depth": frames.latestDepth() != nil,
                 "audio": frames.isAudioActive(),
                 "microphoneEnabled": audio?.isMicrophoneEnabled ?? false,
                 "microphonePermission": audio?.microphonePermission ?? "unavailable",
                 "microphoneError": audio?.microphoneError ?? "Microphone capture is unavailable."]
                status["screenDimmed"] = dimming.screenDimmed
                status["screenBrightness"] = Double(dimming.actualDisplayBrightness)
                status["customOutputSize"] = customOutput.map { ["width": $0.width, "height": $0.height] } ?? NSNull()
                status["outputWidth"] = outputSize.map { Int($0.width.rounded()) } ?? 0
                status["outputHeight"] = outputSize.map { Int($0.height.rounded()) } ?? 0
                return status
            }
            let hdrStatus = camera?.hdrStream.status()
            let capture = frames.captureInfo()
            var statusWithHDR = status
            statusWithHDR["frameWidth"] = capture.width
            statusWithHDR["frameHeight"] = capture.height
            statusWithHDR["captureFPS"] = capture.fps
            statusWithHDR["hdrReady"] = hdrStatus?.ready ?? false
            statusWithHDR["hdrError"] = hdrStatus?.error ?? ""
            statusWithHDR["hdrBitRate"] = hdrStatus?.bitRate ?? 0
            for codec in RocamVideoCodec.allCases {
                let encoded = camera?.compressedStatus(codec: codec) ?? EncodedStreamStatus(ready: false, error: "", bitRate: 0)
                let name = codec == .h264 ? "h264" : "hevc"
                statusWithHDR["\(name)Ready"] = encoded.ready
                statusWithHDR["\(name)Error"] = encoded.error
                statusWithHDR["\(name)BitRate"] = encoded.bitRate
                statusWithHDR["\(name)Clients"] = frames.encodedClientCount(codec: codec)
            }
            let data = (try? JSONSerialization.data(withJSONObject: statusWithHDR)) ?? Data("{}".utf8)
            respond(connection, type: "application/json", body: data)
        case ("POST", "/control"):
            guard let values = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                respond(connection, status: "400 Bad Request"); return
            }
            guard control(values) else {
                respond(connection, status: "400 Bad Request"); return
            }
            respond(connection, type: "application/json", body: Data("{\"ok\":true}".utf8))
        default:
            respond(connection, status: "404 Not Found")
        }
    }

    /// Accept only a socket peer whose literal address is loopback.
    /// `NWEndpoint.Host.name` is intentionally rejected: a DNS name, even one that
    /// resolves to localhost, is not evidence of the socket peer's literal address.
    /// Paired iproxy behavior must be verified on-device before this bootstrap is used.
    private func isLoopbackPeer(_ connection: NWConnection) -> Bool {
        guard case let .hostPort(host, _) = connection.endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return address == IPv4Address("127.0.0.1")
        case .ipv6(let address):
            return address == IPv6Address("::1")
        case .name:
            return false
        @unknown default:
            return false
        }
    }

    /// Parse only the bootstrap request's security boundary. Any malformed or duplicated
    /// header fails closed so an alternate Host or opt-in header cannot be hidden.
    private func isTrustedUSBSessionRequest(header: String, connection: NWConnection) -> Bool {
        guard isLoopbackPeer(connection) else { return false }

        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first,
              requestLine == "GET /usb/session HTTP/1.1" || requestLine == "GET /usb/session HTTP/1.0" else {
            return false
        }
        var headerNames = Set<String>()
        var hostValue: String?
        var usbValue: String?
        var contentLength: String?

        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return false }
            let name = String(line[..<colon])
            guard isHTTPToken(name) else { return false }
            // HTTP field values may have optional ASCII whitespace after the colon;
            // compare the resulting field value exactly after that normalization.
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            let normalizedName = name.lowercased()
            guard headerNames.insert(normalizedName).inserted,
                  value.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }) else {
                return false
            }

            switch normalizedName {
            case "host":
                hostValue = value
            case "x-rocam-usb":
                usbValue = value
            case "origin":
                return false
            case "content-length":
                contentLength = value
            case "transfer-encoding":
                return false
            default:
                if normalizedName.hasPrefix("sec-fetch-") { return false }
            }
        }

        return hostValue == "127.0.0.1:8765"
            && usbValue == "1"
            && (contentLength == nil || contentLength == "0")
    }

    private func isHTTPToken(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126:
                return true
            default:
                return false
            }
        }
    }

    private func control(_ values: [String: Any]) -> Bool {
        enum CustomOutputControl {
            case absent
            case clear
            case set(CustomOutputSize)
        }
        let customOutputControl: CustomOutputControl
        if values.keys.contains("customOutputSize") {
            let raw = values["customOutputSize"]
            if raw is NSNull {
                customOutputControl = .clear
            } else {
                guard let requested = raw as? [String: Any],
                      Set(requested.keys) == ["width", "height"],
                      let size = CustomOutputSize(jsonWidth: requested["width"],
                                                  jsonHeight: requested["height"]) else {
                    return false
                }
                customOutputControl = .set(size)
            }
        } else {
            customOutputControl = .absent
        }
        let availableLenses: [CameraLens]?
        if let camera {
            let readAvailableLenses = { camera.availableLenses }
            availableLenses = Thread.isMainThread
                ? readAvailableLenses()
                : DispatchQueue.main.sync(execute: readAvailableLenses)
        } else {
            availableLenses = nil
        }
        let requestedLens: CameraLens?
        if values.keys.contains("lens") {
            guard let rawLens = values["lens"] as? String,
                  let lens = CameraLens(rawValue: rawLens),
                  let availableLenses,
                  availableLenses.contains(lens) else {
                return false
            }
            requestedLens = lens
        } else {
            requestedLens = nil
        }
        let requestedQuality: VideoQuality?
        if values.keys.contains("quality") {
            guard let rawQuality = values["quality"] as? String,
                  let quality = VideoQuality(rawValue: rawQuality) else {
                return false
            }
            requestedQuality = quality
        } else {
            requestedQuality = nil
        }
        let requestedExposure: Float?
        if values.keys.contains("exposure") {
            guard let number = values["exposure"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            let value = number.doubleValue
            guard value.isFinite,
                  Float(value).isFinite else {
                return false
            }
            requestedExposure = Float(value)
        } else {
            requestedExposure = nil
        }
        let microphoneEnabled: Bool?
        if values.keys.contains("microphoneEnabled") {
            guard let number = values["microphoneEnabled"] as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            microphoneEnabled = number.boolValue
        } else {
            microphoneEnabled = nil
        }
        let manualFocusPosition: Float?
        if values.keys.contains("manualFocusPosition") {
            guard let number = values["manualFocusPosition"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            let value = number.doubleValue
            guard value.isFinite, (0...1).contains(value) else { return false }
            manualFocusPosition = Float(value)
        } else {
            manualFocusPosition = nil
        }
        let cinematicAperture: Double?
        if values.keys.contains("cinematicAperture") {
            guard let number = values["cinematicAperture"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            let value = number.doubleValue
            // Reject values before Float narrowing. The real format-specific range is checked
            // again by CameraService; this envelope keeps impossible JSON numeric values out.
            guard value.isFinite, value > 0, value <= 64 else { return false }
            let narrowed = Float(value)
            guard narrowed.isFinite, narrowed > 0 else { return false }
            if let camera {
                let readBounds = {
                    (Double(camera.cinematicMinAperture), Double(camera.cinematicMaxAperture))
                }
                let bounds = Thread.isMainThread ? readBounds() : DispatchQueue.main.sync(execute: readBounds)
                if bounds.0 > 0 || bounds.1 > 0 {
                    guard bounds.0 > 0, bounds.1 >= bounds.0,
                          value >= bounds.0, value <= bounds.1 else { return false }
                }
            }
            cinematicAperture = value
        } else {
            cinematicAperture = nil
        }
        let cinematicEnabled: Bool?
        if values.keys.contains("cinematicEnabled") {
            guard let number = values["cinematicEnabled"] as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            cinematicEnabled = number.boolValue
        } else {
            cinematicEnabled = nil
        }
        if let microphoneEnabled {
            let applyMicrophoneChange = { [weak self] in
                guard let self else { return }
                if self.isRunning {
                    self.audio?.setMicrophoneEnabled(microphoneEnabled)
                } else {
                    self.audio?.stop()
                }
            }
            if Thread.isMainThread {
                applyMicrophoneChange()
            } else {
                DispatchQueue.main.sync(execute: applyMicrophoneChange)
            }
        }
        guard let camera else { return true }
        DispatchQueue.main.async {
            if requestedLens != nil || requestedQuality != nil {
                camera.select(lens: requestedLens ?? camera.activeLens,
                              quality: requestedQuality ?? camera.activeQuality)
            }
            switch customOutputControl {
            case .set(let size):
                _ = camera.setCustomOutputSize(width: size.width, height: size.height)
            case .clear:
                camera.clearCustomOutputSize()
            case .absent where requestedQuality != nil:
                // A selected quality preset restores its own canonical stream size.
                camera.clearCustomOutputSize()
            case .absent:
                break
            }
            camera.setImageEffects(brightness: (values["brightness"] as? NSNumber)?.floatValue,
                                   contrast: (values["contrast"] as? NSNumber)?.floatValue,
                                   mirror: values["mirror"] as? Bool,
                                   flip: values["flip"] as? Bool,
                                   rotation: (values["rotation"] as? NSNumber)?.intValue)
            if let overlayText = values["overlayText"] as? String { camera.setOverlayText(overlayText) }
            if let value = values["zoom"] as? NSNumber { camera.setZoom(value.floatValue) }
            if let value = values["frameRate"] as? NSNumber { camera.setFrameRate(value.intValue) }
            if let value = values["streamFPS"] as? NSNumber { camera.setStreamFPS(value.intValue) }
            if let quality = (values["streamImageQuality"] as? String).flatMap(StreamImageQuality.init(rawValue:)) {
                camera.setStreamImageQuality(quality)
            }
            if let requestedExposure { camera.setExposure(requestedExposure) }
            if values["refocus"] as? Bool == true { camera.focus(at: CGPoint(x: 0.5, y: 0.5)) }
            if let value = values["focusLocked"] as? Bool { camera.setFocusLocked(value) }
            if let enabled = values["manualFocusEnabled"] as? Bool { camera.setManualFocusEnabled(enabled) }
            if values["manualFocusEnabled"] as? Bool != false, let manualFocusPosition {
                camera.setManualFocusPosition(manualFocusPosition)
            }
            if let value = values["whiteBalanceLocked"] as? Bool { camera.setWhiteBalanceLocked(value) }
            if let value = values["torch"] as? Bool { camera.setTorch(value) }
            if let flash = values["photoFlash"] as? String {
                switch flash {
                case "auto": camera.setPhotoFlashMode(.auto)
                case "on": camera.setPhotoFlashMode(.on)
                case "off": camera.setPhotoFlashMode(.off)
                default: break
                }
            }
            if values["capturePhoto"] as? Bool == true { camera.takePhoto() }
            if let recording = values["recording"] as? Bool {
                if recording { camera.startRecording() } else { camera.stopRecording() }
            }
            if let paused = values["recordingPaused"] as? Bool { camera.setRecordingPaused(paused) }
            if let hdrLive = values["hdrLive"] as? Bool { camera.setHDRLiveEnabled(hdrLive) }
            if let cinematicEnabled { camera.setCinematicEnabled(cinematicEnabled) }
            // A disable and aperture in the same request must never turn Cinematic back on.
            if cinematicEnabled != false, let cinematicAperture { camera.setCinematicAperture(cinematicAperture) }
        }
        return true
    }


    private func respond(_ connection: NWConnection, status: String = "200 OK", type: String = "text/plain", body: Data = Data(),
                         id: UUID? = nil, recordsMediaDelivery: Bool = false,
                         onSuccessfulSend: (() -> Void)? = nil) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] error in
            if error == nil {
                if recordsMediaDelivery, let id {
                    self?.recordMediaDelivery(for: id)
                }
                onSuccessfulSend?()
            }
            connection.cancel()
        })
    }

    private func streamImages(_ connection: NWConnection, id: UUID, depth: Bool) {
        imageClients[id] = depth
        frames.beginImageStream(depth: depth)
        let head = "HTTP/1.0 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nCache-Control: no-store\r\nPragma: no-cache\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            guard self.clients[id] != nil, self.imageClients[id] == depth else { return }
            self.watchStreamingClient(connection, id: id)
            self.sendImage(connection, id: id, depth: depth, after: 0)
        })
    }

    private func streamEncoded(_ connection: NWConnection, id: UUID, codec: RocamVideoCodec) {
        encodedClients[id] = codec
        frames.beginEncodedStream(codec: codec)
        camera?.compressedClientConnected(codec: codec)
        let sequence = frames.currentEncodedSequence(codec: codec)
        let head = "HTTP/1.0 200 OK\r\nContent-Type: application/x-rocam-video\r\nCache-Control: no-store\r\nPragma: no-cache\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            guard self.clients[id] != nil, self.encodedClients[id] == codec else { return }
            self.watchStreamingClient(connection, id: id)
            self.sendEncoded(connection, id: id, codec: codec, after: sequence)
        })
    }

    /// Keep one passive read outstanding after the HTTP request. It detects peer
    /// EOF/errors while the camera is paused, and rejects any extra request bytes.
    private func watchStreamingClient(_ connection: NWConnection, id: UUID) {
        guard clients[id] != nil else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, complete, error in
            guard let self else { return }
            if data != nil || complete || error != nil {
                self.disconnect(connection, id: id)
                return
            }
            self.watchStreamingClient(connection, id: id)
        }
    }

    private func endStreamingClient(_ id: UUID) {
        finishConnectionActivity(for: id)
        if let depth = imageClients.removeValue(forKey: id) {
            frames.endImageStream(depth: depth)
        }
        if let codec = encodedClients.removeValue(forKey: id) {
            frames.endEncodedStream(codec: codec)
            camera?.compressedClientDisconnected(codec: codec)
        }
    }

    private func endAllEncodedStreams() {
        let codecs = Array(encodedClients.values)
        encodedClients.removeAll()
        for codec in codecs {
            frames.endEncodedStream(codec: codec)
            camera?.compressedClientDisconnected(codec: codec)
        }
    }

    private func sendEncoded(_ connection: NWConnection, id: UUID, codec: RocamVideoCodec, after sequence: UInt32,
                             retryDelay: Int = 8) {
        guard clients[id] != nil, encodedClients[id] == codec else { return }
        if let next = frames.encodedPacket(codec: codec, after: sequence) {
            if next.skipped { camera?.compressedClientConnected(codec: codec) }
            connection.send(content: next.packet.wireData(), completion: .contentProcessed { [weak self] error in
                guard let self else { connection.cancel(); return }
                guard error == nil else { self.disconnect(connection, id: id); return }
                guard self.clients[id] != nil, self.encodedClients[id] == codec else { return }
                self.recordClientDelivery(for: id)
                self.queue.async { [weak self] in
                    self?.sendEncoded(connection, id: id, codec: codec, after: next.packet.sequence)
                }
            })
        } else {
            if frames.encodedNeedsKeyframe(codec: codec, after: sequence) {
                camera?.compressedClientConnected(codec: codec)
            }
            queue.asyncAfter(deadline: .now() + .milliseconds(retryDelay)) { [weak self] in
                self?.sendEncoded(connection, id: id, codec: codec, after: sequence,
                                  retryDelay: min(80, retryDelay * 2))
            }
        }
    }

    private func sendImage(_ connection: NWConnection, id: UUID, depth: Bool, after sequence: UInt64,
                           retryDelay: Int = 8) {
        guard clients[id] != nil, imageClients[id] == depth else { return }
        let nextFrame = depth ? frames.latestDepth(after: sequence) : frames.latestColor(after: sequence)
        if let (nextSequence, image) = nextFrame {
            let header = "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(image.count)\r\n\r\n"
            var part = Data(header.utf8)
            part.append(image)
            part.append(Data("\r\n".utf8))
            let startedAt = DispatchTime.now().uptimeNanoseconds
            connection.send(content: part, completion: .contentProcessed { [weak self] error in
                guard let self else { connection.cancel(); return }
                guard error == nil else { self.disconnect(connection, id: id); return }
                guard self.clients[id] != nil, self.imageClients[id] == depth else { return }
                self.recordClientDelivery(for: id)
                let interval = max(1, 1000 / self.frames.currentStreamFPS())
                let elapsed = Int((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
                self.queue.asyncAfter(deadline: .now() + .milliseconds(max(0, interval - elapsed))) { [weak self] in
                    self?.sendImage(connection, id: id, depth: depth, after: nextSequence)
                }
            })
        } else {
            queue.asyncAfter(deadline: .now() + .milliseconds(retryDelay)) { [weak self] in
                self?.sendImage(connection, id: id, depth: depth, after: sequence,
                                retryDelay: min(20, retryDelay * 2))
            }
        }
    }

    private func streamAudio(_ connection: NWConnection, id: UUID) {
        let head = "HTTP/1.0 200 OK\r\nContent-Type: audio/wav\r\nCache-Control: no-store\r\n\r\n"
        var data = Data(head.utf8)
        data.append(Self.wavHeader(sampleRate: frames.sampleRate()))
        let sequence = frames.currentAudioSequence()
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard error == nil else { connection.cancel(); return }
            self?.sendAudio(connection, id: id, after: sequence)
        })
    }

    private func sendAudio(_ connection: NWConnection, id: UUID, after sequence: UInt64) {
        guard clients[id] != nil else { return }
        guard frames.isAudioActive() else { connection.cancel(); return }
        if let (next, chunk) = frames.audio(after: sequence) {
            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                guard error == nil else { connection.cancel(); return }
                self?.sendAudio(connection, id: id, after: next)
            })
        } else {
            queue.asyncAfter(deadline: .now() + .milliseconds(40)) { [weak self] in
                self?.sendAudio(connection, id: id, after: sequence)
            }
        }
    }

    private static func wavHeader(sampleRate: Int) -> Data {
        var data = Data("RIFF".utf8)
        func append16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func append32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        append32(UInt32.max - 8)
        data.append(Data("WAVEfmt ".utf8))
        append32(16); append16(1); append16(1)
        append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 2))
        append16(2); append16(16)
        data.append(Data("data".utf8)); append32(UInt32.max - 44)
        return data
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func localAddresses() -> [StreamAddress] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var result: [StreamAddress] = []
        var item: UnsafeMutablePointer<ifaddrs>? = first
        while let current = item {
            let interface = current.pointee
            if let address = interface.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET),
               interface.ifa_flags & UInt32(IFF_UP) != 0 {
                let name = String(cString: interface.ifa_name)
                if name != "lo0" {
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    if inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                        result.append(StreamAddress(interface: name, ip: String(cString: buffer)))
                    }
                }
            }
            item = interface.ifa_next
        }
        return StreamAddress.ordered(result)
    }

    private static func viewerHTML(key: String) -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>Rocam</title>
        <style>body{margin:0;background:#101114;color:#f4f4f4;font:15px -apple-system,system-ui}main{max-width:1000px;margin:auto;padding:20px}h1{font-size:20px;font-weight:600}img{display:block;width:100%;background:#000;border-radius:14px}section{display:flex;gap:12px;flex-wrap:wrap;margin-top:16px;align-items:center}button,select,input{font:inherit}button,select{background:#24262b;color:#fff;border:1px solid #4b4d54;border-radius:9px;padding:9px 12px}label{display:flex;gap:8px;align-items:center}small{color:#aaa}details{margin-top:18px}summary{cursor:pointer;color:#b6f2d9}details section{margin-top:12px}</style></head>
        <body><main><h1>Rocam</h1><img src="/stream?key=\(key)" alt="Camera stream"><section>
        <select id="lens" aria-label="Camera lens" disabled></select>
        <select id="quality"><option>480p</option><option>720p</option><option>1080p</option><option>1440p</option><option>4K</option></select>
        <select id="frameRate"><option value="0">Auto fps</option></select>
        <select id="streamFPS" aria-label="Live fps cap"><option value="15">15 live fps</option><option value="20">20 live fps</option><option value="30">30 live fps</option><option value="60">60 live fps</option><option value="120">120 live fps</option></select>
        <label>Zoom <input id="zoom" type="range" min="0.5" max="15" step="0.1" value="1"><output id="zoomValue">1×</output></label>
        <label>Exposure <input id="exposure" type="range" min="0" max="0" step="0.1" value="0" disabled></label>
        <button id="torch">Torch</button><button id="refocus">Refocus center</button><button id="focus">Lock focus</button><button id="whiteBalance">Lock white balance</button><button id="depth">Show depth</button><label>Flash <select id="photoFlash"><option value="auto">Auto</option><option value="on">On</option><option value="off">Off</option></select></label><button id="photo">Take photo</button><button id="record" aria-pressed="false">Record video</button><button id="pause" aria-pressed="false" hidden>Pause video</button><button id="microphoneButton" aria-pressed="false">Enable microphone</button><button id="audioButton">Play audio</button></section>
        <details><summary>Image adjustments</summary><section>
        <label>Stream quality <select id="streamImageQuality"><option>Low</option><option>Normal</option><option>High</option><option>Very high</option></select></label>
        <label>Brightness <input id="brightness" type="range" min="-0.5" max="0.5" step="0.05"><output id="brightnessValue">0</output></label>
        <label>Contrast <input id="contrast" type="range" min="0.5" max="1.5" step="0.05"><output id="contrastValue">1</output></label>
        <label><input id="mirror" type="checkbox"> Mirror</label>
        <label><input id="flip" type="checkbox"> Flip vertically</label>
        <label>Stream text <input id="overlayText" type="text" maxlength="64" placeholder="Off"></label>
        <label>Rotate <select id="rotation"><option value="0">0°</option><option value="90">90°</option><option value="180">180°</option><option value="270">270°</option></select></label>
        </section></details>
        <details id="manualFocusControls" hidden><summary>Manual focus</summary><section>
        <button id="manualFocus" aria-pressed="false">Enable manual focus</button>
        <label>Near <input id="manualFocusPosition" type="range" min="0" max="1" step="0.01" value="0"><output id="manualFocusValue">0.00</output> Far</label>
        <small>Position is specific to this camera lens.</small>
        </section></details>
        <details id="cinematicControls" hidden><summary>Cinematic capture</summary><section>
        <label><input id="cinematicEnabled" type="checkbox"> Enable native Cinematic capture</label>
        <label>Aperture <input id="cinematicAperture" type="range" step="0.1" value="0"><output id="cinematicApertureValue">f/0.0</output></label>
        <small id="cinematicNote">Uses the iPhone's native Cinematic renderer.</small>
        </section></details>
        <details><summary>10-bit HDR live</summary><section>
        <button id="hdrLive">Start HDR live</button><a id="hdrLink" hidden>Open HEVC HLS stream</a>
        <small>Requires a compatible HEVC HLS player. The preview above stays SDR.</small>
        </section></details>
        <section><small id="captureMessage" role="status"></small><small id="cameraError" role="alert"></small></section>
        <section><small id="microphoneStatus" role="status"></small><small id="microphoneError" role="alert"></small></section>
        <section><small>For OBS, add this page as a Browser Source. Enable the microphone here, then play audio here.</small></section>
        <audio src="/audio.wav?key=\(key)" preload="none"></audio></main>
        <script>
        const key = '\(key)';
        const post = value => fetch('/control?key=' + key, {
          method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(value)
        });
        const zoom = document.getElementById('zoom');
        const fps = document.getElementById('frameRate');
        const liveFPS = document.getElementById('streamFPS');
        const manualFocusDetails = document.getElementById('manualFocusControls');
        const manualFocus = document.getElementById('manualFocus');
        const manualFocusPosition = document.getElementById('manualFocusPosition');
        const cinematicDetails = document.getElementById('cinematicControls');
        const cinematicEnabled = document.getElementById('cinematicEnabled');
        const cinematicAperture = document.getElementById('cinematicAperture');
        const microphoneButton = document.getElementById('microphoneButton');
        const lensSelect = document.getElementById('lens');
        const refresh = () => fetch('/status.json?key=' + key).then(r => r.json()).then(s => {
          zoom.min = s.minZoom; zoom.max = s.maxZoom;
          if (document.activeElement !== zoom) zoom.value = s.currentZoom;
          zoom.oninput();
          const availableLenses = Array.isArray(s.availableLenses)
            ? s.availableLenses.filter(lens => typeof lens === 'string') : [];
          const lensChoicesChanged = availableLenses.length !== lensSelect.options.length ||
            availableLenses.some((lens, index) => lensSelect.options[index]?.value !== lens);
          if (lensChoicesChanged) {
            lensSelect.replaceChildren(...availableLenses.map(lens => {
              const option = document.createElement('option');
              option.value = lens;
              option.textContent = lens;
              return option;
            }));
          }
          lensSelect.disabled = availableLenses.length === 0;
          if (availableLenses.includes(s.camera)) lensSelect.value = s.camera;
          document.getElementById('quality').value = s.quality;
          const depthButton = document.getElementById('depth');
          depthButton.disabled = s.camera !== 'LiDAR';
          if (depth && depthButton.disabled) {
            depth = false;
            document.querySelector('img').src = '/stream?key=' + key;
            depthButton.textContent = 'Show depth';
          }
          fps.innerHTML = '<option value="0">Auto fps</option>' + s.availableFrameRates.map(rate =>
            '<option value="' + rate + '">' + rate + ' fps</option>').join('');
          fps.value = s.frameRate;
          liveFPS.value = s.streamFPS;
          manualFocusDetails.hidden = !s.manualFocusSupported;
          if (s.manualFocusSupported) {
            manualFocus.setAttribute('aria-pressed', String(s.manualFocusEnabled));
            manualFocus.textContent = s.manualFocusEnabled ? 'Disable manual focus' : 'Enable manual focus';
            manualFocusPosition.disabled = !s.manualFocusEnabled;
            if (document.activeElement !== manualFocusPosition) manualFocusPosition.value = s.manualFocusPosition;
            document.getElementById('manualFocusValue').value = Number(manualFocusPosition.value).toFixed(2);
          }
          cinematicDetails.hidden = !s.cinematicAvailable;
          if (s.cinematicAvailable) {
            cinematicEnabled.checked = s.cinematicEnabled;
            const adjustableAperture = s.cinematicEnabled && s.cinematicMinAperture > 0 &&
              s.cinematicMaxAperture >= s.cinematicMinAperture;
            cinematicAperture.disabled = !adjustableAperture || s.recording || s.recordingPaused;
            cinematicEnabled.disabled = s.recording || s.recordingPaused;
            if (adjustableAperture) {
              cinematicAperture.min = s.cinematicMinAperture;
              cinematicAperture.max = s.cinematicMaxAperture;
              if (document.activeElement !== cinematicAperture) cinematicAperture.value = s.cinematicAperture;
            }
            document.getElementById('cinematicApertureValue').value = 'f/' + Number(s.cinematicAperture || 0).toFixed(1);
            document.getElementById('cinematicNote').textContent = adjustableAperture
              ? 'Uses the iPhone native Cinematic renderer.' : 'This format uses its native aperture.';
          }
          document.getElementById('streamImageQuality').value = s.streamImageQuality;
          document.getElementById('photoFlash').value = s.photoFlash;
          document.getElementById('photoFlash').disabled = s.photoFormat === 'ProRAW';
          const record = document.getElementById('record');
          record.setAttribute('aria-pressed', String(s.recording));
          record.textContent = s.recording ? 'Stop recording' : 'Record video';
          const pause = document.getElementById('pause');
          pause.hidden = !s.recording || !s.recordingPauseAvailable;
          pause.setAttribute('aria-pressed', String(s.recordingPaused));
          pause.textContent = s.recordingPaused ? 'Resume video' : 'Pause video';
          document.getElementById('captureMessage').textContent = s.captureMessage;
          document.getElementById('cameraError').textContent = s.cameraError;
          microphoneButton.setAttribute('aria-pressed', String(s.microphoneEnabled));
          microphoneButton.textContent = s.microphoneEnabled ? 'Disable microphone' : 'Enable microphone';
          document.getElementById('microphoneStatus').textContent = s.audio
            ? 'Microphone is live.'
            : s.microphoneEnabled && s.microphonePermission === 'notDetermined'
              ? 'Waiting for microphone permission.' : '';
          document.getElementById('microphoneError').textContent = s.microphoneError;
          const exposure = document.getElementById('exposure');
          const minimumExposure = Number(s.minExposureTargetBias);
          const maximumExposure = Number(s.maxExposureTargetBias);
          const exposureRangeIsUsable = typeof s.minExposureTargetBias === 'number' &&
            typeof s.maxExposureTargetBias === 'number' && Number.isFinite(minimumExposure) && Number.isFinite(maximumExposure) &&
            minimumExposure <= maximumExposure;
          if (exposureRangeIsUsable) {
            exposure.min = minimumExposure;
            exposure.max = maximumExposure;
            exposure.disabled = minimumExposure === maximumExposure;
            if (document.activeElement !== exposure) {
              exposure.value = Math.min(maximumExposure, Math.max(minimumExposure, Number(s.exposure)));
            }
          } else {
            exposure.disabled = true;
          }
          for (const [id, keyName, on, off] of [
            ['torch', 'torch', 'Torch on', 'Torch off'],
            ['focus', 'focusLocked', 'Focus locked', 'Lock focus'],
            ['whiteBalance', 'whiteBalanceLocked', 'White balance locked', 'Lock white balance']
          ]) {
            const button = document.getElementById(id);
            button.setAttribute('aria-pressed', String(s[keyName]));
            button.textContent = s[keyName] ? on : off;
          }
          for (const id of ['brightness', 'contrast']) {
            const input = document.getElementById(id);
            if (document.activeElement !== input) input.value = s[id];
            document.getElementById(id + 'Value').value = Number(input.value).toFixed(2);
          }
          for (const id of ['mirror', 'flip']) document.getElementById(id).checked = s[id];
          const overlayText = document.getElementById('overlayText');
          if (document.activeElement !== overlayText) overlayText.value = s.overlayText;
          document.getElementById('rotation').value = s.rotation;
          const hdrButton = document.getElementById('hdrLive');
          hdrButton.disabled = !s.hdrLiveAvailable;
          hdrButton.textContent = s.hdrLiveEnabled ? 'Stop HDR live' : 'Start HDR live';
          const hdrLink = document.getElementById('hdrLink');
          hdrLink.hidden = !s.hdrReady;
          hdrLink.href = '/hdr.m3u8?key=' + key;
        });
        for (const id of ['lens', 'quality', 'frameRate', 'streamFPS', 'zoom', 'exposure']) {
          document.getElementById(id).onchange = e => {
            post({[id]: ['lens', 'quality'].includes(id) ? e.target.value : Number(e.target.value)});
            if (['lens', 'quality'].includes(id)) setTimeout(refresh, 700);
          };
        }
        zoom.oninput = () => document.getElementById('zoomValue').value = Number(zoom.value).toFixed(1) + '×';
        for (const id of ['brightness', 'contrast']) {
          const input = document.getElementById(id);
          input.oninput = () => document.getElementById(id + 'Value').value = Number(input.value).toFixed(2);
          input.onchange = () => post({[id]: Number(input.value)});
        }
        document.getElementById('streamImageQuality').onchange = e => post({streamImageQuality: e.target.value});
        for (const id of ['mirror', 'flip']) {
          document.getElementById(id).onchange = e => post({[id]: e.target.checked});
        }
        document.getElementById('overlayText').onchange = e => post({overlayText: e.target.value});
        document.getElementById('rotation').onchange = e => post({rotation: Number(e.target.value)});
        document.getElementById('hdrLive').onclick = () =>
          post({hdrLive: document.getElementById('hdrLive').textContent === 'Start HDR live'});
        manualFocus.onclick = () => {
          const next = manualFocus.getAttribute('aria-pressed') !== 'true';
          manualFocus.setAttribute('aria-pressed', String(next));
          manualFocus.textContent = next ? 'Disable manual focus' : 'Enable manual focus';
          post({manualFocusEnabled: next});
        };
        manualFocusPosition.oninput = () =>
          document.getElementById('manualFocusValue').value = Number(manualFocusPosition.value).toFixed(2);
        manualFocusPosition.onchange = () => post({manualFocusPosition: Number(manualFocusPosition.value)});
        cinematicEnabled.onchange = () => post({cinematicEnabled: cinematicEnabled.checked});
        cinematicAperture.oninput = () =>
          document.getElementById('cinematicApertureValue').value = 'f/' + Number(cinematicAperture.value).toFixed(1);
        cinematicAperture.onchange = () => post({cinematicAperture: Number(cinematicAperture.value)});
        document.getElementById('refocus').onclick = () => post({refocus: true});
        document.getElementById('photoFlash').onchange = e => post({photoFlash: e.target.value});
        document.getElementById('photo').onclick = () => post({capturePhoto: true});
        const record = document.getElementById('record');
        record.onclick = () => {
          const next = record.getAttribute('aria-pressed') !== 'true';
          record.setAttribute('aria-pressed', String(next));
          record.textContent = next ? 'Stop recording' : 'Record video';
          post({recording: next});
        };
        const pause = document.getElementById('pause');
        pause.onclick = () => {
          const next = pause.getAttribute('aria-pressed') !== 'true';
          pause.setAttribute('aria-pressed', String(next));
          pause.textContent = next ? 'Resume video' : 'Pause video';
          post({recordingPaused: next});
        };
        refresh();
        setInterval(refresh, 2000);
        for (const [id, keyName, on, off] of [
          ['torch', 'torch', 'Torch on', 'Torch off'],
          ['focus', 'focusLocked', 'Focus locked', 'Lock focus'],
          ['whiteBalance', 'whiteBalanceLocked', 'White balance locked', 'Lock white balance']
        ]) {
          const button = document.getElementById(id);
          button.onclick = () => {
            const next = button.getAttribute('aria-pressed') !== 'true';
            button.setAttribute('aria-pressed', String(next));
            button.textContent = next ? on : off;
            post({[keyName]: next});
          };
        }
        let depth = false;
        document.getElementById('depth').onclick = () => {
          depth = !depth;
          document.querySelector('img').src = (depth ? '/depth.mjpg' : '/stream') + '?key=' + key;
          document.getElementById('depth').textContent = depth ? 'Show color' : 'Show depth';
        };
        microphoneButton.onclick = async () => {
          const enabling = microphoneButton.getAttribute('aria-pressed') !== 'true';
          microphoneButton.setAttribute('aria-pressed', String(enabling));
          microphoneButton.textContent = enabling ? 'Disable microphone' : 'Enable microphone';
          try {
            const response = await post({microphoneEnabled: enabling});
            if (!response.ok) throw new Error('Microphone request was rejected.');
            refresh();
          } catch (error) {
            document.getElementById('microphoneError').textContent = error.message;
            refresh();
          }
        };
        const audio = document.querySelector('audio');
        const audioButton = document.getElementById('audioButton');
        audioButton.onclick = async () => {
          if (!audio.paused) { audio.pause(); audioButton.textContent = 'Play audio'; return; }
          audio.load();
          try { await audio.play(); audioButton.textContent = 'Mute audio'; }
          catch { audioButton.textContent = 'Play audio'; }
        };
        audio.onerror = () => { audioButton.textContent = 'Play audio'; };
        </script></body></html>
        """
    }
}
