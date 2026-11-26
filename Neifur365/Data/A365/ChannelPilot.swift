import Combine
import Foundation

struct ChannelState: Equatable {
    var setup: ChannelSetup?
    var speeds: [Int: ChannelSpeed] = [:]
    var measuring: Set<Int> = []
    var switchingId: Int?
    var note: String?
    var pickedByApp: Bool = false
    var loadError: String?

    var isTesting: Bool { !measuring.isEmpty }

    var fastest: VideoChannel? {
        setup?.channels
            .filter { speeds[$0.id]?.works == true }
            .max { (speeds[$0.id]?.bytesPerSec ?? 0) < (speeds[$1.id]?.bytesPerSec ?? 0) }
    }
}

/// Chooses whether to switch channels: always leaves a broken channel, or moves on failure to a clearly faster one.
func pickBetterChannel(
    currentId: Int?,
    currentSpeed: ChannelSpeed?,
    best: VideoChannel?,
    bestSpeed: ChannelSpeed?,
    preferSwitch: BooleanCompat
) -> VideoChannel? {
    guard let best, bestSpeed?.works == true else { return nil }
    if best.id == currentId { return nil }
    if currentSpeed?.works != true { return best }
    if preferSwitch, let cur = currentSpeed, let b = bestSpeed, b.bytesPerSec > cur.bytesPerSec * 1.25 {
        return best
    }
    return nil
}

typealias BooleanCompat = Bool

@MainActor
final class ChannelPilot: ObservableObject {
    @Published private(set) var state = ChannelState()

    private let api: Anime365Client
    private let prefs: Prefs
    private let account: AccountStore
    private let network: NetworkMonitor

    private var measureTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private static let backgroundCheckInterval: TimeInterval = 6 * 3600

    init(api: Anime365Client, prefs: Prefs, account: AccountStore, network: NetworkMonitor) {
        self.api = api
        self.prefs = prefs
        self.account = account
        self.network = network

        account.$state
            .removeDuplicates()
            .sink { [weak self] st in
                guard let self else { return }
                switch st {
                case .signedIn:
                    self.state = ChannelState()
                    self.checkInBackground()
                case .signedOut:
                    self.measureTask?.cancel()
                    self.state = ChannelState()
                case .unknown:
                    break
                }
            }
            .store(in: &cancellables)
    }

    @discardableResult
    func load() async -> ChannelSetup? {
        do {
            let setup = try await api.channels()
            state.setup = setup
            state.loadError = nil
            return setup
        } catch {
            if !Task.isCancelled {
                state.loadError = error.userMessage
            }
            return nil
        }
    }

    private func checkInBackground() {
        Task {
            if !prefs.channelAuto {
                _ = await load()
                return
            }
            if let last = prefs.channelCheckedAt, Date().timeIntervalSince(last) < Self.backgroundCheckInterval {
                _ = await load()
                return
            }
            if network.isExpensive {
                _ = await load()
                return
            }
            if await ensureWorking(preferSwitch: false) != nil || state.setup != nil {
                prefs.channelCheckedAt = Date()
            }
        }
    }

    func onNetworkChanged() {
        guard account.isSignedIn, prefs.channelAuto, !network.isExpensive else { return }
        Task {
            _ = await ensureWorking(preferSwitch: false)
            if state.setup != nil {
                prefs.channelCheckedAt = Date()
            }
        }
    }

    /// Probes current / all channels and switches if current is broken (or noticeably slower on stream failure).
    func ensureWorking(preferSwitch: Bool) async -> (VideoChannel?, VideoChannel)? {
        guard let setup = await load() else { return nil }
        let current = setup.currentChannel

        if !preferSwitch, let current {
            let first = await sample(current)
            if first.works { return nil }
            let second = await sample(current)
            if second.works { return nil }

            let others = setup.channels.filter { $0.id != current.id }
            await sampleAll(others)
            guard prefs.channelAuto, let best = state.fastest, best.id != current.id else { return nil }
            let ok = await switchTo(best, byApp: true, note: "«\(current.label)» не отвечает, включён «\(best.label)»")
            if ok {
                prefs.channelCheckedAt = Date()
                return (current, best)
            }
            return nil
        }

        await sampleAll(setup.channels)
        let curSpeed = current.flatMap { state.speeds[$0.id] }
        let best = state.fastest
        let bestSpeed = best.flatMap { state.speeds[$0.id] }
        guard let target = pickBetterChannel(
            currentId: setup.current,
            currentSpeed: curSpeed,
            best: best,
            bestSpeed: bestSpeed,
            preferSwitch: preferSwitch
        ) else { return nil }

        let ok = await switchTo(target, byApp: true, note: "Переключено на более быстрый канал «\(target.label)»")
        if ok {
            prefs.channelCheckedAt = Date()
            return (current, target)
        }
        return nil
    }

    func measureAll() {
        measureTask?.cancel()
        measureTask = Task {
            let setup: ChannelSetup?
            if let existing = state.setup {
                setup = existing
            } else {
                setup = await load()
            }
            guard let setup, !Task.isCancelled else { return }
            await sampleAll(setup.channels)
        }
    }

    func cancelMeasure() {
        measureTask?.cancel()
        state.measuring = []
    }

    func selectChannel(_ channel: VideoChannel) {
        Task {
            _ = await switchTo(channel, byApp: false, note: nil)
        }
    }

    private func sample(_ channel: VideoChannel) async -> ChannelSpeed {
        state.measuring.insert(channel.id)
        let speed = await api.measure(channel: channel)
        state.measuring.remove(channel.id)
        state.speeds[channel.id] = speed
        return speed
    }

    private func sampleAll(_ channels: [VideoChannel]) async {
        for ch in channels { state.measuring.insert(ch.id) }
        await withTaskGroup(of: (Int, ChannelSpeed).self) { group in
            for ch in channels {
                group.addTask {
                    let s = await self.api.measure(channel: ch)
                    return (ch.id, s)
                }
            }
            for await (id, speed) in group {
                state.measuring.remove(id)
                if !Task.isCancelled {
                    state.speeds[id] = speed
                }
            }
        }
        state.measuring = []
    }

    @discardableResult
    private func switchTo(_ channel: VideoChannel, byApp: Bool, note: String?) async -> Bool {
        state.switchingId = channel.id
        defer { state.switchingId = nil }
        do {
            try await api.setChannel(id: channel.id)
            if let cur = state.setup {
                state.setup = ChannelSetup(channels: cur.channels, current: channel.id, fromRussia: cur.fromRussia)
            }
            state.pickedByApp = byApp
            state.note = note
            state.loadError = nil
            return true
        } catch {
            state.loadError = error.userMessage
            return false
        }
    }
}
