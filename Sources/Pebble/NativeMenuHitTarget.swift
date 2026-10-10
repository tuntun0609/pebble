import AppKit
import SwiftUI

enum NativeMenuEntry {
  case separator
  case item(
    title: String,
    systemImage: String? = nil,
    isEnabled: Bool = true,
    isOn: Bool? = nil,
    action: () -> Void
  )
}

struct NativeMenuHitTarget: NSViewRepresentable {
  let label: String
  let entries: [NativeMenuEntry]

  func makeCoordinator() -> Coordinator { Coordinator(entries: entries) }

  func makeNSView(context: Context) -> MenuHitTargetView {
    let view = MenuHitTargetView()
    let button = MenuHitButton(frame: .zero)
    view.menuButton = button
    view.addSubview(button)
    button.onOpen = { [weak coordinator = context.coordinator, weak button] in
      guard let button else { return }
      coordinator?.showMenu(from: button)
    }
    button.setAccessibilityLabel(label)
    return view
  }

  func updateNSView(_ view: MenuHitTargetView, context: Context) {
    context.coordinator.entries = entries
    view.menuButton.setAccessibilityLabel(label)
    view.menuButton.onOpen = { [weak coordinator = context.coordinator, weak button = view.menuButton] in
      guard let button else { return }
      coordinator?.showMenu(from: button)
    }
  }

  final class Coordinator: NSObject {
    var entries: [NativeMenuEntry]

    init(entries: [NativeMenuEntry]) { self.entries = entries }

    func showMenu(from button: NSView) {
      let menu = NSMenu()
      menu.autoenablesItems = false
      for (index, entry) in entries.enumerated() {
        switch entry {
        case .separator:
          menu.addItem(.separator())
        case .item(let title, let symbol, let enabled, let isOn, _):
          let item = NSMenuItem(title: title, action: #selector(selectItem(_:)), keyEquivalent: "")
          item.target = self
          item.representedObject = index
          item.isEnabled = enabled
          item.state = isOn.map { $0 ? .on : .off } ?? .off
          if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
          }
          menu.addItem(item)
        }
      }
      guard let positioningView = button.superview else { return }
      let visibleButtonFrame = button.convert(button.bounds, to: positioningView)
      let anchor = NSPoint(x: visibleButtonFrame.minX, y: positioningView.bounds.maxY)
      menu.popUp(positioning: nil, at: anchor, in: positioningView)
    }

    @objc private func selectItem(_ sender: NSMenuItem) {
      guard let index = sender.representedObject as? Int, entries.indices.contains(index),
            case .item(_, _, _, _, let action) = entries[index] else { return }
      action()
    }
  }
}

final class MenuHitTargetView: NSView {
  var menuButton: MenuHitButton!

  override var isFlipped: Bool { true }

  override func layout() {
    super.layout()
    let size: CGFloat = 31
    menuButton.frame = NSRect(
      x: (bounds.width - size) / 2,
      y: (bounds.height - size) / 2,
      width: size,
      height: size
    )
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard bounds.contains(point), !isHidden, alphaValue > 0 else { return nil }
    return menuButton
  }
}

final class MenuHitButton: NSButton {
  var onOpen: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    isBordered = false
    title = ""
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func draw(_ dirtyRect: NSRect) {}
  override func mouseDown(with event: NSEvent) { onOpen?() }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
