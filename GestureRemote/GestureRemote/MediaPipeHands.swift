import CoreImage
import CoreVideo
import Foundation
import MediaPipeTasksVision
import simd
import Vision

/// Google MediaPipe's hand landmarker (palm detector + 21-point landmark model), the models
/// CardboardXR uses. Besides the 2D points it gives the hand's 3D shape in metres ("world
/// landmarks"), which doesn't shrink or distort with distance the way 2D angles do.
///
/// Runs in image mode on a crop the caller picks (around the tracked hand or the left wrist), so
/// hands across the room still fill the model's input. MediaPipe's own tracking can't take a region.
final class MediaPipeHands {
    private let landmarker: HandLandmarker?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var cropBuffer: CVPixelBuffer?
    private let maxCropSide: CGFloat = 640   // the models work at 192–224 px; more is wasted

    /// MediaPipe's index order for the 21 landmarks, as Vision joint names.
    private static let jointOrder: [HandPose.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]

    init() {
        guard let path = Bundle.main.path(forResource: "hand_landmarker", ofType: "task") else {
            print("[Hands] hand_landmarker.task missing — using Apple Vision")
            landmarker = nil
            return
        }
        let options = HandLandmarkerOptions()
        options.baseOptions.modelAssetPath = path
        options.runningMode = .image
        options.numHands = 2
        options.minHandDetectionConfidence = 0.4
        options.minHandPresenceConfidence = 0.4
        options.minTrackingConfidence = 0.4
        // GPU first (frees the CPU, more frames per second), CPU if the GPU delegate can't start.
        options.baseOptions.delegate = .GPU
        if let gpu = try? HandLandmarker(options: options) {
            landmarker = gpu
            delegateName = "MediaPipe GPU"
            return
        }
        options.baseOptions.delegate = .CPU
        do {
            landmarker = try HandLandmarker(options: options)
            delegateName = "MediaPipe CPU"
        } catch {
            print("[Hands] MediaPipe failed to load (\(error.localizedDescription)) — using Apple Vision")
            landmarker = nil
        }
    }

    var isAvailable: Bool { landmarker != nil }
    private(set) var delegateName = "Apple Vision"

    /// Hands in `region` (normalized, Vision coords: bottom-left origin) of the upright frame,
    /// mapped back to full-frame coordinates.
    /// - Parameter brighten: lift a dark crop (+1.5 EV, gamma 0.75) before the model sees it.
    func detect(in pixelBuffer: CVPixelBuffer, region: CGRect, imageSize: CGSize, brighten: Bool = false) -> [HandPose] {
        guard let landmarker else { return [] }

        // Crop (CIImage shares Vision's bottom-left origin) and scale down to at most maxCropSide.
        let crop = CGRect(x: region.minX * imageSize.width, y: region.minY * imageSize.height,
                          width: region.width * imageSize.width, height: region.height * imageSize.height).integral
        guard crop.width >= 8, crop.height >= 8 else { return [] }
        let scale = min(1, maxCropSide / max(crop.width, crop.height))
        let outWidth = Int((crop.width * scale).rounded())
        let outHeight = Int((crop.height * scale).rounded())
        guard let buffer = buffer(width: outWidth, height: outHeight) else { return [] }
        var image = CIImage(cvPixelBuffer: pixelBuffer)
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if brighten {
            image = image
                .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 1.5])
                .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.75])
        }
        ciContext.render(image, to: buffer, bounds: CGRect(x: 0, y: 0, width: outWidth, height: outHeight), colorSpace: nil)

        guard let mpImage = try? MPImage(pixelBuffer: buffer),
              let result = try? landmarker.detect(image: mpImage) else { return [] }

        let processed = CGRect(x: crop.minX / imageSize.width, y: crop.minY / imageSize.height,
                               width: crop.width / imageSize.width, height: crop.height / imageSize.height)
        var poses: [HandPose] = []
        for (index, landmarks) in result.landmarks.enumerated() where landmarks.count == 21 {
            var joints: [HandPose.JointName: HandPose.Joint] = [:]
            for (i, landmark) in landmarks.enumerated() {
                // MediaPipe: normalized to the crop, origin top-left.
                let location = CGPoint(x: processed.minX + CGFloat(landmark.x) * processed.width,
                                       y: processed.minY + (1 - CGFloat(landmark.y)) * processed.height)
                joints[Self.jointOrder[i]] = HandPose.Joint(location: location, confidence: 0.9)
            }

            var world: [HandPose.JointName: SIMD3<Float>] = [:]
            if index < result.worldLandmarks.count, result.worldLandmarks[index].count == 21 {
                for (i, landmark) in result.worldLandmarks[index].enumerated() {
                    // MediaPipe: metres, x right, y down, z away from the camera. Stored as x right,
                    // y up, z toward the camera (a rotation, so handedness of the axes is kept).
                    world[Self.jointOrder[i]] = SIMD3(landmark.x, -landmark.y, -landmark.z)
                }
            }

            // Checked on device: on our (unmirrored, rear camera) frames MediaPipe's "Left" is the
            // person's left hand — crops around the body-pose left wrist came back "Left".
            var chirality = VNChirality.unknown
            if index < result.handedness.count, let label = result.handedness[index].first?.categoryName {
                chirality = label == "Left" ? .left : (label == "Right" ? .right : .unknown)
            }

            poses.append(HandPose(joints: joints, world: world.isEmpty ? nil : world,
                                  imageSize: imageSize, chirality: chirality))
        }
        return poses
    }

    private func buffer(width: Int, height: Int) -> CVPixelBuffer? {
        if let existing = cropBuffer,
           CVPixelBufferGetWidth(existing) == width, CVPixelBufferGetHeight(existing) == height {
            return existing
        }
        var created: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            attributes as CFDictionary, &created)
        cropBuffer = created
        return created
    }
}
