# wt-layout.ps1 - Windows Terminal layout save/restore.
# Dot-sourced from Microsoft.PowerShell_profile.ps1.
#
#   wtsave <name>      Capture the focused WT window's layout to a named file.
#   wtrestore <name>   Open a new WT window from a named layout file.
#   wtlayouts          List saved layout names.
#
# Layout files live in ~/.config/wt-layouts/ as human-readable JSON. Each pane
# has an editable `cwd` field (empty = profile default, non-empty = pinned dir).

# ---------------------------------------------------------------------------
# U1. Layout data model and file I/O
# ---------------------------------------------------------------------------

# Directory for saved layouts (machine-local runtime data, not in the repo).
function Get-WtLayoutDir {
    Join-Path (Join-Path $HOME '.config') 'wt-layouts'
}

<#
.SYNOPSIS
    Resolve the file path for a named layout.
#>
function Get-WtLayoutPath {
    param([Parameter(Mandatory)] [string]$Name)
    if ($Name -notmatch '^[A-Za-z0-9._-]+$') {
        throw "Invalid layout name '$Name'. Use letters, digits, dot, underscore, or hyphen."
    }
    Join-Path (Get-WtLayoutDir) "$Name.json"
}

<#
.SYNOPSIS
    Write a layout object to a named file.
.DESCRIPTION
    Creates the layouts directory on first use and serialises the layout as
    indented (human-readable) JSON. Overwrites an existing name.
#>
function Save-WtLayoutFile {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] $Layout
    )
    $dir = Get-WtLayoutDir
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $path = Get-WtLayoutPath -Name $Name
    $json = $Layout | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
}

<#
.SYNOPSIS
    Read a named layout file into a PSCustomObject.
#>
function Read-WtLayoutFile {
    param([Parameter(Mandatory)] [string]$Name)
    $path = Get-WtLayoutPath -Name $Name
    if (-not (Test-Path $path)) {
        throw "No layout named '$Name'. Run 'wtsave $Name' first, or use 'wtlayouts' to list saved layouts."
    }
    Get-Content $path -Raw | ConvertFrom-Json
}

<#
.SYNOPSIS
    List the names of saved layouts.
.DESCRIPTION
    Returns layout names (without extension) from the layouts directory,
    or an empty array when the directory does not exist yet.
#>
function List-WtLayouts {
    $dir = Get-WtLayoutDir
    if (-not (Test-Path $dir)) { return @() }
    $items = Get-ChildItem -Path $dir -Filter '*.json' -File -ErrorAction SilentlyContinue
    if (-not $items) { return @() }
    $items | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) }
}

# ---------------------------------------------------------------------------
# U3. Rectangle-to-split-tree reconstruction
# ---------------------------------------------------------------------------
# Given a flat list of pane rectangles (from UIA capture), build the recursive
# split tree that WT uses internally: every node is a binary split (direction +
# ratio) or a leaf referencing a pane index.
#
# WT splits are binary: each split divides one region into two axis-aligned
# halves. The rectangles tile without overlap, so the nesting can be recovered
# by recursive bisection -- find the clean dividing line that partitions the
# group into two contiguous sub-groups, recurse on each, and stop at a single
# rectangle (a leaf).

<#
.SYNOPSIS
    Build a single-pane layout leaf node.
#>
function New-WtLeaf {
    param([int]$PaneIndex)
    [pscustomobject]@{ pane = $PaneIndex }
}

<#
.SYNOPSIS
    Build a split node linking two child subtrees.
#>
function New-WtSplitNode {
    param(
        [ValidateSet('vertical', 'horizontal')] [string]$Split,
        [double]$Ratio,
        $First,
        $Second
    )
    [pscustomobject]@{
        split  = $Split
        ratio  = $Ratio
        first  = $First
        second = $Second
    }
}

<#
.SYNOPSIS
    Try to partition a group of indexed rectangles by a vertical dividing line.
