import Foundation

/// Duplicate detection, reversible merging and strict auto-merge rules.
/// A shared name alone can never produce a reviewable candidate.
public enum DuplicateDetector {
    public struct Candidate: Codable, Hashable, Identifiable, Sendable {
        public var a: String
        public var b: String
        public var score: Double
        public var matches: [String]
        public var conflicts: [String]
        public var id: String { "\(a)|\(b)" }
        public var corroborations: Int { matches.filter { !$0.hasPrefix("name") }.count }
    }

    public struct AutoMergeRules: Codable, Sendable {
        public var enabled = false
        public var minScore = 0.95
        public var minCorroborations = 3
        public init(enabled: Bool = false, minScore: Double = 0.95, minCorroborations: Int = 3) {
            self.enabled = enabled; self.minScore = minScore; self.minCorroborations = minCorroborations
        }
    }

    public static func normalize(_ s: String?) -> String {
        let folded = (s ?? "").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
        return String(folded.lowercased().unicodeScalars.filter { CharacterSet.lowercaseLetters.contains($0) || $0 == " " }
            .map(Character.init)).trimmingCharacters(in: .whitespaces)
    }

    public static func soundex(_ s: String) -> String {
        let chars = Array(normalize(s).replacingOccurrences(of: " ", with: ""))
        guard let first = chars.first else { return "" }
        func code(_ c: Character) -> Character? {
            switch c {
            case "b", "f", "p", "v": return "1"
            case "c", "g", "j", "k", "q", "s", "x", "z": return "2"
            case "d", "t": return "3"
            case "l": return "4"
            case "m", "n": return "5"
            case "r": return "6"
            default: return nil
            }
        }
        var out = String(first).uppercased()
        var last = code(first)
        for c in chars.dropFirst() {
            let k = code(c)
            if let k, k != last { out.append(k) }
            if c != "h" && c != "w" { last = k }
        }
        return String((out + "000").prefix(4))
    }

    public static func jaroWinkler(_ s1: String, _ s2: String) -> Double {
        let a = Array(normalize(s1)), b = Array(normalize(s2))
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }
        let md = max(0, max(a.count, b.count) / 2 - 1)
        var am = [Bool](repeating: false, count: a.count), bm = [Bool](repeating: false, count: b.count)
        var m = 0
        for i in 0..<a.count {
            let lo = max(0, i - md), hi = min(b.count, i + md + 1)
            if lo >= hi { continue }
            for j in lo..<hi where !bm[j] && b[j] == a[i] {
                am[i] = true; bm[j] = true; m += 1
                break
            }
        }
        if m == 0 { return 0 }
        var t = 0, k = 0
        for i in 0..<a.count where am[i] {
            while !bm[k] { k += 1 }
            if a[i] != b[k] { t += 1 }
            k += 1
        }
        let md2 = Double(m)
        let jaro = (md2 / Double(a.count) + md2 / Double(b.count) + (md2 - Double(t) / 2) / md2) / 3
        var p = 0
        for (x, y) in zip(a.prefix(4), b.prefix(4)) { if x != y { break }; p += 1 }
        return jaro + Double(p) * 0.1 * (1 - jaro)
    }

    static func names(_ p: Person) -> [String] {
        ["\(p.given) \(p.surname)"] + p.altNames.map { "\($0.given) \($0.surname)" }
    }

    static func relNames(_ g: TreeGraph, _ id: String, _ edges: [String: [TreeGraph.Edge]]) -> Set<String> {
        Set((edges[id] ?? []).map { normalize(g.name($0.other)) })
    }

    public static func score(_ g: TreeGraph, _ a: String, _ b: String) -> Candidate {
        let pa = g.persons[a]!, pb = g.persons[b]!
        var c = Candidate(a: a, b: b, score: 0, matches: [], conflicts: [])
        var best = 0.0
        for x in names(pa) { for y in names(pb) { best = max(best, jaroWinkler(x, y)) } }
        if best >= 0.97 { c.matches.append("name: exact/near-exact") }
        else if best >= 0.88 { c.matches.append(String(format: "name: similar (%.2f)", best)) }
        else { return c }
        var s = 0.35 * best
        if pa.sex != .U && pb.sex != .U && pa.sex != pb.sex { c.conflicts.append("sex differs"); s -= 0.4 }
        for (ya, yb, label) in [(pa.birthYear, pb.birthYear, "birth year"), (pa.deathYear, pb.deathYear, "death year")] {
            guard let ya, let yb else { continue }
            if ya == yb { c.matches.append("\(label) identical (\(ya))"); s += 0.2 }
            else if abs(ya - yb) <= 2 { c.matches.append("\(label) within 2 years"); s += 0.1 }
            else if abs(ya - yb) > 5 { c.conflicts.append("\(label) differs (\(ya) vs \(yb))"); s -= 0.3 }
        }
        for (x, y, label) in [(pa.birthPlace, pb.birthPlace, "birthplace"), (pa.deathPlace, pb.deathPlace, "death place")] {
            let ta = Set(normalize(x).split(separator: " ")), tb = Set(normalize(y).split(separator: " "))
            guard !ta.isEmpty, !tb.isEmpty else { continue }
            let overlap = Double(ta.intersection(tb).count) / Double(max(1, min(ta.count, tb.count)))
            if overlap >= 0.6 { c.matches.append("\(label) matches"); s += 0.1 }
            else if overlap == 0 { c.conflicts.append("\(label) differs"); s -= 0.05 }
        }
        for (edges, label, w) in [(g.parents, "parents", 0.2), (g.spouses, "spouses", 0.15), (g.children, "children", 0.1)] {
            let na = relNames(g, a, edges), nb = relNames(g, b, edges)
            guard !na.isEmpty, !nb.isEmpty else { continue }
            let shared = na.filter { x in nb.contains { jaroWinkler(x, $0) >= 0.93 } }
            if !shared.isEmpty { c.matches.append("\(label) match (\(shared.count))"); s += w }
        }
        if c.corroborations == 0 { s = min(s, 0.45) }
        c.score = (max(0, min(1, s)) * 1000).rounded() / 1000
        return c
    }

    public static func detect(_ tree: FamilyTree, threshold: Double = 0.55, ignoring: Set<String> = []) -> [Candidate] {
        let g = TreeGraph(tree)
        var blocks: [String: [String]] = [:]
        for (id, p) in g.persons {
            var keys = Set<String>()
            keys.insert(soundex(p.surname) + String(normalize(p.given).prefix(1)))
            for alt in p.altNames { keys.insert(soundex(alt.surname) + String(normalize(alt.given).prefix(1))) }
            for k in keys { blocks[k, default: []].append(id) }
        }
        var seen = Set<String>()
        var out: [Candidate] = []
        for ids in blocks.values where ids.count <= 400 {
            let sorted = ids.sorted()
            for i in 0..<sorted.count {
                for j in (i + 1)..<max(i + 1, sorted.count) {
                    let a = sorted[i], b = sorted[j]
                    let key = "\(a)|\(b)"
                    if seen.contains(key) || ignoring.contains(key) { continue }
                    seen.insert(key)
                    let direct = ((g.parents[a] ?? []) + (g.children[a] ?? []) + (g.spouses[a] ?? [])).contains { $0.other == b }
                    if direct { continue }
                    let c = score(g, a, b)
                    if c.score >= threshold { out.append(c) }
                }
            }
        }
        return out.sorted { $0.score > $1.score }
    }

    public static func autoMergeAllowed(_ c: Candidate, rules: AutoMergeRules) -> Bool {
        rules.enabled && c.score >= rules.minScore && c.conflicts.isEmpty && c.corroborations >= rules.minCorroborations
    }
}

