#!/bin/bash
# Migration 版本號撞號檢查（LS-70）：supabase/migrations/<版本>_<名稱>.sql 的版本號（檔名前綴數字）在本分支須唯一，
# 且不得與目標分支既有的版本號重複（同版本、不同檔名）。來源：2026-08-25 LS-57／LS-66 兩張平行後端票都取
# 20260825030000——supabase CLI 依版本號排序套用，撞號的兩檔順序未定義且 `supabase migration list` 只認一筆，
# 先併的把後併的擠掉、本機 reset 忽有忽無。掛 push-gate（migration 分級之前）；CI rules job 的 Migration rules
# step 以 origin/$BASE 再驗一次（伺服器端兜底）；自測 migration-version-check.test.sh。
#
# 用法：migration-version-check.sh [--target <ref>] [--head <rev>]
#   --target  目標分支 ref（push-gate 依方向矩陣傳 origin/development／origin/main；CI 傳 origin/$BASE）。
#             不給就只驗本分支內唯一。ref 不存在 → exit 2（先 git fetch origin），不靜默跳過。
#   --head    要驗的 rev，預設 HEAD（CI 的 checkout 是 detached merge ref，HEAD 即可）。
# 比對的是 tree（git ls-tree），不是工作目錄：沒 commit 的檔不算——push 出去的只有 commit。
# 規則：
#   1) 檔名須符 <數字>_<名稱>.sql（supabase CLI 的 migration 檔名格式；不合格式的檔 CLI 會靜默略過——這裡直接紅）。
#   2) 本分支 tree 內同一版本號出現兩次 → 紅（列出兩個檔名）。
#   3) 本分支某版本號在目標分支 tree 內也存在、但檔名不同 → 紅。同名＝同一檔，不算撞號；改名既有 migration
#      也在此紅——已套用到別人資料庫的 migration 不該改名。目標分支取 ref 當前 tree，不是 merge-base：撞號正是
#      「分支切出後，別張票帶同版本號先併進去」。
# exit 0＝無撞號；1＝撞號或檔名不合格式；2＝參數／git 錯誤（fail closed）。
set -uo pipefail
export LC_ALL=C   # sort／join 的排序一致

target=; head=HEAD
while [ $# -gt 0 ]; do
  case "$1" in
    --target)
      [ -n "${2:-}" ] || { echo "✗ migration-version-check：--target 缺值" >&2; exit 2; }
      target=$2; shift 2 ;;
    --head)
      [ -n "${2:-}" ] || { echo "✗ migration-version-check：--head 缺值" >&2; exit 2; }
      head=$2; shift 2 ;;
    *) echo "✗ migration-version-check：未知參數 $1" >&2; exit 2 ;;
  esac
done

top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "✗ migration-version-check：不在 git repo 內" >&2; exit 2; }
cd "$top" || exit 2
git rev-parse -q --verify "${head}^{commit}" >/dev/null || { echo "✗ migration-version-check：找不到 --head ${head}" >&2; exit 2; }
if [ -n "$target" ] && ! git rev-parse -q --verify "${target}^{commit}" >/dev/null; then
  echo "✗ migration-version-check：找不到 ${target}（先 git fetch origin），無法比對版本號。" >&2
  exit 2
fi

# <rev> 的 migrations 檔名（basename）一行一個。core.quotePath 關掉：非 ASCII 檔名不會被 C-escape 成對不上的字串。
# sed 同時做「只留 .sql」與「去目錄」——grep 無命中會回 1，在 pipefail 下把「沒有 migration」變成失敗。
list_migrations() {
  git -c core.quotePath=false ls-tree -r --name-only "$1" -- supabase/migrations/ | sed -n 's#^supabase/migrations/##; /\.sql$/p'
}
# 「版本<TAB>檔名」對，依版本排序（join 需要）；不合格式的檔名不進來（規則 1 另外報）
TAB=$(printf '\t')
pairs() { printf '%s\n' "$1" | awk -F_ '/^[0-9]+_.*\.sql$/ { print $1 "\t" $0 }' | sort -t "$TAB" -k1,1; }

head_list=$(list_migrations "$head") || { echo "✗ migration-version-check：git ls-tree ${head} 失敗" >&2; exit 2; }
bad=0

# 1) 檔名格式
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    [0-9]*_*.sql) case "${f%%_*}" in *[!0-9]*) ;; *) continue ;; esac ;;
  esac
  echo "✗ migration-version-check：supabase/migrations/${f} 不符 <數字版本>_<名稱>.sql 格式（supabase CLI 會靜默略過這個檔）" >&2
  bad=1
done <<< "$head_list"

# 2) 本分支內唯一
dups=$(pairs "$head_list" | cut -f1 | uniq -d)
for v in $dups; do
  echo "✗ migration-version-check：版本號 ${v} 在本分支出現多次（supabase CLI 套用順序未定義、migration list 只認一筆）：" >&2
  printf '%s\n' "$head_list" | grep "^${v}_" | sed 's#^#    supabase/migrations/#' >&2
  bad=1
done

# 3) 與目標分支比對：同版本、不同檔名
if [ -n "$target" ]; then
  target_list=$(list_migrations "$target") || { echo "✗ migration-version-check：git ls-tree ${target} 失敗" >&2; exit 2; }
  hp=$(pairs "$head_list"); tp=$(pairs "$target_list")
  collisions=
  if [ -n "$hp" ] && [ -n "$tp" ]; then
    collisions=$(join -t "$TAB" -j 1 <(printf '%s\n' "$hp") <(printf '%s\n' "$tp") | awk -F "$TAB" '$2 != $3')
  fi
  if [ -n "$collisions" ]; then
    while IFS="$TAB" read -r v f t; do
      [ -n "$v" ] || continue
      echo "✗ migration-version-check：版本號 ${v} 與 ${target} 既有 migration 撞號（同版本、不同檔名）：" >&2
      echo "    本分支：supabase/migrations/${f}" >&2
      echo "    ${target}：supabase/migrations/${t}" >&2
    done <<< "$collisions"
    bad=1
  fi
fi

if [ "$bad" -ne 0 ]; then
  echo "  修法：把本分支的 migration 改成新的版本號（date -u +%Y%m%d%H%M%S），內容不動；若目標分支那檔本來就是你這張票先前併入的同一檔，改回同名即可（LS-70，COLLABORATION §6）。" >&2
  exit 1
fi
n=$(printf '%s\n' "$head_list" | grep -c '\.sql$' || true)
echo "✓ migration 版本號無撞號（本分支 ${n} 檔${target:+，對 ${target}}）"
exit 0
