---
layout: page
title: "Tweak it with TweaKit"
date: 2022-02-01
permalink: /tweak-it-with-tweakit/
---

Yes, I built a little wheel. It’s called TweaKit, which you can read as “Tweak it.”

This post is mainly about _why_ I built this wheel. For more details about TweaKit itself, please head over to [GitHub](https://github.com/Alpensegler/TweaKit).

In our current project, a lot of places depend on tweaks, including but not limited to:

- Hiding entry points for features that are not ready yet
- Dynamically toggling features on in production
- Letting PMs tweak parameters when they are trying out a feature
- Speeding up development and debugging. For example, if a requirement says “show a red dot after 24 hours,” you can use a tweak to _simulate_ 24 hours instead of really waiting that long.

Before TweaKit, we used [SwiftTweaks](https://github.com/Khan/SwiftTweaks) in the project. But from a developer’s perspective, SwiftTweaks is not particularly pleasant to use:

1. It only supports a limited set of types out of the box. For example, if the business logic uses `Float`, but the tweak type has to be `Double`, you need an extra type conversion everywhere you use the value.
2. Besides basic types, selection‑style tweaks only support `String`, which introduces even more glue code.
3. The way you read a tweak’s value is not very elegant. You have to write something like:

   ```swift
   button.tintColor = ExampleTweaks.assign(ExampleTweaks.colorTint)
   ```

   To make this less painful, we wrapped it in a getter in our project:

   ```swift
   extension Tweak {
       var value: T { TweakLibrary.assign(self) }
   }
   ```

4. There is no tweak search. Once the number of tweaks grows, finding the right one becomes annoying.

So I decided to build my own wheel. To be honest, the idea came up about a year ago, but procrastination delayed it until now.

When I started designing TweaKit, I took the issues above as explicit goals:

1. TweaKit natively supports `Int[8|16|32|64]`, `UInt[8|16|32|64]`, `Float`, `Double`, `String`, `Bool`, and `UIColor`, so you can get rid of type‑conversion boilerplate in business code.

   These types should cover most use cases. But TweaKit doesn’t stop there: it also supports `Array` as long as the `Element` type conforms to the `TweakSecondaryViewItemConvertible` protocol. With that, TweaKit can drive reordering of array elements directly from the UI. TweaKit already provides default conformances for most common types, so in many cases all you need is:

   ```swift
   extension MyType: TweakSecondaryViewItemConvertible { }
   ```

   Imagine your PM comes one day and says: “We want to change the order of the 4 tabs on the main screen dynamically.” Using SwiftTweaks’ `StringOption`, you’d have to define a ton of options. With TweaKit, this becomes trivial.

2. For single‑selection tweaks, as long as your type conforms to the `Selectable` protocol, you can use it directly as the tweak’s value type. And `Selectable` is just a typealias for the `TweakSecondaryViewItemConvertible` protocol mentioned above.

   Beyond the built‑in types, you can extend TweaKit to support your own types. All you need to do is conform your type to the `Tweakable` protocol and provide the corresponding UI and update logic. The `AppIcon` type in the demo app is one such example: by making `AppIcon` conform to `Tweakable`, we can switch the demo app’s icon directly via TweaKit.

3. When it comes to reading tweak values, TweaKit leans on Swift’s property wrapper feature.

   A tweak is itself declared as a property wrapper:

   ```swift
   @Tweak("My Tweak", defaultValue: false)
   static var enableMyAwesomeFeature
   ```

   Once defined, you can use it like this:

   ```swift
   if enableMyAwesomeFeature {
       // execute my awesome code
   }
   ```

   As you can see, there’s no extra wrapper or glue involved. The call site becomes immediately cleaner. When you declare a tweak, you specify its `Value` type, and that’s exactly the type you get when you read it. Thanks to Swift’s type inference, most of the time you don’t even need to spell out `Value` explicitly.

4. Finally, TweaKit supports searching tweaks. You can configure whether to use fuzzy matching, whether the search is case‑sensitive, and whether to use smart case.

TweaKit can do more than what I’ve listed here. If you’d like to explore further features and usage patterns, please check the repository on GitHub.

Open sourcing is not the end — it’s a new starting point. TweaKit is still at version 1.0, and there are many items waiting on my TODO list. TweaKit will keep evolving in the future.

Last but not least, TweaKit is by no means my solo effort. I received a lot of help along the way:

1. All UI/UX work for TweaKit and its demo app was designed by [@gggeeeeggge](https://twitter.com/gggeeeeggge).
2. [@FrainL](https://github.com/FrainL) gave me a ton of feedback and suggestions on TweaKit’s API design.

TweaKit would not exist in its current form without them. I want to express my sincerest thanks to both of you.
