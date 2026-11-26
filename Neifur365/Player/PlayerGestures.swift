import AVFoundation
import AVKit
import MediaPlayer
import SwiftUI
import UIKit

/// Off-screen `MPVolumeView` placed at a real non-zero frame so iOS always constructs its internal `UISlider`.
enum HardwareVolumeController {
    private static var hostWindow: UIWindow?
    private static weak var slider: UISlider?

    static func installIfNeeded() {
        guard slider == nil else {
            // Re-scan if slider was detached
            return
        }
        let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 200, height: 40))
        volumeView.showsRouteButton = false
        for sub in volumeView.subviews {
            if let s = sub as? UISlider {
                slider = s
            }
        }
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
           let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first {
            window.addSubview(volumeView)
        }
    }

    static func currentVolume() -> Float {
        installIfNeeded()
        return AVAudioSession.sharedInstance().outputVolume
    }

    static func setVolume(_ value: Float) {
        installIfNeeded()
        let clamped = min(max(value, 0), 1)
        DispatchQueue.main.async {
            slider?.setValue(clamped, animated: false)
            slider?.sendActions(for: .touchUpInside)
        }
    }
}

struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = UIColor(Nf.violet)
        picker.prioritizesVideoDevices = true
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

enum PlayerSideFeedback: Equatable {
    case brightness(Float)
    case volume(Float)
}

/// Dedicated UIKit gesture surface that guarantees:
/// - reliable single vs double tap discrimination
/// - zero sticky 2× long-press (always ends on .ended/.cancelled/.failed)
/// - horizontal swipe to scrub, vertical swipe on left/right halves (with edge dead-zones) for brightness/volume
/// - pinch to toggle Fit / Fill
struct PlayerGestureOverlay: UIViewRepresentable {
    var isLocked: Bool
    var isOpening: Bool
    var sideGesturesEnabled: Bool
    var holdBoostEnabled: Bool
    var currentPositionProvider: () -> Double
    var durationProvider: () -> Double

    var onSingleTap: () -> Void
    var onDoubleTap: (_ normalizedX: CGFloat) -> Void
    var onHoldBoostChanged: (_ active: Bool) -> Void
    var onHorizontalScrubChanged: (_ targetSeconds: Double, _ deltaSeconds: Double) -> Void
    var onHorizontalScrubEnded: (_ targetSeconds: Double) -> Void
    var onSideFeedbackChanged: (_ feedback: PlayerSideFeedback?) -> Void
    var onPinchAspect: (_ fill: Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = context.coordinator

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        singleTap.delegate = context.coordinator

        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.4
        longPress.allowableMovement = 24
        longPress.delegate = context.coordinator

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = context.coordinator

        view.addGestureRecognizer(singleTap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(longPress)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(pinch)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PlayerGestureOverlay

        private enum PanMode {
            case none
            case horizontal
            case brightness
            case volume
        }

        private var panMode: PanMode = .none
        private var startPosition: Double = 0
        private var currentTarget: Double = 0
        private var startValue: Float = 0
        private var pinchHandled = false

        init(parent: PlayerGestureOverlay) {
            self.parent = parent
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let view = gestureRecognizer.view, view.bounds.width > 0 else { return false }
            let loc = gestureRecognizer.location(in: view)

            // Edge dead-zones so iOS system gestures (Control Center / Home / Back) aren't hijacked
            if gestureRecognizer is UIPanGestureRecognizer {
                let margin: CGFloat = 24
                if loc.x < margin || loc.x > view.bounds.width - margin ||
                    loc.y < margin || loc.y > view.bounds.height - margin {
                    return false
                }
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }

        @objc func handleSingleTap(_ gr: UITapGestureRecognizer) {
            guard gr.state == .ended else { return }
            parent.onSingleTap()
        }

        @objc func handleDoubleTap(_ gr: UITapGestureRecognizer) {
            guard gr.state == .ended, !parent.isLocked, !parent.isOpening,
                  let view = gr.view, view.bounds.width > 0 else { return }
            let nx = gr.location(in: view).x / view.bounds.width
            parent.onDoubleTap(nx)
        }

        @objc func handleLongPress(_ gr: UILongPressGestureRecognizer) {
            switch gr.state {
            case .began:
                guard !parent.isLocked, !parent.isOpening, parent.holdBoostEnabled else { return }
                parent.onHoldBoostChanged(true)
            case .ended, .cancelled, .failed:
                parent.onHoldBoostChanged(false)
            default:
                break
            }
        }

        @objc func handlePan(_ gr: UIPanGestureRecognizer) {
            guard let view = gr.view, view.bounds.width > 0, view.bounds.height > 0 else { return }

            if parent.isLocked || parent.isOpening {
                if panMode != .none {
                    panMode = .none
                    parent.onSideFeedbackChanged(nil)
                }
                return
            }

            let trans = gr.translation(in: view)
            switch gr.state {
            case .began:
                panMode = .none

            case .changed:
                if panMode == .none {
                    let dx = abs(trans.x)
                    let dy = abs(trans.y)
                    guard max(dx, dy) > 10 else { return }
                    if dx > dy * 1.25 {
                        let dur = parent.durationProvider()
                        guard dur > 0 else { return }
                        panMode = .horizontal
                        startPosition = parent.currentPositionProvider()
                        currentTarget = startPosition
                    } else if parent.sideGesturesEnabled {
                        let startX = gr.location(in: view).x - trans.x
                        if startX < view.bounds.width * 0.5 {
                            panMode = .brightness
                            startValue = Float(UIScreen.main.brightness)
                        } else {
                            panMode = .volume
                            startValue = HardwareVolumeController.currentVolume()
                        }
                    }
                }

                switch panMode {
                case .horizontal:
                    let dur = max(parent.durationProvider(), 1)
                    let delta = Double(trans.x / view.bounds.width) * 180.0
                    let target = min(max(startPosition + delta, 0), dur)
                    currentTarget = target
                    parent.onHorizontalScrubChanged(target, target - startPosition)
                case .brightness:
                    let delta = Float(-trans.y / max(view.bounds.height * 0.65, 180))
                    let next = min(max(startValue + delta, 0), 1)
                    UIScreen.main.brightness = CGFloat(next)
                    parent.onSideFeedbackChanged(.brightness(next))
                case .volume:
                    let delta = Float(-trans.y / max(view.bounds.height * 0.65, 180))
                    let next = min(max(startValue + delta, 0), 1)
                    HardwareVolumeController.setVolume(next)
                    parent.onSideFeedbackChanged(.volume(next))
                case .none:
                    break
                }

            case .ended, .cancelled, .failed:
                switch panMode {
                case .horizontal:
                    parent.onHorizontalScrubEnded(currentTarget)
                case .brightness, .volume:
                    parent.onSideFeedbackChanged(nil)
                case .none:
                    break
                }
                panMode = .none

            default:
                break
            }
        }

        @objc func handlePinch(_ gr: UIPinchGestureRecognizer) {
            guard !parent.isLocked, !parent.isOpening else { return }
            switch gr.state {
            case .began:
                pinchHandled = false
            case .changed:
                guard !pinchHandled else { return }
                if gr.scale > 1.18 {
                    pinchHandled = true
                    parent.onPinchAspect(true)
                } else if gr.scale < 0.85 {
                    pinchHandled = true
                    parent.onPinchAspect(false)
                }
            case .ended, .cancelled, .failed:
                pinchHandled = false
            default:
                break
            }
        }
    }
}
