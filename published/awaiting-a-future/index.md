---
layout: page
title: "Awaiting a Future"
date: 2022-01-02
permalink: /awaiting-a-future/
---

This is the last standalone post in my Programming Rust reading‑note series, and also the first post on this blog in 2022. As we say goodbye to 2021 and step into 2022, let’s talk about _Asynchronous Rust_.

At last year’s WWDC, Apple shipped Swift Concurrency with native `async/await` support. It’s fair to say that async has become a “must‑have” feature for modern programming languages. Today we’ll take a look at how Rust approaches this problem.

# From Sync to Async

## Synchronous Functions

Consider the following function:

```rust
use std::io::prelude::*;
use std::net;

fn cheapo_request(host: &str, port: u16, path: &str) -> std::io::Result<String> {
    let mut socket = net::TcpStream::connect((host, port))?;
    let request = format!("GET {} HTTP/1.1\r\nHost: {}\r\n\r\n", path, host);
    socket.write_all(request.as_bytes())?;
    socket.shutdown(net::Shutdown::Write)?;

    let mut response = String::new();
    socket.read_to_string(&mut response)?;
    Ok(response)
}
```

`cheapo_request` sends a very simple HTTP request over TCP. The diagram below shows its call stack over time from left to right:

![sync.png](/published/awaiting-a-future/sync.png)

`cheapo_request` calls `TcpStream::connect`, `write_all`, and `read_to_string` in sequence. Those functions call other functions, which eventually reach system calls (the dark gray area in the diagram).

(The proportions in the diagram are not accurate. In reality, the dark gray part—the system calls—dominates the total runtime. The thread spends most of its time _waiting_ on syscalls, doing nothing else.)

If we had a way to let the thread do other work while it’s blocked in a syscall, we could greatly improve performance. But achieving that isn’t trivial, because the function’s signature tells us it’s a synchronous function. We need an asynchronous version.

## Future

Rust’s answer to async operations is the `Future` mentioned in this article’s title:

```rust
pub trait Future {
    type Output;
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output>;
}

pub enum Poll<T> {
    Ready(T),
    Pending,
}
```

`Future` lives in the `std::future` module. It’s similar to a `Promise`: it represents a computation whose result you can check:

- If the computation has finished, `poll` returns `Ready` with the final result.
- If it’s not done yet, `poll` returns `Pending`.

Sharp‑eyed readers may have noticed that `poll` takes a `Pin<&mut Self>`. `Pin` is a new type we’ll discuss later; for now, you can mentally treat it as `&mut Self`.

At first glance, `poll` may ring some alarm bells:

1. Is Rust’s async story really built on polling, which is often considered inefficient? Doesn’t that contradict Rust’s “high performance” marketing?
2. What should we do when `poll` returns `Pending`? Do we just go do other work and come back and `poll` again later? Does the program have to track which futures are `Pending` vs `Ready`?

The good news is that using `Future` doesn’t necessarily make your code more complex, and in fact `Future` is a very nice example of a zero‑cost abstraction. How Rust pulls this off is what we’ll explore next.

Before that, let’s see roughly how futures are used. Take `read_to_string` from `cheapo_request`’s call stack as an example. Its synchronous signature is:

```rust
fn read_to_string(&mut self, buf: &mut String) -> std::io::Result<usize>;
```

The async version’s rough signature would look like:

```rust
fn read_to_string(&mut self, buf: &mut String) -> impl Future<Output = Result<usize>>;
```

The only difference is the return type: the async version returns a future that produces `Result<usize>`. Calling this async `read_to_string` just returns a type that implements `Future`. It does _not_ actually start reading. The read only starts when that future is first polled.

(This is very similar to Rx’s `Observable`: a cold observable doesn’t do anything until you subscribe to it.)

Also note that we return `impl Future` rather than a concrete type. The concrete type is an internal compiler‑generated type that is not visible to callers. The only thing callers know is that it implements `Future<Output = R>`.

(For the details of how the compiler generates these types, I strongly recommend Philipp’s excellent article linked at the end of this post.)

## `async` and `await`

Now let’s look at real async functions.

Using `cheapo_request` again, the async version might look like this:

```rust
use async_std::io::prelude::*;
use async_std::net;

async fn cheapo_request(host: &str, port: u16, path: &str) -> std::io::Result<String> {
    let mut socket = net::TcpStream::connect((host, port)).await?;
    let request = format!("GET {} HTTP/1.1\r\nHost: {}\r\n\r\n", path, host);

    socket.write_all(request.as_bytes()).await?;
    socket.shutdown(net::Shutdown::Write)?;

    let mut response = String::new();
    socket.read_to_string(&mut response).await?;
    Ok(response)
}
```

First, note the `async` before `fn`: that marks this as an async function. Even though the return type is written as `Result`, the compiler internally treats it as a `Future`. You can think of this as syntactic sugar.

Second, in the body we’re using async versions of `write_all`, `read_to_string`, etc. from the `async_std` crate. Each such call is followed by `.await`. Despite looking like a field access, `await` is actually a special Rust syntax that waits for the future to complete.

Unlike a normal function, an async function returns _before_ executing its body. For example:

```rust
let response = cheapo_request(host, port, path);
```

Here, `response` is a `Future`. This future bundles up everything needed to run the function body: arguments, locals, etc. Its concrete type is compiler‑generated and opaque to callers, but we know it implements `Future<Output = R>`.

When we first poll the future `response`, execution starts at the beginning of `cheapo_request` and runs until the first `await`, where it polls the sub‑future returned by `TcpStream::connect`. If that sub‑future returns `Ready`, we get its value and continue; if it returns `Pending`, `cheapo_request` returns `Pending` too, and records where to resume next time it’s polled. In other words, repeated polls drive the function from one `await` to the next.

To do this, the future must record where to resume and any needed state. That’s what the compiler‑generated type stores.

This ability to “pause in the middle and resume later” is what distinguishes async functions from normal ones. It also implies that `await` can only be used _inside_ async functions.

An important limitation today: only free functions and inherent methods can be async; trait methods cannot (yet) be `async fn`.

## `block_on`

Now that we understand futures, how do we call async code from sync code and get a result?

`async_std` provides a `block_on` function. It takes a future as input and internally polls it until completion, then returns the result.

Example:

```rust
use async_std::task;

fn main() -> std::io::Result<()> {
    let response = task::block_on(cheapo_request("example.com", 80, "/"))?;
    println!("{}", response);
    Ok(())
}
```

`block_on` is a sync function that bridges from the async world back into the sync world.

The name is a warning: `block_on` blocks the current thread until the future completes. That means you _must not_ call it inside async functions. In async code, you should `await` instead.

![block_on.png](/published/awaiting-a-future/block_on.png)

The diagram above shows how the async call stack looks:

1. `main` calls `cheapo_request`, getting future A, and passes A to `block_on`.
2. `block_on` polls A, starting execution of `cheapo_request`, which calls `TcpStream::connect` and gets future B.
3. At the first `await`, A polls B. Because the network connection isn’t established yet, `B.poll` returns `Pending` and arranges to be polled again once the connection is ready.
4. Since B returned `Pending`, A returns `Pending` to `block_on`.
5. `block_on` has nothing else to do, so it puts the thread to sleep. The whole thread is blocked.
6. When B’s connection completes, it wakes `block_on` so that it can poll A again.
7. Polling A resumes execution at the first `await`, which polls B again.
8. This time, B returns `Ready(Ok(socket))`.
9. The `TcpStream::connect(...).await` expression evaluates to `Ok(socket)`, and `cheapo_request` continues, formatting the request and calling `socket.write_all`.
10. Since `socket.write_all` is also async, it returns a future C, and we repeat the same `await` pattern.
11. … and so on.

A simple loop that repeatedly polls a future isn’t hard to write. The tricky part is knowing when to sleep and when to wake up, so you don’t waste CPU resources. That’s what `block_on` handles for us.

We’ll see _how_ it does that shortly.

## `spawn`

`block_on` blocks the current thread until the given future is `Ready`. If a single future monopolized an entire thread like that, async wouldn’t be very useful. The whole point is to allow a thread to do _other work_ while some futures are waiting.

For that, we can use `async_std::task::spawn_local` (currently unstable). This function adds its future to a local task pool. When that future is `Pending`, subsequent calls to `block_on` will poll other futures from the pool. If you pass a bunch of futures to `spawn_local` and then call `block_on` on a final “join” future, that last future will coordinate polling of all the spawned tasks concurrently.

