import Combine
import SwiftUI
import simd
import Vision

// MARK: - Hand pose

/// Hand joints in Vision coordinates of the full (upright) camera frame:
/// normalized 0…1, origin bottom-left. Detection may run on a crop; points are mapped back here.
struct HandPose {
    struct Joint {
        let location: CGPoint
        let confidence: Float
    }

    typealias JointName = VNHumanHandPoseObservation.JointName

    let joints: [JointName: Joint]
    /// Pixel size of the frame the joints refer to (for aspect-correct drawing).
    let imageSize: CGSize
    /// LiDAR distance to the palm in metres, when available.
    var distance: Float?
    /// Which hand this is (the person's own left/right).
    let chirality: VNChirality
    /// The hand's 3D shape in metres (MediaPipe world landmarks: x right, y up, z toward the
    /// camera, around the hand's centre). Nil with Apple Vision, which only gives 2D points.
    let world: [JointName: SIMD3<Float>]?

    /// - Parameter region: the normalized area of the full frame that Vision actually processed.
    init(observation: VNHumanHandPoseObservation,
         region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
         imageSize: CGSize) {
        var joints: [JointName: Joint] = [:]
        if let points = try? observation.recognizedPoints(.all) {
            for (name, point) in points where point.confidence > 0 {
                let location = CGPoint(x: region.minX + point.location.x * region.width,
                                       y: region.minY + point.location.y * region.height)
                joints[name] = Joint(location: location, confidence: point.confidence)
            }
        }
        self.joints = joints
        self.imageSize = imageSize
        self.chirality = observation.chirality
        self.world = nil
    }

    init(joints: [JointName: Joint], world: [JointName: SIMD3<Float>]?, imageSize: CGSize, chirality: VNChirality) {
        self.joints = joints
        self.world = world
        self.imageSize = imageSize
        self.chirality = chirality
    }

    func joint(_ name: JointName) -> Joint? {
        joints[name]
    }
}

// MARK: - Palm measurements
// After CardboardXR (github.com/brenpoly/CardboardXR, Apache 2.0): the wrist and four knuckles
// hold still relative to each other, so the palm is what's steady to measure and follow.

extension HandPose {
    static let palmJoints: [JointName] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]

    private func confidentPalm() -> [CGPoint]? {
        let points = Self.palmJoints.compactMap { name -> CGPoint? in
            guard let joint = joint(name), joint.confidence > 0.3 else { return nil }
            return joint.location
        }
        return points.count == Self.palmJoints.count ? points : nil
    }

    /// Middle of the palm (Vision coords).
    var palmCenter: CGPoint? {
        guard let points = confidentPalm() else { return nil }
        return CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                       y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
    }

    /// The palm's average width on camera, in pixels: mean distance between its five landmarks.
    var palmWidthPixels: Float? {
        guard let points = confidentPalm() else { return nil }
        var total: CGFloat = 0
        var pairs = 0
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                total += hypot((points[i].x - points[j].x) * imageSize.width,
                               (points[i].y - points[j].y) * imageSize.height)
                pairs += 1
            }
        }
        return Float(total / CGFloat(pairs))
    }

    /// Bend at the middle joint in degrees (180 = straight): in 3D when the shape is known, so a
    /// finger angled toward the camera isn't read as bent.
    func angle(_ a: JointName, _ center: JointName, _ b: JointName) -> CGFloat? {
        if let world, let p = world[a], let c = world[center], let q = world[b] {
            let v1 = p - c, v2 = q - c
            let lengths = simd_length(v1) * simd_length(v2)
            guard lengths > 0 else { return nil }
            return CGFloat(acos(max(-1, min(1, simd_dot(v1, v2) / lengths))) * 180 / .pi)
        }
        guard let p = joint(a), let c = joint(center), let q = joint(b),
              p.confidence > 0.3, c.confidence > 0.3, q.confidence > 0.3 else { return nil }
        let v1x = p.location.x - c.location.x, v1y = p.location.y - c.location.y
        let v2x = q.location.x - c.location.x, v2y = q.location.y - c.location.y
        let lengths = hypot(v1x, v1y) * hypot(v2x, v2y)
        guard lengths > 0.000001 else { return nil }
        return acos(max(-1, min(1, (v1x * v2x + v1y * v2y) / lengths))) * 180 / .pi
    }

    /// Fingertip reach from the wrist over the knuckle's (open ≈ 1.5–2, fist ≈ 1), in 3D when known.
    func reach(knuckle: JointName, tip: JointName) -> CGFloat? {
        if let world, let w = world[.wrist], let k = world[knuckle], let t = world[tip] {
            let base = simd_length(k - w)
            return base > 0 ? CGFloat(simd_length(t - w) / base) : nil
        }
        guard let w = joint(.wrist), let k = joint(knuckle), let t = joint(tip),
              w.confidence > 0.3, k.confidence > 0.3, t.confidence > 0.3 else { return nil }
        let base = hypot(k.location.x - w.location.x, k.location.y - w.location.y)
        return base > 0.001 ? hypot(t.location.x - w.location.x, t.location.y - w.location.y) / base : nil
    }

    /// Thumb tip to index tip in metres, from the 3D shape (nil without it).
    var pinchGapMeters: Float? {
        guard let world, let thumb = world[.thumbTip], let index = world[.indexTip] else { return nil }
        return simd_length(thumb - index)
    }

    /// Fingertip-to-fingertip distance in pixels.
    func pixelDistance(_ a: JointName, _ b: JointName) -> Float? {
        guard let p = joint(a), let q = joint(b), p.confidence > 0.3, q.confidence > 0.3 else { return nil }
        return Float(hypot((p.location.x - q.location.x) * imageSize.width,
                           (p.location.y - q.location.y) * imageSize.height))
    }

    /// How squarely the palm (or the back of the hand) faces the camera: ±1 square on, 0 edge-on;
    /// the sign flips as the hand turns over. With the 3D shape it's the palm normal's component
    /// toward the camera; otherwise the 2D sine of the angle between wrist→index knuckle and
    /// wrist→little knuckle.
    var facing: Float? {
        if let world, let w = world[.wrist], let i = world[.indexMCP], let l = world[.littleMCP] {
            let normal = simd_cross(i - w, l - w)
            let length = simd_length(normal)
            return length > 0 ? normal.z / length : nil
        }
        return facing2D
    }

    private var facing2D: Float? {
        guard let w = joint(.wrist), let i = joint(.indexMCP), let l = joint(.littleMCP),
              w.confidence > 0.3, i.confidence > 0.3, l.confidence > 0.3 else { return nil }
        let ax = (i.location.x - w.location.x) * imageSize.width, ay = (i.location.y - w.location.y) * imageSize.height
        let bx = (l.location.x - w.location.x) * imageSize.width, by = (l.location.y - w.location.y) * imageSize.height
        let lengths = hypot(ax, ay) * hypot(bx, by)
        guard lengths > 0 else { return nil }
        return Float((ax * by - ay * bx) / lengths)
    }
}

