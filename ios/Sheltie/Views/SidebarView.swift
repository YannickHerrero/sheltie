import SheltieProtocol
import SwiftUI

enum WorkspacePathLabels {
    static func make(for workspaces: [WorkspaceSnapshot]) -> [String: String] {
        let candidates = workspaces.compactMap { workspace -> (String, [String])? in
            guard let path = workspace.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
            let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !components.isEmpty else { return nil }
            return (workspace.id, components)
        }

        return Dictionary(uniqueKeysWithValues: candidates.map { id, components in
            for depth in 1 ... components.count {
                let suffix = compactSuffix(components, depth: depth)
                let collides = candidates.contains { otherID, otherComponents in
                    guard otherID != id else { return false }
                    return compactSuffix(otherComponents, depth: min(depth, otherComponents.count))
                        .localizedCaseInsensitiveCompare(suffix) == .orderedSame
                }
                if !collides { return (id, suffix) }
            }
            return (id, compactSuffix(components, depth: components.count))
        })
    }

    private static func compactSuffix(_ components: [String], depth: Int) -> String {
        "/" + components.suffix(depth).joined(separator: "/")
    }
}

enum SidebarSplitLayout {
    static let defaultRatio = 0.42
    static let dividerHeight: CGFloat = 18

    static func clampedRatio(_ ratio: Double, totalHeight: CGFloat) -> Double {
        guard totalHeight > 0 else { return defaultRatio }
        let minimumSectionHeight = min(180, totalHeight * 0.35)
        let minimumRatio = Double(minimumSectionHeight / totalHeight)
        let candidate = ratio.isFinite ? ratio : defaultRatio
        return min(1 - minimumRatio, max(minimumRatio, candidate))
    }
}

struct SidebarView: View {
    @ObservedObject var store: AppStore
    var onSelection: (() -> Void)? = nil
    @State private var workspaceToRename: WorkspaceSnapshot?
    @State private var renameText = ""
    @State private var workspaceToClose: WorkspaceSnapshot?
    @State private var workspaceForTodo: WorkspaceSnapshot?
    @State private var dragStartRatio: Double?
    @AppStorage("sheltie.sidebarSplitRatio") private var splitRatio = SidebarSplitLayout.defaultRatio

