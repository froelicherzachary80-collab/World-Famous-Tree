import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Networking

public protocol HTTPTransport: Sendable {
    func get(_ url: URL) async throws -> (Int, Data)
}

public struct URLSessionTransport: HTTPTransport {
    public static let userAgent = "WorldTreeAI/1.1 (iOS genealogy app; on-device research)"
    public init() {}
    public func get(_ url: URL) async throws -> (Int, Data) {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

public enum ResearchError: LocalizedError, Equatable {
    case blocked(String), http(Int), badData
    public var errorDescription: String? {
        switch self {
        case .blocked(let s): return "Blocked by source (not bypassed): \(s)"
        case .http(let c): return "Source returned HTTP \(c)"
        case .badData: return "Source returned unreadable data"
        }
    }
    public var retryable: Bool { if case .blocked = self { return false }; return true }
}

// MARK: - Wikidata

/// A person as documented on Wikidata. Genealogical fields only — never addresses or contact data.
public struct WDPerson: Codable, Hashable, Sendable {
    public var qid: String
    public var label: String
    public var aliases: [String]
    public var birthName: String?
    public var description: String
    public var sex: Sex
    public var birthYear: Int?
    public var deathYear: Int?
    public var birthDate: String?
    public var deathDate: String?
    public var hasEnglishWikipedia: Bool
    public var youtubeChannelIDs: [String]
    public var occupations: [String]
    /// relation ("father","mother","spouse","sibling","child") -> [(qid, claim has a reference)]
    public var relatives: [String: [RelativeRef]]
    public var wikitreeID: String?

    public struct RelativeRef: Codable, Hashable, Sendable {
        public var qid: String
        public var referenced: Bool
    }

    public var url: String { "https://www.wikidata.org/wiki/\(qid)" }
    public var isPublicFigure: Bool { hasEnglishWikipedia || !youtubeChannelIDs.isEmpty }
    public var isCreator: Bool {
        !youtubeChannelIDs.isEmpty || occupations.contains { WikidataClient.creatorOccupations.contains($0) }
    }
    /// Publicly documented real name, if any (birth name, or the main label when it differs from the handle).
    public func realName(handle: String) -> String? {
        if let b = birthName, !b.isEmpty { return b }
        let norm = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        if norm(label) != norm(handle), label.contains(" ") { return label }
        return nil
    }
}

public struct WikidataClient: Sendable {
    public static let api = "https://www.wikidata.org/w/api.php"
    static let relProps = ["P22": "father", "P25": "mother", "P26": "spouse", "P3373": "sibling", "P40": "child"]
    /// YouTuber, streamer, Let's Player, internet celebrity, vlogger
    public static let creatorOccupations: Set<String> = ["Q17125263", "Q57414145", "Q15077007", "Q94791573", "Q2626540"]

    public let transport: HTTPTransport
    public init(transport: HTTPTransport = URLSessionTransport()) { self.transport = transport }

    func json(_ params: [String: String]) async throws -> [String: Any] {
        var comps = URLComponents(string: Self.api)!
        comps.queryItems = (params.merging(["format": "json"]) { a, _ in a }).sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        let (status, data) = try await transport.get(comps.url!)
        if [401, 402, 403].contains(status) { throw ResearchError.blocked("HTTP \(status)") }
        guard status == 200 else { throw ResearchError.http(status) }
        if let s = String(data: data.prefix(2000), encoding: .utf8), s.lowercased().contains("captcha") {
            throw ResearchError.blocked("CAPTCHA")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ResearchError.badData }
        return obj
    }

    /// Search by name or handle (Wikidata search also matches aliases such as channel names).
    public func search(_ text: String, limit: Int = 7) async throws -> [String] {
        let obj = try await json(["action": "wbsearchentities", "search": text, "language": "en",
                                  "uselang": "en", "type": "item", "limit": String(limit)])
        return (obj["search"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    public func people(_ ids: [String]) async throws -> [String: WDPerson] {
        var out: [String: WDPerson] = [:]
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(ids.count, start + 50)])
            start += 50
            let obj = try await json(["action": "wbgetentities", "ids": chunk.joined(separator: "|"),
                                      "props": "labels|aliases|descriptions|claims|sitelinks", "languages": "en"])
            for (qid, raw) in obj["entities"] as? [String: Any] ?? [:] {
                if let e = raw as? [String: Any], let p = Self.parse(qid, e) { out[qid] = p }
            }
        }
        return out
    }

    /// Wikidata BCE years have no year zero: "-0044" == 44 BC -> astronomical -43.
    public static func astronomicalYear(_ time: String) -> Int? {
        let neg = time.hasPrefix("-")
        let digits = time.drop(while: { $0 == "+" || $0 == "-" }).prefix(while: { $0.isNumber })
        guard let y = Int(digits), y != 0 else { return nil }
        return neg ? 1 - y : y
    }

    static func claims(_ e: [String: Any], _ prop: String) -> [[String: Any]] {
        ((e["claims"] as? [String: Any])?[prop] as? [[String: Any]] ?? []).filter {
            ($0["mainsnak"] as? [String: Any])?["snaktype"] as? String == "value" && ($0["rank"] as? String) != "deprecated"
        }
    }

    static func value(_ claim: [String: Any]) -> Any? {
        ((claim["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"]
    }

    static func itemIDs(_ e: [String: Any], _ prop: String) -> [(String, Bool)] {
        claims(e, prop).compactMap { c -> (String, Bool)? in
            guard let id = (value(c) as? [String: Any])?["id"] as? String else { return nil }
            return (id, !((c["references"] as? [Any]) ?? []).isEmpty)
        }
    }

    static func time(_ e: [String: Any], _ prop: String) -> (Int?, String?) {
        guard let c = claims(e, prop).first, let t = (value(c) as? [String: Any])?["time"] as? String else { return (nil, nil) }
        return (astronomicalYear(t), t)
    }

    static func parse(_ qid: String, _ e: [String: Any]) -> WDPerson? {
        if e["missing"] != nil { return nil }
        guard itemIDs(e, "P31").contains(where: { $0.0 == "Q5" }) else { return nil }   // humans only
        let label = ((e["labels"] as? [String: Any])?["en"] as? [String: Any])?["value"] as? String ?? qid
        let aliases = ((e["aliases"] as? [String: Any])?["en"] as? [[String: Any]] ?? []).compactMap { $0["value"] as? String }
        let desc = ((e["descriptions"] as? [String: Any])?["en"] as? [String: Any])?["value"] as? String ?? ""
        let birthName = claims(e, "P1477").compactMap { (value($0) as? [String: Any])?["text"] as? String }.first
        let genders = itemIDs(e, "P21").map(\.0)
        let sex: Sex = genders.contains { ["Q6581097", "Q2449503"].contains($0) } ? .M
            : genders.contains { ["Q6581072", "Q1052281"].contains($0) } ? .F : .U
        let (by, bt) = time(e, "P569")
        let (dy, dt) = time(e, "P570")
        var rels: [String: [WDPerson.RelativeRef]] = [:]
        for (prop, rel) in relProps {
            let ids = itemIDs(e, prop)
            if !ids.isEmpty { rels[rel] = ids.map { WDPerson.RelativeRef(qid: $0.0, referenced: $0.1) } }
        }
        return WDPerson(
            qid: qid, label: label, aliases: aliases, birthName: birthName, description: desc, sex: sex,
            birthYear: by, deathYear: dy, birthDate: bt, deathDate: dt,
            hasEnglishWikipedia: (e["sitelinks"] as? [String: Any])?["enwiki"] != nil,
            youtubeChannelIDs: claims(e, "P2397").compactMap { value($0) as? String },
            occupations: itemIDs(e, "P106").map(\.0),
            relatives: rels,
            wikitreeID: claims(e, "P2949").compactMap { value($0) as? String }.first)
    }
}

// MARK: - Research engine (persistent, resumable)

public struct ResearchJob: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        case lookupCreator(handle: String)
        case expand(qid: String, depth: Int, root: String)
    }
    public var id = UUID()
    public var kind: Kind
    public var attempts = 0
    public init(_ kind: Kind) { self.kind = kind }
}

public struct LocalDiscovery: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case creatorFound, notFound, newPerson, identityMatch, connection, privacyNote }
    public enum Status: String, Codable, Sendable { case info, pending, accepted, rejected }
    public var id = UUID()
    public var kind: Kind
    public var title: String
    public var detail: String
    public var personIDs: [String] = []
    public var sourceURL: String?
    public var status: Status
    public var date = Date()
}

