import Foundation

/// Arbitrary JSON (discovery details, relationship results).
enum JSONValue: Codable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? { if case .object(let o) = self { return o[key] }; return nil }
    var string: String? {
        switch self { case .string(let s): return s; case .number(let n): return String(format: "%g", n); default: return nil }
    }
    var array: [JSONValue] { if case .array(let a) = self { return a }; return [] }
}

struct ServerStats: Codable {
    var importedPeople = 0, candidatePeople = 0, verifiedConnections = 0, pendingDiscoveries = 0
    var possibleDuplicates = 0, unresolvedBranches = 0, sourcesReviewed = 0, activeGoals = 0, completedGoals = 0
    var errors = 0
    var queue: [String: Int] = [:]
}

struct ResearchPlan: Codable, Hashable {
    struct Step: Codable, Hashable { var agent: String; var action: String }
    var categories: [String]
    var namedPeople: [String]
    var steps: [Step]
    var understood: Bool
}

struct ResearchGoal: Codable, Identifiable, Hashable {
    var id: Int
    var instruction: String
    var status: String
    var priority: Int
    var budget: Int
    var spent: Int
    var schedule: String?
    var plan: ResearchPlan
    var jobs: [String: Int]
}

struct Discovery: Codable, Identifiable, Hashable {
    var id: Int
    var kind: String
    var title: String
    var status: String
    var createdAt: String
    var detail: JSONValue
}

struct ActivityItem: Codable, Identifiable, Hashable {
    var id: Int
    var agent: String
    var level: String
    var message: String
    var createdAt: String
}

struct UniverseInfo: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var color: String
    var members: Int
}

struct RemoteGraph: Codable {
    struct Node: Codable, Hashable {
        var id: String, name: String, sex: String
        var birthYear: Int?, deathYear: Int?
        var evidence: String, origin: String
        var living: Bool, `public`: Bool
        var universes: [String]
    }
    struct Edge: Codable, Hashable {
        var from: String, to: String, kind: String
        var pedigree: String?
        var evidence: String
    }
    var nodes: [Node]
    var edges: [Edge]
}

struct ConnectorInfo: Codable, Identifiable, Hashable {
    var id: String, name: String, status: String, notes: String
}

enum BackendError: LocalizedError {
    case notConfigured, http(Int, String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Connect your research server in Profile first."
        case .http(let code, let msg): return "Server error \(code): \(msg)"
        }
    }
}

/// Talks to the self-hosted WORLD TREE AI research server (see /backend).
struct BackendClient {
    var baseURL: URL
    var token: String

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    func request<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> T {
        let base = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
        guard let url = URL(string: base + path) else { throw BackendError.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 60
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? ""
            throw BackendError.http(code, msg)
        }
        return try Self.decoder.decode(T.self, from: data)
    }

    func health() async throws -> JSONValue { try await request("GET", "/health") }
    func stats() async throws -> ServerStats { try await request("GET", "/stats") }
    func goals() async throws -> [ResearchGoal] { try await request("GET", "/goals") }
    func discoveries() async throws -> [Discovery] { try await request("GET", "/discoveries") }
    func activity() async throws -> [ActivityItem] { try await request("GET", "/activity") }
    func universes() async throws -> [UniverseInfo] { try await request("GET", "/universes") }
    func graph() async throws -> RemoteGraph { try await request("GET", "/graph") }
    func connectors() async throws -> [ConnectorInfo] { try await request("GET", "/connectors") }

    func previewPlan(_ instruction: String) async throws -> ResearchPlan {
        try await request("POST", "/goals/plan-preview", body: ["instruction": instruction])
    }

    func createGoal(_ instruction: String, budget: Int, schedule: String?, start: Bool) async throws -> JSONValue {
        var body: [String: Any] = ["instruction": instruction, "budget": budget, "start": start]
        if let schedule { body["schedule"] = schedule }
        return try await request("POST", "/goals", body: body)
    }

    func goalAction(_ id: Int, _ action: String) async throws -> JSONValue {
        try await request("POST", "/goals/\(id)/\(action)", body: [:])
    }

    func discoveryAction(_ id: Int, _ action: String) async throws -> JSONValue {
        try await request("POST", "/discoveries/\(id)/\(action)", body: [:])
    }

    func uploadGEDCOM(_ text: String) async throws -> JSONValue {
        try await request("POST", "/gedcom/import", body: ["gedcom": text])
    }

    func setHomePerson(_ id: String) async throws -> JSONValue {
        try await request("POST", "/home-person", body: ["person_id": id])
    }
}
