import Foundation

/// Relationship Pathfinder. Blood relationships come from lowest common ancestors
/// (cousin degree = min(gA, gB) - 1, removal = |gA - gB|). Marriage links are never
/// treated as shared ancestry and are used only when no blood/adoptive path exists.
public enum RelationshipCalculator {
    public enum Kind: String, Codable, Sendable { case selfPerson = "self", blood, adoptive, marriage, none }

    public struct PathResult: Codable, Hashable, Sendable {
        public var relationship: String
        public var generationsA: Int?
        public var generationsB: Int?
        public var cousinDegree: Int?
        public var removed: Int?
        public var half: Bool
        public var commonAncestors: [String]
        public var path: [String]
        public var explanation: String
        public var weakestEvidence: EvidenceStatus
        public var uncertain: Bool
    }

    public struct Result: Codable, Hashable, Sendable {
        public var kind: Kind
        public var relationship: String
        public var paths: [PathResult]
        public var primary: PathResult? { paths.first }
    }

    public static let noConnection = "NO VERIFIED CONNECTION FOUND — RESEARCH CONTINUES"

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        if (10...20).contains(n % 100) { suffix = "th" } else {
            switch n % 10 { case 1: suffix = "st"; case 2: suffix = "nd"; case 3: suffix = "rd"; default: suffix = "th" }
        }
        return "\(n)\(suffix)"
    }

    static func times(_ n: Int) -> String { n == 1 ? "once" : n == 2 ? "twice" : "\(n) times" }

    static func gendered(_ sex: Sex, _ m: String, _ f: String, _ n: String) -> String {
        sex == .M ? m : sex == .F ? f : n
    }

    static func greats(_ n: Int, _ base: String) -> String {
        n <= 0 ? base : n == 1 ? "great-\(base)" : "\(ordinal(n)) great-\(base)"
    }

    /// What B is to A, given generations from A and from B up to the common ancestor.
    public static func label(gA: Int, gB: Int, sexB: Sex = .U, half: Bool = false) -> String {
        let h = half ? "half-" : ""
        if gA == 0 && gB == 0 { return "same person" }
        if gB == 0 {
            let base = gendered(sexB, "father", "mother", "parent")
            return gA == 1 ? base : greats(gA - 2, "grand" + base)
        }
        if gA == 0 {
            let base = gendered(sexB, "son", "daughter", "child")
            return gB == 1 ? base : greats(gB - 2, "grand" + base)
        }
        if gA == 1 && gB == 1 { return h + gendered(sexB, "brother", "sister", "sibling") }
        if gB == 1 { return h + greats(gA - 2, gendered(sexB, "uncle", "aunt", "aunt/uncle")) }
        if gA == 1 { return h + greats(gB - 2, gendered(sexB, "nephew", "niece", "niece/nephew")) }
        let degree = min(gA, gB) - 1, removed = abs(gA - gB)
        return "\(h)\(ordinal(degree)) cousin" + (removed > 0 ? " \(times(removed)) removed" : "")
    }

    static func ancestorPaths(_ g: TreeGraph, _ start: String, allowAdopted: Bool) -> [String: [String]] {
        var paths: [String: [String]] = [start: [start]]
        var queue = [start]
        var i = 0
        while i < queue.count {
            let cur = queue[i]; i += 1
            for e in g.parents[cur] ?? [] where (e.pedigree.isBiological || (allowAdopted && e.pedigree == .adopted)) {
                if paths[e.other] == nil {
                    paths[e.other] = paths[cur]! + [e.other]
                    queue.append(e.other)
                }
            }
        }
        return paths
    }

    static func edgeEvidence(_ g: TreeGraph, _ x: String, _ y: String) -> EvidenceStatus {
        let all = (g.parents[x] ?? []) + (g.children[x] ?? []) + (g.spouses[x] ?? [])
        return all.first { $0.other == y }?.evidence ?? .candidate
    }

    static func evidence(_ g: TreeGraph, _ path: [String]) -> (EvidenceStatus, Bool) {
        var worst = EvidenceStatus.verified
        for (x, y) in zip(path, path.dropFirst()) {
            let s = edgeEvidence(g, x, y)
            if s.rank < worst.rank { worst = s }
        }
        return (worst, worst.rank < 5)
    }

    static func stepText(_ g: TreeGraph, _ x: String, _ y: String) -> String {
        let sex = g.persons[y]?.sex ?? .U
        let rel: String
        if let e = g.parents[x]?.first(where: { $0.other == y }) {
            let base = gendered(sex, "father", "mother", "parent")
            rel = e.pedigree == .adopted ? "adoptive \(base)" : e.pedigree == .step ? "step-\(base)" : base
        } else if g.children[x]?.contains(where: { $0.other == y }) == true {
            rel = gendered(sex, "son", "daughter", "child")
        } else {
            rel = gendered(sex, "husband", "wife", "spouse")
        }
        return "\(g.name(x))'s \(rel) is \(g.name(y))"
    }

    public static func explain(_ g: TreeGraph, _ path: [String]) -> String {
        guard path.count > 1 else { return "" }
        return zip(path, path.dropFirst()).map { stepText(g, $0.0, $0.1) }.joined(separator: "; ") + "."
    }

    static func blood(_ g: TreeGraph, _ a: String, _ b: String, allowAdopted: Bool) -> [PathResult] {
        let pa = ancestorPaths(g, a, allowAdopted: allowAdopted)
        let pb = ancestorPaths(g, b, allowAdopted: allowAdopted)
        let common = Set(pa.keys).intersection(pb.keys)
        guard !common.isEmpty else { return [] }
        func allowed(_ e: TreeGraph.Edge) -> Bool { e.pedigree.isBiological || (allowAdopted && e.pedigree == .adopted) }
        // If c sat above another common ancestor, the child of c on that line would be common too.
        let lowest = common.filter { c in !(g.children[c] ?? []).contains { common.contains($0.other) && allowed($0) } }
        var groups: [[Int]: [String]] = [:]
        for c in lowest { groups[[pa[c]!.count - 1, pb[c]!.count - 1], default: []].append(c) }
        var results: [PathResult] = []
        for key in groups.keys.sorted(by: { ($0[0] + $0[1], $0[0]) < ($1[0] + $1[1], $1[0]) }) {
            let cas = groups[key]!.sorted()
            let gA = key[0], gB = key[1]
            let couple = cas.count >= 2 && cas.contains { c in (g.spouses[c] ?? []).contains { cas.contains($0.other) } }
            let ca = cas[0]
            var half = false
            if gA > 0 && gB > 0 && !couple {
                let ka = pa[ca]![pa[ca]!.count - 2], kb = pb[ca]![pb[ca]!.count - 2]
                let oa = Set((g.parents[ka] ?? []).filter(allowed).map(\.other)).subtracting([ca])
                let ob = Set((g.parents[kb] ?? []).filter(allowed).map(\.other)).subtracting([ca])
                half = !oa.isEmpty && !ob.isEmpty && oa.isDisjoint(with: ob)
            }
            let path = pa[ca]! + Array(pb[ca]!.reversed().dropFirst())
            let (worst, uncertain) = evidence(g, path)
            let cousin = gA >= 2 && gB >= 2
            results.append(PathResult(
                relationship: label(gA: gA, gB: gB, sexB: g.persons[b]?.sex ?? .U, half: half),
                generationsA: gA, generationsB: gB,
                cousinDegree: cousin ? min(gA, gB) - 1 : nil, removed: cousin ? abs(gA - gB) : nil,
                half: half, commonAncestors: cas, path: path, explanation: explain(g, path),
                weakestEvidence: worst, uncertain: uncertain))
        }
        return results
    }

    static func shortestAny(_ g: TreeGraph, _ a: String, _ b: String) -> [String]? {
        var prev: [String: String] = [:]
        var seen: Set<String> = [a]
        var queue = [a]
        var i = 0
        while i < queue.count {
            let cur = queue[i]; i += 1
            if cur == b { break }
            for e in (g.parents[cur] ?? []) + (g.children[cur] ?? []) + (g.spouses[cur] ?? []) where !seen.contains(e.other) {
                seen.insert(e.other)
                prev[e.other] = cur
                queue.append(e.other)
            }
        }
        guard seen.contains(b) else { return nil }
        var path = [b]
        var cur = b
        while let p = prev[cur] { path.append(p); cur = p }
        return path.reversed()
    }

    static func marriage(_ g: TreeGraph, _ a: String, _ b: String) -> PathResult? {
        guard let path = shortestAny(g, a, b) else { return nil }
        let sexB = g.persons[b]?.sex ?? .U
        var spouseIdx: [Int] = []
        for i in 0..<(path.count - 1) where (g.spouses[path[i]] ?? []).contains(where: { $0.other == path[i + 1] }) {
            spouseIdx.append(i)
        }
        var rel = "relative by marriage"
        if spouseIdx.count == 1 {
            let i = spouseIdx[0]
            let c = path[i], d = path[i + 1]
            if c == a && d == b {
                rel = gendered(sexB, "husband", "wife", "spouse")
            } else if c == a {
                let inner = blood(g, d, b, allowAdopted: false).first?.relationship ?? ""
                let map = ["father": "father-in-law", "mother": "mother-in-law", "parent": "parent-in-law",
                           "brother": "brother-in-law", "sister": "sister-in-law", "sibling": "sibling-in-law",
                           "son": "stepson", "daughter": "stepdaughter", "child": "stepchild"]
                rel = map[inner] ?? (inner.isEmpty ? rel : "spouse's \(inner)")
            } else if d == b {
                let inner = blood(g, a, c, allowAdopted: false).first?.relationship ?? ""
                if ["father", "mother", "parent"].contains(inner) {
                    rel = gendered(sexB, "stepfather", "stepmother", "step-parent")
                } else if inner.hasSuffix("brother") || inner.hasSuffix("sister") || inner.hasSuffix("sibling") {
                    rel = gendered(sexB, "brother-in-law", "sister-in-law", "sibling-in-law")
                } else if ["son", "daughter", "child"].contains(inner) {
                    rel = gendered(sexB, "son-in-law", "daughter-in-law", "child-in-law")
                } else if !inner.isEmpty {
                    rel = "spouse of \(inner)"
                }
            }
        }
        let (worst, uncertain) = evidence(g, path)
        return PathResult(relationship: rel, generationsA: nil, generationsB: nil, cousinDegree: nil, removed: nil,
                          half: false, commonAncestors: [], path: path, explanation: explain(g, path),
                          weakestEvidence: worst, uncertain: uncertain)
    }

    public static func findConnection(_ g: TreeGraph, _ a: String, _ b: String) -> Result {
        guard g.persons[a] != nil, g.persons[b] != nil else { return Result(kind: .none, relationship: noConnection, paths: []) }
        if a == b { return Result(kind: .selfPerson, relationship: "same person", paths: []) }
        let bl = blood(g, a, b, allowAdopted: false)
        if let first = bl.first { return Result(kind: .blood, relationship: first.relationship, paths: bl) }
        var ad = blood(g, a, b, allowAdopted: true)
        if !ad.isEmpty {
            for i in ad.indices { ad[i].relationship = "adoptive " + ad[i].relationship }
            return Result(kind: .adoptive, relationship: ad[0].relationship, paths: ad)
        }
        if let m = marriage(g, a, b) { return Result(kind: .marriage, relationship: m.relationship, paths: [m]) }
        return Result(kind: .none, relationship: noConnection, paths: [])
    }
}
