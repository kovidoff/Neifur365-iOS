import AVFoundation
import Foundation
import Libmpv
import MediaPlayer
import Nuke
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

/// Hosts one permanent `MpvMetalLayer` as its backing layer (`layerClass`) so orientation changes
/// resize the MoltenVK swapchain cleanly without ever tearing down or rebinding `wid`.
final class MpvContainerUIView: UIView {
    override class var layerClass: AnyClass { MpvMetalLayer.self }

    private let engine: MpvEngine
    private var didAttach = false
    private var lastDrawableSize: CGSize = .zero

    var metalLayer: MpvMetalLayer {
        layer as! MpvMetalLayer
    }

    init(engine: MpvEngine) {
        self.engine = engine
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        isUserInteractionEnabled = false

        let ml = metalLayer
        ml.contentsScale = UIScreen.main.nativeScale
        ml.framebufferOnly = true
        ml.backgroundColor = UIColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1 else { return }
        let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        let targetSize = CGSize(
            width: (bounds.width * scale).rounded(),
            height: (bounds.height * scale).rounded()
        )
        if targetSize != lastDrawableSize {
            lastDrawableSize = targetSize
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metalLayer.contentsScale = scale
            metalLayer.drawableSize = targetSize
            CATransaction.commit()
        }
        if !didAttach {
            didAttach = true
            engine.attach(to: metalLayer)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            setNeedsLayout()
        }
    }
}

struct MpvVideoView: UIViewRepresentable {
    let engine: MpvEngine

    func makeUIView(context: Context) -> MpvContainerUIView {
        MpvContainerUIView(engine: engine)
    }

    func updateUIView(_ uiView: MpvContainerUIView, context: Context) {}
}

/// Isolated high-frequency clock (~4 Hz) so timeline updates never re-render the full player HUD.
@MainActor
final class MpvPlaybackClock: ObservableObject {
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var cacheTime: Double = 0

    nonisolated init() {}
}

final class MpvEngine: ObservableObject {
    let clock = MpvPlaybackClock()

    @Published var isPaused: Bool = false
    @Published var isBuffering: Bool = true
    @Published private(set) var isReady = false
    @Published var isEnded: Bool = false
    @Published var playbackError: String?
    @Published private(set) var audioTracks: [MpvTrack] = []
    @Published private(set) var subtitleTracks: [MpvTrack] = []
    @Published private(set) var embeddedChapters: [PlayerChapter] = []
    @Published private(set) var videoAspect: Double = 16.0 / 9.0

    var onEnded: (@MainActor () -> Void)?
    var onNextCommand: (() -> Void)?
    var onPreviousCommand: (() -> Void)?

    /// Thread-safe cached playback position for non-SwiftUI readers (e.g. progress saver).
    private let posLock = NSLock()
    private var _position: Double = 0
    private var _duration: Double = 0
    var currentPosition: Double { posLock.withLock { _position } }
    var currentDuration: Double { posLock.withLock { _duration } }

    private let queue = DispatchQueue(label: "app.neifur365.mpv", qos: .userInitiated)
    private var mpv: OpaquePointer?
    private weak var attachedLayer: MpvMetalLayer?
    private var pendingLoad: PendingLoad?
    private var loadID = UUID()
    private var queuedLoadID: UUID?
    private var activePlaylistEntryId: Int64 = 0
    private var acceptsPlaybackEvents = false
    private var isShutdown = false
    private var initializationError: String?
    private let userAgent: String

    private var currentTitle = ""
    private var currentSubtitle = ""
    private var currentArtwork: MPMediaItemArtwork?

    // Desired player parameters kept across initialization and episode transitions
    private var desiredSpeed: Double = 1.0
    private var desiredAspectFill: Bool = false
    private var desiredSubScale: Double = 1.0
    private var desiredSubDelay: Double = 0.0
    private var desiredSubPos: Int = 100
    private var desiredSubVisible: Bool = true
    private var desiredNormalizeAudio: Bool = false
    private var pendingSubtitleFile: URL?

