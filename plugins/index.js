// dsh-computer-use-windows — host plugin
//
// Registers the computer_* tool family into the DSH tools registry. Every tool
// is a thin adapter: validate args -> spawn helper/cu.ps1 (one process per
// call, args via env CU_ARGS) -> return the helper's JSON as the tool result.
// All Windows interaction lives in helper/cu.ps1 (single-touch layer).
//
// Pure-JS (no TS/JSX); ESM imports only. See docs/design.zh.md for the
// full tool surface and config schema.

import { defineTool } from "@deepseek-ai/dsh-tools";
import z from "@deepseek-ai/schemastery";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve, isAbsolute } from "node:path";

const name = "computer-use-windows";

/** Services this plugin requires. `tools` is the registry; `systemPrompt` adds the usage section. */
const inject = ["tools", "systemPrompt"];

const Config = z.object({
  helperPath: z.string().default(""),
  enableVision: z.boolean().default(true)
});

/** Resolve helper/cu.ps1: config override, else bundled path relative to this file. */
function resolveHelper(config) {
  if (config.helperPath) {
    return isAbsolute(config.helperPath) ? config.helperPath : resolve(process.cwd(), config.helperPath);
  }
  return join(dirname(fileURLToPath(import.meta.url)), "..", "helper", "cu.ps1");
}

/**
 * Run one helper command. Returns the parsed JSON from stdout.
 * Rejects with the helper's {error} message; enforces timeoutMs via exec signal.
 */
function runHelper(helperPath, payload, exec, timeoutMs = 60000) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn("pwsh", ["-NoProfile", "-NonInteractive", "-File", helperPath], {
      env: { ...process.env, CU_ARGS: JSON.stringify(payload) },
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"]
    });
    let out = "";
    let err = "";
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error(`computer use helper timed out after ${timeoutMs}ms`));
    }, timeoutMs);
    if (exec?.signal) {
      exec.signal.addEventListener("abort", () => {
        clearTimeout(timer);
        child.kill();
        reject(new Error("computer use helper aborted"));
      }, { once: true });
    }
    child.stdout.on("data", (d) => { out += d; });
    child.stderr.on("data", (d) => { err += d; });
    child.on("error", (e) => { clearTimeout(timer); reject(e); });
    child.on("close", (code) => {
      clearTimeout(timer);
      const trimmed = out.trim();
      if (!trimmed) {
        reject(new Error(`computer use helper exited ${code} with no output${err ? `: ${err.trim().slice(0, 500)}` : ""}`));
        return;
      }
      let parsed;
      try {
        parsed = JSON.parse(trimmed.split("\n").pop()); // last line carries the JSON
      } catch {
        reject(new Error(`computer use helper returned non-JSON output: ${trimmed.slice(0, 500)}`));
        return;
      }
      if (parsed && parsed.ok === false) {
        reject(new Error(parsed.error || "computer use helper failed"));
        return;
      }
      resolvePromise(parsed);
    });
  });
}

/** Build a thin tool: name/desc/params -> helper payload mapping. */
function adapterTool(helperPath, spec) {
  return defineTool({
    name: spec.name,
    description: spec.description,
    parameters: spec.parameters,
    output: {
      schema: { type: "object", additionalProperties: true },
      render: (_args, value) => [{ type: "text", text: JSON.stringify(value, null, 2) }]
    },
    timeoutMs: spec.timeoutMs ?? 90000,
    async execute(args, exec) {
      const payload = { cmd: spec.cmd, ...args };
      return runHelper(helperPath, payload, exec, spec.timeoutMs ?? 90000);
    }
  });
}

