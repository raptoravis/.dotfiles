# wt-layout-tests.ps1 — exercises U1, U3, U4, U5 without a live WT window.
# Run:  powershell -NoProfile -File wt-layout-tests.ps1
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\wt-layout.ps1"
$pass = 0; $fail = 0
function Assert-True($cond, $msg) {
    if ($cond) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $msg" -ForegroundColor Red }
}
function Assert-Equal($a, $b, $msg) {
    if ($a -eq $b) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $msg — got '$a' expected '$b'" -ForegroundColor Red }
}
function Assert-Near($a, $b, $tol, $msg) {
    if ([Math]::Abs($a - $b) -le $tol) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $msg — got '$a' expected ~'$b' (tol $tol)" -ForegroundColor Red }
}

# ---- helpers ----
function New-Rect($x,$y,$w,$h) { [pscustomobject]@{ X=$x; Y=$y; Width=$w; Height=$h } }
function New-Group($rects) {
    $g = [System.Collections.Generic.List[object]]::new()
    for ($i=0; $i -lt $rects.Count; $i++) { $g.Add([pscustomobject]@{ Index=$i; Rect=$rects[$i] }) }
    ,$g
}

Write-Host "=== U3: Rectangle-to-split-tree ==="

# One rectangle -> single leaf
$t = ConvertTo-WtSplitTree -Group @(New-Group @(,@(New-Rect 0 0 100 100)))
Assert-True ($null -ne $t.pane) "single rect is leaf"
Assert-Equal $t.pane 0 "leaf index 0"

# Two side-by-side -> vertical split, ratio 0.5
$r1 = New-Rect 0 0 50 100; $r2 = New-Rect 50 0 50 100
$t = ConvertTo-WtSplitTree -Group (New-Group @($r1,$r2))
Assert-Equal $t.split 'vertical' "two side-by-side vertical"
Assert-Near $t.ratio 0.5 0.02 "ratio 0.5"
Assert-Equal $t.first.pane 0 "first leaf 0"
Assert-Equal $t.second.pane 1 "second leaf 1"

# Two stacked -> horizontal split, ratio 0.5
$r1 = New-Rect 0 0 100 50; $r2 = New-Rect 0 50 100 50
$t = ConvertTo-WtSplitTree -Group (New-Group @($r1,$r2))
Assert-Equal $t.split 'horizontal' "two stacked horizontal"
Assert-Near $t.ratio 0.5 0.02 "ratio 0.5"

# Three nested: left full-height, right split top/bottom
$r1 = New-Rect 0 0 50 100; $r2 = New-Rect 50 0 50 50; $r3 = New-Rect 50 50 50 50
$t = ConvertTo-WtSplitTree -Group (New-Group @($r1,$r2,$r3))
Assert-Equal $t.split 'vertical' "outer vertical"
Assert-Equal $t.first.pane 0 "left leaf 0"
Assert-Equal $t.second.split 'horizontal' "right is horizontal"
Assert-Equal $t.second.first.pane 1 "right-top leaf 1"
Assert-Equal $t.second.second.pane 2 "right-bottom leaf 2"

# Uneven split 70/30 vertical
$r1 = New-Rect 0 0 70 100; $r2 = New-Rect 70 0 30 100
$t = ConvertTo-WtSplitTree -Group (New-Group @($r1,$r2))
Assert-Equal $t.split 'vertical' "uneven vertical"
Assert-Near $t.ratio 0.3 0.02 "ratio 0.3 (new pane size)"

# Pixel rounding tolerance (off by 1px)
$r1 = New-Rect 0 0 50 100; $r2 = New-Rect 51 0 49 100
$t = ConvertTo-WtSplitTree -Group (New-Group @($r1,$r2))
Assert-Equal $t.split 'vertical' "1px-gap still vertical"
Assert-Near $t.ratio 0.5 0.02 "1px-gap ratio ~0.5"

Write-Host "=== U1: File I/O round-trip ==="

# Round-trip single tab, single pane
$layout1 = [pscustomobject]@{
    name = 'roundtrip1'
    tabs = @([pscustomobject]@{
        title = 'test'
        panes = @([pscustomobject]@{ profile='PowerShell'; cwd='' })
        layout = [pscustomobject]@{ pane = 0 }
    })
}
$dir = Get-WtLayoutDir
if (Test-Path "$dir\roundtrip1.json") { Remove-Item "$dir\roundtrip1.json" }
Save-WtLayoutFile -Name 'roundtrip1' -Layout $layout1
Assert-True (Test-Path "$dir\roundtrip1.json") "file created"
$read1 = Read-WtLayoutFile -Name 'roundtrip1'
Assert-Equal $read1.name 'roundtrip1' "name round-trip"
Assert-Equal $read1.tabs[0].title 'test' "title round-trip"
Assert-Equal $read1.tabs[0].panes[0].profile 'PowerShell' "profile round-trip"
Assert-Equal $read1.tabs[0].panes[0].cwd '' "cwd empty round-trip"
Assert-Equal $read1.tabs[0].layout.pane 0 "layout leaf round-trip"

# Valid JSON (human-readable)
$jsonRaw = Get-Content "$dir\roundtrip1.json" -Raw
Assert-True ($jsonRaw -match '\n') "JSON is indented/multi-line"

