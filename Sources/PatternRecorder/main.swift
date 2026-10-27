import AppKit
import ApplicationServices
import Carbon
import ServiceManagement
import RecorderCore

func stamp() -> Stamp {
    Stamp(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW), Date().timeIntervalSince1970)
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var timer: Timer?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var store: Store?
    private lazy var engine = Engine { [weak self] record in
        guard let store = self?.store else { throw StoreError.unsafePath }
        try store.append(record)
    }
    private var sleeping = false
    private var sessionActive = true
    private var textEnabled = false
    private var motionEnabled = false
    private var titlesEnabled = false
    private var lastMotion: UInt64 = 0
    private var lastField: AXUIElement?
    private var focusChanged = false
    private var errorMessage = ""
    private var callbackCount: UInt64 = 0
    private var callbackNS: UInt64 = 0
    private var maxCallbackNS: UInt64 = 0
    private var maintenanceTicks = 0
    private var observers: [NSObjectProtocol] = []
    private let defaults = UserDefaults.standard
    private var excluded: Set<String> { Set((defaults.string(forKey: "excluded") ?? "").split(separator: "\n").map(String.init)) }
    private let supported: Set<String> = ["com.apple.TextEdit", "com.apple.dt.Xcode"]
    private let deniedFragments = ["1password", "bitwarden", "lastpass", "keepass", "dashlane", "keychain", "password", "authy", "protonpass", "loginwindow", "systempreferences", "terminal", "iterm"]
    private var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PatternRecorder", isDirectory: true) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No event tap, permission prompt, or data directory until the owner presses Start.
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = NSMenu(); item.menu?.delegate = self
        observe()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        render()
    }
    private func observe() {
        let nc = NSWorkspace.shared.notificationCenter
        func watch(_ name: NSNotification.Name, _ action: @escaping () -> Void) { observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in action() }) }
        watch(NSWorkspace.willSleepNotification) { [weak self] in self?.sleeping = true; self?.boundary() }
        watch(NSWorkspace.didWakeNotification) { [weak self] in self?.sleeping = false; self?.boundary() }
        watch(NSWorkspace.screensDidSleepNotification) { [weak self] in self?.sleeping = true; self?.boundary() }
        watch(NSWorkspace.screensDidWakeNotification) { [weak self] in self?.sleeping = false; self?.boundary() }
        watch(NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.sessionActive = false; self?.boundary() }
        watch(NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.sessionActive = true; self?.boundary() }
        watch(NSWorkspace.didActivateApplicationNotification) { [weak self] in self?.boundary() }
    }
    private func attr(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
    // Read metadata only: NEVER AXValue, selected text, document content or clipboard.
    private func context() -> (String, String?, AXUIElement?) {
        guard engine.enabled else { return ("off", nil, nil) }
        guard !sleeping else { return ("sleep", nil, nil) }
        guard sessionActive, let session = CGSessionCopyCurrentDictionary() as? [String: Any], session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session["CGSSessionScreenIsLocked"] as? Bool != true else { return ("locked", nil, nil) }
        guard CGPreflightListenEventAccess(), AXIsProcessTrusted() else { return ("permission-denied", nil, nil) }
        guard !IsSecureEventInputEnabled() else { return ("secure-input", nil, nil) }
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier else { return ("unknown-app", nil, nil) }
        guard !excluded.contains(id), !deniedFragments.contains(where: { id.lowercased().contains($0) }) else { return ("excluded-app", nil, nil) }
        guard supported.contains(id) else { return ("unsupported-app", nil, nil) }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.01)
        guard let focusedApp = attr(system, kAXFocusedApplicationAttribute), CFGetTypeID(focusedApp) == AXUIElementGetTypeID() else { return ("unknown-focus", nil, nil) }
        var focusedPID: pid_t = 0
        guard AXUIElementGetPid(focusedApp as! AXUIElement, &focusedPID) == .success, focusedPID == app.processIdentifier else { return ("focus-mismatch", nil, nil) }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.01)
        guard let value = attr(appElement, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return ("unknown-field", nil, nil) }
        let field = value as! AXUIElement
        AXUIElementSetMessagingTimeout(field, 0.01)
        var pid: pid_t = 0
        guard AXUIElementGetPid(field, &pid) == .success, pid == app.processIdentifier,
              let role = attr(field, kAXRoleAttribute) as? String, role == kAXTextAreaRole as String,
              (attr(field, kAXEnabledAttribute) as? Bool) == true else { return ("unsupported-field", nil, nil) }
        // Only editor text areas, never generic text/password/search fields. Unknown subroles fail closed.
        var subroleValue: CFTypeRef?
        let subroleResult = AXUIElementCopyAttributeValue(field, kAXSubroleAttribute as CFString, &subroleValue)
        let subrole = subroleValue as? String
        // attributeUnsupported/noValue means absent, not a timeout or permission failure.
        guard (subroleResult == .attributeUnsupported || subroleResult == .noValue) || (subroleResult == .success && (subrole == "AXStandardTextArea" || subrole == "")) else { return ("protected-field", nil, nil) }
        // Re-check after AX IPC; a focus switch during metadata inspection rejects this event.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, !IsSecureEventInputEnabled() else { return ("focus-race", nil, nil) }
        focusChanged = focusChanged || (lastField.map { !CFEqual($0, field) } ?? true)
        lastField = field
        return ("active", id, appElement)
    }
    private func boundary() {
        guard engine.enabled else { return }
        let c = context(); let s = stamp()
        if c.0 == "active" && focusChanged { engine.update(s, context: "focus-change"); focusChanged = false }
        if c.0 != "active" { lastField = nil }
        engine.update(s, context: c.0, app: c.1)
        if c.0 == "permission-denied" { pause(reason: "permission-denied"); errorMessage = "Permission removed. Re-enable Input Monitoring and Accessibility, then Start." }
        render()
    }
    private func tick() {
        if engine.enabled {
            boundary()
            if !engine.enabled { removeTap() }
            saveManifest()
        } else { engine.update(stamp(), context: engine.reason) }
        maintenanceTicks += 1
        if maintenanceTicks >= 60 {
            maintenanceTicks = 0
            if store != nil { saveManifest() }
            do {
                if let store { try store.maintain() }
                else if FileManager.default.fileExists(atPath: root.path) { _ = try Store(root: root) }
            } catch { fail("Retention failed; inspect data folder permissions.") }
        }
        render()
    }
    func menuWillOpen(_ menu: NSMenu) { renderMenu() }
    private func render() {
        let active = engine.enabled && engine.reason == "active"
        item.button?.image = NSImage(systemSymbolName: active ? "record.circle.fill" : "pause.circle", accessibilityDescription: active ? "Recording" : "Paused")
        item.button?.title = active ? " REC" : (engine.enabled ? " WAIT" : " OFF")
        item.button?.toolTip = "Pattern Recorder: \(engine.reason)"
        renderMenu()
    }
    private func renderMenu() {
        guard let menu = item.menu else { return }; menu.removeAllItems()
        func add(_ title: String, _ action: Selector? = nil, state: Bool = false) {
            let m = NSMenuItem(title: title, action: action, keyEquivalent: ""); m.target = self; m.state = state ? .on : .off; menu.addItem(m)
        }
        add("Pattern Recorder — \(engine.reason)")
        let elapsed = engine.elapsed(stamp()) / 3600
        add(String(format: "Elapsed %.2fh · Remaining %.2fh", elapsed, max(0, engine.windowHours - elapsed)))
        add(String(format: "Active %.2fh · Excluded/other %.2fh", (engine.durations["active"] ?? 0) / 3600, engine.durations.filter { $0.key != "active" }.values.reduce(0,+) / 3600))
        if !errorMessage.isEmpty { add(errorMessage) }
        add(engine.enabled ? "Pause immediately" : "Start…", #selector(toggle))
        menu.addItem(.separator())
        add("What is captured / permissions…", #selector(disclosure))
        add("Capture typed characters (opt-in)…", #selector(toggleText), state: textEnabled)
        add("Window titles (opt-in)…", #selector(toggleTitles), state: titlesEnabled)
        add("Mouse motion ≤10 samples/sec…", #selector(toggleMotion), state: motionEnabled)
        add("Collection hours (default 84)…", #selector(hours))
        add("Exclude apps by bundle ID…", #selector(exclusions))
        add("Launch at login (starts OFF)", #selector(login), state: SMAppService.mainApp.status == .enabled)
        if SMAppService.mainApp.status == .requiresApproval { add("Login item needs approval in System Settings") }
        menu.addItem(.separator())
        add("Open data folder", #selector(openFolder))
        add("Export timing-only / redacted…", #selector(exportRedacted))
        add("Export full recordings…", #selector(exportFull))
        add("Delete all recordings…", #selector(deleteData))
        add("Quit (stops capture)", #selector(quit))
    }
    @discardableResult private func alert(_ title: String, _ message: String, confirm: String? = nil) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = title; a.informativeText = message
        a.addButton(withTitle: confirm ?? "OK"); if confirm != nil { a.addButton(withTitle: "Cancel") }
        return a.runModal() == .alertFirstButtonReturn
    }
    private var disclosureText: String {
        "OFF until Start. Records observed physical key codes, down/up timing, modifiers, repeats, corrections, mouse clicks/scroll, foreground editor ID and boundaries. Supported: TextEdit and Xcode editor text areas only; other apps/unknown fields are excluded. Accessibility is required for the safety gate, even in timing-only mode. Secure Input, lock/sleep and excluded apps stop recording. Universal sensitive-field detection is impossible: use Pause for private work.\n\nTyped characters are OFF by default and require a separate opt-in. These are event characters, not final document text; IME, layouts, shortcuts and dropped events limit coverage. Window titles and ≤10Hz motion are separate opt-ins. No clipboard, screenshots, audio, network, document scraping or uploads.\n\nData: ~/Library/Application Support/PatternRecorder, owner-only, 8MiB segments, 256MiB cap (then pause), 14-day retention while running. Default window: 84 elapsed hours including sleep/pauses; active time tracked separately. App restarts OFF, login optional. Export may contain sensitive data."
    }
    @objc private func disclosure() { alert("Capture disclosure", disclosureText) }
    @objc private func toggle() {
        if engine.enabled { pause(); return }
        guard alert("Start local collection?", disclosureText + "\n\nCurrent text capture: \(textEnabled ? "ON" : "OFF"). No real input was collected during implementation.", confirm: "Start") else { return }
        guard CGPreflightListenEventAccess() else {
            _ = CGRequestListenEventAccess()
            alert("Input Monitoring required", "System Settings → Privacy & Security → Input Monitoring → enable Pattern Recorder. Quit/reopen if macOS asks, then press Start again. No capture started."); return
        }
        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            alert("Accessibility required", "System Settings → Privacy & Security → Accessibility → enable Pattern Recorder. Used only to inspect focused field metadata for safe exclusion. Then press Start again. No capture started."); return
        }
        do {
            if store == nil || (engine.started != nil && engine.elapsed(stamp()) >= engine.windowHours * 3600) { store?.closeFile(); store = try Store(root: root); callbackCount = 0; callbackNS = 0; maxCallbackNS = 0 }
            engine.windowHours = defaults.double(forKey: "hours") > 0 ? defaults.double(forKey: "hours") : 84
            engine.start(stamp()); errorMessage = ""
            guard engine.enabled else { throw StoreError.capacity }
            try installTap(); boundary(); saveManifest()
        } catch { fail("Cannot start: \(error). Check permissions, free space and private data directory.") }
        render()
    }
    private func pause(reason: String = "paused") { removeTap(); if engine.enabled { engine.pause(stamp(), reason: reason) }; store?.closeFile(); saveManifest(); render() }
    private func fail(_ message: String) { pause(reason: "error"); errorMessage = message; render() }
    private func saveManifest() {
        guard let store else { return }
        do { try store.manifest(["schema": 1, "session": store.sessionID, "createdWall": engine.started?.wall ?? 0, "windowHours": engine.windowHours, "elapsedSeconds": engine.elapsed(stamp()), "durationsSeconds": engine.durations, "state": engine.reason, "droppedKnown": engine.drops, "unknownLossPossible": true, "textEnabled": textEnabled, "titlesEnabled": titlesEnabled, "motionEnabled": motionEnabled, "callbackCount": callbackCount, "callbackTotalNS": callbackNS, "callbackMaxNS": maxCallbackNS, "platform": ProcessInfo.processInfo.operatingSystemVersionString]) }
        catch { removeTap(); engine.pause(stamp(), reason: "storage-error"); errorMessage = "Manifest write failed; capture stopped. Check disk and permissions." }
    }
    @objc private func toggleText() { pause(); if textEnabled { textEnabled = false } else { textEnabled = alert("Enable typed character capture?", "Supported non-secure TextEdit/Xcode editor events may include personal text. This is not final document text. Unknown contexts are excluded, but universal sensitive-field detection cannot be guaranteed. Pause before private work. Nothing is uploaded.", confirm: "Enable characters") }; render() }
    @objc private func toggleTitles() { pause(); if titlesEnabled { titlesEnabled = false } else { titlesEnabled = alert("Capture window titles?", "Supported editor window titles can contain filenames and personal information. Stored locally and omitted from redacted exports.", confirm: "Enable titles") }; render() }
    @objc private func toggleMotion() { pause(); motionEnabled.toggle(); render() }
    private func edit(_ title: String, value: String) -> String? {
        pause(); NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 80)); field.stringValue = value; a.accessoryView = field
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
    @objc private func hours() { if let s = edit("Elapsed collection hours (0.01–336)", value: String(defaults.double(forKey: "hours") > 0 ? defaults.double(forKey: "hours") : 84)), let n = Double(s), n.isFinite, n >= 0.01, n <= 336 { defaults.set(n, forKey: "hours"); engine.windowHours = n; render() } }
    @objc private func exclusions() { if let s = edit("Additional excluded bundle IDs, one per line", value: defaults.string(forKey: "excluded") ?? "") { defaults.set(s, forKey: "excluded") } }
    @objc private func login() {
        do { if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() } }
        catch { alert("Login setting failed", "\(error). Install the .app in /Applications first. Check System Settings → General → Login Items & Extensions.") }
        render()
    }
    @objc private func openFolder() { if FileManager.default.fileExists(atPath: root.path) { NSWorkspace.shared.open(root) } else { alert("No recordings yet", "The data folder is created only after an explicit Start.\n\(root.path)") } }
    @objc private func exportRedacted() { exportData(redacted: true) }
    @objc private func exportFull() { exportData(redacted: false) }
    private func exportData(redacted: Bool) {
        pause()
        let exportStore: Store
        do {
            guard FileManager.default.fileExists(atPath: root.path) else { alert("No recordings yet", "No local data folder exists."); return }
            exportStore = try store ?? Store(root: root)
        } catch { alert("Cannot open recordings", "Check private data directory permissions."); return }
        if !redacted && !alert("Sensitive export", "Full exports may contain private typed text, physical key identities, app IDs and window titles. Keep exports outside Git and cloud-synced folders. Redacted export removes these fields.", confirm: "Choose local destination") { return }
        let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true; p.prompt = "Export here"
        if p.runModal() == .OK, let parent = p.url {
            let destination = parent.appendingPathComponent("PatternRecorder-\(UUID().uuidString).export")
            do { try exportStore.export(to: destination, redacted: redacted); NSWorkspace.shared.open(destination) }
            catch { alert("Export failed", "\(error). Choose a local folder outside any Git checkout.") }
        }
    }
    @objc private func deleteData() {
        pause()
        guard alert("Delete all local recordings?", "Deletes all app-managed JSON/JSONL recordings and manifests. Exported copies must be deleted separately. SSD backups/snapshots may retain data; deletion is not secure erasure.", confirm: "Delete recordings") else { return }
        do { if let store { try store.deleteAll() } else if FileManager.default.fileExists(atPath: root.path) { try Store(root: root).deleteAll() }; store = nil; engine = Engine { [weak self] r in guard let store = self?.store else { throw StoreError.unsafePath }; try store.append(r) }; errorMessage = "" }
        catch { alert("Deletion failed", "\(error). Inspect \(root.path).") }; render()
    }
    @objc private func quit() { pause(reason: "quit"); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { pause(reason: "quit") }
    private func installTap() throws {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel] + (motionEnabled ? [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged] : [])
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<App>.fromOpaque(info).takeUnretainedValue()
            owner.receive(type, event)
            return Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { throw StoreError.io(EPERM) }
        tap = t; source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        guard let source else { removeTap(); throw StoreError.io(EINVAL) }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes); CGEvent.tapEnable(tap: t, enable: true)
    }
    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; tap = nil
    }
    private func receive(_ type: CGEventType, _ event: CGEvent) {
        guard engine.enabled else { return }
        let received = stamp()
        let begin = received.mono
        defer { let duration = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - begin; callbackCount += 1; callbackNS += duration; maxCallbackNS = max(maxCallbackNS, duration) }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { engine.dropped(stamp()); removeTap(); errorMessage = "Event tap disabled; possible lost events. Press Start to retry."; render(); return }
        if [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type), received.mono >= lastMotion, received.mono - lastMotion < 100_000_000 { return }
        let c = context()
        guard c.0 == "active" else { engine.update(stamp(), context: c.0, app: c.1); if c.0 == "permission-denied" { pause(reason: c.0) }; return }
        // Explicitly identified process-sourced events are rejected; OS does not reliably label all synthetic input.
        guard event.getIntegerValueField(.eventSourceUnixProcessID) == 0,
              event.getIntegerValueField(.eventTargetUnixProcessID) == Int64(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1) else { return }
        let s = received; var r = Record("", s)
        r.sourceTimestampNS = event.timestamp
        switch type {
        case .keyDown, .keyUp, .flagsChanged:
            r.kind = type == .keyDown ? "key-down" : (type == .keyUp ? "key-up" : "modifier")
            r.keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode)); r.modifiers = event.flags.rawValue; r.repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if textEnabled && type == .keyDown && event.flags.intersection([.maskCommand, .maskControl, .maskSecondaryFn]).isEmpty {
                let inputSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
                let asciiPointer = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceIsASCIICapable)
                let asciiCapable = asciiPointer.map { Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue() == kCFBooleanTrue } ?? false
                if asciiCapable {
                var chars = [UniChar](repeating: 0, count: 64); var length = 0
                event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
                r.text = String(utf16CodeUnits: chars, count: min(length, chars.count))
                }
                if let pointer = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID) { r.layout = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String }
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            r.kind = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) ? "mouse-down" : "mouse-up"
            r.button = Int(event.getIntegerValueField(.mouseEventButtonNumber)); r.clickCount = Int(event.getIntegerValueField(.mouseEventClickState)); r.x = event.location.x; r.y = event.location.y
        case .scrollWheel:
            r.kind = "scroll"; r.continuousScroll = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            r.dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2); r.dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        default:
            guard motionEnabled, s.mono >= lastMotion, s.mono - lastMotion >= 100_000_000 else { return }
            lastMotion = s.mono; r.kind = "motion"; r.x = event.location.x; r.y = event.location.y
        }
        if titlesEnabled, let axApp = c.2, let win = attr(axApp, kAXFocusedWindowAttribute), CFGetTypeID(win) == AXUIElementGetTypeID() { r.title = (attr(win as! AXUIElement, kAXTitleAttribute) as? String).map { String($0.prefix(256)) } }
        // Secure Input is never disabled, and metadata failures never fall back to raw capture.
        guard !IsSecureEventInputEnabled(), NSWorkspace.shared.frontmostApplication?.bundleIdentifier == c.1 else { return }
        if focusChanged { engine.update(s, context: "focus-change"); focusChanged = false }
        engine.receive(Input(r), context: c.0, app: c.1)
        if !engine.enabled { removeTap(); errorMessage = "Capture stopped (storage/deadline). Inspect data folder or delete old recordings."; render() }
    }
}
let application = NSApplication.shared
let delegate = App()
application.delegate = delegate
application.run()
