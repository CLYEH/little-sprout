#!/bin/bash
# ci-cache-check.sh 的自測（LS-350）。CI rules job 每個 PR／push 都跑。
#
# 票文三例：① tree 相同→命中（空 commit／FF 同 SHA，印「沿用 run <id>（tree <sha>）」）；② tree 不同→未命中；
# ③ harness＋Swift 混改→不略過。另補：harness-only→略過、harness-only 但動到 ci.yml→不略過、dispatch 在保護分支
# →強制全跑（即使快取有）、dispatch 在工作分支→blocked、gh 失敗→照跑、過期 artifact 不算、PR 且 UI 觸發判定略過
# →record=false、參數錯 exit 2。
# mutation：key 改成 commit sha（HEAD）→ ① 必翻成未命中；混改判定改成「任一 harness 即略過」→ ③b 必翻成略過；
# 不可略過清單拿掉 docs/legal／.swift → R1 M1 兩夾具必翻成略過。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/selftest-helpers.sh
source "${root}/scripts/gates/lib/selftest-helpers.sh"
checker="${root}/scripts/gates/ci-cache-check.sh"
fail=0
ok() { echo "✓ $1"; }
fail() { echo "✗ $1" >&2; fail=1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# 假 gh：`gh api repos/x/y/actions/artifacts?name=<n>&...` → 印 $CI_CACHE_FAKE_STORE/<n>.json（沒有就空列表）；
# CI_CACHE_FAKE_FAIL=1 → exit 1。其餘引數一律 exit 1（呼叫形狀變了要讓測試紅）。
mkdir -p "${work}/bin" "${work}/store"
cat > "${work}/bin/gh" <<'EOF'
#!/bin/bash
[ "${CI_CACHE_FAKE_FAIL:-0}" = 1 ] && exit 1
[ "$1" = api ] || exit 1
case "$2" in
  repos/x/y/actions/artifacts\?name=*) ;;
  *) exit 1 ;;
