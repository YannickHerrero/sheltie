import SheltieProtocol
import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: AppStore
    var onSelection: (() -> Void)? = nil
    @State private var isCreatingWorkspace = false
    @State private var workspaceToRename: WorkspaceSnapshot?
    @State private var renameText = ""
    @State private var workspaceToClose: WorkspaceSnapshot?

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                spaces
                    .frame(height: max(220, proxy.size.height * 0.42))
                Rectangle().fill(SheltieTheme.border).frame(height: 1)
                agents
            }
        }
        .background(SheltieTheme.surface.opacity(0.58))
        .sheet(isPresented: $isCreatingWorkspace) {
            WorkspaceCreationView(store: store)
        }
        .alert("Rename Space", isPresented: renameAlertBinding) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { workspaceToRename = nil }
            Button("Rename") {
                if let workspaceToRename { store.renameWorkspace(workspaceToRename.id, label: renameText) }
                workspaceToRename = nil
            }
        }
        .confirmationDialog("Close this space?", isPresented: closeDialogBinding, titleVisibility: .visible) {
            Button("Close Space", role: .destructive) {
                if let workspaceToClose { store.closeWorkspace(workspaceToClose.id) }
                workspaceToClose = nil
            }
        } message: {
            Text("Every pane in the space will be terminated on the Mac.")
        }
        .accessibilityIdentifier("sidebar")
    }

    private var spaces: some View {
        VStack(spacing: 0) {
            sectionHeader("SPACES") {
                isCreatingWorkspace = true
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(store.snapshot?.workspaces ?? []) { workspace in
                        workspaceRow(workspace)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var agents: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AGENTS")
                Spacer()
                Text("GROUPED")
            }
            .font(SheltieTheme.mono(10, weight: .bold))
            .foregroundStyle(SheltieTheme.muted)
            .tracking(1.1)
            .padding(.horizontal, 16)
            .frame(height: 46)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(store.snapshot?.agents ?? []) { agent in
                        agentRow(agent)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func sectionHeader(_ title: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(SheltieTheme.mono(10, weight: .bold))
                .tracking(1.1)
            Spacer()
            Button(action: action) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Create workspace")
        }
        .foregroundStyle(SheltieTheme.muted)
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .frame(height: 54)
    }

    private func workspaceRow(_ workspace: WorkspaceSnapshot) -> some View {
        let selected = workspace.id == store.selectedWorkspaceID
        return Button {
            store.selectWorkspace(workspace.id)
            onSelection?()
        } label: {
            HStack(spacing: 11) {
                StatusDot(status: workspace.status)
                VStack(alignment: .leading, spacing: 4) {
                    Text(workspace.label)
                        .font(SheltieTheme.body(13, weight: .semibold))
                        .foregroundStyle(SheltieTheme.foreground)
                        .lineLimit(1)
                    Text(workspaceMetadata(workspace))
                        .font(SheltieTheme.mono(10))
                        .foregroundStyle(SheltieTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(SheltieTheme.muted)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? SheltieTheme.foregroundSoft : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? SheltieTheme.border : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                renameText = workspace.label
                workspaceToRename = workspace
            }
            Button("Close Space", systemImage: "xmark", role: .destructive) {
                workspaceToClose = workspace
            }
        }
        .accessibilityIdentifier("workspace.\(workspace.id)")
        .accessibilityLabel("\(workspace.label), \(workspace.status.accessibilityDescription), \(workspace.tabCount) tabs")
    }

    private func agentRow(_ agent: AgentSnapshot) -> some View {
        let selected = agent.paneID == store.selectedPaneID
        return Button {
            store.selectAgent(agent)
            onSelection?()
        } label: {
            HStack(spacing: 11) {
                StatusDot(status: agent.status)
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.displayName)
                        .font(SheltieTheme.body(13, weight: .semibold))
                        .foregroundStyle(SheltieTheme.foreground)
                        .lineLimit(1)
                    Text(agent.statusLabel ?? "\(agent.status.rawValue) · \(agent.name)")
                        .font(SheltieTheme.mono(10))
                        .foregroundStyle(agent.status == .blocked ? SheltieTheme.danger : SheltieTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(SheltieTheme.muted)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? SheltieTheme.foregroundSoft : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? SheltieTheme.border : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("agent.\(agent.id)")
        .accessibilityLabel("\(agent.displayName), \(agent.name), \(agent.status.accessibilityDescription)")
    }

    private func workspaceMetadata(_ workspace: WorkspaceSnapshot) -> String {
        let leading = workspace.branch ?? workspace.path ?? "workspace"
        return workspace.tabCount == 1 ? leading : "\(leading)  ·  \(workspace.tabCount) sessions"
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { workspaceToRename != nil },
            set: { if !$0 { workspaceToRename = nil } }
        )
    }

    private var closeDialogBinding: Binding<Bool> {
        Binding(
            get: { workspaceToClose != nil },
            set: { if !$0 { workspaceToClose = nil } }
        )
    }
}

private struct WorkspaceCreationView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var label = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Workspace") {
                    TextField("Absolute path on the Mac", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Label (optional)", text: $label)
                }
                Section {
                    Text("Herdr creates the workspace and its first shell pane on the selected Mac.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Space")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        store.createWorkspace(cwd: path, label: label.isEmpty ? nil : label)
                        dismiss()
                    }
                    .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
