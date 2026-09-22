import AppKit
import Foundation

enum ViewMode: String {
    case rendered = "渲染模式"
    case source = "原文模式"
}

struct ViewportAnchor: Equatable {
    let sourceLine: Int
    let viewportRatio: Double
    let kind: String

    init(sourceLine: Int, viewportRatio: Double, kind: String) {
        self.sourceLine = max(1, sourceLine)
        self.viewportRatio = min(max(viewportRatio, 0), 1)
        self.kind = kind
    }
}

typealias ViewportCaptureHandler = (@escaping (ViewportAnchor?) -> Void) -> Void

final class AppState: ObservableObject {
    @Published var currentFileURL: URL?
    @Published var sourceText: String = ""
    @Published var mode: ViewMode = .rendered
    @Published var errorMessage: String?
    @Published var renderFailure: String?
    @Published private(set) var renderRevision = 0
    @Published var pendingSourceAnchor: ViewportAnchor?
    @Published var pendingRenderedAnchor: ViewportAnchor?
    private var renderedViewportAnchor: ViewportAnchor?
    private var sourceViewportAnchor: ViewportAnchor?
    private var viewportCaptureHandler: ViewportCaptureHandler?
    private var pendingModeToggleID: UUID?
    private var fileOpenPanel: NSOpenPanel?
    private static var didConsumeStartupArguments = false

    var windowTitle: String {
        guard let currentFileURL else { return "BoMD" }
        return currentFileURL.lastPathComponent
    }

    var currentFileName: String {
        currentFileURL?.lastPathComponent ?? "BoMD"
    }

    init(initialFileURL: URL? = nil, initialFileMethod: String = "window") {
        AppLogger.shared.log("app_launch", metadata: [
            "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")
        ])

