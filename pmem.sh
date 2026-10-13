#!/usr/bin/env bash
# pmem — project-memory 工具（POSIX / Git Bash）
#
# 子命令：
#   init  [目标项目目录]   在项目里建出 project-memory/ 骨架，并把本脚本装进 <pm>/scripts/
#   gen   [pm 目录]        重算索引与快照（先校验，校验不过就拒写）
#   check [pm 目录]        只校验，不写文件；有问题则以非零退出
#
# 设计依据见 README.md。核心约束：手写的只能是「新增」，汇总物一律由本脚本生成。

set -u

PMEM_VERSION="0.1.0"
PMEM_INDEX_MAX="${PMEM_INDEX_MAX:-150}"
PMEM_RAW_BASE="${PMEM_RAW_BASE:-https://raw.githubusercontent.com/arsonist-g/project-memory-kit/main}"

GEN_MARK='<!-- GENERATED — 由 pmem 生成，请勿手改 -->'
HW_BEGIN='<!-- HANDWRITTEN:BEGIN -->'
HW_END='<!-- HANDWRITTEN:END -->'

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warn:  %s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }

usage() {
  cat <<EOF
pmem $PMEM_VERSION — project-memory 脚手架与索引生成器

用法：
  pmem.sh init  [目标项目目录]   建 project-memory/ 骨架（默认当前目录）
  pmem.sh gen   [pm 目录]        校验并重算索引与快照（默认 ./project-memory）
  pmem.sh check [pm 目录]        只校验（默认 ./project-memory）

环境变量：
  PMEM_INDEX_MAX   域索引超过这个行数就退化为「请直接 grep」的提示（默认 150）
  PMEM_RAW_BASE    脚本自身的下载地址前缀，用于 init 时把脚本装进项目

校验项（check / gen 都会跑）：
  1. 条目 id 不重复
  2. front-matter 必填字段齐全，status 取值合法
  3. supersedes / superseded-by 双向一致
  4. evidence 引用的路径存在
  5. CONTEXT.md 行数 <= 100
EOF
}

# ---------- front-matter 读取 ----------
# front-matter 是文件开头第一行 --- 到下一个 --- 之间的部分。

fm_block() { # $1=file ; 打印 front-matter 正文（不含两行 ---）
  [ -f "$1" ] || return 0
  awk '
    NR==1 && $0 ~ /^---[[:space:]]*$/ { infm=1; next }
    infm && $0 ~ /^---[[:space:]]*$/   { exit }
    infm { print }
  ' "$1"
}

fm_get() { # $1=file $2=key ; 打印值（去首尾空白），无则空
  fm_block "$1" | awk -v key="$2" '
    { line=$0; sub(/^[[:space:]]+/,"",line) }
    line ~ ("^" key "[[:space:]]*:") {
      v=line; sub(/^[^:]*:[[:space:]]*/,"",v); sub(/[[:space:]]+$/,"",v); print v; exit
    }
  '
}

fm_has() { # $1=file $2=key
  fm_block "$1" | awk -v key="$2" '
    { line=$0; sub(/^[[:space:]]+/,"",line) }
    line ~ ("^" key "[[:space:]]*:") { found=1; exit }
    END { exit(found?0:1) }
  '
}

fm_list() { # $1=file $2=key ; 把 [a, b] / [] / 裸值 统一成「每行一个」
  v=$(fm_get "$1" "$2") || true
  [ -n "${v:-}" ] || return 0
  v=$(printf '%s' "$v" | sed 's/^\[//; s/\]$//')
  printf '%s' "$v" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true
}

# ---------- 目录约定 ----------

require_pm() { # $1=pm 目录
  [ -d "$1" ] || die "找不到 project-memory 目录：$1"
  [ -f "$1/DECISIONS.md" ] || die "$1 不像记忆层（缺 DECISIONS.md）"
}

ls_dec()   { find "$1/decisions" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort; }
ls_dec_in(){ find "$1" -maxdepth 1 -name 'DEC-*.md' -type f 2>/dev/null | sort; }
ls_con()   { find "$1/constraints" -maxdepth 1 -name 'CONSTRAINT-*.md' -type f 2>/dev/null | sort; }
ls_q()     { find "$1/questions" -maxdepth 1 -name 'Q-*.md' -type f 2>/dev/null | sort; }
ls_topics(){ find "$1/research" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort; }
ls_rep()   { find "$1" -maxdepth 1 -name '*.md' ! -name '_index.md' -type f 2>/dev/null | sort; }