function apply(ctx, config = {}) {
  const helperPath = resolveHelper(config);
  ctx.systemPrompt.section({
    name: "tool:computer-use-windows",
    order: 200,
    text:
      "The computer_* tools operate the Windows desktop through helper/cu.ps1. " +
      "Prefer computer_click_text (OCR-targeted click with a verification loop) over raw " +
      "computer_mouse coordinates. Always resolve the target window by title/process; " +
      "never hard-code window handles. Screenshot coordinates are physical pixels in the " +
      "window's local space when coords.space=window (default). Pure-OCR mode works without " +
      "any vision provider; computer_vision is optional."
  });

  ctx.tools.register(adapterTool(helperPath, {
    name: "computer_screenshot",
    cmd: "screen",
    description: "Capture the full virtual screen or a target window. Returns the PNG path, pixel size, window rect, and offset_x/offset_y (window origin in screen space). Pass window:{by:'title'|'process'|'hwnd', value} to crop to a window.",
    parameters: {
      window: {
        type: "object",
        additionalProperties: true,
        description: "Optional {by, value} window spec. When given, captures only that window and returns its rect as the coordinate origin."
      }
    }
  }));

  ctx.tools.register(adapterTool(helperPath, {
    name: "computer_ocr",
    cmd: "ocr",
    description: "OCR an image (or fresh screenshot) with Windows OCR. Returns words[] with per-word pixel boxes (x/y/w/h + centers cx/cy), lines[], and matches[] for a query. Coordinates are in the ORIGINAL image space; when a window is given, offset_x/offset_y is the window origin and words are filtered to the window rect.",
    parameters: {
      image: { type: "string", description: "PNG path to OCR. Omit to capture a fresh screenshot (honors window)." },
      window: { type: "object", additionalProperties: true, description: "Optional {by, value} window spec (used for capture + word filtering)." },
      query: { type: "string", description: "Optional text to match against words (fuzzy: whitespace/full-width normalized substring)." }
    },
    timeoutMs: 120000
  }));

  ctx.tools.register(adapterTool(helperPath, {
    name: "computer_click_text",
    cmd: "click_text",
    description: "Click the center of OCR-matched text inside a target window, then VERIFY: re-OCR and check expect (text should appear) and/or expect_absent (text should disappear), retrying with an offset grid. Returns attempts and an evidence screenshot. This is the preferred interaction primitive.",
    parameters: {
      text: { type: "string", required: true, description: "Text to locate and click (fuzzy match)." },
      window: { type: "object", additionalProperties: true, description: "{by, value} window spec (falls back to coords.window config)." },
      expect: { type: "string", description: "After click, this text should appear somewhere in the window." },
      expect_absent: { type: "string", description: "After click, this text should disappear from the window." }
    },
    timeoutMs: 120000
  }));

  ctx.tools.register(adapterTool(helperPath, {
    name: "computer_mouse",
    cmd: "mouse",
    description: "Mouse actions: move/click/double_click/right_click/scroll/drag. Coordinates are window-local when a window is given (or coords.window config) and coords.space=window; the helper adds the window origin and residual offset automatically. Focuses the target window first when auto_focus is enabled.",
    parameters: {
      action: { type: "string", required: true, enum: ["move", "click", "double_click", "right_click", "scroll", "drag"] },
      x: { type: "integer", description: "X in window-local (or screen) pixels." },
      y: { type: "integer", description: "Y in window-local (or screen) pixels." },
      window: { type: "object", additionalProperties: true, description: "Optional {by, value} window spec." },
      delta_x: { type: "integer", description: "scroll: horizontal wheel delta." },
      delta_y: { type: "integer", description: "scroll: vertical wheel delta." },
      end_x: { type: "integer", description: "drag: end X." },
      end_y: { type: "integer", description: "drag: end Y." }
    }
  }));

  ctx.tools.register(adapterTool(helperPath, {
    name: "computer_keyboard",
    cmd: "key",
    description: "Keyboard: press a key, hotkey combos, or type text (non-ASCII via clipboard paste). Keys: enter/tab/esc/space/backspace/delete/home/end/pageup/pagedown/arrows/f1-f24/ctrl/shift/alt/win.",
    parameters: {
      action: { type: "string", required: true, enum: ["press", "hotkey", "type"] },
      key: { type: "string", description: "press: key name or single character." },
      keys: { type: "array", items: { type: "string" }, description: "hotkey: modifier + key list, e.g. [ctrl, c, v]." },
      text: { type: "string", description: "type: text to enter." }
    }
  }));

  ctx.tools.register(adapterTool(helperPath, {
    name: "computer_window",
    cmd: "window",
    description: "Window management: list (visible windows with rects), rect (resolve a window spec to its current rect + hwnd), focus (bring to foreground with AttachThreadInput fallback and report whether it became foreground).",
    parameters: {
      action: { type: "string", required: true, enum: ["list", "rect", "focus"] },
      window: { type: "object", additionalProperties: true, description: "{by, value} window spec (rect/focus)." }
    }
  }));

  // computer_use_run (batch) is reserved for v1: run several steps in one helper
  // call. Until implemented, compose the individual tools in Code Mode instead.

  if (config.enableVision !== false) {
    ctx.tools.register(adapterTool(helperPath, {
      name: "computer_vision",
      cmd: "vision",
      description: "Ask the configured vision provider about a screenshot (or fresh capture). With grounding=box the response should include a {x1,y1,x2,y2} box in image pixels, which the helper extracts. Disabled entirely in pure-OCR mode (vision.enabled=false).",
      parameters: {
        image: { type: "string", description: "PNG path. Omit to capture fresh." },
        window: { type: "object", additionalProperties: true, description: "Optional window spec for capture." },
        prompt: { type: "string", description: "Question about the image." },
        ocr_text: { type: "string", description: "Optional OCR text to attach as context." }
      },
      timeoutMs: 120000
    }));
  }

  ctx.tools.register(adapterTool(helperPath, {
    name: "computer_calibrate",
    cmd: "calibrate",
    description: "Calibration: probe (move cursor to a screen point and report actual position/delta) or set-offset (persist residual dx/dy into config.json, applied to every subsequent click).",
    parameters: {
      action: { type: "string", required: true, enum: ["probe", "set-offset"] },
      x: { type: "integer", description: "probe: screen X." },
      y: { type: "integer", description: "probe: screen Y." },
      dx: { type: "integer", description: "set-offset: residual X offset." },
      dy: { type: "integer", description: "set-offset: residual Y offset." }
    }
  }));

  ctx.tools.register(adapterTool(helperPath, {
    name: "computer_config",
    cmd: "config",
    description: "Read or patch helper config.json (vision provider/model/key env, OCR settings, coords, verify, dpi). get returns the effective config with the key env redacted; set merges a patch.",
    parameters: {
      action: { type: "string", required: true, enum: ["get", "set"] },
      patch: { type: "object", additionalProperties: true, description: "set: partial config to merge (e.g. {vision:{enabled:false}})." }
    }
  }));

  ctx.tools.register(adapterTool(helperPath, {
    name: "computer_health",
    cmd: "health",
    description: "Health check: pwsh version, DPI awareness, OCR language availability, helper temp dir.",
    parameters: {}
  }));
}

export { Config, apply, inject, name };
