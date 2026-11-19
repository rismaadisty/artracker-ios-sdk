# People / User Identity — iOS SDK Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Repo:** `artracker-ios-sdk` (branch from `main` @ `e7a00db`)

**Goal:** Bring the iOS SDK to parity with Android on the shared People wire contract:
- `identify(userId:traits:)` + `reset()`;
- a persisted user id (`UserDefaults` key: `artracker.user_id`);
- a `session_start` carrying device context for **every** session;
- replay chunks stamped with the session and user that recorded them.

**Architecture & Context (Post-PR #2 / `e7a00db`):**
- Event names are strictly **`session_start`** and **`session_end`** (aligned with Android wire contract).
- Today iOS has only `setUser(id:)`. It is memory-only, has no traits, no rotation, and no user-profile event.
- `session_start` currently only has `session_id` and optional `launch_type: "cold"`. Sessions created by idle rotation or 24h cap do not have device context attributes.
- `SessionManager` already has a thread-safe `SessionLifecycleListener` (`sessionDidStart(id:)` / `sessionDidEnd(id:durationMs:)`). Pure reads on `sessionId` intentionally do not rotate idle sessions; rotation occurs upon `recordUserActivity()`, `onForeground()`, `rotateSession()`, 24h cap, or idle timeout re-check.
- Replay chunks already capture `sessionId` on `ReplayQueueItem` and reset sequence numbers per session, but `userId` is still dynamically read at upload time (`ReplayChunkManager.swift:295`).
- This plan adds:
  - an internal, thread-safe `IdentityController` that implements `SessionLifecycleListener` and manages `identify` / `reset` / `session_start` / `session_end` emission and pre-Phase-B buffering;
  - `UserDefaults` persistence of `userId` in `SessionManager`;
  - `userId` captured on `ReplayQueueItem` and buffered in `ReplayChunkManager` when frames/touches are recorded;
  - full device context enrichment in `session_start`.

**Tech Stack:** Swift 5.9 (SPM, `swift-tools-version 5.9`), iOS 15+/macOS 12+, XCTest (`ARTrackerTests`). Tests run with `swift test`.

**Spec:** `artracker` repo `docs/superpowers/specs/2026-11-17-people-user-profiles-design.md`. See "Wire contract" §1–§3.

---

## Global Constraints

- **Public API added:**
  - `ARTracker.identify(userId: String, traits: [String: Any] = [:])`;
  - `ARTracker.reset()`.
- **`setUser(id:)` stays, marked `@available(*, deprecated, message: "Use identify(userId:traits:) / reset()")`:**
  - `setUser(id: "x")` → `identify(userId: "x")`;
  - `setUser(id: nil)` → `reset()`.
- **Identify event item:**
  - `Item(type: .event, name: "$identify", sessionId: <session>, userId: <user>, attributes: <traits>)`, with flat traits.
- **Trait limits & sanitization (`TraitSanitizer`):**
  - Validation order: filter sensitive keys, filter invalid keys, drop unsupported value types, drop non-finite doubles (`nan`, `infinity`).
  - Key length: 1–64 characters; empty keys or keys > 64 chars are dropped.
  - Allowed values: `String` (truncated to ≤ 256 chars), `Bool`, `Int`/`Int64`/finite `Double`/`NSNumber`, `NSNull` (mapped to `JSONValue.null`).
  - Unsupported values (e.g. `Date`, `[Any]`, `[String: Any]`, non-finite numbers) are dropped.
  - Bridged bools in `NSNumber`: check `CFGetTypeID(n) == CFBooleanGetTypeID()` before treating as a number.
  - Keys matching regex `(?i)(pass(word)?|secret|token|api[_-]?key|authorization|cookie|card|cvv|pin|nik|ssn)` are dropped.
  - Cap at **50 keys** after filtering, selected by sorted key order (`keys.sorted().prefix(50)`).
  - Blank `userId` (empty or whitespace-only) is ignored with `Log.warn`. Valid `userId` is trimmed of leading/trailing whitespace.
- **User-switch semantics:**
  - **anonymous → A:** keep existing session; emit `$identify` with user A and current session id.
  - **A → A with identical traits:** no-op (no event emitted).
  - **A → A with changed traits:** emit `$identify` with user A and updated traits.
  - **A → B:** emit `session_end` with user A; update `userId = B` (persisted); rotate session; emit `session_start` with user B; emit `$identify` with user B.
  - **`reset()` (A → anonymous):** emit `session_end` with user A; clear user id (`userId = nil`, remove from defaults); rotate session; emit `session_start` with anonymous user (`userId = nil`).
- **`session_start` event attributes:**
  - Name: **`session_start`** (type: `.session`).
  - Existing attributes: `session_id` and optional `launch_type` (`"cold"` on first launch, `"rotation"` on automatic/manual rotation).
  - Added device context:
    - `platform: "ios"`;
    - `os_version`: formatted `major.minor.patch` (or `major.minor`) from thread-safe `ProcessInfo.processInfo.operatingSystemVersion` (avoid `@MainActor` `UIDevice.current.systemVersion`);
    - `manufacturer: "Apple"`;
    - `model`: device identifier from `utsname` (e.g. `iPhone15,3`);
    - `app_version`: `CFBundleShortVersionString` (fallback `"1.0.0"` in unit tests);
    - `app_build`: `CFBundleVersion` (fallback `"1"` in unit tests);
    - `locale`: BCP-47 identifier (`Locale.current.identifier` with `_` replaced by `-`);
    - `tz`: `TimeZone.current.identifier`;
    - `network`: `Reachability.shared.interfaceKind` or `"unknown"`;
    - `is_emulator`: `#if targetEnvironment(simulator) true #else false #endif`;
    - `sdk_version`: `SDKInfo.current.version`.
- **Persistence & Buffering:**
  - Persist `userId` in `UserDefaults` under key `artracker.user_id`. Traits remain in memory only.
  - If `identify`/`reset` or session events occur before Phase B (`_diskQueue` ready), buffer items in a thread-safe in-memory queue within `IdentityController` and drain to `_diskQueue` once Phase B finishes.
- **Version bump:**
  - Bump `SDKInfo.current` to version `0.2.0`, and HTTP `User-Agent` to `artracker-ios/0.2.0`.

---

## Review Focus

1. **A session after 30 minutes idle.** When idle timeout elapses and user activity occurs (`recordUserActivity()`), the rotated session must emit its own `session_start` with device context, and exactly one, even when multiple threads record activity concurrently.
2. **App killed and relaunched while logged in.** The first `session_start` on relaunch must carry the persisted user id before the host application calls `identify` again.
3. **Replay chunk offline attribution.** A chunk recorded under user A and uploaded after switching to user B must be requested and acknowledged with user A's id and session id. A chunk recorded anonymously (`userId == nil`) must NOT fall back to user B upon upload.
4. **Objective-C & bridged scalar traits.** `NSNumber(value: true)` becomes `.bool(true)`, `NSNumber(value: 3)` becomes `.number(3)`. `Date`, nested dictionaries, arrays, and `Double.nan` must be dropped.
5. **Thread safety & pre-Phase B invocation.** `identify` called on background threads or before/during `configurePhaseB` must not crash, must not drop items, and must preserve the strict event ordering: `session_end` (A) → `session_start` (B) → `$identify` (B).

---

## File Structure

| File (under `Sources/ARTracker/`) | Change |
|---|---|
| `Core/TraitSanitizer.swift` | **new**: `enum TraitSanitizer { static func sanitize(_ traits: [String: Any]) -> [String: JSONValue] }` |
| `Core/SessionContext.swift` | **new**: `enum SessionContext { static func startAttributes(config: ARTrackerConfig?, launchType: String?, sessionId: String) -> [String: JSONValue] }` |
| `Core/IdentityController.swift` | **new**: `final class IdentityController: SessionLifecycleListener, @unchecked Sendable` managing identify, reset, lifecycle emission, and Phase B drain |
| `Core/SessionManager.swift` | `UserDefaults` persistence of `userId` (`artracker.user_id`) on get/set and restore |
| `Public/ARTracker.swift` | Holds `identity: IdentityController`; adds public `identify`/`reset`; deprecates `setUser`; routes session lifecycle to `identity` |
| `Replay/ReplayDiskQueue.swift` | Adds `userId: String?` to `ReplayQueueItem` (with optional decoding for backwards compatibility) |
| `Replay/ReplayChunkManager.swift` | Buffers `currentChunkUserId`; stamps `userId` on sealed `ReplayQueueItem`; uploads using `queueItem.userId` without fallback to current user |
| `Core/Envelope.swift`, `Storage/Uploader.swift`, `README.md` | Bump version to `0.2.0`; document `identify`/`reset` API |

---

### Task 1: `TraitSanitizer` + `SessionContext.startAttributes`

**Files:**
- Create: `Sources/ARTracker/Core/TraitSanitizer.swift`, `Sources/ARTracker/Core/SessionContext.swift`
- Test: `Tests/ARTrackerTests/TraitSanitizerTests.swift`, `Tests/ARTrackerTests/SessionContextTests.swift`

**Interfaces:**
- Consumes:
  - `JSONValue` (`Core/JSONValue.swift`);
  - `Reachability.shared.interfaceKind` (`Support/Reachability.swift`);
  - `SDKInfo.current` (`Core/Envelope.swift`).
- Produces:
  ```swift
  public enum TraitSanitizer {
      public static let maxKeys = 50
      public static let maxKeyLength = 64
      public static let maxValueLength = 256
      public static func sanitize(_ traits: [String: Any]) -> [String: JSONValue]
  }

  public enum SessionContext {
      public static func startAttributes(
          config: ARTrackerConfig? = nil,
          launchType: String? = nil,
          sessionId: String
      ) -> [String: JSONValue]
  }
  ```

- [ ] **Step 1: Write failing tests**
  - `TraitSanitizerTests`:
    - `testKeysCappedAt50SortedOrder`: 60 valid keys -> exactly 50 alphabetically first keys retained.
    - `testLongKeyAndEmptyKeyDropped`: empty string `""` and keys > 64 characters are dropped.
    - `testStringTruncatedTo256`: strings longer than 256 characters truncated to 256.
    - `testSensitiveKeysDropped`: `password`, `apiKey`, `API_KEY`, `secret_token`, `card_number`, `pin`, `cvv` dropped; `plan`, `role` kept.
    - `testNSNumberBoolAndNonScalars`:
      - `NSNumber(value: true)` → `.bool(true)`;
      - `NSNumber(value: 42)` → `.number(42)`;
      - `Double.nan` and `Double.infinity` dropped;
      - `Date()`, `[1, 2]`, `["k": "v"]` dropped;
      - `NSNull()` → `.null`.
  - `SessionContextTests`:
    - `testStartAttributesContainContractKeys`: verifies keys contain `["platform", "os_version", "manufacturer", "model", "app_version", "app_build", "locale", "tz", "network", "is_emulator", "sdk_version", "session_id"]`, with `platform == .string("ios")`.
    - `testOsVersionIsNumeric`: matches `^\d+(\.\d+){1,2}$`.
    - `testLocaleIsBCP47`: contains no `_` (e.g. `en-US` instead of `en_US`).
    - `testLaunchTypePreservedIfProvided`: attributes contain `launch_type` when passed.

- [ ] **Step 2: Run tests and confirm failure**
  Run `swift test --filter 'TraitSanitizerTests|SessionContextTests'`.

- [ ] **Step 3: Implement `TraitSanitizer` and `SessionContext`**
  - In `TraitSanitizer`: check `CFGetTypeID(val as CFTypeRef) == CFBooleanGetTypeID()` for `NSNumber` boolean conversion. Drop non-finite doubles (`!d.isFinite`). Sort remaining keys and take first 50.
  - In `SessionContext`: format `ProcessInfo.processInfo.operatingSystemVersion` into `major.minor.patch`. Extract machine model from `utsname`. Ensure test bundle compatibility for `app_version`/`app_build`.

- [ ] **Step 4: Run tests and confirm pass, then commit**
  `git commit -m "feat(identity): trait sanitizer and session_start device context"`

---

### Task 2: `IdentityController` & `SessionManager` Persistence

**Files:**
- Create: `Sources/ARTracker/Core/IdentityController.swift`
- Modify:
  - `Sources/ARTracker/Core/SessionManager.swift`
  - `Sources/ARTracker/Public/ARTracker.swift`
- Test: `Tests/ARTrackerTests/IdentityControllerTests.swift`, `Tests/ARTrackerTests/SessionManagerTests.swift`

**Interfaces:**
- Consumes: `TraitSanitizer`, `SessionContext`, `SessionLifecycleListener`, `CrashContextStore`.
- Produces:
  ```swift
  // SessionManager
  public var userId: String? { get set } // Persisted in UserDefaults["artracker.user_id"]

  // IdentityController
  final class IdentityController: SessionLifecycleListener, @unchecked Sendable {
      init(
          session: SessionManager,
          defaults: UserDefaults = .standard,
          crashContext: CrashContextStore = .shared,
          emit: @escaping @Sendable (Item) -> Void
      )
      func identify(userId: String, traits: [String: Any])
      func reset()
      func sessionDidStart(id: String)
      func sessionDidEnd(id: String, durationMs: Double)
      func attachQueue(_ queue: DiskQueue) // Drains pre-Phase-B buffered items
  }

  // ARTracker Public API
  public static func identify(userId: String, traits: [String: Any] = [:])
  public static func reset()
  @available(*, deprecated, message: "Use identify(userId:traits:) / reset()")
  public static func setUser(id: String?)
  ```

- [ ] **Step 1: Write failing tests**
  - `IdentityControllerTests` (using mock `emit`, isolated `UserDefaults(suiteName:)`):
    - `testIdentifyFromAnonymousKeepsSession`: emits no `session_end`; emits `$identify` with user A and same session id.
    - `testUserSwitchOrder`: switching from user A to user B emits:
      1. `session_end` with user A and old session id;
      2. `session_start` with user B, new session id, and device attributes;
      3. `$identify` with user B, new session id, and traits.
    - `testSameUserSameTraitsEmitsOnce`: repeated calls with identical userId & traits do not emit duplicate `$identify`.
    - `testResetRotatesAndClears`:
      - emits `session_end` with user A;
      - clears user in defaults (`defaults.string(forKey: "artracker.user_id") == nil`);
      - rotates session;
      - emits `session_start` with `userId == nil`.
    - `testIdleRotationEmitsSessionStartWithDeviceContext`:
      - trigger `sessionDidStart` via rotation;
      - verifies exactly one `session_start` emitted containing `model`, `platform`, `sdk_version`.
    - `testPersistedUserStampsFirstSessionStart`:
      - initialize with `artracker.user_id = "user_persisted"` in defaults;
      - `sessionDidStart` emits `session_start` with `userId == "user_persisted"`.
    - `testPrePhaseBBufferingDrainsToDiskQueue`:
      - call `identify` and `sessionDidStart` before `attachQueue`;
      - confirm items are buffered and then drained in FIFO order to `DiskQueue`.
  - `SessionManagerTests`:
    - `testUserIdPersistedToUserDefaults`: setting `userId` stores to defaults; restoring loads it; setting `nil` removes it.

- [ ] **Step 2: Run tests and confirm failure**
  Run `swift test --filter 'IdentityControllerTests|SessionManagerTests'`.

- [ ] **Step 3: Implement `IdentityController` & wire into `ARTracker`**
  - In `SessionManager.swift`: load stored `artracker.user_id` in `init`; persist on `userId` setter.
  - In `IdentityController.swift`:
    - Implement thread-safe synchronization (`UnfairLock`).
    - Track `lastIdentifiedUserId` and `lastIdentifiedTraits` to deduplicate identical identify calls.
    - Implement `sessionDidStart` and `sessionDidEnd` to emit `session_start` (with `SessionContext`) and `session_end`.
    - Handle user switch: emit `session_end` (with old user), update `session.userId = newId` (and crash context), call `session.rotateSession()`, and emit `session_start` and `$identify`.
    - Maintain an internal `[Item]` buffer when queue is not attached, drained atomically on `attachQueue`.
  - In `ARTracker.swift`:
    - Initialize `IdentityController` in Phase A.
    - In Phase B, call `identity.attachQueue(queue)` and register `SessionManager.shared.listener = identity`.
    - Route `ARTracker.identify`, `ARTracker.reset`, and deprecated `ARTracker.setUser` to `identity`.

- [ ] **Step 4: Run full test suite and confirm pass, then commit**
  Run `swift test`.
  `git commit -m "feat(identity): identify/reset, persisted user id, session_start device context"`

---

### Task 3: Replay Chunks Carry Recorded User Attribution

**Files:**
- Modify:
  - `Sources/ARTracker/Replay/ReplayDiskQueue.swift`
  - `Sources/ARTracker/Replay/ReplayChunkManager.swift`
- Test: `Tests/ARTrackerTests/ReplayChunkUserTests.swift`, `Tests/ARTrackerTests/ReplayTests.swift`

**Interfaces:**
- `ReplayQueueItem`: add `public let userId: String?`. Decoded with `decodeIfPresent` for backward compatibility with legacy disk chunks.
- `ReplayChunkManager`:
  - Track `currentChunkUserId: String?`. When frames or touches are appended, record `SessionManager.shared.userId`.
  - If `userId` changes while buffer is non-empty, trigger a chunk flush to avoid mixing users in one chunk.
  - In `processPendingUploads`: pass `queueItem.userId` directly to `uploader.requestChunkUrl`. Do NOT fall back to current `SessionManager.shared.userId`.

- [ ] **Step 1: Write failing tests**
  - `testChunkUploadsWithSealTimeUser`:
    - Seal chunk under session S1 and user A.
    - Switch user to B and session S2.
    - Verify `requestChunkUrl` receives `userId: "A"` and `sessionId: S1`.
  - `testAnonymousChunkUploadsWithNilUser`:
    - Seal chunk while anonymous (`userId: nil`).
    - Switch user to "user_logged_in".
    - Verify `requestChunkUrl` receives `userId: nil` (no fallback).
  - `testLegacyChunkDecodesWithNilUser`:
    - Decode JSON without `user_id` into `ReplayQueueItem` -> `userId == nil`.

- [ ] **Step 2: Run tests and confirm failure**
  Run `swift test --filter 'ReplayChunkUserTests|ReplayTests'`.

- [ ] **Step 3: Implement Replay user stamping**
  - Add `userId: String? = nil` to `ReplayQueueItem` initializer and CodingKeys.
  - In `ReplayChunkManager`: record `currentChunkUserId = SessionManager.shared.userId`. Flush existing buffer when `currentChunkUserId` mismatches active user.
  - Stamp `userId: chunkUser` on `ReplayQueueItem` at seal time.
  - In `processPendingUploads`: use `let userId = queueItem.userId` when calling `uploader.requestChunkUrl`.

- [ ] **Step 4: Run full test suite and confirm pass, then commit**
  Run `swift test`.
  `git commit -m "fix(replay): stamp chunks with recorded user id without upload fallback"`

---

### Task 4: Golden JSON, Documentation & Version Bump

**Files:**
- Modify:
  - `Sources/ARTracker/Core/Envelope.swift` (`SDKInfo.current` -> `0.2.0`)
  - `Sources/ARTracker/Storage/Uploader.swift` (`User-Agent: artracker-ios/0.2.0`)
  - `README.md` (Update installation, identify/reset documentation, limits, deprecations)
- Test: `Tests/ARTrackerTests/GoldenJSONTests.swift`

- [ ] **Step 1: Add golden test for `$identify` and enriched `session_start`**
  - `testIdentifyItemGoldenJSON`:
    - `Item(type: .event, name: "$identify", sessionId: "ses_1", userId: "u_1", attributes: ["plan": .string("pro")])` encodes to expected wire JSON.
  - `testSessionStartDeviceContextGoldenJSON`:
    - Verifies JSON structure contains `platform`, `model`, `app_version`, `app_build`, `locale`, `os_version`.

- [ ] **Step 2: Update README and bump versions**
  - Bump SDK version to `0.2.0` in `Envelope.swift` and `Uploader.swift`.
  - Update `README.md`:
    - Replace `setUser` section with `identify(userId:traits:)` and `reset()`.
    - Document trait limits (50 keys, key lengths, disallowed keys, string limits).
    - Note `setUser` deprecation.

- [ ] **Step 3: Run full test suite and confirm pass**
  Run `swift test`.

- [ ] **Step 4: Commit**
  `git commit -m "docs: document identify/reset and release version 0.2.0"`
