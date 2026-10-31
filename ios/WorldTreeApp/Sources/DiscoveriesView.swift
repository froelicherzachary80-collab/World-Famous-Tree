import SwiftUI
import WorldTreeCore

struct DiscoveriesView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Duplicates (\(model.duplicates.count))").tag(0)
                    Text("iPhone (\(model.research.discoveries.filter { $0.status == .pending }.count))").tag(3)
                    Text("Server (\(model.discoveries.filter { $0.status == "pending" }.count))").tag(1)
                    Text("Merges").tag(2)
                }
                .pickerStyle(.segmented).padding()
                ScrollView {
                    VStack(spacing: 14) {
                        switch tab {
                        case 0: duplicates
                        case 1: research
                        case 3: LocalDiscoveriesList()
                        default: mergeLog
                        }
                    }.padding(.horizontal)
                }
            }
            .screenBackground()
            .navigationTitle("Discoveries")
            .toolbarBackground(Theme.night, for: .navigationBar)
            .refreshable { await model.refreshServer() }
        }
    }

    @ViewBuilder private var duplicates: some View {
        if model.duplicates.isEmpty {
            ContentUnavailableView("No possible duplicates", systemImage: "checkmark.circle",
                                   description: Text("Duplicates need more than a shared name — dates, places or relatives must agree."))
                .foregroundStyle(.white)
        }
        ForEach(model.duplicates) { c in DuplicateCard(candidate: c) }
    }

    @ViewBuilder private var research: some View {
        ServerRequiredBanner()
        ForEach(model.discoveries) { d in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon(d.kind)).foregroundStyle(d.kind == "connection" ? Theme.gold : Theme.violet)
                    Text(d.title).font(.callout.bold()).foregroundStyle(.white)
                }
                if let r = d.detail["result"], let expl = r["primary"]?["explanation"]?.string {
                    Text(expl).font(.caption).foregroundStyle(.white.opacity(0.8))
                }
                if let matches = d.detail["matches"]?.array, !matches.isEmpty {
                    Text("Matching: " + matches.compactMap(\.string).joined(separator: ", ")).font(.caption).foregroundStyle(.green)
                }
                if let issues = d.detail["issues"]?.array, !issues.isEmpty {
                    Text("Issues: " + issues.compactMap(\.string).joined(separator: "; ")).font(.caption).foregroundStyle(.orange)
                }
                if let src = d.detail["source"]?.string, let url = URL(string: src) {
                    Link("Source", destination: url).font(.caption)
                }
                HStack {
                    Text(d.status.replacingOccurrences(of: "_", with: " ")).font(.caption2).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    if d.status == "pending" {
                        Button("Reject") { Task { await model.discoveryAction(d, "reject") } }.buttonStyle(.bordered).tint(Theme.danger)
                        Button(d.kind == "identity_match" ? "Same person — merge" : "Accept") {
                            Task { await model.discoveryAction(d, "accept") }
                        }.buttonStyle(.borderedProminent).tint(Theme.gold)
                    }
                }.font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    private func icon(_ kind: String) -> String {
        switch kind { case "connection": return "sparkles"; case "identity_match": return "person.2.circle"
        case "relationship": return "link"; default: return "person.badge.plus" }
    }

    @ViewBuilder private var mergeLog: some View {
        if model.merges.isEmpty { Text("No merges yet.").foregroundStyle(.white.opacity(0.6)) }
        ForEach(model.merges.reversed()) { m in
            HStack {
                VStack(alignment: .leading) {
                    Text("\(m.keptPersonBefore.name) ← \(model.tree.persons[m.mergedID]?.name ?? m.mergedID)").foregroundStyle(.white)
                    Text(m.date.formatted()).font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Button("Undo") { model.undo(m) }.buttonStyle(.bordered).tint(Theme.gold)
            }.card()
        }
    }
}

struct DuplicateCard: View {
    @EnvironmentObject var model: AppModel
    let candidate: DuplicateDetector.Candidate
    @State private var keepA = true

    var body: some View {
        let g = model.graph
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("POSSIBLE DUPLICATE DETECTED").font(.caption.weight(.heavy)).foregroundStyle(Theme.gold)
                Spacer()
                Text(String(format: "%.0f%%", candidate.score * 100)).font(.caption.monospacedDigit()).foregroundStyle(.white)
            }
            HStack(alignment: .top, spacing: 10) {
                if let a = g.persons[candidate.a] { profile(a, g, chosen: keepA).onTapGesture { keepA = true } }
                if let b = g.persons[candidate.b] { profile(b, g, chosen: !keepA).onTapGesture { keepA = false } }
            }
            ForEach(candidate.matches, id: \.self) { Label($0, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green) }
            ForEach(candidate.conflicts, id: \.self) { Label($0, systemImage: "xmark.circle").font(.caption).foregroundStyle(.orange) }
            Text("Tap a profile to choose which record to keep. Conflicting facts are preserved and every merge can be undone.")
                .font(.caption2).foregroundStyle(.white.opacity(0.6))
            HStack {
                Button("Merge") { withAnimation { model.resolveDuplicate(candidate, action: .merge, keepA: keepA) } }
                    .buttonStyle(.borderedProminent).tint(Theme.gold)
                Button("Keep separate") { withAnimation { model.resolveDuplicate(candidate, action: .keepSeparate) } }
                Menu("More") {
                    Button("Investigate further") { model.resolveDuplicate(candidate, action: .investigate) }
                    Button("Definitely different people") { model.resolveDuplicate(candidate, action: .differentPeople) }
                }
            }.font(.caption).buttonStyle(.bordered).tint(Theme.violet)
        }.card()
    }

    private func profile(_ p: Person, _ g: TreeGraph, chosen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(p.name).font(.callout.bold()).foregroundStyle(.white)
            Text(p.lifespan).font(.caption).foregroundStyle(.white.opacity(0.75))
            if let bp = p.birthPlace { Text(bp).font(.caption2).foregroundStyle(.white.opacity(0.6)) }
            let parents = (g.parents[p.id] ?? []).map { g.name($0.other) }
            if !parents.isEmpty { Text("Parents: " + parents.joined(separator: ", ")).font(.caption2).foregroundStyle(.white.opacity(0.6)) }
            Text("\(p.citations.count) source(s)").font(.caption2).foregroundStyle(.white.opacity(0.6))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(chosen ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(chosen ? Theme.gold : .clear, lineWidth: 1.5))
    }
}
