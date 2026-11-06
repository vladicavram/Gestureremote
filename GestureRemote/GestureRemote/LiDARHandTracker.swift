import AVFoundation
import Combine
import CoreImage
import CoreVideo
import Foundation
import QuartzCore
import simd
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
    /// Camera sensitivity; high ISO = a dark room.
    let iso: Float
    /// Dark enough that the color image struggles: LiDAR leads the hand search and crops are brightened.
    var lowLight: Bool { iso >= 800 }
}

// MARK: - Tracker

/// Hand detection that combines the rear camera with LiDAR depth:
///   • Tracking: once a hand is found, Vision runs on a crop around it, so a hand across the
///     room fills far more of Vision's input than in the full frame.
///   • Depth-guided search: with no hand tracked, alternate frames look at the object nearest
///     the phone (a raised hand is usually in front of the body), the rest at the full frame.
///   • Depth gating: hands closer than 0.25 m or farther than 4 m are ignored and the nearest
///     hand wins, so people further back can't take over.
///   • Steady distance (after CardboardXR): LiDAR at a moving hand swings by 10–27 cm, so it only
///     teaches the user's palm size, slowly; each frame's distance then comes from how wide the
///     palm looks on camera, which doesn't change when the hand moves sideways.
/// The chosen hand goes to the classic GestureProcessor, so the gesture vocabulary is unchanged.
///
/// Live pointer for the whole Apple TV interface, while gestures are awake or the Apple TV
/// keyboard is showing (no wake needed there):
///   Open palm                                      → pointer on; then any hand pose
///   Move the palm 2.5–4.5 cm (less when fast)       → one arrow press (focus moves one step)
///   Pinch thumb and index                          → Select (types the focused key)
final class LiDARHandTracker: ObservableObject {

    @Published private(set) var handDistance: Float?
    @Published private(set) var isPointerActive = false

    /// Nearest hand in range (or nil), in full-frame coordinates with its distance.
    var onHandPose: ((HandPose?) -> Void)?
    /// Arrow steps and presses from the pointer, delivered on the main queue.
    var onPointerGesture: ((Gesture) -> Void)?
    /// Whether classic gestures are awake (palm wake); the open-palm pointer needs it.
    var isGestureAwake: () -> Bool = { false }
    /// Called on every pointer step or press, so gestures don't fall asleep while pointing.
    var onActivity: (() -> Void)?

    private let minControlDistance: Float = 0.25
    private let maxControlDistance: Float = 5.0

    // Tracking crop
    private let trackingScale: CGFloat = 2.2        // crop side = hand size × this
    private let minTrackingSide: CGFloat = 0.12     // fraction of the frame's shorter side: far hands zoom in
    private let minSearchSide: CGFloat = 0.3        // depth-guided search crop
    private let maxMissedFrames = 4                 // then fall back to searching

    // Palm size learned from LiDAR (metres, mean distance between the five palm landmarks)
    private let typicalPalmSize: Float = 0.055
    private let palmSizeRange: ClosedRange<Float> = 0.035...0.09
    private let palmSizeRate: Float = 0.05          // share of each reading that's learned
    private let calibrationDepthRange: ClosedRange<Float> = 0.3...3.0   // LiDAR reads short up close
    private let calibrationMinFacing: Float = 0.3   // edge-on palms look narrow; don't learn from them
    private let calibratedAfter = 15                // readings before the camera estimate takes over

    // Typing
    private let engageFramesRequired = 6            // raised index held ~0.2 s
    private let releaseFramesRequired = 10          // hand lost this long → typing off
    // Pointer acceleration, as with a mouse: slow moves stay precise, fast moves cross the
    // keyboard quickly. Step shrinks from keyStepSlow toward keyStepFast as palm speed rises.
    private let keyStepSlow: Float = 0.045          // metres of palm travel per step, moving slowly
    private let keyStepFast: Float = 0.025          // …and at full speed
    private let accelerationSpeed: Float = 0.8      // m/s at which the step reaches keyStepFast
    private let minStepInterval: TimeInterval = 0.07   // matches AppleTVRemote's pointer pacing
    // Lowering the hand out of view drags the palm down; those steps are held back briefly and
    // dropped if the hand leaves, and a drop faster than navigation sends nothing.
    private let stepConfirmDelay: TimeInterval = 0.1
    private let exitDropSpeed: Float = 0.5          // m/s downward
    private let minPressInterval: TimeInterval = 0.25
    // Pinch (CardboardXR's PinchSensor): fingertip gap over palm width on camera.
    private let pinchCloseRatio: Float = 0.4
    private let pinchOpenRatio: Float = 0.8
    // Measured with MediaPipe at 1.4–2 m: pinched 2.1–3.8 cm, briefly up to ~4.8 in the dark (its
    // 3D shape never closes below ~2 cm that far away); open 7–9 cm. CardboardXR's 2.5/4.5 cm is
    // for arm's length.
    private let pinchCloseMeters: Float = 0.045
    private let pinchOpenMeters: Float = 0.06
    private let pinchSteadyFrames = 3               // hand seen this many frames before a pinch counts
    // A lowered, relaxed hand rests with thumb near index, which looks like a pinch. A real one is a
    // quick close from an open hand that's held up, palm toward the phone.
    private let pinchOpenWithin: TimeInterval = 0.8  // stable open this recently before closing
    // At ~2 m the fingertips jitter on camera and a resting hand's gap flips open/closed every
    // frame (measured); a real pinch holds each state for several frames.
    private let pinchStableOpenFrames = 3
    private let pinchStableClosedFrames = 2
    // Other fingers' reach during a pinch: ~1.8 in good light, 0.9–1.5 in the dark (they read
    // curled); a real fist ~0.6–0.8.
    private let pinchMinOtherReach: CGFloat = 0.85
    private let pinchMinFacing: Float = 0.3          // a hanging hand is edge-on (≈ 0)
    private let pinchAfterDrop: TimeInterval = 0.4   // no pinch this soon after a fast drop
    private let turnRate: Float = 2                 // facing change per second that means turning over
    private let turnHold: TimeInterval = 0.25       // …and no pinch for this long after
    private let extendedAngleThreshold: CGFloat = 150

