---
layout: page
title: "RxSwift Part Source Code Reading IV - PrimitiveSequence"
date: 2022-06-28
permalink: /rxswift-primitivesequence/
---

Today let’s look at another concept in RxSwift — `PrimitiveSequence`.

You might not have heard the name `PrimitiveSequence` when using RxSwift day to day, but chances are you’ve already used it. For example, `Completable` is a `PrimitiveSequence`.

RxSwift positions `PrimitiveSequence` as a _Trait_. The key point of "trait" here is that it is _specialized_ rather than general-purpose. The opposite of "special" is "general", which in our case is the plain `Observable` we normally use. So you can think of a Trait as a specialized `Observable`.

If we already have `Observable`, why introduce `PrimitiveSequence`? Because `PrimitiveSequence` targets more concrete scenarios. In those scenarios, using a `PrimitiveSequence` is more convenient than using a raw `Observable`, and it also carries more contextual information.

So what kinds of `PrimitiveSequence` does RxSwift provide? And how are they implemented? This article will explore those questions from the viewpoint of the source code.

## Before We Start

- The code in this article is based on RxSwift 6.5.0.
- This article assumes you have some experience using RxSwift.
- The snippets from the source code shown here omit parts related to debugging, generics, and comments. You can find the complete source on GitHub.

## PrimitiveSequence

Even if you’ve never explicitly studied RxSwift’s source, you’ve probably seen the name `PrimitiveSequence` show up in call stacks involving RxSwift.

Here is its definition:

```swift
public struct PrimitiveSequence<Trait, Element> {
    let source: Observable<Element>

    init(raw: Observable<Element>) {
        self.source = raw
    }
}

public protocol PrimitiveSequenceType {
    associatedtype Trait
    associatedtype Element

    var primitiveSequence: PrimitiveSequence<Trait, Element> { get }
}

extension PrimitiveSequence: PrimitiveSequenceType {
    public var primitiveSequence: PrimitiveSequence<Trait, Element> { self }
}

extension PrimitiveSequence: ObservableConvertibleType {
    public func asObservable() -> Observable<Element> { source }
}
```

We can see that `PrimitiveSequence` is just a thin wrapper around an `Observable`. It also conforms to `ObservableConvertibleType`, returning the underlying `Observable`.

Note that this is wrapping, not inheritance: `PrimitiveSequence` does _not_ inherit from `Observable`; it decorates it. Since `PrimitiveSequence` is designed for more concrete scenarios, its APIs are more specialized. By not inheriting from `Observable`, it avoids exposing the full `Observable` API surface directly on `PrimitiveSequence`.

There’s also a protocol `PrimitiveSequenceType` that looks almost the same as `PrimitiveSequence`. Even without reading further, from our experience with RxSwift’s code so far, we can guess that this is the protocol-based interface version for `PrimitiveSequence`.

Sharp-eyed readers may have noticed an extra generic parameter `Trait` on `PrimitiveSequence` that seems unnecessary. We’ll leave this as a small cliffhanger; once we look at `Single` it will become obvious.

So if `PrimitiveSequence` is not itself an `Observable`, how can we still call operators like `observe(on:)` on it? The answer is straightforward:

```swift
extension PrimitiveSequence {
    public func delay(_ dueTime: RxTimeInterval, scheduler: SchedulerType) -> PrimitiveSequence<Trait, Element> {
        PrimitiveSequence(raw: source.delay(dueTime, scheduler: scheduler))
    }

    public func observe(on scheduler: ImmediateSchedulerType) -> PrimitiveSequence<Trait, Element> {
        PrimitiveSequence(raw: source.observe(on: scheduler))
    }

    // ...
}
```

RxSwift adds a set of operators on `PrimitiveSequence` that "mirror" the ones on `Observable`. Their implementations simply call the corresponding operator on `source`, and then wrap the result back into a new `PrimitiveSequence`. The work is still done by `source`, but this ensures the operators on `PrimitiveSequence` return another `PrimitiveSequence`, letting the type system help enforce type safety.

## Single

With the basic `PrimitiveSequence` covered, let’s look at one of its concrete variants: `Single`.

