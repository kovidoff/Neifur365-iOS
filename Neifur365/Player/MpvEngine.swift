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
                DispatchQueue.main.sync {
                    super.wantsExtendedDynamicRangeContent = newValue
                }
            }
        }
    }
}

final class MpvContainerUIView: UIView {
    let metalLayer = MpvMetalLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(metalLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        CATransaction.commit()
    }
}

struct MpvVideoView: UIViewRepresentable {
    let engine: MpvEngine

    func makeUIView(context: Context) -> MpvContainerUIView {
        let view = MpvContainerUIView(frame: .zero)
        engine.attach(to: view.metalLayer)
        return view
    }

    func updateUIView(_ uiView: MpvContainerUIView, context: Context) {}
}

final class MpvEngine: ObservableObject {
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var cacheTime: Double = 0
    @Published var isPaused: Bool = false
    @Published var isBuffering: Bool = true
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
    private let userAgent: String
    private var currentTitle = ""
    private var currentSubtitle = ""
    private var currentSubScale: Double = 1.0

    private struct PendingLoad {
        let id: UUID
        let url: String
        let startSeconds: Double
        let subtitleFile: URL?
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
        shutdown()
    }

    func attach(to layer: MpvMetalLayer) {
        guard attachedLayer !== layer else { return }
        attachedLayer = layer

        queue.async { [weak self] in
            guard let self, !self.isShutdown else { return }
            self.initializeMpv(layer: layer)
            if let pending = self.pendingLoad {
                self.pendingLoad = nil
                self.performLoad(pending)
            }
        }
    }

    private func initializeMpv(layer: MpvMetalLayer) {
        if mpv != nil { return }
        guard let ctx = mpv_create() else {
            DispatchQueue.main.async { self.playbackError = "Не удалось инициализировать libmpv" }
            return
        }
        mpv = ctx

        let fontsDir = prepareSubtitleFontsDirectory()
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
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
        setOption("sub-ass-override", "no")
        setOption("sub-ass-force-margins", "no")
        setOption("sub-scale", String(format: "%.2f", currentSubScale))
        if let fontsDir {
            setOption("sub-fonts-dir", fontsDir.path)
            setOption("sub-font", "DejaVu Sans")
        }
        setOption("ao", "audiounit")
        mpv_request_log_messages(ctx, "warn")

        if mpv_initialize(ctx) < 0 {
            DispatchQueue.main.async { self.playbackError = "Ошибка запуска libmpv" }
            return
        }

        mpv_observe_property(ctx, 1, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(ctx, 2, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(ctx, 3, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(ctx, 4, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(ctx, 5, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(ctx, 6, "demuxer-cache-time", MPV_FORMAT_DOUBLE)

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
        isEnded = false
        isPaused = false
        playbackError = nil
        position = startSeconds
        duration = 0
        cacheTime = 0

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
            subtitleFile: subtitleFile
        )

        queue.async { [weak self] in
            guard let self, !self.isShutdown else { return }
            guard self.mpv != nil else {
                self.pendingLoad = req
                return
            }
            self.performLoad(req)
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

        setFlag("pause", false)
        publishPlayback { $0.updateNowPlaying() }
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
        currentSubScale = scale
        queue.async { [weak self] in
            self?.setDouble("sub-scale", scale)
        }
    }

    func addSubtitle(fileURL: URL) {
        queue.async { [weak self] in
            self?.pendingSubtitleFile = fileURL
            self?.command(["sub-add", fileURL.path, "select"])
        }
    }

    func shutdown() {
        queue.sync {
            guard !isShutdown else { return }
            isShutdown = true
            if let ctx = mpv {
                mpv_set_wakeup_callback(ctx, nil, nil)
                mpv_terminate_destroy(ctx)
                mpv = nil
            }
        }
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
                $0.isBuffering = false
                $0.playbackError = nil
                $0.updateNowPlaying()
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
            case "demuxer-cache-time":
                if prop.format == MPV_FORMAT_DOUBLE, let valPtr = prop.data {
                    let val = valPtr.assumingMemoryBound(to: Double.self).pointee
                    publishPlayback { $0.cacheTime = val }
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
        let dir = fm.temporaryDirectory.appendingPathComponent("neifur_mpv_fonts", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let src = Bundle.main.url(forResource: "subfont", withExtension: "ttf") {
            let dest = dir.appendingPathComponent("subfont.ttf")
            if !fm.fileExists(atPath: dest.path) {
                try? fm.copyItem(at: src, to: dest)
            }
        }
        return dir
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
