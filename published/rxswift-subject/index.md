---
layout: page
title: "RxSwift Source Code Reading Part III - Subject"
date: 2022-05-15
permalink: /rxswift-subject/
---

Previously we’ve walked through several important concepts in RxSwift: `Observable`, `Observer`, `Disposable`, and `Scheduler`. Today we’ll talk about `Subject`.

If you’ve used RxSwift, `Subject` is definitely not a stranger—for example, our most commonly used `PublishSubject` and `BehaviorSubject`. They can act both as an `Observable` and as an `Observer`, and they also keep emitting events even when there are no subscribers.

When using these abstractions, have you ever wondered how this capability is actually implemented? This article takes a look from the perspective of the source code.

## Before We Start

- The code in this article is based on RxSwift 6.5.0.
- This article assumes you have some experience using RxSwift.
- The snippets from the source code shown here omit parts related to debugging, generics, and comments. You can find the complete source on GitHub.

## SubjectType

All Subject types implement the same protocol, `SubjectType`; you could say this protocol is the origin of Subjects. Its definition is:

```swift
/// Represents an object that is both an observable sequence as well as an observer.
public protocol SubjectType: ObservableType {
    associatedtype Observer: ObserverType

    func asObserver() -> Observer
}
```

`SubjectType` is very simple—just the few lines above if you ignore the comments.

From the definition, we can see that `SubjectType` itself is also an `ObservableType`, so it can be subscribed to directly. But its ability to act as an observer is not obtained by directly "inheriting" from `ObserverType`. Instead, it introduces an associated type `Observer`, and exposes an `asObserver()` method that converts the subject into an instance of that observer type.

This is because the type used as the observer is not required to be the same as the subject itself (although in practice it usually is), so each implementation has to specify it explicitly. This is also why `asObserver()` is defined directly on `SubjectType`, whereas `asObservable()` is provided in an extension on `ObservableType`.

So the `SubjectType` protocol already encodes the idea that a Subject is both an observable sequence and an observer.

## PublishSubject

With the basic protocol out of the way, let’s look at how a concrete Subject is implemented.

We’ll start with the most familiar one, `PublishSubject`. Here are its declaration and properties:

```swift
public final class PublishSubject<Element>: Observable<Element>, SubjectType, Cancelable, ObserverType, SynchronizedUnsubscribeType {
    public typealias SubjectObserverType = PublishSubject<Element>

    typealias Observers = AnyObserver<Element>.s
    typealias DisposeKey = Observers.KeyType

    private let lock = RecursiveLock()

    private var disposed = false
    private var observers = Observers()
    private var stopped = false
    private var stoppedEvent: Event<Element>?
}
```

Besides some old friends, there are a few new abstractions here. Let’s go one by one.

### SynchronizedUnsubscribeType

`SynchronizedUnsubscribeType` is a protocol:

```swift
protocol SynchronizedUnsubscribeType: AnyObject {
    associatedtype DisposeKey

    func synchronizedUnsubscribe(_ disposeKey: DisposeKey)
}
```

This protocol defines a single method, `synchronizedUnsubscribe(_:)`. From the signature, it looks like it unsubscribes based on a key. Judging from the name, the "synchronized" probably indicates that it’s thread-safe. There’s not a lot of information in the protocol itself; we’ll have a clearer picture when we see it used in context, so we’ll park it for now.

### Observers

`Observers` is a typealias of `AnyObserver<Element>.s`, and `AnyObserver<Element>.s` is itself just a typealias of `Bag<(Event<Element>) -> Void>`. So the key data structure here is `Bag`.

`Bag` is defined in the same directory as `Queue` (which we discussed in the [previous article](/rxswift-scheduler/)). It’s a basic data structure representing a "bag" (multiset) of **a small number** of elements (the same element can be stored multiple times).

