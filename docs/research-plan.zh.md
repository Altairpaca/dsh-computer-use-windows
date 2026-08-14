# 跨平台 Computer Use 调研计划(Research Plan)

> 目标:在动手把 `dsh-computer-use-windows` 做成正式 bundle 之前,系统调研主流平台
> 与学术界的 computer use 实现,把"别人已经踩过的坑和验证过的做法"转化为我们的设计决策。
> 产出:一份对比矩阵 + 一组 ADR(架构决策记录),直接驱动 v1 实现。
> 调研窗口:2026-08-16 ~ 2026-08-22(约 1 周,可并行)。

---

## 1. 调研要回答的问题(Problem Statement)

按优先级排序,每个问题必须得到"证据 + 结论 + 对我们的影响"三级答案:

### P1 坐标与定位(我们实验的最大痛点)
1. 各平台如何让模型"指哪打哪"?纯坐标 / OCR 词框 / UI 语义树 / VLM grounding box / 编号标注(UI-TARS、OmniParser 风格)?
2. 坐标空间的坑:DPI 缩放、多显示器、窗口边框/标题栏偏移、缩放截图后坐标换算——各平台如何声明与处理?
3. VLM grounding 的系统性偏差(我们的"识别偏上、行为偏下")有哪些已知缓解手段?
   - 分辨率限制 / 缩放到固定尺寸再标注并回映射?
   - 网格编号 + 按编号点击(如 UI-TARS、Agent-E)?
   - grounding 结果画框回看确认?

### P2 验证与错误恢复
4. 动作后如何验证?"截图前后对比" / "UI 树 diff" / "预期文本出现/消失" / "像素 diff"?
5. 失败后如何重试?固定偏移网格 / 自适应校准 / 声明式期望(expect 前置条件+后置条件)?
6. 如何检测"点击进了别的窗口/应用没响应/页面未加载完"?超时与稳定等待策略(wait-for-stable、元素可见性轮询)?

### P3 窗口与应用管理
7. 如何绑定目标窗口?句柄/标题/进程/可访问性树?句柄失效(重登录、重启)如何恢复?
8. 焦点控制:SetForegroundWindow 的坑(前台锁限制)、AttachThreadInput fallback、无焦点注入(后台点击)可行性?
9. 窗口缩放后内容不重排(我们实验中 Chromium 内嵌 400px 视图的问题)如何识别与应对?

### P4 感知层选型
10. OCR:Windows OCR(WinRT)/ Tesseract / PaddleOCR / 云 OCR 的准确率、速度、坐标精度、中文支持对比;
11. 视觉模型:闭源 VLM(ChatGPT/Claude/Gemini)vs 开源(Qwen-VL/GLM-4V/UI-TARS)vs 免 key 匿名端点,
    在"UI 定位"任务上的实际表现;grounding 类工具(OmniParser、GroundingDINO)值不值得集成;
12. UI 语义树:Windows UIAutomation 的成熟度、与 OCR 混合使用的分工边界(ezpzai 的"UIA 优先、OCR 降级"是否适用于 DSH)。

### P5 架构与安全
13. 各平台 computer use 的权限模型与安全边界(scope、租约、单次确认);如何避免误操作;
14. 性能:每次动作的延迟预算;常驻 worker vs 每次 spawn(我们当前每次 spawn pwsh);
15. 失败模式清单:应用崩溃、UAC 安全桌面、锁屏、断网、代理——各平台如何处理。

---

## 2. 调研对象矩阵(按优先级分三档)

