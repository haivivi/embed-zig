# Review 标准：lib/pkg/audio — 跨平台软件音频引擎（Ref 对齐重构）

## 审查依据
- Design Proposal: `openteam/design_proposal.md`
- Task: `openteam/task.md`
- Plan: `openteam/plan.md`
- Test: `openteam/test.md`（当前仓库中未找到该文件，后续审查阶段将把“测试标准缺失”作为阻断项）

## 审查范围
- Engine 配置与对齐策略：`lib/pkg/audio`（重点 `engine.zig` 与相关配置/trait）
- 平台实现：`lib/platform/std`（Separate Streams + DuplexStream + RefReader）
- 平台接线：`e2e/tier2_audio_engine/std`、`e2e/tier2_audio_engine/esp`、BK 对应 board/app 路径
- 构建与依赖声明：相关 `BUILD.bazel`、`MODULE.bazel`、三方依赖引用
- 文档与流程合规：PR 标题/描述、提交内容洁净度

## 检查清单

### A. 功能验收（与 task/design/plan 对齐，按“RefReader 必选”新约束）

- [ ] A1. EngineConfig 强制要求 RefReader（非可选）
  - 检查方法：静态检查 `EngineConfig` 与 `AudioEngine(...)` 泛型约束，确认 `RefReader` 不是 `?type` 可空输入；缺失时编译期报错信息清晰。
  - 通过标准：RefReader 为必填契约，调用方无法绕过。
  - 不通过标准：仍支持 `null`/缺省 RefReader，或通过运行时分支兜底。

- [ ] A2. Engine 只消费平台提供的对齐 ref，不再内建延迟猜测
  - 检查方法：检查 mic 处理路径是否统一调用 `RefReader.read()`（或等价接口）拿对齐 ref；检查 engine 内不存在 speaker depth/ring delay 对齐逻辑。
  - 通过标准：Engine 完全去除 ref 对齐策略，职责只剩调度与调用。
  - 不通过标准：Engine 仍保留 `speaker_buffer_depth`、ref_history 或任意 delay 补偿逻辑。

- [ ] A3. 平台层必须实现 RefReader（没有硬件回环也不能缺）
  - 检查方法：逐平台检查（std/esp/bk）是否都提供可实例化的 RefReader 实现；对“不支持硬件回环”的平台检查其替代实现（软件镜像/固定延迟桥接等）。
  - 通过标准：每个平台都有可工作的 RefReader；不存在“该平台先不实现 RefReader”的借口代码。
  - 不通过标准：任一平台缺 RefReader，或仅有 stub/假数据实现。

- [ ] A4. PortAudio 路径在新约束下可运行
  - 检查方法：检查 `lib/platform/std` 是否通过 RefReader 打通链路（Duplex 对齐优先；Separate Streams 若保留，必须配套 RefReader 实现）。
  - 通过标准：无论选哪条 std 平台实现，Engine 入口都满足“RefReader 必选”。
  - 不通过标准：存在不带 RefReader 的 std 入口。

- [ ] A5. 与设计目标一致：Engine 单循环语义不被破坏
  - 检查方法：检查处理顺序与职责边界（Platform 对齐、Engine 调度、Processor 处理）是否保持一致，不把平台细节塞回 Engine。
  - 通过标准：模块边界清晰，Engine 不承担平台时钟/硬件细节。
  - 不通过标准：Engine 混入平台专有逻辑导致跨平台退化。

- [ ] A6. ESP 与 BK 必须全部接入新 AudioEngine
  - 检查方法：检查 ESP/BK 的 e2e 与 board/app 接线路径，确认调用链走 `audio.engine.AudioEngine(...)` + `Processor` + `RefReader`，而非旧聚合音频系统。
  - 通过标准：ESP 与 BK 的目标入口都走新 Engine（至少各有明确可构建/可运行目标），不存在仅一端迁移。
  - 不通过标准：任一平台仍停留在旧路径或仅局部迁移。

