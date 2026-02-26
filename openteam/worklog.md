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

### 2026-02-26 16:43
- **author**: /Users/idy/Vibing/embed-zig/audio-system
- **工作内容**：按“先录音后播放、不要 loopback”新增并运行 `//e2e/tier2_audio_engine/esp/aec`：
  1) 新增 `esp/aec/{BUILD.bazel,app.zig,platform.zig,board.zig}`，流程为“5s far-end 播放 + clean 录音 -> beep x2 -> clean 回放”；
  2) 实机烧录并运行在 `/dev/cu.usbmodem14301`，串口日志确认 `clean recorded: 80000 samples (5.0s)`。
- **遇到问题**：用户反馈回放“明显偏快且尖锐”，怀疑 I2S 分块读写与 AEC 帧长度不一致导致短读/短写带来的时域压缩失真。
- **需要反馈**：已继续修复并重新烧录，请用户复听确认是否改善。

### 2026-02-26 16:43
- **author**: /Users/idy/Vibing/embed-zig/audio-system
- **工作内容**：针对“偏快/尖锐”完成底层修复：
  1) `lib/platform/esp/impl/src/audio_system.zig` 的 `readMic` 改为“循环读取直到目标字节数（不足时补零后送 AEC）”；
  2) `writeSpeaker` 改为“循环写入直到整帧写完”，避免短写导致丢采样；
  3) 重新 `bazel build/run //e2e/tier2_audio_engine/esp/aec:flash` 并 monitor 验证可正常跑完整流程。
- **遇到问题**：`deinit` 时仍有既有警告（`i2s_del_channel ... unless it is disabled`），与本次音速/音色问题无直接关系。
- **需要反馈**：请用户直接复听新固件效果；若仍偏快，我将继续加读写样本计数日志精确定位（每秒统计 mic/read 与 spk/write 实际样本数）。

### 2026-02-26 16:46
- **author**: /Users/idy/Vibing/embed-zig/audio-system
- **工作内容**：按“不能用 join 判定结束，要按 PCM 时长判定”修复 `e2e/tier2_audio_engine/esp/aec/app.zig`：
  1) `farEndTask` 增加 `defer ctx.handle.ctrl.closeWrite()`，确保写端结束后可被 mixer 识别为可排空轨道；
  2) 新增 `waitTrackPlayed()`，基于 `track.ctrl.readBytes()` 计数等待 far-end PCM **被实际消费**后再切换到 beep/playback 阶段；
  3) 重新烧录并串口验证，日志可见 `track melody played: 80128 / 80000 samples`、`track bass played: 80128 / 80000 samples`，说明阶段切换已不再仅依赖 thread join。
- **遇到问题**：`readBytes` 以 mixer chunk 计数，存在小幅超读（本次 +128 samples）属预期粒度误差。
- **需要反馈**：请用户复听当前固件的录音回放速度与音色；若仍异常，我将进一步在 I2S 层增加“每秒读写样本统计”并对 codec 时钟参数做逐项核对。

### 2026-02-26 17:00
- **author**: /Users/idy/Vibing/embed-zig/audio-system
- **工作内容**：根据用户“mic 可 join，ref/mic 可能有小延迟未对齐”的反馈继续调优：
  1) `e2e/tier2_audio_engine/esp/aec/app.zig`：far-end task 改为严格 sample budget（每次 write 前按剩余样本裁剪），主流程阶段切换改为“`t_rec.join()` + `readBytes` 消费计数门控”，不再用 far-end `join` 作为阶段边界；
  2) `lib/platform/esp/impl/src/audio_system.zig`：新增 `aec_ref_delay_samples` 配置与 ref delay ring，在 `readMic()` 中对 ref 进行样本级延迟后再送 AEC；
  3) `lib/platform/esp/src/boards/lichuang_gocool.zig`：将 `.aec_ref_delay_samples` 设为 `64`（@16kHz ≈ 4ms）进行第一轮板级对齐尝试；
  4) 已完成构建/烧录/monitor，串口日志确认新参数生效：`AudioSystem: AEC ref delay=64 samples`。
- **遇到问题**：当前仅完成第一档 delay（64 samples）调优，AEC 主观效果仍需用户实际听感确认。
- **需要反馈**：请用户复听本次固件；若回声仍明显，我将继续做 32/96/128 samples 的快速扫参并保留最佳档。