    var body: some View {
        GeometryReader { proxy in
            let availableHeight = max(1, proxy.size.height - SidebarSplitLayout.dividerHeight)
            let resolvedRatio = SidebarSplitLayout.clampedRatio(splitRatio, totalHeight: availableHeight)
            let spacesHeight = availableHeight * CGFloat(resolvedRatio)

            VStack(spacing: 0) {
                spaces
                    .frame(height: spacesHeight)
                splitDivider(totalHeight: availableHeight, currentRatio: resolvedRatio)
                agents
                    .frame(height: max(0, availableHeight - spacesHeight))
            }
        }
        .background(SheltieTheme.surface.opacity(0.58))
        .sheet(item: $workspaceForTodo) { workspace in
            WorkspaceTodoView(store: store, workspace: workspace)
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

    private func splitDivider(totalHeight: CGFloat, currentRatio: Double) -> some View {
        ZStack {
            Rectangle()
                .fill(SheltieTheme.border)
                .frame(height: 1)
            Capsule()
                .fill(SheltieTheme.muted.opacity(0.55))
                .frame(width: 34, height: 3)
        }
        .frame(height: SidebarSplitLayout.dividerHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = dragStartRatio ?? currentRatio
                    dragStartRatio = start
                    splitRatio = SidebarSplitLayout.clampedRatio(
                        start + Double(value.translation.height / max(1, totalHeight)),
                        totalHeight: totalHeight
                    )
                }
                .onEnded { _ in dragStartRatio = nil }
        )
        .onTapGesture(count: 2) {
            splitRatio = SidebarSplitLayout.defaultRatio
        }
        .hoverEffect(.highlight)
        .accessibilityElement()
        .accessibilityIdentifier("sidebar.splitDivider")
        .accessibilityLabel("Resize Spaces and Agents")
        .accessibilityValue("Spaces use \(Int((currentRatio * 100).rounded())) percent")
        .accessibilityHint("Drag vertically. Double-tap to reset.")
        .accessibilityAdjustableAction { adjustment in
            switch adjustment {
            case .increment:
                splitRatio = SidebarSplitLayout.clampedRatio(currentRatio + 0.05, totalHeight: totalHeight)
            case .decrement:
                splitRatio = SidebarSplitLayout.clampedRatio(currentRatio - 0.05, totalHeight: totalHeight)
            @unknown default:
                break
            }
        }
    }

    private var spaces: some View {
        VStack(spacing: 0) {
            sectionHeader("SPACES") {
                store.createWorkspace()
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
            Button("Todo List", systemImage: "checklist") {
                workspaceForTodo = workspace
            }
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
        let leading = workspacePathLabels[workspace.id] ?? workspace.branch ?? "workspace"
        return workspace.tabCount == 1 ? leading : "\(leading)  ·  \(workspace.tabCount) sessions"
    }

    private var workspacePathLabels: [String: String] {
        WorkspacePathLabels.make(for: store.snapshot?.workspaces ?? [])
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

private struct WorkspaceTodoView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case edit = "Edit"
        case preview = "Preview"
        var id: Self { self }
    }

    @ObservedObject var store: AppStore
    let workspace: WorkspaceSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .edit
    @State private var draft = ""
    @State private var original = ""
    @State private var revision: String?
    @State private var pendingReadID: String?
    @State private var pendingSaveID: String?
    @State private var conflict: WorkspaceTodoDocument?
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Todo view", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if !hasLoaded, store.workspaceTodoLoadingIDs.contains(workspace.id) {
                    ProgressView("Loading todo.md…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if mode == .edit {
                    TextEditor(text: $draft)
                        .font(SheltieTheme.mono(13))
                        .foregroundStyle(SheltieTheme.foreground)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 12)
                        .background(SheltieTheme.background)
                        .accessibilityIdentifier("workspace.todo.editor")
                } else {
                    ScrollView {
                        Text(markdownPreview)
                            .font(SheltieTheme.body(14))
                            .foregroundStyle(SheltieTheme.foreground)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(18)
                    }
                    .background(SheltieTheme.background)
                    .accessibilityIdentifier("workspace.todo.preview")
                }

                VStack(alignment: .leading, spacing: 4) {
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(SheltieTheme.danger)
                    } else {
                        Text("Markdown is saved as todo.md in the Space project root.")
                            .foregroundStyle(SheltieTheme.muted)
                    }
                    Text("\(draft.utf8.count) / \(256 * 1024) bytes")
                        .foregroundStyle(draft.utf8.count > 256 * 1024 ? SheltieTheme.danger : SheltieTheme.muted)
                }
                .font(SheltieTheme.mono(9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(SheltieTheme.surface)
            }
            .navigationTitle("\(workspace.label) Todo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.workspaceTodoSavingIDs.contains(workspace.id) {
                        ProgressView()
                    } else {
                        Button("Save", action: save)
                            .disabled(!hasLoaded || draft == original || draft.utf8.count > 256 * 1024)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear(perform: load)
        .onChange(of: store.workspaceTodos[workspace.id]) { _, document in
            if let document { handle(document) }
        }
        .alert("todo.md changed on the Mac", isPresented: conflictBinding) {
            Button("Cancel", role: .cancel) {}
            Button("Reload Mac Version") { reloadConflict() }
            Button("Overwrite", role: .destructive) { overwriteConflict() }
        } message: {
            Text("Reload to preserve the external edit, or explicitly overwrite it with this draft.")
        }
    }

    private var markdownPreview: AttributedString {
        (try? AttributedString(markdown: draft)) ?? AttributedString(draft)
    }

    private var conflictBinding: Binding<Bool> {
        Binding(
            get: { conflict != nil },
            set: { if !$0 { conflict = nil } }
        )
    }

    private func load() {
        pendingReadID = store.requestWorkspaceTodo(for: workspace.id)
        if let document = store.workspaceTodos[workspace.id] { handle(document) }
    }

    private func save() {
        errorMessage = nil
        pendingSaveID = store.saveWorkspaceTodo(
            workspaceID: workspace.id,
            content: draft,
            expectedRevision: revision
        )
        if let document = store.workspaceTodos[workspace.id] { handle(document) }
    }

    private func handle(_ document: WorkspaceTodoDocument) {
        if document.requestID == pendingReadID {
            pendingReadID = nil
            guard document.errorCode == nil else {
                errorMessage = document.message ?? "todo.md is unavailable."
                return
            }
            draft = document.content ?? ""
            original = draft
            revision = document.revision
            hasLoaded = true
        } else if document.requestID == pendingSaveID {
            pendingSaveID = nil
            if document.errorCode == "conflict" {
                conflict = document
            } else if document.errorCode != nil {
                errorMessage = document.message ?? "todo.md could not be saved."
            } else {
                original = document.content ?? draft
                revision = document.revision
                dismiss()
            }
        }
    }

    private func reloadConflict() {
        guard let conflict else { return }
        draft = conflict.content ?? ""
        original = draft
        revision = conflict.revision
        errorMessage = nil
        self.conflict = nil
    }

    private func overwriteConflict() {
        guard let conflict else { return }
        self.conflict = nil
        pendingSaveID = store.saveWorkspaceTodo(
            workspaceID: workspace.id,
            content: draft,
            expectedRevision: conflict.revision,
            force: true
        )
        if let document = store.workspaceTodos[workspace.id] { handle(document) }
    }
}
