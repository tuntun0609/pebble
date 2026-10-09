import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ServiceManagement

struct VisualEffectBackground: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .hudWindow
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }
  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct WindowDragArea: NSViewRepresentable {
  final class DragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
      window?.performDrag(with: event)
    }
  }

  func makeNSView(context: Context) -> DragView { DragView() }
  func updateNSView(_ view: DragView, context: Context) {}
}

private let noteDragType = UTType.utf8PlainText
private let sectionDragType = UTType(exportedAs: "local.pebble.Pebble.section", conformingTo: .data)

private struct ItemDropPosition: Equatable {
  let areaID: String
  let sectionID: UUID
  let after: Bool
}

private struct ItemDropDelegate: DropDelegate {
  let areaID: String
  let sectionID: UUID
  let dragType: UTType
  let frame: CGRect
  let sectionHeight: CGFloat
  let moveSection: ((UUID, Bool) -> Void)?
  let splitsArea: Bool
  let autoScroller: DragAutoScroller
  @Binding var position: ItemDropPosition?
  let move: (UUID, Bool) -> Void

  func validateDrop(info: DropInfo) -> Bool {
    // Nested targets must handle section drags instead of relying on the enclosing drop target.
    info.hasItemsConforming(to: moveSection == nil ? [dragType] : [dragType, sectionDragType])
  }

  func dropEntered(info: DropInfo) { update(info) }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    update(info)
    return DropProposal(operation: .move)
  }

  func dropExited(info: DropInfo) {
    if position?.areaID == destination(info).areaID { position = nil }
  }

  func performDrop(info: DropInfo) -> Bool {
    let after = destination(info).after
    let isSection = info.hasItemsConforming(to: [sectionDragType])
    let type = isSection ? sectionDragType : dragType
    let action = isSection ? (moveSection ?? move) : move
    autoScroller.stop()
    position = nil
    guard let provider = info.itemProviders(for: [type]).first else { return false }
    provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
      guard let data, let value = String(data: data, encoding: .utf8),
            let id = UUID(uuidString: value) else { return }
      DispatchQueue.main.async { action(id, after) }
    }
    return true
  }

  private func update(_ info: DropInfo) {
    let target = destination(info)
    // AppKit can update the destination again after mouse-up as the reordered views move.
    guard NSEvent.pressedMouseButtons & 1 != 0 else {
      if position?.areaID == target.areaID { position = nil }
      return
    }
    position = target
  }

  private func destination(_ info: DropInfo) -> ItemDropPosition {
    if moveSection != nil && info.hasItemsConforming(to: [sectionDragType]) {
      return ItemDropPosition(areaID: "section-\(sectionID)", sectionID: sectionID,
                              after: frame.minY + info.location.y >= sectionHeight / 2)
    }
    return ItemDropPosition(areaID: areaID, sectionID: sectionID,
                            after: splitsArea && info.location.y >= frame.height / 2)
  }
}

private struct ItemDropModifier: ViewModifier {
  let areaID: String
  let sectionID: UUID
  var dragType = noteDragType
  var sectionHeight: CGFloat = 1
  var moveSection: ((UUID, Bool) -> Void)? = nil
  var splitsArea = false
  var indicatorAtBottom = false
  let autoScroller: DragAutoScroller
  @Binding var position: ItemDropPosition?
  let move: (UUID, Bool) -> Void
  @State private var frame = CGRect(x: 0, y: 0, width: 1, height: 1)

  func body(content: Content) -> some View {
    let atBottom = indicatorAtBottom || (splitsArea && position?.after == true)
    content
      .contentShape(Rectangle())
      .background {
        GeometryReader { geometry in
          Color.clear
            .onAppear { frame = geometry.frame(in: .named(sectionID)) }
            .onChange(of: geometry.frame(in: .named(sectionID))) { _, value in frame = value }
        }
      }
      .overlay(alignment: atBottom ? .bottom : .top) {
        if position?.areaID == areaID {
          HStack(spacing: 0) {
            Circle().frame(width: 7, height: 7)
            Capsule().frame(height: 3)
            Text(tr("Drop here", "放到这里"))
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(.white)
              .padding(.horizontal, 7).frame(height: 18)
              .background(Color.accentColor, in: Capsule())
          }
          .foregroundStyle(Color.accentColor)
          .offset(y: atBottom ? 9 : -9)
          .allowsHitTesting(false)
        }
      }
      .onDrop(of: moveSection == nil ? [dragType] : [dragType, sectionDragType], delegate: ItemDropDelegate(
        areaID: areaID, sectionID: sectionID, dragType: dragType, frame: frame,
        sectionHeight: sectionHeight, moveSection: moveSection, splitsArea: splitsArea,
        autoScroller: autoScroller, position: $position, move: move))
      .zIndex(position?.areaID == areaID ? 1 : 0)
  }
}