rel() { printf '%s' "${1#"$PM_ROOT"/}"; }

# ---------- 校验 ----------

CHECK_FAIL=0
fail() { printf '  [FAIL] %s\n' "$*" >&2; CHECK_FAIL=$((CHECK_FAIL+1)); }

valid_status() { # $1=type $2=status
  case "$1:$2" in
    dec:proposed|dec:accepted|dec:superseded|dec:deprecated) return 0 ;;
    con:active|con:retired)                                  return 0 ;;
    q:open|q:resolved|q:dropped)                             return 0 ;;
    rep:open|rep:concluded|rep:superseded)                   return 0 ;;
    *) return 1 ;;
  esac
}

require_fields() { # $1=file $2=type $3..=fields
  f="$1"; t="$2"; shift 2
  for k in "$@"; do
    fm_has "$f" "$k" || fail "$(rel "$f") 缺必填字段 '$k'"
  done
  s=$(fm_get "$f" status)
  [ -n "$s" ] && ! valid_status "$t" "$s" && fail "$(rel "$f") 的 status='$s' 不是合法取值"
}

run_check() { # $1=pm
  PM_ROOT=$(cd "$1" && pwd)
  CHECK_FAIL=0
  info "校验 $PM_ROOT"

  # --- 1. id 不重复 + 2. 必填字段 ---
  IDS=""
  for d in $(ls_dec "$PM_ROOT"); do
    dom=$(basename "$d")
    [ -f "$d/_about.md" ] || fail "decisions/$dom/ 缺 _about.md（域描述，路由表要用）"
    if [ -f "$d/_about.md" ]; then
      fm_has "$d/_about.md" scope || fail "decisions/$dom/_about.md 缺必填字段 'scope'"
    fi
    for f in $(ls_dec_in "$d"); do
      require_fields "$f" dec id title status date summary
      id=$(fm_get "$f" id)
      [ -n "$id" ] || continue
      case "$IDS" in *"|$id|"*) fail "$(rel "$f") 的 id '$id' 重复" ;; esac
      IDS="$IDS|$id|"
      # 域 = 目录：不允许在 front-matter 里再写 domain
      fm_has "$f" domain && fail "$(rel "$f") 不该写 domain 字段（域由所在目录决定）"
    done
  done

  for f in $(ls_con "$PM_ROOT"); do
    require_fields "$f" con id status date statement
    id=$(fm_get "$f" id)
    [ -n "$id" ] || continue
    case "$IDS" in *"|$id|"*) fail "$(rel "$f") 的 id '$id' 重复" ;; esac
    IDS="$IDS|$id|"
  done

  for f in $(ls_q "$PM_ROOT"); do
    require_fields "$f" q id status date question
    id=$(fm_get "$f" id)
    [ -n "$id" ] || continue
    case "$IDS" in *"|$id|"*) fail "$(rel "$f") 的 id '$id' 重复" ;; esac
    IDS="$IDS|$id|"
  done

  for t in $(ls_topics "$PM_ROOT"); do
    for f in $(ls_rep "$t"); do
      require_fields "$f" rep title date status
      # evidence 引用的路径存在（仅对 DEC 有意义，放在 DEC 循环里做）
    done
  done

  # --- 3. supersedes / superseded-by 双向一致 ---
  # 建 id -> 路径 索引后互查
  for d in $(ls_dec "$PM_ROOT"); do
    for f in $(ls_dec_in "$d"); do
      id=$(fm_get "$f" id); [ -n "$id" ] || continue
      for sup in $(fm_list "$f" supersedes); do
        target=$(grep -rl --include='DEC-*.md' "^id:[[:space:]]*$sup[[:space:]]*$" "$PM_ROOT/decisions" 2>/dev/null | head -1)
        if [ -z "$target" ]; then
          fail "$(rel "$f") supersedes 指向不存在的 $sup"
        elif ! fm_list "$target" superseded-by | grep -qx "$id"; then
          fail "$(rel "$f") 说取代 $sup，但 $(rel "$target") 没写 superseded-by: $id"
        fi
      done
      for sby in $(fm_list "$f" superseded-by); do
        target=$(grep -rl --include='DEC-*.md' "^id:[[:space:]]*$sby[[:space:]]*$" "$PM_ROOT/decisions" 2>/dev/null | head -1)
        if [ -z "$target" ]; then
          fail "$(rel "$f") superseded-by 指向不存在的 $sby"
        elif ! fm_list "$target" supersedes | grep -qx "$id"; then
          fail "$(rel "$f") 说被 $sby 取代，但 $(rel "$target") 没写 supersedes: $id"
        fi
      done
    done
  done

  # --- 4. evidence 路径存在（带或不带 .md 都接受）---
  for d in $(ls_dec "$PM_ROOT"); do
    for f in $(ls_dec_in "$d"); do
      for e in $(fm_list "$f" evidence); do
        if [ ! -e "$PM_ROOT/$e" ] && [ ! -e "$PM_ROOT/$e.md" ]; then
          fail "$(rel "$f") 的 evidence 指向不存在的路径 '$e'"
        fi
      done
    done
  done

  # --- 5. CONTEXT.md 行数 ---
  if [ -f "$PM_ROOT/CONTEXT.md" ]; then
    n=$(wc -l < "$PM_ROOT/CONTEXT.md" | tr -d ' ')
    [ "$n" -le 100 ] || fail "CONTEXT.md 有 $n 行，超过 100 行上限"
  fi

  if [ "$CHECK_FAIL" -eq 0 ]; then
    info "校验通过"
    return 0
  fi
  printf 'error: 校验未通过，%d 处问题\n' "$CHECK_FAIL" >&2
  return 1
}