- [ ] A7. 代码库中不得保留旧 AudioSystem 主路径
  - 检查方法：全仓搜索 `AudioSystem` / `audio_system`，区分“历史注释”与“实际可达代码路径”。
  - 通过标准：旧 `AudioSystem` 模块与导出、board re-export、app 直接依赖已移除或下线，不再作为生产路径可用。
  - 不通过标准：仍存在可编译/可调用的旧 AudioSystem 实现或入口。

### B. 计划项对应验收（plan.md 未完成项重点）

- [ ] B1. 5.2 ESP ref 对齐验收有可追溯实现
  - 检查方法：检查 ESP DuplexAudio/ref 链路与帧边界处理代码，确认与 5.2.1/5.2.2 描述一致。
  - 通过标准：ref 来源、对齐策略、补零/回退策略代码可定位且可读。
  - 不通过标准：仅文档宣称完成，无代码证据。

- [ ] B2. 6.2 BK ref 对齐策略有明确实现/文档落点
  - 检查方法：检查 BK 侧 `writeSpeaker -> ref` 与 `readMic` 固定延迟关系实现及说明。
  - 通过标准：策略明确、边界条件可验证。
  - 不通过标准：策略空缺或“先这样跑着看”。

- [ ] B3. 6.3 BK board/app 接线不改 Engine 主循环语义
  - 检查方法：检查接线改动是否仅替换 Processor/ref 提供链路，无改写 Engine 核心流程。
  - 通过标准：替换点局部、语义稳定。
  - 不通过标准：为适配 BK 侵入式改 Engine。

### C. 代码质量与硬约束

- [ ] C1. 无 TODO 占位、无假实现
  - 检查方法：搜索 `TODO`、`unreachable`、固定返回假数据路径、空函数体。
  - 通过标准：对外暴露接口均端到端实现。
  - 不通过标准：注册了接口但未实现。

- [ ] C2. Zig 规范与错误处理质量
  - 检查方法：检查 public API 的 error union、`errdefer`/清理路径、命名和文件头注释。
  - 通过标准：不泄露 `anyerror`，错误语义明确，代码风格一致。
  - 不通过标准：错误吞噬、panic 代替错误返回、风格混乱。

- [ ] C3. 并发/缓冲安全
  - 检查方法：检查 ring buffer 索引更新、内存可见性和边界；关注丢帧计数与补零逻辑是否自洽。
  - 通过标准：无明显数据竞争和越界风险。
  - 不通过标准：读写竞态、未同步访问、潜在越界。

- [ ] C4. 硬规则合规
  - 检查方法：全量检查是否违反仓库硬规则。
  - 通过标准：
    - 不使用 `Atomic(i128)` / `Atomic(u128)`；
    - 不引入 `sh_binary` / `sh_test`；
    - PortAudio 不使用 callback 模式替代阻塞 I/O（除 task 已明确要求的 Duplex 对齐路径场景，需有充分说明并保持架构一致性）。
  - 不通过标准：任一硬规则违规即失败。

### D. 测试与证据完整性（静态审查角度）

- [ ] D1. test.md 一致性
  - 检查方法：核对 `openteam/test.md` 的测试项与代码/日志证据。
  - 通过标准：测试标准文件存在，且每项有对应实现/执行证据。
  - 不通过标准：`test.md` 缺失或测试项无法映射到改动。

- [ ] D2. ERLE 对比数据链路可追溯
  - 检查方法：检查是否有 A(depth=3/5/8) 与 B(Duplex) 的结果记录位置与采集代码路径。
  - 通过标准：数据表有明确填充来源（日志/脚本/输出文件路径）。
  - 不通过标准：只写“预期更好”没有数据来源。

### E. 提交洁净度与 PR 质量

- [ ] E1. 不应提交文件检查
  - 检查方法：基于 `git diff --name-only` 逐项排查：二进制、编译产物、缓存、敏感信息、IDE 垃圾文件、worklog/log。
  - 通过标准：无违规文件。
  - 不通过标准：出现任一违规项，必须移除并重审。

