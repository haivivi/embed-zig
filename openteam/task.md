# Task: lib/pkg/audio — 跨平台软件音频引擎

## 当前状态：Engine 架构重新设计

### 核心设计变更：Ref 对齐由 platform 负责

**问题**：AEC 的 ref 和 mic 不对齐，导致实机 ERLE 受限。之前尝试了 delay_estimator、ref ring buffer 等方案都有问题。

**解决方案**：Engine comptime 参数化，两种 ref 获取方式：

```zig
pub fn AudioEngine(
    comptime Rt: type,
    comptime Mic: type, 
    comptime Speaker: type,
    comptime config: EngineConfig,
) type {

pub const EngineConfig = struct {
    frame_size: u32 = 160,
    sample_rate: u32 = 16000,
    speaker_buffer_depth: u32 = 0,  // platform speaker 的 buffer 帧数
    RefReader: ?type = null,         // 可选：platform 提供对齐好的 ref
    enable_aec: bool = true,
    enable_ns: bool = true,
    // ...
};
```

**方式 1：speaker_buffer_depth（大部分场景）**

Platform 声明 speaker 有几帧 buffer。Engine 内部维护 ref_history ring，取 delay 帧前的 ref 和 mic 配对。

```
loop:
    ref = mixer.read()
    ref_history.push(ref)
    speaker.write(ref)
    mic.read(mic_buf)
    aligned_ref = ref_history[speaker_buffer_depth]
    aec.process(mic, aligned_ref, clean)
```

**方式 2：RefReader（高级场景）**

Platform 提供 `RefReader` trait（`fn read(buf) !usize`），返回和 mic 对齐的 ref。
适用于硬件回环设备、DuplexStream 对齐等。

```
loop:
    ref = mixer.read()
    speaker.write(ref)
    mic.read(mic_buf)
    ref_reader.read(aligned_ref)   // platform 保证对齐
    aec.process(mic, aligned_ref, clean)
```

### PortAudio 两种实现（都测）

**实现 A：buffer_depth 模式**
- speaker = OutputStream（独立 stream）
- mic = InputStream（独立 stream）
- speaker_buffer_depth = PortAudio suggestedLatency / frame_time（约 5 帧）
- Engine 用 ref_history 取对应帧

**实现 B：DuplexStream RefReader 模式**
- DuplexStream callback 同时处理 input + output
- callback 里缓存 output → ref buffer
- RefReader.read() 返回和 mic 精确对齐的 ref
- speaker_buffer_depth = 0（RefReader 接管）

### 验证计划

1. 实现 A + 实现 B 都用 E1 测试
2. 对比两种方式的 ERLE
3. 都用 step3 (440Hz) 和 step5 (TTS) 验证
4. 确认无正反馈

---

## PM Review (2026-02-23)

### 架构变更审核

**问题定义正确**：之前的单 loop 架构里 ref 和 mic 来自不同的 blocking I/O，时序不对齐。speaker.write(ref) 把数据给了硬件 buffer，mic.read() 采到的回声对应的是几帧之前的 ref，不是当前帧的 ref。这是实机 ERLE 受限的根本原因。

**解决方案合理**：两种模式通过 comptime 参数选择，不影响 ESP32 等平台。

#### 方案分析

**方式 1（buffer_depth）**：简单直接。speaker.write() 后把 ref 存到 ring，mic.read() 后取 N 帧前的 ref。N = speaker 硬件 buffer 深度。

**优点**：不改 mic/speaker HAL 接口，ESP32 等嵌入式平台直接用。只需知道 speaker buffer 深度（DMA frame count 或 PortAudio suggestedLatency）。

**风险**：buffer_depth 是估算值，不精确。PortAudio 的 suggestedLatency 不等于实际 latency。如果估偏了，ref 对齐不准，ERLE 反而可能降。

**方式 2（DuplexStream RefReader）**：PortAudio callback 同时拿到 input 和 output，ref 和 mic 天然帧对齐（same callback same sample clock）。这是之前 step3-step6 的做法——那些测试 ERLE 更好就是因为 DuplexStream 的对齐优势。

**优点**：最精确的 ref 对齐。
**缺点**：需要 platform 提供 DuplexStream 能力。ESP32 I2S DMA 也是双向同步的，可以做到。

#### 关于实际代码

看了 `engine.zig`——当前已经是两个 task（speakerTask + micTask）+ ref_ring 的架构。但文档里说的 comptime `speaker_buffer_depth` 和 `RefReader` 参数**还没有加到代码里**。当前 EngineConfig 还是旧的（第 47-54 行），没有 `speaker_buffer_depth` 和 `RefReader`。

当前 `popRef()` 直接取最新的 ref（第 312 行：`if write == read → 静音`，否则取 read slot）——**没有 delay 补偿**。这等于 speaker_buffer_depth = 0，假设 ref 和 mic 同帧对齐，但实际不是。

### 结论

**两种方式都做。不是选一个，是都要。**

AEC 差一帧对齐效果就天差地别。方式 2（RefReader + DuplexStream）能给最精确的对齐——之前 step3-step6 的实机 ERLE 比 Engine 好，就是因为 DuplexStream callback 天然帧对齐。这个优势不能丢。

方式 1（buffer_depth）是给没有硬件回环能力的平台用的（某些 RTOS I2S 配置只能分开读写）。