# ---------- 生成 ----------

gen_decisions_index() { # $1=pm
  out="$1/DECISIONS.md"
  {
    printf '%s\n\n' "$GEN_MARK"
    printf '# 决策入口表\n\n'
    printf '每次开工必读。本文件只登记**入口**，不登记全体：域一行，条目靠域内 grep。\n\n'
    printf '## 域路由\n\n'
    printf '| 域 | 条目数 | 涵盖 |\n|---|---|---|\n'
    found=0
    for d in $(ls_dec "$1"); do
      dom=$(basename "$d")
      cnt=$(ls_dec_in "$d" | grep -c . || true)
      scope=$(fm_get "$d/_about.md" scope)
      printf '| `%s` | %s | %s |\n' "$dom" "$cnt" "${scope:-(未填 scope)}"
      found=1
    done
    [ "$found" -eq 1 ] || printf '| —— | 0 | 尚无决策条目 |\n'

    printf '\n## 活约束（全文）\n\n'
    n=0
    for f in $(ls_con "$1"); do
      [ "$(fm_get "$f" status)" = "active" ] || continue
      n=$((n+1))
      printf -- '- **%s** — %s\n' "$(fm_get "$f" id)" "$(fm_get "$f" statement)"
    done
    [ "$n" -gt 0 ] || printf '无。\n'

    printf '\n## 开放问题\n\n'
    n=0
    for f in $(ls_q "$1"); do
      [ "$(fm_get "$f" status)" = "open" ] || continue
      n=$((n+1))
      printf -- '- %s %s\n' "$(fm_get "$f" id)" "$(fm_get "$f" question)"
    done
    [ "$n" -gt 0 ] || printf '无。\n'
  } > "$out.tmp" && mv "$out.tmp" "$out"
}

