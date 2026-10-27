import Foundation
import Darwin

public enum StoreError: Error { case unsafePath, io(Int32), capacity, invalidLimit }
public final class Store {
    public let root: URL
    public let sessionID: String
    public var segmentLimit: Int
    public var totalLimit: Int
    public var retentionDays: Double
    private var fd: Int32 = -1
    private var bytes = 0
    private var segment = 0
    private let encoder = JSONEncoder()
    public init(root: URL, sessionID: String = UUID().uuidString, segmentLimit: Int = 8 * 1024 * 1024, totalLimit: Int = 256 * 1024 * 1024, retentionDays: Double = 14) throws {
        guard segmentLimit > 0, totalLimit >= segmentLimit, retentionDays.isFinite, retentionDays > 0, UUID(uuidString: sessionID) != nil else { throw StoreError.invalidLimit }
        self.root = root; self.sessionID = sessionID; self.segmentLimit = segmentLimit; self.totalLimit = totalLimit; self.retentionDays = retentionDays
        try Self.privateDirectory(root)
        encoder.outputFormatting = [.sortedKeys]
        try maintain()
    }
    deinit { closeFile() }
    public static func privateDirectory(_ url: URL) throws {
        let fm = FileManager.default
        // Reject symlink ancestors, including a pre-existing destination.
        var path = url.path
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw StoreError.unsafePath }
        while path != "/" {
            if let a = try? fm.attributesOfItem(atPath: path), a[.type] as? FileAttributeType == .typeSymbolicLink { throw StoreError.unsafePath }
            path = (path as NSString).deletingLastPathComponent
        }
        if !fm.fileExists(atPath: url.path) { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let a = try fm.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeDirectory, (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw StoreError.unsafePath }
        guard chmod(url.path, 0o700) == 0 else { throw StoreError.io(errno) }
    }
    private func files() throws -> [URL] {
        let list = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" || $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in list {
            let a = try FileManager.default.attributesOfItem(atPath: file.path)
            guard a[.type] as? FileAttributeType == .typeRegular, (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw StoreError.unsafePath }
        }
        return list
    }
    public func maintain(now: Date = Date()) throws {
        for file in try files() {
            let a = try FileManager.default.attributesOfItem(atPath: file.path)
            guard a[.type] as? FileAttributeType == .typeRegular else { throw StoreError.unsafePath }
            if let date = a[.modificationDate] as? Date, now.timeIntervalSince(date) > retentionDays * 86400 {
                // Never unlink the currently open file. Rotate before the next write.
                if file.lastPathComponent == currentName { closeFile() }
                try FileManager.default.removeItem(at: file)
            }
        }
    }
    private var currentName: String { "\(sessionID)-\(String(format: "%05d", segment)).jsonl" }
    public func append(_ record: Record) throws {
        var data = try encoder.encode(record); data.append(10)
        guard data.count <= segmentLimit else { throw StoreError.capacity }
        if bytes + data.count > segmentLimit { closeFile() }
        let total = try files().reduce(0) { n, url in n + ((try FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int ?? 0) }
        guard total + data.count <= totalLimit else { throw StoreError.capacity }
        if fd < 0 {
            segment += 1
            fd = Darwin.open(root.appendingPathComponent(currentName).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw StoreError.io(errno) }; bytes = 0
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw StoreError.io(errno) }; offset += n
            }
        }
        bytes += data.count
    }
    public func closeFile() { if fd >= 0 { _ = fsync(fd); _ = Darwin.close(fd); fd = -1 }; bytes = 0 }
    public func manifest(_ values: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        let url = root.appendingPathComponent("\(sessionID)-manifest.json")
        // Atomic replacement stays within the private directory; refuse existing links.
        if let a = try? FileManager.default.attributesOfItem(atPath: url.path), a[.type] as? FileAttributeType != .typeRegular { throw StoreError.unsafePath }
        let existingSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let total = try files().reduce(0) { n, f in n + ((try FileManager.default.attributesOfItem(atPath: f.path)[.size]) as? Int ?? 0) }
        guard total - existingSize + data.count <= totalLimit else { throw StoreError.capacity }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        guard chmod(url.path, 0o600) == 0 else { throw StoreError.io(errno) }
    }
    public func deleteAll() throws {
        closeFile()
        for file in try files() { try FileManager.default.removeItem(at: file) }
    }
    public func export(to destination: URL, redacted: Bool) throws {
        closeFile()
        var ancestor = destination.path
        while ancestor != "/" {
            if FileManager.default.fileExists(atPath: (ancestor as NSString).appendingPathComponent(".git")) { throw StoreError.unsafePath }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw StoreError.unsafePath }
        try Self.privateDirectory(destination)
        do {
            for file in try files() where file.pathExtension == "jsonl" {
                let raw = try Data(contentsOf: file)
                var output = Data()
                for line in raw.split(separator: 10) {
                    let r = try JSONDecoder().decode(Record.self, from: Data(line))
                    output.append(try encoder.encode(redacted ? r.redacted() : r)); output.append(10)
                }
                let target = destination.appendingPathComponent(file.lastPathComponent)
                try output.write(to: target, options: .withoutOverwriting)
                guard chmod(target.path, 0o600) == 0 else { throw StoreError.io(errno) }
            }
            // Redacted manifests carry no app identities, settings or text.
            let manifest: [String: Any] = ["schema": 1, "exportedAt": Date().timeIntervalSince1970, "redacted": redacted, "source": "PatternRecorder", "note": "Observed events, not final document text; recordings may contain gaps."]
            let target = destination.appendingPathComponent("manifest.json")
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: target)
            guard chmod(target.path, 0o600) == 0 else { throw StoreError.io(errno) }
            if !redacted {
                for file in try files() where file.pathExtension == "json" {
                    let target = destination.appendingPathComponent(file.lastPathComponent)
                    try FileManager.default.copyItem(at: file, to: target)
                    guard chmod(target.path, 0o600) == 0 else { throw StoreError.io(errno) }
                }
            }
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
}