        if let initialFileURL {
            openFile(initialFileURL, method: initialFileMethod)
        }
    }

    func handleStartupArgumentsIfNeeded() {
        guard !Self.didConsumeStartupArguments else { return }
        Self.didConsumeStartupArguments = true

        guard let argumentPath = CommandLine.arguments.dropFirst().first(where: { argument in
            let ext = URL(fileURLWithPath: argument).pathExtension.lowercased()
            return ext == "md" || ext == "markdown"
        }) else {
            return
        }

        openFile(URL(fileURLWithPath: argumentPath), method: "argument")
    }

    func openFilePanel() {
        guard fileOpenPanel == nil else { return }

        let panel = Self.makeMarkdownFilePanel()
        fileOpenPanel = panel

        guard let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow else {
            let response = panel.runModal()
            fileOpenPanel = nil
            if response == .OK, let url = panel.url {
                openFile(url, method: "empty_state")
            }
            return
        }

        panel.beginSheetModal(for: parentWindow) { [weak self, weak panel] response in
            guard let self, let panel, self.fileOpenPanel === panel else { return }
            self.fileOpenPanel = nil
            if response == .OK, let url = panel.url {
                self.openFile(url, method: "empty_state")
            }
        }
    }

    static func selectMarkdownFile() -> URL? {
        let panel = makeMarkdownFilePanel()

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func openRecentFile(_ url: URL) {
        dismissFileOpenPanel()
        openFile(url, method: "recent")
    }

    private static func makeMarkdownFilePanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!, .init(filenameExtension: "markdown")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel
    }

    private func dismissFileOpenPanel() {
        guard let panel = fileOpenPanel else { return }
        fileOpenPanel = nil

        if let parentWindow = panel.sheetParent {
            parentWindow.endSheet(panel, returnCode: .cancel)
        } else {
            panel.orderOut(nil)
        }
    }

    func openFile(_ url: URL, method: String = "unknown") {
        let start = Date()
        guard isSupportedMarkdownFile(url) else {
            errorMessage = "仅支持 .md 和 .markdown 文件。"
            AppLogger.shared.log("file_open_failure", metadata: [
                "path": .string(url.path),
                "reason": .string("unsupported_extension"),
                "method": .string(method)
            ])
            return
        }

        do {
            sourceText = try String(contentsOf: url, encoding: .utf8)
            currentFileURL = url
            mode = .rendered
            pendingSourceAnchor = nil
            pendingRenderedAnchor = nil
            renderedViewportAnchor = nil
            sourceViewportAnchor = nil
            pendingModeToggleID = nil
            errorMessage = nil
            retryRendering()
            RecentFilesStore.shared.record(url)
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            AppLogger.shared.log("file_open_success", metadata: [
                "path": .string(url.path),
                "extension": .string(url.pathExtension.lowercased()),
                "size": .int(fileSize),
                "method": .string(method),
                "duration_ms": .int(Self.elapsedMilliseconds(since: start))
            ])
        } catch {
            errorMessage = "文件读取失败：\(error.localizedDescription)"
            AppLogger.shared.log("file_open_failure", metadata: [
                "path": .string(url.path),
                "reason": .string(error.localizedDescription),
                "method": .string(method),
                "duration_ms": .int(Self.elapsedMilliseconds(since: start))
            ])
        }
    }

    func reloadCurrentFile() {
        let start = Date()
        guard let currentFileURL else {
            errorMessage = "当前没有打开的文件。"
            AppLogger.shared.log("reload_failure", metadata: [
                "reason": .string("no_current_file")
            ])
            return
        }

        do {
            sourceText = try String(contentsOf: currentFileURL, encoding: .utf8)
            errorMessage = nil
            retryRendering()
            AppLogger.shared.log("reload_success", metadata: [
                "path": .string(currentFileURL.path),
                "duration_ms": .int(Self.elapsedMilliseconds(since: start))
            ])
        } catch {
            errorMessage = "重新加载失败：\(error.localizedDescription)"
            AppLogger.shared.log("reload_failure", metadata: [
                "path": .string(currentFileURL.path),
                "reason": .string(error.localizedDescription),
                "duration_ms": .int(Self.elapsedMilliseconds(since: start))
            ])
        }
    }

    func retryRendering() {
        renderFailure = nil
        renderRevision &+= 1
    }

    func reportRenderFailure(_ message: String) {
        renderFailure = message
    }

    func toggleMode() {
        guard pendingModeToggleID == nil,
              pendingSourceAnchor == nil,
              pendingRenderedAnchor == nil else {
            return
        }

        let toggleID = UUID()
        pendingModeToggleID = toggleID
        let fallbackAnchor = mode == .rendered ? renderedViewportAnchor : sourceViewportAnchor

        guard let viewportCaptureHandler else {
            completeModeToggle(id: toggleID, anchor: fallbackAnchor)
            return
        }

        viewportCaptureHandler { [weak self] anchor in
            DispatchQueue.main.async {
                self?.completeModeToggle(id: toggleID, anchor: anchor ?? fallbackAnchor)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.completeModeToggle(id: toggleID, anchor: fallbackAnchor)
        }
    }

    func installViewportCaptureHandler(_ handler: @escaping ViewportCaptureHandler) {
        viewportCaptureHandler = handler
    }

    func updateRenderedViewportAnchor(_ anchor: ViewportAnchor) {
        renderedViewportAnchor = anchor
    }

    func updateSourceViewportAnchor(_ anchor: ViewportAnchor) {
        sourceViewportAnchor = anchor
    }

    func clearPendingRenderedAnchor() {
        pendingRenderedAnchor = nil
    }

    private func completeModeToggle(id: UUID, anchor: ViewportAnchor?) {
        guard pendingModeToggleID == id else { return }
        pendingModeToggleID = nil

        let previousMode = mode
        renderFailure = nil
        if previousMode == .rendered {
            pendingSourceAnchor = anchor
            pendingRenderedAnchor = nil
            sourceViewportAnchor = anchor
        } else {
            pendingSourceAnchor = nil
            pendingRenderedAnchor = anchor
            renderedViewportAnchor = anchor
        }
        mode = previousMode == .rendered ? .source : .rendered
        AppLogger.shared.log("mode_toggle", metadata: [
            "path": .string(currentFileURL?.path ?? ""),
            "from": .string(previousMode.rawValue),
            "to": .string(mode.rawValue),
            "anchor_line": .int(anchor?.sourceLine ?? 0),
            "anchor_ratio": .double(anchor?.viewportRatio ?? 0),
            "anchor_kind": .string(anchor?.kind ?? "none")
        ])
    }

    func revealLogsDirectory() {
        AppLogger.shared.revealLogsDirectory()
    }

    private func isSupportedMarkdownFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    private func sourceModuleStartLine(containing line: Int) -> Int {
        let lines = sourceLines
        guard !lines.isEmpty else { return max(1, line) }
        let clampedLine = min(max(1, line), lines.count)

        if let fence = enclosingFenceLine(for: clampedLine, in: lines) {
            return headingImmediatelyBefore(line: fence, in: lines) ?? fence
        }

        if isHeadingLine(clampedLine) {
            return clampedLine
        }

        var current = clampedLine
        while current > 1 {
            let previous = sourceLine(current - 1).trimmingCharacters(in: .whitespacesAndNewlines)
            if previous.isEmpty || isHeadingLine(current - 1) || isFenceOpeningLine(current - 1) {
                break
            }
            current -= 1
        }

        return current
    }

    private var sourceLines: [String] {
        sourceText.components(separatedBy: "\n").map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
    }

    private func sourceLine(_ line: Int) -> String {
        let index = line - 1
        guard sourceLines.indices.contains(index) else { return "" }
        return sourceLines[index]
    }

    private func isHeadingLine(_ line: Int) -> Bool {
        sourceLine(line).range(of: #"^ {0,3}#{1,6}\s+\S"#, options: .regularExpression) != nil
    }

    private func isFenceOpeningLine(_ line: Int) -> Bool {
        sourceLine(line).range(of: #"^ {0,3}(```|~~~)"#, options: .regularExpression) != nil
    }

    private func isModuleHeadLine(_ line: Int) -> Bool {
        let text = sourceLine(line).trimmingCharacters(in: .whitespaces)
        return isHeadingLine(line)
            || isFenceOpeningLine(line)
            || text.range(of: #"^([-*_]\s*){3,}$"#, options: .regularExpression) != nil
            || text.range(of: #"^ {0,3}([-+*]|\d+[.)])\s+\S"#, options: .regularExpression) != nil
            || text.range(of: #"^ {0,3}>\s*\S"#, options: .regularExpression) != nil
            || text.contains("|")
    }

    private func previousModuleStartLine(before line: Int) -> Int? {
        guard line > 1 else { return nil }

        var current = line - 1
        while current >= 1 {
            if isModuleHeadLine(current) {
                return sourceModuleStartLine(containing: current)
            }
            current -= 1
        }

        return nil
    }

    private func enclosingFenceLine(for line: Int, in lines: [String]) -> Int? {
        var openingLine: Int?
        var openingMarker = ""

        for currentLine in 1...line {
            let text = lines[currentLine - 1]
            guard let match = text.range(of: #"^ {0,3}(```|~~~)"#, options: .regularExpression) else {
                continue
            }

            let marker = String(text[match].trimmingCharacters(in: .whitespaces).prefix(3))
            if openingLine == nil {
                openingLine = currentLine
                openingMarker = marker
            } else if marker == openingMarker {
                openingLine = nil
                openingMarker = ""
            }
        }

        return openingLine
    }

    private func headingImmediatelyBefore(line: Int, in lines: [String]) -> Int? {
        var current = line - 1
        while current >= 1 {
            let text = lines[current - 1].trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                current -= 1
                continue
            }
            return isHeadingLine(current) ? current : nil
        }
        return nil
    }

    private static func elapsedMilliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}
