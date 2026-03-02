---
layout: page
title: "RxSwift Source Code Reading Part I - Observable & Observer"
date: 2020-03-13
permalink: /rxswift-observable-observer/
---

```swift
example("hello") {
    let disposeBag = DisposeBag()

    Observable.create { observer -> Disposable in
        observer.onNext("Hello World")
        observer.onCompleted()
        observer.onNext("Hello again")
    }
    .subscribe { event in
        print(event)
    }
    .disposed(by: disposeBag)
}
```

If the code above runs correctly, you will finally see the following printed in the console:

```
next(Hello World)
completed
```

In this article we'll start from this example and explain its inner workings from RxSwift's source code perspective.

## Before We Start

- The code in this article is based on RxSwift 5.0.1.
- This article assumes you have some experience using RxSwift.
- The snippets from the source code shown here omit parts related to debugging, generics, and comments. You can find the complete source on GitHub.

## Observer

An `Observer` is, literally, the observer, and what it observes is the `Observable`. We'll talk about what an `Observable` is later; for now let's focus on the `Observer`. The starting point of `Observer` is `ObserverType`, whose definition is as follows:

```swift
public protocol ObserverType {
    associatedtype Element

    func on(_ event: Event<Element>)
}
```

You can see that `ObserverType` has only one responsibility: respond to an `Event`.

Before we continue with `ObserverType`, let's take a detour and look at `Event`.

The definition of `Event` itself is very simple: it's an enum that represents `next | completed | error`, and it provides some APIs to conveniently extract the data in the event and to determine the event's type.

While reading the source I noticed a detail: `Event` itself conforms to a protocol called `EventConvertible`. This protocol looks very similar to `Event`. Why bother defining an extra protocol? We'll leave that for another time and skip it here.

Back to `ObserverType`. This type also defines methods `onNext(_:)`, `onCompleted()`, and `onError(_:)`. These are essentially just lightweight wrappers over the `on(_:)` method above, so we won't go into detail.

By searching through the code, we can get a rough relationship chain around `ObserverType`: `ObserverType` -> `ObserverBase` -> `AnonymousObserver`.

Let's first look at `ObserverBase`. Its own definition is also very concise:

```swift
class ObserverBase<Element> : Disposable, ObserverType {
    private let _isStopped = AtomicInt(0)

    func on(_ event: Event<Element>) {
        switch event {
        case .next:
            if load(self._isStopped) == 0 {
                self.onCore(event)
            }
        case .error, .completed:
            if fetchOr(self._isStopped, 1) == 0 {
                self.onCore(event)
            }
        }
    }

    func onCore(_ event: Event<Element>) {
        rxAbstractMethod()
    }

    func dispose() {
        fetchOr(self._isStopped, 1)
    }
}
```

As a base class, `ObserverBase` centralizes the common logic for handling `Event`s defined by `ObserverType`, and at the same time provides an `onCore(_:)` method. The `on(_:)` method still forwards the event to this method. Subclasses handle events by implementing `onCore(_:)`.

RxSwift uses this design pattern in several other places as well: provide a base class that conforms to some protocol, implement the protocol methods in the base class to hold common logic, and provide a similar method for subclasses to override. This way, when implementing subclasses you don't have to worry about the common logic and can focus only on the specific behavior. The `Producer` type we'll talk about later is another example.

From the snippet above we can see that `ObserverBase` uses an `AtomicInt` `_isStopped` internally to track state. So what is `AtomicInt`? Let's go take a look at its definition:

```swift
final class AtomicInt: NSLock {
    fileprivate var value: Int32
    public init(_ value: Int32 = 0) {
        self.value = value
    }
}

@discardableResult
@inline(__always)
func add(_ this: AtomicInt, _ value: Int32) -> Int32 {
    this.lock()
    let oldValue = this.value
    this.value += value
    this.unlock()
    return oldValue
}

@discardableResult
@inline(__always)
func sub(_ this: AtomicInt, _ value: Int32) -> Int32 {
    this.lock()
    let oldValue = this.value
    this.value -= value
    this.unlock()
    return oldValue
}

@discardableResult
@inline(__always)
func fetchOr(_ this: AtomicInt, _ mask: Int32) -> Int32 {
    this.lock()
    let oldValue = this.value
    this.value |= mask
    this.unlock()
    return oldValue
}

@inline(__always)
func load(_ this: AtomicInt) -> Int32 {
    this.lock()
    let oldValue = this.value
    this.unlock()
    return oldValue
}
```