> A Single is a variation of Observable that, instead of emitting a series of elements, is always guaranteed to emit either _a single element_ or _an error_.

A `Single` either emits exactly one element, or it emits an error. If that feels abstract, you can think of it as the Rx version of `Result`. In fact, that’s precisely where `Single` shines: when your stream is essentially a `Result` in disguise, using `Single` is more appropriate than using a general `Observable`.

Here is the definition of `Single`:

```swift
public enum SingleTrait { }
public typealias Single<Element> = PrimitiveSequence<SingleTrait, Element>
```

As you can see, `Single` is nothing more than a typealias for `PrimitiveSequence`, with no extra structure.

Earlier we skipped over the `Trait` generic parameter on `PrimitiveSequence`. Now we can see that it plays the role of a _phantom type_. Phantom types are a concept from Haskell: by adding a type parameter that you never actually instantiate or use at runtime, you can let the type system enforce extra invariants and safety. For more on phantom types in Swift, see the references at the end.

Let’s look at how to create a `Single`:

```swift
extension PrimitiveSequenceType where Trait == SingleTrait {
    public typealias SingleEvent<Element> = Result<Element, Swift.Error>
    public typealias SingleObserver = (SingleEvent<Element>) -> Void

    public static func create(subscribe: @escaping (@escaping SingleObserver) -> Disposable) -> Single<Element> {
        let source = Observable<Element>.create { observer in
            return subscribe { event in
                switch event {
                case .success(let element):
                    observer.on(.next(element))
                    observer.on(.completed)
                case .failure(let error):
                    observer.on(.error(error))
                }
            }
        }

        return PrimitiveSequence(raw: source)
    }
}
```

As we said, `Single` is essentially a `Result`, so `create(subscribe:)` does not need to deal with multiple elements—the closure’s parameter is constrained to a single `Result`. Internally it uses a standard `Observable.create`, but ensures that `observer.on` is called correctly to respect the `Single` contract.

Subscribing to a `Single` is similar:

```swift
extension PrimitiveSequenceType where Trait == SingleTrait {
    public func subscribe(_ observer: @escaping (SingleEvent<Element>) -> Void) -> Disposable {
        var stopped = false
        return self.primitiveSequence.asObservable().subscribe { event in
            if stopped { return }
            stopped = true

            switch event {
            case .next(let element):
                observer(.success(element))
            case .error(let error):
                observer(.failure(error))
            case .completed:
                rxFatalErrorInDebug("Singles can't emit a completion event")
            }
        }
    }
}
```

There’s nothing complicated here—just mapping from `Event` to `Result`. The key is the local variable `stopped`: as soon as the first `event` arrives, `stopped` is set to `true`:

- If the event is `.next`, we treat it as `.success`.
- If the event is `.error`, we treat it as `.failure`.
- If the event is `.completed`, this branch is logically unreachable, because `Single.create(subscribe:)` guarantees that `.completed` only follows a `.next`, and by the time `.next` has arrived, `stopped` is already `true`.

