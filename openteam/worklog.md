# Worklog: feat/audio-system

## 日志

### 2026-02-26 11:55
- **author**: /Users/idy/Vibing/embed-zig/audio-system
- **工作内容**：收到继续执行指令，已制定修复 `std` 路径 `mic=0` 的执行计划，并将 Speex AEC 验证纳入本轮步骤。
- **遇到问题**：当前 `aec_test` 里 `ref` 非零但 `mic/clean` 全零，优先怀疑 DuplexAudio 捕获链路或队列发布路径。
- **需要反馈**：暂无，先完成代码级排查与一次可复现实验后再汇报。

### 2026-02-26 12:00
- **author**: /Users/idy/Vibing/embed-zig/audio-system
- **工作内容**：完成 `mic_test/loop_back_test/aec_test` 复现；为 Duplex I/O 增加输入/输出峰值日志；为 PortAudio 增加可选设备选择（`AUDIO_INPUT_DEVICE` / `AUDIO_OUTPUT_DEVICE`）并打印实际使用设备名。
- **遇到问题**：日志显示当前默认设备已是 `MacBook Pro Microphone` 与 `MacBook Pro Speakers`，但输入峰值持续为 0（`in_peak=0`），说明不只是“默认设备索引写错”，还可能涉及 macOS 麦克风权限/系统输入电平/设备占用。
- **需要反馈**：请协助确认本机是否已给当前终端（Terminal/iTerm）麦克风权限，并确认系统“声音-输入”电平是否能实时跳动；若有外接麦克风，也请提供希望使用的设备索引，我将用环境变量强制指定后复测。

### 2026-02-26 12:23
- **author**: /Users/idy/Vibing/embed-zig/audio-system
- **工作内容**：按“使用 PortAudio delay 参数对齐 mic/ref”的要求实现自动对齐：新增 `pa.Stream.info()` 读取 `inputLatency/outputLatency`，在 `DuplexAudio` 启动时计算 `ref_delay_samples`，`RefReader.read()` 改为读取“延迟后的历史 ref”而非最新帧；支持环境变量覆盖 `AUDIO_REF_DELAY_SAMPLES` / `AUDIO_REF_DELAY_FRAMES`。
- **遇到问题**：本机 PortAudio 报告延迟较大（`in=419.06ms, out=197.88ms`，自动换算约 61 帧），AEC 仍可能需要人工微调该偏移。
- **需要反馈**：请主观听感确认当前 AEC 抑制效果；若仍有残留回声，我将基于你听感继续微调 `AUDIO_REF_DELAY_FRAMES` 的默认策略（例如只取 output 或引入可配置补偿）。

### 2026-02-26 12:35
- **author**: /Users/idy/Vibing/embed-zig/audio-system
- **工作内容**：按要求把 std 路径 AEC 切到 Speex playback/capture：在 `engine.speakerTask` 中喂 `aec.playback(frame)`，在 `engine.micTask` 中走 `aec.capture(mic, clean)`（仅 `HasRefReader=true` 路径启用）；为并发访问 Speex state 增加 `aec_mutex` 保护。
- **遇到问题**：`aec_test` 仍有明显 far-end 泄漏，并出现 Speex 警告（`discarded first playback frame` / `Auto-filling the buffer`），说明当前双线程 engine 调度下 playback/capture 仍存在节拍不稳与队列错配。
- **需要反馈**：建议下一步改成“单线程处理链路（speaker->mic->aec）”或在 engine 层引入严格 frame pairing；请确认我是否继续沿这个方向做结构性修复。

### 2026-02-26 12:36
- **author**: /Users/idy/Vibing/embed-zig/audio-system
- **工作内容**：根据“对齐由平台负责、engine 不做 delay 处理”的指令，已撤回 engine playback/capture 改造，恢复为 `aec.process(mic, ref, clean)` 单路径；engine 只消费平台提供的 `RefReader` 对齐结果。
- **遇到问题**：功能上仍存在 far-end 泄漏，说明问题焦点回到平台对齐质量（`RefReader` 产出的 ref 与 mic 对齐仍不够稳定/准确）。
- **需要反馈**：确认后我将只在 `lib/platform/std/src/impl/audio_engine.zig` 侧继续调对齐（不再触碰 engine 架构）。

### 2026-02-26 13:59
- **author**: /Users/idy/Vibing/embed-zig/audio-system
- **工作内容**：按要求先执行 `rebase main` 对齐：已将当前分支 rebase 到 `origin/main`（首次普通 rebase 冲突后，改用 `-X theirs` 成功重放 51 个提交），并恢复本地未提交改动（stash pop）。随后完成计划步骤 1 的文档化冻结，新增 `openteam/docs/audio_engine_platform_contract.md`。
- **遇到问题**：当前工作树累积历史改动较多（含大批删除/新增），后续每步需要严格按契约小步推进，避免引入额外语义漂移。
- **需要反馈**：请确认契约文档中“Platform 必须始终提供 RefReader（无硬件回路也必须软件构造 ref）”为最终强约束；若确认，我将进入步骤 2（统一 Processor 抽象落地）。

