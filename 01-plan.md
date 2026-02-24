# Plan: Fix AudioEngine + SimAudio Integration

## 概述
修复 AudioEngine 与 SimAudio 的集成测试，使完整的 AEC 闭环测试能够正常工作。

## 当前状态
- 简化版测试（手动调用 aec.process()）工作正常 ✓
- AudioEngine 版本卡住在初始化阶段 ✗

## 问题分析
AudioEngine 版本在以下位置卡住：
- sim.start() 
- engine.init()
- engine.start()

可能原因：
1. Threading 问题（SimAudio.clockLoop 与 Engine.speakerTask/micTask 冲突）
2. Driver 接口问题（SimAudio 驱动返回 pointer 而 Engine 需要 pointer）
3. 同步问题（blocking read/write 导致死锁）

## 执行步骤

### 步骤 1：诊断问题
- [ ] 1.1 创建最小复现测试：只初始化 Engine 不启动
- [ ] 1.2 添加详细日志定位卡住位置
- [ ] 1.3 检查 driver 接口是否匹配

### 步骤 2：修复接口问题
- [ ] 2.1 确认 SimAudio.Mic/Speaker/RefReader 接口签名
- [ ] 2.2 确认 AudioEngine 需要的接口签名
- [ ] 2.3 修复接口不匹配问题

### 步骤 3：修复 threading 问题
- [ ] 3.1 如果 SimAudio.clockLoop 与 Engine.task 冲突，考虑：
  - 方案 A：禁用 SimAudio.clockLoop，手动驱动
  - 方案 B：使用不同的 driver 模式
- [ ] 3.2 添加适当的同步机制

### 步骤 4：验证完整流程
- [ ] 4.1 确认 4 个 WAV 文件正确生成
- [ ] 4.2 确认 AEC 消除回声
- [ ] 4.3 确认 speaker 输出包含 clean 数据

## 验收标准
- [ ] AudioEngine 初始化不卡住
- [ ] 产生 4 个 WAV 文件：input, ref, mic, clean
- [ ] clean 中回声被消除
- [ ] speaker 输出与 clean 一致（而非 ref）
