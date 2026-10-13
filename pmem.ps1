#!/usr/bin/env pwsh
# pmem — project-memory 工具（PowerShell 实现）
#
# 与 pmem.sh 行为等价：同一份输入 → 逐字节相同的输出。
# 写出的文件一律 LF 换行、UTF-8 无 BOM。
#
# 子命令：
#   init  [目标项目目录]   在项目里建出 project-memory/ 骨架，并把本脚本装进 <pm>/scripts/
#   gen   [pm 目录]        重算索引与快照（先校验，校验不过就拒写）
#   check [pm 目录]        只校验，不写文件；有问题则以非零退出

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

# 让标准输出/错误用 UTF-8（无 BOM），与 .sh 的字节一致；失败也不致命。
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$PMEM_VERSION = '0.1.0'
$PMEM_INDEX_MAX = if ([string]::IsNullOrEmpty($env:PMEM_INDEX_MAX)) { '150' } else { $env:PMEM_INDEX_MAX }
$PMEM_RAW_BASE = if ([string]::IsNullOrEmpty($env:PMEM_RAW_BASE)) { 'https://raw.githubusercontent.com/arsonist-g/project-memory-kit/main' } else { $env:PMEM_RAW_BASE }

$GEN_MARK = '<!-- GENERATED — 由 pmem 生成，请勿手改 -->'
$HW_BEGIN = '<!-- HANDWRITTEN:BEGIN -->'
$HW_END   = '<!-- HANDWRITTEN:END -->'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:CHECK_FAIL = 0
$script:PM_ROOT = ''

# ---------- 输出 ----------
# error:/warn: 到 stderr；info 到 stdout。全部 LF。

function Out-Stdout([string]$s) { [Console]::Out.Write($s); [Console]::Out.Write("`n"); [Console]::Out.Flush() }
function Out-Stderr([string]$s) { [Console]::Error.Write($s); [Console]::Error.Write("`n"); [Console]::Error.Flush() }

function die([string]$msg)  { Out-Stderr "error: $msg"; exit 1 }
function warn([string]$msg) { Out-Stderr "warn:  $msg" }
function info([string]$msg) { Out-Stdout $msg }

function Show-Usage {
  $u = @(
    "pmem $PMEM_VERSION — project-memory 脚手架与索引生成器",
    "",
    "用法：",
    "  pmem.sh init  [目标项目目录]   建 project-memory/ 骨架（默认当前目录）",
    "  pmem.sh gen   [pm 目录]        校验并重算索引与快照（默认 ./project-memory）",
    "  pmem.sh check [pm 目录]        只校验（默认 ./project-memory）",
    "",
    "环境变量：",
    "  PMEM_INDEX_MAX   域索引超过这个行数就退化为「请直接 grep」的提示（默认 150）",
    "  PMEM_RAW_BASE    脚本自身的下载地址前缀，用于 init 时把脚本装进项目",
    "",
    "校验项（check / gen 都会跑）：",
    "  1. 条目 id 不重复",
    "  2. front-matter 必填字段齐全，status 取值合法",
    "  3. supersedes / superseded-by 双向一致",
    "  4. evidence 引用的路径存在",
    "  5. CONTEXT.md 行数 <= 100"
  )
  Out-Stdout ($u -join "`n")
}

# ---------- 文件读写 ----------
# 读：ReadAllText（.NET 默认按 UTF-8 读并识别/剥掉 BOM）。
# 写：WriteAllText + UTF8Encoding($false)，保证 LF、无 BOM。

function Read-FileText([string]$path) {
  return [System.IO.File]::ReadAllText($path)
}

# 按 \n 切行：文件末尾的换行不产生空行（等价于 awk 的记录切分）。
function Split-Lines([string]$text) {
  if ($text.Length -eq 0) { return @() }
  $t = $text
  if ($t.EndsWith("`n")) { $t = $t.Substring(0, $t.Length - 1) }
  return ($t -split "`n")
}

function Write-FileLF([string]$path, [string]$text) {
  $dir = [System.IO.Path]::GetDirectoryName($path)
  if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
  [System.IO.File]::WriteAllText($path, $text, $script:Utf8NoBom)
}