Conceptually, `spawn_local` is like an async version of `std::thread::spawn`:

- `spawn` takes a closure `c` and starts a new thread to run it. It returns a `JoinHandle`, and calling `join` waits for the thread to finish and returns the closure’s result.
- `spawn_local` takes a future `f` and adds it to a local pool. When you later call `block_on` in that thread, it will poll futures from that pool. It returns an `async_std::task::JoinHandle`, which is itself a future you can await to get `f`’s result.

### An Example

Let’s make this concrete:

```rust
use async_std::task;

async fn many_requests(requests: Vec<(String, u16, String)>) -> Vec<std::io::Result<String>> {
    let mut handles = vec![];
    for (host, port, path) in requests {
        handles.push(task::spawn_local(cheapo_request(&host, port, &path)));
    }

    let mut results = vec![];
    for handle in handles {
        results.push(handle.await);
    }

    results
}
```

`many_requests` calls `cheapo_request` for each request and spawns them all via `spawn_local`. Then it awaits all of the returned `JoinHandle`s.

This code doesn’t compile yet:

![spawn_1.png](/published/awaiting-a-future/spawn_1.png)

If we pass references into an async function, the returned future has to contain those references to have enough context to run. The future must not outlive the referenced values.

Here, `spawn_local` can’t guarantee that you’ll await the `JoinHandle` before dropping `host` and `path`. In fact, `spawn_local` accepts only `'static` futures, because you might just never await the handle and let the task run until the program exits. This is similar to `std::thread::spawn`: if the closure captures references to local variables, the compiler will reject it.

One fix is to write an “owning” version of `cheapo_request`:

```rust
async fn cheapo_owning_request(host: String, port: u16, path: String) -> std::io::Result<String> {
    cheapo_request(&host, port, &path).await
}
```

Now the future owns `host` and `path` and they can safely be `'static`. `cheapo_owning_request` simply awaits the original borrowed version, ensuring that `host` and `path` remain alive until the inner future completes.

We can then use `block_on` in `main`:

```rust
let requests = vec![
    ("example.com".to_string(), 80, "/".to_string()),
    ("www.red-bean.com".to_string(), 80, "/".to_string()),
    ("en.wikipedia.org".to_string(), 80, "/".to_string()),
];

let results = async_std::task::block_on(many_requests(requests));
for result in results {
    match result {
        Ok(response) => println!("{}", response),
        Err(err) => eprintln!("error: {}", err),
    }
}
```

This concurrently runs three requests; each can make progress while the others are waiting.

![spawn_2.png](/published/awaiting-a-future/spawn_2.png)

One possible execution:

- `many_requests` spawns tasks A, B, and C.
- `block_on` first polls A, which starts connecting to `example.com`. When that returns `Pending`, `block_on` polls B, then C.
- Once A, B, and C have all returned `Pending`, `block_on` sleeps.
- Suppose Wikipedia responds fastest; C’s connect future completes first, waking `block_on`.
- When a task finishes, it stores its result in the `JoinHandle` and returns `Ready`.
- After all `cheapo_request` calls finish (successfully or with error), `many_requests` returns, `block_on` completes, and `main` prints the results.

All of this happens on a single thread, with A, B, and C interleaving execution in small chunks.

The key difference between async tasks and threads is _when_ context switches occur. Async tasks switch only when an `await`ed future returns `Pending`. That means if a task does a long CPU‑bound computation without `await`, other tasks are starved. Threads, on the other hand, can be preempted by the OS at any time, ensuring fair CPU sharing.

So async performance depends on how cooperative your futures are in sharing the thread. If you need long‑running compute, we’ll see later how to handle that.

### Async Closures

Instead of `async fn`, you can also use async closures to build async functions:

```rust
use std::io;
use std::future::Future;

fn cheapo_request<'a>(
    host: &'a str,
    port: u16,
    path: &'a str,
) -> impl Future<Output = io::Result<String>> + 'a {
    async move {
        // function body here
    }
}
```

Calling this returns a future representing the closure’s result. Aside from not using `async fn`, the signature is equivalent.

