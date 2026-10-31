import Foundation

/// GEDCOM 5.5 / 5.5.1 / 7.0 parser and importer. Never discards conflicting data:
/// problems are reported as warnings and the remaining records are kept.
public enum GEDCOM {
    final class Node {
        let level: Int
        let tag: String
        var value: String
        let xref: String?
        var children: [Node] = []
        init(level: Int, tag: String, value: String, xref: String?) {
            self.level = level; self.tag = tag; self.value = value; self.xref = xref
        }
        func first(_ tag: String) -> Node? { children.first { $0.tag == tag } }
        func all(_ tag: String) -> [Node] { children.filter { $0.tag == tag } }
        func val(_ tag: String) -> String? {
            guard let v = first(tag)?.value, !v.isEmpty else { return nil }
            return v
        }
    }

    public struct Report: Sendable {
        public var version = "unknown"
        public var people = 0
        public var families = 0
        public var parentLinks = 0
        public var spouseLinks = 0
        public var sources = 0
        public var warnings: [String] = []
        public var errors: [String] = []
        public var isValid: Bool { errors.isEmpty }
    }

    public static func decode(_ data: Data) -> String {
        var d = data
        if d.starts(with: [0xEF, 0xBB, 0xBF]) { d = d.dropFirst(3) }
        if d.starts(with: [0xFF, 0xFE]) || d.starts(with: [0xFE, 0xFF]) {
            return String(data: d, encoding: .utf16) ?? ""
        }
        if let s = String(data: d, encoding: .utf8) { return s }
        return String(data: d, encoding: .isoLatin1) ?? ""   // ANSEL/ANSI fallback
    }

