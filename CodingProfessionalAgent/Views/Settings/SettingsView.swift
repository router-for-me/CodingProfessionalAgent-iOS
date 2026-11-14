import SwiftUI

// Settings sheet with desktop connections and composer / behavior preferences (IMG_5449).
struct SettingsView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .inactive
    @State private var editor: ConnectionEditorTarget?
    @State private var showsAddConnectionDialog = false
    @State private var showsTunnelSheet = false
    @AppStorage(PreferenceKey.collapseKeyboardAfterSend) private var collapseKeyboardAfterSend = true
    @AppStorage(PreferenceKey.showContextUsage) private var showContextUsage = false
    @AppStorage(PreferenceKey.followUpMode) private var followUpMode = FollowUpMode.queue
    @AppStorage(PreferenceKey.wrapDiffLines) private var wrapDiffLines = true
    @AppStorage(PreferenceKey.notifyOnTurnComplete) private var notifyOnTurnComplete = true
    @AppStorage(PreferenceKey.liveActivityMode) private var liveActivityMode = LiveActivityMode.perComputer

    var body: some View {
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
                        sectionTitle("连接")
                        Spacer()
                        Button("全部断开") {
                            store.disconnectAll()
                        }
                        .font(.system(size: 15))
                        .foregroundStyle(.blue)
                        .disabled(!store.connections.contains(where: \.isEnabled))
                    }
                }

                Section {
                    Toggle("发送后收起键盘", isOn: $collapseKeyboardAfterSend)
                    Toggle("显示上下文窗口使用情况", isOn: $showContextUsage)
                    Picker("后续消息处理方式", selection: $followUpMode) {
                        ForEach(FollowUpMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.secondary)
                } header: {
                    sectionTitle("编写器")
                }

                Section {
                    Toggle("任务完成通知", isOn: $notifyOnTurnComplete)
                    Toggle("代码差异行自动换行", isOn: $wrapDiffLines)
                    Picker("实时活动", selection: $liveActivityMode) {
                        ForEach(LiveActivityMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.secondary)
                } header: {
                    sectionTitle("行为")
                }
            }
            .font(.system(size: 17))
            .environment(\.editMode, $editMode)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(editMode.isEditing ? "完成" : "编辑") {
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
            .confirmationDialog("添加连接", isPresented: $showsAddConnectionDialog, titleVisibility: .visible) {
                Button("直连桌面端") {
                    editor = .add
                }
                Button("通过 CLIProxyAPI Tunnel 连接") {
                    showsTunnelSheet = true
                }
                Button("取消", role: .cancel) {}
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
                Text("添加连接")
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
    let connection: DesktopConnection
    let state: ConnectionState

    var body: some View {
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
        guard connection.isEnabled else { return "未连接" }
        switch state {
        case .disconnected: return "未连接"
        case .connecting: return "正在连接…"
        case .connected: return "已连接"
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
