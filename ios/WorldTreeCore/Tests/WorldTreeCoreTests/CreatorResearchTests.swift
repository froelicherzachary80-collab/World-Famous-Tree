import XCTest
@testable import WorldTreeCore

/// Simulated Wikidata (fictional people) so the research pipeline is tested without the network.
struct FakeWikidata: HTTPTransport, @unchecked Sendable {
    var entities: [String: [String: Any]] = [:]
    var search: [String: [String]] = [:]
    var status = 200

    func get(_ url: URL) async throws -> (Int, Data) {
        if status != 200 { return (status, Data()) }
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        let body: [String: Any]
        if q["action"] == "wbsearchentities" {
            body = ["search": (search[q["search"] ?? ""] ?? []).map { ["id": $0] }]
        } else {
            let ids = (q["ids"] ?? "").split(separator: "|").map(String.init)
            body = ["entities": Dictionary(uniqueKeysWithValues: ids.map { ($0, entities[$0] ?? ["missing": ""]) })]
        }
        return (200, try JSONSerialization.data(withJSONObject: body))
    }

    static func item(_ id: String, referenced: Bool = true) -> [String: Any] {
        ["mainsnak": ["snaktype": "value", "datavalue": ["value": ["id": id]]], "rank": "normal",
         "references": referenced ? [["snaks": [:]]] : []]
    }
    static func time(_ t: String) -> [String: Any] {
        ["mainsnak": ["snaktype": "value", "datavalue": ["value": ["time": t]]], "rank": "normal"]
    }
    static func str(_ s: Any) -> [String: Any] {
        ["mainsnak": ["snaktype": "value", "datavalue": ["value": s]], "rank": "normal"]
    }

    static func person(_ label: String, sex: String = "Q6581097", born: String? = nil, died: String? = nil,
                       father: String? = nil, mother: String? = nil, children: [String] = [], aliases: [String] = [],
                       youtube: String? = nil, birthName: String? = nil, enwiki: Bool = false) -> [String: Any] {
        var claims: [String: Any] = ["P31": [item("Q5")], "P21": [item(sex)]]
        if let born { claims["P569"] = [time(born)] }
        if let died { claims["P570"] = [time(died)] }
        if let father { claims["P22"] = [item(father)] }
        if let mother { claims["P25"] = [item(mother)] }
        if !children.isEmpty { claims["P40"] = children.map { item($0) } }
        if let youtube { claims["P2397"] = [str(youtube)]; claims["P106"] = [item("Q17125263")] }
        if let birthName { claims["P1477"] = [str(["text": birthName, "language": "en"])] }
        return ["labels": ["en": ["value": label]], "aliases": ["en": aliases.map { ["value": $0] }],
                "descriptions": ["en": ["value": "test person"]], "claims": claims,
                "sitelinks": enwiki ? ["enwiki": [:]] : [:]]
    }
}

final class CreatorResearchTests: XCTestCase {
    let year = Calendar.current.component(.year, from: Date())

    func web() -> FakeWikidata {
        var w = FakeWikidata()
        w.search = ["TestCreator": ["Q800", "Q900"], "OtherCreator": ["Q800"]]
        w.entities = [
            // A different YouTuber that also matches the search text — must NOT be chosen.
            "Q800": FakeWikidata.person("Someone Else", born: "+1995-01-01T00:00:00Z", aliases: ["OtherCreator"], youtube: "UC800"),
            "Q900": FakeWikidata.person("TestCreator", sex: "Q6581072", born: "+1993-01-01T00:00:00Z", father: "Q901", mother: "Q902",
                                        children: ["Q903"], youtube: "UC900", birthName: "Liz Example", enwiki: true),
            "Q901": FakeWikidata.person("Tom Stone", born: "+1930-01-01T00:00:00Z", died: "+2001-01-01T00:00:00Z", father: "Q904"),
            "Q902": FakeWikidata.person("Private Mum", sex: "Q6581072", born: "+1965-01-01T00:00:00Z"),          // living, private
            "Q903": FakeWikidata.person("Kid", born: "+\(year - 4)-01-01T00:00:00Z", enwiki: true),             // minor
            "Q904": FakeWikidata.person("Ed Stone", born: "+1900-01-01T00:00:00Z", died: "+1970-01-01T00:00:00Z"),
        ]
        return w
    }

