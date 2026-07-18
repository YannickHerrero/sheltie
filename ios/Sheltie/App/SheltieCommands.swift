import SwiftUI

struct SheltieCommands: Commands {
    @ObservedObject var store: AppStore

    var body: some Commands {
        CommandMenu("Sheltie") {
            Button("Toggle Spaces and Agents") { store.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Divider()
            Button("Next Tab") { store.selectNextTab() }
                .keyboardShortcut("]", modifiers: [.command])
                .disabled(store.selectedTabID == nil)
            Button("Next Pane") { store.selectNextPane() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(store.selectedPaneID == nil)
            Divider()
            Button("Send Escape") { store.sendKeys(["Escape"]) }
                .keyboardShortcut(.escape, modifiers: [.command])
                .disabled(store.selectedPaneID == nil)
            Button("Interrupt Pane") { store.sendKeys(["ctrl+c"]) }
                .keyboardShortcut("c", modifiers: [.command, .control])
                .disabled(store.selectedPaneID == nil)
        }
    }
}
