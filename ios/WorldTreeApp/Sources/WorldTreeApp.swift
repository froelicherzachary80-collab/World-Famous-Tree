import SwiftUI

@main
struct WorldTreeAIApp: App {
    @StateObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BackgroundResearch.registerLaunchHandlers()   // must happen before launch finishes
        // Create the model now (not lazily) so a background launch by iOS can resume research.
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(Theme.gold)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                model.save()
                BackgroundResearch.shared.appDidEnterBackground()
            case .active:
                BackgroundResearch.shared.appDidBecomeActive()
            default:
                break
            }
        }
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case home = "Home", tree = "World Tree", research = "AI Research", famous = "Famous", discoveries = "Discoveries", profile = "Profile"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .tree: return "tree.fill"
        case .research: return "sparkle.magnifyingglass"
        case .famous: return "star.circle.fill"
        case .discoveries: return "lightbulb.fill"
        case .profile: return "person.crop.circle"
        }
    }
}

/// Six main tabs with a custom bar (the system bar would hide two of them behind "More" on iPhone).
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab: AppTab = .home

    var body: some View {
        TabView(selection: $tab) {
            HomeView().tag(AppTab.home)
            WorldTreeGraphView().tag(AppTab.tree)
            ResearchView().tag(AppTab.research)
            FamousFamiliesView().tag(AppTab.famous)
            DiscoveriesView().tag(AppTab.discoveries)
            ProfileView().tag(AppTab.profile)
        }
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) { bar }
        .alert("WORLD TREE AI", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.message ?? "") }
        .task { await model.refreshServer() }
    }

    private var badge: Int {
        model.duplicates.count + model.discoveries.filter { $0.status == "pending" }.count
            + model.research.discoveries.filter { $0.status == .pending }.count
    }

    private var bar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { t in
                Button {
                    withAnimation(.snappy) { tab = t }
                } label: {
                    VStack(spacing: 3) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: t.icon).font(.system(size: 19, weight: .semibold))
                                .shadow(color: tab == t ? Theme.gold.opacity(0.8) : .clear, radius: 6)
                            if t == .discoveries && badge > 0 {
                                Text("\(min(badge, 99))").font(.system(size: 9, weight: .bold))
                                    .padding(3).background(Theme.danger, in: Circle()).offset(x: 9, y: -6)
                            }
                        }
                        Text(t == .research ? "Research" : t.rawValue).font(.system(size: 9.5, weight: .medium)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(tab == t ? Theme.gold : .white.opacity(0.6))
                }
                .accessibilityLabel(t.rawValue)
                .accessibilityIdentifier("tab-\(t.rawValue)")
                .accessibilityAddTraits(tab == t ? .isSelected : [])
            }
        }
        .padding(.horizontal, 4)
        .background(.ultraThinMaterial)
        .background(Theme.night.opacity(0.7))
        .overlay(alignment: .top) { Rectangle().fill(Theme.gold.opacity(0.2)).frame(height: 0.5) }
    }
}
