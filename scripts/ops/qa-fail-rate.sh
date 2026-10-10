#!/bin/bash
# QA FAIL 率報表（LS-421 R2 I2／M1）：量 test 分支各 commit 上 `qa` commit status 的 FAILURE 占比，
# 供 Haiku 試點（非 UI 票的 QA 覆寫 haiku，COLLABORATION §1）對 sonnet 基準比較。印一行可貼票 comment 的表列。
#
# 用法：qa-fail-rate.sh [--since <days>] [--non-ui] [--ref <ref>] [--repo <path>] [--slug <owner/name>]
#                       [--statuses-file <tsv>]
#   --since   回看天數（預設 14＝兩個 cycle）。
#   --non-ui  只算非 UI commit（判定見下）；不帶＝全部。
#   --ref     統計的分支（預設 origin/test）。
#   --repo    repo 路徑（預設當前 git repo）。
#   --slug    GitHub owner/name（預設 `gh repo view`）。
#   --statuses-file  自測夾具：每行 `<sha>\t<state>`，給了就不呼叫 gh（自測 qa-fail-rate.test.sh 用）。
#
# 資料來源：`gh api graphql` 取 --ref 近 N 天 history 每個 commit 的 status.contexts，篩 context=qa
# （同一 commit 同一 context 只有最後一次狀態；SUCCESS／FAILURE 之外的 PENDING／ERROR 不計入分母並另列）。
#
# 「非 UI」的判定（git-only，不查 Linear 標籤——lane 標籤要 API key 且一個 test tip 常是多票批次，拆不出來）：
#   某 qa-status commit C 相對「前一個 qa-status commit」（第一個用 C 的第一親代）的 `git diff --name-only`
#   若動到 `LittleSprout/`（app 程式碼）、`LittleSproutUITests/` 或 `design/`（稿）任一路徑＝UI；否則＝非 UI
#   （純 Supabase／harness／docs／scripts）。判定的是「這個 QA 驗收區間有沒有動到畫面」，與 qa.md「非 UI 票＝
#   無模擬器視覺驗收」同義；一個區間內混了 UI 與非 UI 票時整段算 UI（保守，不會把 UI 驗收算進 haiku 樣本）。
#
# 讀法（M1）：FAIL 率只在「QA 嚴格度不變」時有意義。Haiku 的主要失效模式是沒跑驗證就報 PASS，那會讓 FAIL 率
# **下降**——所以 FAIL 率明顯低於基準也要當警訊（抽驗），不只是高於 1.5× 才處理；真正的退場指標是 orchestrator 的
# 「haiku 抽驗：符／不符」記錄（haiku-dispatch skill「試點退場條件」）。
#
# exit：0＝已印摘要；2＝參數錯誤／不是 git repo／ref 不存在／gh 取數失敗（fail closed）。
# 自測：scripts/ops/qa-fail-rate.test.sh（合成 repo 夾具＋mutation）。
set -uo pipefail

DAYS=14; NONUI=0; REF=origin/test; REPO=; SLUG=; SFILE=
while [ $# -gt 0 ]; do
  case "$1" in
    --since)
      case "${2:-}" in ''|*[!0-9]*) echo "✗ qa-fail-rate：--since 須為正整數（得到「${2:-}」）" >&2; exit 2 ;; esac
      DAYS=$2; shift ;;
    --non-ui) NONUI=1 ;;
    --ref) [ -n "${2:-}" ] || { echo "✗ qa-fail-rate：--ref 缺值" >&2; exit 2; }; REF=$2; shift ;;
    --repo) [ -n "${2:-}" ] || { echo "✗ qa-fail-rate：--repo 缺值" >&2; exit 2; }; REPO=$2; shift ;;
    --slug) [ -n "${2:-}" ] || { echo "✗ qa-fail-rate：--slug 缺值" >&2; exit 2; }; SLUG=$2; shift ;;
    --statuses-file) [ -r "${2:-}" ] || { echo "✗ qa-fail-rate：--statuses-file 讀不到「${2:-}」" >&2; exit 2; }; SFILE=$2; shift ;;
    -h|--help) echo "用法：qa-fail-rate.sh [--since <days>] [--non-ui] [--ref <ref>] [--repo <path>] [--slug <owner/name>]（說明見檔頭註解）"; exit 0 ;;
    *) echo "✗ qa-fail-rate：未知參數 $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$REPO" ]; then
  REPO=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "✗ qa-fail-rate：不在 git repo 內且未給 --repo" >&2; exit 2; }
