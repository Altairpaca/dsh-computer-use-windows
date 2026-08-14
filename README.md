# DSH Computer Use (Windows)

> Windows Computer Use for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness):
> window-bound screenshots, robust OCR, verified clicks, pure-OCR mode, and pluggable vision models.
>
> 为 DeepSeek Harness 提供的 Windows 电脑控制插件:窗口绑定截图、健壮 OCR、带验证闭环的点击、
> 纯 OCR 模式、可自由配置的视觉模型。**填补 DSH 生态 Windows computer use 的空白。**

[![License: MIT](https://img.shields.io/badge/license-MIT-2f855a.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-Windows-0078d6.svg)
![PowerShell](https://img.shields.io/badge/powershell-7.4%2B-5391FE.svg)
![DeepSeek Harness](https://img.shields.io/badge/DeepSeek%20Harness-Bundle-5b50ed.svg)

## 为什么存在

DSH 生态里已有 [Anionex/dsh-computer-use](https://github.com/Anionex/dsh-computer-use)(macOS,
Accessibility-first)与一批 vision 插件,但 **Windows 上没有语义优先的 computer use 插件**。
本项目把 2026-08-15 真实实验(操作保险"云助理"客户端提取客户数据)的教训固化为插件:

实验中最致命的三个问题,全部来自"盲坐标"工作流:

1. **VLM/OCR 估坐标** → 点击系统性偏移("识别偏上、行为偏下"),点错入口;
2. **全屏截图混入其他窗口** → OCR 结果被无关文字污染,坐标张冠李戴;
3. **无验证闭环** → 每次点击都是盲试,靠人工盯着纠正。

本项目用四条原则解决它们:

- **窗口绑定**:所有截图/OCR/点击都在一个目标窗口的坐标系内,点击时自动回加窗口偏移;
- **文字即坐标**:提供 `click_text`,用 OCR 定位文字再点击——模型不再需要猜坐标;
- **验证闭环**:每次点击后自动截图 + OCR 校验预期状态,失败按偏移网格重试,返回证据;
- **可配置感知**:视觉模型可插拔(任意 OpenAI 兼容端点),也可以完全关闭——**纯 OCR 模式**
  下全部操作不依赖任何视觉模型,零外部 API。

## 功能特性

| 能力 | 说明 |
|---|---|
| `computer_screenshot` | 全屏或**目标窗口**截图,返回窗口 rect 与坐标空间信息 |
| `computer_ocr` | WinRT OCR(中文/英文),逐词坐标,窗口外词自动过滤,模糊匹配查询 |
| `computer_click_text` | 按文字点击:OCR 定位 → 点击 → **验证 → 失败重试(偏移网格)** |
| `computer_mouse` / `computer_keyboard` | 绝对坐标注入、拖拽、滚轮、剪贴板输入 |
| `computer_window` | 窗口枚举/聚焦/定位,句柄动态解析,前台校验 |
| `computer_use_run` | 批量动作一次调用(点击+输入+验证) |
| `computer_vision`(可选) | 可插拔视觉:opencode-go / 任意 OpenAI 兼容端点 / **关闭** |
| `computer_calibrate` | DPI/残差校准,校准结果持久化,后续点击自动修正 |

## 两种工作模式(Config 自由)

```jsonc
{
  "vision": {
    "enabled": false            // ← 纯 OCR 模式:不调用任何视觉模型
  }
}
```

```jsonc
{
  "vision": {
    "enabled": true,
    "provider": "openai-compatible",   // opencode-go | openai-compatible | none
    "base_url": "https://your-vlm.example.com/v1",
    "api_key_env": "MY_VLM_KEY",       // 从环境变量/DSH 凭据库取 key,不进配置
    "model": "your-vlm-model"
  }
}
```

完整配置见 [docs/design.zh.md](docs/design.zh.md)(`config` schema、每个字段的语义与默认值)。

## 快速开始

> 当前处于 **v0 参考实现**阶段(调研 + 设计 + helper 实现已完成,bundle 集成验证中)。
> 已安装 DSH(Web profile)与 PowerShell 7.4+。

```powershell
# 1. 克隆
git clone https://github.com/Altairpaca/dsh-computer-use-windows
# 2. 体检(可选)
./scripts/check-health.ps1
# 3. 直接使用 helper(无需安装插件即可体验)
$env:CU_ARGS = '{"cmd":"screen"}'
& ./helper/cu.ps1
# 4. 把 helper 安装为 DSH bundle(待 v1 完成)
dsh plugin add dsh-computer-use-windows   # 规划中
```

## 项目状态与路线图

| 阶段 | 内容 | 状态 |
|---|---|---|
| 0. 复盘 | 实验问题根因分析(坐标/验证/窗口) | ✅ 完成([docs/experiment-findings.zh.md](docs/experiment-findings.zh.md)) |
| 1. 调研 | 跨平台 computer use 方案调研(Claude/OpenAI/Gemini/UFO/OmniParser/UI-TARS…) | 📋 计划见 [docs/research-plan.zh.md](docs/research-plan.zh.md) |
| 2. 设计 | 架构、健壮性、config 自由度、OCR 健壮性 | ✅ 完成([docs/design.zh.md](docs/design.zh.md)) |
| 3. 参考实现 | cu.ps1 v2(窗口绑定/click_text/验证闭环/配置化) | ✅ `helper/cu.ps1` |
| 4. Bundle 化 | DSH 插件封装(tools 注册 + SKILL + 一键安装) | 🚧 `plugins/` 骨架,待调研结论固化 |
| 5. 发布 | GitHub Discussion、awesome-dsh-plugin 收录 | 📋 草稿见 [docs/discussion-post.md](docs/discussion-post.md) |

## 文档

- [docs/research-plan.zh.md](docs/research-plan.zh.md) — 跨平台调研计划(问题清单/平台矩阵/验证方法)
- [docs/design.zh.md](docs/design.zh.md) — 架构设计、健壮性、config schema、OCR 健壮性
- [docs/experiment-findings.zh.md](docs/experiment-findings.zh.md) — 实验复盘与根因
- [skills/computer-use-windows/SKILL.md](skills/computer-use-windows/SKILL.md) — 模型侧使用技能

## 安全声明

- 本插件通过 user32 注入鼠标键盘,可操作系统任意窗口;**默认只在目标窗口内点击**,
  但仍建议在隔离环境/授权范围内使用;
- vision 调用会把截图发送到你配置的视觉端点(自备端点或纯 OCR 模式可避免外发);
- API key 只从环境变量或 DSH 凭据库读取,不进入配置文件与代码。

## 许可证

[MIT](LICENSE) © 2026 Altair Li

---

*灵感与致谢:[Anionex/dsh-computer-use](https://github.com/Anionex/dsh-computer-use)(macOS 语义优先设计)、
[ezpzai/codex-computer-use-windows](https://github.com/ezpzai/codex-computer-use-windows)(Windows 配方)、
[ysr666/dsh-vision-router](https://github.com/ysr666/dsh-vision-router)(grounding 工具族)。*