    private var lastClockPush: CFAbsoluteTime = 0
    private var pausedByInterruption = false

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
        if !isShutdown {
            releaseMpv()
        }
    }

    func attach(to layer: MpvMetalLayer) {
        queue.async { [weak self] in
            guard let self, !self.isShutdown else { return }
            guard self.mpv == nil else { return }
            self.attachedLayer = layer
            self.initializeMpv(layer: layer)
            if let pending = self.pendingLoad {
                self.pendingLoad = nil
                self.open(pending)
            }
        }
    }

    private func initializeMpv(layer: MpvMetalLayer) {
        guard let ctx = mpv_create() else {
            initializationError = "Не удалось инициализировать libmpv"
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
        setOption("hr-seek", "yes")
        setOption("cache", "yes")
        setOption("cache-secs", "120")
        setOption("demuxer-max-bytes", "64MiB")
        setOption("demuxer-max-back-bytes", "24MiB")
        setOption("stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_delay_max=5")
        setOption("user-agent", userAgent)
        setOption("sub-auto", "no")
        setOption("sub-ass", "yes")
        setOption("sub-ass-override", desiredSubScale == 1 ? "no" : "scale")
        setOption("sub-ass-force-margins", "no")
        setOption("sub-scale-signs", "no")
        setOption("embeddedfonts", "yes")
        setOption("sub-scale", String(format: "%.2f", desiredSubScale))
        if let fontsDir {
            setOption("config", "yes")
            setOption("config-dir", fontsDir.deletingLastPathComponent().path)
            setOption("load-scripts", "no")
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
        applyDesiredProperties()

        mpv_observe_property(ctx, 1, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(ctx, 2, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(ctx, 3, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(ctx, 4, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(ctx, 5, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(ctx, 6, "demuxer-cache-time", MPV_FORMAT_DOUBLE)
        mpv_observe_property(ctx, 7, "video-params/aspect", MPV_FORMAT_DOUBLE)

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
        audioTracks = []
        subtitleTracks = []
        embeddedChapters = []

        posLock.withLock {
            _position = startSeconds
            _duration = 0
        }
        clock.position = startSeconds
        clock.duration = 0
        clock.cacheTime = 0

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
        subtitle: String = "",
        artworkUrl: String? = nil
    ) {
        prepareForLoad(startSeconds: startSeconds)
        currentTitle = title
        currentSubtitle = subtitle
        fetchArtwork(urlString: artworkUrl)

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

    func setPaused(_ paused: Bool) {
        queue.async { [weak self] in
            self?.setFlag("pause", paused)
        }
    }

    func togglePause() {
        queue.async { [weak self] in
            self?.command(["cycle", "pause"])
        }
    }

    func seek(to seconds: Double) {
        let clamped = max(0, seconds)
        posLock.withLock { _position = clamped }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.clock.position = clamped
            self.updateNowPlaying()
        }
        queue.async { [weak self] in
            self?.command(["seek", String(format: "%.3f", clamped), "absolute+exact"])
        }
    }

    func seekRelative(_ delta: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            let target = max(0, self.currentPosition + delta)
            self.posLock.withLock { self._position = target }
            DispatchQueue.main.async {
                self.clock.position = target
                self.updateNowPlaying()
            }
            self.command(["seek", String(format: "%.3f", delta), "relative"])
        }
    }

    func setSpeed(_ speed: Double) {
        desiredSpeed = speed
        queue.async { [weak self] in
            self?.setDouble("speed", speed)
        }
        DispatchQueue.main.async { [weak self] in
            self?.updateNowPlaying()
        }
    }

    func setAspectFill(_ fill: Bool) {
        desiredAspectFill = fill
        queue.async { [weak self] in
            self?.setDouble("panscan", fill ? 1.0 : 0.0)
        }
    }

    func setSubtitlesVisible(_ visible: Bool) {
        desiredSubVisible = visible
        queue.async { [weak self] in
            self?.setFlag("sub-visibility", visible)
        }
    }

    func setSubtitleScale(_ scale: Double) {
        desiredSubScale = scale
        queue.async { [weak self] in
            guard let self else { return }
            self.setProperty("sub-ass-override", scale == 1 ? "no" : "scale")
            self.setDouble("sub-scale", scale)
        }
    }

    func setSubDelay(_ seconds: Double) {
        desiredSubDelay = seconds
        queue.async { [weak self] in
            self?.setDouble("sub-delay", seconds)
        }
    }

    func setSubPos(_ pos: Int) {
        desiredSubPos = pos
        queue.async { [weak self] in
            self?.setInt64("sub-pos", Int64(pos))
        }
    }

    func setAudioNormalize(_ enabled: Bool) {
        desiredNormalizeAudio = enabled
        queue.async { [weak self] in
            let filter = enabled ? "lavfi=[dynaudnorm=f=150:g=15:p=0.9:m=5]" : ""
            self?.setProperty("af", filter)
        }
    }

    func selectAudioTrack(id: Int) {
        queue.async { [weak self] in
            self?.setInt64("aid", Int64(id))
            self?.refreshTracks()
        }
    }

    func selectSubtitleTrack(id: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            if id <= 0 {
                self.desiredSubVisible = false
                self.setFlag("sub-visibility", false)
            } else {
                self.desiredSubVisible = true
                self.setInt64("sid", Int64(id))
                self.setFlag("sub-visibility", true)
            }
            self.refreshTracks()
        }
    }

    private func applyDesiredProperties() {
        setDouble("speed", desiredSpeed)
        setDouble("panscan", desiredAspectFill ? 1.0 : 0.0)
        setProperty("sub-ass-override", desiredSubScale == 1 ? "no" : "scale")
        setDouble("sub-scale", desiredSubScale)
        setDouble("sub-delay", desiredSubDelay)
        setInt64("sub-pos", Int64(desiredSubPos))
        setFlag("sub-visibility", desiredSubVisible)
        let filter = desiredNormalizeAudio ? "lavfi=[dynaudnorm=f=150:g=15:p=0.9:m=5]" : ""
        setProperty("af", filter)
    }

    @MainActor
    func shutdown() {
        loadID = UUID()
        NotificationCenter.default.removeObserver(self)
        clearRemoteCommands()
        queue.sync {
            releaseMpv()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func releaseMpv() {
        guard !isShutdown else { return }
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
            if let data = event.data {
                let start = data.assumingMemoryBound(to: mpv_event_start_file.self).pointee
                activePlaylistEntryId = start.playlist_entry_id
            }
            acceptsPlaybackEvents = true
        }
        guard acceptsPlaybackEvents else { return }

        switch event.event_id {
        case MPV_EVENT_FILE_LOADED:
            applyDesiredProperties()
            if let sub = pendingSubtitleFile {
                command(["sub-add", sub.path, "select"])
                setFlag("sub-visibility", desiredSubVisible)
            }
            refreshTracks()
            refreshChapters()
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
                if activePlaylistEntryId != 0 && end.playlist_entry_id != activePlaylistEntryId {
                    return
                }
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
                    posLock.withLock { _position = val }
                    let now = CFAbsoluteTimeGetCurrent()
                    if now - lastClockPush >= 0.25 {
                        lastClockPush = now
                        publishPlayback { $0.clock.position = val }
                    }
                }
            case "duration":
                if prop.format == MPV_FORMAT_DOUBLE, let valPtr = prop.data {
                    let val = valPtr.assumingMemoryBound(to: Double.self).pointee
                    posLock.withLock { _duration = val }
                    publishPlayback {
                        $0.clock.duration = val
                        $0.updateNowPlaying()
                    }
                }
            case "demuxer-cache-time":
                if prop.format == MPV_FORMAT_DOUBLE, let valPtr = prop.data {
                    let val = valPtr.assumingMemoryBound(to: Double.self).pointee
                    publishPlayback { $0.clock.cacheTime = val }
                }
            case "video-params/aspect":
                if prop.format == MPV_FORMAT_DOUBLE, let valPtr = prop.data {
                    let aspect = valPtr.assumingMemoryBound(to: Double.self).pointee
                    if aspect > 0.1 {
                        publishPlayback { $0.videoAspect = aspect }
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
                    publishPlayback {
                        if reached {
                            if !$0.isEnded {
                                $0.isEnded = true
                                $0.onEnded?()
                            }
                        } else {
                            $0.isEnded = false
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

    private func refreshTracks() {
        guard let ctx = mpv,
              let ptr = mpv_get_property_string(ctx, "track-list") else { return }
        defer { mpv_free(ptr) }
        let jsonStr = String(cString: ptr)
        guard let data = jsonStr.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        var audio: [MpvTrack] = []
        var subs: [MpvTrack] = []
        for item in raw {
            guard let id = item["id"] as? Int,
                  let type = item["type"] as? String else { continue }
            let track = MpvTrack(
                id: id,
                type: type,
                lang: item["lang"] as? String,
                title: item["title"] as? String,
                codec: item["codec"] as? String,
                isForced: (item["forced"] as? Bool) ?? false,
                isExternal: (item["external"] as? Bool) ?? false,
                isSelected: (item["selected"] as? Bool) ?? false
            )
            if type == "audio" { audio.append(track) }
            else if type == "sub" { subs.append(track) }
        }
        audio.sort { TrackNames.sortKey($0) < TrackNames.sortKey($1) }
        subs.sort { TrackNames.sortKey($0) < TrackNames.sortKey($1) }

        publishPlayback {
            $0.audioTracks = audio
            $0.subtitleTracks = subs
        }
    }

    private func refreshChapters() {
        guard let ctx = mpv,
              let ptr = mpv_get_property_string(ctx, "chapter-list") else { return }
        defer { mpv_free(ptr) }
        let jsonStr = String(cString: ptr)
        guard let data = jsonStr.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        let chapters: [PlayerChapter] = raw.compactMap { item in
            let title = (item["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let time = (item["time"] as? Double) ?? (item["time"] as? NSNumber)?.doubleValue ?? 0
            return PlayerChapter(start: max(0, time), title: title, kind: PlayerChapter.classify(title: title))
        }.sorted { $0.start < $1.start }

        publishPlayback {
            $0.embeddedChapters = chapters
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

    private func setInt64(_ name: String, _ value: Int64) {
        guard let ctx = mpv else { return }
        var v = value
        mpv_set_property(ctx, name, MPV_FORMAT_INT64, &v)
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
        guard let bundled = Bundle.main.url(forResource: "subfont", withExtension: "ttf"),
              let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let config = caches.appendingPathComponent("neifur_mpv", isDirectory: true)
        let fonts = config.appendingPathComponent("fonts", isDirectory: true)
        do {
            try fm.createDirectory(at: fonts, withIntermediateDirectories: true)
            let fallback = config.appendingPathComponent("subfont.ttf")
            if !fm.fileExists(atPath: fallback.path) { try fm.copyItem(at: bundled, to: fallback) }
            let namedFont = fonts.appendingPathComponent("Manrope-SemiBold.ttf")
            if !fm.fileExists(atPath: namedFont.path) { try fm.copyItem(at: bundled, to: namedFont) }
            if let manrope = Bundle.main.url(forResource: "manrope", withExtension: "ttf") {
                let manropeDest = fonts.appendingPathComponent("manrope.ttf")
                if !fm.fileExists(atPath: manropeDest.path) { try? fm.copyItem(at: manrope, to: manropeDest) }
            }
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
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleAudioRouteChange(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleAudioInterruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
    }

    @objc private func handleWillResignActive() {
        queue.sync {
            guard !isShutdown, mpv != nil else { return }
            setFlag("pause", true)
            setProperty("vid", "no")
        }
    }

    @objc private func handleEnterBackground() {
        queue.sync {
            guard !isShutdown, mpv != nil else { return }
            setFlag("pause", true)
            setProperty("vid", "no")
        }
    }

    @objc private func handleEnterForeground() {
        try? AVAudioSession.sharedInstance().setActive(true)
        queue.async { [weak self] in
            guard let self, !self.isShutdown else { return }
            self.setProperty("vid", "auto")
        }
    }

    @objc private func handleAudioRouteChange(_ notification: Notification) {
        guard let reasonVal = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonVal),
              reason == .oldDeviceUnavailable else { return }
        setPaused(true)
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }

        if type == .began {
            if !isPaused {
                pausedByInterruption = true
                setPaused(true)
            }
        } else if type == .ended {
            let optVal = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optVal)
            if pausedByInterruption && options.contains(.shouldResume) {
                pausedByInterruption = false
                try? AVAudioSession.sharedInstance().setActive(true)
                setPaused(false)
            }
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
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: posEvent.positionTime)
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
        center.changePlaybackPositionCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func fetchArtwork(urlString: String?) {
        currentArtwork = nil
        guard let urlString, let url = URL(string: urlString) else { return }
        let req = ImageRequest(url: url)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let img = try? await ImagePipeline.shared.image(for: req) {
                self.currentArtwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                self.updateNowPlaying()
            }
        }
    }

    private func updateNowPlaying() {
        let pos = currentPosition
        let dur = currentDuration
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentTitle,
            MPMediaItemPropertyArtist: currentSubtitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: pos,
            MPMediaItemPropertyPlaybackDuration: dur,
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0.0 : desiredSpeed
        ]
        if let artwork = currentArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        if dur <= 0 { info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
