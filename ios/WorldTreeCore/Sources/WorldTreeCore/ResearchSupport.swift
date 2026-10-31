import Foundation

/// Research-gap analysis for the user's own tree.
public enum GapAnalyzer {
    public struct Gaps: Sendable {
        public var missingParents: [Person]
        public var missingBirth: [Person]
        public var unsourced: [Person]
        public var recommendedGoals: [String]
    }

    public static func analyze(_ tree: FamilyTree) -> Gaps {
        let g = TreeGraph(tree)
        let mine = g.persons.values.filter { $0.universes.contains("my_family") }
        let deceased = mine.filter { !$0.isPresumedLiving() }
        let missingParents = deceased.filter { (g.parents[$0.id] ?? []).count < 2 }
            .sorted { ($0.birthYear ?? Int.max) < ($1.birthYear ?? Int.max) }
        let missingBirth = deceased.filter { $0.birthYear == nil }
        let unsourced = mine.filter { $0.citations.isEmpty }
        var goals: [String] = []
        if !missingParents.isEmpty { goals.append("Reconstruct missing branches for my end-of-line ancestors") }
        goals += ["Find my possible family connections to Minecraft YouTubers",
                  "Research Young Hollywood actors and find connections to my GEDCOM family tree",
                  "Explore royal family connections"]
        return Gaps(missingParents: missingParents, missingBirth: missingBirth, unsourced: unsourced, recommendedGoals: goals)
    }
}

/// Timeline Researcher: chronological contradictions between a parent and child.
public enum TimelineChecker {
    public static func issues(parent: Person, child: Person) -> [String] {
        var out: [String] = []
        if let pb = parent.birthYear, let pd = parent.deathYear, pd < pb { out.append("\(parent.name) died before being born") }
        if let pb = parent.birthYear, let cb = child.birthYear {
            if cb - pb < 12 { out.append("parent only \(cb - pb) years older than child") }
            if cb - pb > 75 { out.append("parent \(cb - pb) years older than child") }
        }
        if let pd = parent.deathYear, let cb = child.birthYear, cb > pd + (parent.sex == .M ? 1 : 0) {
            out.append("child born \(cb - pd) years after parent's death")
        }
        return out
    }

    public static func scan(_ tree: FamilyTree) -> [(Relationship, [String])] {
        tree.relationships.compactMap { r -> (Relationship, [String])? in
            guard r.kind == .parent, let p = tree.persons[r.a], let c = tree.persons[r.b] else { return nil }
            let i = issues(parent: p, child: c)
            return i.isEmpty ? nil : (r, i)
        }
    }
}

/// Raw consumer DNA file parser (23andMe / AncestryDNA). Parses locally only.
/// It does NOT perform relative matching: that needs a consented matching dataset.
public enum RawDNAParser {
    public struct Summary: Codable, Sendable {
        public var format: String
        public var snpCount: Int
        public var noCalls: Int
        public var chromosomes: [String: Int]
    }

    public static func parse(_ text: String) throws -> Summary {
        var format = "unknown"
        var snps = 0, noCalls = 0
        var chroms: [String: Int] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#") {
                if line.localizedCaseInsensitiveContains("23andMe") { format = "23andMe" }
                if line.localizedCaseInsensitiveContains("AncestryDNA") { format = "AncestryDNA" }
                continue
            }
            let cols = line.split(whereSeparator: { $0 == "\t" || $0 == "," }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
            guard cols.count >= 4, cols[0].lowercased().hasPrefix("rs") || cols[0].lowercased().hasPrefix("i") else { continue }
            let genotype = cols.count >= 5 ? cols[3] + cols[4] : cols[3]
            snps += 1
            chroms[cols[1], default: 0] += 1
            if genotype.contains("-") || genotype.contains("0") { noCalls += 1 }
        }
        guard snps > 0 else { throw NSError(domain: "RawDNA", code: 1, userInfo: [NSLocalizedDescriptionKey: "No genotype rows found"]) }
        return Summary(format: format, snpCount: snps, noCalls: noCalls, chromosomes: chroms)
    }
}
