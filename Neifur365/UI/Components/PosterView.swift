import NukeUI
import SwiftUI

struct PosterView: View {
    let urlString: String?
    var cornerRadius: CGFloat = 14

    var body: some View {
        ZStack {
            Nf.surfaceHi
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
        ZStack {
            Circle().fill(Nf.surfaceHi)
            if let urlString, let url = URL(string: urlString) {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "person.fill")
                            .foregroundColor(Nf.textMute)
                    }
                }
            } else {
                Image(systemName: "person.fill")
                    .foregroundColor(Nf.textMute)
            }
        }
        .frame(width: size, height: size)
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

struct AnimePosterCard: View {
    let series: Series
    var listStatus: ListStatus? = nil
    var badgeText: String? = nil
    var badgeColor: Color = Nf.mint
    var width: CGFloat? = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                PosterView(urlString: series.bestPosterUrl, cornerRadius: 14)
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Nf.line.opacity(0.6), lineWidth: 0.5)
                    )

                HStack {
                    if let badgeText {
                        Text(badgeText)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Nf.ink)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(badgeColor, in: Capsule())
                    } else if let score = series.score {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundColor(Nf.amber)
                            Text(String(format: "%.1f", score))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Nf.text)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                    }

                    Spacer(minLength: 0)

                    if let listStatus {
                        Image(systemName: listStatus.systemImage)
                            .font(.system(size: 14))
                            .foregroundColor(listStatus.tintColor)
                            .padding(4)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                .padding(6)
            }

            Text(series.title)
                .font(NfType.label)
                .foregroundColor(Nf.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if let subtitle = metaLine {
                Text(subtitle)
                    .font(NfType.caption)
                    .foregroundColor(Nf.textMute)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
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
