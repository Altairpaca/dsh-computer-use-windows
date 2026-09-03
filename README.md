# DSH Computer Use for Windows

Experimental Windows computer-use bundle for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness), built around **window-scoped perception, text-grounded actions, and post-action verification**.

The repository grew out of a real desktop-automation failure mode: coordinate-only control was brittle when screenshots included unrelated windows, OCR positions drifted, or a click silently landed on the wrong UI state. The implementation therefore treats every action as an observable state transition rather than a blind coordinate command.

> 中文简介：面向 DeepSeek Harness 的 Windows computer-use 实验插件。核心是目标窗口绑定、OCR 文本定位、点击后验证与失败重试；视觉模型是可选项，纯 OCR 模式不需要外部 VLM。

## Status

**Experimental alpha.** The repository now contains a real DSH plugin wrapper (`plugins/index.js`), helper runtime (`helper/cu.ps1`), bundle patch, skill documentation, health checks, and Windows CI smoke coverage. It is suitable for development and controlled testing, but the project does not yet claim production-grade unattended desktop automation.

The remaining release gate is a clean-install / real-DSH validation matrix on representative Windows configurations.

## Design invariants

| Invariant | Why it exists |
| --- | --- |
| Window-scoped coordinates | screenshots, OCR results, and clicks must refer to the same target-window coordinate system |
| Text before coordinates | when text is observable, `click_text` resolves the target from OCR instead of asking the model to guess pixels |
| Verify after action | a click is successful only when the expected post-action state can be observed |
| Retry with evidence | offset retries return the attempted positions and verification result instead of hiding failure |
| Vision is optional | the deterministic OCR path remains usable without sending screenshots to an external model |
| Credentials stay external | model/API credentials are read from environment or host credential storage, not committed config |

## Implemented surface

| Capability | Current surface |
| --- | --- |
| `computer_screenshot` | full-screen or target-window screenshots with coordinate metadata |
| `computer_ocr` | Windows OCR with word coordinates, filtering, and fuzzy query support |
| `computer_click_text` | OCR locate → click → verify → bounded offset retry |
| `computer_mouse` / `computer_keyboard` | mouse, drag, scroll, keyboard, and clipboard-oriented input primitives |
| `computer_window` | enumerate, focus, and resolve target windows |
| `computer_use_run` | batch action execution through one tool call |
| `computer_vision` | optional pluggable OpenAI-compatible vision endpoint |
| `computer_calibrate` | DPI / residual calibration support |

The DSH-facing tool registration lives in `plugins/index.js`; the Windows implementation is kept in `helper/cu.ps1` so platform-specific mechanics remain isolated from the host adapter.

## Modes

### OCR-only

```jsonc
{
  "vision": {
    "enabled": false
  }
}
```

No screenshot is intentionally sent to a remote vision model in this mode.

### Optional vision provider

```jsonc
{
  "vision": {
    "enabled": true,
    "provider": "openai-compatible",
    "base_url": "https://your-vlm.example.com/v1",
    "api_key_env": "MY_VLM_KEY",
    "model": "your-model"
  }
}
```

The API key is referenced by environment-variable name; it is not stored in the repository configuration.

## Local smoke check

Requirements:

- Windows 11 recommended;
- PowerShell 7.4+;
- Node.js 20+ for the DSH plugin surface;
- Windows OCR language packs for OCR-dependent workflows.

Run:

```powershell
./scripts/check-health.ps1
```

The script exercises the helper health path and window enumeration. Missing OCR language support is reported as a warning rather than silently treated as available.

For a direct helper call:

```powershell
$env:CU_ARGS = '{"cmd":"screen"}'
& ./helper/cu.ps1
```

## Automated checks

GitHub Actions runs on `windows-latest` and currently verifies:

1. JavaScript syntax for the DSH plugin wrapper;
2. PowerShell parser correctness for the helper and health-check entry points;
3. the helper health smoke path on a real Windows runner.

This CI is intentionally narrower than the release claim. A hosted runner cannot replace interaction tests against real third-party desktop applications, DPI combinations, and language-pack configurations.

## Repository map

```text
.
├── plugins/index.js              # DSH-facing tool adapter
├── helper/cu.ps1                 # Windows implementation
├── skills/computer-use-windows/  # agent-facing usage contract
├── scripts/check-health.ps1      # local smoke/diagnostic entry point
├── docs/
│   ├── design.zh.md              # architecture and config design
│   ├── experiment-findings.zh.md # failure analysis from the original workflow
│   └── research-plan.zh.md       # comparison / validation questions
├── cordis.patch.yml              # DSH bundle composition
└── package.json
```

## Release-readiness work

Before calling this stable, the project should demonstrate:

- clean installation against a pinned current DSH release;
- at least one reproducible OCR-only workflow on Windows 11;
- DPI scaling checks (100% / 125% / 150% where practical);
- English and Simplified Chinese OCR language-pack behavior;
- explicit failure behavior when the target window disappears or verification cannot be satisfied;
- documentation of which actions are deterministic and which depend on a configured VLM.

## Safety boundary

This software can inject mouse and keyboard input into desktop applications. Use it only on systems and applications you are authorized to operate. Target-window checks reduce accidental interaction with unrelated windows but do not make arbitrary desktop automation risk-free.

If vision is enabled, screenshots may be transmitted to the configured endpoint. Use OCR-only mode when screenshots must remain local.

## License

MIT. See [`LICENSE`](LICENSE).
