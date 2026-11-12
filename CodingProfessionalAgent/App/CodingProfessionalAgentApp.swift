import SwiftUI

@main
struct CodingProfessionalAgentApp: App {
    @State private var router = Router()
    @State private var store = ConnectionStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(router)
                .environment(store)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.wake()
            }
        }
    }
}

