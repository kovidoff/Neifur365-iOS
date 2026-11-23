import NukeUI
import SwiftUI

/// Clipped remote poster view that never overflows its proposed frame.
struct PosterView: View {
    let urlString: String?
    var cornerRadius: CGFloat = 14
    var alignment: Alignment = .top

    var body: some View {
        Color.clear
            .background(Nf.surfaceHi)
            .overlay(alignment: alignment) {
                if let urlString, let url = URL(string: urlString) {
                    LazyImage(url: url) { state in
                        if let image = state.image {
                            image
                                .resizable()
                                .scaledToFill()
                        } else if state.error != nil {
                            Image(systemName: "film")
                                .font(.system(size: 22))
                                .foregroundColor(Nf.textMute)
                        } else {
                            Nf.surfaceHi
                        }
                    }
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 22))
                        .foregroundColor(Nf.textMute)
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct AvatarView: View {
    let urlString: String?
    var size: CGFloat = 40

    var body: some View {
        Color.clear
            .background(Nf.surfaceHi)
            .overlay {
                if let urlString, let url = URL(string: urlString) {
                    LazyImage(url: url) { state in
                        if let image = state.image {
                            image
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "person.fill")
                                .font(.system(size: size * 0.45))
                                .foregroundColor(Nf.textMute)
                        }
                    }
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.45))
                        .foregroundColor(Nf.textMute)
                }
            }
            .frame(width: size, height: size)
            .clipped()
            .clipShape(Circle())
    }
}

extension ListStatus {
    var tintColor: Color {
        switch self {
        case .watching: return Nf.mint
        case .planned: return Nf.violet
        case .completed: return Color(hex: 0x60A5FA)
        case .onHold: return Nf.amber
        case .dropped: return Nf.red
        }
    }
}

/// Crisp 2:3 anime poster card for horizontal carousels.
struct AnimePosterCard: View {
    let series: Series
    var listStatus: ListStatus? = nil
    var badgeText: String? = nil
    var badgeColor: Color = Nf.mint
    var width: CGFloat = 134

    private var posterHeight: CGFloat { round(width * 1.48) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            PosterView(urlString: series.bestPosterUrl, cornerRadius: 14, alignment: .top)
                .frame(width: width, height: posterHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.7)
                )
                .overlay(alignment: .top) {
                    HStack(alignment: .center) {
                        if let badgeText {
                            Text(badgeText)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(Nf.ink)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(badgeColor, in: Capsule())
                        } else if let score = series.score {
                            HStack(spacing: 3) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(Nf.amber)
                                Text(String(format: "%.1f", score))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white)
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                        }

                        Spacer(minLength: 4)

                        if let listStatus {
                            Image(systemName: listStatus.systemImage)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(listStatus.tintColor)
                                .padding(4)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                    .padding(7)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(series.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(Nf.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let subtitle = metaLine {
                    Text(subtitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(Nf.textMute)
                        .lineLimit(1)
                }
            }
            .frame(width: width, alignment: .topLeading)
        }
        .frame(width: width, alignment: .topLeading)
    }

    private var metaLine: String? {
        var parts: [String] = []
        if series.year > 0 { parts.append(String(series.year)) }
        if series.airing {
            parts.append("онгоинг")
        } else if series.isMovie {
            parts.append("фильм")
        } else if series.numberOfEpisodes > 0 {
            parts.append("\(series.numberOfEpisodes) эп.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