    static func parseLine(_ line: Substring) -> (Int, String?, String, String)? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        var parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let lvlStr = parts.first, let level = Int(lvlStr), parts.count == 2 else { return nil }
        var rest = parts[1]
        var xref: String?
        if rest.hasPrefix("@") {
            parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts[0].hasSuffix("@"), parts[0].count > 2 else { return nil }
            xref = String(parts[0])
            rest = parts.count > 1 ? parts[1] : ""
        }
        let tv = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let tag = tv.first, !tag.isEmpty, tag.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        let value = tv.count > 1 ? String(tv[1]) : ""
        return (level, xref, tag.uppercased(), value)
    }

    static func tokenize(_ text: String, warnings: inout [String]) -> [Node] {
        var roots: [Node] = []
        var stack: [Node] = []
        var lineNo = 0
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            lineNo += 1
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let parsed = parseLine(raw) else {
                warnings.append("line \(lineNo): unparseable line skipped")
                continue
            }
            let (level, xref, tag, value) = parsed
            if tag == "CONT" || tag == "CONC", let parent = stack.last(where: { $0.level == level - 1 }) {
                parent.value += (tag == "CONT" ? "\n" : "") + value
                continue
            }
            let node = Node(level: level, tag: tag, value: value, xref: xref)
            while let last = stack.last, last.level >= level { stack.removeLast() }
            if level == 0 {
                roots.append(node)
            } else if let last = stack.last {
                if last.level != level - 1 { warnings.append("line \(lineNo): level jump; attached to nearest parent") }
                last.children.append(node)
            } else {
                roots.append(node)
            }
            stack.append(node)
        }
        return roots
    }

    static func splitName(_ value: String) -> (String, String) {
        let parts = value.components(separatedBy: "/")
        if parts.count >= 3 {
            let given = (parts[0] + " " + parts[2...].joined(separator: " "))
                .split(separator: " ").joined(separator: " ")
            return (given, parts[1].trimmingCharacters(in: .whitespaces))
        }
        return (value.trimmingCharacters(in: .whitespaces), "")
    }

    static func pedigree(_ s: String?) -> Pedigree {
        switch s?.lowercased() {
        case "adopted": return .adopted
        case "foster": return .foster
        case "step": return .step
        case nil, "", "birth", "sealing": return .birth
        default: return .unknown
        }
    }

    /// Parse and merge a GEDCOM file into `tree`. IDs are namespaced per import ("g1:I23").
    @discardableResult
    public static func importFile(_ data: Data, into tree: inout FamilyTree, universe: String = "my_family") -> Report {
        importText(decode(data), into: &tree, universe: universe)
    }

    @discardableResult
    public static func importText(_ input: String, into tree: inout FamilyTree, universe: String = "my_family") -> Report {
        var report = Report()
        let text = input.hasPrefix("\u{FEFF}") ? String(input.dropFirst()) : input
        let roots = tokenize(text, warnings: &report.warnings)
        if roots.isEmpty { report.errors.append("empty file or no GEDCOM records found"); return report }
        if roots.first?.tag != "HEAD" { report.warnings.append("file does not start with HEAD record") }
        if roots.last?.tag != "TRLR" { report.warnings.append("missing TRLR trailer (file may be truncated)") }
        if let v = roots.first(where: { $0.tag == "HEAD" })?.first("GEDC")?.val("VERS") { report.version = v }

        let indis = roots.filter { $0.tag == "INDI" && $0.xref != nil }
        if indis.isEmpty { report.errors.append("no individuals (INDI records) found"); return report }

        let batch = "g\(tree.importCount + 1)"
        tree.importCount += 1
        func pid(_ x: String) -> String { "\(batch):\(x.trimmingCharacters(in: CharacterSet(charactersIn: "@")))" }

        var known = Set<String>()
        for s in roots where s.tag == "SOUR" {
            guard let x = s.xref else { continue }
            tree.sources[pid(x)] = SourceRecord(id: pid(x), title: s.val("TITL") ?? s.val("AUTH") ?? x, url: s.val("WWW"))
            report.sources += 1
        }
        var famcPedigree: [String: [String: Pedigree]] = [:]  // child -> fam -> pedigree
        for r in indis {
            let x = r.xref!
            known.insert(x)
            var p = Person(id: pid(x), universes: [universe])
            for (i, n) in r.all("NAME").enumerated() {
                var (g, s) = splitName(n.value)
                g = n.val("GIVN") ?? g
                s = n.val("SURN") ?? s
                if i == 0 { p.given = g; p.surname = s } else {
                    p.altNames.append(AltName(given: g, surname: s, type: (n.val("TYPE") ?? "aka").lowercased()))
                }
            }
            p.sex = Sex(rawValue: String((r.val("SEX") ?? "U").prefix(1)).uppercased()) ?? .U
            if let b = r.first("BIRT") ?? r.first("CHR") ?? r.first("BAPM") {
                p.birth = GenDate.parse(b.val("DATE")); p.birthPlace = b.val("PLAC")
            }
            if let d = r.first("DEAT") ?? r.first("BURI") {
                p.hasDeathRecord = true; p.death = GenDate.parse(d.val("DATE")); p.deathPlace = d.val("PLAC")
            }
            p.notes = r.all("NOTE").map(\.value).filter { !$0.isEmpty }.joined(separator: "\n")
            p.media = r.all("OBJE").compactMap { $0.val("FILE") ?? ($0.value.isEmpty ? nil : $0.value) }
            var citeNodes = r.all("SOUR")
            for ev in r.children where ["BIRT", "DEAT", "NAME", "CHR", "BURI"].contains(ev.tag) { citeNodes += ev.all("SOUR") }
            for c in citeNodes where c.value.hasPrefix("@") {
                if tree.sources[pid(c.value)] != nil {
                    p.citations.append(CitationRecord(sourceID: pid(c.value), detail: c.val("PAGE") ?? ""))
                } else {
                    report.warnings.append("\(x) cites missing source \(c.value)")
                }
            }
            for fc in r.all("FAMC") { famcPedigree[x, default: [:]][fc.value] = pedigree(fc.val("PEDI")) }
            tree.persons[p.id] = p
            report.people += 1
        }
        let famXrefs = Set(roots.filter { $0.tag == "FAM" }.compactMap(\.xref))
        for (child, fams) in famcPedigree {
            for f in fams.keys where !famXrefs.contains(f) { report.warnings.append("\(child) FAMC references missing family \(f)") }
        }
        for f in roots where f.tag == "FAM" {
            guard let fx = f.xref else { continue }
            report.families += 1
            let parents = [f.val("HUSB"), f.val("WIFE")].compactMap { $0 }.filter {
                if known.contains($0) { return true }
                report.warnings.append("family \(fx) references missing individual \($0)")
                return false
            }
            let famSources = f.all("SOUR").filter { $0.value.hasPrefix("@") }.map { pid($0.value) }.filter { tree.sources[$0] != nil }
            if parents.count == 2 {
                let div = f.first("DIV").map { $0.val("DATE") ?? "Y" }
                tree.addSpouse(pid(parents[0]), pid(parents[1]), ended: div)
                report.spouseLinks += 1
            }
            for c in f.all("CHIL") {
                guard known.contains(c.value) else {
                    report.warnings.append("family \(fx) references missing individual \(c.value)"); continue
                }
                for px in parents {
                    var ped = famcPedigree[c.value]?[fx] ?? .birth
                    if ped == .birth {
                        let rel = px == f.val("HUSB") ? c.val("_FREL") : c.val("_MREL")
                        let p2 = pedigree(rel)
                        if p2 != .unknown { ped = p2 }
                    }
                    tree.addParent(pid(px), child: pid(c.value), pedigree: ped, sources: famSources)
                    report.parentLinks += 1
                }
            }
        }
        if tree.homePersonID == nil { tree.homePersonID = pid(indis[0].xref!) }
        return report
    }
}
