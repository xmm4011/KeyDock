import SwiftUI
import AppKit

@MainActor final class WindowCommandContext: ObservableObject {
    weak var window: NSWindow?
    var allowsMainCommands: Bool { window?.isVisible == true && window?.attachedSheet == nil && window?.sheetParent == nil && NSApp.modalWindow == nil }
}

struct WindowCommandAnchor: NSViewRepresentable {
    let context: WindowCommandContext
    func makeNSView(context: Context) -> Anchor { Anchor(owner: self.context) }
    func updateNSView(_ view: Anchor, context: Context) { self.context.window = view.window }
    final class Anchor: NSView {
        let owner: WindowCommandContext
        init(owner: WindowCommandContext) { self.owner = owner; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); owner.window = window }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// Window-specific: a nested sheet or native panel always gets the shortcut first.
struct SheetShortcuts: NSViewRepresentable {
    var close: () -> Void
    var cancel: (() -> Void)? = nil
    func makeNSView(context: Context) -> Anchor { Anchor(close: close, cancel: cancel) }
    func updateNSView(_ view: Anchor, context: Context) { view.close = close; view.cancel = cancel }
    final class Anchor: NSView {
        var close: () -> Void
        var cancel: (() -> Void)?
        private var monitor: Any?
        init(close: @escaping () -> Void, cancel: (() -> Void)? = nil) {
            self.close = close; self.cancel = cancel; super.init(frame: .zero)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.handles(event) else { return event }
                // Esc 沿用页面的取消 / 停止行为，⌘W 始终关闭顶层弹框。
                if event.keyCode == 53 { (self.cancel ?? self.close)() }
                else { self.close() }
                return nil
            }
        }
        required init?(coder: NSCoder) { fatalError() }
        func handles(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, window.attachedSheet == nil,
                  NSApp.modalWindow == nil || NSApp.modalWindow === window else { return false }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if flags.isEmpty && event.keyCode == 53, let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            return (flags == .command && event.charactersIgnoringModifiers?.lowercased() == "w") || (flags.isEmpty && event.keyCode == 53)
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

extension View {
    func sheetShortcuts(cancel: (() -> Void)? = nil, close: @escaping () -> Void) -> some View {
        background(SheetShortcuts(close: close, cancel: cancel).frame(width: 0, height: 0))
    }
}