gen_domain_index() { # $1=域目录 $2=域名
  out="$1/_index.md"
  cnt=$(ls_dec_in "$1" | grep -c . || true)
  if [ "$cnt" -gt "$PMEM_INDEX_MAX" ]; then
    {
      printf '%s\n\n' "$GEN_MARK"
      printf '# %s\n\n' "$2"
      printf '本域有 %s 条，超过 %s 行的索引上限，已退化为提示。\n\n' "$cnt" "$PMEM_INDEX_MAX"
      printf '**不要读本文件，直接 grep：**\n\n'
      printf '```sh\nrg -l "^(tags|status|summary):.*<关键词>" decisions/%s/\n```\n' "$2"
    } > "$out.tmp" && mv "$out.tmp" "$out"
    return 0
  fi
  {
    printf '%s\n\n' "$GEN_MARK"
    printf '# %s\n\n' "$2"
    printf '%s\n' "$(fm_get "$1/_about.md" scope)"
    printf '\n| ID | 状态 | 摘要 | 日期 |\n|---|---|---|---|\n'
    for f in $(ls_dec_in "$1"); do
      printf '| [%s](%s) | %s | %s | %s |\n' \
        "$(fm_get "$f" id)" "$(basename "$f")" \
        "$(fm_get "$f" status)" "$(fm_get "$f" summary)" "$(fm_get "$f" date)"
    done
  } > "$out.tmp" && mv "$out.tmp" "$out"
}

gen_research_index() { # $1=pm
  {
    printf '%s\n\n' "$GEN_MARK"
    printf '# research 索引\n\n'
    printf '调研与验证报告的主题总表。**报告本体只读归档**：结论变了写新的一份，不改旧的。\n\n'
    printf '| 主题 | 报告数 |\n|---|---|\n'
    n=0
    for t in $(ls_topics "$1"); do
      top=$(basename "$t")
      c=$(ls_rep "$t" | grep -c . || true)
      printf '| [%s](%s/_index.md) | %s |\n' "$top" "$top" "$c"
      n=1
    done
    [ "$n" -eq 1 ] || printf '| —— | 0 |\n'
  } > "$1/research/_index.md.tmp" && mv "$1/research/_index.md.tmp" "$1/research/_index.md"

  for t in $(ls_topics "$1"); do
    top=$(basename "$t")
    {
      printf '%s\n\n' "$GEN_MARK"
      printf '# %s\n\n' "$top"
      printf '| 报告 | 日期 | 状态 | 回答的问题 |\n|---|---|---|---|\n'
      for f in $(ls_rep "$t"); do
        printf '| [%s](%s) | %s | %s | %s |\n' \
          "$(fm_get "$f" title)" "$(basename "$f")" \
          "$(fm_get "$f" date)" "$(fm_get "$f" status)" "$(fm_get "$f" questions)"
      done
    } > "$t/_index.md.tmp" && mv "$t/_index.md.tmp" "$t/_index.md"
  done
}

gen_context() { # $1=pm
  ctx="$1/CONTEXT.md"
  [ -f "$ctx" ] || return 0

  # 保留手写块（含标记行本身）
  if grep -qF "$HW_BEGIN" "$ctx"; then
    awk -v b="$HW_BEGIN" 'index($0,b){p=1} p{print}' "$ctx" > "$ctx.hw.tmp"
  else
    : > "$ctx.hw.tmp"
  fi

  # 源仓 HEAD：记忆层是子仓时取 superproject，否则取自身
  src=$(git -C "$1" rev-parse --show-superproject-working-tree 2>/dev/null || true)
  [ -n "$src" ] || src="$1"
  sha=$(git -C "$src" rev-parse --short=6 HEAD 2>/dev/null || echo "??????")
  dirty=""
  [ -n "$(git -C "$src" status --porcelain 2>/dev/null | head -1)" ] && dirty=" · +uncommitted"

  ndec=0
  for d in $(ls_dec "$1"); do
    c=$(ls_dec_in "$d" | grep -c . || true); ndec=$((ndec+c))
  done
  ndom=$(ls_dec "$1" | grep -c . || true)
  nq=0
  for f in $(ls_q "$1"); do [ "$(fm_get "$f" status)" = "open" ] && nq=$((nq+1)); done
  nrep=0
  for t in $(ls_topics "$1"); do c=$(ls_rep "$t" | grep -c . || true); nrep=$((nrep+c)); done

  {
    printf '%s\n' "$GEN_MARK"
    printf '> 更新于 %s · HEAD %s%s\n' "$(date +%F)" "$sha" "$dirty"
    printf '> 决策 %s 条 / %s 个域 · 开放问题 %s 条 · 调研报告 %s 份\n\n' "$ndec" "$ndom" "$nq" "$nrep"
    cat "$ctx.hw.tmp"
  } > "$ctx.tmp" && mv "$ctx.tmp" "$ctx"
  rm -f "$ctx.hw.tmp"
}

