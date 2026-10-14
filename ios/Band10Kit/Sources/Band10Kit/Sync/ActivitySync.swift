// Band10Kit — part of xiaomi-band10-apple-health, AGPL-3.0-or-later.
// Sequence derived from Gadgetbridge (XiaomiHealthService,
// XiaomiActivityFileFetcher), AGPL-3.0.

import Foundation

/// Downloads the band's recorded data over an authenticated session: asks what
/// it holds for today and for earlier days, then fetches the files one at a
/// time. It holds no transport: feed it what the band sends and carry out its
/// actions in order.
///
/// A file is acknowledged, which lets the band delete it, only when it could be
/// read and holds final data. Anything else stays on the band and is fetched
/// again next time, so a parser gap never loses data.
public struct ActivitySync: Sendable {
    public struct Summary: Equatable, Sendable {
        /// Files received intact.
        public var received = 0
        /// Files that never arrived or arrived damaged; the band keeps them.
        public var failed = 0
        /// Files of a kind this library cannot read, left on the band.
        public var unsupported = 0
        /// Files received but left on the band: unreadable, or a night still in progress.
        public var kept = 0
        /// False when the band did not answer one of the listings, so files may be missing.
        public var isComplete = true
    }

    public enum Action: Equatable, Sendable {
        /// Send these command bytes, encrypted, on the command channel.
        case send(Data)
        /// Keep this file. If it cannot be kept, stop carrying out actions: the
        /// one that follows may tell the band it can forget the file.
        case store(ActivityFile)
        case finished(Summary)
    }

    private enum Step: Equatable, Sendable {
        case idle
        case listingToday
        case listingPastDays
        case fetching(ActivityFileID)
        case finished
    }

    private let acknowledgesFiles: Bool
    private var step = Step.idle
    private var queue: [ActivityFileID] = []
    /// Files already asked for in this sync: a late answer is still welcome,
    /// a second listing of them is not.
    private var requested: Set<ActivityFileID> = []
    private var assembler = ActivityFileAssembler()
    private var summary = Summary()

    /// - Parameter acknowledgesFiles: pass false to leave every file on the band,
    ///   for example to inspect its data without taking it from another app.
    public init(acknowledgesFiles: Bool = true) {
        self.acknowledgesFiles = acknowledgesFiles
    }

    /// True while an answer from the band is pending: the caller should call
    /// `handleTimeout()` if nothing arrives for a few seconds.
    public var isWaitingForBand: Bool {
        step != .idle && step != .finished
    }

    public mutating func start() -> [Action] {
        guard step == .idle else { return [] }
        step = .listingToday
        return [.send(HealthCommand.listToday)]
    }

    public mutating func handle(_ reply: HealthReply) -> [Action] {
        guard case .files(let scope, let files) = reply, isWaitingForBand else { return [] }
        enqueue(files)
        switch (step, scope) {
        case (.listingToday, .today):
            step = .listingPastDays
            return [.send(HealthCommand.listPastDays)]
        case (.listingPastDays, .pastDays):
            return fetchNext()
        default:
            // A list that arrives late only adds to the queue.
            return []
        }
    }

    /// Feeds one decrypted payload of the activity channel.
    public mutating func handle(piece: Data) -> [Action] {
        guard case .fetching(let expected) = step else { return [] }
        switch assembler.append(piece) {
        case .incomplete:
            return []
        case .invalid:
            summary.failed += 1
            return fetchNext()
        case .complete(let file) where file.id == expected:
            return accept(file) + fetchNext()
        case .complete(let file) where requested.contains(file.id):
            // The late answer to a request that timed out: keep it, and keep
            // waiting for the file asked for now.
            summary.failed = max(0, summary.failed - 1)
            return accept(file)
        case .complete:
            // Not something this sync asked for: ignore it and keep waiting.
            return []
        }
    }

    /// The band stayed silent: give up on what was pending and move on.
    public mutating func handleTimeout() -> [Action] {
        switch step {
        case .idle, .finished:
            return []
        case .listingToday:
            summary.isComplete = false
            step = .listingPastDays
            return [.send(HealthCommand.listPastDays)]
        case .listingPastDays:
            summary.isComplete = false
            return fetchNext()
        case .fetching:
            summary.failed += 1
            return fetchNext()
        }
    }

    private mutating func accept(_ file: ActivityFile) -> [Action] {
        summary.received += 1
        guard acknowledgesFiles else { return [.store(file)] }
        guard Self.holdsFinalData(file) else {
            summary.kept += 1
            return [.store(file)]
        }
        return [.store(file), .send(HealthCommand.acknowledge(file.id))]
    }

    /// Readable, and not a night the band is still recording.
    private static func holdsFinalData(_ file: ActivityFile) -> Bool {
        switch try? ActivityContent.decode(file) {
        case .none: false
        case .sleep(let session)?: session.isFinished
        case .some: true
        }
    }

    private mutating func enqueue(_ files: [ActivityFileID]) {
        let supported = files.filter { ActivityContent.isSupported($0.kind) }
        summary.unsupported += files.count - supported.count
        let known = Set(queue).union(requested)
        let fresh = Array(Set(supported.filter { !known.contains($0) }))
        queue = (queue + fresh).sorted(by: Self.isFetchedBefore)
    }

    private mutating func fetchNext() -> [Action] {
        assembler.reset()
        guard let next = queue.first else {
            step = .finished
            return [.finished(summary)]
        }
        queue = Array(queue.dropFirst())
        requested.insert(next)
        step = .fetching(next)
        return [.send(HealthCommand.request(next))]
    }

    /// Oldest first, so that an interrupted sync resumes without gaps.
    private static func isFetchedBefore(_ first: ActivityFileID, _ second: ActivityFileID) -> Bool {
        (first.timestamp, first.category, first.subtype, first.detail, first.version)
            < (second.timestamp, second.category, second.subtype, second.detail, second.version)
    }
}
