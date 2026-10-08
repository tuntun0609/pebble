import AppKit
import SwiftUI

/// A small Markdown renderer for note cards and the full editor preview.
/// Card callers can pass `lineLimit` or use SwiftUI's `.lineLimit(...)` modifier.
struct MarkdownNoteText: View {
  let text: String
  var lineLimit: Int? = nil

  @Environment(\.lineLimit) private var inheritedLineLimit

  private var blocks: [MarkdownBlock] { MarkdownBlock.parse(text) }

  var body: some View {
    if let limit = lineLimit ?? inheritedLineLimit {
      compactText
        .lineLimit(limit)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
          blockView(block)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var compactText: Text {
    blocks.enumerated().reduce(Text("")) { result, item in
      let separator = item.offset == 0 ? Text("") : Text("\n")
      let block = item.element
      let rendered: Text
      switch block.kind {
      case .heading:
        rendered = inline(block.content).bold()
      case .code:
        rendered = Text(block.content).font(.system(.body, design: .monospaced))
      case .quote:
        rendered = Text("│ ").foregroundColor(.secondary) + inline(block.content)
      case .bullet:
        rendered = Text("• ") + inline(block.content)
      case .numbered(let number):
        rendered = Text("\(number). ") + inline(block.content)
      case .rule:
        rendered = Text("—").foregroundColor(.secondary)
      case .paragraph:
        rendered = inline(block.content)
      }
      return result + separator + rendered
    }
  }

  @ViewBuilder
  private func blockView(_ block: MarkdownBlock) -> some View {
    switch block.kind {
    case .heading(let level):
      inline(block.content)
        .font(.system(size: level == 1 ? 23 : level == 2 ? 19 : 16, weight: .semibold))
        .padding(.top, 3)
    case .code:
      Text(block.content.isEmpty ? " " : block.content)
        .font(.system(size: 12, design: .monospaced))
        .lineSpacing(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
    case .quote:
      HStack(alignment: .top, spacing: 10) {
        RoundedRectangle(cornerRadius: 2)
          .fill(Color.secondary.opacity(0.3))
          .frame(width: 3)
        inline(block.content)
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .fixedSize(horizontal: false, vertical: true)
    case .bullet:
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("•").foregroundColor(.secondary)
        inline(block.content).frame(maxWidth: .infinity, alignment: .leading)
      }
    case .numbered(let number):
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("\(number).").foregroundColor(.secondary).monospacedDigit()
        inline(block.content).frame(maxWidth: .infinity, alignment: .leading)
      }
    case .rule:
      Divider().padding(.vertical, 3)
    case .paragraph:
      inline(block.content).lineSpacing(3)
    }
  }

  private func inline(_ source: String) -> Text {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace,
      failurePolicy: .returnPartiallyParsedIfPossible
    )
    guard var attributed = try? AttributedString(markdown: source, options: options) else {
      return Text(source)
    }
    for run in attributed.runs {
      if run.inlinePresentationIntent?.contains(.code) == true {
        attributed[run.range].font = .system(.body, design: .monospaced)
        attributed[run.range].backgroundColor = Color.primary.opacity(0.06)
      }
    }
    return Text(attributed)
  }
}

private struct MarkdownBlock {
  enum Kind {
    case paragraph, heading(Int), code, quote, bullet, numbered(String), rule
  }

  let kind: Kind
  let content: String

