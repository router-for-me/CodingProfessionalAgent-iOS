import SwiftUI
import UIKit

// Context used to prefill the new thread screen.
struct NewThreadContext: Hashable {
    var connectionId: UUID?
    var projectId: String?
    var prompt = ""
    var skillReferences: [SkillReference] = []
    // Speed picked with the home composer's "/" menu; nil keeps the desktop default.
    var speed: SpeedMode?
    // Opens the model settings right away ("/" model command on the home composer).
    var opensModelSettings = false
}

// Destinations that can be pushed onto the main navigation stack.
enum Route: Hashable {
    case thread(connectionId: UUID, sessionId: String)
    case newThread(NewThreadContext)
    // A sub-agent's own conversation (`sessionId`), launched by `parentSessionId`.
    case subAgent(connectionId: UUID, parentSessionId: String, agentId: String, sessionId: String)
}

// Shared navigation state so any screen can push a new destination.
@MainActor
@Observable
final class Router {
    var path: [Route] = []
    private(set) var externalNavigationRevision = 0

    func push(_ route: Route) {
        path.append(route)
    }

    // Replaces the top destination, e.g. the new thread screen with the created thread.
    func replaceTop(with route: Route) {
        if path.isEmpty {
            path.append(route)
        } else {
            path[path.count - 1] = route
        }
    }

    // Navigates directly to a conversation from an external trigger such as a notification tap.
    func openThread(connectionId: UUID, sessionId: String) {
        externalNavigationRevision += 1
        let destination = Route.thread(connectionId: connectionId, sessionId: sessionId)
        if path != [destination] {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                path = [destination]
            }
        }
    }
}

extension EnvironmentValues {
    // Width of the enclosing navigation stack, known before a pushed screen lays out its own body.
    @Entry var navigationWidth: CGFloat = 0
}

@MainActor
enum NavigationLayout {
    // Width of the enclosing navigation stack, falling back to the active window when a screen
    // renders before the root stack's first geometry pass or in a standalone preview.
    static func containerWidth(_ inherited: CGFloat) -> CGFloat {
        if inherited > 0 {
            return inherited
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
        let window = scene?.keyWindow ?? scene?.windows.first
        return window?.bounds.width ?? 0
    }

    // Leading toolbar title width after reserving space for the back button and any trailing items.
    static func titleWidth(containerWidth: CGFloat, reservedWidth: CGFloat) -> CGFloat {
        max(Self.containerWidth(containerWidth) - reservedWidth, 120)
    }
}
