import Vision
import CoreMedia
import Combine
import Foundation
import UIKit

/// Processes camera frames with VNDetectHumanHandPoseRequest and classifies gestures.
///
/// Algorithm: joint-angle classifier at PIP joint (MCP→PIP→TIP) for each finger.
/// Extended finger: angle ≥ 150°  |  Curled finger: angle ≤ 110°
/// This is scale-invariant and robust for varying hand distance from the camera.
///
/// Gesture vocabulary:
///   Open palm moving left/right/up/down → swipe (most reliable, wrist trajectory)
///   Index point (index extended, others curled) → select
final class GestureProcessor: ObservableObject {

    @Published var currentGesture: Gesture = .none
    /// Tracked hand for the on-screen skeleton (updated every frame, observed only by the skeleton view).
    let skeleton = HandSkeletonStore()
    /// Called (on the processing queue) when a hand appears after none was seen for a while.
    var onHandAcquired: (() -> Void)?
    /// Called (on the processing queue) when gestures wake (true) or go to sleep (false).
    var onAwakeChanged: ((Bool) -> Void)?
    /// Gestures that go to the TV immediately, bypassing currentGesture's change/cooldown gate.
    var onImmediateGesture: ((Gesture) -> Void)?
    private var lastHandSeen = Date.distantPast
    private let handReacquireGap: TimeInterval = 0.7
    @Published private(set) var isAwake = false
    
    private var deviceOrientation: UIDeviceOrientation = .portrait

    private let gestureCooldown: TimeInterval = 1.4
    private let neutralFramesRequired = 6
    private var neutralFrameCount = 0
    private var lastGestureTime: Date = .distantPast

    // Wrist trajectory for swipe detection
    private var wristHistory: [CGPoint] = []
    private let maxHistoryCount = 10
    // Wrist→middle knuckle as a fraction of the frame. 0.04 dropped every hand past ~1.5 m: at
    // 2.4 m in LiDAR mode (1920×1080, phone upright) it measures ~0.025.
    private let minimumHandSpan: CGFloat = 0.012

    // Swipe thresholds — expressed as multiples of hand span so they scale with distance
    // A typical close-up hand span (wrist→middleMCP) is ~0.20; far-away ~0.06.
    // Note: These are base values for portrait. In landscape, we adjust for aspect ratio.
    private let swipeSpanMultiplierH: CGFloat = 1.0   // horiz swipe needs 100% of span travel
    private let swipeSpanMultiplierV: CGFloat = 1.4   // vert swipe needs 140% of span travel
    private let swipeAxisDominance: CGFloat = 1.5     // dominant axis must be 50% stronger
    private let swipeStepSpanFraction: CGFloat = 0.04  // per-step min = 4% of span
    
    // Aspect ratio correction for landscape mode (accounts for screen geometry change)
    // In landscape, the normalized coordinate range spans a wider physical distance,
    // so we reduce thresholds proportionally to maintain consistent UX across orientations.
    private let landscapeThresholdFactor: CGFloat = 0.55  // reduce by ~45% in landscape for consistent feel
    private let landscapeHorizontalFactor: CGFloat = 0.12  // ~88% reduction for horizontal swipes
    
    private var currentHandSpan: CGFloat = 0.15        // updated each frame

    // Angle thresholds (degrees)
    private let extendedAngleThreshold: CGFloat = 150
    private let extendedReachThreshold: CGFloat = 1.45
    private let curledAngleThreshold: CGFloat = 110
    private let thumbExtendedAngleThreshold: CGFloat = 120  // for open palm detection
    private let thumbUpAngleThreshold: CGFloat = 130        // thumbs-up only; more achievable

