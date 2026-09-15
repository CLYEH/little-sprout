#!/usr/bin/env bash
# 併入單支 PR 並貼 status（LS-291，取代只存在 scratchpad 的三支樣板 merge-follow／merge-chain／
# bm-follow——09-15 LS-282／285／289 三次都因為樣板裡的 `wait_clean` 寫死 80×30s＝40 分上限，而 `ci`
# job 實際 38–50 分，逾時後只能再手 sed 一支 `bm-follow.sh` 人工接續一輪；池 `be35b840`(2)）。
#
# 做什麼（依 §2「裁決 status 貼在哪個 SHA」表的手動步驟機械化）：
#   1. 等 PR <pr> 的 `mergeStateStatus`：CLEAN → 進 2；DIRTY → exit 4（衝突，需人工解）；
#      其餘狀態持續等，**無固定上限**（每 30s 印一次進度）；checks 全部跑完（無 pending）後看 bucket：
#      有 `fail` → exit 3（RED，印名單）；有 `cancel` 且沒有 `fail` → 找該 head SHA 的 `pull_request`
#      事件 run，套用與 `promote-follow.sh` `no_failure_steps()` 相同判準（沒有任何 `failure`／
#      `timed_out` 步驟）——是就 `gh run rerun <run> --failed` 一次再等，不是（真的有失敗步驟）就當
#      RED 退出；**只 rerun 一次**，rerun 過後再撞 cancel／fail 一律當 RED 退出（LS-257 判準見該檔）。
#   2. `gh pr merge <pr> --merge`（PR 若已是 MERGED 狀態＝續接重跑，略過本步）。
#   3. `git fetch`，核對 base tip＝這次 merge 的 commit（否則有人先併／base 已前進，status 不貼、
#      exit 6）；`post-status.sh <tip> merge-review success "<desc>" --expect <tip>`——`<desc>` 優先用
#      `--note`；沒給則用 `--rid` 組 `promote: no content diff（#<pr> <第二親 sha7>[ <rid 前 8 碼>]）`
#      （第二親＝這次 merge commit 的第二個 parent，即被併入的 head；R<k> 由呼叫端自行併入 `--note`——
#      本腳本不知道審查輪次，見票 LS-291 討論）；兩者都沒給 → exit 6 並要求補 `--note`。
#   4. `--backmerge`（僅當 PR 的 base＝`main` 時有意義，否則 exit 6）：從 PR 的 head 分支名抽票號
#      （`(feature|fix|hotfix)/LS-<n>-<slug>` 正則，同 `pr-body-check.sh`），內建 body 樣板（Ticket／
#      變更摘要／驗證方式＋署名）開 `main→development` PR（若已有相同 head/base 的 open PR 直接沿用，
#      不重開）；body 先過 `bash scripts/gates/pr-body-check.sh <body> --branch main`——main 不是
#      `(feature|fix|hotfix)/LS-<n>-<slug>` 工作分支，這一步固定 exit 2「非工作分支」，**沿現況不
#      擋**（只記一行供稽核，見 COLLABORATION §2／LS-291 討論；票文明確要求呼叫但不擋）；對這支
#      back-merge PR 重複步驟 1–3（desc 用 `promote: no content diff（back-merge main→development，
#      #<原 pr> <原 head sha7>[ <rid 前 8 碼>]）`，沿 `merge-chain.sample.sh`／`bm-follow.sample.sh`
#      實際跑過的措辭，與 COLLABORATION §2 表格「back-merge:」前綴的書面措辭不同——以兩支已實際執行過
#      的樣板為準）。
#   5. `--then-promote <from> <to>`：最後 `exec bash scripts/ops/promote-follow.sh <from> <to>`（用
#      `exec`：這是本腳本最後一步，直接把 process 換成它，退出碼與輸出都是它的）。
#
# 用法：merge-follow.sh <pr> [--backmerge] [--then-promote <from> <to>] [--rid <comment-id>] [--note "<status note>"]
#   <pr>            PR 號（純數字）。
#   --backmerge     PR 併入後（base 須為 main）額外開／續 back-merge PR main→development 並等它併入。
#   --then-promote  兩支併入都做完後 exec promote-follow.sh <from> <to>。
#   --rid           merge-reviewer 該輪 verdict 的 Linear comment id（用於預設 status description）。
#   --note          直接指定 status description（優先於 --rid 組出的預設值；≤140 字，見 post-status.sh）。
#
# exit：0＝全部完成；2＝參數／環境錯誤（缺 gh／jq、不在 git repo、PR 號不是數字、找不到 PR）；
#       3＝RED（checks 紅，含 rerun 一次仍紅）；4＝DIRTY（衝突）；5＝MERGE_FAILED（`gh pr merge` 失敗，
#       或 PR 已 CLOSED 但未 MERGED）；6＝STATUS_FAILED（base tip 核對不符、post-status 失敗、
#       `--backmerge` 用在 base≠main、開 back-merge PR 失敗、desc 兩個來源都沒給）。
#       非 0 時印「續接：bash scripts/ops/merge-follow.sh <原樣參數>」——已完成的步驟（merge／
#       status／已開的 back-merge PR）重跑時會被偵測到直接跳過或沿用，不會重複動作。
#
# 自測：scripts/ops/merge-follow.test.sh（PATH 前置假 gh／git／sleep，`post-status.sh`／
#       `pr-body-check.sh`／`promote-follow.sh` 三個外部呼叫用環境變數 seam 換成假腳本，同
#       `promote-follow.sh` 的 `PROMOTE_SH` 手法）。規約見 docs/COLLABORATION.md §2、§7。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
orig_args=("$@")

