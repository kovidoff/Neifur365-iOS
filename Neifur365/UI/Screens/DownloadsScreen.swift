import SwiftUI

struct DownloadsScreen: View {
    @EnvironmentObject private var app: AppContainer
    @EnvironmentObject private var downloads: DownloadManager

    @State private var playerRequest: PlayerLaunchRequest?
    @State private var showClearConfirm = false

    private var groups: [DownloadedAnime] { downloads.byAnime }

    var body: some View {
        NavigationStack {
            Group {
                if groups.isEmpty {
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

                        ForEach(groups) { group in
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
                                }
                                .textCase(nil)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Nf.ink.ignoresSafeArea())
            .navigationTitle("Загрузки")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if !groups.isEmpty {
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
        playerRequest = PlayerLaunchRequest(
            seriesId: group.animeId,
            animeTitle: group.title,
            posterUrl: group.posterUrl,
            episodes: episodes,
            startIndex: idx,
            initialPickKey: nil
        )
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
                        .fill(statusColor.opacity(0.16))
                        .frame(width: 34, height: 34)
                    if item.isReady {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Nf.mint)
                    } else if item.status == .downloading || item.status == .queued {
                        ProgressView(value: item.progress)
                            .progressViewStyle(.circular)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(Nf.amber)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.episodeLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Nf.text)

                    if item.status == .downloading {
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
                    } else if item.status == .failed {
                        Text(item.errorMessage ?? "Ошибка загрузки")
                            .font(.caption)
                            .foregroundColor(Nf.red)
                            .lineLimit(1)
                    } else {
                        let subMark = item.subtitleFileName != nil ? " · субтитры" : ""
                        Text("\(item.studioName) · \(item.qualityHeight)p\(subMark) · \(formatBytes(item.totalBytes))")
                            .font(.caption)
                            .foregroundColor(Nf.textDim)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        switch item.status {
        case .completed: return Nf.mint
        case .downloading, .queued: return Nf.violet
        case .failed: return Nf.amber
        }
    }
}
