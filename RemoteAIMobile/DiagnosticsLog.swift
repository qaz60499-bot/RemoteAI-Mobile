import Foundation
import Combine
import UIKit

@MainActor
final class DiagnosticsLog: ObservableObject {
    static let shared = DiagnosticsLog()

    @Published private(set) var lines: [String] = []

    private let maxLines = 1200
    private let retention: TimeInterval = 3 * 24 * 60 * 60
    private let fileURL: URL
    private let iso = ISO8601DateFormatter()
    private var persistWorkItem: DispatchWorkItem?
    private let forbiddenKeys = ["secret", "token", "password", "credential", "proof", "cipher", "message", "text", "content", "attachmentdata"]

    private init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("RemoteAI", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("diagnostics.log")
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
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
        let safeEvent = sanitize(event, limit: 96)
        let safeFields = fields
            .filter { key, _ in !forbiddenKeys.contains(where: { key.lowercased().contains($0) }) }
            .sorted { $0.key < $1.key }
            .map { "\(sanitize($0.key, limit: 48))=\(sanitize($0.value, limit: 180))" }
            .joined(separator: " ")
        let line = "\(iso.string(from: Date())) \(level) \(safeEvent)\(safeFields.isEmpty ? "" : " \(safeFields)")"
        lines.append(line)
        pruneInMemory()
        schedulePersist()
    }

    func copyToPasteboard() {
        UIPasteboard.general.string = text
    }

    func clear() {
        persistWorkItem?.cancel()
        persistWorkItem = nil
        lines.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func sanitize(_ value: String, limit: Int) -> String {
        let flattened = value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return String(flattened.prefix(limit))
    }

    private func loadAndPrune() {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let cutoff = Date().addingTimeInterval(-retention)
        lines = raw.split(separator: "\n").map(String.init).filter { line in
            guard let first = line.split(separator: " ").first,
                  let date = iso.date(from: String(first)) else { return false }
            return date >= cutoff
        }
        pruneInMemory()
        persist()
    }

    private func pruneInMemory() {
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    private func schedulePersist() {
        persistWorkItem?.cancel()
        guard let data = lines.joined(separator: "\n").data(using: .utf8) else { return }
        let url = fileURL
        let work = DispatchWorkItem { try? data.write(to: url, options: .atomic) }
        persistWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    private func persist() {
        guard let data = lines.joined(separator: "\n").data(using: .utf8) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
