---
layout: page
title: "Fearless Concurrency"
date: 2021-11-24
permalink: /fearless-concurrency/
---

The title of this post is shamelessly borrowed from _the_ Rust book: "Fearless Concurrency". As that suggests, today’s topic is concurrency in Rust.

# Fork-Join Parallelism

Suppose we have a function that processes multiple files:

```rust
fn process_files(filenames: Vec<String>) -> io::Result<()> {
    for document in filenames {
        let text = load(&document)?;
        let results = process(text);
        save(&document, results)?;
    }
    Ok(())
}
```

It loops over files and, for each one, runs _load → process → save_.

Visually, the sequential execution looks like this:

![fork_join_1.png](/published/fearless-concurrency/fork_join_1.png)

Since each file is independent, it’s natural to think about processing them in parallel, one file per thread:

![fork_join_2.png](/published/fearless-concurrency/fork_join_2.png)

This pattern is called **fork-join parallelism**:

- _fork_: start new threads.
- _join_: wait for them all to finish.

It has some nice properties:

1. Simple to implement.
2. No shared state; no locks or other synchronization primitives needed.
3. Easy to debug; if each thread is self‑contained, behavior is deterministic.

Of course, this assumes that the overall task can be broken into mostly independent pieces, as with our file example.

## `spawn` and `join`

Here’s how we might rewrite the example using fork‑join parallelism:

```rust
use std::{thread, io};

fn process_files_in_parallel(filenames: Vec<String>) -> io::Result<()> {
    let worklists = split_vec_into_chunks(filenames, 8);

    let mut thread_handles = vec![];
    for worklist in worklists {
        thread_handles.push(
            thread::spawn(move || process_files(worklist))
        );
    }

    for handle in thread_handles {
        handle.join().unwrap()?;
    }

    Ok(())
}
```

Compared to the original, we now use `spawn` and `join`.

First, `spawn`. Its full signature is:

```rust
pub fn spawn<F, T>(f: F) -> JoinHandle<T>
where
    F: FnOnce() -> T,
    F: Send + 'static,
    T: Send + 'static,
```

`spawn` takes a closure or function and starts a new OS thread to run it. The closure must be `FnOnce`, `Send`, and `'static`. The return value is a `JoinHandle<T>`, and calling `join` waits for the thread to finish and returns the closure’s result.

Example:

```rust
use std::thread;

thread::spawn(|| {
    println!("hello from a child thread");
});
```

Next, `join`:

```rust
impl<T> JoinHandle<T> {
    pub fn join(self) -> Result<T>
}
```

`join` returns a `Result<T>`; if the thread panicked, you get `Err`. In our example we use `unwrap()?` to both surface panics and propagate `io::Result` errors. One key point: in Rust, a panic in one thread does _not_ bring down the entire process. Panics are isolated to their threads, making threaded code more robust.

## Sharing Immutable Data

Now suppose we also want to pass in a large glossary for processing:

```rust
fn process_files_in_parallel(
    filenames: Vec<String>,
    glossary: &GigabyteMap,
) -> io::Result<()> {
    // ...
    for worklist in worklists {
        thread_handles.push(
            thread::spawn(move || process_files(worklist, glossary))
        );
    }
    // ...
}
```

Since the glossary is large, we’d like to pass it by reference. But this won’t compile:

![share_immutable_error.png](/published/fearless-concurrency/share_immutable_error.png)

Rust doesn’t know how long the spawned threads will live. It must assume the worst: that a thread could outlive the spawning function. If `glossary` was a local reference, the thread might try to use it after it’s freed.

We _could_ make `glossary` `'static`, but that’s rarely what you want for large data.

The idiomatic solution in Rust is to use `Arc` (Atomic Reference Counting). If you know Swift, this is similar in spirit to ARC there, but here the “A” stands for _Atomic_ (thread‑safe), not _Automatic_. (Rust also has `Rc`, which is faster but not thread‑safe.)

`Arc<T>` keeps a reference count of shared ownership. When the count hits zero, it drops the value. Since it’s thread‑safe, multiple threads can share immutable access.

Rewriting with `Arc`:

```rust
use std::sync::Arc;

fn process_files_in_parallel(
    filenames: Vec<String>,
    glossary: Arc<GigabyteMap>,
) -> io::Result<()> {
    // ...
    for worklist in worklists {
        let glossary_for_child = glossary.clone();
        thread_handles.push(
            thread::spawn(move || process_files(worklist, &glossary_for_child))
        );
    }
    // ...
}
```

Here `clone` only clones the `Arc` pointer (incrementing the ref count), not the underlying `GigabyteMap`. As long as the count is > 0, the map stays alive. Because we only read from it, and `Arc` is immutable by default, we avoid data races.

## Rayon

The standard `spawn` API is a low‑level primitive; it’s not specifically tailored to fork‑join patterns. If you’re doing a lot of fork‑join parallelism, consider the `rayon` crate. It wraps `spawn` with a nicer API and manages a thread pool for you. See the [Rayon docs](https://github.com/rayon-rs/rayon) for details.

# Channels

A **channel** is a one‑way communication pipe used to send data from one thread to another. Think of it as a thread‑safe queue:

![channel_1.png](/published/fearless-concurrency/channel_1.png)

In the diagram, `sender.send(msg)` pushes a value into the channel, and `receiver.recv()` removes one. If the channel is empty, `recv()` blocks until a value arrives. Sending a value moves ownership from the sending thread to the receiving thread, keeping it efficient.

Compared to locks, channels offer a higher‑level abstraction for communication and can help you avoid shared mutable state.

Rust isn’t inventing anything new here; Erlang and Go have very similar concepts. The classic Go mantra applies:

> Do not communicate by sharing memory; instead, share memory by communicating.

## An Example

Let’s build a simple multi‑threaded pipeline using channels.

The task: build an **inverted index** from a set of documents. Given a term, we want to know which documents contain it. We’ll handwave over the exact indexing details and use a fake `InMemoryIndex` type.

We’ll use five threads, each doing one stage:

![channel_2.png](/published/fearless-concurrency/channel_2.png)

### Sending Values

We start by reading files on one thread:

```rust
use std::{fs, thread};
use std::sync::mpsc;

fn start_file_reader_thread(
    documents: Vec<PathBuf>,
) -> (mpsc::Receiver<String>, thread::JoinHandle<io::Result<()>>) {
    let (sender, receiver) = mpsc::channel();

    let handle = thread::spawn(move || {
        for filename in documents {
            let text = fs::read_to_string(filename)?;
            if sender.send(text).is_err() {
                break;
            }
        }
        Ok(())
    });

    (receiver, handle)
}
```

`mpsc::channel` creates the channel. The function returns the `Receiver<String>` and the `JoinHandle` for the reader thread.

The channel is typed; here it carries `String`s. The fully explicit type would be `mpsc::channel::<String>()`, but type inference usually saves you from writing it.

We move `sender` into the thread and call `sender.send(text)` for each file. Both `send` and `recv` return `Result`s, but they only fail when the _other end_ of the channel is dropped. If the receiver is gone, `send` fails; if all senders are gone and the channel is empty, `recv` fails.

In our case, `send` will fail when the receiver thread shuts down, so we just break and return `Ok(())` (or propagate any I/O errors).

### Receiving Values

Next, create another thread that _consumes_ those strings and builds `InMemoryIndex`es:

```rust
fn start_file_indexing_thread(
    texts: mpsc::Receiver<String>,
) -> (mpsc::Receiver<InMemoryIndex>, thread::JoinHandle<()>) {
    let (sender, receiver) = mpsc::channel();

    let handle = thread::spawn(move || {
        for (doc_id, text) in texts.into_iter().enumerate() {
            let index = InMemoryIndex::from_single_document(doc_id, text);
            if sender.send(index).is_err() {
                break;
            }
        }
    });

    (receiver, handle)
}
```

The `Receiver` is iterable, so we can just use `for` to get incoming values.

Subsequent stages (merging, writing index files, merging files) are similar; I’ll just show their signatures:

```rust
// Stage 3
fn start_in_memory_merge_thread(
    file_indexes: mpsc::Receiver<InMemoryIndex>,
) -> (mpsc::Receiver<InMemoryIndex>, thread::JoinHandle<()>)

// Stage 4
fn start_index_writer_thread(
    big_indexes: mpsc::Receiver<InMemoryIndex>,
    output_dir: &Path,
) -> (mpsc::Receiver<PathBuf>, thread::JoinHandle<io::Result<()>>)

// Stage 5 (no receiver; runs on caller's thread)
fn merge_index_files(
    files: mpsc::Receiver<PathBuf>,
    output_dir: &Path,
) -> io::Result<()>
```

Finally, we tie the stages together:

```rust
fn run_pipeline(
    documents: Vec<PathBuf>,
    output_dir: PathBuf,
) -> io::Result<()> {
    let (texts, h1) = start_file_reader_thread(documents);
    let (pints, h2) = start_file_indexing_thread(texts);
    let (gallons, h3) = start_in_memory_merge_thread(pints);
    let (files, h4) = start_index_writer_thread(gallons, &output_dir);
    let result = merge_index_files(files, &output_dir);

    let r1 = h1.join().unwrap();
    h2.join().unwrap();
    h3.join().unwrap();
    let r4 = h4.join().unwrap();

    r1?;
    r4?;
    result
}
```

We use `join().unwrap()` to surface panics in the worker threads, but we delay propagating I/O errors until after _all_ threads have joined. That way, even if one stage fails, we still shut down the pipeline cleanly.

## `mpsc`

We’ve been using `std::sync::mpsc`, so what does `mpsc` stand for? **multi‑producer, single‑consumer**.

Rust’s standard channels support multiple senders and a single receiver.

To add more senders, `clone` the original sender and move each clone into its own thread. The receiver side cannot be cloned; if you need multiple threads consuming from the same queue, you’ll need a `Mutex` or similar.

## Performance

Rust’s standard channel is highly optimized:

- Initially it uses a “one‑shot” queue implementation; if you only send one value, overhead is tiny.
- When you send a second value, it transparently switches to a different queue type that supports unbounded sends with minimal allocations.
- When you clone the sender, it switches again to a slightly slower queue that supports multiple producers. Even that implementation is lock‑free.
- Only when the channel is empty and a receiver calls `recv` does it park the thread with a system call.

One common performance pitfall is mismatched producer/consumer speeds. If senders outpace receivers, the channel backs up with unprocessed data, and senders may monopolize CPU time.

To avoid this, Rust offers **synchronous channels** with backpressure. Use `sync_channel` instead of `channel`:

```rust
use std::sync::mpsc;

let (sender, receiver) = mpsc::sync_channel(100);
```

This creates a channel with capacity 100. Once the channel holds 100 items, `send` blocks until a receiver takes something.

If you pass capacity 0, **every** send blocks until a receiver is ready.

## `Send` and `Sync`

By now we’ve brushed up against “thread safety” several times. In Rust, two marker traits encode this: `Send` and `Sync` from `std::marker`.

- `Send`: a type that is safe to move to another thread.
- `Sync`: a type that is safe to share references to between threads.

Most standard library types are both `Send` and `Sync`:

![send_and_sync.png](/published/fearless-concurrency/send_and_sync.png)

If all of a struct’s fields are `Send`/`Sync`, the struct itself is automatically `Send`/`Sync`. You don’t need `derive`.

You might think that `Send` implies `Sync`, but that’s not always the case. Our earlier `Receiver` type for channels is `Send` but not `Sync`, ensuring it’s only used by one thread at a time.

Many non‑`Send`/`Sync` types are those that use non‑atomic interior mutability, such as `Rc`.

# Shared Mutable State

We’ve seen two concurrency models so far:

1. Fork‑join parallelism for highly parallel computations.
2. Channels for decoupled component communication.

But sometimes you really do need shared, mutable state accessed from multiple threads.

One approach is to spawn a dedicated _state manager_ thread and have other threads interact with it solely via channels. That works, but threads are not free.

Rust also offers lower‑level primitives for shared mutable state.

## `Mutex`

A **mutex** (lock) enforces mutual exclusion: only one thread can access the protected data at a time.

Most languages provide some form of mutex, but in many of them, the lock is separate from the data. The compiler can’t force you to always lock before touching the data.

In Rust, the data lives _inside_ the `Mutex<T>`:

```rust
use std::sync::Mutex;

fn main() {
    let m = Mutex::new(5);

    {
        let mut num = m.lock().unwrap();
        *num = 6;
    }

    println!("m = {:?}", m);
}
```

The only way to access the inner `T` is via `lock`, which returns a `MutexGuard<T>`:

- `MutexGuard<T>` implements `Deref`, so you can use it like a `&T` or `&mut T`.
- When the guard is dropped, it automatically unlocks the mutex.

The full signature of `lock` returns a `Result<MutexGuard<T>>`. As with channels, the `Err` case only happens if _another_ thread using the mutex panicked, which "poisons" the mutex. This is Rust being conservative: if one thread panicked while holding the lock, the shared data might be in an inconsistent state.

While Rust’s `Mutex` avoids a lot of footguns, it can’t prevent everything:

- It can prevent data races, but not all race conditions.
- It can’t prevent deadlocks.

Those are inherent to the mutex abstraction itself.

### `Mutex` and `Arc`

Most of the time you’ll see `Mutex` combined with `Arc`:

```rust
use std::sync::{Arc, Mutex};
use std::thread;

fn main() {
    let counter = Arc::new(Mutex::new(0));
    let mut handles = vec![];

    for _ in 0..10 {
        let counter = Arc::clone(&counter);
        let handle = thread::spawn(move || {
            let mut num = counter.lock().unwrap();
            *num += 1;
        });
        handles.push(handle);
    }

    for handle in handles {
        handle.join().unwrap();
    }

    println!("Result: {}", *counter.lock().unwrap());
}
```

Wrapping the `Mutex` in an `Arc` lets us share ownership of the same mutex across threads. Each thread locks, increments, and unlocks.

## Atomics

Rust also has low‑level atomic types in `std::sync::atomic`, such as `AtomicIsize` and `AtomicBool`. These are all `Sync`, so you can share them across threads.

The naive pattern of "read → compute → write" is three separate operations. When multiple threads interleave them, you can get torn updates. Atomics compile down to single CPU instructions that perform the whole read‑modify‑write as one indivisible step.

Example using `AtomicIsize`:

```rust
use std::sync::Arc;
use std::sync::atomic::{AtomicIsize, Ordering};
use std::thread;

const COUNT: u32 = 1_000_000;

fn main() {
    let global = Arc::new(AtomicIsize::new(0));

    let clone1 = global.clone();
    let thread1 = thread::spawn(move || {
        for _ in 0..COUNT {
            clone1.fetch_add(1, Ordering::SeqCst);
        }
    });

    let clone2 = global.clone();
    let thread2 = thread::spawn(move || {
        for _ in 0..COUNT {
            clone2.fetch_sub(1, Ordering::SeqCst);
        }
    });

    thread1.join().unwrap();
    thread2.join().unwrap();
    println!("final value: {:?}", global);
}
```

One thread increments, the other decrements. No matter how many times you run it, the final value is 0. Try replacing `AtomicIsize` with a plain `isize` and you’ll see inconsistent results.

## Global Variables

Rust makes it hard to use global mutable state.

- `const` values are immutable.
- `static` variables are also immutable by default.

You _can_ declare `static mut`, but any access must be inside an `unsafe` block; the compiler can’t enforce thread safety.

For simple types like integers and booleans, use atomic types rather than `static mut`.

## Other Primitives

Rust also provides `RwLock<T>`, `Condvar`, `Barrier`, and more. They follow similar patterns; see the standard library docs for details.

# Summary

In this post we looked at Rust’s tools for concurrency:

1. **Fork-join parallelism** for highly parallelizable workloads.
2. **Channels** for communication between decoupled components.
3. **Lower‑level primitives** like `Mutex`, atomics, etc. when you need finer control over shared mutable state.

We’ve also seen that Rust’s ownership system and type system help prevent many classic concurrency bugs. In Rust, memory safety and concurrency are closely related—ownership is a powerful tool to avoid data races and enforce disciplined sharing.

The goal of "fearless concurrency" is not to eliminate all complexity, but to give you tools and guarantees that make it _much_ easier to write correct, robust concurrent code.

# References

- [Programming Rust](https://www.oreilly.com/library/view/programming-rust-2nd/9781492052586/)
- [深入浅出 Rust](https://book.douban.com/subject/30312231/)
- [Shared-State Concurrency - The Rust Programming Language](https://doc.rust-lang.org/book/ch16-03-shared-state.html)
