# 设计文档:健壮性、Config 自由度与 OCR 健壮性

> 本设计驱动 `dsh-computer-use-windows` v1 实现。现状:helper `cu.ps1` v2 参考实现已落地,
> 本文件描述其目标形态与设计决策;调研(见 research-plan)结论将以 ADR 增量更新本文。

---

## 1. 总体架构

```
DSH Agent (模型)
   │  tools.computer_*  (Code Mode SDK 或原生工具目录)
   ▼
DSH Host 插件  plugins/index.js          ← Cordis bundle (dsh.bundle.patch)
   │  ctx.tools.register(defineTool(...))  每个工具:参数校验 → 调用 helper → 结构化输出
   ▼
PowerShell helper  helper/cu.ps1          ← 唯一触碰 Windows 的层
   │  每次调用独立进程(pwsh),参数经 env CU_ARGS(JSON),结果经 stdout(JSON)
   ▼
Windows API: user32 (SetCursorPos/mouse_event/keybd_event/SetWindowPos)
             WinRT OCR (Windows.Media.Ocr)
             System.Drawing (截图/裁剪/预处理)
可选:HTTP 视觉端点(OpenAI 兼容 / opencode-go)
```

设计原则:

1. **单层触碰系统**:只有 cu.ps1 调用 Windows API,插件层只做参数/结果整形——便于审计与替换后端;
2. **无状态调用**:每次调用独立进程,通过配置文件持久的只有"校准偏移"与"窗口偏好",天然无共享状态竞争;
3. **失败必须带证据**:任何失败返回 JSON `{ok:false, error, evidence:{screenshot?, ocr?, attempted}}`,模型可以自纠;
4. **默认最小侵入**:默认只在目标窗口坐标空间内操作、点击前校验前台窗口、无验证不返回"成功"。

---

## 2. Config Schema(自由度设计)

配置文件位置:`$env:TEMP\dsh-cu\config.json`(可由插件 `computer_config` 工具读写,
也可直接手编)。所有字段都有默认值,缺省即可运行。

```jsonc
{
  // ── 感知模式 ──────────────────────────────────────────────
  "mode": "auto",                // "auto" | "ocr" | "vision"
                                 //   ocr   : 纯 OCR 模式,禁用所有视觉调用(零外部 API)
                                 //   vision: OCR + 视觉双通道(默认)
                                 //   auto  : 有 vision 配置→vision,否则→ocr
  "vision": {
    "enabled": true,             // false 等价于 mode:"ocr"
    "provider": "opencode-go",   // "none" | "opencode-go" | "openai-compatible" | "gemini" | "glm"
    "base_url": "",              // openai-compatible 专用,如 https://host/v1
    "api_key_env": "OPENCODE_GO_API_KEY",   // key 只从环境变量/DSH 凭据库读
    "model": "",                 // 留空用 provider 默认(mimo-v2.5 / glm-4.6v-flash …)
    "timeout_ms": 60000,
    "max_retries": 2,            // 429/5xx 重试
    "grounding": "box",          // "box"(返回 x1y1x2y2 包围盒) | "number"(编号标注) | "text"
    "annotate": true             // 把 grounding box 画回截图,供回看验证
  },

  // ── OCR 健壮性 ────────────────────────────────────────────
  "ocr": {
    "langs": ["zh-Hans-CN", "en-US"],   // 按顺序尝试,全部失败回退用户语言
    "preprocess": true,          // 灰度+对比度增强(小字号/低对比度场景)
    "upscale_factor": 2,         // 文字过小时 2x 放大后再 OCR(坐标自动回映射)
    "max_words": 500,
    "match": "fuzzy",            // "exact" | "fuzzy"(去空白/全半角归一化 + 子串)
    "filter_window": true        // 只返回目标窗口内的词(默认开,消灭跨窗口污染)
  },

  // ── 坐标与窗口 ────────────────────────────────────────────
  "coords": {
    "space": "window",           // "window"(窗口局部,点击时自动回加偏移) | "screen"
    "window": {                  // 默认目标窗口(可按标题/进程名/hwnd 指定)
      "by": "title",             // "title" | "process" | "hwnd"
      "value": "云助理"
    },
    "auto_focus": true,          // 点击前自动置前台(SetForegroundWindow+AttachThreadInput)
    "focus_check": true,         // 置前台后校验 GetForegroundWindow,不符则拒绝并报告
    "residual_offset": [0, 0]    // 人工/校准残留修正,叠加在所有点击上
  },

  // ── DPI ───────────────────────────────────────────────────
  "dpi": {
    "mode": "aware",             // "aware"(进程声明 PerMonitorV2,截图=物理像素=点击坐标)
                                 // "calibrate"(启动时自动校准,见 §4.1)
                                 // "none"(不处理,实验行为,不推荐)
    "auto_calibrate": true       // 首次使用自动跑一次校准并持久化
  },

  // ── 验证闭环 ──────────────────────────────────────────────
  "verify": {
    "enabled": true,
    "timeout_ms": 8000,          // 等待页面稳定/动作生效的总预算
    "settle_ms": 500,            // 动作后等待
    "retries": 3,                // 失败重试次数(每次换一组偏移)
    "offsets": [                 // 重试偏移网格(窗口局部像素)
      [0, 0], [6, 0], [-6, 0], [0, 6], [0, -6], [12, 0], [0, 12], [-12, 0], [0, -12]
    ]
  },

  // ── 运行时 ────────────────────────────────────────────────
  "runtime": {
    "temp_dir": "$env:TEMP/dsh-cu",   // 截图/结果文件目录
    "keep_artifacts": 5,        // 保留最近 N 个截图/OCR 结果,自动清理更旧的
    "max_output_bytes": 200000  // OCR 结果截断保护
  }
}
```

