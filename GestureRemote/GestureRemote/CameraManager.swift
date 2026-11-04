import AVFoundation
import Combine
import UIKit

final class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureDataOutputSynchronizerDelegate {

    private enum PersistenceKeys {
        static let useFrontCamera = "camera.useFrontCamera"
        static let frontZoomFactor = "camera.frontZoomFactor"
        static let backZoomFactor = "camera.backZoomFactor"
    }

    let session = AVCaptureSession()
    private var videoOutput = AVCaptureVideoDataOutput()
    private var depthOutput: AVCaptureDepthDataOutput?
    private var depthSynchronizer: AVCaptureDataOutputSynchronizer?
    private let depthQueue = DispatchQueue(label: "camera.depth.queue", qos: .userInteractive)
    /// LiDAR mode frames, delivered on the depth queue. While LiDAR is active, `sampleBufferPublisher` is silent.
    var depthFrameHandler: ((DepthFrame) -> Void)?
    private var lidarModeRequested = false     // session queue only
    private var lidarHorizontalFOV: Float = 70
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let bufferSubject = PassthroughSubject<CMSampleBuffer, Never>()
    private var isConfigured = false
    private var shouldBeRunning = false
    private var cameraPosition: AVCaptureDevice.Position = .front
    private var healthCheckTimer: Timer?
    private var healthCheckAttempts = 0
    private let preferredFrontCameraZoomFactor: CGFloat = 1.0
    private let preferredBackCameraZoomFactor: CGFloat = 1.0

    @Published var statusLog: [String] = []
    @Published var permissionDenied = false
    @Published var sessionRunning = false
    @Published var useFrontCamera = true {  // set on main thread only
        didSet { cameraPosition = useFrontCamera ? .front : .back }
    }
    @Published var zoomFactor: CGFloat = 1.0
    /// True while the rear LiDAR camera is delivering synchronized depth.
    @Published private(set) var isLiDARActive = false
    
    private var captureDevice: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservations: [NSKeyValueObservation] = []

    var sampleBufferPublisher: AnyPublisher<CMSampleBuffer, Never> {
        bufferSubject.eraseToAnyPublisher()
    }

    private func log(_ msg: String) {
        print("[CameraManager] \(msg)")
        DispatchQueue.main.async { self.statusLog.append(msg) }
    }

