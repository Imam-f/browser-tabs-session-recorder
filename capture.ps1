# Browser tab capture: iterates every Helium and Google Chrome window on every virtual desktop,
# selects each tab, pauses any playing media (Windows media session API),
# screenshots the window, then clicks the "Tab Freezer" extension before
# moving to the next window. Output: tabs.md + screenshots/*.jpg
# Run with Windows PowerShell 5.1 (WinRT media API).

param(
    [ValidateSet('All', 'Helium', 'Chrome')]
    [string]$Browser = 'All',
    [int64]$OnlyHwnd = 0   # for testing: process a single window
)
$ErrorActionPreference = 'Continue'
$OutDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ShotDir = Join-Path $OutDir 'screenshots'

# Website loading delays. Increase these if screenshots are taken before pages finish rendering.
$ActiveTabLoadDelayMs = 900
$InactiveTabLoadDelayMs = 3000
$PageLoadTimeoutMs = 6000

New-Item -ItemType Directory -Force -Path $ShotDir | Out-Null

Import-Module VirtualDesktop 3>$null
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing, System.Windows.Forms
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType=WindowsRuntime]

Add-Type -Namespace X -Name U -MemberDefinition @'
public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
[DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr i);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
public struct RECT { public int L, T, R, B; }
'@

$ae = [System.Windows.Automation.AutomationElement]
$ts = [System.Windows.Automation.TreeScope]
function Cond($prop, $val) { New-Object System.Windows.Automation.PropertyCondition($prop, $val) }
function Log($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

function Activate-Window($hwnd) {
    # Restore if minimized, then force foreground (Alt keypress defeats the foreground lock).
    $h = [IntPtr]$hwnd
    if ([X.U]::IsIconic($h)) { [X.U]::ShowWindow($h, 9) | Out-Null; Start-Sleep -Milliseconds 500 }
    for ($i = 0; $i -lt 3; $i++) {
        [X.U]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [X.U]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
        [X.U]::SetForegroundWindow($h) | Out-Null
        [X.U]::BringWindowToTop($h) | Out-Null
        Start-Sleep -Milliseconds 250
        if ([X.U]::GetForegroundWindow() -eq $h) { return $true }
    }
    return ([X.U]::GetForegroundWindow() -eq $h)
}

# ---------- media session helpers ----------
$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, $type) { $t = $asTask.MakeGenericMethod($type).Invoke($null, @($op)); $t.Wait(5000) | Out-Null; $t.Result }
$MgrType   = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]
$PropsType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties]

function Pause-BrowserMedia {
    # Returns list of titles that were playing and got paused. Loops because Chromium
    # surfaces one active session at a time; pausing one may reveal another.
    $paused = @()
    for ($i = 0; $i -lt 4; $i++) {
        $found = $false
        try {
            $mgr = Await ($MgrType::RequestAsync()) $MgrType
            foreach ($s in $mgr.GetSessions()) {
                if ($s.SourceAppUserModelId -notmatch $script:MediaAppPattern) { continue }
                if ($s.GetPlaybackInfo().PlaybackStatus -ne 'Playing') { continue }
                $found = $true
                $title = try { (Await ($s.TryGetMediaPropertiesAsync()) $PropsType).Title } catch { '?' }
                $ok = Await ($s.TryPauseAsync()) ([bool])
                $paused += "$title" + $(if (-not $ok) { ' (pause rejected)' })
                Log "    paused media: $title"
            }
        } catch { Log "    media api error: $($_.Exception.Message)" }
        if (-not $found) { break }
        Start-Sleep -Milliseconds 500
    }
    return $paused
}

# ---------- window helpers ----------
function Get-BrowserWindows {
    $list = New-Object System.Collections.ArrayList
    $cb = [X.U+EnumWindowsProc]{
        param($h, $l)
        $c = New-Object System.Text.StringBuilder 256; [X.U]::GetClassName($h, $c, 256) | Out-Null
        if ($c.ToString() -eq 'Chrome_WidgetWin_1' -and [X.U]::IsWindowVisible($h)) {
            $t = New-Object System.Text.StringBuilder 1024; [X.U]::GetWindowText($h, $t, 1024) | Out-Null
            $title = $t.ToString()
            [uint32]$procId = 0; [X.U]::GetWindowThreadProcessId($h, [ref]$procId) | Out-Null
            $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
            $definition = $script:BrowserDefinitions | Where-Object {
                $p -and $p.ProcessName -ieq $_.ProcessName -and
                ($title -eq $_.Name -or $title.EndsWith($_.TitleSuffix, [StringComparison]::OrdinalIgnoreCase))
            } | Select-Object -First 1
            if ($definition) {
                $windowTitle = $title
                if ($windowTitle -eq $definition.Name) {
                    $windowTitle = 'New Tab'
                } elseif ($windowTitle.EndsWith($definition.TitleSuffix, [StringComparison]::OrdinalIgnoreCase)) {
                    $windowTitle = $windowTitle.Substring(0, $windowTitle.Length - $definition.TitleSuffix.Length)
                }
                $null = $list.Add([pscustomobject]@{
                    Hwnd = [int64]$h
                    Title = $windowTitle
                    Browser = $definition.Name
                })
            }
        }
        $true
    }
    [X.U]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list
}

