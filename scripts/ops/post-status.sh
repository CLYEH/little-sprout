#!/bin/bash
# 裁決貼 commit status（LS-87）：merge-reviewer／qa 的裁決除了寫 Linear comment，必須以 GitHub commit status 綁到被審的 SHA——
# 分支保護把 `merge-review` 列為 required check（scripts/ops/protection-apply.sh），promote.sh 對 `merge-review`／`qa` 查同一 SHA
# 的 status；沒貼＝PR 併不進去、晉升推不上去。status 綁 SHA 不隨分支走：head 再 push 就要重審重貼（「審完 head 又改」被機械擋住）。
# 這是 `gh api repos/{owner}/{repo}/statuses/<sha>` 的薄封裝：參數驗證（fail closed）＋POST＋回讀核對。
#
# 用法：post-status.sh <sha> <merge-review|qa> <success|failure|pending> "<description>" [--url <linear comment url>]
#   sha          完整 40 位 SHA（`gh pr view <n> --json headRefOid -q .headRefOid`／`git rev-parse origin/test`）——不收短 SHA，
#                貼錯 SHA 等於沒貼
#   context      merge-review（merge-reviewer：APPROVE→success、REQUEST_CHANGES→failure）
#                qa（qa agent：PASS→success、FAIL→failure、BLOCKED→failure 且 description 以「BLOCKED:」開頭寫缺什麼）
#   description  必填、≤140 字（GitHub 上限）；帶輪次與 Linear comment id（例：`APPROVE R2 · linear:<comment id>`）讓 status 追得回記錄
#   --url        target_url（Linear comment／issue 連結；http(s) 開頭）
# 誰貼：feature／fix／hotfix PR 的 head 由 merge-reviewer 貼；promote／back-merge 的 SHA（PR merge commit，沒人審過那個 SHA 本身）
#   由 orchestrator 依 docs/COLLABORATION.md §2 核對後貼「promote: no content diff（PR #<n> head <sha7>）」；test tip 的 qa 由 qa agent 貼。
# exit 0＝已貼且回讀（state／context）一致；1＝gh 失敗或回讀不符；2＝參數／環境錯誤（不在 git repo、缺 gh）。
# 自測：scripts/ops/post-status.test.sh（stub gh，正負樣本，掛 CI rules job）。規約：docs/COLLABORATION.md §1、§2、§7。
set -uo pipefail

usage() {
  echo "用法：post-status.sh <sha> <merge-review|qa> <success|failure|pending> \"<description>\" [--url <url>]（說明見檔頭）" >&2
  exit 2
}

sha=; ctx=; state=; desc=; url=; n=0
while [ $# -gt 0 ]; do
  case "$1" in
    --url)
      [ -n "${2:-}" ] || { echo "✗ post-status：--url 缺值" >&2; exit 2; }
      url=$2; shift ;;
    -h|--help) usage ;;
    -*) echo "✗ post-status：未知參數 $1" >&2; exit 2 ;;
    *)
      n=$((n + 1))
      case "$n" in
        1) sha=$1 ;; 2) ctx=$1 ;; 3) state=$1 ;; 4) desc=$1 ;;
        *) echo "✗ post-status：參數過多（多給了「$1」）——description 含空白請整段加引號" >&2; exit 2 ;;
      esac ;;
  esac
  shift
done
[ "$n" -eq 4 ] || usage

case "$sha" in
  *[!0-9a-f]*|'') echo "✗ post-status：sha「${sha}」不是小寫 40 位十六進位——用 gh pr view <n> --json headRefOid -q .headRefOid 或 git rev-parse <ref> 取完整 SHA" >&2; exit 2 ;;
esac
[ "${#sha}" -eq 40 ] || { echo "✗ post-status：sha「${sha}」長度 ${#sha}≠40——不收短 SHA（貼錯 SHA 等於沒貼）" >&2; exit 2; }
case "$ctx" in
  merge-review|qa) ;;
  *) echo "✗ post-status：context「${ctx}」只允許 merge-review 或 qa" >&2; exit 2 ;;
esac
case "$state" in
  success|failure|pending) ;;
  *) echo "✗ post-status：state「${state}」只允許 success／failure／pending（APPROVE／PASS→success；REQUEST_CHANGES／FAIL／BLOCKED→failure）" >&2; exit 2 ;;
esac
case "$desc" in
  *[![:space:]]*) ;;
  *) echo "✗ post-status：description 不得為空——寫輪次與 Linear comment id（例：APPROVE R2 · linear:<id>）" >&2; exit 2 ;;
esac
# ${#desc} 在 UTF-8 locale 數字元、C locale 數 bytes（只會更嚴，fail closed）；GitHub 對 description 的上限是 140 字元
[ "${#desc}" -le 140 ] || { echo "✗ post-status：description ${#desc} 字超過 GitHub 上限 140——精簡到輪次＋comment id" >&2; exit 2; }
if [ -n "$url" ]; then
  case "$url" in
    http://*|https://*) ;;
    *) echo "✗ post-status：--url「${url}」須以 http(s):// 開頭" >&2; exit 2 ;;
  esac
fi
command -v gh >/dev/null 2>&1 || { echo "✗ post-status：需要 gh（brew install gh）。" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "✗ post-status：請在 repo 內執行（gh 由 origin 推 {owner}/{repo}）。" >&2; exit 2; }

ep="repos/{owner}/{repo}/statuses/${sha}"
set -- -X POST "$ep" -f "state=${state}" -f "context=${ctx}" -f "description=${desc}"
[ -n "$url" ] && set -- "$@" -f "target_url=${url}"
resp=$(gh api "$@" --jq '[.state, .context, (.id | tostring), (.target_url // "-")] | @tsv') || {
  echo "✗ post-status：POST ${ep} 失敗（未登入？SHA 不在 repo？description >140？）——status 未貼，handoff 要明說、不得當成已貼。" >&2
  exit 1
}
got_state=$(printf '%s' "$resp" | cut -f1); got_ctx=$(printf '%s' "$resp" | cut -f2); got_id=$(printf '%s' "$resp" | cut -f3)
if [ "$got_state" != "$state" ] || [ "$got_ctx" != "$ctx" ]; then
  echo "✗ post-status：回讀不符——送 ${ctx}=${state}，GitHub 回 ${got_ctx}=${got_state}（id ${got_id}）。" >&2
  exit 1
fi
echo "✓ status ${ctx}=${state} 已貼到 ${sha}（id ${got_id}）：${desc}${url:+  ${url}}"
exit 0