    func familyTree() -> FamilyTree {
        var tree = FamilyTree()
        GEDCOM.importText(WorldTreeCoreTests.fixture, into: &tree)
        tree.homePersonID = "g1:I16"   // Jack Stone, grandson of Ed Stone
        return tree
    }

    func drain(_ engine: inout CreatorResearchEngine, _ tree: inout FamilyTree, _ w: FakeWikidata) async {
        let client = WikidataClient(transport: w)
        var guardCount = 0
        while let job = engine.nextJob(), guardCount < 50 {
            guardCount += 1
            do { engine.apply(try await CreatorResearchEngine.perform(job, client: client), for: job, to: &tree) }
            catch { engine.fail(job, error: error) }
        }
    }

    func testParseHandles() {
        XCTAssertEqual(CreatorResearchEngine.parseHandles("Ldshadowlady, JumperWho, and MinuteTech"),
                       ["Ldshadowlady", "JumperWho", "MinuteTech"])
        XCTAssertEqual(CreatorResearchEngine.parseHandles("@A & B"), ["A", "B"])
    }

    func testCreatorResearchRespectsPrivacyAndFindsConnection() async {
        var tree = familyTree()
        var engine = CreatorResearchEngine()
        engine.addCreators(["TestCreator", "NoSuchCreator"])
        await drain(&engine, &tree, web())

        let creator = tree.persons["wd:Q900"]
        XCTAssertEqual(creator?.name, "Liz Example")                       // real name from birth name
        XCTAssertTrue(creator?.altNames.contains { $0.given == "TestCreator" } ?? false)
        XCTAssertNil(tree.persons["wd:Q800"])                              // wrong creator never chosen
        XCTAssertNil(tree.persons["wd:Q902"])                              // living private mother not stored
        XCTAssertNil(tree.persons["wd:Q903"])                              // minor never stored
        XCTAssertNotNil(tree.persons["wd:Q901"])                           // deceased father admitted
        XCTAssertNotNil(tree.persons["wd:Q904"])                           // grandfather via expansion
        XCTAssertTrue(engine.discoveries.contains { $0.kind == .privacyNote })
        XCTAssertTrue(engine.discoveries.contains { $0.kind == .notFound && $0.title.contains("NoSuchCreator") })
        XCTAssertTrue(tree.persons["wd:Q900"]!.citations.allSatisfy { tree.sources[$0.sourceID]?.url != nil })

        // Ed Stone from research matches Ed Stone in the user's tree — a suggestion only.
        guard let match = engine.discoveries.first(where: { $0.kind == .identityMatch }) else { return XCTFail("no match") }
        XCTAssertEqual(match.personIDs, ["wd:Q904", "g1:I8"])
        XCTAssertFalse(engine.discoveries.contains { $0.kind == .connection })

        _ = engine.confirmMatch(match.id, tree: &tree)
        let conn = engine.discoveries.first { $0.kind == .connection }
        XCTAssertNotNil(conn)
        XCTAssertTrue(conn!.title.contains("1st cousin"), conn!.title)      // Jack(2 up) & creator(2 up) via Ed Stone
        XCTAssertTrue(conn!.title.hasPrefix("Candidate"))                   // single-source research links
        XCTAssertTrue(engine.isIdle)
    }

    func testBlockedSourceIsNotRetried() async {
        var tree = FamilyTree()
        var engine = CreatorResearchEngine()
        engine.addCreators(["TestCreator"])
        var w = web()
        w.status = 403
        await drain(&engine, &tree, w)
        XCTAssertTrue(engine.isIdle)
        XCTAssertTrue(engine.log.contains { $0.isError && $0.message.contains("Blocked") })
    }

    func testEngineStateSurvivesRelaunch() throws {
        var engine = CreatorResearchEngine()
        engine.addCreators(["A", "B"])
        let data = try JSONEncoder().encode(engine)
        let restored = try JSONDecoder().decode(CreatorResearchEngine.self, from: data)
        XCTAssertEqual(restored.pendingCount, 2)
    }

    func testWikidataBCEYears() {
        XCTAssertEqual(WikidataClient.astronomicalYear("-0044-03-15T00:00:00Z"), -43)
        XCTAssertEqual(WikidataClient.astronomicalYear("+1993-01-01T00:00:00Z"), 1993)
    }
}
