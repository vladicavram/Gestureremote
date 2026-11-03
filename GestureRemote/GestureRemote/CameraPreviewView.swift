import AVFoundation
import SwiftUI
import UIKit

/// SwiftUI wrapper for AVCaptureSession preview layer.
/// Uses layerClass so the preview layer IS the view's backing layer — auto-fills bounds, no layoutSubviews needed.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        // Keep the camera image at native scale to avoid soft upscaling artifacts.
        view.previewLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // Reattach session in case the layer lost the reference (e.g. after bg/fg cycle).
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Keep preview layer connection in sync with device orientation so the
            // preview renders correctly when the phone rotates.
            if let conn = previewLayer.connection {
                let angle = CameraManager.videoAngle(for: UIDevice.current.orientation) ?? 90
                if conn.isVideoRotationAngleSupported(angle) {
                    conn.videoRotationAngle = angle
                }
            }
        }
    }
}
