<#
.SYNOPSIS
    Sort files and folders into category folders (Windows/PowerShell port).
.DESCRIPTION
    organize.ps1 mirrors the core behaviour of organize.sh: extension
    categories, recursive mode, dry runs, custom rules, by-date grouping,
    rename, filters, JSON summary and undoable moves.
#>
[CmdletBinding()]
param(
    [string]$Directory = ".",
    [switch]$Recursive,
    [switch]$Reorganize,
    [switch]$Hidden,
    [switch]$DryRun,
    [switch]$Explain,
    [string]$Target = "",
    [switch]$ByDate,
    [switch]$Rename,
    [switch]$Link,
    [switch]$Json,
    [string]$Rules = "",
    [string]$Config = "",
    [string[]]$Include = @(),
    [string[]]$Exclude = @(),
    [string]$MinSize = "",
    [string]$MaxSize = "",
    [int]$OlderThan = 0,
    [switch]$Undo,
    [switch]$Version,
    [switch]$Doctor,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
$ScriptVersion = "1.3.1"

if ($Version) { Write-Output "organize.ps1 $ScriptVersion"; exit 0 }
if ($Help) {
    Write-Output "Usage: organize.ps1 [options] [directory]"
    Write-Output "  -Recursive          include subdirectories"
    Write-Output "  -DryRun             preview without changing anything"
    Write-Output "  -Target DIR         move files into DIR"
    Write-Output "  -Hidden             include hidden files"
    Write-Output "  -ByDate             group as Category/YYYY/MM/"
    Write-Output "  -Rename             normalize names"
    Write-Output "  -Rules FILE         custom rules"
    Write-Output "  -Undo               undo most recent run"
    Write-Output "  -Json               JSON summary"
    exit 0
}

function Parse-Size([string]$s) {
    if ($s -match '^(\d+)([kKmMgG]?)$') {
        $n = [long]$Matches[1]
        switch ($Matches[2]) {
            'k' { $n *= 1024 }
            'K' { $n *= 1024 }
            'm' { $n *= 1048576 }
            'M' { $n *= 1048576 }
            'g' { $n *= 1073741824 }
            'G' { $n *= 1073741824 }
        }
        return $n
    }
    throw "invalid size: $s"
}

$dir = (Resolve-Path $Directory).Path
if (-not $Target) { $Target = $dir } else { $Target = (Resolve-Path $Target -ErrorAction SilentlyContinue).Path; if (-not $Target) { New-Item -ItemType Directory -Force -Path $args[0] | Out-Null; $Target = (Resolve-Path $Target).Path } }
# ensure target exists
if (-not (Test-Path $Target)) { New-Item -ItemType Directory -Force -Path $Target | Out-Null }
$Target = (Resolve-Path $Target).Path

if ($Doctor) {
    Write-Output "organize.ps1 $ScriptVersion - dependency check"
    foreach ($c in @("powershell")) { Write-Output "[OK] $c" }
    exit 0
}

$categories = @("Images","Documents","Videos","Audio","Archives","Disk Images","Code","Fonts","Executables","Other","Folders")

function Category-For([string]$ext) {
    $e = $ext.ToLower()
    switch -Regex ($e) {
        '^(jpg|jpeg|png|gif|bmp|tiff|tif|webp|svg|heic|heif|avif|raw|cr2|nef|dng)$' { return "Images" }
        '^(pdf|doc|docx|txt|rtf|odt|md|markdown|xls|xlsx|ods|ppt|pptx|odp|csv|epub)$' { return "Documents" }
        '^(mp4|mkv|avi|mov|wmv|flv|webm|m4v|mpg|mpeg|3gp|ogv)$' { return "Videos" }
        '^(mp3|wav|flac|aac|ogg|m4a|wma|opus|mid|midi)$' { return "Audio" }
        '^(zip|tar|gz|bz2|xz|7z|rar|tgz|tbz2|txz|zst)$' { return "Archives" }
        '^(iso|img|dmg)$' { return "Disk Images" }
        '^(sh|bash|zsh|fish|py|js|jsx|ts|tsx|json|yaml|yml|toml|xml|html|htm|css|scss|sass|less|php|rb|go|rs|java|c|h|cpp|hpp|cs|swift|kt|kts|sql|lua|pl|r|m|mm|gradle)$' { return "Code" }
        '^(ttf|otf|woff|woff2)$' { return "Fonts" }
        '^(exe|msi|deb|rpm|appimage|apk|flatpak|snap)$' { return "Executables" }
        default { return "Other" }
    }
}

# Rules
$rulePatterns = @()
$ruleDests = @()
if ($Rules -and (Test-Path $Rules)) {
    $rp = (Resolve-Path $Rules).Path
    foreach ($line in (Get-Content $rp)) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }
        if ($line -match '^(.+?)\s*->\s*(.+)$' -or $line -match '^(.+?)\s*=>\s*(.+)$') {
            $pat = $Matches[1].Trim()
            $dst = $Matches[2].Trim()
            $rulePatterns += $pat
            $ruleDests += $dst
        }
    }
} elseif ($Rules) {
    throw "rules file not found: $Rules"
}

function Rule-For([string]$base) {
    for ($i = 0; $i -lt $rulePatterns.Count; $i++) {
        if ($base -like $rulePatterns[$i]) { return $ruleDests[$i] }
    }
    return $null
}

