import AppKit

// MARK: - PetDragView
//
// A transparent overlay placed over the character in Desktop Pet mode (added in AppKit by
// `AppDelegate`, on top of the bare WKWebView). Single-click + drag moves the whole window;
// double-click leaves pet mode. `performDrag` works even though a borderless window isn't key.

final class PetDragView: NSView {
    var onExit: (() -> Void)?
    /// Called with a multiplicative scale factor (>1 grows, <1 shrinks). The handler keeps
    /// the aspect ratio and clamps to sane bounds.
    var onScale: ((CGFloat) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onExit?()
        } else {
            window?.performDrag(with: event)
        }
    }

    /// Two-finger / wheel scroll resizes the pet (scroll up = bigger).
    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        // Clamp per-tick so a fast flick doesn't jump the size.
        onScale?(1 + max(-0.08, min(0.08, delta * 0.004)))
    }

    /// Trackpad pinch resizes the pet.
    override func magnify(with event: NSEvent) {
        onScale?(1 + event.magnification)
    }
}