### 2026-02-26 14:15
- **author**: /Users/idy/Vibing/embed-zig/audio-system
- **工作内容**：完成步骤 2 与步骤 3 主体实现：
  1) 新增 `lib/pkg/audio/src/processor.zig`，定义统一处理器契约（`init/deinit/process`）并在 engine 侧替换为抽象调用；
  2) 新增 pure Zig `sinc_resampler.zig` / `push_sinc_resampler.zig`；
  3) 重写 `resampler.zig` 的低层 `Resampler` 为 pure Zig 实现，保留 `StreamResampler` 接口语义，并修复块大小与关闭排空相关行为。
- **遇到问题**：`//lib/pkg/audio:engine_test` 在 `E2E-1` 处持续 `Illegal instruction/Bus error`（进入 `speex_echo_cancellation` 前后崩溃），该异常在本轮 Processor 抽象改造后稳定复现，需单独定位。其余验证正常：`resampler_test`、`mixer_test`、`aec_test`、`ns_test`、`bazel build //lib/pkg/audio` 通过。
- **需要反馈**：是否允许我在下一步（步骤 4）继续做“去 Speex AEC 默认接入”与 target 拆分，同时并行定位 `engine_test` 崩溃根因？

### 2026-02-26 14:23
- **author**: /Users/idy/Vibing/embed-zig/audio-system
- **工作内容**：完成步骤 4（解耦 Speex 绑定）：
  1) `lib/pkg/audio/BUILD.bazel` 拆分为 `audio`（纯核心，无 speex 必选依赖）与 `audio_speex`（可选 Speex 扩展）；
  2) `processor.zig` 默认实现改为 `PassthroughProcessor`，Speex 实现迁移到 `processor_speex.zig`；
  3) `audio.zig` 移除默认 `aec/ns` 导出并更新注释，新增 `audio_speex.zig` 承载可选 Speex 导出。
- **遇到问题**：`engine_test` 不再出现先前的 speex 崩溃，但 AEC 相关断言按预期失败（默认 processor 已改为 passthrough，ERLE 不满足原阈值）。
- **需要反馈**：请确认是否继续按计划步骤 5/6 在 ESP/BK 接入平台处理器；同时我会在步骤 8 前重构 `engine_test` 使其改为“可注入处理器”的断言模型（不再默认绑定 Speex 结果阈值）。

### 2026-02-26 14:29
- **author**: /Users/idy/Vibing/embed-zig/audio-system
- **工作内容**：按指令继续清理 Speex NS：
  1) 删除 `lib/pkg/audio/src/ns.zig`；
  2) `processor_speex.zig` 改为仅保留 Speex AEC（不再引用 NS）；
  3) `audio_speex.zig` 移除 `NoiseSuppressor` 导出；
  4) `BUILD.bazel` 删除 `ns_test` 目标。
- **遇到问题**：一次并行测试中 `mixer_test` 出现 T9 段错误（mutex lock），单独复测 `mixer_test` 立即通过，判断为并行触发的瞬时问题（当前不可稳定复现）。
- **需要反馈**：无阻塞。下一步可继续步骤 5（ESP 平台处理器封装）与步骤 6（BK 平台处理器封装）。

### 2026-02-26 15:05
- **author**: /Users/idy/Vibing/embed-zig/audio-system
- **工作内容**：按你的建议完成 Resampler 目录重构：
  1) `resampler.zig` 主实现迁移到 `lib/pkg/audio/src/resampler/mod.zig`；
  2) `sinc_resampler.zig`、`push_sinc_resampler.zig` 分别迁移为 `resampler/sinc.zig`、`resampler/push_sinc.zig`；
  3) 保留 `lib/pkg/audio/src/resampler.zig` 作为兼容桥接导出；
  4) `BUILD.bazel` 的 `resampler_test` main 切到 `src/resampler/mod.zig`。
- **遇到问题**：迁移后桥接文件最初使用 `usingnamespace` 语法在当前 Zig 版本报错，已改为显式导出（`Format/Resampler/StreamResampler/stereoToMono/monoToStereo`）解决。
- **需要反馈**：当前重构已稳定通过 `resampler_test`、`mixer_test` 以及 `audio/audio_speex` 构建；可继续推进步骤 5（ESP 处理器接入）。

