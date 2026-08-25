import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            LibraryView()
        }
        .tint(Theme.accent)
        .task { await model.performLaunchTasks() }
        .onChange(of: scenePhase) { phase in
            model.handleScenePhaseChange(toBackground: phase == .background)
        }
    }
}
