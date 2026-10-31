import SwiftUI
import WorldTreeCore

struct HomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero
                    let gaps = GapAnalyzer.analyze(model.tree)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        StatTile(title: "People in my tree", value: "\(model.tree.activePersons.filter { $0.universes.contains("my_family") }.count)", icon: "person.3.fill")
                        StatTile(title: "Possible duplicates", value: "\(model.duplicates.count)", icon: "person.2.badge.gearshape")
                        StatTile(title: "End-of-line ancestors", value: "\(gaps.missingParents.count)", icon: "arrow.up.to.line")
                        StatTile(title: "Unsourced people", value: "\(gaps.unsourced.count)", icon: "doc.questionmark")
                    }
                    if !model.tree.persons.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Research gaps").font(.headline).foregroundStyle(Theme.gold)
                            ForEach(gaps.missingParents.prefix(5)) { p in
                                NavigationLink { PersonDetailView(personID: p.id) } label: {
                                    HStack {
                                        Text(p.name).foregroundStyle(.white)
                                        Spacer()
                                        Text(p.lifespan).font(.caption).foregroundStyle(.white.opacity(0.6))
                                    }
                                }
                            }
                            Text("Recommended research goals").font(.subheadline.bold()).foregroundStyle(.white).padding(.top, 6)
                            ForEach(gaps.recommendedGoals, id: \.self) { g in
                                Button {
                                    Task { await model.createGoal(g, start: false) }
                                } label: {
                                    Label(g, systemImage: "sparkles").font(.callout).multilineTextAlignment(.leading)
                                }.tint(Theme.violet)
                            }
                            Text("Goals are created as drafts on your research server; start them from AI Research.")
                                .font(.caption2).foregroundStyle(.white.opacity(0.6))
                        }.card()
                    }
                    NavigationLink { ConnectionFinderView() } label: {
                        Label("FIND OUR CONNECTION", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.headline).frame(maxWidth: .infinity).padding()
                            .background(Theme.gold, in: RoundedRectangle(cornerRadius: 16))
                            .foregroundStyle(Theme.night)
                    }
                    .disabled(model.tree.persons.count < 2)
                }
                .padding()
            }
            .screenBackground()
            .navigationTitle("WORLD TREE AI")
            .toolbarBackground(Theme.night, for: .navigationBar)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Famous Family Multiverse").font(.caption.weight(.heavy)).foregroundStyle(Theme.violet).textCase(.uppercase)
            if let home = model.tree.homePersonID, let p = model.tree.persons[home] {
                Text("Welcome back, \(p.given.isEmpty ? p.name : p.given)").font(.largeTitle.bold()).foregroundStyle(.white)
            } else {
                Text("Plant your World Tree").font(.largeTitle.bold()).foregroundStyle(.white)
                Text("Import your GEDCOM file in Profile to begin.").foregroundStyle(.white.opacity(0.75))
            }
        }
    }
}

struct PersonDetailView: View {
    @EnvironmentObject var model: AppModel
    let personID: String

    var body: some View {
        let g = model.graph
        ScrollView {
            if let p = g.persons[personID] {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p.isPresumedLiving() && !p.isPublicFigure ? "\(p.given) \(p.surname) (living, private)" : p.name)
                            .font(.title.bold()).foregroundStyle(.white)
                        Text(p.lifespan).foregroundStyle(.white.opacity(0.75))
                        HStack { EvidenceBadge(status: p.evidence); ForEach(Array(p.universes).sorted(), id: \.self) { u in
                            Text(u.replacingOccurrences(of: "_", with: " ").capitalized).font(.caption2)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Theme.universeColors[u, default: .gray].opacity(0.25), in: Capsule())
                                .foregroundStyle(.white)
                        } }
                    }
                    facts(p).card()
                    relatives("Parents", g.parents[personID] ?? [], g)
                    relatives("Spouses", g.spouses[personID] ?? [], g)
                    relatives("Children", g.children[personID] ?? [], g)
                    if !p.altNames.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Also known as").font(.headline).foregroundStyle(Theme.gold)
                            ForEach(p.altNames, id: \.self) { n in
                                Text("\(n.given) \(n.surname) · \(n.type)").foregroundStyle(.white)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).card()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sources").font(.headline).foregroundStyle(Theme.gold)
                        if p.citations.isEmpty { Text("No sources cited yet.").foregroundStyle(.white.opacity(0.6)) }
                        ForEach(p.citations, id: \.self) { c in
                            VStack(alignment: .leading) {
                                Text(model.tree.sources[c.sourceID]?.title ?? c.sourceID).foregroundStyle(.white)
                                if !c.detail.isEmpty { Text(c.detail).font(.caption).foregroundStyle(.white.opacity(0.6)) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).card()
                    if !p.notes.isEmpty {
                        Text(p.notes).foregroundStyle(.white.opacity(0.85)).frame(maxWidth: .infinity, alignment: .leading).card()
                    }
                    Button("Set as me (home person)") { model.setHome(personID) }.buttonStyle(.borderedProminent).tint(Theme.gold)
                }
                .padding()
            } else {
                ContentUnavailableView("Person not found", systemImage: "person.crop.circle.badge.questionmark")
            }
        }
        .screenBackground()
        .navigationTitle("Profile")
    }

    private func facts(_ p: Person) -> some View {
        let hidePrivate = p.isPresumedLiving() && !p.isPublicFigure
        return VStack(alignment: .leading, spacing: 8) {
            row("Born", hidePrivate ? "Private" : [p.birth?.display, p.birthPlace].compactMap { $0 }.joined(separator: " · "))
            row("Died", [p.death?.display, p.deathPlace].compactMap { $0 }.joined(separator: " · "))
            row("Sex", p.sex == .M ? "Male" : p.sex == .F ? "Female" : "Unknown")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.white.opacity(0.6)).frame(width: 60, alignment: .leading)
            Text(v.isEmpty ? "—" : v).foregroundStyle(.white)
        }
    }

    private func relatives(_ title: String, _ edges: [TreeGraph.Edge], _ g: TreeGraph) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).foregroundStyle(Theme.gold)
            if edges.isEmpty { Text("None recorded").foregroundStyle(.white.opacity(0.6)) }
            ForEach(edges, id: \.self) { e in
                NavigationLink { PersonDetailView(personID: e.other) } label: {
                    HStack {
                        Text(g.name(e.other)).foregroundStyle(.white)
                        if e.pedigree != .birth && e.pedigree != .unknown {
                            Text(e.pedigree.rawValue).font(.caption2).foregroundStyle(Theme.violet)
                        }
                        Spacer()
                        EvidenceBadge(status: e.evidence)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).card()
    }
}

