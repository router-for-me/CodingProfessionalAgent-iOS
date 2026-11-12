import SwiftUI

// Sheet for adding a direct desktop connection or editing an existing direct / tunnel connection.
struct ConnectionEditorSheet: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    private let original: DesktopConnection?
    @State private var icon: ConnectionIcon
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var password: String
    @State private var tunnelBaseURL: String
    @State private var tunnelAPIKey: String

    init(target: ConnectionEditorTarget) {
        let original: DesktopConnection?
        switch target {
        case .add:
            original = nil
        case .edit(let connection):
            original = connection
        }
        self.original = original
        _icon = State(initialValue: original?.icon ?? .display)
        _name = State(initialValue: original?.name ?? "")
        _host = State(initialValue: original?.host ?? "")
        _port = State(initialValue: original.map { $0.port > 0 ? String($0.port) : "18080" } ?? "18080")
        _password = State(initialValue: original.flatMap { KeychainStore.password(for: $0.id) } ?? "")
        _tunnelBaseURL = State(initialValue: original?.tunnelBaseURL ?? "")
        _tunnelAPIKey = State(initialValue: original.flatMap { KeychainStore.tunnelAPIKey(for: $0.id) } ?? "")
    }

    private var isTunnelMode: Bool {
        original?.mode == .tunnel
    }

    var body: some View {
        NavigationStack {
            Form {
                if isTunnelMode {
                    tunnelSection
                } else {
                    directSection
                }

                if let original {
                    Section {
                        Button("删除连接", role: .destructive) {
                            store.remove(original.id)
                            dismiss()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .font(.system(size: 17))
            .navigationTitle(original == nil ? "添加桌面端" : "编辑桌面端")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .tint(Color.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var directSection: some View {
        Section {
            HStack {
                Text("图标")
                Spacer()
                iconPicker
            }

            LabeledContent("显示名称") {
                TextField("选填", text: $name)
                    .multilineTextAlignment(.trailing)
            }

            LabeledContent("主机") {
                TextField("192.168.1.10", text: $host)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            LabeledContent("端口") {
                TextField("18080", text: $port)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
            }

            LabeledContent("密码") {
                SecureField("未设置可留空", text: $password)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let error = parsedAddress.error {
                    Text(error)
                        .foregroundStyle(.red)
                }
                Text("请先在桌面端「设置 → 连接 → Web 服务器」中启用 Web 服务，并将绑定 IP 设为 0.0.0.0（允许局域网访问），然后在此填写电脑的 IP、服务端口与 Web 访问密码。")
            }
        }
    }

    private var tunnelSection: some View {
        Section {
            HStack {
                Text("图标")
                Spacer()
                iconPicker
            }

            LabeledContent("显示名称") {
                TextField(tunnelServerDisplayLabel, text: $name)
                    .multilineTextAlignment(.trailing)
            }

            LabeledContent("CLIProxyAPI") {
                TextField("https://example.com:8317", text: $tunnelBaseURL)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            LabeledContent("API Key") {
                SecureField("必填", text: $tunnelAPIKey)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            LabeledContent("远程服务器") {
                Text(tunnelServerDisplayLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            LabeledContent("密码") {
                SecureField("未设置可留空", text: $password)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let error = tunnelValidationError {
                    Text(error)
                        .foregroundStyle(.red)
                }
                Text("通过 CLIProxyAPI Tunnel 连接远程桌面端；密码对应远程桌面端的 Web 访问密码（未设置可留空）。")
            }
        }
    }

    private var tunnelServerDisplayLabel: String {
        guard let original else { return "选填" }
        let trimmed = original.tunnelServerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? original.tunnelServerUUID : trimmed
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

    private struct ParsedAddress {
        var host = ""
        var port: Int?
        var error: String?
    }

    // Accepts plain hosts as well as pasted addresses such as "http://192.168.1.10:18080/".
    private var parsedAddress: ParsedAddress {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ParsedAddress() }
        if let separator = trimmed.range(of: "://") {
            // The desktop Web server only speaks plain HTTP / WebSocket.
            let scheme = trimmed[..<separator.lowerBound].lowercased()
            guard scheme == "http" || scheme == "ws" else {
                return ParsedAddress(error: "暂不支持 \(scheme) 加密连接，请填写 IP 或 http 地址。")
            }
        }
        // Bare IPv6 literals cannot be parsed as URLs; keep them as typed.
        if !trimmed.contains("://"), trimmed.filter({ $0 == ":" }).count > 1, !trimmed.hasPrefix("[") {
            return ParsedAddress(host: trimmed)
        }
        let candidate = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let components = URLComponents(string: candidate), let parsedHost = components.host, !parsedHost.isEmpty else {
            return ParsedAddress(error: "主机地址无效。")
        }
        let bareHost = parsedHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return ParsedAddress(host: bareHost, port: components.port)
    }

    private var portNumber: Int? {
        if let embedded = parsedAddress.port {
            return (1...65535).contains(embedded) ? embedded : nil
        }
        guard let value = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(value) else {
            return nil
        }
        return value
    }

    private var tunnelValidationError: String? {
        let trimmedURL = tunnelBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedURL.isEmpty, case .failure(let error) = TunnelProtocol.parseEndpoint(tunnelBaseURL) {
            return error.localizedDescription
        }
        let trimmedKey = tunnelAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty, case .failure(let error) = TunnelProtocol.validateAPIKey(tunnelAPIKey) {
            return error.localizedDescription
        }
        return nil
    }

    private var canSave: Bool {
        if isTunnelMode {
            if case .success = TunnelProtocol.parseEndpoint(tunnelBaseURL),
               case .success = TunnelProtocol.validateAPIKey(tunnelAPIKey)
            {
                return true
            }
            return false
        }
        let address = parsedAddress
        return address.error == nil && !address.host.isEmpty && portNumber != nil
    }

    private func save() {
        if isTunnelMode {
            guard var connection = original,
                  let endpoint = try? TunnelProtocol.parseEndpoint(tunnelBaseURL).get(),
                  let validAPIKey = try? TunnelProtocol.validateAPIKey(tunnelAPIKey).get()
            else {
                return
            }
            connection.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            connection.icon = icon
            connection.tunnelBaseURL = endpoint.normalizedBaseURL
            UserDefaults.standard.set(endpoint.normalizedBaseURL, forKey: PreferenceKey.lastTunnelBaseURL)
            KeychainStore.setLastTunnelAPIKey(validAPIKey)
            store.update(connection, password: password, tunnelAPIKey: validAPIKey)
            dismiss()
            return
        }

        guard let portNumber else { return }
        var connection = original ?? DesktopConnection(name: "", host: "", port: portNumber, icon: icon)
        connection.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.host = parsedAddress.host
        connection.port = portNumber
        connection.icon = icon
        if original == nil {
            store.add(connection, password: password)
        } else {
            store.update(connection, password: password)
        }
        dismiss()
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            ConnectionEditorSheet(target: .add)
        }
        .environment(ConnectionStore())
}
