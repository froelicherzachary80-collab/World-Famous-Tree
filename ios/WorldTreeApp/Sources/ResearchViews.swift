import SwiftUI
import WorldTreeCore

struct ServerRequiredBanner: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if model.client == nil || !model.serverOnline {
            VStack(alignment: .leading, spacing: 6) {
                Label(model.client == nil ? "Research server not connected" : "Research server offline", systemImage: "server.rack")
                    .font(.headline).foregroundStyle(Theme.gold)
                Text("Autonomous research runs on your own always-on computer so it keeps going when your iPhone is closed. "
                     + "Set it up from the repository's docs, then enter its address and token in Profile.")
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
            }.frame(maxWidth: .infinity, alignment: .leading).card()
        }
    }
}

struct ResearchView: View {
    @EnvironmentObject var model: AppModel
    @State private var instruction = ""
    @State private var preview: ResearchPlan?
    @State private var budget = 200.0
    @State private var daily = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CreatorResearchPanel()
                    Text("Research server").font(.title3.bold()).foregroundStyle(.white).padding(.top, 4)
                    ServerRequiredBanner()
                    dashboard
                    composer
                    goalsList
                    activityFeed
                }.padding()
            }
            .screenBackground()
            .navigationTitle("AI Research")
            .toolbarBackground(Theme.night, for: .navigationBar)
            .refreshable { await model.refreshServer() }
            .task { model.startPolling(); model.requestNotificationPermission() }
        }
    }

    private var dashboard: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            StatTile(title: "Active goals", value: "\(model.stats.activeGoals)", icon: "bolt.fill")
            StatTile(title: "Completed", value: "\(model.stats.completedGoals)", icon: "checkmark.seal")
            StatTile(title: "Queue", value: "\(model.stats.queue["queued", default: 0] + model.stats.queue["running", default: 0])", icon: "tray.full")
            StatTile(title: "Candidates", value: "\(model.stats.candidatePeople)", icon: "person.badge.plus")
            StatTile(title: "Verified links", value: "\(model.stats.verifiedConnections)", icon: "link")
            StatTile(title: "Sources", value: "\(model.stats.sourcesReviewed)", icon: "books.vertical")
            StatTile(title: "Duplicates", value: "\(model.stats.possibleDuplicates)", icon: "person.2")
            StatTile(title: "Open branches", value: "\(model.stats.unresolvedBranches)", icon: "arrow.triangle.branch")
            StatTile(title: "Errors/blocked", value: "\(model.stats.errors)", icon: "exclamationmark.octagon")
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New research goal").font(.headline).foregroundStyle(Theme.gold)
            TextField("e.g. Research Young Hollywood actors, investigate their publicly documented ancestors, and find possible connections to my GEDCOM family tree.",
                      text: $instruction, axis: .vertical)
                .lineLimit(3...6)
                .padding(10)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
            Text("Quote names to research specific people: \"Tom Holland\"").font(.caption2).foregroundStyle(.white.opacity(0.6))
            HStack {
                Text("Request budget: \(Int(budget))").font(.caption).foregroundStyle(.white)
                Slider(value: $budget, in: 20...2000, step: 20)
            }
            Toggle("Repeat daily", isOn: $daily).foregroundStyle(.white).font(.caption)
            if let p = preview {
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.understood ? "Structured plan" : "I couldn't map that to a research category yet. Try naming a universe (Minecraft, Marvel, royal…) or quoting a person's name.")
                        .font(.caption.bold()).foregroundStyle(p.understood ? Theme.violet : .orange)
                    ForEach(Array(p.steps.enumerated()), id: \.offset) { item in
                        Text("\(item.offset + 1). \(item.element.agent) — \(item.element.action.replacingOccurrences(of: "_", with: " "))")
                            .font(.caption).foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            HStack {
                Button("Preview plan") {
                    Task { preview = try? await model.client?.previewPlan(instruction) }
                }.buttonStyle(.bordered)
                Button("Start research") {
                    let text = instruction
                    Task { await model.createGoal(text, budget: Int(budget), daily: daily, start: true); instruction = ""; preview = nil }
                }.buttonStyle(.borderedProminent)
            }
            .tint(Theme.gold)
            .disabled(instruction.trimmingCharacters(in: .whitespaces).isEmpty || model.client == nil)
        }.card()
    }

    private var goalsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Research goals").font(.headline).foregroundStyle(Theme.gold)
            if model.goals.isEmpty { Text("No goals yet.").foregroundStyle(.white.opacity(0.6)) }
            ForEach(model.goals) { g in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(g.status.uppercased()).font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(statusColor(g.status).opacity(0.25), in: Capsule())
                            .foregroundStyle(statusColor(g.status))
                        if g.schedule == "daily" { Image(systemName: "calendar.badge.clock").foregroundStyle(.white.opacity(0.7)) }
                        Spacer()
                        Text("\(g.spent)/\(g.budget) requests").font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                    }
                    Text(g.instruction).foregroundStyle(.white).font(.callout)
                    ProgressView(value: Double(g.jobs["done", default: 0]),
                                 total: Double(max(1, g.jobs.values.reduce(0, +)))).tint(Theme.gold)
                    HStack {
                        switch g.status {
                        case "draft", "stopped", "completed": actionButton("Start", g, "start")
                        case "active": actionButton("Pause", g, "pause"); actionButton("Stop", g, "stop")
                        case "paused": actionButton("Resume", g, "resume"); actionButton("Stop", g, "stop")
                        default: EmptyView()
                        }
                        actionButton("Prioritize", g, "prioritize")
                    }
                }
                .padding(.vertical, 6)
                Divider().overlay(.white.opacity(0.1))
            }
        }.card()
    }

    private func actionButton(_ title: String, _ g: ResearchGoal, _ action: String) -> some View {
        Button(title) { Task { await model.goalAction(g, action) } }.buttonStyle(.bordered).tint(Theme.violet).font(.caption)
    }

    private func statusColor(_ s: String) -> Color {
        switch s { case "active": return .green; case "paused": return .orange; case "completed": return Theme.gold
        case "stopped": return Theme.danger; default: return .gray }
    }

    private var activityFeed: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Research agent activity").font(.headline).foregroundStyle(Theme.gold)
            if model.activity.isEmpty { Text("Agents are idle.").foregroundStyle(.white.opacity(0.6)) }
            ForEach(model.activity.prefix(40)) { a in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: icon(a.level)).foregroundStyle(a.level == "info" ? Theme.sky : a.level == "warn" ? .orange : Theme.danger)
                        Text(a.agent).font(.caption.bold()).foregroundStyle(.white)
                        Spacer()
                        Text(a.createdAt).font(.caption2).foregroundStyle(.white.opacity(0.5))
                    }
                    Text(a.message).font(.caption).foregroundStyle(.white.opacity(0.85))
                }
            }
        }.card()
    }

    private func icon(_ level: String) -> String {
        switch level { case "warn": return "exclamationmark.triangle"; case "error": return "xmark.octagon"
        case "blocked": return "hand.raised"; default: return "sparkle" }
    }
}

