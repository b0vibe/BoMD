import AppKit
import Foundation

enum AppLogger {
    static let shared = Logger()

    final class Logger {
        private let queue = DispatchQueue(label: "com.wangbo.BoMD.logger")
        private let encoder = JSONEncoder()
        private let timestampFormatter = ISO8601DateFormatter()
        private let logURL: URL
        private let maxFileBytes: Int
        private let retainedArchives: Int
        private var lastSignature: String?
        private var lastSignatureTime: Date?

        init(directory: URL? = nil, maxFileBytes: Int = 2 * 1024 * 1024, retainedArchives: Int = 3) {
            let logsDirectory = directory ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/BoMD", isDirectory: true)
            self.maxFileBytes = max(256, maxFileBytes)
            self.retainedArchives = max(0, retainedArchives)
            try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            logURL = logsDirectory.appendingPathComponent("bomd.log")
            encoder.outputFormatting = [.sortedKeys]
        }

        func log(_ event: String, metadata: [String: LogValue] = [:]) {
            queue.async { [self] in
                var payload: [String: LogValue] = [
                    "time": .string(timestampFormatter.string(from: Date())),
                    "event": .string(event)
                ]
                metadata.forEach { payload[$0.key] = $0.value }

                let signature = Self.signature(event: event, metadata: metadata)
                if signature == self.lastSignature,
                   let lastSignatureTime = self.lastSignatureTime,
                   Date().timeIntervalSince(lastSignatureTime) < 1.0 {
                    return
                }
                do {
                    var data = try encoder.encode(payload)
                    if data.count + 1 > maxFileBytes {
                        // A single very large metadata value must not defeat
                        // the file bound. Keep a valid, explicit JSON record.
                        data = try encoder.encode([
                            "time": .string(timestampFormatter.string(from: Date())),
                            "event": .string("log_record_oversized"),
                            "original_bytes": .int(data.count)
                        ] as [String: LogValue])
                    }
                    data.append(10)
                    try prepareForAppend(byteCount: data.count)
                    if FileManager.default.fileExists(atPath: logURL.path) {
                        let handle = try FileHandle(forWritingTo: logURL)
                        defer { try? handle.close() }
                        try handle.seekToEnd()
                        try handle.write(contentsOf: data)
                    } else {
                        try data.write(to: logURL, options: .atomic)
                    }
                    lastSignature = signature
                    lastSignatureTime = Date()
                } catch {
                    // Do not append after a failed rotation or recursively log
                    // the failure: either could cause unbounded disk growth.
                }
            }
        }

        /// Wait for queued writes, useful for deterministic diagnostics/tests.
        func flush() {
            queue.sync {}
        }

        func revealLogsDirectory() {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        }

        private func archiveURL(_ index: Int) -> URL {
            logURL.deletingLastPathComponent().appendingPathComponent("bomd.\(index).log")
        }

        private func prepareForAppend(byteCount: Int) throws {
            let manager = FileManager.default
            guard manager.fileExists(atPath: logURL.path) else { return }
            let attributes = try manager.attributesOfItem(atPath: logURL.path)
            var size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            if size > maxFileBytes {
                // Migrate an oversized log from older versions without loading
                // it all into memory; retain only complete recent JSONL records.
                let handle = try FileHandle(forReadingFrom: logURL)
                let tail: Data
                do {
                    try handle.seek(toOffset: UInt64(size - maxFileBytes))
                    tail = try handle.read(upToCount: maxFileBytes) ?? Data()
                } catch {
                    try? handle.close()
                    throw error
                }
                try handle.close()
                let complete = tail.firstIndex(of: 10).map { Data(tail.suffix(from: tail.index(after: $0))) } ?? Data()
                try complete.write(to: logURL, options: .atomic)
                size = complete.count
            }
            guard size + byteCount > maxFileBytes else { return }
            if retainedArchives > 0 {
                let oldest = archiveURL(retainedArchives)
                if manager.fileExists(atPath: oldest.path) { try manager.removeItem(at: oldest) }
                if retainedArchives > 1 {
                    for index in stride(from: retainedArchives - 1, through: 1, by: -1) {
                        let source = archiveURL(index)
                        if manager.fileExists(atPath: source.path) {
                            try manager.moveItem(at: source, to: archiveURL(index + 1))
                        }
                    }
                }
                try manager.moveItem(at: logURL, to: archiveURL(1))
            } else {
                try manager.removeItem(at: logURL)
            }
        }

        private static func signature(event: String, metadata: [String: LogValue]) -> String {
            let stableMetadata = metadata
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.signatureValue)" }
                .joined(separator: "&")
            return "\(event):\(stableMetadata)"
        }
    }
}

enum LogValue: Encodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        }
    }

    var signatureValue: String {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return String(value)
        }
    }
}
