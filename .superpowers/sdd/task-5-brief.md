# Task 5: Disconnect cleanup in AppState.reinitializeServices()

When the user saves settings, `reinitializeServices()` tears down everything. It must also disconnect the Tier-2 WS client to avoid orphaned connections.

## Global Constraints

- Swift 6.0, macOS 15.0+ deployment target
- Strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`)
- No SPM packages — URLSessionWebSocketTask is Foundation
- New Swift files go under `AniCompanion/` subtree (auto-included by `project.yml`'s glob)
- After adding files, run `xcodegen generate` from repo root to update the `.xcodeproj`

## Files

- Modify: `AniCompanion/App/AppState.swift`

## Interfaces

- Consumes: `AgentStateWSClient.disconnect()`, `ConversationController.agentStateClient`
- Produces: clean teardown on reinitialize

## Steps

- [ ] **Step 1: Disconnect WS client before reinitialize**

In `reinitializeServices()`, after `conversationController?.cancel()` and before `chatTransport?.disconnect()`, add:

```swift
        // Tear down Tier-2 WS.
        if let wsClient = conversationController?.agentStateClient {
            Task { await wsClient.disconnect() }
        }
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add AniCompanion/App/AppState.swift
git commit -m "fix: disconnect Tier-2 WS client on service reinitialize"
```