function Get-DesktopInfo($hwnd) {
    try {
        $d = Get-DesktopFromWindow -Hwnd $hwnd
        $idx = Get-DesktopIndex -Desktop $d
        return [pscustomobject]@{ Index = $idx; Name = (Get-DesktopName -Desktop $d) }
    } catch { return [pscustomobject]@{ Index = 999; Name = 'Unknown desktop' } }
}

function Clean-TabName($n) {
    $prev = $null
    while ($n -ne $prev) {
        $prev = $n
        $n = $n -replace ' - (Audio playing|Audio muted|Inactive tab|Media recording|Camera and microphone recording|Playing in picture-in-picture|Memory usage - [\d.,]+ [KMG]?B)$', ''
    }
    return $n.Trim()
}

function Reveal-Toolbar($hwnd) {
    # This reveals Helium's auto-hidden toolbar and is harmless when Chrome's toolbar is visible.
    $r = New-Object X.U+RECT; [X.U]::GetWindowRect([IntPtr]$hwnd, [ref]$r) | Out-Null
    $x = [int](($r.L + $r.R) / 2); $y = [Math]::Max(0, $r.T + 2)
    [X.U]::SetCursorPos($x, $y) | Out-Null
    Start-Sleep -Milliseconds 1200
}

function Click-Element($el) {
    $b = $el.Current.BoundingRectangle
    if ($b.IsEmpty -or $b.Y -lt 0) { return $false }
    [X.U]::SetCursorPos([int]($b.X + $b.Width / 2), [int]($b.Y + $b.Height / 2)) | Out-Null
    Start-Sleep -Milliseconds 150
    [X.U]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero); [X.U]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
    return $true
}

function Wait-PageLoad($win, $maxMs) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Milliseconds 400
        $btn = $win.FindFirst($ts::Descendants, (Cond $ae::ClassNameProperty 'ReloadButton'))
        if (-not $btn -or $btn.Current.Name -ne 'Stop') { break }
    } while ($sw.ElapsedMilliseconds -lt $maxMs)
}

function Save-Screenshot($hwnd, $path) {
    $r = New-Object X.U+RECT; [X.U]::GetWindowRect([IntPtr]$hwnd, [ref]$r) | Out-Null
    $scr = [System.Windows.Forms.Screen]::FromHandle([IntPtr]$hwnd).WorkingArea
    $x1 = [Math]::Max($r.L, $scr.Left); $y1 = [Math]::Max($r.T, $scr.Top)
    $x2 = [Math]::Min($r.R, $scr.Right); $y2 = [Math]::Min($r.B, $scr.Bottom)
    $w = $x2 - $x1; $h = $y2 - $y1
    if ($w -le 0 -or $h -le 0) { return $false }
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x1, $y1, 0, 0, $bmp.Size)
    $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg'
    $ep = New-Object System.Drawing.Imaging.EncoderParameters 1
    $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality, [long]82)
    $bmp.Save($path, $codec, $ep)
    $g.Dispose(); $bmp.Dispose()
    return $true
}

# ---------- main ----------
$allBrowserDefinitions = @(
    [pscustomobject]@{ Key = 'Helium'; Name = 'Helium'; ProcessName = 'helium'; TitleSuffix = ' - Helium'; MediaPattern = 'Helium' }
    [pscustomobject]@{ Key = 'Chrome'; Name = 'Google Chrome'; ProcessName = 'chrome'; TitleSuffix = ' - Google Chrome'; MediaPattern = 'Chrome' }
)
$script:BrowserDefinitions = if ($Browser -eq 'All') { $allBrowserDefinitions } else { @($allBrowserDefinitions | Where-Object Key -eq $Browser) }
$script:MediaAppPattern = '({0})' -f (($script:BrowserDefinitions | ForEach-Object MediaPattern) -join '|')

