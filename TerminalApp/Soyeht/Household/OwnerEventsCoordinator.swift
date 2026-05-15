import Foundation
import SoyehtCore

@MainActor
final class OwnerEventsCoordinator: ObservableObject {
    enum Lifecycle: Equatable {
        case foreground
        case background
    }

    enum State: Equatable {
        case suspended
        case foregroundRunning
        case backgroundFetching
        case stopped
        case failed(MachineJoinError)
    }

    typealias ForegroundRun = () async throws -> Void
    typealias BackgroundFetch = () async throws -> Void

    @Published private(set) var state: State = .suspended
    @Published private(set) var lastError: MachineJoinError?

    private let foregroundRun: ForegroundRun
    private let backgroundFetch: BackgroundFetch
    private let notificationCenter: NotificationCenter
    private var lifecycle: Lifecycle = .background
    private var foregroundTask: Task<Void, Never>?
    private var backgroundTask: Task<Void, Never>?
    private var activeTaskID: UUID?
    private var activeBackgroundTaskID: UUID?
    private var apnsTickleObserver: NSObjectProtocol?

    convenience init(longPoll: OwnerEventsLongPoll) {
        self.init(
            foregroundRun: {
                try await longPoll.runForeground()
            },
            backgroundFetch: {
                _ = try await longPoll.pollOnce()
            }
        )
    }

    init(
        foregroundRun: @escaping ForegroundRun,
        backgroundFetch: @escaping BackgroundFetch = {},
        notificationCenter: NotificationCenter = .default
    ) {
        self.foregroundRun = foregroundRun
        self.backgroundFetch = backgroundFetch
        self.notificationCenter = notificationCenter
        apnsTickleObserver = notificationCenter.addObserver(
            forName: .soyehtHouseholdAPNSTickle,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAPNSTickle()
            }
        }
    }

    deinit {
        foregroundTask?.cancel()
        backgroundTask?.cancel()
        if let apnsTickleObserver {
            notificationCenter.removeObserver(apnsTickleObserver)
        }
    }

    func enterForeground() {
        handleLifecycle(.foreground)
    }

    func enterBackground() {
        handleLifecycle(.background)
    }

    func handleLifecycle(_ lifecycle: Lifecycle) {
        self.lifecycle = lifecycle
        switch lifecycle {
        case .foreground:
            suspendBackgroundFetch()
            startForegroundIfNeeded()
        case .background:
            suspendForegroundPolling()
        }
    }

    func stop() {
        lifecycle = .background
        suspendForegroundPolling()
        suspendBackgroundFetch()
    }

    func handleAPNSTickle() {
        guard lifecycle == .background else { return }
        startBackgroundFetchIfNeeded()
    }

    private func startForegroundIfNeeded() {
        guard foregroundTask == nil else { return }
        lastError = nil
        state = .foregroundRunning

        let taskID = UUID()
        activeTaskID = taskID
        foregroundTask = Task { [weak self] in
            do {
                try await self?.foregroundRun()
                self?.foregroundRunCompleted(taskID)
            } catch is CancellationError {
                self?.foregroundRunCancelled(taskID)
            } catch let error as MachineJoinError {
                self?.foregroundRunFailed(error, taskID: taskID)
            } catch {
                self?.foregroundRunFailed(.networkDrop, taskID: taskID)
            }
        }
    }

    private func startBackgroundFetchIfNeeded() {
        guard backgroundTask == nil else { return }
        lastError = nil
        state = .backgroundFetching

        let taskID = UUID()
        activeBackgroundTaskID = taskID
        backgroundTask = Task { [weak self] in
            do {
                try await self?.backgroundFetch()
                self?.backgroundFetchCompleted(taskID)
            } catch is CancellationError {
                self?.backgroundFetchCancelled(taskID)
            } catch let error as MachineJoinError {
                self?.backgroundFetchFailed(error, taskID: taskID)
            } catch {
                self?.backgroundFetchFailed(.networkDrop, taskID: taskID)
            }
        }
    }

    private func suspendForegroundPolling() {
        foregroundTask?.cancel()
        foregroundTask = nil
        activeTaskID = nil
        state = .suspended
    }

    private func suspendBackgroundFetch() {
        backgroundTask?.cancel()
        backgroundTask = nil
        activeBackgroundTaskID = nil
        if state == .backgroundFetching {
            state = .suspended
        }
    }

    private func foregroundRunCompleted(_ taskID: UUID) {
        guard activeTaskID == taskID else { return }
        foregroundTask = nil
        activeTaskID = nil
        state = lifecycle == .foreground ? .stopped : .suspended
    }

    private func foregroundRunCancelled(_ taskID: UUID) {
        guard activeTaskID == taskID else { return }
        foregroundTask = nil
        activeTaskID = nil
        state = .suspended
    }

    private func foregroundRunFailed(_ error: MachineJoinError, taskID: UUID) {
        guard activeTaskID == taskID else { return }
        foregroundTask = nil
        activeTaskID = nil
        lastError = error
        state = .failed(error)
    }

    private func backgroundFetchCompleted(_ taskID: UUID) {
        guard activeBackgroundTaskID == taskID else { return }
        backgroundTask = nil
        activeBackgroundTaskID = nil
        state = lifecycle == .background ? .suspended : .foregroundRunning
    }

    private func backgroundFetchCancelled(_ taskID: UUID) {
        guard activeBackgroundTaskID == taskID else { return }
        backgroundTask = nil
        activeBackgroundTaskID = nil
        state = .suspended
    }

    private func backgroundFetchFailed(_ error: MachineJoinError, taskID: UUID) {
        guard activeBackgroundTaskID == taskID else { return }
        backgroundTask = nil
        activeBackgroundTaskID = nil
        lastError = error
        state = .failed(error)
    }
}