struct PebblePanelView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var store: NoteStore
  @ObservedObject var capture: CaptureService
  @ObservedObject private var localization = Localization.shared
  @Environment(\.colorScheme) private var scheme
  @FocusState private var searchFocused: Bool
  @FocusState private var newSectionFocused: Bool
  @State private var newSectionName = ""
  @State private var dropPosition: ItemDropPosition?
  @State private var draggedSectionID: UUID?
  @State private var sectionHeights: [UUID: CGFloat] = [:]
  @StateObject private var autoScroller = DragAutoScroller()

  var body: some View {
    VStack(spacing: 0) {
      WindowDragArea().frame(height: 14)
      header.padding(.horizontal, 13)
      WindowDragArea().frame(height: 18)
      if let error = store.errorMessage {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "exclamationmark.triangle")
          Text(error.text).font(.system(size: 11))
          Button { store.errorMessage = nil } label: { Image(systemName: "xmark") }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("Dismiss error", "关闭错误提示"))
        }.foregroundStyle(.orange).padding(12)
      }
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            if store.notes.isEmpty { emptyState }
            else if model.visibleNotes.isEmpty && !model.query.isEmpty {
              VStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 30)).foregroundStyle(.secondary)
                Text(tr("No results", "没有搜索结果")).font(.headline)
                Text(tr("No notes match “\(model.query)”.", "没有与“\(model.query)”匹配的笔记。"))
                  .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
              }.frame(maxWidth: .infinity).padding(.vertical, 24)
            }
            ForEach(visibleSections) { section in
              sectionView(section)
                .zIndex(dropPosition?.sectionID == section.id ? 1 : 0)
            }
          }
          .padding(.horizontal, 13).padding(.top, 10).padding(.bottom, 16)
          .background(DragScrollAnchor(scroller: autoScroller).allowsHitTesting(false))
        }
        .scrollIndicators(.hidden)
        .onChange(of: model.selection) { _, selected in
          if let last = model.visibleNotes.last(where: { selected.contains($0.id) }) {
            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(last.id, anchor: nil) }
          }
        }
      }
      composer.padding(.horizontal, 13).padding(.bottom, 14).padding(.top, 8)
    }
    .background(VisualEffectBackground())
    .background(scheme == .dark ? Color.black.opacity(0.15) : Color.white.opacity(0.15))
    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(.white.opacity(scheme == .dark ? 0.15 : 0.45), lineWidth: 1))
    .overlay(alignment: .top) {
      if let toast = model.toast {
        Label(toast.text, systemImage: "checkmark")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 9)
          .background(.black.opacity(0.84), in: Capsule())
          .padding(.top, 57).allowsHitTesting(false)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .preferredColorScheme(model.colorScheme)
    .onChange(of: model.searchFocus) { _, _ in searchFocused = true }
    .onChange(of: model.query) { _, _ in
      dropPosition = nil
      model.selection.formIntersection(Set(model.visibleNotes.map(\.id)))
    }
    .onChange(of: model.showCompleted) { _, _ in dropPosition = nil; model.reconcileSelection() }
    .onChange(of: store.notes) { _, _ in model.reconcileSelection() }
    .onChange(of: store.sections) { _, _ in model.reconcileSelection() }
    .onDisappear { autoScroller.stop(); dropPosition = nil; draggedSectionID = nil }
  }

  private var header: some View {
    HStack(spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField(tr("Search", "搜索"), text: $model.query)
          .textFieldStyle(.plain).font(.system(size: 14)).focused($searchFocused)
          .accessibilityLabel(tr("Search notes", "搜索笔记"))
        if !model.query.isEmpty {
          Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
            .buttonStyle(.plain).accessibilityLabel(tr("Clear search", "清空搜索"))
        }
      }.padding(.horizontal, 12).frame(height: 31)
        .background(.background.opacity(0.66), in: Capsule())
      Menu {
        Button(tr("New Note", "新建笔记"), systemImage: "square.and.pencil") { model.composerFocus += 1 }
        Button(tr("New Section…", "新建分组…"), systemImage: "folder.badge.plus") { model.askSectionName() }
        Divider()
        Toggle(tr("Show Completed", "显示已完成"), isOn: $model.showCompleted)
        Toggle(tr("Always on Top", "始终置顶"), isOn: $model.alwaysOnTop)
        Divider()
        Button(tr("Undo", "撤销"), systemImage: "arrow.uturn.backward") { store.undo() }.disabled(!store.canUndo)
        Button(tr("Redo", "重做"), systemImage: "arrow.uturn.forward") { store.redo() }.disabled(!store.canRedo)
        Divider()
        Button(tr("Settings…", "设置…"), systemImage: "gearshape") { model.onShowSettings?() }
        Button(tr("Show Local Files", "显示本地文件"), systemImage: "folder") { NSWorkspace.shared.open(store.directory) }
        Button(tr("Hide Pebble", "隐藏 Pebble")) { model.onHide?() }
        Button(tr("Quit Pebble", "退出 Pebble")) { NSApp.terminate(nil) }
      } label: {
        Image(systemName: "ellipsis").font(.system(size: 16, weight: .medium))
          .foregroundStyle(.secondary).frame(width: 31, height: 31)
          .background(.background.opacity(0.66), in: Circle())
      }
      .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
      .frame(width: 31, height: 31)
      .background(.background.opacity(0.66), in: Circle())
      .accessibilityLabel(tr("More options", "更多选项"))
    }
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 14) {
      Image(systemName: "square.stack.3d.up").font(.system(size: 28, weight: .ultraLight)).foregroundStyle(.secondary)
      Text(tr("A little room for your\nnext thought.", "为下一个想法\n留一点空间。"))
        .font(.system(size: 24, weight: .medium, design: .rounded)).lineSpacing(2)
      Text(tr("Keep a useful answer, collect an idea, or line up your next prompts.", "收藏有用的回答，记录灵感，或准备下一轮提示词。"))
        .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3)
      HStack(spacing: 6) {
        Text(capture.shortcutLabel).font(.system(size: 12, weight: .medium, design: .monospaced))
          .padding(.horizontal, 8).padding(.vertical, 4).background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        Text(tr("to capture selected text", "捕获选中的文本")).font(.system(size: 11)).foregroundStyle(.secondary)
      }
      if !capture.isTrusted {
        Button(tr("Enable Quick Capture…", "启用快速捕获…")) { model.onShowSettings?() }
          .buttonStyle(.bordered).controlSize(.small)
      }
    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 24)
  }

  private var visibleSections: [NoteSection] {
    store.sections.filter { model.query.isEmpty || !model.notes(in: $0.id).isEmpty }
  }

  private var dropPositionBinding: Binding<ItemDropPosition?> {
    Binding(get: { dropPosition }, set: { target in
      if let target, let draggedSectionID,
         target.areaID == "section-\(target.sectionID)",
         !canMoveSection(draggedSectionID, relativeTo: target.sectionID, after: target.after) {
        dropPosition = nil
      } else {
        dropPosition = target
      }
    })
  }

  private func sectionView(_ section: NoteSection) -> some View {
    let notes = model.notes(in: section.id)
    let sectionHeight = sectionHeights[section.id] ?? 1
    let reorderSection: (UUID, Bool) -> Void = { id, after in
      moveSection(id, relativeTo: section.id, after: after)
    }
    let isTargeted = dropPosition?.sectionID == section.id
    let isEndTargeted = dropPosition?.areaID == "end-\(section.id)"
    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 4) {
        HStack(spacing: 8) {
          Image(systemName: "line.3.horizontal")
            .font(.system(size: 10)).foregroundStyle(.tertiary)
          Text(section.name.uppercased())
            .font(.system(size: 10, weight: .semibold)).tracking(0.8)
            .foregroundStyle(.secondary).lineLimit(1)
          Rectangle().fill(.secondary.opacity(0.22)).frame(height: 1)
          if model.activeSectionID == section.id {
            Circle().fill(.secondary.opacity(0.4)).frame(width: 4, height: 4)
          }
        }.frame(height: 22).contentShape(Rectangle())
        .onTapGesture { model.activeSectionID = section.id; model.composerFocus += 1 }
        .onDrag {
          startDragScrolling()
          dropPosition = nil
          draggedSectionID = section.id
          let provider = NSItemProvider()
          provider.registerDataRepresentation(forTypeIdentifier: sectionDragType.identifier, visibility: .all) { completion in
            completion(Data(section.id.uuidString.utf8), nil)
            return nil
          }
          return provider
        } preview: {
          Label(section.name, systemImage: "line.3.horizontal")
            .font(.system(size: 12, weight: .semibold))
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .help(tr("Drag to reorder sections", "拖拽调整分组顺序"))
        Button { model.askSectionName(existing: section) } label: {
          Image(systemName: "pencil")
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr("Rename Section…", "重命名分组…"))
        .accessibilityLabel(tr("Rename section “\(section.name)”", "重命名分组“\(section.name)”"))
      }.padding(.horizontal, 10).contentShape(Rectangle())
        .contextMenu {
          Button(tr("Add Note Here", "在此添加笔记")) { model.activeSectionID = section.id; model.composerFocus += 1 }
          Button(tr("Rename Section…", "重命名分组…")) { model.askSectionName(existing: section) }
          if store.sections.count > 1 {
            Button(tr("Delete Section (Keep Notes)", "删除分组（保留笔记）"), role: .destructive) {
              store.deleteSection(id: section.id)
              model.activeSectionID = store.sections[0].id
            }
            Button(tr("Delete Section and All Notes", "删除分组及所有笔记"), role: .destructive) {
              store.deleteSection(id: section.id, deleteNotes: true)
              model.activeSectionID = store.sections[0].id
              model.showToast(LocalizedMessage("Section and notes deleted · ⌘Z to undo", "已删除分组及所有笔记 · 按 ⌘Z 撤销"))
            }
          }
        }
        .background(isTargeted ? Color.accentColor.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .trailing) {
          if dropPosition?.areaID == "header-\(section.id)" {
            Text(tr("Move to top", "移到组首"))
              .font(.system(size: 10, weight: .medium))
              .padding(.horizontal, 6).padding(.vertical, 3)
              .background(.regularMaterial, in: Capsule())
              .foregroundStyle(Color.accentColor).allowsHitTesting(false)
          }
        }
        .padding(.bottom, 4)
        .modifier(ItemDropModifier(areaID: "header-\(section.id)", sectionID: section.id,
                                   sectionHeight: sectionHeight, moveSection: reorderSection,
                                   indicatorAtBottom: true, autoScroller: autoScroller, position: dropPositionBinding) { id, _ in
          moveNote(id, to: section.id, before: store.notes.first(where: { $0.sectionID == section.id })?.id)
        })
      ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
        noteCard(note)
          .padding(.vertical, 4)
          .modifier(ItemDropModifier(areaID: "note-\(note.id)", sectionID: section.id,
                                     sectionHeight: sectionHeight, moveSection: reorderSection,
                                     splitsArea: true, autoScroller: autoScroller, position: dropPositionBinding) { id, after in
            // Visible neighbors may have filtered-out notes between them. Keep a visual no-op unchanged.
            if let source = notes.firstIndex(where: { $0.id == id }) {
              let insertion = index + (after ? 1 : 0)
              if insertion == source || insertion == source + 1 { return }
            }
            let nextID = index + 1 < notes.count ? notes[index + 1].id : nil
            moveNote(id, to: section.id, before: after ? nextID : note.id)
          })
          .id(note.id)
      }
      if notes.isEmpty {
        Text(tr("Drop a note into this section", "拖到这里，移入此分组"))
          .font(.system(size: 10))
          .foregroundStyle(isEndTargeted ? Color.accentColor : Color.secondary.opacity(0.7))
          .frame(maxWidth: .infinity).frame(height: 32)
          .background(isEndTargeted ? Color.accentColor.opacity(0.06) : .clear,
                      in: RoundedRectangle(cornerRadius: 10))
          .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(isEndTargeted ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.18),
                          style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .allowsHitTesting(false))
          .modifier(ItemDropModifier(areaID: "end-\(section.id)", sectionID: section.id,
                                     sectionHeight: sectionHeight, moveSection: reorderSection,
                                     autoScroller: autoScroller, position: dropPositionBinding) { id, _ in
            moveNote(id, to: section.id, before: nil)
          })
      }
    }
    .background {
      GeometryReader { geometry in
        Color.clear
          .onAppear { sectionHeights[section.id] = geometry.size.height }
          .onChange(of: geometry.size.height) { _, height in sectionHeights[section.id] = height }
      }
    }
    .coordinateSpace(name: section.id)
    .modifier(ItemDropModifier(areaID: "section-\(section.id)", sectionID: section.id,
                               dragType: sectionDragType, splitsArea: true, autoScroller: autoScroller,
                               position: dropPositionBinding) { id, after in
      moveSection(id, relativeTo: section.id, after: after)
    })
  }

  private func noteCard(_ note: Note) -> some View {
    HStack(alignment: model.editingID == note.id ? .top : .firstTextBaseline, spacing: 10) {
      Button { model.markDone([note.id]) } label: {
        Text(Image(systemName: note.isDone ? "checkmark.circle.fill" : "circle"))
          .font(.system(size: 14, weight: .light))
          .imageScale(.large)
          .foregroundStyle(note.isDone ? Color.accentColor : Color.secondary)
          .frame(width: 19)
      }.buttonStyle(.plain).accessibilityLabel(note.isDone ? tr("Mark incomplete", "标记为未完成") : tr("Mark as done", "标记为已完成"))
      if model.editingID == note.id {
        VStack(alignment: .trailing, spacing: 7) {
          PlainTextEditor(text: $model.editingText, placeholder: tr("Note", "笔记"), onSubmit: { model.commitEdit() }, onCancel: { model.editingID = nil }, focusToken: 1)
            .frame(minHeight: 76, maxHeight: 160)
          HStack(spacing: 10) {
            Button(tr("Cancel", "取消")) { model.editingID = nil }.buttonStyle(.plain).foregroundStyle(.secondary)
            Button(tr("Save", "保存")) { model.commitEdit() }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
          }.font(.system(size: 11))
        }
      } else {
        MarkdownNoteText(text: note.text)
          .font(.system(size: 14)).lineSpacing(2)
          .lineLimit(model.expanded.contains(note.id) ? nil : 3)
          .strikethrough(note.isDone, color: .secondary.opacity(0.6))
          .opacity(note.isDone ? 0.5 : 1)
          .frame(maxWidth: .infinity, alignment: .leading)
          .allowsHitTesting(false)
      }
    }
    .padding(.horizontal, 13).padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      // Recognize selection alongside double-click editing, without delaying either buttons or selection.
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(.background.opacity(scheme == .dark ? 0.72 : 0.88))
        .onTapGesture(count: 2) { model.select(note.id, modifiers: []); model.beginEdit(note.id) }
        .simultaneousGesture(TapGesture().onEnded { model.select(note.id) })
    }
    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
      .strokeBorder(model.selection.contains(note.id) ? Color.accentColor : Color.primary.opacity(0.045), lineWidth: model.selection.contains(note.id) ? 2 : 1)
      .allowsHitTesting(false))
    .contentShape(RoundedRectangle(cornerRadius: 18))
    .contextMenu {
      Button(tr("Copy", "复制")) { context(note.id) { model.copy() } }.keyboardShortcut("c", modifiers: .command)
      Button(tr("Copy as List", "复制为列表")) { context(note.id) { model.copy(asList: true) } }.keyboardShortcut("c", modifiers: [.command, .shift])
      Divider()
      Button(note.isDone ? tr("Mark as Not Done", "标记为未完成") : tr("Mark as Done", "标记为已完成")) { context(note.id) { model.markDone() } }
      Button(model.expanded.contains(note.id) ? tr("Collapse", "收起") : tr("Expand", "展开")) {
        if model.expanded.contains(note.id) { model.expanded.remove(note.id) } else { model.expanded.insert(note.id) }
      }.disabled(model.selection.contains(note.id) && model.selection.count > 1)
      Divider()
      Button(tr("Edit", "编辑")) { model.select(note.id, modifiers: []); model.beginEdit(note.id) }
      Button(tr("Edit in New Window", "在新窗口中编辑")) { model.onEditInWindow?(note.id) }
      Button(tr("Merge Notes", "合并笔记")) { context(note.id) { model.mergeSelection() } }.disabled(!model.selection.contains(note.id) || model.selection.count < 2)
      Menu(tr("Move to", "移动到")) {
        ForEach(store.sections) { section in
          Button(section.name) { context(note.id) { model.moveSelection(to: section.id) } }
        }
      }
      Divider()
      Button(tr("Delete", "删除"), role: .destructive) { context(note.id) { model.deleteSelection() } }
    }
    .onDrag {
      startDragScrolling()
      dropPosition = nil
      draggedSectionID = nil
      return NSItemProvider(object: note.id.uuidString as NSString)
    } preview: {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "line.3.horizontal").foregroundStyle(Color.accentColor)
        Text(note.text).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
      }
      .font(.system(size: 12)).padding(12).frame(width: 240)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
      .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor.opacity(0.5)))
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(note.text)
  }

  private var composer: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Menu {
          ForEach(store.sections) { section in
            Button(section.name) {
              model.activeSectionID = section.id
              dismissNewSection()
            }
          }
          Divider()
          Button(tr("New Section…", "新建分组…")) {
            newSectionName = ""
            model.isCreatingSection = true
          }
        } label: {
          (Text(tr("Section", "分组")).foregroundColor(.secondary)
            + Text("  \(model.activeSection.name)").foregroundColor(.primary).fontWeight(.medium))
            .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10).frame(height: 28)
        .overlay(Capsule().strokeBorder(.primary.opacity(scheme == .dark ? 0.22 : 0.14), lineWidth: 1).allowsHitTesting(false))
        .help(tr("Choose section", "选择分组"))
        .accessibilityLabel(tr("Choose section", "选择分组"))
        .accessibilityValue(model.activeSection.name)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 13).padding(.top, 11)
      VStack(alignment: .leading, spacing: 4) {
        if model.isCreatingSection { newSectionForm }
        PlainTextEditor(text: $model.draft,
                        placeholder: model.activeSection.name == "Notes" ? tr("Add a note or a prompt", "添加笔记或提示词") : tr("Add to \(model.activeSection.name)", "添加到“\(model.activeSection.name)”"),
                        onSubmit: { model.submitDraft() },
                        onCancel: { model.onFocusCards?(); model.onHide?() },
                        focusToken: model.composerFocus)
          .frame(height: 55)
          .accessibilityLabel(tr("Add a note or a prompt", "添加笔记或提示词"))
      }.padding(.horizontal, 13).padding(.top, 8).padding(.bottom, 9)
    }
      .background(.background.opacity(0.86))
      .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(.primary.opacity(0.035), lineWidth: 1))
      .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
  }

  private var newSectionForm: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(tr("New Section", "新建分组")).fontWeight(.medium)
      TextField(tr("Section name", "分组名称"), text: $newSectionName)
        .textFieldStyle(.roundedBorder).focused($newSectionFocused)
        .onSubmit { createSection() }
        .onExitCommand { dismissNewSection() }
        .onAppear { newSectionFocused = true }
      HStack(spacing: 6) {
        Spacer()
        Button(tr("Cancel", "取消")) { dismissNewSection() }.buttonStyle(.bordered)
        Button(tr("Create", "创建")) { createSection() }.buttonStyle(.borderedProminent).tint(.primary)
          .disabled(newSectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }.controlSize(.small)
    }
    .font(.system(size: 12)).padding(.top, 2).padding(.bottom, 10)
    .onDisappear { newSectionName = ""; newSectionFocused = false }
  }

  private func createSection() {
    guard let id = store.addSection(name: newSectionName) else { return }
    model.activeSectionID = id
    dismissNewSection()
  }

  private func dismissNewSection() {
    model.isCreatingSection = false
    model.composerFocus += 1
  }

  private func context(_ id: UUID, action: () -> Void) { model.prepareContext(id); action() }

  private func startDragScrolling() {
    autoScroller.start {
      dropPosition = nil
      draggedSectionID = nil
    }
  }

  private func moveNote(_ id: UUID, to sectionID: UUID, before destinationID: UUID?) {
    guard store.reorder(noteID: id, to: sectionID, before: destinationID) else { return }
    model.activeSectionID = sectionID
    model.showToast(LocalizedMessage("Note moved · ⌘Z to undo", "笔记已移动 · 按 ⌘Z 撤销"))
  }

  private func canMoveSection(_ id: UUID, relativeTo destinationID: UUID, after: Bool) -> Bool {
    let sections = visibleSections
    guard let source = sections.firstIndex(where: { $0.id == id }),
          let destination = sections.firstIndex(where: { $0.id == destinationID }) else { return false }
    let insertion = destination + (after ? 1 : 0)
    return insertion != source && insertion != source + 1
  }

  private func moveSection(_ id: UUID, relativeTo destinationID: UUID, after: Bool) {
    defer { if draggedSectionID == id { draggedSectionID = nil } }
    guard canMoveSection(id, relativeTo: destinationID, after: after) else { return }
    guard store.reorder(sectionID: id, relativeTo: destinationID, after: after) else { return }
    model.showToast(LocalizedMessage("Section moved · ⌘Z to undo", "分组已移动 · 按 ⌘Z 撤销"))
  }

}