esac
name=${2#*name=}; name=${name%%&*}
if [ -f "${CI_CACHE_FAKE_STORE}/${name}.json" ]; then cat "${CI_CACHE_FAKE_STORE}/${name}.json"
else echo '{"total_count":0,"artifacts":[]}'; fi
EOF
chmod +x "${work}/bin/gh"
export PATH="${work}/bin:$PATH" CI_CACHE_FAKE_STORE="${work}/store"

record() {   # record <tree> <run id> [expired]
  printf '{"total_count":1,"artifacts":[{"id":9,"name":"ci-tree-%s","expired":%s,"created_at":"2026-09-23T00:00:00Z","workflow_run":{"id":%s}}]}\n' \
    "$1" "${3:-false}" "$2" > "${CI_CACHE_FAKE_STORE}/ci-tree-$1.json"
}

repo="${work}/repo"
git init -q -b main "$repo"
git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
mkdir -p "$repo/LittleSprout" "$repo/scripts/ops" "$repo/docs" "$repo/.github/workflows"
echo a > "$repo/LittleSprout/A.swift"; echo s > "$repo/scripts/ops/x.sh"; echo d > "$repo/docs/d.md"
echo w > "$repo/.github/workflows/ci.yml"
git -C "$repo" add -A; git -C "$repo" commit -qm base
base_sha=$(git -C "$repo" rev-parse HEAD)

run() {   # run <checker> <args…>：在 $repo 內跑，輸出 stdout＋output 檔內容，rc 放 $rc
  local c=$1; shift
  : > "${work}/out"
  out=$(cd "$repo" && bash "$c" --repo x/y --output "${work}/out" "$@" 2>&1); rc=$?
  outs=$(cat "${work}/out")
}

# ① tree 相同 → 命中（空 commit：新 SHA、同 tree——FF 晉升／空 merge commit 的形狀）
tree0=$(git -C "$repo" rev-parse 'HEAD^{tree}')
record "$tree0" 111
git -C "$repo" commit -q --allow-empty -m empty
run "$checker" --event push --ref refs/heads/test
expect_exit 0 "$rc" "① tree 相同：exit 0" || fail=1
expect_has "$out" "沿用 run 111（tree ${tree0}）" "① tree 相同：印沿用來源 run 與 tree" || fail=1
expect_has "$outs" "mode=hit" "① tree 相同：mode=hit" || fail=1
expect_has "$outs" "skip_macos=true" "① tree 相同：skip_macos=true" || fail=1
expect_has "$outs" "skip_db=true" "① tree 相同：skip_db=true" || fail=1
expect_has "$outs" "record=false" "① tree 相同：命中不重複登記" || fail=1

# 過期 artifact 不算
record "$tree0" 111 true
run "$checker" --event push --ref refs/heads/test
expect_has "$outs" "mode=full" "①b 過期 artifact 不算命中" || fail=1
record "$tree0" 111

# ② tree 不同 → 未命中、record=true（push）
echo b > "$repo/LittleSprout/A.swift"; git -C "$repo" commit -qam change
run "$checker" --event push --ref refs/heads/development
expect_has "$outs" "mode=full" "② tree 不同：mode=full" || fail=1
expect_has "$outs" "skip_macos=false" "② tree 不同：skip_macos=false" || fail=1
expect_has "$outs" "record=true" "② tree 不同：push 全跑可登記" || fail=1
expect_not_has "$out" "沿用 run" "② tree 不同：不印沿用" || fail=1
git -C "$repo" reset -q --hard "$base_sha"

# gh 失敗 → 照跑（fail-safe）
CI_CACHE_FAKE_FAIL=1 run "$checker" --event push --ref refs/heads/test
expect_has "$outs" "mode=full" "gh 失敗：當未命中照跑" || fail=1
expect_has "$out" "查 ci-tree-" "gh 失敗：印 warning" || fail=1

# workflow_dispatch：保護分支強制全跑（快取存在也不查）；工作分支 blocked
run "$checker" --event workflow_dispatch --ref refs/heads/main
expect_has "$outs" "mode=full" "dispatch main：強制全跑（不吃快取）" || fail=1
expect_has "$outs" "record=true" "dispatch main：可登記" || fail=1
run "$checker" --event workflow_dispatch --ref refs/heads/feature/LS-1-x
expect_has "$outs" "mode=blocked" "dispatch 工作分支：blocked" || fail=1
expect_has "$outs" "skip_macos=true" "dispatch 工作分支：不上 macOS" || fail=1

# PR 情境：在 feature 分支上改檔，base＝main
pr_case() {   # pr_case <名稱> <檔…>：從 base 切分支、改列出的檔、commit
  git -C "$repo" checkout -q -B "pr-$1" "$base_sha"
  local f; shift
  for f in "$@"; do mkdir -p "$repo/$(dirname "$f")"; echo "$RANDOM$f" >> "$repo/$f"; done
  git -C "$repo" add -A; git -C "$repo" commit -qm "$1"
}

# ③ 混改 → 不略過
pr_case mixed scripts/ops/x.sh LittleSprout/A.swift
run "$checker" --event pull_request --base main
expect_has "$outs" "mode=full" "③ 混改：mode=full（不略過）" || fail=1
expect_has "$outs" "skip_macos=false" "③ 混改：skip_macos=false" || fail=1
expect_has "$out" "非 harness-only（含 LittleSprout/A.swift）" "③ 混改：點名非 harness 檔" || fail=1
expect_has "$outs" "record=true" "③ 混改含 Swift：UI 觸發判定要跑→完整集合可登記" || fail=1

# ③b 混改（非 Swift 的非 harness 檔：project.yml）→ 不略過。③ 的 Swift 檔自 R1 M1 起也會被不可略過清單的 .swift
# 擋下（雙重保護），M2 要單獨證明「混改規則」本身，所以用這個不含 .swift 的夾具
pr_case mixed2 scripts/ops/x.sh project.yml
run "$checker" --event pull_request --base main
expect_has "$outs" "mode=full" "③b 混改（project.yml）：mode=full（不略過）" || fail=1
expect_has "$out" "非 harness-only（含 project.yml）" "③b 混改：點名非 harness 檔" || fail=1

# harness-only → 略過 macOS，db 照跑
pr_case harness scripts/ops/x.sh docs/d.md CLAUDE.md .claude/agents/a.md
run "$checker" --event pull_request --base main
expect_has "$outs" "mode=harness-skip" "harness-only：mode=harness-skip" || fail=1
expect_has "$outs" "skip_macos=true" "harness-only：skip_macos=true" || fail=1
expect_has "$outs" "skip_db=false" "harness-only：db 照跑" || fail=1
expect_has "$outs" "record=false" "harness-only：不登記" || fail=1

# harness-only 但動到 ci.yml（macOS job 機制檔）→ 不略過；UI 判定略過→record=false
pr_case mech scripts/ops/x.sh .github/workflows/ci.yml
run "$checker" --event pull_request --base main
expect_has "$outs" "mode=full" "機制檔：不略過" || fail=1
expect_has "$out" "不可略過檔 .github/workflows/ci.yml" "機制檔：點名" || fail=1
expect_has "$outs" "record=false" "機制檔：PR 無 UI 變更→非完整集合不登記" || fail=1

# R1 M1：harness 目錄下但 macOS job 會讀到的檔 → 不略過
pr_case legal docs/legal/terms-of-service.md
run "$checker" --event pull_request --base main
expect_has "$outs" "mode=full" "不可略過：docs/legal/ 改動不略過（app bundle＋LegalMarkdownDocumentTests）" || fail=1
expect_has "$out" "不可略過檔 docs/legal/terms-of-service.md" "不可略過：點名 docs/legal 檔" || fail=1
pr_case swift scripts/ops/review-demo-genvideo.swift docs/d.md
run "$checker" --event pull_request --base main
expect_has "$outs" "mode=full" "不可略過：scripts/ 下的 .swift 不略過（swiftlint --strict 範圍）" || fail=1
expect_has "$out" "不可略過檔 scripts/ops/review-demo-genvideo.swift" "不可略過：點名 .swift 檔" || fail=1

# 非 harness、非 UI（supabase/）→ 全跑但不登記
pr_case db supabase/migrations/1.sql
run "$checker" --event pull_request --base main
expect_has "$outs" "mode=full" "supabase-only：全跑" || fail=1
expect_has "$outs" "record=false" "supabase-only：UI 判定略過→不登記" || fail=1

# 參數錯
run "$checker" --event bogus
expect_exit 2 "$rc" "參數錯：--event 非法 exit 2" || fail=1
run "$checker" --event pull_request
expect_exit 2 "$rc" "參數錯：PR 缺 --base exit 2" || fail=1

# ---- mutation ----
# mutant 放 $work/gates/，旁邊擺一份 ui-test-trigger.sh（checker 以自身目錄找它），不在 repo 內留檔
mkdir -p "${work}/gates"; cp "${root}/scripts/gates/ui-test-trigger.sh" "${work}/gates/"
mut="${work}/gates/ci-cache-check.sh"
# M1：key 改成 commit sha → ① 空 commit 必翻成未命中
sed '/# CI-CACHE-KEY$/s/HEAD\^{tree}/HEAD/' "$checker" > "$mut"
if ! grep -q "rev-parse 'HEAD' " "$mut"; then fail "M1 mutant 沒建成（CI-CACHE-KEY 行形狀變了）"; fi
git -C "$repo" checkout -q main; git -C "$repo" reset -q --hard "$base_sha"
git -C "$repo" commit -q --allow-empty -m empty2
run "$mut" --event push --ref refs/heads/test
expect_not_has "$outs" "mode=hit" "M1 key 改 commit sha：① 翻成未命中（證明 ① 釘住 tree key）" || fail=1
# M2：混改判定改「任一 harness 即略過」→ ③ 必翻成略過
sed '/# CI-CACHE-MIXED$/s/grep -Ev "\$harness"/grep -E "^$"/' "$checker" > "$mut"
if ! grep -q 'grep -E "^\$" | grep -m1' "$mut"; then fail "M2 mutant 沒建成（CI-CACHE-MIXED 行形狀變了）"; fi
git -C "$repo" checkout -q pr-mixed2
run "$mut" --event pull_request --base main
expect_has "$outs" "mode=harness-skip" "M2 混改判定放寬：③b 翻成略過（證明 ③b 釘住混改規則）" || fail=1

# M3：不可略過清單拿掉 docs/legal 與 .swift → 兩個 R1 M1 夾具必翻成略過
sed '/# CI-CACHE-MECH$/s/|docs\/legal\/\.\*|\.\*\\\.swift)/)/' "$checker" > "$mut"
if grep -q 'docs/legal' <(grep 'CI-CACHE-MECH$' "$mut"); then fail "M3 mutant 沒建成（CI-CACHE-MECH 行形狀變了）"; fi
git -C "$repo" checkout -q pr-legal
run "$mut" --event pull_request --base main
expect_has "$outs" "mode=harness-skip" "M3 拿掉 docs/legal：legal 夾具翻成略過（證明夾具釘住該規則）" || fail=1
git -C "$repo" checkout -q pr-swift
run "$mut" --event pull_request --base main
expect_has "$outs" "mode=harness-skip" "M3 拿掉 .swift：swift 夾具翻成略過（證明夾具釘住該規則）" || fail=1

if [ "$fail" -ne 0 ]; then
  echo "✗ ci-cache-check.test.sh：有失敗" >&2
  exit 1
fi
echo "✓ ci-cache-check.test.sh 全數通過"