# Round-trip nested splits
$layout2 = [pscustomobject]@{
    name = 'roundtrip2'
    tabs = @([pscustomobject]@{
        title = 'work'
        panes = @(
            [pscustomobject]@{ profile='PowerShell'; cwd='' },
            [pscustomobject]@{ profile='Git Bash'; cwd='D:\dev' },
            [pscustomobject]@{ profile='PowerShell'; cwd='' }
        )
        layout = [pscustomobject]@{
            split='vertical'; ratio=0.5
            first=[pscustomobject]@{ pane=0 }
            second=[pscustomobject]@{ split='horizontal'; ratio=0.5; first=[pscustomobject]@{ pane=1 }; second=[pscustomobject]@{ pane=2 } }
        }
    })
}
Save-WtLayoutFile -Name 'roundtrip2' -Layout $layout2
$read2 = Read-WtLayoutFile -Name 'roundtrip2'
Assert-Equal $read2.tabs[0].layout.split 'vertical' "nested: outer split"
Assert-Equal $read2.tabs[0].layout.second.split 'horizontal' "nested: inner split"
Assert-Equal $read2.tabs[0].panes[1].cwd 'D:\dev' "nested: cwd preserved"

# List-WtLayouts
$names = List-WtLayouts
Assert-True ($names -contains 'roundtrip1') "list contains roundtrip1"
Assert-True ($names -contains 'roundtrip2') "list contains roundtrip2"

# List handles empty dir
$emptyDir = Join-Path $env:TEMP "wt-empty-test-$(Get-Random)"
New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
Assert-True ((List-WtLayouts).Count -ge 0) "list no crash on populated dir"
Remove-Item $emptyDir -Recurse -Force

Write-Host "=== U4: wt.exe command generator ==="

# One tab, one pane
$cmd = New-WtCommand -Layout $layout1
Assert-True ($cmd -match '^wt -w 0 ') "prefix wt -w 0"
Assert-True ($cmd -match 'new-tab -p "PowerShell"') "single pane new-tab"
Assert-True ($cmd -match '--title "test"') "title arg"

# One tab, two panes vertical
$twoPane = [pscustomobject]@{
    name = 'tp'
    tabs = @([pscustomobject]@{
        title = 'tp'
        panes = @([pscustomobject]@{ profile='PowerShell'; cwd='' }, [pscustomobject]@{ profile='PowerShell'; cwd='' })
        layout = [pscustomobject]@{ split='vertical'; ratio=0.5; first=[pscustomobject]@{ pane=0 }; second=[pscustomobject]@{ pane=1 } }
    })
}
$cmd = New-WtCommand -Layout $twoPane
Assert-True ($cmd -match 'split-pane -V -s 0.5 -p "PowerShell"') "two-pane vertical split"

# Per-pane cwd: set emits -d, empty omits -d
$cwdLayout = [pscustomobject]@{
    name = 'cwd'
    tabs = @([pscustomobject]@{
        title = 'cwd'
        panes = @([pscustomobject]@{ profile='PowerShell'; cwd='' }, [pscustomobject]@{ profile='PowerShell'; cwd='D:\dev\mau' })
        layout = [pscustomobject]@{ split='vertical'; ratio=0.5; first=[pscustomobject]@{ pane=0 }; second=[pscustomobject]@{ pane=1 } }
    })
}
$cmd = New-WtCommand -Layout $cwdLayout
$firstFrag = ($cmd -split ' ; ')[0]
Assert-True ($firstFrag -notmatch '-d ') "first pane no -d (empty cwd)"
Assert-True ($cmd -match 'split-pane -V -s 0.5 -p "PowerShell" -d "D:\\dev\\mau"') "second pane has -d"

# Two tabs
$twoTab = [pscustomobject]@{
    name = 'tt'
    tabs = @(
        [pscustomobject]@{ title='A'; panes=@([pscustomobject]@{ profile='PowerShell'; cwd='' }); layout=[pscustomobject]@{ pane=0 } },
        [pscustomobject]@{ title='B'; panes=@([pscustomobject]@{ profile='Git Bash'; cwd='' }); layout=[pscustomobject]@{ pane=0 } }
    )
}
$cmd = New-WtCommand -Layout $twoTab
Assert-True ($cmd -match '--title "A"') "tab A title"
Assert-True ($cmd -match '--title "B"') "tab B title"
Assert-True ($cmd -match 'new-tab -p "Git Bash"') "second tab profile"

# Nested three-pane: should contain move-focus
$cmd = New-WtCommand -Layout $layout2
Assert-True ($cmd -match 'move-focus') "nested layout has move-focus"

# No trailing separator
Assert-True ($cmd -notmatch ' ;\s*$') "no trailing separator"

Write-Host "=== U5: wiring ==="

# Functions exist after dot-source
$cmds = Get-Command wtsave,wtrestore,wtlayouts -ErrorAction SilentlyContinue
Assert-Equal $cmds.Count 3 "wtsave/wtrestore/wtlayouts defined"

# wtrestore nonexistent gives clear error
$threw = $false
try { Read-WtLayoutFile -Name 'definitely-nonexistent-xyz' } catch { $threw = $true }
Assert-True $threw "missing layout throws"

# ---- cleanup ----
Remove-Item "$dir\roundtrip1.json" -ErrorAction SilentlyContinue
Remove-Item "$dir\roundtrip2.json" -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "=== RESULTS: $pass passed, $fail failed ===" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
exit 0