function Write-FileAtomic([string]$path, [string]$text) {
  $tmp = "$path.tmp"
  Write-FileLF $tmp $text
  [System.IO.File]::Copy($tmp, $path, $true)
  [System.IO.File]::Delete($tmp)
}

function Test-Exists([string]$p) {
  return ([System.IO.File]::Exists($p) -or [System.IO.Directory]::Exists($p))
}

# ---------- front-matter 读取 ----------
# front-matter 是文件开头第一行 --- 到下一个 --- 之间的部分。

function Get-FmBlock([string]$path) {
  if (-not [System.IO.File]::Exists($path)) { return @() }
  $lines = @(Split-Lines (Read-FileText $path))
  $out = New-Object 'System.Collections.Generic.List[string]'
  $infm = $false
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($i -eq 0 -and $line -cmatch '^---\s*$') { $infm = $true; continue }
    if ($infm -and $line -cmatch '^---\s*$') { break }
    if ($infm) { [void]$out.Add($line) }
  }
  return @($out.ToArray())
}

function Get-FmGet([string]$path, [string]$key) {
  foreach ($line in @(Get-FmBlock $path)) {
    $l = $line -replace '^\s+', ''
    if ($l -cmatch "^$key\s*:") {
      $v = $l
      $v = $v -replace '^[^:]*:\s*', ''
      $v = $v -replace '\s+$', ''
      return $v
    }
  }
  return ''
}

function Test-FmHas([string]$path, [string]$key) {
  foreach ($line in @(Get-FmBlock $path)) {
    $l = $line -replace '^\s+', ''
    if ($l -cmatch "^$key\s*:") { return $true }
  }
  return $false
}

# 把 [a, b] / [] / 裸值 统一成「每项一个」的数组。
function Get-FmList([string]$path, [string]$key) {
  $v = Get-FmGet $path $key
  if ([string]::IsNullOrEmpty($v)) { return @() }
  $v = $v -replace '^\[', ''
  $v = $v -replace '\]$', ''
  $res = @()
  foreach ($p in ($v -split ',')) {
    $t = $p.Trim()
    if ($t -ne '') { $res += $t }
  }
  return @($res)
}

# ---------- 目录约定 ----------

function Sort-Ordinal([string[]]$items) {
  $arr = @($items)
  if ($arr.Count -eq 0) { return @() }
  $list = New-Object 'System.Collections.Generic.List[string]'
  foreach ($i in $arr) { [void]$list.Add([string]$i) }
  $list.Sort([System.StringComparer]::Ordinal)
  return @($list.ToArray())
}

function Get-SubDirs([string]$parent) {
  if (-not [System.IO.Directory]::Exists($parent)) { return @() }
  return @(Sort-Ordinal @([System.IO.Directory]::GetDirectories($parent)))
}

function Get-FilesLike([string]$dir, [string]$pattern, [string]$exclude) {
  if (-not [System.IO.Directory]::Exists($dir)) { return @() }
  $res = @()
  foreach ($f in [System.IO.Directory]::GetFiles($dir)) {
    $n = [System.IO.Path]::GetFileName($f)
    if ($n -clike $pattern) {
      if ($exclude -and $n -ceq $exclude) { continue }
      $res += $f
    }
  }
  return @(Sort-Ordinal $res)
}

function Get-DecDirs([string]$pm)    { return @(Get-SubDirs (Join-Path $pm 'decisions')) }
function Get-DecEntries([string]$d)  { return @(Get-FilesLike $d 'DEC-*.md' '') }
function Get-ConEntries([string]$pm) { return @(Get-FilesLike (Join-Path $pm 'constraints') 'CONSTRAINT-*.md' '') }
function Get-QEntries([string]$pm)   { return @(Get-FilesLike (Join-Path $pm 'questions') 'Q-*.md' '') }
function Get-Topics([string]$pm)     { return @(Get-SubDirs (Join-Path $pm 'research')) }
function Get-Reports([string]$d)     { return @(Get-FilesLike $d '*.md' '_index.md') }

