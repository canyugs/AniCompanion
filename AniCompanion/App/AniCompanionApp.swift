import SwiftUI

@main
struct AniCompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The main window is created in AppDelegate (so we own its NSWindow for pet mode).
        // This scene provides the Settings (⌘,) window and the menu commands.
        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
        }
        .commands {
            CommandMenu("Character") {
                Button("Desktop Pet Mode") {
                    appDelegate.appState.petMode.toggle()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}
