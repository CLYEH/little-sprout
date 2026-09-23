#!/bin/bash
# CI 去重判定（LS-350）：決定這次 CI run 的 macOS job（lint／ci／ci-ipad）與 db job 要不要真的跑。
# 呼叫端：.github/workflows/ci.yml 的 `ci-dedup` job（ubuntu），輸出寫進 $GITHUB_OUTPUT 給下游 job 的
# runs-on／step if 讀。
#
# 背景（09-23 流程覆盤）：一張票走 PR → development → test → main，同一個 tree 跑 4 次 ci.yml（每次 ci job
# 約 29 分、ci-ipad 約 6 分，都在 macOS runner）；FF 晉升（promote.sh）推上 test／main 的是**同一個 SHA**，
# 卻整套重跑。harness-only PR（只動 scripts/、docs/…）也照跑 macOS job。
#
# 判定順序（第一個成立的即採用）：
#   1. workflow_dispatch：只准 development／test／main（refs/heads/*）——那三支的 dispatch run 與 push run
#      同形（rules 的 PR 專屬 step 兩者都跳過），貼上去的同名 check-run 不會頂掉更嚴的結果；對工作分支
#      dispatch 則會在 PR head SHA 貼一組缺 PR 上下文的同名 check-run、頂掉真 PR run（LS-139 R2 minor 1 的
#      原顧慮）→ mode=blocked（下游 job 第一步 fail loud）。准許的 dispatch＝強制全跑（不查快取）。
#   2. tree 快取：以 `git rev-parse HEAD^{tree}` 為 key，查 repo 內名為 `ci-tree-<tree>` 的未過期 artifact
#      （ci.yml `ci-tree-record` job 只在「完整 run 且 db／lint／ci／ci-ipad 全 success」時上傳）。命中 →
#      mode=hit，印「沿用 run <id>（tree <sha>）」。FF 晉升（同 SHA）、空 merge commit、PR merge 後 base 未動的
#      development merge commit（tree 等於 PR run 測過的 refs/pull/N/merge）都命中。
#      為何用 artifact 而非 actions/cache 或 commit status：actions/cache 的讀取範圍限「本分支＋預設分支
#      （PR 另加 base）」，development 存的 cache test 讀不到——FF 晉升這個主場景直接落空；commit status 掛在
#      commit 上、不是 tree 上，PR run 測的 refs/pull/N/merge 與併入後的 development merge commit 是兩個不相干的
#      SHA，也查不到空 merge commit 的同 tree。artifact 列表 API（`?name=`）是 repo 全域、可按名稱查、回帶
#      workflow_run.id，正好是「tree → 成功 run」的對照表。
#      查詢失敗（gh／jq 錯、無 repo）一律當未命中照跑（fail-safe 方向＝多跑，不是少跑）。
#   3. harness-only PR（只 pull_request）：`<base>...HEAD` 變更清單非空、每一個都在 harness 路徑、且沒有任何
#      一個是「macOS job 自己會執行／讀到的不可略過檔」（機制檔、docs/legal/**、*.swift）→ mode=harness-skip（略過 lint／ci／ci-ipad；rules、db 照跑）。
#      harness 路徑沿 docs/COLLABORATION.md §2「Harness 變更例外」清單放寬到目錄層級：CLAUDE.md、docs/、
#      .claude/、scripts/、.githooks/、.github/、.mcp.json。混改（任一檔不在 harness 路徑，例如 Swift／
#      xcodeproj／supabase/）一律不略過。push 事件不套路徑過濾：push run 是進 test／main 的 SHA 的完整 gate。
#   4. 其餘 → mode=full。
#
# record（這次 run 綠了能不能登記成 tree 快取）：只有 mode=full 且「這次真的跑了完整集合」才 true——
#   push／dispatch 一律完整；pull_request 時 ci job 的 Release 編譯與點擊目標 gate、ci-ipad 會依
#   ui-test-trigger.sh 判定略過（exit 3），略過時 PR run 不是完整集合，record=false（否則 development push
#   會沿用一個沒跑 UITests 的綠燈）。這條與 ci.yml 內那三處 ui-test-trigger 判定是同一個條件，改那邊要一起改。
#
# 用法：ci-cache-check.sh --event <pull_request|push|workflow_dispatch> [--ref <github.ref>] [--base <ref>]
#                         [--repo <owner/repo>] [--output <file>]
#   --base    pull_request 必給（例：origin/development）；--repo 預設 $GITHUB_REPOSITORY；
#   --output  key=value 追加寫入（CI 傳 $GITHUB_OUTPUT）：mode、tree、source_run、skip_macos、skip_db、record、message
# exit：0＝已判定（含 blocked——由下游 job fail）；2＝參數錯。
# 強制全跑：development／test／main 上 `gh workflow run ci.yml --ref <branch>`；PR 上刪掉命中的 artifact
#   （`gh api -X DELETE repos/{owner}/{repo}/actions/artifacts/<artifact id>`）後 rerun。
# 自測：ci-cache-check.test.sh（CI rules job）。規約見 docs/COLLABORATION.md §7。
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
event=; ref=; base=; repo=${GITHUB_REPOSITORY:-}; out=/dev/null
while [ $# -gt 0 ]; do
  case "$1" in
    --event|--ref|--base|--repo|--output)
      [ $# -ge 2 ] || { echo "✗ ci-cache-check：$1 缺值" >&2; exit 2; }
      case "$1" in
        --event) event=$2 ;; --ref) ref=$2 ;; --base) base=$2 ;; --repo) repo=$2 ;; --output) out=$2 ;;
      esac
      shift 2 ;;
    *) echo "✗ ci-cache-check：未知參數「$1」" >&2; exit 2 ;;
  esac
