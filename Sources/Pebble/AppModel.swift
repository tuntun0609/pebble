import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
  let store: NoteStore
  let capture: CaptureService
  @Published var query = ""
  @Published var selection = Set<UUID>()
  @Published var expanded = Set<UUID>()
  @Published var activeSectionID: UUID
  @Published var draft = ""
  @Published var isCreatingSection = false
  @Published var editingID: UUID?
  @Published var editingText = ""
  @Published var composerFocus = 0
  @Published var searchFocus = 0
  @Published var toast: LocalizedMessage?
  @Published var showCompleted: Bool {
    didSet { UserDefaults.standard.set(showCompleted, forKey: "showCompleted") }
  }
  @Published var alwaysOnTop: Bool {
    didSet { UserDefaults.standard.set(alwaysOnTop, forKey: "alwaysOnTop"); onWindowSettingsChanged?() }
  }
  @Published var appearance: String {
    didSet { UserDefaults.standard.set(appearance, forKey: "appearance"); onWindowSettingsChanged?() }
  }
  var onHide: (() -> Void)?
  var onShowSettings: (() -> Void)?
  var onEditInWindow: ((UUID) -> Void)?
  var onFocusCards: (() -> Void)?
  var onWindowSettingsChanged: (() -> Void)?
  private var anchor: UUID?
  private var toastTask: Task<Void, Never>?

  init(store: NoteStore, capture: CaptureService) {
    self.store = store
    self.capture = capture
    activeSectionID = store.sections.first!.id
    showCompleted = UserDefaults.standard.bool(forKey: "showCompleted")
    alwaysOnTop = UserDefaults.standard.object(forKey: "alwaysOnTop") as? Bool ?? true
    appearance = UserDefaults.standard.string(forKey: "appearance") ?? "system"
  }

  var colorScheme: ColorScheme? {
    appearance == "light" ? .light : appearance == "dark" ? .dark : nil
  }
  var activeSection: NoteSection { store.sections.first { $0.id == activeSectionID } ?? store.sections[0] }
  var visibleNotes: [Note] {
    store.sections.flatMap { section in notes(in: section.id) }
  }
  func notes(in section: UUID) -> [Note] {
    store.notes.filter {
      $0.sectionID == section && (showCompleted || !$0.isDone) &&
      (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) ||
       (store.sections.first { $0.id == section }?.name.localizedCaseInsensitiveContains(query) ?? false))
    }
  }
  var selectedNotes: [Note] { visibleNotes.filter { selection.contains($0.id) } }
  var visibleSelection: Set<UUID> { Set(selectedNotes.map(\.id)) }
  func reconcileSelection() {
    selection.formIntersection(Set(visibleNotes.map(\.id)))
    if !store.sections.contains(where: { $0.id == activeSectionID }) { activeSectionID = store.sections[0].id }
  }

  func select(_ id: UUID, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
    onFocusCards?()
    if modifiers.contains(.shift), let anchor,
       let start = visibleNotes.firstIndex(where: { $0.id == anchor }),
       let end = visibleNotes.firstIndex(where: { $0.id == id }) {
      selection = Set(visibleNotes[min(start, end)...max(start, end)].map(\.id))
    } else if modifiers.contains(.command) {
      if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
      anchor = id
    } else {
      selection = [id]
      anchor = id
    }
    if let note = store.notes.first(where: { $0.id == id }) { activeSectionID = note.sectionID }
  }
  func prepareContext(_ id: UUID) { if !selection.contains(id) { select(id, modifiers: []) } }
  func stepSelection(_ delta: Int, extend: Bool) {
    guard !visibleNotes.isEmpty else { return }
    let current = visibleNotes.firstIndex(where: { $0.id == anchor }) ?? (delta > 0 ? -1 : visibleNotes.count)
    let next = visibleNotes[max(0, min(visibleNotes.count - 1, current + delta))].id
    if extend { selection.insert(next) } else { selection = [next] }
    anchor = next
    if let note = store.notes.first(where: { $0.id == next }) { activeSectionID = note.sectionID }
    onFocusCards?()
  }
  func submitDraft() {
    guard let id = store.add(text: draft, sectionID: activeSection.id) else { return }
    draft = ""
    selection = [id]
    composerFocus += 1
  }
  func captured(_ text: String) {
    guard let id = store.add(text: text, sectionID: activeSection.id) else { return }
    selection = [id]
    query = ""
    showToast(LocalizedMessage("Captured", "已收集"))
  }
  func copy(asList: Bool = false) {
    let notes = selectedNotes
    guard !notes.isEmpty else { return }
    let text = notes.enumerated().map { index, note in
      asList ? "\(index + 1). \(note.text.replacingOccurrences(of: "\n", with: "\n   "))" : note.text
    }.joined(separator: "\n\n")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    showToast(asList ? LocalizedMessage("Copied as list", "已复制为列表") : LocalizedMessage("Copied", "已复制"))
  }
  func markDone(_ ids: Set<UUID>? = nil) {
    let targets = ids ?? visibleSelection
    store.toggleDone(ids: targets)
    if !showCompleted { selection.subtract(targets) }
  }
  func deleteSelection() {
    guard !visibleSelection.isEmpty else { return }
    store.remove(ids: visibleSelection)
    selection = []
    showToast(LocalizedMessage("Deleted · ⌘Z to undo", "已删除 · 按 ⌘Z 撤销"))
  }
  func mergeSelection() {
    guard let id = store.merge(ids: visibleSelection) else { return }
    selection = [id]
    showToast(LocalizedMessage("Notes merged", "笔记已合并"))
  }
  func beginEdit(_ id: UUID) {
    guard let note = store.notes.first(where: { $0.id == id }) else { return }
    editingText = note.text
    editingID = id
  }
  func commitEdit() {
    guard let id = editingID else { return }
    if !editingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      store.update(id: id, text: editingText)
    }
    editingID = nil
    onFocusCards?()
  }
  func moveSelection(to section: UUID) {
    store.move(ids: visibleSelection, to: section)
    activeSectionID = section
  }
  func showToast(_ message: LocalizedMessage) {
    toastTask?.cancel()
    withAnimation(.easeOut(duration: 0.15)) { toast = message }
    toastTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 2_400_000_000)
      guard !Task.isCancelled else { return }
      withAnimation(.easeIn(duration: 0.2)) { self?.toast = nil }
    }
  }
  func askSectionName(existing: NoteSection? = nil) {
    let alert = NSAlert()
    alert.messageText = existing == nil ? tr("New Section", "新建分组") : tr("Rename Section", "重命名分组")
    alert.addButton(withTitle: existing == nil ? tr("Create", "创建") : tr("Save", "保存"))
    alert.addButton(withTitle: tr("Cancel", "取消"))
    let field = NSTextField(string: existing?.name ?? "")
    field.placeholderString = tr("Section name", "分组名称")
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 26)
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    if let existing { store.renameSection(id: existing.id, name: field.stringValue) }
    else if let id = store.addSection(name: field.stringValue) { activeSectionID = id; composerFocus += 1 }
  }
}
