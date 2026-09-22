import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @ObservedObject private var themeStore = ThemeStore.shared
    @StateObject private var appState: AppState
    @State private var isDropTargeted = false
    private let shouldHandleStartupArguments: Bool

    init(initialFileURL: URL? = nil, shouldHandleStartupArguments: Bool = true) {
        _appState = StateObject(wrappedValue: AppState(initialFileURL: initialFileURL, initialFileMethod: "menu_new_window"))
        self.shouldHandleStartupArguments = shouldHandleStartupArguments && initialFileURL == nil
    }

    var body: some View {
        ZStack {
            Color(nsColor: themeStore.selection.background)
                .ignoresSafeArea()

            if appState.currentFileURL == nil {
                EmptyStateView(isDropTargeted: isDropTargeted)
            } else if appState.mode == .rendered {
                MarkdownWebView(
                    sourceText: appState.sourceText,
                    fileURL: appState.currentFileURL,
                    targetAnchor: appState.pendingRenderedAnchor,
                    renderRevision: appState.renderRevision,
                    theme: themeStore.selection,
                    onViewportAnchor: appState.updateRenderedViewportAnchor,
                    onCaptureHandlerReady: appState.installViewportCaptureHandler,
                    onInitialPositionReady: appState.clearPendingRenderedAnchor,
                    onRenderFailure: appState.reportRenderFailure
                )
                .overlay {
                    if let failure = appState.renderFailure {
                        VStack(spacing: 16) {
                            Text("暂时无法渲染文档").font(.headline)
                            Text(failure).multilineTextAlignment(.center)
                            HStack {
                                Button("重试", action: appState.retryRendering)
                                Button("查看原文", action: appState.toggleMode)
                            }
                        }
                        .padding(40)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: themeStore.selection.background))
                    }
                }
            } else {
                DocumentShellView()
            }
        }
        .background(WindowConfigurationView())
        .frame(
            minWidth: AppWindowRegistry.minimumContentSize.width,
            minHeight: AppWindowRegistry.minimumContentSize.height
        )
        .navigationTitle(appState.windowTitle)
        .environmentObject(appState)
        .focusedSceneValue(\.appState, appState)
        .onAppear {
            AppWindowRegistry.shared.activate(appState)
            AppWindowRegistry.shared.configureWindow(for: appState)
            if shouldHandleStartupArguments {
                appState.handleStartupArgumentsIfNeeded()
            }
        }
        .onChange(of: appState.currentFileURL) { _, _ in
            AppWindowRegistry.shared.configureWindow(for: appState)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                AppWindowRegistry.shared.configureWindow(for: appState)
            }
        }
        .onChange(of: themeStore.selection) { _, _ in
            AppWindowRegistry.shared.configureWindow(for: appState)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .alert("BoMD", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }

            DispatchQueue.main.async {
                appState.openFile(url, method: "drag")
            }
        }

        return true
    }
}

private struct WindowConfigurationView: NSViewRepresentable {
    @EnvironmentObject private var appState: AppState

    func makeNSView(context: Context) -> WindowRegistrationView {
        let view = WindowRegistrationView()
        view.update(appState: appState)
        return view
    }

    func updateNSView(_ nsView: WindowRegistrationView, context: Context) {
        nsView.update(appState: appState)
    }
}

private final class WindowRegistrationView: NSView {
    private weak var appState: AppState?

    func update(appState: AppState) {
        self.appState = appState
        registerWindowIfPossible()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWindowIfPossible()
    }

    private func registerWindowIfPossible() {
        guard let appState, let window else { return }
        AppWindowRegistry.shared.register(appState, window: window)
    }
}