.DESCRIPTION
    A "vertical" split (in wt.exe terms `-V`) creates a left/right pair, so the
    dividing line is a vertical x-threshold. Returns the two sub-groups (indices
    preserved) and the split ratio if a clean partition is found.
#>
function Test-WtVerticalSplit {
    param([Parameter(Mandatory)] [object[]]$Group)
    # A clean vertical line means some rectangles end (right edge) exactly where
    # others begin (left edge). Gather all distinct right-edges as candidates.
    $candidates = @($Group | ForEach-Object { [double]($_.Rect.X + $_.Rect.Width) } | Sort-Object -Unique)
    foreach ($lineX in $candidates) {
        $leftGroup  = @($Group | Where-Object { ($_.Rect.X + $_.Rect.Width) -le ($lineX + 1) })
        $rightGroup = @($Group | Where-Object { $_.Rect.X -ge ($lineX - 1) })
        # Clean partition: every rectangle is in exactly one side, both non-empty.
        if ($leftGroup.Count -gt 0 -and $rightGroup.Count -gt 0 -and
            ($leftGroup.Count + $rightGroup.Count) -eq $Group.Count) {
            # Ratio = second (right) group proportion; wt.exe -s is the NEW pane's size.
            $minX = ($Group | ForEach-Object { $_.Rect.X } | Measure-Object -Minimum).Minimum
            $maxX = ($Group | ForEach-Object { $_.Rect.X + $_.Rect.Width } | Measure-Object -Maximum).Maximum
            $totalWidth = $maxX - $minX
            $ratio = if ($totalWidth -gt 0) { ($maxX - $lineX) / $totalWidth } else { 0.5 }
            return @{
                Found  = $true
                Split  = 'vertical'
                Ratio  = $ratio
                First  = $leftGroup
                Second = $rightGroup
            }
        }
    }
    return @{ Found = $false }
}

<#
.SYNOPSIS
    Try to partition a group of indexed rectangles by a horizontal dividing line.
.DESCRIPTION
    A "horizontal" split (wt.exe `-H`) creates a top/bottom pair, so the
    dividing line is a horizontal y-threshold.
#>
function Test-WtHorizontalSplit {
    param([Parameter(Mandatory)] [object[]]$Group)
    $candidates = @($Group | ForEach-Object { [double]($_.Rect.Y + $_.Rect.Height) } | Sort-Object -Unique)
    foreach ($lineY in $candidates) {
        $topGroup    = @($Group | Where-Object { ($_.Rect.Y + $_.Rect.Height) -le ($lineY + 1) })
        $bottomGroup = @($Group | Where-Object { $_.Rect.Y -ge ($lineY - 1) })
        if ($topGroup.Count -gt 0 -and $bottomGroup.Count -gt 0 -and
            ($topGroup.Count + $bottomGroup.Count) -eq $Group.Count) {
            $minY = ($Group | ForEach-Object { $_.Rect.Y } | Measure-Object -Minimum).Minimum
            $maxY = ($Group | ForEach-Object { $_.Rect.Y + $_.Rect.Height } | Measure-Object -Maximum).Maximum
            $totalHeight = $maxY - $minY
            $ratio = if ($totalHeight -gt 0) { ($maxY - $lineY) / $totalHeight } else { 0.5 }
            return @{
                Found  = $true
                Split  = 'horizontal'
                Ratio  = $ratio
                First  = $topGroup
                Second = $bottomGroup
            }
        }
    }
    return @{ Found = $false }
}

<#
.SYNOPSIS
    Recursively bisect a group of indexed rectangles into a split tree.
.DESCRIPTION
    Stops at a single rectangle (leaf). Prefers a vertical dividing line, then
    horizontal; falls back to the first element if no clean partition exists
    (defensive -- rectangles from a real WT window always partition cleanly).
