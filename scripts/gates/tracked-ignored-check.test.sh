#!/bin/bash
# tracked-ignored-check.sh 的自測（LS-51）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若檢查退化成只看 untracked、只讀根 .gitignore、
# 或吃了本機專屬 excludes，這裡會紅。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="${root}/scripts/gates/tracked-ignored-check.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 臨時 repo 與本機全域／系統 git 設定隔離：自測結果不能因人而異
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -C "$work/repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

mkdir -p "$work/repo/design-canvas-d/shots"
g init -q
printf 'design-canvas*/_shotcheck.html\ndesign-canvas*/shots/\n' > "$work/repo/.gitignore"
printf 'verified.json\n' > "$work/repo/design-canvas-d/.gitignore"
echo src > "$work/repo/design-canvas-d/Main.dc.html"
echo src > "$work/repo/design-canvas-d/_probe.html"
echo out > "$work/repo/design-canvas-d/_shotcheck.html"
echo out > "$work/repo/design-canvas-d/shots/Main.png"
echo out > "$work/repo/design-canvas-d/verified.json"

# expect <期望 exit code> <樣本名稱> [<輸出必含字串>]
expect() {
  local want=$1 name=$2 must=${3:-} out got
  out="$(bash "$checker" "$work/repo" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ] && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; }; then
    echo "✓ $name"
  else
    echo "✗ $name（期望 exit $want${must:+、輸出含「$must」}，實得 $got）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}

# ① 只追蹤來源檔；執行產物躺在工作區但未追蹤 → 綠（gate 管的是 index，不是工作區）
g add -A
g commit -qm src
expect 0 '① 來源檔已追蹤＋產物未追蹤 → 綠'

# ② git add -f 硬加、尚未 commit（pre-commit 當下的形狀）→ 紅，且點名該檔
g add -f design-canvas-d/_shotcheck.html
expect 1 '② staged 的 git add -f 硬加檔 → 紅' 'design-canvas-d/_shotcheck.html'
g rm -q --cached design-canvas-d/_shotcheck.html

# ③ 規則落地前就已 commit（三軌 _shotcheck.html 的真實形狀）→ 紅；照印出的解法 git rm --cached → 綠
printf '' > "$work/repo/.gitignore"
g add -A
g commit -qm 'before rule'
printf 'design-canvas*/_shotcheck.html\ndesign-canvas*/shots/\n' > "$work/repo/.gitignore"
g add .gitignore
g commit -qm 'rule lands'
expect 1 '③ 規則落地前已 commit 的產物 → 紅' 'design-canvas-d/shots/Main.png'
g rm -q -r --cached design-canvas-d/_shotcheck.html design-canvas-d/shots
g commit -qm 'untrack'
expect 0 '③′ git rm --cached 後 → 綠'

# ④ 規則只寫在子目錄的 .gitignore → 也要紅（各軌自己的 .gitignore 仍生效）
g add -f design-canvas-d/verified.json
expect 1 '④ 子目錄 .gitignore 的規則命中 → 紅' 'design-canvas-d/verified.json'
g rm -q --cached design-canvas-d/verified.json

# ⑤ 本機專屬 excludes（core.excludesFile／.git/info/exclude）不算數：
#    兩處都 ignore *.dc.html，已追蹤的 Main.dc.html 若被算進來就會誤紅
printf '*.dc.html\n' > "$work/global-excludes"
g config core.excludesFile "$work/global-excludes"
printf '*.dc.html\n' > "$work/repo/.git/info/exclude"
expect 0 '⑤ 本機專屬 excludes 不納入比對 → 綠'
g config --unset core.excludesFile
printf '' > "$work/repo/.git/info/exclude"

# ⑥ 子目錄 .gitignore 加否定行 `!_shotcheck.html`（PR #79 R1 F1）→ 必紅，且點名 <path>:<line>。
#    否定後 _shotcheck.html 不再 ignored：不用 -f 就能 add（順便證明否定確實生效），
#    第一檢查看不見它——只有否定行偵測擋得住
printf 'verified.json\n!_shotcheck.html\n' > "$work/repo/design-canvas-d/.gitignore"
g add design-canvas-d/.gitignore design-canvas-d/_shotcheck.html
expect 1 '⑥ 子目錄 .gitignore 否定行（檔案已不再 ignored）→ 紅' 'design-canvas-d/.gitignore:2: 子目錄否定規則會讓根規則失效'
g rm -q --cached design-canvas-d/_shotcheck.html

# ⑦ 子目錄 .gitignore 只有收窄規則（含註解與空行）→ 綠
printf '# 軌內額外產物\nverified.json\n\n_scratch-*.html\n' > "$work/repo/design-canvas-d/.gitignore"
g add design-canvas-d/.gitignore
expect 0 '⑦ 子目錄 .gitignore 只收窄（無否定行）→ 綠'

if [ "$fail" -ne 0 ]; then
  echo "✗ tracked-ignored-check 自測失敗" >&2
  exit 1
fi
echo "✓ tracked-ignored-check 自測通過"
