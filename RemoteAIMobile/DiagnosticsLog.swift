import Foundation
import OSLog
import UIKit
import CryptoKit

private struct RemoteAIDiagnosticRecord: Codable, Hashable {
    let timestamp: Date
    let level: String
    let event: String
    let fields: [String: String]
}

private struct RemoteAIDiagnosticBugCapsule: Codable, Hashable {
    let schemaVersion: Int
    let capsuleId: String
    let firstObservedAt: Date
    let event: String
    let level: String
    let failureLayer: String
    let failureStage: String
    let failureSignature: String
    let verificationStatus: String
    let replayability: String
    let evidence: [String: String]
}

private struct RemoteAIDiagnosticPerformanceSummary: Codable, Hashable {
    let schemaVersion: Int
    let generatedAt: Date
    let recordCount: Int
    let errorCount: Int
    let warningCount: Int
    let reconnectCount: Int
    let deltaRecoveryBatchCount: Int
    let projectRefreshCount: Int
    let projectLoadCount: Int
    let sendCount: Int
    let attachmentFailureCount: Int
    let durationSampleCount: Int
    let averageDurationMs: Int?
    let maxDurationMs: Int?
    let slowOperationCount: Int
}

private enum RemoteAIDiagnosticRedactor {
    static let sensitiveKeyFragments = [
        "authorization", "api_key", "apikey", "api-key", "token", "cookie", "secret", "password",
        "credential", "proof", "cipher", "message", "text", "content", "attachmentdata", "payload", "body"
    ]

    private static let regexes: [NSRegularExpression] = {
        let patterns = [
            #"(?i)\bBearer\s+[A-Za-z0-9._~+\-/=]{8,}"#,
            #"(?i)\bsk-[A-Za-z0-9_-]{12,}"#,
            #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#,
            #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#,
            #"(?i)(authorization|x-api-key|api[_-]?key|access[_-]?token|refresh[_-]?token|cookie|secret|password)\s*[:=]\s*[^\s,;\}\]]+"#,
            #"(?i)([?&](?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|auth)=)[^&#\s]+"#
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    static func text(_ value: String, limit: Int = 8 * 1024) -> String {
        var output = value.replacingOccurrences(of: "\r", with: " ")
        for regex in regexes {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(in: output, range: range, withTemplate: "<redacted>")
        }
        guard output.count > limit else { return output }
        return String(output.prefix(limit)) + "…<truncated>"
    }

    static func event(_ value: String) -> String {
        text(value.replacingOccurrences(of: "\n", with: " "), limit: 128)
    }

    static func fields(_ fields: [String: String]) -> [String: String] {
        var safe: [String: String] = [:]
        for key in fields.keys.sorted().prefix(64) {
            let normalized = key.lowercased()
            let safeKey = text(key, limit: 64)
            if sensitiveKeyFragments.contains(where: { normalized.contains($0) }) {
                safe[safeKey] = "<redacted>"
            } else {
                safe[safeKey] = text(fields[key] ?? "", limit: 512)
            }
        }
        return safe
    }

    static func data(_ data: Data) -> Data {
        if let object = try? JSONSerialization.jsonObject(with: data),
           JSONSerialization.isValidJSONObject(object),
           let encoded = try? JSONSerialization.data(withJSONObject: redactJSONObject(object), options: [.prettyPrinted, .sortedKeys]) {
            return encoded
        }
        guard let string = String(data: data, encoding: .utf8) else {
            return Data("<non-text diagnostic source omitted>".utf8)
        }
        let rawLines = string.split(separator: "\n", omittingEmptySubsequences: false)
        if rawLines.count > 1 {
            var output: [String] = []
            var parsedJSON = false
            for rawLine in rawLines {
                let line = String(rawLine)
                guard !line.isEmpty else { output.append(""); continue }
                if let lineData = line.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: lineData),
                   JSONSerialization.isValidJSONObject(object),
                   let encoded = try? JSONSerialization.data(withJSONObject: redactJSONObject(object), options: [.sortedKeys]),
                   let safe = String(data: encoded, encoding: .utf8) {
                    parsedJSON = true
                    output.append(safe)
                } else {
                    output.append(text(line, limit: 8 * 1024))
                }
            }
            if parsedJSON { return Data(output.joined(separator: "\n").utf8) }
        }
        return Data(text(string, limit: 8 * 1024 * 1024).utf8)
    }

    private static func redactJSONObject(_ value: Any, key: String? = nil) -> Any {
        if let key {
            let normalized = key.lowercased()
            if sensitiveKeyFragments.contains(where: { normalized.contains($0) }) { return "<redacted>" }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = redactJSONObject(entry.value, key: entry.key)
            }
        }
        if let array = value as? [Any] { return array.map { redactJSONObject($0) } }
        if let string = value as? String { return text(string, limit: 8 * 1024) }
        return value
    }
}

