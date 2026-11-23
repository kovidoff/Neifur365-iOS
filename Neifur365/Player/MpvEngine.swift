import AVFoundation
import Foundation
import Libmpv
import MediaPlayer
import SwiftUI
import UIKit

/// Subclass of CAMetalLayer avoiding MoltenVK 1x1 transient resize flicker.
final class MpvMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.wantsExtendedDynamicRangeContent = newValue
                }
            }
        }
    }
}

final class MpvContainerUIView: UIView {
    private let engine: MpvEngine
    private var metalLayer: MpvMetalLayer?
    private var drawableSize: CGSize = .zero
    private var resizeTask: Task<Void, Never>?

    init(engine: MpvEngine) {
        self.engine = engine
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let window, bounds.width > 1, bounds.height > 1 else { return }
        let scale = window.screen.nativeScale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard size != drawableSize else { return }
        drawableSize = size
        resizeTask?.cancel()

        if metalLayer == nil {
            replaceSurface(size: size, scale: scale)
        } else {
            // MoltenVK only reconfigures when mpv rebinds the window. Wait for rotation layout to settle.
            resizeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled, let self, self.window != nil else { return }
                self.replaceSurface(size: size, scale: scale)
            }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            resizeTask?.cancel()
            drawableSize = .zero
        } else {
            setNeedsLayout()
        }
    }

    private func replaceSurface(size: CGSize, scale: CGFloat) {
        let surface = MpvMetalLayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.frame = bounds
        surface.contentsScale = scale
        surface.drawableSize = size
        surface.framebufferOnly = true
        surface.backgroundColor = UIColor.black.cgColor
        metalLayer?.removeFromSuperlayer()
        layer.addSublayer(surface)
        metalLayer = surface
        CATransaction.commit()
        engine.attach(to: surface)
    }
}

struct MpvVideoView: UIViewRepresentable {
    let engine: MpvEngine

    func makeUIView(context: Context) -> MpvContainerUIView {
        MpvContainerUIView(engine: engine)
    }

    func updateUIView(_ uiView: MpvContainerUIView, context: Context) {}
}

final class MpvEngine: ObservableObject {
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var isPaused: Bool = false
    @Published var isBuffering: Bool = true
    @Published private(set) var isReady = false
    @Published var isEnded: Bool = false
    @Published var playbackError: String?

    var onEnded: (@MainActor () -> Void)?
    var onNextCommand: (() -> Void)?
    var onPreviousCommand: (() -> Void)?

    private let queue = DispatchQueue(label: "app.neifur365.mpv", qos: .userInitiated)
    private var mpv: OpaquePointer?
    private var attachedLayer: MpvMetalLayer?
    private var pendingLoad: PendingLoad?
    private var loadID = UUID()
    private var queuedLoadID: UUID?
    private var acceptsPlaybackEvents = false
    private var isShutdown = false
    private var initializationError: String?
    private let userAgent: String
    private var currentTitle = ""
    private var currentSubtitle = ""
    private var currentSubScale: Double = 1.0

    private struct PendingLoad {
        let id: UUID
        let url: String
        let startSeconds: Double
        let subtitleFile: URL?
        let paused: Bool
    }

    init(userAgent: String) {
        self.userAgent = userAgent
        configureAudioSession()
        observeLifecycle()
        setupRemoteCommands()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        clearRemoteCommands()
        releaseMpv()
    }

    func attach(to layer: MpvMetalLayer) {
        queue.async { [weak self] in
            guard let self, !self.isShutdown else { return }
            if let ctx = self.mpv {
                // Keep the previous layer alive until mpv has switched video outputs.
                var wid = Self.windowID(for: layer)
                if mpv_set_property(ctx, "wid", MPV_FORMAT_INT64, &wid) >= 0 {
                    self.attachedLayer = layer
                }
            } else {
                self.attachedLayer = layer
                self.initializeMpv(layer: layer)
            }
            if let pending = self.pendingLoad {
                self.pendingLoad = nil
                self.open(pending)
            }
        }
    }

    private static func windowID(for layer: MpvMetalLayer) -> Int64 {
        Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
    }