### A 档:直接竞品/同生态(必读,代码级)
| 对象 | 重点看 | 产出 |
|---|---|---|
| [Anionex/dsh-computer-use](https://github.com/Anionex/dsh-computer-use)(macOS) | observation TTL、元素索引+targetHandle、动作后返回新观测、作用域权限、焦点策略的实现细节 | 移植清单:哪些可直接搬到 Windows |
| [Anionex/dsh-vision-toolkit](https://github.com/Anionex/dsh-vision-toolkit) | grounding/像素 diff/长截图 OCR 的工具协议 | 是否直接复用其 vision 工具 |
| [ezpzai/codex-computer-use-windows](https://github.com/ezpzai/codex-computer-use-windows) | Windows 配方全貌:UIA 树、find_and_click_element、focus_window、batch_actions、expected_window | 可借鉴的工具面清单 |
| [ysr666/dsh-vision-router](https://github.com/ysr666/dsh-vision-router) | vision_ground 原像素框、免 key 链、渐进式挂载 | 视觉通道候选 |
| [tdf1995/dsh-plugin-vision](https://github.com/tdf1995/dsh-plugin-vision) | 双 provider 故障转移、凭据接入 | 视觉通道候选 |
| Claude Code / Codex 官方 computer use(SKILL/文档) | 官方 prompt 设计:如何描述观察-行动-验证循环 | 工具描述与 SKILL 措辞 |

### B 档:业界与学术界方案(精读论文/仓库 README 与架构文档)
| 对象 | 重点看 |
|---|---|
| [Microsoft UFO](https://github.com/microsoft/UFO)(Windows,UIA+视觉) | Windows 上语义+视觉混合的成熟架构;GPT-4V grounding;窗口/控件交互协议 |
| [Microsoft OmniParser / OmniParser-V2](https://github.com/microsoft/OmniParser) | UI 元素检测 + 编号标注,坐标回映射;是否值得作为可选后端 |
| [Agent-E(IBM)](https://github.com/IBM/agent-e) | grounding + 动作验证 + 树结构观测 |
| [UI-TARS(ByteDance)](https://github.com/bytedance/UI-TARS) | 原生屏幕理解模型;编号点击模式;坐标规范 |
| [OpenAdapt](https://github.com/OpenAdaptAI/OpenAdapt) | 演示驱动、坐标映射、行为克隆 |
| [Windows Agent Arena / OSWorld](https://github.com/microsoft/WindowsAgentArena) | Windows 基准:评估标准、已知失败模式 |
| [Anthropic computer use 文档](https://docs.anthropic.com/en/docs/build-with-claude/computer-use) | 官方最佳实践(截图分辨率、缩放、工具设计、防误操作) |
| [OpenAI CUA 文档](https://platform.openai.com/docs/guides/computer-use) | 合成截图、动作集、安全性 |
| [nut.js / robotjs / pyautogui](https://nutjs.dev/) | 输入注入层的地雷:焦点、管理员窗口、安全桌面 |

### C 档:社区经验与数据(快速扫)
- deepseek-harness 官方 Discussions 中 computer use / 屏幕操作相关帖子;
- awesome-dsh-plugin 目录中 界面/视觉/浏览器桥 分类下未入选但相关的仓库(如 dsh-browser-bridge、sherconan/dsh-web-recon 的作战手册思路);
- Claude Code / Codex 社区关于 Windows 自动化失败的 issue 汇总(坐标、DPI、UIA 限制)。

---

## 3. 调研方法(每档怎么做)

1. **代码级阅读(A 档)**:克隆仓库,通读核心模块,记录:工具清单、参数 schema、验证逻辑、
   错误处理、配置项;输出每仓库一页"速查卡"(存 `docs/research/`);
2. **文档级阅读(B 档)**:官方文档/论文摘要/架构图,重点提取"官方建议的做法"与"已知限制",
   标注对我们 P1–P5 问题的直接答案;
3. **实验验证(关键)**:对结论做最小实验,全部在 Windows 上跑:
   - `V1 校准实验`:在固定窗口上重复点击 5×5 网格,测量"请求坐标 vs 实际效果"的系统性偏移
     (验证 DPI-aware 后偏差是否归零;若不为零,量化并设计校准流程);
   - `V2 OCR 精度实验`:同一截图跑 WinRT OCR / Tesseract(chi_sim)/ PaddleOCR 对比词级坐标误差;
   - `V3 grounding 实验`:同一 UI 截图分别问 opencode-go VLM、GLM-4.6V、Qwen2.5-VL,
     比较"报框 vs 真实元素"的 IoU/中心点偏移(样本:云助理主页/列表页各 5 张);
   - `V4 验证闭环实验`:对 50 个点击动作,统计"无验证" vs "验证+偏移网格重试" 的成功率与耗时。
4. **ADR 输出**:每解决一个 P 问题,写一条 ADR(决策、备选、证据、影响),存 `docs/adr/`。

---

## 4. 时间表(并行化)

| 天 | A 档(代码) | B 档(文档) | C 档(社区) |
|---|---|---|---|
| D1 | Anionex dsh-computer-use 通读 | Anthropic/OpenAI 官方文档 | DSH discussions 扫帖 |
| D2 | ezpzai windows 配方 + dsh-vision-toolkit | UFO / OmniParser 架构 | awesome-dsh-plugin 相关分类 |
| D3 | vision-router / dsh-plugin-vision | UI-TARS / Agent-E / OpenAdapt | Codex/Claude 社区 issue |
| D4 | 输出速查卡 + 工具面对比矩阵 | 输出 B 档结论表 | 输出 C 档经验清单 |
| D5–D6 | **实验 V1–V4**(可提前并行) | | |
| D7 | ADR 汇总 + v1 设计定稿(design.md 更新) | | |

## 5. 验收标准

- [ ] P1–P5 每个问题都有"证据 + 结论 + 对我们的影响";
- [ ] 每仓库速查卡 ≥ 1 页;对比矩阵覆盖 A 档全部;
- [ ] V1–V4 实验全部跑通并记录数据(哪怕结论是"无系统性偏移");
- [ ] 至少 5 条 ADR,且每条都影响 v1 的代码或配置;
- [ ] design.md 的"调研结论"一节据此更新,冲突项注明 ADR 编号。

## 6. 负责人分工(单人完成时按档位)

- A 档 / 实验:优先(决定 v1 骨架);
- B 档:与 A 档并行;
- C 档:碎片时间扫,只留结论。

> 调研不阻塞主线:cu.ps1 v2 参考实现(窗口绑定/click_text/验证闭环)按现状设计先行,
> 调研结论只做增量修正,不做推翻式重构。