function rel([string]$p) {
  $root = $script:PM_ROOT
  if ($root -and $p.StartsWith($root)) {
    return $p.Substring($root.Length).TrimStart('\', '/')
  }
  return $p
}

# ---------- 校验 ----------

function fail([string]$msg) {
  Out-Stderr "  [FAIL] $msg"
  $script:CHECK_FAIL = $script:CHECK_FAIL + 1
}

$script:VALID_STATUS = @{
  'dec:proposed'    = $true; 'dec:accepted' = $true; 'dec:superseded' = $true; 'dec:deprecated' = $true
  'con:active'      = $true; 'con:retired'  = $true
  'q:open'          = $true; 'q:resolved'   = $true; 'q:dropped'      = $true
  'rep:open'        = $true; 'rep:concluded' = $true; 'rep:superseded' = $true
}

function Test-ValidStatus([string]$t, [string]$s) {
  return $script:VALID_STATUS.ContainsKey("$t`:$s")
}

function Require-Fields([string]$f, [string]$t, [string[]]$fields) {
  foreach ($k in $fields) {
    if (-not (Test-FmHas $f $k)) { fail "$(rel $f) 缺必填字段 '$k'" }
  }
  $s = Get-FmGet $f 'status'
  if ($s -ne '' -and -not (Test-ValidStatus $t $s)) {
    fail "$(rel $f) 的 status='$s' 不是合法取值"
  }
}

# grep -rl --include='DEC-*.md' "^id:[[:space:]]*<sup>[[:space:]]*$" decisions | head -1
function Find-DecById([string]$id) {
  $base = Join-Path $script:PM_ROOT 'decisions'
  if (-not [System.IO.Directory]::Exists($base)) { return '' }
  $files = @(Get-ChildItem -LiteralPath $base -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -clike 'DEC-*.md' } | Sort-Object FullName)
  $pat = "^id:\s*$([regex]::Escape($id))\s*$"
  foreach ($file in $files) {
    foreach ($line in @(Split-Lines (Read-FileText $file.FullName))) {
      if ($line -cmatch $pat) { return $file.FullName }
    }
  }
  return ''
}

function Test-ListHas([string[]]$list, [string]$val) {
  foreach ($x in @($list)) { if ($x -ceq $val) { return $true } }
  return $false
}

