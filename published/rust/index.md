---
layout: page
title: "Rust Misc Notes"
date: 2021-11-27
permalink: /rust/
---

This post collects various miscellaneous Rust tidbits. It will be updated from time to time as a memo for myself.

# Resources

## Rust FAQ

FAQ compiled by members of the Rust Chinese community: [Rust Common Questions Summary](https://rust-zh.github.io/faq/), GitHub repo: https://github.com/rust-zh/faq

Rust Chinese Telegram group link: [https://t.me/rust_zh](https://t.me/rust_zh)

## Rust Cheatsheet

An open-source Rust cheatsheet: [https://cheats.rs/](https://cheats.rs/)

## Lib.rs

[Lib.rs](https://lib.rs/) can be thought of as the community version of [crates.io](http://crates.io). Compared with the official site, it adds categories, trending, and statistics.

# Language

## Unsafe Rust: Unsafe from What

An unsafe feature is a feature that comes with a contract: Rust cannot strictly enforce that contract, but you must follow it to avoid undefined behavior.

These contracts are usually only mentioned in documentation; Rust itself has no idea they exist, so its safety checks cannot detect violations. Therefore, when using unsafe features, the programmer must verify that the code respects those contracts.

Unsafe features can only be used inside an `unsafe` block or an `unsafe` function. Rust uses this rule to ensure that you are aware there might be extra contracts you must follow.

— Source: [Programming Rust](https://www.oreilly.com/library/view/programming-rust-2nd/9781492052586/)

## Unsafe Block or Unsafe Function?

Regarding whether to use an `unsafe` block or mark the whole function as `unsafe`, a recommended approach is to first decide based on the function itself:

- If the function can be misused in a way that compiles but can still cause undefined behavior, then it must be marked `unsafe`. The rules for using the function correctly form its contract; the existence of this contract is what makes the function unsafe.
- Otherwise, the function is safe: any normal call to it will not cause undefined behavior. It should not be marked `unsafe`.

Whether a function uses unsafe features internally does not matter; what matters is whether there is a contract. Do not mark a function as unsafe just because its body uses unsafe features:

- This makes the function harder to use.
- It is also confusing for readers, because they will (rightly) expect to find the contract documented somewhere.

Instead, you should use an `unsafe` block, even if it makes up the entire body of the function.

— Source: [Programming Rust](https://www.oreilly.com/library/view/programming-rust-2nd/9781492052586/)

## Sized and ?Sized

`Sized` is a trait defined in `std::marker`:

```rust
pub trait Sized { }
```

It indicates types whose size is known at compile time. For example, the size of `u8` is 1 byte.

As with other traits in the `marker` module, we normally do not implement this trait directly. The compiler automatically implements it for types that meet the requirements, such as `u8`.

`Sized` and `?Sized` are usually used in type bounds.

Type parameters are, by default, implicitly bounded by `Sized`. For example:

```rust
struct Foo<T>(T);
```

is effectively equivalent to:

```rust
struct Foo<T: Sized>(T);
```

However, some types do not have a size known at compile time, for example:

1. Slices like `[u8]`, whose number of elements is not known at compile time.
2. Trait objects, whose concrete type is not known at compile time.

Such types cannot be used directly as the `T` in `Foo` above. We can work around this by putting them behind pointers or in `Box`, since the size of a pointer is always known.

Another way is to change the bound on `T` to `?Sized`, which means `T` may also be a type whose size is not known at compile time.

Note that `?Sized` is special syntax that Rust provides specifically for `Sized`. Other traits cannot be decorated with `?`.

— Source: [Sized in std::marker - Rust](https://doc.rust-lang.org/std/marker/trait.Sized.html)
