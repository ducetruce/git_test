import SwiftUI

/// The app's look: deep navy, soft cards, light type, a few calm accents.
enum Theme {
    static let background = Color(red: 0.043, green: 0.063, blue: 0.098)   // #0B1019
    static let card = Color(red: 0.071, green: 0.102, blue: 0.157)         // #121A28
    static let track = Color(red: 0.094, green: 0.137, blue: 0.227)        // #18233A
    static let hairline = Color(red: 0.165, green: 0.216, blue: 0.314)     // #2A3750
    static let text = Color(red: 0.918, green: 0.941, blue: 0.969)         // #EAF0F7
    static let secondary = Color(red: 0.576, green: 0.627, blue: 0.706)    // #93A0B4
    static let tertiary = Color(red: 0.498, green: 0.545, blue: 0.627)     // #7F8BA0
    static let teal = Color(red: 0.525, green: 0.839, blue: 0.780)         // #86D6C7
    static let blue = Color(red: 0.620, green: 0.765, blue: 1.0)           // #9EC3FF
    static let amber = Color(red: 0.941, green: 0.765, blue: 0.557)        // #F0C38E
    static let red = Color(red: 1.0, green: 0.541, blue: 0.502)            // #FF8A80

    /// Small spaced capitals, for section labels.
    static func label(_ text: String, color: Color = Theme.tertiary) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.3)
            .foregroundStyle(color)
    }
}

/// A rounded card on the dark background.
struct Card<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// A score ring with a value in the middle and a label under it.
struct ScoreRing: View {
    let value: String
    let label: String
    /// 0...1, or nil for an empty ring.
    let fraction: Double?
    var color: Color = Theme.teal
    var size: CGFloat = 84

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(Theme.track, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: min(max(fraction ?? 0, 0), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(value)
                    .font(.system(size: size * 0.27, weight: .light))
                    .foregroundStyle(Theme.text)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
            }
            .frame(width: size, height: size)
            Theme.label(label)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Primary (filled) and secondary (outlined) pill buttons.
struct PillButtonStyle: ButtonStyle {
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: filled ? .semibold : .regular))
            .foregroundStyle(filled ? Theme.background : Theme.text)
            .padding(.horizontal, 20)
            .frame(minHeight: 46)
            .background {
                if filled {
                    Capsule().fill(Theme.text)
                } else {
                    Capsule().stroke(Theme.hairline, lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// A round icon button with a caption, for quick actions.
struct RoundAction: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .regular))
                    .frame(width: 54, height: 54)
                    .background(Theme.card, in: Circle())
                    .foregroundStyle(Theme.text)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// Dark lists that sit on the app background, with card-coloured rows.
    func themedList() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.background)
    }
}
