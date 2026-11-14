import Foundation
import Observation

// Persists the configured desktop connections and owns one client per connection.
@MainActor
@Observable
final class ConnectionStore {
    private static let storageKey = "desktop.connections"

    private let defaults: UserDefaults
    private let persistsCredentials: Bool
    private(set) var connections: [DesktopConnection] = []
    @ObservationIgnored private var clients: [UUID: DesktopClient] = [:]
    @ObservationIgnored private var changeObservers: [UUID: @MainActor () -> Void] = [:]

    init(defaults: UserDefaults = .standard, persistsCredentials: Bool = true) {
        self.defaults = defaults
        self.persistsCredentials = persistsCredentials
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([DesktopConnection].self, from: data)
        {
            connections = saved
        }
        for connection in connections {
            let client = DesktopClient(connection: connection)
            clients[connection.id] = client
            if connection.isEnabled {
                client.start()
            }
        }
    }

    func client(for id: UUID) -> DesktopClient? {
        clients[id]
    }

    // Clients of the connections the user switched on, in list order.
    var enabledClients: [DesktopClient] {
        connections.filter(\.isEnabled).compactMap { clients[$0.id] }
    }

    func add(_ connection: DesktopConnection, password: String, tunnelAPIKey: String = "") {
        if persistsCredentials {
            KeychainStore.setPassword(password, for: connection.id)
            if connection.mode == .tunnel {
                KeychainStore.setTunnelAPIKey(tunnelAPIKey, for: connection.id)
            }
        }
        connections.append(connection)
        let client = DesktopClient(connection: connection)
        clients[connection.id] = client
        if connection.isEnabled {
            client.start()
        }
        save()
    }

    func update(_ connection: DesktopConnection, password: String, tunnelAPIKey: String = "") {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        let passwordChanged: Bool
        let apiKeyChanged: Bool
        if persistsCredentials {
            passwordChanged = (KeychainStore.password(for: connection.id) ?? "") != password
            if passwordChanged {
                KeychainStore.setPassword(password, for: connection.id)
            }
            apiKeyChanged = connection.mode == .tunnel
                && (KeychainStore.tunnelAPIKey(for: connection.id) ?? "") != tunnelAPIKey
            if apiKeyChanged {
                KeychainStore.setTunnelAPIKey(tunnelAPIKey, for: connection.id)
            }
        } else {
            passwordChanged = false
            apiKeyChanged = false
        }
        connections[index] = connection
        clients[connection.id]?.update(connection: connection, credentialsChanged: passwordChanged || apiKeyChanged)
        save()
    }

    func remove(_ id: UUID) {
        clients[id]?.stop()
        clients[id] = nil
        connections.removeAll { $0.id == id }
        if persistsCredentials {
            KeychainStore.deletePassword(for: id)
            KeychainStore.deleteTunnelAPIKey(for: id)
        }
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        connections.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].isEnabled = enabled
        if enabled {
            clients[id]?.start()
        } else {
            clients[id]?.stop()
        }
        save()
    }

    func disconnectAll() {
        for connection in connections where connection.isEnabled {
            setEnabled(connection.id, false)
        }
    }

    // Revalidates every enabled connection after the app returns to the foreground.
    func wake() {
        TunnelClientManager.shared.wakeAll()
        for client in enabledClients {
            client.wake()
        }
    }

    func addChangeObserver(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID()
        changeObservers[token] = handler
        return token
    }

    func removeChangeObserver(_ token: UUID) {
        changeObservers[token] = nil
    }

    private func notifyObservers() {
        for observer in Array(changeObservers.values) {
            observer()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(connections) {
            defaults.set(data, forKey: Self.storageKey)
        }
        notifyObservers()
    }
}
