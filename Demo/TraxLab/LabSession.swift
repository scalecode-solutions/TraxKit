import SwiftUI
import TraxKit

/// Owns the Lab's one `TraxEngine` for a signed-in person: the shape a
/// production host uses (one engine per identity, many screens reading it).
///
/// Unlike a calendar, location sharing is app-wide: the engine starts at
/// sign-in and keeps running in the background (sharing and geofences must not
/// stop because no map is on screen). What screens add is a hold: a screen
/// showing others' locations acquires the engine, which refreshes at once and
/// polls at its fast cadence while held. The engine counts holds, so the hub
/// and a person's screen can't fight.
@MainActor
@Observable
final class LabSession {
    let engine: TraxEngine
    /// True from `start()` until `stop()` or sign-out.
    private(set) var isRunning = false

    private var wiped = false

    init(engine: TraxEngine) {
        self.engine = engine
    }

    /// Signed in: run the engine app-wide. Idempotent.
    func start() {
        guard !wiped, !isRunning else { return }
        isRunning = true
        engine.start()
    }

    /// The host went away without a sign-out (the session expired and the app
    /// fell back to the login screen): stop, but keep the store. The engine's
    /// work stops with the host instead of depending on when the engine is freed.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.stop()
    }

    /// A screen showing others' locations appeared.
    func acquire() { engine.acquire() }

    /// That screen went away.
    func release() { engine.release() }

    /// The scene went to the background (false) or came back (true). Driven
    /// from the app's scene phase, not from a screen.
    func setForeground(_ on: Bool) { engine.setForeground(on) }

    /// Sign-out: delete this person's local store, then stop. The wipe goes
    /// first, while the container is still open (`TraxEngine.wipeStore`).
    /// Nothing restarts a wiped session; the next identity gets a new one.
    func wipe() {
        wiped = true
        engine.wipeStore()
        engine.stop()
        isRunning = false
    }
}

/// Holds the session while a map screen is anywhere in its navigation stack,
/// including while something is pushed over it.
///
/// A `.task` won't do: a NavigationStack treats a covered screen as
/// disappeared. Held in the screen's `@State` instead: SwiftUI keeps that
/// storage while the screen is in the stack and frees it when it's popped.
/// `arm` runs from `onAppear`, so the throwaway copies SwiftUI makes of a
/// view's initial state never touch the session.
@MainActor
final class LabMapHold {
    private var session: LabSession?

    /// The first call acquires; later ones (reappearing from under a push) do nothing.
    func arm(_ session: LabSession) {
        guard self.session == nil else { return }
        self.session = session
        session.acquire()
    }

    isolated deinit {
        session?.release()
    }
}
