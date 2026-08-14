# Computer Use (Windows)

Operate Windows desktop applications through the `computer_*` tool family
(backed by `helper/cu.ps1`). Built for reliable GUI automation: window-bound
coordinates, OCR-targeted clicks, and a verification loop.

## Core workflow

1. **Resolve the window first.** `computer_window list` to find the target
   (title/process), then use it in every call as `window: {by:"title",
   value:"..."}`. Never hard-code window handles — they change on re-login.
2. **Prefer `computer_click_text`.** Locate click targets by OCR text, not by
   guessed coordinates: `computer_click_text(text:"孤单客户数", expect:"客户列表")`.
   The tool clicks the OCR word center, re-OCR-verifies `expect` /
   `expect_absent`, and retries an offset grid on failure.
3. **Verify after every action.** Ask for the expected state change in the same
   call (`expect` appears / `expect_absent` disappears). If verification fails,
   the tool returns evidence (attempts + screenshot) — re-inspect, don't blindly
   retry.
4. **Use raw coordinates only when OCR can't see the target.** Keep
   `coords.space: window` (default): pass window-local x/y; the helper adds the
   window origin + residual offset. Screenshot pixels are physical; what you see
   in the PNG at (x,y) is what a click at window-local (x,y) hits.

## Pure-OCR mode

When `vision.enabled` is false (or mode is `ocr`), all of the above works
without any vision model: OCR + click_text + verification are fully local.
`computer_vision` will fail with VISION_DISABLED — that is expected.

## Token-saving tips

- Use `computer_ocr` with `query` instead of dumping full text.
- Use `computer_ocr` on a window capture, not the full screen — other windows'
  text is filtered out automatically.
- Let `computer_click_text` verify; skip separate verification screenshots.

## Window management

- `computer_window list` — enumerate visible windows (rect + process + title).
- `computer_window focus` — bring to foreground; it reports whether the
  foreground check passed.
- If the app is a Chromium-embedded mobile view (e.g. 400px phone UI stretched
  wide), content may NOT re-layout after resize: prefer the window's natural
  aspect, or use window-local coordinates from the CURRENT capture, never from
  a previous layout.

## Constraints

- Works on the interactive desktop only; cannot operate UAC secure desktop or
  locked sessions.
- Screenshot coordinates are physical pixels (DPI-aware process); multi-monitor
  uses virtual-screen origin.
- OCR is Windows built-in (zh-Hans-CN / en-US); no extra install.
- Vision calls send screenshots to the configured provider — disable
  (`vision.enabled: false`) for offline/privacy-sensitive work.

## Config

`computer_config get` shows the effective config (key env redacted).
`computer_config set {patch}` merges partial config (e.g.
`{vision:{enabled:false}}`, `{verify:{retries:5}}`). Full schema:
`docs/design.zh.md`.
