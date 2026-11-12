# CodingProfessionalAgent-iOS

SwiftUI iOS client for the CodingProfessionalAgent desktop app, built from the design screenshots in `docs/screenshot`.

The app connects directly to the desktop app's built-in Web server and drives it the same way the desktop Web frontend does: projects, conversations, streaming agent output, stopping runs and answering `ask` questions all happen on the desktop.

## Requirements

- Xcode 26 or later
- iOS 26.0 or later (uses Liquid Glass APIs such as `glassEffect`)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Getting Started

```bash
xcodegen generate
open CodingProfessionalAgent.xcodeproj
```

Run `xcodegen generate` again after adding or removing source files.

## Connecting to the Desktop

1. On the desktop, open **Settings → Connections → Web Server**, enable the Web service, set the bind IP to `0.0.0.0` (LAN access) and optionally set a Web access password.
2. In the iOS app, tap the menu button on the home screen to open **Settings**, then **Add Connection**, and fill in the computer's IP, the service port (default `18080`) and the Web access password.

Passwords are stored in the keychain. Each connection can be toggled on and off independently.

## Protocol

The client mirrors `BrowserBridgeClient` in the desktop frontend:

- `GET /api/auth/status` and `POST /api/auth/login` (`cpa_web_session` cookie, handled manually per connection)
- JSON RPC over the `/api/ws` WebSocket (`{ type: "rpc", id, method, args }` → `rpc_result` / `rpc_error`)
- Native events pushed on the same socket (`{ type: "event", event }`)

| Feature | RPC / event |
| --- | --- |
| Projects | `kvstore:get("projects")`, `projects:updated` |
| Conversations | `session:listSessions`, `session:get`, `session:setMeta`, `session:meta-updated`, `session:deleted` |
| Models and defaults | `kvstore:get("cachedModels")`, `kvstore:get("app-state")` |
| Send a message | `session:delegateRun` with `skillReferences` (the desktop hosts the agent run) |
| Attachments (`+` menu: camera, photos, files) | Images go in `session:delegateRun` `images`; files are uploaded with `native:runtimeInfo`, `native:fileExists`, `native:writeFile` to `~/.coding-professional-agent/attachments/<session id>/` and referenced as `@path` |
| Sent images | Image blocks of user entries (`session:get`, `user-entry` stream events) are shown as thumbnails above the prompt; tapping one opens Quick Look |
| Skills (`$` menu) | `native:runtimeInfo`, `native:readDir`, `native:readFileIfExists` (same folders as the desktop Web composer) |
| `/` commands (fast mode, model) | `session:setMeta` (`speed`, `modelId`, `reasoningEffort`) |
| Streaming | `session:stream-event`, `session:run-status`, `session:entries-updated`, `session:getActiveRuns` |
| Stop | `session:abortRun` |
| Branches | `native:runProcess` (`git branch`) |
| Ask tool | `ask:getRequests`, `ask:submitAnswer` |

## Project Structure

```
CodingProfessionalAgent/
├── App/            # App entry point and navigation router
├── Models/         # JSON value, desktop payload models and UI models
├── Services/       # Desktop client (auth, WebSocket RPC, events), connection store, keychain
├── Theme/          # Shared colors
├── Views/
│   ├── Components/ # Composers (chip text view, draft model, "/" and "$" menus, attachments) and shared controls
│   ├── Home/       # Project and thread list
│   ├── Thread/     # Conversation screen, entry rendering and ask sheet
│   ├── NewThread/  # New thread, reasoning slider and advanced settings
│   └── Settings/   # Settings and connection editor (IMG_5449, IMG_5450)
└── Resources/      # Asset catalog and generated Info.plist
```

## Not Yet Implemented

Voice input, search, message feedback / fork and Live Activities are UI placeholders.
