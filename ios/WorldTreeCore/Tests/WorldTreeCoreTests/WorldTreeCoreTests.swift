import XCTest
@testable import WorldTreeCore

/// Uses the same synthetic dataset as the Python backend tests: /tests/fixtures/synthetic_family.ged
final class WorldTreeCoreTests: XCTestCase {
    static let fixture: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/synthetic_family.ged")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    func loaded() -> FamilyTree {
        var tree = FamilyTree()
        let report = GEDCOM.importText(Self.fixture, into: &tree)
        XCTAssertTrue(report.isValid, "\(report.errors)")
        return tree
    }

    func id(_ x: String) -> String { "g1:\(x)" }

    func testGEDCOMImport() {
        var tree = FamilyTree()
        let r = GEDCOM.importText(Self.fixture, into: &tree)
        XCTAssertEqual(r.version, "5.5.1")
        XCTAssertEqual(r.people, 27)
        XCTAssertEqual(r.families, 9)
        XCTAssertEqual(r.spouseLinks, 9)
        XCTAssertEqual(r.parentLinks, 24)
        XCTAssertEqual(r.warnings, [])
        let john = tree.persons[id("I25")]!
        XCTAssertEqual(john.altNames.first, AltName(given: "Johann", surname: "Schmidt", type: "birth"))
        XCTAssertEqual(tree.persons[id("I27")]!.notes, "Test record for BCE date handling.\nSecond line of the note.")
        XCTAssertEqual(tree.persons[id("I1")]!.citations.first?.detail, "p. 3")
        XCTAssertTrue(tree.relationships.contains { $0.b == id("I22") && $0.pedigree == .adopted })
        XCTAssertTrue(tree.persons[id("I16")]!.isPresumedLiving())
        XCTAssertFalse(tree.persons[id("I1")]!.isPresumedLiving())
    }

    func testMalformedInputKeepsGoodRecords() {
        var tree = FamilyTree()
        let r = GEDCOM.importText("0 HEAD\njunk line\n0 @I1@ INDI\n1 NAME A /B/\n1 FAMC @F9@\n", into: &tree)
        XCTAssertTrue(r.isValid)
        XCTAssertEqual(r.people, 1)
        XCTAssertTrue(r.warnings.contains { $0.contains("unparseable") })
        XCTAssertTrue(r.warnings.contains { $0.contains("TRLR") })
        XCTAssertFalse(GEDCOM.importText("", into: &tree).isValid)
    }

    func testDates() {
        XCTAssertEqual(GenDate.parse("44 B.C.")?.year, -43)
        XCTAssertEqual(GenDate.parse("1 BC")?.year, 0)
        XCTAssertEqual(GenDate.parse("4000 BCE")?.year, -3999)
        XCTAssertEqual(GenDate.formatYear(-3999), "4000 BCE")
        let d = GenDate.parse("ABT 12 MAR 1850")!
        XCTAssertEqual(d.qualifier, .about)
        XCTAssertEqual(d.day, 12)
        XCTAssertEqual(d.month, 3)
        XCTAssertEqual(d.year, 1850)
        let r = GenDate.parse("BET 1800 AND 1810")!
        XCTAssertEqual(r.qualifier, .between)
        XCTAssertEqual(r.endYear, 1810)
        XCTAssertEqual(GenDate.parse("1700/01")?.year, 1700)
        XCTAssertNil(GenDate.parse(""))
    }

    func testRelationships() {
        let g = TreeGraph(loaded())
        let expected: [(String, String, RelationshipCalculator.Kind, String)] = [
            ("I3", "I4", .blood, "sister"),
            ("I3", "I6", .blood, "half-brother"),
            ("I8", "I11", .blood, "1st cousin"),
            ("I13", "I15", .blood, "2nd cousin"),
            ("I15", "I16", .blood, "2nd cousin once removed"),
            ("I11", "I13", .blood, "1st cousin once removed"),
            ("I8", "I4", .blood, "aunt"),
            ("I16", "I1", .blood, "2nd great-grandfather"),
            ("I8", "I19", .blood, "half-1st cousin"),
            ("I3", "I5", .marriage, "stepmother"),
            ("I22", "I23", .adoptive, "adoptive sister"),
            ("I12", "I3", .marriage, "father-in-law"),
            ("I3", "I12", .marriage, "daughter-in-law"),
            ("I16", "I22", .none, RelationshipCalculator.noConnection),
        ]
        for (a, b, kind, rel) in expected {
            let r = RelationshipCalculator.findConnection(g, id(a), id(b))
            XCTAssertEqual(r.kind, kind, "\(a)-\(b)")
            XCTAssertEqual(r.relationship, rel, "\(a)-\(b)")
        }
        let p = RelationshipCalculator.findConnection(g, id("I15"), id("I16")).primary!
        XCTAssertEqual(p.cousinDegree, 2)
        XCTAssertEqual(p.removed, 1)
        XCTAssertEqual(Set(p.commonAncestors), [id("I1"), id("I2")])
        XCTAssertFalse(p.uncertain)
    }

    func testLabels() {
        XCTAssertEqual(RelationshipCalculator.label(gA: 6, gB: 9), "5th cousin 3 times removed")
        XCTAssertEqual(RelationshipCalculator.label(gA: 5, gB: 0, sexB: .F), "3rd great-grandmother")
        XCTAssertEqual(RelationshipCalculator.label(gA: 12, gB: 12), "11th cousin")
    }

    func testDuplicatesAndUndoableMerge() {
        var tree = loaded()
        let found = DuplicateDetector.detect(tree)
        XCTAssertTrue(found.contains { $0.a == id("I24") && $0.b == id("I25") })
        XCTAssertFalse(found.contains { $0.a == id("I25") && $0.b == id("I26") })
        tree.addParent(id("I25"), child: id("I26"))
        let before = tree.relationships.count
        let rec = tree.merge(keep: id("I24"), drop: id("I25"))!
        XCTAssertEqual(tree.persons[id("I25")]?.mergedInto, id("I24"))
        XCTAssertTrue(TreeGraph(tree).children[id("I24")]!.contains { $0.other == id("I26") })
        tree.undo(rec)
        XCTAssertNil(tree.persons[id("I25")]?.mergedInto)
        XCTAssertEqual(tree.relationships.count, before)
        XCTAssertNil(TreeGraph(tree).children[id("I24")])
    }

    func testNameOnlyIsNeverACandidate() {
        var tree = FamilyTree()
        tree.persons["a"] = Person(id: "a", given: "Mary", surname: "Jones")
        tree.persons["b"] = Person(id: "b", given: "Mary", surname: "Jones")
        XCTAssertTrue(DuplicateDetector.detect(tree).isEmpty)
        XCTAssertEqual(DuplicateDetector.soundex("Smyth"), "S530")
    }

    func testGapsTimelineDNA() throws {
        let tree = loaded()
        let gaps = GapAnalyzer.analyze(tree)
        XCTAssertTrue(gaps.missingParents.contains { $0.id == id("I1") })
        XCTAssertFalse(gaps.recommendedGoals.isEmpty)
        XCTAssertTrue(TimelineChecker.scan(tree).isEmpty)
        let dna = try RawDNAParser.parse("# This data file generated by 23andMe\nrs123\t1\t1000\tAG\nrs124\t2\t2000\t--\n")
        XCTAssertEqual(dna.format, "23andMe")
        XCTAssertEqual(dna.snpCount, 2)
        XCTAssertEqual(dna.noCalls, 1)
    }

    func testLargeTreePerformance() {
        var tree = FamilyTree()
        var prev: [String] = (0..<256).map { "r\($0)" }
        for (i, p) in prev.enumerated() { tree.persons[p] = Person(id: p, given: "G\(i)", surname: "Root\(i)", sex: i % 2 == 0 ? .M : .F) }
        var level = 0
        var rng = SystemRandomNumberGenerator()
        while tree.persons.count < 10_000 {
            level += 1
            prev.shuffle(using: &rng)
            var next: [String] = []
            var i = 0
            while i + 1 < prev.count {
                tree.addSpouse(prev[i], prev[i + 1])
                for k in 0..<Int.random(in: 3...5) {
                    let c = "p\(level)_\(next.count)"
                    tree.persons[c] = Person(id: c, given: "N\(Int.random(in: 0...99999))", surname: "S\(Int.random(in: 0...5000))", sex: k % 2 == 0 ? .M : .F)
                    tree.addParent(prev[i], child: c)
                    tree.addParent(prev[i + 1], child: c)
                    next.append(c)
                }
                i += 2
            }
            prev = next
        }
        let start = Date()
        let g = TreeGraph(tree)
        for i in 0..<10 { _ = RelationshipCalculator.findConnection(g, prev[i], prev[prev.count - 1 - i]) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }
}
