# CodingProfessionalAgent-iOS

Native SwiftUI iOS client for the `CodingProfessionalAgent` (CPA) desktop application. All projects, sessions, agent runs, tool executions, and `ask` interactions execute on the desktop; the iOS app mirrors the desktop Web frontend protocol over direct LAN HTTP/WebSocket or multiplexed CLIProxyAPI Tunnel connections.

## Stack & Targets

- **Language & Frameworks**: Swift 6.0, SwiftUI, UIKit interop (`UITextView`, `UNUserNotificationCenterDelegate`), Observation (`@Observable`), `OSAllocatedUnfairLock`, `Network`, `Security`, `UserNotifications`, `QuickLook`
- **Minimum Deployment Target**: iOS 26.0 (uses iOS 26 Liquid Glass APIs such as `glassEffect`)
- **Device Support**: iPhone-only (`TARGETED_DEVICE_FAMILY: "1"`, Portrait)
- **Dependencies**: Zero third-party SwiftPM packages (Apple system frameworks only)
- **Xcode Project Generation**: Managed by `project.yml` via XcodeGen (`CodingProfessionalAgent.xcodeproj` is checked into git)
- **Targets**:
  - `CodingProfessionalAgent` (`me.router-for.CodingProfessionalAgent`, display name `CPA`)
  - `CodingProfessionalAgentTests` (`me.router-for.CodingProfessionalAgentTests`, host-injected into `CodingProfessionalAgent.app`)

## Common Commands

```bash
# Regenerate CodingProfessionalAgent.xcodeproj after adding, removing, or moving files or changing project.yml
xcodegen generate

# Verify unsigned generic iOS device build
xcodebuild -scheme CodingProfessionalAgent -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build

# Run full test suite on iOS Simulator (boot simulator first to avoid cold-boot SBMainWorkspace timeouts)
xcrun simctl boot "iPhone 17 Pro" || true
xcrun simctl bootstatus "iPhone 17 Pro" -b
xcodebuild -scheme CodingProfessionalAgent -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGN_IDENTITY=- test
```

## Directory Structure

```text
.
├── project.yml                         # Authoritative XcodeGen specification
├── CodingProfessionalAgent.xcodeproj/  # Generated Xcode project & shared scheme
├── CodingProfessionalAgent/
│   ├── App/
│   │   ├── CodingProfessionalAgentApp.swift # @main App entry & AppDelegate (APNs + notification delegate)
│   │   └── Router.swift                     # Route enum, Router navigation state, NavigationLayout helpers
│   ├── Models/
│   │   ├── JSONValue.swift                  # Untyped JSON enum for RPC args/results and stream events
│   │   ├── Models.swift                     # DesktopConnection, ConnectionMode, PreferenceKey, UI enums
│   │   └── RemoteModels.swift               # Lenient Decodable models mirrored from desktop payloads
│   ├── Services/
│   │   ├── DesktopClient.swift              # Per-connection auth, /api/ws RPC/events, reconnect, read/unread sync
│   │   ├── ConnectionStore.swift            # Persisted connection list, client ownership, removal cleanup
│   │   ├── TunnelClientManager.swift        # Shared CLIProxyAPI /v1/tunnel session & virtual WS multiplexing
│   │   ├── TunnelProtocol.swift             # Tunnel endpoint parsing, binary frame & mux codecs
│   │   ├── TurnNotificationCoordinator.swift # APNs token registration sync, foreground suppression & deep links
│   │   ├── KeychainStore.swift              # Keychain storage for desktop passwords and tunnel API keys
│   │   ├── Localization.swift               # AppLanguage, LocalizationManager, thread-safe L10n lookup
│   │   ├── CodeHighlighter.swift            # Lightweight regex syntax highlighting
│   │   └── GitDiff.swift                    # Unified git diff parser for review panels
│   ├── Theme/
│   │   └── Theme.swift                      # Display P3 adaptive colors & semantic tokens
│   ├── Views/
│   │   ├── Components/                      # ComposerBar, UTF-16 ComposerDraft, UITextView wrapper, menus, attachments
│   │   ├── Home/                            # Project & thread list, chat search, directory browser, worktree fork
│   │   ├── Thread/                          # ThreadModel, ThreadView, turn/entry/markdown renderers, panels, sub-agents, AskSheet
│   │   ├── NewThread/                       # NewThreadView, ReasoningSlider, AdvancedSettingsSheet
│   │   └── Settings/                        # SettingsView, ConnectionEditorSheet, TunnelConnectionSheet
│   └── Resources/
│       ├── Assets.xcassets/
│       ├── CodingProfessionalAgent.entitlements # aps-environment
│       ├── Info.plist
│       ├── InfoPlist.xcstrings              # Localized Info.plist strings (en, zh-Hans)
│       └── Localizable.xcstrings            # App String Catalog (en development language, zh-Hans)
├── CodingProfessionalAgentTests/            # Unit, mock WebSocket/tunnel integration, and UI layout tests
└── docs/
    ├── screenshot/                          # Design reference screenshots
    └── superpowers/                         # Architecture specs and implementation plans
```

## Architecture & Protocol Contracts

- **Dual Connection Transports**:
  - **Direct (`ConnectionMode.direct`)**: Plain HTTP (`NSAllowsArbitraryLoads: true` for user-provided LAN hosts) auth via `GET /api/auth/status` + `POST /api/auth/login` (`cpa_web_session` cookie managed per connection) and WebSocket RPC/events on `/api/ws`.
  - **Tunnel (`ConnectionMode.tunnel`)**: Connects to a CLIProxyAPI `/v1/tunnel` gateway using a Bearer API key, discovers online CPA desktop servers, and multiplexes HTTP requests and virtual WebSocket streams (`TunnelWebSocketStream`) over `TunnelSession`.