usage() {
  echo "用法：merge-follow.sh <pr> [--backmerge] [--then-promote <from> <to>] [--rid <comment-id>] [--note \"<status note>\"]（說明見檔頭）" >&2
  exit 2
}

pr=; backmerge=0; then_from=; then_to=; rid=; note=
while [ $# -gt 0 ]; do
  case "$1" in
    --backmerge) backmerge=1; shift ;;
    --then-promote)
      [ $# -ge 3 ] || { echo "✗ merge-follow：--then-promote 需要 <from> <to> 兩個值" >&2; exit 2; }
      then_from=$2; then_to=$3; shift 3 ;;
    --rid)
      [ -n "${2:-}" ] || { echo "✗ merge-follow：--rid 缺值" >&2; exit 2; }
      rid=$2; shift 2 ;;
    --note)
      [ -n "${2:-}" ] || { echo "✗ merge-follow：--note 缺值" >&2; exit 2; }
      note=$2; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "✗ merge-follow：未知參數 $1" >&2; exit 2 ;;
    *)
      [ -z "$pr" ] || { echo "✗ merge-follow：只接受一個 PR 號（多給了 $1）" >&2; exit 2; }
      pr=$1; shift ;;
  esac
done
[ -n "${pr:-}" ] || usage
case "$pr" in *[!0-9]*|'') echo "✗ merge-follow：PR 號「$pr」須為正整數" >&2; exit 2 ;; esac

command -v gh >/dev/null 2>&1 || { echo "✗ merge-follow：需要 gh（brew install gh）。" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "✗ merge-follow：需要 jq。" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "✗ merge-follow：目前目錄不在 git repo 內。" >&2; exit 2; }

log() { echo "[$(date +%H:%M:%S)] $*"; }
print_resume_hint() { echo "  續接：bash scripts/ops/merge-follow.sh ${orig_args[*]}" >&2; }

post_status_sh() { bash "${POST_STATUS_SH:-${root}/scripts/ops/post-status.sh}" "$@"; }
pr_body_check_sh() { bash "${PR_BODY_CHECK_SH:-${root}/scripts/gates/pr-body-check.sh}" "$@"; }

# pr_view <pr> → JSON {state,mergeStateStatus,baseRefName,headRefName,headRefOid,mergeCommit}
pr_view() {
  gh pr view "$1" --json state,mergeStateStatus,baseRefName,headRefName,headRefOid,mergeCommit 2>/dev/null
}
# pr_checks <pr> → JSON array [{name,bucket}]（可能為空字串／`[]`）
pr_checks() { gh pr checks "$1" --json name,bucket 2>/dev/null; }
# find_pr_run <headref> <sha> → 印該 head sha 在該分支上最新一筆 pull_request 事件 run id（找不到印空字串）
find_pr_run() {
  local headref=$1 sha=$2
  gh run list --branch "${headref}" --commit "${sha}" --json databaseId,event,createdAt \
    --jq '[.[] | select(.event == "pull_request")] | sort_by(.createdAt) | last | .databaseId // empty' 2>/dev/null
}
run_json() { gh run view "$1" --json status,conclusion,jobs,attempt 2>/dev/null; }
# no_failure_steps <run json> → 0＝沒有任何 failure／timed_out 步驟（LS-257 判準，沿 promote-follow.sh）
no_failure_steps() {
  printf '%s' "$1" | jq -e '[.jobs[].steps[]?.conclusion] | length > 0 and all(. != "failure" and . != "timed_out")' >/dev/null 2>&1
}

