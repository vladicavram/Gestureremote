import AVFoundation
import Combine
import CoreVideo
import Foundation
import Vision

// MARK: - Device support

/// LiDAR mode is offered on iPhone 15 Pro and newer Pro models (rear LiDAR scanner + A17 Pro or later).
enum LiDARSupport {
    static let isSupported: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        guard AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) != nil else {
            return false
        }
        // iPhone 15 Pro is "iPhone16,1"; every later LiDAR iPhone has a higher major number.
        let identifier = modelIdentifier
        guard identifier.hasPrefix("iPhone"),
              let majorText = identifier.dropFirst("iPhone".count).split(separator: ",").first,
              let major = Int(majorText) else { return false }
        return major >= 16
        #endif
    }()

    private static var modelIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

// MARK: - Frame

/// Synchronized color + LiDAR depth frame from the rear camera.
struct DepthFrame {
    /// Upright video frame (the video connection is rotated to the device orientation).
    let pixelBuffer: CVPixelBuffer
    /// DepthFloat32 in metres, in the sensor's native (unrotated) orientation. Nil if depth was dropped.
    let depthMap: CVPixelBuffer?
    /// Clockwise rotation, in degrees, from the depth map's orientation to `pixelBuffer`.
    let rotationAngle: CGFloat
    /// Horizontal field of view across the sensor's native width, in degrees.
    let horizontalFieldOfView: Float
    let timestamp: TimeInterval
}

// MARK: - Tracker

/// LiDAR hand tracking for the rear camera.
///
/// Runs hand pose once per frame, picks the hand nearest the phone (so people further back
/// are ignored), forwards it to the classic GestureProcessor, and adds an "air pointer":
///   Raised index finger (other fingers folded) → pointer engages
///   Move the finger ~3 cm                       → one arrow press (moves TV keyboard focus one key)
///   Push the hand ~3.5 cm toward the phone      → Select (types the focused key)
/// Positions are measured in metres using LiDAR depth, so key spacing feels the same at any distance.
final class LiDARHandTracker: ObservableObject {

    @Published private(set) var handDistance: Float?
    @Published private(set) var isPointerActive = false
    @Published private(set) var lastPointerGesture: Gesture = .none

    /// Nearest hand in range (or nil), so the classic gesture vocabulary keeps working.
    var onHandObservation: ((VNHumanHandPoseObservation?) -> Void)?
    /// Arrow steps and air taps, delivered on the main queue.
    var onPointerGesture: ((Gesture) -> Void)?
    /// Pointer only engages while classic gestures are awake (palm wake), like every other gesture.
    var isGestureAwake: () -> Bool = { true }
    /// Called while the pointer is in use so the classic sleep timer doesn't fire mid-typing.
    var onActivity: (() -> Void)?

    // Range gating
    private let minControlDistance: Float = 0.25
    private let maxControlDistance: Float = 4.0

    // Pointer engagement
    private let engageFramesRequired = 8      // ~0.27 s at 30 fps
    private let releaseFramesRequired = 6     // pose lost this long → pointer off

    // Pointer stepping (metres)
    private let horizontalStep: Float = 0.03
    private let verticalStep: Float = 0.03
    private let minStepInterval: TimeInterval = 0.1   // matches AppleTVRemote pointer pacing

    // Air tap (metres / seconds)
    private let tapDepth: Float = 0.035
    private let tapWindow: TimeInterval = 0.35
    private let tapRearmDistance: Float = 0.02
    private let tapRearmTimeout: TimeInterval = 0.8
    private let minTapInterval: TimeInterval = 0.25
    private let pushFreezeSpeed: Float = 0.15         // m/s toward/away from phone → hold steps

    // Pose thresholds (degrees at PIP joint, same convention as GestureProcessor)
    private let extendedAngleThreshold: CGFloat = 150

    private let queue = DispatchQueue(label: "lidar.tracking", qos: .userInteractive)
    private let busyLock = NSLock()
    private var isBusy = false
    private let handRequest = VNDetectHumanHandPoseRequest()

    // Pointer state (tracking queue only)
    private var poseFrames = 0
    private var lostFrames = 0
    private var pointerActive = false
    private var anchor = SIMD2<Float>(0, 0)
    private var filterX = OneEuroFilter(minCutoff: 1.2, beta: 10)
    private var filterY = OneEuroFilter(minCutoff: 1.2, beta: 10)
    private var filterZ = OneEuroFilter(minCutoff: 4.0, beta: 5)
    private var zHistory: [(time: TimeInterval, z: Float)] = []
    private var tapArmed = true
    private var tapLowestZ: Float = 0
    private var lastTapTime: TimeInterval = 0
    private var lastStepTime: TimeInterval = 0

