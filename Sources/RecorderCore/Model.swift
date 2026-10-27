import Foundation

public struct Stamp: Codable {
    public let mono: UInt64 // uptime nanoseconds; intervals only
    public let continuous: UInt64 // includes sleep; collection deadline
    public let wall: Double // Unix seconds; alignment only
    public init(_ mono: UInt64, _ continuous: UInt64, _ wall: Double) { self.mono = mono; self.continuous = continuous; self.wall = wall }
}
public struct Record: Codable {
    public var schema = 1
    public var kind: String
    public var stamp: Stamp
    public var app: String?
    public var reason: String?
    public var keyCode: Int?
    public var sourceTimestampNS: UInt64?
    public var modifiers: UInt64?
    public var text: String?
    public var title: String?
    public var layout: String?
    public var repeated: Bool?
    public var holdNS: UInt64?
    public var downIntervalNS: UInt64?
    public var gapNS: Int64?
    public var overlap: Int?
    public var button: Int?
    public var x: Double?
    public var y: Double?
    public var dx: Double?
    public var dy: Double?
    public var clickCount: Int?
    public var continuousScroll: Bool?
    public init(_ kind: String, _ stamp: Stamp) { self.kind = kind; self.stamp = stamp }
    public func redacted() -> Record {
        var r = self; r.text = nil; r.title = nil; r.layout = nil; r.app = nil; r.keyCode = nil; r.modifiers = nil; r.x = nil; r.y = nil
        return r
    }
}
public struct Input {
    public var record: Record
    public init(_ record: Record) { self.record = record }
}
public final class Engine {
    public private(set) var enabled = false
    public private(set) var started: Stamp?
    public private(set) var reason = "off"
    public private(set) var durations: [String: Double] = [:]
    public private(set) var drops = 0
    public var windowHours: Double = 84
    public var sink: (Record) throws -> Void
    private var last: Stamp?
    private var keys: [Int: UInt64] = [:]
    private var buttons: [Int: UInt64] = [:]
    private var previousDown: UInt64?
    private var previousUp: UInt64?
    private var app: String?
    public init(sink: @escaping (Record) throws -> Void) { self.sink = sink }
    public func elapsed(_ s: Stamp) -> Double { guard let start = started else { return 0 }; return Double(s.continuous >= start.continuous ? s.continuous - start.continuous : 0) / 1e9 }
    public func start(_ s: Stamp) {
        if started == nil || elapsed(s) >= windowHours * 3600 { started = s; durations = [:]; last = nil; reason = "off"; drops = 0; app = nil }
        enabled = true; transition("checking", s)
    }
    public func pause(_ s: Stamp, reason: String = "paused") { account(s); enabled = false; transition(reason, s) }
    private func account(_ s: Stamp) {
        if let l = last, let start = started {
            let deadline = start.continuous + UInt64(windowHours * 3600 * 1e9)
            let end = min(s.continuous, deadline)
            if end >= l.continuous { durations[reason, default: 0] += Double(end - l.continuous) / 1e9 }
        }
        last = s
    }
    private func emit(_ r: Record) {
        do { try sink(r) } catch { drops += 1; enabled = false; reason = "storage-error"; keys = [:]; buttons = [:] }
    }
    private func transition(_ next: String, _ s: Stamp) {
        account(s)
        if reason != next {
            reason = next; keys = [:]; buttons = [:]; previousDown = nil; previousUp = nil; lastInput = nil
            var r = Record("boundary", s); r.reason = next; emit(r)
        }
    }
    public func update(_ s: Stamp, context: String, app newApp: String? = nil) {
        if enabled, let start = started, elapsed(s) >= windowHours * 3600 {
            let deadline = start.continuous + UInt64(windowHours * 3600 * 1e9)
            let end = Stamp(s.mono, deadline, start.wall + windowHours * 3600)
            pause(end, reason: "expired"); last = s; return
        }
        guard enabled else { account(s); return }
        transition(context, s)
        guard enabled else { return }
        if app != newApp {
            keys = [:]; buttons = [:]; previousDown = nil; previousUp = nil; lastInput = nil; app = newApp
            if context == "active", let newApp { var r = Record("app-change", s); r.app = newApp; emit(r) }
        }
    }
    public func dropped(_ s: Stamp) { guard enabled else { return }; drops += 1; transition("tap-disabled", s); pause(s, reason: "tap-disabled") }
    public func receive(_ input: Input, context: String, app: String?) {
        let s = input.record.stamp
        update(s, context: context, app: app)
        guard enabled, reason == "active" else { return }
        var r = input.record; r.app = app
        let eventTime = r.sourceTimestampNS ?? s.mono
        if let code = r.keyCode {
            if r.kind == "key-down" {
                r.overlap = keys.count
                if r.repeated != true {
                    if let prior = previousDown, eventTime >= prior { r.downIntervalNS = eventTime - prior } // down-to-down ns
                    if let up = previousUp { r.gapNS = Int64(clamping: eventTime) - Int64(clamping: up) }
                    keys[code] = eventTime; previousDown = eventTime
                }
                if code == 51 || code == 117 { r.reason = "correction-key" }
            } else if r.kind == "key-up" {
                if let down = keys.removeValue(forKey: code), eventTime >= down { r.holdNS = eventTime - down }
                previousUp = eventTime
            }
        }
        if let button = r.button {
            if r.kind == "mouse-down" { buttons[button] = eventTime }
            if r.kind == "mouse-up", let down = buttons.removeValue(forKey: button), eventTime >= down { r.holdNS = eventTime - down }
        }
        if let prior = lastInput, eventTime >= prior, eventTime - prior >= 2_000_000_000 { var pause = Record("input-pause", s); pause.holdNS = eventTime - prior; emit(pause) }
        guard enabled else { return }
        lastInput = eventTime
        emit(r)
    }
    private var lastInput: UInt64?
}
