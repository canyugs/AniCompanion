# Task 5: Disconnect cleanup in AppState.reinitializeServices() — COMPLETE

## Summary

Successfully added Tier-2 WS client disconnect cleanup to the `reinitializeServices()` method in `AniCompanion/App/AppState.swift`. This ensures that when the user saves settings and services are torn down, any active Tier-2 WebSocket connection is properly disconnected to avoid orphaned connections.

## Changes Made

**File Modified:** `AniCompanion/App/AppState.swift`

**Location:** `reinitializeServices()` method (lines 170-181)

**Code Added** (after `conversationController?.cancel()` and before `chatTransport?.disconnect()`):

```swift
        // Tear down Tier-2 WS.
        if let wsClient = conversationController?.agentStateClient {
            Task { await wsClient.disconnect() }
        }
```

## Verification

- **Build Result:** ✅ BUILD SUCCEEDED
- **Build Command:** `xcodebuild -project AniCompanion.xcodeproj -scheme AniCompanion -destination 'platform=macOS' build`

## Commit

- **Hash:** 84884bb
- **Message:** `fix: disconnect Tier-2 WS client on service reinitialize`
- **Files Changed:** 1 file, 5 insertions(+)

## Status

Task 5 complete. The Tier-2 WebSocket client is now properly cleaned up during service reinitialization, preventing orphaned connections when users update settings.