private struct EmptyStateView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var themeStore = ThemeStore.shared
    let isDropTargeted: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("BoMD")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(themeStore.selection == .dark ? Color.white.opacity(0.9) : Color.primary)

            Text("拖入 Markdown 文件到此处")
                .font(.system(size: 18))
                .foregroundStyle(themeStore.selection == .dark ? Color.white.opacity(0.62) : Color.secondary)

            Text("或")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(themeStore.selection == .dark ? Color.white.opacity(0.38) : Color.secondary.opacity(0.8))

            Button {
                appState.openFilePanel()
            } label: {
                Text("打开文件")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 96, height: 40)
            }
            .buttonStyle(EmptyStateButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(isDropTargeted ? (themeStore.selection == .dark ? Color.white.opacity(0.42) : Color.accentColor.opacity(0.5)) : .clear, lineWidth: 2)
                .padding(28)
        }
    }
}

private struct EmptyStateButtonStyle: ButtonStyle {
    @ObservedObject private var themeStore = ThemeStore.shared
    func makeBody(configuration: Configuration) -> some View {
        let ink = themeStore.selection == .dark ? Color.white : Color(nsColor: .labelColor)
        return configuration.label
            .foregroundStyle(ink.opacity(configuration.isPressed ? 0.95 : 0.82))
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(ink.opacity(configuration.isPressed ? 0.16 : 0.08))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(ink.opacity(configuration.isPressed ? 0.24 : 0.14), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct DocumentShellView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var themeStore = ThemeStore.shared

    var body: some View {
        SourceTextEditor(
            sourceText: appState.sourceText,
            theme: themeStore.selection,
            targetAnchor: appState.pendingSourceAnchor,
            onViewportAnchor: appState.updateSourceViewportAnchor,
            onCaptureHandlerReady: appState.installViewportCaptureHandler,
            onInitialPositionReady: { appState.pendingSourceAnchor = nil }
        )
    }
}

private struct SourceTextEditor: NSViewRepresentable {
    let sourceText: String
    let theme: AppTheme
    let targetAnchor: ViewportAnchor?
    let onViewportAnchor: (ViewportAnchor) -> Void
    let onCaptureHandlerReady: (@escaping ViewportCaptureHandler) -> Void
    let onInitialPositionReady: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onViewportAnchor: onViewportAnchor,
            onCaptureHandlerReady: onCaptureHandlerReady,
            onInitialPositionReady: onInitialPositionReady
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let backgroundColor = theme.background
        let textView = SourceTextView(frame: NSRect(x: 0, y: 0, width: 860, height: 640))
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.drawsBackground = true
        textView.backgroundColor = backgroundColor
        textView.textColor = theme.text
        textView.lineNumberColor = theme.lineNumber
        textView.selectedTextAttributes = [.backgroundColor: theme.selection]
        textView.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.textContainerInset = NSSize(width: 72, height: 56)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.appearance = theme.appearance
        scrollView.documentView = textView
        scrollView.drawsBackground = true
        scrollView.backgroundColor = backgroundColor
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.contentView.postsBoundsChangedNotifications = true

        context.coordinator.configure(scrollView: scrollView, textView: textView)
        context.coordinator.update(
            sourceText: sourceText,
            targetAnchor: targetAnchor,
            onViewportAnchor: onViewportAnchor,
            onInitialPositionReady: onInitialPositionReady
        )

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        scrollView.appearance = theme.appearance
        scrollView.backgroundColor = theme.background
        scrollView.contentView.backgroundColor = theme.background
        if let textView = scrollView.documentView as? SourceTextView {
            textView.backgroundColor = theme.background
            textView.textColor = theme.text
            textView.lineNumberColor = theme.lineNumber
            textView.selectedTextAttributes = [.backgroundColor: theme.selection]
            textView.needsDisplay = true
        }
        context.coordinator.update(
            sourceText: sourceText,
            targetAnchor: targetAnchor,
            onViewportAnchor: onViewportAnchor,
            onInitialPositionReady: onInitialPositionReady
        )
    }

    final class Coordinator: NSObject {
        private weak var scrollView: NSScrollView?
        private weak var textView: SourceTextView?
        private var boundsObserver: NSObjectProtocol?
        private var renderedSourceText = ""
        private var lastScrolledAnchor: ViewportAnchor?
        private var onViewportAnchor: (ViewportAnchor) -> Void
        private let onCaptureHandlerReady: (@escaping ViewportCaptureHandler) -> Void
        private var onInitialPositionReady: () -> Void

        init(
            onViewportAnchor: @escaping (ViewportAnchor) -> Void,
            onCaptureHandlerReady: @escaping (@escaping ViewportCaptureHandler) -> Void,
            onInitialPositionReady: @escaping () -> Void
        ) {
            self.onViewportAnchor = onViewportAnchor
            self.onCaptureHandlerReady = onCaptureHandlerReady
            self.onInitialPositionReady = onInitialPositionReady
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }

        func configure(scrollView: NSScrollView, textView: SourceTextView) {
            self.scrollView = scrollView
            self.textView = textView
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.reportViewportAnchor()
            }
            onCaptureHandlerReady { [weak self] completion in
                completion(self?.captureViewportAnchor())
            }
        }

        func update(
            sourceText: String,
            targetAnchor: ViewportAnchor?,
            onViewportAnchor: @escaping (ViewportAnchor) -> Void,
            onInitialPositionReady: @escaping () -> Void
        ) {
            self.onViewportAnchor = onViewportAnchor
            self.onInitialPositionReady = onInitialPositionReady

            if renderedSourceText != sourceText {
                renderedSourceText = sourceText
                textView?.lineIndex = SourceLineIndex(sourceText)
                textView?.string = sourceText
                textView?.needsDisplay = true
                lastScrolledAnchor = nil
            }

            guard let targetAnchor else {
                lastScrolledAnchor = nil
                reportViewportAnchor()
                return
            }
            guard lastScrolledAnchor != targetAnchor else { return }

            lastScrolledAnchor = targetAnchor
            scrollToAnchor(targetAnchor)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scrollToAnchor(targetAnchor)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.scrollToAnchor(targetAnchor)
                    self.reportViewportAnchor()
                    self.onInitialPositionReady()
                }
            }
        }

        private func scrollToAnchor(_ anchor: ViewportAnchor) {
            guard let scrollView,
                  let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                return
            }

            let source = textView.string as NSString
            guard source.length > 0 else { return }

            let lineOffset = textView.lineIndex.characterOffset(for: anchor.sourceLine)
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: source.length))
            let characterRange = NSRange(location: min(lineOffset, source.length - 1), length: 1)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
            let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let desiredViewportY = scrollView.contentView.bounds.height * anchor.viewportRatio
            let laidOutHeight = layoutManager.usedRect(for: textContainer).maxY
                + textView.textContainerOrigin.y
                + textView.textContainerInset.height
            let documentHeight = max(textView.bounds.height, laidOutHeight)
            let minimumClipY = textView.frame.minY
            let maximumClipY = max(
                minimumClipY,
                minimumClipY + documentHeight - scrollView.contentView.bounds.height
            )
            let targetDocumentY = max(
                0,
                glyphRect.minY + textView.textContainerOrigin.y - desiredViewportY
            )
            let y = min(max(minimumClipY + targetDocumentY, minimumClipY), maximumClipY)

            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func reportViewportAnchor() {
            guard let anchor = captureViewportAnchor() else { return }
            onViewportAnchor(anchor)
        }

        private func captureViewportAnchor() -> ViewportAnchor? {
            guard let textView else {
                return nil
            }

            let visibleRect = textView.visibleRect
            let entries = visibleLineEntries()
                .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !entries.isEmpty, visibleRect.height > 0 else { return nil }

            let middleY = visibleRect.midY
            let headings = entries.filter { textView.lineIndex.isHeadingLine($0.line) }

            if let upperHeading = headings
                .filter({ $0.rect.midY <= middleY })
                .min(by: { $0.rect.minY < $1.rect.minY }) {
                return ViewportAnchor(sourceLine: upperHeading.line, viewportRatio: 0.02, kind: "heading")
            }

            if let lowerHeading = headings
                .filter({ $0.rect.midY > middleY })
                .min(by: { $0.rect.minY < $1.rect.minY }) {
                return ViewportAnchor(sourceLine: lowerHeading.line, viewportRatio: 0.5, kind: "heading")
            }

            let referenceY = visibleRect.minY + visibleRect.height * 0.38
            guard let content = entries.min(by: {
                distance(from: $0.rect, to: referenceY) < distance(from: $1.rect, to: referenceY)
            }) else {
                return nil
            }

            return ViewportAnchor(
                sourceLine: content.line,
                viewportRatio: 0.38,
                kind: textView.lineIndex.anchorKind(for: content.line)
            )
        }

        private struct VisibleLineEntry {
            let line: Int
            let rect: NSRect
            let text: String
        }

        private func visibleLineEntries() -> [VisibleLineEntry] {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  layoutManager.numberOfGlyphs > 0 else {
                return []
            }

            let visibleRect = textView.visibleRect
            let containerOrigin = textView.textContainerOrigin
            let containerVisibleRect = visibleRect.offsetBy(dx: -containerOrigin.x, dy: -containerOrigin.y)
            let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: containerVisibleRect, in: textContainer)
            let visibleCharacterRange = layoutManager.characterRange(
                forGlyphRange: visibleGlyphRange,
                actualGlyphRange: nil
            )
            let source = textView.string as NSString
            let firstLineRange = source.lineRange(for: NSRange(location: visibleCharacterRange.location, length: 0))
            var lineNumber = textView.lineIndex.lineNumber(atUTF16Offset: firstLineRange.location)
            var lineRange = firstLineRange
            var entries: [VisibleLineEntry] = []
            let visibleCharacterEnd = NSMaxRange(visibleCharacterRange)

            while lineRange.location <= visibleCharacterEnd, lineRange.location < source.length {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
                var lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                lineRect = lineRect.offsetBy(dx: containerOrigin.x, dy: containerOrigin.y)

                if lineRect.maxY > visibleRect.minY && lineRect.minY < visibleRect.maxY {
                    entries.append(VisibleLineEntry(
                        line: lineNumber,
                        rect: lineRect,
                        text: source.substring(with: lineRange)
                    ))
                }

                let nextLocation = NSMaxRange(lineRange)
                guard nextLocation > lineRange.location, nextLocation < source.length else { break }
                lineRange = source.lineRange(for: NSRange(location: nextLocation, length: 0))
                lineNumber += 1
            }

            return entries
        }

        private func distance(from rect: NSRect, to y: CGFloat) -> CGFloat {
            if rect.minY <= y, rect.maxY >= y {
                return 0
            }
            return min(abs(rect.minY - y), abs(rect.maxY - y))
        }

    }
}

private final class SourceTextView: NSTextView {
    var lineNumberColor = NSColor.white.withAlphaComponent(0.28)
    var lineIndex = SourceLineIndex("")

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let layoutManager,
              let textContainer,
              layoutManager.numberOfGlyphs > 0 else {
            return
        }

        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let source = string as NSString
        var glyphIndex = glyphRange.location

        while glyphIndex < NSMaxRange(glyphRange) {
            var lineRange = NSRange()
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

            if characterIndex == 0 || (characterIndex > 0 && source.character(at: characterIndex - 1) == 10) {
                let lineNumber = lineIndex.lineNumber(atUTF16Offset: characterIndex)
                let numberRect = NSRect(
                    x: 12,
                    y: lineRect.minY + textContainerOrigin.y,
                    width: 48,
                    height: lineRect.height
                )
                ("\(lineNumber)" as NSString).draw(
                    in: numberRect,
                    withAttributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                        .foregroundColor: lineNumberColor,
                        .paragraphStyle: SourceTextView.lineNumberParagraphStyle
                    ]
                )
            }

            glyphIndex = NSMaxRange(lineRange)
        }
    }

    private static let lineNumberParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        return style
    }()
}