### 配置自由度承诺

- **视觉模型任意换**:只要你的端点兼容 OpenAI chat/completions 图像输入,填 `base_url/api_key_env/model`
  即可;内置 `opencode-go`/`gemini`/`glm` 快捷 provider;
- **纯 OCR 模式完整可用**:`mode:"ocr"` 下 `click_text`、验证闭环、窗口绑定全部照常工作,
  不产生任何外部请求——适合无 key、内网、或隐私敏感场景;
- **零配置可运行**:所有字段有默认值,`{}` 即代表"opencode-go + 全默认"。

---

## 3. 健壮性设计

### 3.1 坐标一致性(消灭"识别偏上、行为偏下")

| 环节 | 措施 |
|---|---|
| DPI | 进程声明 `SetProcessDpiAwarenessContext(PerMonitorV2)`:截图(CopyFromScreen)与注入(SetCursorPos)处于同一物理像素空间;pwsh 若已声明则跳过(避免 ERROR_ACCESS_DENIED) |
| 窗口偏移 | 所有截图/OCR 在窗口 rect 上归一:OCR 词坐标 = 窗口局部;点击时自动 +窗口 (left,top)。窗口移动后 rect 重新查询,不存在陈旧偏移 |
| 裁剪 | 工具层不再允许"裁剪后直接点击":任何 crop 返回 `{file, offset_x, offset_y}`,点击必须带 offset 回加 |
| 残留误差 | `coords.residual_offset` 持久化,`computer_calibrate` 写入;OCR 词中心点击命中即无需视觉 |
| 多显示器 | 虚拟屏原点(负坐标)在截图/点击两端同时处理(VirtualScreen.X/Y 参与偏移计算) |

### 3.2 验证闭环(把"盲试"变成"可证明")

```
click_text(孤单客户数) → 前置条件满足?
  1. window resolve(句柄动态查找,无硬编码)
  2. focus + focus_check(必要时)
  3. OCR 定位词 → 候选中心
  4. 点击(窗口局部 + residual_offset)
  5. 等待 settle_ms
  6. 重新截图 + OCR:
     - 有 expect_text   → 目标文本出现?→ 成功
     - 有 expect_absent → 目标文本消失?→ 成功
     - 无期望           → 截图前后 diff(窗口区域像素变化)非零?→ 成功(仅提示)
  7. 失败 → 按 verify.offsets 网格重试,直到 retries 用尽
  8. 全部失败 → 返回 {ok:false, evidence:{final_screenshot, ocr_words, attempted:[...]}}
```

所有成功/失败都附带"证据"(截图路径 + OCR 摘要),模型与用户都可复核。

### 3.3 窗口绑定与句柄失效恢复

- `computer_window list/focus/rect`:按 `title`(模糊)/`process`/`hwnd` 动态解析;
- 每次动作前重新解析句柄;**重登录/重建窗口后句柄变化自动跟随**(实验中的 264750→1181976 问题消失);
- `focus_check`:置前台后校验 `GetForegroundWindow == 目标`,失败拒绝执行(点击别的窗口 = 最贵的事故);
- Chromium 内嵌应用(如云助理)窗口拉大后内容不重排 → 工具返回 `content_scale` 提示
  (通过 OCR 词密度估计实际内容宽度),SKILL 指导模型优先用窗口原始宽高操作。

### 3.4 错误与超时

- 每个工具带 `timeout_ms`,默认 60s,超时返回部分证据;
- 明确错误分类:WINDOW_NOT_FOUND / FOREGROUND_MISMATCH / OCR_ENGINE_UNAVAILABLE /
  VISION_TIMEOUT / VERIFY_FAILED / INVALID_ARGS,模型可据此决策;
- 稳定等待:`verify.settle_ms` 后仍不稳定(连续两帧 OCR 文本变化)则继续等,直到 timeout;
- UAC 安全桌面 / 锁屏:检测到前台是 secure desktop 或会话已锁定时拒绝操作并明确报错。

### 3.5 安全

