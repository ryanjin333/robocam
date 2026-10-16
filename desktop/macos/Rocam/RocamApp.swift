import OSLog
import SwiftUI
@preconcurrency import SystemExtensions

@main
struct RocamApp: App {
    var body: some Scene { WindowGroup { RocamView() } }
}

@MainActor
final class RocamViewModel: NSObject, ObservableObject, @preconcurrency OSSystemExtensionRequestDelegate {
    private enum ExtensionState {
        case unknown, requesting, awaitingApproval, failed, ready
    }

    @Published var status = "Enable the Rocam Camera once, then connect and trust your iPhone by USB."
    @Published var phones: [USBDevice] = []
    @Published var selectedPhone: USBDevice?

    private let bridge = CameraBridge()
    private let stream = RocamUSBStream()
    private var started = false
    private var activationRequest: OSSystemExtensionRequest?
    private var discoveryTimer: Timer?
    private var discoveryInFlight = false
    private var discoveryGeneration: UInt64 = 0
    private var extensionState = ExtensionState.unknown

    func enable() {
        guard activationRequest == nil else { return }
        extensionState = .requesting
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: "com.rocam.desktop.CameraExtension", queue: .main
        )
        request.delegate = self
        activationRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
        status = "macOS is asking to enable Rocam Camera."
    }

    func beginDiscovery() {
        guard discoveryTimer == nil else { return }
        refreshPhones()
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPhones() }
        }
    }

    func endDiscovery() {
        discoveryGeneration &+= 1
        discoveryInFlight = false
        discoveryTimer?.invalidate()
        discoveryTimer = nil
        stream.stop()
        started = false
        bridge.clear()
    }

    func refreshPhones() {
        guard !discoveryInFlight else { return }
        discoveryInFlight = true
        let generation = discoveryGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = (try? UsbmuxClient().phones()) ?? []
            DispatchQueue.main.async {
                guard let self, generation == self.discoveryGeneration else { return }
                self.discoveryInFlight = false
                self.applyDiscoveredPhones(result)
            }
        }
    }

    func start() {
        guard let phone = selectedPhone else { return }
        if started { stream.stop() }
        started = true
        publishTransportStatus("Connecting to \(phone.name)…")
        stream.start(
            device: phone,
            frame: { [weak self] jpeg in self?.bridge.publishJPEG(jpeg) },
            state: { [weak self] message in
                DispatchQueue.main.async {
                    self?.publishTransportStatus(message)
                    if message.hasPrefix("Waiting") { self?.bridge.clear() }
                }
            }
        )
    }

    func request(_: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        activationRequest = nil
        if result == .completed {
            extensionState = .ready
            status = "Rocam Camera is enabled. Connect and trust an iPhone over USB."
            beginDiscovery()
        } else {
            extensionState = .awaitingApproval
            status = "Rocam Camera needs macOS approval."
        }
    }

    func request(_: OSSystemExtensionRequest, didFailWithError error: Error) {
        activationRequest = nil
        extensionState = .failed
        status = "Rocam Camera could not be enabled: \(error.localizedDescription)"
    }

    func requestNeedsUserApproval(_: OSSystemExtensionRequest) {
        extensionState = .awaitingApproval
        status = "Approve Rocam Camera in System Settings, then reopen Rocam."
    }

    func request(
        _: OSSystemExtensionRequest,
        actionForReplacingExtension _: OSSystemExtensionProperties,
        withExtension _: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction { .replace }

    private func applyDiscoveredPhones(_ result: [USBDevice]) {
        phones = result
        if result.count == 1 {
            selectedPhone = result[0]
            if !started { start() }
        } else if result.isEmpty {
            selectedPhone = nil
            publishTransportStatus("Waiting for a trusted iPhone over USB.")
        } else {
            if let selectedPhone, result.contains(selectedPhone) {
                if !started { publishTransportStatus("Choose an iPhone to start Rocam.") }
            } else {
                self.selectedPhone = nil
                publishTransportStatus("Choose an iPhone to start Rocam.")
            }
        }
    }

    private func publishTransportStatus(_ message: String) {
        guard extensionState != .requesting,
              extensionState != .awaitingApproval,
              extensionState != .failed else { return }
        status = message
    }
}

struct RocamView: View {
    @StateObject private var model = RocamViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rocam").font(.largeTitle.weight(.semibold))
            Text(model.status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Enable Rocam Camera", action: model.enable)
            if model.phones.count > 1 {
                Picker("iPhone", selection: $model.selectedPhone) {
                    Text("Choose iPhone").tag(Optional<USBDevice>.none)
                    ForEach(model.phones) { Text($0.name).tag(Optional($0)) }
                }
                .frame(width: 280)
                Button("Start USB Camera", action: model.start).disabled(model.selectedPhone == nil)
            }
            Text("Rocam uses USB only. Microphone forwarding is off.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 460)
        .task { model.beginDiscovery() }
        .onDisappear { model.endDiscovery() }
    }
}
