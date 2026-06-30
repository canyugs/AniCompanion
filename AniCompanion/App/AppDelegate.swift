import SwiftUI
import AppKit
import WebKit
import Combine

// MARK: - PetPanelWindow
//
// A window that can still become key/main once it's borderless (a stock borderless NSWindow
// returns false for both, which silently kills keyboard focus and makes it look "dead").

final class PetPanelWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - AppDelegate
//
// We create the main window ourselves so we fully own its NSWindow. Desktop Pet mode swaps
// the window between two states:
//   • Windowed: an NSHostingController hosting MainView (character + chat).
//   • Pet:      borderless + transparent, with the *bare* WKWebView as the contentView.
//
// Why the bare webView in pet mode: the character's WebGL canvas is genuinely transparent
// (drawsBackground=false + three.js alpha:true + transparent HTML), so putting it directly
// in a borderless `isOpaque=false` window lets the desktop show through. Routing it through
// SwiftUI instead reintroduces two opaque layers — the NSHostingController backing layer and
// ThreeVRMRenderView's RadialGradient — which is what blocked transparency before.
//
// The same WKWebView instance is reused the whole time (ThreeVRMWebView.makeNSView returns
// `characterManager.webView` if it exists), so toggling never reloads the model.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let appState = AppState()

    private(set) var mainWindow: NSWindow?
    private var petCancellable: AnyCancellable?
    private var isPetActive = false

    private static let basePetSize = NSSize(width: 320, height: 540)
    private static let windowedSize = NSSize(width: 1000, height: 650)

    /// Current pet size — persists across toggles so a resized pet stays that size.
    private var currentPetSize = AppDelegate.basePetSize

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState.initializeServices()

        let window = PetPanelWindow(contentViewController: makeWindowedController())
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(Self.windowedSize)
        window.isReleasedWhenClosed = false
        window.title = String(localized: "AI Agent | Xiaoguang", comment: "Window title — character name")
        window.center()
        window.makeKeyAndOrderFront(nil)
        mainWindow = window

        // Drive the window's pet/normal state directly off the shared flag. Guarding on a
        // tracked bool (not the style mask) avoids the `.contains(.borderless)` tautology and
        // skips the launch-time `petMode == false` emission.
        petCancellable = appState.$petMode
            .receive(on: RunLoop.main)
            .sink { [weak self] petMode in
                guard let self, let window = self.mainWindow, petMode != self.isPetActive else { return }
                self.isPetActive = petMode
                petMode ? self.enterPet(window) : self.exitPet(window)
            }
    }

    private func makeWindowedController() -> NSViewController {
        let controller = NSHostingController(rootView: MainView().environmentObject(appState))
        // Bridge SwiftUI's `.toolbar` (the 🐾 + ⚙️ buttons) and `.navigationTitle` into our
        // AppKit-owned window. Without this a hand-created NSHostingController shows no toolbar,
        // and the fresh controller made on exiting pet mode would come back bare.
        controller.sceneBridgingOptions = [.title, .toolbars]
        return controller
    }

    // MARK: - Pet mode

    private func enterPet(_ window: NSWindow) {
        guard let webView = appState.characterManager.webView else {
            // Character not loaded yet — make the toggle a graceful no-op.
            isPetActive = false
            appState.petMode = false
            return
        }

        appState.characterManager.petModeActive = true   // enable the speech bubble

        window.styleMask = [.borderless]                 // full assignment drops .titled
        window.hasShadow = false                         // also avoids a 1px stroke on Tahoe
        window.level = .floating                         // always on top
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false                          // both load-bearing
        window.backgroundColor = .clear

        // Detach the SwiftUI host and the webView.
        window.contentViewController = nil
        webView.removeFromSuperview()

        // Resize the window to the pet size FIRST, so the content is built at the final size
        // (building large then shrinking confuses autoresizing and leaves the webView the
        // wrong size, which is what zoomed the camera onto the legs).
        var f = window.frame
        f.origin.y += f.height - currentPetSize.height
        f.size = currentPetSize
        window.setFrame(f, display: true)

        // Bare transparent webView (+ drag overlay) as the content, sized to fill.
        let bounds = NSRect(origin: .zero, size: currentPetSize)
        let container = NSView(frame: bounds)
        container.wantsLayer = true
        container.layer?.isOpaque = false
        container.layer?.backgroundColor = NSColor.clear.cgColor

        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let drag = PetDragView(frame: bounds)
        drag.onExit = { [weak self] in self?.appState.petMode = false }
        drag.onScale = { [weak self] factor in self?.scalePet(by: factor) }
        drag.autoresizingMask = [.width, .height]
        container.addSubview(drag)                        // on top: drag moves, double-click exits, scroll/pinch resizes

        window.contentView = container
        window.makeKeyAndOrderFront(nil)                  // must re-key after the mask change

        // The WebGL scene re-fits on the JS 'resize' event, which isn't guaranteed to fire on
        // an AppKit reparent — dispatch it explicitly so three.js re-frames the full character.
        refitScene(webView)
    }

    private func exitPet(_ window: NSWindow) {
        appState.characterManager.setSpeechText(nil)      // hide bubble (while still active)
        appState.characterManager.petModeActive = false

        let webView = appState.characterManager.webView
        webView?.removeFromSuperview()
        window.contentView = nil
        // A FRESH host re-mounts MainView, whose ThreeVRMRenderView reuses the same webView
        // (no reload). Chat history etc. live in AppState, so nothing is lost.
        window.contentViewController = makeWindowedController()

        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.hasShadow = true
        window.level = .normal
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.fullScreenPrimary]

        var f = window.frame
        f.size = Self.windowedSize
        window.setFrame(f, display: true)
        window.center()
        window.makeKeyAndOrderFront(nil)

        // Re-fit after SwiftUI has laid the webView back out at the windowed size.
        if let webView { refitScene(webView) }
    }

    /// Force the three.js scene to re-read its size and re-frame the camera.
    private func refitScene(_ webView: WKWebView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            webView.evaluateJavaScript("window.dispatchEvent(new Event('resize'))", completionHandler: nil)
        }
    }

    /// Resize the pet by `factor`, keeping the aspect ratio and anchoring her feet (so she
    /// grows/shrinks in place). The WebView autoresizes and three.js re-frames automatically.
    private func scalePet(by factor: CGFloat) {
        guard isPetActive, let window = mainWindow else { return }
        let ratio = Self.basePetSize.width / Self.basePetSize.height
        let minHeight: CGFloat = 280
        let maxHeight: CGFloat = 1100
        let height = min(max(currentPetSize.height * factor, minHeight), maxHeight)
        currentPetSize = NSSize(width: height * ratio, height: height)

        var f = window.frame
        let centerX = f.midX
        let bottomY = f.minY                 // keep her feet planted
        f.size = currentPetSize
        f.origin.x = centerX - currentPetSize.width / 2
        f.origin.y = bottomY
        window.setFrame(f, display: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
