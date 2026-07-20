import SheltieProtocol
import SwiftUI

enum AppBarNavigationStyle {
    case standard
    case phoneRoot
    case phoneWorkspace
}

struct AppBar: View {
    @ObservedObject var store: AppStore
    let sidebarWidth: CGFloat
    let isCompact: Bool
    let isNarrow: Bool
    @Binding var isShowingInstances: Bool
    var navigationStyle: AppBarNavigationStyle = .standard
    var onBack: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            brand
                .frame(width: isCompact ? (isNarrow ? 58 : 154) : sidebarWidth, alignment: .leading)
            Rectangle().fill(SheltieTheme.border).frame(width: 1)
            instanceButton
            if let usage = store.snapshot?.usageMeters.first {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    usageMeter(usage, now: context.date)
                }
                .frame(width: isNarrow ? 142 : 236)
                .padding(.trailing, 10)
            } else if store.snapshot?.bridge.capabilities.contains("usage.codex") == true {
                unavailableUsageMeter
                    .frame(width: isNarrow ? 142 : 236)
                    .padding(.trailing, 10)
            }
        }
        .frame(height: 58)
        .background(SheltieTheme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(SheltieTheme.border).frame(height: 1) }
    }

    private var brand: some View {
        HStack(spacing: 10) {
            switch navigationStyle {
            case .phoneRoot:
                LogoMark()
                    .frame(width: 44, height: 44)
            case .phoneWorkspace:
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(SheltieTheme.foreground)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("phone.navigation.back")
                .accessibilityLabel("Back to spaces and agents")
            case .standard:
                if isCompact {
                    Button(action: store.toggleSidebar) {
                        LogoMark()
                    }
                    .buttonStyle(.plain)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel(store.isSidebarPresented ? "Hide spaces and agents" : "Show spaces and agents")
                } else {
                    LogoMark()
                }
            }
            if !isNarrow {
                Text("Sheltie")
                    .font(SheltieTheme.display(20, weight: .semibold))
                    .foregroundStyle(SheltieTheme.foreground)
            }
        }
        .padding(.horizontal, isCompact ? 7 : 16)
    }

    private var instanceButton: some View {
        Button {
            isShowingInstances = true
        } label: {
            HStack(spacing: 12) {
                connectionDot
                VStack(alignment: .leading, spacing: 2) {
                    Text(instanceTitle)
                        .font(SheltieTheme.body(13, weight: .semibold))
                        .foregroundStyle(SheltieTheme.foreground)
                        .lineLimit(1)
                    if !isNarrow {
                        Text(instanceMetadata)
                            .font(SheltieTheme.mono(10))
                            .foregroundStyle(SheltieTheme.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SheltieTheme.muted)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, isNarrow ? 10 : 16)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("instance.selector")
        .accessibilityLabel("Bridge host, \(instanceTitle)")
    }

    private var connectionDot: some View {
        Circle()
            .fill(connectionColor)
            .frame(width: 8, height: 8)
            .background(Circle().fill(connectionColor.opacity(0.12)).padding(-4))
    }

    private var connectionColor: Color {
        switch store.phase {
        case .connected: SheltieTheme.success
        case .connecting, .reconnecting: SheltieTheme.warning
        case .failed: SheltieTheme.danger
        case .noInstances, .disconnected: SheltieTheme.muted
        }
    }

    private var instanceTitle: String {
        let name = store.snapshot?.instance.name ?? store.selectedProfile?.displayName ?? "Choose a host"
        return switch store.phase {
        case .connected: "\(name) · Connected"
        case .connecting: "\(name) · Connecting"
        case .reconnecting: "\(name) · Reconnecting"
        case .failed: "\(name) · Unavailable"
        case .disconnected: "\(name) · Disconnected"
        case .noInstances: "Add a host"
        }
    }

    private var instanceMetadata: String {
        let session = store.snapshot?.activeSessionID ?? "no session"
        let host = store.snapshot?.instance.host ?? store.selectedProfile?.baseURL.host ?? "pairing required"
        return "\(session)  ·  \(host)"
    }

    private func usageMeter(_ usage: UsageMeter, now: Date) -> some View {
        let isStale = now.timeIntervalSince1970 * 1_000 - Double(usage.observedAtMillis) > 5 * 60_000
        return VStack(spacing: 7) {
            HStack {
                Text(isNarrow ? usage.provider.uppercased() : usage.label.uppercased())
                    .font(SheltieTheme.mono(9, weight: .medium))
                    .foregroundStyle(SheltieTheme.muted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(isStale ? "STALE" : "\(Int((usage.remainingFraction * 100).rounded()))% left")
                    .font(SheltieTheme.mono(11, weight: .bold))
                    .foregroundStyle(isStale ? SheltieTheme.warning : SheltieTheme.foreground)
            }
            HStack(spacing: 8) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(SheltieTheme.border.opacity(0.7))
                        Capsule().fill(SheltieTheme.accent)
                            .frame(width: proxy.size.width * max(0, min(1, usage.remainingFraction)))
                    }
                }
                .frame(height: 4)
                if !isNarrow, let reset = usage.resetAtMillis {
                    Text("Reset \(Date(timeIntervalSince1970: Double(reset) / 1_000), format: .dateTime.weekday(.abbreviated).hour().minute())")
                        .font(SheltieTheme.mono(9))
                        .foregroundStyle(SheltieTheme.muted)
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(SheltieTheme.background.opacity(0.34)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(SheltieTheme.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isStale
            ? "\(usage.label), usage information is stale"
            : "\(usage.label), \(Int(usage.remainingFraction * 100)) percent remaining")
    }

    private var unavailableUsageMeter: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.0percent")
            Text(isNarrow ? "CODEX —" : "CODEX USAGE UNAVAILABLE")
                .lineLimit(1)
        }
        .font(SheltieTheme.mono(9, weight: .semibold))
        .foregroundStyle(SheltieTheme.muted)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(SheltieTheme.background.opacity(0.34)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(SheltieTheme.border, lineWidth: 1))
        .accessibilityLabel("Codex usage unavailable")
    }
}

struct LogoMark: View {
    private let columns = [GridItem(.fixed(4), spacing: 3), GridItem(.fixed(4), spacing: 3), GridItem(.fixed(4), spacing: 3)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 3) {
            ForEach(0 ..< 6, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index == 1 ? SheltieTheme.accent : SheltieTheme.foreground)
                    .frame(width: 4, height: index == 1 || index == 4 ? 11 : 8)
            }
        }
        .frame(width: 28, height: 28)
        .background(RoundedRectangle(cornerRadius: 7).stroke(SheltieTheme.muted, lineWidth: 1))
        .accessibilityHidden(true)
    }
}
