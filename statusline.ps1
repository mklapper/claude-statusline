#!/usr/bin/env pwsh
# Claude Code statusline — model · effort · permission mode · git · context · usage
#
# All data is local: the session JSON arrives on stdin (pushed by Claude Code, no
# API call), and permission mode is read from the transcript file (the same JSONL
# Claude Code already maintains). Nothing here contacts the network.
#
# PowerShell 7+ only (uses ?. and ?? — the null-conditional and null-coalescing
# operators introduced in PS 7.0). No jq dependency: ConvertFrom-Json is native.
#
# Tune this: the raw context %% that we treat as "100% full". Claude Code
# auto-compacts before the hard window limit, so scaling against this makes the
# displayed bar hit 100% right when auto-compact is imminent.
$CompactAt = 92

# Emoji/box-drawing glyphs need UTF-8 out, or a narrow console codepage can mangle
# or crash on them — set explicitly rather than trusting the inherited codepage.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$raw = [Console]::In.ReadToEnd()
$json = $raw | ConvertFrom-Json

$Model = $json.model?.display_name ?? '?'
$Effort = $json.effort?.level
$CtxRaw = $json.context_window?.used_percentage ?? 0
$FiveH = $json.rate_limits?.five_hour?.used_percentage
$SevenD = $json.rate_limits?.seven_day?.used_percentage
$ResetsAt = $json.rate_limits?.five_hour?.resets_at
$SessionId = $json.session_id
$Transcript = $json.transcript_path

# --- colors ---------------------------------------------------------------
$ESC = "`e"
$RESET = "$ESC[0m"; $DIM = "$ESC[2m"
$CYAN = "$ESC[36m"; $GREEN = "$ESC[32m"; $YELLOW = "$ESC[33m"; $RED = "$ESC[31m"
$MAGENTA = "$ESC[35m"; $BLUE = "$ESC[34m"; $BOLDRED = "$ESC[1;31m"

function Get-PctColor([int]$Pct) {
  if ($Pct -ge 90) { $RED }
  elseif ($Pct -ge 70) { $YELLOW }
  else { $GREEN }
}

# --- permission mode (last value in the transcript) ------------------------
# A single forward pass keeping the last match is enough here — no need for the
# bash script's tac+head reverse-read trick.
$ModeSeg = ''
if (-not [string]::IsNullOrEmpty($Transcript) -and (Test-Path -LiteralPath $Transcript -PathType Leaf)) {
  $Mode = $null
  foreach ($line in Get-Content -LiteralPath $Transcript) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $entry = $line | ConvertFrom-Json -ErrorAction Stop
      if ($null -ne $entry.permissionMode) { $Mode = $entry.permissionMode }
    } catch { continue }
  }
  switch ($Mode) {
    'plan'              { $ModeSeg = " ${CYAN}PLAN${RESET}" }
    'acceptEdits'        { $ModeSeg = " ${YELLOW}accept-edits${RESET}" }
    'bypassPermissions'  { $ModeSeg = " ${RED}BYPASS${RESET}" }
    { $_ -eq 'default' -or [string]::IsNullOrEmpty($_) } { $ModeSeg = '' }
    default              { $ModeSeg = " ${MAGENTA}${Mode}${RESET}" }
  }
}

# --- git (branch + dirty state), cached 5s per session so it never lags typing
# Buckets are mutually exclusive per file, priority: conflict > deleted > staged
# > modified — same priority order as the bash version.
$GitSeg = ''
$Cache = Join-Path $env:TEMP "claude-statusline-git-$($SessionId ?? 'none')"

function Test-CacheStale([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $true }
  ((Get-Date) - (Get-Item -LiteralPath $Path).LastWriteTime).TotalSeconds -gt 5
}

if (Test-CacheStale $Cache) {
  $null = git rev-parse --git-dir 2>$null
  if ($LASTEXITCODE -eq 0) {
    $GitDir = git rev-parse --git-dir 2>$null
    $BrStatus = @(git status --porcelain=v1 --branch 2>$null)
    $BranchLine = if ($BrStatus.Count -gt 0) { $BrStatus[0] } else { '' }
    $Rest = $BranchLine -replace '^## ', ''

    $Detached = 0; $Name = ''
    if ($Rest -like 'HEAD (no branch)*') {
      $Detached = 1
      $Name = git rev-parse --short HEAD 2>$null
    } elseif ($Rest -like 'No commits yet on *') {
      # A repo with no commits reports "## No commits yet on main" — no "..."
      # separator, so splitting on it would leave the whole sentence and render
      # it as if it were the branch name.
      $Name = $Rest -replace '^No commits yet on ', ''
    } else {
      $Name = ($Rest -split '\.\.\.')[0]
    }

    $Ahead = if ($Rest -match 'ahead (\d+)') { [int]$Matches[1] } else { 0 }
    $Behind = if ($Rest -match 'behind (\d+)') { [int]$Matches[1] } else { 0 }

    $C = 0; $S = 0; $Mod = 0; $Del = 0; $U = 0
    $FileLines = if ($BrStatus.Count -gt 1) { $BrStatus[1..($BrStatus.Count - 1)] } else { @() }
    foreach ($line in $FileLines) {
      if ([string]::IsNullOrEmpty($line)) { continue }
      $x = $line.Substring(0, 1); $y = $line.Substring(1, 1)
      if ($x -eq '?' -and $y -eq '?') {
        $U++
      } elseif ($x -eq 'U' -or $y -eq 'U' -or ($x -eq 'A' -and $y -eq 'A') -or ($x -eq 'D' -and $y -eq 'D')) {
        $C++
      } elseif ($x -eq 'D' -or $y -eq 'D') {
        $Del++
      } elseif ($x -ne ' ') {
        $S++
      } elseif ($y -ne ' ') {
        $Mod++
      }
    }

    $OpState = ''
    if ((Test-Path -LiteralPath (Join-Path $GitDir 'rebase-merge')) -or (Test-Path -LiteralPath (Join-Path $GitDir 'rebase-apply'))) {
      $OpState = 'REBASE'
    } elseif (Test-Path -LiteralPath (Join-Path $GitDir 'MERGE_HEAD')) {
      $OpState = 'MERGE'
    } elseif (Test-Path -LiteralPath (Join-Path $GitDir 'CHERRY_PICK_HEAD')) {
      $OpState = 'CHERRY-PICK'
    }

    $Stash = @(git stash list 2>$null).Count

    Set-Content -LiteralPath $Cache -Value @($Detached, $Name, $Ahead, $Behind, $OpState, $C, $S, $Mod, $Del, $U, $Stash)
  } else {
    Set-Content -LiteralPath $Cache -Value @('0', '', '0', '0', '', '0', '0', '0', '0', '0', '0')
  }
}