#>
function ConvertTo-WtSplitTree {
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [object[]]$Group)

    if ($Group.Count -eq 1) {
        return New-WtLeaf -PaneIndex $Group[0].Index
    }

    $v = Test-WtVerticalSplit -Group $Group
    if ($v.Found) {
        return New-WtSplitNode -Split $v.Split -Ratio $v.Ratio `
            -First  (ConvertTo-WtSplitTree -Group $v.First) `
            -Second (ConvertTo-WtSplitTree -Group $v.Second)
    }

    $h = Test-WtHorizontalSplit -Group $Group
    if ($h.Found) {
        return New-WtSplitNode -Split $h.Split -Ratio $h.Ratio `
            -First  (ConvertTo-WtSplitTree -Group $h.First) `
            -Second (ConvertTo-WtSplitTree -Group $h.Second)
    }

    # No clean partition found -- treat as a single pane (best-effort fallback).
    return New-WtLeaf -PaneIndex $Group[0].Index
}

# ---------------------------------------------------------------------------
# U4. Restore -- split-tree to wt.exe command generator
# ---------------------------------------------------------------------------
# Translate a layout file into a wt.exe command line. wt.exe builds a window
# from left to right: `new-tab` creates the first pane of each tab, then
# `split-pane` divides the focused pane. A newly created pane receives focus,
# so the generator walks each tab's split tree in pre-order DFS -- emit the
# first pane, split to create the sibling (now focused), recurse the sibling
# subtree, then `move-focus` back to continue splitting the original branch.

<#
.SYNOPSIS
    Build a single pane's argument fragment.
.DESCRIPTION
    Emits `-p <profile>` and `-d <cwd>` (only when cwd is non-empty).
#>
function Get-WtPaneArgs {
    param([Parameter(Mandatory)] $Pane)
    $a = @("-p `"$($Pane.profile)`"")
    if ($Pane.cwd) {
        $a += "-d `"$($Pane.cwd)`""
    }
    $a -join ' '
}

<#
.SYNOPSIS
    Resolve a tree node down to the pane index of its first (leftmost) leaf.
#>
function Resolve-WtLeafIndex {
    param($Node)
    $cur = $Node
    while ($null -eq $cur.pane) {
        $cur = $cur.first
    }
    return [int]$cur.pane
}

<#
.SYNOPSIS
    Emit a split-pane for the sibling, recurse its subtree, then move-focus back.
.DESCRIPTION
    wt.exe split-pane flags: -V splits left/right (new pane on right),
    -H splits top/bottom (new pane on bottom). -s is the new pane's size
    relative to the pane being split.
#>
function Add-WtSplitAndRecurse {
    param(
        $Node,
        $Panes,
        [System.Collections.Generic.List[string]]$Sink
    )
    $flag = if ($Node.split -eq 'vertical') { '-V' } else { '-H' }
    $ratioStr = '{0:0.###}' -f $Node.ratio
    $secondPane = $Panes[[int](Resolve-WtLeafIndex -Node $Node.second)]
    $Sink.Add("split-pane $flag -s $ratioStr $(Get-WtPaneArgs $secondPane)")

    # Recurse into the sibling subtree (it has focus after the split).
    Add-WtChildFragments -Node $Node.second -Panes $Panes -Sink $Sink

    # Move focus back toward the original branch.
    if ($Node.split -eq 'vertical') {
        $Sink.Add('move-focus left')
    } else {
        $Sink.Add('move-focus up')
    }

    # Recurse into the first child subtree (now that focus is back).
    Add-WtChildFragments -Node $Node.first -Panes $Panes -Sink $Sink
}

<#
.SYNOPSIS
    Recurse into a child subtree, emitting split-panes for non-leaf nodes.
#>
function Add-WtChildFragments {
    param($Node, $Panes, [System.Collections.Generic.List[string]]$Sink)
    if ($null -ne $Node.pane) { return }
    Add-WtSplitAndRecurse -Node $Node -Panes $Panes -Sink $Sink
}

<#
.SYNOPSIS
    Generate a wt.exe command line for a layout object.
.DESCRIPTION
    Produces a string beginning with `wt -w 0` and a sequence of
    new-tab / split-pane / move-focus sub-commands separated by ` ; `.
