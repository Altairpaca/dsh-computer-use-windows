# Discussion 发布草稿(deepseek-harness Discussions)

> 用途:发布到 https://github.com/deepseek-ai/deepseek-harness/discussions
> 建议分类:**Show and tell**(或 **Plugins & Ecosystem**,视现有分类而定)。
> 发布前更新:仓库正式链接、版本号(v0→v1)、Star 数。

---

## 标题

**dsh-computer-use-windows:Windows Computer Use for DSH — 窗口绑定、验证闭环、纯 OCR 模式(填补 Windows 空白)**

## 正文

### TL;DR

为 DeepSeek Harness 发布了 Windows 版 computer use 插件(参考实现阶段):
窗口绑定截图/OCR、**按文字点击 + 验证闭环**、可插拔视觉模型、**纯 OCR 模式零外部依赖**。
生态里已有 macOS 的 [Anionex/dsh-computer-use](https://github.com/Anionex/dsh-computer-use),
Windows 侧此前是空白 —— 我们补上了。

Repo: https://github.com/Altairpaca/dsh-computer-use-windows

### 背景:一次真实实验的教训

在 Windows 上操作一个保险"云助理"客户端(Chromium 内嵌手机视图)提取客户数据时,原生的
"截图 → 让 VLM 报坐标 → 点击"工作流反复失败:点击系统性偏移(识别偏上、行为偏下)、
点错入口、全屏截图混入其他窗口文字、窗口句柄失效后盲目点击。复盘(见 repo
`docs/experiment-findings.zh.md`)得出四个根因,全部指向"盲坐标"工作流。

### 设计:四条原则

1. **窗口绑定** —— 所有截图/OCR/点击在目标窗口坐标空间内进行,点击自动回加窗口偏移,
   句柄动态解析,点击前校验前台窗口;
2. **文字即坐标** —— `computer_click_text`:OCR 定位文字中心再点击,模型不再猜坐标;
3. **验证闭环** —— 点击后自动截图+OCR 校验期望状态,失败按偏移网格重试,返回证据
   (截图+尝试记录),"盲试"变成"可证明";
4. **感知可配置** —— 视觉模型任意 OpenAI 兼容端点可插拔;`mode:"ocr"` 纯 OCR 模式下
   全部操作零外部 API,适合无 key/内网/隐私敏感场景。

### 现状与路线图

- ✅ 实验复盘 / 设计文档(含完整 config schema)
- ✅ cu.ps1 v2 参考实现(helper 层,可直接用)
- 🚧 Bundle 化(plugins/ 骨架)与一键安装 —— 调研期后定稿
- 📋 跨平台调研计划(Claude/OpenAI/Gemini/UFO/OmniParser/UI-TARS…)已公开在 repo

### 求反馈

1. Windows 上大家怎么处理 VLM grounding 偏差?(偏移网格?编号标注?UIA 树?)
2. 纯 OCR 模式 + 验证闭环对你够用吗?还是必须语义树(UIAutomation)?
3. 愿意一起做 Windows 版"语义优先"第二代的,欢迎来 repo 讨论。

### 致谢

设计借鉴 [Anionex/dsh-computer-use](https://github.com/Anionex/dsh-computer-use)(macOS 语义优先)、
[ezpzai/codex-computer-use-windows](https://github.com/ezpzai/codex-computer-use-windows)、
[ysr666/dsh-vision-router](https://github.com/ysr666/dsh-vision-router)。

---

*发布附注:如果 Discussions 分类里有 "Show and tell" 用这个;没有就选最接近的
(Plugins / Ecosystem)。配一张架构图或 click_text 验证闭环的示意图更佳(可在 repo assets/ 放一张)。*
