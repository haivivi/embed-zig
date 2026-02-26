# Bazel External Workspace E2E

本目录用于验证 `embed_zig` 作为 external repo 被引用时的 Bazel 行为。

## external monitor（1130 devkit）

在 `external_esp` 子工作区执行：

```bash
bazel run //:monitor --@embed_zig//bazel:port=/dev/cu.usbserial-1130
```

预期：
- 命令可启动 monitor，不出现 runfiles 路径缺失错误。
- 日志中不出现 `external/embed_zig+...` 硬编码路径报错。