/// A reversible merge: everything needed to restore the tree exactly.
public struct MergeRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var keptID: String
    public var mergedID: String
    public var date: Date
    public var originalRelationships: [Relationship]
    public var newRelationshipIDs: [Int]
    public var keptPersonBefore: Person
}

public extension FamilyTree {
    /// Merge `drop` into `keep`; conflicting facts on `drop` are preserved as alt names / notes.
    @discardableResult
    mutating func merge(keep: String, drop: String) -> MergeRecord? {
        guard let kept = persons[keep], let dropped = persons[drop], keep != drop else { return nil }
        let touched = relationships.filter { $0.a == drop || $0.b == drop }
        relationships.removeAll { $0.a == drop || $0.b == drop }
        var newIDs: [Int] = []
        for r in touched {
            let a = r.a == drop ? keep : r.a
            let b = r.b == drop ? keep : r.b
            if a == b { continue }
            let id: Int
            if r.kind == .parent {
                let before = nextRelationshipID
                id = addParent(a, child: b, pedigree: r.pedigree, evidence: r.evidence, sources: r.sourceIDs)
                if nextRelationshipID != before { newIDs.append(id) }
            } else {
                let before = nextRelationshipID
                id = addSpouse(a, b, ended: r.ended, evidence: r.evidence)
                if nextRelationshipID != before { newIDs.append(id) }
            }
        }
        var k = kept
        k.altNames.append(AltName(given: dropped.given, surname: dropped.surname, type: "merged"))
        k.citations += dropped.citations
        k.universes.formUnion(dropped.universes)
        if k.birth == nil { k.birth = dropped.birth }
        if k.death == nil { k.death = dropped.death }
        if k.birthPlace == nil { k.birthPlace = dropped.birthPlace }
        if let db = dropped.birthYear, let kb = kept.birthYear, db != kb {
            k.notes += (k.notes.isEmpty ? "" : "\n") + "Conflicting birth year from merged record: \(db)"
        }
        persons[keep] = k
        persons[drop]?.mergedInto = keep
        return MergeRecord(id: UUID(), keptID: keep, mergedID: drop, date: Date(), originalRelationships: touched,
                           newRelationshipIDs: newIDs, keptPersonBefore: kept)
    }

    mutating func undo(_ m: MergeRecord) {
        relationships.removeAll { m.newRelationshipIDs.contains($0.id) }
        relationships.append(contentsOf: m.originalRelationships)
        persons[m.keptID] = m.keptPersonBefore
        persons[m.mergedID]?.mergedInto = nil
    }
}