function Invoke-Check([string]$pmDir) {
  $script:PM_ROOT = (Resolve-Path -LiteralPath $pmDir).Path
  $script:CHECK_FAIL = 0
  info "校验 $script:PM_ROOT"

  # --- 1. id 不重复 + 2. 必填字段 ---
  $IDS = ''
  foreach ($d in @(Get-DecDirs $script:PM_ROOT)) {
    $dom = [System.IO.Path]::GetFileName($d)
    $about = Join-Path $d '_about.md'
    if (-not [System.IO.File]::Exists($about)) {
      fail "decisions/$dom/ 缺 _about.md（域描述，路由表要用）"
    }
    if ([System.IO.File]::Exists($about)) {
      if (-not (Test-FmHas $about 'scope')) { fail "decisions/$dom/_about.md 缺必填字段 'scope'" }
    }
    foreach ($f in @(Get-DecEntries $d)) {
      Require-Fields $f 'dec' @('id', 'title', 'status', 'date', 'summary')
      $id = Get-FmGet $f 'id'
      if ($id -eq '') { continue }
      if ($IDS.Contains("|$id|")) { fail "$(rel $f) 的 id '$id' 重复" }
      $IDS += "|$id|"
      if (Test-FmHas $f 'domain') { fail "$(rel $f) 不该写 domain 字段（域由所在目录决定）" }
    }
  }

  foreach ($f in @(Get-ConEntries $script:PM_ROOT)) {
    Require-Fields $f 'con' @('id', 'status', 'date', 'statement')
    $id = Get-FmGet $f 'id'
    if ($id -eq '') { continue }
    if ($IDS.Contains("|$id|")) { fail "$(rel $f) 的 id '$id' 重复" }
    $IDS += "|$id|"
  }

  foreach ($f in @(Get-QEntries $script:PM_ROOT)) {
    Require-Fields $f 'q' @('id', 'status', 'date', 'question')
    $id = Get-FmGet $f 'id'
    if ($id -eq '') { continue }
    if ($IDS.Contains("|$id|")) { fail "$(rel $f) 的 id '$id' 重复" }
    $IDS += "|$id|"
  }

  foreach ($t in @(Get-Topics $script:PM_ROOT)) {
    foreach ($f in @(Get-Reports $t)) {
      Require-Fields $f 'rep' @('title', 'date', 'status')
    }
  }

  # --- 3. supersedes / superseded-by 双向一致 ---
  foreach ($d in @(Get-DecDirs $script:PM_ROOT)) {
    foreach ($f in @(Get-DecEntries $d)) {
      $id = Get-FmGet $f 'id'
      if ($id -eq '') { continue }
      foreach ($sup in @(Get-FmList $f 'supersedes')) {
        $target = Find-DecById $sup
        if ($target -eq '') {
          fail "$(rel $f) supersedes 指向不存在的 $sup"
        } elseif (-not (Test-ListHas @(Get-FmList $target 'superseded-by') $id)) {
          fail "$(rel $f) 说取代 $sup，但 $(rel $target) 没写 superseded-by: $id"
        }
      }
      foreach ($sby in @(Get-FmList $f 'superseded-by')) {
        $target = Find-DecById $sby
        if ($target -eq '') {
          fail "$(rel $f) superseded-by 指向不存在的 $sby"
        } elseif (-not (Test-ListHas @(Get-FmList $target 'supersedes') $id)) {
          fail "$(rel $f) 说被 $sby 取代，但 $(rel $target) 没写 supersedes: $id"
        }
      }
    }
  }

  # --- 4. evidence 路径存在 ---
  foreach ($d in @(Get-DecDirs $script:PM_ROOT)) {
    foreach ($f in @(Get-DecEntries $d)) {
      foreach ($e in @(Get-FmList $f 'evidence')) {
        if (-not (Test-Exists (Join-Path $script:PM_ROOT $e))) {
          fail "$(rel $f) 的 evidence 指向不存在的路径 '$e'"
        }
      }
    }
  }

  # --- 5. CONTEXT.md 行数 ---
  $ctx = Join-Path $script:PM_ROOT 'CONTEXT.md'
  if ([System.IO.File]::Exists($ctx)) {
    $n = ([regex]::Matches((Read-FileText $ctx), "`n")).Count
    if ($n -gt 100) { fail "CONTEXT.md 有 $n 行，超过 100 行上限" }
  }

  if ($script:CHECK_FAIL -eq 0) {
    info "校验通过"
    return $true
  }
  Out-Stderr "error: 校验未通过，$($script:CHECK_FAIL) 处问题"
  return $false
}

# ---------- 生成 ----------

function New-DecisionsIndex([string]$pm) {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append($GEN_MARK + "`n`n")
  [void]$sb.Append("# 决策入口表`n`n")
  [void]$sb.Append("每次开工必读。本文件只登记**入口**，不登记全体：域一行，条目靠域内 grep。`n`n")
  [void]$sb.Append("## 域路由`n`n")
  [void]$sb.Append("| 域 | 条目数 | 涵盖 |`n|---|---|---|`n")

  $found = 0
  foreach ($d in @(Get-DecDirs $pm)) {
    $dom = [System.IO.Path]::GetFileName($d)
    $cnt = @(Get-DecEntries $d).Count
    $scope = Get-FmGet (Join-Path $d '_about.md') 'scope'
    if ($scope -eq '') { $scope = '(未填 scope)' }
    [void]$sb.Append("| ``$dom`` | $cnt | $scope |`n")
    $found = 1
  }
  if ($found -ne 1) { [void]$sb.Append("| —— | 0 | 尚无决策条目 |`n") }

  [void]$sb.Append("`n## 活约束（全文）`n`n")
  $n = 0
  foreach ($f in @(Get-ConEntries $pm)) {
    if ((Get-FmGet $f 'status') -ne 'active') { continue }
    $n = $n + 1
    [void]$sb.Append("- **$(Get-FmGet $f 'id')** — $(Get-FmGet $f 'statement')`n")
  }
  if ($n -le 0) { [void]$sb.Append("无。`n") }

  [void]$sb.Append("`n## 开放问题`n`n")
  $n = 0
  foreach ($f in @(Get-QEntries $pm)) {
    if ((Get-FmGet $f 'status') -ne 'open') { continue }
    $n = $n + 1
    [void]$sb.Append("- $(Get-FmGet $f 'id') $(Get-FmGet $f 'question')`n")
  }
  if ($n -le 0) { [void]$sb.Append("无。`n") }

  Write-FileAtomic (Join-Path $pm 'DECISIONS.md') $sb.ToString()
}

