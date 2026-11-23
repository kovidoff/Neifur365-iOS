import SwiftUI

struct ScheduleRoute: Hashable {}

struct ScheduleItem: Identifiable, Hashable {
    let malId: Int64
    let seriesId: Int64?
    let title: String
    let poster: String?
    let nextEpisode: Int
    let totalEpisodes: Int
    let score: Double?
    let year: Int?
    let kind: String?
    let airAt: Date
    let status: ListStatus?

    var id: String { "\(malId)-\(nextEpisode)" }
    var isMine: Bool { status == .watching || status == .planned }

    var route: AnimeRoute {
        if let seriesId {
            return AnimeRoute(id: seriesId, malId: malId, title: title, posterUrl: poster, series: nil)
        }
        return AnimeRoute(id: nil, malId: malId, title: title, posterUrl: poster, series: nil)
    }
}

enum ScheduleBuilder {
    static func parseISO(_ iso: String) -> Date? {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: iso) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso)
    }

    /// Groups ongoing Shikimori titles into the 7-day window [today..today+6] in the given calendar/timezone.
    static func buildWeekly(
        animes: [ShikiAnime],
        byMalId: [Int64: ListedTitle],
        calendar: Calendar = .current,
        today: Date = Date()
    ) -> [(day: Date, items: [ScheduleItem])] {
        let startOfToday = calendar.startOfDay(for: today)
        var days: [Date] = []
        var grouped: [Date: [ScheduleItem]] = [:]
        for offset in 0..<7 {
            if let d = calendar.date(byAdding: .day, value: offset, to: startOfToday) {
                days.append(d)
                grouped[d] = []
            }
        }
        guard let lastDayEnd = calendar.date(byAdding: .day, value: 7, to: startOfToday) else { return [] }

        for a in animes {
            guard let iso = a.nextEpisodeAt,
                  let airDate = parseISO(iso),
                  airDate >= startOfToday && airDate < lastDayEnd,
                  let malId = a.malId else { continue }

            let day = calendar.startOfDay(for: airDate)
            let listed = byMalId[malId]
            let nextEp = max((a.episodesAired ?? 0) + 1, 1)
            let item = ScheduleItem(
                malId: malId,
                seriesId: listed?.entry.seriesId,
                title: listed?.series?.title ?? a.title,
                poster: listed?.series?.bestPosterUrl ?? a.poster?.card,
                nextEpisode: nextEp,
                totalEpisodes: listed?.total ?? (a.episodes ?? 0),
                score: listed?.series?.score ?? a.score,
                year: listed?.series.flatMap { $0.year > 0 ? $0.year : nil } ?? a.year,
                kind: listed?.series?.type ?? a.kind,
                airAt: airDate,
                status: listed?.status
            )
            grouped[day, default: []].append(item)
        }

        return days.map { day in
            let sorted = (grouped[day] ?? []).sorted { a, b in
                if a.airAt != b.airAt { return a.airAt < b.airAt }
                if a.isMine != b.isMine { return a.isMine }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
            return (day, sorted)
        }
    }

    static func formatRelativeAir(airAt: Date, now: Date = Date()) -> (text: String, aired: Bool) {
        let mins = Int(airAt.timeIntervalSince(now) / 60)
        if mins <= -60 {
            return ("вышла \(-mins / 60) ч назад", true)
        }
        if mins < 0 {
            return ("вышла \(max(-mins, 1)) мин назад", true)
        }
        if mins == 0 {
            return ("выходит сейчас", true)
        }
        if mins < 60 {
            return ("через \(mins) мин", false)
        }
        if mins < 24 * 60 {
            let h = mins / 60
            let m = mins % 60
            return (m > 0 ? "через \(h) ч \(m) мин" : "через \(h) ч", false)
        }
        let d = (mins + 720) / (24 * 60)
        return ("через \(d) \(pluralDays(d))", false)
    }

    static func shortWeekday(for date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.weekday, from: date) {
        case 2: return "Пн"
        case 3: return "Вт"
        case 4: return "Ср"
        case 5: return "Чт"
        case 6: return "Пт"
        case 7: return "Сб"
        default: return "Вс"
        }
    }

    private static func pluralDays(_ n: Int) -> String {
        let m10 = n % 10
        let m100 = n % 100
        if m10 == 1 && m100 != 11 { return "день" }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return "дня" }
        return "дней"
    }
}

@MainActor
final class ScheduleViewModel: ObservableObject {
    @Published var days: [(day: Date, items: [ScheduleItem])] = []
    @Published var loading = false
    @Published var errorMessage: String?

    func load(shikimori: ShikimoriClient, lists: ListsStore, force: Bool = false) async {
        if !force && !days.isEmpty { return }
        loading = true
        errorMessage = nil

        var byMalId: [Int64: ListedTitle] = [:]
        var extraMalIds: [Int64] = []
        for item in lists.titles.values {
            if let mal = item.series?.myAnimeListId, mal > 0 {
                byMalId[mal] = item
                if item.airing && (item.status == .watching || item.status == .planned) {
                    extraMalIds.append(mal)
                }
            }
        }

        do {
            let ongoing = try await shikimori.ongoingSchedule(extraMalIds: extraMalIds)
            days = ScheduleBuilder.buildWeekly(animes: ongoing, byMalId: byMalId)
        } catch {
            errorMessage = error.userMessage
        }
        loading = false
    }
}

