import SwiftUI
import UIKit

/// Takes a photo with the camera.
///
/// Worth having beyond convenience: it is the only way into the app for paper.
/// A letter from the Belastingdienst, a gemeente form, a notice pinned in a
/// stairwell — none of those are screenshots, and they are exactly the Dutch
/// someone is most stuck on.
///
/// `UIImagePickerController` rather than a custom `AVCaptureSession`: it gives
/// the system shutter, flash, focus and retake for free, and a hand-rolled
/// camera would be a lot of surface for no gain here.
struct CameraPicker: UIViewControllerRepresentable {

    /// Whether this device can do it at all — false on a simulator, and on an
    /// iPad without a usable rear camera.
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.allowsEditing = false
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onFinish: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
                             UINavigationControllerDelegate {
        private let onCapture: (UIImage) -> Void
        private let onFinish: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, onFinish: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onFinish = onFinish
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            // `.originalImage` rather than `.editedImage`: editing is off, and
            // asking for the edited one returns nil when it is.
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
            onFinish()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish()
        }
    }
}
