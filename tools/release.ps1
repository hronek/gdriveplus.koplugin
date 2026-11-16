<#
.SYNOPSIS
Releases a new version of the plugin: works out the version number from the changes,
sets it everywhere, commits, tags and pushes. Run it by double-clicking release.cmd.

.DESCRIPTION
The version is kept in two files:
  _meta.lua      version = "X.Y.Z"    shown in Settings; the Release workflow checks the tag against it
  CHANGELOG.md   ## X.Y.Z - date      its text becomes the GitHub release notes
The release itself is the tag vX.Y.Z. Pushing it runs .github/workflows/release.yml, which
tests, builds gdriveplus.koplugin.zip and publishes the GitHub release that Storefront installs.

The new version counts from the newest vX.Y.Z tag, by what changed in the plugin since then
(committed or not):
  major  the sync file format version changed (FORMAT_VERSION, progress "version"),
         a "### Breaking" heading in the changelog, or a commit "feat!:" / "BREAKING"
  minor  a new menu item, setting, automatic trigger (onSomething handler) or gesture
         action; "### Added" / "### Changed" in the changelog; a commit "feat: ..."
  patch  any other change to the plugin code (main.lua, gdriveplus_*.lua)
Documentation, tests, tools and workflows alone are not released: Storefront users
would get nothing new, and the documentation is on GitHub anyway.

Release notes: the top CHANGELOG.md section is used when it is "## Unreleased" (or an
unreleased version left by an earlier run). Otherwise one is drafted from the commit
subjects; the script shows it and offers to edit it in Notepad before releasing.

Nothing is committed before you answer y. Running it again gives the same version.

.PARAMETER Version
Optional: patch, minor, major or X.Y.Z instead of the automatic choice.

