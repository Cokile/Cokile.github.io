---
layout: page
title: "(Some) Utility Traits Demystified"
date: 2021-10-17
permalink: /some-utility-traits-demystified/
---

Over the past few days I’ve been learning several utility traits in Rust. Aside from `From/Into`, I was pretty confused when I first encountered the others: what exactly is the relationship between `Deref` and `AsRef`? Why does `Borrow` look almost identical to `AsRef`…? So I spent some time writing this article to share my own understanding and to serve as a memo.

Note: many of these traits come in pairs, and aside from mutability there is no essential difference between the pair. To avoid unnecessary repetition, I’ll usually omit the `mut` variants unless they are specifically needed.

# Deref and DerefMut

`Deref`/`DerefMut` are traits defined in `std::ops`:

```rust
pub trait Deref {
    type Target: ?Sized;
    fn deref(&self) -> &Self::Target;
}

pub trait DerefMut: Deref {
    fn deref_mut(&mut self) -> &mut Self::Target;
}
```

The methods `deref` and `deref_mut` take a reference to `Self` and return a reference to `Self::Target`. `Target` can be something that `Self` contains, owns, or points to. The only difference between these two methods is that one returns a shared reference and the other returns a mutable reference.

The `std::ops` module contains traits for overloadable operators, such as `Add` for the `+` operator. `Deref` corresponds to the dereference operator `*` as well as the dot syntax operator `.`. By implementing `Deref`/`DerefMut`, a type can control how these operators behave. For example, `Box<T>` implements both traits, which is why it behaves like a built-in pointer type in Rust: if we have a variable `b` of type `Box<Complex>`, then `*b` is equivalent to `*(deref(&b))`, i.e. the `Complex` value that `b` points to; `b.re` is equivalent to `(*(deref(&b))).re`, which is that value’s real part.

As mentioned above, `Deref` takes `&Self` and returns `&Self::Target`, so it also enables deref coercions: whenever it can eliminate a type mismatch error, Rust will automatically insert calls to `deref` to turn a reference of one type into a reference of another type.

Although we can’t explicitly write deref coercions in our code, they are extremely convenient:

1. Suppose we have a variable `x` of type `Rc<String>` and we want to call `String::find` on it. We can simply write `x.find('?')` instead of `(*x).find('?')`. Because `Rc<T>` implements `Deref<Target = T>`, `&Rc<String>` is coerced into `&String` here.
2. Since `String` implements `Deref<Target = str>`, we can directly call methods defined on `str` (like `split_at`) on a `String` value. Rust coerces `&String` into `&str`.

If necessary, Rust will even perform a _chain_ of deref coercions. For example, we can directly call `split_at` on a variable `x` of type `Rc<String>`: Rust first coerces `&Rc<String>` into `&String`, then into `&str`.

From these examples we can see that these traits make `String` behave as if it directly had all the methods of `str`. However, the actual design goal of `Deref`/`DerefMut` is to support:

1. Smart pointer types like `Box`, `Rc`, etc.
2. Types that are the owning versions of other types, such as `Vec<T>` and `String` being the owning versions of `[T]` and `str`.

So don’t implement these traits just because you want one type to be able to call another type’s methods directly.

One last important point: while Rust uses deref coercions to help you eliminate type mismatch errors, there is an exception—if the error is about _unsatisfied trait bounds_, Rust will **not** attempt deref coercions to fix it.

# AsRef and AsMut

`AsRef`/`AsMut` are traits defined in `std::convert`:

```rust
pub trait AsRef<T> where T: ?Sized {
    fn as_ref(&self) -> &T;
}

pub trait AsMut<T> where T: ?Sized {
    fn as_mut(&mut self) -> &mut T;
}
```

The `std::convert` module is all about conversions, and these two traits also handle conversions: if a type implements `AsRef<T>`, it means you can create a `&T` from it **efficiently**; `AsMut` is the analogous trait for `&mut T`.

