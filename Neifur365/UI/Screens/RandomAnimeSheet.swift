import SwiftUI

struct RandomAnimeSheet: View {
    @EnvironmentObject private var app: AppContainer
    @EnvironmentObject private var lists: ListsStore
    @Environment(\.dismiss) private var dismiss

    let initialGenre: A365Genre?
    let onOpenAnime: (Series) -> Void

    @State private var selectedGenre: A365Genre?
    @State private var excludeWatched = true
    @State private var candidate: Series?
    @State private var loading = false
    @State private var errorMessage: String?

    init(initialGenre: A365Genre? = nil, onOpenAnime: @escaping (Series) -> Void) {
        self.initialGenre = initialGenre
        self._selectedGenre = State(initialValue: initialGenre)
        self.onOpenAnime = onOpenAnime
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let candidate {
                    candidateCard(candidate)
                } else if loading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Крутим рулетку…")
                            .font(.subheadline)
                            .foregroundColor(Nf.textDim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "die.face.5")
                            .font(.system(size: 40))
                            .foregroundColor(Nf.amber)
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundColor(Nf.textDim)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                VStack(spacing: 10) {
                    Menu {
                        Button("Любой жанр") { selectedGenre = nil }
                        ForEach(A365Genre.all) { g in
                            Button(g.title) { selectedGenre = g }
                        }
                    } label: {
                        HStack {
                            Label("Жанр", systemImage: "tag")
                            Spacer()
                            Text(selectedGenre?.title ?? "Любой")
                                .foregroundColor(Nf.textDim)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundColor(Nf.textMute)
                        }
                        .padding(12)
                        .background(Nf.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .foregroundColor(Nf.text)

                    Toggle("Скрывать тайтлы из моих списков", isOn: $excludeWatched)
                        .font(.subheadline)
                        .foregroundColor(Nf.text)
                        .padding(.horizontal, 4)

                    HStack(spacing: 10) {
                        Button {
                            Task { await roll() }
                        } label: {
                            Label("Ещё вариант", systemImage: "dice.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                        .disabled(loading)

                        if let candidate {
                            Button {
                                dismiss()
                                onOpenAnime(candidate)
                            } label: {
                                Label("Открыть", systemImage: "play.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Nf.violet)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .background(Nf.ink.ignoresSafeArea())
            .navigationTitle("Случайное аниме")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .task {
                if candidate == nil {
                    await roll()
                }
            }
        }
        .presentationDetents([.large])
    }

    private func candidateCard(_ series: Series) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                PosterView(urlString: series.bestPosterUrl, cornerRadius: 16, alignment: .top, contentMode: .fill)
                    .frame(width: 156, height: 234)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 0.7)
                    )
                    .shadow(color: .black.opacity(0.45), radius: 16, y: 8)

                Text(series.title)
                    .font(.title3.weight(.bold))
                    .foregroundColor(Nf.text)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)

                HStack(spacing: 10) {
                    if let score = series.score {
                        Label(String(format: "%.1f", score), systemImage: "star.fill")
                            .foregroundColor(Nf.amber)
                    }
                    if series.year > 0 {
                        Text(String(series.year))
                            .foregroundColor(Nf.textDim)
                    }
                    if let typeTitle = series.typeTitle, !typeTitle.isEmpty {
                        Text(typeTitle)
                            .foregroundColor(Nf.textDim)
                    }
                }
                .font(.caption.weight(.semibold))

                if let genres = series.genres, !genres.isEmpty {
                    Text(genres.prefix(4).map(\.title).joined(separator: " · "))
                        .font(.caption)
                        .foregroundColor(Nf.violet)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }

                if let desc = series.descriptionText {
                    Text(desc)
                        .font(.footnote)
                        .foregroundColor(Nf.textDim)
                        .lineLimit(5)
                        .padding(.horizontal, 20)
                }
            }
            .padding(.top, 12)
        }
    }

    private func roll() async {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        defer { loading = false }

        do {
            let maxOffset = selectedGenre == nil ? 420 : 120
            let offsets = [Int.random(in: 0...maxOffset), Int.random(in: 0...max(30, maxOffset / 3)), 0]
            var picked: Series?

            for off in offsets {
                let page = try await app.a365.catalog(
                    offset: off,
                    limit: 30,
                    genre: selectedGenre?.id
                )
                let pool = excludeWatched
                    ? page.filter { lists.get($0.id) == nil }
                    : page
                if let chosen = (pool.isEmpty ? page : pool).randomElement() {
                    picked = chosen
                    break
                }
            }

            if let picked {
                candidate = picked
            } else {
                errorMessage = "Не удалось подобрать тайтл по этим параметрам — попробуйте сбросить жанр."
            }
        } catch {
            errorMessage = error.userMessage
        }
    }
}
