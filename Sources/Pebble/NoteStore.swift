import Combine
import Foundation

struct Note: Identifiable, Codable, Equatable {
  var id: UUID
  var text: String
  var sectionID: UUID
  var isDone: Bool
  var isPinned: Bool
  var createdAt: Date
  var updatedAt: Date

  private enum CodingKeys: String, CodingKey {
    case id, text, sectionID, isDone, isPinned, createdAt, updatedAt
  }

  init(id: UUID, text: String, sectionID: UUID, isDone: Bool, isPinned: Bool = false,
       createdAt: Date, updatedAt: Date) {
    self.id = id
    self.text = text
    self.sectionID = sectionID
    self.isDone = isPinned ? false : isDone
    self.isPinned = isPinned
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    self.init(id: try values.decode(UUID.self, forKey: .id),
              text: try values.decode(String.self, forKey: .text),
              sectionID: try values.decode(UUID.self, forKey: .sectionID),
              isDone: try values.decode(Bool.self, forKey: .isDone),
              isPinned: isPinned,
              createdAt: try values.decode(Date.self, forKey: .createdAt),
              updatedAt: try values.decode(Date.self, forKey: .updatedAt))
  }
}

struct NoteSection: Identifiable, Codable, Equatable {
  var id: UUID
  var name: String
}

@MainActor
final class NoteStore: ObservableObject {
  @Published private(set) var notes: [Note] = []
  @Published private(set) var sections: [NoteSection] = []
  @Published var errorMessage: LocalizedMessage?

  private(set) var directory: URL
  var canUndo: Bool { !undoHistory.isEmpty }
  var canRedo: Bool { !redoHistory.isEmpty }

  private struct Snapshot: Codable, Equatable {
    var notes: [Note]
    var sections: [NoteSection]
  }

  private var undoHistory: [Snapshot] = []
  private var redoHistory: [Snapshot] = []
  private var lastEditID: UUID?
  private var lastEditAt = Date.distantPast
  private var lastSavedData: Data?
  private var blockedSaveReason: LocalizedMessage?
  private var fileURL: URL { directory.appendingPathComponent("notes.json") }
  private var backupURL: URL { directory.appendingPathComponent("notes.backup.json") }
  private var snapshot: Snapshot { Snapshot(notes: notes, sections: sections) }

  init(directory: URL? = nil) {
    self.directory = (directory ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Pebble", isDirectory: true))
      .standardizedFileURL
    sections = [NoteSection(id: UUID(), name: tr("Notes", "笔记"))]
    if directory == nil, !FileManager.default.fileExists(atPath: self.directory.path) {
      let previousDirectory = self.directory.deletingLastPathComponent()
        .appendingPathComponent("Copper Local", isDirectory: true)
      if FileManager.default.fileExists(atPath: previousDirectory.path) {
        do {
          try FileManager.default.moveItem(at: previousDirectory, to: self.directory)
        } catch {
          let message = LocalizedMessage("Could not migrate notes to the Pebble data folder. Saving is disabled; repair the data folder and reopen Pebble. \(error.localizedDescription)",
                                         "无法将笔记迁移到 Pebble 数据目录，保存已暂停；请修复数据目录后重新打开 Pebble。\(error.localizedDescription)")
          blockedSaveReason = message
          errorMessage = message
          return
        }
      }
    }
    load()
  }

  @discardableResult
  func add(text: String, sectionID: UUID) -> UUID? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, sections.contains(where: { $0.id == sectionID }) else { return nil }
    let now = Date()
    let note = Note(id: UUID(), text: text, sectionID: sectionID, isDone: false,
                    createdAt: now, updatedAt: now)
    var next = snapshot
    next.notes.append(note)
    commit(next)
    return note.id
  }

