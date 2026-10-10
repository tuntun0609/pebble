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
  @State private var copyResetTask: Task<Void, Never>?

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
    // NSPopover draws the background, corners, border, and arrow as one surface.
    // A separate rounded background exposes its backing at the mismatched corners.
    .preferredColorScheme(model.colorScheme)
    .onChange(of: store.notes) { _, _ in
      if let copiedID, !store.notes.contains(where: { $0.id == copiedID }) {
        copyResetTask?.cancel()
        self.copiedID = nil
      }
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

      ZStack {
        Circle().fill(.background.opacity(0.66))
        Image(systemName: "ellipsis")
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 31, height: 31)
      }
      .frame(width: 31, height: 31)
      .overlay {
        NativeMenuHitTarget(label: tr("More options", "更多选项"), entries: [
          .item(title: tr("Open Pebble", "打开 Pebble"), systemImage: "macwindow", action: { onOpenMainPanel() }),
          .item(title: tr("New Note…", "新建笔记…"), systemImage: "square.and.pencil", action: {
            model.composerFocus += 1
            onOpenMainPanel()
          }),
          .item(title: tr("Capture Selected Text", "收集选中文字"), systemImage: "text.viewfinder", action: { capture.captureSelection() }),
          .separator,
          .item(title: tr("Redo", "重做"), systemImage: "arrow.uturn.forward", isEnabled: store.canRedo, action: { store.redo() }),
          .item(title: tr("Settings…", "设置…"), systemImage: "gearshape", action: { model.onShowSettings?() }),
          .item(title: tr("Show Local Files", "显示本地文件"), systemImage: "folder", action: { NSWorkspace.shared.open(store.directory) }),
          .item(title: tr("Check for Updates…", "检查更新…"), systemImage: "arrow.down.circle", action: { model.onCheckForUpdates?() }),
          .separator,
          .item(title: tr("Quit Pebble", "退出 Pebble"), systemImage: "xmark.circle", action: { NSApp.terminate(nil) })
        ])
        .frame(width: 56, height: 48)
      }
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

      noteTrailingIcon(note)
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
    copyResetTask?.cancel()
    withAnimation(.easeOut(duration: 0.15)) { copiedID = note.id }
    copyResetTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      guard !Task.isCancelled, copiedID == note.id else { return }
      withAnimation(.easeInOut(duration: 0.15)) { copiedID = nil }
    }
  }

  @ViewBuilder
  private func noteTrailingIcon(_ note: Note) -> some View {
    let isCopied = copiedID == note.id

    if note.isPinned {
      Button {
        guard !isCopied else { return }
        store.setPinned(ids: [note.id], to: false)
      } label: {
        ZStack {
          Image(systemName: "pin.fill")
            .font(.system(size: 12, weight: .medium))
            .opacity(isCopied ? 0 : 1)
          Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .semibold))
            .opacity(isCopied ? 1 : 0)
        }
        .foregroundStyle(Color.accentColor)
        .frame(width: 18, height: 20)
      }
      .buttonStyle(.plain)
      .disabled(isCopied)
      .help(isCopied ? tr("Copied", "已复制") : tr("Unpin note", "取消置顶"))
      .accessibilityLabel(isCopied ? tr("Copied", "已复制") : tr("Unpin note", "取消置顶"))
    } else {
      Image(systemName: "checkmark")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.accentColor)
        .frame(width: 18, height: 20)
        .opacity(isCopied ? 1 : 0)
        .accessibilityHidden(true)
    }
  }
}
