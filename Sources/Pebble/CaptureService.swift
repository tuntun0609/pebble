import AppKit
import ApplicationServices
import Carbon
import Combine

struct CaptureShortcut: Codable, Equatable {
  var keyCode: UInt16
  var modifiers: UInt

  var label: String {
    let flags = NSEvent.ModifierFlags(rawValue: modifiers)
    let prefix = (flags.contains(.control) ? "⌃" : "")
      + (flags.contains(.option) ? "⌥" : "")
      + (flags.contains(.shift) ? "⇧" : "")
      + (flags.contains(.command) ? "⌘" : "")
    let names: [UInt16: String] = [
      0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
      11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
      20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8",
      29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L",
      38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
      47: ".", 48: "⇥", 49: tr("Space", "空格"), 50: "`", 51: "⌫", 53: "⎋", 64: "F17", 65: ".",
      67: "*", 69: "+", 71: tr("Clear", "清除"), 75: "/", 76: "⌤", 78: "−", 79: "F18", 80: "F19",
      81: "=", 82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7",
      90: "F20", 91: "8", 92: "9", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
      101: "F9", 103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12",
      113: "F15", 114: tr("Help", "帮助"), 115: "↖", 116: "⇞", 117: "⌦", 118: "F4", 119: "↘",
      120: "F2", 121: "⇟", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
    return prefix + (names[keyCode] ?? tr("Key \(keyCode)", "按键 \(keyCode)"))
  }
}

@MainActor
final class CaptureService: ObservableObject {
  @Published var isTrusted = AXIsProcessTrusted()
  @Published private(set) var shortcut: CaptureShortcut {
    didSet {
      if let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: "captureShortcut") }
      resetGesture()
    }
  }
  @Published private(set) var usesDoubleShift: Bool {
    didSet { defaults.set(usesDoubleShift, forKey: "captureUsesDoubleShift"); resetGesture() }
  }

  var onCapture: ((String?) -> Void)?
  var onStatus: ((LocalizedMessage) -> Void)?
  var lastSourceApplication: NSRunningApplication?
  var recordingShortcut = false {
    didSet {
      resetGesture()
      guard running else { return }
      // Release the old combination so the recorder can receive it too.
      if recordingShortcut { unregisterHotKey() }
      else { activateSavedShortcut() }
    }
  }
  var shortcutLabel: String { usesDoubleShift ? "⇧ ⇧" : shortcut.label }

  private let defaults: UserDefaults
  private let selectionQueue = DispatchQueue(label: "local.pebble.selection", qos: .userInitiated)
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var permissionTimer: Timer?
  private var hotKey: EventHotKeyRef?
  private var hotKeyHandler: EventHandlerRef?
  private var registeredShortcut: CaptureShortcut?
  private var hotKeyID: UInt32 = 0
  private var nextHotKeyID: UInt32 = 0
  private var hotKeyIsDown = false
  private var running = false
  private var shiftDownAt: TimeInterval?
  private var firstShiftUpAt: TimeInterval?
  private var overlappingShifts = false
  private var interactionSerial = 0
  private var activeRequest: UUID?
  private static let shortcutModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
  private static let syntheticEventTag: Int64 = 0x43505052
  private static let hotKeySignature: OSType = 0x43707072

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    shortcut = defaults.data(forKey: "captureShortcut")
      .flatMap { try? JSONDecoder().decode(CaptureShortcut.self, from: $0) }
      ?? CaptureShortcut(keyCode: 49, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue)
    usesDoubleShift = defaults.object(forKey: "captureUsesDoubleShift") as? Bool ?? true
  }

  func start() {
    guard !running else { return }
    refreshPermission()
    running = true
    installMonitors()
    activateSavedShortcut()
    permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      DispatchQueue.main.async { self?.refreshPermission() }
    }
  }

  func stop() {
    running = false
    permissionTimer?.invalidate()
    permissionTimer = nil
    removeMonitors()
    unregisterHotKey()
    if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    hotKeyHandler = nil
    activeRequest = nil
    resetGesture()
  }

  func refreshPermission() {
    let trusted = AXIsProcessTrusted()
    if isTrusted != trusted {
      isTrusted = trusted
      if running { installMonitors() }
    }
  }

  func requestPermission() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
    refreshPermission()
  }

  func setShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
    let flags = modifiers.intersection(Self.shortcutModifiers)
    guard ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode) else {
      onStatus?(LocalizedMessage("Choose a letter, number, or function key for your shortcut.", "请选择字母、数字或功能键作为快捷键。"))
      return
    }
    guard !flags.intersection([.command, .option, .control]).isEmpty else {
      onStatus?(LocalizedMessage("Include Command, Option, or Control in your shortcut.", "快捷键须包含 Command、Option 或 Control。"))
      return
    }
    let candidate = CaptureShortcut(keyCode: keyCode, modifiers: flags.rawValue)
    if running {
      let status = registerHotKey(candidate)
      guard status == noErr else {
        onStatus?(status == eventHotKeyExistsErr
          ? LocalizedMessage("That shortcut is already in use. Your previous shortcut is unchanged.", "该快捷键已被占用，已保留原快捷键。")
          : LocalizedMessage("Couldn't register that shortcut (\(status)). Your previous shortcut is unchanged.", "无法注册该快捷键（\(status)），已保留原快捷键。"))
        return
      }
    }
    shortcut = candidate
    usesDoubleShift = false
  }

  func resetShortcut() {
    unregisterHotKey()
    usesDoubleShift = true
  }

  private func activateSavedShortcut() {
    guard running, !usesDoubleShift, !recordingShortcut else { return }
    let status = registerHotKey(shortcut)
    if status != noErr {
      unregisterHotKey()
      usesDoubleShift = true
      onStatus?(LocalizedMessage("Your saved shortcut is unavailable (\(status)). Double Shift is enabled instead.", "已保存的快捷键不可用（\(status)），已改为双击 Shift。"))
    }
  }

  private func registerHotKey(_ candidate: CaptureShortcut) -> OSStatus {
    let flags = NSEvent.ModifierFlags(rawValue: candidate.modifiers)
    guard candidate.keyCode < 128, ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(candidate.keyCode),
          !flags.intersection([.command, .option, .control]).isEmpty else { return OSStatus(paramErr) }
    if hotKey != nil, registeredShortcut == candidate { return noErr }
    if hotKeyHandler == nil {
      let types = [
        EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
        EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
      ]
      let status = types.withUnsafeBufferPointer { buffer in
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
          guard let event, let context else { return OSStatus(eventNotHandledErr) }
          var identifier = EventHotKeyID()
          let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                         EventParamType(typeEventHotKeyID), nil,
                                         MemoryLayout<EventHotKeyID>.size, nil, &identifier)
          guard status == noErr else { return status }
          let service = Unmanaged<CaptureService>.fromOpaque(context).takeUnretainedValue()
          // The application event target is dispatched by the main application event loop.
          return MainActor.assumeIsolated {
            service.handleHotKey(identifier, kind: GetEventKind(event))
          }
        }, buffer.count, buffer.baseAddress,
        Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
      }
      guard status == noErr else { return status }
    }
    var carbonFlags: UInt32 = 0
    if flags.contains(.command) { carbonFlags |= UInt32(cmdKey) }
    if flags.contains(.option) { carbonFlags |= UInt32(optionKey) }
    if flags.contains(.control) { carbonFlags |= UInt32(controlKey) }
    if flags.contains(.shift) { carbonFlags |= UInt32(shiftKey) }
    nextHotKeyID &+= 1
    if nextHotKeyID == 0 { nextHotKeyID = 1 }
    let identifier = EventHotKeyID(signature: Self.hotKeySignature, id: nextHotKeyID)
    var replacement: EventHotKeyRef?
    let status = RegisterEventHotKey(UInt32(candidate.keyCode), carbonFlags, identifier,
                                     GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &replacement)
    guard status == noErr, let replacement else { return status == noErr ? OSStatus(paramErr) : status }
    let previous = hotKey
    hotKey = replacement
    hotKeyID = identifier.id
    registeredShortcut = candidate
    hotKeyIsDown = false
    if let previous { UnregisterEventHotKey(previous) }
    return noErr
  }

  private func unregisterHotKey() {
    if let hotKey { UnregisterEventHotKey(hotKey) }
    hotKey = nil
    registeredShortcut = nil
    hotKeyIsDown = false
  }

  private func handleHotKey(_ identifier: EventHotKeyID, kind: UInt32) -> OSStatus {
    guard identifier.signature == Self.hotKeySignature, identifier.id == hotKeyID else {
      return OSStatus(eventNotHandledErr)
    }
    guard running, hotKey != nil, !usesDoubleShift, !recordingShortcut else { return noErr }
    if kind == UInt32(kEventHotKeyPressed) {
      hotKeyIsDown = true
    } else if kind == UInt32(kEventHotKeyReleased), hotKeyIsDown {
      hotKeyIsDown = false
      captureSelection()
    }
    return noErr
  }

  private func installMonitors() {
    removeMonitors()
    let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
      DispatchQueue.main.async { self?.handle(event) }
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      DispatchQueue.main.async { self?.handle(event) }
      return event
    }
  }

  private func removeMonitors() {
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    globalMonitor = nil
    localMonitor = nil
  }

  private func handle(_ event: NSEvent) {
    if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventTag { return }
    interactionSerial += 1
    guard !recordingShortcut else { resetGesture(); return }
    let modifiers = event.modifierFlags.intersection(Self.shortcutModifiers)
    guard usesDoubleShift else { return }
    guard event.type == .flagsChanged, event.keyCode == 56 || event.keyCode == 60 else {
      resetGesture()
      return
    }
    guard modifiers.subtracting(.shift).isEmpty else { resetGesture(); return }
    if overlappingShifts {
      if !modifiers.contains(.shift) { resetGesture() }
      return
    }
    if modifiers.contains(.shift) {
      // Both Shift keys held at once, or another press before a release, is not a tap.
      guard shiftDownAt == nil else { resetGesture(); overlappingShifts = true; return }
      shiftDownAt = event.timestamp
    } else {
      guard let downAt = shiftDownAt, event.timestamp - downAt <= 0.35 else {
        resetGesture()
        return
      }
      shiftDownAt = nil
      if let previous = firstShiftUpAt, event.timestamp - previous <= 0.45 {
        resetGesture()
        captureSelection()
      } else {
        firstShiftUpAt = event.timestamp
      }
    }
  }

  private func resetGesture() { shiftDownAt = nil; firstShiftUpAt = nil; overlappingShifts = false }

  func captureSelection() {
    guard activeRequest == nil, !recordingShortcut else { return }
    resetGesture()
    let request = UUID()
    activeRequest = request
    guard !IsSecureEventInputEnabled() else {
      finish(request, status: LocalizedMessage("Secure input is active. Capture is unavailable here.", "安全输入已启用，当前无法捕获文字。"))
      return
    }
    guard let application = NSWorkspace.shared.frontmostApplication,
          application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
      finish(request)
      return
    }
    lastSourceApplication = application
    refreshPermission()
    guard isTrusted else {
      finish(request, status: LocalizedMessage("Enable Accessibility in Settings to capture selected text.", "请在系统设置中允许辅助功能权限，以捕获选中文字。"))
      return
    }
    waitForKeyRelease(request, application: application, attempts: 60)
  }

  private func waitForKeyRelease(_ request: UUID, application: NSRunningApplication, attempts: Int) {
    guard activeRequest == request else { return }
    guard attempts > 0 else {
      finish(request, status: LocalizedMessage("Release the shortcut keys, then try again.", "请松开快捷键后重试。"))
      return
    }
    if !NSEvent.modifierFlags.intersection(Self.shortcutModifiers).isEmpty {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
        self?.waitForKeyRelease(request, application: application, attempts: attempts - 1)
      }
      return
    }
    let pid = application.processIdentifier
    guard sourceIsCurrent(pid), !IsSecureEventInputEnabled() else {
      finish(request, status: LocalizedMessage("The active app changed. Select the text and try again.", "前台应用已切换，请重新选中文字后重试。"))
      return
    }
    selectionQueue.async { [weak self] in
      let result = Self.readSelection(pid: pid)
      DispatchQueue.main.async { self?.handleSelection(result, request: request, pid: pid) }
    }
  }

  private func sourceIsCurrent(_ pid: pid_t) -> Bool {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
  }

  private enum SelectionResult {
    case text(String), empty, unsupported, protected, failed
  }

  private nonisolated static func readSelection(pid: pid_t) -> SelectionResult {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.3)
    var focused: CFTypeRef?
    let focusResult = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
    guard focusResult == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
      return focusResult == .cannotComplete || focusResult == .apiDisabled ? .failed : .unsupported
    }
    let element = focused as! AXUIElement
    AXUIElementSetMessagingTimeout(element, 0.3)
    var ancestor: AXUIElement? = element
    for _ in 0..<4 {
      guard let current = ancestor else { break }
      if attribute(current, kAXSubroleAttribute as CFString) as? String == kAXSecureTextFieldSubrole as String {
        return .protected
      }
      if let parent = attribute(current, kAXParentAttribute as CFString), CFGetTypeID(parent) == AXUIElementGetTypeID() {
        ancestor = (parent as! AXUIElement)
      } else { ancestor = nil }
    }
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
    if result == .noValue { return .empty }
    if result == .attributeUnsupported || result == .notImplemented { return .unsupported }
    guard result == .success, let text = value as? String else { return .failed }
    guard !text.isEmpty else { return .empty }
    if let range = attribute(element, kAXSelectedTextRangeAttribute as CFString) {
      var attributed: CFTypeRef?
      if AXUIElementCopyParameterizedAttributeValue(element, kAXAttributedStringForRangeParameterizedAttribute as CFString,
                                                    range, &attributed) == .success,
         let attributed = attributed as? NSAttributedString, attributed.string == text {
        return .text(markdown(from: attributed))
      }
    }
    return .text(text)
  }

  private nonisolated static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
  }

  private func handleSelection(_ result: SelectionResult, request: UUID, pid: pid_t) {
    guard activeRequest == request else { return }
    guard sourceIsCurrent(pid), !IsSecureEventInputEnabled() else {
      finish(request, status: LocalizedMessage("The active app changed. Select the text and try again.", "前台应用已切换，请重新选中文字后重试。"))
      return
    }
    switch result {
    case .text(let text): finish(request, text: text)
    case .empty: finish(request)
    case .unsupported: copyFallback(request, pid: pid)
    case .protected: finish(request, status: LocalizedMessage("Password fields cannot be captured.", "无法捕获密码输入框中的内容。"))
    case .failed: finish(request, status: LocalizedMessage("Couldn't read this selection. Copy and paste it into a note.", "无法读取选中文字，请手动复制并粘贴到笔记中。"))
    }
  }

  private struct ClipboardSnapshot {
    var changeCount: Int
    var items: [[NSPasteboard.PasteboardType: Data]]
  }

  private func copyFallback(_ request: UUID, pid: pid_t) {
    guard sourceIsCurrent(pid), !IsSecureEventInputEnabled(),
          NSEvent.modifierFlags.intersection(Self.shortcutModifiers).isEmpty,
          CGPreflightPostEventAccess() else {
      finish(request, status: LocalizedMessage("Couldn't capture this selection. Copy and paste it into a note.", "无法捕获选中文字，请手动复制并粘贴到笔记中。"))
      return
    }
    let pasteboard = NSPasteboard.general
    let originalCount = pasteboard.changeCount
    var items: [[NSPasteboard.PasteboardType: Data]] = []
    for item in pasteboard.pasteboardItems ?? [] {
      var saved: [NSPasteboard.PasteboardType: Data] = [:]
      for type in item.types {
        guard let data = item.data(forType: type) else {
          finish(request, status: LocalizedMessage("Couldn't preserve your clipboard. Copy and paste the selection into a note.", "无法备份剪贴板，请手动复制选中文字并粘贴到笔记中。"))
          return
        }
        saved[type] = data
      }
      items.append(saved)
    }
    guard pasteboard.changeCount == originalCount else {
      finish(request, status: LocalizedMessage("The clipboard changed. Please try capturing again.", "剪贴板内容已改变，请重新捕获。"))
      return
    }
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: false) else {
      finish(request, status: LocalizedMessage("Couldn't copy this selection. Copy and paste it into a note.", "无法复制选中文字，请手动复制并粘贴到笔记中。"))
      return
    }
    let snapshot = ClipboardSnapshot(changeCount: originalCount, items: items)
    let serial = interactionSerial
    for event in [down, up] {
      event.flags = .maskCommand
      event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
      event.postToPid(pid)
    }
    pollClipboard(request, pid: pid, snapshot: snapshot, serial: serial, remaining: 24)
  }

  private func pollClipboard(_ request: UUID, pid: pid_t, snapshot: ClipboardSnapshot, serial: Int, remaining: Int) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      guard let self, self.activeRequest == request else { return }
      guard self.sourceIsCurrent(pid), self.interactionSerial == serial, !IsSecureEventInputEnabled() else {
        self.finish(request, status: LocalizedMessage("Capture was interrupted. No further clipboard changes were made.", "捕获已中断，此后未再修改剪贴板。"))
        return
      }
      let count = NSPasteboard.general.changeCount
      if count != snapshot.changeCount {
        // A second observation prevents restoring over a clipboard write still in progress.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
          self?.readCopiedClipboard(request, pid: pid, snapshot: snapshot, serial: serial, expectedCount: count)
        }
      } else if remaining > 0 {
        self.pollClipboard(request, pid: pid, snapshot: snapshot, serial: serial, remaining: remaining - 1)
      } else {
        self.finish(request, status: LocalizedMessage("This app didn't copy any selected text. Copy and paste it into a note.", "来源应用未复制任何选中文字，请手动复制并粘贴到笔记中。"))
      }
    }
  }

  private func readCopiedClipboard(_ request: UUID, pid: pid_t, snapshot: ClipboardSnapshot, serial: Int, expectedCount: Int) {
    guard activeRequest == request else { return }
    let pasteboard = NSPasteboard.general
    guard pasteboard.changeCount == expectedCount, interactionSerial == serial,
          sourceIsCurrent(pid), !IsSecureEventInputEnabled() else {
      finish(request, status: LocalizedMessage("The clipboard changed during capture. Please try again.", "捕获期间剪贴板内容已改变，请重试。"))
      return
    }
    var text = pasteboard.string(forType: .string)
    if let data = pasteboard.data(forType: .rtf),
       let rich = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
       text == nil || text == rich.string {
      text = Self.markdown(from: rich)
    }
    guard pasteboard.changeCount == expectedCount else {
      finish(request, status: LocalizedMessage("The clipboard changed during capture. Please try again.", "捕获期间剪贴板内容已改变，请重试。"))
      return
    }
    let restored = snapshot.items.map { values -> NSPasteboardItem in
      let item = NSPasteboardItem()
      for (type, data) in values { item.setData(data, forType: type) }
      return item
    }
    // Recheck immediately before restoration, including after materializing every saved item.
    guard pasteboard.changeCount == expectedCount, interactionSerial == serial,
          sourceIsCurrent(pid), !IsSecureEventInputEnabled() else {
      finish(request, status: LocalizedMessage("Capture was interrupted. No further clipboard changes were made.", "捕获已中断，此后未再修改剪贴板。"))
      return
    }
    let clearedCount = pasteboard.clearContents()
    guard pasteboard.changeCount == clearedCount else {
      finish(request, status: LocalizedMessage("The clipboard changed during restoration. No further changes were made.", "恢复期间剪贴板内容已改变，此后未再修改。"))
      return
    }
    let restoredSuccessfully = restored.isEmpty || pasteboard.writeObjects(restored)
    if let text, !text.isEmpty {
      finish(request, text: text, status: restoredSuccessfully ? nil : LocalizedMessage("Captured the text, but couldn't restore your previous clipboard.", "文字已捕获，但未能恢复原剪贴板内容。"))
    }
    else { finish(request, status: LocalizedMessage("No text was copied. Select text and try again.", "未复制到文字，请选中文字后重试。")) }
  }

  private func finish(_ request: UUID, text: String? = nil, status: LocalizedMessage? = nil) {
    guard activeRequest == request else { return }
    activeRequest = nil
    if let status { onStatus?(status) }
    onCapture?(text)
  }

  private nonisolated static func markdown(from attributed: NSAttributedString) -> String {
    struct Run { var text: String; var bold: Bool; var link: String? }
    var runs: [Run] = []
    attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
      let text = (attributed.string as NSString).substring(with: range)
      var bold = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
      if let font = attributes[NSAttributedString.Key(kAXFontTextAttribute.takeUnretainedValue() as String)] as? [String: Any],
         let name = font[kAXFontNameKey.takeUnretainedValue() as String] as? String {
        bold = bold || ["bold", "heavy", "black"].contains { name.lowercased().contains($0) }
      }
      var link = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String
      if link == nil, let reference = attributes[NSAttributedString.Key(kAXLinkTextAttribute.takeUnretainedValue() as String)] {
        let value = reference as CFTypeRef
        if CFGetTypeID(value) == AXUIElementGetTypeID() {
          let element = value as! AXUIElement
          AXUIElementSetMessagingTimeout(element, 0.2)
          let url = attribute(element, kAXURLAttribute as CFString)
          link = (url as? URL)?.absoluteString ?? url as? String
        }
      }
      if let last = runs.last, last.bold == bold, last.link == link { runs[runs.count - 1].text += text }
      else { runs.append(Run(text: text, bold: bold, link: link)) }
    }
    return runs.map { run in
      guard run.bold || run.link != nil else { return run.text }
      return run.text.components(separatedBy: "\n").map { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let range = line.range(of: trimmed) else { return line }
        var content = trimmed.replacingOccurrences(of: "\\", with: "\\\\")
          .replacingOccurrences(of: "*", with: "\\*")
          .replacingOccurrences(of: "[", with: "\\[")
          .replacingOccurrences(of: "]", with: "\\]")
        if run.bold { content = "**\(content)**" }
        if let link = run.link, !link.isEmpty {
          let destination = link.replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
          content = "[\(content)](\(destination))"
        }
        return String(line[..<range.lowerBound]) + content + String(line[range.upperBound...])
      }.joined(separator: "\n")
    }.joined()
  }
}