$GF = Get-Content -LiteralPath $Cache
$Detached = $GF[0]; $Name = $GF[1]; $Ahead = [int]$GF[2]; $Behind = [int]$GF[3]; $OpState = $GF[4]
$C = [int]$GF[5]; $S = [int]$GF[6]; $Mod = [int]$GF[7]; $Del = [int]$GF[8]; $U = [int]$GF[9]; $Stash = [int]$GF[10]

if ($Name) {
  $BrColor = if ($C -gt 0) { $RED }
             elseif ($S -gt 0 -or $Mod -gt 0 -or $Del -gt 0 -or $U -gt 0) { $YELLOW }
             else { $GREEN }

  $BranchChunk = if ($Detached -eq '1') { "${MAGENTA}⚠ ${Name}${RESET}" } else { "🌿 ${BrColor}${Name}${RESET}" }

  $AB = ''
  if ($Ahead -gt 0) { $AB += " ${CYAN}↑${Ahead}${RESET}" }
  if ($Behind -gt 0) { $AB += " ${CYAN}↓${Behind}${RESET}" }

  $OpSeg = if ($OpState) { " ${MAGENTA}[${OpState}]${RESET}" } else { '' }

  $Dirty = ''
  if ($C -gt 0) { $Dirty += " ${BOLDRED}!!${C}${RESET}" }
  if ($S -gt 0) { $Dirty += " ${GREEN}+${S}${RESET}" }
  if ($Mod -gt 0) { $Dirty += " ${YELLOW}~${Mod}${RESET}" }
  if ($Del -gt 0) { $Dirty += " ${RED}-${Del}${RESET}" }
  if ($U -gt 0) { $Dirty += " ${BLUE}?${U}${RESET}" }

  $StashSeg = if ($Stash -gt 0) { " ${DIM}·${RESET} ${DIM}📦${Stash}${RESET}" } else { '' }

  $GitSeg = " ${DIM}·${RESET} ${BranchChunk}${AB}${OpSeg}${Dirty}${StashSeg}"
}

# --- context bar (scaled to the auto-compact threshold) ---------------------
$CtxInt = [int][math]::Truncate([double]$CtxRaw)
$Scaled = [int][math]::Truncate($CtxInt * 100 / $CompactAt)
if ($Scaled -gt 100) { $Scaled = 100 }
$Filled = [int][math]::Truncate($Scaled / 10)
$Empty = 10 - $Filled
$Bar = ('█' * $Filled) + ('░' * $Empty)
$CtxColor = Get-PctColor $Scaled

# --- usage + reset timer (Pro/Max only; absent otherwise) -------------------
$UsageSeg = ''
if ($null -ne $FiveH) {
  $Fh = [int][math]::Truncate([double]$FiveH)
  $UsageSeg += " ${DIM}·${RESET} 5h $(Get-PctColor $Fh)${Fh}%${RESET}"
}
if ($null -ne $ResetsAt) {
  $Rem = [int64]$ResetsAt - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  if ($Rem -gt 0) {
    $H = [int][math]::Truncate($Rem / 3600)
    $Min = [int][math]::Truncate(($Rem % 3600) / 60)
    $UsageSeg += " ${DIM}·${RESET} ${DIM}⟳ ${H}h${Min}m${RESET}"
  }
}
if ($null -ne $SevenD) {
  $Sd = [int][math]::Truncate([double]$SevenD)
  $UsageSeg += " ${DIM}·${RESET} 7d $(Get-PctColor $Sd)${Sd}%${RESET}"
}

# --- effort tag ---------------------------------------------------------------
$EffortSeg = if (-not [string]::IsNullOrEmpty($Effort)) { "${DIM}·${RESET}${MAGENTA}$($Effort.ToUpper())${RESET}" } else { '' }

# --- render (two lines) --------------------------------------------------------
Write-Output "${CYAN}${Model}${RESET}${EffortSeg}${ModeSeg}${GitSeg}"
Write-Output "${CtxColor}${Bar}${RESET} ${Scaled}% ctx${UsageSeg}"
