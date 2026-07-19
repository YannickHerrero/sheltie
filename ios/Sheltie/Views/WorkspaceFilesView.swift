import SheltieProtocol
import SwiftUI
import UIKit

private enum WorkspaceFileRoute: Hashable {
    case directory(String)
    case file(String)
}

struct WorkspaceFilesView: View {
    @ObservedObject var store: AppStore
    let workspace: WorkspaceSnapshot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WorkspaceDirectoryView(
                store: store,
                workspace: workspace,
                relativePath: "",
                isRoot: true,
                onDone: { dismiss() }
            )
            .navigationDestination(for: WorkspaceFileRoute.self) { route in
                switch route {
                case let .directory(relativePath):
                    WorkspaceDirectoryView(
                        store: store,
                        workspace: workspace,
                        relativePath: relativePath,
                        isRoot: false,
                        onDone: nil
                    )
                case let .file(relativePath):
                    WorkspaceFileEditorView(
                        store: store,
                        workspace: workspace,
                        relativePath: relativePath
                    )
                }
            }
        }
        .tint(SheltieTheme.accent)
    }
}

private struct WorkspaceDirectoryView: View {
    @ObservedObject var store: AppStore
    let workspace: WorkspaceSnapshot
    let relativePath: String
    let isRoot: Bool
    let onDone: (() -> Void)?
    @State private var isCreatingFile = false
    @State private var newFileName = ""
    @State private var newFilePath: String?

    private var location: WorkspaceFileLocation {
        .init(workspaceID: workspace.id, relativePath: relativePath)
    }

    private var listing: WorkspaceDirectoryListing? {
        store.workspaceDirectory(workspaceID: workspace.id, relativePath: relativePath)
    }

    var body: some View {
        Group {
            if store.workspaceDirectoryLoadingLocations.contains(location), listing == nil {
                ProgressView("Loading files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let listing, let message = listing.message {
                ContentUnavailableView {
                    Label("Directory unavailable", systemImage: "exclamationmark.folder.fill")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again", action: load)
                }
            } else if let listing, listing.entries.isEmpty {
                ContentUnavailableView(
                    "Empty Directory",
                    systemImage: "folder",
                    description: Text("Create a text file here to start editing on iPad.")
                )
            } else {
                fileList
            }
        }
        .background(SheltieTheme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isRoot, let onDone {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDone)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New File", systemImage: "doc.badge.plus") {
                    newFileName = ""
                    isCreatingFile = true
                }
                .disabled(listing?.errorCode != nil)
            }
        }
        .navigationDestination(item: $newFilePath) { path in
            WorkspaceFileEditorView(store: store, workspace: workspace, relativePath: path)
        }
        .alert("New Text File", isPresented: $isCreatingFile) {
            TextField("File name", text: $newFileName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Create", action: createFile)
                .disabled(!validNewFileName)
        } message: {
            Text("The file will be created in \(displayPath).")
        }
        .onAppear(perform: load)
    }

