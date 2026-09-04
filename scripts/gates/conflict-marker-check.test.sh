#!/bin/bash
# conflict-marker-check.sh 的自測（LS-157）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若檢查退化成放過標記、把行中 `=======`／表格分隔線／setext 以外的 `=` 行誤擋、
# 看了未 staged 或 HEAD 既有內容、改名檔漏掉、純刪除 commit 炸掉、或非 repo 假綠，這裡會紅。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/scripts/gates/conflict-marker-check.sh"
fail=0
n=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
R="$work/repo"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

# expect <期望 exit> <名稱> <輸出必含|''> [<不得含>]（在 $R 內跑 checker）
expect() {
  local want=$1 name=$2 must=$3 mustnot=${4:-} out got
  out="$(cd "$R" && bash "$check" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ] && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; } \
     && { [ -z "$mustnot" ] || ! printf '%s' "$out" | grep -qF -- "$mustnot"; }; then
    echo "✓ ${name}"; n=$((n + 1))
  else
    echo "✗ ${name}（期望 exit ${want}${must:+、輸出含「${must}」}${mustnot:+、不含「${mustnot}」}，實得 ${got}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}

mkdir -p "$R/docs"
g init -q -b main
printf 'a\nb\nc\n' > "$R/docs/a.md"
printf '| col | col |\n|---|---|\n| x | y |\n' > "$R/docs/table.md"
g add -A
g commit -qm 'chore(harness): LS-1 init'

# ① 乾淨 staged diff → 綠
printf 'a\nb2\nc\n' > "$R/docs/a.md"
g add docs/a.md
expect 0 '① 乾淨 staged diff → 綠' '無衝突標記'

# ② staged 新增行含三種標記 → 紅並列 檔案:行號
printf 'a\n<<<<<<< HEAD\nb-ours\n=======\nb-theirs\n>>>>>>> feature/LS-2-x\nc\n' > "$R/docs/a.md"
g add docs/a.md
expect 1 '② staged 含 <<<<<<< HEAD → 紅並列檔名' 'docs/a.md:2: <<<<<<< HEAD'
expect 1 '②′ ======= 整行列出正確行號' 'docs/a.md:4: ======='
expect 1 '②″ >>>>>>> 列出正確行號' 'docs/a.md:6: >>>>>>> feature/LS-2-x'
expect 1 '②‴ 紅時不印通過' '' '✓ conflict-marker gate'

# ③ 形似但非標記的新增行 → 綠：行中 =======、表格分隔線、====、=======x、<<<<<<<x（無空白）、行首帶空白、七個 -
printf 'a\nx = y ======= z\n|---|---|\n====\n=======x\n<<<<<<<x\n =======\n-------\nc\n' > "$R/docs/a.md"
g add docs/a.md
expect 0 '③ 行中 =======／表格分隔線／====／=======x／<<<<<<<x／行首空白 → 綠' '無衝突標記'

# ④ 標記已在 HEAD、本次 staged 只改別行 → 綠（只看新增行）
printf 'a\n=======\nc\n' > "$R/docs/a.md"
g add docs/a.md
g commit -qm 'chore(harness): LS-1 marker already in head'
printf 'a\n=======\nc\nd\n' > "$R/docs/a.md"
g add docs/a.md
expect 0 '④ HEAD 既有標記、staged 新增行乾淨 → 綠' '無衝突標記'
g commit -qm 'chore(harness): LS-1 d'

# ⑤ 標記只在工作區、未 staged → 綠
printf '<<<<<<< HEAD\nunstaged\n' > "$R/docs/unstaged.md"
expect 0 '⑤ 標記只在未 staged 的工作區檔 → 綠' '無衝突標記'
rm "$R/docs/unstaged.md"

# ⑥ 純刪除 commit（沒有新增行）→ 綠，不炸
g rm -q docs/table.md
expect 0 '⑥ 純刪除、無新增行 → 綠' '無衝突標記'
g commit -qm 'chore(harness): LS-1 rm table'

# ⑦ 兩檔同時中 → 一次列完
printf '<<<<<<< HEAD\n' > "$R/docs/one.sh"
printf 'x\n>>>>>>> theirs\n' > "$R/docs/two.py"
g add docs/one.sh docs/two.py
expect 1 '⑦ 兩檔同時中 → 一次列完（one.sh）' 'docs/one.sh:1: <<<<<<< HEAD'
expect 1 '⑦′ 兩檔同時中 → 一次列完（two.py）' 'docs/two.py:2: >>>>>>> theirs'
g reset -q

# ⑧ 改名＋修改加入標記 → 紅（--no-renames，rename 偵測不會把它濾掉）
g mv docs/a.md docs/renamed.md
printf 'a\n=======\nc\nd\n=======\n' > "$R/docs/renamed.md"
g add docs/renamed.md
expect 1 '⑧ 改名＋修改新增標記 → 紅並用新檔名' 'docs/renamed.md:5: ======='
g reset -q --hard

# ⑨ 不在 git repo → exit 2
out="$(cd "$work" && bash "$check" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '不在 git repo'; then
  echo '✓ ⑨ 不在 git repo → exit 2（fail closed）'; n=$((n + 1))
else
  echo "✗ ⑨ 不在 git repo 應 exit 2（實得 ${got}：${out}）" >&2; fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "✗ conflict-marker-check 自測失敗" >&2
  exit 1
fi
echo "✓ conflict-marker-check 自測通過（${n} 組樣本）"