/// Latest tracked hand for drawing. Kept out of the gesture processor's published state so
/// per-frame updates only redraw the skeleton, not the whole screen.
final class HandSkeletonStore: ObservableObject {
    @Published private(set) var pose: HandPose?

    func update(_ pose: HandPose?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if pose == nil && self.pose == nil { return }
            self.pose = pose
        }
    }
}

// MARK: - Drawing

/// Black screen with the tracked hand drawn as joints and bones (replaces the camera preview).
struct HandSkeletonView: View {
    @ObservedObject var store: HandSkeletonStore
    /// Front camera: mirror so the drawing moves like a reflection.
    var mirrored: Bool
    var tint: Color

    private static let fingers: [[HandPose.JointName]] = [
        [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip],
    ]
    private static let palm: [HandPose.JointName] = [.indexMCP, .middleMCP, .ringMCP, .littleMCP]
    private static let tips: Set<HandPose.JointName> = [.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip]
    private let minConfidence: Float = 0.3

    var body: some View {
        Canvas { context, size in
            guard let pose = store.pose, pose.imageSize.width > 0, pose.imageSize.height > 0 else { return }

            // Aspect-fit the camera frame into the view, like the old preview did.
            let scale = min(size.width / pose.imageSize.width, size.height / pose.imageSize.height)
            let drawn = CGSize(width: pose.imageSize.width * scale, height: pose.imageSize.height * scale)
            let origin = CGPoint(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2)

            func screenPoint(_ name: HandPose.JointName) -> CGPoint? {
                guard let joint = pose.joint(name), joint.confidence >= minConfidence else { return nil }
                let x = mirrored ? 1 - joint.location.x : joint.location.x
                return CGPoint(x: origin.x + x * drawn.width,
                               y: origin.y + (1 - joint.location.y) * drawn.height)
            }

            // Bones
            var bones = Path()
            for chain in Self.fingers + [Self.palm] {
                for (a, b) in zip(chain, chain.dropFirst()) {
                    guard let p = screenPoint(a), let q = screenPoint(b) else { continue }
                    bones.move(to: p)
                    bones.addLine(to: q)
                }
            }
            context.stroke(bones, with: .color(tint.opacity(0.75)),
                           style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))

            // Joints
            for name in pose.joints.keys {
                guard let p = screenPoint(name) else { continue }
                let radius: CGFloat = Self.tips.contains(name) ? 8 : 5
                let dot = Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
                context.fill(dot, with: .color(Self.tips.contains(name) ? .white : tint))
            }

            // LiDAR distance next to the wrist
            if let distance = pose.distance, let wrist = screenPoint(.wrist) {
                let label = Text(String(format: "%.1f m", distance))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                context.draw(label, at: CGPoint(x: wrist.x, y: wrist.y + 22))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
