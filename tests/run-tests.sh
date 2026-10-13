#!/usr/bin/env bash
# pmem 自测：语法 → 冒烟 → 五项校验负例 → .sh / .ps1 产出一致性
#
# 用法：bash tests/run-tests.sh
# 退出码非零表示有失败。

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SH="$ROOT/pmem.sh"
PS1FILE="$ROOT/pmem.ps1"   # 注意：不能叫 PS1，那是 bash 的提示符保留变量
# PowerShell 不认 Git Bash 的 /d/... 路径，转成 Windows 形式
PS1WIN=$(cygpath -w "$PS1FILE" 2>/dev/null || printf '%s' "$PS1FILE")
WORK=$(mktemp -d 2>/dev/null || echo "/tmp/pmem-tests.$$")
mkdir -p "$WORK"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
head1() { printf '\n\033[1m%s\033[0m\n' "$1"; }

assert_eq() { # $1=desc $2=expected $3=actual
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1（期望 [$2]，实得 [$3]）"; fi
}
assert_contains() { # $1=desc $2=needle $3=haystack
  case "$3" in *"$2"*) ok "$1" ;; *) no "$1（没找到 [$2]）" ;; esac
}

new_fixture() { # $1=目录名 ; 打印 fixture 路径
  local d="$WORK/$1"; rm -rf "$d"; mkdir -p "$d"
  bash "$SH" init "$d" >/dev/null 2>&1
  printf '%s' "$d"
}

# ---------- 1. 语法 ----------
head1 "1. 语法检查"
if bash -n "$SH" 2>/dev/null; then ok "pmem.sh 语法通过"; else no "pmem.sh 语法错误"; fi
if ! command -v pwsh >/dev/null 2>&1; then
  printf '  \033[33mSKIP\033[0m 本机无 pwsh，跳过 pmem.ps1 语法检查\n'
elif [ ! -f "$PS1FILE" ]; then
  no "pmem.ps1 不存在"