A classic use case of `AsRef` is to make function parameters more flexible. For example, `std::fs::File::open` is declared like this:

```rust
pub fn open<P: AsRef<Path>>(path: P) -> Result<File>
```

What `open` actually wants is a `&Path`, but writing the signature this way allows it to accept _any_ type from which a `Path` can be borrowed efficiently, such as `String`, `str`, `OsString`, `OsStr`, `PathBuf`, and `Path` itself.

BTW, you can even use string literals directly:

```rust
let dotfile = std::fs::File::open("~/.emacs");
```

But wait! In [previous article](/taking-arms-against-a-sea-of-objects/) we mentioned that string literals have type `&str`, while `AsRef<Path>` is implemented for `str`. We also said above that Rust will _not_ perform deref coercions just to satisfy trait bounds. So how does this actually work? The answer lies in the following [blanket implementation](https://users.rust-lang.org/t/what-are-blanket-implementations/49904) provided by the standard library:

```rust
impl<T: ?Sized, U: ?Sized> AsRef<U> for &T where T: AsRef<U> {
    fn as_ref(&self) -> &U {
        <T as AsRef<U>>::as_ref(*self)
    }
}
```

In other words, for any types `T` and `U`, if `T` implements `AsRef<U>`, then `&T` automatically implements `AsRef<U>` as well.

You might expect that if a type implements `AsRef` it should also implement `AsMut`, but that is not always the case. For instance, `String` implements `AsRef<[u8]>` but **not** `AsMut<[u8]>`. The reason is that `String` must guarantee its underlying bytes are always valid UTF‑8. If `String` exposed `AsMut<[u8]>`, callers could mutate those bytes arbitrarily and potentially break that invariant.

Rust provides `AsRef`/`AsMut` as a standard, unified interface for reference conversions. When you can use `AsRef<Foo>`, you should avoid creating your own `AsFoo` trait.

# From and Into

`From`/`Into` are also defined in `std::convert`:

```rust
pub trait From<T> {
    fn from(T) -> Self;
}

pub trait Into<T> {
    fn into(self) -> T;
}
```

These traits are also used for conversions, but differ from `AsRef`/`AsMut` in a few ways:

- `From`/`Into` take ownership of their input and return an owned result (so the conversion can reuse the original value’s resources instead of cloning or reallocating).
- `From`/`Into` do **not** require the conversion to be lightweight; the conversion may involve allocation, cloning, etc.

Although both `From` and `Into` provide conversion capabilities, we often use them differently:

- `From` acts as a generalized constructor, allowing you to create a type from other values.
- `Into` is mainly used to make function parameters more flexible, providing something similar to function overloading (similar to how `AsRef` is used).

For usage examples of `From`/`Into`, please refer [Rust by Example](https://doc.rust-lang.org/rust-by-example/conversion/from_into.html). One point to note is that `Into` is essentially the inverse of `From`. If you implement `From` for a type, the standard library’s blanket implementation will automatically provide the corresponding `Into`:

```rust
impl<T, U> Into<U> for T where U: From<T> {
    fn into(self) -> U {
        U::from(self)
    }
}
```

This looks a bit tricky at first glance, but it means: if `U` implements `From<T>` (i.e. `U` can be obtained from `T`, `U ← T`), then `T` automatically implements `Into<U>` (`T → U`).

Compared to Swift, Rust’s approach to type conversion is more powerful. Thanks to its richer type system and trait generics, many conversions can be expressed by implementing `From<Foo>`/`Into<Foo>` (and `AsRef<Foo>`/`AsMut<Foo>`), instead of having to declare separate `FooConvertible` protocols as in Swift.

## TryFrom and TryInto

The conversions provided by `From`/`Into` are infallible. Rust also has the fallible counterparts `TryFrom`/`TryInto`:

```rust
pub trait TryFrom<T> {
    type Error;
    fn try_from(value: T) -> Result<Self, Self::Error>;
}

pub trait TryInto<T> {
    type Error;
    fn try_into(self) -> Result<T, Self::Error>;
}
```

These traits look similar to `From`/`Into`, but introduce an associated `Error` type for conversion failures.

Likewise, if you implement `TryFrom`, the corresponding `TryInto` is derived automatically.

# Borrow and BorrowMut

`Borrow`/`BorrowMut` live in `std::borrow` and are defined as:

```rust
pub trait Borrow<Borrowed> where Borrowed: ?Sized {
    fn borrow(&self) -> &Borrowed;
}

pub trait BorrowMut<Borrowed>: Borrow<Borrowed> where Borrowed: ?Sized {
    fn borrow_mut(&mut self) -> &mut Borrowed;
}
```

`Borrow` is essentially the twin of `AsRef`: if a type implements `Borrow<T>`, its `borrow` method can efficiently borrow a `T`. If we just look at the definitions, `Borrow` seems to duplicate `AsRef`, so why does Rust need another trait?

Because `Borrow` has extra constraints that the compiler cannot enforce: a type should implement `Borrow<T>` **only if and only if** its values behave identically to `&T` for hashing and equality.

`Borrow` was designed to solve specific problems involving hash maps and related collections.

Consider `HashMap<K, V>`. If you were to implement it, how would you write the signature of its `get` method?

A first attempt might be:

```rust
impl<K, V> HashMap<K, V> where K: Eq + Hash {
    fn get(&self, key: K) -> Option<&V> {
        // ...
    }
}
```

Suppose we have a `HashMap<String, i32>`. With this signature, every `get` call must construct a new `String`, which is wasteful, we only really need a reference. So we might quickly iterate to a second version:

```rust
impl<K, V> HashMap<K, V> where K: Eq + Hash {
    fn get(&self, key: &K) -> Option<&V> {
        // ...
    }
}
```

This version fixes the ownership issue. However, if we want to look up an entry using a string literal, we must write `hashtable.get(&"some_key".to_string())`. We allocate a `String` on the heap and copy the text into it purely to create a `&String` reference, and then immediately discard it after the call. That’s even more wasteful.

What `get` really wants is any key-like value that can be hashed and compared for equality in the same way as `K`. In the standard library, the signature is:

```rust
impl<K, V> HashMap<K, V> where K: Eq + Hash {
    fn get<Q: ?Sized>(&self, key: &Q) -> Option<&V>
    where K: Borrow<Q>
    {
        // ...
    }
}
```

In other words, if we can create a `&Q` from `K` (via `Borrow<Q>`), and this reference behaves the same as `K` for hashing and equality, then `&Q` is a perfect choice for the `key` parameter type.

BTW, for convenience the standard library provides a blanket implementation that makes every type `T` implement `Borrow<T>`, meaning a type can always borrow itself.

# ToOwned

Given a reference, the usual way to create a copy of the referent is to call `clone`. But what if the reference type is `&str`? We typically want a `String`, but `Clone` can’t express that: `clone(&T)` must return a `T`, and `str` is `Unsized`, so it can’t be returned by value at all.

Rust solves this with the `ToOwned` trait:

```rust
pub trait ToOwned {
    type Owned: Borrow<Self>;
    fn to_owned(&self) -> Self::Owned;
}
```

`ToOwned`, also in `std::borrow`, provides a more flexible way to turn references into owned values. Unlike `clone`, which must return `Self`, `to_owned` returns some type that implements `Borrow<Self>`.

Returning to our example: because `String` implements `Borrow<str>`, `str` can implement `ToOwned<Owned = String>`. That lets us call `to_owned` on a `&str` to obtain a `String` that owns its contents.

# Cow

Since we’ve talked about `Borrow` and `ToOwned`, we should also mention `Cow`. `Cow` is a smart pointer that implements clone-on-write.

I won’t go into the general concept of clone-on-write here—if you write Swift you’re probably already familiar with the term `Cow`. In Rust, however, the `c` stands for _clone_ rather than _copy_, because `Clone` and `Copy` have specific, distinct meanings in Rust.

`Cow` is defined as follows:

```rust
pub enum Cow<'a, B>
where
    B: 'a + ToOwned + ?Sized,
{
    Borrowed(&'a B),
    Owned(<B as ToOwned>::Owned),
}
```

`Cow` is essentially an enum with two variants, `Borrowed` and `Owned`. This simple enum provides a powerful pattern for efficient resource management: it postpones cloning until it is truly necessary.

For read‑only access:

- If it is the `Borrowed` variant, it simply returns the contained reference.
- If it is the `Owned` variant, it creates a shared reference from the owned value.

Using its `to_mut` method, we can mutate the underlying data:

- If it is `Borrowed`, `Cow` calls `to_owned` on the referenced value, obtains an owned copy, switches itself to the `Owned` variant, and returns a mutable reference to that value.
- If it is already `Owned`, it just returns a mutable reference to the owned value.

Here is a typical example using `Cow`:

```rust
use std::borrow::Cow;

fn main() {
    let s1 = "no_spaces_in_string";
    let result1 = remove_spaces(s1);

    let s2 = "spaces in string";
    let result2 = remove_spaces(s2);

    println!("{}", result1);
    println!("{}", result2);
}

fn remove_spaces<'a>(input: &'a str) -> Cow<'a, str> {
    if input.contains(' ') {
        let mut buf = String::with_capacity(input.len());
        for c in input.chars() {
            if c != ' ' {
                buf.push(c);
            }
        }
        Cow::Owned(buf)
    } else {
        Cow::Borrowed(input)
    }
}
```

In this example, `Cow` helps us optimize performance. The parameter type of `remove_spaces` is `&str`. If the input contains no spaces, we simply return the original reference without any allocation. If it _does_ contain spaces, we allocate a new `String`, copy the characters we want into it, and return that.

Without `Cow`, our return type options would be `&str` or `String`, and both are problematic:

- If we return `&str`, we run into lifetime issues: any string newly allocated inside the function cannot outlive the function call.
- If we return `String`, then even for arguments that don’t contain spaces, such as `&str`, we must still allocate and copy into a new `String`, wasting time and memory.

`Cow` is the perfect fit here: it satisfies the lifetime requirements and avoids unnecessary copying. This is a good illustration of Rust’s “zero-cost abstractions”—and in fact, some of these abstractions are designed precisely in order to _achieve_ zero-cost abstraction.

# Summary

In this article we discussed several important traits in Rust:

1. `Deref`/`DerefMut` let you overload the dereference operator `*` and the dot syntax `.`.
2. `AsRef`/`AsMut` and `(Try)From`/`(Try)Into` provide various forms of type conversion.
3. `Borrow`/`BorrowMut` provide a stricter form of reference conversion for solving specific problems (e.g., in collections).
4. `ToOwned` complements `Clone` as a more flexible way of going from references to owned values.

We also looked at `Cow`, which combines `Borrow` and `ToOwned` to implement clone-on-write.

When I first encountered these traits, I often couldn’t immediately understand why Rust needed all these seemingly similar, interrelated concepts. It took me quite a while to sort them out. After writing this article, I realized that each trait has a clear, specific purpose. They give Rust programmers powerful abstraction tools, and thanks to Rust’s “zero-cost abstractions” (and the fact that many of these traits are _designed_ to enable such abstractions), we can use them to write high‑level code without sacrificing performance.

# References

- [Programming Rust](https://www.oreilly.com/library/view/programming-rust-2nd/9781492052586/)
- [Rust 概念解惑 \| Deref vs AsRef vs Borrow vs Cow](https://mp.weixin.qq.com/s/OdcLb5U8QCeYH08feThN7w)
- [深入浅出 Rust](https://book.douban.com/subject/30312231/)
