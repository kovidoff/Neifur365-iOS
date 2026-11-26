import Combine
import Foundation
import UIKit

struct PlayerLaunchRequest: Identifiable, Hashable {
    let id = UUID()
    let seriesId: Int64
    let malId: Int64
    let animeTitle: String
    let posterUrl: String?
    let episodes: [Episode]
    let startIndex: Int
    let initialPickKey: String?
}

enum SleepTimerOption: Int, CaseIterable, Identifiable {
    case off = 0
    case endOfEpisode = -1
    case min15 = 15
    case min30 = 30
    case min45 = 45
    case min60 = 60
    case min90 = 90
    case min120 = 120

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: return "Выключен"
        case .endOfEpisode: return "До конца серии"
        case .min15: return "15 минут"
        case .min30: return "30 минут"
        case .min45: return "45 минут"
        case .min60: return "60 минут"
        case .min90: return "90 минут"
        case .min120: return "2 часа"
        }
    }
}

@MainActor
final class PlayerViewModel: ObservableObject {
    let request: PlayerLaunchRequest
    let engine: MpvEngine

    @Published var currentIndex: Int
    @Published var loadingStream = true
    @Published var errorMessage: String?
    @Published var isSubscriptionRequired = false
    @Published var isOfflinePlayback = false

    @Published var translations: [Translation] = []
    @Published var currentTranslation: Translation?
    @Published var availableQualities: [EmbedStream] = []
    @Published var selectedHeight: Int = 1080
    @Published var hasSubtitles = false
    @Published var subtitlesVisible = true
    @Published var subDelay: Double = 0.0

    @Published var speed: Double = 1.0
    @Published var aspectFill = false
    @Published var sleepTimer: SleepTimerOption = .off
    @Published var sleepRemainingSeconds: Int = 0
    @Published var markedWatchedNotice: String?
    @Published var toastNotice: String?

    @Published var chapters: [PlayerChapter] = []
    @Published var skipSegments: [SkipSegment] = []
    @Published var activeSkipSegment: SkipSegment?
    @Published var autoNextRemaining: Int?

    private let app: AppContainer
    private var hasStarted = false
    private var currentPickKey: String?
    private var currentOfflineTranslationId: Int64?
    private var lastSubtitleTempURL: URL?
    private var currentStreamUrls: [String] = []
    private var currentStreamUrlIndex = 0
    private var didTryChannelSwitchForLoad = false
    private var lastAniSkipQueryKey: String?
    private var prefetchedEpisodeId: Int64?
    private var prefetchedEmbeds: [Int64: (Date, Embed, [Translation])] = [:]

    private var markedEpisodeIds = Set<Int64>()
    private var deleteOnCloseIds = Set<Int64>()
    private var progressTimer: Task<Void, Never>?
    private var stallWatchdogTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var autoNextTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var stallAttempts = 0
    private var lastStallCheckPos: Double = -1
    private var isPausedExternally = false
    private var cancellables = Set<AnyCancellable>()

    var currentEpisode: Episode? {
        guard request.episodes.indices.contains(currentIndex) else { return nil }
        return request.episodes[currentIndex]
    }

    var hasPrevious: Bool { currentIndex > 0 }
    var hasNext: Bool { currentIndex + 1 < request.episodes.count }

    var groupedTranslations: [(TranslationKind, [Translation])] {
        TranslationPicker.options(translations, quality: app.prefs.quality)
    }