- **Lenient Desktop Payload Decoding**: Keep decoding in `RemoteModels.swift` tolerant (`decodeIfPresent` with safe defaults) so newer desktop versions do not break older iOS clients.
- **UTF-16 Composer Offsets**: `ComposerDraft` and `SkillReference` offsets (`start`, `length`, `cursor`) MUST stay UTF-16 code unit based to match JavaScript string indexing on the desktop.
- **Read/Unread & Directory Pinning Parity**:
  - Within each project directory in `HomeView`, sessions are ordered in three tiers (`running > unread > read`), then by `updatedAt` desc, `createdAt` desc, `id` asc; the collapsed slice expands to avoid hiding running or unread items.
  - Only top-level normal turn completions mark unviewed sessions unread and emit APNs/turn-completion behavior; sub-agent runs, aborted/errored runs, and `/compact` are handled distinctly in `DesktopClient`.
- **APNs Push Notifications**:
  - Turn completion notifications rely on APNs remote push (`aps-environment` in `CodingProfessionalAgent.entitlements`) synchronized with the desktop via `notification:registerClient` and `notification:unregisterClient` RPCs (`TurnNotificationCoordinator`).
  - Do not reintroduce `BGContinuedProcessingTask` or background processing modes for turn monitoring.

## Swift Concurrency, UI & Coding Conventions

- **Indentation & Comments**: Use 4 spaces for Swift indentation. Write all code comments in English.
- **Swift 6 Concurrency & Observation**:
  - State containers (`ConnectionStore`, `DesktopClient`, `TunnelSession`, `Router`, `ThreadModel`, `LocalizationManager`, `TurnNotificationCoordinator`) are `@MainActor`. Annotate non-UI-observed internal tasks, observer tokens, continuations, and timers with `@ObservationIgnored`.
  - Mark cross-actor payloads and enums `Sendable`. Off-main-actor shared state (such as `L10n`) must be synchronized with `OSAllocatedUnfairLock`.
- **UNUserNotificationCenterDelegate Main-Thread Safety**:
  - `NotificationDelegateBridge` MUST implement the explicit completion-handler `UNUserNotificationCenterDelegate` methods (`withCompletionHandler:`) and dispatch both navigation callbacks and UIKit `completionHandler` invocations to the main thread (`MainActor.assumeIsolated` / `DispatchQueue.main.async`). Never replace them with non-isolated Swift `async` witnesses, which execute UIKit completion handlers on cooperative background threads and trigger `SIGABRT`.
- **External Navigation & View Identity**:
  - `Router.openThread(connectionId:sessionId:titleHint:)` replaces `Router.path` inside a non-animated `Transaction` and bumps `externalNavigationRevision` so active sheets/overlays dismiss.
  - Key pushed conversation views (`ThreadContent`, `SubAgentContent`) by connection/session identifiers so replacing `Router.path` in place recreates `ThreadModel` instead of reusing stale view state.
  - Use `TimelineView(.animation(...))` for loading indicators (such as `ConversationLoadingView`) so animations run inside non-animated navigation transitions while respecting `accessibilityReduceMotion`.
  - Keep `ThreadModel`'s `ConnectionGraceConfiguration` intact so transient foreground-wake or reconnect sockets do not immediately flash offline errors while waking `DesktopClient`.
- **Localization (i18n)**:
  - Supported locales are `en` (`developmentLanguage`) and `zh-Hans` (`knownRegions: [en, zh-Hans]`). Traditional Chinese tags (`zh-Hant`, `zh-TW`, `zh-HK`, `zh-MO`) fall back to `en` unless a Simplified Chinese tag follows in `Locale.preferredLanguages`.
  - Route all user-facing copy through `L10n` in `CodingProfessionalAgent/Services/Localization.swift` and add translations for both `en` and `zh-Hans` in `Localizable.xcstrings` (or `InfoPlist.xcstrings`).
  - Views supporting hot language switching should reference `@Environment(\.locale)` and `LocalizationManager.shared.revision`; services caching error descriptions should observe `LocalizationManager.languageDidChangeNotification`.
- **Theme & UI Consistency**:
  - Use adaptive colors from `Theme` (`Theme.accent`, `Theme.online`, `Theme.userBubble`, `Theme.userBubbleText`, `Theme.chipBackground`, `Theme.skillChip`) and native Liquid Glass modifiers instead of hardcoded one-off colors.
- **Credential & Secret Hygiene**:
  - Store passwords and Tunnel API keys exclusively in `KeychainStore`, never in `UserDefaults`. Never log passwords, Tunnel API keys, or APNs device tokens.

## Testing Guidelines

- Add or update tests in `CodingProfessionalAgentTests/` when changing protocol framing, client state machines, localization, notification routing, composer hit-testing, theme contrast, or navigation layout.
- Isolate test persistence with a dedicated `UserDefaults(suiteName:)` cleaned up in `defer`, and initialize `ConnectionStore(..., persistsCredentials: false)` so tests never mutate the host keychain.
- Network integration tests should use local `NWListener` mock HTTP/WebSocket servers rather than external hosts.
- When adding Swift source or test files, run `xcodegen generate` and verify both the simulator test suite (`xcodebuild ... test`) and the generic iOS device build (`xcodebuild -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`).
