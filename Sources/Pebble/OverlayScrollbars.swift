import AppKit
import SwiftUI

/// Keep native, draggable scrollers without changing the document's width.
/// AppKit can reset the style when the user's scroll-bar preference or mouse changes.
final class OverlayScrollbarConfiguration {
  private weak var scrollView: NSScrollView?
  private var styleObservation: NSKeyValueObservation?

  func attach(to scrollView: NSScrollView?) {
    guard self.scrollView !== scrollView else { return }
    styleObservation = nil
    self.scrollView = scrollView
    guard let scrollView else { return }
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    styleObservation = scrollView.observe(\.scrollerStyle, options: [.initial, .new]) { view, _ in
      if view.scrollerStyle != .overlay { view.scrollerStyle = .overlay }
    }
  }
}

/// Place inside the ScrollView's content so enclosingScrollView is the intended container,
/// including when a text editor is nested inside the main list.
struct OverlayScrollAnchor: NSViewRepresentable {
  func makeNSView(context: Context) -> AnchorView { AnchorView() }

  func updateNSView(_ view: AnchorView, context: Context) { view.attach() }

  final class AnchorView: NSView {
    private let configuration = OverlayScrollbarConfiguration()

    override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      attach()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      attach()
    }

    func attach() { configuration.attach(to: enclosingScrollView) }
  }
}
