import SheltieProtocol
import SwiftTerm
import SwiftUI
import UIKit

struct TerminalSurface: UIViewRepresentable {
    let paneID: String
    let frame: TerminalFrame?
    let onInput: (Data) -> Void
    let onFocus: () -> Void
    let onHistoryRequest: () -> Void
    let onSizeChange: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput, onFocus: onFocus, onSizeChange: onSizeChange)
    }

    func makeUIView(context: Context) -> FocusTerminalView {
        let view = FocusTerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.onFocus = context.coordinator.onFocus
        view.onHistoryRequest = onHistoryRequest
        view.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = SheltieTheme.uiBackground
        view.nativeForegroundColor = SheltieTheme.uiForeground
        view.contentInset = .zero
        view.alwaysBounceVertical = true
        view.keyboardAppearance = .light
        view.autocorrectionType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.accessibilityIdentifier = "terminal.\(paneID)"
        view.accessibilityLabel = "Live terminal"
        context.coordinator.paneID = paneID
        return view
    }

    func updateUIView(_ view: FocusTerminalView, context: Context) {
        context.coordinator.onInput = onInput
        context.coordinator.onFocus = onFocus
        context.coordinator.onSizeChange = onSizeChange
        view.onFocus = onFocus
        view.onHistoryRequest = onHistoryRequest
        context.coordinator.stage(frame: frame, paneID: paneID, in: view)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var paneID: String?
        var lastFrameIdentity: String?
        var pendingFrame: TerminalFrame?
        var needsClear = false
        var onInput: (Data) -> Void
        var onFocus: () -> Void
        var onSizeChange: (Int, Int) -> Void

        init(
            onInput: @escaping (Data) -> Void,
            onFocus: @escaping () -> Void,
            onSizeChange: @escaping (Int, Int) -> Void
        ) {
            self.onInput = onInput
            self.onFocus = onFocus
            self.onSizeChange = onSizeChange
        }

        func stage(frame: TerminalFrame?, paneID: String, in view: TerminalView) {
            if self.paneID != paneID {
                self.paneID = paneID
                lastFrameIdentity = nil
                needsClear = true
            }
            pendingFrame = frame
            feedIfReady(view)
        }

        func feedIfReady(_ view: TerminalView) {
            guard view.bounds.width > 100, view.bounds.height > 80 else { return }
            if needsClear {
                view.feed(text: "\u{001B}[2J\u{001B}[H")
                needsClear = false
            }
            guard let frame = pendingFrame,
                  let bytes = frame.bytes else { return }
            let identity = "\(frame.sequence):\(frame.bytesBase64.hashValue)"
            guard lastFrameIdentity != identity else { return }
            lastFrameIdentity = identity
            if frame.full { view.feed(text: "\u{001B}[2J\u{001B}[H") }
            let array = [UInt8](bytes)
            view.feed(byteArray: array[...])
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            onSizeChange(newCols, newRows)
            if pendingFrame?.full == true {
                lastFrameIdentity = nil
                needsClear = true
            }
            feedIfReady(source)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            onInput(Data(data))
        }

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) else { return }
            UIApplication.shared.open(url)
        }

        func bell(source: TerminalView) {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            UIPasteboard.general.string = String(data: content, encoding: .utf8)
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

struct TerminalHistorySurface: UIViewRepresentable {
    let history: TerminalHistory
    let onScrolledAwayFromLatest: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScrolledAwayFromLatest: onScrolledAwayFromLatest)
    }

    func makeUIView(context: Context) -> ReadOnlyTerminalView {
        let view = ReadOnlyTerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.delegate = context.coordinator
        view.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = SheltieTheme.uiBackground
        view.nativeForegroundColor = SheltieTheme.uiForeground
        view.contentInset = .zero
        view.alwaysBounceVertical = true
        view.showsVerticalScrollIndicator = true
        view.keyboardDismissMode = .none
        view.getTerminal().changeHistorySize(1_100)
        view.accessibilityIdentifier = "terminal.history.\(history.paneID)"
        view.accessibilityLabel = "Terminal history"
        view.accessibilityValue = "Latest output"
        return view
    }

    func updateUIView(_ view: ReadOnlyTerminalView, context: Context) {
        context.coordinator.onScrolledAwayFromLatest = onScrolledAwayFromLatest
        context.coordinator.stage(history: history, in: view)
    }

    final class Coordinator: NSObject, TerminalViewDelegate, UIScrollViewDelegate {
        private var pendingHistory: TerminalHistory?
        private var lastRequestID: String?
        private var wasAwayFromLatest = false
        var onScrolledAwayFromLatest: (Bool) -> Void

        init(onScrolledAwayFromLatest: @escaping (Bool) -> Void) {
            self.onScrolledAwayFromLatest = onScrolledAwayFromLatest
        }

        func stage(history: TerminalHistory, in view: TerminalView) {
            pendingHistory = history
            feedIfReady(view)
        }

        private func feedIfReady(_ view: TerminalView) {
            guard view.bounds.width > 100, view.bounds.height > 80,
                  let history = pendingHistory,
                  history.requestID != lastRequestID,
                  let bytes = history.bytes else { return }
            lastRequestID = history.requestID
            view.getTerminal().resetToInitialState()
            view.getTerminal().changeHistorySize(1_100)
            let array = [UInt8](bytes)
            view.feed(byteArray: array[...])
            view.scroll(toPosition: 1)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let bottom = max(
                -scrollView.adjustedContentInset.top,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            let isAwayFromLatest = scrollView.contentOffset.y < bottom - 8
            scrollView.accessibilityValue = isAwayFromLatest ? "Earlier output" : "Latest output"
            guard isAwayFromLatest != wasAwayFromLatest else { return }
            wasAwayFromLatest = isAwayFromLatest
            DispatchQueue.main.async { [onScrolledAwayFromLatest] in
                onScrolledAwayFromLatest(isAwayFromLatest)
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            feedIfReady(source)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) else { return }
            UIApplication.shared.open(url)
        }
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            UIPasteboard.general.string = String(data: content, encoding: .utf8)
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

final class FocusTerminalView: TerminalView {
    var onFocus: (() -> Void)?
    var onHistoryRequest: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        panGestureRecognizer.addTarget(self, action: #selector(handleHistoryPan(_:)))
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        panGestureRecognizer.addTarget(self, action: #selector(handleHistoryPan(_:)))
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }

    @objc private func handleHistoryPan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let translation = gesture.translation(in: self)
        guard abs(translation.y) > 32, abs(translation.y) > abs(translation.x) * 1.2 else { return }
        onHistoryRequest?()
    }
}

final class ReadOnlyTerminalView: TerminalView {
    override var canBecomeFirstResponder: Bool { false }
}
