#!/bin/bash
# evidence-path-check.sh 的自測（LS-61）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若檢查退化成只看第一層目錄、把檔名當目錄、漏掉 rename 目的地、
# 把白名單外的 png 放行、大小寫敏感、被引號檔名騙過、非 repo 假綠、或反過來擋了刪除／掃起工作區，這裡會紅。
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
expect 1 '④ ls99r1-review/scan.html（非 png，目錄層 *-review*/）→ 紅' 'ls99r1-review/scan.html'
g rm -q --cached ls99r1-review/scan.html

# ⑤ 目錄名規則看任一層、且不看 png 白名單：docs/img/design-review/r3/shot.png → 紅
mk docs/img/design-review/r3/shot.png
g add docs/img/design-review/r3/shot.png
expect 1 '⑤ 深層目錄 docs/img/design-review/…（png 在白名單內仍擋）→ 紅' 'docs/img/design-review/r3/shot.png'
g rm -q --cached docs/img/design-review/r3/shot.png

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

# ⑬ 目錄名規則是 review*／*-review*、不是 *review*：Xcode 預設的 Preview Content/ 放行（orchestrator 裁決）
mk 'Preview Content/x.swift' 'LittleSprout/Preview Content/y.swift'
g add 'Preview Content/x.swift' 'LittleSprout/Preview Content/y.swift'
expect 0 '⑬ Preview Content/（含 review 子字串但非 review 開頭／-review）→ 綠'
g rm -q --cached 'Preview Content/x.swift' 'LittleSprout/Preview Content/y.swift'

# ⑭ 收窄後兩種形狀仍擋：-review 尾綴（歷史 ls46r8-review/）與 review 開頭（review-notes/）
mk ls46r8-review/x.png review-notes/x.png
g add ls46r8-review/x.png review-notes/x.png
expect 1 '⑭ ls46r8-review/x.png（*-review*）仍擋' 'ls46r8-review/x.png'
expect 1 '⑭′ review-notes/x.png（review* 開頭）仍擋' 'review-notes/x.png'
g rm -q --cached ls46r8-review/x.png review-notes/x.png

# ⑮ png 白名單含 LittleSprout/Preview Content/（Xcode 模板的 Preview Assets.xcassets 會帶 png）→ 綠
mk 'LittleSprout/Preview Content/Preview Assets.xcassets/sample.imageset/sample.png'
g add 'LittleSprout/Preview Content/Preview Assets.xcassets/sample.imageset/sample.png'
expect 0 '⑮ LittleSprout/Preview Content/…/sample.png（白名單）→ 綠'
g rm -q --cached 'LittleSprout/Preview Content/Preview Assets.xcassets/sample.imageset/sample.png'

# ⑯ R1 M1：png 白名單是 docs/img/，不是整個 docs/（repo 最常寫的目錄，放行不會 fail loud）
mk docs/screenshots/home.png
g add docs/screenshots/home.png
expect 1 '⑯ docs/screenshots/home.png（docs/ 非 docs/img/）→ 紅' 'docs/screenshots/home.png'
g rm -q --cached docs/screenshots/home.png

# ⑰ R1 I4：白名單是精確的 LittleSprout/Assets.xcassets/——Assets* 會吃掉 AssetsFake/
mk LittleSprout/AssetsFake/x.png
g add LittleSprout/AssetsFake/x.png
expect 1 '⑰ LittleSprout/AssetsFake/x.png → 紅' 'LittleSprout/AssetsFake/x.png'
g rm -q --cached LittleSprout/AssetsFake/x.png

# ⑱ R1 I3：目錄規則大小寫不敏感（非 png 只有目錄規則擋得住）
mk LS46r9/scan.html Review-shots/x.html
g add LS46r9/scan.html Review-shots/x.html
expect 1 '⑱ LS46r9/scan.html（大寫 LS）→ 紅' 'LS46r9/scan.html'
expect 1 '⑱′ Review-shots/x.html（大寫 Review）→ 紅' 'Review-shots/x.html'
g rm -q --cached LS46r9/scan.html Review-shots/x.html

# ⑲ R1 I1：檔名含 " 時 --name-only 會加引號輸出、*.png 對不上；-z 讀取後仍要擋且原樣點名
mk 'ls99r1/sh"ot.png'
g add 'ls99r1/sh"ot.png'
expect 1 '⑲ ls99r1/sh"ot.png（引號檔名）→ 紅' 'sh"ot.png'
g rm -q --cached 'ls99r1/sh"ot.png'

# ⑳ R1 I2：帶路徑參數指到非 git 目錄 → exit 2 fail closed（不是印 ✓ 假綠）
mkdir -p "$work/notrepo"
out="$(bash "$checker" "$work/notrepo" 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF 'fail closed'; then
  echo '✓ ⑳ 非 git 目錄 → exit 2 fail closed'
else
  echo "✗ ⑳ 非 git 目錄 → exit 2 fail closed（期望 exit 2、輸出含「fail closed」，實得 ${got}）" >&2
  printf '%s\n' "$out" | sed 's/^/    /' >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "✗ evidence-path-check 自測失敗" >&2
  exit 1
fi
echo "✓ evidence-path-check 自測通過"