We can see that `AtomicInt` is essentially an `NSLock` that wraps an `Int32` value. The provided APIs all operate on this value and use the lock to guarantee thread safety, and each of these methods returns the value before the operation.

At this point I had a question: why not just use a `Bool`? Why define an extra type, and why do these APIs return the old value, which looks a bit strange at first? So I checked the commit history and found that `AtomicInt` used to be defined differently. It used to be defined via macros in `RxAtomic.h` as a wrapper around `stdatomic.h`, implementing lock-free programming style operations for sharing data among multiple threads. `RxAtomic` was later split out of RxSwift, and only then was it changed to the current lock-based implementation. If you're familiar with lock-free programming these APIs will look very familiar.

After a basic understanding of `AtomicInt`, let's go back to the `on(_:)` method of `ObserverBase`:

1. When a `.next` event arrives, it first checks the `isStopped` state. If it's 0, it continues handling the `.next` event; if it's 1, the `.next` event will be dropped.
2. When an `.error` or `.completed` event arrives for the first time, it sets `isStopped` to 1, and `fetchOr` returns the previous value 0, so it continues handling the current event.
3. When another `.error` or `.completed` event arrives later, `isStopped` is again set to 1, but this time `fetchOr` returns 1, and the current event will be dropped.

From this point on, no matter what events come in, `ObserverBase` and its subclasses will no longer respond. This is, at an abstract level in RxSwift, why an `Observable` stops producing new events after a terminal event.

Now let's turn to `AnonymousObserver`. After removing some debug-only logic, its definition looks like this:

```swift
final class AnonymousObserver<Element>: ObserverBase<Element> {
    typealias EventHandler = (Event<Element>) -> Void

    private let _eventHandler : EventHandler

    init(_ eventHandler: @escaping EventHandler) {
        self._eventHandler = eventHandler
    }

    override func onCore(_ event: Event<Element>) {
        return self._eventHandler(event)
    }
}
```

`AnonymousObserver` is very simple: you pass in an `EventHandler` when creating it, it stores it internally, and whenever a new event is observed it uses the handler to process that event.

There is another `Observer` type that has to be mentioned: `AnyObserver`. As the name suggests, `AnyObserver` is used for type erasure. Its definition is as follows:

```swift
public struct AnyObserver<Element> : ObserverType {
    public typealias EventHandler = (Event<Element>) -> Void

    private let observer: EventHandler

    public init(eventHandler: @escaping EventHandler) {
        self.observer = eventHandler
    }

    public init<Observer: ObserverType>(_ observer: Observer) where Observer.Element == Element {
        self.observer = observer.on
    }

    public func on(_ event: Event<Element>) {
        return self.observer(event)
    }

    public func asObserver() -> AnyObserver<Element> {
        return self
    }
}
```

`AnyObserver` can be initialized with either an `EventHandler` or another `Observer`. The implementation is straightforward, so we won't go into more detail here. There is also an `asObserver()` method whose original definition is in an extension on `ObserverType`:

```swift
extension ObserverType {
    public func asObserver() -> AnyObserver<Element> {
        return AnyObserver(self)
    }
}
```

The default implementation of this method erases the concrete `Observer` type and returns a unified `AnyObserver`, while `AnyObserver`'s own `asObserver()` simply returns `self`.

## Disposable and Cancelable

Before talking about `Observable`, let's talk about `Disposable` and `Cancelable`. Their definitions are as follows:

```swift
public protocol Disposable {
    func dispose()
}

public protocol Cancelable : Disposable {
    var isDisposed: Bool { get }
}
```

`Disposable` is very simple: it only has a `dispose()` method, which defines how to release resources. `Cancelable` extends `Disposable` by adding a flag indicating whether it has been disposed.

We'll come back to `Disposable` later; for now just have a rough idea of it.