function New-DomainIndex([string]$dir, [string]$name) {
  $out = Join-Path $dir '_index.md'
  $cnt = @(Get-DecEntries $dir).Count
  if ($cnt -gt [int]$PMEM_INDEX_MAX) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($GEN_MARK + "`n`n")
    [void]$sb.Append("# $name`n`n")
    [void]$sb.Append("本域有 $cnt 条，超过 $PMEM_INDEX_MAX 行的索引上限，已退化为提示。`n`n")
    [void]$sb.Append("**不要读本文件，直接 grep：**`n`n")
    [void]$sb.Append('```sh' + "`n")
    [void]$sb.Append('rg -l "^(tags|status|summary):.*<关键词>" decisions/' + $name + '/' + "`n")
    [void]$sb.Append('```' + "`n")
    Write-FileAtomic $out $sb.ToString()
    return
  }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append($GEN_MARK + "`n`n")
  [void]$sb.Append("# $name`n`n")
  [void]$sb.Append((Get-FmGet (Join-Path $dir '_about.md') 'scope') + "`n")
  [void]$sb.Append("`n| ID | 状态 | 摘要 | 日期 |`n|---|---|---|---|`n")
  foreach ($f in @(Get-DecEntries $dir)) {
    $base = [System.IO.Path]::GetFileName($f)
    [void]$sb.Append("| [$(Get-FmGet $f 'id')]($base) | $(Get-FmGet $f 'status') | $(Get-FmGet $f 'summary') | $(Get-FmGet $f 'date') |`n")
  }
  Write-FileAtomic $out $sb.ToString()
}

function New-ResearchIndex([string]$pm) {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append($GEN_MARK + "`n`n")
  [void]$sb.Append("# research 索引`n`n")
  [void]$sb.Append("调研与验证报告的主题总表。**报告本体只读归档**：结论变了写新的一份，不改旧的。`n`n")
  [void]$sb.Append("| 主题 | 报告数 |`n|---|---|`n")
  $n = 0
  foreach ($t in @(Get-Topics $pm)) {
    $top = [System.IO.Path]::GetFileName($t)
    $c = @(Get-Reports $t).Count
    [void]$sb.Append("| [$top]($top/_index.md) | $c |`n")
    $n = 1
  }
  if ($n -ne 1) { [void]$sb.Append("| —— | 0 |`n") }
  Write-FileAtomic (Join-Path $pm 'research/_index.md') $sb.ToString()

  foreach ($t in @(Get-Topics $pm)) {
    $top = [System.IO.Path]::GetFileName($t)
    $sb2 = New-Object System.Text.StringBuilder
    [void]$sb2.Append($GEN_MARK + "`n`n")
    [void]$sb2.Append("# $top`n`n")
    [void]$sb2.Append("| 报告 | 日期 | 状态 | 回答的问题 |`n|---|---|---|---|`n")
    foreach ($f in @(Get-Reports $t)) {
      $base = [System.IO.Path]::GetFileName($f)
      [void]$sb2.Append("| [$(Get-FmGet $f 'title')]($base) | $(Get-FmGet $f 'date') | $(Get-FmGet $f 'status') | $(Get-FmGet $f 'questions') |`n")
    }
    Write-FileAtomic (Join-Path $t '_index.md') $sb2.ToString()
  }
}

