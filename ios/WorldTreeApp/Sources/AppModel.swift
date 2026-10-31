import Foundation
import SwiftUI
import UserNotifications
import WorldTreeCore

@MainActor
final class AppModel: ObservableObject {
    // Local-first genealogy database (encrypted on device)
    @Published var tree = FamilyTree()
    @Published var lastImport: GEDCOM.Report?
    @Published var duplicates: [DuplicateDetector.Candidate] = []
    @Published var merges: [MergeRecord] = []
    @Published var dismissedDuplicates: Set<String> = []
    @Published var highlightedPath: [String] = []
    @Published var autoMerge = DuplicateDetector.AutoMergeRules()
    @Published var dnaSummary: RawDNAParser.Summary?
    @Published var message: String?

    // On-device creator research (see AppModel+Research.swift, BackgroundResearch.swift)
    @Published var research = CreatorResearchEngine()
    @Published var researchRunning = false
    var researchTask: Task<Void, Never>?

    // Research server
    @Published var serverURL: String = UserDefaults.standard.string(forKey: "serverURL") ?? ""
    @Published var serverOnline = false
    @Published var stats = ServerStats()
    @Published var goals: [ResearchGoal] = []
    @Published var discoveries: [Discovery] = []
    @Published var activity: [ActivityItem] = []
    @Published var universes: [UniverseInfo] = []
    @Published var connectors: [ConnectorInfo] = []
    @Published var remoteGraph: RemoteGraph?
    @Published var shareTreeWithServer = UserDefaults.standard.bool(forKey: "shareTree")

    private var rawGEDCOMs: [String] = []
    private var seenDiscoveryIDs: Set<Int> = Set(UserDefaults.standard.array(forKey: "seenDiscoveries") as? [Int] ?? [])
    private var pollTask: Task<Void, Never>?

    var graph: TreeGraph { TreeGraph(tree) }

    var client: BackendClient? {
        guard let url = URL(string: serverURL), url.scheme != nil, let token = Keychain.string("api-token"), !token.isEmpty
        else { return nil }
        return BackendClient(baseURL: url, token: token)
    }

    init() {
        load()
        BackgroundResearch.shared.model = self
    }

    // MARK: - Persistence

    struct Persisted: Codable {
        var tree: FamilyTree
        var merges: [MergeRecord]
        var dismissed: Set<String>
        var rawGEDCOMs: [String]
        var dna: RawDNAParser.Summary?
        var autoMerge: DuplicateDetector.AutoMergeRules
        var research: CreatorResearchEngine?
    }

    func load() {
        guard let data = EncryptedStore.read(name: "tree.enc"),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        tree = p.tree; merges = p.merges; dismissedDuplicates = p.dismissed; rawGEDCOMs = p.rawGEDCOMs
        dnaSummary = p.dna; autoMerge = p.autoMerge
        research = p.research ?? CreatorResearchEngine()
        refreshDuplicates()
    }

    func save() {
        let p = Persisted(tree: tree, merges: merges, dismissed: dismissedDuplicates, rawGEDCOMs: rawGEDCOMs,
                          dna: dnaSummary, autoMerge: autoMerge, research: research)
        do { try EncryptedStore.write(try JSONEncoder().encode(p), name: "tree.enc") }
        catch { message = "Could not save: \(error.localizedDescription)" }
    }

    // MARK: - GEDCOM

    func importGEDCOM(_ data: Data) {
        let text = GEDCOM.decode(data)
        let report = GEDCOM.importText(text, into: &tree)
        lastImport = report
        guard report.isValid else { message = report.errors.joined(separator: "\n"); return }
        rawGEDCOMs.append(text)
        refreshDuplicates()
        applyAutoMerges()
        save()
        message = "Imported \(report.people) people and \(report.families) families."
        if shareTreeWithServer { Task { await uploadTree(text) } }
    }

    func refreshDuplicates() {
        duplicates = DuplicateDetector.detect(tree, ignoring: dismissedDuplicates)
    }

    func applyAutoMerges() {
        guard autoMerge.enabled else { return }
        for c in duplicates where DuplicateDetector.autoMergeAllowed(c, rules: autoMerge) {
            if let rec = tree.merge(keep: c.a, drop: c.b) { merges.append(rec) }
        }
        refreshDuplicates()
    }

    func resolveDuplicate(_ c: DuplicateDetector.Candidate, action: DuplicateAction, keepA: Bool = true) {
        switch action {
        case .merge:
            if let rec = tree.merge(keep: keepA ? c.a : c.b, drop: keepA ? c.b : c.a) { merges.append(rec) }
        case .keepSeparate, .differentPeople:
            dismissedDuplicates.insert(c.id)
        case .investigate:
            break
        }
        refreshDuplicates()
        save()
    }

