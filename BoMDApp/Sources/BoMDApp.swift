import AppKit
import SwiftUI

@main
struct BoMDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @FocusedValue(\.appState) private var focusedAppState
    @ObservedObject private var recentFiles = RecentFilesStore.shared
    @ObservedObject private var themeStore = ThemeStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView(shouldHandleStartupArguments: false)
                .onAppear {
                    appDelegate.flushPendingURLsIfPossible()
                }
        }
        .defaultSize(
            width: AppWindowRegistry.launchContentSize.width,
            height: AppWindowRegistry.launchContentSize.height
        )
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开...") {
                    if let url = AppState.selectMarkdownFile() {
                        AppWindowRegistry.shared.openDocumentWindow(fileURL: url)
                    }
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("新窗口") {
                    AppWindowRegistry.shared.openEmptyWindow()
                }
                .keyboardShortcut("n", modifiers: .command)

                Menu("最近打开") {
                    if recentFiles.fileURLs.isEmpty {
                        Text("无最近文件")
                    } else {
                        ForEach(recentFiles.fileURLs, id: \.self) { url in
                            Button(url.lastPathComponent) {
                                openRecentFile(url)
                            }
                        }

                        Divider()
                    }

                    Button("清除最近浏览文件") {
                        recentFiles.clear()
                    }
                    .disabled(recentFiles.fileURLs.isEmpty)
                }
            }

            CommandGroup(after: .newItem) {
                Button("重新加载") {
                    (focusedAppState ?? AppWindowRegistry.shared.activeAppState)?.reloadCurrentFile()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(focusedAppState == nil && AppWindowRegistry.shared.activeAppState == nil)
            }

            CommandMenu("视图") {
                Button("切换原文/渲染模式") {
                    (focusedAppState ?? AppWindowRegistry.shared.activeAppState)?.toggleMode()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(focusedAppState == nil && AppWindowRegistry.shared.activeAppState == nil)

                Divider()
                Toggle("深色外观", isOn: Binding(
                    get: { themeStore.selection == .dark },
                    set: { if $0 { themeStore.selection = .dark } }
                ))
                Toggle("浅色外观", isOn: Binding(
                    get: { themeStore.selection == .light },
                    set: { if $0 { themeStore.selection = .light } }
                ))
            }

            CommandGroup(after: .help) {
                Button("打开日志目录") {
                    AppLogger.shared.revealLogsDirectory()
                }
            }
        }
    }

    private func openRecentFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            recentFiles.remove(url)
            return
        }

        let targetAppState = AppWindowRegistry.shared.appState(for: NSApp.keyWindow)
            ?? AppWindowRegistry.shared.appState(for: NSApp.mainWindow)
            ?? focusedAppState
            ?? AppWindowRegistry.shared.activeAppState
        if let targetAppState, targetAppState.currentFileURL == nil {
            targetAppState.openRecentFile(url)
            return
        }

        AppWindowRegistry.shared.openDocumentWindow(fileURL: url)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingURLs: [URL] = []
    private var shouldCloseLaunchEmptyWindows = false
    private var isHandlingInitialLaunch = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemeStore.shared.applyAppearance()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            defer { self.isHandlingInitialLaunch = false }
            if self.openPendingOrStartupDocumentIfPossible() {
                return
            }

            if !AppWindowRegistry.shared.hasVisibleWindow {
                AppWindowRegistry.shared.openEmptyWindow(usingLaunchSize: true)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingURLs.append(contentsOf: urls)
        flushPendingURLsIfPossible()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "打开",
            action: #selector(openDocumentFromDock),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "新窗口",
            action: #selector(openEmptyWindowFromDock),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "重新加载",
            action: #selector(reloadDocumentFromDock),
            keyEquivalent: ""
        ))
        menu.items.forEach { $0.target = self }
        return menu
    }

    func flushPendingURLsIfPossible() {
        guard NSApp.isRunning,
              !pendingURLs.isEmpty else {
            return
        }

        openPendingOrStartupDocumentIfPossible()
    }

    @objc private func openDocumentFromDock() {
        if let url = AppState.selectMarkdownFile() {
            AppWindowRegistry.shared.openDocumentWindow(fileURL: url)
        }
    }

    @objc private func openEmptyWindowFromDock() {
        AppWindowRegistry.shared.openEmptyWindow()
    }

    @objc private func reloadDocumentFromDock() {
        AppWindowRegistry.shared.activeAppState?.reloadCurrentFile()
    }

    @discardableResult
    private func openPendingOrStartupDocumentIfPossible() -> Bool {
        if let firstURL = pendingURLs.first {
            pendingURLs.removeAll()
            shouldCloseLaunchEmptyWindows = true
            AppWindowRegistry.shared.openDocumentWindow(
                fileURL: firstURL,
                usingLaunchSize: isHandlingInitialLaunch
            )
            scheduleLaunchEmptyWindowCleanup()
            return true
        }

        guard let startupURL = startupDocumentURL() else {
            return false
        }

        shouldCloseLaunchEmptyWindows = true
        AppWindowRegistry.shared.openDocumentWindow(
            fileURL: startupURL,
            usingLaunchSize: isHandlingInitialLaunch
        )
        scheduleLaunchEmptyWindowCleanup()
        return true
    }

    private func scheduleLaunchEmptyWindowCleanup() {
        [0.05, 0.2, 0.5].forEach { delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard self.shouldCloseLaunchEmptyWindows else { return }
                AppWindowRegistry.shared.closeEmptyWindows()
                if delay == 0.5 {
                    self.shouldCloseLaunchEmptyWindows = false
                }
            }
        }
    }

    private func startupDocumentURL() -> URL? {
        CommandLine.arguments.dropFirst().compactMap { argument in
            let url = URL(fileURLWithPath: argument)
            let ext = url.pathExtension.lowercased()
            return (ext == "md" || ext == "markdown") ? url : nil
        }.first
    }
}

