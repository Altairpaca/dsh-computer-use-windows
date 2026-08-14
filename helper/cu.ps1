# dsh-computer-use-windows — helper/cu.ps1 (v2 reference implementation)
#
# Windows Computer Use bridge for DeepSeek Harness.
# One process per call, parameters via env CU_ARGS (JSON), results via stdout (JSON).
#
# v2 changes vs the 2026-08-15 experiment script:
#   - DPI-aware process (screenshot pixels == SetCursorPos coordinates)
#   - window binding: resolve/focus/rect, window-local coordinates, focus check
#   - click_text: OCR-targeted click + verification loop with offset grid retries
#   - config.json: pluggable vision (opencode-go / openai-compatible / gemini / glm / none),
#     pure-OCR mode, OCR preprocessing, fuzzy matching, window filtering
#   - errors carry evidence (screenshot + OCR summary)
#
# Usage:
#   $env:CU_ARGS = '{"cmd":"screen","window":{"by":"title","value":"云助理"}}'
#   & ./cu.ps1
#
# Config file: $env:TEMP\dsh-cu\config.json  (all fields optional, see docs/design.zh.md)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType=WindowsRuntime]
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType=WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType=WindowsRuntime]
$null = [Windows.Storage.Streams.RandomAccessStream, Windows.Storage.Streams, ContentType=WindowsRuntime]
$null = [Windows.Globalization.Language, Windows.Foundation, ContentType=WindowsRuntime]

# ── DPI awareness: make screenshot space == input space (physical pixels) ──────────
try {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DshDpi {
  [DllImport("user32.dll")] public static extern int SetProcessDpiAwarenessContext(IntPtr value);
  [DllImport("user32.dll")] public static extern int GetDpiForSystem();
  public static readonly IntPtr PMV2 = new IntPtr(-4); // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
}
'@
  [DshDpi]::SetProcessDpiAwarenessContext([DshDpi]::PMV2) | Out-Null
} catch { /* already DPI-aware (pwsh manifest) — fine */ }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DshCu {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
  [DllImport("user32.dll")] public static extern short VkKeyScan(char ch);
  [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT lpPoint);
  [DllImport("kernel32.dll")] public static extern uint GetLastError();
  public struct RECT { public int Left, Top, Right, Bottom; }
  public struct POINT { public int X, Y; }
  public const uint LEFTDOWN = 0x02, LEFTUP = 0x04, RIGHTDOWN = 0x08, RIGHTUP = 0x10, WHEEL = 0x0800, KEYUP = 0x02;
  public const byte VK_SHIFT = 0x10, VK_CTRL = 0x11, VK_ALT = 0x12, VK_V = 0x56;
  public static void Tap(byte code) { keybd_event(code, 0, 0, UIntPtr.Zero); keybd_event(code, 0, KEYUP, UIntPtr.Zero); }
  public static void Wheel(int delta) { mouse_event(WHEEL, 0, 0, (uint)delta, UIntPtr.Zero); }
  public static void AttachInputTo(IntPtr hWnd) {
    // AttachThreadInput fallback for reliable foreground switching
    uint fgPid, tgPid;
    uint fg = GetWindowThreadProcessId(GetForegroundWindow(), out fgPid);
    uint tg = GetWindowThreadProcessId(hWnd, out tgPid);
    if (fg != 0 && fg != tg) { AttachThreadInput(fg, tg, true); DetachThreadInput(fg, tg, true); }
  }
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
  [DllImport("user32.dll")] public static extern bool DetachThreadInput(uint idAttach, uint idAttachTo, bool fDetach);
}
'@

function Emit-Json($obj) { Write-Output ($obj | ConvertTo-Json -Compress -Depth 12) }
function Get-Param { return ($env:CU_ARGS | ConvertFrom-Json) }
function Get-CuDir { $d = Join-Path $env:TEMP 'dsh-cu'; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }; return $d }
function Get-Utf8 { return (New-Object System.Text.UTF8Encoding($false)) }