run_gen() { # $1=pm
  run_check "$1" || die "校验未通过，已拒绝写入（先修上面的问题）"
  PM_ROOT=$(cd "$1" && pwd)
  gen_decisions_index "$PM_ROOT"
  for d in $(ls_dec "$PM_ROOT"); do gen_domain_index "$d" "$(basename "$d")"; done
  gen_research_index "$PM_ROOT"
  gen_context "$PM_ROOT"
  info "已生成：DECISIONS.md、各 decisions/*/_index.md、research/**/_index.md、CONTEXT.md"
}

# ---------- init ----------

write_if_absent() { # $1=路径 ; stdin=内容
  [ -e "$1" ] && { warn "已存在，跳过：$1"; return 1; }
  mkdir -p "$(dirname "$1")"
  cat > "$1"
  return 0
}

self_dir() { # 脚本自身所在目录；失败则空（例如进程替换运行）
  case "${BASH_SOURCE[0]:-$0}" in
    /dev/fd/*|/proc/self/fd/*|-) return 1 ;;
  esac
  d=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd) || return 1
  printf '%s' "$d"
}

install_script() { # $1=目标 scripts 目录 $2=文件名
  dst="$1/$2"
  [ -e "$dst" ] && return 0
  if src=$(self_dir) && [ -f "$src/$2" ]; then
    cp "$src/$2" "$dst"
  else
    curl -fsSL "$PMEM_RAW_BASE/$2" -o "$dst" 2>/dev/null \
      || { warn "装不进 $2（没能确定脚本位置，也没能下载）"; return 1; }
  fi
  chmod +x "$dst" 2>/dev/null || true
}

run_init() { # $1=目标项目目录
  proj="$1"
  mkdir -p "$proj" || die "建不了目录：$proj"
  proj=$(cd "$proj" && pwd)
  pm="$proj/project-memory"
  [ -e "$pm" ] && die "$pm 已存在，不覆盖。要重建请先自行处理。"

  mkdir -p "$pm"/{decisions,constraints,questions,research,spec,task-tracker,scripts}
  for d in constraints questions spec task-tracker; do : > "$pm/$d/.gitkeep"; done

  write_if_absent "$pm/decisions/general/_about.md" <<'EOF'
---
domain: general
scope: 尚未归类的决策
---
EOF

  write_if_absent "$pm/CONTEXT.md" <<'EOF'
<!-- GENERATED — 由 pmem 生成，请勿手改本行以下至 HANDWRITTEN 标记之间 -->

<!-- HANDWRITTEN:BEGIN -->
# 项目一句话

（一句话说清这个项目是什么。）

# 当前状态

- （项目现在到哪了。）

# 下次第一件事

（下一轮开工先做什么。）

# 指针

- 设计：`spec/`
- 证据：`research/`
<!-- HANDWRITTEN:END -->
EOF

  write_if_absent "$pm/DECISIONS.md" <<'EOF'
<!-- GENERATED — 由 pmem 生成，请勿手改 -->

# 决策入口表

跑 `scripts/pmem.sh gen` 生成。
EOF

  install_script "$pm/scripts" pmem.sh  || true
  install_script "$pm/scripts" pmem.ps1 || true

  run_gen "$pm" || die "初始化后校验未通过"

  info ""
  info "已建好：$pm"
  info "  scripts/pmem.sh  ·  scripts/pmem.ps1"
  info "下一步：编辑 CONTEXT.md 的 HANDWRITTEN 块；写第一条决策到 decisions/<域>/DEC-001-<slug>.md"
}

# ---------- 入口 ----------

cmd="${1:-}"
case "$cmd" in
  init)
    shift || true
    run_init "${1:-.}" ;;
  gen)
    shift || true
    t="${1:-./project-memory}"; require_pm "$t"; run_gen "$t" ;;
  check)
    shift || true
    t="${1:-./project-memory}"; require_pm "$t"; run_check "$t" ;;
  ""|-h|--help|help)
    usage ;;
  *)
    die "未知子命令：$cmd（试试 --help）" ;;
esac