final class AppWindowRegistry: NSObject, NSWindowDelegate {
    static let shared = AppWindowRegistry()
    static let minimumContentSize = NSSize(width: 860, height: 640)
    static let newWindowContentSize = NSSize(width: 960, height: 720)
    private static let savedContentWidthKey = "window.lastContentWidth"
    private static let savedContentHeightKey = "window.lastContentHeight"

    static var launchContentSize: NSSize {
        let defaults = UserDefaults.standard
        let savedWidth = defaults.double(forKey: savedContentWidthKey)
        let savedHeight = defaults.double(forKey: savedContentHeightKey)
        let savedSize = NSSize(width: savedWidth, height: savedHeight)

        guard savedSize.width >= minimumContentSize.width,
              savedSize.height >= minimumContentSize.height else {
            return newWindowContentSize
        }

        return constrainedContentSize(savedSize)
    }

    weak var activeAppState: AppState?
    private var ownedWindows: [NSWindow] = []
    private var windowsByAppState: [ObjectIdentifier: WeakWindowBox] = [:]
    private var appStatesByWindow: [ObjectIdentifier: WeakAppStateBox] = [:]
    private var normalizedWindowIDs: Set<ObjectIdentifier> = []

    private override init() { }

    var hasVisibleWindow: Bool {
        NSApp.windows.contains { $0.isVisible }
    }

    var hasOwnedWindow: Bool {
        ownedWindows.contains { $0.isVisible }
    }

    func activate(_ appState: AppState) {
        activeAppState = appState
    }

    func appState(for window: NSWindow?) -> AppState? {
        guard let window else { return nil }
        return appStatesByWindow[ObjectIdentifier(window)]?.appState
    }