  func update(id: UUID, text: String) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, let index = notes.firstIndex(where: { $0.id == id && !$0.isPinned }),
          notes[index].text != text else { return }
    var next = snapshot
    next.notes[index].text = text
    next.notes[index].updatedAt = Date()
    commit(next, editID: id)
  }

  func toggleDone(ids: Set<UUID>) {
    let selected = notes.filter { ids.contains($0.id) && !$0.isPinned }
    guard !selected.isEmpty else { return }
    let isDone = !selected.allSatisfy(\.isDone)
    let now = Date()
    var next = snapshot
    for index in next.notes.indices where ids.contains(next.notes[index].id) && !next.notes[index].isPinned {
      if next.notes[index].isDone != isDone {
        next.notes[index].isDone = isDone
        next.notes[index].updatedAt = now
      }
    }
    commit(next)
  }

  func remove(ids: Set<UUID>) {
    var next = snapshot
    next.notes.removeAll { ids.contains($0.id) && !$0.isPinned }
    commit(next)
  }

  func setPinned(ids: Set<UUID>, to isPinned: Bool) {
    let changing = notes.filter { ids.contains($0.id) && $0.isPinned != isPinned }
    guard !changing.isEmpty else { return }
    let changingIDs = Set(changing.map(\.id))
    let now = Date()
    var next = snapshot
    for index in next.notes.indices where changingIDs.contains(next.notes[index].id) {
      next.notes[index].isPinned = isPinned
      if isPinned { next.notes[index].isDone = false }
      next.notes[index].updatedAt = now
    }

    for section in sections {
      let moved = next.notes.filter { changingIDs.contains($0.id) && $0.sectionID == section.id }
      guard !moved.isEmpty else { continue }
      let movedIDs = Set(moved.map(\.id))
      next.notes.removeAll { movedIDs.contains($0.id) }
      let insertion: Int
      if isPinned,
         let firstPinned = next.notes.firstIndex(where: { $0.sectionID == section.id && $0.isPinned }) {
        insertion = firstPinned
      } else if let firstUnpinned = next.notes.firstIndex(where: { $0.sectionID == section.id && !$0.isPinned }) {
        insertion = firstUnpinned
      } else {
        insertion = next.notes.lastIndex(where: { $0.sectionID == section.id }).map { $0 + 1 } ?? next.notes.endIndex
      }
      next.notes.insert(contentsOf: moved, at: insertion)
    }
    commit(next)
  }

  @discardableResult
  func merge(ids: Set<UUID>) -> UUID? {
    let selected = sections.flatMap { section in notes.filter { $0.sectionID == section.id && ids.contains($0.id) } }
    guard selected.count > 1, let first = selected.first,
          selected.allSatisfy({ !$0.isPinned }),
          let index = notes.firstIndex(where: { $0.id == first.id }) else { return nil }
    var next = snapshot
    next.notes[index].text = selected.map(\.text).joined(separator: "\n\n")
    next.notes[index].isDone = selected.allSatisfy(\.isDone)
    next.notes[index].updatedAt = Date()
    next.notes.removeAll { ids.contains($0.id) && $0.id != first.id }
    commit(next)
    return first.id
  }

  @discardableResult
  func removeCompleted(in sectionID: UUID? = nil) -> Int {
    let ids = Set(notes.filter { $0.isDone && (sectionID == nil || $0.sectionID == sectionID) }.map(\.id))
    guard !ids.isEmpty else { return 0 }
    remove(ids: ids)
    return ids.count
  }

  func move(ids: Set<UUID>, to sectionID: UUID) {
    guard sections.contains(where: { $0.id == sectionID }) else { return }
    let now = Date()
    var next = snapshot
    for index in next.notes.indices where ids.contains(next.notes[index].id) && !next.notes[index].isPinned {
      if next.notes[index].sectionID != sectionID {
        next.notes[index].sectionID = sectionID
        next.notes[index].updatedAt = now
      }
    }
    commit(next)
  }

  @discardableResult
  func addSection(name: String) -> UUID? {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return nil }
    let section = NoteSection(id: UUID(), name: name)
    var next = snapshot
    next.sections.append(section)
    commit(next)
    return section.id
  }

  func renameSection(id: UUID, name: String) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, let index = sections.firstIndex(where: { $0.id == id }) else { return }
    var next = snapshot
    next.sections[index].name = name
    commit(next)
  }

  func deleteSection(id: UUID, deleteNotes: Bool = false) {
    guard sections.count > 1, sections.contains(where: { $0.id == id }),
          let destination = sections.first(where: { $0.id != id }),
          !notes.contains(where: { $0.sectionID == id && $0.isPinned }) else { return }
    var next = snapshot
    next.sections.removeAll { $0.id == id }
    if deleteNotes {
      next.notes.removeAll { $0.sectionID == id }
    } else {
      let now = Date()
      for index in next.notes.indices where next.notes[index].sectionID == id {
        next.notes[index].sectionID = destination.id
        next.notes[index].updatedAt = now
      }
    }
    commit(next)
  }

  @discardableResult
  func reorder(sectionID: UUID, relativeTo destinationID: UUID, after: Bool) -> Bool {
    guard sectionID != destinationID,
          let index = sections.firstIndex(where: { $0.id == sectionID }) else { return false }
    var next = snapshot
    let section = next.sections.remove(at: index)
    guard let destination = next.sections.firstIndex(where: { $0.id == destinationID }) else { return false }
    next.sections.insert(section, at: destination + (after ? 1 : 0))
    guard next.sections != sections else { return false }
    commit(next)
    return true
  }

  @discardableResult
  func reorder(noteID: UUID, to sectionID: UUID, before destinationID: UUID? = nil) -> Bool {
    guard sections.contains(where: { $0.id == sectionID }),
          let index = notes.firstIndex(where: { $0.id == noteID }) else { return false }
    let source = notes[index]
    guard !source.isPinned || source.sectionID == sectionID else { return false }
    if let destinationID {
      guard noteID != destinationID,
            notes.contains(where: { $0.id == destinationID && $0.sectionID == sectionID }) else { return false }
    }
    var next = snapshot
    var note = next.notes.remove(at: index)
    note.sectionID = sectionID
    let destination: Int
    if let destinationID {
      guard let anchor = next.notes.firstIndex(where: { $0.id == destinationID && $0.sectionID == sectionID }) else { return false }
      let target = next.notes[anchor]
      if target.isPinned == note.isPinned {
        destination = anchor
      } else {
        destination = next.notes.firstIndex(where: { $0.sectionID == sectionID && !$0.isPinned })
          ?? (next.notes.lastIndex(where: { $0.sectionID == sectionID }).map { $0 + 1 } ?? next.notes.endIndex)
      }
    } else {
      if note.isPinned {
        destination = next.notes.firstIndex(where: { $0.sectionID == sectionID && !$0.isPinned })
          ?? (next.notes.lastIndex(where: { $0.sectionID == sectionID }).map { $0 + 1 } ?? next.notes.endIndex)
      } else {
        destination = next.notes.lastIndex(where: { $0.sectionID == sectionID }).map { $0 + 1 } ?? next.notes.endIndex
      }
    }
    next.notes.insert(note, at: destination)
    if notes[index].sectionID == sectionID,
       notes.filter({ $0.sectionID == sectionID }).map(\.id)
         == next.notes.filter({ $0.sectionID == sectionID }).map(\.id) { return false }
    next.notes[destination].updatedAt = Date()
    commit(next)
    return true
  }

  func undo() {
    guard let previous = undoHistory.popLast() else { return }
    redoHistory.append(snapshot)
    lastEditID = nil
    apply(previous)
    save()
  }

  func redo() {
    guard let next = redoHistory.popLast() else { return }
    undoHistory.append(snapshot)
    lastEditID = nil
    apply(next)
    save()
  }

  func save() {
    if let reason = blockedSaveReason {
      errorMessage = reason
      return
    }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      let data = try encoder.encode(snapshot)
      var previousData = lastSavedData
      if FileManager.default.fileExists(atPath: fileURL.path) {
        let existing = try Data(contentsOf: fileURL)
        _ = try decode(existing)
        previousData = existing
      }
      // Keep the previous valid document before atomically replacing the current one.
      try (previousData ?? data).write(to: backupURL, options: .atomic)
      try data.write(to: fileURL, options: .atomic)
      lastSavedData = data
      errorMessage = nil
    } catch {
      errorMessage = LocalizedMessage("Could not save notes. Your changes remain in memory. \(error.localizedDescription)",
                                      "无法保存笔记，改动暂时保留在内存中。\(error.localizedDescription)")
    }
  }

  private func commit(_ next: Snapshot, editID: UUID? = nil) {
    guard next != snapshot else { return }
    let now = Date()
    let coalesceEdit = editID != nil && editID == lastEditID
      && now.timeIntervalSince(lastEditAt) < 0.8 && redoHistory.isEmpty
    if !coalesceEdit {
      undoHistory.append(snapshot)
      if undoHistory.count > 100 { undoHistory.removeFirst() }
    }
    redoHistory.removeAll()
    lastEditID = editID
    lastEditAt = now
    apply(next)
    save()
  }

  private func apply(_ value: Snapshot) {
    notes = value.notes
    sections = value.sections
  }

  private func decode(_ data: Data) throws -> Snapshot {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let value = try decoder.decode(Snapshot.self, from: data)
    let sectionIDs = Set(value.sections.map(\.id))
    guard !value.sections.isEmpty,
          sectionIDs.count == value.sections.count,
          value.sections.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
          Set(value.notes.map(\.id)).count == value.notes.count,
          value.notes.allSatisfy({ sectionIDs.contains($0.sectionID)
            && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
      throw NSError(domain: "Pebble.Notes", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: tr("The notes file contains invalid data.", "笔记文件包含无效数据。")])
    }
    return value
  }

  private func load() {
    let fileManager = FileManager.default
    let hasFile = fileManager.fileExists(atPath: fileURL.path)
    let hasBackup = fileManager.fileExists(atPath: backupURL.path)
    if !hasFile && !hasBackup {
      save()
      return
    }
    var loadError: Error?
    if hasFile {
      do {
        let data = try Data(contentsOf: fileURL)
        apply(try decode(data))
        lastSavedData = data
        return
      } catch {
        loadError = error
      }
    }
    do {
      let backup = try Data(contentsOf: backupURL)
      let recovered = try decode(backup)
      apply(recovered)
      lastSavedData = backup
      if hasFile {
        let preservedURL = directory.appendingPathComponent("notes.corrupt-\(UUID().uuidString).json")
        try fileManager.copyItem(at: fileURL, to: preservedURL)
      }
      try backup.write(to: fileURL, options: .atomic)
      errorMessage = hasFile
        ? LocalizedMessage("Notes were recovered from the backup. The damaged original was preserved in the data folder.", "已从备份恢复笔记，损坏的原文件已保留在数据文件夹中。")
        : LocalizedMessage("The notes file was missing. Notes were recovered from the backup.", "笔记文件缺失，已从备份恢复。")
    } catch {
      let detail = (loadError ?? error).localizedDescription
      let message = LocalizedMessage("Could not restore the notes file. Existing files were left untouched. Saving is disabled to protect them; repair the data folder and reopen Pebble. \(detail)",
                                     "无法恢复笔记文件。现有文件未被修改，为保护数据已暂停保存；请修复数据文件夹后重新打开 Pebble。\(detail)")
      blockedSaveReason = message
      errorMessage = message
    }
  }
}