Due to space, I won’t paste the `Bag` source here. If you’re interested, you can read it on [GitHub](https://github.com/ReactiveX/RxSwift/blob/main/Platform/DataStructures/Bag.swift). I’ll briefly describe how it works.

`Bag` stores data as key-value pairs, where the key is a `UInt64` and the value is a generic `T`. Conceptually, it’s similar to a `Dictionary`. So why define a separate type?

Someone actually opened an [issue](https://github.com/ReactiveX/RxSwift/issues/2352) asking a similar question, but RxSwift’s issues are not really used to explain design decisions, and I couldn’t find much in Slack either. Based on the `Bag` implementation, my view is that it’s done for optimization:

- When inserting elements, if they can be stored inline, they’re stored inline.
- Otherwise, it initializes a `ContiguousArray` to store them.
- If the array grows beyond a threshold, it switches to a `Dictionary`.

This avoids unnecessary allocations. In most Rx use cases there is only one observer, which means inline storage is enough. From the caller’s perspective, you can simply treat `Observers` as a collection of event handlers.

### DisposeKey

`DisposeKey` is a typealias of `Observers.KeyType`, which is a typealias of `BagKey`:

```swift
struct BagKey {
    fileprivate let rawValue: UInt64
}
```

`BagKey` is essentially just a tiny wrapper around a `UInt64`, exposed as an opaque type.

With that foundation in place, let’s look at the rest of `PublishSubject`.

Because `PublishSubject` has to deal with multi-threaded access, it uses a recursive lock internally to ensure thread safety. As a result, its methods are usually split into two variants (this pattern is also used by other Subject types): `someMethod()` and `synchronized_someMethod()` (or similarly named). The synchronized version does the real work, and the public method simply acquires the lock and delegates to it. We’ll focus on the synchronized variants.

### Observer side

```swift
public func on(_ event: Event<Element>) {
    dispatch(synchronized_on(event), event)
}

func synchronized_on(_ event: Event<Element>) -> Observers {
    lock.lock(); defer { lock.unlock() }

    switch event {
    case .next:
        if isDisposed || stopped {
            return Observers()
        }

        return observers
    case .completed, .error:
        if stoppedEvent == nil {
            stoppedEvent = event
            stopped = true
            let observers = self.observers
            self.observers.removeAll()
            return observers
        }

        return Observers()
    }
}
```

`synchronized_on(_:)` returns the appropriate set of `observers` based on the incoming event:

1. For `.next` events: if the `PublishSubject` has already received a `.completed` or `.error`, it returns an empty collection; otherwise, it returns the current `observers`.
2. For `.completed` or `.error` events: if this is the first terminal event, it records it in `stoppedEvent`, sets `stopped` to `true`, clears and returns the current `observers`; otherwise it returns an empty collection.

`dispatch(_:, _:)` is an extension on `Bag`:

```swift
func dispatch<Element>(_ bag: Bag<(Event<Element>) -> Void>, _ event: Event<Element>) {
    bag._value0?(event)

    if bag._onlyFastPath {
        return
    }

    let pairs = bag._pairs
    for i in 0 ..< pairs.count {
        pairs[i].value(event)
    }

    if let dictionary = bag._dictionary {
        for element in dictionary.values {
            element(event)
        }
    }
}
```

This method simply calls each event handler in `bag` with the given `event`. When there are no observers, this is effectively just iterating an empty collection, i.e. the event is "dropped".

Putting `synchronized_on(_:)` and `dispatch(_:, _:)` together, we can see that:

1. Once a `PublishSubject` instance has received a terminal event, none of its existing observers receive any further events. In other words, the stream has ended.
2. A `PublishSubject` instance emits events even when it has no subscribers. This is what we usually mean when we say `PublishSubject` is a "hot" observable. In contrast, an `Observable` created via `Observable.create` is "cold": it only starts emitting events when subscribed to.

Incidentally, `PublishSubject`’s observer is itself:

```swift
public func asObserver() -> PublishSubject<Element> {
    self
}
```

### Observable side

```swift
func synchronized_subscribe<Observer: ObserverType>(_ observer: Observer) -> Disposable where Observer.Element == Element {
    if let stoppedEvent = self.stoppedEvent {
        observer.on(stoppedEvent)
        return Disposables.create()
    }

    if isDisposed {
        observer.on(.error(RxError.disposed(object: self)))
        return Disposables.create()
    }

    let key = observers.insert(observer.on)
    return SubscriptionDisposable(owner: self, key: key)
}
```

From this we can see that when subscribing to a `PublishSubject`:

- If the subject has already terminated, it immediately sends the terminal event to the new observer and ends the subscription.
- If it has been disposed, it sends an error indicating the subject has been disposed, and ends the subscription.

In other words, you can always "successfully" subscribe to an already-ended `PublishSubject`, whether or not it has been disposed—what you get is simply the appropriate terminal event.

In the normal case, it just inserts the observer’s `on` handler into `observers`, so that it will receive all subsequent events.

The returned `Disposable` is a `SubscriptionDisposable`. Let’s look at its definition:

```swift
struct SubscriptionDisposable<T: SynchronizedUnsubscribeType> : Disposable {
    private let key: T.DisposeKey
    private weak var owner: T?

    init(owner: T, key: T.DisposeKey) {
        self.owner = owner
        self.key = key
    }

    func dispose() {
        self.owner?.synchronizedUnsubscribe(self.key)
    }
}
```

`SubscriptionDisposable` is simple: when disposed, it calls `owner.synchronizedUnsubscribe(key)`. This is where `SynchronizedUnsubscribeType` comes into play.

Since we’re talking about unsubscribe, let’s check the corresponding code in `PublishSubject`:

```swift
func synchronized_unsubscribe(_ disposeKey: DisposeKey) {
    _ = observers.removeKey(disposeKey)
}
```

Unsubscribing just removes from `observers` the entry associated with that key. Disposing a particular subscription to a `PublishSubject` effectively removes the corresponding observer.

A small detail: it only removes the observer associated with that specific subscription’s key. If you subscribe the _same_ observer multiple times to the same `PublishSubject` (I haven’t needed to do this in real code), disposing one subscription does not cancel all subscriptions of that observer.

Finally, disposal of the subject itself:

```swift
final func synchronized_dispose() {
    disposed = true
    observers.removeAll()
    stoppedEvent = nil
}
```

Disposing a `PublishSubject` clears all observers and sets the `disposed` flag to `true`.

## BehaviorSubject

`BehaviorSubject` is probably the second most commonly used Subject for me (if not the first). Functionally, it’s quite similar to `PublishSubject`.

`BehaviorSubject` requires an initial value at initialization:

```swift
public init(value: Element) {
    self.element = value
}
```

`BehaviorSubject` stores the latest value it has received in `element`, so you can retrieve it via `value()`:

```swift
public func value() throws -> Element {
    lock.lock(); defer { lock.unlock() }

    if isDisposed {
        throw RxError.disposed(object: self)
    }

    if let error = stoppedEvent?.error {
        // intentionally throw exception
        throw error
    } else {
        return element
    }
}
```

Besides retrieving the latest value, the biggest difference between `BehaviorSubject` and `PublishSubject` is this: when you subscribe to a `BehaviorSubject`, the observer will _first_ receive the last `.next` event emitted before the subscription:

```swift
func synchronized_subscribe<Observer: ObserverType>(_ observer: Observer) -> Disposable where Observer.Element == Element {
    if isDisposed {
        observer.on(.error(RxError.disposed(object: self)))
        return Disposables.create()
    }

    if let stoppedEvent = self.stoppedEvent {
        observer.on(stoppedEvent)
        return Disposables.create()
    }

    let key = observers.insert(observer.on)
    observer.on(.next(self.element))

    return SubscriptionDisposable(owner: self, key: key)
}
```

Here, on subscription, `observer.on(.next(self.element))` is immediately called, whereas `PublishSubject` does not behave this way. This makes `BehaviorSubject` well suited for scenarios where a stream needs an initial value.

Note that the order of checks for `isDisposed` and `stoppedEvent` is the opposite of `PublishSubject`. Once a `BehaviorSubject` has been disposed, any new subscriptions always receive an error event. A `BehaviorSubject` represents a value that changes over time; once time has "ended", that value no longer makes sense.

The rest of `BehaviorSubject`’s implementation is very similar to `PublishSubject` (since their behavior is similar), and its observer is also itself. I won’t paste more code here; if you’re interested, see the source on [GitHub](https://github.com/ReactiveX/RxSwift/blob/main/RxSwift/Subjects/BehaviorSubject.swift).

## ReplaySubject

If `BehaviorSubject` buffers a single value, `ReplaySubject` buffers _n_ values. You can think of `BehaviorSubject` as a special case of `ReplaySubject` (although in practice I haven’t used `ReplaySubject` much myself).

`ReplaySubject`’s code is also quite similar to the other Subjects, so I won’t paste the full source. We’ll focus on what’s unique to `ReplaySubject`; see [GitHub](https://github.com/ReactiveX/RxSwift/blob/main/RxSwift/Subjects/ReplaySubject.swift) for the complete code.

`ReplaySubject` itself is an abstract class that internally uses different concrete subclasses depending on the buffer size:

```swift
public static func create(bufferSize: Int) -> ReplaySubject<Element> {
    if bufferSize == 1 {
        return ReplayOne()
    }
    else {
        return ReplayMany(bufferSize: bufferSize)
    }
}

public static func createUnbounded() -> ReplaySubject<Element> {
    ReplayAll()
}
```

You normally create `ReplaySubject`s via these APIs. Instantiating `ReplaySubject` itself directly will result in a runtime error.

Most methods on `ReplaySubject` are abstract and must be overridden by subclasses. The only common part is that `asObserver()` always returns `ReplaySubject<Element>`, since only `ReplaySubject` itself is exposed publicly.

Let’s explore the subclass implementations.

### ReplayBufferBase

The `ReplayOne`, `ReplayMany`, and `ReplayAll` types do not directly inherit from `ReplaySubject`; instead, they inherit from a base class `ReplayBufferBase`:

```swift
private class ReplayBufferBase<Element>: ReplaySubject<Element>, SynchronizedUnsubscribeType {
    func trim() {
        rxAbstractMethod()
    }

    func addValueToBuffer(_ value: Element) {
        rxAbstractMethod()
    }

    func replayBuffer<Observer: ObserverType>(_ observer: Observer) where Observer.Element == Element {
        rxAbstractMethod()
    }
}
```

These methods are all meant to be implemented by subclasses. Even without the implementations, their purposes are fairly clear:

1. `trim()`: trim the buffer.
2. `addValueToBuffer(_:)`: add a value to the buffer.
3. `replayBuffer(_:)`: replay buffered values to an observer.

You can also see their roles from how `ReplayBufferBase` implements the `Observable` and `Observer` parts:

```swift
func synchronized_on(_ event: Event<Element>) -> Observers {
    lock.lock(); defer { lock.unlock() }

    if isDisposed || isStopped {
        return Observers()
    }

    switch event {
    case .next(let element):
        addValueToBuffer(element)
        trim()
        return observers
    case .error, .completed:
        stoppedEvent = event
        trim()
        let observers = self.observers
        observers.removeAll()
        return observers
    }
}

func synchronized_subscribe<Observer: ObserverType>(_ observer: Observer) -> Disposable where Observer.Element == Element {
    if isDisposed {
        observer.on(.error(RxError.disposed(object: self)))
        return Disposables.create()
    }

    let anyObserver = observer.asObserver()

    self.replayBuffer(anyObserver)
    if let stoppedEvent = self.stoppedEvent {
        observer.on(stoppedEvent)
        return Disposables.create()
    }
    else {
        let key = observers.insert(observer.on)
        return SubscriptionDisposable(owner: self, key: key)
    }
}
```

This confirms our guesses:

1. In `synchronized_on(_:)`, when receiving a `.next` event, it first adds the value to the buffer, then trims the buffer; when receiving `.error` or `.completed`, it trims the buffer once more.
2. In `synchronized_subscribe(_:)`, i.e. when subscribing, it first replays the buffer to the observer.

The dispose and unsubscribe logic is shared in `ReplayBufferBase` and is essentially the same as `BehaviorSubject`, so we won’t repeat it. Let’s look at the concrete subclasses instead.

### ReplayOne

```swift
private final class ReplayOne<Element> : ReplayBufferBase<Element> {
    private var value: Element?

    override func trim() {

    }

    override func addValueToBuffer(_ value: Element) {
        self.value = value
    }

    override func replayBuffer<Observer: ObserverType>(_ observer: Observer) where Observer.Element == Element {
        if let value = self.value {
            observer.on(.next(value))
        }
    }

    override func synchronized_dispose() {
        super.synchronized_dispose()
        self.value = nil
    }
}
```

As the name suggests, `ReplayOne` buffers only a single value. The code is straightforward: store the latest value in a variable and clear it on dispose.

### ReplayMany and ReplayAll

These two are similar enough that we can discuss them together:

```swift
private class ReplayManyBase<Element>: ReplayBufferBase<Element> {
    fileprivate var queue: Queue<Element>

    init(queueSize: Int) {
        self.queue = Queue(capacity: queueSize + 1)
    }

    override func addValueToBuffer(_ value: Element) {
        self.queue.enqueue(value)
    }

    override func replayBuffer<Observer: ObserverType>(_ observer: Observer) where Observer.Element == Element {
        for item in self.queue {
            observer.on(.next(item))
        }
    }

    override func synchronized_dispose() {
        super.synchronized_dispose()
        self.queue = Queue(capacity: 0)
    }
}

private final class ReplayMany<Element> : ReplayManyBase<Element> {
    private let bufferSize: Int

    init(bufferSize: Int) {
        self.bufferSize = bufferSize

        super.init(queueSize: bufferSize)
    }

    override func trim() {
        while self.queue.count > self.bufferSize {
            _ = self.queue.dequeue()
        }
    }
}

private final class ReplayAll<Element> : ReplayManyBase<Element> {
    init() {
        super.init(queueSize: 0)
    }

    override func trim() {

    }
}
```

Again, the implementation is straightforward. Both `ReplayMany` and `ReplayAll` inherit from `ReplayManyBase`, which uses a `Queue` to buffer values. The differences:

1. `ReplayMany` trims the queue according to `bufferSize`, while `ReplayAll` does not.
2. `ReplayMany` initializes the queue with `bufferSize`, while `ReplayAll` uses 0, since you can’t know in advance how many values will be stored.

One subtlety: in `ReplayManyBase`, the queue is initialized with `queueSize + 1` rather than `queueSize`. This is because in `synchronized_on(_:)`, `addValueToBuffer(_:)` is called before `trim()`. That means the maximum number of elements in the queue is one more than the logical buffer size.

As for `ReplayAll`, there’s an important detail: its implementation is extremely simple—it never trims the buffer. So if you use `ReplayAll` (via `createUnbounded()`), you must ensure that the number of values remains within a reasonable range; otherwise you risk an OOM.

## AsyncSubject

To be honest, this is the first time I’ve really paid attention to `AsyncSubject`. Skimming the docs, an `AsyncSubject` will emit only the _last_ value from the sequence to each subscriber, regardless of how many values the sequence actually produced. For use cases, you can refer to [this article](https://www.learn-it-with-examples.com/development/html-css-javascript/angular/what-asyncsubject-angular.html); here we’ll stay focused on the source.

`AsyncSubject`’s code is also similar to the other Subject types, so I won’t paste the whole thing. We’ll only look at what’s specific to `AsyncSubject`; see [GitHub](https://github.com/ReactiveX/RxSwift/blob/main/RxSwift/Subjects/AsyncSubject.swift) for details.

### Observer side

```swift
public func on(_ event: Event<Element>) {
    let (observers, event) = synchronized_on(event)

    switch event {
    case .next:
        dispatch(observers, event)
        dispatch(observers, .completed)
    case .completed:
        dispatch(observers, event)
    case .error:
        dispatch(observers, event)
    }
}

func synchronized_on(_ event: Event<Element>) -> (Observers, Event<Element>) {
    lock.lock(); defer { lock.unlock() }

    if self.isStopped {
        return (Observers(), .completed)
    }

    switch event {
    case .next(let element):
        lastElement = element
        return (Observers(), .completed)
    case .error:
        stoppedEvent = event

        let observers = self.observers
        self.observers.removeAll()

        return (observers, event)
    case .completed:
        let observers = self.observers
        self.observers.removeAll()

        if let lastElement = self.lastElement {
            stoppedEvent = .next(lastElement)
            return (observers, .next(lastElement))
        } else {
            stoppedEvent = event
            return (observers, .completed)
        }
    }
}
```

First, look at `synchronized_on(_:)`:

1. For `.next` events, it records the value into `lastElement` and returns an empty `observers` set.
2. For `.error` events, it records the event in `stoppedEvent`, sets `stopped` to `true`, clears `observers`, and returns the previous `observers` along with the error event.
3. For `.completed` events:
   - If there is a `lastElement`, it records `.next(lastElement)` in `stoppedEvent`, sets `stopped` to `true`, clears `observers`, and returns the previous `observers` and the `.next(lastElement)` event.
   - Otherwise it records the `.completed` event in `stoppedEvent`, sets `stopped` to `true`, clears `observers`, and returns the previous `observers` and the `.completed` event.

Then look at `on(_:)`. Based on what `synchronized_on(_:)` returned:

1. For `.next`, `observers` is empty, so the event is effectively dropped.
2. For `.error`, it dispatches the error event to all current observers.
3. For `.completed`:
   - If there was a previous `.next` event, it dispatches the latest `.next` event to observers.

     There’s a subtlety here: it does _not_ also send a `.completed` event at this point, which is not strictly necessary for observers (though personally I suspect that `dispatch(observers, .completed)` in the `.next` case might have been intended for here instead).

   - Otherwise, it dispatches a `.completed` event to observers.

### Observable side

```swift
func synchronized_subscribe<Observer: ObserverType>(_ observer: Observer) -> Disposable where Observer.Element == Element {
    if let stoppedEvent = self.stoppedEvent {
        switch stoppedEvent {
        case .next:
            observer.on(stoppedEvent)
            observer.on(.completed)
        case .completed:
            observer.on(stoppedEvent)
        case .error:
            observer.on(stoppedEvent)
        }
        return Disposables.create()
    }

    let key = observers.insert(observer.on)

    return SubscriptionDisposable(owner: self, key: key)
}
```

Here, when a new observer subscribes to an `AsyncSubject`:

- If the stream has already ended, it immediately sends the final `.next` (that is, `stoppedEvent` when it’s `.next`) **and** the actual terminal event to the observer, then ends the subscription. (For `.completed` and `.error` cases, that terminal event is just `stoppedEvent` itself.)
- Otherwise, it subscribes normally, and future events flow through the `on(_:)` logic described above.

At this point the logic is clear: `AsyncSubject` implements this behavior by tracking both `lastElement` and `stoppedEvent`.

I still don’t have a great intuition for what exactly the "Async" in `AsyncSubject` is meant to convey—it’s probably more about typical usage patterns than anything inherent in the implementation.

## Summary

In this article we’ve added another member to our mental model of RxSwift: `Subject`. If `Observable` and `Observer` form a one-to-one relationship, then `Subject` and its observers form a one-to-many relationship (with the additional distinction between "hot" and "cold"). A Subject often acts as a multicast hub, wiring together value changes and observers that are not logically co-located.

Each Subject type in Rx has its own semantics and use cases. I hope this article helps deepen your understanding of Subjects.

## References

- [ReactiveX/RxSwift: Reactive Programming in Swift](https://github.com/ReactiveX/RxSwift)
- [Bag seems to be a combination of Dictionary and ContiguousArray, why? · Issue #2352 · ReactiveX/RxSwift · GitHub](https://github.com/ReactiveX/RxSwift/issues/2352)
- [What a AsyncSubject is in Angular ? \| AsyncSubject usage with an example in Angular.](https://www.learn-it-with-examples.com/development/html-css-javascript/angular/what-asyncsubject-angular.html)