- [ ] E2. PR 标题与描述规范（英文）
  - 检查方法：检查 PR title/body。
  - 通过标准：
    - 标题英文、动词开头、简洁说明目的；
    - 描述英文，包含 `Summary`（1-3 条价值点）与 `Testing`（命令/结果或未执行原因）。
  - 不通过标准：中文标题/描述、缺少必填段落、Testing 含糊。

## 审查判定规则
- **Pass**：A/B/C/D/E 全部通过；无 P0 问题。
- **Needs Fixes**：存在任一不通过项但可修复（将写入 `plan.md` 的“Reviewer 要求修改”）。
- **Reject**：出现架构违背、硬规则违规、明显伪实现、或提交污染严重。

## 审查结果（待执行）
- 总体状态：Needs Fixes
- 发现问题数：8
- 最后审查时间：2026-02-27

## 本轮审查结论（2026-02-27）

### 结论摘要
- 本轮代码未通过。核心阻断问题是 **Engine 仍保留“RefReader 可选 + buffer_depth fallback”旧架构**，与最新设计“RefReader 必选、平台必须实现”直接冲突。
- 另有提交洁净度风险（工作区存在多份 `openteam/*.mp3` 二进制文件），必须禁止进入 PR。

### 逐项检查（关键项）
- ❌ A1（RefReader 必选）：失败
  - 证据：`lib/pkg/audio/src/engine.zig:58` 仍为 `RefReader: ?type = null`。

- ❌ A2（Engine 不再做 delay 策略）：失败
  - 证据：`lib/pkg/audio/src/engine.zig:55` 仍有 `speaker_buffer_depth`；
  - 证据：`lib/pkg/audio/src/engine.zig:93, 103-107, 330-346` 仍存在 ref ring + depth 对齐逻辑。

- ❌ A3（每个平台必须提供 RefReader）：失败（从引擎契约层面可绕过）
  - 证据：`lib/pkg/audio/src/engine.zig:89-90,125` 通过 `HasRefReader` 分支允许“无 RefReader”实例化。

- ❌ A6（ESP/BK 全量接入新 Engine）：失败
  - 证据：BK 侧仍直接导出旧路径 `AudioSystem`：`lib/platform/bk/src/boards/bk7258.zig:257`。
  - 证据：示例 app 仍引用旧接口：`examples/apps/aec_test/bk/bk7258.zig:24`。

- ❌ A7（移除旧 AudioSystem 主路径）：失败
  - 证据：`lib/platform/esp/impl/src/audio_system.zig`、`lib/platform/bk/impl/src/audio_system.zig` 仍存在完整实现；
  - 证据：ESP/BK board 层仍有 `AudioSystem` re-export（如 `lib/platform/esp/src/boards/lichuang_gocool.zig:287-291`、`lib/platform/bk/src/boards/bk7258.zig:257`）。

- ⚠️ D1（test.md 一致性）：失败
  - 证据：`openteam/test.md` 文件缺失，无法做测试标准映射审查。

- ❌ E1（不应提交文件）：存在高风险
  - 证据：工作区出现多个 `openteam/t2a_*.mp3` 二进制文件（`git status --short` 可见）。
  - 说明：若这些文件进入 PR，必须驳回并要求移除。

- ❌ Engine 逻辑缺陷（静态审查）：失败
  - 问题 1：`start()` 第二线程创建失败时没有回滚第一线程与 `running` 状态，可能泄漏后台线程并导致状态错乱。
  - 证据：`lib/pkg/audio/src/engine.zig:208-210`。
  - 问题 2：buffer_depth 路径在“历史不足”时返回 slot0，而非静音，早期帧会错误使用未对齐 ref。
  - 证据：`lib/pkg/audio/src/engine.zig:339-346`。

### 通过项（本轮可确认）
- ✅ 本次改动中未发现 `Atomic(i128/u128)` 违规。
- ✅ 本次改动中未发现新增 `sh_binary/sh_test`。

### 备注
- PR 标题/描述规范（英文 `Summary` + `Testing`）本轮无法静态核验：当前未提供 PR 链接与正文。提交 PR 时将作为必检项。
