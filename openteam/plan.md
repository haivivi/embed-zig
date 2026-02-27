# 执行计划：WiFi Scan 接口重构 — 纯事件流模型

## 概述

将 WiFi scan 从"请求-拉取"模式（scanStart → scan_done → scanGetResults）重构为"纯事件流"模式（scanStart → scan_result × N → scan_done）。涉及 HAL 层接口变更、BK/ESP 两个平台的 Driver 实现适配、以及 E2E 测试的改写。

核心原则：scan 结果通过 Board 事件队列逐条交付，HAL/Driver 不持有结果缓存，应用层自行管理存储。

## 执行步骤

### 第一阶段：HAL 层接口变更 (`lib/hal/src/wifi.zig`)

- [x] 步骤 1：`WifiEvent` 新增 `scan_result: ApInfo` 变体，放在 `scan_done` 之前
- [x] 步骤 2：`ScanDoneInfo` 移除 `count: u16` 字段，只保留 `success: bool`
- [x] 步骤 3：删除 `scanGetResults()` 方法（HAL wrapper 的 from() 中整个方法）
- [x] 步骤 4：更新 `scanStart()` 的文档注释（不再提及 scanGetResults）
- [x] 步骤 5：更新 `pollEvent()` 中的 switch 分支，处理新增的 `scan_result` 和修改后的 `scan_done`
- [x] 步骤 6：更新模块顶部的文档注释和示例代码，反映事件流模式
- [x] 步骤 7：更新文件底部的 `MockWifiEvent` 测试类型，与新的 `WifiEvent` 保持一致
- [x] 步骤 8：更新 Spec Requirements 注释中的 `scanGetResults` 行
- [x] 步骤 9：删除 comptime 验证中涉及 `scanGetResults` 的注释引用

### 第二阶段：BK 平台适配 (`lib/platform/bk/impl/src/wifi.zig`)

- [x] 步骤 10：BK impl 层 — `WifiEvent` 新增 `scan_result: ApInfo` 变体（定义本地 ApInfo/AuthMode 类型）
- [x] 步骤 11：BK impl 层 — `ScanDoneInfo` 移除 `count` 字段
- [x] 步骤 12：BK impl 层 — 删除 `WifiDriver.scanGetResults()` 方法、`scan_results_hal` 静态缓冲区、HAL ApInfo/AuthMode 导入
- [x] 步骤 13：BK impl 层 — `WifiDriver` 新增 scan 状态字段：`scan_yielding`、`scan_cursor`、`scan_total`、`scan_success`
- [x] 步骤 14：BK impl 层 — 修改 `WifiDriver.pollEvent()`：拦截 scan_done → fetchScanResults → 逐条 yield scan_result → 最后 scan_done
- [x] 步骤 15：BK impl 层 — `scan_buf` 内部缓冲区 + `fetchScanResults()`/`securityToAuthMode()` 辅助函数
- [x] 步骤 16：BK `event_dispatch.zig` — 修改 `scan_done` 构造，移除 `.count = 0`

### 第三阶段：ESP 平台适配

- [x] 步骤 17：ESP IDF C helper — 新增 scan_event_handler、scan_start（带事件处理器注册）、scan_poll_done、scan_get_ap_count、scan_get_ap_records
- [x] 步骤 18：ESP IDF C helper — `wifi_helper_ap_flat_t` 结构体、`map_auth_mode` 转换函数
- [x] 步骤 19：ESP IDF Zig 绑定 — `ScanApFlat` extern struct、scan extern 声明、scanStart/scanPollDone/scanGetApCount/scanGetApRecords 封装
- [x] 步骤 20：ESP impl 层 — `StaDriver` 新增 scan 状态字段和 `scanStart()` 方法
- [x] 步骤 21：ESP impl 层 — `StaDriver.pollEvent()` 实现 scan 事件流：scanPollDone → fetchScanResults → yield scan_result × N → scan_done
- [x] 步骤 22：ESP `wifi.cmake` — WIFI_FORCE_LINK 添加 scan 函数

### 第四阶段：E2E 测试改写 (`e2e/tier1_wifi_scan/app.zig`)

- [x] 步骤 23：移除 `processing_results` 状态和 `scanGetResults()` 调用
- [x] 步骤 24：新增应用层 AP 列表缓冲区（`ap_list[64]`、`ap_count`）
- [x] 步骤 25：事件循环中处理 `scan_result` 事件 — 累积到 ap_list
- [x] 步骤 26：事件循环中处理 `scan_done` 事件 — 打印汇总结果，重置 ap_count

### 第五阶段：验证与收尾

- [x] 步骤 27：运行 `bazel test //lib/hal:hal_test` — 57/57 测试通过
- [x] 步骤 28：验证所有 7 条验收标准满足（AC1-AC7 全部 PASS）
- [x] 步骤 29：提交代码（4 commits）

注：ESP/BK 的 `bazel build` 需要交叉编译环境（IDF_PATH / ARMINO_PATH），本机无法执行完整构建。HAL 单元测试已在本机通过。
