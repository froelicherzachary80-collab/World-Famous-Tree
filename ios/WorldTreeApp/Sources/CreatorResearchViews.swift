import SwiftUI
import WorldTreeCore

/// On-device creator research panel (works without the research server).
struct CreatorResearchPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var handles = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Creator research on this iPhone", systemImage: "iphone.gen3.radiowaves.left.and.right")
                    .font(.headline).foregroundStyle(Theme.gold)
                Spacer()
                if model.researchRunning { ProgressView().tint(Theme.gold) }
            }
            TextField("LDShadowLady, JumperWho, MinuteTech", text: $handles, axis: .vertical)
                .lineLimit(1...4)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
            Button {
                model.researchCreators(handles)
                handles = ""
            } label: {
                Label("Research creators", systemImage: "sparkle.magnifyingglass").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Theme.gold)
            .disabled(CreatorResearchEngine.parseHandles(handles).isEmpty)

            status
            Text("Finds each creator's publicly documented real name, public relatives and deceased ancestors, then checks them against your tree. Living family members who aren't public figures, and anyone under 18, are never researched.")
                .font(.caption2).foregroundStyle(.white.opacity(0.6))
            if !model.research.log.isEmpty {
                DisclosureGroup("Agent log") {
                    ForEach(model.research.log.prefix(30)) { e in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.agent).font(.caption2.bold()).foregroundStyle(e.isError ? .orange : Theme.sky)
                            Text(e.message).font(.caption).foregroundStyle(.white.opacity(0.85))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .foregroundStyle(.white)
                .font(.caption)
            }
        }
        .card()
    }

    @ViewBuilder private var status: some View {
        let r = model.research
        if !r.isIdle || model.researchRunning {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(r.completedJobs), total: Double(max(1, r.completedJobs + r.pendingCount)))
                    .tint(Theme.gold)
                HStack {
                    Text(model.researchRunning ? "Researching… \(r.pendingCount) step(s) left" : "Paused — \(r.pendingCount) step(s) saved")
                        .font(.caption).foregroundStyle(.white)
                    Spacer()
                    if model.researchRunning {
                        Button("Pause") { model.stopResearchLoop() }.font(.caption)
                    } else {
                        Button("Resume") { BackgroundResearch.shared.userStartedResearch() }.font(.caption)
                    }
                    Button("Clear", role: .destructive) { model.clearResearchQueue() }.font(.caption)
                }
                Label("You can leave the app — research keeps going in the background. Swiping the app away from the app switcher stops it; it resumes next time you open the app.",
                      systemImage: "info.circle")
                    .font(.caption2).foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}

/// Results from on-device research, shown in Discoveries.
struct LocalDiscoveriesList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let items = model.research.discoveries.reversed()
        if items.isEmpty {
            Text("Research a creator from the AI Research tab to see results here.")
                .font(.caption).foregroundStyle(.white.opacity(0.6))
        }
        ForEach(Array(items)) { d in
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Image(systemName: icon(d.kind)).foregroundStyle(color(d.kind))
                    Text(d.title).font(.callout.bold()).foregroundStyle(.white)
                }
                if !d.detail.isEmpty { Text(d.detail).font(.caption).foregroundStyle(.white.opacity(0.8)) }
                HStack {
                    if let s = d.sourceURL, let url = URL(string: s) { Link("Source", destination: url).font(.caption) }
                    if let first = d.personIDs.first, model.tree.persons[first] != nil {
                        NavigationLink("Profile") { PersonDetailView(personID: first) }.font(.caption)
                    }
                    Spacer()
                    if d.kind == .identityMatch && d.status == .pending {
                        Button("Not the same") { model.rejectLocalMatch(d) }.buttonStyle(.bordered).tint(Theme.danger)
                        Button("Same person — merge") { model.confirmLocalMatch(d) }.buttonStyle(.borderedProminent).tint(Theme.gold)
                    } else if d.kind == .identityMatch {
                        Text(d.status.rawValue).font(.caption2).foregroundStyle(.white.opacity(0.6))
                    }
                }.font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    private func icon(_ k: LocalDiscovery.Kind) -> String {
        switch k {
        case .creatorFound: return "person.crop.square.filled.and.at.rectangle"
        case .notFound: return "questionmark.circle"
        case .newPerson: return "person.badge.plus"
        case .identityMatch: return "person.2.circle"
        case .connection: return "sparkles"
        case .privacyNote: return "lock.shield"
        }
    }

    private func color(_ k: LocalDiscovery.Kind) -> Color {
        switch k {
        case .connection, .creatorFound: return Theme.gold
        case .identityMatch: return Theme.violet
        case .notFound: return .gray
        case .privacyNote: return Theme.sky
        case .newPerson: return .green
        }
    }
}