    func undo(_ m: MergeRecord) {
        tree.undo(m)
        merges.removeAll { $0.id == m.id }
        refreshDuplicates()
        save()
    }

    func setHome(_ id: String) {
        tree.homePersonID = id
        save()
        if let c = client { Task { _ = try? await c.setHomePerson(id) } }
    }

    // MARK: - Pathfinder

    func connection(_ a: String, _ b: String) -> RelationshipCalculator.Result {
        let r = RelationshipCalculator.findConnection(graph, a, b)
        highlightedPath = r.primary?.path ?? []
        return r
    }

    // MARK: - Research server

    func saveServer(url: String, token: String) {
        serverURL = url.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(serverURL, forKey: "serverURL")
        if !token.isEmpty { Keychain.setString(token.trimmingCharacters(in: .whitespaces), "api-token") }
        Task { await refreshServer() }
    }

    func setShareTree(_ on: Bool) {
        shareTreeWithServer = on
        UserDefaults.standard.set(on, forKey: "shareTree")
    }

    func uploadTree(_ text: String? = nil) async {
        guard let c = client else { message = BackendError.notConfigured.localizedDescription; return }
        do {
            for t in (text.map { [$0] } ?? rawGEDCOMs) { _ = try await c.uploadGEDCOM(t) }
            message = "Your tree was sent to your own research server."
            await refreshServer()
        } catch { message = error.localizedDescription }
    }

    func refreshServer() async {
        guard let c = client else { serverOnline = false; return }
        do {
            async let s = c.stats()
            async let g = c.goals()
            async let d = c.discoveries()
            async let a = c.activity()
            async let u = c.universes()
            (stats, goals, discoveries, activity, universes) = try await (s, g, d, a, u)
            serverOnline = true
            notifyNewDiscoveries()
        } catch {
            serverOnline = false
        }
    }

    func refreshGraphAndConnectors() async {
        guard let c = client else { return }
        remoteGraph = try? await c.graph()
        connectors = (try? await c.connectors()) ?? []
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshServer()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    func createGoal(_ text: String, budget: Int = 200, daily: Bool = false, start: Bool = true) async {
        guard let c = client else { message = BackendError.notConfigured.localizedDescription; return }
        do {
            _ = try await c.createGoal(text, budget: budget, schedule: daily ? "daily" : nil, start: start)
            await refreshServer()
        } catch { message = error.localizedDescription }
    }

    func goalAction(_ g: ResearchGoal, _ action: String) async {
        guard let c = client else { return }
        do { _ = try await c.goalAction(g.id, action); await refreshServer() }
        catch { message = error.localizedDescription }
    }

    func discoveryAction(_ d: Discovery, _ action: String) async {
        guard let c = client else { return }
        do { _ = try await c.discoveryAction(d.id, action); await refreshServer() }
        catch { message = error.localizedDescription }
    }

    // MARK: - Notifications

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func notifyNewDiscoveries() {
        let interesting = discoveries.filter {
            ($0.kind == "connection" || $0.kind == "identity_match") && !seenDiscoveryIDs.contains($0.id)
        }
        for d in interesting {
            let content = UNMutableNotificationContent()
            content.title = d.kind == "connection" ? "New family connection" : "Possible ancestor match"
            content.body = d.title
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "disc-\(d.id)", content: content, trigger: nil))
            seenDiscoveryIDs.insert(d.id)
        }
        UserDefaults.standard.set(Array(seenDiscoveryIDs), forKey: "seenDiscoveries")
    }

    // MARK: - DNA (private, local, consent-gated)

    func importDNA(_ data: Data) {
        do {
            let summary = try RawDNAParser.parse(String(decoding: data, as: UTF8.self))
            try EncryptedStore.write(data, name: "dna.enc")
            dnaSummary = summary
            save()
            message = "DNA file stored encrypted on this iPhone (\(summary.snpCount) markers). It is never uploaded."
        } catch { message = error.localizedDescription }
    }

    func deleteDNA() {
        try? FileManager.default.removeItem(at: EncryptedStore.directory.appendingPathComponent("dna.enc"))
        dnaSummary = nil
        save()
    }

    // MARK: - Export / delete

    func exportJSON() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(tree)) ?? Data()
    }

    func deleteEverything() {
        EncryptedStore.deleteAll()
        tree = FamilyTree(); merges = []; duplicates = []; dismissedDuplicates = []; rawGEDCOMs = []
        dnaSummary = nil; highlightedPath = []; lastImport = nil
        stopResearchLoop(); research = CreatorResearchEngine()
    }
}

enum DuplicateAction { case merge, keepSeparate, investigate, differentPeople }