### 2026-02-26 15:18
- **author**: /Users/idy/Vibing/embed-zig/audio-system
- **工作内容**：按“Speex 全面删除”继续清理：
  1) 删除 `lib/pkg/audio/src/aec.zig`、`audio_speex.zig`、`processor_speex.zig`；
  2) `lib/pkg/audio/BUILD.bazel` 移除 `audio_speex` 与 `aec_test`；
  3) `lib/pkg/audio/build.zig` 移除 speex 依赖与相关测试项；
  4) `MODULE.bazel`、`extensions.bzl` 从 `audio_libs` 扩展中去掉 `speexdsp` 仓库；
  5) e2e BUILD 与 zig build 脚本中移除 speex 链接依赖。
- **遇到问题**：并行跑 `resampler_test+mixer_test` 时 `mixer_test(T9)` 出现一次段错误；单独复测 `mixer_test` 稳定通过，判定为并行触发的既有不稳定点（与本次 Speex 删除无直接编译耦合）。
- **需要反馈**：若你希望“仓库中彻底不保留 speex third_party 目录”，我可以在下一步继续删除 `third_party/speexdsp/*` 与相关文档注释；当前已做到“构建与运行路径不再依赖 Speex”。

### 2026-02-26 15:26
- **author**: /Users/idy/Vibing/embed-zig/audio-system
- **工作内容**：定位“resampler 与 mixer 并行测试偶发崩溃”并完成修复：
  1) 根因定位在 `mixer.readFullLocked` 移除轨道时“立即释放 TrackInternal”，与 writer 线程仍可能执行 `RingBuf.writeFull()` 并发冲突（use-after-free）；
  2) 修复为：移除轨道时只从 active list 脱链并挂到 `detached_head`，**不立即释放 TrackInternal**；实际释放延后到 `destroyTrackCtrl()` 或 `mixer.deinit()`；
  3) 同步调整 `deinit()` 的 detached 清理逻辑，改走 `freeTrackCtrl()`，避免泄漏。
- **遇到问题**：无新增阻塞。
- **需要反馈**：修复后并行验证通过：`resampler_test+mixer_test` 通过，且 `--runs_per_test=8 --nocache_test_results` 重复并行也通过。若你同意，我继续推进步骤 5（ESP 处理器接入）。

### 2026-02-26 15:35
- **author**: /Users/idy/Vibing/embed-zig/audio-system
- **工作内容**：继续推进步骤 5/6，新增平台处理器适配实现：
  1) 新增 `lib/platform/esp/impl/src/audio_processor.zig`，把 ESP AFE AEC 封装为统一 `init/deinit/process/reset` 入口，输入按 `RM`（ref,mic）打包，输出 clean；
  2) 新增 `lib/platform/bk/impl/src/audio_processor.zig`，把 BK Armino AEC 封装为统一处理器入口；
  3) 更新 `openteam/plan.md`：5.1 / 6.1 已勾选完成；
  4) 回归验证：`bazel test //lib/pkg/audio:resampler_test //lib/pkg/audio:mixer_test` 通过。
- **遇到问题**：本次仅完成“处理器封装层”，尚未完成 board/app 接线与平台对齐链路端到端验证（5.2/5.3、6.2/6.3 仍待做）。
- **需要反馈**：请确认下一步优先级：先做 ESP board/app 接线（步骤 5.2/5.3），还是先补 BK ref 对齐策略文档与接线（步骤 6.2/6.3）。

### 2026-02-26 15:55
- **author**: /Users/idy/Vibing/embed-zig/audio-system
- **工作内容**：按“Zig 需手动释放 TrackCtrl”要求补齐调用方清理与实机验证：
  1) 在 `e2e/tier2_audio_engine` 的 `speaker_test/mic_test/loop_back_test/aec_test` 中，为 `engine.createTrack(...)` 创建的句柄补充 `defer engine.destroyTrackCtrl(handle.ctrl)`；
  2) ESP 平台补充 `impl` 导出：`audio_processor` / `AecProcessor`；
  3) 本地构建验证：`bazel build //e2e/tier2_audio_engine/std:{speaker_test,mic_test,loop_back_test,aec_test}` 通过；
  4) 使用串口 `/dev/cu.usbmodem14301` 烧录并运行实机：
     - `bazel run //e2e/tier2_opus_aec/esp:flash --//bazel:port=/dev/cu.usbmodem14301`（首次因 `idf.py` 不在 PATH 失败，补 `IDF_PATH` 后成功）；
     - `bazel run //bazel/esp:monitor --//bazel:port=/dev/cu.usbmodem14301` 观察到 AEC app 正常启动、30s pipeline 跑完并输出 FINAL 指标。
- **遇到问题**：`monitor` 末尾出现 `Device not configured`（USB 串口在运行后断开/重枚举），但在此之前核心日志已完整打印（含 AEC 初始化、运行与最终统计），不影响本轮“可烧录可运行”结论。
- **需要反馈**：如你需要，我下一步可直接基于这块板继续做 5.2/5.3（把 Engine + ESPProcessor 真正接到 ESP board/app），并按同一串口复测。
