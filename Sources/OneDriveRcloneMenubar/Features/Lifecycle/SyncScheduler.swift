import Foundation

@MainActor
protocol RepeatingScheduler: AnyObject {
    func start(interval: TimeInterval, action: @escaping @MainActor () async -> Void)
    func stop()
}

@MainActor
final class SyncScheduler: RepeatingScheduler {
    private var timer: Timer?

    func start(interval: TimeInterval, action: @escaping @MainActor () async -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in await action() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }
}
