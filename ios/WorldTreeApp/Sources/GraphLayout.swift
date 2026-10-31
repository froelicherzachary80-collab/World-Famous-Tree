import CoreGraphics
import Foundation
import WorldTreeCore

/// One node in the Family Multiverse graph: local tree people plus research people from the server.
struct GraphNode: Identifiable, Hashable {
    let id: String
    let name: String
    let birthYear: Int?
    let universes: [String]
    let evidence: EvidenceStatus
    let isPublic: Bool
    let isLiving: Bool
    var generation = 0
    var position: CGPoint = .zero
}

struct GraphEdge: Hashable {
    let from: String
    let to: String
    let isSpouse: Bool
    let evidence: EvidenceStatus
}

struct GraphModel {
    var nodes: [String: GraphNode] = [:]
    var edges: [GraphEdge] = []
    var bounds: CGRect = .zero

    static let rowHeight: CGFloat = 150
    static let colWidth: CGFloat = 120

    /// Build from the local tree and (optionally) the research server graph.
    /// Shared identities (same id) collapse into one canonical node.
    init(tree: FamilyTree, remote: RemoteGraph?) {
        let g = TreeGraph(tree)
        for p in g.persons.values {
            nodes[p.id] = GraphNode(id: p.id, name: p.name, birthYear: p.birthYear, universes: Array(p.universes),
                                    evidence: p.evidence, isPublic: p.isPublicFigure, isLiving: p.isPresumedLiving())
        }
        for r in tree.relationships where r.evidence != .rejected && nodes[r.a] != nil && nodes[r.b] != nil {
            edges.append(GraphEdge(from: r.a, to: r.b, isSpouse: r.kind == .spouse, evidence: r.evidence))
        }
        if let remote {
            for n in remote.nodes where nodes[n.id] == nil {
                nodes[n.id] = GraphNode(id: n.id, name: n.name, birthYear: n.birthYear, universes: n.universes,
                                        evidence: EvidenceStatus(rawValue: n.evidence) ?? .candidate,
                                        isPublic: n.public, isLiving: n.living)
            }
            let existing = Set(edges.map { "\($0.from)>\($0.to)" })
            for e in remote.edges where nodes[e.from] != nil && nodes[e.to] != nil && !existing.contains("\(e.from)>\(e.to)") {
                edges.append(GraphEdge(from: e.from, to: e.to, isSpouse: e.kind == "spouse",
                                       evidence: EvidenceStatus(rawValue: e.evidence) ?? .candidate))
            }
        }
        layout()
    }

    /// Generational layered layout: generation = 1 + max(parent generation); spouses share a row;
    /// order within a row by barycenter of parents (two sweeps). O(n + e).
    mutating func layout() {
        var parents: [String: [String]] = [:]
        var spouses: [String: [String]] = [:]
        for e in edges {
            if e.isSpouse { spouses[e.from, default: []].append(e.to); spouses[e.to, default: []].append(e.from) }
            else { parents[e.to, default: []].append(e.from) }
        }
        var gen: [String: Int] = [:]
        var visiting = Set<String>()
        func depth(_ id: String) -> Int {
            if let g = gen[id] { return g }
            if visiting.contains(id) { return 0 }   // cycle guard for bad data
            visiting.insert(id)
            let d = (parents[id] ?? []).map { depth($0) + 1 }.max() ?? 0
            visiting.remove(id)
            gen[id] = d
            return d
        }
        for id in nodes.keys { _ = depth(id) }
        for (a, list) in spouses { for b in list { let m = max(gen[a] ?? 0, gen[b] ?? 0); gen[a] = m; gen[b] = m } }

        var rows: [Int: [String]] = [:]
        for (id, g) in gen { rows[g, default: []].append(id) }
        var xPos: [String: CGFloat] = [:]
        let sortedGens = rows.keys.sorted()
        for sweep in 0..<2 {
            for g in sortedGens {
                var row = rows[g]!
                if sweep == 0 && g == sortedGens.first {
                    row.sort { (nodes[$0]?.birthYear ?? 0, $0) < (nodes[$1]?.birthYear ?? 0, $1) }
                } else {
                    func bary(_ id: String) -> CGFloat {
                        let ps = (parents[id] ?? []).compactMap { xPos[$0] }
                        if !ps.isEmpty { return ps.reduce(0, +) / CGFloat(ps.count) }
                        let sp = (spouses[id] ?? []).compactMap { xPos[$0] }
                        return sp.first.map { $0 + 0.5 } ?? xPos[id] ?? 0
                    }
                    row.sort { (bary($0), $0) < (bary($1), $1) }
                }
                let width = CGFloat(row.count - 1) * Self.colWidth
                for (i, id) in row.enumerated() { xPos[id] = CGFloat(i) * Self.colWidth - width / 2 }
                rows[g] = row
            }
        }
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        for (id, x) in xPos {
            let y = CGFloat(gen[id] ?? 0) * Self.rowHeight
            nodes[id]?.generation = gen[id] ?? 0
            nodes[id]?.position = CGPoint(x: x, y: y)
            minX = min(minX, x); maxX = max(maxX, x)
        }
        let maxGen = CGFloat(sortedGens.last ?? 0)
        bounds = nodes.isEmpty ? .zero : CGRect(x: minX, y: 0, width: maxX - minX, height: maxGen * Self.rowHeight)
    }
}
