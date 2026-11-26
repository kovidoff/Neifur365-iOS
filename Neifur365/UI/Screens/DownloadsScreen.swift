import SwiftUI

struct DownloadsScreen: View {
    @EnvironmentObject private var app: AppContainer
    @EnvironmentObject private var lists: ListsStore
    @EnvironmentObject private var downloads: DownloadManager

    @State private var playerRequest: PlayerLaunchRequest?
    @State private var showClearConfirm = false

    private var activeOrFailed: [DownloadedEpisode] {
        downloads.items
            .filter { !$0.isReady }
            .sorted { $0.addedAt > $1.addedAt }
    }

    private var completedGroups: [DownloadedAnime] {
        downloads.byAnime.compactMap { group in
            let ready = group.episodes.filter(\.isReady)
            guard !ready.isEmpty else { return nil }
            return DownloadedAnime(
                animeId: group.animeId,
                title: group.title,
                posterUrl: group.posterUrl,
                episodes: ready
            )
        }
    }

    var body: some View {
        Group {
            if downloads.items.isEmpty {
                emptyState
            } else {
                List {
                    Section {
                        HStack {
                            Label("Занято на устройстве", systemImage: "internaldrive")
                                .font(.subheadline)
                                .foregroundColor(Nf.text)
                            Spacer()
                            Text(formatBytes(downloads.totalStorageBytes))
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(Nf.mint)
                                .monospacedDigit()
                        }
                        .listRowBackground(Nf.surface)
                    }

                    if !activeOrFailed.isEmpty {
                        Section("Очередь и активные") {
                            ForEach(activeOrFailed) { ep in
                                ActiveOrFailedDownloadRow(
                                    item: ep,
                                    onRetry: {
                                        Task { try? await downloads.retry(episodeId: ep.episodeId) }
                                    },
                                    onCancel: {
                                        downloads.cancelOrDelete(episodeId: ep.episodeId)
                                    }
                                )
                                .listRowBackground(Nf.surface)
                                .listRowSeparatorTint(Nf.line)
                            }
                        }
                    }

                    ForEach(completedGroups) { group in
                        Section {
                            ForEach(group.episodes) { ep in
                                DownloadedEpisodeRow(item: ep) {
                                    playOffline(group: group, startEpisode: ep)
                                }
                                .listRowBackground(Nf.surface)
                                .listRowSeparatorTint(Nf.line)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        downloads.cancelOrDelete(episodeId: ep.episodeId)
                                    } label: {
                                        Label("Удалить", systemImage: "trash")
                                    }
                                }
                            }
                        } header: {
                            NavigationLink(value: AnimeRoute(id: group.animeId, title: group.title, posterUrl: group.posterUrl)) {
                                HStack(spacing: 10) {
                                    PosterView(urlString: group.posterUrl, cornerRadius: 6, alignment: .top)
                                        .frame(width: 24, height: 34)
                                    Text(group.title)
                                        .font(.footnote.weight(.bold))
                                        .foregroundColor(Nf.text)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(formatBytes(group.totalBytes))
                                        .font(.caption2)
                                        .foregroundColor(Nf.textMute)
                                        .monospacedDigit()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundColor(Nf.textMute)
                                }
                                .textCase(nil)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Nf.ink.ignoresSafeArea())
        .navigationTitle("Загрузки")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !downloads.items.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Удалить все загрузки")
                }
            }
        }
        .confirmationDialog("Удалить все скачанные серии?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Удалить всё", role: .destructive) {
                downloads.clearAll()
            }
            Button("Отмена", role: .cancel) {}
        }
        .fullScreenCover(item: $playerRequest) { req in
            PlayerScreen(request: req, app: app)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 50))
                .foregroundColor(Nf.violet)
            Text("Офлайн-загрузок пока нет")
                .font(.title3.weight(.bold))
                .foregroundColor(Nf.text)
            Text("Откройте любое аниме и скачайте серии по одной или пакетом +3 — видео и .ass-субтитры будут доступны без интернета.")
                .font(.subheadline)
                .foregroundColor(Nf.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func playOffline(group: DownloadedAnime, startEpisode: DownloadedEpisode) {
        let ready = group.episodes.filter(\.isReady)
        guard !ready.isEmpty else { return }
        let episodes = ready.map { $0.toEpisode() }
        let idx = ready.firstIndex(where: { $0.episodeId == startEpisode.episodeId }) ?? 0
        let malId = lists.get(group.animeId)?.series?.myAnimeListId ?? 0
        playerRequest = PlayerLaunchRequest(
            seriesId: group.animeId,
            malId: malId,
            animeTitle: group.title,
            posterUrl: group.posterUrl,
            episodes: episodes,
            startIndex: idx,
            initialPickKey: nil
        )
    }
}

private struct ActiveOrFailedDownloadRow: View {
    let item: DownloadedEpisode
    let onRetry: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            PosterView(urlString: item.posterUrl, cornerRadius: 8, alignment: .top)
                .frame(width: 38, height: 54)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(item.animeTitle) · \(item.episodeLabel)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Nf.text)
                    .lineLimit(1)

                switch item.status {
                case .downloading:
                    let pct = Int(round(item.progress * 100))
                    let sizeInfo = item.totalBytes > 0
                        ? "\(formatBytes(item.bytesDownloaded)) / \(formatBytes(item.totalBytes))"
                        : formatBytes(item.bytesDownloaded)
                    Text("Загрузка \(pct)% · \(sizeInfo)")
                        .font(.caption)
                        .foregroundColor(Nf.violet)
                        .monospacedDigit()
                    ProgressView(value: item.progress)
                        .tint(Nf.violet)
                case .queued:
                    Text("В очереди на скачивание…")
                        .font(.caption)
                        .foregroundColor(Nf.textDim)
                case .waitingWifi:
                    Text("Ожидает Wi‑Fi")
                        .font(.caption)
                        .foregroundColor(Nf.amber)
                case .failed:
                    Text(item.errorMessage ?? "Ошибка загрузки")
                        .font(.caption)
                        .foregroundColor(Nf.red)
                        .lineLimit(2)
                case .completed:
                    EmptyView()
                }
            }

            Spacer(minLength: 4)

            if item.status == .failed || item.status == .waitingWifi {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(Nf.violet)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Повторить")
            }

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(Nf.textMute)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Отменить")
        }
        .padding(.vertical, 4)
    }
}

private struct DownloadedEpisodeRow: View {
    let item: DownloadedEpisode
    let onPlay: () -> Void

    var body: some View {
        Button {
            if item.isReady { onPlay() }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Nf.mint.opacity(0.16))
                        .frame(width: 34, height: 34)
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Nf.mint)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.episodeLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Nf.text)

                    let subMark = item.subtitleFileName != nil ? " · субтитры" : ""
                    Text(verbatim: "\(item.studioName) · \(item.qualityHeight)p\(subMark) · \(formatBytes(item.totalBytes))")
                        .font(.caption)
                        .foregroundColor(Nf.textDim)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
