import AppKit
import SwiftUI

final class DragAutoScroller: ObservableObject {
  weak var anchor: NSView?
  private var timer: Timer?
  private var keyMonitor: Any?
  private var onEnd: (() -> Void)?

  func start(onEnd: @escaping () -> Void) {
    stop()
    self.onEnd = onEnd
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      if event.keyCode == 53 { self?.stop() }
      return event
    }
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
      self?.scroll()
    }
    self.timer = timer
    // Keep ticking in AppKit's drag tracking loop, even when the pointer is stationary.
    RunLoop.main.add(timer, forMode: .common)
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    let completion = onEnd
    onEnd = nil
    completion?()
  }

  private func scroll() {
    guard NSEvent.pressedMouseButtons & 1 != 0,
          let anchor, let window = anchor.window, window.isVisible,
          !anchor.isHiddenOrHasHiddenAncestor else {
      stop()
      return
    }
    guard let scrollView = anchor.enclosingScrollView else { return }
    let clipView = scrollView.contentView
    let point = clipView.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
    let bounds = clipView.bounds
    guard bounds.contains(point) else { return }

    let edge = min(56, bounds.height / 3)
    guard edge > 0 else { return }
    let lowerDistance = point.y - bounds.minY
    let upperDistance = bounds.maxY - point.y
    let strength: CGFloat
    if lowerDistance < edge {
      strength = -(1 - lowerDistance / edge)
    } else if upperDistance < edge {
      strength = 1 - upperDistance / edge
    } else {
      return
    }

    var target = bounds
    target.origin.y += strength * abs(strength) * 10
    target = clipView.constrainBoundsRect(target)
    guard target.origin != bounds.origin else { return }
    clipView.scroll(to: target.origin)
    scrollView.reflectScrolledClipView(clipView)
  }

  deinit {
    timer?.invalidate()
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
  }
}

struct DragScrollAnchor: NSViewRepresentable {
  let scroller: DragAutoScroller

  func makeCoordinator() -> DragAutoScroller { scroller }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    scroller.anchor = view
    return view
  }

  func updateNSView(_ view: NSView, context: Context) { scroller.anchor = view }

  static func dismantleNSView(_ view: NSView, coordinator: DragAutoScroller) {
    coordinator.stop()
    coordinator.anchor = nil
  }
}