  static func parse(_ text: String) -> [MarkdownBlock] {
    var result: [MarkdownBlock] = []
    var paragraph: [String] = []
    var code: [String] = []
    var fence: String?

    func flushParagraph() {
      if !paragraph.isEmpty {
        result.append(.init(kind: .paragraph, content: paragraph.joined(separator: "\n")))
        paragraph.removeAll()
      }
    }

    for rawLine in text.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if let activeFence = fence {
        if line.hasPrefix(activeFence) {
          result.append(.init(kind: .code, content: code.joined(separator: "\n")))
          code.removeAll()
          fence = nil
        } else {
          code.append(rawLine)
        }
        continue
      }
      if line.hasPrefix("```") || line.hasPrefix("~~~") {
        flushParagraph()
        fence = String(line.prefix(while: { $0 == line.first }))
      } else if line.isEmpty {
        flushParagraph()
      } else if line == "---" || line == "***" || line == "___" {
        flushParagraph()
        result.append(.init(kind: .rule, content: ""))
      } else if line.hasPrefix("#") {
        let level = line.prefix(while: { $0 == "#" }).count
        let remainder = line.dropFirst(level)
        if (1...6).contains(level), remainder.first == " " {
          flushParagraph()
          result.append(.init(kind: .heading(level), content: String(remainder.dropFirst())))
        } else {
          paragraph.append(rawLine)
        }
      } else if line.hasPrefix(">") {
        flushParagraph()
        result.append(.init(kind: .quote, content: String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
      } else if ["- ", "* ", "+ "].contains(where: line.hasPrefix) {
        flushParagraph()
        result.append(.init(kind: .bullet, content: String(line.dropFirst(2))))
      } else if let match = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
        flushParagraph()
        let number = String(line[match].prefix(while: \.isNumber))
        result.append(.init(kind: .numbered(number), content: String(line[match.upperBound...])))
      } else {
        paragraph.append(rawLine)
      }
    }
    flushParagraph()
    if fence != nil {
      result.append(.init(kind: .code, content: code.joined(separator: "\n")))
    }
    return result
  }
}

/// Plain text input with native selection, clipboard, undo, and IME support.
/// With onSubmit, Return submits and Shift-Return inserts a newline. Set
/// submitOnReturn to false for a multiline editor; Command-Return still submits.
/// Without onSubmit all Return keys retain NSTextView's normal behavior.
struct PlainTextEditor: NSViewRepresentable {
  @Binding var text: String
  var placeholder: String
  var fontSize: CGFloat = 14
  var onSubmit: (() -> Void)? = nil
  var onCancel: (() -> Void)? = nil
  var onFocusChanged: ((Bool) -> Void)? = nil
  var focusToken: Int = 0
  var submitOnReturn: Bool = true

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true

    let editor = PebbleTextView(frame: .zero)
    editor.delegate = context.coordinator
    editor.isEditable = true
    editor.isSelectable = true
    editor.isRichText = false
    editor.importsGraphics = false
    editor.allowsUndo = true
    editor.drawsBackground = false
    editor.isAutomaticQuoteSubstitutionEnabled = false
    editor.isAutomaticDashSubstitutionEnabled = false
    editor.isAutomaticLinkDetectionEnabled = false
    editor.isAutomaticSpellingCorrectionEnabled = false
    editor.isAutomaticTextReplacementEnabled = false
    editor.isContinuousSpellCheckingEnabled = false
    editor.usesFindPanel = true
    editor.isVerticallyResizable = true
    editor.isHorizontallyResizable = false
    editor.autoresizingMask = [.width]
    editor.minSize = .zero
    editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    editor.textContainerInset = NSSize(width: 0, height: 2)
    editor.textContainer?.widthTracksTextView = true
    editor.textContainer?.heightTracksTextView = false
    editor.textContainer?.lineFragmentPadding = 0
    editor.string = text
    scrollView.documentView = editor
    configure(editor)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let editor = scrollView.documentView as? PebbleTextView else { return }
    configure(editor)

    // Never replace the text storage while an input method is composing.
    if editor.string != text, !editor.hasMarkedText() {
      let selectedRange = editor.selectedRange()
      editor.string = text
      let length = (text as NSString).length
      editor.setSelectedRange(NSRange(location: min(selectedRange.location, length), length: 0))
      editor.needsDisplay = true
    }
    if context.coordinator.lastFocusToken != focusToken {
      context.coordinator.lastFocusToken = focusToken
      DispatchQueue.main.async { [weak editor] in
        // A focus request never activates the app or a different window.
        guard let editor, let window = editor.window, window.isKeyWindow else { return }
        window.makeFirstResponder(editor)
      }
    }
  }

  private func configure(_ editor: PebbleTextView) {
    editor.placeholder = placeholder
    let desiredFont = NSFont.systemFont(ofSize: fontSize)
    if editor.font != desiredFont { editor.font = desiredFont }
    editor.textColor = .labelColor
    editor.insertionPointColor = .labelColor
    editor.onSubmit = onSubmit
    editor.onCancel = onCancel
    editor.onFocusChanged = onFocusChanged
    editor.submitOnReturn = submitOnReturn
    editor.setAccessibilityLabel(placeholder.isEmpty ? tr("Note text", "笔记内容") : placeholder)
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: PlainTextEditor
    var lastFocusToken = 0

    init(_ parent: PlainTextEditor) { self.parent = parent }

    func textDidChange(_ notification: Notification) {
      guard let editor = notification.object as? PebbleTextView else { return }
      parent.text = editor.string
      editor.needsDisplay = true
    }
  }
}