# ── config ─────────────────────────────────────────────────────────────────────────
function Get-Config {
  $defaults = @{
    mode = 'auto'                      # auto | ocr | vision
    vision = @{
      enabled = $true
      provider = 'opencode-go'         # none | opencode-go | openai-compatible | gemini | glm
      base_url = ''
      api_key_env = 'OPENCODE_GO_API_KEY'
      model = ''
      timeout_ms = 60000
      max_retries = 2
      grounding = 'box'                # box | text
      annotate = $true
    }
    ocr = @{
      langs = @('zh-Hans-CN', 'en-US')
      preprocess = $true
      upscale_factor = 2
      max_words = 500
      match = 'fuzzy'                  # exact | fuzzy
      filter_window = $true
    }
    coords = @{
      space = 'window'                 # window | screen
      window = $null                   # @{ by='title'|'process'|'hwnd'; value=... }
      auto_focus = $true
      focus_check = $true
      residual_offset = @(0, 0)
    }
    dpi = @{ mode = 'aware'; auto_calibrate = $true }
    verify = @{
      enabled = $true
      timeout_ms = 8000
      settle_ms = 500
      retries = 3
      offsets = @(@(0,0), @(6,0), @(-6,0), @(0,6), @(0,-6), @(12,0), @(0,12), @(-12,0), @(0,-12))
    }
    runtime = @{ keep_artifacts = 5; max_output_bytes = 200000 }
  }
  $cfgFile = Join-Path (Get-CuDir) 'config.json'
  $user = @{}
  if (Test-Path $cfgFile) { try { $user = (Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { } }
  # one-level deep merge (nested hashtables)
  $out = $defaults.Clone()
  foreach ($k in $user.PSObject.Properties) {
    $v = $k.Value
    if ($v -is [System.Management.Automation.PSCustomObject]) {
      $base = @{}
      if ($out.ContainsKey($k.Name)) { $base = $out[$k.Name] }
      $merged = $base.Clone()
      foreach ($sk in $v.PSObject.Properties) { $merged[$sk.Name] = $sk.Value }
      $out[$k.Name] = $merged
    } else { $out[$k.Name] = $v }
  }
  # mode resolution
  $vis = $out['vision']
  if ($out['mode'] -eq 'ocr' -or -not $vis['enabled'] -or $vis['provider'] -eq 'none') {
    $vis['enabled'] = $false; $out['mode'] = 'ocr'
  } elseif ($out['mode'] -eq 'auto') { $out['mode'] = 'vision' }
  return $out
}

# ── window binding ─────────────────────────────────────────────────────────────────
function Find-Window($spec) {
  if (-not $spec) { return $null }
  $by = [string]$spec.by; $value = [string]$spec.value
  if ($by -eq 'hwnd') {
    $h = [IntPtr]::new([int64]$value)
    $r = New-Object DshCu+RECT
    if ([DshCu]::IsWindow($h) -and [DshCu]::GetWindowRect($h, [ref]$r)) {
      return @{ hwnd = $h; title = $value; left = $r.Left; top = $r.Top; width = $r.Right - $r.Left; height = $r.Bottom - $r.Top }
    }
    return $null
  }
  if ($by -eq 'process') {
    $p = Get-Process -Name $value -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $p) { return $null }
    $h = $p.MainWindowHandle
    $r = New-Object DshCu+RECT
    if (-not [DshCu]::GetWindowRect($h, [ref]$r)) { return $null }
    return @{ hwnd = $h; title = $p.MainWindowTitle; left = $r.Left; top = $r.Top; width = $r.Right - $r.Left; height = $r.Bottom - $r.Top }
  }
  # title (substring, case-insensitive)
  $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like "*$value*" } | Select-Object -First 1
  if (-not $procs) { return $null }
  $h = $procs.MainWindowHandle
  $r = New-Object DshCu+RECT
  if (-not [DshCu]::GetWindowRect($h, [ref]$r)) { return $null }
  return @{ hwnd = $h; title = $procs.MainWindowTitle; left = $r.Left; top = $r.Top; width = $r.Right - $r.Left; height = $r.Bottom - $r.Top }
}

function Set-TargetForeground($win) {
  if (-not $win) { return $true }
  if ([DshCu]::IsIconic($win.hwnd)) { [DshCu]::ShowWindow($win.hwnd, 9) | Out-Null; Start-Sleep -Milliseconds 200 }
  [DshCu]::SetForegroundWindow($win.hwnd) | Out-Null
  [DshCu]::AttachInputTo($win.hwnd) | Out-Null
  [DshCu]::SetForegroundWindow($win.hwnd) | Out-Null
  Start-Sleep -Milliseconds 200
  return [DshCu]::GetForegroundWindow() -eq $win.hwnd
}

