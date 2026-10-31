import Foundation
import WorldTreeCore

/// On-device creator research (no server needed). Runs while the app is open or in the background,
/// stops when the app is swiped away, and resumes from the saved queue next time.
extension AppModel {
    func researchCreators(_ text: String) {
        let handles = CreatorResearchEngine.parseHandles(text)
        guard !handles.isEmpty else { return }
        research.addCreators(handles)
        save()
        requestNotificationPermission()
        BackgroundResearch.shared.userStartedResearch()
    }

    func researchNote(_ message: String) {
        research.log.insert(ResearchLogEntry(agent: "Genealogy Director AI", message: message), at: 0)
    }

    func startResearchLoop() {
        guard researchTask == nil, !research.isIdle else { return }
        researchRunning = true
        let client = WikidataClient()
        researchTask = Task { [weak self] in
            var sinceSave = 0
            while !Task.isCancelled {
                guard let self, let job = self.research.nextJob() else { break }
                let before = self.research.discoveries.count
                do {
                    let output = try await CreatorResearchEngine.perform(job, client: client)   // network, off the main actor
                    var engine = self.research
                    var tree = self.tree
                    engine.apply(output, for: job, to: &tree)
                    self.tree = tree
                    self.research = engine
                } catch {
                    self.research.fail(job, error: error)
                }
                for d in self.research.discoveries.dropFirst(before) where d.kind != .privacyNote {
                    BackgroundResearch.shared.notify(d)
                }
                BackgroundResearch.shared.updateProgress()
                sinceSave += 1
                if sinceSave >= 5 { self.save(); sinceSave = 0 }
                try? await Task.sleep(nanoseconds: 600_000_000)   // be polite to Wikidata (~1–2 requests/s)
            }
            guard let self else { return }
            self.researchTask = nil
            self.researchRunning = false
            self.refreshDuplicates()
            self.save()
            if self.research.isIdle { BackgroundResearch.shared.finish(success: true) }
        }
    }

    func stopResearchLoop() {
        researchTask?.cancel()
        researchTask = nil
        researchRunning = false
        save()
    }

    func clearResearchQueue() {
        stopResearchLoop()
        research.queue.removeAll()
        BackgroundResearch.shared.finish(success: true)
        save()
    }

    func confirmLocalMatch(_ d: LocalDiscovery) {
        var engine = research
        var t = tree
        let rec = engine.confirmMatch(d.id, tree: &t)
        tree = t
        research = engine
        if let rec { merges.append(rec) }
        if let connection = research.discoveries.last(where: { $0.kind == .connection }) {
            highlightedPath = connection.personIDs.count == 2
                ? (RelationshipCalculator.findConnection(graph, connection.personIDs[0], connection.personIDs[1]).primary?.path ?? [])
                : []
        }
        refreshDuplicates()
        save()
    }

    func rejectLocalMatch(_ d: LocalDiscovery) {
        research.rejectMatch(d.id)
        save()
    }
}