private final class PebbleTextView: NSTextView {
  var placeholder = "" {
    didSet { if oldValue != placeholder { needsDisplay = true } }
  }
  var onSubmit: (() -> Void)?
  var onCancel: (() -> Void)?
  var onFocusChanged: ((Bool) -> Void)?
  var submitOnReturn = true

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard string.isEmpty, !placeholder.isEmpty else { return }
    let rectangle = NSRect(
      x: textContainerInset.width,
      y: textContainerInset.height,
      width: max(0, bounds.width - textContainerInset.width * 2),
      height: max(0, bounds.height - textContainerInset.height * 2)
    )
    (placeholder as NSString).draw(in: rectangle, withAttributes: [
      .font: font ?? NSFont.systemFont(ofSize: 14),
      .foregroundColor: NSColor.placeholderTextColor
    ])
  }

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { onFocusChanged?(true) }
    return accepted
  }

  override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if accepted { onFocusChanged?(false) }
    return accepted
  }

  override func keyDown(with event: NSEvent) {
    guard !hasMarkedText() else {
      super.keyDown(with: event)
      return
    }
    if event.keyCode == 53, let onCancel {
      onCancel()
      return
    }
    if event.keyCode == 36 || event.keyCode == 76, let onSubmit {
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      let plainReturn = !flags.contains(.shift) && !flags.contains(.option) && !flags.contains(.control)
      if flags.contains(.command) || (submitOnReturn && plainReturn) {
        onSubmit()
        return
      }
    }
    super.keyDown(with: event)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard window?.firstResponder === self else {
      return super.performKeyEquivalent(with: event)
    }
    let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
    guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control) else {
      return super.performKeyEquivalent(with: event)
    }
    if event.keyCode == 36 || event.keyCode == 76, let onSubmit {
      // Consume the equivalent while composing so the window's Save
      // button cannot receive it and submit an unfinished IME draft.
      guard !hasMarkedText() else { return true }
      onSubmit()
      return true
    }
    // These remain available even in the menu-bar app's compact panel.
    switch event.charactersIgnoringModifiers?.lowercased() {
    case "a" where !flags.contains(.shift): selectAll(nil)
    case "c" where !flags.contains(.shift): copy(nil)
    case "x" where !flags.contains(.shift): cut(nil)
    case "v" where !flags.contains(.shift): pasteAsPlainText(nil)
    case "z":
      if flags.contains(.shift) { undoManager?.redo() } else { undoManager?.undo() }
    default: return super.performKeyEquivalent(with: event)
    }
    return true
  }
}

struct NoteEditorView: View {
  let initialText: String
  let onSave: (String) -> Void
  let onCancel: () -> Void

  @ObservedObject private var localization = Localization.shared
  @State private var draft: String
  @State private var showPreview = false
  @State private var focusToken = 0

  init(initialText: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
    self.initialText = initialText
    self.onSave = onSave
    self.onCancel = onCancel
    _draft = State(initialValue: initialText)
  }

  private var canSave: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Image(systemName: "square.and.pencil").foregroundStyle(.secondary)
        Text(tr("Edit note", "编辑笔记")).font(.system(size: 14, weight: .semibold))
        Spacer()
        Picker(tr("View", "视图"), selection: $showPreview) {
          Text(tr("Edit", "编辑")).tag(false)
          Text(tr("Preview", "预览")).tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 160)
      }
      .padding(16)

      Divider()

      if showPreview {
        ScrollView {
          if draft.isEmpty {
            Text(tr("Nothing to preview yet.", "还没有可预览的内容。"))
              .foregroundStyle(.tertiary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(20)
          } else {
            MarkdownNoteText(text: draft)
              .font(.system(size: 14))
              .textSelection(.enabled)
              .padding(20)
          }
        }
      } else {
        PlainTextEditor(
          text: $draft,
          placeholder: tr("Write a note. Markdown is supported.", "写下笔记，支持 Markdown。"),
          fontSize: 14,
          onSubmit: save,
          onCancel: onCancel,
          focusToken: focusToken,
          submitOnReturn: false
        )
        .padding(10)
      }

      Divider()

      HStack(spacing: 12) {
        Text(tr("\(draft.count) characters", "\(draft.count) 字"))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
        Spacer()
        Button(tr("Cancel", "取消"), action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button(tr("Save", "保存"), action: save)
          .keyboardShortcut(.return, modifiers: .command)
          .buttonStyle(.borderedProminent)
          .tint(Color(red: 0.64, green: 0.32, blue: 0.20))
          .disabled(!canSave)
      }
      .padding(14)
    }
    .frame(minWidth: 440, idealWidth: 580, minHeight: 350, idealHeight: 520)
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear { focusToken += 1 }
    .onChange(of: showPreview) { _, preview in
      if !preview { focusToken += 1 }
    }
  }

  private func save() {
    guard canSave else { return }
    onSave(draft)
  }
}
