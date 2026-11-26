import SwiftUI
import UIKit

struct ScreenshotItem: Identifiable, Hashable {
    let url: String
    var id: String { url }
}

struct ScreenshotViewer: View {
    let urls: [String]
    @State var currentIndex: Int
    let onClose: () -> Void

    init(urls: [String], initialIndex: Int = 0, onClose: @escaping () -> Void) {
        self.urls = urls
        let clamped = urls.indices.contains(initialIndex) ? initialIndex : 0
        self._currentIndex = State(initialValue: clamped)
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(urls.enumerated()), id: \.offset) { idx, url in
                    ZoomableScreenshotView(urlString: url)
                        .tag(idx)
                        .ignoresSafeArea()
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            VStack {
                HStack {
                    Text("\(currentIndex + 1) / \(max(urls.count, 1))")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                        .monospacedDigit()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .nfGlassCapsule()

                    Spacer()

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .nfGlassCircle()
                    }
                    .accessibilityLabel("Закрыть")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Spacer()
            }
        }
        .statusBarHidden(true)
    }
}

private struct ZoomableScreenshotView: UIViewRepresentable {
    let urlString: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.backgroundColor = .black
        scroll.minimumZoomScale = 1.0
        scroll.maximumZoomScale = 4.0
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.delegate = context.coordinator

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            imageView.centerXAnchor.constraint(equalTo: scroll.contentLayoutGuide.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: scroll.contentLayoutGuide.centerYAnchor)
        ])

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        scroll.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor)
        ])

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        context.coordinator.scrollView = scroll
        context.coordinator.imageView = imageView
        context.coordinator.spinner = spinner
        context.coordinator.load(urlString: urlString)
        return scroll
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        if context.coordinator.loadedUrl != urlString {
            uiView.setZoomScale(1.0, animated: false)
            context.coordinator.load(urlString: urlString)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        weak var spinner: UIActivityIndicatorView?
        var loadedUrl: String?
        private var task: Task<Void, Never>?

        deinit { task?.cancel() }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > 1.1 {
                scrollView.setZoomScale(1.0, animated: true)
            } else {
                let point = recognizer.location(in: imageView)
                let size = CGSize(
                    width: scrollView.bounds.width / 2.4,
                    height: scrollView.bounds.height / 2.4
                )
                let rect = CGRect(
                    x: point.x - size.width / 2,
                    y: point.y - size.height / 2,
                    width: size.width,
                    height: size.height
                )
                scrollView.zoom(to: rect, animated: true)
            }
        }

        func load(urlString: String) {
            loadedUrl = urlString
            task?.cancel()
            imageView?.image = nil
            spinner?.startAnimating()
            guard let url = URL(string: urlString) else {
                spinner?.stopAnimating()
                return
            }
            task = Task { [weak self] in
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    guard !Task.isCancelled, let img = UIImage(data: data) else { return }
                    await MainActor.run {
                        self?.imageView?.image = img
                        self?.spinner?.stopAnimating()
                    }
                } catch {
                    await MainActor.run {
                        self?.spinner?.stopAnimating()
                    }
                }
            }
        }
    }
}
