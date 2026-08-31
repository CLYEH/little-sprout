#!/bin/bash
# 已併入 base 的 migration 檔不可變（LS-80）：本分支相對 target 的 merge-base，`supabase/migrations/` 下
# 在 base 已存在的檔案不得 modified／renamed／deleted；新增（A）不管。掛 push-gate（LS-70 的 4b 之後、
# 分級之前）＋CI `rules` job 的 Migration rules step；自測 migration-immutable-check.test.sh。
#
# 來源：2026-08-25 LS-57 R2 直接修改了已併入 main 的 LS-66 migration
# `20260825030000_children_write_path_and_soft_delete.sql`（把錯誤碼 LS040 改成 42501），review 才抓到、
# 改為在本票另開 migration 用 `CREATE OR REPLACE` 覆寫。「migration 是歷史紀錄、已併入不可改」先前只在
# COLLABORATION 與 agent 定義有文字，沒有機械 gate——LS-70 的撞號 gate 只比版本號是否重複，不管內容有沒有被
# 悄悄改掉。migration 是 append-only 帳本：已 apply 到本機或正式站的內容被改，會造成兩邊 schema drift（同一個
# 版本號在不同機器上實際套用過不同的 SQL）。
#
# 用法：migration-immutable-check.sh --base <ref> [--head <rev>] [--pr-body <file>]
#   --base     target 分支 ref（push-gate 依方向矩陣傳 origin/development／origin/main；CI 傳 origin/$BASE）。
#              本腳本自己對 --head 算 merge-base，呼叫端不必先算好；傳已經是 merge-base 的 SHA 也一樣正確
#              （merge-base(mb, head) = mb，冪等）。找不到 → exit 2（先 git fetch origin），不靜默跳過。
#   --head     要驗的 rev，預設 HEAD（CI 的 checkout 是 detached merge ref，用預設值即可）。
#   --pr-body  PR body 檔（CI 用）：commit body 宣告逃生口時，同樣的獨佔一行宣告必須也出現在 PR body，
#              否則 exit 1（逃生口使用必須在 PR 可見，同 branch-ticket-check 的 Bundles 機制）。push-gate
#              不傳這個旗標（本機沒有 PR body 可驗），只印提醒。
#
# 判定：`git diff -M --diff-filter=MRD --name-status <merge-base> <head> -- supabase/migrations/`——
#   M <path>：修改既有檔；D <path>：刪除既有檔；R<pct> <old> <new>：改名，**舊路徑消失就算改動已存在檔**
#   （即使新舊內容完全相同也算——已 apply 到別人資料庫的 migration 不該被改名，supabase CLI 認的是檔名）。
#   `<merge-base>` 端不存在的檔（本分支自己新增、狀態 A）不受影響：--diff-filter=MRD 天然只回報「兩端都存在、
#   算得出對應關係」的路徑，純新增檔在 base 端不存在，只會落在 A、不會被誤判成 M/R/D（本票已用合成 repo
#   驗證：git diff --name-only 對 rename 只印新路徑，所以訊息組裝改用 --name-status 才能同時秀出舊路徑）。
#
# 逃生口（僅限尚未部署到正式站的檔，需人判斷、故要標記——比照 LS-45 DESTRUCTIVE-APPROVED／LS-50 Bundles 的
# 整行錨定寫法）：本分支任一 commit body **獨佔一行** `MIGRATION-REWRITE-APPROVED: LS-<n>`（允許前後空白；
# 同一行不得有其他字，粗體／反引號包起／前綴／尾隨文字皆不算，理由建議寫下一行），且給了 --pr-body 時
# 同樣獨佔一行的宣告必須也出現在 PR body。涵蓋本分支**全部**違規，不逐檔列舉核可對象——核可是否合理（該檔
# 是否真的尚未部署）靠 merge-reviewer 與 orchestrator 人工把關，本 gate 只驗形式。
#
# exit 0＝無違規，或違規已由 commit body（＋給了 --pr-body 時的 PR body）雙重宣告；
# exit 1＝違規未宣告，或宣告了但 PR body 沒有同步；exit 2＝參數／git 錯誤（fail closed）。
set -uo pipefail

base=; head=HEAD; pr_body=
while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      [ -n "${2:-}" ] || { echo "✗ migration-immutable-check：--base 缺值" >&2; exit 2; }
      base=$2; shift 2 ;;
    --head)
      [ -n "${2:-}" ] || { echo "✗ migration-immutable-check：--head 缺值" >&2; exit 2; }
      head=$2; shift 2 ;;
    --pr-body)
      [ -n "${2:-}" ] || { echo "✗ migration-immutable-check：--pr-body 缺值" >&2; exit 2; }
      pr_body=$2; shift 2 ;;
    *) echo "✗ migration-immutable-check：未知參數 $1" >&2; exit 2 ;;
  esac