public struct ResearchLogEntry: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var agent: String
    public var message: String
    public var isError = false

    public init(agent: String, message: String, isError: Bool = false) {
        self.agent = agent; self.message = message; self.isError = isError
    }
}

/// Fetched data for one job — produced off the main thread, applied to the tree synchronously.
public enum JobOutput: Sendable {
    case lookup(handle: String, candidates: [WDPerson], relatives: [String: WDPerson])
    case expand(person: WDPerson?, relatives: [String: WDPerson])
}

public struct CreatorResearchEngine: Codable, Sendable {
    public var queue: [ResearchJob] = []
    public var discoveries: [LocalDiscovery] = []
    public var log: [ResearchLogEntry] = []
    public var requestsMade = 0
    public var completedJobs = 0
    public var visited: Set<String> = []
    public var maxGenerations = 4
    public static let universe = "minecraft"

    public init() {}

    public var isIdle: Bool { queue.isEmpty }
    public var pendingCount: Int { queue.count }

    /// Accepts "LDShadowLady, JumperWho and MinuteTech" style lists.
    public static func parseHandles(_ text: String) -> [String] {
        text.replacingOccurrences(of: " and ", with: ",").replacingOccurrences(of: "&", with: ",")
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "@\"“”"))) }
            .filter { !$0.isEmpty }
    }

    public mutating func addCreators(_ handles: [String]) {
        for h in handles where !queue.contains(where: { $0.kind == .lookupCreator(handle: h) }) {
            queue.append(ResearchJob(.lookupCreator(handle: h)))
            note("Research Planner AI", "Queued creator research: \(h)")
        }
    }

    public func nextJob() -> ResearchJob? { queue.first }

    mutating func note(_ agent: String, _ msg: String, error: Bool = false) {
        log.insert(ResearchLogEntry(agent: agent, message: msg, isError: error), at: 0)
        if log.count > 300 { log.removeLast(log.count - 300) }
    }

    // MARK: fetch (network only)

    public static func perform(_ job: ResearchJob, client: WikidataClient) async throws -> JobOutput {
        switch job.kind {
        case .lookupCreator(let handle):
            let ids = try await client.search(handle)
            let found = try await client.people(ids)
            let candidates = ids.compactMap { found[$0] }
            let best = choose(handle, candidates)
            var rel: [String: WDPerson] = [:]
            if let best {
                let rids = best.relatives.values.flatMap { $0.map(\.qid) }
                if !rids.isEmpty { rel = try await client.people(rids) }
            }
            return .lookup(handle: handle, candidates: best.map { [$0] } ?? [], relatives: rel)
        case .expand(let qid, _, _):
            let p = try await client.people([qid])[qid]
            var rel: [String: WDPerson] = [:]
            if let p {
                let parents = (p.relatives["father"] ?? []) + (p.relatives["mother"] ?? [])
                if !parents.isEmpty { rel = try await client.people(parents.map(\.qid)) }
            }
            return .expand(person: p, relatives: rel)
        }
    }

    /// Pick the search result that is actually a content creator matching the handle.
    public static func choose(_ handle: String, _ people: [WDPerson]) -> WDPerson? {
        let norm = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let h = norm(handle)
        let creators = people.filter(\.isCreator)
        let exact = creators.first { person in
            ([person.label] + person.aliases).contains { name in norm(name) == h }
        }
        return exact   // never guess a "closest" creator — a wrong person would poison the tree
    }

    // MARK: privacy

    public enum Admission { case admit, privateLiving, minor }

    public static func admission(_ p: WDPerson, currentYear: Int = Calendar.current.component(.year, from: Date())) -> Admission {
        let living = p.deathYear == nil && (p.birthYear.map { $0 > currentYear - Person.livingCutoffYears } ?? true)
        if living, let by = p.birthYear, currentYear - by < 18 { return .minor }
        if living && !p.isPublicFigure { return .privateLiving }
        return .admit
    }

    // MARK: apply (synchronous, on the tree)

    @discardableResult
    mutating func store(_ p: WDPerson, in tree: inout FamilyTree, handle: String? = nil) -> String {
        let id = "wd:\(p.qid)"
        let isNew = tree.persons[id] == nil
        if isNew {
            let real = handle.flatMap { p.realName(handle: $0) } ?? p.birthName ?? p.label
            let parts = real.split(separator: " ")
            let sourceID = "wikidata:\(p.qid)"
            tree.sources[sourceID] = SourceRecord(id: sourceID, title: "Wikidata: \(p.label)", url: p.url,
                                                  connector: "wikidata", retrievedAt: Date())
            var alt: [AltName] = []
            if let handle { alt.append(AltName(given: handle, surname: "", type: "creator handle")) }
            if p.label != real { alt.append(AltName(given: p.label, surname: "", type: "known as")) }
            tree.persons[id] = Person(
                id: id, given: parts.dropLast().joined(separator: " ").isEmpty ? real : parts.dropLast().joined(separator: " "),
                surname: parts.count > 1 ? String(parts.last!) : "", sex: p.sex,
                birth: p.birthYear.map { GenDate(year: $0, original: p.birthDate ?? "") },
                death: p.deathYear.map { GenDate(year: $0, original: p.deathDate ?? "") },
                hasDeathRecord: p.deathYear != nil, altNames: alt, notes: p.description,
                citations: [CitationRecord(sourceID: sourceID, detail: "Retrieved \(Date().formatted(date: .abbreviated, time: .omitted))")],
                universes: [Self.universe], evidence: .supported, isPublicFigure: p.isPublicFigure)
        } else {
            tree.persons[id]?.universes.insert(Self.universe)
        }
        return id
    }

    mutating func link(_ parent: String, _ child: String, referenced: Bool, in tree: inout FamilyTree) {
        let id = tree.addParent(parent, child: child, evidence: referenced ? .supported : .candidate)
        if let p = tree.persons[parent], let c = tree.persons[child], !TimelineChecker.issues(parent: p, child: c).isEmpty {
            tree.setEvidence(.disputed, forRelationship: id)
            note("Timeline Researcher AI", "Contradiction between \(p.name) and \(c.name) — marked disputed", error: true)
        }
    }

    /// Admit relatives (privacy rules), link them, queue ancestor expansion, match against the user's tree.
    mutating func admitRelatives(of p: WDPerson, id: String, depth: Int, root: String,
                                 fetched: [String: WDPerson], tree: inout FamilyTree, parentsOnly: Bool) {
        var skippedPrivate = 0, skippedMinor = 0
        let rels = parentsOnly ? ["father", "mother"] : ["father", "mother", "spouse", "sibling", "child"]
        for rel in rels {
            for ref in p.relatives[rel] ?? [] {
                guard let r = fetched[ref.qid] else { continue }
                switch Self.admission(r) {
                case .minor: skippedMinor += 1; continue
                case .privateLiving: skippedPrivate += 1; continue
                case .admit: break
                }
                let rid = store(r, in: &tree)
                switch rel {
                case "father", "mother":
                    link(rid, id, referenced: ref.referenced, in: &tree)
                    if depth + 1 < maxGenerations && !visited.contains(r.qid) {
                        queue.append(ResearchJob(.expand(qid: r.qid, depth: depth + 1, root: root)))
                    }
                case "child":
                    link(id, rid, referenced: ref.referenced, in: &tree)
                case "spouse":
                    tree.addSpouse(id, rid, evidence: ref.referenced ? .supported : .candidate)
                default:   // sibling: link through shared documented parents only — never invent parents
                    break
                }
                if rel == "sibling" {
                    discoveries.append(LocalDiscovery(kind: .newPerson, title: "Public sibling: \(r.label)",
                                                      detail: "Documented sibling of \(p.label). Shown in Discoveries; linked in the tree once shared parents are documented.",
                                                      personIDs: [rid, id], sourceURL: r.url, status: .info))
                }
                matchAgainstMyTree(rid, tree: &tree)
            }
        }
        if skippedPrivate + skippedMinor > 0 {
            let msg = "\(skippedPrivate + skippedMinor) living relative(s) of \(p.label) are private individuals" +
                (skippedMinor > 0 ? " or minors" : "") + " and were not researched."
            note("Evidence Verification AI", msg)
            if depth == 0 {
                discoveries.append(LocalDiscovery(kind: .privacyNote, title: "Private family protected", detail: msg,
                                                  personIDs: [id], status: .info))
            }
        }
    }

    mutating func matchAgainstMyTree(_ id: String, tree: inout FamilyTree) {
        let g = TreeGraph(tree)
        guard g.persons[id] != nil else { return }
        let mine = g.persons.values.filter { $0.universes.contains("my_family") && !$0.id.hasPrefix("wd:") }
        var best: DuplicateDetector.Candidate?
        for m in mine {
            let c = DuplicateDetector.score(g, id, m.id)
            if c.score >= 0.7 && c.corroborations >= 2 && c.conflicts.isEmpty && c.score > (best?.score ?? 0) { best = c }
        }
        guard let b = best, !discoveries.contains(where: { $0.kind == .identityMatch && $0.personIDs == [id, b.b] }) else { return }
        discoveries.append(LocalDiscovery(kind: .identityMatch,
                                          title: "Possible match: \(g.name(id)) ↔ \(g.name(b.b)) in your tree",
                                          detail: b.matches.joined(separator: ", "), personIDs: [id, b.b], status: .pending))
        note("Family Matcher AI", "Possible ancestor match for \(g.name(id)) (\(Int(b.score * 100))%) — needs your review")
    }

    public mutating func apply(_ output: JobOutput, for job: ResearchJob, to tree: inout FamilyTree) {
        queue.removeAll { $0.id == job.id }
        completedJobs += 1
        switch (job.kind, output) {
        case (.lookupCreator(let handle), .lookup(_, let candidates, let relatives)):
            guard let c = candidates.first else {
                discoveries.append(LocalDiscovery(kind: .notFound, title: "No public record found for \(handle)",
                                                  detail: "This creator has no public genealogical record in Wikidata yet, so nothing was guessed. Their real name and family stay unknown unless a public source documents them.",
                                                  status: .info))
                note("Web Researcher AI", "No public record found for \(handle)")
                return
            }
            visited.insert(c.qid)
            let id = store(c, in: &tree, handle: handle)
            let real = c.realName(handle: handle)
            discoveries.append(LocalDiscovery(kind: .creatorFound,
                                              title: real.map { "\(handle) — real name: \($0)" } ?? "\(handle) — real name not publicly documented",
                                              detail: [c.description, c.birthYear.map { "Born \(GenDate.formatYear($0))" }].compactMap { $0 }.joined(separator: " · "),
                                              personIDs: [id], sourceURL: c.url, status: .info))
            note("Celebrity Research AI", "Found \(handle) on Wikidata\(real.map { " (\($0))" } ?? "")")
            admitRelatives(of: c, id: id, depth: 0, root: c.qid, fetched: relatives, tree: &tree, parentsOnly: false)
            matchAgainstMyTree(id, tree: &tree)
        case (.expand(let qid, let depth, let root), .expand(let person, let relatives)):
            visited.insert(qid)
            guard let p = person else { return }
            let id = store(p, in: &tree)
            admitRelatives(of: p, id: id, depth: depth, root: root, fetched: relatives, tree: &tree, parentsOnly: true)
        default:
            break
        }
    }

    public mutating func fail(_ job: ResearchJob, error: Error) {
        let retryable = (error as? ResearchError)?.retryable ?? true
        if let i = queue.firstIndex(where: { $0.id == job.id }) {
            queue[i].attempts += 1
            if !retryable || queue[i].attempts >= 3 {
                queue.remove(at: i)
                note("Web Researcher AI", "Gave up on a job: \(error.localizedDescription)", error: true)
            } else {
                let j = queue.remove(at: i)
                queue.append(j)   // retry later
                note("Web Researcher AI", "Source error, will retry: \(error.localizedDescription)", error: true)
            }
        }
    }

    /// After the user confirms an identity match: merge, then compute the connection to each researched creator.
    public mutating func confirmMatch(_ discoveryID: UUID, tree: inout FamilyTree) -> MergeRecord? {
        guard let i = discoveries.firstIndex(where: { $0.id == discoveryID }), discoveries[i].personIDs.count == 2 else { return nil }
        let research = discoveries[i].personIDs[0], mine = discoveries[i].personIDs[1]
        let rec = tree.merge(keep: mine, drop: research)
        discoveries[i].status = .accepted
        if let home = tree.homePersonID {
            let g = TreeGraph(tree)
            for creator in g.persons.values where creator.isPublicFigure && creator.universes.contains(Self.universe) {
                let r = RelationshipCalculator.findConnection(g, home, creator.id)
                guard r.kind != .none, r.kind != .selfPerson, let p = r.primary else { continue }
                discoveries.append(LocalDiscovery(kind: .connection,
                    title: "\(p.uncertain ? "Candidate" : "VERIFIED") connection: \(creator.name) is your \(r.relationship)",
                    detail: p.explanation, personIDs: [home, creator.id], status: .info))
            }
        }
        return rec
    }

    public mutating func rejectMatch(_ discoveryID: UUID) {
        if let i = discoveries.firstIndex(where: { $0.id == discoveryID }) { discoveries[i].status = .rejected }
    }
}
