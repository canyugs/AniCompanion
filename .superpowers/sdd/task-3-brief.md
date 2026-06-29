# Task 3: Settings UI + AppState wiring

Add a toggle and endpoint field in Settings so the user can enable Tier-2 and point it at their VTuber adapter. Wire `AppState` to create and pass the `AgentStateWSClient` into `ConversationController`.

## Global Constraints

- Swift 6.0, macOS 15.0+ deployment target
- Strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`)
- No SPM packages — URLSessionWebSocketTask is Foundation
- New Swift files go under `AniCompanion/` subtree (auto-included by `project.yml`'s glob)
- After adding files, run `xcodegen generate` from repo root to update the `.xcodeproj`

## Files

- Modify: `AniCompanion/App/AppState.swift`
- Modify: `AniCompanion/Views/SettingsView.swift`

## Interfaces

- Consumes: `AgentStateWSClient(endpoint:token:)`, `ConversationController.agentStateClient`, `ConversationController.startAgentStateListener()`
- Produces: `AppState.tier2Enabled: Bool` (`@AppStorage`), `AppState.tier2Endpoint: String` (`@AppStorage`)

## Steps

- [ ] **Step 1: Add @AppStorage properties to AppState**

In `AppState.swift`, add after the existing `@AppStorage` block (around line 36):

```swift
    /// Whether the Tier-2 VTuber WS side-channel is enabled. Connects to the OpenAB
    /// VTuber Adapter's /v1/vtuber/ws for agent-state push, structured emotions,
    /// and ambient notifications.
    @AppStorage("tier2_ws_enabled") var tier2Enabled: Bool = false

    /// Base URL of the VTuber adapter for Tier-2 WS (e.g. "http://127.0.0.1:9100").
    /// The client appends /v1/vtuber/ws and upgrades to ws://.
    @AppStorage("tier2_ws_endpoint") var tier2Endpoint: String = "http://127.0.0.1:9100"
```

- [ ] **Step 2: Create and wire the WS client in initializeServices()**

In `AppState.initializeServices()`, after `conversationController = controller` (around line 133), add:

```swift
        // Tier-2: agent-state WS side-channel (optional).
        if tier2Enabled {
            let backend = ChatBackend.current
            let wsClient = AgentStateWSClient(
                endpoint: tier2Endpoint,
                token: backend.savedAPIKey()
            )
            controller.agentStateClient = wsClient
            controller.startAgentStateListener()
        }
```

- [ ] **Step 3: Add Tier-2 section to SettingsView**

In `SettingsView.swift`, add local `@State` properties after the existing ones (around line 25):

```swift
    @State private var tier2Enabled: Bool = false
    @State private var tier2Endpoint: String = "http://127.0.0.1:9100"
```

Add a new section after the Voice section (Section 2, around line 158). Insert before the Language section:

```swift
                    // MARK: Section 3: Agent State (Tier-2)

                    SettingsSection(title: "Agent State", icon: "antenna.radiowaves.left.and.right") {
                        VStack(alignment: .leading, spacing: 14) {
                            Toggle("Enable Tier-2 WS", isOn: $tier2Enabled)
                                .toggleStyle(.switch)

                            if tier2Enabled {
                                SettingsField(label: "Adapter Endpoint") {
                                    TextField("http://127.0.0.1:9100", text: $tier2Endpoint)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }

                            Text("Connects to the OpenAB VTuber Adapter for real-time agent state, emotions, and ambient notifications.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
```

In `loadSettings()`, add:

```swift
        tier2Enabled = appState.tier2Enabled
        tier2Endpoint = appState.tier2Endpoint
```

In `saveSettings()`, add before `appState.reinitializeServices()`:

```swift
        appState.tier2Enabled = tier2Enabled
        appState.tier2Endpoint = tier2Endpoint
```

- [ ] **Step 4: Verify it compiles**

Run: `xcodegen generate && xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add AniCompanion/App/AppState.swift AniCompanion/Views/SettingsView.swift
git commit -m "feat: add Tier-2 WS settings (toggle + endpoint) and wire into AppState"
```