struct PersonPicker: View {
    @EnvironmentObject var model: AppModel
    let title: String
    @Binding var selection: String?
    @State private var query = ""

    var body: some View {
        let people = model.tree.activePersons
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { ($0.surname, $0.given) < ($1.surname, $1.given) }
            .prefix(200)
        List(Array(people)) { p in
            Button {
                selection = p.id
            } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(p.name)
                        Text(p.lifespan).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selection == p.id { Image(systemName: "checkmark").foregroundStyle(Theme.gold) }
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle(title)
    }
}

struct ConnectionFinderView: View {
    @EnvironmentObject var model: AppModel
    @State private var a: String?
    @State private var b: String?
    @State private var result: RelationshipCalculator.Result?

    var body: some View {
        Form {
            Section("Who?") {
                NavigationLink { PersonPicker(title: "First person", selection: $a) } label: {
                    LabeledContent("Person A", value: a.map { model.graph.name($0) } ?? "Choose")
                }
                NavigationLink { PersonPicker(title: "Second person", selection: $b) } label: {
                    LabeledContent("Person B", value: b.map { model.graph.name($0) } ?? "Choose")
                }
            }
            Section {
                Button {
                    if let a, let b { withAnimation { result = model.connection(a, b) } }
                } label: {
                    Text("FIND OUR CONNECTION").font(.headline).frame(maxWidth: .infinity)
                }
                .disabled(a == nil || b == nil)
                .tint(Theme.gold)
            }
            if let r = result, let a, let b {
                Section("Result") {
                    Text(r.kind == .none ? r.relationship : "\(model.graph.name(b)) is \(model.graph.name(a))'s \(r.relationship)")
                        .font(.title3.bold())
                    if r.kind == .marriage { Text("Connected by marriage only — no shared ancestry.").font(.caption) }
                    if let p = r.primary {
                        if let d = p.cousinDegree, let rm = p.removed {
                            LabeledContent("Cousin degree", value: "\(d)")
                            LabeledContent("Times removed", value: "\(rm)")
                        }
                        if !p.commonAncestors.isEmpty {
                            LabeledContent("Common ancestors", value: p.commonAncestors.map { model.graph.name($0) }.joined(separator: " & "))
                        }
                        HStack {
                            Text("Evidence")
                            Spacer()
                            EvidenceBadge(status: p.weakestEvidence)
                        }
                        if p.uncertain {
                            Label("This path depends on unverified or disputed records.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        Text(p.explanation).font(.callout)
                    }
                }
                if r.paths.count > 1 {
                    Section("Other relationship paths") {
                        ForEach(r.paths.dropFirst(), id: \.self) { p in
                            VStack(alignment: .leading) {
                                Text(p.relationship).bold()
                                Text(p.explanation).font(.caption)
                            }
                        }
                    }
                }
                Section { Text("Open the World Tree tab to see this path glowing on the graph.").font(.caption) }
            }
        }
        .navigationTitle("Relationship Pathfinder")
        .onAppear { if a == nil { a = model.tree.homePersonID } }
    }
}
