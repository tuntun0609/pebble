import AppKit
import SwiftUI

struct MenuBarPopoverView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var store: NoteStore
  @ObservedObject var capture: CaptureService
  @ObservedObject private var localization = Localization.shared
  @Environment(\.colorScheme) private var colorScheme
  @State private var query = ""
  @State private var copiedID: UUID?

  let onOpenMainPanel: () -> Void

  private var visibleSections: [NoteSection] {
    store.sections.filter { !notes(in: $0.id).isEmpty }
  }

  private var visibleNotes: [Note] {
    visibleSections.flatMap { notes(in: $0.id) }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
        .padding(.horizontal, 13)
        .padding(.top, 12)
        .padding(.bottom, 8)

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          if let error = store.errorMessage {
            Label(error.text, systemImage: "exclamationmark.triangle")
              .font(.system(size: 11))
              .foregroundStyle(.orange)
              .padding(10)
          }

          if visibleNotes.isEmpty {
            emptyState
          } else {
            ForEach(visibleSections) { section in
              VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                  Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                  Text(section.name.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                  Rectangle().fill(.secondary.opacity(0.22)).frame(height: 1)
                }
                .frame(height: 22)
                .padding(.bottom, 3)
                VStack(spacing: 7) {
                  ForEach(notes(in: section.id)) { note in
                    noteCard(note)
                  }
                }
              }
            }
          }
        }
        .padding(.horizontal, 13)
        .padding(.top, 4)
        .padding(.bottom, 13)
      }
      .scrollIndicators(.hidden)
    }
    .frame(width: 360, height: 540)
    .background(VisualEffectBackground())
    .background(colorScheme == .dark ? Color.black.opacity(0.15) : Color.white.opacity(0.15))
    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous)
      .strokeBorder(.white.opacity(colorScheme == .dark ? 0.15 : 0.45), lineWidth: 1))
    .preferredColorScheme(model.colorScheme)
    .onChange(of: store.notes) { _, _ in
      if let copiedID, !store.notes.contains(where: { $0.id == copiedID }) { self.copiedID = nil }
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField(tr("Search", "搜索"), text: $query)
          .textFieldStyle(.plain)
          .font(.system(size: 14))
          .accessibilityLabel(tr("Search notes", "搜索便签"))
        if !query.isEmpty {
          Button { query = "" } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(tr("Clear search", "清空搜索"))
        }
      }
      .padding(.horizontal, 12)
      .frame(height: 31)
      .background(.background.opacity(0.66), in: Capsule())

      Button { model.showCompleted.toggle() } label: {
        Image(systemName: model.showCompleted ? "checkmark.circle.fill" : "checkmark.circle")
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(model.showCompleted ? Color.accentColor : Color.secondary)
          .frame(width: 31, height: 31)
          .background(.background.opacity(0.66), in: Circle())
      }
      .buttonStyle(.plain)
      .help(tr("Show completed notes", "显示已完成便签"))
      .accessibilityLabel(tr("Show completed notes", "显示已完成便签"))

      Button { store.undo() } label: {
        Image(systemName: "arrow.uturn.backward")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(store.canUndo ? Color.primary : Color.secondary.opacity(0.45))
          .frame(width: 31, height: 31)
          .background(.background.opacity(0.66), in: Circle())
      }
      .buttonStyle(.plain)
      .disabled(!store.canUndo)
      .help(tr("Undo", "撤销"))

      Menu {
        Button(tr("Open Pebble", "打开 Pebble"), systemImage: "macwindow") { onOpenMainPanel() }
        Button(tr("New Note…", "新建笔记…"), systemImage: "square.and.pencil") {
          model.composerFocus += 1
          onOpenMainPanel()
        }
        Button(tr("Capture Selected Text", "收集选中文字"), systemImage: "text.viewfinder") {
          capture.captureSelection()
        }
        Divider()
        Button(tr("Redo", "重做"), systemImage: "arrow.uturn.forward") { store.redo() }
          .disabled(!store.canRedo)
        Button(tr("Settings…", "设置…"), systemImage: "gearshape") { model.onShowSettings?() }
        Button(tr("Show Local Files", "显示本地文件"), systemImage: "folder") {
          NSWorkspace.shared.open(store.directory)
        }
        Button(tr("Check for Updates…", "检查更新…"), systemImage: "arrow.down.circle") {
          model.onCheckForUpdates?()
        }
        Divider()
        Button(tr("Quit Pebble", "退出 Pebble"), systemImage: "xmark.circle") { NSApp.terminate(nil) }
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 31, height: 31)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .frame(width: 31, height: 31)
      .background(.background.opacity(0.66), in: Circle())
      .accessibilityLabel(tr("More options", "更多选项"))
    }
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: query.isEmpty ? "note.text" : "magnifyingglass")
        .font(.system(size: 24, weight: .light))
        .foregroundStyle(.secondary)
      Text(query.isEmpty ? tr("No notes yet", "还没有便签") : tr("No matching notes", "没有找到匹配的便签"))
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 30)
  }

  private func noteCard(_ note: Note) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Button { store.toggleDone(ids: [note.id]) } label: {
        Image(systemName: note.isDone ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(note.isDone ? Color.accentColor : Color.secondary.opacity(0.75))
          .frame(width: 18, height: 20)
      }
      .buttonStyle(.plain)
      .help(note.isDone ? tr("Mark incomplete", "标记为未完成") : tr("Mark as done", "标记为已完成"))

      MarkdownNoteText(text: note.text)
        .font(.system(size: 14))
        .lineSpacing(2)
        .lineLimit(3)
        .foregroundStyle(note.isDone ? Color.secondary : Color.primary)
        .opacity(note.isDone ? 0.65 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { copy(note) }
        .help(tr("Click to copy", "点击复制"))

      if note.isPinned {
        Button { store.setPinned(ids: [note.id], to: false) } label: {
          Image(systemName: "pin.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .frame(width: 18, height: 20)
        }
        .buttonStyle(.plain)
        .help(tr("Unpin note", "取消置顶"))
        .accessibilityLabel(tr("Unpin note", "取消置顶"))
      }

      if copiedID == note.id {
        Image(systemName: "checkmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Color.accentColor)
          .padding(.top, 3)
          .transition(.opacity)
      }
    }
    .padding(.horizontal, 13)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
      .fill(.background.opacity(colorScheme == .dark ? 0.72 : 0.88)))
    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
      .strokeBorder(Color.primary.opacity(0.045), lineWidth: 1))
    .contextMenu {
      Button(tr("Copy", "复制"), systemImage: "doc.on.doc") { copy(note) }
      Button(note.isDone ? tr("Mark incomplete", "标记为未完成") : tr("Mark as done", "标记为已完成")) {
        store.toggleDone(ids: [note.id])
      }
      if note.isPinned {
        Button(tr("Unpin", "取消置顶")) { store.setPinned(ids: [note.id], to: false) }
      } else {
        Button(tr("Pin", "置顶"), systemImage: "pin") { store.setPinned(ids: [note.id], to: true) }
      }
    }
  }

  private func notes(in sectionID: UUID) -> [Note] {
    let matching = store.notes.filter { note in
      note.sectionID == sectionID && (model.showCompleted || !note.isDone) &&
      (query.isEmpty || note.text.localizedCaseInsensitiveContains(query) ||
       (store.sections.first(where: { $0.id == sectionID })?.name.localizedCaseInsensitiveContains(query) ?? false))
    }
    return matching.filter(\.isPinned) + matching.filter { !$0.isPinned }
  }

  private func copy(_ note: Note) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(note.text, forType: .string)
    withAnimation(.easeOut(duration: 0.15)) { copiedID = note.id }
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_200_000_000)
      if copiedID == note.id { withAnimation(.easeIn(duration: 0.15)) { copiedID = nil } }
    }
  }
}
