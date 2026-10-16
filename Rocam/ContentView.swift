import AVFoundation
import AVKit
import SwiftUI

struct ContentView: View {
    @ObservedObject private var services = AppServices.shared
    @StateObject private var camera: CameraService
    @StateObject private var server: StreamServer
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var zoomSelectionNamespace

    @State private var showConnection = false
    @State private var showWiFiInfo = false
    @State private var showConnectionOptions = false
    @State private var copiedLinkID: String?
    @State private var copyFeedbackTask: Task<Void, Never>?
    @State private var showCameraSettings = false
    @State private var showZoomSlider = false
    @State private var isEditingCustomOutputSize = false
    @State private var customOutputWidth = ""
    @State private var customOutputHeight = ""
    @State private var customOutputError: String?
    private let audio: AudioCapture

    private enum ResolutionSelection: Hashable {
        case preset(VideoQuality)
        case custom
    }

    init() {
        let services = AppServices.shared
        _camera = StateObject(wrappedValue: services.camera)
        _server = StateObject(wrappedValue: services.server)
        audio = services.audio
    }

    private var hasRearCamera: Bool { camera.availableLenses.contains(.automatic) }
    private var previewStatusMessage: String? {
        camera.captureMessage ?? camera.errorMessage ?? server.errorMessage
    }
    private var controlAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.2)
    }
    private var statusTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92))
    }
    private var hasFixedLiDARZoomRange: Bool {
        camera.activeLens == .lidar && abs(camera.maxZoom - camera.minZoom) < 0.01
    }
    private var nearestZoomStop: Float? {
        camera.zoomStops.min { abs(camera.currentZoom - $0) < abs(camera.currentZoom - $1) }
    }
    private var fixedLiDARZoomLabel: String {
        String(format: camera.currentZoom.rounded() == camera.currentZoom ? "%.0f×" : "%.1f×", camera.currentZoom)
    }
    private var isPresentingPhoneSheet: Bool {
        showConnection || showCameraSettings
    }
    var body: some View {
        if #available(iOS 18.0, *) {
            cameraContent.onCameraCaptureEvent(
                isEnabled: hasRearCamera && camera.isRunning && scenePhase == .active &&
                    !showConnection && !showCameraSettings
            ) { event in
                if event.phase == .ended { pressVideoShutter() }
            }
        } else if #available(iOS 17.2, *) {
            cameraContent.background {
                HardwareCaptureInteraction(
                isEnabled: hasRearCamera && camera.isRunning && scenePhase == .active &&
                        !showConnection && !showCameraSettings,
                    action: pressVideoShutter
                )
            }
        } else {
            cameraContent
        }
    }

    private var cameraContent: some View {
        ZStack {
            Color(red: 0.055, green: 0.06, blue: 0.07).ignoresSafeArea()
            GeometryReader { safeAreaGeometry in
                if hasRearCamera {
                    let safeArea = safeAreaGeometry.safeAreaInsets
                    let fullCanvasSize = CGSize(
                        width: safeAreaGeometry.size.width + safeArea.leading + safeArea.trailing,
                        height: safeAreaGeometry.size.height + safeArea.top + safeArea.bottom
                    )
                    let layout = PreviewLayout(
                        canvasSize: fullCanvasSize,
                        safeArea: safeArea,
                        outputSize: camera.currentOutputSize,
                        bottomControlStackExtraHeight: showZoomSlider && !hasFixedLiDARZoomRange ? 84 : 0
                    )
                    ZStack(alignment: .topLeading) {
                        // Keep this representable in one stable subtree. Moving it between
                        // orientation branches recreates its preview layer while the capture
                        // session is reconfiguring.
                        preview(layout: layout)
                            .frame(width: fullCanvasSize.width, height: fullCanvasSize.height)

                        VStack(spacing: 0) {
                            previewHeader
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, layout.headerLeadingInset)
                        .padding(.trailing, layout.headerTrailingInset)
                        .padding(.top, layout.headerTopInset)
                    }
                    .frame(width: fullCanvasSize.width, height: fullCanvasSize.height, alignment: .topLeading)
                    .offset(x: -safeArea.leading, y: -safeArea.top)
                } else {
                    VStack(spacing: 10) {
                        Text("Rocam").font(.system(size: 24, weight: .semibold, design: .rounded))
                        cameraUnavailableCard
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .preferredColorScheme(.dark)
        // This is simultaneous so it observes preview/control interaction
        // without taking focus, zoom, slider, or ScrollView gestures away.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in services.noteScreenInteraction() },
            including: .all
        )
        .sheet(isPresented: $showConnection) {
            NavigationStack {
                ScrollView { connectionCard.padding(16) }
                    .background(Color(red: 0.055, green: 0.06, blue: 0.07))
                    .navigationTitle("Connection")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showConnection = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .alert("Wi-Fi", isPresented: $showWiFiInfo) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Open the Wi-Fi link in a browser on the same network to view your camera.")
            }
        }
        .sheet(isPresented: $showCameraSettings) {
            NavigationStack {
                Form {
                    cameraControls
                }
                .navigationTitle("Camera controls")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showCameraSettings = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .onAppear {
            services.setScreenDimmingViewVisible(true)
            services.setScreenDimmingForegroundActive(scenePhase == .active)
            services.setScreenDimmingSheetPresented(isPresentingPhoneSheet)
            services.setRecordingActive(camera.isRecording)
            if hasRearCamera {
                camera.requestAccessAndStart()
                if camera.isRunning { server.start() }
            }
        }
        .onDisappear {
            services.setScreenDimmingViewVisible(false)
        }
        .onChange(of: showConnection) { _, _ in
            services.setScreenDimmingSheetPresented(isPresentingPhoneSheet)
        }
        .onChange(of: showCameraSettings) { _, _ in
            services.setScreenDimmingSheetPresented(isPresentingPhoneSheet)
        }
        .onChange(of: scenePhase) { _, phase in
            services.setScreenDimmingForegroundActive(phase == .active)
            if phase == .background {
                services.setRecordingActive(false)
                camera.stopRecording()
                server.stop(); camera.stop(); audio.stop()
            } else if phase == .active && hasRearCamera {
                services.setRecordingActive(camera.isRecording)
                camera.requestAccessAndStart()
                if camera.isRunning { server.start() }
            }
        }
        .onChange(of: camera.isRunning) { _, running in
            guard hasRearCamera else { return }
            // A system permission sheet is inactive but still foregrounded.
            if running && scenePhase != .background {
                server.start()
            } else if !running && !camera.isConfiguring {
                server.stop()
            }
        }
        .onChange(of: camera.isConfiguring) { _, configuring in
            guard hasRearCamera, !configuring, !camera.isRunning else { return }
            // A LiDAR graph switch briefly publishes a stopped session before
            // its replacement is ready. Keep the USB listener alive for that
            // intentional handoff, but stop it if configuration finishes down.
            server.stop()
        }
        .onChange(of: camera.isRecording) { _, recording in
            services.setRecordingActive(recording && scenePhase != .background)
        }
    }

    private var previewHeader: some View {
        glassControlContainer {
            HStack {
                Spacer(minLength: 0)
                recordingIndicator
                Spacer(minLength: 0)
            }
            .animation(controlAnimation, value: camera.isRecording)
        }
    }

    private var connectionButton: some View {
        Button { showConnection = true } label: {
            Image(systemName: "link")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
        }
        .floatingGlass(in: Circle(), interactive: true, tint: server.isInUse ? .green : nil)
        .animation(controlAnimation, value: server.isInUse)
        .accessibilityLabel(server.isInUse ? "Connection, in use" : server.isRunning ? "Connection, ready" : "Connection, off")
    }

    private var cameraSettingsButton: some View {
        Button { showCameraSettings = true } label: {
            Image(systemName: "circle.grid.3x3.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
        }
        .floatingGlass(in: Circle(), interactive: true)
        .accessibilityLabel("Camera controls")
    }

    @ViewBuilder
    private var recordingIndicator: some View {
        if camera.isRecording {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let time = recordingTime(camera.recordingDuration)
                HStack(spacing: 6) {
                    Circle()
                        .fill(camera.isRecordingPaused ? .yellow : .red)
                        .frame(width: 7, height: 7)
                    Text(time)
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .lineLimit(1)
                        .minimumScaleFactor(0.3)
                        .frame(width: 58, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .floatingGlass(in: Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(camera.isRecordingPaused ? "Paused at \(time)" : "Recording \(time)")
                .transition(statusTransition)
            }
        }
    }

    private func preview(layout: PreviewLayout) -> some View {
        ZStack(alignment: .topLeading) {
            CameraPreview(zoom: camera.currentZoom, exposureBias: camera.exposureBias, aeAfLocked: camera.aeAfLocked,
                          outputRect: layout.previewRect,
                          matchesRenderedCenterCrop: camera.customOutputSize != nil,
                          manualRotationDegrees: camera.effectRotation,
                          accessibilityLabel: server.isRunning ? "Live camera preview" : "Camera preview",
                          onPreviewLayers: camera.setPreviewLayers(primary:background:),
                          onFocus: camera.focus(at:),
                          onLock: camera.lockFocusAndExposure(at:),
                          onExposure: camera.setExposure(_:), onZoom: { camera.setZoom($0) })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Color.black
                .opacity(camera.isConfiguring ? 0.18 : 0)
                .frame(width: layout.previewRect.width, height: layout.previewRect.height)
                .offset(x: layout.previewRect.minX, y: layout.previewRect.minY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .animation(controlAnimation, value: camera.isConfiguring)
            previewStatus
                .animation(controlAnimation, value: previewStatusMessage)
                .frame(width: layout.previewRect.width)
                .offset(x: layout.previewRect.minX, y: layout.previewRect.minY + layout.statusTopInset)
            if hasRearCamera {
                bottomControls(layout: layout)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(controlAnimation, value: camera.activeLens == .lidar)
        .onChange(of: hasFixedLiDARZoomRange) { _, isFixed in
            if isFixed { showZoomSlider = false }
        }
    }

    private func bottomControls(layout: PreviewLayout) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            if showZoomSlider && !hasFixedLiDARZoomRange {
                precisionZoomSlider
                    .transition(statusTransition)
            }
            HStack(spacing: 8) {
                connectionButton
                Spacer(minLength: 0)
                if hasFixedLiDARZoomRange {
                    fixedLiDARZoomIndicator
                } else {
                    bottomZoomSelector(maximumWidth: max(0, layout.bottomControlsRect.width - 120))
                }
                Spacer(minLength: 0)
                cameraSettingsButton
            }
            .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
        }
        .frame(
            width: layout.bottomControlsRect.width,
            height: layout.bottomControlsRect.height,
            alignment: .bottom
        )
        .offset(x: layout.bottomControlsRect.minX, y: layout.bottomControlsRect.minY)
    }

    @ViewBuilder
    private func bottomZoomSelector(maximumWidth: CGFloat) -> some View {
        if zoomSelectorWidth <= maximumWidth {
            zoomSelector
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                zoomSelector
            }
            .frame(width: maximumWidth, height: 48)
            .clipShape(Capsule())
            .accessibilityLabel("Zoom controls")
        }
    }

    private var zoomSelectorWidth: CGFloat {
        let stopCount = CGFloat(camera.zoomStops.count)
        return stopCount * 44 + max(0, stopCount - 1) * 2 + 8
    }

    private var precisionZoomSlider: some View {
        VStack(spacing: 0) {
            Text(String(format: "%.1f×", camera.currentZoom))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.yellow)
            HStack(spacing: 10) {
                Text(String(format: "%.1f×", camera.minZoom)).font(.caption.monospacedDigit())
                Slider(value: Binding(get: { zoomPosition }, set: { camera.setZoom(zoomValue(for: $0)) }), in: 0...1)
                    .tint(.yellow)
                Text(String(format: "%.0f×", camera.maxZoom)).font(.caption.monospacedDigit())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .floatingGlass(in: Capsule(), interactive: true)
    }

    private var zoomSelector: some View {
        ZStack {
            zoomSelectionGeometry
            zoomSelectorButtons
        }
        .padding(.horizontal, 4)
        .background {
            Capsule().fill(.clear).floatingGlass(in: Capsule(), interactive: true)
        }
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in
            withAnimation(controlAnimation) { showZoomSlider.toggle() }
        })
        .animation(controlAnimation, value: nearestZoomStop)
    }

    private var zoomSelectionGeometry: some View {
        glassControlContainer(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(camera.zoomStops, id: \.self) { stop in
                    ZStack {
                        Color.clear
                        zoomSelectionIndicator(isSelected: nearestZoomStop == stop)
                    }
                    .frame(width: 44, height: 44)
                }
            }
            .frame(height: 48)
        }
        .allowsHitTesting(false)
    }

    private var zoomSelectorButtons: some View {
        HStack(spacing: 2) {
            ForEach(camera.zoomStops, id: \.self) { stop in
                let selected = nearestZoomStop == stop
                Button { camera.setZoom(stop, animated: !reduceMotion) } label: {
                    Text(String(format: selected
                        ? (stop.rounded() == stop ? "%.0f×" : "%.1f×")
                        : (stop.rounded() == stop ? "%.0f" : "%.1f"), stop))
                        .font(.caption.weight(.semibold))
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .lineLimit(1)
                        .minimumScaleFactor(0.3)
                        .foregroundStyle(selected ? .yellow : .white)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Zoom to \(String(format: "%.1f", stop)) times")
                .accessibilityHint("Touch and hold for precise zoom")
            }
        }
        .frame(height: 48)
    }

    @ViewBuilder
    private func zoomSelectionIndicator(isSelected: Bool) -> some View {
        if isSelected {
            if #available(iOS 26.0, *) {
                Circle()
                    .fill(.clear)
                    .frame(width: 34, height: 34)
                    .glassEffect(.regular.tint(.black.opacity(0.55)), in: Circle())
                    .glassEffectID("zoom-selection", in: zoomSelectionNamespace)
            } else {
                Circle()
                    .fill(Color.black.opacity(0.72))
                    .frame(width: 34, height: 34)
                    .matchedGeometryEffect(id: "zoom-selection", in: zoomSelectionNamespace)
            }
        }
    }

    private var fixedLiDARZoomIndicator: some View {
        Text("LiDAR · \(fixedLiDARZoomLabel)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .frame(height: 48)
        .padding(.horizontal, 12)
        .floatingGlass(in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("LiDAR, \(fixedLiDARZoomLabel) zoom")
    }

    @ViewBuilder
    private var previewStatus: some View {
        if let message = previewStatusMessage {
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(camera.errorMessage != nil || server.errorMessage != nil ? .orange : .mint)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .floatingGlass(in: Capsule())
                .frame(maxWidth: .infinity)
                .accessibilityLabel(message)
                .transition(statusTransition)
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("USB")
                    .font(.footnote.weight(.medium))
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Text(server.isUSBConnected ? "Connected" : "Waiting for computer")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if server.isUSBConnected {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            if services.externalDisplayActive {
                Label("HDMI", systemImage: "display")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.mint)
            }
            if server.isRunning, let wifiLinkURL {
                wifiConnectionLink(url: wifiLinkURL)
            }
            if server.isRunning && hdrLinkCount == 1 {
                hdrLinkRows
            } else if server.isRunning && hdrLinkCount > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(controlAnimation) { showConnectionOptions.toggle() }
                    } label: {
                        HStack {
                            Text("Links")
                                .font(.body.weight(.medium))
                            Spacer(minLength: 0)
                            Image(systemName: showConnectionOptions ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .floatingGlass(in: Capsule(), interactive: true)
                    .accessibilityLabel("Links")
                    .accessibilityValue(showConnectionOptions ? "Expanded" : "Collapsed")
                    .accessibilityHint("Shows connection links")

                    if showConnectionOptions {
                        VStack(alignment: .leading, spacing: 8) {
                            hdrLinkRows
                        }
                        .transition(statusTransition)
                    }
                }
                .animation(controlAnimation, value: showConnectionOptions)
            }
            if let message = server.errorMessage ?? camera.errorMessage {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
        }
        .card()
    }

    private var wifiLinkURL: String? {
        guard let wifiAddress = server.addresses.first(where: { $0.interface == "en0" }) else { return nil }
        return "http://\(wifiAddress.ip):\(server.port)/?key=\(server.accessKey)"
    }

    private var hdrLinkCount: Int {
        guard camera.hdrLiveEnabled else { return 0 }
        return server.addresses.isEmpty ? 1 : 2
    }

    @ViewBuilder
    private var hdrLinkRows: some View {
        if let address = server.addresses.first {
            connectionLink("HDR",
                           url: "http://\(address.ip):\(server.port)/hdr.m3u8?key=\(server.accessKey)",
                           id: "hdr")
        }
        connectionLink("USB HDR",
                       url: "http://localhost:\(server.port)/hdr.m3u8?key=\(server.accessKey)",
                       id: "usb-hdr")
    }

    private func connectionLink(_ title: String, url: String, id: String) -> some View {
        let wasCopied = copiedLinkID == id
        return Button {
            copyLink(url, id: id)
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .font(.footnote.weight(.medium))
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Text(wasCopied ? "Copied" : "Copy")
                    Image(systemName: wasCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .floatingGlass(in: Capsule(), interactive: true)
        .accessibilityLabel(wasCopied ? "\(title) link copied" : "Copy \(title) link")
        .accessibilityHint("Copies the connection link")
    }

    private func wifiConnectionLink(url: String) -> some View {
        let wasCopied = copiedLinkID == "camera"
        return HStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("Wi-Fi")
                    .font(.footnote.weight(.medium))
                Button {
                    showWiFiInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About the Wi-Fi link")
                .accessibilityHint("Explains how to open the camera preview")
            }
            Spacer(minLength: 0)
            Button {
                copyLink(url, id: "camera")
            } label: {
                HStack(spacing: 4) {
                    Text(wasCopied ? "Copied" : "Copy")
                    Image(systemName: wasCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(wasCopied ? "Wi-Fi link copied" : "Copy Wi-Fi link")
            .accessibilityHint("Copies the connection link")
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    private func copyLink(_ url: String, id: String) {
        UIPasteboard.general.string = url
        copyFeedbackTask?.cancel()
        copiedLinkID = id
        copyFeedbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, copiedLinkID == id else { return }
            copiedLinkID = nil
        }
    }

    @ViewBuilder
    private var cameraControls: some View {
        Picker("Resolution", selection: Binding<ResolutionSelection>(
            get: {
                camera.customOutputSize != nil || isEditingCustomOutputSize
                    ? .custom
                    : .preset(camera.activeQuality)
            },
            set: { (selection: ResolutionSelection) in
                switch selection {
                case .preset(let quality):
                    isEditingCustomOutputSize = false
                    customOutputError = nil
                    camera.clearCustomOutputSize()
                    selectVideoCamera(lidarEnabled: camera.activeLens == .lidar, quality: quality)
                case .custom:
                    isEditingCustomOutputSize = true
                    customOutputError = nil
                    populateCustomOutputFields()
                }
            }
        )) {
            ForEach(VideoQuality.allCases) { quality in
                Text(quality.displayName).tag(ResolutionSelection.preset(quality))
            }
            Text("Custom…").tag(ResolutionSelection.custom)
        }
        .pickerStyle(.navigationLink)
        .disabled(camera.isRecording)

        if camera.customOutputSize != nil || isEditingCustomOutputSize {
            Section("Custom resolution") {
                HStack(spacing: 10) {
                    TextField("Width", text: $customOutputWidth)
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never)
                        .accessibilityLabel("Custom output width")
                    Text("×").foregroundStyle(.secondary)
                    TextField("Height", text: $customOutputHeight)
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never)
                        .accessibilityLabel("Custom output height")
                }
                .monospacedDigit()

                Button("Apply") { applyCustomOutputSize() }
                    .disabled(camera.isRecording)

                if let customOutputError {
                    Text(customOutputError)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .onAppear { populateCustomOutputFields() }
        }

        if camera.availableLenses.contains(.lidar) {
            Toggle("Turn on LiDAR", isOn: Binding(
                get: { camera.activeLens == .lidar },
                set: { selectVideoCamera(lidarEnabled: $0, quality: camera.activeQuality) }
            ))
            .disabled(camera.isRecording)
        }
    }

    private var cameraUnavailableCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Rear camera unavailable", systemImage: "camera")
                .font(.headline)
            Text("Rocam needs a rear camera.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .card()
    }

    private func selectVideoCamera(lidarEnabled: Bool, quality: VideoQuality) {
        camera.select(lens: lidarEnabled ? .lidar : .automatic, quality: quality)
        camera.setTorch(false)
    }

    private func populateCustomOutputFields() {
        guard customOutputWidth.isEmpty || customOutputHeight.isEmpty else { return }
        let dimensions: (width: Int, height: Int)
        if let custom = camera.customOutputSize {
            dimensions = (custom.width, custom.height)
        } else if let output = camera.currentOutputSize {
            dimensions = (
                Int(min(output.width, output.height).rounded()),
                Int(max(output.width, output.height).rounded())
            )
        } else {
            dimensions = (480, 640)
        }
        customOutputWidth = String(dimensions.width)
        customOutputHeight = String(dimensions.height)
    }

    private func applyCustomOutputSize() {
        guard let width = Int(customOutputWidth), let height = Int(customOutputHeight) else {
            customOutputError = "Enter whole-number width and height values."
            return
        }
        guard (16...4096).contains(width), (16...4096).contains(height),
              width.isMultiple(of: 2), height.isMultiple(of: 2), width <= height,
              width <= 8_000_000 / height else {
            customOutputError = "Use even portrait dimensions from 16 to 4096 pixels, up to 8 MP."
            return
        }
        guard camera.setCustomOutputSize(width: width, height: height) else {
            customOutputError = "Rocam could not apply that output size."
            return
        }
        customOutputError = nil
        isEditingCustomOutputSize = true
    }

    private var zoomPosition: Double {
        let minValue = max(Double(camera.minZoom), 0.1)
        let maxValue = max(Double(camera.maxZoom), minValue + 0.1)
        return min(1, max(0, log(Double(camera.currentZoom) / minValue) / log(maxValue / minValue)))
    }

    private func zoomValue(for position: Double) -> Float {
        let minValue = max(Double(camera.minZoom), 0.1)
        let maxValue = max(Double(camera.maxZoom), minValue + 0.1)
        return Float(minValue * pow(maxValue / minValue, position))
    }

    private func pressVideoShutter() {
        guard camera.isRunning || camera.isRecording else { return }
        services.noteScreenInteraction()
        if camera.isRecording {
            camera.stopRecording()
        } else {
            camera.startRecording()
        }
    }

    private func recordingTime(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.isFinite ? duration : 0))
        if seconds >= 100 * 3_600 { return "99h+" }
        if seconds >= 3_600 {
            return String(format: "%02d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

}

private struct PreviewLayout {
    let previewRect: CGRect
    let headerTopInset: CGFloat
    let headerLeadingInset: CGFloat
    let headerTrailingInset: CGFloat
    let bottomControlsRect: CGRect
    let statusTopInset: CGFloat

    init(
        canvasSize: CGSize,
        safeArea: EdgeInsets,
        outputSize: CGSize?,
        bottomControlStackExtraHeight: CGFloat = 0
    ) {
        let canvas = CGSize(width: max(0, canvasSize.width), height: max(0, canvasSize.height))
        let deliveredAspect = outputSize.flatMap { size -> CGFloat? in
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
            return size.width / size.height
        }
        // The initial canvas-sized viewport avoids inventing an orientation before a
        // frame arrives. Once it does, width and height come directly from the
        // delivered stream, including a deliberate 90°/270° software rotation.
        let fallbackAspect = canvas.height > 0 ? canvas.width / canvas.height : 1
        let aspect = deliveredAspect ?? fallbackAspect
        let size = PreviewLayout.aspectFitSize(aspect: aspect, in: canvas)
        var resolvedPreviewRect = CGRect(
            x: (canvas.width - size.width) / 2,
            y: (canvas.height - size.height) / 2,
            width: size.width,
            height: size.height
        )

        // The bottom row lives entirely in the blurred surround. Preserve the
        // centered aspect-fit viewport whenever it already clears that band;
        // otherwise move it up first, then reduce it only when a very tall
        // output cannot move without leaving the canvas.
        let bottomRowHeight: CGFloat = 48
        let bottomPadding: CGFloat = 12
        let bottomControlTopGap: CGFloat = 12
        let sliderReserve = max(0, bottomControlStackExtraHeight)
        let bottomRowTop = max(0, canvas.height - safeArea.bottom - bottomPadding - bottomRowHeight)
        let sharpPreviewBottomLimit = max(0, bottomRowTop - bottomControlTopGap - sliderReserve)
        if resolvedPreviewRect.maxY > sharpPreviewBottomLimit {
            let upwardShift = min(resolvedPreviewRect.minY, resolvedPreviewRect.maxY - sharpPreviewBottomLimit)
            resolvedPreviewRect.origin.y -= upwardShift
            if resolvedPreviewRect.maxY > sharpPreviewBottomLimit {
                let constrainedSize = PreviewLayout.aspectFitSize(
                    aspect: aspect,
                    in: CGSize(width: canvas.width, height: sharpPreviewBottomLimit)
                )
                resolvedPreviewRect = CGRect(
                    x: (canvas.width - constrainedSize.width) / 2,
                    y: 0,
                    width: constrainedSize.width,
                    height: constrainedSize.height
                )
            }
        }
        previewRect = resolvedPreviewRect
        headerTopInset = max(safeArea.top + 12, previewRect.minY + 12)
        headerLeadingInset = max(safeArea.leading + 12, previewRect.minX + 12)
        headerTrailingInset = max(safeArea.trailing + 12, canvas.width - previewRect.maxX + 12)

        let safeControlWidth = max(0, canvas.width - safeArea.leading - safeArea.trailing - 24)
        // These controls are anchored to the canvas safe area instead of the
        // aspect-fitted frame. Their bottom position stays fixed whether the
        // delivered stream is portrait, landscape, or switches resolution.
        bottomControlsRect = CGRect(
            x: safeArea.leading + 12,
            y: 0,
            width: safeControlWidth,
            height: max(0, canvas.height - safeArea.bottom - bottomPadding)
        )
        statusTopInset = max(62, headerTopInset - previewRect.minY + 56)
    }

    private static func aspectFitSize(aspect: CGFloat, in canvas: CGSize) -> CGSize {
        guard canvas.width > 0, canvas.height > 0, aspect.isFinite, aspect > 0 else { return .zero }
        if canvas.width / canvas.height > aspect {
            return CGSize(width: canvas.height * aspect, height: canvas.height)
        }
        return CGSize(width: canvas.width, height: canvas.width / aspect)
    }
}

private extension View {
    @ViewBuilder
    func glassControlContainer<Content: View>(spacing: CGFloat? = 12, @ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }

    @ViewBuilder
    func floatingGlass<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                glassEffect(interactive ? .regular.tint(tint).interactive() : .regular.tint(tint), in: shape)
            } else {
                glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
            }
        } else {
            if let tint {
                background(.ultraThinMaterial, in: shape)
                    .overlay(shape.fill(tint.opacity(0.18)).allowsHitTesting(false))
            } else {
                background(.ultraThinMaterial, in: shape)
            }
        }
    }

    @ViewBuilder
    func streamActionStyle(tint: Color) -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
                .tint(tint)
        } else {
            buttonStyle(.borderedProminent)
                .tint(tint)
        }
    }

    func card() -> some View {
        self.padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 18))
    }
}

@available(iOS 17.2, *)
private struct HardwareCaptureInteraction: UIViewRepresentable {
    let isEnabled: Bool
    let action: () -> Void

    final class Coordinator {
        var action: () -> Void
        var interaction: AVCaptureEventInteraction?

        init(action: @escaping () -> Void) { self.action = action }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let coordinator = context.coordinator
        let interaction = AVCaptureEventInteraction { [weak coordinator] event in
            if event.phase == .ended { coordinator?.action() }
        }
        view.addInteraction(interaction)
        coordinator.interaction = interaction
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.action = action
        context.coordinator.interaction?.isEnabled = isEnabled
    }
}

private struct CameraPreview: UIViewRepresentable {
    let zoom: Float
    let exposureBias: Float
    let aeAfLocked: Bool
    let outputRect: CGRect
    let matchesRenderedCenterCrop: Bool
    let manualRotationDegrees: Int
    let accessibilityLabel: String
    let onPreviewLayers: (AVCaptureVideoPreviewLayer, AVCaptureVideoPreviewLayer) -> Void
    let onFocus: (CGPoint) -> Void
    let onLock: (CGPoint) -> Void
    let onExposure: (Float) -> Void
    let onZoom: (Float) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.outputRect = outputRect
        view.matchesRenderedCenterCrop = matchesRenderedCenterCrop
        view.manualRotationDegrees = manualRotationDegrees
        onPreviewLayers(view.previewLayer, view.backgroundPreviewLayer)
        view.onFocus = onFocus
        view.onLock = onLock
        view.onExposure = onExposure
        view.onZoom = onZoom
        view.currentZoom = zoom
        view.currentExposure = exposureBias
        view.aeAfLocked = aeAfLocked
        view.accessibilityLabel = accessibilityLabel
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.outputRect = outputRect
        uiView.matchesRenderedCenterCrop = matchesRenderedCenterCrop
        uiView.manualRotationDegrees = manualRotationDegrees
        uiView.onFocus = onFocus
        uiView.onLock = onLock
        uiView.onExposure = onExposure
        uiView.onZoom = onZoom
        uiView.currentZoom = zoom
        uiView.currentExposure = exposureBias
        uiView.aeAfLocked = aeAfLocked
        uiView.accessibilityLabel = accessibilityLabel
    }
}

private final class PreviewView: UIView, UIGestureRecognizerDelegate {
    let backgroundPreviewLayer = AVCaptureVideoPreviewLayer()
    let previewLayer = AVCaptureVideoPreviewLayer()
    // The extension is deliberately a separate composited layer.  Its mask
    // removes the delivered-output rectangle, so neither the blur nor its
    // dimmer can ever sit over the image the camera is recording.
    private let surroundBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let surroundDimView = UIView()
    private let sharpViewport = UIView()
    var outputRect: CGRect = .zero {
        didSet { setNeedsLayout() }
    }
    /// Custom SDR output is centre-cropped before it is encoded. Use the same
    /// fill geometry in the sharp viewport so the phone and computer frame the
    /// same pixels; ordinary output keeps its full aspect-fit preview.
    var matchesRenderedCenterCrop = false {
        didSet {
            previewLayer.videoGravity = matchesRenderedCenterCrop ? .resizeAspectFill : .resizeAspect
            setNeedsLayout()
        }
    }
    var manualRotationDegrees = 0 {
        didSet { setNeedsLayout() }
    }
    var onFocus: ((CGPoint) -> Void)?
    var onLock: ((CGPoint) -> Void)?
    var onExposure: ((Float) -> Void)?
    var onZoom: ((Float) -> Void)?
    var currentZoom: Float = 1
    var currentExposure: Float = 0
    var aeAfLocked = false {
        didSet {
            lockLabel.isHidden = !aeAfLocked
            if aeAfLocked { focusRing.alpha = 1; exposureHandle.alpha = 1 }
        }
    }
    private var pinchStartZoom: Float = 1
    private var panStartExposure: Float = 0
    private let focusRing = UIView(frame: CGRect(x: 0, y: 0, width: 68, height: 68))
    private let exposureHandle = UIImageView(image: UIImage(systemName: "sun.max.fill"))
    private let exposureValueLabel = UILabel()
    private let lockLabel = UILabel()
    private var focusGeneration = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .image
        backgroundPreviewLayer.videoGravity = .resizeAspectFill
        previewLayer.videoGravity = .resizeAspect
        layer.addSublayer(backgroundPreviewLayer)
        surroundBlurView.isUserInteractionEnabled = false
        addSubview(surroundBlurView)
        surroundDimView.isUserInteractionEnabled = false
        surroundDimView.backgroundColor = UIColor.black.withAlphaComponent(0.42)
        addSubview(surroundDimView)
        sharpViewport.clipsToBounds = true
        sharpViewport.isUserInteractionEnabled = false
        addSubview(sharpViewport)
        sharpViewport.layer.addSublayer(previewLayer)
        focusRing.isUserInteractionEnabled = false
        focusRing.layer.borderColor = UIColor.systemYellow.cgColor
        focusRing.layer.borderWidth = 2
        focusRing.layer.cornerRadius = 6
        focusRing.alpha = 0
        sharpViewport.addSubview(focusRing)
        exposureHandle.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        exposureHandle.contentMode = .center
        exposureHandle.tintColor = .systemYellow
        exposureHandle.isUserInteractionEnabled = false
        exposureHandle.alpha = 0
        exposureHandle.accessibilityLabel = "Adjust exposure"
        sharpViewport.addSubview(exposureHandle)
        exposureValueLabel.frame.size = CGSize(width: 72, height: 22)
        exposureValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        exposureValueLabel.textColor = .systemYellow
        exposureValueLabel.textAlignment = .center
        exposureValueLabel.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        exposureValueLabel.layer.cornerRadius = 5
        exposureValueLabel.layer.masksToBounds = true
        exposureValueLabel.isHidden = true
        sharpViewport.addSubview(exposureValueLabel)
        lockLabel.text = "AE/AF LOCK"
        lockLabel.textColor = .systemYellow
        lockLabel.font = .systemFont(ofSize: 12, weight: .bold)
        lockLabel.textAlignment = .center
        lockLabel.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        lockLabel.layer.cornerRadius = 6
        lockLabel.layer.masksToBounds = true
        lockLabel.frame.size = CGSize(width: 92, height: 24)
        lockLabel.isHidden = true
        sharpViewport.addSubview(lockLabel)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.5
        let exposurePan = UIPanGestureRecognizer(target: self, action: #selector(draggedExposure(_:)))
        tap.delegate = self
        hold.delegate = self
        exposurePan.delegate = self
        tap.require(toFail: hold)
        addGestureRecognizer(tap)
        addGestureRecognizer(hold)
        addGestureRecognizer(exposurePan)
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
    }

    required init?(coder: NSCoder) { fatalError("Storyboard initialization is unsupported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        sharpViewport.frame = outputRect
        let viewport = outputRect.intersection(bounds)
        let shouldBlur = !viewport.isNull && !viewport.isEmpty && !viewport.equalTo(bounds)
        backgroundPreviewLayer.isHidden = !shouldBlur
        surroundBlurView.isHidden = !shouldBlur
        surroundDimView.isHidden = !shouldBlur
        if shouldBlur {
            surroundBlurView.frame = bounds
            surroundDimView.frame = bounds
            applySurroundMask(excluding: viewport, to: surroundBlurView)
            applySurroundMask(excluding: viewport, to: surroundDimView)
        } else {
            surroundBlurView.layer.mask = nil
            surroundDimView.layer.mask = nil
        }
        let isQuarterTurn = manualRotationDegrees == 90 || manualRotationDegrees == 270
        let backgroundSize = isQuarterTurn
            ? CGSize(width: bounds.height, height: bounds.width)
            : bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundPreviewLayer.bounds = CGRect(origin: .zero, size: backgroundSize)
        backgroundPreviewLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        backgroundPreviewLayer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(manualRotationDegrees) * .pi / 180))
        let sharpBounds = sharpViewport.bounds
        let unrotatedSize = isQuarterTurn
            ? CGSize(width: sharpBounds.height, height: sharpBounds.width)
            : sharpBounds.size
        previewLayer.bounds = CGRect(origin: .zero, size: unrotatedSize)
        previewLayer.position = CGPoint(x: sharpBounds.midX, y: sharpBounds.midY)
        previewLayer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(manualRotationDegrees) * .pi / 180))
        CATransaction.commit()
        lockLabel.center = CGPoint(x: sharpBounds.midX, y: sharpViewport.safeAreaInsets.top + 26)
    }

    private func applySurroundMask(excluding viewport: CGRect, to view: UIView) {
        let path = UIBezierPath(rect: view.bounds)
        // Expand the opening by one physical point. This keeps the actual
        // preview crisp right up to its edge even when Core Animation rounds
        // an aspect-fit rectangle onto device pixels.
        path.append(UIBezierPath(rect: viewport.insetBy(dx: -1, dy: -1)))
        let mask = CAShapeLayer()
        mask.frame = view.bounds
        mask.path = path.cgPath
        mask.fillRule = .evenOdd
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer.mask = mask
        CATransaction.commit()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // The blurred extension only supplies context. Camera gestures always map
        // to the sharp delivered-output viewport.
        sharpViewport.frame.contains(point)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UIPinchGestureRecognizer {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        guard exposureHandle.alpha > 0.01 else { return !(gestureRecognizer is UIPanGestureRecognizer) }
        let area = exposureHandle.frame.insetBy(dx: -8, dy: -8)
        if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            let position = pan.location(in: sharpViewport)
            let translation = pan.translation(in: sharpViewport)
            return area.contains(CGPoint(x: position.x - translation.x, y: position.y - translation.y))
        }
        return !area.contains(gestureRecognizer.location(in: sharpViewport))
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: sharpViewport)
        let layerLocation = previewLayer.convert(location, from: sharpViewport.layer)
        onFocus?(previewLayer.captureDevicePointConverted(fromLayerPoint: layerLocation))
        showFocus(at: location)
    }

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let location = gesture.location(in: sharpViewport)
        let layerLocation = previewLayer.convert(location, from: sharpViewport.layer)
        onLock?(previewLayer.captureDevicePointConverted(fromLayerPoint: layerLocation))
        showFocus(at: location)
    }

    private func showFocus(at location: CGPoint) {
        focusGeneration += 1
        let generation = focusGeneration
        focusRing.layer.removeAllAnimations()
        focusRing.center = CGPoint(x: min(max(location.x, 42), sharpViewport.bounds.maxX - 42),
                                   y: min(max(location.y, 42), sharpViewport.bounds.maxY - 42))
        let handleOffset: CGFloat = focusRing.center.x > sharpViewport.bounds.midX ? -54 : 54
        exposureHandle.center = CGPoint(x: focusRing.center.x + handleOffset, y: focusRing.center.y)
        exposureValueLabel.center = CGPoint(x: exposureHandle.center.x, y: exposureHandle.center.y + 34)
        exposureValueLabel.isHidden = true
        focusRing.alpha = 1
        exposureHandle.alpha = 1
        if UIAccessibility.isReduceMotionEnabled {
            focusRing.transform = .identity
        } else {
            focusRing.transform = CGAffineTransform(scaleX: 1.25, y: 1.25)
            UIView.animate(withDuration: 0.2) { self.focusRing.transform = .identity }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self, self.focusGeneration == generation, !self.aeAfLocked else { return }
            let hide = {
                self.focusRing.alpha = 0
                self.exposureHandle.alpha = 0
            }
            if UIAccessibility.isReduceMotionEnabled {
                hide()
            } else {
                UIView.animate(withDuration: 0.25, animations: hide)
            }
        }
    }

    @objc private func draggedExposure(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { panStartExposure = currentExposure }
        if gesture.state == .began || gesture.state == .changed {
            let adjusted = min(3, max(-3, panStartExposure - Float(gesture.translation(in: self).y / 80)))
            currentExposure = adjusted
            exposureValueLabel.text = String(format: "EV %+.1f", adjusted)
            exposureValueLabel.isHidden = false
            onExposure?(adjusted)
        }
        if gesture.state == .ended || gesture.state == .cancelled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.exposureValueLabel.isHidden = true
            }
        }
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began { pinchStartZoom = currentZoom }
        if gesture.state == .began || gesture.state == .changed {
            onZoom?(pinchStartZoom * Float(gesture.scale))
        }
    }
}