else
  errs=$(PMEM_PS1_FILE="$PS1WIN" pwsh -NoProfile -Command '
    $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile($env:PMEM_PS1_FILE, [ref]$null, [ref]$e) | Out-Null
    if ($e -and $e.Count -gt 0) { $e | ForEach-Object { $_.Message }; exit 1 }
  ' 2>&1)
  if [ $? -eq 0 ]; then ok "pmem.ps1 语法通过"; else no "pmem.ps1 语法错误：$errs"; fi
fi

# ---------- 2. 冒烟 ----------
head1 "2. 冒烟：init → 写条目 → gen"
F=$(new_fixture smoke); PM="$F/project-memory"
[ -f "$PM/scripts/pmem.sh" ] && ok "init 把脚本装进了 scripts/" || no "init 没装脚本"
[ -f "$PM/decisions/general/_about.md" ] && ok "init 建了示例域" || no "init 没建示例域"
[ -f "$PM/CONTEXT.md" ] && ok "init 建了 CONTEXT.md" || no "init 没建 CONTEXT.md"

mkdir -p "$PM/research/auth"
cat > "$PM/decisions/general/DEC-001-use-postgres.md" <<'EOF'
---
id: DEC-001
title: 用 PostgreSQL 而不是 MySQL
status: accepted
date: 2026-10-13
summary: 主库选 PostgreSQL，看重 JSONB 与扩展性
tags: [db, storage]
supersedes: []
superseded-by: []
evidence: [research/auth/2026-10-13-token-strategy]
---
正文
EOF
cat > "$PM/constraints/CONSTRAINT-001-no-prod-db.md" <<'EOF'
---
id: CONSTRAINT-001
status: active
date: 2026-10-13
statement: 任何自动化流程不得直连生产库
---
EOF
cat > "$PM/questions/Q-001-multi-tenant.md" <<'EOF'
---
id: Q-001
status: open
date: 2026-10-13
question: 多租户用 schema 分库还是行级 RLS？
---
EOF
cat > "$PM/research/auth/2026-10-13-token-strategy.md" <<'EOF'
---
title: 令牌方案选型
date: 2026-10-13
status: concluded
questions: JWT 还是服务端 session？
leads-to: [DEC-001]
---
结论：JWT。
EOF

if bash "$SH" gen "$PM" >/dev/null 2>&1; then ok "gen 成功"; else no "gen 失败"; fi

assert_contains "路由表列出域 general" '| `general` | 1 |' "$(cat "$PM/DECISIONS.md")"
assert_contains "活约束全文内联" 'CONSTRAINT-001' "$(cat "$PM/DECISIONS.md")"
assert_contains "开放问题一行"      'Q-001' "$(cat "$PM/DECISIONS.md")"
assert_contains "域索引有该条目"    'DEC-001' "$(cat "$PM/decisions/general/_index.md")"
assert_contains "research 主题表"   'auth'   "$(cat "$PM/research/_index.md")"
assert_contains "research 报告表"   '令牌方案选型' "$(cat "$PM/research/auth/_index.md")"
assert_contains "CONTEXT 计数"      '决策 1 条 / 1 个域' "$(cat "$PM/CONTEXT.md")"
assert_contains "CONTEXT 保留手写块" 'HANDWRITTEN:BEGIN' "$(cat "$PM/CONTEXT.md")"

# 生成物必须带标记
n=$(grep -l 'GENERATED' "$PM/DECISIONS.md" "$PM/decisions/general/_index.md" "$PM/research/_index.md" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "三个生成物都带 GENERATED 标记" "3" "$n"

# 幂等：再跑一次 gen，产物字节不变
before=$(cat "$PM/DECISIONS.md" "$PM/decisions/general/_index.md" | md5sum | cut -d' ' -f1)
bash "$SH" gen "$PM" >/dev/null 2>&1
after=$(cat "$PM/DECISIONS.md" "$PM/decisions/general/_index.md" | md5sum | cut -d' ' -f1)
assert_eq "gen 幂等（重复跑产出不变）" "$before" "$after"

# 手写块不被 gen 冲掉
sed -i 's/（一句话说清这个项目是什么。）/一个测试项目。/' "$PM/CONTEXT.md" 2>/dev/null
bash "$SH" gen "$PM" >/dev/null 2>&1
assert_contains "手写块内容被保留" '一个测试项目。' "$(cat "$PM/CONTEXT.md")"

# ---------- 3. 五项校验的负例 ----------
head1 "3. 校验负例（每条都必须被拒绝，退出码非零）"
neg() { # $1=desc $2=文件名 $3=内容
  local d="$PM/decisions/general/$2"
  printf '%s' "$3" > "$d"
  if bash "$SH" check "$PM" >/dev/null 2>&1; then no "$1 —— 竟然通过了"; else ok "$1"; fi
  rm -f "$d"
}
neg "1 重复 id" DEC-001-dup.md '---
id: DEC-001
title: dup
status: accepted
date: 2026-10-13
summary: x
---
'
neg "2 缺必填字段" DEC-900-miss.md '---
id: DEC-900
title: 缺 date/summary
status: accepted
---
'
neg "2 非法 status" DEC-901-status.md '---
id: DEC-901
title: 坏状态
status: nope
date: 2026-10-13
summary: x
---
'
neg "3 supersede 单向" DEC-902-oneway.md '---
id: DEC-902
title: 单向取代
status: accepted
date: 2026-10-13
summary: x
supersedes: [DEC-001]
---
'
neg "4 evidence 路径不存在" DEC-903-ev.md '---
id: DEC-903
title: 坏证据
status: accepted
date: 2026-10-13
summary: x
evidence: [research/nope/missing]
---
'
neg "不许写 domain 字段" DEC-904-dom.md '---
id: DEC-904
title: 写了 domain
status: accepted
date: 2026-10-13
summary: x
domain: general
---
'

# 5 CONTEXT 行数
cp "$PM/CONTEXT.md" "$WORK/ctx.bak"
for i in $(seq 1 120); do echo "- 填充 $i" >> "$PM/CONTEXT.md"; done
if bash "$SH" check "$PM" >/dev/null 2>&1; then no "5 CONTEXT 超 100 行 —— 竟然通过了"; else ok "5 CONTEXT 超 100 行"; fi
mv "$WORK/ctx.bak" "$PM/CONTEXT.md"

# 域缺 _about.md
mv "$PM/decisions/general/_about.md" "$WORK/about.bak"
if bash "$SH" check "$PM" >/dev/null 2>&1; then no "域缺 _about.md —— 竟然通过了"; else ok "域缺 _about.md"; fi
mv "$WORK/about.bak" "$PM/decisions/general/_about.md"

# 校验失败时 gen 必须拒写
printf '%s' '---
id: DEC-999
status: nope
---
' > "$PM/decisions/general/DEC-999-bad.md"
i_before=$(md5sum "$PM/DECISIONS.md" | cut -d' ' -f1)
bash "$SH" gen "$PM" >/dev/null 2>&1; rc=$?
i_after=$(md5sum "$PM/DECISIONS.md" | cut -d' ' -f1)
rm -f "$PM/decisions/general/DEC-999-bad.md"
[ "$rc" -ne 0 ] && ok "gen 校验失败时退出码非零" || no "gen 校验失败却返回 0"
assert_eq "gen 校验失败时未改写索引" "$i_before" "$i_after"

# ---------- 4. 索引溢出退化 ----------
head1 "4. 索引溢出退化"
PMEM_INDEX_MAX=0 bash "$SH" gen "$PM" >/dev/null 2>&1
assert_contains "超阈值时索引退化为 grep 提示" '直接 grep' "$(cat "$PM/decisions/general/_index.md")"
bash "$SH" gen "$PM" >/dev/null 2>&1
assert_contains "阈值恢复后索引恢复" '| ID | 状态 | 摘要 | 日期 |' "$(cat "$PM/decisions/general/_index.md")"

# ---------- 5. 两个实现产出一致 ----------
head1 "5. .sh 与 .ps1 产出一致性"
if command -v pwsh >/dev/null 2>&1 && [ -f "$PS1FILE" ]; then
  A=$(new_fixture par-a); B=$(new_fixture par-b)
  for d in "$A" "$B"; do
    cat > "$d/project-memory/decisions/general/DEC-001-x.md" <<'EOF'
---
id: DEC-001
title: 用 PostgreSQL
status: accepted
date: 2026-10-13
summary: 主库选 PostgreSQL
tags: [db, storage]
supersedes: []
superseded-by: []
evidence: []
---
正文
EOF
    cat > "$d/project-memory/constraints/CONSTRAINT-001-a.md" <<'EOF'
---
id: CONSTRAINT-001
status: active
date: 2026-10-13
statement: 禁止直连生产库
---
EOF
  done
  bash "$SH" gen "$A/project-memory" >/dev/null 2>&1
  pwsh -NoProfile -File "$PS1WIN" gen "$B/project-memory" >/dev/null 2>&1
  if diff -r -q "$A/project-memory" "$B/project-memory" >/dev/null 2>&1; then
    ok ".sh 与 .ps1 产出逐字节相同"
  else
    no ".sh 与 .ps1 产出不同："
    diff -r "$A/project-memory" "$B/project-memory" 2>&1 | head -20 | sed 's/^/      /'
  fi
  # 换行与 BOM
  if grep -q $'\r' "$B/project-memory/DECISIONS.md" 2>/dev/null; then no ".ps1 产出含 CR"; else ok ".ps1 产出为 LF"; fi
  if [ "$(head -c 3 "$B/project-memory/DECISIONS.md" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; then
    no ".ps1 产出带 UTF-8 BOM"; else ok ".ps1 产出无 BOM"; fi
else
  printf '  \033[33mSKIP\033[0m 本机无 pwsh 或缺 pmem.ps1，跳过一致性检查\n'
fi

# ---------- 汇总 ----------
printf '\n\033[1m结果\033[0m：%d 通过，%d 失败\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
rm -rf "$WORK"