## Observable

Let's briefly introduce `Observable`. Here I list all the related definitions together:

```swift
public protocol ObservableConvertibleType {
    associatedtype Element

    func asObservable() -> Observable<Element>
}

public protocol ObservableType : ObservableConvertibleType {
     func subscribe<Observer: ObserverType>(_ observer: Observer) -> Disposable where Observer.Element == Element
}

extension ObservableType {
    public func asObservable() -> Observable<Element> {
        return Observable.create { o in
            return self.subscribe(o)
        }
    }
}

public class Observable<Element> : ObservableType {
    public func subscribe<Observer: ObserverType>(_ observer: Observer) -> Disposable where Observer.Element == Element {
        rxAbstractMethod()
    }

    public func asObservable() -> Observable<Element> {
        return self
    }
}
```

From this we can see the relationships among these types: `Observable` -> `ObservableType` -> `ObservableConvertibleType`. The primary responsibility of `Observable` is to be subscribed to by an `Observer`, that is, to let an `Observer` receive events.

At first glance, the name of the `subscribe` method in `ObservableType` may feel counterintuitive, because your first impression is probably that an `Observer` subscribes to an `ObservableType`. Why is the interface named the other way around? When I first read the code I got stuck on this naming for a while. Eventually I gave up nitpicking and accepted that this is just a name. You could as well rename `subscribe` to `add`, and then it becomes `Observable` add `Observer`, the well-known observer pattern.

`ObservableType` conforms to `ObservableConvertibleType` and provides the default implementation of `ObservableConvertibleType`: it wraps the concrete `ObservableType` in a new `Observable`. This new `Observable` simply passes the `observer` to the current `ObservableType`'s `subscribe`. The implementation in `Observable` itself just returns `self`. You can see that the main role of `Observable` is to erase the concrete `ObservableType` type, and it also serves as the abstract base class for the many different concrete `Observable` types. Each concrete `Observable` implements its own `subscribe(_:)`.

## Sink

`Sink` literally means a sink or a basin. If we think of `Observable` as a stream, then `Sink` is the place where the stream is processed. You could say `Sink` is the basis on which RxSwift implements chaining operators, but that's not the focus of this article—we'll come back to it when we talk about operators. For now, we'll skip those details. Let's first look at the definition of `Sink`:

```swift
class Sink<Observer: ObserverType> : Disposable {
    fileprivate let _observer: Observer
    fileprivate let _cancel: Cancelable
    private let _disposed = AtomicInt(0)

    init(observer: Observer, cancel: Cancelable) {
        self._observer = observer
        self._cancel = cancel
    }

    final func forwardOn(_ event: Event<Observer.Element>) {
        if isFlagSet(self._disposed, 1) {
            return
        }
        self._observer.on(event)
    }

    final var disposed: Bool {
        return isFlagSet(self._disposed, 1)
    }

    func dispose() {
        fetchOr(self._disposed, 1)
        self._cancel.dispose()
    }
```

`Sink` itself is a `Disposable`. To initialize a `Sink` you need to provide an `Observer` and a `Cancelable`, which it holds internally. From the definition you can see that `Sink` is mostly a wrapper that encapsulates an `Observer` and a `Cancelable`. It doesn't process `Event`s itself; instead it forwards them to the internal `Observer`. But before forwarding, it checks whether it has been disposed; if it has, it no longer forwards events. Its `dispose` method simply calls `dispose` on the `Cancelable`, plus some logic to ensure it's disposed only once. Here it again uses an `AtomicInt` as a flag.

Later we'll see that not all `Observer` subclasses inherit from `ObserverBase`, so similar logic is needed elsewhere to ensure that after the first terminal event, subsequent events are no longer handled. This is exactly what `Sink` does.

## Producer

Almost all of RxSwift's built-in `Observable` subclasses do not directly inherit from `Observable`; instead they inherit from `Producer`, and `Producer` itself inherits from `Observable`. `Producer` is tightly coupled with `Sink`. Let's look at its definition:

```swift
class Producer<Element> : Observable<Element> {
    override func subscribe<Observer: ObserverType>(_ observer: Observer) -> Disposable where Observer.Element == Element {
      // Code related to Scheduler omitted
      let disposer = SinkDisposer()
      let sinkAndSubscription = self.run(observer, cancel: disposer)
      disposer.setSinkAndSubscription(sink: sinkAndSubscription.sink, subscription: sinkAndSubscription.subscription)
      return disposer
    }

    func run<Observer: ObserverType>(_ observer: Observer, cancel: Cancelable) -> (sink: Disposable, subscription: Disposable) where Observer.Element == Element {
        rxAbstractMethod()
    }
}
```

From the definition we can see that `Producer` overrides the `subscribe(_:)` method and provides an additional `run(_:cancel:)` method for subclasses to implement. This follows the same design idea as `ObserverBase`: `Producer`, as a base class, concentrates the common logic, and provides a new method for subclasses. For now you can think of `run(_:cancel:)` as the `subscribe(_:)` method of each concrete `Producer` subclass.

The `subscribe(_:)` method of `Producer` introduces a `SinkDisposer`, so let's go see what it does. Here's its definition:

```swift
private final class SinkDisposer: Cancelable {
    private enum DisposeState: Int32 {
        case disposed = 1
        case sinkAndSubscriptionSet = 2
    }

    private let _state = AtomicInt(0)
    private var _sink: Disposable?
    private var _subscription: Disposable?

    var isDisposed: Bool {
        return isFlagSet(self._state, DisposeState.disposed.rawValue)
    }

    func setSinkAndSubscription(sink: Disposable, subscription: Disposable) {
        self._sink = sink
        self._subscription = subscription

        let previousState = fetchOr(self._state, DisposeState.sinkAndSubscriptionSet.rawValue)
        if (previousState & DisposeState.sinkAndSubscriptionSet.rawValue) != 0 {
            rxFatalError("Sink and subscription were already set")
        }

        if (previousState & DisposeState.disposed.rawValue) != 0 {
            sink.dispose()
            subscription.dispose()
            self._sink = nil
            self._subscription = nil
        }
    }

    func dispose() {
        let previousState = fetchOr(self._state, DisposeState.disposed.rawValue)

        if (previousState & DisposeState.disposed.rawValue) != 0 {
            return
        }

        if (previousState & DisposeState.sinkAndSubscriptionSet.rawValue) != 0 {
            guard let sink = self._sink else {
                rxFatalError("Sink not set")
            }
            guard let subscription = self._subscription else {
                rxFatalError("Subscription not set")
            }

            sink.dispose()
            subscription.dispose()

            self._sink = nil
            self._subscription = nil
        }
    }
}
```

`SinkDisposer` conforms to `Cancelable` and uses an `AtomicInt` internally to track state.

First look at its `setSinkAndSubscription(sink:subscription:)` method. If it's called for the first time, `previousState` is 0, so neither of the two `if` branches is taken. `sink` and `subscription` are set normally, and `_state` becomes `sinkAndSubscriptionSet`. If you call this method again before disposal, you'll hit a `fatalError`, which indicates a logic error that we can ignore here.

If `_state` has been set to `disposed`—that is, `dispose()` has been called—then calling `setSinkAndSubscription(sink:subscription:)` will immediately dispose both `sink` and `subscription` and clear their references. You can think of this as subscribing to an `Observable` that has already completed: the subscription ends immediately. (Note that the `Observable` in our example is a cold observable: re-subscribing will re-run the observable logic, meaning you'll see those two log lines printed again.)

The `dispose()` method works similarly, ensuring that only the first call is effective and subsequent calls do nothing, because the caller might manually dispose early.

With `SinkDisposer` understood, let's go back to `Producer`. Every time a `Producer` is subscribed to, a new `SinkDisposer` instance is created and the final returned value is exactly this instance. This is the `Disposable` instance returned by `subscribe(_:)` in the example at the beginning.

There's still that `run(_:cancel:)` method, but let's leave it hanging for a moment. Note that the newly created `SinkDisposer` is passed in as the second argument to `run(_:cancel:)`.

## From Points to a Line

We now have most of the pieces, so we can return to the initial example and start exploring how it works.

Let's look again at the implementation of the `subscribe` method used in the example:

```swift
extension ObservableType {
    public func subscribe(_ on: @escaping (Event<Element>) -> Void) -> Disposable {
        let observer = AnonymousObserver { e in
            on(e)
        }
        return self.asObservable().subscribe(observer)
    }
```

We can now see why we never have to manually create observers when using RxSwift, even though it's based on the observer pattern: RxSwift has already created an anonymous `Observer` for you from the closure you pass in, then uses that `Observer` to subscribe to the corresponding `Observable`. This `Observer` is the origin of the `observer` parameter in `Observable.create` (note: it's the origin, not the exact same instance; some transformations happen in between).

