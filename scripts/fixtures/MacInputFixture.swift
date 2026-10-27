import AppKit

/// Synthetic-input target only. Standard AppKit controls; no input observer,
/// permission requests, clipboard API, storage, network or secure-input override.
@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Synthetic AppKit input fixture — test markers only"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()

        let heading = NSTextField(labelWithString: "Synthetic input fixture")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString:
            "Use synthetic markers only. This fixture does not record or persist input, use the clipboard, request permissions, or contact a network. Closing the window quits the fixture.")
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor

        let plainLabel = NSTextField(labelWithString: "Plain test field")
        let plain = NSTextField(string: "")
        plain.placeholderString = "Synthetic single-line marker"
        plain.font = .systemFont(ofSize: 15)
        plain.identifier = NSUserInterfaceItemIdentifier("plain-test-field")
        plain.setAccessibilityLabel("Plain test field")

        let multilineLabel = NSTextField(labelWithString: "Plain multiline test view")
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 632, height: 115))
        textView.minSize = NSSize(width: 0, height: 115)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 15)
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.identifier = NSUserInterfaceItemIdentifier("plain-multiline-test-view")
        textView.setAccessibilityLabel("Plain multiline test view")
        textView.textContainerInset = NSSize(width: 7, height: 7)
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let secureLabel = NSTextField(labelWithString: "Secure synthetic test field")
        // Deliberately the ordinary system control: no custom field editor,
        // Carbon EnableSecureEventInput call, masking shim or asserted OS state.
        let secure = NSSecureTextField(string: "")
        secure.placeholderString = "Synthetic marker only — do not enter real passwords"
        secure.font = .systemFont(ofSize: 15)
        secure.identifier = NSUserInterfaceItemIdentifier("secure-synthetic-test-field")
        secure.setAccessibilityLabel("Secure synthetic test field")

        let boundary = NSTextField(wrappingLabelWithString:
            "The secure control is a normal NSSecureTextField. Its actual system secure-input behavior must be observed externally; this app does not simulate or claim that state.")
        boundary.font = .systemFont(ofSize: 11)
        boundary.textColor = .secondaryLabelColor

        let controls: [NSView] = [heading, explanation, plainLabel, plain,
                                  multilineLabel, scroll, secureLabel, secure, boundary]
        let stack = NSStackView(views: controls)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        window.contentView = content
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            plain.heightAnchor.constraint(equalToConstant: 28),
            secure.heightAnchor.constraint(equalToConstant: 28),
            scroll.heightAnchor.constraint(equalToConstant: 115)
        ])
        for control in controls {
            control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Synthetic Input Fixture",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = menu

        self.window = window
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(plain)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MacInputFixture {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = FixtureDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
