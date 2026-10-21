<#
.SYNOPSIS
    Opens two Brave windows on monitor 1 (or the specified monitor).
.EXAMPLE
    .\Open-BraveWorkspace.ps1
.EXAMPLE
    .\Open-BraveWorkspace.ps1 -MonitorNumber 2
.EXAMPLE
    .\Open-BraveWorkspace.ps1 -ListMonitors
.NOTES
    Windows only. Existing browser windows are left open. Each run creates two
    new windows. The timer uses a normal browser window with its tab bar.
    The right window is 515 x 658 browser (DPI-scaled) pixels.
    The left window fills the available height, excluding the taskbar.
    Monitor numbers follow Windows display device names, e.g. DISPLAY1.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 99)]
    [int]$MonitorNumber = 1,
    [switch]$ListMonitors,
    [string]$BravePath
)

$ErrorActionPreference = 'Stop'

$nativeSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace BraveWorkspace {
    public class Display {
        public string Device;
        public int Left, Top, Width, Height;
        public uint Dpi;
    }

    public static class Native {
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
        public struct INFO {
            public int Size; public RECT Monitor, Work; public uint Flags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string Device;
        }

        delegate bool MonitorCallback(IntPtr monitor, IntPtr dc, IntPtr rect, IntPtr data);
        delegate bool WindowCallback(IntPtr window, IntPtr data);

        [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorCallback callback, IntPtr data);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr monitor, ref INFO info);
        [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr monitor, int kind, out uint x, out uint y);
        [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        [DllImport("user32.dll")] static extern bool EnumWindows(WindowCallback callback, IntPtr data);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder name, int count);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out RECT rect);
        [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out RECT rect, int size);
        [DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);

        public static bool PlaceVisibleWindow(IntPtr window, int x, int y, int width, int height) {
            RECT outer, visible;
            if (!GetWindowRect(window, out outer) ||
                DwmGetWindowAttribute(window, 9, out visible, Marshal.SizeOf(typeof(RECT))) != 0)
                throw new Exception("Cannot measure Brave's visible window borders.");
            int left = visible.L - outer.L, top = visible.T - outer.T;
            int right = outer.R - visible.R, bottom = outer.B - visible.B;
            return SetWindowPos(window, IntPtr.Zero, x-left, y-top,
                width+left+right, height+top+bottom, 0x0014);
        }

        public static Display[] Displays() {
            var result = new List<Display>();
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (m,d,r,p) => {
                var info = new INFO(); info.Size = Marshal.SizeOf(typeof(INFO));
                if (!GetMonitorInfo(m, ref info)) throw new Exception("Cannot read monitor information.");
                uint x,y;
                if (GetDpiForMonitor(m,0,out x,out y) != 0) x = 96;
                result.Add(new Display { Device=info.Device, Left=info.Work.L,
                    Top=info.Work.T, Width=info.Work.R-info.Work.L,
                    Height=info.Work.B-info.Work.T, Dpi=x });
                return true;
            }, IntPtr.Zero);
            return result.ToArray();
        }

        public static IntPtr[] BraveWindows() {
            var result = new List<IntPtr>();
            EnumWindows((w,d) => {
                if (!IsWindowVisible(w)) return true;
                var name = new StringBuilder(256); GetClassName(w,name,name.Capacity);
                if (name.ToString() != "Chrome_WidgetWin_1") return true;
                uint pid; GetWindowThreadProcessId(w,out pid);
                try {
                    using (var process = System.Diagnostics.Process.GetProcessById((int)pid)) {
                        if (process.ProcessName.Equals("brave",StringComparison.OrdinalIgnoreCase)) result.Add(w);
                    }
                } catch (ArgumentException) { }
                return true;
            }, IntPtr.Zero);
            return result.ToArray();
        }
    }
}
'@
# A content-based namespace lets updated helper code coexist with versions
# already loaded in this PowerShell session (Add-Type cannot replace a type).
$hasher = [System.Security.Cryptography.SHA256]::Create()
try {
    $sourceHash = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($nativeSource))).Replace('-', '')
}
finally {
    $hasher.Dispose()
}

$nativeNamespace = 'BraveWorkspace_' + $sourceHash
$native = ($nativeNamespace + '.Native') -as [type]
if (-not $native) {
    Add-Type -TypeDefinition $nativeSource.Replace('namespace BraveWorkspace {', "namespace $nativeNamespace {")
    $native = ($nativeNamespace + '.Native') -as [type]
}