    private func initializeMpv(layer: MpvMetalLayer) {
        guard let ctx = mpv_create() else {
            initializationError = "Не удалось инициализировать плеер"
            return
        }
        mpv = ctx

        let fontsDir = prepareSubtitleFontsDirectory()
        var wid = Self.windowID(for: layer)
        mpv_set_option(ctx, "wid", MPV_FORMAT_INT64, &wid)

        setOption("vo", "gpu-next")
        setOption("gpu-api", "vulkan")
        setOption("gpu-context", "moltenvk")
        setOption("hwdec", "videotoolbox")
        setOption("video-rotate", "no")
        setOption("keep-open", "yes")
        setOption("cache", "yes")
        setOption("cache-secs", "45")
        setOption("demuxer-max-bytes", "64MiB")
        setOption("demuxer-max-back-bytes", "24MiB")
        setOption("user-agent", userAgent)
        setOption("sub-auto", "no")
        setOption("sub-ass", "yes")
        setOption("sub-ass-override", currentSubScale == 1 ? "no" : "scale")
        setOption("sub-ass-force-margins", "no")
        setOption("sub-scale-signs", "no")
        setOption("embeddedfonts", "yes")
        setOption("sub-scale", String(format: "%.2f", currentSubScale))
        if let fontsDir {
            setOption("config-dir", fontsDir.deletingLastPathComponent().path)
            setOption("sub-fonts-dir", fontsDir.path)
            setOption("sub-font", "Manrope")
        }
        setOption("ao", "audiounit")
        mpv_request_log_messages(ctx, "warn")

        if mpv_initialize(ctx) < 0 {
            mpv_terminate_destroy(ctx)
            mpv = nil
            initializationError = "Не удалось запустить плеер"
            return
        }
        initializationError = nil

        mpv_observe_property(ctx, 1, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(ctx, 2, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(ctx, 3, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(ctx, 4, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(ctx, 5, "eof-reached", MPV_FORMAT_FLAG)

        let rawSelf = Unmanaged.passUnretained(self).toOpaque()
        mpv_set_wakeup_callback(ctx, { userdata in
            guard let userdata else { return }
            let engine = Unmanaged<MpvEngine>.fromOpaque(userdata).takeUnretainedValue()
            engine.drainEvents()
        }, rawSelf)
    }

    @MainActor
    func prepareForLoad(startSeconds: Double = 0) {
        loadID = UUID()
        isBuffering = true
        isReady = false
        isEnded = false
        isPaused = false
        playbackError = nil
        position = startSeconds
        duration = 0

        queue.async { [weak self] in
            guard let self, !self.isShutdown else { return }
            self.queuedLoadID = nil
            self.acceptsPlaybackEvents = false
            self.pendingLoad = nil
            self.pendingSubtitleFile = nil
            self.command(["stop"])
        }
    }

    @MainActor
    func load(
        url: String,
        startSeconds: Double = 0,
        subtitleFile: URL? = nil,
        paused: Bool = false,
        title: String = "",
        subtitle: String = ""
    ) {
        prepareForLoad(startSeconds: startSeconds)
        currentTitle = title
        currentSubtitle = subtitle

        let req = PendingLoad(
            id: loadID,
            url: url,
            startSeconds: max(0, startSeconds),
            subtitleFile: subtitleFile,
            paused: paused
        )

        queue.async { [weak self] in
            guard let self, !self.isShutdown else { return }
            self.open(req)
        }
    }

    private func open(_ request: PendingLoad) {
        if let initializationError {
            queuedLoadID = request.id
            publishPlayback {
                $0.isBuffering = false
                $0.playbackError = initializationError
            }
        } else if mpv != nil {
            performLoad(request)
        } else {
            pendingLoad = request
        }
    }

    private func performLoad(_ req: PendingLoad) {
        readEvents()
        queuedLoadID = req.id
        pendingSubtitleFile = req.subtitleFile

        var options: [String] = []
        if req.startSeconds > 2 {
            options.append("start=\(Int(req.startSeconds))")
        }

        var args = ["loadfile", req.url, "replace"]
        setFlag("pause", req.paused)
        if !options.isEmpty {
            args.append(contentsOf: ["-1", options.joined(separator: ",")])
        }
        let result = command(args)
        if result < 0 {
            let message = String(cString: mpv_error_string(result))
            publishPlayback {
                $0.isBuffering = false
                $0.playbackError = "Не удалось открыть видео (\(message))"
            }
            return
        }

        publishPlayback {
            $0.isPaused = req.paused
            $0.updateNowPlaying()
        }
    }

    private var pendingSubtitleFile: URL?

    func setPaused(_ paused: Bool) {
        queue.async { [weak self] in
            self?.setFlag("pause", paused)
        }
    }

    func togglePause() {
        queue.async { [weak self] in
            guard let self else { return }
            self.command(["cycle", "pause"])
        }
    }

    func seek(to seconds: Double) {
        let clamped = max(0, seconds)
        queue.async { [weak self] in
            self?.command(["seek", String(format: "%.2f", clamped), "absolute"])
        }
    }

    func seekRelative(_ delta: Double) {
        queue.async { [weak self] in
            self?.command(["seek", String(format: "%.2f", delta), "relative"])
        }
    }

    func setSpeed(_ speed: Double) {
        queue.async { [weak self] in
            self?.setDouble("speed", speed)
        }
    }

    func setAspectFill(_ fill: Bool) {
        queue.async { [weak self] in
            self?.setDouble("panscan", fill ? 1.0 : 0.0)
        }
    }

    func setSubtitlesVisible(_ visible: Bool) {
        queue.async { [weak self] in
            self?.setFlag("sub-visibility", visible)
        }
    }

    func setSubtitleScale(_ scale: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            self.currentSubScale = scale
            self.setProperty("sub-ass-override", scale == 1 ? "no" : "scale")
            self.setDouble("sub-scale", scale)
        }
    }

    func addSubtitle(fileURL: URL) {
        queue.async { [weak self] in
            self?.pendingSubtitleFile = fileURL
            self?.command(["sub-add", fileURL.path, "select"])
        }
    }

    @MainActor
    func shutdown() {
        loadID = UUID()
        queue.async { [self] in releaseMpv() }
    }

    private func releaseMpv() {
        isShutdown = true
        if let ctx = mpv {
            mpv_set_wakeup_callback(ctx, nil, nil)
            mpv_terminate_destroy(ctx)
            mpv = nil
        }
        attachedLayer = nil
    }

    // MARK: - Event Loop

    private func drainEvents() {
        queue.async { [weak self] in self?.readEvents() }
    }

    private func readEvents() {
        guard !isShutdown, let ctx = mpv else { return }
        while let eventPtr = mpv_wait_event(ctx, 0) {
            let event = eventPtr.pointee
            if event.event_id == MPV_EVENT_NONE { break }
            handle(event: event)
        }
    }

    private func publishPlayback(_ update: @escaping @MainActor (MpvEngine) -> Void) {
        guard let id = queuedLoadID else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.loadID == id else { return }
            update(self)
        }
    }

    private func handle(event: mpv_event) {
        guard queuedLoadID != nil else { return }
        if event.event_id == MPV_EVENT_START_FILE {
            acceptsPlaybackEvents = true
        }
        guard acceptsPlaybackEvents else { return }

        switch event.event_id {
        case MPV_EVENT_FILE_LOADED:
            if let sub = pendingSubtitleFile {
                command(["sub-add", sub.path, "select"])
            }
            publishPlayback {
                $0.playbackError = nil
                $0.updateNowPlaying()
            }

        case MPV_EVENT_PLAYBACK_RESTART:
            publishPlayback {
                $0.isReady = true
                $0.isBuffering = false
            }

        case MPV_EVENT_START_FILE:
            publishPlayback {
                $0.isBuffering = true
                $0.isEnded = false
            }

        case MPV_EVENT_END_FILE:
            if let data = event.data {
                let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if end.reason == MPV_END_FILE_REASON_ERROR {
                    let msg = String(cString: mpv_error_string(end.error))
                    publishPlayback {
                        $0.isBuffering = false
                        $0.playbackError = "Ошибка воспроизведения (\(msg))"
                    }
                }
            }

        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data else { return }
            let prop = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            guard let namePtr = prop.name else { return }
            let name = String(cString: namePtr)

            switch name {
            case "time-pos":
                if prop.format == MPV_FORMAT_DOUBLE, let valPtr = prop.data {
                    let val = valPtr.assumingMemoryBound(to: Double.self).pointee
                    publishPlayback { $0.position = val }
                }
            case "duration":
                if prop.format == MPV_FORMAT_DOUBLE, let valPtr = prop.data {
                    let val = valPtr.assumingMemoryBound(to: Double.self).pointee
                    publishPlayback {
                        $0.duration = val
                        $0.updateNowPlaying()
                    }
                }
            case "pause":
                if prop.format == MPV_FORMAT_FLAG, let valPtr = prop.data {
                    let paused = valPtr.assumingMemoryBound(to: Int32.self).pointee != 0
                    publishPlayback {
                        $0.isPaused = paused
                        $0.updateNowPlaying()
                    }
                }
            case "paused-for-cache":
                if prop.format == MPV_FORMAT_FLAG, let valPtr = prop.data {
                    let buffering = valPtr.assumingMemoryBound(to: Int32.self).pointee != 0
                    publishPlayback { $0.isBuffering = buffering }
                }
            case "eof-reached":
                if prop.format == MPV_FORMAT_FLAG, let valPtr = prop.data {
                    let reached = valPtr.assumingMemoryBound(to: Int32.self).pointee != 0
                    if reached {
                        publishPlayback {
                            if !$0.isEnded {
                                $0.isEnded = true
                                $0.onEnded?()
                            }
                        }
                    }
                }
            default:
                break
            }

        default:
            break
        }
    }

    // MARK: - Low-level Helpers

    private func setOption(_ name: String, _ value: String) {
        guard let ctx = mpv else { return }
        mpv_set_option_string(ctx, name, value)
    }

    private func setProperty(_ name: String, _ value: String) {
        guard let ctx = mpv else { return }
        mpv_set_property_string(ctx, name, value)
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard let ctx = mpv else { return }
        var flag: Int32 = value ? 1 : 0
        mpv_set_property(ctx, name, MPV_FORMAT_FLAG, &flag)
    }

    private func setDouble(_ name: String, _ value: Double) {
        guard let ctx = mpv else { return }
        var v = value
        mpv_set_property(ctx, name, MPV_FORMAT_DOUBLE, &v)
    }

    @discardableResult
    private func command(_ args: [String]) -> Int32 {
        guard let ctx = mpv else { return 0 }
        var cStrings: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cStrings.append(nil)
        defer { cStrings.forEach { if let p = $0 { free(p) } } }
        var ptrs: [UnsafePointer<CChar>?] = cStrings.map { $0.map { UnsafePointer($0) } }
        return ptrs.withUnsafeMutableBufferPointer { buf in
            mpv_command(ctx, buf.baseAddress)
        }
    }

    private func prepareSubtitleFontsDirectory() -> URL? {
        let fm = FileManager.default
        guard let bundled = Bundle.main.url(forResource: "subfont", withExtension: "ttf") else { return nil }
        let config = fm.temporaryDirectory.appendingPathComponent("neifur_mpv", isDirectory: true)
        let fonts = config.appendingPathComponent("fonts", isDirectory: true)
        do {
            try fm.createDirectory(at: fonts, withIntermediateDirectories: true)
            let fallback = config.appendingPathComponent("subfont.ttf")
            if !fm.fileExists(atPath: fallback.path) { try fm.copyItem(at: bundled, to: fallback) }
            let namedFont = fonts.appendingPathComponent("Manrope-SemiBold.ttf")
            if !fm.fileExists(atPath: namedFont.path) { try fm.copyItem(at: bundled, to: namedFont) }
            return fonts
        } catch {
            return nil
        }
    }

    // MARK: - Lifecycle & Audio / Now Playing

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
    }

    private func observeLifecycle() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
    }

    @objc private func handleEnterBackground() {
        queue.async { [weak self] in
            self?.setFlag("pause", true)
            self?.setProperty("vid", "no")
        }
    }

    @objc private func handleEnterForeground() {
        queue.async { [weak self] in
            self?.setProperty("vid", "auto")
        }
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.setPaused(false)
            return .success
        }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.setPaused(true)
            return .success
        }
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePause()
            return .success
        }
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.seekRelative(10)
            return .success
        }
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.seekRelative(-10)
            return .success
        }
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onNextCommand?() }
            return .success
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onPreviousCommand?() }
            return .success
        }
    }

    private func clearRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentTitle,
            MPMediaItemPropertyArtist: currentSubtitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0.0 : 1.0
        ]
        if duration <= 0 { info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
