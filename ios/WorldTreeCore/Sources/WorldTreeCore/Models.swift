import Foundation

public enum EvidenceStatus: String, Codable, CaseIterable, Sendable {
    case userProvided = "user_provided"
    case verified, supported, candidate, disputed, legendary, rejected

    /// Higher = stronger. Only `userProvided`/`verified` count as certain.
    public var rank: Int {
        switch self {
        case .verified, .userProvided: return 5
        case .supported: return 4
        case .candidate: return 2
        case .disputed: return 1
        case .legendary, .rejected: return 0
        }
    }

    public var label: String {
        switch self {
        case .userProvided: return "Your records"
        case .verified: return "Verified"
        case .supported: return "Supported (1 source)"
        case .candidate: return "Candidate"
        case .disputed: return "Disputed"
        case .legendary: return "Legendary"
        case .rejected: return "Rejected"
        }
    }
}

public enum Pedigree: String, Codable, Sendable {
    case birth, adopted, step, foster, unknown
    public var isBiological: Bool { self == .birth || self == .unknown }
}

public enum Sex: String, Codable, Sendable { case M, F, U }

public struct AltName: Codable, Hashable, Sendable {
    public var given: String
    public var surname: String
    public var type: String
    public init(given: String, surname: String, type: String) {
        self.given = given; self.surname = surname; self.type = type
    }
}

public struct SourceRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var url: String?
    public var connector: String
    public var retrievedAt: Date?
    public init(id: String, title: String, url: String? = nil, connector: String = "gedcom", retrievedAt: Date? = nil) {
        self.id = id; self.title = title; self.url = url; self.connector = connector; self.retrievedAt = retrievedAt
    }
}

public struct CitationRecord: Codable, Hashable, Sendable {
    public var sourceID: String
    public var detail: String
    public init(sourceID: String, detail: String) { self.sourceID = sourceID; self.detail = detail }
}

public struct Person: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var given: String
    public var surname: String
    public var sex: Sex
    public var birth: GenDate?
    public var birthPlace: String?
    public var death: GenDate?
    public var deathPlace: String?
    public var hasDeathRecord: Bool
    public var altNames: [AltName]
    public var notes: String
    public var citations: [CitationRecord]
    public var media: [String]
    public var universes: Set<String>
    public var evidence: EvidenceStatus
    public var isPublicFigure: Bool
    public var mergedInto: String?

    public init(id: String, given: String = "", surname: String = "", sex: Sex = .U, birth: GenDate? = nil,
                birthPlace: String? = nil, death: GenDate? = nil, deathPlace: String? = nil, hasDeathRecord: Bool = false,
                altNames: [AltName] = [], notes: String = "", citations: [CitationRecord] = [], media: [String] = [],
                universes: Set<String> = ["my_family"], evidence: EvidenceStatus = .userProvided,
                isPublicFigure: Bool = false, mergedInto: String? = nil) {
        self.id = id; self.given = given; self.surname = surname; self.sex = sex; self.birth = birth
        self.birthPlace = birthPlace; self.death = death; self.deathPlace = deathPlace
        self.hasDeathRecord = hasDeathRecord; self.altNames = altNames; self.notes = notes
        self.citations = citations; self.media = media; self.universes = universes; self.evidence = evidence
        self.isPublicFigure = isPublicFigure; self.mergedInto = mergedInto
    }

    public var name: String {
        let n = "\(given) \(surname)".trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "(unknown)" : n
    }

    public var birthYear: Int? { birth?.year }
    public var deathYear: Int? { death?.year }

    public static let livingCutoffYears = 110

    /// Living people are private by default (no death record and born within 110 years, or unknown birth).
    public func isPresumedLiving(currentYear: Int = Calendar.current.component(.year, from: Date())) -> Bool {
        if hasDeathRecord || deathYear != nil { return false }
        guard let by = birthYear else { return true }
        return by > currentYear - Person.livingCutoffYears
    }

    public var lifespan: String {
        let b = birth?.display ?? "?"
        let d = death?.display ?? (hasDeathRecord ? "?" : "")
        return d.isEmpty ? "b. \(b)" : "\(b) – \(d)"
    }
}

public struct Relationship: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case parent, spouse }
    public var id: Int
    public var kind: Kind
    /// parent for `.parent`; for `.spouse` the lexically smaller id.
    public var a: String
    /// child for `.parent`.
    public var b: String
    public var pedigree: Pedigree
    public var evidence: EvidenceStatus
    public var ended: String?
    public var sourceIDs: [String]

    public init(id: Int, kind: Kind, a: String, b: String, pedigree: Pedigree = .birth,
                evidence: EvidenceStatus = .userProvided, ended: String? = nil, sourceIDs: [String] = []) {
        self.id = id; self.kind = kind; self.a = a; self.b = b; self.pedigree = pedigree
        self.evidence = evidence; self.ended = ended; self.sourceIDs = sourceIDs
    }
}