    init(request: PlayerLaunchRequest, app: AppContainer) {
        self.request = request
        self.app = app
        self.currentIndex = min(max(0, request.startIndex), max(0, request.episodes.count - 1))
        self.currentPickKey = request.initialPickKey ?? app.prefs.pick(animeId: request.seriesId)
        self.selectedHeight = app.prefs.quality
        self.engine = MpvEngine(userAgent: app.a365.userAgent)
        self.engine.setSubtitleScale(app.prefs.subScale)
        self.engine.setAudioNormalize(app.prefs.normalizeAudio)

        self.engine.onEnded = { [weak self] in
            self?.handlePlaybackEnded()
        }
        self.engine.onNextCommand = { [weak self] in
            Task { @MainActor in self?.playNext() }
        }
        self.engine.onPreviousCommand = { [weak self] in
            Task { @MainActor in self?.playPrevious() }
        }

        // Forward ONLY low-frequency engine states (never time-pos clock!).
        Publishers.MergeMany(
            engine.$isPaused.map { _ in () }.eraseToAnyPublisher(),
            engine.$isBuffering.map { _ in () }.eraseToAnyPublisher(),
            engine.$isReady.map { _ in () }.eraseToAnyPublisher(),
            engine.$isEnded.map { _ in () }.eraseToAnyPublisher(),
            engine.$playbackError.map { _ in () }.eraseToAnyPublisher(),
            engine.$audioTracks.map { _ in () }.eraseToAnyPublisher(),
            engine.$subtitleTracks.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            guard let self else { return }
            self.objectWillChange.send()
        }
        .store(in: &cancellables)

        engine.$playbackError
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] err in
                self?.handleEngineStreamError(err)
            }
            .store(in: &cancellables)

        engine.$embeddedChapters
            .receive(on: RunLoop.main)
            .sink { [weak self] embedded in
                guard let self else { return }
                if !embedded.isEmpty {
                    self.chapters = embedded
                }
            }
            .store(in: &cancellables)

        engine.$videoAspect
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateSubPosForAspect()
            }
            .store(in: &cancellables)

        engine.clock.$duration
            .receive(on: RunLoop.main)
            .sink { [weak self] dur in
                self?.maybeFetchAniSkip(duration: dur)
            }
            .store(in: &cancellables)

        engine.clock.$position
            .receive(on: RunLoop.main)
            .sink { [weak self] pos in
                self?.updateActiveSkipSegment(position: pos)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.saveCurrentProgress()
            }
            .store(in: &cancellables)
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        startProgressLoop()
        loadCurrentEpisode(resumeFromSaved: true)
    }

    func stop() {
        saveCurrentProgress()
        flushPendingDeleteOnClose()
        progressTimer?.cancel()
        stallWatchdogTask?.cancel()
        sleepTask?.cancel()
        autoNextTask?.cancel()
        loadTask?.cancel()
        engine.shutdown()
    }

    func loadCurrentEpisode(resumeFromSaved: Bool, preservePosition: Double? = nil) {
        guard let episode = currentEpisode else { return }
        loadTask?.cancel()
        cancelAutoNext()
        stallWatchdogTask?.cancel()
        stallAttempts = 0
        didTryChannelSwitchForLoad = false
        currentStreamUrls = []
        currentStreamUrlIndex = 0

        loadingStream = true
        errorMessage = nil
        isSubscriptionRequired = false
        isOfflinePlayback = false
        translations = []
        currentTranslation = nil
        currentOfflineTranslationId = nil
        availableQualities = []
        hasSubtitles = false
        lastSubtitleTempURL = nil
        chapters = []
        skipSegments = []
        activeSkipSegment = nil
        lastAniSkipQueryKey = nil
        subDelay = 0
        engine.setSubDelay(0)

        let startSec = preservePosition ?? (resumeFromSaved ? app.prefs.savedPosition(animeId: request.seriesId, episode: episode.number) : 0)
        engine.prepareForLoad(startSeconds: startSec)

        loadTask = Task {
            guard !Task.isCancelled else { return }

            // 1. Offline file first if already downloaded and ready
            if let offline = app.downloads.item(forEpisodeId: episode.id),
               offline.isReady,
               let videoUrl = app.downloads.videoURL(for: offline) {
                let subUrl = app.downloads.subtitleURL(for: offline)
                isOfflinePlayback = true
                currentOfflineTranslationId = offline.translationId
                selectedHeight = offline.qualityHeight
                hasSubtitles = subUrl != nil
                subtitlesVisible = true
                engine.setSubtitlesVisible(true)
                loadingStream = false
                engine.load(
                    url: videoUrl.absoluteString,
                    startSeconds: startSec,
                    subtitleFile: subUrl,
                    title: request.animeTitle,
                    subtitle: "\(episode.label) · \(offline.studioName) (офлайн)",
                    artworkUrl: request.posterUrl
                )
                return
            }

            // 2. Online stream (check prefetch cache first)
            do {
                if let cached = prefetchedEmbeds[episode.id],
                   Date().timeIntervalSince(cached.0) < 360 {
                    translations = cached.2
                    if let picked = TranslationPicker.choose(
                        all: cached.2,
                        pick: currentPickKey,
                        preferred: app.prefs.preferredKind,
                        favourites: app.prefs.favouriteStudioKeys,
                        quality: app.prefs.quality
                    ) {
                        currentTranslation = picked
                        if picked.id == cached.2.first?.id {
                            try await applyEmbed(cached.1, translation: picked, episode: episode, startSeconds: startSec, paused: false)
                            return
                        }
                        try await openTranslation(picked, episode: episode, startSeconds: startSec)
                        return
                    }
                }

                let fullEp = try await app.a365.episode(id: episode.id)
                if Task.isCancelled { return }
                let allTr = fullEp.translations ?? []
                translations = allTr

                guard let picked = TranslationPicker.choose(
                    all: allTr,
                    pick: currentPickKey,
                    preferred: app.prefs.preferredKind,
                    favourites: app.prefs.favouriteStudioKeys,
                    quality: app.prefs.quality
                ) else {
                    throw ApiError("Нет доступных озвучек или субтитров для этой серии")
                }

                currentTranslation = picked
                try await openTranslation(picked, episode: episode, startSeconds: startSec)
            } catch {
                if Task.isCancelled { return }
                loadingStream = false
                if error is SubscriptionRequiredError {
                    isSubscriptionRequired = true
                }
                errorMessage = error.userMessage
            }
        }
    }

    func selectTranslation(_ tr: Translation) {
        guard let episode = currentEpisode else { return }
        let prevTranslation = currentTranslation
        let prevPickKey = currentPickKey
        let wasReady = engine.isReady

        let resumePos = engine.currentPosition
        let wasPaused = engine.isPaused
        currentPickKey = tr.pickKey
        app.prefs.setPick(animeId: request.seriesId, key: tr.pickKey)
        currentTranslation = tr
        loadingStream = true
        errorMessage = nil
        isSubscriptionRequired = false

        loadTask?.cancel()
        if !wasReady {
            engine.prepareForLoad(startSeconds: resumePos)
        }
        loadTask = Task {
            do {
                try await openTranslation(tr, episode: episode, startSeconds: resumePos, paused: wasPaused)
            } catch {
                if Task.isCancelled { return }
                loadingStream = false
                if wasReady, let prevTranslation {
                    // Roll back cleanly instead of showing a dead error over playing video
                    currentTranslation = prevTranslation
                    currentPickKey = prevPickKey
                    if let prevKey = prevPickKey {
                        app.prefs.setPick(animeId: request.seriesId, key: prevKey)
                    }
                    showToast(error.userMessage)
                } else {
                    if error is SubscriptionRequiredError { isSubscriptionRequired = true }
                    errorMessage = error.userMessage
                }
            }
        }
    }

    func selectQuality(_ stream: EmbedStream) {
        guard !loadingStream, stream.height != selectedHeight,
              let episode = currentEpisode, !stream.urls.isEmpty else { return }
        let resumePos = engine.currentPosition
        selectedHeight = stream.height
        app.prefs.quality = stream.height
        currentStreamUrls = stream.urls
        currentStreamUrlIndex = 0

        guard let rawUrl = stream.urls.first else { return }
        engine.load(
            url: rawUrl,
            startSeconds: resumePos,
            subtitleFile: lastSubtitleTempURL,
            paused: engine.isPaused,
            title: request.animeTitle,
            subtitle: "\(episode.label) · \(currentTranslation?.author ?? "")",
            artworkUrl: request.posterUrl
        )
    }

    private func openTranslation(_ tr: Translation, episode: Episode, startSeconds: Double, paused: Bool = false) async throws {
        let embed = try await app.a365.embed(translationId: tr.id)
        if Task.isCancelled { return }
        try await applyEmbed(embed, translation: tr, episode: episode, startSeconds: startSeconds, paused: paused)
    }

    private func applyEmbed(_ embed: Embed, translation tr: Translation, episode: Episode, startSeconds: Double, paused: Bool) async throws {
        var heights = Set<Int>()
        let sortedStreams = embed.stream
            .filter { !$0.urls.isEmpty && heights.insert($0.height).inserted }
            .sorted { $0.height > $1.height }

        let targetQ = app.prefs.quality
        let bestStream = sortedStreams.first(where: { $0.height <= targetQ }) ?? sortedStreams.last
        guard let chosen = bestStream, let rawUrl = chosen.urls.first else {
            throw ApiError("Не удалось получить ссылку на видео")
        }

        let subtitle = await app.a365.subtitles(for: embed)
        guard !Task.isCancelled else { return }

        var subFile: URL?
        if let subtitle {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("neifur_sub_\(tr.id).\(subtitle.fileExtension)")
            if (try? subtitle.data.write(to: temp, options: .atomic)) != nil { subFile = temp }
        }

        availableQualities = sortedStreams
        selectedHeight = chosen.height
        currentStreamUrls = chosen.urls
        currentStreamUrlIndex = 0
        lastSubtitleTempURL = subFile
        hasSubtitles = subFile != nil

        // Never disable subtitles when the user intentionally picked a subtitle translation.
        let showSubs = tr.kind.isSubs ? true : (subFile != nil)
        subtitlesVisible = showSubs
        engine.setSubtitlesVisible(showSubs)

        loadingStream = false
        engine.load(
            url: rawUrl,
            startSeconds: startSeconds,
            subtitleFile: subFile,
            paused: paused,
            title: request.animeTitle,
            subtitle: "\(episode.label) · \(tr.author)",
            artworkUrl: request.posterUrl
        )
        engine.setSpeed(speed)
        engine.setAspectFill(aspectFill)
        engine.setSubtitleScale(app.prefs.subScale)
        updateSubPosForAspect()
    }

    private func handleEngineStreamError(_ message: String) {
        guard !isOfflinePlayback, let episode = currentEpisode else {
            errorMessage = message
            return
        }

        // 1. Try next mirror URL in current EmbedStream
        let nextUrlIdx = currentStreamUrlIndex + 1
        if currentStreamUrls.indices.contains(nextUrlIdx) {
            currentStreamUrlIndex = nextUrlIdx
            let url = currentStreamUrls[nextUrlIdx]
            let resume = engine.currentPosition
            engine.load(
                url: url,
                startSeconds: resume,
                subtitleFile: lastSubtitleTempURL,
                paused: false,
                title: request.animeTitle,
                subtitle: "\(episode.label) · \(currentTranslation?.author ?? "")",
                artworkUrl: request.posterUrl
            )
            return
        }

        // 2. Ask ChannelPilot to find a working CDN channel and retry fresh embed once
        if !didTryChannelSwitchForLoad, let tr = currentTranslation {
            didTryChannelSwitchForLoad = true
            let resume = engine.currentPosition
            loadingStream = true
            engine.playbackError = nil
            Task {
                let switched = await app.channelPilot.ensureWorking(preferSwitch: true)
                if let (_, newCh) = switched {
                    showToast("Канал переключён на «\(newCh.label)»")
                }
                do {
                    try await openTranslation(tr, episode: episode, startSeconds: resume)
                } catch {
                    loadingStream = false
                    errorMessage = error.userMessage
                }
            }
            return
        }

        errorMessage = message
    }

    func selectEpisode(at index: Int) {
        guard request.episodes.indices.contains(index), index != currentIndex else { return }
        cancelAutoNext()
        saveCurrentProgress()
        flushPendingDeleteOnClose()
        currentIndex = index
        loadCurrentEpisode(resumeFromSaved: true)
    }

    func playNext() {
        guard hasNext else { return }
        selectEpisode(at: currentIndex + 1)
    }

    func playPrevious() {
        guard hasPrevious else { return }
        selectEpisode(at: currentIndex - 1)
    }

    func setSpeed(_ value: Double) {
        speed = value
        engine.setSpeed(value)
    }

    func setAspectFill(_ fill: Bool) {
        guard aspectFill != fill else { return }
        aspectFill = fill
        engine.setAspectFill(fill)
        updateSubPosForAspect()
    }

    func toggleAspectFill() {
        setAspectFill(!aspectFill)
    }

    private func updateSubPosForAspect() {
        guard aspectFill else {
            engine.setSubPos(100)
            return
        }
        let bounds = UIScreen.main.bounds
        let screenAspect = max(bounds.width, bounds.height) / max(min(bounds.width, bounds.height), 1)
        let videoAspect = max(engine.videoAspect, 0.5)
        if screenAspect > videoAspect * 1.08 {
            let visibleFraction = videoAspect / screenAspect
            let lifted = Int((visibleFraction * 100).rounded())
            engine.setSubPos(min(max(lifted, 82), 95))
        } else {
            engine.setSubPos(100)
        }
    }

    func toggleSubtitles() {
        subtitlesVisible.toggle()
        engine.setSubtitlesVisible(subtitlesVisible)
    }

    func setSubtitleScale(_ scale: Double) {
        app.prefs.subScale = scale
        engine.setSubtitleScale(scale)
    }

    func adjustSubDelay(by delta: Double) {
        subDelay = ((subDelay + delta) * 10).rounded() / 10
        engine.setSubDelay(subDelay)
    }

    func resetSubDelay() {
        subDelay = 0
        engine.setSubDelay(0)
    }

    func setSleepTimer(_ option: SleepTimerOption) {
        sleepTimer = option
        sleepTask?.cancel()
        sleepTask = nil
        sleepRemainingSeconds = 0
        guard option.rawValue > 0 else { return }
        sleepRemainingSeconds = option.rawValue * 60
        sleepTask = Task {
            while sleepRemainingSeconds > 0 && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                sleepRemainingSeconds -= 1
            }
            if !Task.isCancelled {
                engine.setPaused(true)
                sleepTimer = .off
                sleepRemainingSeconds = 0
            }
        }
    }

    func extendSleepTimerBy5Minutes() {
        guard sleepTimer.rawValue > 0 else { return }
        sleepRemainingSeconds += 300
    }

    func skipOpening() {
        if let active = activeSkipSegment {
            engine.seek(to: active.end)
            activeSkipSegment = nil
        } else {
            engine.seekRelative(85)
        }
    }

    func setSheetPaused(_ paused: Bool) {
        isPausedExternally = paused
        if paused {
            autoNextTask?.cancel()
        }
    }

    func cancelAutoNext() {
        autoNextTask?.cancel()
        autoNextTask = nil
        autoNextRemaining = nil
    }

    private func handlePlaybackEnded() {
        saveCurrentProgress(forceFinished: true)
        markCurrentWatchedIfNeeded()
        if let ep = currentEpisode, app.prefs.autoDeleteDownloaded {
            deleteOnCloseIds.insert(ep.id)
        }
        if sleepTimer == .endOfEpisode {
            engine.setPaused(true)
            sleepTimer = .off
            return
        }
        guard hasNext else { return }
        startAutoNextCountdown()
    }

    private func startAutoNextCountdown() {
        cancelAutoNext()
        autoNextRemaining = 7
        autoNextTask = Task {
            while let rem = autoNextRemaining, rem > 0, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                if isPausedExternally { continue }
                autoNextRemaining = rem - 1
            }
            if !Task.isCancelled {
                autoNextRemaining = nil
                playNext()
            }
        }
    }

    private func startProgressLoop() {
        progressTimer?.cancel()
        progressTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                saveCurrentProgress()
                checkAutoMarkWatched()
                maybePrefetchNext()
                checkStallWatchdog()
            }
        }
    }

    private func checkStallWatchdog() {
        guard engine.isReady && engine.isBuffering && !engine.isPaused && errorMessage == nil else {
            stallAttempts = 0
            lastStallCheckPos = -1
            return
        }
        let pos = engine.currentPosition
        if abs(pos - lastStallCheckPos) < 0.2 {
            stallAttempts += 1
            if stallAttempts == 2 {
                // Soft kick: re-seek to current position to wake demuxer
                engine.seek(to: pos)
            } else if stallAttempts >= 4 {
                stallAttempts = 0
                handleEngineStreamError("Буферизация зависла")
            }
        } else {
            stallAttempts = 0
        }
        lastStallCheckPos = pos
    }

    private func maybePrefetchNext() {
        guard hasNext, !isOfflinePlayback else { return }
        let dur = engine.currentDuration
        let pos = engine.currentPosition
        guard dur > 60, pos / dur >= 0.88 else { return }
        let nextEp = request.episodes[currentIndex + 1]
        guard prefetchedEpisodeId != nextEp.id else { return }
        prefetchedEpisodeId = nextEp.id

        Task {
            guard let fullEp = try? await app.a365.episode(id: nextEp.id),
                  let trs = fullEp.translations,
                  let picked = TranslationPicker.choose(
                    all: trs,
                    pick: currentPickKey,
                    preferred: app.prefs.preferredKind,
                    favourites: app.prefs.favouriteStudioKeys,
                    quality: app.prefs.quality
                  ),
                  let embed = try? await app.a365.embed(translationId: picked.id) else { return }
            prefetchedEmbeds[nextEp.id] = (Date(), embed, trs)
        }
    }

    private func maybeFetchAniSkip(duration: Double) {
        guard app.prefs.aniskipEnabled,
              request.malId > 0,
              duration > 60,
              let ep = currentEpisode,
              ep.number > 0,
              engine.embeddedChapters.isEmpty else { return }

        let key = "\(request.malId)-\(ep.number)-\(Int(duration))"
        guard lastAniSkipQueryKey != key else { return }
        lastAniSkipQueryKey = key

        Task {
            let segs = await app.aniSkip.skipTimes(malId: request.malId, episodeNumber: ep.number, videoDurationSec: duration)
            guard !Task.isCancelled, self.lastAniSkipQueryKey == key, !segs.isEmpty else { return }
            self.skipSegments = segs
            if self.engine.embeddedChapters.isEmpty {
                self.chapters = AniSkipParser.skipSegmentsToChapters(segs, duration: duration)
            }
            self.updateActiveSkipSegment(position: self.engine.currentPosition)
        }
    }

    private func updateActiveSkipSegment(position: Double) {
        if !skipSegments.isEmpty {
            let hit = skipSegments.first { position >= $0.start && position < ($0.end - 1.5) }
            if hit != activeSkipSegment {
                activeSkipSegment = hit
            }
            return
        }
        // Fallback to embedded chapter if it is an OP/ED/Recap
        guard !chapters.isEmpty else {
            if activeSkipSegment != nil { activeSkipSegment = nil }
            return
        }
        let dur = engine.currentDuration
        for idx in chapters.indices {
            let ch = chapters[idx]
            guard ch.kind.isSkippable else { continue }
            let end = (idx + 1 < chapters.count) ? chapters[idx + 1].start : dur
            if position >= ch.start && position < end - 1.5 && (end - ch.start) >= 5 {
                let seg = SkipSegment(start: ch.start, end: end, kind: ch.kind, label: ch.title.isEmpty ? "Заставка" : ch.title)
                if activeSkipSegment != seg { activeSkipSegment = seg }
                return
            }
        }
        if activeSkipSegment != nil { activeSkipSegment = nil }
    }

    func saveCurrentProgress(forceFinished: Bool = false) {
        let dur = engine.currentDuration
        guard let ep = currentEpisode, dur > 30 else { return }
        let pos = forceFinished ? dur : engine.currentPosition
        guard pos > 3 else { return }
        app.prefs.recordProgress(
            animeId: request.seriesId,
            title: request.animeTitle,
            poster: request.posterUrl,
            episode: ep.number,
            positionSec: pos,
            durationSec: dur
        )
        if app.prefs.autoDeleteDownloaded && pos / dur > 0.92 {
            deleteOnCloseIds.insert(ep.id)
        }
    }

    private func flushPendingDeleteOnClose() {
        guard app.prefs.autoDeleteDownloaded, !deleteOnCloseIds.isEmpty else { return }
        for id in deleteOnCloseIds {
            app.downloads.handleEpisodeFinished(episodeId: id)
        }
        deleteOnCloseIds.removeAll()
    }

    private func checkAutoMarkWatched() {
        let dur = engine.currentDuration
        guard dur > 60 else { return }
        if engine.currentPosition / dur >= 0.85 {
            markCurrentWatchedIfNeeded()
        }
    }

    private func markCurrentWatchedIfNeeded() {
        guard let ep = currentEpisode,
              !markedEpisodeIds.contains(ep.id),
              app.account.isSignedIn,
              let trId = currentTranslation?.id ?? currentOfflineTranslationId else { return }
        markedEpisodeIds.insert(ep.id)

        Task {
            do {
                try await app.a365.markWatched(translationId: trId)
                app.lists.refresh()
                markedWatchedNotice = "\(ep.label) отмечена просмотренной"
                try? await Task.sleep(nanoseconds: 2_800_000_000)
                if markedWatchedNotice == "\(ep.label) отмечена просмотренной" {
                    markedWatchedNotice = nil
                }
            } catch {
                app.prefs.queuePendingWatch(seriesId: request.seriesId, episodeNumber: ep.number, translationId: trId)
            }
        }
    }

    func showToast(_ text: String) {
        toastNotice = text
        Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if toastNotice == text { toastNotice = nil }
        }
    }
}