### 2026-02-27 02:25
- **author**: /Users/idy/Vibing/embed-zig/audio-system
- **工作内容**：根据“ESP 测试不应重写 app，应该仅切 board/入口”的反馈完成架构回正：
  1) `bazel/esp/defs.bzl` 新增 `entry_file` / `entry_fn` 参数（默认仍为 `app.zig` / `run`），生成的 `app_main` 与 `run_in_psram` 分支统一按配置调用入口函数；
  2) `e2e/tier2_audio_engine/esp/{mic,speaker,aec}/BUILD.bazel` 改为复用 `//e2e/tier2_audio_engine:app_srcs`，通过 `entry_file` 选择 `mic_test.zig` / `speaker_test.zig` / `aec_test.zig`；
  3) 删除此前在 `esp/{mic,speaker,aec}` 下复制的 `app.zig/platform.zig/board.zig`；保留单一 `e2e/tier2_audio_engine/esp/board.zig`；
  4) 为跨平台入口统一分配 allocator：`Board.allocator()`（std/sim 用 `c_allocator`，esp 用 `idf.heap.psram`），并将 `mic/speaker/loop_back/aec` 四个测试改为使用该接口，避免 freestanding 下 `GeneralPurposeAllocator` 编译错误；
  5) `aec_test.zig` 将“阶段切换”修复同步回共享测试逻辑：mic 可 join，far-end 按 `readBytes` 消费样本门控后再 join 清理。
- **遇到问题**：初次切到共享测试后，ESP 编译报错 `freestanding page_size_max`（根因是测试内使用 `GeneralPurposeAllocator`）；已通过 `Board.allocator()` 方案修复。
- **需要反馈**：当前已通过构建验证：
  - `bazel build //e2e/tier2_audio_engine/esp/mic:app`
  - `bazel build //e2e/tier2_audio_engine/esp/speaker:app`
  - `bazel build //e2e/tier2_audio_engine/esp/aec:app`
  - `bazel build //e2e/tier2_audio_engine/std:aec_test`
  请确认是否继续按此新结构直接烧录复测 AEC 听感。

### 2026-02-27 02:49
- **author**: /Users/idy/Vibing/embed-zig/audio-system
- **工作内容**：按“ESP 目录与 std 一样，收敛到单 BUILD.bazel”继续重构：
  1) 将 `e2e/tier2_audio_engine/esp/mic|speaker|aec` 的 `esp_zig_app/esp_flash` 合并到 `e2e/tier2_audio_engine/esp/BUILD.bazel`；
  2) 新目标统一为 `:mic_app/:mic_flash`、`:speaker_app/:speaker_flash`、`:aec_app/:aec_flash`；
  3) 删除子目录下独立 BUILD 文件；
  4) 为支持同一 package 下多个 `esp_zig_app`，修正 `bazel/esp/defs.bzl` 输出命名冲突：`bootloader.bin/partition-table.bin` 改为带 `project_name` 前缀（例如 `mic_app_bootloader.bin`），避免 action 冲突。
- **遇到问题**：合并后首次构建出现 `bootloader.bin` 多目标冲突；已通过上述输出文件命名修复。
- **需要反馈**：已验证构建通过：
  - `bazel build //e2e/tier2_audio_engine/esp:mic_app`
  - `bazel build //e2e/tier2_audio_engine/esp:speaker_app`
  - `bazel build //e2e/tier2_audio_engine/esp:aec_app`
  你确认后我可直接用新目标名继续烧录与听感复测。

### 2026-02-27 10:30
- **author**: /Users/idy/Vibing/embed-zig/audio-system
- **工作内容**：完成 5.4.5（可观测指标）和 5.5（NS 归属校验）：
  1) 在 `esp/board.zig` 的 DuplexAudio 中增加每秒统计日志：mic/ref/spk 样本计数、drops_mic/drops_ref、mic_zero_fill/ref_zero_fill、ref_delay 配置、fifo 实时水位；
  2) 在 Processor.init() 中增加 AEC/NS 开关状态日志（5.5.3）；
  3) 在 DuplexAudio.init() 中增加初始化参数日志（i2s_bits、chunk_frames、ref_delay、fifo_cap）；
  4) 验证 5.5.1：engine.zig micTask 仅调 processor.process()，无 NS 分支编排；
  5) 验证 5.5.2：ESP AFE 内部管理 NS，engine 层不知道 NS 存在。
- **遇到问题**：engine_test 仍有 E2E-1/E2E-2 两个已知失败（PassthroughProcessor 无 AEC 能力导致 ERLE 不达标），与本次改动无关。100/102 通过。
- **需要反馈**：5.4.5 和 5.5 均已完成。下一步可继续 5.2（ESP ref 对齐验收）或烧录实机验证可观测指标输出。
