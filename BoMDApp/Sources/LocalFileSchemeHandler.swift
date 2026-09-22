import Foundation
import UniformTypeIdentifiers
import WebKit

final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    private static let localImageMIMETypes: [String: String] = [
        "avif": "image/avif",
        "bmp": "image/bmp",
        "gif": "image/gif",
        "heic": "image/heic",
        "heif": "image/heif",
        "jpeg": "image/jpeg",
        "jpg": "image/jpeg",
        "png": "image/png",
        "svg": "image/svg+xml",
        "tif": "image/tiff",
        "tiff": "image/tiff",
        "webp": "image/webp"
    ]
    private var baseDirectory: URL?

    init(baseDirectory: URL?) {
        self.baseDirectory = baseDirectory?.standardizedFileURL
    }

    func updateBaseDirectory(_ baseDirectory: URL?) {
        self.baseDirectory = baseDirectory?.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let fileURL = resolvedFileURL(from: requestURL),
              Self.isAllowedLocalResource(fileURL, relativeTo: baseDirectory),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            fail(urlSchemeTask, code: 404)
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let response = URLResponse(
                url: requestURL,
                mimeType: mimeType(for: fileURL),
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            fail(urlSchemeTask, code: 500)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { }

    private func resolvedFileURL(from requestURL: URL) -> URL? {
        guard let encodedPath = requestURL.host ?? requestURL.pathComponents.dropFirst().first,
              let decodedPath = encodedPath.removingPercentEncoding else {
            return nil
        }

        return URL(fileURLWithPath: decodedPath).standardizedFileURL
    }

    static func isAllowedLocalResource(_ fileURL: URL, relativeTo baseDirectory: URL?) -> Bool {
        guard baseDirectory != nil,
              fileURL.isFileURL,
              localImageMIMETypes[fileURL.pathExtension.lowercased()] != nil else {
            return false
        }

        return true
    }

    private func mimeType(for fileURL: URL) -> String {
        if let mimeType = Self.localImageMIMETypes[fileURL.pathExtension.lowercased()] {
            return mimeType
        }
        if let type = UTType(filenameExtension: fileURL.pathExtension),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        return "application/octet-stream"
    }

    private func fail(_ urlSchemeTask: WKURLSchemeTask, code: Int) {
        let error = NSError(
            domain: "BoMD.LocalFileSchemeHandler",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: "Unable to load local resource."]
        )
        urlSchemeTask.didFailWithError(error)
    }
}
