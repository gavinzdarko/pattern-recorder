# Verification evidence

Environment inspected 2026-10-26: macOS 26.6.1 (25G76), arm64, Xcode 26.2 (17C52), Swift 6.2.3. Tests use fake event records/clocks and disposable private temp directories only. No real event tap was started, no macOS privacy consent was granted, and no real typing/mouse recording or multi-day collection was performed. The owner app-data directory was confirmed absent after implementation checks.

## Core PR

[PR1](https://github.com/gavinzdarko/pattern-recorder/pull/1), candidate `ef03ec37b7682e631abbc3255f7b1e0219ae9731`: local 10 XCTest cases passed, 0 failures; independent agent rerun 10/10; hosted push and pull_request synthetic jobs passed. [Hosted PR check](https://github.com/gavinzdarko/pattern-recorder/actions/runs/40431362172).

Coverage: OFF emits no input; Start/Pause/immediate shutdown suppress later events; simulated denied/revoked, Secure Input, exclusion, unsupported, sleep and lock contexts; boundary reset; source monotonic timing despite wall changes; repeats/modifiers/overlaps/correction keys; deadline including sleep/manual pauses and late wake; dropped tap and storage failure-stop (including mid-event/boundary); rotation/cap; directory0700/file0600 ownership; retention/deletion; symlink/Git-destination refusal and redaction. These do not exercise actual TCC, editor APIs, field detection or lock transitions.

Independent review found and verified fixes for receipt/source timestamp confusion, AX-subrole error handling, global focus/target PID gating, focus boundaries, incorrect negative gaps, late deadline/reset accounting, continuing writes after storage failure, OFF export/retention, new-window manifests/counters and private temporary-path normalization. Final independent source SHA256 prefixes: Model `73120029ff02156b`, Store `c310a05e24103ee2`, native `2a84d4bcb1808fdd`, tests `d23a2f17b3537494`. [Review record](https://github.com/gavinzdarko/pattern-recorder/pull/1#issuecomment-6431266824). This is independent agent review, not a second human GitHub approval.

## Native app / offline tools

Release `./scripts/build.sh` compiled AppKit/Carbon/ServiceManagement app and passed `codesign --verify --strict` on the ad-hoc bundle. It does not install or launch capture. Full candidate local checks and hosted evidence are recorded in PR2 before merge. Offline fixture summary test verifies 110ms median holds, signed flights −50ms/+230ms (median 90ms), down count and correction rate. Publication audit checks all tracked paths and reachable history blobs; no recordings/build outputs/logs/secrets are intentionally tracked. Human inspection complements heuristic secret patterns.

An OFF-only native UI inspection was attempted through computer use. Tool result: **“Computer Use was not approved to use Pattern Recorder.”** No onscreen icon, menu interaction or native owner action is claimed verified. The owner must open the built app and confirm the right-hand OFF status item; approval is needed to finish that inspection through computer use. Do not substitute screenshots of a browser or claim a GUI check from source inspection.

## Synthetic overhead / growth

Independent 10,000-event core+store run: 2.083s, 208µs/event,2,070,143 bytes (207B/event). Local rerun approximately 2.04s/204µs per event. Debug-build throughput, inline encoding/disk writes and safety state included; **live AX/TCC/WindowServer, hardware delivery and optional title queries excluded**. At an assumed 10 stored events/s, 207B/event projects 7.45MB/hour and 626MB/84h; at 20/s, 14.9MB/hour and 1.25GB/84h. These are extrapolations, not multi-day measurements. The256 MiB cap therefore pauses before 84h under sustained heavy activity; ordinary intermittent use differs. Mouse/text/title sizes increase growth. Motion sample throttle occurs before expensive AX queries and records at most 10Hz.

Manifest callbackCount/TotalNS/MaxNS measure native callback cost when the owner later records; max/mean are latency observations, not hard real-time guarantees. Activity Monitor can assess whole-process CPU/memory/energy during owner synthetic qualification. Live overhead is unmeasured in implementation. Gate polling approximately 1s and event-driven AX calls can add overhead; tap timeout stops collection and indicates possible loss. Unknown OS drops/coalescing cannot be counted exactly.

## Remaining owner qualification

[OWNER-CHECKS](OWNER-CHECKS.md) lists actual bundle signing/install identity, permission deny/revoke/consent, supported editor delivery, secure/protected contexts, lock/sleep/wake, repeated/overlapping input, optional motion and live overhead. No guarantee is made that the public advisory lock dictionary key exists or that arbitrary apps expose safe field semantics. Missing focus/session/target metadata rejects collection. Partial JSONL after interrupted writes requires local repair before strict summary/export. No camera testing is relevant or performed; app has no camera feature.
