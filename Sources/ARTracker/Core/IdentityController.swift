import Foundation

public final class IdentityController: SessionLifecycleListener, @unchecked Sendable {
    private let lock = UnfairLock()
    private let session: SessionManager
    private let defaults: UserDefaults
    private let crashContext: CrashContextStore
    private var emitHandler: (@Sendable (Item) -> Void)?
    private var diskQueue: DiskQueue?
    private var pendingItems: [Item] = []

    private var lastIdentifiedUserId: String?
    private var lastIdentifiedTraits: [String: JSONValue]?
    private var hasEmittedFirstStart = false

    public init(
        session: SessionManager = .shared,
        defaults: UserDefaults = .standard,
        crashContext: CrashContextStore = .shared,
        emit: (@Sendable (Item) -> Void)? = nil
    ) {
        self.session = session
        self.defaults = defaults
        self.crashContext = crashContext
        self.emitHandler = emit
        self.lastIdentifiedUserId = session.userId
    }

    public func attachQueue(_ queue: DiskQueue) {
        let itemsToDrain: [Item] = lock.withLock {
            self.diskQueue = queue
            let items = self.pendingItems
            self.pendingItems.removeAll()
            return items
        }

        for item in itemsToDrain {
            _ = queue.enqueue(item)
        }
    }

    public func setEmitHandler(_ handler: @escaping @Sendable (Item) -> Void) {
        lock.withLock {
            self.emitHandler = handler
        }
    }

    public func identify(userId: String, traits: [String: Any] = [:]) {
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Log.warn("ARTracker.identify called with blank userId; ignored.")
            return
        }

        let sanitizedTraits = TraitSanitizer.sanitize(traits)

        var itemToEmitImmediately: Item?
        var userSwitchEvents: (end: Item, start: Item, identify: Item)?

        lock.withLock {
            let currentUser = session.userId

            if currentUser == nil {
                // Anonymous -> User A: keep session, emit $identify
                session.userId = trimmed
                crashContext.recordUserId(trimmed)
                lastIdentifiedUserId = trimmed
                lastIdentifiedTraits = sanitizedTraits

                let item = Item(
                    type: .event,
                    name: "$identify",
                    sessionId: session.sessionId,
                    userId: trimmed,
                    attributes: sanitizedTraits
                )
                itemToEmitImmediately = item
            } else if currentUser == trimmed {
                // A -> A with identical traits: no-op
                if let lastTraits = lastIdentifiedTraits, lastTraits == sanitizedTraits {
                    return
                }
                lastIdentifiedTraits = sanitizedTraits
                let item = Item(
                    type: .event,
                    name: "$identify",
                    sessionId: session.sessionId,
                    userId: trimmed,
                    attributes: sanitizedTraits
                )
                itemToEmitImmediately = item
            } else {
                // A -> B: user switch
                let oldSessionId = session.sessionId
                let oldUser = currentUser

                // 1. session_end with A
                let endItem = Item(
                    type: .session,
                    name: "session_end",
                    sessionId: oldSessionId,
                    userId: oldUser,
                    attributes: [
                        "session_id": .string(oldSessionId)
                    ]
                )

                // 2. update to B
                session.userId = trimmed
                crashContext.recordUserId(trimmed)
                lastIdentifiedUserId = trimmed
                lastIdentifiedTraits = sanitizedTraits

                // 3. rotate session
                let newSessionId = session.rotateSession()
                crashContext.recordSessionId(newSessionId)

                // 4. session_start with B
                let startAttrs = SessionContext.startAttributes(
                    launchType: "rotation",
                    sessionId: newSessionId
                )
                let startItem = Item(
                    type: .session,
                    name: "session_start",
                    sessionId: newSessionId,
                    userId: trimmed,
                    attributes: startAttrs
                )

                // 5. $identify with B
                let identifyItem = Item(
                    type: .event,
                    name: "$identify",
                    sessionId: newSessionId,
                    userId: trimmed,
                    attributes: sanitizedTraits
                )

                userSwitchEvents = (end: endItem, start: startItem, identify: identifyItem)
            }
        }

        if let item = itemToEmitImmediately {
            enqueue(item)
        } else if let events = userSwitchEvents {
            enqueue(events.end)
            enqueue(events.start)
            enqueue(events.identify)
        }
    }

    public func reset() {
        var eventsToEmit: (end: Item, start: Item)?

        lock.withLock {
            let oldSessionId = session.sessionId
            let oldUser = session.userId

            let endItem = Item(
                type: .session,
                name: "session_end",
                sessionId: oldSessionId,
                userId: oldUser,
                attributes: [
                    "session_id": .string(oldSessionId)
                ]
            )

            session.userId = nil
            crashContext.recordUserId(nil)
            lastIdentifiedUserId = nil
            lastIdentifiedTraits = nil

            let newSessionId = session.rotateSession()
            crashContext.recordSessionId(newSessionId)

            let startAttrs = SessionContext.startAttributes(
                launchType: "rotation",
                sessionId: newSessionId
            )
            let startItem = Item(
                type: .session,
                name: "session_start",
                sessionId: newSessionId,
                userId: nil,
                attributes: startAttrs
            )

            eventsToEmit = (end: endItem, start: startItem)
        }

        if let events = eventsToEmit {
            enqueue(events.end)
            enqueue(events.start)
        }
    }

    // MARK: - SessionLifecycleListener

    public func sessionDidStart(id: String) {
        let (launchType, currentUserId) = lock.withLock { () -> (String?, String?) in
            let isFirst = !hasEmittedFirstStart
            hasEmittedFirstStart = true
            return (isFirst ? "cold" : "rotation", session.userId)
        }

        crashContext.recordSessionId(id)

        let attrs = SessionContext.startAttributes(
            launchType: launchType,
            sessionId: id
        )

        let item = Item(
            type: .session,
            name: "session_start",
            sessionId: id,
            userId: currentUserId,
            attributes: attrs
        )
        enqueue(item)
    }

    public func sessionDidEnd(id: String, durationMs: Double) {
        let currentUserId = lock.withLock { session.userId }
        let item = Item(
            type: .session,
            name: "session_end",
            sessionId: id,
            userId: currentUserId,
            attributes: [
                "duration_ms": .number(durationMs),
                "session_id": .string(id)
            ]
        )
        enqueue(item)
    }

    private func enqueue(_ item: Item) {
        var directEmit: ((Item) -> Void)?
        var queueTarget: DiskQueue?

        lock.withLock {
            if let customEmit = emitHandler {
                directEmit = customEmit
            } else if let queue = diskQueue {
                queueTarget = queue
            } else {
                pendingItems.append(item)
            }
        }

        if let emit = directEmit {
            emit(item)
        } else if let queue = queueTarget {
            _ = queue.enqueue(item)
        }
    }
}
