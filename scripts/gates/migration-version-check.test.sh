#!/bin/bash
# migration-version-check.sh 的自測（LS-70）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若撞號放行（目標分支先併進同版本號、本分支內重複、改名既有 migration）、
# 同名檔被誤報、不合格式檔名靜默略過、缺 ref 靜默跳過、或拿工作目錄而非 tree 比對——這裡會紅。
# 合成 repo：development 當目標分支，每個場景各切一條 feature 分支。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/scripts/gates/migration-version-check.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
R="$work/repo"
M=supabase/migrations

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
mig() {   # mig <檔名> [內容]：寫 migration 檔並 commit
  mkdir -p "$R/$M"; printf '%s\n' "${2:-select 1;}" > "$R/$M/$1"; g add -A; g commit -qm "feat(db): LS-1 $1"
}
branch() { g checkout -q development && g checkout -q -b "$1"; }

# expect <期望 exit code> <樣本名稱> <輸出必含字串|''> <checker 參數…>
expect() {
  local want=$1 name=$2 must=$3 out got
  shift 3
  out="$(cd "$R" && bash "$check" "$@" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ] && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; }; then
    echo "✓ ${name}"
  else
    echo "✗ ${name}（期望 exit ${want}${must:+、輸出含「${must}」}，實得 ${got}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}
hasnt() {   # hasnt <名稱> <不得含> <checker 參數…>
  local name=$1 no=$2 out; shift 2
  out="$(cd "$R" && bash "$check" "$@" 2>&1)"
  if printf '%s' "$out" | grep -qF -- "$no"; then echo "✗ ${name}（輸出不應含「${no}」）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; else echo "✓ ${name}"; fi
}

# ---- 合成 repo：development 有兩個 migration ----
mkdir -p "$R"; g init -q -b development
echo x > "$R/README.md"; g add -A; g commit -qm 'chore(harness): LS-1 init'
mig 20260101000000_init.sql
mig 20260102000000_two.sql

# ① 正向：本分支新增不撞號的版本
branch feature/LS-2-ok
mig 20260103000000_three.sql
expect 0 '① 新版本號不撞 → exit 0' '無撞號' --target development
expect 0 '① 印檔數' '本分支 3 檔' --target development
expect 0 '① 不給 --target 只驗本分支內 → exit 0' '無撞號'

# ② 目標分支先併進同版本號（LS-57／LS-66 的形狀）：分支切出後 development 多了 20260105_other，本分支也用 20260105
branch feature/LS-3-collide
mig 20260105000000_mine.sql
g checkout -q development; mig 20260105000000_other.sql
g checkout -q feature/LS-3-collide
expect 1 '② 與目標分支撞號 → exit 1' '撞號' --target development
expect 1 '② 列出目標分支那檔' '20260105000000_other.sql' --target development
expect 1 '② 列出本分支那檔' '20260105000000_mine.sql' --target development
expect 1 '② 印修法' '修法' --target development
expect 0 '② 不給 --target 看不到跨分支撞號（本分支內仍唯一）' ''

# ③ 本分支內同版本號兩檔
branch feature/LS-4-dup
mig 20260106000000_a.sql
mig 20260106000000_b.sql
expect 1 '③ 本分支內重複 → exit 1' '出現多次' --target development
expect 1 '③ 列出兩檔之一' '20260106000000_a.sql' --target development
expect 1 '③ 列出兩檔之二' '20260106000000_b.sql' --target development
expect 1 '③ 不給 --target 也擋本分支內重複' '出現多次'

# ④ 同名檔不算撞號（同一檔已在目標分支——例如本票先前併入、或 merge 回來）
branch feature/LS-5-same
mig 20260107000000_same.sql
g checkout -q development; mig 20260107000000_same.sql
g checkout -q feature/LS-5-same
expect 0 '④ 同版本同檔名 → 同一檔、exit 0' '無撞號' --target development
hasnt  '④ 同名檔不印 ✗' '✗' --target development

# ⑤ 改名既有 migration（版本同、檔名不同）→ 紅
branch feature/LS-6-rename
g mv "$M/20260101000000_init.sql" "$M/20260101000000_init_v2.sql"; g commit -qm 'chore(db): LS-1 rename'
expect 1 '⑤ 改名既有 migration → exit 1' '20260101000000_init.sql' --target development

# ⑥ 檔名不合格式（CLI 會靜默略過）→ 紅
branch feature/LS-7-badname
mig foo.sql
expect 1 '⑥ 無版本號前綴 → exit 1' '不符' --target development
branch feature/LS-8-badname2
mig 2026x_bad.sql
expect 1 '⑥ 版本號含非數字 → exit 1' '不符' --target development

# ⑦ 只看 tree：工作目錄未 commit 的撞號檔不算（push 出去的只有 commit）
branch feature/LS-9-tree
mkdir -p "$R/$M"; printf 'select 1;\n' > "$R/$M/20260102000000_uncommitted.sql"
expect 0 '⑦ 未 commit 的撞號檔不算' '無撞號' --target development
rm -f "$R/$M/20260102000000_uncommitted.sql"

# ⑧ supabase/migrations 以外的 .sql 不管
branch feature/LS-10-elsewhere
mkdir -p "$R/supabase/tests"; printf 'select 1;\n' > "$R/supabase/tests/20260102000000_x.sql"; g add -A; g commit -qm 'test(db): LS-1 t'
expect 0 '⑧ tests/ 下同版本號不算' '無撞號' --target development

# ⑨ --head 指定 rev（CI 用 HEAD；這裡驗參數有效）
expect 1 '⑨ --head 指向撞號分支 → exit 1' '撞號' --target development --head feature/LS-3-collide
expect 0 '⑨ --head 指向乾淨分支 → exit 0' '無撞號' --target development --head feature/LS-2-ok

# ⑩ 參數／ref 錯誤 fail closed（exit 2）
expect 2 '⑩ --target 不存在 → exit 2' '找不到' --target origin/nope
expect 2 '⑩ --target 缺值 → exit 2' '缺值' --target
expect 2 '⑩ --head 不存在 → exit 2' '找不到' --head nope
expect 2 '⑩ 未知參數 → exit 2' '未知參數' --bogus

if [ "$fail" -eq 0 ]; then
  echo "✓ migration-version-check 自測通過"
fi
exit "$fail"