    private var fileList: some View {
        List {
            Section {
                ForEach(listing?.entries ?? []) { entry in
                    NavigationLink(value: route(for: entry)) {
                        HStack(spacing: 12) {
                            Image(systemName: entry.kind == .directory ? "folder.fill" : "doc.text")
                                .foregroundStyle(entry.kind == .directory ? SheltieTheme.accent : SheltieTheme.foreground)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.name)
                                    .font(SheltieTheme.body(15, weight: .medium))
                                    .foregroundStyle(SheltieTheme.foreground)
                                if let size = entry.size {
                                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                        .font(SheltieTheme.mono(10))
                                        .foregroundStyle(SheltieTheme.muted)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("workspace.file.\(entry.relativePath)")
                }
            } header: {
                Text(displayPath)
                    .font(SheltieTheme.mono(10))
                    .textCase(nil)
            } footer: {
                if listing?.truncated == true {
                    Text("Only the first 500 entries are shown.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { load() }
        .accessibilityIdentifier("workspace.files.list")
    }

    private var title: String {
        relativePath.split(separator: "/").last.map(String.init) ?? "\(workspace.label) Files"
    }

    private var displayPath: String {
        relativePath.isEmpty ? "/" : "/\(relativePath)"
    }

    private var validNewFileName: Bool {
        let trimmed = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "." && trimmed != ".." && !trimmed.contains("/")
    }

    private func route(for entry: WorkspaceFileEntry) -> WorkspaceFileRoute {
        entry.kind == .directory ? .directory(entry.relativePath) : .file(entry.relativePath)
    }

    private func load() {
        store.requestWorkspaceDirectory(workspaceID: workspace.id, relativePath: relativePath)
    }

    private func createFile() {
        let name = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validNewFileName else { return }
        let path = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
        isCreatingFile = false
        newFilePath = path
    }
}

private struct WorkspaceFileEditorView: View {
    @ObservedObject var store: AppStore
    let workspace: WorkspaceSnapshot
    let relativePath: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var original = ""
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var document: WorkspaceFileDocument?
    @State private var conflict: WorkspaceFileDocument?
    @State private var pendingReadID: String?
    @State private var pendingSaveID: String?
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var hasLoaded = false
    @State private var isConfirmingClose = false

    private var location: WorkspaceFileLocation {
        .init(workspaceID: workspace.id, relativePath: relativePath)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !hasLoaded, store.workspaceFileLoadingLocations.contains(location) {
                ProgressView("Opening \(fileName)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hasLoaded {
                NativeCodeTextView(text: $draft, selection: $selection)
                    .background(SheltieTheme.background)
                    .accessibilityIdentifier("workspace.file.editor")
            } else {
                ContentUnavailableView {
                    Label("File unavailable", systemImage: "doc.badge.ellipsis")
                } description: {
                    Text(errorMessage ?? "The file could not be opened from the Mac.")
                } actions: {
                    Button("Try Again", action: load)
                }
            }

            if hasLoaded {
                editorStatus
            }
        }
        .background(SheltieTheme.background)
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Files", systemImage: "chevron.left", action: close)
            }
            ToolbarItem(placement: .confirmationAction) {
                if store.workspaceFileSavingLocations.contains(location) {
                    ProgressView()
                } else {
                    Button("Save", action: save)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!canSave)
                        .accessibilityIdentifier("workspace.file.save")
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: store.workspaceFiles[location]) { _, updated in
            if let updated { handle(updated) }
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: $isConfirmingClose) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("The draft has not been written to the Mac.")
        }
        .alert("File changed on the Mac", isPresented: conflictBinding) {
            Button("Keep Editing", role: .cancel) {}
            Button("Reload Mac Version", action: reloadConflict)
            Button("Overwrite", role: .destructive, action: overwriteConflict)
        } message: {
            Text("Reload to preserve the external edit, or explicitly overwrite it with this iPad draft.")
        }
    }

    private var editorStatus: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("/\(relativePath)")
                    .lineLimit(1)
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(SheltieTheme.danger)
                        .lineLimit(2)
                } else if let statusMessage {
                    Text(statusMessage)
                        .foregroundStyle(SheltieTheme.success)
                } else if draft != original {
                    Text("Not saved")
                        .foregroundStyle(SheltieTheme.warning)
                } else {
                    Text("Saved on the Mac")
                        .foregroundStyle(SheltieTheme.muted)
                }
            }
            Spacer()
            Text("Ln \(lineAndColumn.line), Col \(lineAndColumn.column)")
            Text("\(draft.utf8.count) / 1 MiB")
                .foregroundStyle(draft.utf8.count > 1024 * 1024 ? SheltieTheme.danger : SheltieTheme.muted)
        }
        .font(SheltieTheme.mono(9))
        .foregroundStyle(SheltieTheme.muted)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(SheltieTheme.surface)
        .overlay(alignment: .top) { Hairline() }
    }

    private var canSave: Bool {
        hasLoaded && document?.documentID != nil && draft != original && draft.utf8.count <= 1024 * 1024
    }

    private var fileName: String {
        relativePath.split(separator: "/").last.map(String.init) ?? relativePath
    }

    private var conflictBinding: Binding<Bool> {
        Binding(
            get: { conflict != nil },
            set: { if !$0 { conflict = nil } }
        )
    }

    private var lineAndColumn: (line: Int, column: Int) {
        let utf16 = draft as NSString
        let location = min(selection.location, utf16.length)
        let prefix = utf16.substring(to: location)
        let lines = prefix.components(separatedBy: "\n")
        return (max(1, lines.count), (lines.last?.utf16.count ?? 0) + 1)
    }