    init() {
        handRequest.maximumHandCount = 2
    }

    /// Drops frames while the previous one is still being processed so latency never builds up.
    func process(_ frame: DepthFrame) {
        busyLock.lock()
        guard !isBusy else { busyLock.unlock(); return }
        isBusy = true
        busyLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.handle(frame)
            self.busyLock.lock()
            self.isBusy = false
            self.busyLock.unlock()
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.deactivatePointer()
            DispatchQueue.main.async { self.handDistance = nil }
        }
    }

    // MARK: - Per-frame

    private func handle(_ frame: DepthFrame) {
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([handRequest])
        let observations = handRequest.results ?? []

        var chosen: VNHumanHandPoseObservation?
        var chosenDepth: Float?

        if let depthMap = frame.depthMap,
           let sampler = DepthSampler(depthMap: depthMap, frame: frame) {
            defer { sampler.close() }
            for observation in observations {
                let depth = palmDepth(of: observation, sampler: sampler)
                if let depth, depth < minControlDistance || depth > maxControlDistance { continue }
                if chosen == nil || (depth ?? .infinity) < (chosenDepth ?? .infinity) {
                    chosen = observation
                    chosenDepth = depth
                }
            }
        } else {
            chosen = observations.first
        }

        onHandObservation?(chosen)
        updatePointer(observation: chosen, depth: chosenDepth, frame: frame)

        let distance = chosenDepth
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.handDistance != distance { self.handDistance = distance }
        }
    }

    // MARK: - Depth

    /// Robust distance to the palm: low percentile of depth around wrist + knuckles.
    /// The hand is the nearest surface in those windows, so a low percentile rejects the body behind it.
    private func palmDepth(of observation: VNHumanHandPoseObservation, sampler: DepthSampler) -> Float? {
        let joints: [VNHumanHandPoseObservation.JointName] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
        var samples: [Float] = []
        samples.reserveCapacity(joints.count * 25)
        for joint in joints {
            guard let point = try? observation.recognizedPoint(joint), point.confidence > 0.3 else { continue }
            sampler.collect(around: point.location, radius: 2, into: &samples)
        }
        guard samples.count >= 8 else { return nil }
        samples.sort()
        return samples[Int(Float(samples.count - 1) * 0.3)]
    }

    // MARK: - Pointer

    private func updatePointer(observation: VNHumanHandPoseObservation?, depth: Float?, frame: DepthFrame) {
        guard let observation,
              let depth,
              isPointingPose(observation),
              let tip = try? observation.recognizedPoint(.indexTip),
              tip.confidence > 0.5 else {
            if pointerActive {
                lostFrames += 1
                if lostFrames >= releaseFramesRequired { deactivatePointer() }
            } else {
                poseFrames = 0
            }
            return
        }
        lostFrames = 0

        let t = frame.timestamp
        let position = metricPosition(of: tip.location, depth: depth, frame: frame)

        guard pointerActive else {
            poseFrames += 1
            guard poseFrames >= engageFramesRequired, isGestureAwake() else { return }
            activatePointer(at: position, depth: depth, time: t)
            return
        }

        onActivity?()

        let x = filterX.filter(position.x, at: t)
        let y = filterY.filter(position.y, at: t)
        let z = filterZ.filter(depth, at: t)

        zHistory.append((t, z))
        zHistory.removeAll { t - $0.time > tapWindow }

        // ── Air tap: hand pushed toward the phone ──────────────────────────
        if !tapArmed {
            tapLowestZ = min(tapLowestZ, z)
            // Re-arm once the hand pulls back, or after a pause if it stays forward.
            if z >= tapLowestZ + tapRearmDistance || t - lastTapTime > tapRearmTimeout {
                tapArmed = true
                anchor = SIMD2(x, y)
            }
        }
        let recentFarthest = zHistory.map(\.z).max() ?? z
        if tapArmed, recentFarthest - z >= tapDepth, t - lastTapTime >= minTapInterval {
            tapArmed = false
            tapLowestZ = z
            lastTapTime = t
            zHistory.removeAll()
            anchor = SIMD2(x, y)
            emit(.select)
            return
        }

        // Hold arrow steps while the hand moves in depth: pushing shifts the fingertip in the
        // image, which would otherwise fire a stray arrow right before every tap.
        if abs(depthSpeed(now: t, z: z)) > pushFreezeSpeed || !tapArmed {
            anchor = SIMD2(x, y)
            return
        }

        // ── Arrow steps: one key per step of finger travel ──────────────────
        guard t - lastStepTime >= minStepInterval else { return }
        let dx = x - anchor.x
        let dy = y - anchor.y
        let stepsX = abs(dx) / horizontalStep
        let stepsY = abs(dy) / verticalStep

        if stepsX >= 1, stepsX >= stepsY {
            anchor.x += dx > 0 ? horizontalStep : -horizontalStep
            anchor.y = y
            lastStepTime = t
            emit(dx > 0 ? .swipeRight : .swipeLeft)
        } else if stepsY >= 1 {
            anchor.y += dy > 0 ? verticalStep : -verticalStep
            anchor.x = x
            lastStepTime = t
            emit(dy > 0 ? .swipeUp : .swipeDown)
        }
    }

    /// Depth velocity (m/s) over the last ~0.1 s; negative = moving toward the phone.
    private func depthSpeed(now t: TimeInterval, z: Float) -> Float {
        guard let past = zHistory.first(where: { t - $0.time <= 0.12 }), t - past.time > 0.03 else { return 0 }
        return (z - past.z) / Float(t - past.time)
    }

    /// Index finger extended, middle/ring/little not extended. Thumb is ignored.
    private func isPointingPose(_ observation: VNHumanHandPoseObservation) -> Bool {
        func angle(_ mcp: VNHumanHandPoseObservation.JointName,
                   _ pip: VNHumanHandPoseObservation.JointName,
                   _ tip: VNHumanHandPoseObservation.JointName) -> CGFloat? {
            guard let a = try? observation.recognizedPoint(mcp),
                  let b = try? observation.recognizedPoint(pip),
                  let c = try? observation.recognizedPoint(tip),
                  a.confidence > 0.3, b.confidence > 0.3, c.confidence > 0.3 else { return nil }
            return jointAngle(a.location, b.location, c.location)
        }
        guard let index  = angle(.indexMCP, .indexPIP, .indexTip),
              let middle = angle(.middleMCP, .middlePIP, .middleTip),
              let ring   = angle(.ringMCP, .ringPIP, .ringTip),
              let little = angle(.littleMCP, .littlePIP, .littleTip) else { return false }
        return index >= extendedAngleThreshold
            && middle < extendedAngleThreshold
            && ring < extendedAngleThreshold
            && little < extendedAngleThreshold
    }

    /// Fingertip position in metres on a plane facing the phone, from the user's point of view
    /// (+x = user's right, +y = up). Uses the pinhole model with the format's field of view.
    private func metricPosition(of point: CGPoint, depth: Float, frame: DepthFrame) -> SIMD2<Float> {
        let rotated = Int(frame.rotationAngle.rounded()) % 180 != 0
        let bufferWidth = Float(CVPixelBufferGetWidth(frame.pixelBuffer))
        let bufferHeight = Float(CVPixelBufferGetHeight(frame.pixelBuffer))
        let nativeWidth = rotated ? bufferHeight : bufferWidth
        let nativeHeight = rotated ? bufferWidth : bufferHeight

        let tanHalfNativeH = tan(frame.horizontalFieldOfView * .pi / 360)
        let tanHalfNativeV = tanHalfNativeH * nativeHeight / nativeWidth
        let tanHalfX = rotated ? tanHalfNativeV : tanHalfNativeH
        let tanHalfY = rotated ? tanHalfNativeH : tanHalfNativeV

        // Camera faces the user, so the user's right is image-left (same as GestureProcessor swipes).
        let x = -(Float(point.x) - 0.5) * 2 * depth * tanHalfX
        let y = (Float(point.y) - 0.5) * 2 * depth * tanHalfY
        return SIMD2(x, y)
    }

    private func activatePointer(at position: SIMD2<Float>, depth: Float, time: TimeInterval) {
        pointerActive = true
        filterX.reset(); filterY.reset(); filterZ.reset()
        anchor = SIMD2(filterX.filter(position.x, at: time), filterY.filter(position.y, at: time))
        _ = filterZ.filter(depth, at: time)
        zHistory = [(time, depth)]
        tapArmed = true
        lastStepTime = time
        onActivity?()
        DispatchQueue.main.async { [weak self] in self?.isPointerActive = true }
    }

    private func deactivatePointer() {
        poseFrames = 0
        lostFrames = 0
        zHistory.removeAll()
        guard pointerActive else { return }
        pointerActive = false
        DispatchQueue.main.async { [weak self] in
            self?.isPointerActive = false
            self?.lastPointerGesture = .none
        }
    }

    private func emit(_ gesture: Gesture) {
        DispatchQueue.main.async { [weak self] in
            self?.lastPointerGesture = gesture
            self?.onPointerGesture?(gesture)
        }
    }

    private func jointAngle(_ a: CGPoint, _ center: CGPoint, _ b: CGPoint) -> CGFloat {
        let v1x = a.x - center.x, v1y = a.y - center.y
        let v2x = b.x - center.x, v2y = b.y - center.y
        let mag1 = sqrt(v1x * v1x + v1y * v1y)
        let mag2 = sqrt(v2x * v2x + v2y * v2y)
        guard mag1 > 0.001, mag2 > 0.001 else { return 0 }
        let cosine = (v1x * v2x + v1y * v2y) / (mag1 * mag2)
        return acos(max(-1, min(1, cosine))) * 180 / .pi
    }
}

