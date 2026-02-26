# 执行计划：去 Speex AEC 并落地跨平台 AudioEngine（平台 AEC + 纯 Zig Resampler）

## 概述
按已确认方向推进：
- 平台负责 mic/ref 对齐，engine 不做 delay 策略。
- 不再在本项目继续集成 Speex AEC 方案。
- ESP/BK 分别调用各自平台 AEC（NS 作为处理器内部可选能力，不在 Engine 编排）。
- 跨平台统一走 AEC3 接口语义。
- `lib/pkg/audio` 保留统一 Engine + Mixer，并实现 pure Zig Stream Resampler（参考 `aec3-zig` 的 `SincResampler/PushSincResampler` 思路）。

## 当前里程碑（已完成）

- 已完成步骤 1~4（契约冻结、Processor 抽象、pure Zig resampler、Speex 路径清理）。
- 已完成步骤 5.1 / 6.1（ESP/BK 平台 AEC Processor 封装）。
- 已完成 5.4 全部子项（5.4.1~5.4.5），含实机可观测指标。
- 已完成 5.5 NS 归属落地校验（engine 不做 NS 编排，NS 仅在 Processor 内部）。
- 下一阶段主线：完成 **ESP ref 对齐验收（5.2）**，再并行推进 BK 接线。

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
  - [x] 5.1 封装 ESP 现有 AEC 调用为统一处理器实现（对外只暴露 `process`，NS 作为后续可选能力）。
  - [ ] 5.2 确保 ref 对齐由 ESP 平台侧完成并稳定输出给处理器。
    - [ ] 5.2.1 明确 ESP ref 采样来源（I2S 回采/软件镜像）与帧边界语义。
    - [ ] 5.2.2 对齐 `readMic` 与 `RefReader.read` 的帧时序，补齐越界/欠采样补零策略。
    - [x] 5.2.3 增加最小诊断日志（帧长、丢帧计数、峰值）用于实机定位。
  - [x] 5.4 以"旧 AudioSystem 仅作参考"为前提，重写 ESP 平台 I/O 适配层（mic/ref/speaker）。
    - [x] 5.4.1 新建/重构 ESP DuplexAudio 组件：
      - `Mic.read` 只提供原始 mic（不做 AEC）；
      - `Speaker.write` 只做播放并记录 ref 来源；
      - `RefReader.read` 只输出对齐后的 ref。
    - [x] 5.4.2 明确 ref 链路与时钟：
      - 统一以 speaker 实际写入样本为 ref 时间基；
      - 建立平台内固定延迟模型（样本级），不把 delay 策略上推到 engine。
    - [x] 5.4.3 实现无损帧桥接（重点）：
      - 平台 chunk（如 256）与 engine step（如 160）不一致时，必须通过残余缓存拼接/切分；
      - 禁止 `min(len)` 截断导致掉样本。
    - [x] 5.4.4 接线切换到"Engine + ESPProcessor"真实路径：
      - e2e 的 mic/speaker/aec 测试统一使用新 DuplexAudio + ESPProcessor；
      - 不再走旧 AudioSystem 内部 AEC 主路径。
    - [x] 5.4.5 增加实机可观测指标：
      - 每秒 mic/ref/spk 样本计数；
      - ref 延迟档位与当前对齐偏移；
      - 丢帧/补零计数。
  - [x] 5.5 NS 归属落地校验（对齐 1.1/1.3 约束）。
    - [x] 5.5.1 确认 engine 不做 NS 分支编排；
    - [x] 5.5.2 确认 NS 仅在 ESPProcessor 内部按配置启用；
    - [x] 5.5.3 在 e2e 日志明确打印"processor 内部 AEC/NS 开关状态"。
  - [x] 5.3 board/app 接线切到 Engine + ESPProcessor，不改 engine 核心流程。
    - [x] 5.3.1 选定 1 个 ESP board/app（实际落地为 `e2e/tier2_audio_engine/esp`）完成接线。
    - [x] 5.3.2 保持原有应用行为不回退（已恢复为"共享测试逻辑 + board 适配 + entry_file 入口选择"，并完成构建验证）。

- [ ] 步骤 6：实现平台处理器适配（BK）
  - [x] 6.1 封装 BK 现有 AEC 调用为统一处理器实现（NS 作为后续可选能力）。
  - [ ] 6.2 明确 BK 的 ref 来源与对齐策略（平台内完成，不上推到 engine）。
    - [ ] 6.2.1 确认 BK `writeSpeaker` → `ref` 缓存与 `readMic` 的固定延迟关系。
    - [ ] 6.2.2 给出 BK 平台内 ref 对齐策略文档（含边界条件与失败回退）。
  - [ ] 6.3 board/app 接线切到 Engine + BKProcessor。
    - [ ] 6.3.1 选定 1 个 BK board/app（优先 `examples/apps/aec_test/bk`）完成接线。
    - [ ] 6.3.2 保证不改 Engine 主循环语义，仅替换平台 Processor 与 ref 提供链路。

- [ ] 步骤 7：预留 AEC3 处理器接入位（跨平台统一目标）
  - [ ] 7.1 定义 AEC3 处理器适配约束：外部单入口 `process`，内部可 `render->capture`。
  - [ ] 7.2 与 `aec3-zig` 对齐输入输出帧语义，确保后续可无缝替换平台处理器。

- [ ] 步骤 8：Bazel 验证与回归测试
  - [ ] 8.1 运行 `//lib/pkg/audio:resampler_test`、`:mixer_test`、`:engine_test`。
  - [ ] 8.2 运行 `//e2e/tier2_audio_engine/std:mic_test`、`:loop_back_test`、`:aec_test`。
  - [ ] 8.3 验证 ESP/BK 目标至少可编译通过（可运行目标按硬件条件执行）。
  - [ ] 8.4 对比关键指标：音频连续性、无死锁、无爆音、回声抑制主观可用。

## 执行顺序（更新）

1. 先完成 ESP 的 5.2（ref 对齐验收）。5.4/5.5 已完成。
2. 再完成 BK 的 6.2/6.3（ref 策略 + 接线）。
3. 然后推进 7（AEC3 接口位）与 8（统一回归）。
4. 最后完成 9（迁移文档与后续节奏）。

- [ ] 步骤 9：文档与迁移说明
  - [ ] 9.1 更新 `openteam/worklog.md`，记录每步结论、问题与修复。
  - [ ] 9.2 更新开发文档：说明 Speex AEC 已移除、平台处理器与 AEC3 路线。
  - [ ] 9.3 列出后续事项：AEC3 完整替换节奏、性能基准与质量基准补充计划。
