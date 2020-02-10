import Foundation
import ReactiveSwift

final class Floodgate<State, Event>: FeedbackEventConsumer<Event> {
    struct QueueState {
        var events: [(Event, Token)] = []
        var isOuterLifetimeEnded = false
    }

    let (stateDidChange, changeObserver) = Signal<State, Never>.pipe()

    private let reducerLock = NSLock()
    private var state: State
    private var hasStarted = false

    private let queue = Atomic(QueueState())
    private let reducer: (State, Event) -> State
    private let eventScheduler: Scheduler

    init(state: State, reducer: @escaping (State, Event) -> State, scheduler: Scheduler) {
        self.state = state
        self.reducer = reducer
        self.eventScheduler = scheduler
    }

    func bootstrap() {
        eventScheduler.schedule {
            self.reducerLock.lock()
            defer { self.reducerLock.unlock() }

            guard !self.hasStarted else { return }
            self.hasStarted = true

            self.changeObserver.send(value: self.state)
            self.drainEvents()
        }
    }

    override func process(_ event: Event, for token: Token) {
        eventScheduler.schedule {
            if self.reducerLock.try() {
                // Fast path: No running effect.
                defer { self.reducerLock.unlock() }

                self.consume(event)
                self.drainEvents()
            } else {
                // Slow path: Enqueue the event for the running effect to drain it on behalf of us.
                self.enqueue(event, for: token)
            }
        }
    }

    override func unqueueAllEvents(for token: Token) {
        queue.modify { $0.events.removeAll(where: { _, t in t == token }) }
    }

    func withValue<Result>(_ action: (State, Bool) -> Result) -> Result {
        reducerLock.perform { action(state, hasStarted) }
    }

    func dispose() {
        queue.modify {
            $0.isOuterLifetimeEnded = true
        }
    }

    private func enqueue(_ event: Event, for token: Token) {
        queue.modify { $0.events.append((event, token)) }
    }

    private func dequeue() -> Event? {
        queue.modify {
            guard !$0.isOuterLifetimeEnded, !$0.events.isEmpty else { return nil }
            return $0.events.removeFirst().0
        }
    }

    private func drainEvents() {
        // Drain any recursively produced events.
        while let next = dequeue() {
            consume(next)
        }
    }

    private func consume(_ event: Event) {
        state = reducer(state, event)
        changeObserver.send(value: state)
    }
}

extension SignalProducer where Error == Never {
    public func enqueue(to consumer: FeedbackEventConsumer<Value>) -> SignalProducer<Never, Never> {
        SignalProducer<Never, Never> { observer, lifetime in
            let token = FeedbackEventConsumer<Value>.Token()

            lifetime += self.startWithValues { event in
                consumer.process(event, for: token)
            }
            lifetime.observeEnded { consumer.unqueueAllEvents(for: token) }
        }
    }
}