# wait_and_merge <pr> → 等 mergeStateStatus=CLEAN（無上限）並 `gh pr merge`；已是 MERGED 狀態則略過。
# 回傳 0＝已併入（含本來就已併入）；非 0＝依上方 exit 分類（3 RED／4 DIRTY／5 MERGE_FAILED）。
wait_and_merge() {
  local prnum=$1 rerun_done=0 pj state ms checks headref headsha run rj
  pj=$(pr_view "$prnum") || true
  [ -n "$pj" ] || { echo "✗ merge-follow：gh pr view #${prnum} 失敗（PR 不存在？未登入？）" >&2; return 2; }
  state=$(printf '%s' "$pj" | jq -r '.state // empty')
  if [ "$state" = MERGED ]; then
    log "#${prnum} 已是 MERGED（續接偵測，略過等待與 merge 步驟）"
    return 0
  fi
  if [ "$state" = CLOSED ]; then
    echo "✗ merge-follow：#${prnum} 已 CLOSED（非 MERGED）——無法自動續接，需人工處理" >&2
    return 5
  fi
  while :; do
    pj=$(pr_view "$prnum") || true
    [ -n "$pj" ] || { echo "✗ merge-follow：gh pr view #${prnum} 失敗" >&2; return 2; }
    ms=$(printf '%s' "$pj" | jq -r '.mergeStateStatus // empty')
    if [ "$ms" = CLEAN ]; then break; fi
    if [ "$ms" = DIRTY ]; then
      echo "✗ merge-follow：#${prnum} DIRTY（衝突），需先解衝突再重跑本腳本" >&2
      return 4
    fi
    checks=$(pr_checks "$prnum")
    if [ -n "$checks" ] && [ "$checks" != "[]" ] && \
       printf '%s' "$checks" | jq -e 'all(.bucket != "pending")' >/dev/null 2>&1; then
      if printf '%s' "$checks" | jq -e '[.[] | select(.bucket=="fail")] | length > 0' >/dev/null 2>&1; then
        echo "✗ merge-follow：#${prnum} checks 紅：$(printf '%s' "$checks" | jq -r '.[] | select(.bucket=="fail") | .name' | sort -u | tr '\n' ' ')" >&2
        return 3
      fi
      if printf '%s' "$checks" | jq -e '[.[] | select(.bucket=="cancel")] | length > 0' >/dev/null 2>&1; then
        if [ "$rerun_done" -eq 0 ]; then
          headref=$(printf '%s' "$pj" | jq -r '.headRefName // empty')
          headsha=$(printf '%s' "$pj" | jq -r '.headRefOid // empty')
          run=""
          [ -n "$headref" ] && [ -n "$headsha" ] && run=$(find_pr_run "$headref" "$headsha")
          if [ -n "$run" ]; then
            rj=$(run_json "$run")
            if [ -n "$rj" ] && no_failure_steps "$rj"; then
              log "#${prnum} cancelled 且無 failure／timed_out 步驟（LS-257 判準的假紅）→ gh run rerun ${run} --failed 一次"
              if gh run rerun "${run}" --failed; then
                rerun_done=1
                sleep 30
                continue
              fi
              echo "✗ merge-follow：gh run rerun ${run} --failed 失敗" >&2
              return 3
            fi
          fi
        fi
        echo "✗ merge-follow：#${prnum} checks cancel（已 rerun 過一次仍未綠，或找不到可判斷的 run／有真的失敗步驟）：$(printf '%s' "$checks" | jq -r '.[] | select(.bucket=="cancel" or .bucket=="fail") | .name' | sort -u | tr '\n' ' ')" >&2
        return 3
      fi
    fi
    log "#${prnum} 等待中（mergeStateStatus=${ms:-?}）"
    sleep 30
  done
  if gh pr merge "${prnum}" --merge; then
    return 0
  fi
  # 併的當下可能被別人搶先併入——重查一次 state，是就當成功（續接語意），不是才真的算失敗。
  pj=$(pr_view "$prnum") || true
  if [ -n "$pj" ] && [ "$(printf '%s' "$pj" | jq -r '.state // empty')" = MERGED ]; then
    log "#${prnum} gh pr merge 回錯但重查 state=MERGED（可能剛好被別的呼叫併走），視為成功"
    return 0
  fi
  echo "✗ merge-follow：gh pr merge #${prnum} 失敗" >&2
  return 5
}

