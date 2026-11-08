import SwiftUI
import AppKit

// Only the main window's header and title-bar area. Content double-clicks retain
// their own selection, editing and image-preview behavior.
struct WindowZoomArea: NSViewRepresentable {
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {}
    final class Anchor: NSView {
        private var monitor: Any?
        private var originalFrame: NSRect?
        private var filledFrame: NSRect?
        init() {
            super.init(frame: .zero)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                guard let self, self.handles(event) else { return event }
                // Intercept before AppKit's native title-bar zoom changes the
                // frame, so the original size can be restored accurately.
                if event.type == .leftMouseDown { self.toggleZoom() }
                return nil
            }
        }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func handles(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, event.clickCount == 2,
                  window.attachedSheet == nil, NSApp.modalWindow == nil,
                  !window.styleMask.contains(.fullScreen) else { return false }
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                if let button = window.standardWindowButton(type), button.convert(button.bounds, to: nil).contains(event.locationInWindow) { return false }
            }
            return event.locationInWindow.y >= convert(bounds, to: nil).minY
        }
        func toggleZoom(animated: Bool = true) {
            guard let window, !window.styleMask.contains(.fullScreen), let screen = window.screen ?? NSScreen.main else { return }
            if let originalFrame, let filledFrame, window.frame.equalTo(filledFrame) {
                window.setFrame(originalFrame, display: true, animate: animated)
                self.originalFrame = nil; self.filledFrame = nil
            } else {
                originalFrame = window.frame
                window.setFrame(screen.visibleFrame, display: true, animate: animated)
                filledFrame = window.frame
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
