import XCTest
@testable import RecorderCore

final class RecorderTests: XCTestCase {
    func s(_ seconds: Double, wall: Double? = nil) -> Stamp { Stamp(UInt64(seconds * 1e9), UInt64(seconds * 1e9), wall ?? seconds) }
    func key(_ kind: String, _ t: Double, _ code: Int = 0, repeat repeated: Bool = false) -> Input { var r = Record(kind, s(t)); r.keyCode = code; r.repeated = repeated; r.text = "SYNTHETIC"; return Input(r) }
    func testOffStartPauseImmediateShutdown() {
        var rows: [Record] = []; let e = Engine { rows.append($0) }
        e.receive(key("key-down", 0), context: "active", app: "synthetic")
        XCTAssertTrue(rows.isEmpty); e.start(s(1))
        e.receive(key("key-down", 2), context: "active", app: "synthetic"); e.pause(s(3))
        let count = rows.count; e.receive(key("key-up", 4), context: "active", app: "synthetic")
        XCTAssertEqual(rows.count, count); XCTAssertFalse(e.enabled)
        XCTAssertEqual(e.durations["active"], 1)
    }
    func testDeniedRevokedSecureExcludedUnsupportedLockSleep() {
        for reason in ["permission-denied", "secure-input", "excluded-app", "unsupported-app", "unknown-field", "protected-field", "locked", "sleep"] {
            var rows: [Record] = []; let e = Engine { rows.append($0) }; e.start(s(0))
            e.receive(key("key-down", 1), context: reason, app: nil)
            XCTAssertFalse(rows.contains { $0.keyCode != nil }, reason)
            e.update(s(11), context: "active", app: "synthetic")
            XCTAssertEqual(e.durations[reason], 10)
            e.receive(key("key-up", 12), context: "active", app: "synthetic")
            XCTAssertNil(rows.last?.holdNS)
        }
    }
    func testMonotonicRepeatsOverlapsModifiersAndCorrections() {
        var rows: [Record] = []; let e = Engine { rows.append($0) }; e.start(s(0))
        e.receive(key("key-down", 1), context: "active", app: "synthetic")
        e.receive(key("key-down", 1.1, repeat: true), context: "active", app: "synthetic")
        e.receive(key("key-down", 1.2, 1), context: "active", app: "synthetic")
        e.receive(key("key-up", 1.3), context: "active", app: "synthetic")
        XCTAssertEqual(rows.last?.holdNS, 300_000_000)
        XCTAssertEqual(rows.first { $0.keyCode == 1 }?.overlap, 1)
        var modifier = Record("modifier", s(1.4)); modifier.keyCode = 56; modifier.modifiers = 131072
        e.receive(Input(modifier), context: "active", app: "synthetic")
        e.receive(key("key-down", 1.5, 51), context: "active", app: "synthetic")
        XCTAssertEqual(rows.last?.reason, "correction-key")
        XCTAssertEqual(rows.last?.gapNS, 200_000_000)
        // Wall clock changes never affect interval derivation or expiry.
        var up = Record("key-up", s(2, wall: -100)); up.keyCode = 51
        e.receive(Input(up), context: "active", app: "synthetic")
        XCTAssertEqual(rows.last?.holdNS, 500_000_000)
    }
    func testDeadlineIncludesSleepAndManualPauses() {
        let e = Engine { _ in }; e.windowHours = 1; e.start(s(0)); e.update(s(10), context: "sleep")
        e.update(Stamp(11_000_000_000, 3_600_000_000_000, -20), context: "active", app: "synthetic")
        XCTAssertFalse(e.enabled); XCTAssertEqual(e.reason, "expired"); XCTAssertEqual(e.durations["sleep"], 3590)
        e.start(s(3601)); XCTAssertTrue(e.enabled)
        e.pause(s(3602)); e.start(s(4000)); XCTAssertEqual(e.elapsed(s(4001)), 400)
    }
    func testFailureStopsAndDroppedTap() {
        let e = Engine { _ in throw StoreError.capacity }; e.start(s(0)); XCTAssertFalse(e.enabled); XCTAssertEqual(e.reason, "storage-error")
        var writes: [String] = []; var failBoundary = false
        let guarded = Engine { r in writes.append(r.kind); if failBoundary { throw StoreError.capacity } }
        guarded.start(s(0)); writes = []; failBoundary = true
        guarded.update(s(1), context: "active", app: "synthetic")
        XCTAssertEqual(writes, ["boundary"])
        let e2 = Engine { _ in }; e2.start(s(0)); e2.dropped(s(1)); XCTAssertFalse(e2.enabled); XCTAssertEqual(e2.drops, 1)
    }
    func testLateDeadlineNewWindowAndMidEventStorageFailure() {
        let e = Engine { _ in }; e.windowHours = 1.0 / 3600
        e.start(s(0)); e.update(s(0), context: "active", app: "synthetic")
        e.update(s(100), context: "active", app: "synthetic")
        XCTAssertEqual(e.durations["active"], 1)
        e.start(s(110)); XCTAssertEqual(e.durations.values.reduce(0,+), 0)
        var shouldFail = false; var kinds: [String] = []
        let f = Engine { r in
            kinds.append(r.kind)
            if shouldFail && r.kind == "input-pause" { throw StoreError.capacity }
        }
        f.start(s(0)); f.receive(key("key-down", 1), context: "active", app: "synthetic")
        shouldFail = true
        f.receive(key("key-up", 10), context: "active", app: "synthetic")
        XCTAssertFalse(f.enabled); XCTAssertEqual(kinds.last, "input-pause")
    }
    func testSourceTimestampAndFocusBoundary() {
        var rows: [Record] = []; let e = Engine { rows.append($0) }; e.start(s(0))
        var down = Record("key-down", s(10)); down.keyCode = 0; down.sourceTimestampNS = 1_000
        var up = Record("key-up", s(20)); up.keyCode = 0; up.sourceTimestampNS = 2_000
        e.receive(Input(down), context: "active", app: "synthetic")
        e.receive(Input(up), context: "active", app: "synthetic")
        XCTAssertEqual(rows.last?.holdNS, 1_000)
        e.receive(Input(down), context: "active", app: "synthetic")
        e.update(s(21), context: "focus-change")
        e.receive(Input(up), context: "active", app: "synthetic")
        XCTAssertNil(rows.last?.holdNS)
    }
    func temp() -> URL { URL(fileURLWithPath: "/private/tmp").appendingPathComponent("PatternRecorder-test-\(UUID())") }
    func testRotationPermissionsCapRetentionDeletionAndRedaction() throws {
        let root = temp(); let output = temp(); defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: output) }
        let store = try Store(root: root, segmentLimit: 512, totalLimit: 8192, retentionDays: 1)
        var r = Record("key-down", s(1)); r.text = "SYNTHETIC PRIVATE TEXT"; r.title = "SYNTHETIC TITLE"; r.app = "synthetic"; r.keyCode = 0; r.modifiers = 1
        for _ in 0..<8 { try store.append(r) }; store.closeFile()
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertGreaterThan(files.count, 1)
        XCTAssertEqual((try fm.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        for f in files { XCTAssertEqual((try fm.attributesOfItem(atPath: f.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600) }
        try store.manifest(["schema": 1, "synthetic": true]); try store.export(to: output, redacted: true)
        for f in try fm.contentsOfDirectory(at: output, includingPropertiesForKeys: nil) {
            let text = try String(contentsOf: f, encoding: .utf8)
            XCTAssertFalse(text.contains("SYNTHETIC PRIVATE")); XCTAssertFalse(text.contains("keyCode")); XCTAssertFalse(text.contains("SYNTHETIC TITLE"))
        }
        XCTAssertThrowsError(try store.export(to: output, redacted: false))
        try store.maintain(now: Date().addingTimeInterval(90000)); XCTAssertTrue(try fm.contentsOfDirectory(atPath: root.path).isEmpty)
        for _ in 0..<8 { try store.append(r) }; try store.deleteAll(); XCTAssertTrue(try fm.contentsOfDirectory(atPath: root.path).isEmpty)
        let tiny = try Store(root: root, segmentLimit: 512, totalLimit: 512)
        var capped = false
        for _ in 0..<20 {
            do { try tiny.append(r) } catch StoreError.capacity { capped = true; break }
        }
        XCTAssertTrue(capped)
        tiny.closeFile()
        let total = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).reduce(0) { n, f in n + ((try fm.attributesOfItem(atPath: f.path)[.size]) as? Int ?? 0) }
        XCTAssertLessThanOrEqual(total, 512)
    }
    func testSymlinkAndGitExportRefusal() throws {
        let base = temp(); let link = temp(); let repo = temp()
        defer { for p in [base, link, repo] { try? FileManager.default.removeItem(at: p) } }
        try Store.privateDirectory(base)
        guard symlink(base.path, link.path) == 0 else { throw StoreError.io(errno) }
        XCTAssertThrowsError(try Store(root: link))
        let store = try Store(root: base)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.export(to: repo.appendingPathComponent("export"), redacted: false))
    }
    func testSyntheticGrowthAndOverhead() throws {
        let root = temp(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root); let e = Engine { try store.append($0) }; e.start(s(0))
        let start = Date()
        for i in 0..<10000 { e.receive(key(i % 2 == 0 ? "key-down" : "key-up", Double(i) * 0.1, 0), context: "active", app: "synthetic") }
        store.closeFile()
        let elapsed = Date().timeIntervalSince(start)
        let bytes = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).reduce(0) { n, p in n + ((try FileManager.default.attributesOfItem(atPath: p.path)[.size]) as? Int ?? 0) }
        print("SYNTHETIC_BENCH events=10000 seconds=\(elapsed) bytes=\(bytes) microsecondsPerEvent=\(elapsed * 100) bytesPerEvent=\(Double(bytes)/10000)")
        XCTAssertEqual(e.drops, 0)
    }
}
