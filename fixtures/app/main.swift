import AppKit

/// Disposable acceptance fixture for `nuvin-computer-use` Stage K.
/// Two windows, deterministic AX labels, in-memory only — no disk/clipboard.
/// Build: ./build.sh  →  fixtures/app/CUFixture.app
/// Run:   open fixtures/app/CUFixture.app  (or run the binary directly)

let app = NSApplication.shared
app.setActivationPolicy(.regular)

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var primary: NSWindow!
    var secondary: NSWindow!
    var status: NSTextField!
    var field: NSTextField!

    func applicationDidFinishLaunching(_ notification: Notification) {
        primary = makeWindow(
            title: "CU Fixture — Primary",
            rect: NSRect(x: 200, y: 200, width: 480, height: 360)
        )
        primary.identifier = NSUserInterfaceItemIdentifier("fixture-primary")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        // AXPress target — a labeled button that flips a status line.
        let button = NSButton(title: "Press Me", target: self, action: #selector(didPress))
        button.setAccessibilityIdentifier("fixture-press-button")
        button.setAccessibilityLabel("Press Me")
        stack.addArrangedSubview(button)

        // Status line the runner can read to confirm the press landed.
        status = NSTextField(labelWithString: "status: idle")
        status.setAccessibilityIdentifier("fixture-status")
        stack.addArrangedSubview(status)

        // AXValue / type target — a labeled editable text field.
        field = NSTextField(string: "")
        field.placeholderString = "type here"
        field.setAccessibilityIdentifier("fixture-text-field")
        field.setAccessibilityLabel("Input Field")
        stack.addArrangedSubview(field)

        // Scrollable area — a fixed-height clip view of many labeled rows.
        // Plain NSViews expose a shallow, reliable AX surface (NSTextView's
        // deep attributed-text tree is what made AX reads unreliable).
        let scroll = NSScrollView()
        scroll.setAccessibilityIdentifier("fixture-scroll")
        scroll.setAccessibilityLabel("Scroll Area")
        scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        for i in 1...60 {
            let row = NSTextField(labelWithString: "fixture row \(i)")
            row.setAccessibilityIdentifier("fixture-row-\(i)")
            column.addArrangedSubview(row)
        }
        column.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = column
        column.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
        stack.addArrangedSubview(scroll)

        primary.contentView = stack
        primary.makeKeyAndOrderFront(nil)

        // Second window for multi-window/ambiguity coverage.
        secondary = makeWindow(
            title: "CU Fixture — Secondary",
            rect: NSRect(x: 720, y: 200, width: 320, height: 200)
        )
        secondary.identifier = NSUserInterfaceItemIdentifier("fixture-secondary")
        secondary.contentView = NSTextField(labelWithString: "secondary window")
        secondary.orderFront(nil)

        app.activate(ignoringOtherApps: true)
    }

    private func makeWindow(title: String, rect: NSRect) -> NSWindow {
        let w = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = title
        w.isReleasedWhenClosed = false
        return w
    }

    @objc private func didPress() {
        status.stringValue = "status: pressed"
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // keep alive so the runner controls lifecycle
    }
}

let delegate = FixtureDelegate()
app.delegate = delegate
app.run()