.PARAMETER NoCommit
Only update _meta.lua and CHANGELOG.md and print the git commands.
#>
param(
    [Parameter(Position = 0)][string]$Version,
    [switch]$NoCommit
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding $false
$dash = [string][char]0x2014   # em dash; this file stays ASCII for Windows PowerShell 5.1
$levelNames = @('none', 'patch', 'minor', 'major')

# Plugin code: a change here is worth a release. The documentation in the zip
# (README.md, SYNC_FORMAT.md, LICENSE) goes along but does not count on its own.
function Test-PluginCode([string]$path) { $path -eq 'main.lua' -or $path -match '^gdriveplus_\w+\.lua$' }

function Read-Text([string]$name) { [System.IO.File]::ReadAllText((Join-Path $root $name), $utf8) }
function Write-Text([string]$name, [string]$text) { [System.IO.File]::WriteAllText((Join-Path $root $name), $text, $utf8) }

function Invoke-Git {
    $out = & git -C $root @args
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed (exit code $LASTEXITCODE)" }
    $out
}

# A file's text at a tag, or $null when it did not exist there.
function Get-TagText([string]$tag, [string]$name) {
    $ErrorActionPreference = 'Continue'
    $out = & git -C $root show "${tag}:$name" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    ($out -join "`n")
}

function Find-All([string]$text, [string]$pattern) {
    if (-not $text) { return @() }
    @([regex]::Matches($text, $pattern) | ForEach-Object { $_.Groups[1].Value })
}

function Get-SettingKeys([string]$text) {
    $m = [regex]::Match("$text", '(?s)GDrivePlus\.default_settings\s*=\s*\{(.*?)\n\}')
    if (-not $m.Success) { return @() }
    Find-All $m.Groups[1].Value '(?m)^\s*([A-Za-z_]\w*)\s*='
}

# What changed in the plugin since $tag, and which version level that needs.
function Measure-Changes([string]$tag, [string]$notes) {
    $reasons = New-Object System.Collections.Generic.List[string]
    $script:level = 0
    function Raise([int]$to, [string]$why) {
        if ($to -gt $script:level) { $script:level = $to }
        $reasons.Add("$($levelNames[$to]): $why")
    }

    $changed = @(Invoke-Git diff --name-only $tag --) + @(Invoke-Git ls-files --others --exclude-standard)
    $files = @($changed | Where-Object { Test-PluginCode $_ } | Sort-Object -Unique)
    if ($files.Count -eq 0) {
        return [pscustomobject]@{ Level = 0; Reasons = $reasons; Files = $files; Labels = @() }
    }
    Raise 1 ("changed " + ($files -join ', '))

    # main.lua: menu items, settings, automatic triggers, gesture actions
    $old = Get-TagText $tag 'main.lua'
    $new = Read-Text 'main.lua'
    $labelPattern = '(?:\btext\s*=\s*_\(|\btext_func\s*=\s*function\s*\(\)[^\n]*?_\()"((?:[^"\\]|\\.)*)"'
    $oldLabels = Find-All $old $labelPattern
    $newLabels = Find-All $new $labelPattern
    $addedLabels = @($newLabels | Where-Object { $oldLabels -notcontains $_ } | Sort-Object -Unique)
    if ($newLabels.Count -gt $oldLabels.Count) {
        Raise 2 ("new menu item: " + $(if ($addedLabels) { $addedLabels -join '; ' } else { 'more items' }))
    }
    $oldKeys = Get-SettingKeys $old
    $newKeys = @(Get-SettingKeys $new | Where-Object { $oldKeys -notcontains $_ })
    if ($newKeys) { Raise 2 ("new setting: " + ($newKeys -join ', ')) }
    $handlerPattern = '(?m)^function\s+GDrivePlus:(on\w+)\s*\('
    $oldHandlers = Find-All $old $handlerPattern
    $newHandlers = @(Find-All $new $handlerPattern | Where-Object { $oldHandlers -notcontains $_ })
    if ($newHandlers) { Raise 2 ("new automatic trigger: " + ($newHandlers -join ', ')) }
    $actionPattern = 'registerAction\(\s*"([^"]+)"'
    $oldActions = Find-All $old $actionPattern
    $newActions = @(Find-All $new $actionPattern | Where-Object { $oldActions -notcontains $_ })
    if ($newActions) { Raise 2 ("new gesture action: " + ($newActions -join ', ')) }

    # sync file format
    foreach ($f in @(@('gdriveplus_annotations.lua', 'FORMAT_VERSION\s*=\s*(\d+)', 'annotation file format'),
                     @('gdriveplus_progress.lua', '(?m)^\s*version\s*=\s*(\d+)', 'progress file format'))) {
        $before = @(Find-All (Get-TagText $tag $f[0]) $f[1]) | Select-Object -First 1
        $after = @(Find-All (Read-Text $f[0]) $f[1]) | Select-Object -First 1
        if ($before -and $after -and $before -ne $after) { Raise 3 "$($f[2]) version $before -> $after" }
    }

    # commit messages and changelog headings
    foreach ($s in @(Invoke-Git log "$tag..HEAD" --no-merges '--format=%s%n%b')) {
        if ($s -match '^\w+(\([^)]*\))?!:|BREAKING CHANGE') { Raise 3 "commit: $s" }
        elseif ($s -match '^feat(\([^)]*\))?:') { Raise 2 "commit: $s" }
    }
    if ($notes -match '(?im)^###\s*breaking') { Raise 3 'changelog: ### Breaking' }
    elseif ($notes -match '(?im)^###\s*(added|new|changed|removed)\b') { Raise 2 "changelog: ### $($Matches[1])" }

    [pscustomobject]@{ Level = $script:level; Reasons = $reasons; Files = $files; Labels = $addedLabels }
}

# The text under the heading at $start, up to the next "## ".
function Get-SectionText($lines, [int]$start) {
    $body = New-Object System.Collections.Generic.List[string]
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^## ') { break }
        $body.Add($lines[$i])
    }
    ($body -join "`n").Trim()
}

function Show-Notes([string]$notes) {
    Write-Host '--- release notes ---' -ForegroundColor DarkGray
    Write-Host $(if ($notes) { $notes } else { '(empty)' })
    Write-Host '---------------------' -ForegroundColor DarkGray
}