# ── screenshot ─────────────────────────────────────────────────────────────────────
function Invoke-Screen($p, $cfg) {
  $dir = Get-CuDir
  $stamp = Get-Date -Format 'yyyyMMddHHmmssfff'
  $win = $null
  $offsetX = 0; $offsetY = 0
  if ($p.window -or $cfg.coords.window) {
    $spec = if ($p.window) { $p.window } else { $cfg.coords.window }
    $win = Find-Window $spec
    if (-not $win) { throw 'WINDOW_NOT_FOUND: no window matches the given spec' }
    $offsetX = $win.left; $offsetY = $win.top
  }
  $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
  if ($win) {
    $bmp = New-Object System.Drawing.Bitmap($win.width, $win.height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($win.left, $win.top, 0, 0, $bmp.Size)
  } else {
    $bmp = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($vs.X, $vs.Y, 0, 0, $bmp.Size)
  }
  $full = Join-Path $dir ('screen-' + $stamp + '.png')
  $bmp.Save($full, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
  Cleanup-Artifacts $cfg
  return @{
    ok = $true; file = $full; width = $(if ($win) { $win.width } else { $vs.Width }); height = $(if ($win) { $win.height } else { $vs.Height })
    offset_x = $offsetX; offset_y = $offsetY
    window = $(if ($win) { @{ title = $win.title; left = $win.left; top = $win.top; width = $win.width; height = $win.height } } else { $null })
  }
}

function Cleanup-Artifacts($cfg) {
  try {
    $keep = [int]$cfg.runtime.keep_artifacts
    $dir = Get-CuDir
    Get-ChildItem $dir -Filter '*.png' | Sort-Object LastWriteTime -Descending | Select-Object -Skip $keep | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem $dir -Filter 'ocr-*.json' | Sort-Object LastWriteTime -Descending | Select-Object -Skip $keep | Remove-Item -Force -ErrorAction SilentlyContinue
  } catch { }
}

# ── OCR ────────────────────────────────────────────────────────────────────────────
function Await($WinRtTask, $ResultType) {
  $m = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
  $t = $m.MakeGenericMethod($ResultType)
  $nt = $t.Invoke($null, @($WinRtTask))
  $nt.Wait(-1) | Out-Null
  return $nt.Result
}

function Get-OcrEngine([string]$langTag) {
  if ($langTag -and $langTag -ne 'auto') {
    try {
      $lang = New-Object Windows.Globalization.Language($langTag)
      $e = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
      if ($e) { return $e }
    } catch {}
  }
  foreach ($cand in @('zh-Hans-CN', 'en-US')) {
    try {
      $lang = New-Object Windows.Globalization.Language($cand)
      $e = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
      if ($e) { return $e }
    } catch {}
  }
  $e = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
  if ($e) { return $e }
  throw 'OCR_ENGINE_UNAVAILABLE: no usable Windows OCR language pack (install Chinese/English language pack)'
}

function Normalize-Text([string]$s) {
  if (-not $s) { return '' }
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $s.ToCharArray()) {
    $c = [int]$ch
    if ($c -ge 0xFF01 -and $c -le 0xFF5E) { $c = $c - 0xFEE0 }  # full-width → half-width
    elseif ($c -eq 0x3000) { $c = 0x20 }                          # ideographic space
    if (-not [char]::IsWhiteSpace([char]$c)) { [void]$sb.Append([char]$c) }
  }
  return $sb.ToString().ToLowerInvariant()
}

function Run-OcrOnFile($imgPath, $cfg, $wantLangs) {
  $engine = $null
  foreach ($tag in $wantLangs) { $engine = Get-OcrEngine $tag; if ($engine) { break } }
  if (-not $engine) { throw 'OCR_ENGINE_UNAVAILABLE' }
  $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($imgPath)) ([Windows.Storage.StorageFile])
  $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
  $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $maxDim = [Windows.Media.Ocr.OcrEngine]::MaxImageDimension
  $sf = 1.0
  if ($decoder.PixelWidth -gt $maxDim -or $decoder.PixelHeight -gt $maxDim) {
    $sf = [Math]::Min($maxDim / $decoder.PixelWidth, $maxDim / $decoder.PixelHeight)
    $tr = New-Object Windows.Graphics.Imaging.BitmapTransform
    $tr.ScaledWidth = [uint32]($decoder.PixelWidth * $sf)
    $tr.ScaledHeight = [uint32]($decoder.PixelHeight * $sf)
    $bitmap = Await ($decoder.GetSoftwareBitmapAsync([Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8, [Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied, $tr)) ([Windows.Graphics.Imaging.SoftwareBitmap])
  } else {
    $bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
  }
  $result = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
  $lines = @($result.Lines | ForEach-Object { $_.Text })
  $words = @()
  foreach ($line in $result.Lines) {
    foreach ($w in $line.Words) {
      $r = $w.BoundingRect
      $words += @{
        text = $w.Text
        x = [int]($r.X / $sf); y = [int]($r.Y / $sf); w = [int]($r.Width / $sf); h = [int]($r.Height / $sf)
        cx = [int](($r.X + $r.Width / 2) / $sf); cy = [int](($r.Y + $r.Height / 2) / $sf)
      }
    }
  }
  return @{ engine = $engine.RecognizerLanguage.LanguageTag; text = ($lines -join [char]10); words = $words }
}

function Preprocess-Image($srcPath, $upscale) {
  # grayscale + contrast stretch (and optional upscale) → temp png; returns new path + scale factor
  $src = [System.Drawing.Image]::FromFile($srcPath)
  $w = $src.Width; $h = $src.Height
  $outW = $w; $outH = $h; $sf = 1.0
  if ($upscale -gt 1) { $outW = $w * $upscale; $outH = $h * $upscale; $sf = $upscale }
  $bmp = New-Object System.Drawing.Bitmap($outW, $outH)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $cm = New-Object System.Drawing.Imaging.ColorMatrix
  $cm.Matrix00 = 0.33; $cm.Matrix01 = 0.33; $cm.Matrix02 = 0.33
  $cm.Matrix10 = 0.33; $cm.Matrix11 = 0.33; $cm.Matrix12 = 0.33
  $cm.Matrix20 = 0.33; $cm.Matrix21 = 0.33; $cm.Matrix22 = 0.33
  $ia = New-Object System.Drawing.Imaging.ImageAttributes
  $ia.SetColorMatrix($cm, [System.Drawing.Imaging.ColorMatrixFlag]::SkipGrays, [System.Drawing.Imaging.ColorAdjustType]::Bitmap)
  $rect = New-Object System.Drawing.Rectangle(0, 0, $outW, $outH)
  $g.DrawImage($src, $rect, 0, 0, $w, $h, [System.Drawing.GraphicsUnit]::Pixel, $ia)
  $g.Dispose(); $src.Dispose()
  $dir = Get-CuDir
  $out = Join-Path $dir ('pre-' + (Get-Date -Format 'yyyyMMddHHmmssfff') + '.png')
  $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  return @{ path = $out; scale = $sf }
}

function Invoke-Ocr($p, $cfg) {
  $dir = Get-CuDir
  # 1) produce the image (explicit path, or fresh screenshot with optional window)
  $imgPath = [string]$p.image
  $win = $null
  $offsetX = 0; $offsetY = 0
  if (-not $imgPath) {
    $shot = Invoke-Screen $p $cfg
    $imgPath = $shot.file; $offsetX = $shot.offset_x; $offsetY = $shot.offset_y
    if ($shot.window) { $win = $shot.window }
  } elseif ($cfg.ocr.filter_window -and $p.window) {
    $spec = $p.window
    $w = Find-Window $spec
    if ($w) { $offsetX = $w.left; $offsetY = $w.top; $win = @{ title = $w.title; left = $w.left; top = $w.top; width = $w.width; height = $w.height } }
  }
  # 2) optional preprocessing
  $ocrPath = $imgPath
  $imgScale = 1.0
  if ($cfg.ocr.preprocess) {
    $pp = Preprocess-Image $imgPath ([int]$cfg.ocr.upscale_factor)
    $ocrPath = $pp.path; $imgScale = $pp.scale
  }
  # 3) OCR
  $want = @()
  foreach ($l in @($cfg.ocr.langs)) { $want += [string]$l }
  $res = Run-OcrOnFile $ocrPath $cfg $want
  # 4) map coordinates back to the ORIGINAL image space
  $words = @()
  foreach ($wd in $res.words) {
    $words += @{
      text = $wd.text
      x = [int]($wd.x / $imgScale); y = [int]($wd.y / $imgScale)
      w = [int]($wd.w / $imgScale); h = [int]($wd.h / $imgScale)
      cx = [int]($wd.cx / $imgScale); cy = [int]($wd.cy / $imgScale)
    }
  }
  # 5) window filtering (drop words outside the target window rect)
  if ($cfg.ocr.filter_window -and $win) {
    $rx = $win.left; $ry = $win.top; $rw = $win.width; $rh = $win.height
    $words = @($words | Where-Object { $_.cx -ge $rx -and $_.cx -lt ($rx + $rw) -and $_.cy -ge $ry -and $_.cy -lt ($ry + $rh) })
  }
  # 6) truncation
  $maxWords = [int]$cfg.ocr.max_words
  if ($words.Count -gt $maxWords) { $words = @($words | Select-Object -First $maxWords) }
  # 7) query matching (fuzzy: normalized substring)
  $matches = @()
  $q = [string]$p.query
  if ($q) {
    $nq = Normalize-Text $q
    foreach ($wd in $words) {
      if ($cfg.ocr.match -eq 'exact') {
        if ((Normalize-Text $wd.text) -eq $nq) { $matches += $wd }
      } else {
        if ((Normalize-Text $wd.text).Contains($nq)) { $matches += $wd }
      }
    }
  }
  # 8) line grouping
  $lineGroups = @()
  $sorted = @($words | Sort-Object y, x)
  foreach ($wd in $sorted) {
    $placed = $false
    for ($i = 0; $i -lt $lineGroups.Count; $i++) {
      $ref = $lineGroups[$i][0]
      if ([Math]::Abs($wd.y - $ref.y) -lt [Math]::Max(8, $ref.h * 0.6)) {
        $lineGroups[$i] = $lineGroups[$i] + $wd; $placed = $true; break
      }
    }
    if (-not $placed) { $lineGroups += ,@($wd) }
  }
  $lines = @($lineGroups | ForEach-Object { @{ text = (($_ | ForEach-Object { $_.text }) -join ''); y = $_[0].y; x = $_[0].x } })
  $out = @{
    ok = $true; lang = $res.engine; image = $imgPath
    text = $res.text
    words = $words
    matches = $matches
    lines = $lines
    offset_x = $offsetX; offset_y = $offsetY
    window = $win
  }
  $resFile = Join-Path $dir ('ocr-' + (Get-Date -Format 'yyyyMMddHHmmssfff') + '.json')
  [IO.File]::WriteAllText($resFile, ($out | ConvertTo-Json -Compress -Depth 8), (Get-Utf8))
  Cleanup-Artifacts $cfg
  Emit-Json @{ ok = $true; result_file = $resFile; summary = @{ lang = $res.engine; word_count = $words.Count; match_count = $matches.Count } }
}

# ── mouse / keyboard ───────────────────────────────────────────────────────────────
function Resolve-ClickPoint($p, $cfg) {
  $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $win = $null
  if ($p.window -or $cfg.coords.window) {
    $spec = if ($p.window) { $p.window } else { $cfg.coords.window }
    $win = Find-Window $spec
    if (-not $win) { throw 'WINDOW_NOT_FOUND: no window matches the given spec' }
    if ($cfg.coords.auto_focus) { $ok = Set-TargetForeground $win; if ($cfg.coords.focus_check -and -not $ok) { throw 'FOREGROUND_MISMATCH: cannot bring target window to foreground' } }
  }
  $ro = @($cfg.coords.residual_offset)
  $sx = [int]$p.x + $ro[0]
  $sy = [int]$p.y + $ro[1]
  if ($win -and $cfg.coords.space -eq 'window') { $sx += $win.left; $sy += $win.top }
  $sx += $vs.X; $sy += $vs.Y
  return @{ x = $sx; y = $sy; win = $win }
}

function Invoke-Mouse($p, $cfg) {
  $pt = Resolve-ClickPoint $p $cfg
  $action = [string]$p.action
  switch ($action) {
    'move' { [DshCu]::SetCursorPos($pt.x, $pt.y) | Out-Null }
    'click' { [DshCu]::SetCursorPos($pt.x, $pt.y) | Out-Null; [DshCu]::mouse_event([DshCu]::LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 40; [DshCu]::mouse_event([DshCu]::LEFTUP, 0, 0, 0, [UIntPtr]::Zero) }
    'double_click' { [DshCu]::SetCursorPos($pt.x, $pt.y) | Out-Null; 1..2 | ForEach-Object { [DshCu]::mouse_event([DshCu]::LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 40; [DshCu]::mouse_event([DshCu]::LEFTUP, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60 } }
    'right_click' { [DshCu]::SetCursorPos($pt.x, $pt.y) | Out-Null; [DshCu]::mouse_event([DshCu]::RIGHTDOWN, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 40; [DshCu]::mouse_event([DshCu]::RIGHTUP, 0, 0, 0, [UIntPtr]::Zero) }
    'scroll' { $dy = [int]$p.delta_y; if ($dy -eq 0) { $dy = [int]$p.delta_x }; [DshCu]::Wheel($dy * 120) }
    'drag' {
      $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
      $ex = [int]$p.end_x + $pt.win.left + $vs.X
      $ey = [int]$p.end_y + $pt.win.top + $vs.Y
      if (-not $pt.win) { $ex = [int]$p.end_x + $vs.X; $ey = [int]$p.end_y + $vs.Y }
      [DshCu]::SetCursorPos($pt.x, $pt.y) | Out-Null
      [DshCu]::mouse_event([DshCu]::LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
      1..10 | ForEach-Object { $t = $_ / 10; [DshCu]::SetCursorPos([int]($pt.x + ($ex - $pt.x) * $t), [int]($pt.y + ($ey - $pt.y) * $t)) | Out-Null; Start-Sleep -Milliseconds 15 }
      [DshCu]::mouse_event([DshCu]::LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
    }
    default { throw ('INVALID_ARGS: unknown mouse action: ' + $action) }
  }
  Emit-Json @{ ok = $true; action = $action; x = [int]$p.x; y = [int]$p.y; screen_x = $pt.x; screen_y = $pt.y }
}

function Key-Code([string]$name) {
  $n = $name.ToLower()
  $map = @{
    'enter' = 0x0D; 'return' = 0x0D; 'tab' = 0x09; 'esc' = 0x1B; 'escape' = 0x1B; 'space' = 0x20;
    'backspace' = 0x08; 'delete' = 0x2E; 'home' = 0x24; 'end' = 0x23; 'pageup' = 0x21; 'pagedown' = 0x22;
    'up' = 0x26; 'down' = 0x28; 'left' = 0x25; 'right' = 0x27; 'insert' = 0x2D; 'capslock' = 0x14; 'caps' = 0x14;
    'win' = 0x5B; 'menu' = 0x5D; 'ctrl' = 0x11; 'control' = 0x11; 'shift' = 0x10; 'alt' = 0x12;
    'f1' = 0x70; 'f2' = 0x71; 'f3' = 0x72; 'f4' = 0x73; 'f5' = 0x74; 'f6' = 0x75; 'f7' = 0x76; 'f8' = 0x77;
    'f9' = 0x78; 'f10' = 0x79; 'f11' = 0x7A; 'f12' = 0x7B; 'f13' = 0x7C; 'f14' = 0x7D; 'f15' = 0x7E; 'f16' = 0x7F;
    'f17' = 0x80; 'f18' = 0x81; 'f19' = 0x82; 'f20' = 0x83; 'f21' = 0x84; 'f22' = 0x85; 'f23' = 0x86; 'f24' = 0x87
  }
  if ($map.ContainsKey($n)) { return [int]$map[$n] }
  if ($name.Length -eq 1) {
    $vk = [DshCu]::VkKeyScan([char]$name[0])
    if ($vk -ge 0) { return [int]($vk -band 0xFF) }
  }
  return -1
}

function Paste-Text([string]$s) {
  [System.Windows.Forms.Clipboard]::SetText($s)
  Start-Sleep -Milliseconds 120
  [DshCu]::keybd_event([DshCu]::VK_CTRL, 0, 0, [UIntPtr]::Zero)
  [DshCu]::Tap([DshCu]::VK_V)
  [DshCu]::keybd_event([DshCu]::VK_CTRL, 0, 2, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 120
}

function Invoke-Key($p) {
  $action = [string]$p.action
  if ($action -eq 'press') {
    $code = Key-Code ([string]$p.key)
    if ($code -lt 0) { throw ('INVALID_ARGS: unknown key: ' + $p.key) }
    [DshCu]::Tap([byte]$code)
    Emit-Json @{ ok = $true; action = 'press'; key = [string]$p.key }
    return
  }
  if ($action -eq 'hotkey') {
    $down = @()
    foreach ($k in @($p.keys)) {
      $code = Key-Code ([string]$k)
      if ($code -lt 0) { throw ('INVALID_ARGS: unknown key: ' + $k) }
      $low = $k.ToLower()
      if ($low -in @('ctrl','control','shift','alt','win')) { [DshCu]::keybd_event([byte]$code, 0, 0, [UIntPtr]::Zero); $down += $code }
      else { [DshCu]::Tap([byte]$code) }
    }
    foreach ($code in $down) { [DshCu]::keybd_event([byte]$code, 0, 2, [UIntPtr]::Zero) }
    Emit-Json @{ ok = $true; action = 'hotkey'; keys = @($p.keys) }
    return
  }
  if ($action -eq 'type') {
    $text = [string]$p.text
    $clipBuf = New-Object System.Text.StringBuilder
    foreach ($ch in $text.ToCharArray()) {
      $vk = [DshCu]::VkKeyScan($ch)
      if ($vk -lt 0) { [void]$clipBuf.Append($ch); continue }
      if ($clipBuf.Length -gt 0) { Paste-Text $clipBuf.ToString(); [void]$clipBuf.Clear() }
      $code = [byte]($vk -band 0xFF)
      $mods = ($vk -shr 8)
      $shift = (($mods -band 1) -ne 0); $ctrl = (($mods -band 2) -ne 0); $alt = (($mods -band 4) -ne 0)
      if ($shift) { [DshCu]::keybd_event([DshCu]::VK_SHIFT, 0, 0, [UIntPtr]::Zero) }
      if ($ctrl) { [DshCu]::keybd_event([DshCu]::VK_CTRL, 0, 0, [UIntPtr]::Zero) }
      if ($alt) { [DshCu]::keybd_event([DshCu]::VK_ALT, 0, 0, [UIntPtr]::Zero) }
      [DshCu]::Tap($code)
      if ($shift) { [DshCu]::keybd_event([DshCu]::VK_SHIFT, 0, 2, [UIntPtr]::Zero) }
      if ($ctrl) { [DshCu]::keybd_event([DshCu]::VK_CTRL, 0, 2, [UIntPtr]::Zero) }
      if ($alt) { [DshCu]::keybd_event([DshCu]::VK_ALT, 0, 2, [UIntPtr]::Zero) }
    }
    if ($clipBuf.Length -gt 0) { Paste-Text $clipBuf.ToString() }
    Emit-Json @{ ok = $true; action = 'type'; chars = $text.Length }
    return
  }
  throw ('INVALID_ARGS: unknown key action: ' + $action)
}

# ── click_text: OCR-targeted click + verification loop ─────────────────────────────
function Invoke-ClickText($p, $cfg) {
  if (-not $p.text) { throw 'INVALID_ARGS: text is required' }
  $want = [string]$p.text
  $target = if ($p.window) { $p.window } else { $cfg.coords.window }
  if (-not $target) { throw 'INVALID_ARGS: click_text requires a target window (--window or coords.window)' }
  $win = Find-Window $target
  if (-not $win) { throw 'WINDOW_NOT_FOUND' }
  if ($cfg.coords.auto_focus) {
    $ok = Set-TargetForeground $win
    if ($cfg.coords.focus_check -and -not $ok) { throw 'FOREGROUND_MISMATCH: cannot bring target window to foreground' }
  }
  $verifyCfg = $cfg.verify
  $expect = [string]$p.expect
  $expectAbsent = [string]$p.expect_absent
  $verifyOn = ($verifyCfg.enabled -and ($expect -or $expectAbsent)) -or $p.verify -eq $true
  $attempts = @()
  $deadline = [DateTime]::UtcNow.AddMilliseconds([double]$verifyCfg.timeout_ms)
  # locate the word center (window-local)
  $shot = Invoke-Screen @{ window = $target } $cfg
  $ocrArgs = @{ image = $shot.file; window = $target; query = $want }
  $ocrResRaw = Invoke-Ocr $ocrArgs $cfg
  $ocrResFile = $ocrResRaw.result_file
  $ocrRes = Get-Content $ocrResFile -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($ocrRes.matches.Count -lt 1) { throw ('VERIFY_FAILED: text not found by OCR: ' + $want) }
  $m = $ocrRes.matches[0]
  $baseX = [int]($m.cx - $ocrRes.offset_x)   # window-local
  $baseY = [int]($m.cy - $ocrRes.offset_y)
  $offsets = @($verifyCfg.offsets)
  if ($offsets.Count -eq 0) { $offsets = @(@(0,0)) }
  $maxTries = [Math]::Max(1, [int]$verifyCfg.retries) * $offsets.Count
  foreach ($off in $offsets) {
    if ([DateTime]::UtcNow -gt $deadline) { break }
    $dx = [int]$off[0]; $dy = [int]$off[1]
    $attempts += @{ dx = $dx; dy = $dy }
    $clickP = @{ action = 'click'; x = $baseX + $dx; y = $baseY + $dy; window = $target }
    Invoke-Mouse $clickP $cfg | Out-Null
    Start-Sleep -Milliseconds ([int]$verifyCfg.settle_ms)
    if (-not $verifyOn) {
      Emit-Json @{ ok = $true; clicked = $true; window_local = @{ x = $baseX + $dx; y = $baseY + $dy }; text = $want; attempts = $attempts; note = 'no verification requested' }
      return
    }
    # verify: re-OCR and check expected state
    $vShot = Invoke-Screen @{ window = $target } $cfg
    $vOcrRaw = Invoke-Ocr @{ image = $vShot.file; window = $target } $cfg
    $vFile = $vOcrRaw.result_file
    $vRes = Get-Content $vFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $fullText = $vRes.text
    $normFull = Normalize-Text $fullText
    $passed = $true
    if ($expect) { $passed = $passed -and $normFull.Contains((Normalize-Text $expect)) }
    if ($expectAbsent) { $passed = $passed -and -not $normFull.Contains((Normalize-Text $expectAbsent)) }
    if ($passed) {
      Emit-Json @{ ok = $true; clicked = $true; verified = $true; window_local = @{ x = $baseX + $dx; y = $baseY + $dy }; text = $want; expect = $(if ($expect) { $expect } else { $null }); expect_absent = $(if ($expectAbsent) { $expectAbsent } else { $null }); attempts = $attempts; evidence_screenshot = $vShot.file }
      return
    }
  }
  throw ('VERIFY_FAILED: could not reach expected state after clicking text "' + $want + '"; attempts=' + ($attempts | ConvertTo-Json -Compress -Depth 3) + '; last_screenshot=' + $vShot.file)
}

# ── window management ──────────────────────────────────────────────────────────────
function Invoke-Window($p) {
  $action = [string]$p.action
  switch ($action) {
    'list' {
      $list = @()
      Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | ForEach-Object {
        $r = New-Object DshCu+RECT
        if ([DshCu]::GetWindowRect($_.MainWindowHandle, [ref]$r)) {
          $list += @{ pid = $_.Id; process = $_.ProcessName; title = $_.MainWindowTitle; left = $r.Left; top = $r.Top; width = $r.Right - $r.Left; height = $r.Bottom - $r.Top }
        }
      }
      Emit-Json @{ ok = $true; windows = @($list | Select-Object -First 50) }
      return
    }
    'rect' {
      $spec = $p.window
      if (-not $spec) { throw 'INVALID_ARGS: window spec required' }
      $w = Find-Window $spec
      if (-not $w) { throw 'WINDOW_NOT_FOUND' }
      Emit-Json @{ ok = $true; hwnd = $w.hwnd.ToInt64(); title = $w.title; left = $w.left; top = $w.top; width = $w.width; height = $w.height }
      return
    }
    'focus' {
      $spec = $p.window
      if (-not $spec) { throw 'INVALID_ARGS: window spec required' }
      $w = Find-Window $spec
      if (-not $w) { throw 'WINDOW_NOT_FOUND' }
      $ok = Set-TargetForeground $w
      Emit-Json @{ ok = $ok; title = $w.title; foreground = $ok }
      return
    }
    default { throw ('INVALID_ARGS: unknown window action: ' + $action) }
  }
}

# ── vision (pluggable) ─────────────────────────────────────────────────────────────
function Invoke-Vision($p, $cfg) {
  if (-not $cfg.vision.enabled) { throw 'VISION_DISABLED: pure OCR mode (set vision.enabled=true to use a vision provider)' }
  $imgPath = [string]$p.image
  if (-not $imgPath) {
    $shot = Invoke-Screen $p $cfg
    $imgPath = $shot.file
  }
  $prov = [string]$cfg.vision.provider
  $key = ''
  $keyEnv = [string]$cfg.vision.api_key_env
  if ($keyEnv) {
    $key = [Environment]::GetEnvironmentVariable($keyEnv)
    if (-not $key) {
      $credFile = Join-Path $env:USERPROFILE (Join-Path '.dsh' '.credentials.yaml')
      if (Test-Path $credFile) {
        foreach ($line in Get-Content $credFile) {
          if ($line -match ('^' + [regex]::Escape($keyEnv) + ':\s*(.+?)\s*$')) { $key = $Matches[1]; break }
        }
      }
    }
  }
  if (-not $key) { throw ('VISION_KEY_MISSING: credential ' + $keyEnv + ' not found (env or ~/.dsh/.credentials.yaml)') }
  $url = ''
  $model = ''
  switch ($prov) {
    'opencode-go' { $url = 'https://opencode.ai/zen/go/v1/chat/completions'; if (-not $model) { $model = 'mimo-v2.5' } }
    'openai-compatible' { $url = [string]$cfg.vision.base_url; if (-not $model) { $model = [string]$cfg.vision.model } }
    'gemini' { $url = 'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions'; if (-not $model) { $model = 'gemini-2.5-flash' } }
    'glm' { $url = 'https://open.bigmodel.cn/api/paas/v4/chat/completions'; if (-not $model) { $model = 'glm-4.6v-flash' } }
    default { throw ('INVALID_ARGS: unknown vision provider: ' + $prov) }
  }
  if (-not $url) { throw 'INVALID_ARGS: openai-compatible provider requires vision.base_url' }
  $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($imgPath))
  $prompt = [string]$p.prompt
  if (-not $prompt) { $prompt = '请详细描述这张屏幕截图中的界面内容。' }
  if ($cfg.vision.grounding -eq 'box') {
    $prompt = $prompt + [char]10 + '如果你在界面中看到了目标元素,请以 JSON 输出其包围盒,格式严格为 {"x1":..,"y1":..,"x2":..,"y2":..}(像素,相对整张图片左上角);如果没有,输出 null。'
  }
  $ocrText = ''
  if ($p.ocr_text) { $ocrText = [string]$p.ocr_text }
  $content = @()
  if ($ocrText) { $content += @{ type = 'text'; text = ('屏幕文字(OCR 提取,可供参考):' + [char]10 + $ocrText) } }
  $content += @{ type = 'text'; text = $prompt }
  $content += @{ type = 'image_url'; image_url = @{ url = ('data:image/png;base64,' + $b64) } }
  $bodyJson = @{
    model = $model
    messages = @(@{ role = 'user'; content = $content })
    max_tokens = 1024
    temperature = 0.1
  } | ConvertTo-Json -Depth 12
  $dir = Get-CuDir
  $stamp = Get-Date -Format 'yyyyMMddHHmmssfff'
  $reqFile = Join-Path $dir ('req-' + $stamp + '.json')
  $respFile = Join-Path $dir ('resp-' + $stamp + '.json')
  [IO.File]::WriteAllText($reqFile, $bodyJson, (Get-Utf8))
  $maxTime = [int]([Math]::Max(10, $cfg.vision.timeout_ms / 1000))
  $maxRetries = [int]$cfg.vision.max_retries
  $lastErr = ''
  for ($try = 0; $try -le $maxRetries; $try++) {
    & curl.exe -sS --max-time $maxTime -X POST $url -H ('Authorization: Bearer ' + $key) -H 'Content-Type: application/json' --data-binary ('@' + $reqFile) -o $respFile 2>$null
    if ($LASTEXITCODE -ne 0) { $lastErr = 'curl exit ' + $LASTEXITCODE; Start-Sleep -Milliseconds 800; continue }
    if (-not (Test-Path $respFile)) { $lastErr = 'no response file'; continue }
    $respJson = [IO.File]::ReadAllText($respFile, (Get-Utf8))
    $resp = $null
    try { $resp = $respJson | ConvertFrom-Json } catch { $lastErr = 'bad json response'; continue }
    if ($resp.error) { $lastErr = ($resp.error | ConvertTo-Json -Compress -Depth 5); if ($resp.error.code -eq 429 -or $resp.error.code -eq 500) { Start-Sleep -Milliseconds 1000; continue } else { break } }
    if (-not $resp.choices -or $resp.choices.Count -lt 1) { $lastErr = 'empty choices'; continue }
    $text = $resp.choices[0].message.content
    if ($text -is [System.Array]) { $text = (($text | ForEach-Object { if ($_.text) { $_.text } else { '' } }) -join '') }
    $box = $null
    if ($cfg.vision.grounding -eq 'box' -and $text) {
      $m = [regex]::Match([string]$text, '\{"x1"\s*:\s*[\d\.\-]+\s*,\s*"y1"\s*:\s*[\d\.\-]+\s*,\s*"x2"\s*:\s*[\d\.\-]+\s*,\s*"y2"\s*:\s*[\d\.\-]+\s*\}')
      if ($m.Success) { try { $box = $m.Value | ConvertFrom-Json } catch { } }
    }
    $resFile = Join-Path $dir ('vision-' + $stamp + '.json')
    $out = @{ ok = $true; provider = $prov; model = $resp.model; text = [string]$text; box = $box; image = $imgPath }
    [IO.File]::WriteAllText($resFile, ($out | ConvertTo-Json -Compress -Depth 8), (Get-Utf8))
    Emit-Json $out
    return
  }
  throw ('VISION_FAILED: ' + $lastErr)
}

# ── calibrate: verify injection path + residual offset ────────────────────────────
function Invoke-Calibrate($p, $cfg) {
  $action = [string]$p.action
  if ($action -eq 'set-offset') {
    $cfgFile = Join-Path (Get-CuDir) 'config.json'
    $cfg.coords.residual_offset = @([int]$p.dx, [int]$p.dy)
    $cfg.coords | ConvertTo-Json -Compress -Depth 6 | Set-Content -Path $cfgFile -Encoding UTF8
    Emit-Json @{ ok = $true; residual_offset = $cfg.coords.residual_offset; note = 'written to config.json' }
    return
  }
  if ($action -eq 'probe') {
    # move cursor to the requested screen point and report actual position
    [DshCu]::SetCursorPos([int]$p.x, [int]$p.y) | Out-Null
    Start-Sleep -Milliseconds 200
    $pt = New-Object DshCu+POINT
    [DshCu]::GetCursorPos([ref]$pt) | Out-Null
    Emit-Json @{ ok = $true; requested = @{ x = [int]$p.x; y = [int]$p.y }; actual = @{ x = $pt.X; y = $pt.Y }; delta = @{ x = $pt.X - [int]$p.x; y = $pt.Y - [int]$p.y } }
    return
  }
  throw ('INVALID_ARGS: calibrate action must be "probe" or "set-offset"')
}

# ── config read/write ──────────────────────────────────────────────────────────────
function Invoke-Config($p) {
  $cfgFile = Join-Path (Get-CuDir) 'config.json'
  $action = [string]$p.action
  if ($action -eq 'get') {
    $cfg = Get-Config
    # redact keys
    if ($cfg.vision) { $cfg.vision['api_key_env'] = '***' }
    Emit-Json @{ ok = $true; config_file = $cfgFile; config = $cfg }
    return
  }
  if ($action -eq 'set') {
    $cur = @{}
    if (Test-Path $cfgFile) { try { $cur = (Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { } }
    $patch = $p.patch
    foreach ($k in $patch.PSObject.Properties) { $cur | Add-Member -NotePropertyName $k.Name -NotePropertyValue $k.Value -Force }
    ($cur | ConvertTo-Json -Depth 10) | Set-Content -Path $cfgFile -Encoding UTF8
    Emit-Json @{ ok = $true; config_file = $cfgFile }
    return
  }
  throw ('INVALID_ARGS: config action must be "get" or "set"')
}

# ── dispatch ──────────────────────────────────────────────────────────────────────
$p = Get-Param
$cmd = [string]$p.cmd
$cfg = Get-Config
try {
  switch ($cmd) {
    'screen' { Emit-Json (Invoke-Screen $p $cfg) }
    'mouse' { Invoke-Mouse $p $cfg }
    'key' { Invoke-Key $p }
    'ocr' { Invoke-Ocr $p $cfg }
    'click_text' { Invoke-ClickText $p $cfg }
    'window' { Invoke-Window $p }
    'vision' { Invoke-Vision $p $cfg }
    'calibrate' { Invoke-Calibrate $p $cfg }
    'config' { Invoke-Config $p }
    'health' {
      $dpiOk = $false
      try { $dpiOk = ([DshDpi]::GetDpiForSystem() -gt 0) } catch { }
      $ocrOk = $true
      try { $e = Get-OcrEngine 'auto' } catch { $ocrOk = $false }
      Emit-Json @{ ok = $true; pwsh = $PSVersionTable.PSVersion.ToString(); dpi_aware = $dpiOk; ocr_available = $ocrOk; temp_dir = (Get-CuDir) }
    }
    default { throw ('INVALID_ARGS: unknown cmd: ' + $cmd) }
  }
} catch {
  $err = $_.Exception.Message
  Emit-Json @{ ok = $false; error = $err }
  exit 1
}
