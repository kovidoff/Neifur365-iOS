import CoreText
import SwiftUI
import UIKit

/// Neifur palette: near-black ink with a cold violet tint, one violet accent, mint for "ready to play".
enum Nf {
    static let ink = Color(hex: 0x08080C)
    static let surface = Color(hex: 0x111119)
    static let surfaceHi = Color(hex: 0x1A1A25)
    static let line = Color(hex: 0x282836)
    static let text = Color(hex: 0xF3F1FA)
    static let textDim = Color(hex: 0xA9A6BC)
    static let textMute = Color(hex: 0x6F6C84)
    static let violet = Color(hex: 0x9B7BFF)
    static let pink = Color(hex: 0xFF6B9A)
    static let mint = Color(hex: 0x5CF2B0)
    static let amber = Color(hex: 0xFFC56B)
    static let red = Color(hex: 0xFF6B6B)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

/// Loads bundled variable fonts (Manrope / Unbounded) with exact `wght` axis values and Dynamic Type scaling.
enum NfFont {
    private static let weightAxisTag: UInt32 = 0x77676874 // 'wght'

    static func manrope(size: CGFloat, weight: Int, relativeTo textStyle: UIFont.TextStyle = .body) -> Font {
        let scaled = UIFontMetrics(forTextStyle: textStyle).scaledValue(for: size)
        return variableFont(postScriptName: "Manrope-ExtraLight", size: scaled, weight: weight)
    }

    static func unbounded(size: CGFloat, weight: Int, relativeTo textStyle: UIFont.TextStyle = .headline) -> Font {
        let scaled = UIFontMetrics(forTextStyle: textStyle).scaledValue(for: size)
        return variableFont(postScriptName: "Unbounded-Regular", size: scaled, weight: weight)
    }

    static func variableUIFont(postScriptName: String, size: CGFloat, weight: Int) -> UIFont {
        guard let base = UIFont(name: postScriptName, size: size) else {
            return UIFont.systemFont(ofSize: size, weight: uiFontWeight(for: weight))
        }
        let variations: [NSNumber: NSNumber] = [
            NSNumber(value: weightAxisTag): NSNumber(value: weight)
        ]
        let attrs: [CFString: Any] = [
            kCTFontVariationAttribute: variations
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
        let varied = CTFontCreateCopyWithAttributes(base as CTFont, size, nil, descriptor)
        return varied as UIFont
    }

    private static func variableFont(postScriptName: String, size: CGFloat, weight: Int) -> Font {
        Font(variableUIFont(postScriptName: postScriptName, size: size, weight: weight))
    }

    private static func uiFontWeight(for weight: Int) -> UIFont.Weight {
        switch weight {
        case ..<450: return .regular
        case 450..<550: return .medium
        case 550..<650: return .semibold
        case 650..<750: return .bold
        default: return .heavy
        }
    }
}

/// Typography tokens aligned with Dynamic Type and bundled display/body fonts.
enum NfType {
    static var hero: Font { NfFont.unbounded(size: 26, weight: 600, relativeTo: .largeTitle) }
    static var display: Font { NfFont.unbounded(size: 21, weight: 600, relativeTo: .title2) }
    static var section: Font { NfFont.unbounded(size: 15, weight: 500, relativeTo: .headline) }
    static var title: Font { NfFont.manrope(size: 16, weight: 700, relativeTo: .headline) }
    static var body: Font { NfFont.manrope(size: 14.5, weight: 500, relativeTo: .body) }
    static var label: Font { NfFont.manrope(size: 13, weight: 600, relativeTo: .subheadline) }
    static var caption: Font { NfFont.manrope(size: 11.5, weight: 600, relativeTo: .caption1) }
    static var overline: Font { NfFont.manrope(size: 10.5, weight: 800, relativeTo: .caption2) }
}

// MARK: - iOS 26 Liquid Glass Helpers

extension View {
    @ViewBuilder
    func nfGlassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.7))
        }
    }

    @ViewBuilder
    func nfGlassCircle() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .circle)
        } else {
            self
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.7))
        }
    }

    @ViewBuilder
    func nfGlassCard(cornerRadius: CGFloat = 18) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.7)
                )
        }
    }
}

/// Subtle spring scale feedback for cards and buttons.
struct NfPressableStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: configuration.isPressed)
    }
}
