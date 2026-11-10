import Foundation

@MainActor
protocol RepeatingScheduler: AnyObject {
    /// When the action next runs, or nil when the scheduler is stopped.
    var nextFireDate: Date? { get }
    func start(interval: TimeInterval, action: @escaping @MainActor () async -> Void)
    func stop()
}

@MainActor
final class SyncScheduler: RepeatingScheduler {
    private var timer: Timer?

    var nextFireDate: Date? { timer?.fireDate }

    func start(interval: TimeInterval, action: @escaping @MainActor () async -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in await action() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }
}