# resolve_merge_tip <base> <pr> → fetch＋核對 origin/<base> tip＝#<pr> 的 mergeCommit，印 tip（stdout）；
# 不符（有人先併／base 已前進）→ 印錯誤、return 6、不貼 status（LS-291 票文明定步驟 3 的前提）
resolve_merge_tip() {
  local base=$1 prnum=$2 tip mc
  git fetch -q origin || { echo "✗ merge-follow：git fetch origin 失敗" >&2; return 6; }
  tip=$(git rev-parse "origin/${base}" 2>/dev/null) || { echo "✗ merge-follow：本機沒有 origin/${base}" >&2; return 6; }
  mc=$(gh pr view "${prnum}" --json mergeCommit -q '.mergeCommit.oid // empty' 2>/dev/null)
  if [ -z "$mc" ] || [ "$tip" != "$mc" ]; then
    echo "✗ merge-follow：${base} tip ${tip:0:7} 不是 #${prnum} 的 merge commit ${mc:0:7}（有人先併／base 已前進），status 不貼" >&2
    return 6
  fi
  printf '%s\n' "${tip}"
}

# post_status_for <tip sha> <desc> → 貼 merge-review success 到 <tip>（--expect 同一顆，見 post-status.sh）
post_status_for() {
  local tip=$1 desc=$2
  if ! post_status_sh "${tip}" merge-review success "${desc}" --expect "${tip}"; then
    echo "✗ merge-follow：post-status 貼 ${tip:0:7} 失敗（見上方原因）" >&2
    return 6
  fi
}