struct FamousFamiliesView: View {
    @EnvironmentObject var model: AppModel

    struct Category: Identifiable {
        let id: String, universe: String, title: String, icon: String, goal: String, items: [String]
    }

    let categories = [
        Category(id: "minecraft", universe: "minecraft", title: "Minecraft Universe", icon: "cube.fill",
                 goal: "Research Minecraft YouTubers and find documented family connections to my ancestors.",
                 items: ["Minecraft YouTubers", "Minecraft streamers", "Gaming creators"]),
        Category(id: "young_hollywood", universe: "young_hollywood", title: "Young Hollywood", icon: "star.fill",
                 goal: "Research Young Hollywood actors and actresses and find connections to my GEDCOM family tree.",
                 items: ["Young actors", "TV stars", "Disney & Nickelodeon alumni", "Streaming-series performers"]),
        Category(id: "marvel", universe: "marvel", title: "Marvel Universe", icon: "bolt.shield.fill",
                 goal: "Research Marvel Cinematic Universe actors and find connections to my family tree.",
                 items: ["MCU actors", "Marvel TV actors", "Marvel film cast"]),
        Category(id: "music", universe: "music", title: "Music Universe", icon: "music.mic",
                 goal: "Research famous pop singers and musicians and find connections to my family tree.",
                 items: ["Pop singers", "Musicians", "Songwriters", "Music-industry families"]),
        Category(id: "royal", universe: "royal", title: "History Universe", icon: "crown.fill",
                 goal: "Explore royal family connections, royal dynasties and medieval nobility linked to my tree.",
                 items: ["Royal families", "Medieval nobility", "Historical figures"]),
        Category(id: "ancient", universe: "ancient", title: "Ancient Civilizations", icon: "building.columns.fill",
                 goal: "Research documented ancient dynasties (Egypt, Greece, Rome, Mesopotamia).",
                 items: ["Ancient Egypt", "Greece & Rome", "Mesopotamia"]),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ServerRequiredBanner()
                    Text("Researching a famous person never assumes you're related. Only documented, evidence-backed paths are shown as connections.")
                        .font(.caption).foregroundStyle(.white.opacity(0.75))
                    ForEach(categories) { c in card(c) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Ancient & legendary lines").font(.headline).foregroundStyle(Theme.gold)
                        Text("Records back to 4000 BCE and earlier are supported, but a date is not a lineage. Research separates documented ancestry, probable-but-incomplete lines, disputed genealogy, legendary lines and population-level ancestry — and never invents royal or ancient descent.")
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                    }.frame(maxWidth: .infinity, alignment: .leading).card()
                }.padding()
            }
            .screenBackground()
            .navigationTitle("Famous Families")
            .toolbarBackground(Theme.night, for: .navigationBar)
            .task { await model.refreshServer() }
        }
    }

    private func card(_ c: Category) -> some View {
        let members = model.universes.first { $0.id == c.universe }?.members ?? 0
        let color = Theme.universeColors[c.universe] ?? .gray
        let connections = model.discoveries.filter { $0.kind == "connection" }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: c.icon).font(.title2).foregroundStyle(color)
                    .shadow(color: color.opacity(0.8), radius: 8)
                VStack(alignment: .leading) {
                    Text(c.title).font(.headline).foregroundStyle(.white)
                    Text("\(members) researched people").font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
            }
            Text(c.items.joined(separator: " · ")).font(.caption).foregroundStyle(.white.opacity(0.75))
            Text(connections.isEmpty ? RelationshipCalculator.noConnection : "\(connections.count) connection(s) found — see Discoveries")
                .font(.caption2.bold()).foregroundStyle(connections.isEmpty ? .white.opacity(0.5) : Theme.gold)
            Button("Research this universe") { Task { await model.createGoal(c.goal) } }
                .buttonStyle(.borderedProminent).tint(color).font(.caption)
                .disabled(model.client == nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
