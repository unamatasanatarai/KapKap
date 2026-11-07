import Cocoa

/// Section selection: one transparent, borderless window per screen at `.screenSaver` level (the record
/// panel sits one level above). A drag starts on one screen and is clamped to it. Once there is a
/// selection, dragging inside it moves it and dragging an edge or corner resizes it; a drag outside it
/// starts a new selection.
public final class RegionSelectionOverlay: NSObject, RegionSelecting {
    public weak var selectionDelegate: RegionSelectionOverlayDelegate?

    /// Drags smaller than this (in points) count as a click and clear the selection.
    public static let minimumSelectionSize: CGFloat = 4
    /// Resizing never makes the selection smaller than this (in points).
    public static let minimumEditedSize: CGFloat = 16

    private struct Surface {
        let window: NSWindow
        let view: RegionSelectionView
        let screen: ScreenInfo
    }

    private var surfaces: [Surface] = []
    private var dragStart: CGPoint?
    private var dragScreen: ScreenInfo?
    /// The current selection in AppKit global points and its screen.
    private var selected: (rect: CGRect, screen: ScreenInfo)?
    /// Set while a drag edits the existing selection (instead of drawing a new one).
    private var editing: (handle: SelectionEditing.Handle, original: CGRect)?

    public override init() {
        super.init()
    }

    public var isVisible: Bool {
        return !surfaces.isEmpty
    }

    // MARK: - RegionSelecting

    public func show() {
        guard surfaces.isEmpty else { return }
        for screen in NSScreen.screens {
            guard let info = ScreenInfo(screen: screen) else { continue }
            surfaces.append(makeSurface(for: info))
        }
        NSCursor.crosshair.set()
    }

    public func dismiss() {
        guard !surfaces.isEmpty else { return }
        // Order out first and release on the next runloop turn: tearing an overlay window down while
        // it is still on screen (or handling its own event) has caused crashes.
        let old = surfaces
        for surface in old {
            surface.window.orderOut(nil)
        }
        surfaces = []
        dragStart = nil
        dragScreen = nil
        selected = nil
        editing = nil
        NSCursor.arrow.set()
        DispatchQueue.main.async {
            withExtendedLifetime(old) {}
        }
    }

    public func setSuspended(_ suspended: Bool) {
        for surface in surfaces {
            if suspended {
                surface.window.orderOut(nil)
            } else {
                surface.window.orderFrontRegardless()
            }
        }
        if suspended {
            NSCursor.arrow.set()
        } else if !surfaces.isEmpty {
            NSCursor.crosshair.set()
        }
    }

    // MARK: - Windows

    private func makeSurface(for screen: ScreenInfo) -> Surface {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false

        let view = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), scale: screen.scale)
        view.onMouseDown = { [weak self] point in self?.dragBegan(at: point, on: screen) }
        view.onMouseDragged = { [weak self] point in self?.dragMoved(to: point) }
        view.onMouseUp = { [weak self] point in self?.dragEnded(at: point) }
        window.contentView = view
        window.orderFrontRegardless()
        return Surface(window: window, view: view, screen: screen)
    }

    // MARK: - Dragging

    private func dragBegan(at point: CGPoint, on screen: ScreenInfo) {
        dragStart = point
        dragScreen = screen
        if let selected = selected, selected.screen.id == screen.id,
           let handle = SelectionEditing.handle(at: point, in: selected.rect) {
            editing = (handle, selected.rect)
            surface(for: screen)?.view.isDraggingSelection = true
            return
        }
        editing = nil
        selected = nil
        for surface in surfaces {
            surface.view.selection = nil
        }
        selectionDelegate?.regionSelectionDidClear()
    }

    private func dragMoved(to point: CGPoint) {
        if let edited = editedRect(to: point), let screen = dragScreen {
            surface(for: screen)?.view.selection = edited.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            return
        }
        guard let rect = currentRect(to: point), let screen = dragScreen else { return }
        surface(for: screen)?.view.selection = rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    }

    private func dragEnded(at point: CGPoint) {
        defer {
            dragStart = nil
            dragScreen = nil
            editing = nil
        }
        if let edited = editedRect(to: point), let screen = dragScreen {
            let view = surface(for: screen)?.view
            view?.isDraggingSelection = false
            view?.selection = edited.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            selected = (edited, screen)
            selectionDelegate?.regionSelection(didSelect: edited, on: screen)
            return
        }
        guard let rect = currentRect(to: point), let screen = dragScreen else { return }
        if rect.width >= Self.minimumSelectionSize && rect.height >= Self.minimumSelectionSize {
            surface(for: screen)?.view.selection = rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            selected = (rect, screen)
            selectionDelegate?.regionSelection(didSelect: rect, on: screen)
        } else {
            surface(for: screen)?.view.selection = nil
        }
    }

    /// While editing: the original selection moved or resized by the drag so far, kept on its screen.
    private func editedRect(to point: CGPoint) -> CGRect? {
        guard let editing = editing, let start = dragStart, let screen = dragScreen else { return nil }
        let delta = CGVector(dx: point.x - start.x, dy: point.y - start.y)
        return SelectionEditing.apply(editing.handle, to: editing.original, delta: delta, bounds: screen.frame,
                                      minSize: Self.minimumEditedSize)
    }

    /// The rect from the drag start to `point` in global points, clamped to the screen the drag began on.
    private func currentRect(to point: CGPoint) -> CGRect? {
        guard let start = dragStart, let screen = dragScreen else { return nil }
        let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                          width: abs(point.x - start.x), height: abs(point.y - start.y))
        return ScreenGeometry.clamp(rect, to: screen)
    }

    private func surface(for screen: ScreenInfo) -> Surface? {
        return surfaces.first { $0.screen.id == screen.id }
    }
}
