import SwiftUI
import UIKit

private enum PhoneDestination: Hashable {
    case workspace
}

struct RootView: View {
    @ObservedObject var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingInstances = false
    @State private var phonePath: [PhoneDestination]

    init(store: AppStore) {
        self.store = store
        let arguments = ProcessInfo.processInfo.arguments
        let startsInDemoWorkspace = arguments.contains("--demo") && arguments.contains("--phone-workspace")
        _phonePath = State(initialValue: startsInDemoWorkspace ? [.workspace] : [])
    }

    var body: some View {
        GeometryReader { proxy in
            let isPhone = UIDevice.current.userInterfaceIdiom == .phone
            let isCompact = isPhone || proxy.size.width <= 820
            let isNarrow = proxy.size.width <= 560
            let sidebarWidth = max(205, min(240, proxy.size.width * 0.21))

            ZStack(alignment: .topLeading) {
                if isPhone {
                    phoneNavigation(sidebarWidth: sidebarWidth, isNarrow: isNarrow)
                } else {
                    appFrame(
                        sidebarWidth: sidebarWidth,
                        isCompact: isCompact,
                        isNarrow: isNarrow
                    )
                }

                if !isPhone, isCompact, store.isSidebarPresented {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .onTapGesture { store.isSidebarPresented = false }
                        .transition(.opacity)
                    SidebarView(store: store)
                        .frame(width: min(292, proxy.size.width * 0.82))
                        .padding(.top, 58)
                        .background(SheltieTheme.surface)
                        .shadow(color: .black.opacity(0.16), radius: 18, x: 6)
                        .transition(.move(edge: .leading))
                }

                if let toast = store.toast {
                    ToastView(toast: toast) { store.dismissToast() }
                        .frame(maxWidth: 420)
                        .padding(.top, 68)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(3)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: store.isSidebarPresented)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: store.toast)
            .sheet(isPresented: $isShowingInstances) {
                InstancePickerView(store: store)
            }
            .onAppear {
                if store.profiles.isEmpty { isShowingInstances = true }
            }
        }
        .background(SheltieTheme.background.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sheltie.root")
    }

    @ViewBuilder
    private func phoneNavigation(sidebarWidth: CGFloat, isNarrow: Bool) -> some View {
        if phonePath.isEmpty {
            VStack(spacing: 0) {
                AppBar(
                    store: store,
                    sidebarWidth: sidebarWidth,
                    isCompact: true,
                    isNarrow: isNarrow,
                    isShowingInstances: $isShowingInstances,
                    navigationStyle: .phoneRoot
                )
                SidebarView(store: store) {
                    phonePath = [.workspace]
                }
            }
            .background(SheltieTheme.background)
            .accessibilityIdentifier("phone.navigation")
        } else {
            phoneWorkspace(sidebarWidth: sidebarWidth, isNarrow: isNarrow)
        }
    }

    private func phoneWorkspace(sidebarWidth: CGFloat, isNarrow: Bool) -> some View {
        VStack(spacing: 0) {
            AppBar(
                store: store,
                sidebarWidth: sidebarWidth,
                isCompact: true,
                isNarrow: isNarrow,
                isShowingInstances: $isShowingInstances,
                navigationStyle: .phoneWorkspace,
                onBack: { phonePath.removeAll() }
            )
            workspace(isCompact: true, isNarrow: isNarrow)
        }
        .background(SheltieTheme.background)
        .accessibilityIdentifier("phone.workspace")
    }

    private func appFrame(sidebarWidth: CGFloat, isCompact: Bool, isNarrow: Bool) -> some View {
        VStack(spacing: 0) {
            AppBar(
                store: store,
                sidebarWidth: sidebarWidth,
                isCompact: isCompact,
                isNarrow: isNarrow,
                isShowingInstances: $isShowingInstances
            )
            HStack(spacing: 0) {
                if !isCompact {
                    SidebarView(store: store)
                        .frame(width: sidebarWidth)
                    Rectangle().fill(SheltieTheme.border).frame(width: 1)
                }
                workspace(isCompact: isCompact, isNarrow: isNarrow)
            }
        }
        .background(SheltieTheme.background)
    }

    private func workspace(isCompact: Bool, isNarrow: Bool) -> some View {
        VStack(spacing: 0) {
            SessionTabsView(store: store)
            if isCompact { CompactPaneSwitcher(store: store) }
            ZStack {
                PaneWorkspaceView(store: store, isCompact: isCompact)
                if store.snapshot == nil {
                    ConnectionStateView(store: store) {
                        isShowingInstances = true
                    }
                }
            }
            TerminalKeybar(store: store, isNarrow: isNarrow)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ConnectionStateView: View {
    @ObservedObject var store: AppStore
    let showInstances: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(color)
            Text(title)
                .font(SheltieTheme.display(25, weight: .semibold))
                .foregroundStyle(SheltieTheme.foreground)
            Text(message)
                .font(SheltieTheme.body(13))
                .foregroundStyle(SheltieTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 10) {
                if case .failed = store.phase {
                    Button("Retry") { store.retryConnection() }
                        .buttonStyle(.borderedProminent)
                        .tint(SheltieTheme.accent)
                }
                Button(store.profiles.isEmpty ? "Pair a Mac" : "Manage Macs", action: showInstances)
                    .buttonStyle(.bordered)
                    .tint(SheltieTheme.foreground)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SheltieTheme.background.opacity(0.96))
    }

    private var icon: String {
        switch store.phase {
        case .connecting, .reconnecting: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle"
        case .noInstances: "laptopcomputer.and.ipad"
        case .disconnected: "wifi.slash"
        case .connected: "checkmark.circle"
        }
    }

    private var color: Color {
        switch store.phase {
        case .failed: SheltieTheme.danger
        case .connecting, .reconnecting: SheltieTheme.warning
        case .connected: SheltieTheme.success
        case .noInstances, .disconnected: SheltieTheme.muted
        }
    }

    private var title: String {
        switch store.phase {
        case .noInstances: "Pair your Mac"
        case .disconnected: "Mac disconnected"
        case .connecting: "Connecting to Herdr"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .failed: "Couldn’t connect"
        }
    }

    private var message: String {
        switch store.phase {
        case .noInstances: "Sheltie connects through a paired, tailnet-only Mac bridge."
        case .disconnected: "Choose a registered Mac or try connecting again."
        case .connecting: "Loading workspaces, agents, tabs, and terminal panes."
        case .connected: "Herdr is ready."
        case let .reconnecting(attempt): "Network or bridge interruption · attempt \(attempt)"
        case let .failed(message): message
        }
    }
}

private struct ToastView: View {
    let toast: ToastMessage
    let dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            HStack(spacing: 10) {
                Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                Text(toast.text)
                    .font(SheltieTheme.body(12, weight: .medium))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(toast.isError ? SheltieTheme.danger : SheltieTheme.foreground)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(toast.isError ? SheltieTheme.danger.opacity(0.5) : SheltieTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(toast.isError ? "Error" : "Status"): \(toast.text). Dismiss")
    }
}
