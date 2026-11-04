import SwiftUI
import UIKit
import AVFoundation

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var gestureProcessor = GestureProcessor()
    @StateObject private var tvRemote = AppleTVRemote()
    @StateObject private var ipCameraManager = IPCameraManager()
    @StateObject private var cameraDiscovery = IPCameraDiscovery()
    // @State, not @StateObject: the tracker publishes often and only the status card should redraw.
    @State private var lidarTracker = LiDARHandTracker()
    @Environment(\.scenePhase) private var scenePhase

    @State private var showDebugLog = false  // hidden by default, toggle with terminal button
    @State private var showManualEntry = false
    @State private var manualHost = ""
    @State private var manualPort = "49152"
    @State private var pinInput = ""
    @State private var liveExperienceStarted = false
    @State private var scanningTooLong = false
    @State private var useIPCamera = false
    @State private var showIPCameraEntry = false
    @AppStorage("ipCameraURL") private var savedIPCameraURL = ""
    @State private var ipCameraURLInput = ""
    // On by default wherever LiDAR mode is supported; the cube turns it off for this session.
    @State private var lidarModeEnabled = LiDARSupport.isSupported

    /// LiDAR mode needs a supported iPhone and the built-in camera.
    private var lidarModeRequested: Bool {
        lidarModeEnabled && LiDARSupport.isSupported && !useIPCamera
    }

    private var activeGesture: Gesture {
        gestureProcessor.currentGesture
    }

    var body: some View {
        ZStack {
            // No camera image: black screen with the tracked hand drawn on it.
            Color.black.ignoresSafeArea()
            HandSkeletonView(
                store: gestureProcessor.skeleton,
                mirrored: cameraManager.useFrontCamera && !cameraManager.isLiDARActive && !useIPCamera,
                tint: gestureProcessor.isAwake ? .green : .white
            )

            if useIPCamera && ipCameraManager.currentFrame == nil {
                VStack(spacing: 16) {
                    if ipCameraManager.isConnecting {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(2)
                            .tint(.white)
                        Text("Connecting to IP camera…")
                            .font(.headline)
                            .foregroundColor(.white.opacity(0.8))
                    } else if let err = ipCameraManager.errorMessage {
                        Image(systemName: "network.slash")
                            .font(.system(size: 48))
                            .foregroundColor(.white.opacity(0.6))
                        Text(err)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    } else {
                        Image(systemName: "network")
                            .font(.system(size: 48))
                            .foregroundColor(.white.opacity(0.4))
                        Text("No IP camera connected")
                            .font(.headline)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
            }

            if !cameraManager.sessionRunning && !cameraManager.permissionDenied && !useIPCamera {
                Color.black.ignoresSafeArea()
                VStack(spacing: 20) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(2)
                        .tint(.white)
                    Text("Starting camera…")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.8))
                }
            }

            // Camera permission denied overlay
            if cameraManager.permissionDenied {
                Color.black.ignoresSafeArea()
                VStack(spacing: 16) {
                    Image(systemName: "camera.slash.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.white.opacity(0.7))
                    Text("Camera Access Required")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    Text("GestureRemote needs camera access to detect hand gestures.")
                        .font(.body)
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            VStack(spacing: 0) {
                // Top bar
                    HStack(spacing: 2) {
                    // Large connection status dot
                        connectionDot

                        Spacer()

                        Button {
                            NotificationCenter.default.post(name: .showGestureSlides, object: nil)
                        } label: {
                            Image(systemName: "play.rectangle.on.rectangle").foregroundColor(.white)
                                .topBarButtonFrame()
                        }

                        Button {
                            if useIPCamera {
                                // Disconnect and switch back to device camera
                                ipCameraManager.disconnect()
                                useIPCamera = false
                                cameraManager.startSession()
                            } else {
                                // Show URL entry to connect to IP camera
                                ipCameraURLInput = savedIPCameraURL
                                cameraDiscovery.suppressSubnetScan = tvRemote.isConnected || tvRemote.isConnecting
                                showIPCameraEntry = true
                            }
                        } label: {
                            Image(systemName: useIPCamera ? "network.slash" : "network")
                                .foregroundColor(useIPCamera ? .orange : .white)
                                .topBarButtonFrame()
                        }

                        if LiDARSupport.isSupported {
                            Button {
                                lidarModeEnabled.toggle()
                            } label: {
                                Image(systemName: lidarModeEnabled ? "cube.transparent.fill" : "cube.transparent")
                                    .foregroundColor(useIPCamera ? .white.opacity(0.3) : (lidarModeEnabled ? .orange : .white))
                                    .topBarButtonFrame()
                            }
                            .disabled(useIPCamera)
                            .accessibilityLabel(lidarModeEnabled ? "Turn off LiDAR mode" : "Turn on LiDAR mode")
                        }

                        Button {
                            if !useIPCamera {
                                cameraManager.switchCamera()
                                gestureProcessor.isFrontCamera = !cameraManager.useFrontCamera
                            }
                        } label: {
                            Image(systemName: "camera.rotate")
                                .foregroundColor(useIPCamera || cameraManager.isLiDARActive ? .white.opacity(0.3) : .white)
                                .topBarButtonFrame()
                        }
                        .disabled(useIPCamera || cameraManager.isLiDARActive)

                        // Zoom controls
                        Button {
                            cameraManager.zoomOut()
                        } label: {
                            Image(systemName: "minus.magnifyingglass")
                                .foregroundColor(cameraManager.isLiDARActive ? .white.opacity(0.3) : .white)
                                .topBarButtonFrame()
                        }
                        .disabled(cameraManager.isLiDARActive)
                        
                        Text(String(format: "%.1f×", cameraManager.zoomFactor))
                            .font(.caption.monospaced())
                            .foregroundColor(.white)
                            .frame(width: 34)
                        
                        Button {
                            cameraManager.zoomIn()
                        } label: {
                            Image(systemName: "plus.magnifyingglass")
                                .foregroundColor(cameraManager.isLiDARActive ? .white.opacity(0.3) : .white)
                                .topBarButtonFrame()
                        }
                        .disabled(cameraManager.isLiDARActive)
                        
                        Button { showDebugLog.toggle() } label: {
                            Image(systemName: "terminal").foregroundColor(.white)
                                .topBarButtonFrame()
                        }

                    }
                    .padding(.horizontal, 10)
                    .background(Color.clear)

                    // Debug log
                    if showDebugLog {
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(cameraManager.statusLog.enumerated()), id: \.offset) { i, line in
                                        Text("CAM: " + line)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.yellow)
                                            .id("cam\(i)")
                                    }
                                    ForEach(Array(tvRemote.debugLog.enumerated()), id: \.offset) { i, line in
                                        Text(line)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.green)
                                            .id(i)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                            }
                            .frame(height: 180)
                            .background(Color.black)
                            .onChange(of: tvRemote.debugLog.count) { _, _ in
                                if let last = tvRemote.debugLog.indices.last {
                                    proxy.scrollTo(last)
                                }
                            }
                        }
                    }

                    Spacer()

                    // Device controls
                    VStack(spacing: 10) {
                        if tvRemote.discoveredDevices.isEmpty {
                            VStack(spacing: 4) {
                                Text("Scanning for Apple TVs…")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.8))
                                if scanningTooLong {
                                    Button(action: {
                                        if let url = URL(string: UIApplication.openSettingsURLString) {
                                            UIApplication.shared.open(url)
                                        }
                                    }) {
                                        Text("No Apple TV found — check Local Network permission in Settings")
                                            .font(.caption2)
                                            .foregroundColor(.orange)
                                            .multilineTextAlignment(.center)
                                    }
                                }
                            }
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(tvRemote.discoveredDevices) { device in
                                        Button(device.name) {
                                            tvRemote.connect(to: device)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(tvRemote.connectedDevice?.id == device.id ? .blue : .gray)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }

                        HStack(spacing: 12) {
                            Button("Rescan") { tvRemote.rescan() }
                                .buttonStyle(.bordered).tint(.white)
                            Button("Manual IP") { showManualEntry.toggle() }
                                .buttonStyle(.bordered).tint(.white)
                        }

                        if showManualEntry {
                            HStack {
                                TextField("Apple TV IP", text: $manualHost)
                                    .textFieldStyle(.roundedBorder)
                                    .keyboardType(.decimalPad)
                                    .frame(width: 150)
                                TextField("Port", text: $manualPort)
                                    .textFieldStyle(.roundedBorder)
                                    .keyboardType(.numberPad)
                                    .frame(width: 70)
                                Button("Connect") {
                                    tvRemote.connectManually(host: manualHost, port: Int(manualPort) ?? 49152)
                                    showManualEntry = false
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.bottom, 40)
                    .padding(.top, 10)
                        .background(Color.clear)
            }

            // PIN dialog overlay
            if tvRemote.needsPIN {
                PINEntryView(pin: $pinInput) { pin in
                    tvRemote.submitPIN(pin)
                    pinInput = ""
                }
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                gestureStatusCard
                lidarStatusCard
            }
            .padding(.top, 84)
        }
        .onAppear {
            print("ContentView: onAppear fired")
            startLiveExperience()
        }
        .onDisappear {
            // Only stop if the view is truly going away, not just covered by a sheet
            if !showIPCameraEntry {
                stopLiveExperience()
            }
        }
        .onChange(of: gestureProcessor.currentGesture) { _, gesture in
            tvRemote.send(gesture: gesture)
        }
        .onChange(of: lidarModeRequested) { _, enabled in
            cameraManager.setLiDARMode(enabled)
            if !enabled { lidarTracker.reset() }
        }
        .onChange(of: cameraManager.isLiDARActive) { _, active in
            gestureProcessor.setLiDARControls(active)
        }
        .onChange(of: tvRemote.isKeyboardActive) { _, active in
            lidarTracker.setKeyboardActive(active)
        }

        .onReceive(cameraManager.sampleBufferPublisher) { buffer in
            if !useIPCamera {
                gestureProcessor.process(sampleBuffer: buffer)
            }
        }
        .onReceive(ipCameraManager.framePublisher) { pixelBuffer in
            if useIPCamera {
                gestureProcessor.process(pixelBuffer: pixelBuffer)
            }
        }
        .sheet(isPresented: $showIPCameraEntry) {
            IPCameraEntryView(
                urlText: $ipCameraURLInput,
                discoveryManager: cameraDiscovery
            ) { url in
                savedIPCameraURL = url
                cameraDiscovery.stopDiscovery()
                showIPCameraEntry = false
                cameraManager.stopSession()
                useIPCamera = true
                ipCameraManager.connect(to: url)
            } onCancel: {
                cameraDiscovery.stopDiscovery()
                showIPCameraEntry = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                startLiveExperience()
            } else if phase == .background {
                // Only fully stop on background — .inactive fires for notifications,
                // control-center, etc. and would cancel the subnet-scan timer repeatedly.
                stopLiveExperience()
            }
        }
    }

    private func startLiveExperience() {
        guard !liveExperienceStarted else { return }
        liveExperienceStarted = true
        scanningTooLong = false
        configureDeviceBehaviorForLiveExperience(isActive: true)
        gestureProcessor.isFrontCamera = cameraManager.useFrontCamera
        configureLiDARTracker()
        cameraManager.setLiDARMode(lidarModeRequested)
        cameraManager.startSession()
        tvRemote.startDiscovery()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [self] in
            if tvRemote.discoveredDevices.isEmpty && !tvRemote.isConnected {
                scanningTooLong = true
            }
        }
    }

    private func configureLiDARTracker() {
        let gestures = gestureProcessor
        let remote = tvRemote
        let camera = cameraManager
        // Flash on the back: once on wake, twice on sleep.
        gestures.onAwakeChanged = { awake in camera.pulseTorch(count: awake ? 1 : 2) }
        gestures.onImmediateGesture = { remote.sendPointer(gesture: $0) }
        lidarTracker.onHandPose = { gestures.process(pose: $0) }
        lidarTracker.onPointerGesture = { remote.sendPointer(gesture: $0) }
        lidarTracker.isGestureAwake = { gestures.isAwake }
        lidarTracker.onActivity = { gestures.noteActivity() }
        gestures.setLiDARControls(cameraManager.isLiDARActive)
        lidarTracker.onDoublePinch = { gestures.setAwake(false) }
        lidarTracker.setKeyboardActive(tvRemote.isKeyboardActive)
        let tracker = lidarTracker
        cameraManager.depthFrameHandler = { tracker.process($0) }
    }

    private func stopLiveExperience() {
        liveExperienceStarted = false
        scanningTooLong = false
        configureDeviceBehaviorForLiveExperience(isActive: false)
        cameraManager.stopSession()
        ipCameraManager.disconnect()
        tvRemote.stopDiscovery()
    }

    private func configureDeviceBehaviorForLiveExperience(isActive: Bool) {
        UIApplication.shared.isIdleTimerDisabled = isActive

        if UIDevice.current.isProximityMonitoringEnabled {
            UIDevice.current.isProximityMonitoringEnabled = false
        }
    }

    private var connectionDot: some View {
        let color: Color = tvRemote.isConnected
            ? .green
            : (tvRemote.isConnecting || tvRemote.isPairing ? .orange : .red)
        let label = tvRemote.isConnected
            ? tvRemote.connectedDeviceName
            : (tvRemote.isPairing ? "Pairing…" : tvRemote.isConnecting ? "Connecting…" : "Not connected")
        return HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 22, height: 22)
                .shadow(color: color.opacity(0.7), radius: 6)
                .animation(.easeInOut(duration: 0.4), value: color)
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.white)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var lidarStatusCard: some View {
        if cameraManager.isLiDARActive && !useIPCamera {
            LiDARStatusCard(tracker: lidarTracker, keyboardActive: tvRemote.isKeyboardActive)
        } else if tvRemote.isKeyboardActive && LiDARSupport.isSupported && !useIPCamera {
            Text("TV keyboard open · tap the cube to type with your finger")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.8))
                .cornerRadius(12)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var gestureStatusCard: some View {
        if !gestureProcessor.isAwake {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.black)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hold up your palm")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.black)
                    Text("to wake gestures")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.black)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(red: 1.0, green: 0.96, blue: 0.2))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.black, lineWidth: 1)
            )
            .cornerRadius(12)
            .allowsHitTesting(false)
        } else if activeGesture != .none {
            HStack(spacing: 12) {
                Image(systemName: activeGesture.iconName)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.black)
                Text(activeGesture.displayName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.black)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(red: 1.0, green: 1.0, blue: 0.2))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.black, lineWidth: 1)
            )
            .cornerRadius(12)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Top bar