Looking back at the `Observable` creation process in the example, we can see that the essence of thinking of `Observable` as a stream or an array is simply repeatedly calling `ObserverType`'s `on(_:)`. The concept of `Observable` only exists because we have `Observer`.

Now let's look at the implementation of `Observable.create`:

```swift
extension ObservableType {
    public static func create(_ subscribe: @escaping (AnyObserver<Element>) -> Disposable) -> Observable<Element> {
        return AnonymousObservable(subscribe)
    }
}
```

There's only one line: it simply returns an `AnonymousObservable`. From what we've seen so far, we can easily guess that `AnonymousObservable` will hold the `subscribe` closure and call it when being subscribed to, passing in the `AnonymousObserver` we just discussed.

To verify that, let's look at the definition of `AnonymousObservable`:

```swift
final private class AnonymousObservable<Element>: Producer<Element> {
    typealias SubscribeHandler = (AnyObserver<Element>) -> Disposable

    let _subscribeHandler: SubscribeHandler

    init(_ subscribeHandler: @escaping SubscribeHandler) {
        self._subscribeHandler = subscribeHandler
    }

    override func run<Observer: ObserverType>(_ observer: Observer, cancel: Cancelable) -> (sink: Disposable, subscription: Disposable) where Observer.Element == Element {
        let sink = AnonymousObservableSink(observer: observer, cancel: cancel)
        let subscription = _subscribeHandler(AnyObserver(sink))
        return (sink: sink, subscription: subscription)
    }
}

final private class AnonymousObservableSink<Observer: ObserverType>: Sink<Observer>, ObserverType {
    typealias Element = Observer.Element
    typealias Parent = AnonymousObservable<Element>

    private let _isStopped = AtomicInt(0)

    override init(observer: Observer, cancel: Cancelable) {
        super.init(observer: observer, cancel: cancel)
    }

    func on(_ event: Event<Element>) {
        switch event {
        case .next:
            if load(self._isStopped) == 1 {
                return
            }
            self.forwardOn(event)
        case .error, .completed:
            if fetchOr(self._isStopped, 1) == 0 {
                self.forwardOn(event)
                self.dispose()
            }
        }
    }
}
```

`AnonymousObservable` is indeed a subclass of `Producer`. I've also included the definition of `AnonymousObservableSink`, since `Producer` and `Sink` almost always appear together. Note that the `Sink` type that appears with `Producer` not only inherits from the `Sink` we saw earlier, it also conforms to `ObserverType` itself, meaning it is itself an `Observer`. (To distinguish, let's call this `Sink` the `ProducerSink` below.)

The implementation of `AnonymousObservableSink` is very simple: it forwards events to its internal `observer`, and when disposed it disposes the `cancel` it holds. At the same time it uses `AtomicInt` to ensure only the first terminal event is forwarded; subsequent events are dropped.

Back to `AnonymousObservable`. In its implementation of `run(_:cancel:)`, it initializes an `AnonymousObservableSink` instance, then wraps this sink in `AnyObserver` and passes it into `_subscribeHandler`—which is exactly the `observer` in the `Observable.create` closure. Through these successive layers of wrapping, we finally arrive at the `print(event)` in our example and print the first two events.

Next let's see who the `cancel` held by `AnonymousObservableSink` actually is. From the `Producer` source we know that this `cancel` is the `sinkDisposer` we discussed above. As mentioned, `sinkDisposer` is exactly the `Disposable` the caller receives. When a terminal event arrives for the first time—that is, when the stream has completed—we dispose the `sinkDisposer` as well. At this point the subscription has ended and resources are automatically released.