    private let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
    private let queue = DispatchQueue(label: "lidar.tracking", qos: .userInteractive)
    private let busyLock = NSLock()
    private var isBusy = false
    private let handRequest = VNDetectHumanHandPoseRequest()
    /// MediaPipe hand landmarker (with 3D hand shape); Apple Vision is the fallback if it can't load.
    private let mediaPipe = MediaPipeHands()
    /// Finds people, and their wrists, from much further away than the hand detector can.
    private let bodyRequest = VNDetectHumanBodyPoseRequest()

    // Tracking queue only
    private var trackedRegion: CGRect?
    private var missedFrames = 0
    private var searchNearestNext = false
    private var palmSize: Float
    private var calibrationReadings = 0
    private var keyboardActive = false
    private var poseFrames = 0
    private var lostFrames = 0
    private var steadyFrames = 0
    private var pointerActive = false
    private var anchor = SIMD2<Float>(0, 0)
    // Higher beta than before: the filter opens up faster when the palm moves, so less lag.
    private var filterX = OneEuroFilter(minCutoff: 1.0, beta: 15)
    private var filterY = OneEuroFilter(minCutoff: 1.0, beta: 15)
    private var lastPosition: SIMD2<Float>?
    private var lastPositionTime: TimeInterval = 0
    private var palmSpeed: Float = 0
    private var palmVelocity = SIMD2<Float>(0, 0)
    private var pendingSteps: [(gesture: Gesture, time: TimeInterval)] = []
    private var lastOpenGapTime: TimeInterval = 0
    private var openFrames = 0
    private var closedFrames = 0
    private var pinchArmed = false
    private var lastDropTime: TimeInterval = 0
    private var filterDistance = OneEuroFilter(minCutoff: 3.0, beta: 2)
    private var isPinched = false
    private var lastFacing: Float?
    private var lastFacingTime: TimeInterval = 0
    private var turningUntil: TimeInterval = 0
    private var lastPressTime: TimeInterval = 0
    private var lastStepTime: TimeInterval = 0
    private var lastDiagnosticTick = 0
    // ✌️ volume
    private let volumeStep: Float = 0.04             // metres of hand travel per volume step
    private let volumeStepInterval: TimeInterval = 0.15
    private let volumeEngageFrames = 4
    private let volumeReleaseFrames = 4
    private var volumeActive = false
    private var volumePoseFrames = 0
    private var volumeLostFrames = 0
    private var volumeAnchorY: Float = 0
    private var lastVolumeStepTime: TimeInterval = 0
    private var volumeFilter = OneEuroFilter(minCutoff: 1.0, beta: 15)
    private var pointerNeedsReanchor = false
    private var raisedCheckCounter = 0
    private var lastRaised: Bool?
    private var lastRaisedTime: TimeInterval = 0
    private let raisedMinRise: CGFloat = 0.25        // sin(~15°): forearm pointing up

    init() {
        handRequest.maximumHandCount = 2
        palmSize = typicalPalmSize
    }

