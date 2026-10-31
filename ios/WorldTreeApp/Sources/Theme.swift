import SwiftUI
import WorldTreeCore

enum Theme {
    static let night = Color(red: 0.027, green: 0.043, blue: 0.122)      // #070B1F
    static let deep = Color(red: 0.07, green: 0.10, blue: 0.24)
    static let card = Color(red: 0.10, green: 0.13, blue: 0.30).opacity(0.85)
    static let gold = Color(red: 0.91, green: 0.77, blue: 0.41)           // #E8C468
    static let violet = Color(red: 0.56, green: 0.42, blue: 1.0)          // #8E6CFF
    static let sky = Color(red: 0.44, green: 0.66, blue: 1.0)
    static let danger = Color(red: 0.90, green: 0.35, blue: 0.35)

    static let background = LinearGradient(colors: [night, deep, Color(red: 0.13, green: 0.07, blue: 0.27)],
                                           startPoint: .top, endPoint: .bottom)

    static let universeColors: [String: Color] = [
        "my_family": gold,
        "minecraft": Color(red: 0.37, green: 0.83, blue: 0.55),
        "young_hollywood": Color(red: 0.97, green: 0.56, blue: 0.70),
        "marvel": Color(red: 0.90, green: 0.33, blue: 0.33),
        "music": Color(red: 0.71, green: 0.55, blue: 1.0),
        "royal": sky,
        "ancient": Color(red: 0.85, green: 0.63, blue: 0.40),
    ]

    static func color(forUniverses u: [String]) -> Color {
        for key in ["my_family", "royal", "ancient", "marvel", "young_hollywood", "music", "minecraft"] where u.contains(key) {
            return universeColors[key]!
        }
        return Color.gray
    }

    static func color(for evidence: EvidenceStatus) -> Color {
        switch evidence {
        case .verified, .userProvided: return gold
        case .supported: return violet
        case .candidate: return Color.gray
        case .disputed, .rejected: return danger
        case .legendary: return Color.orange
        }
    }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.gold.opacity(0.18), lineWidth: 1))
    }
}

extension View {
    func card() -> some View { modifier(CardStyle()) }
    func screenBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
            .scrollContentBackground(.hidden)
    }
}

struct EvidenceBadge: View {
    let status: EvidenceStatus
    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.color(for: status).opacity(0.2), in: Capsule())
            .foregroundStyle(Theme.color(for: status))
            .accessibilityLabel("Evidence: \(status.label)")
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(Theme.gold)
            Text(value).font(.title2.bold().monospacedDigit()).foregroundStyle(.white)
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .combine)
    }
}