We can now revisit `run(_:cancel:)`. This method returns a 2-tuple of `Disposable`s, and it's now clear what each is for:

1. The first is the `Disposable` created by RxSwift during the subscription process itself.
2. The second is the `Disposable` returned by the closure that created the `Observable`.

What the caller finally receives is a `Disposable` (`SinkDisposer`) that manages these two `Disposable`s together.

## A Second Look at Disposable

When creating an `Observable`, you may need extra resources to make it produce data—for example, a network request. `Disposable` is an abstraction of these resources, providing an opportunity to clean up or release them. From the outside, `Disposable` also represents the concept of a subscription. Cancelling a subscription is essentially releasing resources early so that the `Observer` no longer receives events.

RxSwift will usually call `dispose` for you automatically. However, when business logic becomes complex—e.g. an `Observable` may keep emitting new events indefinitely, or a network request might take a long time to complete—we often want to manage these subscriptions uniformly: for example, cancelling them automatically when the user leaves a screen. One way is to record each subscription individually and call `dispose` on each in `deinit`, but on a heavily RxSwift-based screen this is obviously unreasonable.

So RxSwift provides `DisposeBag`:

```swift
public final class DisposeBag: DisposeBase {

    private var _lock = SpinLock()

    fileprivate var _disposables = [[Disposable]]
    fileprivate var _isDisposed = false

    public func insert(_ disposable: Disposable) {
        self._insert(disposable)?.dispose()
    }

    private func _insert(_ disposable: Disposable) -> Disposable? {
        self._lock.lock(); defer { self._lock.unlock() }
        if self._isDisposed {
            return disposable
        }

        self._disposables.append(disposable)

        return nil
    }

    private func dispose() {
        let oldDisposables = self._dispose()

        for disposable in oldDisposables {
            disposable.dispose()
        }
    }

    private func _dispose() -> [Disposable] {
        self._lock.lock(); defer { self._lock.unlock() }

        let disposables = self._disposables

        self._disposables.removeAll(keepingCapacity: false)
        self._isDisposed = true

        return disposables
    }

    deinit {
        self.dispose()
    }
}
```

When you call `disposed(by:)` on a `Disposable`, it is inserted into the `DisposeBag` you pass in and thus bound to the lifetime of that `DisposeBag`. When the `DisposeBag` instance is deallocated, it iterates through all the `Disposable`s it holds and calls `dispose()` on each to release resources.

From the source we can see that a `DisposeBag` can only be disposed once. If you insert a new `Disposable` into an already-disposed `DisposeBag`, that `Disposable` is disposed immediately. Note also that it uses a recursive lock here, because `insert(_:)` might be called multiple times on the same thread, and a recursive lock prevents deadlock. Under the `Disposables` directory you'll also find several other `Disposable` types, each implementing a different cleanup behavior.

Finally, here's a diagram I drew to summarize the relationships among the types discussed in this article:

![rx_source_code_1-1.png](/published/rxswift-observable-observer/rx_source_code_1-1.png)

## Summary

At first glance, reading RxSwift's source code really requires patience, because there's a lot of abstraction. If you look only at the parts introduced in this article, it may feel over-engineered, but in fact these abstractions are designed to support other parts we haven't covered yet. There are still many worthwhile things to learn from RxSwift:

- The design of `Disposable` is a classic example of "program to an interface, not an implementation". All related code is written against `Disposable`, not any specific `Disposable` type.
- Each type has a very clear, single responsibility. For example, `Observable` -> `ObservableType` -> `ObservableConvertibleType`: each protocol defines exactly one responsibility, and concrete implementations focus only on their own responsibility, minimizing concerns.
- `AtomicInt` is used elegantly to handle different concurrency scenarios.

## References

- [ReactiveX/RxSwift: Reactive Programming in Swift](https://github.com/ReactiveX/RxSwift)
- [【领略RxSwift源码】- 订阅的工作流（Subscribing）](https://www.jianshu.com/p/af17ba8e5d14)
