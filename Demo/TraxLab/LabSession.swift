import SwiftUI
import TraxKit

/// Owns the Lab's one `TraxEngine` for a signed-in person: the shape a
/// production host uses (one engine per identity, many screens reading it).
///
/// Unlike a calendar, location sharing is app-wide: the engine starts at
/// sign-in and keeps running in the background (sharing and geofences must not
/// stop because no map is on screen). What screens add is a hold: a map on
/// screen acquires the session and refreshes immediately, so it opens fresh
/// instead of waiting for the next poll. Holds are counted, so the hub and a
/// person's screen can't fight.
@MainActor
@Observable
final class LabSession {
    let engine: TraxEngine
    /// True from `start()` until `stop()` or sign-out.
    private(set) var isRunning = false
    /// How many map surfaces hold the session right now.
    private(set) var holders = 0

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
    /// fell back to the login screen): stop, but keep the store. Without this
    /// the poll loop, which holds the engine while it runs, would outlive the host.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.stop()
    }

    /// A map surface appeared: refresh now rather than on the next poll tick.
    func acquire() {
        holders += 1
        guard isRunning else { return }
        Task { [engine] in await engine.sync.refresh() }
    }

    /// A map surface went away.
    func release() {
        holders = max(0, holders - 1)
    }

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
