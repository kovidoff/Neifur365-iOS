import Foundation

struct VideoChannel: Hashable, Identifiable {
    let id: Int
    let name: String
    let desc: String
    let testUrl: String
    let fallbackUrl: String?

    var label: String {
        var s = desc.trimmingCharacters(in: CharacterSet(charactersIn: "() "))
        if s.hasPrefix("CDN ") {
            s = String(s.dropFirst(4))
        }
        if let first = s.first {
            s = first.uppercased() + s.dropFirst()
        }
        return s.isEmpty ? name : s
    }
}

struct ChannelSetup: Hashable {
    let channels: [VideoChannel]
    let current: Int?
    let fromRussia: Bool?

    var currentChannel: VideoChannel? {
        channels.first { $0.id == current }
    }
}

struct ChannelSpeed: Hashable {
    static let worksThreshold: Double = 300.0 * 1024

    let bytesPerSec: Double

    var works: Bool { bytesPerSec >= Self.worksThreshold }

    var label: String {
        if !works { return "не работает" }
        if bytesPerSec >= 1024 * 1024 {
            return String(format: "%.1f МБ/с", bytesPerSec / 1024 / 1024)
        }
        return "\(Int(bytesPerSec / 1024)) КБ/с"
    }
}

enum ChannelPage {
    static func parse(_ html: String) -> ChannelSetup? {
        let marker = "var DIAG = "
        guard let startRange = html.range(of: marker) else { return nil }
        guard let endRange = html.range(of: "};", range: startRange.upperBound..<html.endIndex) else { return nil }
        let jsonSlice = String(html[startRange.upperBound...endRange.lowerBound])
        guard let data = jsonSlice.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let targets = root["targets"] as? [[String: Any]] else {
            return nil
        }

        let channels: [VideoChannel] = targets.compactMap { obj in
            if (obj["reference"] as? Bool) == true { return nil }
            guard let id = obj["id"] as? Int,
                  let url = obj["url"] as? String else { return nil }
            return VideoChannel(
                id: id,
                name: obj["name"] as? String ?? "",
                desc: obj["desc"] as? String ?? "",
                testUrl: url,
                fallbackUrl: obj["fallbackUrl"] as? String
            )
        }
        guard !channels.isEmpty else { return nil }
        return ChannelSetup(
            channels: channels,
            current: root["currentChannel"] as? Int,
            fromRussia: root["isRu"] as? Bool
        )
    }
}