### Thread Pool

So far we’ve mostly looked at I/O‑bound tasks, but many real workloads are CPU‑bound. When one thread isn’t enough, you can move futures to a thread pool using `async_std::task::spawn`.

`spawn` is more common than `spawn_local` because you nearly always want to use all available cores.

Its usage is similar:

```rust
use async_std::task;

let mut handles = vec![];
for (host, port, path) in requests {
    handles.push(task::spawn(async move {
        cheapo_request(&host, port, &path).await
    }));
}

// await handles...
```

`spawn` also returns a `JoinHandle` future, but it’s polled by the thread pool itself as long as there are idle threads.

An important detail: to avoid idle threads, the runtime tries to poll a future as soon as it becomes ready again. That means a task might start on one thread, hit an `await`, and then resume on a _different_ thread. From the async function’s perspective everything looks linear, but under the hood its state might bounce between threads.

This implies that any state used by an async function must be thread‑safe.

Also, because `spawn` moves the future to another thread, that future must be `Send`. In other words, all arguments, locals, etc. captured in the future must be `Send`. This is the same as for `std::thread`: its closure runs in another thread.

It’s easy to trip over this, for example:

```rust
use async_std::task;
use std::rc::Rc;

async fn reluctant() -> String {
    let string = Rc::new("ref-counted string".to_string());
    some_asynchronous_thing().await;
    format!("Your splendid string: {}", string)
}

task::spawn(reluctant());
```

This fails to compile:

![spawn_3.png](/published/awaiting-a-future/spawn_3.png)

The future generated by `reluctant` needs to hold an `Rc<String>` so that `string` remains available after the `await`. But `Rc` is not `Send`, so the future cannot be `Send`, and thus cannot be passed to `spawn`.

Two ways to fix this:

- Use `Arc` instead of `Rc`.
- Restrict the scope of the non‑`Send` value so that it’s dropped before any `await`:

  ```rust
  async fn reluctant() -> String {
      let return_value = {
          let string = Rc::new("ref-counted string".to_string());
          format!("Your splendid string: {}", string)
          // Rc<String> is dropped here...
      };

      // ... so it doesn’t exist when we suspend here.
      some_asynchronous_thing().await;

      return_value
  }
  ```

## Expensive Computation

A well‑behaved future should return from `poll` quickly, so that other tasks get a chance to run. If a future does heavy computation inside `poll`, other tasks may starve.

`async_std` offers a `yield_now` helper:

```rust
while computation_not_done() {
    // do one medium-sized step of computation...
    async_std::task::yield_now().await;
}
```

The first time the `yield_now` future is polled it returns `Pending` and yields the thread to other tasks. The second time it returns `Ready`, and your async function resumes.

`yield_now` isn’t always sufficient. If the computation lives inside a third‑party library, you can’t sprinkle `yield_now` calls inside its inner loops.

In those cases, use `spawn_blocking`. It takes a closure and runs it in a dedicated blocking thread, returning a future whose output is the closure’s return value. Because the work moves to another thread, it doesn’t starve the async runtime.

## Comparing Async Designs

Rust’s async model resembles other languages in many ways. JavaScript, C#, and Rust all have `await` and a concept of an “incomplete computation”: JS has `Promise`, C# has `Task`, Rust has `Future`.

Where Rust differs is in its _polling_ model. In JS and C#, async functions start running as soon as they’re called, and the language runtime provides a built‑in global event loop that resumes them after `await`.

In Rust, calling an async function just creates a `Future`. It doesn’t run until you give it to an executor like `block_on` to be polled. Executors play the role of event loops in other languages—but because Rust lets you choose the executor, the standard library doesn’t need a global one.

# Futures and Executors

We’ve said that while futures use polling, executors only poll “at the right time”. We still haven’t answered the key question, which is probably on your mind:

> How does the executor _know_ when the right time is?

Consider this code:

```rust
task::block_on(async {
    let socket = net::TcpStream::connect(address).await?;
    // ...
})
```

When `block_on` first polls this future, the TCP connection almost certainly isn’t ready, so `block_on` must go to sleep. But how does it know _when_ to wake up and poll again? When the network connection finishes, `TcpStream` needs some way to tell `block_on` that the future is ready to make progress.

