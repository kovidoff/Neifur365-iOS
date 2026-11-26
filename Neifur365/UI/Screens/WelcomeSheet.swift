import SwiftUI

struct WelcomeSheet: View {
    @EnvironmentObject private var prefs: Prefs
    @Environment(\.dismiss) private var dismiss

    @State private var page = 0
    let onSignIn: () -> Void

    private struct Slide: Identifiable {
        let id: Int
        let icon: String
        let tint: Color
        let title: String
        let body: String
    }

    private let slides: [Slide] = [
        Slide(
            id: 0,
            icon: "play.tv.fill",
            tint: Nf.violet,
            title: "Anime 365 на iPhone и iPad",
            body: "Быстрый нативный плеер на базе libmpv и Metal с .ass-субтитрами, пропуском опенингов и жестами."
        ),
        Slide(
            id: 1,
            icon: "bookmark.fill",
            tint: Nf.mint,
            title: "Ваши списки и прогресс",
            body: "Синхронизация с Anime 365, офлайн-кеш списков и автопереключение рабочих зеркал и видеоканалов."
        ),
        Slide(
            id: 2,
            icon: "arrow.down.circle.fill",
            tint: Nf.amber,
            title: "Офлайн-просмотр и уведомления",
            body: "Скачивайте серии на устройство, настраивайте любимые студии и получайте уведомления о новых эпизодах."
        )
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(slides) { slide in
                        VStack(spacing: 18) {
                            Spacer()
                            Image(systemName: slide.icon)
                                .font(.system(size: 54))
                                .foregroundColor(slide.tint)
                                .padding(26)
                                .background(slide.tint.opacity(0.14), in: Circle())

                            Text(slide.title)
                                .font(NfType.display)
                                .foregroundColor(Nf.text)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)

                            Text(slide.body)
                                .font(NfType.body)
                                .foregroundColor(Nf.textDim)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 28)
                            Spacer()
                        }
                        .tag(slide.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                VStack(spacing: 10) {
                    if page < slides.count - 1 {
                        Button {
                            withAnimation { page += 1 }
                        } label: {
                            Text("Дальше")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Nf.violet)
                    } else {
                        Button {
                            prefs.onboarded = true
                            dismiss()
                            onSignIn()
                        } label: {
                            Text("Войти в Anime 365")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Nf.violet)

                        Button {
                            prefs.onboarded = true
                            dismiss()
                        } label: {
                            Text("Продолжить без входа")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(Nf.textDim)
                                .padding(.vertical, 8)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .background(Nf.ink.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Пропустить") {
                        prefs.onboarded = true
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}