// MARK: - Depth sampling

/// Reads LiDAR depth at Vision points. Vision points live in the upright video image;
/// the depth map is in sensor-native orientation, so points are rotated back before lookup.
private final class DepthSampler {
    private let depthMap: CVPixelBuffer
    private let base: UnsafeMutableRawPointer
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int
    private let rotation: Int

    init?(depthMap: CVPixelBuffer, frame: DepthFrame) {
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            return nil
        }
        self.depthMap = depthMap
        self.base = base
        width = CVPixelBufferGetWidth(depthMap)
        height = CVPixelBufferGetHeight(depthMap)
        bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        rotation = ((Int(frame.rotationAngle.rounded()) % 360) + 360) % 360
    }

    func close() {
        CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
    }

    /// Appends valid depths (metres) in a (2r+1)² window around a Vision point.
    func collect(around visionPoint: CGPoint, radius: Int, into samples: inout [Float]) {
        // Vision: origin bottom-left → top-left normalized coords in the upright image.
        let rx = Float(visionPoint.x)
        let ry = 1 - Float(visionPoint.y)

        // Undo the clockwise rotation applied to the video to get native coords.
        let nx: Float, ny: Float
        switch rotation {
        case 90:  nx = ry;     ny = 1 - rx
        case 180: nx = 1 - rx; ny = 1 - ry
        case 270: nx = 1 - ry; ny = rx
        default:  nx = rx;     ny = ry
        }

        let cx = Int(nx * Float(width))
        let cy = Int(ny * Float(height))
        let x0 = max(0, cx - radius), x1 = min(width - 1, cx + radius)
        let y0 = max(0, cy - radius), y1 = min(height - 1, cy + radius)
        guard x0 <= x1, y0 <= y1 else { return }
        for py in y0...y1 {
            let row = base.advanced(by: py * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for px in x0...x1 {
                let value = row[px]
                if value.isFinite, value > 0.15, value < 6 { samples.append(value) }
            }
        }
    }
}

// MARK: - One Euro filter

/// Speed-adaptive low-pass filter: heavy smoothing when still (no jitter), light when moving (no lag).
struct OneEuroFilter {
    let minCutoff: Float
    let beta: Float
    var derivativeCutoff: Float = 1.0

    private var lastValue: Float?
    private var lastTime: TimeInterval?
    private var derivative: Float = 0

    init(minCutoff: Float, beta: Float) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    mutating func filter(_ value: Float, at time: TimeInterval) -> Float {
        guard let previous = lastValue, let previousTime = lastTime, time > previousTime else {
            lastValue = value
            lastTime = time
            return value
        }
        let dt = Float(time - previousTime)
        let rawDerivative = (value - previous) / dt
        derivative += alpha(cutoff: derivativeCutoff, dt: dt) * (rawDerivative - derivative)
        let cutoff = minCutoff + beta * abs(derivative)
        let result = previous + alpha(cutoff: cutoff, dt: dt) * (value - previous)
        lastValue = result
        lastTime = time
        return result
    }

    mutating func reset() {
        lastValue = nil
        lastTime = nil
        derivative = 0
    }

    private func alpha(cutoff: Float, dt: Float) -> Float {
        let tau = 1 / (2 * Float.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}