    override init() {
        super.init()

        let defaults = UserDefaults.standard
        let restoredUseFrontCamera = defaults.object(forKey: PersistenceKeys.useFrontCamera) as? Bool ?? true
        useFrontCamera = restoredUseFrontCamera
        cameraPosition = restoredUseFrontCamera ? .front : .back
        zoomFactor = restoredZoomFactor(forFrontCamera: restoredUseFrontCamera)

        log("init")
        log("restored camera=\(useFrontCamera ? "front" : "back") zoom=\(zoomFactor)")
        // Device orientation events drive the rotation coordinator's horizon-level angles.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        // Restart camera when app returns to foreground (iOS interrupts session on background)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionRuntimeError),
            name: .AVCaptureSessionRuntimeError,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionInterruptionEnded),
            name: .AVCaptureSessionInterruptionEnded,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionWasInterrupted),
            name: .AVCaptureSessionWasInterrupted,
            object: session
        )
    }

    deinit {
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Torch

    /// A short, dim pulse of the back flashlight, so the user can see from across the room that
    /// their hand was picked up. Back cameras only (the front camera has no torch).
    /// Level 0.001: the torch only accepts levels above 0, and the hardware rounds this up to its
    /// dimmest step.
    func pulseTorch(level: Float = 0.001, duration: TimeInterval = 0.15, count: Int = 1) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice,
                  device.hasTorch, device.isTorchModeSupported(.on) else { return }
            do {
                try device.lockForConfiguration()
                try device.setTorchModeOn(level: level)
                device.unlockForConfiguration()
            } catch {
                return
            }
            self.sessionQueue.asyncAfter(deadline: .now() + duration) {
                guard (try? device.lockForConfiguration()) != nil else { return }
                device.torchMode = .off
                device.unlockForConfiguration()
                if count > 1 {
                    self.sessionQueue.asyncAfter(deadline: .now() + duration) {
                        self.pulseTorch(level: level, duration: duration, count: count - 1)
                    }
                }
            }
        }
    }

    // MARK: - Rotation

    /// Hard-coded angles ("portrait = 90°") assume a landscape-mounted sensor, which is wrong for
    /// cameras like the iPhone 17 front camera. The coordinator reports the correct angle per device
    /// for the frames handed to Vision (upright buffers).
    private func setUpRotationCoordinator(for device: AVCaptureDevice) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.setUpRotationCoordinator(for: device) }
            return
        }
        rotationObservations.removeAll()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator

        rotationObservations.append(coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            self?.sessionQueue.async {
                guard let connection = self?.videoOutput.connection(with: .video),
                      connection.isVideoRotationAngleSupported(angle) else { return }
                connection.videoRotationAngle = angle
            }
        })
        log("rotation coordinator for \(device.localizedName): capture \(coordinator.videoRotationAngleForHorizonLevelCapture)°")
    }

    @objc private func appDidBecomeActive() {
        guard shouldBeRunning else { return }
        // Don't try to start without authorization — startSession already handles the first auth
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured { self.configureSession() }
            guard !self.session.isRunning else { return }
            self.log("resuming after foreground")
            self.session.startRunning()
            let running = self.session.isRunning
            self.log("resumed, isRunning=\(running)")
            DispatchQueue.main.async { self.sessionRunning = running }
        }
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
        log("RUNTIME ERROR: \(error?.localizedDescription ?? "unknown")")
        DispatchQueue.main.async { self.sessionRunning = false }
        guard shouldBeRunning else { return }
        // Reset isConfigured so the session is fully rebuilt on retry
        isConfigured = false
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.shouldBeRunning else { return }
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
            self.sessionQueue.async {
                if !self.isConfigured { self.configureSession() }
                self.log("retrying after runtime error")
                self.session.startRunning()
                let running = self.session.isRunning
                self.log("retry isRunning=\(running)")
                DispatchQueue.main.async { self.sessionRunning = running }
            }
        }
    }

    @objc private func sessionWasInterrupted(_ notification: Notification) {
        let reason = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
        log("interrupted reason=\(reason ?? -1)")
        DispatchQueue.main.async { self.sessionRunning = false }
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        log("interruption ended")
        guard shouldBeRunning else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured { self.configureSession() }
            self.session.startRunning()
            let running = self.session.isRunning
            self.log("interruption resume, isRunning=\(running)")
            DispatchQueue.main.async { self.sessionRunning = running }
        }
    }

    func startSession() {
        log("startSession auth=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
        shouldBeRunning = true
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            self.log("permission granted=\(granted)")
            guard granted else {
                DispatchQueue.main.async { self.permissionDenied = true }
                return
            }
            self.sessionQueue.async {
                if !self.isConfigured {
                    self.configureSession()
                }
                guard !self.session.isRunning else {
                    self.log("already running")
                    return
                }
                self.log("startRunning")
                self.session.startRunning()
                let running = self.session.isRunning
                self.log("session.isRunning=\(running)")
                DispatchQueue.main.async {
                    self.sessionRunning = running
                    self.startHealthCheck()
                }
            }
        }
    }

    /// Fires every 2 s until session is confirmed running (max 10 attempts).
    private func startHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckAttempts = 0
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.shouldBeRunning else { self.healthCheckTimer?.invalidate(); return }
            if self.session.isRunning {
                self.log("health OK")
                self.healthCheckTimer?.invalidate()
                return
            }
            self.healthCheckAttempts += 1
            self.log("health check #\(self.healthCheckAttempts) — session not running, restarting")
            if self.healthCheckAttempts > 10 {
                self.log("health check gave up after 10 attempts")
                self.healthCheckTimer?.invalidate()
                return
            }
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                self.log("health check: waiting for authorization")
                return
            }
            self.isConfigured = false
            self.sessionQueue.async { [weak self] in
                guard let self, self.shouldBeRunning else { return }
                if !self.isConfigured { self.configureSession() }
                self.session.startRunning()
                let running = self.session.isRunning
                self.log("health restart, isRunning=\(running)")
                DispatchQueue.main.async { self.sessionRunning = running }
            }
        }
    }

    /// Switches between the classic camera setup and the rear LiDAR camera.
    /// Takes effect immediately if the session is configured, otherwise on the next configure.
    func setLiDARMode(_ enabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, self.lidarModeRequested != enabled else { return }
            self.lidarModeRequested = enabled
            self.log("LiDAR mode \(enabled ? "on" : "off")")
            guard self.isConfigured else { return }
            let wasRunning = self.session.isRunning
            if wasRunning { self.session.stopRunning() }
            self.configureSession()
            guard wasRunning || self.shouldBeRunning else { return }
            self.session.startRunning()
            let running = self.session.isRunning
            self.log("reconfigured for LiDAR=\(enabled), isRunning=\(running)")
            DispatchQueue.main.async { self.sessionRunning = running }
        }
    }

    func stopSession() {
        shouldBeRunning = false
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            self.log("stopped")
        }
    }

    private func configureSession() {
        log("configureSession start")
        session.beginConfiguration()

        // Remove any stale inputs/outputs from a previous (failed) configure pass
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        depthSynchronizer = nil
        depthOutput = nil
        videoOutput = AVCaptureVideoDataOutput()

        var useLiDAR = lidarModeRequested && LiDARSupport.isSupported
        let lidarDevice = useLiDAR
            ? AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back)
            : nil
        if useLiDAR && lidarDevice == nil {
            log("LiDAR camera unavailable — using classic camera")
            useLiDAR = false
        }

        if useLiDAR {
            // Format is chosen on the device below; the session follows it (.inputPriority).
        } else if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .high
            log("preset fallback to .high")
        }

        let position: AVCaptureDevice.Position = cameraPosition
        guard let device = lidarDevice
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            session.commitConfiguration()
            log("FAILED — no camera device")
            return
        }
        log("device=\(device.localizedName)")
        self.captureDevice = device

        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .none
            }
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = false
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.unlockForConfiguration()
            log("camera sharpen tuning applied")
        } catch {
            log("camera sharpen tuning failed: \(error.localizedDescription)")
        }

        guard let input = try? AVCaptureDeviceInput(device: device) else {
            session.commitConfiguration()
            log("FAILED — AVCaptureDeviceInput threw")
            return
        }

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            log("FAILED — canAddInput false")
            return
        }
        session.addInput(input)
        log("input added")

        if useLiDAR && !configureLiDARFormat(device) {
            log("no LiDAR depth format — depth disabled")
            useLiDAR = false
        }

        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera.buffer.queue"))
        videoOutput.alwaysDiscardsLateVideoFrames = true
        // Use BGRA pixel format for stable Vision processing across devices.
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            log("output added")
        } else {
            log("WARNING — canAddOutput false (preview still works)")
        }

        if useLiDAR {
            let output = AVCaptureDepthDataOutput()
            output.isFilteringEnabled = true          // fills LiDAR holes, smooths edges
            output.alwaysDiscardsLateDepthData = true
            if session.canAddOutput(output) {
                session.addOutput(output)
                depthOutput = output
                // The synchronizer replaces videoOutput's delegate while it exists.
                let synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, output])
                synchronizer.setDelegate(self, queue: depthQueue)
                depthSynchronizer = synchronizer
                lidarHorizontalFOV = device.activeFormat.videoFieldOfView
                log("LiDAR depth output added (FOV \(lidarHorizontalFOV)°)")
            } else {
                log("WARNING — cannot add depth output")
                useLiDAR = false
            }
        }

        session.commitConfiguration()
        isConfigured = true
        let lidarActive = useLiDAR
        DispatchQueue.main.async { self.isLiDARActive = lidarActive }
        if lidarActive {
            // Depth is only aligned with the unzoomed image.
            DispatchQueue.main.async { self.zoomFactor = 1.0 }
        } else {
            applySavedZoom(for: device)
        }
        setUpRotationCoordinator(for: device)
        log("configured OK")
    }

    /// Picks a video format that has a Float depth format with the same aspect ratio (so depth
    /// pixels line up with video pixels): sharpest depth first, then the largest video up to
    /// 1920 wide: a hand 2–3 m away is only a few dozen pixels, and detection runs on crops, so
    /// the extra resolution costs little.
    private func configureLiDARFormat(_ device: AVCaptureDevice) -> Bool {
        func dimensions(_ format: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        }

        var best: (video: AVCaptureDevice.Format, depth: AVCaptureDevice.Format)?
        for format in device.formats {
            let video = dimensions(format)
            guard video.width <= 1920 else { continue }
            let aspect = Float(video.width) / Float(video.height)
            let depthFormats = format.supportedDepthDataFormats.filter {
                let type = CMFormatDescriptionGetMediaSubType($0.formatDescription)
                let depth = dimensions($0)
                return (type == kCVPixelFormatType_DepthFloat32 || type == kCVPixelFormatType_DepthFloat16)
                    && abs(Float(depth.width) / Float(depth.height) - aspect) < 0.02
            }
            guard let depth = depthFormats.max(by: { dimensions($0).width < dimensions($1).width }) else { continue }

            if let current = best {
                let currentScore = (dimensions(current.depth).width, dimensions(current.video).width)
                let score = (dimensions(depth).width, video.width)
                guard score > currentScore else { continue }
            }
            best = (format, depth)
        }

        guard let best else { return false }
        do {
            try device.lockForConfiguration()
            device.activeFormat = best.video
            device.activeDepthDataFormat = best.depth
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()
        } catch {
            log("LiDAR format failed: \(error.localizedDescription)")
            return false
        }
        let video = dimensions(best.video)
        let depth = dimensions(best.depth)
        log("LiDAR format video=\(video.width)x\(video.height) depth=\(depth.width)x\(depth.height)")
        return true
    }

    private func restoredZoomFactor(forFrontCamera isFrontCamera: Bool) -> CGFloat {
        let defaults = UserDefaults.standard
        let key = isFrontCamera ? PersistenceKeys.frontZoomFactor : PersistenceKeys.backZoomFactor
        let fallback = isFrontCamera ? preferredFrontCameraZoomFactor : preferredBackCameraZoomFactor
        let storedZoom = defaults.double(forKey: key)
        return storedZoom > 0 ? CGFloat(storedZoom) : fallback
    }

    private func saveCurrentCameraSelection() {
        UserDefaults.standard.set(useFrontCamera, forKey: PersistenceKeys.useFrontCamera)
    }

    private func saveZoomFactor(_ factor: CGFloat, forFrontCamera isFrontCamera: Bool) {
        let key = isFrontCamera ? PersistenceKeys.frontZoomFactor : PersistenceKeys.backZoomFactor
        UserDefaults.standard.set(Double(factor), forKey: key)
    }

    private func applySavedZoom(for device: AVCaptureDevice) {
        let requestedZoom = restoredZoomFactor(forFrontCamera: useFrontCamera)

        do {
            try device.lockForConfiguration()
            let clampedFactor = min(max(requestedZoom, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            device.videoZoomFactor = clampedFactor
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .none
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.zoomFactor = clampedFactor }
            saveZoomFactor(clampedFactor, forFrontCamera: useFrontCamera)
            log("restored zoom set to \(clampedFactor) for \(useFrontCamera ? "front" : "back") camera")
        } catch {
            log("restored zoom failed: \(error.localizedDescription)")
        }
    }

    func switchCamera() {
        guard !isLiDARActive else { return }   // LiDAR is rear-only
        let newFront = !useFrontCamera
        // Update @Published on main thread; cameraPosition updated via didSet
        DispatchQueue.main.async { self.useFrontCamera = newFront }
        // cameraPosition is the non-published mirror read by session queue
        cameraPosition = newFront ? .front : .back
        UserDefaults.standard.set(newFront, forKey: PersistenceKeys.useFrontCamera)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.isConfigured = false
            if self.session.isRunning { self.session.stopRunning() }
            self.configureSession()
            self.session.startRunning()
            let running = self.session.isRunning
            self.log("switched to \(newFront ? "front" : "back"), isRunning=\(running)")
            DispatchQueue.main.async { self.sessionRunning = running }
        }
    }

    func setZoom(_ factor: CGFloat) {
        guard let device = captureDevice, !isLiDARActive else { return }
        
        do {
            try device.lockForConfiguration()
            let clampedFactor = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            device.videoZoomFactor = clampedFactor
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.zoomFactor = clampedFactor }
            saveZoomFactor(clampedFactor, forFrontCamera: useFrontCamera)
            log("zoom set to \(clampedFactor)")
        } catch {
            log("zoom failed: \(error.localizedDescription)")
        }
    }

    func zoomIn() {
        let newZoom = zoomFactor * 1.1  // 10% increase
        setZoom(newZoom)
    }

    func zoomOut() {
        let newZoom = zoomFactor / 1.1  // 10% decrease
        setZoom(newZoom)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        bufferSubject.send(sampleBuffer)
    }

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        // Use the synchronizer's own outputs — the properties may be swapped by a reconfigure.
        guard let video = synchronizer.dataOutputs.first(where: { $0 is AVCaptureVideoDataOutput }),
              let videoData = synchronizedDataCollection.synchronizedData(for: video) as? AVCaptureSynchronizedSampleBufferData,
              !videoData.sampleBufferWasDropped,
              let pixelBuffer = CMSampleBufferGetImageBuffer(videoData.sampleBuffer) else { return }

        var depthMap: CVPixelBuffer?
        var depthAngle: CGFloat = 0
        if let depth = synchronizer.dataOutputs.first(where: { $0 is AVCaptureDepthDataOutput }),
           let depthData = synchronizedDataCollection.synchronizedData(for: depth) as? AVCaptureSynchronizedDepthData,
           !depthData.depthDataWasDropped {
            let data = depthData.depthData.depthDataType == kCVPixelFormatType_DepthFloat32
                ? depthData.depthData
                : depthData.depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
            depthMap = data.depthDataMap
            depthAngle = depth.connection(with: .depthData)?.videoRotationAngle ?? 0
        }

        let videoAngle = video.connection(with: .video)?.videoRotationAngle ?? 0
        let frame = DepthFrame(
            pixelBuffer: pixelBuffer,
            depthMap: depthMap,
            rotationAngle: videoAngle - depthAngle,
            horizontalFieldOfView: lidarHorizontalFOV,
            timestamp: CMSampleBufferGetPresentationTimeStamp(videoData.sampleBuffer).seconds
        )
        depthFrameHandler?(frame)
    }
}
