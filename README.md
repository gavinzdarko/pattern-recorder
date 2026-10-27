# Pattern Recorder

A small **native right-hand macOS menu-bar app** that records the owner's own typing/mouse patterns locally for later calibration. Separate project; **no Ghost Typer integration**. Every launch starts **OFF**. No real input was collected during implementation.

## Install and run

Requires macOS 13+, Xcode/Swift 6 for source builds, and Python 3 only for offline summaries. Locally built on Apple silicon/macOS 26.6.1 with Xcode 26.2; older deployment targets and Intel need owner qualification.

```sh
git clone https://github.com/gavinzdarko/pattern-recorder.git
cd pattern-recorder
./scripts/check.sh             # synthetic tests, build/sign, offline checks; no capture
./scripts/build.sh
open "dist/Pattern Recorder.app"
```

For stable permissions/login behavior, copy the bundle to `/Applications` before granting consent, then open it there. If your checkout is in a managed/File Provider folder and Finder metadata invalidates the bundle signature after building, use `PATTERN_RECORDER_OUTPUT_DIR=/private/tmp/pattern-recorder-native-build ./scripts/build.sh`, then open that output bundle. The output-folder option changes generated build artifacts only, never recording storage.

The build script signs ad hoc by default; it does not notarize or install anything. For a stable Developer ID signature, run `SIGN_IDENTITY="Developer ID Application: …" ./scripts/build.sh` with your own installed certificate. Rebuilding an ad-hoc binary can invalidate existing TCC consent; remove/re-add the final bundle in the privacy panes if needed. Do not disable macOS security protections. If Gatekeeper refuses a downloaded build, build from inspected source or use a properly Developer-ID-signed/notarized release; this repository does not supply one.

The pause-circle **OFF** icon appears in the **right-hand system menu bar**, alongside status icons such as Wi-Fi/battery, with no Dock icon. Click it to open controls. macOS/user controls exact ordering; crowded/notched menu bars can hide icons. It is not a browser/webpage or the left application menu.

## Permissions and first Start

1. Open the icon → **What is captured / permissions…**. Start explains exact capture again and has Cancel. Until the owner confirms **Start**, no event tap, permission prompt or recording directory is created. Existing data may be retained/deleted/exported while OFF.
2. After Start, macOS may request **Input Monitoring**. Open Apple menu → System Settings → Privacy & Security → Input Monitoring; enable **Pattern Recorder**. Quit/reopen if requested, then press Start again. Denial leaves capture off.
3. Start may next request **Accessibility**. System Settings → Privacy & Security → Accessibility → add/enable the same final `.app`. This is used for focused-field metadata safety checks, including timing-only mode. No field/document contents are read through Accessibility. Press Start again. No Screen Recording, camera, mic, browser or Full Disk Access permissions are needed.
4. Review [owner-only qualification](docs/OWNER-CHECKS.md) using disposable synthetic text before personal collection. Permission revocation is checked per event and at most one-second polling; capture stops and requires Start again. No bypass, TCC edits or repeated automatic prompting.

Only **TextEdit and Xcode editor AXTextArea fields** are supported. Global focus, event-target PID, field metadata and Secure Input must pass. Unsupported apps and unknown contexts are excluded. Browsers, terminals, password managers, generic/password/search fields and lock/login contexts are unsupported. Sensitive-field detection across arbitrary apps cannot be guaranteed. Even an editor can contain secrets: Pause for private work. See [Apple API research](docs/APPLE-RESEARCH.md) for the documented APIs and release-dependent lock-state caveat.

## Controls and the 3.5-day workflow

- **Start… / Pause immediately**: explicit recording intent. **REC** + filled recording symbol means eligible collection; **WAIT** + pause symbol means enabled but excluded/sleep/locked/unknown context; **OFF** + pause symbol means stopped. Menu names the reason, elapsed/remaining hours, active versus excluded/other duration and actionable failures.
- **Capture typed characters**: separate opt-in, OFF by default. Timing-only works independently. Stores available event characters only in supported editor contexts, with shortcuts/non-ASCII-capable input sources suppressed. These are observed key events, not final document text. No pasteboard, background document reads or final-text reconstruction.
- **Window titles** and **mouse motion ≤10 samples/sec**: separate opt-ins. Click positions/button holds and scroll are included in basic collection; motion is optional.
- **Collection hours**: defaults to **84 elapsed hours** (3.5 days), configurable 0.01–336. The continuous clock includes sleep and manual pauses. Actual eligible active time is reported separately from sleep, excluded, unsupported and paused periods in the manifest. Eligibility is sampled at approximately 1s plus events/notifications; it is not proof of loss-free delivery. The app auto-pauses at expiry, including after waking past the deadline; starting after expiry creates a new window/session. Quitting ends capture; reopening always starts OFF and a new collection session. A continuous 84-hour process run has not been tested.
- **Exclude apps by bundle ID**: add exclusions, one per line. Built-in exclusions cannot be overridden and unsupported apps cannot be enabled. Settings/text/title/motion changes pause and require Start to resume.
- **Launch at login**: explicit SMAppService opt-in, starts the app **OFF**. Install in `/Applications` first. If approval is needed, System Settings → General → Login Items & Extensions. Toggle off to unregister. No helper/watchdog/hidden persistence.

