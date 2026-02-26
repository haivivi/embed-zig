# Development Guide

## Build & Test Commands

### Bazel First — Always Use Bazel

```bash
# Build everything
bazel build //...

# Run a single unit test
bazel test //lib/pkg/audio:aec3_test --test_output=all
bazel test //lib/pkg/audio:sim_audio_test --test_output=all
bazel test //lib/pkg/audio:resampler_test --test_output=all

# Run all audio tests
bazel test //lib/pkg/audio/... --test_output=errors

# Run an E2E test (requires real audio hardware)
bazel run //e2e/tier2_audio_engine/std:e1
bazel run //e2e/tier2_audio_engine/std:simple
bazel run //e2e/tier2_audio_engine/std:diag-noise

# Build a specific library
bazel build //lib/pkg/audio
bazel build //third_party/portaudio
bazel build //third_party/speexdsp:speexdsp_float

# Build with optimization
bazel build //e2e/tier2_audio_engine/std:e1 --compilation_mode=opt
```

### Zig Native (fallback for e2e tests with PortAudio)

```bash
cd e2e/tier2_audio_engine/std
zig build e1        # E1 loopback test
zig build diag-noise  # Noise diagnostic
zig build --help    # List all available steps
```

---

## Repository Structure

```
lib/
  trait/          # Abstract interface contracts (no platform deps)
  hal/            # Hardware abstraction layer traits
  pkg/            # Cross-platform libraries (trait + hal only)
    audio/        # AEC, NS, mixer, engine, SimAudio
    portaudio/    # Alias → //third_party/portaudio
  platform/
    esp/          # ESP32 implementations
    std/          # Desktop/Zig-std implementations (PortAudio, threads)
    raysim/       # Raylib simulator
third_party/
  portaudio/      # Built from source via zig cc (v19.7.0)
  speexdsp/       # Built from source via zig cc
  opus/           # Built from source
e2e/
  tier2_audio_engine/std/  # E1-E5 + diagnostic tests (bazel run)
```

---

## Code Style

### Zig Conventions

**File header** — every `.zig` file starts with a `//!` doc comment:
```zig
//! ModuleName — one-line description
//!
//! Longer explanation. Use ASCII art for data flow.
//! Include usage example in a code block.
```

**Imports** — standard ordering: std → third-party modules → local modules:
```zig
const std = @import("std");
const trait = @import("trait");
const speexdsp = @import("speexdsp");
const mixer_mod = @import("mixer.zig");
```

**Naming**:
- Types: `PascalCase` (`AudioEngine`, `SimConfig`)
- Functions/methods: `camelCase` (`readClean`, `processFrame`)
- Constants: `SCREAMING_SNAKE` for module-level, `camelCase` for local
- Struct fields: `snake_case` (`frame_size`, `echo_gain`)
- Errors: `PascalCase` (`InvalidDevice`, `BufferTooSmall`)

**Module-level aliases** — define common type aliases at the top:
```zig
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
```

**Generic types** — use `comptime` params for platform abstraction:
```zig
pub fn AudioEngine(comptime Rt: type, comptime Mic: type, comptime Speaker: type) type {
    comptime { _ = trait.audio.Mic(Mic); } // validate via trait
    return struct { ... };
}
```

### Error Handling

- Use `error{...}` union types — never return raw `anyerror` from public API
- Use `catch continue` in audio loops (drop frames, keep running)
- Use `errdefer` for cleanup on failure path
- PortAudio/hardware errors: return named errors, not panics
```zig
pub const PaError = error{ NotInitialized, InvalidDevice, ... };
fn check(code: c.PaError) PaError!void { ... }
```

### Struct Initialization

Always use named fields; structs with defaults use `= .{}` pattern:
```zig
pub const Config = struct {
    frame_size: u32 = 160,
    sample_rate: u32 = 16000,
    echo_gain: f32 = 0.76,
};

var cfg = Config{};                       // all defaults
var cfg = Config{ .frame_size = 320 };   // override one
```

---

## Architecture Rules

### Dependency Constraints

| Layer | Can depend on | MUST NOT depend on |
|-------|--------------|-------------------|
| `lib/pkg/*` | `lib/trait`, `lib/hal`, other `lib/pkg` | `lib/platform/*` |
| `lib/platform/esp` | any | `lib/platform/std`, `lib/platform/raysim` |
| `lib/platform/std` | `lib/pkg/*`, `lib/trait` | `lib/platform/esp` |
| App code | `lib/trait`, `lib/hal`, `lib/pkg/*` | `lib/platform/*` directly |

### Audio Pipeline (Critical)

The audio loop runs **single-threaded**, paced by hardware blocking I/O:
```
mixer.read() → speaker.write() → mic.read() → aec.process() → ns.process() → pushClean()
```
- `speaker.write()` blocks until hardware consumes the frame
- `mic.read()` blocks until hardware provides a frame
- This natural alignment means **no ring-buffer sync needed between mic and ref**

### SimAudio for Testing

Use `SimAudio` (not real hardware) for deterministic unit tests:
```zig
const Sim = sim_audio.SimAudio(.{
    .echo_delay_samples = 160,
    .echo_gain = 0.8,
    .has_hardware_loopback = true,
    .ambient_noise_rms = 50,
});
var sim = Sim.init();
try sim.start();
defer sim.stop();
```

### PortAudio Bindings

PortAudio is built from source via `zig cc` (in `//third_party/portaudio`).
Use **blocking I/O only** — `Pa_ReadStream` / `Pa_WriteStream`. No callbacks.
```zig
var stream = try pa.Stream.open(allocator, .{
    .input_channels = 1, .output_channels = 1,
    .sample_rate = 16000.0, .frames_per_buffer = 160,
});
defer stream.close();
try stream.start();
_ = try stream.read(&mic_buf);   // blocking
try stream.write(&spk_buf);      // blocking
```

---

## Bazel Rules

### Adding a new library

```python
# lib/pkg/mylib/BUILD.bazel
load("//bazel/zig:defs.bzl", "zig_package")

zig_package(
    name = "mylib",
    deps = ["//lib/trait"],  # add deps here
)
```

### Adding a test

```python
zig_test(
    name = "mylib_test",
    main = "src/mylib.zig",        # file with `test` blocks
    srcs = glob(["src/**/*.zig"]), # all sources in sandbox
    deps = ["//lib/trait", "//lib/platform/std"],
)
```

### Critical Bazel/Zig Rule

**`-I` flags MUST come BEFORE the `-M` module definition** in `zig build-exe`.
In Zig 0.15, `-I` placed after `-M` is silently ignored by clang during `@cImport`.
This is already handled in `bazel/zig/defs.bzl` — do not reorder.

### Adding a third-party C library

Follow the pattern in `third_party/portaudio/`:
1. `repository.bzl` — `repository_rule` that downloads + generates `BUILD.bazel`
2. `BUILD.bazel` — `zig_library` with `c_srcs`, auto-detect includes via `.h` filegroups
3. Register in `extensions.bzl` `_audio_libs_impl` and `MODULE.bazel`

---

## ⚠️ Hard Rules

- **No `Atomic(i128)` / `Atomic(u128)`** — use `Atomic(i64)` / `Atomic(u64)`
- **No `sh_binary` / `sh_test` in Bazel** — use Go for cross-platform executors
- **No callback-mode PortAudio** — always use blocking `Pa_ReadStream`/`Pa_WriteStream`
- **No TODO placeholders** — if a function is registered, it must be implemented end-to-end
- **No workarounds** — fix the root cause; stop and ask if blocked
- **Commit frequently** (every small working change) when not on main branch