struct SettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var capture: CaptureService
  @ObservedObject private var localization = Localization.shared
  @State private var recording = false
  @State private var loginEnabled = SMAppService.mainApp.status == .enabled
  @State private var loginError: String?
  var body: some View {
    Form {
      Section(tr("General", "通用")) {
        Picker(tr("Language", "语言"), selection: $localization.language) {
          Text("English").tag(AppLanguage.english)
          Text("简体中文").tag(AppLanguage.chinese)
        }
        HStack {
          Text(tr("Version", "版本"))
          Spacer()
          Text(Self.appVersion).foregroundStyle(.secondary)
        }
      }
      Section {
        HStack {
          Label(capture.isTrusted ? tr("Quick Capture is ready", "快速捕获已就绪") : tr("Accessibility permission required", "需要辅助功能权限"), systemImage: capture.isTrusted ? "checkmark.circle.fill" : "hand.raised")
            .foregroundStyle(capture.isTrusted ? Color.green : Color.primary)
          Spacer()
          if !capture.isTrusted { Button(tr("Enable…", "启用…")) { capture.requestPermission() } }
        }
        Text(tr("Select text in another app, then press your capture shortcut. Notes stay on this Mac.", "在其他应用中选中文本，再按捕获快捷键。笔记只保存在这台 Mac 上。"))
          .font(.callout).foregroundStyle(.secondary)
        HStack {
          Text(tr("Capture shortcut", "捕获快捷键"))
          Spacer()
          Text(capture.shortcutLabel).font(.system(.body, design: .monospaced))
          Button(recording ? tr("Cancel", "取消") : tr("Record…", "录制…")) { recording.toggle(); capture.recordingShortcut = recording }
          Button(tr("Reset", "重置")) { capture.resetShortcut(); recording = false; capture.recordingShortcut = false }
        }
        if recording {
          ShortcutRecorder { event in
            if event.keyCode != 53 { capture.setShortcut(keyCode: event.keyCode, modifiers: event.modifierFlags) }
            recording = false
            capture.recordingShortcut = false
          }.frame(height: 38)
        }
        Text(tr("When direct capture is unavailable, Pebble briefly uses Copy and restores the previous clipboard if it is still unchanged. You can always paste a note manually.", "无法直接捕获时，Pebble 会短暂使用复制功能，并在剪贴板未被其他操作更改时恢复原有内容。你也可以手动粘贴笔记。"))
          .font(.caption).foregroundStyle(.secondary)
      } header: { Text(tr("Capture", "捕获")) }
      Section(tr("Window", "窗口")) {
        Toggle(tr("Always on top", "始终置顶"), isOn: $model.alwaysOnTop)
        Picker(tr("Appearance", "外观"), selection: $model.appearance) {
          Text(tr("System", "跟随系统")).tag("system")
          Text(tr("Light", "浅色")).tag("light")
          Text(tr("Dark", "深色")).tag("dark")
        }
        Toggle(tr("Launch at login", "登录时启动"), isOn: $loginEnabled)
          .onChange(of: loginEnabled) { _, enabled in
            do {
              if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
              loginError = nil
            } catch {
              loginError = error.localizedDescription
              loginEnabled = SMAppService.mainApp.status == .enabled
            }
          }
        if let loginError {
          Text(tr("Could not change launch at login: \(loginError)", "无法更改登录启动设置：\(loginError)"))
            .font(.caption).foregroundStyle(.orange)
        }
      }
      Section(tr("Local files", "本地文件")) {
        Text(tr("Automatically saved. No account, sync, or tracking.", "自动保存，无需账号，没有同步或追踪。")).font(.callout).foregroundStyle(.secondary)
        Button(tr("Show Notes in Finder", "在访达中显示笔记")) { NSWorkspace.shared.open(model.store.directory) }
      }
      Section(tr("Keyboard", "键盘快捷键")) {
        shortcutRow(tr("New note / Search", "新建笔记 / 搜索"), "⌘N / ⌘F")
        shortcutRow(tr("Select / Add to selection", "选择 / 扩展选择"), "↑ ↓ / ⇧↑ ⇧↓")
        shortcutRow(tr("Copy / Copy as list", "复制 / 复制为列表"), "⌘C / ⇧⌘C")
        shortcutRow(tr("Mark as done / Edit", "标记完成 / 编辑"), tr("Space / Return", "空格 / 回车"))
        shortcutRow(tr("Edit in new window / Merge", "在新窗口编辑 / 合并"), tr("⌘Return / ⇧⌘M", "⌘回车 / ⇧⌘M"))
        shortcutRow(tr("Undo / Redo / Hide", "撤销 / 重做 / 隐藏"), "⌘Z / ⇧⌘Z / Esc")
      }
    }.formStyle(.grouped).padding(8).frame(width: 510, height: 660)
      .preferredColorScheme(model.colorScheme)
      .onAppear { capture.refreshPermission() }
      .onDisappear { capture.recordingShortcut = false }
  }
  private func shortcutRow(_ title: String, _ keys: String) -> some View {
    HStack { Text(title); Spacer(); Text(keys).foregroundStyle(.secondary).font(.system(.caption, design: .monospaced)) }
  }
  private static var appVersion: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "—"
    guard let build = info?["CFBundleVersion"] as? String, build != short else { return short }
    return "\(short) (\(build))"
  }
}

struct ShortcutRecorder: NSViewRepresentable {
  var onRecord: (NSEvent) -> Void
  func makeNSView(context: Context) -> ShortcutRecorderView {
    let view = ShortcutRecorderView()
    view.onRecord = onRecord
    return view
  }
  func updateNSView(_ view: ShortcutRecorderView, context: Context) {
    view.onRecord = onRecord
    view.needsDisplay = true
    DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
  }
}
final class ShortcutRecorderView: NSView {
  var onRecord: ((NSEvent) -> Void)?
  override var acceptsFirstResponder: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    let text = tr("Press ⌘, ⌥ or ⌃ with a key · Esc to cancel", "按 ⌘、⌥ 或 ⌃ 加其他键 · Esc 取消") as NSString
    text.draw(at: NSPoint(x: 12, y: 11), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 || !event.modifierFlags.intersection([.command, .option, .control]).isEmpty { onRecord?(event) }
    else { NSSound.beep() }
  }
  override func performKeyEquivalent(with event: NSEvent) -> Bool { keyDown(with: event); return true }
}
