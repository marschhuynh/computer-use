import CoreGraphics
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Visual feedback only — never the input path. An injectable seam so all
/// ordering/cleanup tests run without a real window.
public protocol CursorRenderer {
    /// Create the overlay. Called before any input; a failure here must fail
    /// the command before mutation.
    func prepare() throws
    /// Move toward a screen point, bounded (≤150 ms handled by the timeline).
    func approach(_ point: CGPoint, context: CommandContext) async throws
    /// Click/press feedback pulse.
    func pulse() async throws
    /// Drag feedback along a path of screen points.
    func dragAlong(_ points: [CGPoint], context: CommandContext) async throws
    /// Hide the overlay (also used before a capture so the cursor isn't in it).
    func hide() async throws
    /// Tear down the overlay; runs on every path (success/failure/cancel).
    func teardown() async throws
}

/// The visualization the timeline produced for a command's `visualization`
/// result field.
public enum Visualization: String {
    case none, approach, pulse, drag
}

/// What a spatial action's cursor should do.
public enum SpatialActionKind {
    case click
    case move
    case drag(to: CGPoint)
    case press
}

/// Sequences cursor feedback and input on one timeline within the command
/// budget. The `input` closure is where the real mutation happens; the timeline
/// wraps it in prepare/approach/pulse/hide/teardown.
public final class ActionTimeline {
    private let renderer: CursorRenderer

    public init(renderer: CursorRenderer) {
        self.renderer = renderer
    }

    /// Spatial action (click/move/drag): prepare, approach, act, hide, teardown.
    /// Returns the visualization that ran. Teardown is guaranteed on every path.
    @discardableResult
    public func spatialAction(
        at point: CGPoint,
        kind: SpatialActionKind,
        context: CommandContext,
        input: @escaping (CommandContext) async throws -> Void
    ) async throws -> Visualization {
        // Preparation happens first and any failure is surfaced before input.
        do {
            try renderer.prepare()
        } catch {
            try? await renderer.teardown()
            throw error
        }
        do {
            let visualization: Visualization
            switch kind {
            case .click, .press:
                try await renderer.approach(point, context: context)
                try await renderer.pulse()
                visualization = .pulse
            case .move:
                try await renderer.approach(point, context: context)
                visualization = .approach
            case let .drag(to):
                try await renderer.approach(point, context: context)
                try await renderer.dragAlong([point, to], context: context)
                visualization = .drag
            }
            try context.check()
            try await input(context)
            await markInput(in: renderer)
            try await renderer.hide()
            try await renderer.teardown()
            return visualization
        } catch {
            try? await renderer.hide()
            try? await renderer.teardown()
            throw error
        }
    }

    /// Element-anchored action (press/set-value/scroll-to-ref): show feedback at
    /// the element's bounds when geometry is available; otherwise run the action
    /// with no visualization (never fabricate a coordinate fallback).
    @discardableResult
    public func elementAction(
        at boundsCenter: CGPoint?,
        context: CommandContext,
        input: @escaping (CommandContext) async throws -> Void
    ) async throws -> Visualization {
        guard let boundsCenter else {
            try await input(context)
            return .none
        }
        do {
            try renderer.prepare()
        } catch {
            try? await renderer.teardown()
            throw error
        }
        do {
            try await renderer.approach(boundsCenter, context: context)
            try context.check()
            try await input(context)
            try await renderer.hide()
            try await renderer.teardown()
            return .approach
        } catch {
            try? await renderer.hide()
            try? await renderer.teardown()
            throw error
        }
    }

    private func markInput(in renderer: CursorRenderer) async {
        if let recorder = renderer as? InputMarking { recorder.markInput() }
    }
}

/// Test seam: renderers that want to observe the point where input dispatched.
public protocol InputMarking {
    func markInput()
}

/// No-op renderer for non-AppKit contexts and tests.
public final class NullCursorRenderer: CursorRenderer {
    public init() {}
    public func prepare() throws {}
    public func approach(_ point: CGPoint, context: CommandContext) async throws {}
    public func pulse() async throws {}
    public func dragAlong(_ points: [CGPoint], context: CommandContext) async throws {}
    public func hide() async throws {}
    public func teardown() async throws {}
}

#if canImport(AppKit)
/// Real overlay: a borderless, transparent, non-activating, click-through
/// NSPanel showing an original cursor glyph. Owns its own window lifecycle.
public final class CursorOverlay: CursorRenderer {
    private var panel: NSPanel?
    private var view: CursorView?

    public init() {}

    public func prepare() throws {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 32, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.hasShadow = false
        let view = CursorView(frame: panel.contentView!.bounds)
        panel.contentView = view
        self.panel = panel
        self.view = view
        panel.orderFront(nil)
    }

    public func approach(_ point: CGPoint, context: CommandContext) async throws {
        try context.check()
        guard let panel else { return }
        // Position the overlay centered on the target point.
        let frame = NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32)
        await MainActor.run {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15 // ≤150 ms approach
                panel.animator().setFrame(frame, display: true)
            }
        }
    }

    public func pulse() async throws {
        guard let view else { return }
        await MainActor.run { view.pulse() }
    }

    public func dragAlong(_ points: [CGPoint], context: CommandContext) async throws {
        guard let panel else { return }
        for point in points {
            try context.check()
            panel.setFrameOrigin(NSPoint(x: point.x - 16, y: point.y - 16))
        }
    }

    public func hide() async throws {
        panel?.orderOut(nil)
    }

    public func teardown() async throws {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        view = nil
    }
}

/// An original cursor glyph — a filled pointer with a ring, drawn in code (no
/// copied assets).
final class CursorView: NSView {
    private var pulsing = false
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(dirtyRect)
        // pointer
        let pointer = NSBezierPath()
        pointer.move(to: NSPoint(x: 8, y: 6))
        pointer.line(to: NSPoint(x: 8, y: 26))
        pointer.line(to: NSPoint(x: 15, y: 20))
        pointer.line(to: NSPoint(x: 22, y: 20))
        pointer.close()
        NSColor.systemBlue.setFill()
        pointer.fill()
        NSColor.white.setStroke()
        pointer.lineWidth = 1.5
        pointer.stroke()
        if pulsing {
            let ring = NSBezierPath(ovalIn: dirtyRect.insetBy(dx: 2, dy: 2))
            NSColor.systemBlue.withAlphaComponent(0.4).setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }
    }
    func pulse() {
        pulsing = true
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in // 100 ms pulse
            self?.pulsing = false
            self?.needsDisplay = true
        }
    }
}
#endif