# backmerge_body <ticket> <pr> <head sha7> → 印 back-merge PR body（stdout）
backmerge_body() {
  local ticket=$1 pr=$2 sha7=$3
  cat <<EOF
## Ticket

${ticket} — back-merge \`main\` → \`development\`（hotfix PR #${pr} 併入 main 後的 harness 回併，無新內容）。

## 變更摘要

- 只把 main 上已併入的 ${ticket} commit 帶回 development（hotfix PR #${pr} merge commit，head \`${sha7}\`）；不動其餘檔案。

## 驗證方式

- PR #${pr} 的 merge-review 已 APPROVE，status 貼於 head \`${sha7}\`；CI checks 綠。
- main tip 已貼 \`promote: no content diff\` status；本 PR 併入後 development 與 main 祖先鏈恢復。

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
  [ -n "${MERGE_FOLLOW_SESSION_URL:-}" ] && printf '\n%s\n' "${MERGE_FOLLOW_SESSION_URL}"
}

pj=$(pr_view "$pr") || true
[ -n "$pj" ] || { echo "✗ merge-follow：gh pr view #${pr} 失敗（PR 不存在？未登入？）" >&2; exit 2; }
base=$(printf '%s' "$pj" | jq -r '.baseRefName // empty')
orig_headref=$(printf '%s' "$pj" | jq -r '.headRefName // empty')
orig_head_sha=$(printf '%s' "$pj" | jq -r '.headRefOid // empty')
[ -n "$base" ] && [ -n "$orig_head_sha" ] || { echo "✗ merge-follow：讀不到 #${pr} 的 base／head（PR 不存在？）" >&2; exit 2; }
orig_head_sha7=${orig_head_sha:0:7}

wait_and_merge "$pr"; rc=$?
if [ "$rc" -ne 0 ]; then print_resume_hint; exit "$rc"; fi

tip=$(resolve_merge_tip "$base" "$pr") || { print_resume_hint; exit 6; }

if [ -n "$note" ]; then
  desc=$note
elif [ -n "$rid" ]; then
  # 第二親＝這次 merge commit 的第二個 parent＝被併入的 head（沿 merge-follow.sample.sh 措辭）
  p2sha7=$(git log -1 --format='%P' "$tip" 2>/dev/null | awk '{print $2}' | cut -c1-7)
  desc="promote: no content diff（#${pr} ${p2sha7:-${orig_head_sha7}} ${rid:0:8}）"
else
  echo "✗ merge-follow：沒給 --note 也沒給 --rid，無法組出 status description——補其中一個再重跑（--rid 只組『promote: no content diff（#pr sha7 ridid8）』不含審查輪次 R<k>，要輪次就用 --note 自己寫）" >&2
  print_resume_hint
  exit 6
fi
post_status_for "$tip" "$desc" || { print_resume_hint; exit 6; }
log "✓ merged #${pr} → ${base} ${tip:0:7}；status 已貼：${desc}"

if [ "$backmerge" -eq 1 ]; then
  if [ "$base" != main ]; then
    echo "✗ merge-follow：--backmerge 只在 PR base 為 main 時有意義（#${pr} base=${base}）" >&2
    exit 6
  fi
  ticket=$(printf '%s' "$orig_headref" | sed -nE 's#^(feature|fix|hotfix)/(LS-[1-9][0-9]*)-[a-z0-9][a-z0-9-]*$#\2#p')
  slug=$(printf '%s' "$orig_headref" | sed -nE 's#^(feature|fix|hotfix)/LS-[1-9][0-9]*-([a-z0-9][a-z0-9-]*)$#\2#p')
  if [ -z "$ticket" ]; then
    echo "✗ merge-follow：--backmerge 抽不出票號（head 分支「${orig_headref}」不符 (feature|fix|hotfix)/LS-<n>-<slug>）" >&2
    exit 6
  fi

  bmpr=$(gh pr list --head main --base development --state open --json number -q '.[0].number // empty' 2>/dev/null)
  if [ -n "$bmpr" ]; then
    log "沿用既有 back-merge PR #${bmpr}（head=main base=development 已存在，續接偵測）"
  else
    body="$(mktemp)"
    trap 'rm -f "$body"' EXIT
    backmerge_body "$ticket" "$pr" "$orig_head_sha7" > "$body"
    pr_body_check_sh "$body" --branch main >/dev/null 2>&1
    bcrc=$?
    log "pr-body-check --branch main exit ${bcrc}（main 非 (feature|fix|hotfix)/LS-<n>-<slug> 工作分支，固定 exit 2，沿現況不擋，見檔頭）"
    title="chore(harness): ${ticket} back-merge main→development${slug:+（${slug}）}"
    bmout=$(gh pr create --head main --base development --title "$title" --body-file "$body" 2>&1)
    bmrc=$?
    rm -f "$body"; trap - EXIT
    if [ "$bmrc" -ne 0 ]; then
      echo "✗ merge-follow：開 back-merge PR 失敗：${bmout}" >&2
      print_resume_hint
      exit 6
    fi
    bmpr=$(printf '%s' "$bmout" | grep -oE '[0-9]+$')
    [ -n "$bmpr" ] || { echo "✗ merge-follow：取不到 back-merge PR 號（gh 輸出：${bmout}）" >&2; print_resume_hint; exit 6; }
    log "back-merge PR：${bmout}"
  fi

  wait_and_merge "$bmpr"; rc=$?
  if [ "$rc" -ne 0 ]; then print_resume_hint; exit "$rc"; fi

  bmtip=$(resolve_merge_tip development "$bmpr") || { print_resume_hint; exit 6; }
  if [ -n "$rid" ]; then bmdesc="promote: no content diff（back-merge main→development，#${pr} ${orig_head_sha7} ${rid:0:8}）"
  else bmdesc="promote: no content diff（back-merge main→development，#${pr} ${orig_head_sha7}）"
  fi
  post_status_for "$bmtip" "$bmdesc" || { print_resume_hint; exit 6; }
  log "✓ back-merge #${bmpr} → development ${bmtip:0:7}；status 已貼：${bmdesc}"
fi

if [ -n "$then_from" ]; then
  log "→ exec promote-follow.sh ${then_from} ${then_to}"
  exec bash "${PROMOTE_FOLLOW_SH:-${root}/scripts/ops/promote-follow.sh}" "$then_from" "$then_to"
fi

exit 0
