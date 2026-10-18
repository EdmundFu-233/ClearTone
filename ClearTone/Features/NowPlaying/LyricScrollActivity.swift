import SwiftUI
import AppKit

/// Detect wheel and trackpad input without mistaking programmatic scrolling for user input.
struct LyricScrollActivity: NSViewRepresentable {
    var onScroll: () -> Void
    func makeNSView(context: Context) -> ScrollActivityView {
        let view = ScrollActivityView()
        view.onScroll = onScroll
        return view
    }
    func updateNSView(_ nsView: ScrollActivityView, context: Context) { nsView.onScroll = onScroll }
    static func dismantleNSView(_ nsView: ScrollActivityView, coordinator: ()) { nsView.stopMonitoring() }

    final class ScrollActivityView: NSView {
        var onScroll: (() -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, self.window === event.window,
                       !self.isHiddenOrHasHiddenAncestor,
                       self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                       event.scrollingDeltaY != 0 {
                        self.onScroll?()
                    }
                }
                return event
            }
        }
        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
