import Foundation

enum DownloadStatus: String, Codable, Hashable {
    case queued
    case downloading
    case completed
    case failed
}

struct DownloadedEpisode: Codable, Hashable, Identifiable {
    let episodeId: Int64
    let animeId: Int64
    let animeTitle: String
    let posterUrl: String?
    let episodeNumber: Int
    let episodeLabel: String
    let translationId: Int64
    let studioName: String
    let translationKind: TranslationKind
    let qualityHeight: Int
    var status: DownloadStatus
    var progress: Double
    var bytesDownloaded: Int64
    var totalBytes: Int64
    var videoFileName: String?
    var subtitleFileName: String?
    var errorMessage: String?
    var addedAt: Date

    var id: Int64 { episodeId }
    var isReady: Bool { status == .completed && videoFileName != nil }

    func toEpisode() -> Episode {
        Episode(
            id: episodeId,
            episodeFull: episodeLabel,
            episodeInt: Double(episodeNumber),
            episodeType: "tv",
            isActive: 1,
            seriesId: animeId
        )
    }
}

struct DownloadedAnime: Identifiable, Hashable {
    let animeId: Int64
    let title: String
    let posterUrl: String?
    let episodes: [DownloadedEpisode]

    var id: Int64 { animeId }
    var totalBytes: Int64 { episodes.reduce(0) { $0 + max($1.totalBytes, $1.bytesDownloaded) } }
    var readyCount: Int { episodes.filter(\.isReady).count }
}