#>
function New-WtCommand {
    param([Parameter(Mandatory)] $Layout)
    $fragments = [System.Collections.Generic.List[string]]::new()

    for ($t = 0; $t -lt $Layout.tabs.Count; $t++) {
        $tab = $Layout.tabs[$t]
        $firstIndex = Resolve-WtLeafIndex -Node $tab.layout
        $firstPane = $tab.panes[$firstIndex]
        $titleArg = if ($tab.title) { "--title `"$($tab.title)`"" } else { '' }
        $firstArgs = Get-WtPaneArgs $firstPane
        $fragments.Add("new-tab $firstArgs $titleArg".Trim())

        # Build splits for this tab (skip if single pane -- a bare leaf).
        if ($null -eq $tab.layout.pane) {
            Add-WtChildFragments -Node $tab.layout -Panes $tab.panes -Sink $fragments
        }
    }

    "wt -w 0 " + ($fragments -join ' ; ')
}

# ---------------------------------------------------------------------------
# U2. UIA capture -- tab and pane enumeration
# ---------------------------------------------------------------------------
# Walk the focused Windows Terminal window's UI Automation tree to extract
# tab order, tab titles, pane rectangles, and profile names. Each pane is a
# TermControl element carrying a BoundingRectangle and a Name equal to its
# profile.

# Load the UIA assemblies once per session.
if (-not $script:WtUiaAssembliesLoaded) {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction SilentlyContinue
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction SilentlyContinue
    $script:WtUiaAssembliesLoaded = $true
}

# Win32 helpers for the foreground-window / process check.
if (-not ('WtWin32' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WtWin32 {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
}
"@ -ErrorAction SilentlyContinue
}

# P/Invoke helper to read another process's working directory from its PEB.
# Uses NtQueryInformationProcess to reach the RTL_USER_PROCESS_PARAMETERS,
# then reads CurrentDirectory.DosPath via NtReadVirtualMemory.
if (-not ('WtProcCwd' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class WtProcCwd {
    [DllImport("kernel32.dll")]
    private static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(
        IntPtr ProcessHandle, int ProcessInformationClass,
        out PROCESS_BASIC_INFORMATION ProcessInformation,
        int ProcessInformationLength, out int ReturnLength);

    [DllImport("ntdll.dll")]
    private static extern int NtReadVirtualMemory(
        IntPtr ProcessHandle, IntPtr BaseAddress,
        byte[] Buffer, int NumberOfBytesToRead, out int NumberOfBytesRead);

    [DllImport("kernel32.dll")]
    private static extern bool IsWow64Process(IntPtr hProcess, out bool Wow64Process);

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_BASIC_INFORMATION {
        public IntPtr ExitStatus;
        public IntPtr PebBaseAddress;
        public IntPtr AffinityMask;
        public IntPtr BasePriority;
        public UIntPtr UniqueProcessId;
        public IntPtr InheritedFromUniqueProcessId;
    }

    private const int ProcessBasicInformation = 0;
    private const uint PROCESS_QUERY_INFORMATION = 0x0400;
    private const uint PROCESS_VM_READ = 0x0010;

    // Offsets within PEB (stable across Windows 10 / 11):
    //   x64: ProcessParameters at +0x20
    //   x86: ProcessParameters at +0x10
    // Offsets within RTL_USER_PROCESS_PARAMETERS:
    //   x64: CurrentDirectory (CURDIR) at +0x38; UNICODE_STRING.Buffer at +0x08
    //   x86: CurrentDirectory (CURDIR) at +0x24; UNICODE_STRING.Buffer at +0x04

    public static string GetCwd(int pid) {
        IntPtr hProcess = IntPtr.Zero;
        try {
            hProcess = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, pid);
            if (hProcess == IntPtr.Zero) return "";

            int retLen;
            PROCESS_BASIC_INFORMATION pbi;
            if (NtQueryInformationProcess(hProcess, ProcessBasicInformation,
                out pbi, Marshal.SizeOf<PROCESS_BASIC_INFORMATION>(), out retLen) != 0)
                return "";
            if (pbi.PebBaseAddress == IntPtr.Zero) return "";

            // Determine target process bitness (WOW64 check).
            bool is64;
            if (!IsWow64Process(hProcess, out is64))
                is64 = Environment.Is64BitOperatingSystem;
            else
                is64 = !is64 && Environment.Is64BitOperatingSystem;

            int ppOffset  = is64 ? 0x20 : 0x10;  // PEB -> ProcessParameters
            int cdOffset  = is64 ? 0x38 : 0x24;  // ProcParams -> CurrentDirectory (CURDIR)
            int usBufOff  = is64 ? 8 : 4;        // UNICODE_STRING -> Buffer ptr
            int ptrSize   = is64 ? 8 : 4;

            long pebAddr = pbi.PebBaseAddress.ToInt64();

            // 1. Read ProcessParameters pointer from PEB.
            byte[] buf = new byte[ptrSize];
            if (NtReadVirtualMemory(hProcess, new IntPtr(pebAddr + ppOffset),
                buf, ptrSize, out retLen) != 0) return "";
            long ppVal = is64 ? BitConverter.ToInt64(buf, 0) : BitConverter.ToInt32(buf, 0);
            if (ppVal == 0) return "";

            // 2. Read DosPath.Length from CurrentDirectory UNICODE_STRING.
            buf = new byte[2];
            if (NtReadVirtualMemory(hProcess, new IntPtr(ppVal + cdOffset),
                buf, 2, out retLen) != 0) return "";
            ushort len = BitConverter.ToUInt16(buf, 0);
            if (len == 0 || len > 4096) return "";

            // 3. Read DosPath.Buffer pointer.
            buf = new byte[ptrSize];
            if (NtReadVirtualMemory(hProcess, new IntPtr(ppVal + cdOffset + usBufOff),
                buf, ptrSize, out retLen) != 0) return "";
            long strPtr = is64 ? BitConverter.ToInt64(buf, 0) : BitConverter.ToInt32(buf, 0);
            if (strPtr == 0) return "";

            // 4. Read the Unicode string.
            byte[] strBuf = new byte[len];
            if (NtReadVirtualMemory(hProcess, new IntPtr(strPtr),
                strBuf, len, out retLen) != 0) return "";

            string cwd = System.Text.Encoding.Unicode.GetString(strBuf, 0, len);
            // Normalise trailing backslash (PEB stores with trailing \).
            return cwd.TrimEnd('\\');
        } catch {
            return "";
        } finally {
            if (hProcess != IntPtr.Zero) CloseHandle(hProcess);
        }
    }
}
"@ -ErrorAction SilentlyContinue
}

<#
.SYNOPSIS
    Find the focused Windows Terminal top-level window element.
.DESCRIPTION
    Uses the foreground window handle and verifies the owning process is
    Windows Terminal (WindowsTerminal.exe). Throws a clear error when no
    WT window is focused.
#>
function Get-WtFocusedWindow {
    $hwnd = [WtWin32]::GetForegroundWindow()
    $pidValue = [uint32]0
    [void][WtWin32]::GetWindowThreadProcessId($hwnd, [ref]$pidValue)
    if ($pidValue -eq 0) {
        throw "Could not identify the focused window. Focus a Windows Terminal window and retry."
    }
    $proc = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
    if (-not $proc -or $proc.ProcessName -notmatch 'WindowsTerminal') {
        $name = if ($proc) { $proc.ProcessName } else { 'unknown' }
        throw "The focused window is not Windows Terminal (PID $pidValue, $name). Focus a Windows Terminal window and retry."
    }
    return [pscustomobject]@{
        Window = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
        Pid    = [uint32]$pidValue
    }
}

<#
.SYNOPSIS
    Walk a WT window's UIA tree and collect tabs with their panes.
.DESCRIPTION
    Finds TabItem elements (each carrying a title) and, within each tab, the
    TermControl elements (each carrying a BoundingRectangle and profile Name).
    Returns an ordered list of PSCustomObjects:
    @{ Title; Panes = @( @{ Rect; Profile } ) }.
#>
function Capture-WtWindow {
    param([Parameter(Mandatory)] $Window)

    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker

    # Collect all TermControl descendants of a given element.
    $paneCollector = {
        param($element, $panes)
        try {
            $cls = $element.Current.ClassName
        } catch {
            $cls = ''
        }
        if ($cls -match 'TermControl') {
            $name = $element.Current.Name
            $r = $element.Current.BoundingRectangle
            $panes.Add([pscustomobject]@{
                Profile = $name
                Rect    = [pscustomobject]@{ X = [double]$r.X; Y = [double]$r.Y; Width = [double]$r.Width; Height = [double]$r.Height }
            })
        }
        $child = $walker.GetFirstChild($element)
        while ($child) {
            & $paneCollector $child $panes
            $child = $walker.GetNextSibling($child)
        }
    }

    # Collect all TabItem descendants of a given element.
    # Match on ControlType (not ClassName) — WT WinUI 3 uses ListViewItem
    # as the class name while ControlType remains TabItem across versions.
    # Guard against elements whose ControlType may be null (crashes the walk).
    # depth tracking helps diagnose structural issues.
    $tabCollector = {
        param($element, $tabs, $depth = 0)
        try {
            $cls = $element.Current.ClassName
            $ctlType = $element.Current.ControlType
            $ctlName = if ($null -ne $ctlType) { $ctlType.ProgrammaticName } else { '<null>' }
            $isTabItem = ($null -ne $ctlType -and $ctlName -eq 'ControlType.TabItem')
        } catch {
            $cls = '<error>'
            $ctlName = '<error>'
            $isTabItem = $false
        }
        if ($depth -le 3) {
            $script:debugElements.Add("depth=$depth [$cls] $ctlName name='$($element.Current.Name)'")
        }
        if ($isTabItem) {
            $tabs.Add([pscustomobject]@{ Title = $element.Current.Name; Element = $element; Panes = [System.Collections.Generic.List[object]]::new() })
        }
        $child = $walker.GetFirstChild($element)
        while ($child) {
            & $tabCollector $child $tabs ($depth + 1)
            $child = $walker.GetNextSibling($child)
        }
    }

    $tabs = [System.Collections.Generic.List[object]]::new()
    $script:debugElements = [System.Collections.Generic.List[string]]::new()
    & $tabCollector $Window $tabs

    if ($tabs.Count -eq 0) {
        Write-Host "DEBUG: Walked UIA tree, found no TabItem. Visited elements (depth<=3):"
        foreach ($d in $script:debugElements) { Write-Host "  $d" }
        throw "No tabs found in the focused Windows Terminal window."
    }

    # Collect all TermControl panes from the window root.
    # In WinUI 3 WT, TermControl elements are NOT children of TabItem —
    # they live at window level and only the active tab's panes are rendered.
    # Match panes to the tab whose title equals the window title.
    $allPanes = [System.Collections.Generic.List[object]]::new()
    & $paneCollector $Window $allPanes
    $windowTitle = $Window.Current.Name
    foreach ($tab in $tabs) {
        if ($tab.Title -eq $windowTitle) {
            $tab.Panes = $allPanes
        }
    }

    # Build the ordered capture result.
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($tab in $tabs) {
        $result.Add([pscustomobject]@{
            Title = $tab.Title
            Panes = @($tab.Panes)
        })
    }
    return $result
}

<#
.SYNOPSIS
    Recursively walk the process tree under a root PID to find shell descendants.
.DESCRIPTION
    WindowsTerminal.exe spawns OpenConsole.exe which spawns the actual shell
    (pwsh.exe, cmd.exe, etc.). A flat parent-child query misses these. This
    function walks down from the root PID with a depth limit of 4, collecting
    every process whose name matches a known shell, sorted by CreationDate.

    Returns an array of CIM process objects (ProcessId, Name, CreationDate).
#>
function Get-WtShellDescendants {
    param([Parameter(Mandatory)] [uint32]$RootPid)

    $shellNames = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    @(
        'pwsh.exe', 'powershell.exe', 'cmd.exe', 'wsl.exe',
        'bash.exe', 'git-bash.exe', 'zsh.exe', 'fish.exe', 'nu.exe'
    ) | ForEach-Object { [void]$shellNames.Add($_) }

    $result  = [System.Collections.Generic.List[object]]::new()
    $visited = [System.Collections.Generic.HashSet[uint32]]::new()

    # NOTE: $Pid is a read-only automatic variable in PowerShell — name the
    # param $ProcessId instead so the scriptblock can bind to it.
    $recurse = {
        param([uint32]$ProcessId, [int]$Depth)
        if ($Depth -gt 4) { return }
        if (-not $visited.Add($ProcessId)) { return }

        $query = "SELECT ProcessId, Name, CreationDate FROM Win32_Process WHERE ParentProcessId = $ProcessId"
        $children = Get-CimInstance -Query $query -ErrorAction SilentlyContinue
        if (-not $children) { return }

        foreach ($child in $children) {
            if ($shellNames.Contains($child.Name)) {
                $result.Add($child)
            }
            & $recurse -ProcessId ([uint32]$child.ProcessId) -Depth ($Depth + 1)
        }
    }

    & $recurse -ProcessId $RootPid -Depth 0

    # CreationDate in CIM is YYYYMMDDHHMMSS.micros±UTC — lexicographic sort works.
    return @($result | Sort-Object CreationDate)
}

<#
.SYNOPSIS
    Best-effort capture of working directories for each pane in the active tab.
.DESCRIPTION
    Uses Get-WtShellDescendants to recursively find shell processes under the
    focused WT window, then matches processes to panes in two tiers:

    Tier 1 — exact count match: when shell process count equals pane count,
    pair by CreationDate index (oldest first, matching UIA tree order).

    Tier 2 — per-profile queue matching: when counts differ (inactive tabs
    with visible shell processes), group processes by executable name into
    FIFO queues and dequeue per pane based on its profile name. Unconsumed
    processes (from inactive tabs) stay in their queues.

    Returns an array of empty strings when no cwd can be determined.
#>
function Get-WtPaneCwds {
    param(
        [Parameter(Mandatory)] [int]$PaneCount,
        [Parameter(Mandatory)] [uint32]$WtPid,
        [Parameter(Mandatory)] [object[]]$Panes
    )

    if ($PaneCount -eq 0) { return @() }
    if (-not ('WtProcCwd' -as [type])) { return @('') * $PaneCount }

    $shellProcs = Get-WtShellDescendants -RootPid $WtPid
    if ($shellProcs.Count -eq 0) { return @('') * $PaneCount }

    # ---- Tier 1: exact count match (single-tab / all-panes-visible) ----
    if ($shellProcs.Count -eq $PaneCount) {
        $cwds = [string[]]::new($PaneCount)
        for ($i = 0; $i -lt $PaneCount; $i++) {
            $cwd = [WtProcCwd]::GetCwd([int]$shellProcs[$i].ProcessId)
            $cwds[$i] = if ($cwd) { $cwd } else { '' }
        }
        return $cwds
    }

    # ---- Tier 2: per-profile queue matching (multi-tab) ----
    function Get-ExpectedExeNames {
        param([string]$Profile)
        $p = $Profile.ToLowerInvariant()
        if ($p -match 'powershell' -or $p -eq 'pwsh') {
            return @('pwsh.exe', 'powershell.exe')
        }
        if ($p -match 'command.*prompt|^cmd$') {
            return @('cmd.exe')
        }
        # WSL distros, Git Bash, and everything else.
        return @('wsl.exe', 'bash.exe', 'git-bash.exe', 'zsh.exe', 'fish.exe', 'nu.exe')
    }

    $queues = @{}
    foreach ($proc in $shellProcs) {
        $key = $proc.Name.ToLowerInvariant()
        if (-not $queues.ContainsKey($key)) {
            $queues[$key] = [System.Collections.Generic.Queue[object]]::new()
        }
        $queues[$key].Enqueue($proc)
    }

    $cwds = [string[]]::new($PaneCount)
    for ($i = 0; $i -lt $PaneCount; $i++) {
        $candidates = Get-ExpectedExeNames -Profile $Panes[$i].Profile
        $found = $false
        foreach ($cand in $candidates) {
            $key = $cand.ToLowerInvariant()
            if ($queues.ContainsKey($key) -and $queues[$key].Count -gt 0) {
                $matched = $queues[$key].Dequeue()
                $cwd = [WtProcCwd]::GetCwd([int]$matched.ProcessId)
                $cwds[$i] = if ($cwd) { $cwd } else { '' }
                $found = $true
                break
            }
        }
        if (-not $found) { $cwds[$i] = '' }
    }

    return $cwds
}

# ---------------------------------------------------------------------------
# U5. wtsave / wtrestore / wtlayouts wiring
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Capture the focused Windows Terminal window's layout to a named file.
#>
function wtsave {
    param([Parameter(Mandatory, Position = 0)] [string]$Name)
    $focused = Get-WtFocusedWindow
    $tabs = Capture-WtWindow -Window $focused.Window

    $layoutTabs = [System.Collections.Generic.List[object]]::new()
    foreach ($tab in $tabs) {
        $panesList = [System.Collections.Generic.List[object]]::new()
        $group = [System.Collections.Generic.List[object]]::new()
        # Inactive tabs have no TermControl elements in the UIA tree.
        # Save them with a single default-pane placeholder so restore works.
        if ($tab.Panes.Count -eq 0) {
            $panesList.Add([pscustomobject]@{ profile = ''; cwd = '' })
            $tree = New-WtLeaf -PaneIndex 0
        } else {
            # Pane capture only makes sense when there are visible panes; an
            # empty array would trip Get-WtPaneCwds's mandatory $Panes param.
            $paneCwds = Get-WtPaneCwds -PaneCount $tab.Panes.Count -WtPid $focused.Pid -Panes $tab.Panes
            for ($i = 0; $i -lt $tab.Panes.Count; $i++) {
                $pane = $tab.Panes[$i]
                $panesList.Add([pscustomobject]@{
                    profile = $pane.Profile
                    cwd     = $paneCwds[$i]
                })
                $group.Add([pscustomobject]@{ Index = $i; Rect = $pane.Rect })
            }
            if ($tab.Panes.Count -eq 1) {
                $tree = New-WtLeaf -PaneIndex 0
            } else {
                $tree = ConvertTo-WtSplitTree -Group @($group)
            }
        }
        $layoutTabs.Add([pscustomobject]@{
            title  = $tab.Title
            panes  = @($panesList)
            layout = $tree
        })
    }

    $layout = [pscustomobject]@{
        name = $Name
        tabs = @($layoutTabs)
    }
    Save-WtLayoutFile -Name $Name -Layout $layout
    $path = Get-WtLayoutPath -Name $Name
    Write-Host "Saved layout '$Name' -> $path"
    Write-Host "  $($layoutTabs.Count) tab(s)."
}

<#
.SYNOPSIS
    Open a new Windows Terminal window from a named layout file.
#>
function wtrestore {
    param([Parameter(Mandatory, Position = 0)] [string]$Name)
    $layout = Read-WtLayoutFile -Name $Name
    $cmd = New-WtCommand -Layout $layout
    Write-Host "Restoring layout '$Name'..."
    cmd /c $cmd
}

<#
.SYNOPSIS
    List saved layout names.
#>
function wtlayouts {
    $names = List-WtLayouts
    if ($names.Count -eq 0) {
        Write-Host "No saved layouts. Run 'wtsave <name>' to capture one."
        return
    }
    Write-Host "Saved layouts ($(Get-WtLayoutDir)):"
    foreach ($n in $names) {
        Write-Host "  $n"
    }
}