    // Frame counters for static gesture confirmation
    private let staticFramesRequired = 6
    private let thumbsUpFramesRequired = 6    // short hold; pose geometry should do most of the filtering
    private let thumbsDownFramesRequired = 6  // short hold; pose geometry should do most of the filtering
    // Palm: still for ~2 s fires playPause; any movement fires a swipe
    private let palmStillFramesRequired = 18   // ~0.6 s at 30 fps (easier palm detection)
    private let palmStillThreshold: CGFloat = 0.15  // fraction of hand span = "not moved"
    private var palmFrameCount = 0             // counts frames palm has been visible
    private var palmStillFrames = 0            // counts consecutive still frames
    private var palmAnchor: CGPoint = .zero    // wrist position when palm was first seen
    private var palmWasOpen = false            // tracks palm→fist transition for menu
    private var thumbsUpFrameCount = 0
    private var thumbsDownFrameCount = 0
    // Measured on device: an open palm facing the phone reads 0.6–0.8 at 1 m but only 0.3–0.45 at
    // 2.7–2.9 m (the palm looks squeezed that far away); edge-on stays near 0.
    private let wakeMinFacing: Float = 0.25
    private let wakeHoldSeconds: TimeInterval = 1.5
    private let wakeStillThreshold: CGFloat = 0.25    // wrist drift allowed, in hand spans
    private let wakeFlickerGrace: TimeInterval = 0.25  // open palm missed this long → start over
    private var wakeStillSince: Date?
    // Hand flip (Back)
    private let flipMinFacing: Float = 0.25
    private let flipHoldSeconds: TimeInterval = 0.1
    private let flipCooldown: TimeInterval = 0.5
    private var lastFlipTime = Date.distantPast
    private var palmSide: Float = 0              // sign of `facing` when the palm shows; 0 = unknown
    private var learningSide: Float = 0
    private var learningSince: Date?
    private var backShownSince: Date?
    private var flipArmed = false
    private var pointerHandlesSwipes = false
    private var wakeAnchor: CGPoint = .zero
    private var lastWakePalmSeen = Date.distantPast
    private let sleepAfterNoGestureInterval: TimeInterval = 5
    private var palmWakeEnabled = true
    private var wakeBlockedUntil = Date.distantPast
    private let wakeBlockSeconds: TimeInterval = 3
    private var thumbsEnabled = true    // off in LiDAR mode: a closing fist read as thumbs-up
    private var lastGestureRecognitionTime = Date.distantPast
    private var sleepMonitorTimer: DispatchSourceTimer?

    var isFrontCamera: Bool = false

    private let handRequest = VNDetectHumanHandPoseRequest()
    private let processingQueue = DispatchQueue(label: "gesture.processing", qos: .userInteractive)