fi
git -C "$REPO" rev-parse --verify -q "${REF}^{commit}" >/dev/null 2>&1 || { echo "✗ qa-fail-rate：${REPO} 找不到 ref「${REF}」" >&2; exit 2; }

work=$(mktemp -d) || exit 2
trap 'rm -rf "$work"' EXIT
tsv="$work/statuses.tsv"

if [ -n "$SFILE" ]; then
  cp "$SFILE" "$tsv"
else
  if [ -z "$SLUG" ]; then
    SLUG=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || { echo "✗ qa-fail-rate：gh repo view 失敗（給 --slug <owner/name>）" >&2; exit 2; }
  fi
  owner=${SLUG%%/*}; name=${SLUG#*/}
  branch=${REF#origin/}
  since=$(date -u -v-"${DAYS}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "${DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ) || { echo "✗ qa-fail-rate：算不出 since" >&2; exit 2; }
  : > "$tsv"; cursor=""
  for _ in 1 2 3 4 5 6 7 8; do  # 每頁 100 commit，最多 800（兩個 cycle 約 430）
    after=""; [ -n "$cursor" ] && after=", after: \"$cursor\""
    q="query { repository(owner:\"$owner\", name:\"$name\") { ref(qualifiedName:\"refs/heads/$branch\") { target { ... on Commit { history(first:100, since:\"$since\"$after) { pageInfo{hasNextPage endCursor} nodes{ oid status{ contexts{context state} } } } } } } } }"
    r=$(gh api graphql -f query="$q") || { echo "✗ qa-fail-rate：gh api graphql 失敗" >&2; exit 2; }
    printf '%s' "$r" | jq -r '.data.repository.ref.target.history.nodes[] | .oid as $o | (.status.contexts // [])[] | select(.context == "qa") | [$o, .state] | @tsv' >> "$tsv" \
      || { echo "✗ qa-fail-rate：解析 graphql 回應失敗" >&2; exit 2; }
    [ "$(printf '%s' "$r" | jq -r '.data.repository.ref.target.history.pageInfo.hasNextPage')" = true ] || break
    cursor=$(printf '%s' "$r" | jq -r '.data.repository.ref.target.history.pageInfo.endCursor')
  done
fi

# 依 git 歷史順序（第一親代鏈、舊→新）排出有 qa status 的 commit，逐個判 UI／非 UI
ordered="$work/ordered.txt"
git -C "$REPO" rev-list --first-parent --reverse "$REF" | LC_ALL=C awk -F'\t' 'NR == FNR { st[$1] = $2; next } ($1 in st) { print $1 "\t" st[$1] }' "$tsv" - > "$ordered"

succ=0; fail=0; other=0; prev=
while IFS=$'\t' read -r sha state; do
  [ -n "$sha" ] || continue
  base=${prev:-${sha}^}
  prev=$sha
  if [ "$NONUI" -eq 1 ]; then
    if git -C "$REPO" diff --name-only "$base" "$sha" 2>/dev/null | LC_ALL=C grep -qE '^(LittleSprout/|LittleSproutUITests/|design/)'; then
      continue
    fi
  fi
  case "$state" in
    SUCCESS) succ=$((succ + 1)) ;;
    FAILURE) fail=$((fail + 1)) ;;
    *) other=$((other + 1)) ;;
  esac
done < "$ordered"

total=$((succ + fail))
if [ "$total" -eq 0 ]; then pct="—"; else pct=$(awk -v f="$fail" -v t="$total" 'BEGIN { printf "%.1f%%", f * 100 / t }'); fi
scope="全部"; [ "$NONUI" -eq 1 ] && scope="非 UI"
printf 'qa-fail-rate（近 %d 天，%s，%s）：FAIL %d／%d＝%s｜SUCCESS %d｜其他狀態 %d\n' "$DAYS" "$REF" "$scope" "$fail" "$total" "$pct" "$succ" "$other"
