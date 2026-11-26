import Foundation
import Network

@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isConnected: Bool = true
    @Published private(set) var isExpensive: Bool = false
    @Published private(set) var isWifi: Bool = true
    @Published private(set) var networkKey: String = ""

    var onNetworkRestoredOrChanged: ((_ isWifi: Bool) -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.neifur365.netmonitor", qos: .utility)
    private var debounceTask: Task<Void, Never>?
    private var lastReportedKey: String?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let expensive = path.isExpensive
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            let iface = path.availableInterfaces.map { "\($0.type)-\($0.name)" }.sorted().joined(separator: ",")
            let key = "\(connected)-\(expensive)-\(iface)"

            Task { @MainActor [weak self] in
                self?.applyUpdate(connected: connected, expensive: expensive, wifi: wifi, key: key)
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    private func applyUpdate(connected: Bool, expensive: Bool, wifi: Bool, key: String) {
        isConnected = connected
        isExpensive = expensive
        isWifi = wifi
        networkKey = key

        guard connected else {
            lastReportedKey = key
            debounceTask?.cancel()
            return
        }

        if lastReportedKey == nil {
            lastReportedKey = key
            return
        }
        guard key != lastReportedKey else { return }
        lastReportedKey = key

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self, self.isConnected else { return }
            self.onNetworkRestoredOrChanged?(self.isWifi)
        }
    }
}
