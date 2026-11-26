import UIKit

@MainActor
final class OrientationManager {
    static let shared = OrientationManager()

    private(set) var allowedMask: UIInterfaceOrientationMask =
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait

    private init() {}

    func enterPlayer(preferLandscape: Bool) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            allowedMask = .all
            return
        }
        allowedMask = [.portrait, .landscapeLeft, .landscapeRight]
        apply(target: preferLandscape ? .landscapeRight : .portrait)
    }

    func setPlayerOrientation(landscape: Bool) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            apply(target: landscape ? .landscapeRight : .portrait)
            return
        }
        allowedMask = [.portrait, .landscapeLeft, .landscapeRight]
        apply(target: landscape ? .landscapeRight : .portrait)
    }

    func exitPlayer() {
        if UIDevice.current.userInterfaceIdiom == .pad {
            allowedMask = .all
            return
        }
        allowedMask = .portrait
        apply(target: .portrait)
    }

    private func apply(target: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }

        if #available(iOS 16.0, *) {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { _ in }
        }
    }
}
