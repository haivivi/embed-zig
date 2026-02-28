# 执行计划：WiFi Scan 接口重构 — 纯事件流模型

## Reviewer 要求修改

### P0: 必须修改
- [x] 修复测试入口函数签名不兼容问题 (Cursor Review)
  - 修复: 每个测试文件新增 `entry(_: anytype) void`，BUILD.bazel 改 `entry_fn = "entry"`
  - 验证: 6 个 ESP 目标全部编译通过 (commit ab047063)

- [x] 删除未使用的 `scanGetApCount` 函数 (Cursor Review)
  - 修复: 删除 C 函数、Zig wrapper、extern 声明、ScanGetCountFailed error、cmake force link
  - 验证: ESP app 编译通过 (commit 48eebb12)

- [ ] 修复 BK `isConnected` 在 yielding 时静默丢弃 scan results 问题 (Cursor Review)
  - 位置: `lib/platform/bk/impl/src/wifi.zig#L111-L123` + `#L85-L91`
  - 问题: BK 驱动的 `isConnected()` 内部调用 `pollEvent()` 并丢弃返回值。在 PR 之后，`pollEvent` 在 scan 期间返回 `scan_result` 数据事件，`isConnected()` 调用会静默消费并丢弃一个 `scan_result` 事件，推进 `scan_cursor` 并永久丢失该 AP 的数据
  - 修复方向: 在 `isConnected()` 中 scan_yielding 时跳过 `pollEvent()` 调用
  - Severity: Medium
  - 状态: ❌ 未解决（已修复但尚未请求 Cursor 重新审查）

- [ ] 等待并确保 PR #85 的 `ESP cross-compile` 检查通过
  - 现状：CI 已触发，等待结果

### P1: 建议修改
- [x] PR 标题审核通过（按仓库规范）
  - 规范：`{mod/submod}: {subject}`，且 `subject` 以小写字母开头
  - 当前标题：`hal/wifi: refactor scan to pure event-stream model`
  - 结论：符合规范，无需改为首字母大写的动词句式

- [ ] 在 PR `Testing` 中补充最终 CI 结果链接（尤其是 ESP cross-compile）
  - 建议：当 pending 变为 pass 后，将结果补充到 PR 描述，便于审计