function New-Context([string]$pm) {
  $ctx = Join-Path $pm 'CONTEXT.md'
  if (-not [System.IO.File]::Exists($ctx)) { return }

  # 保留手写块（含两行标记本身）。块外的一切都是生成区，会被重写。
  $p = $false
  $hw = @()
  foreach ($ln in @(Split-Lines (Read-FileText $ctx))) {
    if ($ln.Contains($HW_BEGIN)) { $p = $true }
    if ($p) { $hw += $ln }
    if ($p -and $ln.Contains($HW_END)) { break }
  }
  $hwText = ''
  if ($hw.Count -gt 0) { $hwText = ($hw -join "`n") + "`n" }

  # 源仓 HEAD：记忆层是子仓时取 superproject，否则取自身
  $src = ''
  try {
    $o = & git -C $pm rev-parse --show-superproject-working-tree 2>$null
    if ($LASTEXITCODE -eq 0 -and $o) { $src = ([string](@($o)[0])).Trim() }
  } catch { $src = '' }
  if (-not $src) { $src = $pm }

  $sha = '??????'
  try {
    $o2 = & git -C $src rev-parse --short=6 HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $o2) { $sha = ([string](@($o2)[0])).Trim() }
  } catch { }

  $dirty = ''
  try {
    $o3 = & git -C $src status --porcelain 2>$null
    if ($o3) { $dirty = ' · +uncommitted' }
  } catch { }

  $ndec = 0
  foreach ($d in @(Get-DecDirs $pm)) { $ndec = $ndec + @(Get-DecEntries $d).Count }
  $ndom = @(Get-DecDirs $pm).Count
  $nq = 0
  foreach ($f in @(Get-QEntries $pm)) { if ((Get-FmGet $f 'status') -eq 'open') { $nq = $nq + 1 } }
  $nrep = 0
  foreach ($t in @(Get-Topics $pm)) { $nrep = $nrep + @(Get-Reports $t).Count }

  $today = (Get-Date).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append($GEN_MARK + "`n")
  [void]$sb.Append("> 更新于 $today · HEAD $sha$dirty`n")
  [void]$sb.Append("> 决策 $ndec 条 / $ndom 个域 · 开放问题 $nq 条 · 调研报告 $nrep 份`n`n")
  [void]$sb.Append($hwText)
  Write-FileAtomic $ctx $sb.ToString()
}

function Invoke-Gen([string]$pm) {
  if (-not (Invoke-Check $pm)) { die "校验未通过，已拒绝写入（先修上面的问题）" }
  $script:PM_ROOT = (Resolve-Path -LiteralPath $pm).Path
  New-DecisionsIndex $script:PM_ROOT
  foreach ($d in @(Get-DecDirs $script:PM_ROOT)) {
    New-DomainIndex $d ([System.IO.Path]::GetFileName($d))
  }
  New-ResearchIndex $script:PM_ROOT
  New-Context $script:PM_ROOT
  info "已生成：DECISIONS.md、各 decisions/*/_index.md、research/**/_index.md、CONTEXT.md"
  return $true
}

function Require-Pm([string]$d) {
  if (-not [System.IO.Directory]::Exists($d)) { die "找不到 project-memory 目录：$d" }
  if (-not [System.IO.File]::Exists((Join-Path $d 'DECISIONS.md'))) { die "$d 不像记忆层（缺 DECISIONS.md）" }
}

# ---------- init ----------

function Write-IfAbsent([string]$path, [string]$content) {
  if (Test-Exists $path) { warn "已存在，跳过：$path"; return $false }
  $dir = [System.IO.Path]::GetDirectoryName($path)
  if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
  [System.IO.File]::WriteAllText($path, $content, $script:Utf8NoBom)
  return $true
}

function Get-SelfDir {
  $p = $PSCommandPath
  if ([string]::IsNullOrEmpty($p)) { $p = $MyInvocation.MyCommand.Path }
  if ([string]::IsNullOrEmpty($p)) { return $null }
  return [System.IO.Path]::GetDirectoryName($p)
}

function Install-Script([string]$dir, [string]$name) {
  $dst = Join-Path $dir $name
  if (Test-Exists $dst) { return $true }
  $selfDir = Get-SelfDir
  if ($selfDir -and [System.IO.File]::Exists((Join-Path $selfDir $name))) {
    [System.IO.File]::Copy((Join-Path $selfDir $name), $dst, $true)
  } else {
    try {
      $wc = New-Object System.Net.WebClient
      $wc.DownloadFile("$PMEM_RAW_BASE/$name", $dst)
    } catch {
      warn "装不进 $name（没能确定脚本位置，也没能下载）"
      return $false
    }
  }
  return $true
}

