#!/bin/bash
# merge-conflict-check.sh 的自測（LS-50）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若檢查退化成衝突放行、缺 ref 靜默跳過、或拿過期的 origin/<target>
# 比對而假綠，這裡會紅。用 file:// 裸 repo 當遠端，ls-remote 不需網路。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/scripts/gates/merge-conflict-check.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
R="$work/repo"
remote="$work/remote.git"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

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

git init -q --bare "$remote"
mkdir -p "$R"
g init -q -b development
printf 'a\nb\nc\n' > "$R/shared.txt"
echo x > "$R/other.txt"
g add -A
g commit -qm 'chore(harness): LS-1 init'
g remote add origin "$remote"
g push -q origin development
dev0=$(g rev-parse HEAD)

# ① feature 只改 other.txt → 可乾淨合併
g checkout -q -b feature/LS-40-clean
echo y > "$R/other.txt"
g commit -qam 'feat(ios): LS-40 other'
expect 0 '① 與 origin/development 無衝突 → 綠' '可乾淨合併' --target origin/development

# ② development 改 shared.txt 同一行並推上遠端；feature 也改同一行 → 紅並點名檔案（PR #77 形狀）
g checkout -q development
printf 'a\nB-dev\nc\n' > "$R/shared.txt"
g commit -qam 'feat(db): LS-2 dev edits shared'
g push -q origin development
dev1=$(g rev-parse HEAD)
g checkout -q feature/LS-40-clean
printf 'a\nB-feat\nc\n' > "$R/shared.txt"
g commit -qam 'feat(ios): LS-40 feat edits shared'
expect 1 '② 同檔同行衝突 → 紅並點名 shared.txt' '    shared.txt' --target origin/development

# ③ 照指示 git merge origin/development 解衝突後 → 綠
g merge -q origin/development >/dev/null 2>&1 || true
printf 'a\nB-both\nc\n' > "$R/shared.txt"
g add shared.txt
g commit -qm 'fix(ios): LS-40 merge origin/development'
expect 0 '③ merge origin/development 解衝突後 → 綠' '可乾淨合併' --target origin/development

# ④ 本機 origin/development 落後遠端（遠端又前進、本機沒 fetch）→ exit 2 要求 fetch；fetch 後綠
g checkout -q development
echo n > "$R/new.txt"
g add new.txt
g commit -qm 'feat(db): LS-3 dev moves again'
g push -q origin development
g update-ref refs/remotes/origin/development "$dev1"
g checkout -q feature/LS-40-clean
expect 2 '④ 本機 origin/development 落後遠端 → exit 2（先 fetch，不拿過期 ref 假綠）' 'git fetch origin' --target origin/development
g fetch -q origin
expect 0 '④′ fetch 後 → 綠' '可乾淨合併' --target origin/development

# ⑤ 本機沒有 origin/main → exit 2（fail closed）
expect 2 '⑤ 本機無 origin/main → exit 2' 'git fetch origin' --target origin/main

# ⑥ 本機有 ref 但遠端沒有該分支 → exit 2
g update-ref refs/remotes/origin/main "$dev0"
expect 2 '⑥ 遠端沒有 main → exit 2' '遠端 origin 沒有分支 main' --target origin/main

# ⑦ 參數形狀
expect 2 '⑦ --target 不是 <remote>/<branch> → exit 2' '<remote>/<branch>' --target development
expect 2 '⑦′ 缺 --target → exit 2' '' 

if [ "$fail" -ne 0 ]; then
  echo "✗ merge-conflict-check 自測失敗" >&2
  exit 1
fi
echo "✓ merge-conflict-check 自測通過（9 組樣本）"