    /// Drops frames while the previous one is still being processed so latency never builds up.
    func process(_ frame: DepthFrame) {
        busyLock.lock()
        guard !isBusy else { busyLock.unlock(); return }
        isBusy = true
        busyLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let start = CACurrentMediaTime()
            self.lastISO = frame.iso
            self.handle(frame)
            self.notePerformance(frameTime: CACurrentMediaTime() - start)
            self.busyLock.lock()
            self.isBusy = false
            self.busyLock.unlock()
        }
    }

    private var perfFrames = 0
    private var lastISO: Float = 0
    private var perfBusy: TimeInterval = 0
    private var perfSince = CACurrentMediaTime()

    /// Logs processed frames per second and the average time per frame, every 2 s.
    private func notePerformance(frameTime: TimeInterval) {
        perfFrames += 1
        perfBusy += frameTime
        let now = CACurrentMediaTime()
        guard now - perfSince >= 2 else { return }
        print(String(format: "[PERF] %.1f fps, %.0f ms per frame (%@), ISO %.0f%@", Double(perfFrames) / (now - perfSince),
                     perfBusy / Double(perfFrames) * 1000, mediaPipe.delegateName, lastISO, lastISO >= 800 ? " LOW LIGHT" : ""))
        perfFrames = 0
        perfBusy = 0
        perfSince = now
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.trackedRegion = nil
            self.missedFrames = 0
            self.deactivatePointer()
            DispatchQueue.main.async { self.handDistance = nil }
        }
    }

    /// Typing is only available while the Apple TV keyboard is on screen.
    func setKeyboardActive(_ active: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.keyboardActive = active
            if !active { self.deactivatePointer() }
        }
    }

    // MARK: - Per-frame

    private func handle(_ frame: DepthFrame) {
        let imageSize = CGSize(width: CVPixelBufferGetWidth(frame.pixelBuffer),
                               height: CVPixelBufferGetHeight(frame.pixelBuffer))
        let sampler = frame.depthMap.flatMap { DepthSampler(depthMap: $0, frame: frame) }
        defer { sampler?.close() }

        // 1. Where to look: around the tracked hand; else around people's wrists (body pose
        //    reaches much further than hand pose); else alternate nearest-object / full frame.
        var regions: [CGRect] = []
        let trackedRegionBefore = trackedRegion
        if let tracked = trackedRegion {
            regions = [tracked]
        } else if frame.lowLight, searchNearestNext, let sampler,
                  let nearest = sampler.nearestObjectRegion(minDepth: minControlDistance, maxDepth: maxControlDistance) {
            // Dark room: body pose (color image) often finds nobody, but LiDAR still sees the
            // nearest surface, usually a raised hand in front of the body. Alternates with the
            // wrist search below.
            regions = [squareRegion(around: nearest, scale: 1.6, minSide: minTrackingSide, imageSize: imageSize)]
            searchNearestNext.toggle()
        } else {
            if frame.lowLight { searchNearestNext.toggle() }
            regions = wristRegions(in: frame.pixelBuffer, imageSize: imageSize)
            if regions.isEmpty {
                var region = fullFrame
                if searchNearestNext, let sampler,
                   let nearest = sampler.nearestObjectRegion(minDepth: minControlDistance, maxDepth: maxControlDistance) {
                    region = squareRegion(around: nearest, scale: 1.4, minSide: minSearchSide, imageSize: imageSize)
                }
                searchNearestNext.toggle()
                regions = [region]
            }
        }

        // 2. Detect, measure each hand, keep the nearest within range.
        let focal = focalLengthPixels(frame: frame, imageSize: imageSize)
        var chosen: HandPose?
        var chosenLiDAR: Float?
        // One hand at a time: while tracking, only the hand in its own crop is looked for, so a
        // second hand can't take over; searching the full frame, the nearest of two wins.
        handRequest.maximumHandCount = trackedRegionBefore != nil ? 1 : 2
        let candidates = regions.flatMap { detectHands(in: frame.pixelBuffer, region: $0, imageSize: imageSize, brighten: frame.lowLight) }
        for var pose in candidates {
            // Left hand only. Unknown is allowed: Vision can't always tell on a small, far hand.
            if pose.chirality == .right { continue }
            let lidar = sampler.flatMap { palmLiDAR(of: pose, sampler: $0) }
            pose.distance = steadyDistance(of: pose, lidar: lidar, focal: focal)
            if let d = pose.distance, d < minControlDistance || d > maxControlDistance { continue }
            if chosen == nil || (pose.distance ?? .infinity) < (chosen?.distance ?? .infinity) {
                chosen = pose
                chosenLiDAR = lidar
            }
        }
        if let chosen { learnPalmSize(from: chosen, lidar: chosenLiDAR, focal: focal) }

        // 3. Update the tracking crop.
        if let chosen, let box = jointBounds(of: chosen) {
            trackedRegion = squareRegion(around: box, scale: trackingScale, minSide: minTrackingSide, imageSize: imageSize)
            missedFrames = 0
        } else if trackedRegion != nil {
            missedFrames += 1
            if missedFrames >= maxMissedFrames {
                trackedRegion = nil
                missedFrames = 0
            }
        }

        // A hand resting in the lap or on an armrest can be open, still and facing the phone, just
        // like a raised one. Only a raised hand (wrist above elbow) controls anything; a lowered one
        // stays tracked so control resumes the moment it comes up.
        let raised = chosen.map { isHandRaised($0, in: frame.pixelBuffer, time: frame.timestamp) }
        let active = raised == false ? nil : chosen
        onHandPose?(active)
        updateTyping(pose: active, frame: frame)

        if Int(frame.timestamp * 2) != lastDiagnosticTick {
            lastDiagnosticTick = Int(frame.timestamp * 2)
            let source = trackedRegionBefore != nil ? "tracked" : (regions.count > 0 && regions[0] != fullFrame ? "wrist/near" : "full")
            if let chosen, let fingers = fingerShapes(chosen) {
                let shapes = fingers.map { String(format: "%.0f°/%.1f", $0.angle, $0.reach) }.joined(separator: " ")
                let hand = chosen.chirality == .left ? "LEFT" : (chosen.chirality == .right ? "RIGHT" : "unknown")
                let gap2D = chosen.pixelDistance(.thumbTip, .indexTip).flatMap { g in chosen.palmWidthPixels.map { g / $0 } } ?? -1
                let others = fingers.dropFirst().map(\.reach).reduce(0, +) / 3
                print(String(format: "[PINCH-DEBUG] gap %@, 2D ratio %.2f, others reach %.2f, open/closed frames %d/%d, armed %@",
                             chosen.pinchGapMeters.map { String(format: "%.1f cm", $0 * 100) } ?? "n/a", gap2D, others,
                             openFrames, closedFrames, pinchArmed ? "yes" : "no"))
                print(String(format: "[HAND-DEBUG] %@ %@ hand %@, %.2f m, open %@, facing %.2f, fingers %@, awake %@",
                             source, hand, raised == false ? "DOWN" : "raised", chosen.distance ?? -1, isOpenPalmPose(chosen) ? "yes" : "no",
                             chosen.facing ?? -9, shapes, isGestureAwake() ? "yes" : "no"))
            } else {
                let seen = candidates.map { $0.chirality == .left ? "L" : ($0.chirality == .right ? "R" : "?") }.joined()
                print("[HAND-DEBUG] \(source) \(regions.count) region(s), hands seen [\(seen)], none chosen")
            }
        }

        // 0.1 m steps: publishing every frame's distance would redraw the status card constantly.
        let distance = chosen?.distance.map { ($0 * 10).rounded() / 10 }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.handDistance != distance { self.handDistance = distance }
        }
    }

    /// Whether the person's left wrist is clearly above their left elbow (forearm angled up at least
    /// ~15°). Body pose runs every sixth frame; unknown (no body, elbow hidden) doesn't block.
    private func isHandRaised(_ pose: HandPose, in pixelBuffer: CVPixelBuffer, time t: TimeInterval) -> Bool {
        raisedCheckCounter += 1
        if raisedCheckCounter % 6 == 0 || t - lastRaisedTime > 0.6, let palm = pose.palmCenter {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            try? handler.perform([bodyRequest])
            lastRaised = nil
            var bestDistance = CGFloat.infinity
            for body in bodyRequest.results ?? [] {
                guard let wrist = try? body.recognizedPoint(.leftWrist), wrist.confidence > 0.2,
                      let elbow = try? body.recognizedPoint(.leftElbow), elbow.confidence > 0.2 else { continue }
                // The body whose left wrist is nearest this hand.
                let gap = hypot(wrist.location.x - palm.x, wrist.location.y - palm.y)
                guard gap < 0.2, gap < bestDistance else { continue }
                bestDistance = gap
                let size = pose.imageSize
                let rise = (wrist.location.y - elbow.location.y) * size.height
                let forearm = hypot((wrist.location.x - elbow.location.x) * size.width, rise)
                lastRaised = forearm > 0 && rise > forearm * raisedMinRise
            }
            lastRaisedTime = t
        }
        return lastRaised ?? true
    }

    /// A search crop around the most likely wrist, sized from the forearm and shifted toward where the
    /// hand is (past the wrist, away from the elbow). Raised hands (wrist above elbow) first.
    private func wristRegions(in pixelBuffer: CVPixelBuffer, imageSize: CGSize) -> [CGRect] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([bodyRequest])
        var found: [(region: CGRect, raised: Bool)] = []
        for body in (bodyRequest.results ?? []).prefix(3) {
            // Left hand only: search around the person's left wrist.
            for (wristName, elbowName) in [(VNHumanBodyPoseObservation.JointName.leftWrist, VNHumanBodyPoseObservation.JointName.leftElbow)] {
                guard let wrist = try? body.recognizedPoint(wristName), wrist.confidence > 0.2,
                      let elbow = try? body.recognizedPoint(elbowName), elbow.confidence > 0.2 else { continue }
                let w = CGPoint(x: wrist.location.x * imageSize.width, y: wrist.location.y * imageSize.height)
                let e = CGPoint(x: elbow.location.x * imageSize.width, y: elbow.location.y * imageSize.height)
                let forearm = hypot(w.x - e.x, w.y - e.y)
                guard forearm > 4 else { continue }
                // The hand is about 0.7 forearm-lengths long, beyond the wrist.
                let center = CGPoint(x: w.x + (w.x - e.x) * 0.4, y: w.y + (w.y - e.y) * 0.4)
                let side = forearm * 2.2           // MediaPipe's palm detector wants some context
                let box = CGRect(x: (center.x - side / 2) / imageSize.width, y: (center.y - side / 2) / imageSize.height,
                                 width: side / imageSize.width, height: side / imageSize.height)
                found.append((squareRegion(around: box, scale: 1, minSide: minTrackingSide, imageSize: imageSize),
                              wrist.location.y > elbow.location.y))
            }
        }
        return found.sorted { $0.raised && !$1.raised }.prefix(1).map(\.region)
    }

    /// Runs hand pose on `region` (normalized, Vision coords) and maps joints back to the full frame.
    private func detectHands(in pixelBuffer: CVPixelBuffer, region: CGRect, imageSize: CGSize, brighten: Bool = false) -> [HandPose] {
        if mediaPipe.isAvailable {
            return mediaPipe.detect(in: pixelBuffer, region: region, imageSize: imageSize, brighten: brighten)
        }
        let handler: VNImageRequestHandler
        var processed = fullFrame
        if region == fullFrame {
            handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        } else {
            // CIImage and Vision share a bottom-left origin, so the crop maps directly.
            let crop = CGRect(x: region.minX * imageSize.width, y: region.minY * imageSize.height,
                              width: region.width * imageSize.width, height: region.height * imageSize.height).integral
            let image = CIImage(cvPixelBuffer: pixelBuffer)
                .cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            handler = VNImageRequestHandler(ciImage: image, orientation: .up, options: [:])
            processed = CGRect(x: crop.minX / imageSize.width, y: crop.minY / imageSize.height,
                               width: crop.width / imageSize.width, height: crop.height / imageSize.height)
        }
        try? handler.perform([handRequest])
        return (handRequest.results ?? []).map { HandPose(observation: $0, region: processed, imageSize: imageSize) }
    }

    // MARK: - Distance

    /// Camera focal length in pixels, from the format's horizontal field of view.
    private func focalLengthPixels(frame: DepthFrame, imageSize: CGSize) -> Float {
        let rotated = Int(frame.rotationAngle.rounded()) % 180 != 0
        let nativeWidth = Float(rotated ? imageSize.height : imageSize.width)
        return nativeWidth / 2 / tan(frame.horizontalFieldOfView * .pi / 360)
    }

    /// LiDAR at the palm's middle: the median of a 5×5 window, which stays inside a palm at arm's
    /// length and isn't pulled far by edge pixels that see the room behind.
    private func palmLiDAR(of pose: HandPose, sampler: DepthSampler) -> Float? {
        guard let center = pose.palmCenter else { return nil }
        var samples: [Float] = []
        samples.reserveCapacity(25)
        sampler.collect(around: center, radius: 2, into: &samples)
        guard samples.count >= 5 else { return nil }
        samples.sort()
        return samples[samples.count / 2]
    }

    /// Distance from the palm's width on camera once its real size is learned; LiDAR until then.
    private func steadyDistance(of pose: HandPose, lidar: Float?, focal: Float) -> Float? {
        if calibrationReadings >= calibratedAfter, let width = pose.palmWidthPixels, width > 1 {
            return focal * palmSize / width
        }
        return lidar
    }

    /// From far enough out, where LiDAR is accurate, learns the palm size that makes the camera
    /// estimate agree with it. Slowly, in log space, and only from palms that face the camera.
    private func learnPalmSize(from pose: HandPose, lidar: Float?, focal: Float) {
        guard let lidar, calibrationDepthRange.contains(lidar),
              let width = pose.palmWidthPixels, width > 1,
              let facing = pose.facing, abs(facing) >= calibrationMinFacing else { return }
        let target = lidar * width / focal
        guard palmSizeRange.contains(target) else { return }   // something other than a palm
        palmSize = exp(log(palmSize) + (log(target) - log(palmSize)) * palmSizeRate)
        palmSize = min(max(palmSize, palmSizeRange.lowerBound), palmSizeRange.upperBound)
        calibrationReadings += 1
        if calibrationReadings == calibratedAfter {
            print(String(format: "[TYPE-DEBUG] palm size learned: %.1f cm (hand %.2f m away)", palmSize * 100, lidar))
        }
    }

    // MARK: - Typing

    private func updateTyping(pose: HandPose?, frame: DepthFrame) {
        let t = frame.timestamp
        let awake = isGestureAwake()
        let allowed = keyboardActive || awake

        guard let pose, let distance = pose.distance,
              let center = pose.palmCenter, let width = pose.palmWidthPixels else {
            steadyFrames = 0
            openFrames = 0
            closedFrames = 0
            pendingSteps.removeAll()        // hand gone: it was being lowered, not navigating
            if volumeActive {
                volumeActive = false
                volumeFilter.reset()
                pointerNeedsReanchor = true
            }
            if pointerActive {
                lostFrames += 1
                if lostFrames >= releaseFramesRequired { deactivatePointer() }
            } else {
                poseFrames = 0
            }
            return
        }
        lostFrames = 0
        steadyFrames += 1
        let turning = updateTurnGate(facing: pose.facing, time: t)

        let pinched = detectPinch(pose: pose, width: width, turning: turning, time: t)

        guard allowed else {
            if pointerActive { deactivatePointer() }
            return
        }

        // ✌️ volume: while awake, two raised fingers moved up/down change the volume. Handled
        // before the pointer, which pauses meanwhile.
        if awake, updateVolume(pose: pose, center: center, distance: distance, frame: frame) {
            return
        }

        // Engage with an open palm; once on, any pose works (pinching bends the index).
        guard pointerActive else {
            let engages = isOpenPalmPose(pose)
            poseFrames = engages ? poseFrames + 1 : 0
            if poseFrames >= engageFramesRequired {
                activatePointer(position: metricPosition(of: center, depth: distance, frame: frame),
                                distance: distance, time: t)
            }
            return
        }

        let smoothDistance = filterDistance.filter(distance, at: t)
        let raw = metricPosition(of: center, depth: smoothDistance, frame: frame)
        let position = SIMD2(filterX.filter(raw.x, at: t), filterY.filter(raw.y, at: t))
        if pointerNeedsReanchor {
            // Back from volume mode: carry on from where the hand is now, no jump.
            pointerNeedsReanchor = false
            anchor = position
            pendingSteps.removeAll()
        }
        if let last = lastPosition, t > lastPositionTime {
            let velocity = (position - last) / Float(t - lastPositionTime)
            palmVelocity += (velocity - palmVelocity) * 0.5  // light smoothing
            palmSpeed = simd_length(palmVelocity)
        }
        lastPosition = position
        lastPositionTime = t

        // Hand dropping fast = being lowered out of view: discard held steps, send nothing.
        if palmVelocity.y < -exitDropSpeed {
            lastDropTime = t
            pendingSteps.removeAll()
            anchor = position
            return
        }
        for step in pendingSteps where t - step.time >= stepConfirmDelay { emit(step.gesture) }
        pendingSteps.removeAll { t - $0.time >= stepConfirmDelay }

        // Pinch = Select, straight away.
        if pinched {
            press(reason: "pinch", time: t, position: position)
            return
        }

        // Hold steps while pinching or turning (so a press doesn't fire a stray arrow first), and
        // while the hand is a fist: a fist is neutral, so moving it around does nothing.
        let fist = isFist(pose)
        if fist { pendingSteps.removeAll() }
        if isPinched || turning || fist {
            anchor = position
            return
        }

        // ── Arrow steps: one key per keyStep of palm travel, shorter when moving fast ───
        guard t - lastStepTime >= minStepInterval else { return }
        let speedShare = min(palmSpeed / accelerationSpeed, 1)
        let keyStep = keyStepSlow + (keyStepFast - keyStepSlow) * speedShare
        let delta = position - anchor
        let stepsX = abs(delta.x) / keyStep
        let stepsY = abs(delta.y) / keyStep
        if stepsX >= 1, stepsX >= stepsY {
            anchor.x += delta.x > 0 ? keyStep : -keyStep
            anchor.y = position.y
            lastStepTime = t
            pendingSteps.append((delta.x > 0 ? .swipeRight : .swipeLeft, t))
        } else if stepsY >= 1 {
            anchor.y += delta.y > 0 ? keyStep : -keyStep
            anchor.x = position.x
            lastStepTime = t
            pendingSteps.append((delta.y > 0 ? .swipeUp : .swipeDown, t))
        }
    }

    // MARK: - Pinch

    /// A deliberate pinch (thumb tip to index tip): fingers clearly open for a few frames, then
    /// clearly closed for a few, palm toward the phone, not turning, not right after a drop.
    private func detectPinch(pose: HandPose, width: Float, turning: Bool, time t: TimeInterval) -> Bool {
        // With the 3D shape, the fingertip gap in metres; otherwise the 2D gap over palm width.
        // `ratio` is on the 2D scale either way.
        let ratio: Float
        if let meters = pose.pinchGapMeters {
            ratio = meters < pinchCloseMeters ? 0 : (meters > pinchOpenMeters ? 1 : (pinchCloseRatio + pinchOpenRatio) / 2)
        } else if let gap = pose.pixelDistance(.thumbTip, .indexTip) {
            ratio = gap / width
        } else {
            return false
        }
        if ratio > pinchOpenRatio {
            openFrames += 1
            closedFrames = 0
            if openFrames >= pinchStableOpenFrames {
                pinchArmed = true
                lastOpenGapTime = t
            }
        } else if ratio < pinchCloseRatio {
            closedFrames += 1
            openFrames = 0
        } else {
            openFrames = 0
            closedFrames = 0
        }
        isPinched = closedFrames > 0
        // A fist also brings thumb and index together; in a pinch the other fingers stay at least
        // partly open (see pinchMinOtherReach).
        let othersReach = fingerShapes(pose).map { ($0[1].reach + $0[2].reach + $0[3].reach) / 3 } ?? 0
        let deliberate = pinchArmed
            && othersReach >= pinchMinOtherReach
            && closedFrames >= pinchStableClosedFrames
            && t - lastOpenGapTime <= pinchOpenWithin
            && abs(pose.facing ?? 0) >= pinchMinFacing
            && t - lastDropTime >= pinchAfterDrop
            && steadyFrames > pinchSteadyFrames
            && !turning
        guard deliberate else { return false }
        pinchArmed = false
        print(String(format: "[TYPE-DEBUG] pinch %@, facing %.2f", pose.pinchGapMeters.map { String(format: "%.1f cm", $0 * 100) } ?? String(format: "%.2f", ratio), pose.facing ?? -9))
        return true
    }

    private func press(reason: String, time t: TimeInterval, position: SIMD2<Float>) {
        guard t - lastPressTime >= minPressInterval else { return }
        lastPressTime = t
        // Steps made before the press go first, so Select lands where the user moved to.
        pendingSteps.forEach { emit($0.gesture) }
        pendingSteps.removeAll()
        anchor = position
        print("[TYPE-DEBUG] press (\(reason))")
        emit(.select)
    }

    /// True while the hand turns over (and briefly after): edge-on, the fingertips meet on camera
    /// and read as a pinch (CardboardXR's HandTurnGate).
    private func updateTurnGate(facing: Float?, time t: TimeInterval) -> Bool {
        if let facing, let last = lastFacing {
            let dt = t - lastFacingTime
            if dt > 0, dt < 0.5, abs(facing - last) / Float(dt) > turnRate { turningUntil = t + turnHold }
        }
        if let facing { lastFacing = facing; lastFacingTime = t }
        return t < turningUntil
    }

    // MARK: - Volume (✌️)

    /// Returns true while in volume mode (the caller then skips the pointer).
    private func updateVolume(pose: HandPose, center: CGPoint, distance: Float, frame: DepthFrame) -> Bool {
        let t = frame.timestamp
        guard isTwoFingerPose(pose) else {
            volumePoseFrames = 0
            if volumeActive {
                volumeLostFrames += 1
                if volumeLostFrames >= volumeReleaseFrames {
                    volumeActive = false
                    pointerNeedsReanchor = true
                    print("[TYPE-DEBUG] volume mode OFF")
                }
                return volumeActive
            }
            return false
        }
        volumeLostFrames = 0
        let y = volumeFilter.filter(metricPosition(of: center, depth: distance, frame: frame).y, at: t)

        guard volumeActive else {
            volumePoseFrames += 1
            if volumePoseFrames >= volumeEngageFrames {
                volumeActive = true
                volumeAnchorY = y
                lastVolumeStepTime = t
                pendingSteps.removeAll()
                print("[TYPE-DEBUG] volume mode ON")
            }
            return volumeActive
        }

        guard t - lastVolumeStepTime >= volumeStepInterval else { return true }
        let dy = y - volumeAnchorY
        if abs(dy) >= volumeStep {
            volumeAnchorY += dy > 0 ? volumeStep : -volumeStep
            lastVolumeStepTime = t
            emit(dy > 0 ? .volumeUp : .volumeDown)
        }
        return true
    }

    /// Index and middle raised, ring and little folded (thumb ignored).
    private func isTwoFingerPose(_ pose: HandPose) -> Bool {
        guard let f = fingerShapes(pose) else { return false }
        func extended(_ s: (angle: CGFloat, reach: CGFloat)) -> Bool { s.angle >= extendedAngleThreshold || s.reach >= 1.45 }
        func folded(_ s: (angle: CGFloat, reach: CGFloat)) -> Bool { s.reach < 1.35 }
        return extended(f[0]) && extended(f[1]) && folded(f[2]) && folded(f[3])
    }

    /// All four fingers folded (reach measured ~0.7–1.1 in a fist, ≥ 1.4 open).
    private func isFist(_ pose: HandPose) -> Bool {
        guard let fingers = fingerShapes(pose) else { return false }
        return fingers.allSatisfy { $0.reach < 1.25 }
    }

    /// All four fingers extended (thumb ignored): the open palm that drives the pointer.
    private func isOpenPalmPose(_ pose: HandPose) -> Bool {
        guard let fingers = fingerShapes(pose) else { return false }
        // Reach 1.45: past ~2.5 m angles read bent on open hands, reach doesn't (fist ≈ 1.1).
        return fingers.allSatisfy { $0.angle >= extendedAngleThreshold || $0.reach >= 1.45 }
    }

    /// Index, middle, ring, little: bend angle at the middle joint, and fingertip reach from the
    /// wrist relative to the knuckle. A finger angled toward the phone looks shorter and more bent
    /// in the image, so tests accept either measure.
    private func fingerShapes(_ pose: HandPose) -> [(angle: CGFloat, reach: CGFloat)]? {
        // In 3D when MediaPipe's hand shape is available (true bend, no distance distortion).
        func finger(_ mcp: HandPose.JointName, _ pip: HandPose.JointName, _ tip: HandPose.JointName)
            -> (angle: CGFloat, reach: CGFloat)? {
            guard let angle = pose.angle(mcp, pip, tip), let reach = pose.reach(knuckle: mcp, tip: tip) else { return nil }
            return (angle, reach)
        }
        guard let index  = finger(.indexMCP, .indexPIP, .indexTip),
              let middle = finger(.middleMCP, .middlePIP, .middleTip),
              let ring   = finger(.ringMCP, .ringPIP, .ringTip),
              let little = finger(.littleMCP, .littlePIP, .littleTip) else { return nil }
        return [index, middle, ring, little]
    }

    /// A point's position in metres on a plane facing the phone, from the user's point of view
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

    private func activatePointer(position: SIMD2<Float>, distance: Float, time: TimeInterval) {
        pointerActive = true
        print(String(format: "[TYPE-DEBUG] pointer ON at %.2f m (palm %.1f cm, %d LiDAR readings)",
                     distance, palmSize * 100, calibrationReadings))
        filterX.reset(); filterY.reset(); filterDistance.reset()
        lastPosition = nil
        palmSpeed = 0
        palmVelocity = .zero
        pendingSteps.removeAll()
        anchor = SIMD2(filterX.filter(position.x, at: time), filterY.filter(position.y, at: time))
        _ = filterDistance.filter(distance, at: time)
        isPinched = false
        openFrames = 0
        closedFrames = 0
        pinchArmed = false
        lastStepTime = time
        DispatchQueue.main.async { [weak self] in self?.isPointerActive = true }
    }

    private func deactivatePointer() {
        poseFrames = 0
        lostFrames = 0
        isPinched = false
        openFrames = 0
        closedFrames = 0
        pinchArmed = false
        pendingSteps.removeAll()
        guard pointerActive else { return }
        pointerActive = false
        print("[TYPE-DEBUG] pointer OFF")
        DispatchQueue.main.async { [weak self] in self?.isPointerActive = false }
    }

    private func emit(_ gesture: Gesture) {
        onActivity?()
        DispatchQueue.main.async { [weak self] in self?.onPointerGesture?(gesture) }
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

    // MARK: - Geometry

    private func jointBounds(of pose: HandPose) -> CGRect? {
        let points = pose.joints.values.filter { $0.confidence > 0.3 }.map(\.location)
        guard points.count >= 5,
              let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Square (in pixels) crop around `box`, scaled, clamped inside the frame. Normalized Vision coords.
    private func squareRegion(around box: CGRect, scale: CGFloat, minSide: CGFloat, imageSize: CGSize) -> CGRect {
        let shortSide = min(imageSize.width, imageSize.height)
        var side = max(box.width * imageSize.width, box.height * imageSize.height) * scale
        side = min(max(side, shortSide * minSide), shortSide)

        let w = side / imageSize.width
        let h = side / imageSize.height
        let x = min(max(box.midX - w / 2, 0), 1 - w)
        let y = min(max(box.midY - h / 2, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

// MARK: - Depth sampling

/// Reads LiDAR depth at Vision points. Vision points live in the upright video image;
/// the depth map is in sensor-native orientation, so points are rotated between the two.
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
        let native = nativePoint(fromVision: visionPoint)
        let cx = Int(native.x * CGFloat(width))
        let cy = Int(native.y * CGFloat(height))
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

    /// Bounding box (Vision coords) of the surface nearest the phone within range, or nil.
    func nearestObjectRegion(minDepth: Float, maxDepth: Float, band: Float = 0.15) -> CGRect? {
        let stride = 2
        var values: [Float] = []
        values.reserveCapacity((width / stride) * (height / stride))
        for py in Swift.stride(from: 0, to: height, by: stride) {
            let row = base.advanced(by: py * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for px in Swift.stride(from: 0, to: width, by: stride) {
                let value = row[px]
                if value.isFinite, value >= minDepth, value <= maxDepth { values.append(value) }
            }
        }
        guard values.count >= 50 else { return nil }
        values.sort()
        let nearest = values[values.count / 50]          // 2nd percentile: ignores stray pixels
        let limit = nearest + band

        var minX = width, maxX = -1, minY = height, maxY = -1, count = 0
        for py in Swift.stride(from: 0, to: height, by: stride) {
            let row = base.advanced(by: py * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for px in Swift.stride(from: 0, to: width, by: stride) {
                let value = row[px]
                guard value.isFinite, value >= minDepth, value <= limit else { continue }
                minX = min(minX, px); maxX = max(maxX, px)
                minY = min(minY, py); maxY = max(maxY, py)
                count += 1
            }
        }
        guard count >= 12, maxX > minX, maxY > minY else { return nil }
        // A huge "nearest object" is a table or wall, not a hand.
        let area = Float((maxX - minX) * (maxY - minY)) / Float(width * height)
        guard area < 0.25 else { return nil }

        let corners = [
            visionPoint(fromNative: CGPoint(x: CGFloat(minX) / CGFloat(width), y: CGFloat(minY) / CGFloat(height))),
            visionPoint(fromNative: CGPoint(x: CGFloat(maxX) / CGFloat(width), y: CGFloat(maxY) / CGFloat(height))),
        ]
        return CGRect(x: min(corners[0].x, corners[1].x), y: min(corners[0].y, corners[1].y),
                      width: abs(corners[0].x - corners[1].x), height: abs(corners[0].y - corners[1].y))
    }

    // MARK: Orientation

    /// Vision point (upright image, origin bottom-left) → native depth coords (origin top-left).
    private func nativePoint(fromVision p: CGPoint) -> CGPoint {
        let rx = p.x, ry = 1 - p.y
        switch rotation {
        case 90:  return CGPoint(x: ry, y: 1 - rx)
        case 180: return CGPoint(x: 1 - rx, y: 1 - ry)
        case 270: return CGPoint(x: 1 - ry, y: rx)
        default:  return CGPoint(x: rx, y: ry)
        }
    }

    /// Native depth coords (origin top-left) → Vision point (upright image, origin bottom-left).
    private func visionPoint(fromNative n: CGPoint) -> CGPoint {
        let r: CGPoint
        switch rotation {
        case 90:  r = CGPoint(x: 1 - n.y, y: n.x)
        case 180: r = CGPoint(x: 1 - n.x, y: 1 - n.y)
        case 270: r = CGPoint(x: n.y, y: 1 - n.x)
        default:  r = n
        }
        return CGPoint(x: r.x, y: 1 - r.y)
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
