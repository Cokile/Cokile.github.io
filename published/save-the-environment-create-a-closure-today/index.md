---
layout: page
title: "Save the Environment Create a Closure Today!"
date: 2021-10-23
permalink: /save-the-environment-create-a-closure-today/
---

I couldn’t come up with a better title for this article, so I borrowed this line from [Cormac Flanagan](https://users.soe.ucsc.edu/~cormac/) instead. It may look a bit click‑baity, but it does capture the topic of this post quite well — closures. Closures originated from λ‑calculus and functional programming languages, and later many non‑functional languages added support for them as well. Our main character today, Rust, is one of them.

In this article, we’ll take a look at closures in Rust.

# First Look at Rust Closures

## Basic Syntax

The basic syntax of a closure in Rust looks like this:

```rust
fn main() {
	let add = |a: i32, b: i32| -> i32 {
		return a + b;
	};

	let result = add(1, 2);
	println!("result is {}", result);
}
```

In the example above, `add` is a closure. It has two parameters wrapped in `| |`, and its body is inside `{ }`.

Thanks to Rust’s type system, the parameter and return types of a closure can often be omitted:

```rust
let add = |a, b| { return a + b; };
```

According to Rust’s basic syntax rules, the explicit `return` at the end can also be omitted:

```rust
let add = |a, b| { a + b };
```

Furthermore, if the closure body contains only a single expression, the outer braces can be omitted as well:

```rust
let add = |a, b| a + b;
```

## Capturing Variables

Closures look very similar to functions, but they’re actually different. Consider the following example:

```rust
fn main() {
	let x: i32 = 1;

	let add_v2 = || x + 1;

	let result = add_v2();
	println!("result is {}", result);
}
```

A closure can use data from the environment in which it is defined. In the example above, the closure `add_v2` uses `x` from the `main` function. We say that the closure captures `x`.

If we rewrite the closure as a function:

```rust
fn main() {
	let x: i32 = 1;

	fn add_v3() -> i32 {
		x + 1
	}

	let result = add_v3();
	println!("result is {}", result);
}
```

The compiler will report an error: `error: can't capture dynamic environment in a fn item; use the || { ... } closure form instead [E0434]`.

Capturing variables is one of the defining capabilities of closures, and Rust certainly supports this. But Rust closures behave a bit differently. Let’s look at a JavaScript example:

```jsx
function startSortingAnimation(cities, stat) {
  function keyfn(city) {
    return city.get_statistic(stat);
  }

  if (pendingSort) pendingSort.cancel();

  pendingSort = new SortingAnimation(cities, keyfn);
}
```

The `startSortingAnimation` function is responsible for sorting the cities (`cities`), and the sort key comes from the statistic `stat` for each city. In this example, the closure `keyfn` is stored in the `SortAnimation` object, which means this closure will still be used after `startSortingAnimation` returns.

Normally, when a function returns, its variables and parameters go out of scope and are supposed to be destroyed. However, the JavaScript engine must keep `stat` alive because the closure `keyfn` still needs it. So most JavaScript engines will allocate `stat` on the heap, allowing the garbage collector to reclaim it later.

Rust, on the other hand, has no garbage collector. So how does Rust implement closures?

Let’s move on and take a look.

# How Rust Implements Closures

## Function Types

Before we dive deeper into closures, let’s briefly talk about functions.

Consider this function:

```rust
fn city_population(city: &City) -> i64 {
	city.population
}
```

This function takes a reference to a `City` and returns an `i64`, so its type is `fn(&City) → i64`. (As in Swift, if there is no return value, the `→ i64` part can be omitted and the default return type is `()`.)

A value of a function type is essentially the machine code address of that function, which is the same as a function pointer in C++.

In fact, for closures that do not capture any variables from their environment, they are essentially just function pointers, since they don’t need to carry any extra information.

## Variable Capture

Now let’s look at closures that do capture variables. (Unless otherwise noted, when we say “closure” below, we mean a closure that captures variables.)

The current implementation of closures in Rust is also called an "unboxed closure": when a closure is created, the compiler will generate a struct type for it. By analyzing the body of the closure, it infers which fields the struct needs to store and what their types should be.

Consider this example:

```rust
fn main() {
	let x: i32 = 1;
	let add_x = |a| x + a;
	let result = add_x(5);
	println!("result is {}", result);
}
```

Here is an equivalent implementation using an explicit struct:

```rust
struct Closure {
	inner: i32
}

impl Closure {
	fn call(&self, a: i32) -> i32 {
		self.inner + a
	}
}

fn main() {
	let x: i32 = 1;
	let add_x = Closure { inner: x };
	let result = add_x.call(5);
	println!("result is {}", result);
}
```

In this simplified model, creating a closure is analogous to creating a struct. We store the captured environment variables as fields of the struct, and calling the closure is analogous to calling a method on that struct.

There is an important detail here: because closures can capture different numbers of variables of different types, the compiler will generate a distinct struct type for each closure. In other words, no two closures share the same struct type.

With this rough mental model in place, we can now tackle the key questions. After the compiler desugars closure syntax into structs and method calls:

1. What types should be used for the struct fields? Should they be `&i32`, `&mut i32`, or `i32`?
2. What should the `self` type of the corresponding method be? `&self`, `&mut self`, or `self`?

For the first question, Rust primarily looks at how the captured variable is used inside the closure:

1. If an external variable is only ever accessed via a shared reference inside the closure, then the closure can capture it by shared reference.
2. If an external variable is accessed via a mutable reference inside the closure, then it must be captured by mutable reference.
3. If an external variable is used by moving its ownership into the closure, then it must be captured by value.

In short, as long as the code remains valid, the compiler chooses the capturing strategy that is the least restrictive to the outside world: it prefers `&T`, then `&mut T`, and only falls back to `T` when necessary.

### The `move` Keyword

The rules above apply to non‑escaping closures. For escaping closures, the situation is a bit different. For example:

```rust
use std::thread;

fn start_thread(x: i32) -> thread::JoinHandle<i32> {
	thread::spawn(|| {
	  x + 1
	})
}
```

According to the rules we just discussed, this closure would capture `x` by shared reference. But here Rust reports a compilation error instead: `closure may outlive the current function, but it borrows 'x', which is owned by the current function`.

The reason is that `thread::spawn` takes a closure and runs it in a new thread. Rust cannot guarantee that the lifetime of that closure is shorter than the lifetime of `start_thread`. In other words, the reference to `x` inside the closure might outlive `start_thread`, and Rust cannot guarantee the safety of that reference.

To fix this, we need to annotate the closure with the `move` keyword:

```rust
thread::spawn(move || {
	x + 1
})
```

`move` changes captures that would otherwise be by reference into captures by value. In other words, ownership of `x` is moved into the closure.

So even without a garbage collector, Rust provides two ways for a closure to access data: moving ownership and borrowing. Closures obey all the usual rules of ownership and borrowing, and Rust uses lifetimes to ensure safety. We covered ownership and borrowing in more detail in [previous article](/taking-arms-against-a-sea-of-objects/), so we won’t repeat it here, but there are a few points worth mentioning:

1. If the value being moved is `Copy`, then the operation is actually a copy rather than a move, as with `x` in this example.
2. For non‑`Copy` values, once ownership has been moved, Rust will no longer allow you to use the original value. If `x` were a `String` in this example, we wouldn’t be able to use `x` after creating the `spawn` closure.
3. If you still want to use a value after moving it into a closure, you need to clone it first and then move the clone instead.

## `Fn` / `FnMut` / `FnOnce`

We’ve only answered the first question so far. Now let’s move on to the second one: how closures are called.

Even though closures are implemented as structs, we don’t call them with method syntax using `.`, we call them as if they were functions. The reason is that the compiler implements three special traits for closures:

```rust
pub trait FnOnce<Args> {
    type Output;
    extern "rust-call" fn call_once(self, args: Args) -> Self::Output;
}

pub trait FnMut<Args>: FnOnce<Args> {
    extern "rust-call" fn call_mut(&mut self, args: Args) -> Self::Output;
}

pub trait Fn<Args>: FnMut<Args> {
    extern "rust-call" fn call(&self, args: Args) -> Self::Output;
}
```

These three traits are defined in `std::ops`. You can see that they form an inheritance chain of sorts: `FnMut` is a subtrait of `FnOnce`, and `Fn` is a subtrait of `FnMut`. Their main difference lies in the type of `self` used in the call method:

- For `FnOnce`, `self` is taken by value, so a closure implementing `FnOnce` can only be called once — hence the "Once" in the name.
- For `FnMut`, `self` is a mutable reference, so the closure can mutate its captured state.
- For `Fn`, `self` is a shared reference, so the closure can only read from the captured variables.

So how does Rust decide which traits a given closure implements? The answer is: Rust tries to implement all three, and keeps whichever ones make the code compile. When calling a closure, it prefers calling `call`, then falls back to `call_mut`, and finally to `call_once`.

At this point you might ask: “Why do we need these distinctions at all? I can understand having `Fn` and `FnMut`, but why do we need `FnOnce`, which can only be called once? In other languages, closures can be called as many times as you like.” The answer is that Rust must guarantee safety.

Take this example:

```rust
fn main() {
	let my_str = "hello".to_string();
	let f = || std::mem::drop(my_str);
	f();
	f(); // compile error
}
```

If the closure `f` could be called multiple times, `my_str` would be dropped twice, causing a double‑free memory safety bug.

Fortunately, Rust prevents this. The signature of `drop` is `fn drop<T>(x: T)`, which takes ownership of its argument. According to the capture rules discussed earlier, `f` must capture `my_str` by value. Based on what we’ve just seen, this means `f` can only implement `FnOnce` and cannot be called multiple times.

Now consider the `Fn` case:

```rust
fn main() {
	let v: Vec<i32> = vec![1, 2, 3];
	let c = || for i in &v { println!("{}", i) };
	c();
	c();
}
```

Here, the closure `c` only needs a `&Vec<i32>` to do its work, so it captures `v` by reference and can implement `Fn`, which means it can be called multiple times.

What if we add `move` to `c`?

```rust
fn main() {
	let v: Vec<i32> = vec![1, 2, 3];
	let c = move || for i in &v { println!("{}", i) };
	c();
	c();
}
```

This still compiles, because `c` only needs a reference to `v` when it runs. This highlights a subtle point that often confuses beginners: the _type_ of a closure is determined by how it _uses_ its captured variables, not by how it _captures_ them. The `move` keyword only affects how variables are captured, not which traits (`Fn`, `FnMut`, `FnOnce`) the closure implements.

## Back to Functions

A function can take another function as a parameter. For example:

```rust
fn count_selected_cities(cities: &Vec<City>, test_fn: fn(&City) -> bool) -> usize {
	let mut count = 0;
	for city in cities {
		if test_fn(city) {
			count += 1;
		}
	}
	count
}

fn has_monster_attacks(city: &City) -> bool {
   city.monster_attack_risk > 0.0
}

fn main() {
	let n = count_selected_cities(&my_cities, has_monster_attacks);
}
```

Here `count_selected_cities` takes a function `test_fn` as a parameter. If we try to pass a closure instead of a function, we’ll get a type mismatch error. The fix is straightforward: change the type of `test_fn` so that it can accept both functions and closures:

```rust
fn count_selected_cities<F>(cities: &Vec<City>, test_fn: F) -> usize
where
	F: Fn(&City) -> bool
{
	// ...
}
```

This works because Rust also implements the `Fn` trait for plain functions.

At this point we have two different types:

```rust
Fn(&City) -> bool
fn(&City) -> bool
```

`Fn` and `fn` are not the same:

- `Fn` is a trait. It can represent both functions and closures.
- `fn` is, in most cases, only for plain functions. Why “in most cases”? As we mentioned earlier, if a closure does not capture any variables, it is essentially a function pointer, so such closures can also be used where a `fn` is expected.

## `Clone` and `Copy` for Closures

Just as Rust can infer how a variable is captured, it can also infer whether a closure can implement `Clone` or `Copy`. Since closures are essentially structs whose fields are either values or references, the rules for closure `Clone`/`Copy` are the same as for any other struct:

- A non‑`move` closure that only captures variables by shared reference is both `Clone` and `Copy`.
- A non‑`move` closure that captures any variables by mutable reference is neither `Clone` nor `Copy`.
- A `move` closure is `Copy` if all of its captured variables are `Copy`. It is `Clone` if all of its captured variables are `Clone`.

## Performance of Closures

Finally, let’s briefly talk about the performance of closures.

In many languages, closures are:

- Allocated on the heap
- Invoked via dynamic dispatch
- Reclaimed by a garbage collector

This means that creating, calling, and reclaiming closures all incur runtime overhead. Even worse, closures can often defeat inlining, which is a crucial compiler optimization.

Rust closures, in contrast, avoid these costs:

1. Closures do not rely on garbage collection.
2. Unless placed inside containers like `Box` or `Rc`, closures are not heap‑allocated.
3. Because each closure has its own concrete type, the compiler can inline calls whenever it knows the closure’s type.

As a result, Rust closures are very efficient. That is by design: they aim to be fast — faster than function pointers — so that you can comfortably use closures even in performance‑critical code.

# Conclusion

In this article, we took a tour of closures in Rust. We started with basic syntax, then dug into how Rust implements closures under the hood.

Closures are a powerful abstraction tool that many languages provide. When you write Rust code, you will encounter closures frequently. I hope this article helps deepen your understanding of how they work in Rust.

# References

- [Programming Rust](https://www.oreilly.com/library/view/programming-rust-2nd/9781492052586/)
- [深入浅出 Rust](https://book.douban.com/subject/30312231/)