private extension View {
    /// Small SF Symbols are only tappable inside the glyph; give each top-bar icon a full tap target.
    func topBarButtonFrame() -> some View {
        frame(width: 30, height: 44).contentShape(Rectangle())
    }
}

// MARK: - LiDAR Status

/// Observes the tracker on its own so frequent LiDAR updates only redraw this card.
struct LiDARStatusCard: View {
    @ObservedObject var tracker: LiDARHandTracker
    var keyboardActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: tracker.isPointerActive ? "hand.point.up.left.fill" : (keyboardActive ? "keyboard" : "cube.transparent"))
                .font(.system(size: 20, weight: .bold))
            VStack(alignment: .leading, spacing: 2) {
                if tracker.isPointerActive {
                    Text(keyboardActive ? "Typing" : "Pointer")
                        .font(.system(size: 16, weight: .bold))
                    Text(keyboardActive ? "Move hand to pick a key · pinch to type" : "Move palm to move · pinch to select")
                        .font(.system(size: 12, weight: .semibold))
                } else {
                    Text(tracker.handDistance.map { String(format: "LiDAR + camera · hand %.1f m", $0) } ?? "LiDAR + camera")
                        .font(.system(size: 16, weight: .bold))
                    Text(keyboardActive
                         ? "TV keyboard open · open palm to point, pinch to type"
                         : (tracker.handDistance == nil ? "Looking for the nearest hand" : "Tracking nearest hand"))
                        .font(.system(size: 12, weight: .semibold))
                }
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(tracker.isPointerActive ? 0.95 : 0.8))
        .cornerRadius(12)
        .allowsHitTesting(false)
    }
}