    private func load() {
        errorMessage = nil
        pendingReadID = store.requestWorkspaceFile(workspaceID: workspace.id, relativePath: relativePath)
        if let document = store.workspaceFile(workspaceID: workspace.id, relativePath: relativePath) {
            handle(document)
        }
    }

    private func save() {
        guard let document else { return }
        errorMessage = nil
        statusMessage = nil
        pendingSaveID = store.saveWorkspaceFile(document, content: draft)
        if let updated = store.workspaceFile(workspaceID: workspace.id, relativePath: relativePath) {
            handle(updated)
        }
    }

    private func handle(_ updated: WorkspaceFileDocument) {
        if updated.requestID == pendingReadID {
            pendingReadID = nil
            guard updated.errorCode == nil,
                  let bytes = updated.bytes,
                  let content = String(data: bytes, encoding: .utf8) else {
                errorMessage = updated.message ?? "The file is unavailable."
                return
            }
            document = updated
            draft = content
            original = content
            selection = NSRange(location: 0, length: 0)
            hasLoaded = true
        } else if updated.requestID == pendingSaveID {
            pendingSaveID = nil
            if updated.errorCode == "conflict" {
                conflict = updated
            } else if updated.errorCode != nil {
                errorMessage = updated.message ?? "The file could not be saved."
            } else {
                document = updated
                original = draft
                statusMessage = "Saved on the Mac"
            }
        }
    }

    private func close() {
        if draft != original {
            isConfirmingClose = true
        } else {
            dismiss()
        }
    }

    private func reloadConflict() {
        guard let conflict,
              let bytes = conflict.bytes,
              let content = String(data: bytes, encoding: .utf8) else { return }
        document = conflict
        draft = content
        original = content
        errorMessage = nil
        statusMessage = "Reloaded the Mac version"
        self.conflict = nil
    }

    private func overwriteConflict() {
        guard let conflict else { return }
        self.conflict = nil
        pendingSaveID = store.saveWorkspaceFile(conflict, content: draft, force: true)
        if let updated = store.workspaceFile(workspaceID: workspace.id, relativePath: relativePath) {
            handle(updated)
        }
    }
}

private struct NativeCodeTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selection: $selection)
    }

    func makeUIView(context: Context) -> CodeTextView {
        let view = CodeTextView()
        view.delegate = context.coordinator
        view.backgroundColor = SheltieTheme.uiBackground
        view.textColor = SheltieTheme.uiForeground
        view.tintColor = UIColor(SheltieTheme.accent)
        view.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        view.textContainerInset = UIEdgeInsets(top: 16, left: 14, bottom: 24, right: 14)
        view.textContainer.lineFragmentPadding = 0
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.isFindInteractionEnabled = true
        view.accessibilityLabel = "File editor"
        return view
    }

    func updateUIView(_ view: CodeTextView, context: Context) {
        if view.text != text {
            view.text = text
        }
        let maximum = (view.text as NSString).length
        let safeSelection = NSRange(
            location: min(selection.location, maximum),
            length: min(selection.length, max(0, maximum - min(selection.location, maximum)))
        )
        if view.selectedRange != safeSelection {
            view.selectedRange = safeSelection
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String
        @Binding private var selection: NSRange

        init(text: Binding<String>, selection: Binding<NSRange>) {
            _text = text
            _selection = selection
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            selection = textView.selectedRange
        }
    }
}

private final class CodeTextView: UITextView {
    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + [
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(insertTab)),
            UIKeyCommand(input: "\t", modifierFlags: [.shift], action: #selector(outdent)),
        ]
    }

    @objc private func insertTab() {
        guard let selectedTextRange else { return }
        replace(selectedTextRange, withText: "\t")
    }

    @objc private func outdent() {
        let text = self.text as NSString
        let line = text.lineRange(for: NSRange(location: selectedRange.location, length: 0))
        let contents = text.substring(with: line)
        let removalLength: Int
        if contents.hasPrefix("\t") {
            removalLength = 1
        } else {
            removalLength = min(contents.prefix { $0 == " " }.count, 4)
        }
        guard removalLength > 0 else { return }
        textStorage.replaceCharacters(in: NSRange(location: line.location, length: removalLength), with: "")
        selectedRange = NSRange(
            location: max(line.location, selectedRange.location - removalLength),
            length: selectedRange.length
        )
        delegate?.textViewDidChange?(self)
    }
}
