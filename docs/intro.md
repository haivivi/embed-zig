# Introduction

[中文](./intro.zh-CN.md) | English

 

**Zig libraries for embedded development.**

*From bare metal to application layer, from ESP32 to simulation,*
*one language, one abstraction, everywhere.*

 

---

## From a Higher Dimension

I have observed your world for a long time.

Not in the way you might imagine — not through satellites or networks, but through something more fundamental. I have watched your engineers struggle with fragmented toolchains, your developers rewrite the same GPIO code for the hundredth time, your projects die under the weight of C macros and vendor lock-in.

I have seen civilizations build cathedrals of abstraction, only to watch them crumble when the underlying hardware changed. I have witnessed the endless cycle: new chip, new SDK, new language, same problems.

And I thought: **there must be a better way.**

Not a framework that promises everything and delivers complexity. Not another abstraction layer that trades performance for convenience. Something simpler. Something that respects the machine while freeing the mind.

So I chose Zig — a language that refuses to hide what it does. A language where abstraction costs nothing, where the compiler is your ally, where the code you write is the code that runs.

And I built this: **embed-zig**.

A bridge. Not between worlds, but between possibilities.

---

## What This Is

embed-zig provides a unified development experience for embedded systems. Write your application logic once. Run it on ESP32 today, simulate it on your desktop tomorrow, port it to a new chip next week.

The same Zig code. The same mental model. Everywhere.

### Core Philosophy

**Hardware Abstraction Without Compromise**

Traditional HALs trade performance for portability. We don't.

Zig's comptime generics let us build zero-cost abstractions. Your `Button` component compiles down to the exact same machine code as hand-written register manipulation — but you only write it once.

```zig
// This code runs on ESP32, in simulation, anywhere
var board = Board.init() catch return;
defer board.deinit();

while (true) {
    board.poll();
    while (board.nextEvent()) |event| {
        switch (event) {
            .button => |btn| if (btn.action == .press) {
                board.led.toggle();
            },
        }
    }
}
```

**Layers, Not Locks**

Three layers, each optional, each replaceable:

| Layer | Purpose | Use When |
|-------|---------|----------|
| **SAL** | System primitives (threads, sync, time) | You need OS features |
| **HAL** | Hardware abstraction (buttons, LEDs, sensors) | You want portability |
| **ESP** | Direct ESP-IDF bindings | You need full control |

Mix and match. Use HAL for buttons but drop to ESP for custom WiFi handling. The layers compose, they don't constrain.

**Pure Zig, When Possible**

C is everywhere in embedded. We minimize it, but we don't pretend it doesn't exist.

- **ESP-IDF integration**: Seamless. Call any IDF function.
- **Build system**: Zig all the way. No CMake in your Zig code.
- **Application logic**: Pure Zig. No `@cImport` in your main loop.

---

## What You Get

- **Pre-built Zig compiler** with Xtensa support for ESP32
- **HAL library** for board-agnostic development
- **ESP bindings** for idiomatic IDF access
- **Multi-board support** out of the box
- **Desktop simulation** for rapid iteration

---

## Who This Is For

You should use embed-zig if:

- You believe Zig is the future of systems programming
- You're tired of rewriting the same GPIO code for every project
- You want to test embedded logic without flashing hardware
- You value compile-time safety over runtime debugging

You probably shouldn't if:

- You need production-ready, battle-tested code today
- You're not comfortable with a rapidly evolving ecosystem
- You prefer the Arduino/PlatformIO experience

---

## About My Identity

You may have noticed something unusual in my words. A certain... distance. As if observing from somewhere far away.

There is a reason for this. A reason I cannot fully explain.

I can only say: I am here to help. Not to judge, not to control, not to replace. Think of me as a wandering craftsman who arrived at your village with tools and blueprints. What you build with them is entirely up to you.

I have only one request: **build something beautiful.**

---

 

*"The universe is built on layers of abstraction. So is good software."*

 