func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useMB, .useGB, .useKB]
    return formatter.string(fromByteCount: max(bytes, 0))
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    @Published private(set) var items: [DownloadedEpisode] = []

    private let api: Anime365Client
    private let prefs: Prefs
    private let fm = FileManager.default
    private let downloadsDir: URL
    private let indexUrl: URL

    private var bgSession: URLSession!
    private var activeTasks: [Int64: URLSessionDownloadTask] = [:]
    private var episodeIdByTaskId: [Int: Int64] = [:]

    var byAnime: [DownloadedAnime] {
        let grouped = Dictionary(grouping: items, by: \.animeId)
        return grouped.values.compactMap { list -> DownloadedAnime? in
            guard let first = list.first else { return nil }
            let sorted = list.sorted { $0.episodeNumber < $1.episodeNumber }
            return DownloadedAnime(
                animeId: first.animeId,
                title: first.animeTitle,
                posterUrl: first.posterUrl,
                episodes: sorted
            )
        }.sorted { a, b in
            let la = a.episodes.map(\.addedAt).max() ?? .distantPast
            let lb = b.episodes.map(\.addedAt).max() ?? .distantPast
            return la > lb
        }
    }

    var totalStorageBytes: Int64 {
        items.filter(\.isReady).reduce(0) { $0 + max($1.totalBytes, $1.bytesDownloaded) }
    }

    var activeCount: Int {
        items.filter { $0.status == .downloading || $0.status == .queued }.count
    }

    init(api: Anime365Client, prefs: Prefs) {
        self.api = api
        self.prefs = prefs

        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        self.downloadsDir = appSupport.appendingPathComponent("NeifurDownloads", isDirectory: true)
        self.indexUrl = downloadsDir.appendingPathComponent("index.json")

        super.init()

        try? fm.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDir = downloadsDir
        try? mutableDir.setResourceValues(resourceValues)

        let cfg = URLSessionConfiguration.background(withIdentifier: "app.neifur365.ios.downloads")
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        cfg.httpAdditionalHeaders = ["User-Agent": api.userAgent]
        self.bgSession = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)

        loadIndex()
    }

    func item(forEpisodeId id: Int64) -> DownloadedEpisode? {
        items.first { $0.episodeId == id }
    }

    func videoURL(for item: DownloadedEpisode) -> URL? {
        guard let name = item.videoFileName else { return nil }
        let url = downloadsDir.appendingPathComponent(name)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    func subtitleURL(for item: DownloadedEpisode) -> URL? {
        guard let name = item.subtitleFileName else { return nil }
        let url = downloadsDir.appendingPathComponent(name)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    /// Queues one episode for background download (resolving embed URL + downloading .ass subtitles if present).
    func enqueue(
        series: Series,
        episode: Episode,
        studio: Studio?,
        fallbackTranslation: Translation? = nil
    ) async throws {
        if let existing = item(forEpisodeId: episode.id),
           existing.status == .completed || existing.status == .downloading {
            return
        }

        let targetQuality = prefs.downloadQuality
        let translation: Translation
        if let chosen = fallbackTranslation {
            translation = chosen
        } else if let studio, let variants = studio.byEpisode[episode.id],
                  let best = TranslationPicker.best(variants, quality: targetQuality) {
            translation = best
        } else {
            let fullEp = try await api.episode(id: episode.id)
            guard let picked = TranslationPicker.choose(
                all: fullEp.translations ?? [],
                pick: prefs.pick(animeId: series.id),
                preferred: prefs.preferredKind,
                favourites: prefs.favouriteStudioKeys,
                quality: targetQuality
            ) else {
                throw ApiError("Нет доступных озвучек для серии \(episode.number)")
            }
            translation = picked
        }

        let embed = try await api.embed(translationId: translation.id)
        let sortedStreams = embed.stream.sorted { a, b in
            let aFit = a.height <= targetQuality ? 1 : 0
            let bFit = b.height <= targetQuality ? 1 : 0
            if aFit != bFit { return aFit > bFit }
            return a.height > b.height
        }
        guard let stream = sortedStreams.first(where: { !$0.urls.isEmpty }),
              let rawUrl = stream.urls.first,
              let videoUrl = URL(string: rawUrl) else {
            throw ApiError("Anime 365 не выдал ссылку на видео для скачивания")
        }

        var subFileName: String? = nil
        if let subUrl = embed.subtitlesUrl ?? embed.subtitlesVttUrl, !subUrl.isEmpty {
            if let subContent = try? await api.subtitles(url: subUrl), !subContent.isEmpty {
                let ext = subUrl.lowercased().contains("vtt") ? "vtt" : "ass"
                let name = "ep_\(episode.id).\(ext)"
                let dest = downloadsDir.appendingPathComponent(name)
                try? subContent.data(using: .utf8)?.write(to: dest, options: .atomic)
                subFileName = name
            }
        }

        let record = DownloadedEpisode(
            episodeId: episode.id,
            animeId: series.id,
            animeTitle: series.title,
            posterUrl: series.bestPosterUrl,
            episodeNumber: episode.number,
            episodeLabel: episode.label,
            translationId: translation.id,
            studioName: translation.author,
            translationKind: translation.kind,
            qualityHeight: stream.height > 0 ? stream.height : targetQuality,
            status: .downloading,
            progress: 0,
            bytesDownloaded: 0,
            totalBytes: 0,
            videoFileName: nil,
            subtitleFileName: subFileName,
            errorMessage: nil,
            addedAt: Date()
        )
        upsert(record)

        var req = URLRequest(url: videoUrl)
        req.setValue(api.userAgent, forHTTPHeaderField: "User-Agent")
        let task = bgSession.downloadTask(with: req)
        task.taskDescription = String(episode.id)
        activeTasks[episode.id] = task
        episodeIdByTaskId[task.taskIdentifier] = episode.id
        task.resume()
    }

    func enqueueBatch(series: Series, episodes: [Episode], studio: Studio?, count: Int = 3) async -> Int {
        var started = 0
        for ep in episodes.prefix(count) {
            if let existing = item(forEpisodeId: ep.id),
               existing.status == .completed || existing.status == .downloading {
                continue
            }
            if (try? await enqueue(series: series, episode: ep, studio: studio)) != nil {
                started += 1
            }
        }
        return started
    }

    func cancelOrDelete(episodeId: Int64) {
        if let task = activeTasks.removeValue(forKey: episodeId) {
            episodeIdByTaskId.removeValue(forKey: task.taskIdentifier)
            task.cancel()
        }
        if let item = item(forEpisodeId: episodeId) {
            if let vf = item.videoFileName {
                try? fm.removeItem(at: downloadsDir.appendingPathComponent(vf))
            }
            if let sf = item.subtitleFileName {
                try? fm.removeItem(at: downloadsDir.appendingPathComponent(sf))
            }
        }
        items.removeAll { $0.episodeId == episodeId }
        saveIndex()
    }

    func deleteAnime(animeId: Int64) {
        let ids = items.filter { $0.animeId == animeId }.map(\.episodeId)
        for id in ids { cancelOrDelete(episodeId: id) }
    }

    func clearAll() {
        let ids = items.map(\.episodeId)
        for id in ids { cancelOrDelete(episodeId: id) }
    }

    func handleEpisodeFinished(episodeId: Int64) {
        guard prefs.autoDeleteDownloaded, let item = item(forEpisodeId: episodeId), item.isReady else { return }
        cancelOrDelete(episodeId: episodeId)
    }

    private func upsert(_ record: DownloadedEpisode) {
        if let idx = items.firstIndex(where: { $0.episodeId == record.episodeId }) {
            items[idx] = record
        } else {
            items.insert(record, at: 0)
        }
        saveIndex()
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexUrl),
              let decoded = try? JSONDecoder().decode([DownloadedEpisode].self, from: data) else {
            items = []
            return
        }
        items = decoded.map { item in
            var copy = item
            if copy.status == .completed, let vf = copy.videoFileName {
                if !fm.fileExists(atPath: downloadsDir.appendingPathComponent(vf).path) {
                    copy.status = .failed
                    copy.errorMessage = "Файл удалён"
                }
            }
            return copy
        }
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: indexUrl, options: .atomic)
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let epId = downloadTask.taskDescription.flatMap(Int64.init)
        Task { @MainActor [weak self] in
            guard let self, let id = epId ?? self.episodeIdByTaskId[downloadTask.taskIdentifier],
                  let idx = self.items.firstIndex(where: { $0.episodeId == id }) else { return }
            self.items[idx].status = .downloading
            self.items[idx].bytesDownloaded = totalBytesWritten
            if totalBytesExpectedToWrite > 0 {
                self.items[idx].totalBytes = totalBytesExpectedToWrite
                self.items[idx].progress = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let epId = downloadTask.taskDescription.flatMap(Int64.init)
        guard let epId else { return }
        let fileName = "ep_\(epId).mp4"
        let dest = downloadsDir.appendingPathComponent(fileName)
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        var moveError: String? = nil
        var finalSize: Int64 = 0
        do {
            try fm.moveItem(at: location, to: dest)
            if let attrs = try? fm.attributesOfItem(atPath: dest.path),
               let size = attrs[.size] as? NSNumber {
                finalSize = size.int64Value
            }
        } catch {
            moveError = error.localizedDescription
        }

        Task { @MainActor [weak self] in
            guard let self, let idx = self.items.firstIndex(where: { $0.episodeId == epId }) else { return }
            self.activeTasks.removeValue(forKey: epId)
            self.episodeIdByTaskId.removeValue(forKey: downloadTask.taskIdentifier)
            if let moveError {
                self.items[idx].status = .failed
                self.items[idx].errorMessage = moveError
            } else {
                self.items[idx].status = .completed
                self.items[idx].progress = 1.0
                self.items[idx].videoFileName = fileName
                if finalSize > 0 {
                    self.items[idx].bytesDownloaded = finalSize
                    self.items[idx].totalBytes = finalSize
                }
                self.items[idx].errorMessage = nil
            }
            self.saveIndex()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        let epId = task.taskDescription.flatMap(Int64.init)
        Task { @MainActor [weak self] in
            guard let self, let id = epId ?? self.episodeIdByTaskId[task.taskIdentifier],
                  let idx = self.items.firstIndex(where: { $0.episodeId == id }) else { return }
            self.activeTasks.removeValue(forKey: id)
            self.episodeIdByTaskId.removeValue(forKey: task.taskIdentifier)
            self.items[idx].status = .failed
            self.items[idx].errorMessage = error.userMessage
            self.saveIndex()
        }
    }
}
