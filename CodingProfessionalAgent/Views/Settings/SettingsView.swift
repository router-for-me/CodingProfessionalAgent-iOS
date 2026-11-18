import SwiftUI

// Settings sheet with desktop connections and composer / behavior preferences (IMG_5449).
struct SettingsView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var localization = LocalizationManager.shared
    @State private var editMode: EditMode = .inactive
    @State private var editor: ConnectionEditorTarget?
    @State private var showsAddConnectionDialog = false
    @State private var showsTunnelSheet = false
    @AppStorage(PreferenceKey.collapseKeyboardAfterSend) private var collapseKeyboardAfterSend = true
    @AppStorage(PreferenceKey.showContextUsage) private var showContextUsage = false
    @AppStorage(PreferenceKey.wrapDiffLines) private var wrapDiffLines = true
    @AppStorage(PreferenceKey.notifyOnTurnComplete) private var notifyOnTurnComplete = true
    @AppStorage(PreferenceKey.liveActivityMode) private var liveActivityMode = LiveActivityMode.perComputer

    var body: some View {
        let _ = (locale, localization.revision)
        NavigationStack {
            List {
                Section {
                    ForEach(store.connections) { connection in
                        ConnectionRow(
                            connection: connection,
                            state: store.client(for: connection.id)?.state ?? .disconnected
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editor = .edit(connection)
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { store.connections[$0].id }
                        for id in ids {
                            store.remove(id)
                        }
                    }
                    .onMove { source, destination in
                        store.move(fromOffsets: source, toOffset: destination)
                    }

                    addConnectionRow
                } header: {
                    HStack {
                        sectionTitle(L10n.Settings.connections)
                        Spacer()
                        Button(L10n.Settings.disconnectAll) {
                            store.disconnectAll()
                        }
                        .font(.system(size: 15))
                        .foregroundStyle(.blue)
                        .disabled(!store.connections.contains(where: \.isEnabled))
                    }
                }

                Section {
                    Toggle(L10n.Settings.collapseKeyboardAfterSend, isOn: $collapseKeyboardAfterSend)
                    Toggle(L10n.Settings.showContextUsage, isOn: $showContextUsage)
                    LabeledContent(L10n.Settings.followUpMode, value: L10n.Settings.followUpDesktop)
                } header: {
                    sectionTitle(L10n.Settings.composer)
                }

                Section {
                    Toggle(L10n.Settings.notifyOnTurnComplete, isOn: $notifyOnTurnComplete)
                    Toggle(L10n.Settings.wrapDiffLines, isOn: $wrapDiffLines)
                    Picker(L10n.Settings.liveActivityMode, selection: $liveActivityMode) {
                        ForEach(LiveActivityMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .id("liveActivity-\(locale.identifier)-\(localization.revision)")
                    .pickerStyle(.menu)
                    .tint(Color.secondary)
                } header: {
                    sectionTitle(L10n.Settings.behavior)
                }

                Section {
                    Picker(L10n.Settings.language, selection: $localization.language) {
                        ForEach(AppLanguage.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .id("language-\(locale.identifier)-\(localization.revision)")
                    .pickerStyle(.menu)
                    .tint(Color.secondary)
                } header: {
                    sectionTitle(L10n.Settings.general)
                }
            }
            .font(.system(size: 17))
            .environment(\.editMode, $editMode)
            .navigationTitle(L10n.Settings.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(editMode.isEditing ? L10n.Common.done : L10n.Common.edit) {
                        withAnimation {
                            editMode = editMode.isEditing ? .inactive : .active
                        }
                    }
                    .tint(Color.primary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) {
                        dismiss()
                    }
                    .tint(Color.primary)
                }
            }
            .sheet(item: $editor) { target in
                ConnectionEditorSheet(target: target)
            }
            .sheet(isPresented: $showsTunnelSheet) {
                TunnelConnectionSheet()
            }
            .confirmationDialog(L10n.Connection.addDialogTitle, isPresented: $showsAddConnectionDialog, titleVisibility: .visible) {
                Button(L10n.Connection.addDirect) {
                    editor = .add
                }
                Button(L10n.Connection.addTunnel) {
                    showsTunnelSheet = true
                }
                Button(L10n.Common.cancel, role: .cancel) {}
            }
        }
    }

    private var addConnectionRow: some View {
        Button {
            showsAddConnectionDialog = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .light))
                    .frame(width: 34)
                Text(L10n.Settings.addConnection)
            }
            .foregroundStyle(.blue)
            .padding(.vertical, 6)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color.primary)
            .textCase(nil)
    }
}

enum ConnectionEditorTarget: Identifiable {
    case add
    case edit(DesktopConnection)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let connection): connection.id.uuidString
        }
    }
}

private struct ConnectionRow: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(\.locale) private var locale
    let connection: DesktopConnection
    let state: ConnectionState

    var body: some View {
        let _ = locale
        HStack(spacing: 14) {
            ConnectionIconImage(icon: connection.icon, color: .secondary)
                .font(.system(size: 24))
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(connection.displayName)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 9, height: 9)
                    Text(statusText)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: isEnabled)
                .labelsHidden()
                .tint(.green)
        }
        .padding(.vertical, 6)
    }

    private var isEnabled: Binding<Bool> {
        let store = store
        let id = connection.id
        return Binding(get: { connection.isEnabled }, set: { store.setEnabled(id, $0) })
    }

    private var statusText: String {
        guard connection.isEnabled else { return L10n.Connection.statusDisconnected }
        switch state {
        case .disconnected: return L10n.Connection.statusDisconnected
        case .connecting: return L10n.Connection.statusConnecting
        case .connected: return L10n.Connection.statusConnected
        case .failed(let message): return message
        }
    }

    private var statusColor: Color {
        guard connection.isEnabled else { return Color(.systemGray3) }
        switch state {
        case .disconnected: return Color(.systemGray3)
        case .connecting: return .orange
        case .connected: return Theme.online
        case .failed: return .red
        }
    }
}

// Outline-style connection icon; the palette keeps filled screen layers transparent.
struct ConnectionIconImage: View {
    let icon: ConnectionIcon
    let color: Color

    var body: some View {
        Image(systemName: icon.systemImage)
            .symbolRenderingMode(.palette)
            .foregroundStyle(color, Color.clear)
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            SettingsView()
        }
        .environment(ConnectionStore())
}