The rest of `Single` is just helper methods; I won’t go into detail here. You can check the implementation on [GitHub](https://github.com/ReactiveX/RxSwift/blob/main/RxSwift/Traits/PrimitiveSequence/Single.swift).

## Maybe

> A Maybe is a variation of Observable that is right in between a Single and a Completable. It can either emit a single element, complete without emitting an element, or emit an error.

A `Maybe` emits exactly one of: a `next`, a `completed`, or an `error`. Here is its definition:

```swift
public enum MaybeTrait { }
public typealias Maybe<Element> = PrimitiveSequence<MaybeTrait, Element>
```

The definition is very similar to `Single`: it’s just a `PrimitiveSequence` with `Trait` specialized to `MaybeTrait`.

Creation looks like this:

```swift
extension PrimitiveSequenceType where Trait == MaybeTrait {
    public typealias MaybeObserver = (MaybeEvent<Element>) -> Void
    @frozen public enum MaybeEvent<Element> {
        case success(Element)
        case error(Swift.Error)
        case completed
    }

    public static func create(subscribe: @escaping (@escaping MaybeObserver) -> Disposable) -> PrimitiveSequence<Trait, Element> {
        let source = Observable<Element>.create { observer in
            return subscribe { event in
                switch event {
                case .success(let element):
                    observer.on(.next(element))
                    observer.on(.completed)
                case .error(let error):
                    observer.on(.error(error))
                case .completed:
                    observer.on(.completed)
                }
            }
        }

        return PrimitiveSequence(raw: source)
    }
}
```

Creating a `Maybe` is essentially the same as hand-writing an `Observable` that emits at most one element.

Subscribing to a `Maybe` looks like this:

```swift
extension PrimitiveSequenceType where Trait == MaybeTrait {
    public func subscribe(_ observer: @escaping (MaybeEvent<Element>) -> Void) -> Disposable {
        var stopped = false
        return self.primitiveSequence.asObservable().subscribe { event in
            if stopped { return }
            stopped = true

            switch event {
            case .next(let element):
                observer(.success(element))
            case .error(let error):
                observer(.error(error))
            case .completed:
                observer(.completed)
            }
        }
    }
}
```

As with `Single`, a local `stopped` flag ensures that only a single event is handled. Unlike `Single`, `completed` is a first-class outcome.

The remaining parts of `Maybe` are auxiliary methods; see [GitHub](https://github.com/ReactiveX/RxSwift/blob/main/RxSwift/Traits/PrimitiveSequence/Maybe.swift) for details.

## Completable

> A Completable is a variation of Observable that can only _complete_ or _emit an error_. It is guaranteed to not emit any elements.

A `Completable` either completes or errors; it never emits any `.next` values. If that feels a bit abstract, you can think of it as the Rx version of `(Error?) -> Void`. That’s also its natural use case: if you just want to wrap a "no return value" asynchronous operation in RxSwift, `Completable` is a better fit than `Observable`.

Here is its definition:

```swift
public enum CompletableTrait { }
public typealias Completable = PrimitiveSequence<CompletableTrait, Swift.Never>
```

The definition is again similar to `Single` and `Maybe`. The one interesting point is that `Element` is `Never` (an _uninhabited type_), which statically guarantees that a `Completable` can never carry an element.

A small aside: `SingleTrait`, `MaybeTrait`, and `CompletableTrait` are conceptually similar to `Never`—they’re all uninhabited types. You can’t construct values of these types; they exist for the type system. For more on `Never`, see the reference section.

Here is how `Completable` is created and subscribed to:

```swift
extension PrimitiveSequenceType where Trait == CompletableTrait, Element == Swift.Never {
    public typealias CompletableObserver = (CompletableEvent) -> Void

    @frozen public enum CompletableEvent {
        case error(Swift.Error)
        case completed
    }

    public static func create(subscribe: @escaping (@escaping CompletableObserver) -> Disposable) -> PrimitiveSequence<Trait, Element> {
        let source = Observable<Element>.create { observer in
            return subscribe { event in
                switch event {
                case .error(let error):
                    observer.on(.error(error))
                case .completed:
                    observer.on(.completed)
                }
            }
        }

        return PrimitiveSequence(raw: source)
    }

    public func subscribe(_ observer: @escaping (CompletableEvent) -> Void) -> Disposable {
        var stopped = false
        return self.primitiveSequence.asObservable().subscribe { event in
            if stopped { return }
            stopped = true

            switch event {
            case .next:
                rxFatalError("Completables can't emit values")
            case .error(let error):
                observer(.error(error))
            case .completed:
                observer(.completed)
            }
        }
    }
}
```

The code is much like `Single` and `Maybe`, so we won’t belabor it here.

### ConcatCompletable

Speaking of `Completable`, we can’t ignore its high-usage operator `andThen`. This operator chains another `Observable`/`PrimitiveSequence` to execute after the current `Completable` completes.

For example, consider a function that downloads an image:

```swift
func downloadImage(name: String) -> Completable {
    // implementation details
}
```

If you need to download images named `image1`, `image2`, and `image3` in sequence, you could write:

```swift
downloadImage(name: "image1")
    .andThen(downloadImage(name: "image2"))
    .andThen(downloadImage(name: "image3"))
    .subscribe()
```

The resulting code is very readable.

You can think of `andThen` as `flatMap` for `Completable`. It’s not limited to chaining `Completable` only; it can chain almost any kind of "stream":

```swift
extension PrimitiveSequenceType where Trait == CompletableTrait, Element == Never {
    public func andThen<Element>(_ second: Single<Element>) -> Single<Element> {
        let completable = self.primitiveSequence.asObservable()
        return Single(raw: ConcatCompletable(completable: completable, second: second.asObservable()))
    }

    public func andThen<Element>(_ second: Maybe<Element>) -> Maybe<Element> {
        let completable = self.primitiveSequence.asObservable()
        return Maybe(raw: ConcatCompletable(completable: completable, second: second.asObservable()))
    }

    public func andThen(_ second: Completable) -> Completable {
        let completable = self.primitiveSequence.asObservable()
        return Completable(raw: ConcatCompletable(completable: completable, second: second.asObservable()))
    }

    public func andThen<Element>(_ second: Observable<Element>) -> Observable<Element> {
        let completable = self.primitiveSequence.asObservable()
        return ConcatCompletable(completable: completable, second: second.asObservable())
    }
}
```

Each overload of `andThen` here points to a `ConcatCompletable`. Let’s look at its implementation:

```swift
final private class ConcatCompletable<Element>: Producer<Element> {
    fileprivate let completable: Observable<Never>
    fileprivate let second: Observable<Element>

    init(completable: Observable<Never>, second: Observable<Element>) {
        self.completable = completable
        self.second = second
    }

    override func run<Observer: ObserverType>(_ observer: Observer, cancel: Cancelable) -> (sink: Disposable, subscription: Disposable) where Observer.Element == Element {
        let sink = ConcatCompletableSink(parent: self, observer: observer, cancel: cancel)
        let subscription = sink.run()
        return (sink: sink, subscription: subscription)
    }
}

final private class ConcatCompletableSink<Observer: ObserverType>: Sink<Observer>, ObserverType {
    typealias Element = Never
    typealias Parent = ConcatCompletable<Observer.Element>

    private let parent: Parent
    private let subscription = SerialDisposable()

    init(parent: Parent, observer: Observer, cancel: Cancelable) {
        self.parent = parent
        super.init(observer: observer, cancel: cancel)
    }

    func on(_ event: Event<Element>) {
        switch event {
        case .error(let error):
            self.forwardOn(.error(error))
            self.dispose()
        case .next:
            break
        case .completed:
            let otherSink = ConcatCompletableSinkOther(parent: self)
            self.subscription.disposable = self.parent.second.subscribe(otherSink)
        }
    }

    func run() -> Disposable {
        let subscription = SingleAssignmentDisposable()
        self.subscription.disposable = subscription
        subscription.setDisposable(self.parent.completable.subscribe(self))
        return self.subscription
    }
}

final private class ConcatCompletableSinkOther<Observer: ObserverType>: ObserverType {
    typealias Element = Observer.Element
    typealias Parent = ConcatCompletableSink<Observer>

    private let parent: Parent

    init(parent: Parent) {
        self.parent = parent
    }

    func on(_ event: Event<Observer.Element>) {
        self.parent.forwardOn(event)
        if event.isStopEvent {
            self.parent.dispose()
        }
    }
}
```

This is the familiar `Producer` + `Sink` pairing again. `ConcatCompletable` holds the original `completable` and the stream to follow it, `second`, for use by `ConcatCompletableSink`.

When `ConcatCompletable` is subscribed to, `ConcatCompletableSink` first subscribes to `completable`, with itself as the observer. Once `completable` completes, it then subscribes to `second` via `ConcatCompletableSinkOther`, thereby implementing the sequential subscription of `completable` followed by `second`.

A few small details:

- If you dispose before `completable` finishes, only the subscription to `completable` is disposed, because at that point only `completable` has been subscribed.
- Both `completable` and `second` ultimately feed into the same `on(_:)` handling via `ConcatCompletableSink`/`ConcatCompletableSinkOther`. If either produces an error, the whole chain forwards that error and terminates.

## Converting to and from Observable

You can convert a `PrimitiveSequence` to an `Observable` simply by calling `asObservable`. Conversely, `Observable` can be converted to a `PrimitiveSequence`:

```swift
extension ObservableType {
    public func asSingle() -> Single<Element> {
        PrimitiveSequence(raw: AsSingle(source: self.asObservable()))
    }

    public func asMaybe() -> Maybe<Element> {
        PrimitiveSequence(raw: AsMaybe(source: self.asObservable()))
    }
}
```

RxSwift provides `asSingle`/`asMaybe` to turn an `Observable` into a `Single`/`Maybe`. This introduces two new types: `AsSingle` and `AsMaybe`. Their implementations are very similar—they just enforce the respective semantics of `Single` and `Maybe`. I’ll walk through `AsSingle`; you can inspect `AsMaybe` on [GitHub](https://github.com/ReactiveX/RxSwift/blob/main/RxSwift/Observables/AsMaybe.swift).

Here is `AsSingle`:

```swift
private final class AsSingleSink<Observer: ObserverType> : Sink<Observer>, ObserverType {
    typealias Element = Observer.Element

    private var element: Event<Element>?

    func on(_ event: Event<Element>) {
        switch event {
        case .next:
            if self.element != nil {
                self.forwardOn(.error(RxError.moreThanOneElement))
                self.dispose()
            }

            self.element = event
        case .error:
            self.forwardOn(event)
            self.dispose()
        case .completed:
            if let element = self.element {
                self.forwardOn(element)
                self.forwardOn(.completed)
            }
            else {
                self.forwardOn(.error(RxError.noElements))
            }
            self.dispose()
        }
    }
}

final class AsSingle<Element>: Producer<Element> {
    private let source: Observable<Element>

    init(source: Observable<Element>) {
        self.source = source
    }

    override func run<Observer: ObserverType>(_ observer: Observer, cancel: Cancelable) -> (sink: Disposable, subscription: Disposable) where Observer.Element == Element {
        let sink = AsSingleSink(observer: observer, cancel: cancel)
        let subscription = self.source.subscribe(sink)
        return (sink: sink, subscription: subscription)
    }
}
```

Again we see the standard `Producer` + `Sink` pattern. The `Producer` part is routine, so let’s focus on `AsSingleSink.on(_:)`:

- On the first `.next`, it records the event. If another `.next` arrives later, it forwards an error (`RxError.moreThanOneElement`) and disposes itself.
- On `.completed`, it checks whether a `.next` was seen before. If yes, it forwards that element and then `.completed`. If not, this violates the `Single` contract, so it forwards `RxError.noElements`.
- On `.error`, it directly forwards the error.

From this we can see that converting an `Observable` to a `Single` only makes sense if the original stream’s event pattern conforms to the definition of `Single`; otherwise you’ll get runtime errors. This also explains why there is no `asCompletable` operator: it wouldn’t be meaningful. If an `Observable` has no elements at all, you should just be using a `Completable` from the start.

## Summary

In this article we’ve added another concept to our RxSwift toolbox: `PrimitiveSequence`.

`PrimitiveSequence` looks like `Observable`, but it isn’t an `Observable`. RxSwift uses Swift’s type system techniques—such as phantom types and uninhabited types—to enforce type safety when using `PrimitiveSequence`. You can create and subscribe to a `PrimitiveSequence` much like you do with an `Observable`, but to the type system, it is not the same thing.

`PrimitiveSequence` is designed for concrete scenarios. In those scenarios, using `PrimitiveSequence` instead of `Observable` provides clearer semantics and stronger type guarantees. Learning and using `PrimitiveSequence` can help us write code that is both more readable and more robust.

## References

- [ReactiveX/RxSwift: Reactive Programming in Swift](https://github.com/ReactiveX/RxSwift)
- [[]] at main · ReactiveX/RxSwift · [[]]
- [Phantom types in Swift \| Swift by Sundell](https://www.swiftbysundell.com/articles/phantom-types-in-swift/)
- [Never - NSHipster](https://nshipster.com/never/)
