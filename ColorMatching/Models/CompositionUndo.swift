import Foundation

/// Bridges user composition edits to an `UndoManager` (issue #14).
///
/// The model notes each user edit together with a pre-edit snapshot. The first
/// edit of a burst registers the undo action; rapid same-kind edits that follow
/// (slider drags, held steppers) coalesce into that single step. Undo and redo
/// apply snapshots and re-register the displaced state as the inverse, so both
/// directions stay available. Only edits that pass through `noteUserEdit` ever
/// reach the undo stack — solves and results never do.
///
/// Main-actor isolated because `UndoManager` is, and because every user edit
/// originates from the main-actor UI.
@MainActor
final class CompositionUndo {
    /// Same-kind edits within this window continue the current undo step.
    static let coalesceInterval: TimeInterval = 0.5

    /// Held weakly: the window owns the manager; this type only registers.
    private(set) weak var undoManager: UndoManager?

    private var suspensionDepth = 0
    private var coalesceKey: String?
    private var lastEditTime = Date.distantPast

    /// Connects `manager`. Attaching a different manager (a new window, or a
    /// fresh model taking over after New Project) clears stale registrations.
    func attach(_ manager: UndoManager?) {
        if manager !== undoManager {
            manager?.removeAllActions()
            coalesceKey = nil
        }
        undoManager = manager
    }

    /// Drops all registered actions, for when a project file replaces state.
    func reset() {
        undoManager?.removeAllActions()
        coalesceKey = nil
    }

    /// Notes a user edit. `restore` is the pre-edit snapshot; `swap` applies a
    /// snapshot to the model and returns the one it replaced, which becomes
    /// the inverse action.
    func noteUserEdit(
        kind: String,
        actionName: String,
        restore: CompositionEdit,
        swap: @escaping (CompositionEdit) -> CompositionEdit
    ) {
        guard let undoManager, suspensionDepth == 0 else { return }
        if coalesceKey != kind || Date().timeIntervalSince(lastEditTime) > Self.coalesceInterval {
            register(restore, actionName: actionName, swap: swap)
        }
        coalesceKey = kind
        lastEditTime = Date()
    }

    /// Runs `body` with registration suspended — undo/redo application and
    /// programmatic changes (project load, image import) are not user edits.
    func performWithoutRegistration<R>(_ body: () -> R) -> R {
        suspensionDepth += 1
        defer { suspensionDepth -= 1 }
        return body()
    }

    private func register(
        _ restore: CompositionEdit,
        actionName: String,
        swap: @escaping (CompositionEdit) -> CompositionEdit
    ) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.apply(restore, actionName: actionName, swap: swap)
        }
        undoManager?.setActionName(actionName)
    }

    /// Applies `snapshot` and registers the state it displaced as the inverse.
    /// Runs inside `UndoManager.undo()`/`redo()`, so the registration lands on
    /// the opposite stack automatically. Coalescing is reset first so the next
    /// user edit always registers a fresh step.
    private func apply(
        _ snapshot: CompositionEdit,
        actionName: String,
        swap: @escaping (CompositionEdit) -> CompositionEdit
    ) {
        coalesceKey = nil
        let inverse = performWithoutRegistration { swap(snapshot) }
        register(inverse, actionName: actionName, swap: swap)
    }
}