@MainActor
final class DiagnosticsLog: ObservableObject {
    static let shared = DiagnosticsLog()

    @Published private(set) var lines: [String] = []

    private let maxDisplayLines = 1200
    private let retention: TimeInterval = 72 * 60 * 60
    private let maxTotalBytes: Int64 = 100 * 1024 * 1024
    private let maxFileBytes: Int64 = 8 * 1024 * 1024
    private let directoryURL: URL
    private let legacyFileURL: URL
    private let iso = ISO8601DateFormatter()
    private let logger = Logger(subsystem: "com.remoteai.mobile", category: "diagnostics")
    private static let systemMirrorFieldAllowlist: Set<String> = [
        "state", "errortype", "transportkind", "durationms", "closecode", "sequence", "latestsequence",
        "cachedcount", "count", "attachments", "attachmentcount", "build", "finalbytes", "finalchars",
        "canonicalequal", "firstvisiblems", "firstdeltaafterstreaminitms", "visibleupdateintervalp50ms",
        "visibleupdateintervalp95ms", "flushtoframep95ms", "mainthreadstallsover100ms", "reconnectattempt",
        "agentconnected", "browserconnected", "storagedegraded"
    ]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var lastCleanupAt = Date.distantPast

    private init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        directoryURL = base.appendingPathComponent("RemoteAI/Diagnostics", isDirectory: true)
        legacyFileURL = base.appendingPathComponent("RemoteAI/diagnostics.log")
        try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        loadAndPrune()
    }

    var text: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let header = "RemoteAI diagnostics | app=\(version)(\(build)) | iOS=\(UIDevice.current.systemVersion) | model=\(UIDevice.current.model)"
        return ([header] + lines).joined(separator: "\n")
    }

    func record(_ event: String, fields: [String: String] = [:], level: String = "INFO") {
        let record = RemoteAIDiagnosticRecord(
            timestamp: Date(),
            level: normalizedLevel(level),
            event: RemoteAIDiagnosticRedactor.event(event),
            fields: RemoteAIDiagnosticRedactor.fields(fields)
        )
        let rendered = render(record)
        lines.append(rendered)
        pruneDisplay()
        append(record)
        mirrorToSystemLog(record)
        cleanupIfNeeded()
    }

    private func mirrorToSystemLog(_ record: RemoteAIDiagnosticRecord) {
        var parts = [record.event]
        for key in record.fields.keys.sorted() {
            guard Self.systemMirrorFieldAllowlist.contains(key.lowercased()) else { continue }
            let safeKey = RemoteAIDiagnosticRedactor.text(key, limit: 48)
            let safeValue = RemoteAIDiagnosticRedactor.text(record.fields[key] ?? "", limit: 128)
            parts.append("\(safeKey)=\(safeValue)")
        }
        let summary = RemoteAIDiagnosticRedactor.text(parts.joined(separator: " "), limit: 1024)
        switch record.level {
        case "ERROR": logger.error("\(summary, privacy: .public)")
        case "WARN": logger.warning("\(summary, privacy: .public)")
        case "DEBUG": logger.debug("\(summary, privacy: .public)")
        default: logger.info("\(summary, privacy: .public)")
        }
    }

    func copyToPasteboard() {
        UIPasteboard.general.string = RemoteAIDiagnosticRedactor.text(text, limit: 4 * 1024 * 1024)
    }

    func clear() {
        lines.removeAll()
        let fm = FileManager.default
        for url in logFileURLs() { try? fm.removeItem(at: url) }
        try? fm.removeItem(at: legacyFileURL)
        lastCleanupAt = Date()
    }

    func exportDiagnosticBundle(agentSnapshot: JSONValue?, state: [String: String]) throws -> URL {
        cleanup(now: Date())
        let records = readRecords(limit: 10_000)
        let capsules = buildBugCapsules(records: records)
        let performance = buildPerformanceSummary(records: records)
        let info = Bundle.main.infoDictionary
        let metadata: [String: String] = [
            "appVersion": info?["CFBundleShortVersionString"] as? String ?? "?",
            "build": info?["CFBundleVersion"] as? String ?? "?",
            "iOSVersion": UIDevice.current.systemVersion,
            "deviceClass": UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone",
            "generatedAt": iso.string(from: Date()),
            "redacted": "true",
            "retentionHours": "72",
            "logCapacityBytes": String(maxTotalBytes)
        ].merging(RemoteAIDiagnosticRedactor.fields(state)) { current, _ in current }

        var files: [String: Data] = [:]
        files["manifest.json"] = try prettyJSON(metadata)
        files["diagnostics/bug-capsules.json"] = try prettyJSON(capsules)
        files["diagnostics/performance-summary.json"] = try prettyJSON(performance)
        files["diagnostics/recent-records.json"] = try prettyJSON(Array(records.suffix(2000)))

        for url in logFileURLs().sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: url) else { continue }
            files["mobile/runtime/\(url.lastPathComponent)"] = RemoteAIDiagnosticRedactor.data(data)
        }
        if FileManager.default.fileExists(atPath: legacyFileURL.path), let legacy = try? Data(contentsOf: legacyFileURL) {
            files["mobile/legacy/diagnostics.log"] = RemoteAIDiagnosticRedactor.data(legacy)
        }
        if let agentSnapshot {
            let data = try JSONEncoder.remoteAI.encode(agentSnapshot)
            files["windows/agent-snapshot.json"] = RemoteAIDiagnosticRedactor.data(data)
        } else {
            files["windows/agent-snapshot.json"] = Data("{\"available\":false}".utf8)
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteAI-Diagnostics-\(UUID().uuidString).zip")
        try StoredZipArchive.write(files: files, to: destination, maxInputBytes: 128 * 1024 * 1024)
        return destination
    }

    private func normalizedLevel(_ level: String) -> String {
        switch level.uppercased() {
        case "ERROR": return "ERROR"
        case "WARN", "WARNING": return "WARN"
        case "DEBUG": return "DEBUG"
        default: return "INFO"
        }
    }

    private func render(_ record: RemoteAIDiagnosticRecord) -> String {
        let fieldText = record.fields.keys.sorted().map { "\($0)=\(record.fields[$0] ?? "")" }.joined(separator: " ")
        return "\(iso.string(from: record.timestamp)) \(record.level) \(record.event)\(fieldText.isEmpty ? "" : " \(fieldText)")"
    }

    private func append(_ record: RemoteAIDiagnosticRecord) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let url = activeLogURL(at: record.timestamp)
            var data = try encoder.encode(record)
            data.append(0x0A)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            // Diagnostics must never crash or block the app's primary workflow.
        }
    }

    private func activeLogURL(at date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HH"
        let prefix = "runtime-\(formatter.string(from: date))-"
        let candidates = logFileURLs().filter { $0.lastPathComponent.hasPrefix(prefix) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let last = candidates.last,
           let attributes = try? FileManager.default.attributesOfItem(atPath: last.path),
           let size = (attributes[.size] as? NSNumber)?.int64Value,
           size < maxFileBytes {
            return last
        }
        let index: Int
        if let last = candidates.last {
            index = (Int(last.deletingPathExtension().lastPathComponent.split(separator: "-").last ?? "-1") ?? -1) + 1
        } else {
            index = 0
        }
        return directoryURL.appendingPathComponent(String(format: "%@%03d.jsonl", prefix, index))
    }

    private func loadAndPrune() {
        cleanup(now: Date())
        var records = readRecords(limit: maxDisplayLines)
        if records.isEmpty, let legacy = try? String(contentsOf: legacyFileURL, encoding: .utf8) {
            let cutoff = Date().addingTimeInterval(-retention)
            let safe = legacy.split(separator: "\n").map(String.init).filter { line in
                guard let first = line.split(separator: " ").first, let date = iso.date(from: String(first)) else { return false }
                return date >= cutoff
            }.map { RemoteAIDiagnosticRedactor.text($0, limit: 2048) }
            lines = Array(safe.suffix(maxDisplayLines))
            return
        }
        records = Array(records.suffix(maxDisplayLines))
        lines = records.map(render)
        pruneDisplay()
    }

    private func readRecords(limit: Int) -> [RemoteAIDiagnosticRecord] {
        var result: [RemoteAIDiagnosticRecord] = []
        let bounded = max(1, min(limit, 20_000))
        for url in logFileURLs().sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: 0x0A).reversed() {
                guard let record = try? decoder.decode(RemoteAIDiagnosticRecord.self, from: Data(line)) else { continue }
                result.append(RemoteAIDiagnosticRecord(
                    timestamp: record.timestamp,
                    level: normalizedLevel(record.level),
                    event: RemoteAIDiagnosticRedactor.event(record.event),
                    fields: RemoteAIDiagnosticRedactor.fields(record.fields)
                ))
                if result.count >= bounded { break }
            }
            if result.count >= bounded { break }
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    private func pruneDisplay() {
        if lines.count > maxDisplayLines { lines.removeFirst(lines.count - maxDisplayLines) }
    }

    private func cleanupIfNeeded() {
        guard Date().timeIntervalSince(lastCleanupAt) >= 60 else { return }
        cleanup(now: Date())
    }

    private func cleanup(now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        let fm = FileManager.default
        var metadata: [(URL, Date, Int64)] = []
        for url in logFileURLs() {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = values?.contentModificationDate ?? .distantPast
            let size = Int64(values?.fileSize ?? 0)
            if modified < cutoff {
                try? fm.removeItem(at: url)
            } else {
                metadata.append((url, modified, size))
            }
        }
        metadata.sort { $0.1 < $1.1 }
        var total = metadata.reduce(Int64(0)) { $0 + $1.2 }
        for (url, _, size) in metadata where total > maxTotalBytes {
            do {
                try fm.removeItem(at: url)
                total -= size
            } catch { }
        }
        lastCleanupAt = now
    }

    private func logFileURLs() -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return [] }
        return urls.filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("runtime-") }
    }

    private func buildBugCapsules(records: [RemoteAIDiagnosticRecord]) -> [RemoteAIDiagnosticBugCapsule] {
        let candidates = records.filter { record in
            let combined = (record.event + " " + record.fields.values.joined(separator: " ")).lowercased()
            return record.level == "ERROR"
                || combined.contains("failed")
                || combined.contains("failure")
                || combined.contains("timeout")
                || combined.contains("unknown_delivery")
                || combined.contains("replay")
                || combined.contains("incomplete")
        }
        return Array(candidates.suffix(128)).map { record in
            let layer = failureLayer(event: record.event)
            let stage = failureStage(event: record.event)
            let reason = failureReason(record: record)
            let signature = "\(layer).\(stage).\(reason)"
            let seed = Data("\(iso.string(from: record.timestamp))|\(record.event)|\(signature)".utf8)
            let digest = SHA256.hash(data: seed).prefix(10).map { String(format: "%02x", $0) }.joined()
            return RemoteAIDiagnosticBugCapsule(
                schemaVersion: 1,
                capsuleId: "bug-\(digest)",
                firstObservedAt: record.timestamp,
                event: record.event,
                level: record.level,
                failureLayer: layer,
                failureStage: stage,
                failureSignature: signature,
                verificationStatus: record.fields["state"] ?? record.fields["verification"] ?? "unknown",
                replayability: replayability(layer: layer),
                evidence: RemoteAIDiagnosticRedactor.fields(record.fields)
            )
        }
    }

    private func failureLayer(event: String) -> String {
        let value = event.lowercased()
        if value.contains("relay") || value.contains("connection") || value.contains("transport") { return "transport" }
        if value.contains("browser") { return "browser_bridge" }
        if value.contains("project") { return "project_sync" }
        if value.contains("delta") || value.contains("event_") { return "event_sync" }
        if value.contains("attachment") { return "attachment" }
        if value.contains("send") { return "send" }
        if value.contains("session") { return "session_sync" }
        return "unknown"
    }

    private func failureStage(event: String) -> String {
        let value = event.lowercased()
        if value.contains("reconnect") { return "reconnect" }
        if value.contains("refresh") || value.contains("load") { return "read" }
        if value.contains("send") { return "send" }
        if value.contains("recovery") { return "recovery" }
        if value.contains("preview") || value.contains("download") { return "materialization" }
        return "runtime"
    }

    private func failureReason(record: RemoteAIDiagnosticRecord) -> String {
        if let kind = record.fields["transportKind"] { return stableToken(kind) }
        if let code = record.fields["remoteCode"] { return stableToken(code) }
        let value = record.event.lowercased()
        if value.contains("timeout") { return "timeout" }
        if value.contains("incomplete") { return "incomplete" }
        if value.contains("unknown_delivery") { return "unknown_delivery" }
        if value.contains("failed") || record.level == "ERROR" { return "failed" }
        return stableToken(record.event)
    }

    private func replayability(layer: String) -> String {
        switch layer {
        case "project_sync", "event_sync", "transport", "send", "session_sync": return "deterministic"
        case "browser_bridge": return "desktop_browser_required"
        case "attachment": return "artifact_required"
        default: return "runtime_required"
        }
    }

    private func stableToken(_ value: String) -> String {
        let lower = value.lowercased()
        let allowed = lower.map { character -> Character in
            character.isLetter || character.isNumber ? character : "_"
        }
        var result = String(allowed)
        while result.contains("__") { result = result.replacingOccurrences(of: "__", with: "_") }
        return String(result.trimmingCharacters(in: CharacterSet(charactersIn: "_")).prefix(96))
    }

    private func buildPerformanceSummary(records: [RemoteAIDiagnosticRecord]) -> RemoteAIDiagnosticPerformanceSummary {
        let durations = records.compactMap { record -> Int? in
            for key in ["durationMs", "latencyMs", "totalMs"] {
                if let value = record.fields[key].flatMap(Int.init), value >= 0 { return value }
            }
            return nil
        }
        return RemoteAIDiagnosticPerformanceSummary(
            schemaVersion: 1,
            generatedAt: Date(),
            recordCount: records.count,
            errorCount: records.filter { $0.level == "ERROR" }.count,
            warningCount: records.filter { $0.level == "WARN" }.count,
            reconnectCount: records.filter { $0.event.contains("reconnect") || $0.event.contains("connection_failure") }.count,
            deltaRecoveryBatchCount: records.filter { $0.event == "delta_recovery_batch" }.count,
            projectRefreshCount: records.filter { $0.event.hasPrefix("projects_refresh") }.count,
            projectLoadCount: records.filter { $0.event.hasPrefix("project_load") }.count,
            sendCount: records.filter { $0.event.hasPrefix("send_") }.count,
            attachmentFailureCount: records.filter { $0.event.contains("attachment") && ($0.level == "ERROR" || $0.level == "WARN") }.count,
            durationSampleCount: durations.count,
            averageDurationMs: durations.isEmpty ? nil : durations.reduce(0, +) / durations.count,
            maxDurationMs: durations.max(),
            slowOperationCount: durations.filter { $0 >= 5_000 }.count
        )
    }

    private func prettyJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return RemoteAIDiagnosticRedactor.data(try encoder.encode(value))
    }
}

