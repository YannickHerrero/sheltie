import SheltieProtocol
import SwiftUI

struct PaneWorkspaceView: View {
    @ObservedObject var store: AppStore
    let isCompact: Bool

    private var activeLayout: PaneLayoutSnapshot? {
        store.snapshot?.layouts.first { $0.tabID == store.selectedTabID }
    }

    private var compactPane: PaneSnapshot? {
        let id = store.compactPaneID ?? store.selectedPaneID
        return store.snapshot?.panes.first { $0.id == id }
    }

    private var visiblePaneIDs: [String] {
        if isCompact { return compactPane.map { [$0.id] } ?? [] }
        return activeLayout?.root.paneIDs ?? []
    }

    var body: some View {
        Group {
            if isCompact, let compactPane {
                TerminalPaneView(store: store, pane: compactPane)
            } else if let layout = activeLayout {
                layoutNode(layout.root, tabID: layout.tabID, path: [])
            } else {
                ContentUnavailableView(
                    "No terminal panes",
                    systemImage: "rectangle.split.2x1",
                    description: Text("Choose a space and tab with an active Herdr pane.")
                )
                .foregroundStyle(SheltieTheme.muted)
            }
        }
        .background(SheltieTheme.background)
        .onAppear { store.updateVisiblePanes(visiblePaneIDs) }
        .onChange(of: visiblePaneIDs) { _, ids in store.updateVisiblePanes(ids) }
    }

    private func layoutNode(_ node: LayoutNode, tabID: String, path: [Bool]) -> AnyView {
        switch node {
        case let .pane(paneID):
            guard let pane = store.snapshot?.panes.first(where: { $0.id == paneID }) else {
                return AnyView(Color.clear)
            }
            return AnyView(TerminalPaneView(store: store, pane: pane))
        case let .split(direction, ratio, first, second):
            return AnyView(
                ResizableSplitNode(
                    direction: direction,
                    serverRatio: ratio,
                    first: layoutNode(first, tabID: tabID, path: path + [false]),
                    second: layoutNode(second, tabID: tabID, path: path + [true]),
                    onCommit: { store.setSplitRatio(tabID: tabID, path: path, ratio: $0) }
                )
            )
        }
    }
}

private struct ResizableSplitNode: View {
    let direction: SplitDirection
    let serverRatio: Double
    let first: AnyView
    let second: AnyView
    let onCommit: (Double) -> Void
    @State private var ratio: Double
    @State private var dragStartRatio: Double?

    init(
        direction: SplitDirection,
        serverRatio: Double,
        first: AnyView,
        second: AnyView,
        onCommit: @escaping (Double) -> Void
    ) {
        self.direction = direction
        self.serverRatio = serverRatio
        self.first = first
        self.second = second
        self.onCommit = onCommit
        _ratio = State(initialValue: serverRatio)
    }

    var body: some View {
        GeometryReader { proxy in
            if direction == .horizontal {
                HStack(spacing: 0) {
                    first.frame(width: max(120, proxy.size.width * ratio - 0.5))
                    divider(totalLength: proxy.size.width)
                    second
                }
            } else {
                VStack(spacing: 0) {
                    first.frame(height: max(120, proxy.size.height * ratio - 0.5))
                    divider(totalLength: proxy.size.height)
                    second
                }
            }
        }
        .onChange(of: serverRatio) { _, value in
            if dragStartRatio == nil { ratio = value }
        }
    }

    private func divider(totalLength: CGFloat) -> some View {
        Rectangle()
            .fill(SheltieTheme.border)
            .frame(width: direction == .horizontal ? 1 : nil, height: direction == .vertical ? 1 : nil)
            .overlay {
                Color.clear
                    .frame(width: direction == .horizontal ? 18 : nil, height: direction == .vertical ? 18 : nil)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = dragStartRatio ?? ratio
                                dragStartRatio = start
                                let translation = direction == .horizontal ? value.translation.width : value.translation.height
                                ratio = min(0.9, max(0.1, start + translation / max(1, totalLength)))
                            }
                            .onEnded { _ in
                                dragStartRatio = nil
                                onCommit(ratio)
                            }
                    )
            }
            .accessibilityLabel(direction == .horizontal ? "Resize panes horizontally" : "Resize panes vertically")
            .accessibilityAdjustableAction { adjustment in
                switch adjustment {
                case .increment: ratio = min(0.9, ratio + 0.05)
                case .decrement: ratio = max(0.1, ratio - 0.05)
                @unknown default: return
                }
                onCommit(ratio)
            }
    }
}