    func register(_ appState: AppState, window: NSWindow) {
        let windowID = ObjectIdentifier(window)
        windowsByAppState[ObjectIdentifier(appState)] = WeakWindowBox(window)
        appStatesByWindow[windowID] = WeakAppStateBox(appState)
        window.delegate = self
        var cascadeAnchorWindow: NSWindow?
        if !normalizedWindowIDs.contains(windowID) {
            let isOwnedWindow = ownedWindows.contains(where: { $0 === window })
            if !isOwnedWindow {
                window.setContentSize(Self.launchContentSize)
                cascadeAnchorWindow = visibleWindowForCascade(excluding: window)
            }
            window.contentMinSize = Self.minimumContentSize
            normalizedWindowIDs.insert(windowID)
        }
        if window.isKeyWindow || activeAppState == nil {
            activeAppState = appState
        }
        window.title = appState.windowTitle
        configureWindow(window)
        if let cascadeAnchorWindow {
            position(window, offsetFrom: cascadeAnchorWindow)
            DispatchQueue.main.async { [weak self, weak window, weak cascadeAnchorWindow] in
                guard let self, let window, let cascadeAnchorWindow else { return }
                self.position(window, offsetFrom: cascadeAnchorWindow)
            }
        }
    }

    func openEmptyWindow(usingLaunchSize: Bool? = nil) {
        openWindow(
            initialFileURL: nil,
            usingLaunchSize: usingLaunchSize ?? !hasVisibleWindow
        )
    }

    func openDocumentWindow(fileURL: URL, usingLaunchSize: Bool? = nil) {
        openWindow(
            initialFileURL: fileURL,
            usingLaunchSize: usingLaunchSize ?? !hasVisibleWindow
        )
    }

    private func openWindow(initialFileURL: URL?, usingLaunchSize: Bool) {
        let cascadeAnchorWindow = usingLaunchSize ? nil : visibleWindowForCascade()
        let rootView = ContentView(
            initialFileURL: initialFileURL,
            shouldHandleStartupArguments: false
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = initialFileURL?.lastPathComponent ?? "BoMD"
        window.setContentSize(usingLaunchSize ? Self.launchContentSize : Self.newWindowContentSize)
        window.contentMinSize = Self.minimumContentSize
        configureWindow(window)
        window.delegate = self
        ownedWindows.append(window)
        if let cascadeAnchorWindow {
            position(window, offsetFrom: cascadeAnchorWindow)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let cascadeAnchorWindow {
            DispatchQueue.main.async { [weak self, weak window, weak cascadeAnchorWindow] in
                guard let self, let window, let cascadeAnchorWindow else { return }
                self.position(window, offsetFrom: cascadeAnchorWindow)
            }
        }
    }

    private func visibleWindowForCascade(excluding excludedWindow: NSWindow? = nil) -> NSWindow? {
        let focusedWindows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
        if let focusedWindow = focusedWindows.first(where: {
            $0 !== excludedWindow && isCascadeAnchorWindow($0)
        }) {
            return focusedWindow
        }

        return NSApp.windows.reversed().first(where: {
            $0 !== excludedWindow && isCascadeAnchorWindow($0)
        })
    }

    private func isCascadeAnchorWindow(_ window: NSWindow) -> Bool {
        window.isVisible && !(window is NSPanel)
    }

    private func position(_ window: NSWindow, offsetFrom anchorWindow: NSWindow) {
        let cascadeOffset: CGFloat = 24
        var frame = window.frame
        frame.origin = NSPoint(
            x: anchorWindow.frame.minX + cascadeOffset,
            y: anchorWindow.frame.maxY - cascadeOffset - frame.height
        )

        guard let screen = anchorWindow.screen ?? NSScreen.main else {
            window.setFrame(frame, display: false)
            return
        }

        frame = window.constrainFrameRect(frame, to: screen)
        let landedOnAnchor = abs(frame.minX - anchorWindow.frame.minX) < 1
            && abs(frame.minY - anchorWindow.frame.minY) < 1
        if landedOnAnchor {
            frame.origin = NSPoint(
                x: anchorWindow.frame.minX - cascadeOffset,
                y: anchorWindow.frame.minY + cascadeOffset
            )
            frame = window.constrainFrameRect(frame, to: screen)
        }

        window.setFrame(frame, display: false)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow else { return }
        saveLaunchContentSize(from: closedWindow)
        ownedWindows.removeAll { $0 === closedWindow }
        windowsByAppState = windowsByAppState.filter { $0.value.window !== closedWindow }
        let windowID = ObjectIdentifier(closedWindow)
        appStatesByWindow.removeValue(forKey: windowID)
        normalizedWindowIDs.remove(windowID)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let appState = appStatesByWindow[ObjectIdentifier(window)]?.appState else {
            return
        }

        activeAppState = appState
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        configureWindow(window)
        relayoutContent(in: window)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        configureWindow(window)
        relayoutContent(in: window)
        saveLaunchContentSize(from: window)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        configureFullScreenWindow(window)
        relayoutContent(in: window)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        configureFullScreenWindow(window)
        relayoutContent(in: window)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        configureStandardWindow(window)
        relayoutContent(in: window)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        configureStandardWindow(window)
        relayoutContent(in: window)
    }

    func closeEmptyWindows() {
        for window in NSApp.windows {
            let windowID = ObjectIdentifier(window)
            guard let appState = appStatesByWindow[windowID]?.appState,
                  appState.currentFileURL == nil else {
                continue
            }

            window.close()
        }
    }

    func configureWindow(_ window: NSWindow) {
        let backgroundColor = ThemeStore.shared.selection.background

        if window.styleMask.contains(.fullScreen) {
            configureFullScreenWindow(window)
        } else {
            configureStandardWindow(window)
        }
        window.appearance = ThemeStore.shared.selection.appearance
        if #available(macOS 11.0, *) {
            window.titlebarSeparatorStyle = .automatic
        }
        window.isOpaque = true
        window.contentMinSize = Self.minimumContentSize
        window.backgroundColor = backgroundColor
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = backgroundColor.cgColor
        relayoutContent(in: window)
    }

    private func configureStandardWindow(_ window: NSWindow) {
        window.styleMask.remove(.fullSizeContentView)
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = false
    }

    private func configureFullScreenWindow(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
    }

    private func relayoutContent(in window: NSWindow) {
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentViewController?.view.needsLayout = true
        window.contentViewController?.view.layoutSubtreeIfNeeded()
    }

    private func saveLaunchContentSize(from window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), !window.isZoomed else { return }

        let contentSize = window.contentLayoutRect.size
        guard contentSize.width >= Self.minimumContentSize.width,
              contentSize.height >= Self.minimumContentSize.height else {
            return
        }

        let constrainedSize = Self.constrainedContentSize(contentSize)
        let defaults = UserDefaults.standard
        defaults.set(constrainedSize.width, forKey: Self.savedContentWidthKey)
        defaults.set(constrainedSize.height, forKey: Self.savedContentHeightKey)
    }

