import SwiftUI

struct TerminalKeybar: View {
    @ObservedObject var store: AppStore
    let isNarrow: Bool
    @State private var controlIsSticky = false
    @State private var optionIsSticky = false
    @State private var shiftIsSticky = false

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    key("esc") { send("Escape") }
                    key("tab") { send("Tab") }
                    key("ctrl c") { store.sendKeys(["ctrl+c"]) }
                    key("pg ↑", accessibility: "Page up", repeats: true) { send("PageUp") }
                    key("pg ↓", accessibility: "Page down", repeats: true) { send("PageDown") }
                    modifier("ctrl", active: $controlIsSticky)
                    modifier("opt", active: $optionIsSticky)
                    modifier("shift", active: $shiftIsSticky)
                    key("|") { sendLiteral("|") }
                    key("~") { sendLiteral("~") }
                    key("/") { sendLiteral("/") }
                    key("←", accessibility: "Left arrow") { send("Left") }
                    key("↑", accessibility: "Up arrow") { send("Up") }
                    key("↓", accessibility: "Down arrow") { send("Down") }
                    key("→", accessibility: "Right arrow") { send("Right") }
                    key("↵", accessibility: "Enter") { send("Enter") }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.hidden)
            if !isNarrow {
                Text("hardware keyboard ready")
                    .font(SheltieTheme.mono(9))
                    .foregroundStyle(SheltieTheme.muted)
                    .padding(.trailing, 14)
                    .fixedSize()
            }
        }
        .frame(height: 50)
        .background(SheltieTheme.surface)
        .overlay(alignment: .top) { Rectangle().fill(SheltieTheme.border).frame(height: 1) }
        .accessibilityIdentifier("terminal.keybar")
    }

    private func key(
        _ label: String,
        accessibility: String? = nil,
        repeats: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(SheltieTheme.mono(10, weight: .medium))
                .foregroundStyle(SheltieTheme.muted)
                .padding(.horizontal, 12)
                .frame(minWidth: 44, minHeight: 38)
                .background(RoundedRectangle(cornerRadius: 7).fill(SheltieTheme.background.opacity(0.45)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(SheltieTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(repeats ? .enabled : .disabled)
        .disabled(store.selectedPaneID == nil)
        .accessibilityLabel(accessibility ?? label)
    }

    private func modifier(_ label: String, active: Binding<Bool>) -> some View {
        Button {
            active.wrappedValue.toggle()
        } label: {
            Text(label)
                .font(SheltieTheme.mono(10, weight: active.wrappedValue ? .bold : .medium))
                .foregroundStyle(active.wrappedValue ? SheltieTheme.foreground : SheltieTheme.muted)
                .padding(.horizontal, 11)
                .frame(minWidth: 44, minHeight: 38)
                .background(RoundedRectangle(cornerRadius: 7).fill(active.wrappedValue ? SheltieTheme.accentSoft : SheltieTheme.background.opacity(0.45)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(active.wrappedValue ? SheltieTheme.accent : SheltieTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sticky \(label)")
        .accessibilityValue(active.wrappedValue ? "On" : "Off")
    }

    private func send(_ key: String) {
        store.sendKeys([modified(key)])
        clearStickyModifiers()
    }

    private func sendLiteral(_ literal: String) {
        store.sendKeys([modified(literal)])
        clearStickyModifiers()
    }

    private func modified(_ key: String) -> String {
        var modifiers: [String] = []
        if controlIsSticky { modifiers.append("ctrl") }
        if optionIsSticky { modifiers.append("alt") }
        if shiftIsSticky { modifiers.append("shift") }
        return modifiers.isEmpty ? key : (modifiers + [key]).joined(separator: "+")
    }

    private func clearStickyModifiers() {
        controlIsSticky = false
        optionIsSticky = false
        shiftIsSticky = false
    }
}