function Main {
    Write-Host 'Google Drive Plus - release' -ForegroundColor Cyan

    # --- where we are ----------------------------------------------------------
    $branch = Invoke-Git rev-parse --abbrev-ref HEAD
    if (-not $NoCommit -and $branch -ne 'main') { throw "Releases are made from main; the current branch is $branch." }

    Write-Host 'Checking GitHub...'
    $ErrorActionPreference = 'Continue'
    & git -C $root fetch --quiet --tags origin
    $fetched = $LASTEXITCODE -eq 0
    $ErrorActionPreference = 'Stop'
    if (-not $fetched) {
        if (-not $NoCommit) { throw 'Cannot reach origin (GitHub). Check the connection and try again.' }
        Write-Host 'Cannot reach origin; using the tags known here.' -ForegroundColor Yellow
    } elseif (-not $NoCommit) {
        $behind = [int](Invoke-Git rev-list --count "HEAD..origin/$branch")
        if ($behind -gt 0) {
            throw "GitHub has $behind commit(s) on $branch that are not here. Run  git pull --rebase  first."
        }
    }

    $origMeta = Read-Text '_meta.lua'
    $m = [regex]::Match($origMeta, '(?m)^\s*version\s*=\s*"(\d+\.\d+\.\d+)"')
    if (-not $m.Success) { throw '_meta.lua has no line  version = "X.Y.Z"' }
    $current = $m.Groups[1].Value

    $released = @{}
    foreach ($t in (Invoke-Git tag -l 'v*')) { if ($t -match '^v(\d+\.\d+\.\d+)$') { $released[$Matches[1]] = $true } }
    $latest = $released.Keys | Sort-Object { [version]$_ } | Select-Object -Last 1
    if (-not $latest) { throw 'No release tag vX.Y.Z found. Give the first version: release.cmd 1.0.0' }
    $tag = "v$latest"

    $origChangelog = Read-Text 'CHANGELOG.md'
    $nl = if ($origChangelog.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [System.Collections.Generic.List[string]]($origChangelog -split '\r?\n')
    $top = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^## ') { $top = $i; break } }
    $reuse = $false
    if ($top -ge 0 -and $lines[$top] -match '^##\s+(\S+)') {
        $token = $Matches[1]
        if ($token -ieq 'Unreleased') { $reuse = $true }
        elseif ($token -match '^v?(\d+\.\d+\.\d+)$') {
            $v = $Matches[1]
            $reuse = -not $released.ContainsKey($v) -and [version]$v -gt [version]$latest
        }
    }
    $notes = if ($reuse) { Get-SectionText $lines $top } else { '' }

    # --- the new version -------------------------------------------------------
    $changes = Measure-Changes $tag $notes
    $b = [version]$latest
    $level = $changes.Level
    if ($Version) {
        switch -regex ($Version) {
            '^major$' { $level = 3; break }
            '^minor$' { $level = 2; break }
            '^patch$' { $level = 1; break }
            '^v?\d+\.\d+\.\d+$' { $level = -1; break }
            default { throw "Unknown version '$Version'. Use patch, minor, major or X.Y.Z." }
        }
    } elseif ($level -eq 0) {
        Write-Host ''
        Write-Host "The plugin code has not changed since $tag (documentation, tests and tools are not released)."
        Write-Host 'Nothing to release.'
        return 0
    }
    if ($level -lt 0) { $new = $Version.TrimStart('v', 'V') }
    elseif ($level -eq 3) { $new = "$($b.Major + 1).0.0" }
    elseif ($level -eq 2) { $new = "$($b.Major).$($b.Minor + 1).0" }
    else { $new = "$($b.Major).$($b.Minor).$($b.Build + 1)" }
    if (-not $Version -and [version]$current -gt [version]$new -and -not $released.ContainsKey($current)) {
        $new = $current   # set higher by hand in _meta.lua: keep it
    }
    if ($released.ContainsKey($new)) { throw "v$new is already released." }
    if ([version]$new -le [version]$latest) { throw "$new is not newer than the last release $tag." }

    # --- _meta.lua and CHANGELOG.md --------------------------------------------
    if ($current -ne $new) {
        $g = $m.Groups[1]
        Write-Text '_meta.lua' ($origMeta.Substring(0, $g.Index) + $new + $origMeta.Substring($g.Index + $g.Length))
    }
    $heading = "## $new $dash $(Get-Date -Format 'yyyy-MM-dd')"
    $drafted = -not $reuse
    if ($reuse) {
        $start = $top
        $lines[$start] = $heading
    } else {
        $draft = @(Invoke-Git log "$tag..HEAD" --no-merges '--format=%s' |
            Where-Object { $_ -and $_ -notmatch '^(Release \d|v?\d+(\.\d+)*$|wip$|update$|changes?$)' } |
            ForEach-Object { "- $_" })
        if ($draft.Count -eq 0) { $draft = @($changes.Labels | ForEach-Object { "- New: *$_*." }) }
        if ($draft.Count -eq 0) { $draft = @('- Fixes and improvements.') }
        $block = [string[]](@($heading, '') + $draft + @(''))
        if ($top -ge 0) {
            $start = $top
            $lines.InsertRange($start, $block)
        } else {
            while ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
            $lines.Add('')
            $start = $lines.Count
            $lines.AddRange($block)
        }
    }
    Write-Text 'CHANGELOG.md' ($lines -join $nl)
    $notes = Get-SectionText $lines $start

    # --- summary -----------------------------------------------------------------
    Write-Host ''
    Write-Host "Last release   $tag"
    Write-Host "New version    v$new  ($(if ($level -ge 0) { $levelNames[$level] } else { 'given' }))" -ForegroundColor Green
    Write-Host "Date           $(Get-Date -Format 'yyyy-MM-dd')"
    Write-Host 'Why:'
    if ($Version) { Write-Host "  asked for: $Version" }
    foreach ($r in $changes.Reasons) { Write-Host "  $r" }
    Write-Host ''
    Write-Host "_meta.lua      version = `"$new`"  ($(if ($current -eq $new) { 'already set' } else { "was $current" }))"
    Write-Host "CHANGELOG.md   $heading$(if ($drafted) { '  (new section, drafted automatically)' })"
    Write-Host ''
    Show-Notes $notes

    if ($NoCommit) {
        Write-Host ''
        Write-Host 'To release, commit and push with the tag:'
        Write-Host '  git add -A'
        Write-Host "  git commit -m `"Release $new`""
        Write-Host "  git tag v$new"
        Write-Host "  git push --atomic origin main v$new"
        return 0
    }

    # --- ask ---------------------------------------------------------------------
    $edited = $false
    while ($true) {
        Write-Host ''
        Write-Host 'Will be committed:'
        Invoke-Git status --short | ForEach-Object { Write-Host "  $_" }
        Write-Host ''
        $answer = Read-Host "[y] release v$new (commit, tag, push)   [e] edit the release notes   [n] cancel"
        if ($answer -match '^\s*(y|yes|a|ano)\s*$') { break }
        if ($answer -match '^\s*e') {
            Start-Process notepad.exe -ArgumentList ('"' + (Join-Path $root 'CHANGELOG.md') + '"')
            [void](Read-Host "Edit the $new section in Notepad, save it, then press Enter here")
            $edited = $true
            $lines = [System.Collections.Generic.List[string]]((Read-Text 'CHANGELOG.md') -split '\r?\n')
            $start = -1
            for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "^##\s+v?$([regex]::Escape($new))(\s|$)") { $start = $i; break } }
            if ($start -lt 0) { throw "CHANGELOG.md no longer has a section ## $new. Fix it and run release.cmd again." }
            $notes = Get-SectionText $lines $start
            Write-Host ''
            Show-Notes $notes
            continue
        }
        if ($edited) {
            Write-Host "Cancelled. Your edits are kept; release.cmd will use them next time (still v$new)."
        } else {
            Write-Text '_meta.lua' $origMeta
            Write-Text 'CHANGELOG.md' $origChangelog
            Write-Host 'Cancelled; _meta.lua and CHANGELOG.md are back as they were.'
        }
        return 1
    }
    if (-not $notes) { throw "The $new section in CHANGELOG.md is empty; the release needs a text." }

    # --- commit, tag, push -----------------------------------------------------
    Invoke-Git add -A
    & git -C $root diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        $msgFile = Join-Path ([System.IO.Path]::GetTempPath()) "gdriveplus-release-$new.txt"
        [System.IO.File]::WriteAllText($msgFile, "Release $new`n`n$notes`n", $utf8)
        try { Invoke-Git commit --quiet -F $msgFile } finally { Remove-Item $msgFile -ErrorAction SilentlyContinue }
    }
    Invoke-Git tag -a "v$new" -m "Release $new"
    Invoke-Git push --quiet --atomic origin main "v$new"

    Write-Host ''
    Write-Host "Done: v$new is pushed. GitHub now runs the tests and publishes the release (about a minute)." -ForegroundColor Green
    $url = Invoke-Git remote get-url origin
    if ($url -match 'github\.com[:/](.+?)(\.git)?$') {
        Write-Host "  progress: https://github.com/$($Matches[1])/actions"
        Write-Host "  release:  https://github.com/$($Matches[1])/releases/tag/v$new"
    }
    return 0
}

$savedEncoding = $null
try { $savedEncoding = [Console]::OutputEncoding; [Console]::OutputEncoding = $utf8 } catch { }
try {
    $code = Main
} catch {
    Write-Host ''
    Write-Host $_.Exception.Message -ForegroundColor Red
    $code = 1
} finally {
    if ($savedEncoding) { try { [Console]::OutputEncoding = $savedEncoding } catch { } }
}
exit $code