done
[ -n "$base" ] || { echo "✗ migration-immutable-check：缺 --base <ref>" >&2; exit 2; }

top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "✗ migration-immutable-check：不在 git repo 內" >&2; exit 2; }
cd "$top" || exit 2

git rev-parse -q --verify "${head}^{commit}" >/dev/null || { echo "✗ migration-immutable-check：找不到 --head ${head}" >&2; exit 2; }
if ! git rev-parse -q --verify "${base}^{commit}" >/dev/null; then
  echo "✗ migration-immutable-check：找不到 ${base}（先 git fetch origin）。" >&2
  exit 2
fi
if [ -n "$pr_body" ] && [ ! -r "$pr_body" ]; then
  echo "✗ migration-immutable-check：讀不到 --pr-body ${pr_body}。" >&2
  exit 2
fi

mb=$(git merge-base "$base" "$head") || { echo "✗ migration-immutable-check：${base} 與 ${head} 沒有共同祖先（merge-base 失敗）。" >&2; exit 2; }

status=$(git -c core.quotePath=false diff -M --diff-filter=MRD --name-status "$mb" "$head" -- supabase/migrations/) \
  || { echo "✗ migration-immutable-check：git diff ${mb}..${head} 失敗" >&2; exit 2; }

if [ -z "$status" ]; then
  echo "✓ migration-immutable-check：無既有 migration 被修改／改名／刪除（對 ${base}）"
  exit 0
fi

TAB=$(printf '\t')
violations=
while IFS="$TAB" read -r code a b; do
  [ -n "$code" ] || continue
  # a／b 已經是 git diff 回報的完整 repo 相對路徑（含 supabase/migrations/ 前綴），不需再補一次
  case "$code" in
    M) violations="${violations}    修改：${a}"$'\n' ;;
    D) violations="${violations}    刪除：${a}"$'\n' ;;
    R*) violations="${violations}    改名：${a} → ${b}"$'\n' ;;
    *) violations="${violations}    ${code}：${a}"$'\n' ;;
  esac
done <<< "$status"

# 逃生口偵測：本分支（mb..head，排除已在保護分支上的 commit——同 branch-ticket-check 的 LS-10 做法，
# 避免把保護分支 merge 回來解衝突誤判成夾帶的宣告來源）任一 commit body 有獨佔一行
# MIGRATION-REWRITE-APPROVED: LS-<n>。
exclude=
for r in origin/main origin/development origin/test; do
  git rev-parse -q --verify "refs/remotes/${r}^{commit}" >/dev/null && exclude="${exclude} ${r}"
done
marker_re='^[[:space:]]*MIGRATION-REWRITE-APPROVED:[[:space:]]*LS-[1-9][0-9]*[[:space:]]*$'
# shellcheck disable=SC2086  # $exclude 是以空白分隔的 ref 名清單，刻意不加引號
declared=$(git log --no-merges --format=%b "${mb}..${head}" --not $exclude 2>/dev/null \
  | grep -E "$marker_re" | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort -u || true)

if [ -z "$declared" ]; then
  echo "✗ migration-immutable-check：以下已併入 ${base} 的 migration 檔被本分支修改／改名／刪除（migration 是 append-only 帳本，已 apply 的內容被改會造成本機與正式站 drift，COLLABORATION §6）：" >&2
  printf '%s' "$violations" >&2
  echo "  正確做法：新增一張新版本號的 migration（date -u +%Y%m%d%H%M%S）去修正／覆寫（例如 CREATE OR REPLACE FUNCTION），不要動已併入的檔。" >&2
  echo "  逃生口（極罕見，僅限尚未部署到正式站的檔，需人判斷）：任一 commit body 獨佔一行 \`MIGRATION-REWRITE-APPROVED: LS-<n>\`（理由建議寫下一行），PR body 同段落宣告。" >&2
  exit 1
fi

echo "→ 偵測到已併入 ${base} 的 migration 被修改／改名／刪除，但本分支以 commit body 宣告逃生口：" >&2
printf '%s' "$violations" >&2
printf '%s\n' "$declared" | sed 's/^/    /' >&2

if [ -n "$pr_body" ]; then
  if ! grep -qE "$marker_re" "$pr_body"; then
    echo "✗ migration-immutable-check：commit body 宣告了 MIGRATION-REWRITE-APPROVED，但 PR body 沒有同樣獨佔一行的宣告——逃生口使用必須在 PR 可見（COLLABORATION §6）。" >&2
    exit 1
  fi
  echo "✓ PR body 已宣告逃生口"
else
  echo "  （push-gate 只驗得到 commit body；PR body 須同段落宣告，CI 會擋）" >&2
fi

exit 0