struct ScheduleScreen: View {
    @EnvironmentObject private var app: AppContainer
    @EnvironmentObject private var lists: ListsStore

    @StateObject private var vm = ScheduleViewModel()
    @State private var selectedDayIndex = 0
    @State private var onlyMine = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayHeaderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EEEE, d MMMM"
        return f
    }()

    private var currentItems: [ScheduleItem] {
        guard vm.days.indices.contains(selectedDayIndex) else { return [] }
        let items = vm.days[selectedDayIndex].items
        return onlyMine ? items.filter(\.isMine) : items
    }

    var body: some View {
        VStack(spacing: 0) {
            if !vm.days.isEmpty {
                dayStrip
            }

            if vm.loading && vm.days.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Загрузка расписания…")
                        .font(.subheadline)
                        .foregroundColor(Nf.textDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = vm.errorMessage, vm.days.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.system(size: 38))
                        .foregroundColor(Nf.textMute)
                    Text("Не удалось загрузить расписание")
                        .font(.headline)
                        .foregroundColor(Nf.text)
                    Text(err)
                        .font(.subheadline)
                        .foregroundColor(Nf.textDim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                    Button("Повторить") {
                        Task { await vm.load(shikimori: app.shikimori, lists: lists, force: true) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if currentItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "calendar")
                        .font(.system(size: 38))
                        .foregroundColor(Nf.textMute)
                    Text(onlyMine ? "В этот день ваших онгоингов нет" : "Нет запланированных серий")
                        .font(.headline)
                        .foregroundColor(Nf.text)
                    if onlyMine {
                        Button("Показать все онгоинги") {
                            onlyMine = false
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(currentItems) { item in
                            NavigationLink(value: item.route) {
                                ScheduleRowView(item: item, timeText: Self.timeFormatter.string(from: item.airAt))
                            }
                            .listRowBackground(Nf.surface)
                            .listRowSeparatorTint(Nf.line)
                        }
                    } header: {
                        if vm.days.indices.contains(selectedDayIndex) {
                            Text(dayHeading(for: selectedDayIndex, date: vm.days[selectedDayIndex].day))
                                .font(.footnote.weight(.semibold))
                                .foregroundColor(Nf.textDim)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .refreshable {
                    await vm.load(shikimori: app.shikimori, lists: lists, force: true)
                }
            }
        }
        .background(Nf.ink.ignoresSafeArea())
        .navigationTitle("Расписание")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    withAnimation { onlyMine.toggle() }
                } label: {
                    Label(onlyMine ? "Мои" : "Все", systemImage: onlyMine ? "bookmark.fill" : "bookmark")
                }
            }
        }
        .task {
            await vm.load(shikimori: app.shikimori, lists: lists)
        }
    }

    private var dayStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(vm.days.enumerated()), id: \.offset) { idx, entry in
                    let active = selectedDayIndex == idx
                    let count = onlyMine ? entry.items.filter(\.isMine).count : entry.items.count
                    let dayNum = Calendar.current.component(.day, from: entry.day)
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            selectedDayIndex = idx
                        }
                    } label: {
                        VStack(spacing: 3) {
                            Text(idx == 0 ? "Сег" : ScheduleBuilder.shortWeekday(for: entry.day))
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(active ? Nf.ink.opacity(0.8) : Nf.textMute)
                            Text("\(dayNum)")
                                .font(.headline.weight(.bold))
                                .foregroundColor(active ? Nf.ink : Nf.text)
                                .monospacedDigit()
                            Circle()
                                .fill(count > 0 ? (active ? Nf.ink : Nf.mint) : Color.clear)
                                .frame(width: 4, height: 4)
                        }
                        .frame(width: 50, height: 60)
                        .background(active ? Nf.violet : Nf.surfaceHi, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(NfPressableStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func dayHeading(for index: Int, date: Date) -> String {
        let base = Self.dayHeaderFormatter.string(from: date).capitalized
        if index == 0 { return "Сегодня · \(base)" }
        if index == 1 { return "Завтра · \(base)" }
        return base
    }
}

private struct ScheduleRowView: View {
    let item: ScheduleItem
    let timeText: String

    var body: some View {
        let rel = ScheduleBuilder.formatRelativeAir(airAt: item.airAt)
        HStack(spacing: 12) {
            PosterView(urlString: item.poster, cornerRadius: 10, alignment: .top)
                .frame(width: 52, height: 76)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(timeText)
                        .font(.caption.weight(.bold))
                        .foregroundColor(rel.aired ? Nf.mint : Nf.violet)
                        .monospacedDigit()

                    Text("· \(rel.text)")
                        .font(.caption)
                        .foregroundColor(rel.aired ? Nf.mint : Nf.textDim)

                    Spacer(minLength: 4)

                    if let status = item.status {
                        Image(systemName: status.systemImage)
                            .font(.system(size: 13))
                            .foregroundColor(status.tintColor)
                    }
                }

                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Nf.text)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    let totalSuffix = item.totalEpisodes > 0 ? " из \(item.totalEpisodes)" : ""
                    Text("Серия \(item.nextEpisode)\(totalSuffix)")
                        .font(.caption)
                        .foregroundColor(Nf.textDim)
                    if let score = item.score, score > 0 {
                        Text("· ★ \(String(format: "%.1f", score))")
                            .font(.caption)
                            .foregroundColor(Nf.amber)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
