import Foundation

struct CachedListsSnapshot: Codable {
    let savedAt: Date
    let titles: [ListedTitle]
}

struct CachedScheduleSnapshot: Codable {
    let savedAt: Date
    let animes: [ShikiAnime]
}

/// Atomic local JSON snapshots for instant cold-start and offline browsing of Lists and Schedule.
final class OfflineCache {
    private let fm = FileManager.default
    private let cacheDir: URL
    private let queue = DispatchQueue(label: "app.neifur365.offlinecache", qos: .utility)

    init() {
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        self.cacheDir = appSupport.appendingPathComponent("NeifurCache", isDirectory: true)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = cacheDir
        try? mutable.setResourceValues(values)
    }

    func readLists(userId: Int64) -> CachedListsSnapshot? {
        let url = cacheDir.appendingPathComponent("lists_\(userId).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachedListsSnapshot.self, from: data)
    }

    func writeLists(userId: Int64, titles: [ListedTitle]) {
        let url = cacheDir.appendingPathComponent("lists_\(userId).json")
        let snapshot = CachedListsSnapshot(savedAt: Date(), titles: titles)
        queue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func readSchedule() -> CachedScheduleSnapshot? {
        let url = cacheDir.appendingPathComponent("schedule.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachedScheduleSnapshot.self, from: data)
    }

    func writeSchedule(animes: [ShikiAnime]) {
        let url = cacheDir.appendingPathComponent("schedule.json")
        let snapshot = CachedScheduleSnapshot(savedAt: Date(), animes: animes)
        queue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
