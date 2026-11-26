import Charts
import SwiftUI

struct WatchStats: Equatable {
    struct GenreStat: Identifiable, Equatable {
        let name: String
        let count: Int
        var id: String { name }
    }

    struct ScoreBin: Identifiable, Equatable {
        let score: Int
        let count: Int
        var id: Int { score }
    }

    let totalTitles: Int
    let episodesWatched: Int
    let totalMinutes: Int
    let meanScore: Double?
    let ratedCount: Int
    let byStatus: [ListStatus: Int]
    let topGenres: [GenreStat]
    let scoreHistogram: [ScoreBin]
}

func computeWatchStats(items: [ListedTitle]) -> WatchStats {
    var byStatus: [ListStatus: Int] = [:]
    var episodes = 0
    var minutes = 0
    var ratedSum = 0
    var ratedCount = 0
    var scoreBuckets: [Int: Int] = [:]
    var activeGenres: [String: Int] = [:]
    var fallbackGenres: [String: Int] = [:]

    for item in items {
        if let st = item.status {
            byStatus[st, default: 0] += 1
        }
        let watched = max(item.entry.watched, 0)
        episodes += watched
        let isMovie = item.series?.isMovie == true
        minutes += watched * (isMovie ? 95 : 24)

        if let score = item.entry.score, (1...10).contains(score) {
            ratedSum += score
            ratedCount += 1
            scoreBuckets[score, default: 0] += 1
        }

        if let genres = item.series?.genres, !genres.isEmpty, item.status != .planned {
            for g in genres where !g.title.isEmpty {
                fallbackGenres[g.title, default: 0] += 1
                if item.status != .dropped {
                    activeGenres[g.title, default: 0] += 1
                }
            }
        }
    }

    let sourceGenres = activeGenres.isEmpty ? fallbackGenres : activeGenres
    let topGenres = sourceGenres
        .map { WatchStats.GenreStat(name: $0.key, count: $0.value) }
        .sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.name < rhs.name
        }
        .prefix(5)

    let scoreHistogram = (1...10).map { s in
        WatchStats.ScoreBin(score: s, count: scoreBuckets[s, default: 0])
    }

    return WatchStats(
        totalTitles: items.count,
        episodesWatched: episodes,
        totalMinutes: minutes,
        meanScore: ratedCount > 0 ? Double(ratedSum) / Double(ratedCount) : nil,
        ratedCount: ratedCount,
        byStatus: byStatus,
        topGenres: Array(topGenres),
        scoreHistogram: scoreHistogram
    )
}

func formatWatchTime(minutes: Int) -> String {
    guard minutes > 0 else { return "0 ч" }
    let hours = minutes / 60
    let days = hours / 24
    let remHours = hours % 24
    if days > 0 {
        return "\(days) д \(remHours) ч"
    }
    if hours > 0 {
        let mins = minutes % 60
        return mins > 0 ? "\(hours) ч \(mins) мин" : "\(hours) ч"
    }
    return "\(minutes) мин"
}

struct WatchStatsSheet: View {
    @EnvironmentObject private var lists: ListsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let stats = computeWatchStats(items: Array(lists.titles.values))
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if stats.totalTitles == 0 {
                        emptyState
                    } else {
                        summaryGrid(stats)
                        statusSection(stats)
                        if stats.ratedCount > 0 {
                            scoreSection(stats)
                        }
                        if !stats.topGenres.isEmpty {
                            genresSection(stats)
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .background(Nf.ink.ignoresSafeArea())
            .navigationTitle("Статистика")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 36))
                .foregroundColor(Nf.textMute)
            Text("Пока нет данных")
                .font(.headline)
                .foregroundColor(Nf.text)
            Text("Добавляйте аниме в списки и отмечайте просмотренные серии — здесь появится ваша статистика.")
                .font(.subheadline)
                .foregroundColor(Nf.textDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func summaryGrid(_ stats: WatchStats) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            metricCard(
                title: "Время просмотра",
                value: formatWatchTime(minutes: stats.totalMinutes),
                icon: "clock.fill",
                tint: Nf.violet
            )
            metricCard(
                title: "Серий просмотрено",
                value: "\(stats.episodesWatched)",
                icon: "play.rectangle.fill",
                tint: Nf.mint
            )
            metricCard(
                title: "Тайтлов в списках",
                value: "\(stats.totalTitles)",
                icon: "bookmark.fill",
                tint: Nf.pink
            )
            metricCard(
                title: "Средняя оценка",
                value: stats.meanScore.map { String(format: "%.1f ★", $0) } ?? "—",
                icon: "star.fill",
                tint: Nf.amber
            )
        }
    }

    private func metricCard(title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(tint)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundColor(Nf.text)
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundColor(Nf.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Nf.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Nf.line, lineWidth: 0.7)
        )
    }

    private func statusSection(_ stats: WatchStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("По спискам")
                .font(NfType.section)
                .foregroundColor(Nf.text)

            VStack(spacing: 10) {
                ForEach(ListStatus.allCases) { status in
                    let count = stats.byStatus[status, default: 0]
                    let ratio = stats.totalTitles > 0 ? Double(count) / Double(stats.totalTitles) : 0
                    VStack(spacing: 6) {
                        HStack {
                            Label(status.title, systemImage: status.systemImage)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(Nf.text)
                            Spacer()
                            Text("\(count)")
                                .font(.subheadline.weight(.bold))
                                .foregroundColor(status.tintColor)
                                .monospacedDigit()
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Nf.surfaceHi)
                                Capsule()
                                    .fill(status.tintColor)
                                    .frame(width: max(ratio > 0 ? 6 : 0, geo.size.width * ratio))
                            }
                        }
                        .frame(height: 6)
                    }
                }
            }
            .padding(14)
            .background(Nf.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Nf.line, lineWidth: 0.7)
            )
        }
    }

    private func scoreSection(_ stats: WatchStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Оценки")
                    .font(NfType.section)
                    .foregroundColor(Nf.text)
                Spacer()
                Text("Оценено: \(stats.ratedCount)")
                    .font(.caption)
                    .foregroundColor(Nf.textMute)
            }

            Chart(stats.scoreHistogram) { bin in
                BarMark(
                    x: .value("Оценка", String(bin.score)),
                    y: .value("Количество", bin.count)
                )
                .foregroundStyle(bin.score >= 8 ? Nf.mint : (bin.score >= 5 ? Nf.violet : Nf.amber))
                .cornerRadius(4)
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .frame(height: 150)
            .padding(14)
            .background(Nf.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Nf.line, lineWidth: 0.7)
            )
        }
    }

    private func genresSection(_ stats: WatchStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Любимые жанры")
                .font(NfType.section)
                .foregroundColor(Nf.text)

            VStack(spacing: 8) {
                let topCount = max(stats.topGenres.first?.count ?? 1, 1)
                ForEach(stats.topGenres) { item in
                    let ratio = Double(item.count) / Double(topCount)
                    HStack(spacing: 10) {
                        Text(item.name)
                            .font(.subheadline)
                            .foregroundColor(Nf.text)
                            .frame(width: 120, alignment: .leading)
                            .lineLimit(1)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Nf.surfaceHi)
                                Capsule()
                                    .fill(Nf.violet)
                                    .frame(width: max(8, geo.size.width * ratio))
                            }
                        }
                        .frame(height: 7)
                        Text("\(item.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Nf.textDim)
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                    }
                }
            }
            .padding(14)
            .background(Nf.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Nf.line, lineWidth: 0.7)
            )
        }
    }
}