    init() {
        handRequest.maximumHandCount = 1
        
        // Observe device orientation changes to update coordinate transforms
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )

        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.isAwake else { return }
            guard Date().timeIntervalSince(self.lastGestureRecognitionTime) >= self.sleepAfterNoGestureInterval else { return }
            self.sleepRecognition()
        }
        sleepMonitorTimer = timer
        timer.resume()
    }
    
    deinit {
        sleepMonitorTimer?.cancel()
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func deviceOrientationDidChange() {
        let newOrientation = UIDevice.current.orientation
        // Only update for actionable orientations; ignore face-up/down/unknown
        switch newOrientation {
        case .portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight:
            processingQueue.async { [weak self] in
                self?.deviceOrientation = newOrientation
            }
        default:
            break
        }
    }
    
    // MARK: - Orientation Mapping
    
    /// Maps UIDeviceOrientation to CGImagePropertyOrientation for Vision framework.
    /// This ensures Vision processes coordinates in a consistent frame of reference.
    private func deviceOrientationToVisionOrientation(_ orientation: UIDeviceOrientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .portrait:           return .up
        case .portraitUpsideDown: return .down
        case .landscapeLeft:      return .right
        case .landscapeRight:     return .left
        default:                  return .up  // unknown: default to portrait
        }
    }
    
    /// Check if device is in landscape orientation.
    private var isLandscape: Bool {
        switch deviceOrientation {
        case .landscapeLeft, .landscapeRight:
            return true
        default:
            return false
        }
    }

    func process(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        processingQueue.async { [weak self] in
            self?.runVision(on: pixelBuffer)
        }
    }

    func process(pixelBuffer: CVPixelBuffer) {
        processingQueue.async { [weak self] in
            self?.runVision(on: pixelBuffer)
        }
    }

    /// LiDAR mode: the hand was already detected (camera + depth), so skip running Vision twice.
    func process(pose: HandPose?) {
        processingQueue.async { [weak self] in
            self?.handle(pose: pose)
        }
    }

    /// LiDAR mode: the open-palm pointer moves the selection continuously (so one-step swipes would
    /// double up with it), and two quick pinches put gestures to sleep.
    func setLiDARControls(_ enabled: Bool) {
        processingQueue.async { [weak self] in
            self?.pointerHandlesSwipes = enabled
            self?.thumbsEnabled = !enabled      // pinch selects, hand flip goes back
        }
    }

    /// Double pinch (LiDAR mode): wake or sleep directly. After a sleep the hand is usually still
    /// up and open, so palm-hold wake waits until it's lowered (or wakeBlockSeconds pass).
    func setAwake(_ awake: Bool) {
        processingQueue.async { [weak self] in
            guard let self, self.isAwake != awake else { return }
            if awake {
                self.wakeRecognition()
            } else {
                self.sleepRecognition()
                self.wakeBlockedUntil = Date().addingTimeInterval(self.wakeBlockSeconds)
            }
        }
    }

    /// Keeps gestures awake while the pointer is moving (it doesn't emit classic gestures).
    func noteActivity() {
        processingQueue.async { [weak self] in
            guard let self, self.isAwake else { return }
            self.lastGestureRecognitionTime = Date()
        }
    }

    private func runVision(on pixelBuffer: CVPixelBuffer) {
        // Always use .up orientation; Vision will report coordinates consistently
        // regardless of device rotation. We handle landscape adjustment in swipe detection.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([handRequest])
        let imageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        handle(pose: handRequest.results?.first.map { HandPose(observation: $0, imageSize: imageSize) })
    }

    private func handle(pose: HandPose?) {
        skeleton.update(pose)
        if pose != nil {
            let now = Date()
            if now.timeIntervalSince(lastHandSeen) > handReacquireGap {
                wakeBlockedUntil = .distantPast     // hand was lowered: palm wake allowed again
                onHandAcquired?()
                forgetPalmSide()        // maybe the other hand: learn its palm side afresh
            }
            lastHandSeen = now
        }
        guard let pose,
              let analysis = analyzeHand(from: pose) else {
            if Date().timeIntervalSince(lastWakePalmSeen) > wakeFlickerGrace { wakeStillSince = nil }
            markNeutralFrame()
            reset()
            return
        }

        currentHandSpan = analysis.handSpan

        if !isAwake && (!palmWakeEnabled || Date() < wakeBlockedUntil) { return }
        if !isAwake {
            // Wake: an open palm facing the camera (not edge-on, after CardboardXR), held fairly
            // still for wakeHoldSeconds. Timed rather than counted in frames, so it feels the same
            // in LiDAR mode (fewer frames per second), and brief misses of one finger are forgiven.
            let now = Date()
            if analysis.isOpenPalm && abs(pose.facing ?? 1) >= wakeMinFacing {
                lastWakePalmSeen = now
                if let since = wakeStillSince,
                   dist(analysis.wrist, wakeAnchor) < analysis.handSpan * wakeStillThreshold {
                    if now.timeIntervalSince(since) >= wakeHoldSeconds {
                        if let facing = pose.facing { palmSide = facing > 0 ? 1 : -1; flipArmed = true }
                        wakeRecognition()
                    }
                } else {
                    wakeStillSince = now
                    wakeAnchor = analysis.wrist
                }
            } else if now.timeIntervalSince(lastWakePalmSeen) > wakeFlickerGrace {
                wakeStillSince = nil
            }
            return
        }

        if Date().timeIntervalSince(lastGestureRecognitionTime) >= sleepAfterNoGestureInterval {
            sleepRecognition()
            return
        }

        // ── Hand flip → Back ─────────────────────────────────────────────────────
        // Sent straight to the TV (not via currentGesture, which only reports changes and waits
        // for neutral frames and the 1.4 s cooldown), so flips land quickly and back to back.
        // Open hand only: twisting a fist also changes which side faces the camera.
        if analysis.isOpenPalm, let facing = pose.facing, detectFlip(facing: facing) {
            let now = Date()
            if now.timeIntervalSince(lastFlipTime) >= flipCooldown {
                lastFlipTime = now
                lastGestureRecognitionTime = now
                print("[GESTURE-DEBUG] back (hand flip)")
                DispatchQueue.main.async { [weak self] in self?.onImmediateGesture?(.back) }
            }
            return
        }

        // ── Thumbs up → Select ─────────────────────────────────────────────
        if analysis.isThumbsUp && thumbsEnabled {
            thumbsUpFrameCount += 1
            thumbsDownFrameCount = 0
            palmFrameCount = 0
            wristHistory.removeAll(keepingCapacity: true)
            if thumbsUpFrameCount == thumbsUpFramesRequired {
                emitGesture(.select)
            }
            return
        }
        thumbsUpFrameCount = 0

        // ── Thumbs down → Menu/Back ───────────────────────────────────────────
        if analysis.isThumbsDown && thumbsEnabled {
            thumbsDownFrameCount += 1
            palmFrameCount = 0
            wristHistory.removeAll(keepingCapacity: true)
            if thumbsDownFrameCount == thumbsDownFramesRequired {
                emitGesture(.back)
            }
            return
        }
        thumbsDownFrameCount = 0

        // ── Open palm → Moving = Swipe ──────────────────────────────────────────────
        if analysis.isOpenPalm {
            palmFrameCount += 1

            // Require palm visible for at least 10 frames before enabling palm→fist
            if palmFrameCount >= 10 {
                palmWasOpen = true
            }

            // Anchor is set on the very first frame the palm appears after a reset.
            if palmFrameCount == 1 {
                palmAnchor = analysis.wrist
                palmStillFrames = 0
            }

            let displacement = dist(analysis.wrist, palmAnchor)
            let isStill = displacement < analysis.handSpan * palmStillThreshold

            if isStill {
                palmStillFrames += 1
                wristHistory.removeAll(keepingCapacity: true)
            } else {
                // Palm is moving — record trajectory, check swipe.
                palmStillFrames = 0
                wristHistory.append(analysis.wrist)
                if wristHistory.count > maxHistoryCount {
                    wristHistory.removeFirst(wristHistory.count - maxHistoryCount)
                }
                if !pointerHandlesSwipes, let swipe = detectSwipe() {
                    reset()
                    emitGesture(swipe)
                }
            }
            return
        }

        // A fist does nothing (palm → fist used to send Home; removed as too easy to trigger).

        palmFrameCount = 0
        palmWasOpen = false
        markNeutralFrame()
        reset()
    }

    // MARK: - Hand Analysis

    private struct HandAnalysis {
        let wrist: CGPoint
        let handSpan: CGFloat
        let isOpenPalm: Bool
        let isClosedFist: Bool
        let isThumbsUp: Bool
        let isThumbsDown: Bool
    }

    private func analyzeHand(from pose: HandPose) -> HandAnalysis? {
        guard
            let wrist     = pose.joint(.wrist),
            let middleMCP = pose.joint(.middleMCP),
            wrist.confidence > 0.35,
            middleMCP.confidence > 0.35
        else { return nil }

        let wristPos = wrist.location
        let span = dist(wristPos, middleMCP.location)
        guard span >= minimumHandSpan else { return nil }

        guard let fingers = classifyFingers(from: pose, handSpan: span) else { return nil }

        return HandAnalysis(
            wrist: wristPos,
            handSpan: span,
            isOpenPalm: fingers.isOpenPalm,
            isClosedFist: fingers.isClosedFist,
            isThumbsUp: fingers.isThumbsUp,
            isThumbsDown: fingers.isThumbsDown
        )
    }

    // MARK: - Joint-angle finger classifier

    private struct FingerStates {
        let indexExtended: Bool
        let middleExtended: Bool
        let ringExtended: Bool
        let littleExtended: Bool
        let thumbExtended: Bool       // ≥120° — used for open palm
        let thumbFullyExtended: Bool  // ≥150° — used for thumbs-up only
        let indexCurled: Bool
        let middleCurled: Bool
        let ringCurled: Bool
        let littleCurled: Bool
        // Thumb direction uses tip relative to IP so it remains stable when the base joint rotates.
        // Vision coordinates are normalized with y increasing upward.
        let thumbTipX: CGFloat
        let thumbIPX: CGFloat
        let thumbTipY: CGFloat
        let thumbIPY: CGFloat
        let wristY: CGFloat
        let knuckleLineY: CGFloat  // indexMCP Y — anchor for true upward extension check
        let handSpan: CGFloat   // used to make direction threshold scale-invariant

        private var thumbDeltaX: CGFloat { thumbTipX - thumbIPX }
        private var thumbDeltaY: CGFloat { thumbTipY - thumbIPY }
        // Keep vertical-bias strict enough to reject sideways thumbs but allow natural tilt.
        private var thumbVerticalBias: Bool { abs(thumbDeltaY) > abs(thumbDeltaX) * 3.0 }
        // Thumb tip must be clearly above wrist.
        private var thumbClearlyAboveWrist: Bool { thumbTipY > wristY + handSpan * 0.20 }
        let fingerTipClusterX: CGFloat
        let fingerTipClusterY: CGFloat
        // Thumb tip must be above the knuckle line; this still blocks fist-like thumbs.
        private var thumbAboveKnuckleLine: Bool { thumbTipY > knuckleLineY + handSpan * 0.12 }
        private var thumbClearlyBelowWrist: Bool { thumbTipY < wristY - handSpan * 0.12 }
        // Thumbs-down: tip is below IP joint by at least 10% of span.
        private var thumbPointingDown: Bool { thumbDeltaY < -handSpan * 0.14 }
        // Thumb tip must be above IP joint by a meaningful margin.
        private var thumbPointingUp:   Bool { thumbDeltaY >  handSpan * 0.18 }
        // Loose fist: finger is curled OR not clearly extended (catches bent-but-not-fully-curled fingers)
        private var indexFisted: Bool  { indexCurled  || !indexExtended }
        private var middleFisted: Bool { middleCurled || !middleExtended }
        private var ringFisted: Bool   { ringCurled   || !ringExtended }
        private var littleFisted: Bool { littleCurled || !littleExtended }

        // Strict fist: ALL 4 fingers must be clearly curled (angle ≤ curledAngleThreshold)
        // This is much tighter than "not extended" and avoids false positives from relaxed hands.
        var isClosedFist: Bool {
            indexFisted && middleFisted && ringFisted && littleFisted
        }

        // All 4 fingers + thumb open → open palm for swipes
        // Thumb not required: it's the least reliable joint on a hand a few metres away.
        var isOpenPalm: Bool {
            indexExtended && middleExtended && ringExtended && littleExtended
        }
        // Thumbs up (select): loose fist (fingers curled or not clearly extended) with thumb clearly extended upward
        // Only triggers from a fist, not a palm (all non-thumb fingers must not be extended)
        var isThumbsUp: Bool {
            // Block if thumb and index fingertip are close together (touching)
            let thumbIndexDist = hypot(thumbTipX - indexTipX, thumbTipY - indexTipY)
            let minSeparation = handSpan * 0.20 // must be clearly separated
            return indexFisted && middleFisted && ringFisted && littleFisted
                && thumbFullyExtended && thumbVerticalBias && thumbPointingUp
                && thumbClearlyAboveWrist && thumbAboveKnuckleLine
                && thumbIndexDist > minSeparation
        }
            // Add indexTip for thumb-index distance check
            let indexTipX: CGFloat
            let indexTipY: CGFloat
        // Thumbs down: fist with thumb pointing downward and vertical-bias (not sideways)
        var isThumbsDown: Bool {
            indexFisted && middleFisted && ringFisted && littleFisted
                && thumbVerticalBias && thumbPointingDown && thumbClearlyBelowWrist
        }
    }

    private func classifyFingers(from pose: HandPose, handSpan: CGFloat) -> FingerStates? {
        guard
            let indexMCP  = pose.joint(.indexMCP),
            let indexPIP  = pose.joint(.indexPIP),
            let indexTip  = pose.joint(.indexTip),
            let middleMCP = pose.joint(.middleMCP),
            let middlePIP = pose.joint(.middlePIP),
            let middleTip = pose.joint(.middleTip),
            let ringMCP   = pose.joint(.ringMCP),
            let ringPIP   = pose.joint(.ringPIP),
            let ringTip   = pose.joint(.ringTip),
            let littleMCP = pose.joint(.littleMCP),
            let littlePIP = pose.joint(.littlePIP),
            let littleTip = pose.joint(.littleTip),
            let thumbCMC  = pose.joint(.thumbCMC),
            let thumbIP   = pose.joint(.thumbIP),
            let thumbTip  = pose.joint(.thumbTip),
            indexMCP.confidence  > 0.30, indexPIP.confidence  > 0.30, indexTip.confidence  > 0.30,
            middleMCP.confidence > 0.30, middlePIP.confidence > 0.30, middleTip.confidence > 0.30,
            ringMCP.confidence   > 0.30, ringPIP.confidence   > 0.30, ringTip.confidence   > 0.30,
            littleMCP.confidence > 0.30, littlePIP.confidence > 0.30, littleTip.confidence > 0.30,
            thumbCMC.confidence  > 0.30, thumbIP.confidence   > 0.30, thumbTip.confidence  > 0.30
        else { return nil }

        // Angle at PIP joint (A=MCP, center=PIP, B=Tip)
        // 3D bend when MediaPipe's hand shape is available, else 2D.
        let ia = pose.angle(.indexMCP, .indexPIP, .indexTip) ?? jointAngle(indexMCP.location, indexPIP.location, indexTip.location)
        let ma = pose.angle(.middleMCP, .middlePIP, .middleTip) ?? jointAngle(middleMCP.location, middlePIP.location, middleTip.location)
        let ra = pose.angle(.ringMCP, .ringPIP, .ringTip) ?? jointAngle(ringMCP.location, ringPIP.location, ringTip.location)
        let la = pose.angle(.littleMCP, .littlePIP, .littleTip) ?? jointAngle(littleMCP.location, littlePIP.location, littleTip.location)
        // Thumb: CMC → IP → Tip
        let ta = pose.angle(.thumbCMC, .thumbIP, .thumbTip) ?? jointAngle(thumbCMC.location, thumbIP.location, thumbTip.location)

        // Fingertip reach from the wrist over the knuckle's. Past ~2.5 m the middle joints are placed
        // badly and an open hand's angles read 20–120°, but reach still separates it: measured
        // 1.5–2.1 open against ~1.1 for a fist. A finger is extended by either measure.
        func extended(_ angle: CGFloat, _ mcp: HandPose.JointName, _ tip: HandPose.JointName) -> Bool {
            angle >= extendedAngleThreshold || (pose.reach(knuckle: mcp, tip: tip) ?? 0) >= extendedReachThreshold
        }

        // Compute the average position of all fingertips for fingerTipClusterX/Y
        let tipXs = [indexTip.location.x, middleTip.location.x, ringTip.location.x, littleTip.location.x]
        let tipYs = [indexTip.location.y, middleTip.location.y, ringTip.location.y, littleTip.location.y]
        let fingerTipClusterX = tipXs.reduce(0, +) / CGFloat(tipXs.count)
        let fingerTipClusterY = tipYs.reduce(0, +) / CGFloat(tipYs.count)
        return FingerStates(
            indexExtended:  extended(ia, .indexMCP, .indexTip),
            middleExtended: extended(ma, .middleMCP, .middleTip),
            ringExtended:   extended(ra, .ringMCP, .ringTip),
            littleExtended: extended(la, .littleMCP, .littleTip),
            thumbExtended:  ta >= thumbExtendedAngleThreshold,
            thumbFullyExtended: ta >= thumbUpAngleThreshold,
            indexCurled:    ia <= curledAngleThreshold,
            middleCurled:   ma <= curledAngleThreshold,
            ringCurled:     ra <= curledAngleThreshold,
            littleCurled:   la <= curledAngleThreshold,
            // Vision y=0 is at the bottom of the frame for both cameras; no flip needed.
            thumbTipX:      thumbTip.location.x,
            thumbIPX:       thumbIP.location.x,
            thumbTipY:      thumbTip.location.y,
            thumbIPY:       thumbIP.location.y,
            wristY:         pose.joint(.wrist)?.location.y ?? thumbIP.location.y,
            knuckleLineY:   indexMCP.location.y,
            handSpan:       handSpan,
            fingerTipClusterX: fingerTipClusterX,
            fingerTipClusterY: fingerTipClusterY,
            indexTipX:      indexTip.location.x,
            indexTipY:      indexTip.location.y
        )
    }

    /// Angle in degrees at `center`, between vectors center→a and center→b.
    private func jointAngle(_ a: CGPoint, _ center: CGPoint, _ b: CGPoint) -> CGFloat {
        let v1x = a.x - center.x, v1y = a.y - center.y
        let v2x = b.x - center.x, v2y = b.y - center.y
        let dot  = v1x * v2x + v1y * v2y
        let mag1 = sqrt(v1x * v1x + v1y * v1y)
        let mag2 = sqrt(v2x * v2x + v2y * v2y)
        guard mag1 > 0.001, mag2 > 0.001 else { return 0 }
        return acos(max(-1, min(1, dot / (mag1 * mag2)))) * 180 / .pi
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    // MARK: - Swipe Detection (wrist trajectory)

    private func detectSwipe() -> Gesture? {
        guard wristHistory.count >= 6 else { return nil }

        let start   = wristHistory[0]
        let end     = wristHistory[wristHistory.count - 1]
        let rawDx   = end.x - start.x
        // Vision x increases left-to-right in the raw camera buffer, but from the user's
        // perspective (looking toward the camera) right-hand movement decreases Vision x.
        // This holds for BOTH front and back cameras, so we always negate.
        let totalDx = -rawDx
        let totalDy = end.y - start.y
        let absDx   = abs(totalDx)
        let absDy   = abs(totalDy)

        // Scale thresholds by current hand span so they work at any distance
        var stepThreshold = currentHandSpan * swipeStepSpanFraction
        var hThreshold    = currentHandSpan * swipeSpanMultiplierH
        var vThreshold    = currentHandSpan * swipeSpanMultiplierV
        
        // In landscape mode, dramatically reduce thresholds for horizontal movement
        // Physical left/right swipes (Y-axis) span a much wider distance, so use aggressive factor on vThreshold
        // Physical up/down swipes (X-axis) are normal, so use moderate factor on hThreshold
        if isLandscape {
            stepThreshold *= landscapeThresholdFactor
            hThreshold *= landscapeThresholdFactor       // moderate reduction for up/down
            vThreshold *= landscapeHorizontalFactor      // much more aggressive for left/right
        }

        let deltas = zip(wristHistory, wristHistory.dropFirst()).map {
            CGPoint(x: $1.x - $0.x, y: $1.y - $0.y)
        }
        
        // For landscape horizontal swipes, use an even more relaxed step threshold
        let hStepThreshold = stepThreshold
        let vStepThreshold = isLandscape ? (currentHandSpan * swipeStepSpanFraction * landscapeHorizontalFactor) : stepThreshold

        if absDx >= hThreshold && absDx > absDy * swipeAxisDominance {
            let direction: CGFloat = totalDx > 0 ? 1 : -1
            // Alignment check also uses negated rawDx so steps match the corrected direction
            let aligned = deltas.filter {
                abs($0.x) >= hStepThreshold && (-$0.x * direction) > 0
            }.count
            guard aligned >= max(2, deltas.count - 2) else { return nil }  // most steps must be on-axis
            return totalDx > 0 ? .swipeRight : .swipeLeft
        }

        if absDy >= vThreshold && absDy > absDx * swipeAxisDominance {
            let direction: CGFloat = totalDy > 0 ? 1 : -1
            let aligned = deltas.filter {
                abs($0.y) >= vStepThreshold && ($0.y * direction) > 0
            }.count
            guard aligned >= max(2, deltas.count - 2) else { return nil }  // most steps must be on-axis
            return totalDy > 0 ? .swipeUp : .swipeDown
        }

        return nil
    }

    // MARK: - Hand flip

    /// Back = turning the hand over so its back faces the camera. Which side is the palm isn't
    /// known from the image alone (it depends on left/right hand), so it's learned: the side shown
    /// at wake, or the side held steadily after the hand is raised. The flip fires once the back
    /// is held for flipHoldSeconds, and re-arms when the palm faces the camera again.
    /// Uses the palm-facing measure, which stays strong (0.65–0.9) even 3–4 m away.
    private func detectFlip(facing: Float) -> Bool {
        let now = Date()
        guard abs(facing) >= flipMinFacing else { return false }   // edge-on: mid-turn
        let side: Float = facing > 0 ? 1 : -1

        if palmSide == 0 {
            if side != learningSide { learningSide = side; learningSince = now }
            if let since = learningSince, now.timeIntervalSince(since) >= flipHoldSeconds {
                palmSide = side
                flipArmed = true
            }
            return false
        }
        if side == palmSide {
            flipArmed = true
            backShownSince = nil
            return false
        }
        guard flipArmed else { return false }
        if backShownSince == nil { backShownSince = now }
        if let since = backShownSince, now.timeIntervalSince(since) >= flipHoldSeconds {
            flipArmed = false
            backShownSince = nil
            return true
        }
        return false
    }

    private func forgetPalmSide() {
        palmSide = 0
        learningSide = 0
        learningSince = nil
        backShownSince = nil
        flipArmed = false
    }

    // MARK: - State helpers

    private func wakeRecognition() {
        wakeStillSince = nil
        print("[WAKE-DEBUG] gestures awake")
        isAwake = true
        onAwakeChanged?(true)
        lastGestureRecognitionTime = Date()
        neutralFrameCount = neutralFramesRequired
        lastGestureTime = .distantPast
        DispatchQueue.main.async { [weak self] in self?.currentGesture = .none }
        reset()
    }

    private func sleepRecognition() {
        wakeStillSince = nil
        isAwake = false
        onAwakeChanged?(false)
        neutralFrameCount = 0
        lastGestureTime = .distantPast
        DispatchQueue.main.async { [weak self] in self?.currentGesture = .none }
        reset()
    }

    private func reset() {
        wristHistory.removeAll(keepingCapacity: true)
        thumbsUpFrameCount = 0
        thumbsDownFrameCount = 0
        palmFrameCount = 0
        palmStillFrames = 0
        palmAnchor = .zero
        palmWasOpen = false
    }

    private func markNeutralFrame() {
        neutralFrameCount = min(neutralFrameCount + 1, neutralFramesRequired)
        if currentGesture != .none {
            DispatchQueue.main.async { [weak self] in self?.currentGesture = .none }
        }
    }

    private func emitGesture(_ gesture: Gesture) {
        let now = Date()
        guard neutralFrameCount >= neutralFramesRequired else { return }
        guard now.timeIntervalSince(lastGestureTime) >= gestureCooldown else { return }
        neutralFrameCount = 0
        lastGestureTime = now
        lastGestureRecognitionTime = now
        DispatchQueue.main.async { [weak self] in self?.currentGesture = gesture }
    }

}