done
case "$event" in
  pull_request|push|workflow_dispatch) ;;
  *) echo "✗ ci-cache-check：--event 須為 pull_request|push|workflow_dispatch（實得「${event}」）" >&2; exit 2 ;;
esac
if [ "$event" = pull_request ] && [ -z "$base" ]; then
  echo "✗ ci-cache-check：pull_request 須給 --base" >&2; exit 2
fi

emit() {   # emit <mode> <skip_macos> <skip_db> <record> <source_run> <message>
  echo "$6"
  {
    echo "mode=$1"; echo "tree=${tree:-}"; echo "source_run=$5"
    echo "skip_macos=$2"; echo "skip_db=$3"; echo "record=$4"; echo "message=$6"
  } >> "$out"
  exit 0
}

tree=$(git rev-parse 'HEAD^{tree}' 2>/dev/null)   # CI-CACHE-KEY
if [ -z "$tree" ]; then
  emit full false false false "" "::warning::CI 去重：取不到 HEAD^{tree}，照全跑（不登記快取）"
fi

# 1. workflow_dispatch
if [ "$event" = workflow_dispatch ]; then
  case "$ref" in
    refs/heads/development|refs/heads/test|refs/heads/main)
      emit full false false true "" "→ CI 去重：workflow_dispatch 強制全跑（${ref}，tree ${tree}，不查快取）" ;;
    *)
      emit blocked true true false "" "::error::CI 去重：workflow_dispatch 只限 development／test／main（本次 ${ref:-未知 ref}）——對工作分支 dispatch 會在 PR head SHA 貼缺 PR 上下文的同名 check-run、頂掉真 PR run（LS-139 R2）。PR 要強制全跑：刪掉命中的 ci-tree-<tree> artifact 後 rerun" ;;
  esac
fi

# 2. tree 快取
if [ -n "$repo" ]; then
  src=$(gh api "repos/${repo}/actions/artifacts?name=ci-tree-${tree}&per_page=20" 2>/dev/null \
        | jq -r '[.artifacts[] | select(.expired | not)] | sort_by(.created_at) | last | .workflow_run.id // empty' 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "::warning::CI 去重：查 ci-tree-${tree} artifact 失敗（gh／jq exit ${rc}），當未命中照跑"
    src=
  fi
  if [ -n "$src" ]; then
    emit hit true true false "$src" "→ CI 去重：沿用 run ${src}（tree ${tree}）——同 tree 已有完整全綠 run，lint／ci／ci-ipad／db 不重跑（rules 照跑；強制全跑見 COLLABORATION §7）"
  fi
else
  echo "::warning::CI 去重：無 --repo／GITHUB_REPOSITORY，不查快取"
fi

# 3. harness-only PR
if [ "$event" = pull_request ]; then
  changed=$(git -c core.quotePath=false diff --name-only --no-renames "${base}...HEAD" 2>/dev/null) || {
    emit full false false false "" "::warning::CI 去重：git diff ${base}...HEAD 失敗，照全跑（不登記快取）"; }
  harness='^(CLAUDE\.md$|docs/|\.claude/|scripts/|\.githooks/|\.github/|\.mcp\.json$)'   # CI-CACHE-HARNESS
  # 不可略過清單（macOS job 會讀到的 harness 路徑檔，與機制檔同一處維護；LS-350 R1 M1）：
  #   docs/legal/**  project.yml 打包進 app bundle，LittleSproutTests/LegalMarkdownDocumentTests 斷言其 version
  #   *.swift        任何路徑的 Swift 檔都在 lint job `swiftlint lint --strict` 範圍內（例：scripts/ops/review-demo-genvideo.swift）
  mech='^(\.github/workflows/ci\.yml|scripts/gates/(ci-cache-check|detect-simulator|ui-test-trigger|tap-target-check|list-ipad-tests|pick-ipad-runtime)\.sh|scripts/gates/tap-target-exemptions\.txt|docs/legal/.*|.*\.swift)$'   # CI-CACHE-MECH
  files=$(printf '%s\n' "$changed" | grep '[^[:space:]]' || true)
  n=$(printf '%s\n' "$files" | grep -c '[^[:space:]]' || true)
  non_harness=$(printf '%s\n' "$files" | grep -Ev "$harness" | grep -m1 '[^[:space:]]' || true)   # CI-CACHE-MIXED
  mech_hit=$(printf '%s\n' "$files" | grep -Em1 "$mech" || true)
  if [ "$n" -gt 0 ] && [ -z "$non_harness" ] && [ -z "$mech_hit" ]; then
    emit harness-skip true false false "" "→ CI 去重：harness-only PR（${n} 個檔皆在 harness 路徑）——略過 lint／ci／ci-ipad 的 macOS 執行，rules／db 照跑；併入後的 push run 仍全跑"
  fi
  if [ -n "$non_harness" ]; then echo "→ CI 去重：非 harness-only（含 ${non_harness}），不略過"; fi
  if [ -z "$non_harness" ] && [ -n "$mech_hit" ]; then echo "→ CI 去重：diff 動到 macOS job 機制檔／不可略過檔 ${mech_hit}，不略過"; fi
  urc=0; bash "${here}/ui-test-trigger.sh" --base "$base" >/dev/null 2>&1 || urc=$?
  if [ "$urc" -eq 3 ]; then
    emit full false false false "" "→ CI 去重：未命中（tree ${tree}）——全跑；本 PR 的 UITests／Release／iPad 依 ui-test-trigger 略過，非完整集合，不登記快取"
  fi
fi

emit full false false true "" "→ CI 去重：未命中（tree ${tree}）——全跑，全綠後登記 ci-tree-${tree}"
