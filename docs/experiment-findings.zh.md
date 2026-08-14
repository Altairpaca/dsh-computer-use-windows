# 实验复盘:云助理客户数据提取会话(2026-08-15)

> 来源:DSH 会话导出包 `dsh-session-session-2ac9a09e-d9aa-4b02-bb5a-3c6f621ab2eb.zip`
> (会话 `session-2ac9a09e`,cwd `D:\保险`,agent preset `code`)。
> 本文档把实验失败模式固化为本插件的设计输入;完整对比分析见
> [dsh-codex-gpt 仓库](https://github.com/Altairpaca/dsh-codex-gpt/blob/main/docs/computer-use-comparison.zh.md)。

## 1. 任务与工具

- 任务:用 computer use 操作保险"云助理"PC 客户端,提取客户/保单信息到 CSV;
- 工具面(当时会话的 Code Mode SDK):`computer_screenshot` / `computer_ocr` / `computer_vision` /
  `computer_mouse` / `computer_keyboard` / `computer_use_run`,底层实现为临时 PowerShell 脚本
  `%TEMP%\dsh-cu\cu.ps1`(WinRT OCR + mimo-v2.5 视觉 + user32 注入);
- 规模:约 26 分钟内 58 次截图、63 次 OCR、44 次鼠标动作,最终仍需人工多次纠正。

## 2. 失败模式与根因

| # | 现象 | 根因 | 本插件的对策 |
|---|---|---|---|
| F1 | 点进"月拜访客户"而非"孤单客户数",反复失败 | 目标窗口是 Chromium 应用内嵌 ~400px 手机视图;窗口被拉大到 1700×1030 后**内容未重排**;模型按放大后布局推断坐标 → 错位(日志:文字@(384,256) 却点 (440,256);文字@(82,359) 却点 (150,400)) | 窗口绑定 + OCR 词中心点击 + content_scale 提示 |
| F2 | "识别偏上、行为偏下",偏差 30–60px | (a) 全屏截图混入其他窗口文字(DSH Chrome/Edge/任务栏),OCR 与 VLM 被污染;(b) VLM 对全屏图直接报坐标,grounding 系统性偏上;(c) 裁剪后 OCR 坐标未回加裁剪偏移 | `filter_window` 窗口词过滤;`click_text` 不用 VLM 报点;crop 强制返回 offset 并回加 |
| F3 | 窗口句柄失效(264750→1181976) | Agent 硬编码 MainWindowHandle,重登录后句柄变化 | 每次动作动态解析句柄(标题/进程),focus 后校验 |
| F4 | 点击落在错误窗口 | 目标窗口未置前台,DSH 的 Chrome 在最上层 | `auto_focus` + `focus_check` 前置校验,不符拒绝 |
| F5 | 每步都是盲试,靠人工盯着纠正 | 无"点击→截图→OCR 验证→失败重试"闭环 | `verify` 验证闭环 + 偏移网格重试 + 证据返回 |
| F6 | vision 通道不稳定(偶发返回空)、成本不确定 | 单一 provider(opencode-go/mimo-v2.5),无故障转移 | provider 可插拔 + 超时重试 + 纯 OCR 模式 |
| F7 | 实现不可复用 | cu.ps1 在临时目录,会话结束即丢 | 固化为 bundle + helper 常驻仓库,可安装可审计 |

## 3. 对设计的直接要求(已纳入 design.zh.md)

1. 坐标必须**单一来源、单一坐标系**(DPI-aware + 窗口局部 + offset 回加);
2. 点击必须**可证明**(验证闭环),失败必须**带证据**;
3. 窗口必须**动态绑定**,点击前**前台校验**;
4. 感知层必须**可降级**(纯 OCR 模式完整可用)。

## 4. 遗留问题(待调研/实验)

- VLM grounding 偏差的定量评估与缓解手段对比(V3 实验);
- 验证闭环的像素 diff 阈值(V4 实验);
- Chromium 内嵌视图"内容缩放"的自动检测精度。
