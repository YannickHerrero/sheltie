import SwiftUI

struct RootView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        ZStack {
            Color(red: 0.882, green: 0.886, blue: 0.906)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "rectangle.split.3x3")
                    .font(.system(size: 42, weight: .medium))
                Text("Sheltie")
                    .font(.system(size: 34, weight: .semibold, design: .serif))
                Text(statusText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color(red: 0.122, green: 0.184, blue: 0.400))
        }
        .accessibilityIdentifier("sheltie.root")
    }

    private var statusText: String {
        switch store.phase {
        case .noInstances: "Pair a Mac to begin"
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case let .reconnecting(attempt): "Reconnecting · \(attempt)"
        case let .failed(message): message
        }
    }
}