$script:ABOUT_GENERAL = (@(
    '---',
    'domain: general',
    'scope: 尚未归类的决策',
    '---'
  ) -join "`n") + "`n"

$script:CONTEXT_INIT = (@(
    '<!-- GENERATED — 由 pmem 生成，请勿手改本行以下至 HANDWRITTEN 标记之间 -->',
    '',
    '<!-- HANDWRITTEN:BEGIN -->',
    '# 项目一句话',
    '',
    '（一句话说清这个项目是什么。）',
    '',
    '# 当前状态',
    '',
    '- （项目现在到哪了。）',
    '',
    '# 下次第一件事',
    '',
    '（下一轮开工先做什么。）',
    '',
    '# 指针',
    '',
    '- 设计：`spec/`',
    '- 证据：`research/`',
    '<!-- HANDWRITTEN:END -->'
  ) -join "`n") + "`n"

$script:DECISIONS_INIT = (@(
    '<!-- GENERATED — 由 pmem 生成，请勿手改 -->',
    '',
    '# 决策入口表',
    '',
    '跑 `scripts/pmem.sh gen` 生成。'
  ) -join "`n") + "`n"

function Invoke-Init([string]$proj) {
  if (-not [System.IO.Directory]::Exists($proj)) {
    try { [void][System.IO.Directory]::CreateDirectory($proj) } catch { die "建不了目录：$proj" }
  }
  $proj = (Resolve-Path -LiteralPath $proj).Path
  $pm = Join-Path $proj 'project-memory'
  if (Test-Exists $pm) { die "$pm 已存在，不覆盖。要重建请先自行处理。" }

  foreach ($sub in @('decisions', 'constraints', 'questions', 'research', 'spec', 'task-tracker', 'scripts')) {
    [void][System.IO.Directory]::CreateDirectory((Join-Path $pm $sub))
  }
  foreach ($d in @('constraints', 'questions', 'spec', 'task-tracker')) {
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $pm $d) '.gitkeep'), '', $script:Utf8NoBom)
  }

  [void](Write-IfAbsent (Join-Path $pm 'decisions/general/_about.md') $script:ABOUT_GENERAL)
  [void](Write-IfAbsent (Join-Path $pm 'CONTEXT.md') $script:CONTEXT_INIT)
  [void](Write-IfAbsent (Join-Path $pm 'DECISIONS.md') $script:DECISIONS_INIT)

  [void](Install-Script (Join-Path $pm 'scripts') 'pmem.sh')
  [void](Install-Script (Join-Path $pm 'scripts') 'pmem.ps1')

  if (-not (Invoke-Gen $pm)) { die "初始化后校验未通过" }

  info ""
  info "已建好：$pm"
  info "  scripts/pmem.sh  ·  scripts/pmem.ps1"
  info "下一步：编辑 CONTEXT.md 的 HANDWRITTEN 块；写第一条决策到 decisions/<域>/DEC-001-<slug>.md"
}

# ---------- 入口 ----------

$argv = @($args)
$cmd = if ($argv.Count -ge 1) { [string]$argv[0] } else { '' }

if ($cmd -eq 'init') {
  $t = if ($argv.Count -ge 2) { [string]$argv[1] } else { '.' }
  Invoke-Init $t
  exit 0
} elseif ($cmd -eq 'gen') {
  $t = if ($argv.Count -ge 2) { [string]$argv[1] } else { './project-memory' }
  Require-Pm $t
  Invoke-Gen $t
  exit 0
} elseif ($cmd -eq 'check') {
  $t = if ($argv.Count -ge 2) { [string]$argv[1] } else { './project-memory' }
  Require-Pm $t
  if (Invoke-Check $t) { exit 0 } else { exit 1 }
} elseif ($cmd -eq '' -or $cmd -eq '-h' -or $cmd -eq '--help' -or $cmd -eq 'help') {
  Show-Usage
  exit 0
} else {
  die "未知子命令：$cmd（试试 --help）"
}
