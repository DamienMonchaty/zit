# Zit's footprint on Windows, measured rather than supposed — what
# tools/measure.sh reads from /proc on Linux, read here from the kernel
# (NtQuerySystemInformation), which the localized performance counters'
# names would not let a script do the same way on every machine.
#
#   tools/measure.ps1 [-Exe zig-out\bin\zit.exe] [-Repo .] [-Settle 40] [-Idle 20]
#                     [-Focus] [-Renderer direct3d11|direct3d12|vulkan|opengl|gpu]
#                     [-Cache dir] [-Out results.tsv]
#
# Config and cache are throwaway, as in measure.sh; -Cache keeps the cache,
# with its pictures, between runs. -Focus brings the window to the front for
# the idle window — Zit polls more often when it has the keyboard where it
# cannot watch — and the seconds it really had it are printed. Working set
# is the RSS; private working set the part that is Zit's alone; commit what
# it has asked the system to guarantee, touched or not. Wake-ups are every
# thread's context switches. Fails when idle CPU is over -MaxIdleCpu, the
# ceiling in docs/PERF.md.
param(
    [string]$Exe = 'zig-out\bin\zit.exe',
    [string]$Repo = '.',
    [int]$Settle = 40,
    [int]$Idle = 20,
    [switch]$Focus,
    [string]$Renderer = '',
    [string]$Cache = '',
    [string]$Out = '',
    [double]$MaxIdleCpu = 0.5
)
$ErrorActionPreference = 'Stop'
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class ZitMeasure {
    [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int ret);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern void SwitchToThisWindow(IntPtr h, bool alt);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    public static bool Foreground(int pid) { uint p; GetWindowThreadProcessId(GetForegroundWindow(), out p); return p == (uint)pid; }
    public static void Raise(IntPtr h) { SwitchToThisWindow(h, true); SetForegroundWindow(h); }
    public class Snap {
        public long Time, WS, PeakWS, PrivWS, Commit; public int Threads;
        public Dictionary<long, long> Switches = new Dictionary<long, long>();
    }
    // SYSTEM_PROCESS_INFORMATION and its SYSTEM_THREAD_INFORMATIONs, x64.
    public static Snap Get(int pid) {
        int len = 1 << 20; IntPtr buf;
        for (;;) {
            buf = Marshal.AllocHGlobal(len); int ret;
            int st = NtQuerySystemInformation(5, buf, len, out ret);
            if (st == 0) break;
            Marshal.FreeHGlobal(buf);
            if ((uint)st != 0xC0000004) throw new Exception("NtQuerySystemInformation " + st.ToString("X"));
            len = Math.Max(len * 2, ret + 65536);
        }
        try {
            long off = 0;
            for (;;) {
                IntPtr p = new IntPtr(buf.ToInt64() + off);
                int next = Marshal.ReadInt32(p, 0);
                if (Marshal.ReadInt64(p, 0x50) == pid) {
                    var s = new Snap();
                    s.Threads = Marshal.ReadInt32(p, 0x04);
                    s.PrivWS = Marshal.ReadInt64(p, 0x08);
                    s.Time = Marshal.ReadInt64(p, 0x28) + Marshal.ReadInt64(p, 0x30);
                    s.PeakWS = Marshal.ReadInt64(p, 0x88);
                    s.WS = Marshal.ReadInt64(p, 0x90);
                    s.Commit = Marshal.ReadInt64(p, 0xB8);
                    for (int i = 0; i < s.Threads; i++) {
                        IntPtr t = new IntPtr(p.ToInt64() + 0x100 + i * 0x50);
                        s.Switches[Marshal.ReadInt64(t, 0x30)] = (uint)Marshal.ReadInt32(t, 0x40);
                    }
                    return s;
                }
                if (next == 0) return null;
                off += next;
            }
        } finally { Marshal.FreeHGlobal(buf); }
    }
}
'@

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("zit-measure-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force "$tmp\config" | Out-Null
$env:APPDATA = "$tmp\config"
$env:LOCALAPPDATA = if ($Cache) { $Cache } else { "$tmp\cache" }
if ($Renderer) { $env:SDL_RENDER_DRIVER = $Renderer }

$repoPath = (Resolve-Path $Repo).Path
$proc = Start-Process -FilePath (Resolve-Path $Exe).Path -ArgumentList "`"$repoPath`"" -WorkingDirectory $repoPath -PassThru
try {
    Start-Sleep -Seconds $Settle
    if ($proc.HasExited) { throw "zit exited during start-up (code $($proc.ExitCode))" }
    if ($Focus) {
        $proc.Refresh()
        [ZitMeasure]::Raise($proc.MainWindowHandle)
        Start-Sleep -Seconds 3
    }

    $a = [ZitMeasure]::Get($proc.Id)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $focused = 0
    for ($i = 0; $i -lt $Idle; $i++) {
        Start-Sleep -Seconds 1
        if ([ZitMeasure]::Foreground($proc.Id)) { $focused++ }
    }
    $b = [ZitMeasure]::Get($proc.Id)
    $secs = $clock.Elapsed.TotalSeconds
    if ($null -eq $b) { throw "zit exited while idle" }

    $switches = 0
    foreach ($tid in $b.Switches.Keys) {
        $switches += $b.Switches[$tid] - $(if ($a.Switches.ContainsKey($tid)) { $a.Switches[$tid] } else { 0 })
    }
    $cpu = ($b.Time - $a.Time) / 1e7 / $secs * 100
    $mb = { param($v) [math]::Round($v / 1MB, 1) }
    $row = [ordered]@{
        repository = $repoPath
        commits = (git -C $repoPath rev-list --all --count 2>$null)
        renderer = $(if ($Renderer) { $Renderer } else { 'default' })
        focused = "$focused/$Idle s"
        idle_cpu_pct = [math]::Round($cpu, 2)
        wakeups_per_s = [math]::Round($switches / $secs, 1)
        working_set_mb = & $mb $b.WS
        peak_working_set_mb = & $mb $b.PeakWS
        private_working_set_mb = & $mb $b.PrivWS
        commit_mb = & $mb $b.Commit
        threads = $b.Threads
    }
    [pscustomobject]$row | Format-List
    if ($Out) {
        if (-not (Test-Path $Out)) { ($row.Keys -join "`t") | Out-File -Encoding utf8 $Out }
        ($row.Values -join "`t") | Out-File -Append -Encoding utf8 $Out
    }
    if ($cpu -gt $MaxIdleCpu) { Write-Output "over: idle CPU (ceiling $MaxIdleCpu %)"; exit 1 }
} finally {
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force; $proc.WaitForExit(5000) | Out-Null }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
