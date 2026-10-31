import SwiftUI
import WorldTreeCore

/// The Family Multiverse: pinch-zoom/pan graph rendered with Canvas (Metal-backed via drawingGroup),
/// viewport culling + level-of-detail labels for large trees.
struct WorldTreeGraphView: View {
    @EnvironmentObject var model: AppModel
    @State private var graph = GraphModel(tree: FamilyTree(), remote: nil)
    @State private var scale: CGFloat = 0.8
    @State private var baseScale: CGFloat = 0.8
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var selected: String?
    @State private var search = ""
    @State private var showFilters = false
    @State private var hiddenUniverses: Set<String> = []
    @State private var centuryRange: ClosedRange<Double> = -40...21
    @State private var collapsed: Set<String> = []
    @State private var includeResearch = true

    private var visibleIDs: Set<String> {
        var hidden = Set<String>()
        // Collapsed subtrees: hide all descendants of collapsed nodes.
        var kids: [String: [String]] = [:]
        for e in graph.edges where !e.isSpouse { kids[e.from, default: []].append(e.to) }
        var stack = Array(collapsed)
        while let c = stack.popLast() {
            for k in kids[c] ?? [] where !hidden.contains(k) { hidden.insert(k); stack.append(k) }
        }
        return Set(graph.nodes.values.filter { n in
            if hidden.contains(n.id) { return false }
            if !n.universes.isEmpty && n.universes.allSatisfy({ hiddenUniverses.contains($0) }) { return false }
            if let y = n.birthYear {
                let century = Double(y) / 100
                if century < centuryRange.lowerBound || century > centuryRange.upperBound { return false }
            }
            return true
        }.map(\.id))
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Theme.background.ignoresSafeArea()
                if graph.nodes.isEmpty {
                    ContentUnavailableView("Your World Tree is empty", systemImage: "tree",
                                           description: Text("Import a GEDCOM file from the Profile tab to grow your tree."))
                        .foregroundStyle(.white)
                } else {
                    canvas
                    if let s = selected, let n = graph.nodes[s] { selectionCard(n) }
                }
            }
            .navigationTitle("World Tree")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.night, for: .navigationBar)
            .searchable(text: $search, prompt: "Search people")
            .onSubmit(of: .search) { focusSearch() }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { withAnimation(.spring) { scale = 0.8; baseScale = 0.8; offset = .zero; baseOffset = .zero } } label: {
                        Image(systemName: "scope")
                    }.accessibilityLabel("Reset view")
                    Button { showFilters = true } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                        .accessibilityLabel("Filters")
                }
            }
            .sheet(isPresented: $showFilters) { filters.presentationDetents([.medium]) }
            .task { await rebuild() }
            .onChange(of: model.tree.persons.count) { _, _ in Task { await rebuild() } }
            .onChange(of: model.tree.relationships.count) { _, _ in Task { await rebuild() } }
            .onChange(of: includeResearch) { _, _ in Task { await rebuild() } }
        }
    }

    private func rebuild() async {
        if includeResearch { await model.refreshGraphAndConnectors() }
        let tree = model.tree
        let remote = includeResearch ? model.remoteGraph : nil
        let built = await Task.detached(priority: .userInitiated) { GraphModel(tree: tree, remote: remote) }.value
        withAnimation(.easeInOut(duration: 0.6)) { graph = built }
        if let home = model.tree.homePersonID, offset == .zero { center(on: home, animated: false) }
    }

    private func focusSearch() {
        let q = search.lowercased()
        if let hit = graph.nodes.values.filter({ $0.name.lowercased().contains(q) }).min(by: { $0.name.count < $1.name.count }) {
            selected = hit.id
            center(on: hit.id, animated: true)
        }
    }

    private func center(on id: String, animated: Bool) {
        guard let p = graph.nodes[id]?.position else { return }
        let target = CGSize(width: -p.x * scale, height: -p.y * scale)
        if animated { withAnimation(.spring(duration: 0.6)) { offset = target } } else { offset = target }
        baseOffset = target
    }

    private func screen(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: p.x * scale + offset.width + size.width / 2, y: p.y * scale + offset.height + size.height / 2)
    }

    private var canvas: some View {
        GeometryReader { geo in
            let visible = visibleIDs
            let path = model.highlightedPath
            let pathEdges = Set(zip(path, path.dropFirst()).flatMap { ["\($0.0)>\($0.1)", "\($0.1)>\($0.0)"] })
            TimelineView(.animation(minimumInterval: 1 / 30, paused: path.isEmpty)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate
                Canvas { ctx, size in
                    let viewport = CGRect(origin: .zero, size: size).insetBy(dx: -80, dy: -80)
                    // Edges
                    for e in graph.edges where visible.contains(e.from) && visible.contains(e.to) {
                        guard let a = graph.nodes[e.from]?.position, let b = graph.nodes[e.to]?.position else { continue }
                        let pa = screen(a, size), pb = screen(b, size)
                        if !viewport.contains(pa) && !viewport.contains(pb) { continue }
                        var p = Path()
                        p.move(to: pa)
                        if e.isSpouse { p.addLine(to: pb) } else {
                            let midY = (pa.y + pb.y) / 2
                            p.addCurve(to: pb, control1: CGPoint(x: pa.x, y: midY), control2: CGPoint(x: pb.x, y: midY))
                        }
                        let onPath = pathEdges.contains("\(e.from)>\(e.to)")
                        if onPath {
                            let glow = 0.6 + 0.4 * sin(phase * 3)
                            var g = ctx
                            g.addFilter(.shadow(color: Theme.gold.opacity(glow), radius: 10))
                            g.stroke(p, with: .color(Theme.gold), lineWidth: 4)
                        } else {
                            let dash: [CGFloat] = e.evidence.rank < 4 ? [5, 5] : []
                            ctx.stroke(p, with: .color((e.isSpouse ? Theme.violet : Theme.sky).opacity(0.45)),
                                       style: StrokeStyle(lineWidth: e.isSpouse ? 1.2 : 1.5, dash: dash))
                        }
                    }
                    // Nodes
                    let showLabels = scale > 0.45
                    let r: CGFloat = max(4, 14 * min(scale, 1.4))
                    for n in graph.nodes.values where visible.contains(n.id) {
                        let c = screen(n.position, size)
                        guard viewport.contains(c) else { continue }
                        let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                        let fill = Theme.color(forUniverses: n.universes)
                        if n.universes.count > 1 || n.isPublic {
                            var g = ctx
                            g.addFilter(.shadow(color: fill.opacity(0.8), radius: 8))
                            g.fill(Path(ellipseIn: rect), with: .color(fill))
                        } else {
                            ctx.fill(Path(ellipseIn: rect), with: .color(fill.opacity(n.isLiving ? 0.55 : 0.95)))
                        }
                        let ring = Theme.color(for: n.evidence)
                        ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(ring),
                                   style: StrokeStyle(lineWidth: n.id == selected || path.contains(n.id) ? 3 : 1.5,
                                                      dash: n.evidence.rank < 4 ? [3, 3] : []))
                        if collapsed.contains(n.id) {
                            ctx.draw(Text("+").font(.caption.bold()).foregroundStyle(.white), at: c)
                        }
                        if showLabels {
                            let label = n.isLiving && !n.isPublic ? "Living" : n.name
                            ctx.draw(Text(label).font(.system(size: 11 * min(max(scale, 0.8), 1.3), weight: .semibold))
                                        .foregroundStyle(.white), at: CGPoint(x: c.x, y: c.y + r + 10))
                            if let y = n.birthYear, scale > 0.8 {
                                ctx.draw(Text(GenDate.formatYear(y)).font(.system(size: 9)).foregroundStyle(.white.opacity(0.6)),
                                         at: CGPoint(x: c.x, y: c.y + r + 23))
                            }
                        }
                    }
                }
                .drawingGroup()   // rasterize through Metal
            }
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .onChanged { v in scale = min(4, max(0.08, baseScale * v)) }
                        .onEnded { _ in baseScale = scale },
                    DragGesture(minimumDistance: 4)
                        .onChanged { v in offset = CGSize(width: baseOffset.width + v.translation.width,
                                                          height: baseOffset.height + v.translation.height) }
                        .onEnded { _ in baseOffset = offset }
                )
            )
            .simultaneousGesture(SpatialTapGesture().onEnded { v in select(at: v.location, size: geo.size) })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Family graph with \(visible.count) people. Use search to find someone.")
        }
    }

    private func select(at point: CGPoint, size: CGSize) {
        let hit = graph.nodes.values.min { a, b in
            dist(screen(a.position, size), point) < dist(screen(b.position, size), point)
        }
        if let hit, dist(screen(hit.position, size), point) < 30 { withAnimation { selected = hit.id } }
        else { withAnimation { selected = nil } }
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private func selectionCard(_ n: GraphNode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading) {
                    Text(n.isLiving && !n.isPublic ? "Living person (private)" : n.name).font(.headline).foregroundStyle(.white)
                    Text(n.birthYear.map { "Born \(GenDate.formatYear($0))" } ?? "Birth unknown")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                EvidenceBadge(status: n.evidence)
            }
            HStack {
                if model.tree.persons[n.id] != nil {
                    NavigationLink("Profile") { PersonDetailView(personID: n.id) }
                    Button("Set as me") { model.setHome(n.id) }
                }
                Button(collapsed.contains(n.id) ? "Expand" : "Collapse") {
                    withAnimation { if collapsed.contains(n.id) { collapsed.remove(n.id) } else { collapsed.insert(n.id) } }
                }
                if let home = model.tree.homePersonID, home != n.id, model.tree.persons[n.id] != nil {
                    Button("Find our connection") { _ = model.connection(home, n.id) }
                }
            }
            .buttonStyle(.bordered).tint(Theme.gold).font(.caption)
        }
        .card()
        .padding()
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var filters: some View {
        NavigationStack {
            Form {
                Section("Research universes") {
                    ForEach(Theme.universeColors.keys.sorted(), id: \.self) { u in
                        Toggle(isOn: Binding(get: { !hiddenUniverses.contains(u) },
                                             set: { on in if on { hiddenUniverses.remove(u) } else { hiddenUniverses.insert(u) } })) {
                            Label(u.replacingOccurrences(of: "_", with: " ").capitalized, systemImage: "circle.fill")
                                .foregroundStyle(Theme.universeColors[u]!)
                        }
                    }
                    Toggle("Include research-server people", isOn: $includeResearch)
                }
                Section("Timeline (by century of birth)") {
                    HStack {
                        Text(GenDate.formatYear(Int(centuryRange.lowerBound * 100)))
                        Spacer()
                        Text(GenDate.formatYear(Int(centuryRange.upperBound * 100)))
                    }.font(.caption.monospacedDigit())
                    Slider(value: Binding(get: { centuryRange.lowerBound },
                                          set: { centuryRange = min($0, centuryRange.upperBound - 1)...centuryRange.upperBound }),
                           in: -40...20, step: 1) { Text("From") }
                    Slider(value: Binding(get: { centuryRange.upperBound },
                                          set: { centuryRange = centuryRange.lowerBound...max($0, centuryRange.lowerBound + 1) }),
                           in: -39...21, step: 1) { Text("To") }
                }
                Section("Generations") {
                    Button("Expand all") { collapsed = [] }
                    if !model.highlightedPath.isEmpty { Button("Clear highlighted path") { model.highlightedPath = [] } }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
