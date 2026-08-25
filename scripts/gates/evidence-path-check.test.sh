#!/bin/bash
# evidence-path-check.sh 的自測（LS-61）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若檢查退化成只看第一層目錄、把檔名當目錄、漏掉 rename 目的地、
# 把白名單外的 png 放行、或反過來擋了刪除／掃起工作區，這裡會紅。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="${root}/scripts/gates/evidence-path-check.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 臨時 repo 與本機全域／系統 git 設定隔離：自測結果不能因人而異（也不會跑到本 repo 的 hook）
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -C "$work/repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
# mk <相對路徑>…：建檔（內容不重要，看的是路徑）
mk() { local p; for p in "$@"; do mkdir -p "$work/repo/$(dirname "$p")"; echo x > "$work/repo/$p"; done; }

# expect <期望 exit code> <樣本名稱> [<輸出必含字串>]
expect() {
  local want=$1 name=$2 must=${3:-} out got
  out="$(bash "$checker" "$work/repo" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ] && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; }; then
    echo "✓ ${name}"
  else
    echo "✗ ${name}（期望 exit ${want}${must:+、輸出含「${must}」}，實得 ${got}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}

mkdir -p "$work/repo"
g init -q

# ① 白名單內 png＋一般檔；檔名含 review／ls<數字> 但不是目錄層 → 綠
mk design/home.png 'LittleSprout/Assets.xcassets/AppIcon.appiconset/icon.png' docs/img/flow.png \
   LittleSprout/Features/Home.swift .claude/agents/visual-reviewer.md docs/ls46-notes.md
g add -A
expect 0 '① 白名單內 png、檔名含 review／ls<n> 但非目錄層 → 綠'
g commit -qm base

# ② 沒有 staged 變更 → 綠
expect 0 '② 無 staged 變更 → 綠'

# ③ 票文驗收樣本：ls99r1/x.png → 紅，且點名該檔
mk ls99r1/x.png
g add ls99r1/x.png
expect 1 '③ ls99r1/x.png（目錄層 ls[0-9]*/）→ 紅' 'ls99r1/x.png'
g rm -q --cached ls99r1/x.png

# ④ 非 png 的掃描輸出，靠目錄名擋：ls99r1-review/scan.html → 紅
mk ls99r1-review/scan.html
g add ls99r1-review/scan.html
expect 1 '④ ls99r1-review/scan.html（非 png，目錄層 *review*/）→ 紅' 'ls99r1-review/scan.html'
g rm -q --cached ls99r1-review/scan.html

# ⑤ 目錄名規則看任一層、且不看白名單：docs/design-review/r3/notes.md → 紅
mk docs/design-review/r3/notes.md
g add docs/design-review/r3/notes.md
expect 1 '⑤ 深層目錄 docs/design-review/…（白名單內仍擋）→ 紅' 'docs/design-review/r3/notes.md'
g rm -q --cached docs/design-review/r3/notes.md

# ⑥ 目錄名無異狀、但 png 落在白名單外 → 紅
mk Screenshots/home.png
g add Screenshots/home.png
expect 1 '⑥ 白名單外 png（Screenshots/home.png）→ 紅' 'Screenshots/home.png'
g rm -q --cached Screenshots/home.png

# ⑦ LittleSprout/ 底下只有 Assets* 是白名單；副檔名大寫也算 png
mk LittleSprout/Features/home.PNG
g add LittleSprout/Features/home.PNG
expect 1 '⑦ LittleSprout/ 非 Assets* 的 .PNG → 紅' 'LittleSprout/Features/home.PNG'
g rm -q --cached LittleSprout/Features/home.PNG

# ⑧ 固定位置 .claude/evidence/：.gitignore 先擋（add 直接失敗、index 無變更 → 綠）；-f 硬加 → 紅
printf '.claude/evidence/\n' > "$work/repo/.gitignore"
g add .gitignore
g commit -qm ignore
mk .claude/evidence/LS-61/r1/x.png
g add .claude/evidence/LS-61/r1/x.png >/dev/null 2>&1 || true
expect 0 '⑧ 固定位置被 .gitignore 擋在 index 外 → 綠'
g add -f .claude/evidence/LS-61/r1/x.png
expect 1 '⑧′ 固定位置 git add -f 硬加 → 紅' '.claude/evidence/LS-61/r1/x.png'
g rm -q --cached .claude/evidence/LS-61/r1/x.png

# ⑨ 取證只躺在工作區、未 add → 綠（本 gate 只看 index；未追蹤是 §7 明載的盲區，不是誤放行）
mk ls99r2/y.png
expect 0 '⑨ 取證只在工作區未 add → 綠（只看 index）'

# ⑩ 清掉歷史誤入版控的取證（staged 刪除）要放行；臨時 repo 沒有 hook，可直接把它 commit 進去模擬歷史
mk ls46r8/old.png
g add ls46r8/old.png
g commit -qm historical
g rm -q ls46r8/old.png
expect 0 '⑩ 刪除歷史誤入版控的取證（staged D）→ 綠'
g commit -qm cleanup

# ⑪ rename 目的地也要看：design/home.png → shots/home.png → 紅，點名目的地
mkdir -p "$work/repo/shots"
g mv design/home.png shots/home.png
expect 1 '⑪ rename 到白名單外（design/home.png → shots/home.png）→ 紅' 'shots/home.png'
g mv shots/home.png design/home.png

# ⑫ 多檔命中一次全列（不是碰到第一個就停）
mk ls99r1/x.png Screenshots/home.png
g add ls99r1/x.png Screenshots/home.png
expect 1 '⑫ 多檔命中一次全列（第一檔）' 'ls99r1/x.png'
expect 1 '⑫′ 多檔命中一次全列（第二檔）' 'Screenshots/home.png'
g rm -q --cached ls99r1/x.png Screenshots/home.png

if [ "$fail" -ne 0 ]; then
  echo "✗ evidence-path-check 自測失敗" >&2
  exit 1
fi
echo "✓ evidence-path-check 自測通過"
