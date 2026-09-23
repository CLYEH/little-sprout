#!/bin/bash
# gate-usage-report.sh 的自測（LS-351 範圍 2）。CI rules job 跑；不打真 GitHub——gh 用 PATH 前置的假身，
# 回固定的 run 清單與 --log-failed 內容；git log 近似用合成 repo 的 commit 訊息。
# 覆蓋：git log 近似（同行 gate 名＋攔／擋字樣才算；改動 gate 檔本身的 commit 不算；無關鍵字不算）、
# CI（✗ 行含 gate 名才算；step 腳本回顯 ESC[36;1m 與「自測」step 不算；認不出 gate 名的紅行列「未歸屬」）、
# *.test.sh 不列、退役候選 Y/N 與總數、--no-ci 略過 CI 且註明、參數錯 exit 2；
# mutation：拿掉「改動 gate 檔本身不算」→ bar-check 被誤計 1 次、不再是候選。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ops/gate-usage-report.sh"
fail=0
source "${root}/scripts/gates/lib/selftest-helpers.sh"
fail() { echo "✗ $1" >&2; fail=1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# ---- 合成 repo：三支 gate（＋一支自測，不得列出）、一支 hook ----
repo="$work/repo"
git init -q -b main "$repo"
g() { git -C "$repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
mkdir -p "$repo/scripts/gates" "$repo/scripts/hooks"
for f in foo-check bar-check baz-check foo-check.test; do printf '#!/bin/bash\n' > "$repo/scripts/gates/$f.sh"; done
printf '#!/bin/bash\n' > "$repo/scripts/hooks/qux-guard.sh"
g add -A; g commit -q -m 'chore: LS-1 init'
: > "$repo/README.md"; g add -A; g commit -q -m 'fix: LS-2 被 foo-check 擋下後改寫 body'
printf '# x\n' >> "$repo/scripts/gates/bar-check.sh"; g add -A; g commit -q -m 'fix: LS-3 bar-check 擋錯樣式的修正'
printf 'x\n' >> "$repo/README.md"; g add -A; g commit -q -m 'docs: LS-4 提到 baz-check 但沒有關鍵字'

# ---- stub gh ----
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'EOF'
#!/bin/bash
case "$1 $2" in
  'run list') echo '[{"databaseId":11},{"databaseId":12}]' ;;
  'run view')
    if [ "$3" = 11 ]; then
      printf 'rules\tPR body check\t2026-09-19T14:59:48.9135765Z ✗ qux-guard：deny 樣本\n'
      printf 'rules\tPR body check\t2026-09-19T14:59:48.9135765Z \033[36;1m  echo "✗ baz-check：腳本回顯"\033[0m\n'
      printf 'rules\tGate 腳本自測（baz-check）\t2026-09-19T14:59:48.9135765Z ✗ baz-check 自測失敗\n'
      printf 'rules\tPR body check\t- ✗ baz-check 出現在沒有時間戳的 PR body 引文\n'
    else
      printf 'ci\tBuild\t2026-09-19T14:59:48.9135765Z ##[error]::error::無關的編譯錯誤\n'
    fi ;;
  *) echo "stub gh：未預期的呼叫 $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/gh"

out="$(PATH="$work/bin:$PATH" bash "$script" --repo "$repo" 2>&1)"; rc=$?
expect_exit 0 "$rc" '① 正常跑一輪 exit 0'
expect_has "$out" '| `scripts/gates/foo-check.sh` | 1 | git log 近似 1 | N |' '① git log 近似：同行 gate 名＋「擋」→ foo-check 1 次、非候選'
expect_has "$out" '| `scripts/gates/bar-check.sh` | 0 |' '① 改動 gate 檔本身的 commit 不算攔截 → bar-check 0'
expect_has "$out" '| `scripts/gates/baz-check.sh` | 0 | —（CI＋git log 近似皆 0） | Y |' '① baz-check：無關鍵字 commit／腳本回顯／自測 step／無時間戳引文都不算 → 0、候選 Y'
expect_has "$out" '| `scripts/hooks/qux-guard.sh` | 1 | CI 1 | N |' '① CI：帶時間戳的 ✗ 行含 hook 名 → qux-guard CI 1'
expect_not_has "$out" 'foo-check.test.sh' '① *.test.sh 不列入'
expect_has "$out" '- ci／Build ×1' '① 認不出 gate 名的紅行列「未歸屬」（job／step ×次數）'
expect_has "$out" '退役候選 2／4 支' '① 退役候選總數 2／4'
expect_has "$out" 'CI：30 天內失敗 run 2 支，讀 log 2 支' '① 註記 CI 讀了幾支 run'

out="$(PATH="$work/bin:$PATH" bash "$script" --repo "$repo" --no-ci 2>&1)"; rc=$?
expect_exit 0 "$rc" '② --no-ci exit 0'
expect_has "$out" '| `scripts/hooks/qux-guard.sh` | 0 | —（僅 git log 近似） | Y |' '② --no-ci：CI 次數不算、來源標「僅 git log 近似」'
expect_has "$out" 'CI 段略過（--no-ci）' '② --no-ci：註記 CI 段略過'

out="$(bash "$script" --repo "$repo" --days abc 2>&1)"; rc=$?
expect_exit 2 "$rc" '③ --days 非數字 → exit 2'
out="$(bash "$script" --repo "$work/nope" 2>&1)"; rc=$?
expect_exit 2 "$rc" '③ --repo 不是 git repo → exit 2'

# ④ mutation：拿掉「改動 gate 檔本身不算」→ bar-check 被誤計為 1、不再是候選——證明 ① 的 bar-check 0 來自這條排除
mut="$work/mut.sh"
sed 's/^        if path in files:$/        if False:  # LS-351 mutation/' "$script" > "$mut"
if ! grep -q 'LS-351 mutation' "$mut"; then
  fail '④ mutant 沒被正確合成'
else
  out="$(PATH="$work/bin:$PATH" bash "$mut" --repo "$repo" 2>&1)"
  expect_has "$out" '| `scripts/gates/bar-check.sh` | 1 | git log 近似 1 | N |' '④ mutant（拿掉自身 commit 排除）：bar-check 被誤計 1 次——證明 ① 的綠來自這條排除'
fi

if [ "$fail" -ne 0 ]; then
  echo "✗ gate-usage-report 自測失敗" >&2
  exit 1
fi
echo "✓ gate-usage-report 自測通過"