private enum StoredZipArchive {
    private struct Entry {
        let path: Data
        let crc32: UInt32
        let size: UInt32
        let offset: UInt32
        let dosTime: UInt16
        let dosDate: UInt16
    }

    static func write(files: [String: Data], to output: URL, maxInputBytes: Int64) throws {
        let safeFiles = files.keys.sorted().compactMap { path -> (String, Data)? in
            guard !path.isEmpty,
                  !path.hasPrefix("/"),
                  !path.contains("../"),
                  !path.contains("\\") else { return nil }
            guard let data = files[path], data.count <= 24 * 1024 * 1024 else { return nil }
            return (path, data)
        }
        let total = safeFiles.reduce(Int64(0)) { $0 + Int64($1.1.count) }
        guard total <= maxInputBytes else { throw CocoaError(.fileWriteOutOfSpace) }

        var archive = Data()
        var entries: [Entry] = []
        let now = Date()
        let (dosTime, dosDate) = dosTimestamp(now)

        for (pathString, data) in safeFiles {
            let path = Data(pathString.utf8)
            guard path.count <= Int(UInt16.max), data.count <= Int(UInt32.max), archive.count <= Int(UInt32.max) else { continue }
            let crc = crc32(data)
            let offset = UInt32(archive.count)
            archive.appendLE(UInt32(0x04034b50))
            archive.appendLE(UInt16(20))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(dosTime)
            archive.appendLE(dosDate)
            archive.appendLE(crc)
            archive.appendLE(UInt32(data.count))
            archive.appendLE(UInt32(data.count))
            archive.appendLE(UInt16(path.count))
            archive.appendLE(UInt16(0))
            archive.append(path)
            archive.append(data)
            entries.append(Entry(path: path, crc32: crc, size: UInt32(data.count), offset: offset, dosTime: dosTime, dosDate: dosDate))
        }

        let centralOffset = UInt32(archive.count)
        for entry in entries {
            archive.appendLE(UInt32(0x02014b50))
            archive.appendLE(UInt16(20))
            archive.appendLE(UInt16(20))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(entry.dosTime)
            archive.appendLE(entry.dosDate)
            archive.appendLE(entry.crc32)
            archive.appendLE(entry.size)
            archive.appendLE(entry.size)
            archive.appendLE(UInt16(entry.path.count))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt32(0))
            archive.appendLE(entry.offset)
            archive.append(entry.path)
        }
        let centralSize = UInt32(archive.count) - centralOffset
        archive.appendLE(UInt32(0x06054b50))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(centralSize)
        archive.appendLE(centralOffset)
        archive.appendLE(UInt16(0))
        try archive.write(to: output, options: .atomic)
    }

    private static func dosTimestamp(_ date: Date) -> (UInt16, UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone.current, from: date)
        let year = max(1980, min(2107, components.year ?? 1980))
        let month = max(1, min(12, components.month ?? 1))
        let day = max(1, min(31, components.day ?? 1))
        let hour = max(0, min(23, components.hour ?? 0))
        let minute = max(0, min(59, components.minute ?? 0))
        let second = max(0, min(59, components.second ?? 0))
        let time = UInt16((hour << 11) | (minute << 5) | (second / 2))
        let date = UInt16(((year - 1980) << 9) | (month << 5) | day)
        return (time, date)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            var value = (crc ^ UInt32(byte)) & 0xff
            for _ in 0..<8 {
                value = (value & 1) != 0 ? (0xedb88320 ^ (value >> 1)) : (value >> 1)
            }
            crc = (crc >> 8) ^ value
        }
        return crc ^ 0xffffffff
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { buffer in
            append(contentsOf: buffer)
        }
    }
}
