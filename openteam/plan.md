# 执行计划：WiFi Scan 接口重构 — 纯事件流模型

## Reviewer 要求修改

### P0: 必须修改
- [ ] 修复测试入口函数签名不兼容问题 (Cursor Review) ✅ 已解决
  - 位置: `e2e/tier1_wifi_scan/normal_scan.zig#L20-L21` (及其他 4 个测试文件)
  - 问题: 5 个测试文件的 `run` 函数签名是 `pub fn run(b: *Board) TestResult`，但生成的 main 调用 `app.{entry_fn}(env_module.env)` 参数是 `Env`，不是 `*Board`，且返回类型被丢弃
  - 影响: 5 个新的 `esp_zig_app` 目标 (`normal_scan_app`, `empty_scan_app` 等) 将无法编译
  - 修复方向: 
    - 方案A: 修改 Bazel 生成的 main.zig，适配 `fn(b: *Board) TestResult` 签名并处理返回值
    - 方案B: 修改测试入口函数签名为 `pub fn run(_: anytype) void`，与现有 `app.zig` 保持一致
  - Severity: High

- [ ] 删除未使用的 `scanGetApCount` 函数 (Cursor Review)
  - 位置: `lib/platform/esp/idf/src/wifi/wifi.zig#L271-L278` + `lib/platform/esp/idf/src/wifi/helper.c#L390-L398`
  - 问题: 新增的 `scanGetApCount` Zig wrapper 和 C 函数 `wifi_helper_scan_get_ap_count` 未被调用，是死代码
  - 修复: 删除这两个函数，并在 `StaDriver.fetchScanResults` 中直接调用 `scanGetApRecords`
  - Severity: Low
  - 状态: ❌ 未解决

- [ ] 等待并确保 PR #85 的 `ESP cross-compile` 检查通过
  - 现状：`gh pr checks 85` 显示该检查为 `pending`
  - 要求：提供最终通过状态（或对应失败修复后再次通过），作为 AC7 编译通过证据

### P1: 建议修改
- [ ] 在 PR `Testing` 中补充最终 CI 结果链接（尤其是 ESP cross-compile）
  - 建议：当 pending 变为 pass 后，将结果补充到 PR 描述，便于审计
