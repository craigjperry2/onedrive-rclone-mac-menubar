import Foundation

@MainActor
final class SyncScheduler {
    private var timer: Timer?

    func start(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in action() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }
}