两种方式通过 comptime 参数选择，零运行时开销。

#### Engine comptime 参数化

```zig
pub fn AudioEngine(
    comptime Rt: type,
    comptime Mic: type,
    comptime Speaker: type,
    comptime config: EngineConfig,
) type {

pub const EngineConfig = struct {
    frame_size: u32 = 160,
    sample_rate: u32 = 16000,
    enable_aec: bool = true,
    enable_ns: bool = true,

    // Ref 对齐方式（二选一）
    RefReader: ?type = null,          // 方式 2：platform 提供对齐好的 ref
    speaker_buffer_depth: u32 = 0,    // 方式 1：Engine 内部 ring buffer 补偿
};
```

- `RefReader != null` → 方式 2：micTask 调 `RefReader.read()` 获取对齐的 ref，不用 ref_ring
- `RefReader == null` → 方式 1：speakerTask pushRef → micTask popRef（delay = speaker_buffer_depth）

#### PortAudio std 平台：两种方式都实现，用来测试和对比

PortAudio 必须同时提供两种实现，跑实机对比 ERLE，用数据说话。

**实现 A: Separate Streams + buffer_depth（方式 1）**

```zig
// lib/platform/std/src/impl/mic.zig — PortAudio InputStream
// lib/platform/std/src/impl/speaker.zig — PortAudio OutputStream
// 两个独立 stream，不共享 callback

const Engine = AudioEngine(Rt, PaMic, PaSpeaker, .{
    .speaker_buffer_depth = 5,  // 试不同值
});
```

**实现 B: DuplexStream + RefReader（方式 2）**

```zig
// lib/platform/std/src/impl/duplex_audio.zig — PortAudio DuplexStream
const DuplexAudio = struct {
    duplex: pa.DuplexStream(i16),
    ref_buf: [FRAME_SIZE]i16,  // callback 里缓存 output

    // 作为 Mic: read() 返回 input
    // 作为 Speaker: write() 填到 output
    // 作为 RefReader: read() 返回和 mic 帧对齐的 ref
};

const Engine = AudioEngine(Rt, DuplexMic, DuplexSpeaker, .{
    .RefReader = DuplexRefReader,  // 精确对齐
});
```

**对比测试（必须跑）：**

```
T1 440Hz 10s:
  实现 A (buffer_depth=3): ERLE = ?dB
  实现 A (buffer_depth=5): ERLE = ?dB
  实现 A (buffer_depth=8): ERLE = ?dB
  实现 B (DuplexStream):   ERLE = ?dB  ← 预期最高

T3 TTS:
  实现 A (最优 depth):     ERLE = ?dB
  实现 B (DuplexStream):   ERLE = ?dB

把数据填到这个表里，不是猜的，是跑出来的。
```

#### ESP32 平台

ESP32 I2S full-duplex 也是同一 DMA 时钟驱动 TX/RX，可以做方式 2。如果某板子不支持双向同步，fallback 方式 1。

#### 方式 1 作为 fallback

```zig
const Engine = AudioEngine(Rt, Mic, Speaker, .{
    .speaker_buffer_depth = 5,  // 方式 1 fallback
});
```

### 进度

**Phase 1: Engine 重构** — DONE
1. [x] `EngineConfig` 加 `RefReader: ?type` 和 `speaker_buffer_depth: u32`
2. [x] Engine 内部根据 `RefReader != null` 走不同路径（comptime if）
3. [x] 方式 1: `getAlignedRef()` 从 ref_history ring 取 delay 帧前的 ref
4. [x] 方式 2: `getAlignedRef()` 调 `ref_reader.read()` 获取对齐 ref
5. [x] 软件回环测试不回归（135/136 pass，E2E-4 pre-existing flaky）

**Phase 2: PortAudio DuplexStream 实现** — DONE
6. [x] `DuplexAudio` — `lib/platform/std/src/impl/audio_engine.zig`
   - DuplexStream callback → 3 个 ring buffer（mic/spk/ref）
   - `DuplexAudio.Mic` / `DuplexAudio.Speaker` / `DuplexAudio.RefReader` 子类型
7. [x] E1 用方式 2 跑 — 15s，240k clean samples，无 crash
8. [x] E1b 用方式 1（buffer_depth=5）跑 — 15s，240k clean samples，无 crash
9. [x] E2-E5 全部改为 DuplexStream + RefReader

**Phase 3: 实机对比**
10. [ ] 对比 depth=3/5/8 vs DuplexStream ERLE（填入下表）
11. [ ] E3 多轮 + E4 60s + E5 近端验证

**Phase 4: 平台**
12. [ ] ESP32 交叉编译（方式 1 或 2 取决于板子 I2S 能力）
13. [ ] BM1 性能

### ERLE 对比数据（待填）

| 测试 | 方式 | ERLE |
|------|------|------|
| T1 440Hz 10s | A (depth=3) | ? |
| T1 440Hz 10s | A (depth=5) | ? |
| T1 440Hz 10s | A (depth=8) | ? |
| T1 440Hz 10s | B (DuplexStream) | ? |
| T3 TTS | A (最优 depth) | ? |
| T3 TTS | B (DuplexStream) | ? |

**方式 1 和方式 2 都有，方式 2 是默认首选，方式 1 是 fallback。**
