import SwiftUI

// MARK: - MainView

/// The windowed UI: the VRM 3D character on the left (~60% width) and the chat interface on
/// the right (~40% width). Desktop Pet mode is handled entirely in AppKit (`AppDelegate`):
/// it swaps the window to a borderless transparent panel showing the bare WebView, so this
/// view is only ever shown in the normal window. The 🐾 toolbar button (and ⌘⇧D) flips
/// `appState.petMode`, which `AppDelegate` observes.
struct MainView: View {

    @EnvironmentObject private var appState: AppState

    /// Whether the settings sheet is presented.
    @State private var showSettings: Bool = false

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                // MARK: - Left: VRM Character Display
                ThreeVRMRenderView(characterManager: appState.characterManager)
                    .frame(minWidth: 400)
                    .layoutPriority(1)

                Divider()
                    .background(Color.white.opacity(0.1))

                // MARK: - Right: Chat Interface
                if let controller = appState.conversationController {
                    ChatView(
                        conversationController: controller,
                        conversationHistory: appState.conversationHistory
                    )
                    .frame(minWidth: 300, idealWidth: 360)
                } else {
                    VStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Initializing...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 300, idealWidth: 360)
                }
            }
            .frame(minWidth: 900, minHeight: 600)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)),
                        Color(nsColor: NSColor(red: 0.12, green: 0.10, blue: 0.18, alpha: 1.0)),
                        Color(nsColor: NSColor(red: 0.06, green: 0.06, blue: 0.10, alpha: 1.0))
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        appState.petMode.toggle()
                    } label: {
                        Image(systemName: "pawprint.fill")
                    }
                    .help("Desktop Pet Mode (⌘⇧D)")
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                            .overlay(alignment: .topTrailing) {
                                Circle()
                                    .fill(appState.isConnected ? Color.green : Color.red)
                                    .frame(width: 6, height: 6)
                                    .offset(x: 2, y: -2)
                            }
                    }
                    .help(appState.isConnected ? "Connected — Settings" : "Disconnected — Settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(appState)
            }
            .navigationTitle(Text("AI Agent | Xiaoguang", comment: "Window title — character name"))
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Preview

#Preview {
    MainView()
        .environmentObject(AppState())
}