function Open-WorkspaceWindow {
    param([string[]]$Urls, [int]$X, [int]$Y, [int]$Width, [int]$Height)

    $before = @($native::BraveWindows())
    # URLs are quoted individually so ampersands and other URL characters survive.
    $arguments = '--new-window ' + (($Urls | ForEach-Object { '"' + $_ + '"' }) -join ' ')
    Start-Process -FilePath $BravePath -ArgumentList $arguments | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 200
        $created = @($native::BraveWindows() | Where-Object { $_ -notin $before })
    } until ($created.Count -gt 0 -or [DateTime]::UtcNow -ge $deadline)

    if ($created.Count -ne 1) {
        throw "Expected one new Brave window; found $($created.Count). Close any first-run prompts and retry; avoid opening other Brave windows while this script runs."
    }

    $handle = $created[0]
    # Restore first in case Brave inherits a maximized state. Repeat placement
    # after startup so Chromium's saved window placement has time to settle.
    foreach ($attempt in 1..3) {
        [void]$native::ShowWindow($handle, 9)
        # Move to the target display first so border measurements use its DPI.
        if ($attempt -eq 1) {
            [void]$native::SetWindowPos($handle, [IntPtr]::Zero, $X, $Y, $Width, $Height, 0x0014)
            Start-Sleep -Milliseconds 300
        }

        if (-not $native::PlaceVisibleWindow($handle, $X, $Y, $Width, $Height)) {
            throw "Could not position Brave: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }

        Start-Sleep -Milliseconds 300
    }
}

$previousDpiContext = $native::SetThreadDpiAwarenessContext([IntPtr](-4))
try {
    $displays = @($native::Displays())
    if ($ListMonitors) {
        $displays | Select-Object @{Name = 'MonitorNumber'; Expression = { [int]($_.Device -replace '^.*DISPLAY', '') } },
        Device, Left, Top, Width, Height, Dpi | Format-Table -AutoSize
        return
    }

    $display = $displays | Where-Object { $_.Device -match ('DISPLAY' + $MonitorNumber + '$') }
    if (-not $display) {
        throw "Monitor $MonitorNumber was not found. Run with -ListMonitors to see available monitors."
    }

    if (-not $BravePath) {
        $candidates = @(
            "${env:ProgramFiles}\BraveSoftware\Brave-Browser\Application\brave.exe"
            "${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser\Application\brave.exe"
            "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe"
        )

        $BravePath = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if (-not $BravePath) {
            throw 'Brave was not found. Supply -BravePath with the full path to brave.exe.'
        }
    }

    $rightWidth = [int][Math]::Round(515 * $display.Dpi / 96.0)
    $rightHeight = [int][Math]::Round(658 * $display.Dpi / 96.0)
    $leftWidth = $display.Width - $rightWidth
    if ($leftWidth -lt 500 * $display.Dpi / 96.0 -or $rightHeight -gt $display.Height) {
        throw 'The selected monitor is too small for this layout at its current scaling.'
    }

    # A cold launch normally applies Brave's startup/session-restore settings.
    # Initialize the browser without a startup window before requesting our
    # explicit windows, so tabs from the previous session aren't restored here.
    if (-not (Get-Process -Name brave -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath $BravePath -ArgumentList '--no-startup-window' | Out-Null
        $startupDeadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            Start-Sleep -Milliseconds 200
            $browserProcesses = @(Get-Process -Name brave -ErrorAction SilentlyContinue)
        } until ($browserProcesses.Count -gt 0 -or [DateTime]::UtcNow -ge $startupDeadline)

        if ($browserProcesses.Count -eq 0) {
            throw 'Brave did not start within 30 seconds.'
        }

        # Allow profile initialization to finish before the next launch request.
        Start-Sleep -Seconds 2
    }

    Open-WorkspaceWindow -Urls @(
        'https://mail.google.com/mail/u/0/#inbox'
        'https://docs.google.com/spreadsheets/d/1RlJTrdOS0S42WohewQlYB8dMo1PjNo8VfuVwAa53IdU/edit?gid=1149591132#gid=1149591132'
        'https://www.codewars.com/kata/search/go?q=&r%5B%5D=-5&xids=completed&beta=false&order_by=popularity%20desc'
    ) -X $display.Left -Y $display.Top -Width $leftWidth -Height $display.Height

    Open-WorkspaceWindow -Urls @('https://timers.richarddotparker.workers.dev/') `
        -X ($display.Left + $leftWidth) -Y $display.Top -Width $rightWidth -Height $rightHeight

    Write-Host "Opened Brave workspace on monitor $MonitorNumber."
}
finally {
    if ($previousDpiContext -ne [IntPtr]::Zero) {
        [void]$native::SetThreadDpiAwarenessContext($previousDpiContext)
    }
}
