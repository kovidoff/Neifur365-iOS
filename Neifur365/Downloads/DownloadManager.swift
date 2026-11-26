import Combine
import Foundation

enum DownloadStatus: String, Codable, Hashable {
    case queued
    case waitingWifi
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
    var transferId: UUID?
    var pendingUrlString: String?

    var id: Int64 { episodeId }
    var isReady: Bool { status == .completed && videoFileName != nil }
    var isActive: Bool { status == .queued || status == .downloading || status == .waitingWifi }

    fileprivate var taskDescription: String {
        transferId.map { "\(episodeId):\($0.uuidString)" } ?? String(episodeId)
    }

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
    AppFormatters.formatBytes(bytes)
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let sessionIdentifier = "app.neifur365.ios.downloads"

    @Published private(set) var items: [DownloadedEpisode] = []

    private let api: Anime365Client
    private let prefs: Prefs
    private let network: NetworkMonitor
    private let fm = FileManager.default
    private let downloadsDir: URL
    private let indexUrl: URL

    private lazy var bgSession: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        cfg.httpAdditionalHeaders = ["User-Agent": api.userAgent]
        return URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
    }()
    private var activeTasks: [Int64: URLSessionDownloadTask] = [:]
    private var pendingRequests: [Int64: UUID] = [:]
    private var lastProgressUIUpdate: [Int64: (time: CFAbsoluteTime, progress: Double)] = [:]
    private var didRestoreTasks = false
    private var backgroundCompletion: (() -> Void)?

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
        items.filter(\.isActive).count
    }

    init(api: Anime365Client, prefs: Prefs, network: NetworkMonitor) {
        self.api = api
        self.prefs = prefs
        self.network = network

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

        loadIndex()
    }

    func handleBackgroundEvents(completionHandler: @escaping () -> Void) {
        backgroundCompletion = completionHandler
        restoreTasks()
    }

    func restoreTasks() {
        guard !didRestoreTasks else { return }
        didRestoreTasks = true
        let savedTransfers = Set(items.filter { $0.status == .downloading || $0.status == .queued }.map(\.taskDescription))
        bgSession.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                self?.restoreTasks(tasks, savedTransfers: savedTransfers)
            }
        }
    }

    private func restoreTasks(_ tasks: [URLSessionTask], savedTransfers: Set<String>) {
        for case let task as URLSessionDownloadTask in tasks {
            guard let index = index(for: task), items[index].isActive else {
                task.cancel()
                continue
            }
            activeTasks[items[index].episodeId] = task
            if task.state == .suspended && !(prefs.wifiOnlyDownloads && !network.isWifi) {
                task.resume()
            }
        }
        for index in items.indices where (items[index].status == .downloading || items[index].status == .queued) {
            let item = items[index]
            if savedTransfers.contains(item.taskDescription), activeTasks[item.episodeId] == nil {
                items[index].status = .failed
                items[index].errorMessage = "Загрузка была прервана — нажмите «Повторить»"
            }
        }
        saveIndex()
    }

    func onNetworkPolicyChanged() {
        if prefs.wifiOnlyDownloads && !network.isWifi {
            for idx in items.indices where items[idx].status == .downloading {
                let id = items[idx].episodeId
                activeTasks.removeValue(forKey: id)?.cancel()
                items[idx].status = .waitingWifi
                items[idx].errorMessage = nil
            }
            saveIndex()
        } else {
            resumeWifiWaitingIfPossible()
        }
    }

    func resumeWifiWaitingIfPossible() {
        guard network.isConnected, (!prefs.wifiOnlyDownloads || network.isWifi) else { return }
        for idx in items.indices where items[idx].status == .waitingWifi {
            if let urlStr = items[idx].pendingUrlString, let url = URL(string: urlStr) {
                items[idx].status = .downloading
                var req = URLRequest(url: url)
                req.setValue(api.userAgent, forHTTPHeaderField: "User-Agent")
                let task = bgSession.downloadTask(with: req)
                task.taskDescription = items[idx].taskDescription
                activeTasks[items[idx].episodeId] = task
                task.resume()
            } else {
                items[idx].status = .failed
                items[idx].errorMessage = "Нажмите «Повторить» для возобновления"
            }
        }
        saveIndex()
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

    @discardableResult
    func enqueue(
        series: Series,
        episode: Episode,
        studio: Studio?,
        fallbackTranslation: Translation? = nil
    ) async throws -> Bool {
        let id = episode.id
        guard pendingRequests[id] == nil,
              item(forEpisodeId: id)?.isActive != true,
              item(forEpisodeId: id)?.isReady != true else { return false }
        let transferId = UUID()
        pendingRequests[id] = transferId
        defer {
            if pendingRequests[id] == transferId {
                pendingRequests.removeValue(forKey: id)
            }
        }
        restoreTasks()

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

        return try await startDownload(
            seriesId: series.id,
            animeTitle: series.title,
            posterUrl: series.bestPosterUrl,
            episode: episode,
            translation: translation,
            targetQuality: targetQuality,
            transferId: transferId
        )
    }

    func retry(episodeId: Int64) async throws {
        guard let existing = item(forEpisodeId: episodeId), existing.status == .failed else { return }
        let transferId = UUID()
        pendingRequests[episodeId] = transferId
        defer {
            if pendingRequests[episodeId] == transferId {
                pendingRequests.removeValue(forKey: episodeId)
            }
        }
        let fullEp = try await api.episode(id: episodeId)
        let translation = (fullEp.translations ?? []).first { $0.id == existing.translationId }
            ?? TranslationPicker.choose(
                all: fullEp.translations ?? [],
                pick: prefs.pick(animeId: existing.animeId),
                preferred: prefs.preferredKind,
                favourites: prefs.favouriteStudioKeys,
                quality: existing.qualityHeight
            )
        guard let translation else {
            throw ApiError("Перевод для этой серии больше не доступен")
        }
        _ = try await startDownload(
            seriesId: existing.animeId,
            animeTitle: existing.animeTitle,
            posterUrl: existing.posterUrl,
            episode: existing.toEpisode(),
            translation: translation,
            targetQuality: existing.qualityHeight,
            transferId: transferId
        )
    }

    private func startDownload(
        seriesId: Int64,
        animeTitle: String,
        posterUrl: String?,
        episode: Episode,
        translation: Translation,
        targetQuality: Int,
        transferId: UUID
    ) async throws -> Bool {
        let id = episode.id
        let embed = try await api.embed(translationId: translation.id)
        let sortedStreams = embed.stream
            .filter { !$0.urls.isEmpty }
            .sorted { $0.height > $1.height }
        let stream = sortedStreams.first(where: { $0.height <= targetQuality }) ?? sortedStreams.last
        let downloadableUrl = stream?.urls.compactMap { raw -> URL? in
            guard let u = URL(string: raw),
                  ["https", "http"].contains(u.scheme?.lowercased() ?? ""),
                  u.host != nil,
                  u.pathExtension.lowercased() != "m3u8" else { return nil }
            return u
        }.first

        guard let stream, let videoUrl = downloadableUrl else {
            throw ApiError("Эта версия серии доступна только для просмотра онлайн")
        }

        let subtitle = await api.subtitles(for: embed)
        try Task.checkCancellation()
        guard pendingRequests[id] == transferId,
              item(forEpisodeId: id)?.isReady != true,
              item(forEpisodeId: id)?.isActive != true else { return false }

        var subFileName: String?
        if let subtitle {
            let name = "ep_\(id)_\(transferId.uuidString).\(subtitle.fileExtension)"
            if (try? subtitle.data.write(to: downloadsDir.appendingPathComponent(name), options: .atomic)) != nil {
                subFileName = name
            }
        }

        let waitForWifi = prefs.wifiOnlyDownloads && !network.isWifi
        let record = DownloadedEpisode(
            episodeId: id,
            animeId: seriesId,
            animeTitle: animeTitle,
            posterUrl: posterUrl,
            episodeNumber: episode.number,
            episodeLabel: episode.label,
            translationId: translation.id,
            studioName: translation.author,
            translationKind: translation.kind,
            qualityHeight: stream.height > 0 ? stream.height : targetQuality,
            status: waitForWifi ? .waitingWifi : .downloading,
            progress: 0,
            bytesDownloaded: 0,
            totalBytes: 0,
            videoFileName: nil,
            subtitleFileName: subFileName,
            errorMessage: nil,
            addedAt: Date(),
            transferId: transferId,
            pendingUrlString: videoUrl.absoluteString
        )
        do {
            try persistNewTransfer(record)
        } catch {
            removeFile(named: subFileName)
            throw error
        }

        if !waitForWifi {
            var req = URLRequest(url: videoUrl)
            req.setValue(api.userAgent, forHTTPHeaderField: "User-Agent")
            let task = bgSession.downloadTask(with: req)
            task.taskDescription = record.taskDescription
            activeTasks[id] = task
            task.resume()
        }
        return true
    }

    func enqueueBatch(series: Series, episodes: [Episode], studio: Studio?, count: Int = 3) async -> Int {
        var started = 0
        for ep in episodes.prefix(count) {
            if (try? await enqueue(series: series, episode: ep, studio: studio)) == true {
                started += 1
            }
        }
        return started
    }

    func cancelOrDelete(episodeId: Int64) {
        pendingRequests.removeValue(forKey: episodeId)
        activeTasks.removeValue(forKey: episodeId)?.cancel()
        lastProgressUIUpdate.removeValue(forKey: episodeId)
        if let item = item(forEpisodeId: episodeId) {
            removeFile(named: item.videoFileName)
            removeFile(named: item.subtitleFileName)
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

    private func persistNewTransfer(_ record: DownloadedEpisode) throws {
        var updated = items
        let previous = item(forEpisodeId: record.episodeId)
        if let idx = updated.firstIndex(where: { $0.episodeId == record.episodeId }) {
            updated[idx] = record
        } else {
            updated.insert(record, at: 0)
        }
        try JSONEncoder().encode(updated).write(to: indexUrl, options: .atomic)
        items = updated
        removeFile(named: previous?.subtitleFileName)
        removeFile(named: previous?.videoFileName)
    }

    private func removeFile(named name: String?) {
        guard let name else { return }
        try? fm.removeItem(at: downloadsDir.appendingPathComponent(name))
    }

    private func index(for task: URLSessionTask) -> Int? {
        guard let description = task.taskDescription else { return nil }
        return items.firstIndex { $0.taskDescription == description && $0.status != .completed }
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
        MainActor.assumeIsolated {
            guard let index = self.index(for: downloadTask) else { return }
            let id = items[index].episodeId
            activeTasks[id] = downloadTask

            let newProgress = totalBytesExpectedToWrite > 0
                ? min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
                : 0
            let now = CFAbsoluteTimeGetCurrent()
            let prev = lastProgressUIUpdate[id]
            let shouldPublish = items[index].status != .downloading
                || prev == nil
                || (now - (prev?.time ?? 0)) >= 0.25
                || abs(newProgress - (prev?.progress ?? 0)) >= 0.015
            guard shouldPublish else { return }
            lastProgressUIUpdate[id] = (now, newProgress)

            items[index].status = .downloading
            items[index].errorMessage = nil
            items[index].bytesDownloaded = totalBytesWritten
            if totalBytesExpectedToWrite > 0 {
                items[index].totalBytes = totalBytesExpectedToWrite
                items[index].progress = newProgress
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        MainActor.assumeIsolated {
            finishDownload(downloadTask, at: location)
        }
    }

    private func finishDownload(_ task: URLSessionDownloadTask, at location: URL) {
        guard let index = index(for: task) else { return }
        var record = items[index]
        activeTasks.removeValue(forKey: record.episodeId)
        lastProgressUIUpdate.removeValue(forKey: record.episodeId)

        do {
            guard let response = task.response as? HTTPURLResponse else {
                throw ApiError("Сервер не вернул видео")
            }
            guard (200...299).contains(response.statusCode) else {
                throw ApiError("Сервер не отдал видео (HTTP \(response.statusCode))")
            }
            let mime = response.mimeType?.lowercased() ?? ""
            guard !mime.hasPrefix("text/"), !mime.contains("json"), !mime.contains("mpegurl") else {
                throw ApiError("Сервер вернул страницу или плейлист вместо видеофайла")
            }
            let attributes = try fm.attributesOfItem(atPath: location.path)
            guard let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0 else {
                throw ApiError("Сервер вернул пустой файл")
            }
            let fileName = record.transferId.map { "ep_\(record.episodeId)_\($0.uuidString).mp4" }
                ?? "ep_\(record.episodeId).mp4"
            let destination = downloadsDir.appendingPathComponent(fileName)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: location)
            } else {
                try fm.moveItem(at: location, to: destination)
            }
            record.status = .completed
            record.progress = 1
            record.videoFileName = fileName
            record.bytesDownloaded = size
            record.totalBytes = size
            record.errorMessage = nil
            record.pendingUrlString = nil
        } catch {
            record.status = .failed
            record.errorMessage = error.userMessage
        }
        items[index] = record
        saveIndex()
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        MainActor.assumeIsolated {
            guard let index = index(for: task) else { return }
            let id = items[index].episodeId
            activeTasks.removeValue(forKey: id)
            lastProgressUIUpdate.removeValue(forKey: id)
            if (error as NSError).code == NSURLErrorCancelled && items[index].status == .waitingWifi {
                return
            }
            items[index].status = .failed
            items[index].errorMessage = error.userMessage
            saveIndex()
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            let completion = backgroundCompletion
            backgroundCompletion = nil
            completion?()
        }
    }
}
