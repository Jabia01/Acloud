#if os(iOS) && canImport(UIKit) && canImport(PhotosUI)
import Photos
import PhotosUI
import UIKit

// Picker presentation is a PhotosUI extension of PHPhotoLibrary, not a Photos
// API exposed by importing Photos alone. Keep UIKit out of the scanner adapter.
@available(iOS 15.0, *)
@MainActor public enum PhotoLibraryAccessUI {
    public static func manageLimitedAccess(
        from controller: UIViewController,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else {
            completion()
            return
        }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(
            from: controller,
            completionHandler: { _ in
                // The SDK completion is Sendable; UI state must stay on MainActor.
                Task { @MainActor in completion() }
            }
        )
    }
}
#endif