private struct TerminalPaneView: View {
    @ObservedObject var store: AppStore
    let pane: PaneSnapshot
    @State private var composerText = ""
    @State private var isConfirmingClose = false
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isShowingHistory = false
    @State private var historyIsAwayFromLatest = false
    @State private var historyOpenedAtSequence: Int64?
    @FocusState private var isComposerFocused: Bool

    private var selected: Bool { pane.id == store.selectedPaneID }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(SheltieTheme.border).frame(height: 1)
            ZStack {
                TerminalSurface(
                    paneID: pane.id,
                    frame: store.terminalFrames[pane.id],
                    onInput: { store.sendTerminalData($0, to: pane.id) },
                    onFocus: { store.selectPane(pane.id) },
                    onSizeChange: { store.updateTerminalSize(paneID: pane.id, columns: $0, rows: $1) }
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                if store.terminalFrames[pane.id] == nil, store.phase == .connected {
                    ProgressView()
                        .tint(SheltieTheme.accent)
                        .accessibilityLabel("Loading terminal")
                }
                if isShowingHistory {
                    historyView
                        .transition(.opacity)
                }
            }
            Rectangle().fill(SheltieTheme.border).frame(height: 1)
            composer
        }
        .background(SheltieTheme.background)
        .overlay(Rectangle().stroke(selected ? SheltieTheme.accent.opacity(0.7) : .clear, lineWidth: selected ? 1.5 : 0))
        .alert("Rename Pane", isPresented: $isRenaming) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { store.renamePane(pane.id, label: renameText.isEmpty ? nil : renameText) }
        }
        .confirmationDialog("Close this pane?", isPresented: $isConfirmingClose, titleVisibility: .visible) {
            Button("Close Pane", role: .destructive) { store.closeSelectedPane() }
        } message: {
            Text("Closing the pane terminates its process on the Mac.")
        }
        .accessibilityIdentifier("pane.\(pane.id)")
    }

    private var header: some View {
        HStack(spacing: 9) {
            StatusDot(status: pane.agentStatus, size: 7)
            Text(pane.title)
                .font(SheltieTheme.mono(11, weight: .bold))
                .foregroundStyle(SheltieTheme.foreground)
                .lineLimit(1)
            Text(pane.kind == .agent ? (pane.agentName ?? "agent") : "pty · attached")
                .font(SheltieTheme.mono(10))
                .foregroundStyle(SheltieTheme.muted)
                .lineLimit(1)
            Spacer(minLength: 4)
            if pane.kind == .shell {
                Button("clear") { store.sendKeys(["ctrl+l"], to: pane.id) }
                    .font(SheltieTheme.mono(10))
                    .foregroundStyle(SheltieTheme.muted)
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 38)
            }
            Button(action: showHistory) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SheltieTheme.muted)
                    .frame(width: 40, height: 38)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show terminal history")

            Menu {
                Button("Split Side by Side", systemImage: "rectangle.split.2x1") {
                    store.selectPane(pane.id)
                    store.splitSelectedPane(.horizontal)
                }
                Button("Split Above and Below", systemImage: "rectangle.split.1x2") {
                    store.selectPane(pane.id)
                    store.splitSelectedPane(.vertical)
                }
                Button("Toggle Zoom", systemImage: "arrow.up.left.and.arrow.down.right") {
                    store.selectPane(pane.id)
                    store.zoomSelectedPane()
                }
                Button("Rename", systemImage: "pencil") {
                    renameText = pane.title
                    isRenaming = true
                }
                Menu("Move Pane", systemImage: "rectangle.on.rectangle") {
                    ForEach(destinationTabs) { tab in
                        Button(tab.label) { store.movePane(pane.id, to: tab.id) }
                    }
                    Button("New Tab") { store.movePaneToNewTab(pane.id, workspaceID: pane.workspaceID) }
                }
                Divider()
                Button("Close Pane", systemImage: "xmark", role: .destructive) {
                    store.selectPane(pane.id)
                    isConfirmingClose = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(SheltieTheme.muted)
                    .frame(width: 44, height: 38)
            }
            .accessibilityLabel("Pane actions")
        }
        .padding(.leading, 12)
        .frame(height: 38)
        .background(SheltieTheme.surface.opacity(0.45))
    }

    private var historyView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("HISTORY")
                    .font(SheltieTheme.mono(9, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(SheltieTheme.muted)
                if hasNewOutputSinceHistoryOpened {
                    Circle()
                        .fill(SheltieTheme.accent)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                Spacer()
                Button {
                    isShowingHistory = false
                } label: {
                    Label("Latest", systemImage: "arrow.down.to.line")
                        .font(SheltieTheme.mono(10, weight: .semibold))
                        .foregroundStyle(SheltieTheme.foreground)
                        .frame(minWidth: 70, minHeight: 32)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("terminal.history.latest.\(pane.id)")
                .accessibilityValue(historyIsAwayFromLatest ? "Earlier output" : "Latest output")
                .accessibilityHint("Returns to live terminal output")
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(SheltieTheme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(SheltieTheme.border).frame(height: 1) }

            if let history = store.terminalHistories[pane.id] {
                TerminalHistorySurface(
                    history: history,
                    onScrolledAwayFromLatest: { historyIsAwayFromLatest = $0 }
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            } else if store.terminalHistoryLoadingPaneIDs.contains(pane.id) {
                VStack(spacing: 10) {
                    ProgressView()
                        .tint(SheltieTheme.accent)
                    Text("Loading recent terminal history…")
                        .font(SheltieTheme.mono(10))
                        .foregroundStyle(SheltieTheme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            } else {
                ContentUnavailableView {
                    Label("History unavailable", systemImage: "clock.badge.exclamationmark")
                } description: {
                    Text("The recent terminal buffer could not be loaded.")
                } actions: {
                    Button("Try Again") { store.requestTerminalHistory(for: pane.id) }
                }
                .foregroundStyle(SheltieTheme.muted)
            }
        }
        .background(SheltieTheme.background)
        .accessibilityIdentifier("terminal.history.container.\(pane.id)")
        .accessibilityValue(historyIsAwayFromLatest ? "Earlier output" : "Latest output")
    }

    private var hasNewOutputSinceHistoryOpened: Bool {
        guard let historyOpenedAtSequence,
              let current = store.terminalFrames[pane.id]?.sequence else { return false }
        return current != historyOpenedAtSequence
    }

    private func showHistory() {
        guard !isShowingHistory else { return }
        historyOpenedAtSequence = store.terminalFrames[pane.id]?.sequence
        historyIsAwayFromLatest = false
        guard store.snapshot?.bridge.capabilities.contains("terminal.history") == true else {
            store.requestTerminalHistory(for: pane.id)
            return
        }
        isShowingHistory = true
        store.requestTerminalHistory(for: pane.id)
    }

    private var destinationTabs: [TabSnapshot] {
        store.snapshot?.tabs.filter { $0.workspaceID == pane.workspaceID && $0.id != pane.tabID } ?? []
    }

    private var composer: some View {
        HStack(spacing: 9) {
            Text("❯")
                .font(SheltieTheme.mono(15, weight: .bold))
                .foregroundStyle(SheltieTheme.foreground)
            TextField(pane.kind == .agent ? "Message the agent…" : "Type a command…", text: $composerText, axis: .vertical)
                .font(SheltieTheme.mono(12))
                .foregroundStyle(SheltieTheme.foreground)
                .lineLimit(1 ... 3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(pane.kind == .shell)
                .submitLabel(.send)
                .focused($isComposerFocused)
                .onSubmit(sendComposer)
                .accessibilityIdentifier("composer.\(pane.id)")
                .accessibilityLabel(pane.kind == .agent ? "Agent message composer" : "Shell command composer")
            Button(action: sendComposer) {
                Image(systemName: pane.kind == .agent ? "paperplane" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SheltieTheme.foreground)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 8).fill(SheltieTheme.foregroundSoft))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(SheltieTheme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(composerText.isEmpty)
            .accessibilityLabel(pane.kind == .agent ? "Send message" : "Run command")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 54)
        .background(SheltieTheme.surface.opacity(0.5))
    }

    private func sendComposer() {
        let text = composerText
        guard !text.isEmpty else { return }
        let shouldRestoreFocus = isComposerFocused
        composerText = ""
        if pane.kind == .agent {
            store.sendAgentMessage(text, to: pane.id)
        } else {
            store.sendTerminalCommand(text, to: pane.id)
        }
        if shouldRestoreFocus {
            isComposerFocused = false
            Task { @MainActor in
                await Task.yield()
                isComposerFocused = true
            }
        }
    }
}

private extension LayoutNode {
    var paneIDs: [String] {
        switch self {
        case let .pane(paneID): [paneID]
        case let .split(_, _, first, second): first.paneIDs + second.paneIDs
        }
    }
}
