import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  let store: NoteStore
  let capture = CaptureService()
  let updates = UpdateService()
  let model: AppModel
  private var panel: FloatingPanel!
  private var statusItem: NSStatusItem!
  private var settingsWindow: NSWindow?
  private var editorWindows: [UUID: NSWindow] = [:]
  private var keyboardMonitor: Any?
  private var updateTimer: Timer?

  override init() {
    let arguments = CommandLine.arguments
    var directory: URL?
    if let flag = arguments.firstIndex(of: "--data-dir"), arguments.indices.contains(flag + 1) {
      directory = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
    }
    store = NoteStore(directory: directory)
    model = AppModel(store: store, capture: capture)
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    createMainMenu()
    createPanel()
    createStatusItem()
    NotificationCenter.default.addObserver(self, selector: #selector(refreshLanguage), name: .pebbleLanguageChanged, object: nil)
    model.onHide = { [weak self] in self?.hidePanel() }
    model.onShowSettings = { [weak self] in self?.showSettings() }
    model.onEditInWindow = { [weak self] id in self?.openEditor(id) }
    model.onFocusCards = { [weak self] in self?.panel.makeFirstResponder(nil) }
    model.onWindowSettingsChanged = { [weak self] in self?.applyWindowSettings() }
    updates.onInstalled = { [weak self] version in self?.promptToRestart(version: version) }
    startAutomaticUpdates()
    capture.onCapture = { [weak self] text in
      guard let self else { return }
      if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        self.model.captured(text)
        self.showPanel(activate: false)
      } else {
        self.showPanel(activate: true)
        self.model.composerFocus += 1
      }
    }
    capture.onStatus = { [weak self] text in self?.model.showToast(text) }
    capture.start()
    keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      var handled = false
      MainActor.assumeIsolated {
        if let self { handled = self.handleKey(event) == nil }
      }
      return handled ? nil : event
    }
    showPanel(activate: true)
  }
  func applicationWillTerminate(_ notification: Notification) {
    NotificationCenter.default.removeObserver(self, name: .pebbleLanguageChanged, object: nil)
    store.save()
    capture.stop()
    if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
    updateTimer?.invalidate()
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showPanel(activate: true)
    return true
  }
  func applicationDidBecomeActive(_ notification: Notification) { capture.refreshPermission() }

  private func createPanel() {
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    panel = FloatingPanel(contentRect: NSRect(x: screen.maxX - 382, y: screen.midY - 320, width: 360, height: 640),
                          styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.title = "Pebble"
    panel.identifier = NSUserInterfaceItemIdentifier("pebble-panel")
    panel.minSize = NSSize(width: 320, height: 370)
    panel.maxSize = NSSize(width: 720, height: 1400)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .utilityWindow
    panel.delegate = self
    panel.contentView = NSHostingView(rootView: PebblePanelView(model: model, store: store, capture: capture))
    panel.setFrameAutosaveName("PebblePanel")
    if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
      panel.setFrameOrigin(NSPoint(x: screen.maxX - 382, y: screen.midY - 320))
    }
    applyWindowSettings()
  }
  private func applyWindowSettings() {
    panel?.level = model.alwaysOnTop ? .floating : .normal
    let appearance: NSAppearance? = model.appearance == "system" ? nil : NSAppearance(named: model.appearance == "dark" ? .darkAqua : .aqua)
    panel?.appearance = appearance
    settingsWindow?.appearance = appearance
    editorWindows.values.forEach { $0.appearance = appearance }
  }
  private func showPanel(activate: Bool) {
    if activate {
      if let source = NSWorkspace.shared.frontmostApplication,
         source.processIdentifier != ProcessInfo.processInfo.processIdentifier {
        capture.lastSourceApplication = source
      }
      NSApp.activate(ignoringOtherApps: true)
      panel.makeKeyAndOrderFront(nil)
    } else {
      panel.orderFrontRegardless()
    }
  }
  private func hidePanel() {
    panel.orderOut(nil)
    if editorWindows.isEmpty && !(settingsWindow?.isVisible ?? false) {
      capture.lastSourceApplication?.activate(options: [])
    }
  }
  @objc private func togglePanel() {
    if panel.isVisible && panel.isKeyWindow { hidePanel() } else { showPanel(activate: true) }
  }
  @objc private func captureNow() { capture.captureSelection() }
  @objc private func showSettings() {
    if settingsWindow == nil {
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 660),
                            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
      window.title = tr("Pebble Settings", "Pebble 设置")
      window.contentView = NSHostingView(rootView: SettingsView(model: model, capture: capture, updates: updates))
      window.isReleasedWhenClosed = false
      window.center()
      settingsWindow = window
    }
    applyWindowSettings()
    settingsWindow?.level = .floating
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow?.makeKeyAndOrderFront(nil)
  }
  private func openEditor(_ id: UUID) {
    if let window = editorWindows[id] { window.makeKeyAndOrderFront(nil); return }
    guard let note = store.notes.first(where: { $0.id == id }) else { return }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = tr("Edit Note — Pebble", "编辑笔记 — Pebble")
    window.minSize = NSSize(width: 440, height: 340)
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.contentView = NSHostingView(rootView: NoteEditorView(initialText: note.text, onSave: { [weak self, weak window] text in
      self?.store.update(id: id, text: text)
      window?.close()
    }, onCancel: { [weak window] in window?.close() }))
    editorWindows[id] = window
    window.center()
    applyWindowSettings()
    window.level = .floating
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }
  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    if let id = editorWindows.first(where: { $0.value === window })?.key { editorWindows.removeValue(forKey: id) }
  }
  private func createStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let image = Bundle.main.url(forResource: "PebbleStatusTemplate", withExtension: "png")
      .flatMap { NSImage(contentsOf: $0) }
    image?.size = NSSize(width: 20, height: 20)
    image?.isTemplate = true
    image?.accessibilityDescription = "Pebble"
    statusItem.button?.image = image
    statusItem.button?.imageScaling = .scaleProportionallyDown
    statusItem.button?.toolTip = "Pebble"
    rebuildStatusMenu()
  }
  private func rebuildStatusMenu() {
    let menu = NSMenu()
    menu.addItem(item(tr("Show / Hide Pebble", "显示 / 隐藏 Pebble"), action: #selector(togglePanel)))
    menu.addItem(item(tr("Capture Selected Text", "收集选中文字"), action: #selector(captureNow)))
    menu.addItem(.separator())
    menu.addItem(item(tr("Settings…", "设置…"), action: #selector(showSettings)))
    menu.addItem(item(tr("Show Local Files", "打开本地文件夹"), action: #selector(showLocalFiles)))
    menu.addItem(item(tr("Check for Updates…", "检查更新…"), action: #selector(checkForUpdates)))
    menu.addItem(.separator())
    menu.addItem(item(tr("Quit Pebble", "退出 Pebble"), action: #selector(quit), key: "q"))
    statusItem.menu = menu
  }
  @objc private func refreshLanguage() {
    createMainMenu()
    rebuildStatusMenu()
    settingsWindow?.title = tr("Pebble Settings", "Pebble 设置")
    editorWindows.values.forEach { $0.title = tr("Edit Note — Pebble", "编辑笔记 — Pebble") }
  }
  private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.target = self
    return item
  }
  private func createMainMenu() {
    let menu = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(item(tr("Settings…", "设置…"), action: #selector(showSettings), key: ","))
    appMenu.addItem(.separator())
    appMenu.addItem(item(tr("Quit Pebble", "退出 Pebble"), action: #selector(quit), key: "q"))
    appItem.submenu = appMenu
    menu.addItem(appItem)
    let editItem = NSMenuItem()
    editItem.title = tr("Edit", "编辑")
    let editMenu = NSMenu(title: tr("Edit", "编辑"))
    editMenu.addItem(item(tr("Undo", "撤销"), action: #selector(undoAction), key: "z"))
    let redo = item(tr("Redo", "重做"), action: #selector(redoAction), key: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(redo)
    editMenu.addItem(.separator())
    for (name, selector, key) in [(tr("Cut", "剪切"), "cut:", "x"), (tr("Copy", "复制"), "copy:", "c"), (tr("Paste", "粘贴"), "paste:", "v"), (tr("Select All", "全选"), "selectAll:", "a")] {
      editMenu.addItem(NSMenuItem(title: name, action: Selector(selector), keyEquivalent: key))
    }
    editItem.submenu = editMenu
    menu.addItem(editItem)
    NSApp.mainMenu = menu
  }
  @objc private func quit() { NSApp.terminate(nil) }
  @objc private func showLocalFiles() { NSWorkspace.shared.open(store.directory) }

  private func startAutomaticUpdates() {
    guard !updates.isDevBuild else { return }
    // Ask once shortly after launch, then a few times a day. The random
    // offset keeps many installs behind one NAT from polling in lockstep.
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      await self?.updates.check(userInitiated: false)
    }
    let interval: TimeInterval = 6 * 3600
    updateTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.updates.check(userInitiated: false) }
    }
    updateTimer?.fireDate = Date().addingTimeInterval(interval + Double.random(in: 0...600))
  }
  @objc private func checkForUpdates() {
    Task { await updates.check(userInitiated: true) }
    showSettings()
  }
  private func promptToRestart(version: String) {
    let alert = NSAlert()
    alert.messageText = tr("Pebble \(version) is ready", "Pebble \(version) 已就绪")
    alert.informativeText = tr("Restart to use the new version.", "重启后即可使用新版本。")
    alert.addButton(withTitle: tr("Restart Now", "立即重启"))
    alert.addButton(withTitle: tr("Later", "稍后"))
    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertFirstButtonReturn { updates.restartNow() }
  }
  @objc private func undoAction() {
    if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.undoManager?.undo() } else { store.undo() }
  }
  @objc private func redoAction() {
    if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.undoManager?.redo() } else { store.redo() }
  }
  private func handleKey(_ event: NSEvent) -> NSEvent? {
    guard panel.isKeyWindow, !capture.recordingShortcut else { return event }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let command = flags.contains(.command)
    let shift = flags.contains(.shift)
    let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
    if command && key == "f" { model.searchFocus += 1; return nil }
    if command && key == "n" { model.composerFocus += 1; return nil }
    if event.keyCode == 53 && model.isCreatingSection {
      if (panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return event }
      model.isCreatingSection = false
      model.composerFocus += 1
      return nil
    }
    let inText = panel.firstResponder is NSTextView
    if inText {
      if event.keyCode == 53 && model.editingID == nil && !model.query.isEmpty {
        model.query = ""
        panel.makeFirstResponder(nil)
        return nil
      }
      return event
    }
    if command {
      switch key {
      case "c": model.copy(asList: shift); return nil
      case "a": model.selection = Set(model.visibleNotes.map(\.id)); return nil
      case "m" where shift: model.mergeSelection(); return nil
      case "z": shift ? store.redo() : store.undo(); return nil
      default: break
      }
      if event.keyCode == 36, let id = model.selectedNotes.first?.id { openEditor(id); return nil }
    }
    guard flags.intersection([.command, .option, .control]).isEmpty else { return event }
    switch event.keyCode {
    case 53: hidePanel(); return nil
    case 125: model.stepSelection(1, extend: shift); return nil
    case 126: model.stepSelection(-1, extend: shift); return nil
    case 49: model.markDone(); return nil
    case 36: if let id = model.selectedNotes.first?.id { model.beginEdit(id) } else { model.composerFocus += 1 }; return nil
    case 51, 117: model.deleteSelection(); return nil
    default: return event
    }
  }
}