$origDesktop = Get-CurrentDesktop
$origFg = [X.U]::GetForegroundWindow()
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
# Minimize the OpenCode window so it never overlaps screenshots; restored at the end.
$opencodeHwnd = 0
$ocCond = New-Object System.Windows.Automation.AndCondition((Cond $ae::ClassNameProperty 'Chrome_WidgetWin_1'), (Cond $ae::NameProperty 'OpenCode'))
$oc = $ae::RootElement.FindFirst($ts::Children, $ocCond)
if ($oc) { $opencodeHwnd = $oc.Current.NativeWindowHandle; [X.U]::ShowWindow([IntPtr]$opencodeHwnd, 6) | Out-Null; Log "Minimized OpenCode window $opencodeHwnd" }

$windows = Get-BrowserWindows
if ($OnlyHwnd) { $windows = @($windows | Where-Object Hwnd -eq $OnlyHwnd) }
foreach ($w in $windows) { $di = Get-DesktopInfo $w.Hwnd; $w | Add-Member DesktopIndex $di.Index; $w | Add-Member DesktopName $di.Name }
Log "Found $($windows.Count) supported browser windows"

$results = @()   # per tab records
$totalTabs = 0
$groups = $windows | Group-Object DesktopIndex | Sort-Object { [int]$_.Name }

foreach ($grp in $groups) {
    $dIdx = [int]$grp.Name
    if ($dIdx -ne 999) {
        Log "=== Switching to desktop index $dIdx ($($grp.Group[0].DesktopName)) ==="
        try { Switch-Desktop -Desktop (Get-Desktop -Index $dIdx) } catch { Log "  switch failed: $($_.Exception.Message)" }
        Start-Sleep -Milliseconds 900
    }
    $wIdx = 0
    foreach ($w in $grp.Group) {
        $wIdx++
        Log "--- Window $($w.Hwnd): $($w.Title)"
        $h = [IntPtr]$w.Hwnd
        $wasIconic = [X.U]::IsIconic($h)
        $fgOk = Activate-Window $w.Hwnd
        if (-not $fgOk) { Log "  WARNING: could not bring window to foreground" }
        Start-Sleep -Milliseconds 400

        $win = $null
        try { $win = $ae::FromHandle($h) } catch { Log "  UIA FromHandle failed: $($_.Exception.Message)"; continue }
        $tabs = @($win.FindAll($ts::Descendants, (Cond $ae::ClassNameProperty 'Tab')))
        Log "  $($tabs.Count) tabs"
        $origSelected = $null
        foreach ($t in $tabs) {
            try { if ($t.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected) { $origSelected = $t } } catch {}
        }

        $tIdx = 0
        foreach ($t in $tabs) {
            $tIdx++; $totalTabs++
            $rawName = $t.Current.Name
            $wasInactive = $rawName -match 'Inactive tab'
            $audioFlag = $rawName -match 'Audio playing'
            # select the tab
            $selected = $false
            try { $t.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select(); $selected = $true } catch {}
            if (-not $selected) { Reveal-Toolbar $w.Hwnd; $selected = Click-Element $t }
            Start-Sleep -Milliseconds $(if ($wasInactive) { $InactiveTabLoadDelayMs } else { $ActiveTabLoadDelayMs })
            Wait-PageLoad $win $PageLoadTimeoutMs

            # pause any playing media (this tab or another selected browser tab); re-check once since
            # reloaded pages (e.g. YouTube) often start playback a moment after load
            $paused = @(Pause-BrowserMedia)
            Start-Sleep -Milliseconds 700
            $paused += Pause-BrowserMedia
            $nowName = try { $t.Current.Name } catch { $rawName }
            if ($nowName -match 'Audio playing') {
                Start-Sleep -Milliseconds 600
                $paused += Pause-BrowserMedia
                $nowName = try { $t.Current.Name } catch { $nowName }
            }
            $paused = @($paused | Select-Object -Unique)
            $stillPlaying = $nowName -match 'Audio playing'

            $url = ''
            try {
                $omni = $win.FindFirst($ts::Descendants, (Cond $ae::ClassNameProperty 'OmniboxViewViews'))
                if ($omni) { $url = $omni.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value }
            } catch {}

            # make sure the window is still frontmost, park cursor bottom-right so no hover overlays, then shoot
            if ([X.U]::GetForegroundWindow() -ne $h -or [X.U]::IsIconic($h)) { Activate-Window $w.Hwnd | Out-Null; Start-Sleep -Milliseconds 400 }
            [X.U]::SetCursorPos($screen.Right - 2, $screen.Bottom - 2) | Out-Null; Start-Sleep -Milliseconds 350
            $file = 'd{0}_w{1}_t{2:d2}.jpg' -f $dIdx, $w.Hwnd, $tIdx
            $ok = Save-Screenshot $w.Hwnd (Join-Path $ShotDir $file)
            $title = Clean-TabName $nowName
            Log "  [$tIdx/$($tabs.Count)] $title  $(if($audioFlag){'[audio]'})"
            $results += [pscustomobject]@{
                DesktopIndex = $dIdx; DesktopName = $w.DesktopName; Hwnd = $w.Hwnd; WindowTitle = $w.Title; Browser = $w.Browser
                TabIndex = $tIdx; Title = $title; Url = $url; WasInactive = $wasInactive
                AudioWasPlaying = $audioFlag; Paused = ($paused -join '; '); StillPlaying = $stillPlaying
                Screenshot = $(if ($ok) { "screenshots/$file" } else { '' }); Selected = $selected
            }
        }

        # restore the originally selected tab, then freeze the window via Tab Freezer
        if ($origSelected) { try { $origSelected.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select(); Start-Sleep -Milliseconds 700 } catch {} }
        $froze = $false
        for ($try = 0; $try -lt 2 -and -not $froze; $try++) {
            if ([X.U]::GetForegroundWindow() -ne $h -or [X.U]::IsIconic($h)) { Activate-Window $w.Hwnd | Out-Null }
            Reveal-Toolbar $w.Hwnd
            $fz = $win.FindFirst($ts::Descendants, (Cond $ae::NameProperty 'Tab Freezer'))
            if ($fz) { $froze = Click-Element $fz }
        }
        Log "  Tab Freezer clicked: $froze"
        Start-Sleep -Milliseconds 800
        Pause-BrowserMedia | Out-Null
        if ($wasIconic) { [X.U]::ShowWindow($h, 6) | Out-Null }
    }
}

