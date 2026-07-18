import SheltieProtocol
import SwiftUI

struct SessionTabsView: View {
    @ObservedObject var store: AppStore
    @State private var tabToRename: TabSnapshot?
    @State private var renameText = ""
    @State private var tabToClose: TabSnapshot?

    private var tabs: [TabSnapshot] {
        store.snapshot?.tabs.filter { $0.workspaceID == store.selectedWorkspaceID } ?? []
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(tabs) { tab in
                    tabButton(tab)
                }
                Button(action: store.createTab) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(SheltieTheme.muted)
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Create tab")
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: 46)
        .background(SheltieTheme.surface.opacity(0.74))
        .overlay(alignment: .bottom) { Rectangle().fill(SheltieTheme.border).frame(height: 1) }
        .accessibilityIdentifier("session.tabs")
        .alert("Rename Tab", isPresented: renameAlertBinding) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { tabToRename = nil }
            Button("Rename") {
                if let tabToRename { store.renameTab(tabToRename.id, label: renameText) }
                tabToRename = nil
            }
        }
        .confirmationDialog("Close this tab?", isPresented: closeDialogBinding, titleVisibility: .visible) {
            Button("Close Tab", role: .destructive) {
                if let tabToClose { store.closeTab(tabToClose.id) }
                tabToClose = nil
            }
        } message: {
            Text("Every pane in the tab will be terminated on the Mac.")
        }
    }

    private func tabButton(_ tab: TabSnapshot) -> some View {
        let active = tab.id == store.selectedTabID
        return Button {
            store.selectTab(tab.id)
        } label: {
            HStack(spacing: 9) {
                StatusDot(status: tab.status, size: 7)
                Text(tab.label)
                    .font(SheltieTheme.mono(11, weight: active ? .bold : .regular))
                    .foregroundStyle(active ? SheltieTheme.foreground : SheltieTheme.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 18)
            .frame(minWidth: 116, minHeight: 46)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(active ? SheltieTheme.accent : .clear)
                    .frame(height: 3)
                    .padding(.horizontal, 14)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                renameText = tab.label
                tabToRename = tab
            }
            Button("Close Tab", systemImage: "xmark", role: .destructive) {
                tabToClose = tab
            }
        }
        .accessibilityIdentifier("tab.\(tab.id)")
        .accessibilityLabel("\(tab.label), \(tab.status.accessibilityDescription)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(get: { tabToRename != nil }, set: { if !$0 { tabToRename = nil } })
    }

    private var closeDialogBinding: Binding<Bool> {
        Binding(get: { tabToClose != nil }, set: { if !$0 { tabToClose = nil } })
    }
}

struct CompactPaneSwitcher: View {
    @ObservedObject var store: AppStore

    private var panes: [PaneSnapshot] {
        store.snapshot?.panes.filter { $0.tabID == store.selectedTabID } ?? []
    }

    var body: some View {
        if panes.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(panes) { pane in
                        let selected = pane.id == store.compactPaneID
                        Button {
                            store.selectPane(pane.id)
                        } label: {
                            HStack(spacing: 6) {
                                StatusDot(status: pane.agentStatus, size: 6)
                                Text(pane.kind == .agent ? (pane.agentDisplayName ?? pane.title) : pane.title)
                                    .lineLimit(1)
                            }
                            .font(SheltieTheme.mono(10, weight: selected ? .bold : .regular))
                            .foregroundStyle(selected ? SheltieTheme.foreground : SheltieTheme.muted)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(Capsule().fill(selected ? SheltieTheme.accentSoft : SheltieTheme.foregroundSoft))
                            .overlay(Capsule().stroke(selected ? SheltieTheme.accent.opacity(0.45) : .clear, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
            .scrollIndicators(.hidden)
            .frame(height: 42)
            .background(SheltieTheme.surface.opacity(0.6))
            .overlay(alignment: .bottom) { Rectangle().fill(SheltieTheme.border).frame(height: 1) }
            .accessibilityIdentifier("pane.switcher")
        }
    }
}
