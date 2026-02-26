# 执行计划：去 Speex AEC 并落地跨平台 AudioEngine（平台 AEC + 纯 Zig Resampler）

## 概述
按已确认方向推进：
- 平台负责 mic/ref 对齐，engine 不做 delay 策略。
- 不再在本项目继续集成 Speex AEC 方案。
- ESP/BK 分别调用各自平台 AEC+NS。
- 跨平台统一走 AEC3 接口语义。
- `lib/pkg/audio` 保留统一 Engine + Mixer，并实现 pure Zig Stream Resampler（参考 `aec3-zig` 的 `SincResampler/PushSincResampler` 思路）。

## 执行步骤

- [x] 步骤 1：冻结架构边界与接口契约（先文档化再改代码）
  - [x] 1.1 明确三层职责：Platform(I/O+对齐) / Engine(调度+mixer) / Processor(AEC+NS)。
  - [x] 1.2 明确统一处理入口：`process(mic, ref, out)`；engine 不暴露 delay 参数。
  - [x] 1.3 明确 NS 归属：作为处理器内部能力（可选），不在 engine 编排策略里分支化。

- [x] 步骤 2：在 `lib/pkg/audio` 定义统一处理器抽象（去具体算法耦合）
  - [x] 2.1 新增处理器接口模块（如 `processor.zig`），定义 `init/deinit/process/reset` 等最小能力。
  - [x] 2.2 `engine.zig` 改为仅依赖该抽象；移除对具体 Speex AEC 类型的直接引用。
  - [x] 2.3 保证编译期约束清晰（comptime trait check），失败信息可读。

- [x] 步骤 3：实现 pure Zig Stream Resampler（替代 Speex resampler 依赖）
  - [x] 3.1 引入/移植 `SincResampler` 与 `PushSincResampler` 核心实现（来源 `aec3-zig`）。
  - [x] 3.2 在 `resampler.zig` 实现流式语义：`write([]u8)` / `read([]u8)`，支持可变块输入输出。
  - [x] 3.3 支持 mono/stereo 通道处理（必要时按通道拆分后重组），确保与 mixer 现有调用兼容。
  - [x] 3.4 补齐单测：采样率转换、通道转换、跨线程阻塞/唤醒、关闭排空、边界输入。

- [x] 步骤 4：清理 `lib/pkg/audio` 的 Speex 绑定耦合
  - [x] 4.1 从 `audio` package 依赖中移除 Speex 必选依赖（按模块拆分，避免全局绑定）。
  - [x] 4.2 删除或下线 `pkg/audio` 内 Speex AEC 路径引用，防止误接入。
  - [x] 4.3 更新模块导出与文档注释，避免继续宣称默认 Speex AEC。

- [ ] 步骤 5：实现平台处理器适配（ESP）
  - [x] 5.1 封装 ESP 现有 AEC+NS 调用为统一处理器实现（对外只暴露 `process`）。
  - [ ] 5.2 确保 ref 对齐由 ESP 平台侧完成并稳定输出给处理器。
  - [ ] 5.3 board/app 接线切到 Engine + ESPProcessor，不改 engine 核心流程。

- [ ] 步骤 6：实现平台处理器适配（BK）
  - [x] 6.1 封装 BK 现有 AEC+NS 调用为统一处理器实现。
  - [ ] 6.2 明确 BK 的 ref 来源与对齐策略（平台内完成，不上推到 engine）。
  - [ ] 6.3 board/app 接线切到 Engine + BKProcessor。

- [ ] 步骤 7：预留 AEC3 处理器接入位（跨平台统一目标）
  - [ ] 7.1 定义 AEC3 处理器适配约束：外部单入口 `process`，内部可 `render->capture`。
  - [ ] 7.2 与 `aec3-zig` 对齐输入输出帧语义，确保后续可无缝替换平台处理器。

- [ ] 步骤 8：Bazel 验证与回归测试
  - [ ] 8.1 运行 `//lib/pkg/audio:resampler_test`、`:mixer_test`、`:engine_test`。
  - [ ] 8.2 运行 `//e2e/tier2_audio_engine/std:mic_test`、`:loop_back_test`、`:aec_test`。
  - [ ] 8.3 验证 ESP/BK 目标至少可编译通过（可运行目标按硬件条件执行）。
  - [ ] 8.4 对比关键指标：音频连续性、无死锁、无爆音、回声抑制主观可用。

- [ ] 步骤 9：文档与迁移说明
  - [ ] 9.1 更新 `openteam/worklog.md`，记录每步结论、问题与修复。
  - [ ] 9.2 更新开发文档：说明 Speex AEC 已移除、平台处理器与 AEC3 路线。
  - [ ] 9.3 列出后续事项：AEC3 完整替换节奏、性能基准与质量基准补充计划。