    private static func constrainedContentSize(_ size: NSSize) -> NSSize {
        guard let visibleFrame = NSScreen.main?.visibleFrame else {
            return NSSize(
                width: max(minimumContentSize.width, size.width),
                height: max(minimumContentSize.height, size.height)
            )
        }

        let maximumWidth = max(minimumContentSize.width, visibleFrame.width - 80)
        let maximumHeight = max(minimumContentSize.height, visibleFrame.height - 100)
        return NSSize(
            width: min(maximumWidth, max(minimumContentSize.width, size.width)),
            height: min(maximumHeight, max(minimumContentSize.height, size.height))
        )
    }

    func configureActiveWindowIfPossible() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        configureWindow(window)
    }

    func configureWindow(for appState: AppState) {
        guard let window = windowsByAppState[ObjectIdentifier(appState)]?.window else {
            configureActiveWindowIfPossible()
            return
        }

        window.title = appState.windowTitle
        configureWindow(window)
    }
}

private final class WeakWindowBox {
    weak var window: NSWindow?

    init(_ window: NSWindow) {
        self.window = window
    }
}

private final class WeakAppStateBox {
    weak var appState: AppState?

    init(_ appState: AppState) {
        self.appState = appState
    }
}

private struct AppStateFocusedValueKey: FocusedValueKey {
    typealias Value = AppState
}

extension FocusedValues {
    var appState: AppState? {
        get { self[AppStateFocusedValueKey.self] }
        set { self[AppStateFocusedValueKey.self] = newValue }
    }
}
