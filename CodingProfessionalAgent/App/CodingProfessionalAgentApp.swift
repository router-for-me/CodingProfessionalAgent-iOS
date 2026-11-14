import SwiftUI
import UIKit

@main
struct CodingProfessionalAgentApp: App {
    @State private var router: Router
    @State private var store: ConnectionStore
    @State private var notificationCoordinator: TurnNotificationCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PreferenceKey.notifyOnTurnComplete) private var notifyOnTurnComplete = true

    init() {
        let router = Router()
        let store = ConnectionStore()
        let coordinator = TurnNotificationCoordinator(
            store: store,
            router: router,
            initialActive: UIApplication.shared.applicationState == .active
        )
        _router = State(initialValue: router)
        _store = State(initialValue: store)
        _notificationCoordinator = State(initialValue: coordinator)
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(router)
                .environment(store)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            notificationCoordinator.setAppActive(phase == .active)
            if phase == .active {
                store.wake()
            }
        }
        .onChange(of: notifyOnTurnComplete) { _, isEnabled in
            notificationCoordinator.setNotificationsEnabled(isEnabled)
        }
    }
}