# restore user's context
try { Switch-Desktop -Desktop $origDesktop } catch {}
Start-Sleep -Milliseconds 500
if ($opencodeHwnd) { [X.U]::ShowWindow([IntPtr]$opencodeHwnd, 9) | Out-Null }
Activate-Window ([int64]$origFg) | Out-Null

# ---------- markdown ----------
$sb = New-Object System.Text.StringBuilder
$null = $sb.AppendLine("# Browser Tabs Session Recorder - $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
$null = $sb.AppendLine()
$null = $sb.AppendLine("**$($groups.Count) virtual desktops, $($windows.Count) windows, $totalTabs tabs.** Screenshots in ``screenshots/``. Every tab was visited and playing browser media was paused via the Windows media session API.")
$null = $sb.AppendLine()
$null = $sb.AppendLine("## Contents")
foreach ($g in ($results | Group-Object DesktopIndex | Sort-Object { [int]$_.Name })) {
    $dn = $g.Group[0].DesktopName; $wc = @($g.Group | Select-Object -ExpandProperty Hwnd -Unique).Count
    $null = $sb.AppendLine("- [$dn](#$(($dn -replace '[^a-zA-Z0-9 ]','' -replace ' ','-').ToLower())) - $wc windows, $($g.Count) tabs")
}
$null = $sb.AppendLine()
foreach ($g in ($results | Group-Object DesktopIndex | Sort-Object { [int]$_.Name })) {
    $null = $sb.AppendLine("## $($g.Group[0].DesktopName)")
    $null = $sb.AppendLine()
    foreach ($wg in ($g.Group | Group-Object Hwnd)) {
        $first = $wg.Group[0]
        $null = $sb.AppendLine("### Window: $($first.WindowTitle) ($($first.Browser), hwnd $($first.Hwnd), $($wg.Count) tabs)")
        $null = $sb.AppendLine()
        foreach ($r in ($wg.Group | Sort-Object TabIndex)) {
            $null = $sb.AppendLine("#### $($r.TabIndex). $($r.Title)")
            $null = $sb.AppendLine()
            if ($r.Url) { $null = $sb.AppendLine("- URL: ``$($r.Url)``") }
            $flags = @()
            if ($r.AudioWasPlaying) { $flags += 'audio was playing' }
            if ($r.Paused) { $flags += "paused: $($r.Paused)" }
            if ($r.StillPlaying) { $flags += 'WARNING: still flagged as playing after pause attempt' }
            if ($r.WasInactive) { $flags += 'was frozen/discarded before visit' }
            if (-not $r.Selected) { $flags += 'WARNING: tab could not be selected' }
            if ($flags.Count) { $null = $sb.AppendLine("- Notes: $($flags -join '; ')") }
            $null = $sb.AppendLine()
            if ($r.Screenshot) { $null = $sb.AppendLine("![$($r.Title)]($($r.Screenshot))") } else { $null = $sb.AppendLine("_(screenshot failed)_") }
            $null = $sb.AppendLine()
        }
    }
}
[IO.File]::WriteAllText((Join-Path $OutDir 'tabs.md'), $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))
$results | Export-Csv -Path (Join-Path $OutDir 'tabs.csv') -NoTypeInformation -Encoding UTF8
Log "DONE. $totalTabs tabs across $($windows.Count) windows -> tabs.md"