- 参数注入:所有参数经 env JSON(`CU_ARGS`),不拼接命令行字符串,无注入面;
- key 管理:视觉 key 只经 `api_key_env` 引用(环境变量或 DSH 凭据库),配置文件与日志不含 key;
- 范围约束:`coords.window` 默认限定动作目标;`click_text` 只点 OCR 命中词中心,不点空白区;
- 截图隐私:默认只保留最近 N 张,可配置关闭落盘。

---

## 4. OCR 健壮性

### 4.1 引擎与语言

- 主引擎:WinRT `Windows.Media.Ocr`(离线、免费、坐标精确到词、无外部依赖);
- 语言链:`zh-Hans-CN → en-US → 用户配置文件语言`,按 `ocr.langs` 顺序尝试;
- 候选扩展(调研 V2 实验后决定):Tesseract(chi_sim)作为 fallback、PaddleOCR 作为可选升级——
  对比指标:词级坐标误差(与人工标注的 IoU)、CJK 识别率、单次耗时。

### 4.2 预处理管线(preprocess: true)

```
输入 PNG → 灰度 → 自适应对比度增强(CLAHE) → (可选 2x 放大)
       → OCR → 词坐标 ÷ upscale_factor(回映射原图坐标)
```

- 小字号/低对比度(灰色文字、浅色背景)场景显著提升识别率;
- **坐标回映射是硬性要求**:任何缩放/裁剪都记录变换,词坐标永远回到原截图坐标空间,
  杜绝"放大后 OCR 坐标直接用"这类 bug。

### 4.3 词级结果质量

- 输出 `words[]`:`{text, x, y, w, h, cx, cy}`(窗口局部 + 屏幕绝对两套坐标);
- 行分组:按 y 聚类成行,提供 `lines[]`,便于列表页整行识别;
- 文本归一化:全角→半角、去空白,`match:"fuzzy"` 下匹配更稳(如"孤单客户数"vs"孤 单 客 户 数");
- `filter_window`:词必须落在窗口 rect 内才返回——实验中被 DSH Chrome/Edge 文字污染的根因直接消除;
- 大图:超过 OCR 引擎 MaxImageDimension 自动缩放并 `$sf` 回映射(继承 cu.ps1 v1 的正确实现);
- 输出截断:`max_words` + `max_output_bytes`,防止一次 OCR 撑爆上下文。

### 4.4 自检与诊断

- `computer_ocr --debug` 返回预处理前后对比图 + 每步耗时;
- `scripts/check-health.ps1` 检查:OCR 语言包是否安装、DPI 声明是否生效、
  目标窗口是否可枚举、Tesseract(若启用)是否存在;
- 连续失败自动降级:OCR 引擎不可用时明确报 OCR_ENGINE_UNAVAILABLE 而不是静默返回空。

---

## 5. 工具面(暂定 v1)

| 工具 | 参数(摘要) | 说明 |
|---|---|---|
| `computer_screenshot` | `window?` `region?` `annotate?` | 全屏/窗口截图;返回 `{file, width, height, window:{rect}, offset}` |
| `computer_ocr` | `image?` `window?` `query?` `lang?` `preprocess?` | OCR + 词坐标 + query 匹配(窗口过滤) |
| `computer_click_text` | `text` `window?` `expect?` `expect_absent?` | **核心**:文字点击 + 验证闭环 |
| `computer_mouse` | `action` `x? y?` `window?` | move/click/double/right/scroll/drag(窗口局部坐标) |
| `computer_keyboard` | `action` `key? keys? text?` | press/hotkey/type(剪贴板输入非 ASCII) |
| `computer_window` | `action` `by? value?` | list/focus/rect/resolve |
| `computer_use_run` | `steps[]` | 批量步骤一次执行,任一步失败即停并带证据(**v1 实现,当前用单工具组合**) |
| `computer_vision` | `image?` `prompt` `box?` | 可插拔视觉;`grounding:"box"` 返回包围盒 |
| `computer_calibrate` | `mode` | 校准残留偏移(写入 config) |
| `computer_config` | `get? set?` | 运行时读写配置 |

## 6. 与社区方案的定位

- 不做 macOS(那是 [Anionex/dsh-computer-use](https://github.com/Anionex/dsh-computer-use) 的领域,后续可联合);
- 不做通用浏览器自动化(DSH 生态已有 dsh-browser-bridge 等);
- 聚焦:**Windows 原生桌面应用的可靠操作**,以 OCR 优先、可纯 OCR 运行为差异化卖点;
- 架构上借鉴 Anionex 的"观测-绑定-验证"三段式,但落地为 Windows 的
  "窗口 rect + OCR 词 + 验证闭环"等价物(UIAutomation 语义层作为调研后的 v2 可选增强)。

## 7. 未决问题(待调研 ADR)

1. UIAutomation 语义树是否引入(pwsh 需 Windows Compatibility Pack;复杂度 vs 收益);
2. grounding:"box" vs "number" 编号标注,哪个对现有 VLM 更稳(V3 实验决定);
3. 常驻 helper 进程(省 spawn 开销,但引入状态与崩溃恢复)是否值得;
4. 验证闭环的像素 diff 阈值与误报控制(V4 实验)。