For your personal collection later: qualify supported contexts, keep default 84 hours (or set your choice), choose text capture if wanted, configure exclusions, then press Start yourself. Keep app running. Lock/sleep pauses eligible collection; wake/unlock can resume only the already-enabled process, with WAIT/REC visible and only within the deadline. Check status/storage periodically. At 84 hours it pauses; export before retention expires. The 256 MiB cap may stop collection earlier during heavy input or motion.

## Files, export, delete

Data: `~/Library/Application Support/PatternRecorder/`, outside Git, mode 0700; JSONL segments/manifests mode 0600. Rotation 8 MiB, cap 256 MiB, retention 14 days by modification time on store open and every minute while app runs, including OFF/paused. No automatic maintenance when app is quit. No encryption is added beyond OS/account protections; consider FileVault and backups.

**Open data folder** opens that directory (or explains no data exists). **Export timing-only / redacted** pauses and removes characters, titles, app IDs, key codes, modifiers, layout and coordinates; patterns/scroll can remain identifying. **Export full recordings** pauses and warns about sensitive text. Both create a new private `.export` folder at your chosen destination; Git-checkout destinations are rejected. Choose a truly local, non-cloud folder. Existing recordings can be exported while OFF after relaunch. App never uploads anything.

```sh
python3 scripts/summary.py "/path/to/PatternRecorder-UUID.export"
```

Summary reports hold/down intervals, signed flights when physical key identities are available, correction-key rates, eligibility coverage/durations, exclusion boundaries and known dropped-event counts. Unknown losses remain possible. Redacted export omits original manifests and physical identities, so coverage/signed-flight statistics may be unavailable; use the private source folder/full export locally for them. [Schema and units](docs/SCHEMA.md), [privacy/storage policy](docs/PRIVACY.md).

**Delete all recordings** pauses and confirms deletion of app-managed recordings/manifests. Exported copies/backups/APFS snapshots must be removed separately; deletion is not secure SSD erasure. Quit stops capture immediately. Uninstall: quit, turn off launch-at-login, delete the app; use Delete first if you also want local data removed.

## Verification and limits

[Verification evidence](docs/VERIFICATION.md) distinguishes deterministic synthetic tests from owner-only native qualification. Tests cover OFF/Start/Pause, failure-stop, simulated permission/secure/exclusion/sleep/lock contexts, timing/repeats/modifiers/overlap, deadline, rotation/cap, owner modes, retention, export/redaction, symlinks/Git refusal and deletion. Independent agent reviewed correctness/local-data handling; confirmed issues were fixed before merge.

No real input collection, permission consent, protected-field/lock test or multi-day collection is claimed. Event taps can drop/coalesce events; a disabled tap pauses rather than silently recovering. Layouts, dead keys, IME/composition, shortcuts, repeats, synthetic input, missing key-ups and app restrictions limit observed coverage. Clearly process-sourced synthetic events and missing/mismatched targets are rejected; synthetic detection is not universal. Partial JSONL after crash/disk-full can require local repair before strict export/summary succeeds. Live AX/TCC/WindowServer overhead remains to be measured by the owner; synthetic core results do not prove native latency.

## Repository layout

`Sources/RecorderCore` contains state/timing/private storage; `Sources/PatternRecorder` contains AppKit/status item and macOS safety gates; `Tests` uses synthetic events only; `scripts` builds/signs, verifies, summarizes and audits; `docs` contains privacy/schema/API/owner checks; `fixtures` contains labeled synthetic JSONL; `.github` runs hosted synthetic checks. MIT licensed. Public tracked files/history are inspected before pushes; never commit recordings, exports, text-bearing logs or secrets.