When an executor polls a future, it passes in a callback known as a _waker_. If the future isn’t ready yet, the `Future` trait requires implementations to:

1. Return `Pending`.
2. Arrange to call the waker later when it’s worth polling again.

A skeletal implementation:

```rust
use std::task::Waker;

struct MyPrimitiveFuture {
    // ...
    waker: Option<Waker>,
}

impl Future for MyPrimitiveFuture {
    type Output = ...;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<...> {
        // ...

        if /* future is ready */ {
            return Poll::Ready(final_value);
        }

        // Save the waker for later.
        self.waker = Some(cx.waker().clone());
        Poll::Pending
    }
}
```

When the future is ready again, it wakes the executor:

```rust
if let Some(waker) = self.waker.take() {
    waker.wake();
}
```

Ideally, futures and executors alternate between polling and waking: the executor polls and sleeps, then the future calls the waker, then the executor wakes and polls again.

Async functions and closures themselves don’t handle wakers; they just pass the `Context` they receive on to inner futures, delegating waker storage and waking to them.

Executors are allowed to poll a future more often than strictly necessary; that’s harmless but inefficient. Wakers, however, _must not_ be called unless polling really might return `Ready`, otherwise you waste work.

### Implementing `spawn_blocking`

Earlier we mentioned `spawn_blocking`, which runs a blocking closure on a separate thread and returns a future of its result. Now that we understand wakers, we can implement it ourselves.

The signature:

```rust
pub fn spawn_blocking<T, F>(closure: F) -> SpawnBlocking<T>
where
    F: FnOnce() -> T,
    F: Send + 'static,
    T: Send + 'static,
```

Because the closure runs on another thread and its result is sent back, both `F` and `T` must be `Send` and `'static`.

`SpawnBlocking` looks like this:

```rust
use std::sync::{Arc, Mutex};
use std::task::Waker;
use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Poll};

pub struct SpawnBlocking<T>(Arc<Mutex<Shared<T>>>);

struct Shared<T> {
    value: Option<T>,
    waker: Option<Waker>,
}

impl<T: Send> Future for SpawnBlocking<T> {
    type Output = T;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<T> {
        let mut guard = self.0.lock().unwrap();

        if let Some(value) = guard.value.take() {
            return Poll::Ready(value);
        }
        guard.waker = Some(cx.waker().clone());
        Poll::Pending
    }
}
```

`Shared` is the rendezvous point between the future and the worker thread, so we wrap it in `Mutex` + `Arc`. When the future is polled, it first checks whether a value is available. If so, it takes ownership and returns `Ready`. Otherwise, it stores the waker and returns `Pending`.

`spawn_blocking` then spins up the worker thread:

```rust
pub fn spawn_blocking<T, F>(closure: F) -> SpawnBlocking<T>
where
    F: FnOnce() -> T,
    F: Send + 'static,
    T: Send + 'static,
{
    let inner = Arc::new(Mutex::new(Shared {
        value: None,
        waker: None,
    }));

    std::thread::spawn({
        let inner = inner.clone();
        move || {
            let value = closure();

            let maybe_waker = {
                let mut guard = inner.lock().unwrap();
                guard.value = Some(value);
                guard.waker.take()
            };

            if let Some(waker) = maybe_waker {
                waker.wake();
            }
        }
    });

    SpawnBlocking(inner)
}
```

The spawned thread runs the closure, stores its result in `Shared`, takes the waker (if any), and wakes it.

# Pinning

When we first introduced `Future`, we hand‑waved past the `Pin` argument. Now let’s circle back. "Pin" here literally means "to pin down", so what is Rust trying to pin?

Before answering, recall one of the first concepts we learn in Rust: _moves_.

Take a simple string example:

```rust
fn main() {
    let mut s1 = String::from("Hello");
    let s2 = s1;
}
```

On line 3, `s1` is moved into `s2`. Conceptually, the compiler allocates stack space for `s2`, copies the stack representation of `s1` into `s2`, and invalidates `s1`. A move is essentially a change in _address_.

Moves are fundamental in Rust, but they can cause trouble for a certain pattern: **self‑referential structs**.

### Self‑Referential Structs

A self‑referential struct is one where a field references another field (or the struct itself). For example (schematically):

