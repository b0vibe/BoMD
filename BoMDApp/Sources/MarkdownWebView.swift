import AppKit
import SwiftUI
import WebKit

struct MarkdownWebView: NSViewRepresentable {
    let sourceText: String
    let fileURL: URL?
    let targetAnchor: ViewportAnchor?
    let renderRevision: Int
    let theme: AppTheme
    let onViewportAnchor: (ViewportAnchor) -> Void
    let onCaptureHandlerReady: (@escaping ViewportCaptureHandler) -> Void
    let onInitialPositionReady: () -> Void
    let onRenderFailure: (String) -> Void
    private var backgroundColor: NSColor { theme.background }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            baseDirectory: fileURL?.deletingLastPathComponent(),
            onViewportAnchor: onViewportAnchor,
            onCaptureHandlerReady: onCaptureHandlerReady,
            onInitialPositionReady: onInitialPositionReady,
            onRenderFailure: onRenderFailure
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "bomd")
        configuration.setURLSchemeHandler(context.coordinator.localFileSchemeHandler, forURLScheme: "bomd-local")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.appearance = theme.appearance
        webView.navigationDelegate = context.coordinator
        webView.wantsLayer = true
        webView.layer?.backgroundColor = backgroundColor.cgColor
        webView.alphaValue = targetAnchor == nil ? 1 : 0
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 11.0, *) {
            webView.underPageBackgroundColor = backgroundColor
        }
        DispatchQueue.main.async {
            configureDescendantBackgrounds(in: webView)
        }

        context.coordinator.webView = webView
        context.coordinator.update(payload: payload, anchor: targetAnchor, revision: renderRevision)
        context.coordinator.registerCaptureHandler()
        context.coordinator.loadRenderer()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.appearance = theme.appearance
        webView.underPageBackgroundColor = backgroundColor
        webView.layer?.backgroundColor = backgroundColor.cgColor
        configureDescendantBackgrounds(in: webView)
        context.coordinator.localFileSchemeHandler.updateBaseDirectory(fileURL?.deletingLastPathComponent())
        context.coordinator.update(payload: payload, anchor: targetAnchor, revision: renderRevision)
        context.coordinator.registerCaptureHandler()
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.invalidate()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "bomd")
        webView.stopLoading()
    }

    private func configureDescendantBackgrounds(in view: NSView) {
        if let scrollView = view as? NSScrollView {
            scrollView.drawsBackground = true
            scrollView.backgroundColor = backgroundColor
            scrollView.contentView.backgroundColor = backgroundColor
        }

        view.subviews.forEach { configureDescendantBackgrounds(in: $0) }
    }

    private var payload: [String: String] {
        [
            "source": sourceText,
            "fileName": fileURL?.lastPathComponent ?? "BoMD",
            "basePath": fileURL?.deletingLastPathComponent().path ?? "",
            "targetSourceLine": targetAnchor.map { String($0.sourceLine) } ?? "",
            "targetViewportRatio": targetAnchor.map { String($0.viewportRatio) } ?? ""
        ]
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let localFileSchemeHandler: LocalFileSchemeHandler
        private let onViewportAnchor: (ViewportAnchor) -> Void
        private let onCaptureHandlerReady: (@escaping ViewportCaptureHandler) -> Void
        private let onInitialPositionReady: () -> Void
        private let onRenderFailure: (String) -> Void
        private let rendererURL: URL?
        private let timeoutInterval: TimeInterval
        private let logger: AppLogger.Logger
        weak var webView: WKWebView?
        var pendingPayload: [String: String] = [:]
        var targetAnchor: ViewportAnchor?
        private var isReady = false
        private var lastRenderedContentPayload: String?
        private var lastRenderedTargetAnchor: ViewportAnchor?
        private var revision = 0
        private var lastRenderedRevision: Int?
        private var hasFailed = false
        private var isActive = true
        private var generation = UUID()
        private var activeRequest: UUID?
        private var timeout: DispatchWorkItem?
        private var rendererNavigation: WKNavigation?

        init(
            baseDirectory: URL?,
            onViewportAnchor: @escaping (ViewportAnchor) -> Void,
            onCaptureHandlerReady: @escaping (@escaping ViewportCaptureHandler) -> Void,
            onInitialPositionReady: @escaping () -> Void,
            onRenderFailure: @escaping (String) -> Void,
            rendererURL: URL? = Bundle.main.url(forResource: "renderer", withExtension: "html"),
            timeoutInterval: TimeInterval = 15,
            logger: AppLogger.Logger = AppLogger.shared
        ) {
            localFileSchemeHandler = LocalFileSchemeHandler(baseDirectory: baseDirectory)
            self.onViewportAnchor = onViewportAnchor
            self.onCaptureHandlerReady = onCaptureHandlerReady
            self.onInitialPositionReady = onInitialPositionReady
            self.onRenderFailure = onRenderFailure
            self.rendererURL = rendererURL
            self.timeoutInterval = timeoutInterval
            self.logger = logger
        }

        func update(payload: [String: String], anchor: ViewportAnchor?, revision: Int) {
            let explicitRetry = self.revision != revision
            pendingPayload = payload
            targetAnchor = anchor
            self.revision = revision
            guard isActive else { return }
            if hasFailed {
                // Failure is latched: SwiftUI updates must not cause retry loops.
                if explicitRetry { loadRenderer() }
                return
            }
            renderIfReady()
        }

        func loadRenderer() {
            guard isActive, let webView else { return }
            rendererNavigation = nil
            webView.stopLoading()
            isReady = false
            hasFailed = false
            lastRenderedContentPayload = nil
            lastRenderedTargetAnchor = nil
            lastRenderedRevision = nil
            let request = beginRequest()
            guard let rendererURL, FileManager.default.fileExists(atPath: rendererURL.path) else {
                fail(request, reason: "renderer_html_missing")
                return
            }
            rendererNavigation = webView.loadFileURL(rendererURL, allowingReadAccessTo: rendererURL.deletingLastPathComponent())
        }

        private func beginRequest() -> UUID {
            timeout?.cancel()
            generation = UUID()
            let request = generation
            activeRequest = request
            let work = DispatchWorkItem { [weak self] in
                self?.fail(request, reason: "render_timeout")
            }
            timeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutInterval, execute: work)
            return request
        }

        func invalidate() {
            isActive = false
            generation = UUID()
            activeRequest = nil
            timeout?.cancel()
            timeout = nil
        }

        private func fail(_ request: UUID, reason: String, error: Error? = nil) {
            guard isActive, activeRequest == request else { return }
            activeRequest = nil
            timeout?.cancel()
            timeout = nil
            hasFailed = true
            isReady = false
            rendererNavigation = nil
            webView?.stopLoading()
            webView?.alphaValue = 1
            targetAnchor = nil
            logger.log("render_failure", metadata: [
                "reason": .string(reason),
                "error": .string(error?.localizedDescription ?? "")
            ])
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive, self.generation == request, self.hasFailed else { return }
                self.onInitialPositionReady()
                self.onRenderFailure(reason == "render_timeout"
                    ? "渲染超时。可以重试或查看原文，文件内容未被修改。"
                    : "渲染未能完成。可以重试或查看原文，文件内容未被修改。")
            }
        }

        private func finish(_ request: UUID) {
            guard isActive, activeRequest == request else { return }
            activeRequest = nil
            timeout?.cancel()
            timeout = nil
            webView?.alphaValue = 1
            targetAnchor = nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive, self.generation == request, !self.hasFailed else { return }
                self.onInitialPositionReady()
            }
        }

        func registerCaptureHandler() {
            onCaptureHandlerReady { [weak self] completion in
                self?.captureViewportAnchor(completion: completion) ?? completion(nil)
            }
        }

        private func captureViewportAnchor(completion: @escaping (ViewportAnchor?) -> Void) {
            guard let webView else {
                completion(nil)
                return
            }

            webView.evaluateJavaScript("window.BoMDCaptureViewportAnchor?.()") { result, _ in
                completion(Self.viewportAnchor(from: result))
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard isActive, !hasFailed, let navigation, navigation === rendererNavigation else { return }
            timeout?.cancel()
            activeRequest = nil
            [0.0, 0.1, 0.5].forEach { delay in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.hideNativeScrollers(around: webView)
                }
            }
            isReady = true
            renderIfReady()
        }

        private func hideNativeScrollers(around webView: WKWebView) {
            var root: NSView = webView

            while let superview = root.superview {
                root = superview
            }

            hideNativeScrollers(in: root)
        }

        private func hideNativeScrollers(in view: NSView) {
            if let scrollView = view as? NSScrollView {
                scrollView.scrollerStyle = .overlay
                scrollView.autohidesScrollers = true
                scrollView.hasHorizontalScroller = false
                scrollView.hasVerticalScroller = false
                scrollView.horizontalScroller?.isHidden = true
                scrollView.verticalScroller?.isHidden = true
            }

            view.subviews.forEach { hideNativeScrollers(in: $0) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url,
                  shouldOpenInDefaultBrowser(url) else {
                decisionHandler(.allow)
                return
            }

            NSWorkspace.shared.open(url)
            logger.log("external_link_open", metadata: [
                "url": .string(url.absoluteString)
            ])
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard let navigation, navigation === rendererNavigation, let request = activeRequest else { return }
            fail(request, reason: "navigation_failed", error: error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard let navigation, navigation === rendererNavigation, let request = activeRequest else { return }
            fail(request, reason: "provisional_navigation_failed", error: error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard isActive else { return }
            let request = activeRequest ?? beginRequest()
            fail(request, reason: "web_content_process_terminated")
        }

        private func shouldOpenInDefaultBrowser(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https"
        }

        func renderIfReady() {
            guard isActive, isReady, !hasFailed, let webView else { return }

            do {
                let contentPayload = pendingPayload.filter { key, _ in
                    key != "targetSourceLine" && key != "targetViewportRatio"
                }
                let contentData = try JSONSerialization.data(withJSONObject: contentPayload, options: [.sortedKeys])
                guard let contentJSON = String(data: contentData, encoding: .utf8) else {
                    fail(beginRequest(), reason: "payload_encoding_failed")
                    return
                }

                let contentChanged = contentJSON != lastRenderedContentPayload
                let hasNewTarget = targetAnchor != nil && targetAnchor != lastRenderedTargetAnchor
                guard contentChanged || hasNewTarget || revision != lastRenderedRevision else { return }

                lastRenderedContentPayload = contentJSON
                lastRenderedTargetAnchor = targetAnchor
                lastRenderedRevision = revision
                let request = beginRequest()
                // Await the actual Promise, including asynchronous exceptions.
                // Only this request's completion may reveal/unlock the view.
                webView.callAsyncJavaScript(
                    "await window.BoMDRenderMarkdown(payload); return true;",
                    arguments: ["payload": pendingPayload], in: nil, in: .page
                ) { [weak self] result in
                    switch result {
                    case .success:
                        self?.finish(request)
                    case .failure(let error):
                        self?.fail(request, reason: "javascript_failed", error: error)
                    }
                }
            } catch {
                fail(beginRequest(), reason: "payload_encoding_failed", error: error)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard isActive, message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any],
                  let event = body["event"] as? String else {
                return
            }

            if event == "code_copy_request" {
                handleCodeCopyRequest(body)
                return
            }

            if event == "source_line_focus" {
                handleSourceLineFocus(body)
                return
            }

            if event == "render_position_ready" {
                // Native Promise completion owns the lifecycle. A delayed
                // message from a superseded render must not unlock a new one.
                return
            }

            logger.log(event, metadata: Self.metadata(from: body))
        }

        private func handleSourceLineFocus(_ body: [String: Any]) {
            guard let anchor = Self.viewportAnchor(from: body) else { return }

            DispatchQueue.main.async {
                self.onViewportAnchor(anchor)
            }
        }

        private static func viewportAnchor(from value: Any?) -> ViewportAnchor? {
            guard let body = value as? [String: Any] else { return nil }
            let line = (body["line"] as? NSNumber)?.intValue ?? 0
            let ratio = (body["viewportRatio"] as? NSNumber)?.doubleValue ?? 0.38
            let kind = body["kind"] as? String ?? "content"
            guard line > 0 else { return nil }
            return ViewportAnchor(sourceLine: line, viewportRatio: ratio, kind: kind)
        }

        private func handleCodeCopyRequest(_ body: [String: Any]) {
            let requestID = body["requestID"] as? String ?? ""
            let code = body["code"] as? String ?? ""
            let success = !code.isEmpty

            if success {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(code, forType: .string)
            }

            logger.log(success ? "code_copy_success" : "code_copy_failure", metadata: [
                "length": .int(code.count)
            ])

            sendCopyResult(requestID: requestID, success: success)
        }

        private func sendCopyResult(requestID: String, success: Bool) {
            guard let webView else { return }
            let payload: [String: Any] = [
                "requestID": requestID,
                "success": success
            ]

            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else {
                return
            }

            webView.evaluateJavaScript("window.BoMDHandleCopyResult(\(json));")
        }

        private static func metadata(from body: [String: Any]) -> [String: LogValue] {
            body.reduce(into: [:]) { result, item in
                guard item.key != "event" else { return }

                switch item.value {
                case let value as String:
                    result[item.key] = .string(value)
                case let value as Int:
                    result[item.key] = .int(value)
                case let value as Double:
                    result[item.key] = .double(value)
                case let value as Bool:
                    result[item.key] = .bool(value)
                default:
                    result[item.key] = .string(String(describing: item.value))
                }
            }
        }
    }
}
