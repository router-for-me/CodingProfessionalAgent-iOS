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
    @ObservationIgnored private var willRemoveObservers: [UUID: @MainActor (UUID) -> Task<Void, Never>?] = [:]

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
        let cleanupTasks = Array(willRemoveObservers.values).compactMap { $0(id) }
        let removedClient = clients.removeValue(forKey: id)
        connections.removeAll { $0.id == id }
        if persistsCredentials {
            KeychainStore.deletePassword(for: id)
            KeychainStore.deleteTunnelAPIKey(for: id)
        }
        save()
        guard let removedClient else { return }
        if cleanupTasks.isEmpty {
            removedClient.stop()
        } else {
            RemovalStopCoordinator(cleanupTasks: cleanupTasks, client: removedClient).start()
        }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        connections.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].isEnabled = enabled
        clients[id]?.update(connection: connections[index], credentialsChanged: false)
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

    func addWillRemoveObserver(_ handler: @escaping @MainActor (UUID) -> Task<Void, Never>?) -> UUID {
        let token = UUID()
        willRemoveObservers[token] = handler
        return token
    }

    func removeWillRemoveObserver(_ token: UUID) {
        willRemoveObservers[token] = nil
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

// Bounds the wait for pre-removal unregister RPCs so an unresponsive desktop cannot delay socket closure.
@MainActor
private final class RemovalStopCoordinator {
    private var didStop = false
    private var cleanupTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private let cleanupTasks: [Task<Void, Never>]
    private let client: DesktopClient

    init(cleanupTasks: [Task<Void, Never>], client: DesktopClient) {
        self.cleanupTasks = cleanupTasks
        self.client = client
    }

    func start(timeout: Duration = .milliseconds(500)) {
        cleanupTask = Task { @MainActor in
            for task in cleanupTasks {
                await task.value
                if didStop { return }
            }
            finish()
        }
        deadlineTask = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            finish()
        }
    }

    private func finish() {
        guard !didStop else { return }
        didStop = true
        deadlineTask?.cancel()
        deadlineTask = nil
        cleanupTask?.cancel()
        cleanupTask = nil
        for task in cleanupTasks {
            task.cancel()
        }
        client.stop()
    }
}
