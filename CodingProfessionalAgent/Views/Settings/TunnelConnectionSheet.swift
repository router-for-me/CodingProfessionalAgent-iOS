import SwiftUI

private struct ConnectedTunnelContext {
    let endpoint: TunnelEndpoint
    let apiKey: String
    let session: TunnelSession

    var configKey: String {
        "\(endpoint.webSocketBaseURL)\n\(apiKey)"
    }
}

private struct SelectedTunnelServerTarget: Hashable {
    let server: DiscoveredTunnelServer
    let endpoint: TunnelEndpoint
    let apiKey: String
}

// Two-step sheet that registers this iPhone as a CLIProxyAPI /v1/tunnel client,
// discovers online CPA desktop servers, and adds the selected server connection.
struct TunnelConnectionSheet: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    @State private var baseURL: String
    @State private var apiKey: String
    @State private var connectedContext: ConnectedTunnelContext?
    @State private var searchLeaseID: UUID?
    @State private var connectError: String?
    @State private var hasAttemptedConnect = false
    @State private var navigationPath: [SelectedTunnelServerTarget] = []

    init() {
        let savedURL = UserDefaults.standard.string(forKey: PreferenceKey.lastTunnelBaseURL) ?? ""
        let savedKey = KeychainStore.lastTunnelAPIKey() ?? ""
        _baseURL = State(initialValue: savedURL)
        _apiKey = State(initialValue: savedKey)
    }

    var body: some View {
        let _ = locale
        NavigationStack(path: $navigationPath) {
            Form {
                gatewaySection
                if let connectedContext {
                    serversSection(context: connectedContext)
                }
            }
            .font(.system(size: 17))
            .navigationTitle("CLIProxyAPI Tunnel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) {
                        dismiss()
                    }
                    .tint(Color.primary)
                }
            }
            .navigationDestination(for: SelectedTunnelServerTarget.self) { target in
                TunnelServerDetailView(
                    server: target.server,
                    endpoint: target.endpoint,
                    apiKey: target.apiKey
                ) { connection, password in
                    UserDefaults.standard.set(target.endpoint.normalizedBaseURL, forKey: PreferenceKey.lastTunnelBaseURL)
                    KeychainStore.setLastTunnelAPIKey(target.apiKey)
                    store.add(connection, password: password, tunnelAPIKey: target.apiKey)
                    releaseSearchLease()
                    dismiss()
                }
            }
        }
        .presentationDetents([.large])
        .onChange(of: connectedContext?.session.phase) { _, newPhase in
            if newPhase == .connected, let connectedContext {
                UserDefaults.standard.set(connectedContext.endpoint.normalizedBaseURL, forKey: PreferenceKey.lastTunnelBaseURL)
                KeychainStore.setLastTunnelAPIKey(connectedContext.apiKey)
            }
        }
        .onDisappear {
            releaseSearchLease()
        }
    }

    private var gatewaySection: some View {
        Section {
            LabeledContent(L10n.Tunnel.urlLabel) {
                TextField("https://example.com:8317", text: $baseURL)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            LabeledContent("API Key") {
                SecureField(L10n.Common.required, text: $apiKey)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Button {
                connectAndSearch()
            } label: {
                HStack(spacing: 10) {
                    if isSearchingCurrentConfig {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(connectButtonTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(!canConnect || isSearchingCurrentConfig)
        } header: {
            Text(L10n.Tunnel.serviceSection)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let validationMessage {
                    Text(validationMessage)
                        .foregroundStyle(.red)
                } else if let connectError {
                    Text(connectError)
                        .foregroundStyle(.red)
                }
                Text(L10n.Tunnel.gatewayHint)
            }
        }
    }

    @ViewBuilder
    private func serversSection(context: ConnectedTunnelContext) -> some View {
        let session = context.session
        Section {
            if !isConnectedToCurrentConfig {
                Text(L10n.Tunnel.configChangedPrompt)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                switch session.phase {
                case .connecting:
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.Tunnel.registering)
                            .foregroundStyle(.secondary)
                    }
                case .reconnecting(let attempt):
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.Tunnel.reconnectingAttempt(attempt))
                            .foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(message)
                                .font(.system(size: 15))
                                .foregroundStyle(.red)
                        }
                        Button(L10n.Tunnel.retryConnect) {
                            session.retryNow()
                        }
                        .font(.system(size: 15, weight: .medium))
                    }
                    .padding(.vertical, 4)
                case .connected:
                    if !session.hasReceivedInitialServerList {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text(L10n.Tunnel.syncingServers)
                                .foregroundStyle(.secondary)
                        }
                    } else if session.servers.isEmpty {
                        Text(L10n.Tunnel.noOnlineServers)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(session.servers) { server in
                            serverRow(server, context: context)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text(L10n.Tunnel.onlineServersSection)
                Spacer()
                if isConnectedToCurrentConfig, session.phase == .connected {
                    Button {
                        session.refreshServers()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text(L10n.Common.refresh)
                        }
                        .font(.system(size: 14))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func serverRow(_ server: DiscoveredTunnelServer, context: ConnectedTunnelContext) -> some View {
        let added = isAlreadyAdded(server: server, endpoint: context.endpoint)
        if added {
            HStack(spacing: 14) {
                ConnectionIconImage(icon: .display, color: .secondary)
                    .font(.system(size: 22))
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(server.uuid)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                Text(L10n.Tunnel.added)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        } else {
            let target = SelectedTunnelServerTarget(
                server: server,
                endpoint: context.endpoint,
                apiKey: context.apiKey
            )
            NavigationLink(value: target) {
                HStack(spacing: 14) {
                    ConnectionIconImage(icon: .display, color: .primary)
                        .font(.system(size: 22))
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(server.uuid)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Validation & Actions

    private var parsedEndpoint: Result<TunnelEndpoint, TunnelProtocolError> {
        TunnelProtocol.parseEndpoint(baseURL)
    }

    private var validatedAPIKey: Result<String, TunnelProtocolError> {
        TunnelProtocol.validateAPIKey(apiKey)
    }

    private var canConnect: Bool {
        if case .success = parsedEndpoint, case .success = validatedAPIKey {
            return true
        }
        return false
    }

    private var currentConfigKey: String? {
        guard let endpoint = try? parsedEndpoint.get(),
              let key = try? validatedAPIKey.get()
        else {
            return nil
        }
        return "\(endpoint.webSocketBaseURL)\n\(key)"
    }

    private var isConnectedToCurrentConfig: Bool {
        guard let key = currentConfigKey, let connectedContext else { return false }
        return key == connectedContext.configKey
    }

    private var isSearchingCurrentConfig: Bool {
        guard isConnectedToCurrentConfig, let phase = connectedContext?.session.phase else { return false }
        if case .connecting = phase {
            return true
        }
        return false
    }

    private var connectButtonTitle: String {
        if isSearchingCurrentConfig {
            return L10n.Connection.statusConnecting
        }
        if isConnectedToCurrentConfig {
            return L10n.Tunnel.searchAgain
        }
        return connectedContext == nil ? L10n.Tunnel.connectAndSearch : L10n.Tunnel.switchGatewayAndSearch
    }

    private var validationMessage: String? {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedURL.isEmpty, case .failure(let error) = parsedEndpoint {
            return error.localizedDescription
        }
        if hasAttemptedConnect {
            if case .failure(let error) = parsedEndpoint {
                return error.localizedDescription
            }
            if case .failure(let error) = validatedAPIKey {
                return error.localizedDescription
            }
        }
        return nil
    }

    private func isAlreadyAdded(server: DiscoveredTunnelServer, endpoint: TunnelEndpoint) -> Bool {
        let candidate = DesktopConnection.tunnel(
            name: "",
            tunnelBaseURL: endpoint.normalizedBaseURL,
            serverUUID: server.uuid,
            serverName: server.name,
            icon: .display
        )
        return store.connections.contains { $0.hasSameEndpoint(as: candidate) }
    }

    private func connectAndSearch() {
        hasAttemptedConnect = true
        connectError = nil
        guard let endpoint = try? parsedEndpoint.get(),
              let validKey = try? validatedAPIKey.get()
        else {
            return
        }
        let nextKey = "\(endpoint.webSocketBaseURL)\n\(validKey)"
        if let existing = connectedContext, existing.configKey == nextKey {
            if case .failed = existing.session.phase {
                existing.session.retryNow()
            } else {
                existing.session.refreshServers()
            }
            return
        }

        releaseSearchLease()
        do {
            let (session, leaseID) = try TunnelClientManager.shared.acquireSession(
                baseURL: endpoint.normalizedBaseURL,
                apiKey: validKey
            )
            connectedContext = ConnectedTunnelContext(
                endpoint: endpoint,
                apiKey: validKey,
                session: session
            )
            searchLeaseID = leaseID
            if session.phase == .connected {
                UserDefaults.standard.set(endpoint.normalizedBaseURL, forKey: PreferenceKey.lastTunnelBaseURL)
                KeychainStore.setLastTunnelAPIKey(validKey)
            }
        } catch {
            connectError = error.localizedDescription
        }
    }

    private func releaseSearchLease() {
        if let leaseID = searchLeaseID {
            TunnelClientManager.shared.releaseLease(leaseID)
            searchLeaseID = nil
        }
        connectedContext = nil
    }
}

// Second step: configures display name, icon, and optional desktop Web password for a discovered server.
private struct TunnelServerDetailView: View {
    @Environment(\.locale) private var locale
    let server: DiscoveredTunnelServer
    let endpoint: TunnelEndpoint
    let apiKey: String
    let onSave: (DesktopConnection, String) -> Void

    @State private var icon: ConnectionIcon = .display
    @State private var name: String
    @State private var password = ""

    init(
        server: DiscoveredTunnelServer,
        endpoint: TunnelEndpoint,
        apiKey: String,
        onSave: @escaping (DesktopConnection, String) -> Void
    ) {
        self.server = server
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.onSave = onSave
        _name = State(initialValue: server.name)
    }

    var body: some View {
        let _ = locale
        Form {
            Section {
                HStack {
                    Text(L10n.Connection.icon)
                    Spacer()
                    iconPicker
                }

                LabeledContent(L10n.Connection.displayName) {
                    TextField(server.name, text: $name)
                        .multilineTextAlignment(.trailing)
                }

                LabeledContent(L10n.Connection.password) {
                    SecureField(L10n.Connection.passwordPlaceholder, text: $password)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                }
            } footer: {
                Text(L10n.Tunnel.detailPasswordHint)
            }

            Section(L10n.Tunnel.infoSection) {
                LabeledContent(L10n.Connection.remoteServer) {
                    Text(server.name)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                LabeledContent("CLIProxyAPI") {
                    Text(endpoint.normalizedBaseURL)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .font(.system(size: 17))
        .navigationTitle(L10n.Tunnel.addRemoteServerTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.Common.save) {
                    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let connection = DesktopConnection.tunnel(
                        name: trimmedName,
                        tunnelBaseURL: endpoint.normalizedBaseURL,
                        serverUUID: server.uuid,
                        serverName: server.name,
                        icon: icon
                    )
                    onSave(connection, password)
                }
            }
        }
    }

    private var iconPicker: some View {
        HStack(spacing: 18) {
            ForEach(ConnectionIcon.allCases) { item in
                Button {
                    icon = item
                } label: {
                    ConnectionIconImage(icon: item, color: item == icon ? Color.primary : Color(.systemGray3))
                        .font(.system(size: 24, weight: item == icon ? .semibold : .regular))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(item.rawValue))
                .accessibilityAddTraits(item == icon ? .isSelected : [])
            }
        }
    }
}
