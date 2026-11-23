import Combine
import Foundation

struct PlayerLaunchRequest: Identifiable, Hashable {
    let id = UUID()
    let seriesId: Int64
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

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: return "Выключен"
        case .endOfEpisode: return "До конца серии"
        case .min15: return "15 минут"
        case .min30: return "30 минут"
        case .min45: return "45 минут"
        case .min60: return "60 минут"
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
    @Published var isOfflinePlayback = false

    @Published var translations: [Translation] = []
    @Published var currentTranslation: Translation?
    @Published var availableQualities: [EmbedStream] = []
    @Published var selectedHeight: Int = 1080
    @Published var hasSubtitles = false
    @Published var subtitlesVisible = true

    @Published var speed: Double = 1.0
    @Published var aspectFill = false
    @Published var sleepTimer: SleepTimerOption = .off
    @Published var markedWatchedNotice: String?

    private let app: AppContainer
    private var currentPickKey: String?
    private var markedEpisodeIds = Set<Int64>()
    private var progressTimer: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
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

        self.engine.onEnded = { [weak self] in
            self?.handlePlaybackEnded()
        }
        self.engine.onNextCommand = { [weak self] in
            Task { @MainActor in self?.playNext() }
        }
        self.engine.onPreviousCommand = { [weak self] in
            Task { @MainActor in self?.playPrevious() }
        }

        // Forward engine changes so SwiftUI controls re-render smoothly.
        engine.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func start() {
        startProgressLoop()
        loadCurrentEpisode(resumeFromSaved: true)
    }

    func stop() {
        saveCurrentProgress()
        progressTimer?.cancel()
        sleepTask?.cancel()
        loadTask?.cancel()
        engine.shutdown()
    }

    func loadCurrentEpisode(resumeFromSaved: Bool) {
        guard let episode = currentEpisode else { return }
        loadTask?.cancel()
        loadingStream = true
        errorMessage = nil
        isOfflinePlayback = false
        translations = []
        currentTranslation = nil
        availableQualities = []
        hasSubtitles = false
        lastSubtitleTempURL = nil

        let startSec = resumeFromSaved ? app.prefs.savedPosition(animeId: request.seriesId, episode: episode.number) : 0
        engine.prepareForLoad(startSeconds: startSec)

        loadTask = Task {
            guard !Task.isCancelled else { return }
            // 1. Offline file first if already downloaded and ready
            if let offline = app.downloads.item(forEpisodeId: episode.id),
               offline.isReady,
               let videoUrl = app.downloads.videoURL(for: offline) {
                let subUrl = app.downloads.subtitleURL(for: offline)
                isOfflinePlayback = true
                selectedHeight = offline.qualityHeight
                hasSubtitles = subUrl != nil
                loadingStream = false
                engine.load(
                    url: videoUrl.absoluteString,
                    startSeconds: startSec,
                    subtitleFile: subUrl,
                    title: request.animeTitle,
                    subtitle: "\(episode.label) · \(offline.studioName) (офлайн)"
                )
                return
            }

            // 2. Online stream via Anime 365
            do {
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
                errorMessage = error.userMessage
            }
        }
    }

    func selectTranslation(_ tr: Translation) {
        guard let episode = currentEpisode else { return }
        let resumePos = engine.position
        let wasPaused = engine.isPaused
        currentPickKey = tr.pickKey
        app.prefs.setPick(animeId: request.seriesId, key: tr.pickKey)
        currentTranslation = tr
        loadingStream = true
        errorMessage = nil
        availableQualities = []
        hasSubtitles = false

        loadTask?.cancel()
        engine.prepareForLoad(startSeconds: resumePos)
        loadTask = Task {
            do {
                try await openTranslation(tr, episode: episode, startSeconds: resumePos, paused: wasPaused)
            } catch {
                if Task.isCancelled { return }
                loadingStream = false
                errorMessage = error.userMessage
            }
        }
    }

    func selectQuality(_ stream: EmbedStream) {
        guard !loadingStream, stream.height != selectedHeight,
              let episode = currentEpisode, let url = stream.urls.first else { return }
        let resumePos = engine.position
        selectedHeight = stream.height
        app.prefs.quality = stream.height
        let subFile = lastSubtitleTempURL
        engine.load(
            url: url,
            startSeconds: resumePos,
            subtitleFile: subFile,
            paused: engine.isPaused,
            title: request.animeTitle,
            subtitle: "\(episode.label) · \(currentTranslation?.author ?? "")"
        )
    }

    private var lastSubtitleTempURL: URL?

    private func openTranslation(_ tr: Translation, episode: Episode, startSeconds: Double, paused: Bool = false) async throws {
        let embed = try await app.a365.embed(translationId: tr.id)
        if Task.isCancelled { return }

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
        lastSubtitleTempURL = subFile
        hasSubtitles = subFile != nil
        loadingStream = false

        engine.load(
            url: rawUrl,
            startSeconds: startSeconds,
            subtitleFile: subFile,
            paused: paused,
            title: request.animeTitle,
            subtitle: "\(episode.label) · \(tr.author)"
        )
        engine.setSpeed(speed)
        engine.setAspectFill(aspectFill)
        engine.setSubtitleScale(app.prefs.subScale)
    }

    func selectEpisode(at index: Int) {
        guard request.episodes.indices.contains(index), index != currentIndex else { return }
        saveCurrentProgress()
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

    func toggleAspectFill() {
        aspectFill.toggle()
        engine.setAspectFill(aspectFill)
    }

    func toggleSubtitles() {
        subtitlesVisible.toggle()
        engine.setSubtitlesVisible(subtitlesVisible)
    }

    func setSubtitleScale(_ scale: Double) {
        app.prefs.subScale = scale
        engine.setSubtitleScale(scale)
    }

    func setSleepTimer(_ option: SleepTimerOption) {
        sleepTimer = option
        sleepTask?.cancel()
        sleepTask = nil
        guard option.rawValue > 0 else { return }
        let mins = option.rawValue
        sleepTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(mins) * 60 * 1_000_000_000)
            if !Task.isCancelled {
                engine.setPaused(true)
                sleepTimer = .off
            }
        }
    }

    func skipOpening() {
        engine.seekRelative(85)
    }

    private func handlePlaybackEnded() {
        saveCurrentProgress(forceFinished: true)
        markCurrentWatchedIfNeeded()
        if let ep = currentEpisode {
            app.downloads.handleEpisodeFinished(episodeId: ep.id)
        }
        if sleepTimer == .endOfEpisode {
            engine.setPaused(true)
            sleepTimer = .off
            return
        }
        if hasNext {
            playNext()
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
            }
        }
    }

    func saveCurrentProgress(forceFinished: Bool = false) {
        guard let ep = currentEpisode, engine.duration > 30 else { return }
        let pos = forceFinished ? engine.duration : engine.position
        guard pos > 3 else { return }
        app.prefs.recordProgress(
            animeId: request.seriesId,
            title: request.animeTitle,
            poster: request.posterUrl,
            episode: ep.number,
            positionSec: pos,
            durationSec: engine.duration
        )
    }

    private func checkAutoMarkWatched() {
        guard engine.duration > 60 else { return }
        if engine.position / engine.duration >= 0.85 {
            markCurrentWatchedIfNeeded()
        }
    }

    private func markCurrentWatchedIfNeeded() {
        guard let ep = currentEpisode,
              !markedEpisodeIds.contains(ep.id),
              app.account.isSignedIn,
              let trId = currentTranslation?.id else { return }
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
                markedEpisodeIds.remove(ep.id)
            }
        }
    }
}