![pin_1.png](/published/awaiting-a-future/pin_1.png)

Here `pointer` points into the object itself. This is fine… until the struct is moved. After a move, you might end up with:

![pin2.png](/published/awaiting-a-future/pin2.png)

We moved the value, but the internal pointer still points to the _old_ location, which is now invalid. That’s a recipe for undefined behavior—exactly what Rust is trying to prevent.

And as it happens, compiler‑generated futures are very likely to be self‑referential. They need to store state that may include references into themselves.

Rust solves this with the `Pin` smart pointer. A `Pin<T>` promises that the value will never be moved again. For pinned types, the compiler enforces that behavior.

How does the compiler know which types can be moved and which can’t? Via the `Unpin` marker trait:

- Types that implement `Unpin` _can_ still be moved. The compiler automatically implements `Unpin` for almost all types where moving is safe, such as integers, booleans, etc.
- Types that do _not_ implement `Unpin` (often written as `!Unpin`) are "pinned" once placed behind `Pin<T>`.

`Unpin` is a bit unintuitive at first because of the negation in the name.

This post only scratches the surface of `Pin`. For a deeper dive, see Philipp’s article and Folyd’s two posts in the references section.

# When Async Helps

Writing async code is trickier than writing threaded code. You need the right async I/O primitives, the right runtime, and sometimes to worry about details like pinning that you can safely ignore with plain threads.

So what’s the point? Why bother with async at all?

One common claim is that "async is better for I/O". That’s not quite right. If your program spends most of its time waiting on I/O, rewriting it to be async won’t magically make it faster. Under the hood, both sync and async I/O use the same OS primitives. In fact, async often incurs an extra syscall: one to initiate and another to check readiness.

Another claim is that async is easier than threads. In JavaScript or Python, this can be true: you can get concurrency without worrying about locks, because there’s only one thread actually running code. In Rust, though, if your code compiles, there are _no_ data races, and you have high‑level tools (`Mutex`, channels, atomics, etc.) to manage shared state. Async doesn’t buy you special safety advantages there.

So what _are_ the real benefits of async in Rust?

1. **Lower per‑task memory usage.** On Linux, a thread typically reserves at least ~20 KB of stack. A future, by contrast, is often much smaller, and the compiler will keep shrinking it as optimizations improve.
2. **Cheaper task creation.** Creating a thread on Linux can cost around 15 µs; creating an async task can be as cheap as 300 ns—roughly fifty times faster.
3. **Faster context switching between tasks.** In ideal cases, switching between tasks can be ~0.2 µs versus ~1.7 µs per thread context switch.

These advantages matter in scenarios like high‑load servers: each async task costs less memory and CPU, so you can handle more concurrent connections.

# Summary

In this post, we started from the `Future` abstraction and, using `async_std` as our runtime, walked through the core concepts and patterns in Rust’s async story.

Rust’s async ecosystem is the product of cooperation between:

- The _language_, which provides syntax like `async` and `await`.
- The _standard library_, which defines the core traits and types: `Future`, `Context`, `Pin`, `Waker`, etc. Because the compiler needs these definitions to compile async functions, they must live in `std`.
- _Third‑party crates_ like `async-std` (and `tokio`), which provide concrete runtimes and executors. Not every program needs them, which is why they live outside the standard library.

Rust’s async model is also a nice demonstration of zero‑cost abstractions: it offers a clean, high‑level way to write async code while staying very close to the metal in terms of performance.

Even if you don’t need async _today_, it’s a powerful tool to keep in your toolbox. Whether you choose threads or async for a given problem, you’ll still end up profiling and tuning hotspots—there are no silver bullets.

# References

- [Programming Rust](https://www.oreilly.com/library/view/programming-rust-2nd/9781492052586/)
- [Async/Await \| Writing an OS in Rust](https://os.phil-opp.com/async-await/)
- [Pin, Unpin, and why Rust needs them](https://blog.cloudflare.com/pin-and-unpin-in-rust/)
- [Rust 的 Pin 与 Unpin — Folyd](https://folyd.com/blog/rust-pin-unpin/)
- [Rust Pin 进阶 — Folyd](https://folyd.com/blog/rust-pin-advanced/)
