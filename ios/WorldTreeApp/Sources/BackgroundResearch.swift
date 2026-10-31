import BackgroundTasks
import UIKit
import UserNotifications
import WorldTreeCore

/// Keeps on-device research going after you leave the app — but never after you swipe it away
/// (iOS ends all of an app's work when it is force-quit, which is exactly the rule you asked for).
///
/// * iOS 26+: a BGContinuedProcessingTask is submitted when you tap "Research". iOS keeps the app
///   running in the background with a system progress indicator until the queue is done.
/// * iOS 17–25: ~30 s of extra time when leaving the app, then iOS-scheduled background slots
///   (BGProcessingTask / BGAppRefreshTask) continue the saved queue whenever iOS allows.
@MainActor
final class BackgroundResearch {
    static let shared = BackgroundResearch()
    nonisolated static let refreshID = "ai.worldtree.app.research.refresh"
    nonisolated static let processingID = "ai.worldtree.app.research.processing"
    nonisolated static let continuedPrefix = "ai.worldtree.app.research.continued."

    weak var model: AppModel?
    private var continuedTask: AnyObject?          // BGContinuedProcessingTask (iOS 26+)
    private var slotTask: BGTask?                  // BGProcessingTask / BGAppRefreshTask
    private var extraTime: UIBackgroundTaskIdentifier = .invalid
    private(set) var mode: String = "Foreground"

    /// Must run before the app finishes launching.
    nonisolated static func registerLaunchHandlers() {
        for id in [refreshID, processingID] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
                Task { @MainActor in BackgroundResearch.shared.runSlot(task) }
            }
        }
    }

    // MARK: Starting

    /// Call from the user's tap in the foreground.
    func userStartedResearch() {
        model?.startResearchLoop()
        if #available(iOS 26.0, *) { submitContinued() }
    }

    @available(iOS 26.0, *)
    private func submitContinued() {
        guard continuedTask == nil else { return }
        let id = Self.continuedPrefix + UUID().uuidString
        // Apple requires a handler registered for this exact identifier before submitting.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
            Task { @MainActor in BackgroundResearch.shared.attachContinued(task) }
        }
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: "World Tree research",
                                                       subtitle: "Researching creator family trees")
        request.strategy = .queue
        do { try BGTaskScheduler.shared.submit(request) }
        catch { model?.researchNote("Background continuation unavailable: \(error.localizedDescription)") }
    }

    @available(iOS 26.0, *)
    private func attachContinued(_ task: BGTask) {
        guard let t = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
        continuedTask = t
        mode = "Continuing in background (iOS)"
        t.expirationHandler = {
            Task { @MainActor in
                BackgroundResearch.shared.model?.stopResearchLoop()
                BackgroundResearch.shared.finish(success: false)
            }
        }
        updateProgress()
        model?.startResearchLoop()
        if model?.research.isIdle ?? true { finish(success: true) }
    }

    private func runSlot(_ task: BGTask) {
        scheduleSlots()   // always line up the next opportunity
        guard let model, !model.research.isIdle else { task.setTaskCompleted(success: true); return }
        slotTask = task
        mode = "iOS background slot"
        task.expirationHandler = {
            Task { @MainActor in
                BackgroundResearch.shared.model?.stopResearchLoop()
                BackgroundResearch.shared.finish(success: false)
            }
        }
        model.startResearchLoop()
    }

    // MARK: App lifecycle

    func appDidEnterBackground() {
        guard let model, !model.research.isIdle else { return }
        if continuedTask == nil && extraTime == .invalid {
            extraTime = UIApplication.shared.beginBackgroundTask(withName: "WorldTreeResearch") {
                Task { @MainActor in BackgroundResearch.shared.endExtraTime() }
            }
        }
        scheduleSlots()
    }

    func appDidBecomeActive() {
        endExtraTime()
        mode = continuedTask == nil ? "Foreground" : mode
        if let model, !model.research.isIdle { model.startResearchLoop() }
    }

    func scheduleSlots() {
        guard let model, !model.research.isIdle else { return }
        let processing = BGProcessingTaskRequest(identifier: Self.processingID)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(processing)
        let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(refresh)
    }

    // MARK: Progress / completion

    func updateProgress() {
        guard let model else { return }
        if #available(iOS 26.0, *), let t = continuedTask as? BGContinuedProcessingTask {
            let done = Int64(model.research.completedJobs)
            t.progress.totalUnitCount = max(1, done + Int64(model.research.pendingCount))
            t.progress.completedUnitCount = done
        }
    }

    /// Called by the research loop when the queue is empty or work stopped.
    func finish(success: Bool) {
        if #available(iOS 26.0, *), let t = continuedTask as? BGContinuedProcessingTask {
            t.setTaskCompleted(success: success)
        }
        continuedTask = nil
        slotTask?.setTaskCompleted(success: success)
        slotTask = nil
        endExtraTime()
        mode = "Foreground"
    }

    private func endExtraTime() {
        if extraTime != .invalid {
            UIApplication.shared.endBackgroundTask(extraTime)
            extraTime = .invalid
        }
    }

    func notify(_ d: LocalDiscovery) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = d.kind == .connection ? "New family connection" : d.kind == .identityMatch ? "Possible ancestor match" : "Research update"
        content.body = d.title
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: d.id.uuidString, content: content, trigger: nil))
    }
}
