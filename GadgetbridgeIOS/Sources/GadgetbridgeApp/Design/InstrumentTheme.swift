import SwiftUI

/// The single source of truth for the instrument-panel visual system.
///
/// Colours are fixed rather than adaptive: the app commits to a dark
/// instrument face in both system appearances, the way a piece of measuring
/// equipment doesn't turn beige in daylight. Every surface, accent and
/// semantic colour used anywhere in the UI is declared here.
enum Instrument {
    // MARK: - Surfaces

    /// Screen base. Cool-biased near-black rather than pure black.
    static let ground = Color(hex: 0x0A0D0F)
    /// Raised surfaces, lit from above.
    static let panel = Color(hex: 0x141A1E)
    static let panelHighlight = Color(hex: 0x1A2126)
    /// Recessed surfaces: charts, logs, text fields. Data sits *in* these.
    static let well = Color(hex: 0x070909)
    static let rule = Color(hex: 0x232A30)
    /// 1px top highlight that makes a panel read as lit from above.
    static let hairline = Color.white.opacity(0.045)

    // MARK: - Ink

    static let ink = Color(hex: 0xEDEDE9)
    static let dim = Color(hex: 0x96A1A7)
    static let faint = Color(hex: 0x5C666C)

    // MARK: - Accent and semantics

    /// Accent and backlight. Chrome only — never used to encode data.
    static let amber = Color(hex: 0xE9A23B)
    static let amberSoft = Color(hex: 0xE9A23B).opacity(0.14)
    /// Heart rate. Reserved: never used as chrome.
    static let pulse = Color(hex: 0xFF6B81)
    /// Connection status. Always paired with a text label, never colour alone.
    static let linked = Color(hex: 0x4BC98A)
    /// Bytes inbound from a device, in the protocol log.
    static let inbound = Color(hex: 0x74C8E0)
    /// A response this code discarded, in the protocol log.
    static let discarded = Color(hex: 0xFF8B5E)
    static let danger = Color(hex: 0xFF7070)

    // MARK: - Type

    /// Every numeral, identifier and hex string. Tabular so readings twitch
    /// in place instead of reflowing.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Small uppercase section label, letterspaced.
    static let labelSize: CGFloat = 10
    static let labelTracking: CGFloat = 1.4
}

// MARK: - Surface modifiers

extension View {
    /// A raised panel: gradient fill, hairline top highlight, soft drop.
    func instrumentPanel(cornerRadius: CGFloat = 15) -> some View {
        self
            .background(
                LinearGradient(
                    colors: [Instrument.panelHighlight, Instrument.panel],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Instrument.rule, lineWidth: 1)
            )
            .overlay(alignment: .top) {
                Instrument.hairline
                    .frame(height: 1)
                    .padding(.horizontal, 1)
            }
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
    }

    /// A recessed well: data sits inside the surface rather than on it.
    func instrumentWell(cornerRadius: CGFloat = 9) -> some View {
        self
            .background(Instrument.well)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.03), lineWidth: 1)
            )
    }

    /// Uppercase, letterspaced section label in the instrument register.
    func instrumentLabel() -> some View {
        self
            .font(Instrument.mono(Instrument.labelSize))
            .tracking(Instrument.labelTracking)
            .textCase(.uppercase)
            .foregroundStyle(Instrument.faint)
    }
}

/// A section label that keeps hex identifiers in their real casing —
/// `0x2A37`, never `0X2A37`, which matters in an app whose premise is
/// getting bytes right.
struct SectionLabel: View {
    let title: String
    var trailing: String?
    var trailingIsRaw = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).instrumentLabel()
            Spacer(minLength: 8)
            if let trailing {
                if trailingIsRaw {
                    Text(trailing)
                        .font(Instrument.mono(Instrument.labelSize))
                        .tracking(0.6)
                        .foregroundStyle(Instrument.faint)
                } else {
                    Text(trailing).instrumentLabel()
                }
            }
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