/// The whole local family database. Codable so it can be stored encrypted on device.
public struct FamilyTree: Codable, Sendable {
    public var persons: [String: Person] = [:]
    /// Mutate only through FamilyTree APIs (set is module-internal so the dedup index stays correct).
    public internal(set) var relationships: [Relationship] = [] { didSet { if !suppressInvalidate { edgeIndex = [:] } } }
    public var sources: [String: SourceRecord] = [:]
    public var nextRelationshipID: Int = 1
    public var homePersonID: String?
    public var importCount: Int = 0
    /// Transient dedup index (rebuilt on demand, not persisted).
    private var edgeIndex: [String: Int] = [:]
    private var suppressInvalidate = false

    enum CodingKeys: String, CodingKey {
        case persons, relationships, sources, nextRelationshipID, homePersonID, importCount
    }

    public init() {}

    public var activePersons: [Person] { persons.values.filter { $0.mergedInto == nil } }

    private static func key(_ kind: Relationship.Kind, _ a: String, _ b: String, _ p: Pedigree) -> String {
        "\(kind.rawValue)|\(a)|\(b)|\(kind == .parent ? p.rawValue : "")"
    }

    private mutating func lookup(_ k: String) -> Int? {
        if edgeIndex.isEmpty && !relationships.isEmpty {
            var idx: [String: Int] = [:]
            for r in relationships { idx[Self.key(r.kind, r.a, r.b, r.pedigree)] = r.id }
            edgeIndex = idx
        }
        return edgeIndex[k]
    }

    private mutating func append(_ r: Relationship, key k: String) {
        suppressInvalidate = true
        relationships.append(r)
        suppressInvalidate = false
        edgeIndex[k] = r.id
        nextRelationshipID += 1
    }

    @discardableResult
    public mutating func addParent(_ parent: String, child: String, pedigree: Pedigree = .birth,
                                   evidence: EvidenceStatus = .userProvided, sources: [String] = []) -> Int {
        let k = Self.key(.parent, parent, child, pedigree)
        if let existing = lookup(k) { return existing }
        let r = Relationship(id: nextRelationshipID, kind: .parent, a: parent, b: child, pedigree: pedigree,
                             evidence: evidence, sourceIDs: sources)
        append(r, key: k)
        return r.id
    }

    @discardableResult
    public mutating func addSpouse(_ x: String, _ y: String, ended: String? = nil, evidence: EvidenceStatus = .userProvided) -> Int {
        let (a, b) = x < y ? (x, y) : (y, x)
        let k = Self.key(.spouse, a, b, .birth)
        if let existing = lookup(k) { return existing }
        let r = Relationship(id: nextRelationshipID, kind: .spouse, a: a, b: b, evidence: evidence, ended: ended)
        append(r, key: k)
        return r.id
    }

    /// Change the evidence status of a relationship (e.g. after the user reviews a discovery).
    public mutating func setEvidence(_ status: EvidenceStatus, forRelationship id: Int) {
        guard let i = relationships.firstIndex(where: { $0.id == id }) else { return }
        suppressInvalidate = true
        relationships[i].evidence = status
        suppressInvalidate = false
    }
}

/// Fast adjacency view over a FamilyTree (merged and rejected records excluded).
public struct TreeGraph: Sendable {
    public struct Edge: Hashable, Sendable {
        public let other: String
        public let pedigree: Pedigree
        public let evidence: EvidenceStatus
    }

    public let persons: [String: Person]
    public private(set) var parents: [String: [Edge]] = [:]
    public private(set) var children: [String: [Edge]] = [:]
    public private(set) var spouses: [String: [Edge]] = [:]

    public init(_ tree: FamilyTree) {
        var active: [String: Person] = [:]
        for (k, p) in tree.persons where p.mergedInto == nil { active[k] = p }
        persons = active
        for r in tree.relationships where r.evidence != .rejected {
            guard active[r.a] != nil, active[r.b] != nil else { continue }
            switch r.kind {
            case .parent:
                parents[r.b, default: []].append(Edge(other: r.a, pedigree: r.pedigree, evidence: r.evidence))
                children[r.a, default: []].append(Edge(other: r.b, pedigree: r.pedigree, evidence: r.evidence))
            case .spouse:
                spouses[r.a, default: []].append(Edge(other: r.b, pedigree: .birth, evidence: r.evidence))
                spouses[r.b, default: []].append(Edge(other: r.a, pedigree: .birth, evidence: r.evidence))
            }
        }
    }

    public func name(_ id: String) -> String { persons[id]?.name ?? id }
}