# Undo log helpers (JSON)
$logs = Get-ChildItem -Path $dir -Filter ".organize-log-*.log" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime
if ($Undo) {
    if (-not $logs) { Write-Output "no organize log found in $dir"; exit 0 }
    $latest = $logs | Select-Object -Last 1
    $data = Get-Content $latest.FullName -Raw | ConvertFrom-Json
    # restore in reverse
    $entries = $data.entries
    for ($i = $entries.Count - 1; $i -ge 0; $i--) {
        $e = $entries[$i]
        $src = $e.src; $dest = $e.dest
        if (-not (Test-Path $dest)) { Write-Output "skip (missing): $dest"; continue }
        $parent = Split-Path $src -Parent
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        if (Test-Path $src) { Write-Output "skip (target exists): $src"; continue }
        Move-Item -LiteralPath $dest -Destination $src -Force
        Write-Output "restored: $src"
    }
    Remove-Item $latest.FullName -Force
    Write-Output "Undo complete."
    exit 0
}

# Collect files
$files = @()
$pruneNames = @()
if ($Recursive) {
    $all = Get-ChildItem -Path $dir -Recurse -File -Force:$Hidden -ErrorAction SilentlyContinue
} else {
    $all = Get-ChildItem -Path $dir -File -Force:$Hidden -ErrorAction SilentlyContinue
}
foreach ($f in $all) {
    # skip hidden unless requested
    if (-not $Hidden -and $f.Name.StartsWith(".")) { continue }
    # include/exclude
    $skip = $false
    foreach ($g in $Exclude) { if ($f.Name -like $g) { $skip = $true } }
    if ($skip) { continue }
    if ($Include.Count -gt 0) {
        $ok = $false
        foreach ($g in $Include) { if ($f.Name -like $g) { $ok = $true } }
        if (-not $ok) { continue }
    }
    # size filters
    if ($MinSize) { if ($f.Length -lt (Parse-Size $MinSize)) { continue } }
    if ($MaxSize) { if ($f.Length -gt (Parse-Size $MaxSize)) { continue } }
    # older-than
    if ($OlderThan -gt 0) {
        if ((New-TimeSpan -Start $f.LastWriteTime -End (Get-Date)).Days -lt $OlderThan) { continue }
    }
    $files += $f
}

# Counters
$counts = @{}
$movedCount = 0
$movedBytes = 0
$entries = @()

function Unique-Path([string]$dest) {
    if (-not (Test-Path $dest)) { return $dest }
    $dir = Split-Path $dest -Parent
    $name = Split-Path $dest -Leaf
    if ($name -match '^(.*)\.([^\.]+)$') {
        $base = $Matches[1]; $ext = "." + $Matches[2]
    } else {
        $base = $name; $ext = ""
    }
    $i = 1
    while (Test-Path (Join-Path $dir "$base ($i)$ext")) { $i++ }
    return (Join-Path $dir "$base ($i)$ext")
}

$moveCount = 0
foreach ($f in $files) {
    $ext = [System.IO.Path]::GetExtension($f.Name).TrimStart(".")
    $cat = Rule-For $f.Name
    if (-not $cat) { $cat = Category-For $ext }
    # by-date
    if ($ByDate) {
        $d = $f.LastWriteTime
        $cat = "$cat/$($d.Year)/$($d.Month.ToString('00'))"
    }
    # rename
    $name = $f.Name
    if ($Rename) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($name)
        $e = [System.IO.Path]::GetExtension($name)
        $base = $base.ToLower() -replace '\s+','_' -replace '_+','_'
        $name = $base + $e
    }
    $destDir = Join-Path $Target $cat
    $dest = Join-Path $destDir $name
    if ($dest -eq $f.FullName) { Write-Output "already organized: $($f.FullName)"; continue }
    $dest = Unique-Path $dest

    if ($Explain -and -not $Json) {
        Write-Output "why: $($f.FullName) -> $dest (category $cat)"
    }
    if ($DryRun) {
        Write-Output "would move: $($f.FullName) -> $dest"
    } else {
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
        Move-Item -LiteralPath $f.FullName -Destination $dest -Force
        Write-Output "moved: $($f.FullName) -> $dest"
    }
    $entries += @{ src = $f.FullName; dest = $dest }
    $top = $cat.Split("/\")[0]
    if (-not $counts.ContainsKey($top)) { $counts[$top] = @{count=0;bytes=0} }
    $counts[$top].count++
    $counts[$top].bytes += $f.Length
    $movedCount++
    $movedBytes += $f.Length
}

# Write undo log
if (-not $DryRun -and $entries.Count -gt 0) {
    $logName = ".organize-log-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$PID.log"
    $logPath = Join-Path $dir $logName
    $logObj = @{ target = $Target; entries = $entries }
    $logObj | ConvertTo-Json -Depth 5 | Set-Content -Path $logPath -Encoding UTF8
    Write-Output "Log: $logPath (use -Undo to revert)"
}

# Summary
if ($Json) {
    $catObj = @{}
    foreach ($k in $counts.Keys) { $catObj[$k] = @{count=$counts[$k].count;bytes=$counts[$k].bytes} }
    $summary = @{ dry_run = $DryRun.IsPresent; moved = $movedCount; moved_bytes = $movedBytes; categories = $catObj }
    $summary | ConvertTo-Json -Depth 5 -Compress
} else {
    if ($DryRun) { Write-Output "Summary (dry run):" } else { Write-Output "Summary:" }
    foreach ($k in ($counts.Keys | Sort-Object)) {
        $sz = $counts[$k].bytes
        if ($sz -ge 1048576) { $hs = "{0:N1} MiB" -f ($sz/1048576) } elseif ($sz -ge 1024) { $hs = "{0:N1} KiB" -f ($sz/1024) } else { $hs = "$sz B" }
        Write-Output ("  {0,-20} {1} files  {2}" -f $k, $counts[$k].count, $hs)
    }
    Write-Output ("  {0,-20} {1} files  {2}" -f "Total", $movedCount, "")
}