// MARK: - PIN Entry

struct PINEntryView: View {
    @Binding var pin: String
    let onSubmit: (String) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 20) {
                Text("Enter Apple TV PIN")
                    .font(.title2.bold())
                    .foregroundColor(.white)
                Text("Look at the PIN shown on your Apple TV screen")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                TextField("4-digit PIN", text: $pin)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .frame(width: 120)
                    .multilineTextAlignment(.center)
                    .font(.title)
                Button("Confirm") {
                    guard pin.count == 4 else { return }
                    onSubmit(pin)
                }
                .buttonStyle(.borderedProminent)
                .disabled(pin.count != 4)
            }
            .padding(32)
            .background(Color(white: 0.15).cornerRadius(20))
        }
    }
}

// MARK: - IP Camera URL Entry

struct IPCameraEntryView: View {
    @Binding var urlText: String
    let discoveryManager: IPCameraDiscovery
    let onConnect: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                // Quick scan section
                Section {
                    if discoveryManager.isScanning {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text(discoveryManager.statusMessage)
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                    } else {
                        Button(action: {
                            discoveryManager.startDiscovery()
                        }) {
                            HStack {
                                Image(systemName: "waveform.circle.fill")
                                Text("Scan for Cameras")
                                    .font(.body.weight(.medium))
                                Spacer()
                            }
                        }
                        .foregroundColor(.blue)

                        if !discoveryManager.statusMessage.isEmpty && !discoveryManager.isScanning {
                            Text(discoveryManager.statusMessage)
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                } header: {
                    Text("Auto Discovery")
                }

                // Discovered cameras list
                if !discoveryManager.discoveredCameras.isEmpty {
                    Section {
                        ForEach(discoveryManager.discoveredCameras) { camera in
                            Button(action: {
                                urlText = camera.streamURL
                            }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(camera.name)
                                        .font(.body.weight(.medium))
                                        .foregroundColor(.primary)
                                    Text(camera.streamURL)
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                        .lineLimit(1)
                                }
                            }
                        }
                    } header: {
                        Text("Found Cameras")
                    }
                }

                // Manual entry section
                Section {
                    TextField("e.g. http://192.168.1.100/mjpeg", text: $urlText)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Manual URL")
                } footer: {
                    Text("If auto-discovery doesn't find your camera, enter the MJPEG stream URL manually.")
                }
            }
            .navigationTitle("IP Camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        onConnect(urlText)
                    }
                    .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
