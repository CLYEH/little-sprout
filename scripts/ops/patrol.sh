#!/bin/bash
# 巡檢（LS-71）：列出「無依賴卻沒人動」的 PR／分支／worktree＋Supabase lock 持有者（LS-70）＋三分支祖先鏈漂移（LS-85）＋gate hooks 是否
# 裝好（LS-87），只讀不寫（唯一的寫入是 git fetch origin）。
# 給 orchestrator 的巡檢 cron（每 26 分鐘，prompt 模板見 docs/COLLABORATION.md §4-b）與 SessionStart hook
# （scripts/ops/session-start.sh）用。Linear 那一半（Ready 無人接／In Progress 無 worktree／QA 但 test 未含）
# 要 orchestrator 用 MCP list_issues 對照，這裡只印提醒。自測：scripts/ops/patrol.test.sh（合成 repo，掛 CI rules job）。
#
# 用法：patrol.sh [stale_minutes] [--brief|--json] [--no-fetch] [--no-pr] [--repo <path>] [--linear]
#   stale_minutes  幾分鐘沒動算停滯（預設 45）
#   --brief        只印表頭＋異常行（hook 注入 context 用）；全正常時末行「巡檢：無異常」
#   --json         單一 JSON 物件（欄位見檔尾 json 分支），不依賴 jq
#   --no-fetch     不先 git fetch origin（預設會 fetch，看門狗 PATROL_FETCH_TIMEOUT 秒、預設 10；逾時或失敗只警告，
#                  退回本機 origin/* 續跑——hook timeout 30s 不能被黑洞位址的 TCP 逾時（實測 75s）撐爆）
#   --no-pr        略過 gh pr list（自測用；gh 未裝或失敗時本來就會自動略過並標示原因，不會炸）
#   --repo <path>  指定 repo（任一 worktree 路徑皆可；預設取腳本所在 repo）；主 checkout 由 git-common-dir 推得
#   --linear       human／brief 模式末段串接 scripts/ops/patrol-linear.sh（狀態對照／cycle 對帳／lane 補位／
#                  開票結構的 Linear 半段機械化，LS-103）；缺 LINEAR_API_KEY 時它自己印「略過」不炸。與 --json
#                  合併未支援（Linear 半段是獨立 JSON 物件，契約不合併）——這裡只印警告，另跑
#                  `patrol-linear.sh --json`。
#
# 停滯判定（§4-b 三型態；stale＝上面的分鐘數）：
#   PR       CONFLICTING／UNSTABLE／BEHIND／CHANGES_REQUESTED 立即標；CLEAN 且 APPROVED 立即標「可併」；
#            其餘 CLEAN／BLOCKED 超過 stale 沒更新標 ⏳（草稿不標）
#   分支     有 commit 但分支從未 push；領先 remote 且最後 commit 超過 stale（push gate 卡？）；
#            落後 remote（別處 push 過）；已 push、無 open PR、最後 commit 超過 stale
#   工作區   有未提交變更（不含 untracked）且最後改動超過 stale；worktree 建好超過 stale 仍 0 commit 無變更（尚未開工）；
#            分支已併入 base（自 merge-base 0 commit、但分支 reflog 有過 commit）而 worktree 未移除（§2：合併完成後移除）
#   ※「最後 commit 幾分鐘前」只在分支自 merge-base 後有 commit 時才有意義——新 worktree 的 HEAD 就是 base
#     commit，拿它的時間會把剛建好的 worktree 誤判成停滯（scratchpad 原型的 bug）。0 commit 時改看 dirty 檔的
#     mtime（date -r <file> +%s，macOS／GNU 皆可）與 worktree 建立時間（<worktree>/.git 檔的 mtime）。
#   主 checkout（main）落後 origin/main 也標：agent 定義與 harness 讀自主 checkout，落後就派工＝用舊規約（§2）。
#   hooks    core.hooksPath 不是 .githooks（或其絕對路徑）、或 .githooks/{commit-msg,pre-commit,pre-push} 任一缺／不可執行即標：
#            hooks 沒裝時本機 commit／push gate 靜默不跑、只剩 CI 攔（LS-87 G5）。worktree 共用同一份 config，主 checkout 驗一次即可。
#   三分支   祖先鏈 test ⊂ development、main ⊂ development（晉升＝promote.sh 的 FF push，LS-85）：test 有 commit 不在 development
#            立即標（test 只能由 development FF 而來，出現＝手動 push／舊式 back-merge）；main 有 commit 不在 development 是 hotfix
#            併入後待 back-merge、屬預期，最早那筆 first-parent（＝最早未 back-merge 的 PR merge）超過 stale 才標；main 不在 test
#            不標（下次 promote 帶到）。
# 時間一律用 epoch：commit 用 git log --format=%ct、PR 用 gh 內建 jq 的 fromdateiso8601，不碰 date -j／date -d。
# exit 0＝巡檢完成（有無異常都 0，異常在輸出）；2＝參數／repo 錯誤。
set -uo pipefail

STALE=45; MODE=human; DO_FETCH=1; DO_PR=1; REPO=; DO_LINEAR=0
while [ $# -gt 0 ]; do
  case "$1" in
    --brief) MODE=brief ;;
    --json) MODE=json ;;
    --no-fetch) DO_FETCH=0 ;;
    --no-pr) DO_PR=0 ;;
    --linear) DO_LINEAR=1 ;;
    --repo)
      [ -n "${2:-}" ] || { echo "✗ patrol：--repo 缺值" >&2; exit 2; }
      REPO=$2; shift ;;
    -h|--help)
      echo "用法：patrol.sh [stale_minutes] [--brief|--json] [--no-fetch] [--no-pr] [--repo <path>] [--linear]（說明見檔頭註解）"; exit 0 ;;
    -*) echo "✗ patrol：未知參數 $1" >&2; exit 2 ;;
    *)
      case "$1" in ''|*[!0-9]*) echo "✗ patrol：stale 分鐘須為整數（得到「$1」）" >&2; exit 2 ;; esac
      STALE=$1 ;;
  esac
  shift
done

[ -n "$REPO" ] || REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ -d "$REPO" ] || { echo "✗ patrol：找不到 repo 目錄 ${REPO}" >&2; exit 2; }
common=$(git -C "$REPO" rev-parse --git-common-dir 2>/dev/null) || { echo "✗ patrol：${REPO} 不是 git repo" >&2; exit 2; }
case "$common" in /*) ;; *) common="${REPO}/${common}" ;; esac
ROOT=$(cd "$(dirname "$common")" && pwd)
now=$(date +%s)

# ---- 小工具（bash 3.2；不依賴 jq／date -j／date -d）----
mins_since() { echo $(( (now - $1) / 60 )); }
file_epoch() { date -r "$1" +%s 2>/dev/null || echo "$now"; }   # 檔案 mtime：macOS 與 GNU date 都支援 -r <file>
count() { git -C "$ROOT" rev-list --count "$1" 2>/dev/null || echo "?"; }
json_str() {  # JSON 字串（含引號）
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; s=${s//$'\r'/\\r}
  printf '"%s"' "$s"
}
json_num() { case "$1" in ''|*[!0-9]*) printf 'null' ;; *) printf '%s' "$1" ;; esac; }
FLAGS=; J_FLAGS=
add_flag() { FLAGS="${FLAGS}${1}"$'\n'; J_FLAGS="${J_FLAGS:+${J_FLAGS},}$(json_str "$1")"; }

# ---- fetch（看門狗：逾時／失敗只警告，退回本機 origin/* 續巡；PR #99 R1）----
# macOS 沒有 coreutils timeout：背景跑 git fetch、另一個背景 sleep 到期就 kill 它；被 SIGTERM 的 git 回 143 → 視為逾時。
# 所有背景子程序的 fd 都接 /dev/null——殘留的 sleep／ssh 若還握著本程序的 stdout，呼叫端的 $() 會等到它們結束才收到 EOF。
FETCH_TIMEOUT=${PATROL_FETCH_TIMEOUT:-10}
case "$FETCH_TIMEOUT" in ''|*[!0-9]*) echo "✗ patrol：PATROL_FETCH_TIMEOUT 須為整數秒（得到「${FETCH_TIMEOUT}」）" >&2; exit 2 ;; esac
fetch_with_timeout() {  # exit 0＝成功；124＝逾時；其他＝fetch 本身失敗
  (
    GIT_TERMINAL_PROMPT=0 git -C "$ROOT" fetch -q origin >/dev/null 2>&1 &
    fpid=$!
    ( sleep "$FETCH_TIMEOUT"; kill "$fpid" 2>/dev/null ) >/dev/null 2>&1 &
    wpid=$!
    wait "$fpid"; rc=$?
    kill "$wpid" 2>/dev/null
    [ "$rc" -eq 143 ] && exit 124
    exit "$rc"
  ) 2>/dev/null
}
FETCHED=false; fetch_warn=
if [ "$DO_FETCH" -eq 1 ]; then
  fetch_with_timeout; frc=$?
  if [ "$frc" -eq 0 ]; then FETCHED=true
  elif [ "$frc" -eq 124 ]; then fetch_warn="⚠ fetch 逾時（git fetch origin >${FETCH_TIMEOUT}s 無回應：離線或遠端不可達？），用本機 ref 繼續——以下 origin/* 可能過期"
  else fetch_warn="⚠ git fetch origin 失敗（離線？），用本機 ref 繼續——以下 origin/* 可能過期"; fi
fi

# ---- PR（open）：gh 未裝／失敗一律略過並標示原因，不炸 ----
PR_CHECKED=0; pr_skip=; pr_total=0; pr_flagged=0; PR_LINES=; J_PRS=; PR_HEADS=; pr_raw=
# gh 的 stderr 另存暫存檔，不併進 TSV（2>&1 會把警告行當成一筆 PR 讀進去；PR #99 R1）
gh_err=$(mktemp "${TMPDIR:-/tmp}/patrol-gh.XXXXXX") || { echo "✗ patrol：mktemp 失敗" >&2; exit 2; }
trap 'rm -f "$gh_err"' EXIT
if [ "$DO_PR" -eq 0 ]; then pr_skip="--no-pr"
elif ! command -v gh >/dev/null 2>&1; then pr_skip="gh 未安裝"
elif pr_raw=$(cd "$ROOT" && gh pr list --state open --limit 50 \
      --json number,title,headRefName,baseRefName,mergeStateStatus,updatedAt,reviewDecision,isDraft \
      -q '.[] | [.number, .mergeStateStatus, (if (.reviewDecision // "") == "" then "-" else .reviewDecision end), (((now - (.updatedAt | fromdateiso8601)) / 60) | floor), .headRefName, .baseRefName, (.isDraft | tostring), .title] | @tsv' 2>"$gh_err"); then
  PR_CHECKED=1
else
  pr_skip="gh 失敗：$(head -1 "$gh_err" 2>/dev/null)"
fi
if [ "$PR_CHECKED" -eq 1 ] && [ -n "$pr_raw" ]; then
  while IFS=$'\t' read -r n st rd age head base draft title; do
    [ -n "$n" ] || continue
    pr_total=$((pr_total + 1))
    PR_HEADS="${PR_HEADS}${head}"$'\t'"${n}"$'\n'
    [ "$draft" = true ] || draft=false
    flag=
    if [ "$draft" = false ]; then
      case "$st" in
        CONFLICTING|DIRTY) flag="⚠ 衝突（git merge origin/${base} 解掉再 push；CONFLICTING 的 PR 不會跑 CI）" ;;
        UNSTABLE) flag="⚠ CI 紅" ;;
        BEHIND) flag="⚠ 落後 base（gh pr update-branch）" ;;
        CLEAN)
          if [ "$rd" = APPROVED ]; then flag="✅ CLEAN 且已 APPROVE → 可併"
          elif [ "$age" -ge "$STALE" ]; then flag="⏳ CLEAN 但 ${age}m 無動作（待審／待併？）"; fi ;;
        *) if [ "$age" -ge "$STALE" ]; then flag="⏳ ${st} ${age}m 無動作（CI 沒回報？）"; fi ;;
      esac
      if [ "$rd" = CHANGES_REQUESTED ]; then flag="${flag:+${flag}；}⚠ CHANGES_REQUESTED"; fi
    fi
    if [ -n "$flag" ]; then pr_flagged=$((pr_flagged + 1)); add_flag "[PR #${n} ${head}] ${flag}"; fi
    PR_LINES="${PR_LINES}$(printf '  #%-4s %-12s %-18s %5sm  %s → %s  %s%s' "$n" "$st" "$rd" "$age" "$head" "$base" "$([ "$draft" = true ] && echo '草稿 ')" "${flag:-ok}")"$'\n'
    J_PRS="${J_PRS:+${J_PRS},}{\"number\":$(json_num "$n"),\"merge_state\":$(json_str "$st"),\"review\":$(json_str "$rd"),\"age_minutes\":$(json_num "$age"),\"head\":$(json_str "$head"),\"base\":$(json_str "$base"),\"draft\":${draft},\"title\":$(json_str "$title"),\"flag\":$(json_str "$flag")}"
  done <<EOF
$pr_raw
EOF
fi
pr_of_branch() { printf '%s' "$PR_HEADS" | awk -F'\t' -v b="$1" '$1 == b { print $2; exit }'; }

# ---- 三分支（祖先鏈 test ⊂ development、main ⊂ development；晉升＝promote.sh FF push，LS-85）----
dev_main=$(count origin/development..origin/main)    # main 有、development 沒有：hotfix 併入後待 back-merge（超過 stale 才標）
test_main=$(count origin/test..origin/main)          # main 有、test 沒有：下次 promote 帶到，不標
test_dev=$(count origin/test..origin/development)    # development 有、test 沒有：待晉升
dev_test=$(count origin/development..origin/test)    # test 有、development 沒有：不該發生（test 只能由 development FF 而來）
drift_flag=; main_ahead_m=
if [ "$dev_test" != "?" ] && [ "$dev_test" -gt 0 ]; then
  drift_flag="⚠ 分支漂移：test 有 ${dev_test} commit 不在 development（test 只能由 promote.sh 自 development FF 而來——手動 push／舊式 back-merge？→ 以 hotfix/LS-<n>-backmerge-development 把 origin/test 併回 development，§2）"
fi
if [ "$dev_main" != "?" ] && [ "$dev_main" -gt 0 ]; then
  # 最早那筆 first-parent（＝最早併入 main 而未 back-merge 的 PR merge）的 commit 時間；hotfix 分支自己的 commit 更早，不拿
  oldest=$(git -C "$ROOT" log --first-parent --format=%ct origin/development..origin/main 2>/dev/null | awk 'NR == 1 || $1 < m { m = $1 } END { if (NR) print m }')
  [ -n "$oldest" ] && main_ahead_m=$(mins_since "$oldest")
  if [ "${main_ahead_m:-0}" -ge "$STALE" ]; then
    drift_flag="${drift_flag:+${drift_flag}；}⚠ 分支漂移：main 有 ${dev_main} commit 不在 development 已 ${main_ahead_m}m 未 back-merge（hotfix 併入後 → gh pr create --head main --base development，§2）"
  fi
fi
[ -n "$drift_flag" ] && add_flag "[三分支] ${drift_flag}"

# ---- 主 checkout（agent 定義與 harness 讀自這裡）----
mc_branch=$(git -C "$ROOT" symbolic-ref --short -q HEAD 2>/dev/null || echo DETACHED)
mc_behind=$(count HEAD..origin/main)
mc_dirty=$(git -C "$ROOT" diff --name-only HEAD 2>/dev/null | wc -l | tr -d ' ')
mc_flag=
if [ "$mc_branch" != main ]; then
  mc_flag="⚠ 主 checkout 不在 main（${mc_branch}）——派工前切回 main 並 pull"
elif [ "$mc_behind" != "?" ] && [ "$mc_behind" -gt 0 ]; then
  mc_flag="⚠ 主 checkout 落後 origin/main ${mc_behind} commit → 先 git pull --ff-only origin main 再派工（agent 定義讀自主 checkout）"
fi
if [ "$mc_dirty" -gt 0 ]; then mc_flag="${mc_flag:+${mc_flag}；}⚠ 主 checkout 有 ${mc_dirty} 個未提交變更（harness 改動也該在 hotfix worktree）"; fi
[ -n "$mc_flag" ] && add_flag "[主 checkout] ${mc_flag}"

# ---- gate hooks（LS-87 G5）：沒裝＝本機 gate 靜默不跑，只剩 CI；config 由所有 worktree 共用，看主 checkout ----
hooks_path=$(git -C "$ROOT" config core.hooksPath 2>/dev/null || true)
hooks_flag=
case "$hooks_path" in
  .githooks|"${ROOT}/.githooks") ;;
  '') hooks_flag="⚠ core.hooksPath 未設定（commit／push gate 不會跑）→ git config core.hooksPath .githooks（§2）" ;;
  *) hooks_flag="⚠ core.hooksPath 是「${hooks_path}」而非 .githooks → git config core.hooksPath .githooks（§2）" ;;
esac
for h in commit-msg pre-commit pre-push; do
  [ -x "${ROOT}/.githooks/${h}" ] || hooks_flag="${hooks_flag:+${hooks_flag}；}⚠ .githooks/${h} 缺或不可執行 → chmod +x .githooks/${h}"
done
[ -n "$hooks_flag" ] && add_flag "[hooks] ${hooks_flag}"

# ---- worktree ----
wt_total=0; wt_flagged=0; WT_LINES=; J_WTS=
process_wt() {
  local w=$1 b=$2 det=$3
  local name l r= ahead=0 behind=0 base mb since=0 had=0 lc lm= dirty=0 dmax=0 dm= wt_ts wm= pr= flag= info= f t commit_txt dirty_txt merged=false
  name=$(basename "$w")
  if [ "$det" -eq 1 ] || [ -z "$b" ]; then
    WT_LINES="${WT_LINES}  $(printf '%-14s' "$name") detached，略過"$'\n'; return
  fi
  case "$b" in main|development|test) return ;; esac
  wt_total=$((wt_total + 1))
  if [ ! -d "$w" ]; then
    flag="⚠ 目錄不存在（git worktree prune）"
    wt_flagged=$((wt_flagged + 1)); add_flag "[worktree ${name} ${b}] ${flag}"
    WT_LINES="${WT_LINES}  $(printf '%-14s %-34s' "$name" "$b") ${flag}"$'\n'
    # 欄位與正常 worktree 同一套（值 null），消費端不必分兩種形狀（PR #99 R1）
    J_WTS="${J_WTS:+${J_WTS},}{\"path\":$(json_str "$w"),\"name\":$(json_str "$name"),\"branch\":$(json_str "$b"),\"missing\":true,\"local\":null,\"remote\":null,\"ahead\":null,\"behind_remote\":null,\"commits_since_base\":null,\"merged_into_base\":null,\"last_commit_minutes\":null,\"dirty\":null,\"dirty_minutes\":null,\"worktree_minutes\":null,\"pr\":null,\"flag\":$(json_str "$flag")}"
    return
  fi
  l=$(git -C "$ROOT" rev-parse --short "$b" 2>/dev/null || echo '?')
  r=$(git -C "$ROOT" rev-parse --short -q --verify "refs/remotes/origin/${b}" 2>/dev/null || true)
  if [ -n "$r" ]; then ahead=$(count "origin/${b}..${b}"); behind=$(count "${b}..origin/${b}"); fi
  case "$b" in hotfix/*) base=origin/main ;; *) base=origin/development ;; esac
  git -C "$ROOT" rev-parse -q --verify "$base" >/dev/null 2>&1 || base=origin/main
  mb=$(git -C "$ROOT" merge-base "$base" "$b" 2>/dev/null || true)
  [ -n "$mb" ] && since=$(count "${mb}..${b}")
  # 分支 reflog 除了「branch: Created」／「checkout:」之外還有別的（commit／merge／rebase／reset…）＝這條分支動過；
  # 動過但自 merge-base 0 commit ＝ 已併入 base（worktree 該移除），沒動過才是「尚未開工」
  had=$(git -C "$ROOT" reflog show --format=%gs "refs/heads/${b}" 2>/dev/null | grep -vcE '^(branch: Created|checkout: )' || true)
  if [ "$since" = 0 ] && [ "${had:-0}" -gt 0 ]; then merged=true; fi
  if [ "$since" != "?" ] && [ "$since" -gt 0 ]; then
    lc=$(git -C "$ROOT" log -1 --format=%ct "$b"); lm=$(mins_since "$lc")
  fi
  while IFS= read -r -d '' f; do
    dirty=$((dirty + 1))
    if [ -e "${w}/${f}" ]; then t=$(file_epoch "${w}/${f}"); [ "$t" -gt "$dmax" ] && dmax=$t; fi
  done < <(git -C "$w" diff -z --name-only HEAD 2>/dev/null)
  [ "$dmax" -gt 0 ] && dm=$(mins_since "$dmax")
  wt_ts=$(file_epoch "${w}/.git"); wm=$(mins_since "$wt_ts")
  [ "$PR_CHECKED" -eq 1 ] && pr=$(pr_of_branch "$b")

  # 判定（§4-b 分支／工作區停滯）
  if [ -z "$r" ] && [ "$since" != "?" ] && [ "$since" -gt 0 ]; then
    flag="⚠ 分支未 push（${since} commit 只在本機）"
  elif [ -n "$r" ] && [ "$ahead" != "?" ] && [ "$ahead" -gt 0 ]; then
    if [ "${lm:-0}" -ge "$STALE" ]; then flag="⚠ 領先 remote ${ahead} commit 已 ${lm}m 未 push（push gate 卡？）"
    else info="領先 remote ${ahead}（${lm:-0}m 前，可能還在跑 push gate）"; fi
  fi
  if [ -n "$r" ] && [ "$behind" != "?" ] && [ "$behind" -gt 0 ]; then flag="${flag:+${flag}；}⚠ 落後 remote ${behind} commit（remote 有本機沒有的 commit）"; fi
  if [ "$dirty" -gt 0 ] && [ "${dm:-0}" -ge "$STALE" ]; then flag="${flag:+${flag}；}⏳ ${dirty} 個未提交變更、最後改動 ${dm}m 前（停滯？）"; fi
  if [ "$since" = 0 ] && [ "$dirty" -eq 0 ]; then
    if [ "$merged" = true ]; then flag="${flag:+${flag}；}⚠ 分支已併入 base、worktree 未移除（git worktree remove）"
    elif [ "$wm" -ge "$STALE" ]; then flag="${flag:+${flag}；}⏳ 建好 ${wm}m 仍 0 commit、無變更（尚未開工？）"; fi
  fi
  if [ "$PR_CHECKED" -eq 1 ] && [ -z "$pr" ] && [ -n "$r" ] && [ "$ahead" = 0 ] && [ "$since" != "?" ] && [ "$since" -gt 0 ] && [ "${lm:-0}" -ge "$STALE" ]; then
    flag="${flag:+${flag}；}⏳ 已 push、無 open PR、最後 commit ${lm}m 前（該開 PR 了？）"
  fi

  if [ "$since" != "?" ] && [ "$since" -gt 0 ]; then commit_txt="commit ${since}（最後 ${lm}m 前）"
  elif [ "$merged" = true ]; then commit_txt="已併入 base（建好 ${wm}m）"
  else commit_txt="尚無 commit（建好 ${wm}m）"; fi
  if [ "$dirty" -gt 0 ]; then dirty_txt="dirty=${dirty}（${dm:-0}m 前）"; else dirty_txt="dirty=0"; fi
  if [ -n "$flag" ]; then wt_flagged=$((wt_flagged + 1)); add_flag "[worktree ${name} ${b}] ${flag}"; fi
  WT_LINES="${WT_LINES}$(printf '  %-14s %-34s local=%s remote=%s ahead=%s %s %s%s  %s' "$name" "$b" "$l" "${r:-none}" "$ahead" "$commit_txt" "$dirty_txt" "${pr:+ PR#${pr}}" "${flag:-${info:-ok}}")"$'\n'
  J_WTS="${J_WTS:+${J_WTS},}{\"path\":$(json_str "$w"),\"name\":$(json_str "$name"),\"branch\":$(json_str "$b"),\"missing\":false,\"local\":$(json_str "$l"),\"remote\":$([ -n "$r" ] && json_str "$r" || printf null),\"ahead\":$(json_num "$ahead"),\"behind_remote\":$(json_num "$behind"),\"commits_since_base\":$(json_num "$since"),\"merged_into_base\":${merged},\"last_commit_minutes\":$(json_num "$lm"),\"dirty\":${dirty},\"dirty_minutes\":$(json_num "$dm"),\"worktree_minutes\":$(json_num "$wm"),\"pr\":$(json_num "$pr"),\"flag\":$(json_str "$flag")}"
}
# git worktree list --porcelain：主 checkout 保證列在第一筆；每筆 worktree／HEAD／branch|detached，空行分隔
cur_path=; cur_branch=; cur_det=0; first=1
flush_wt() {
  [ -n "$cur_path" ] || return 0
  if [ "$first" -eq 1 ]; then first=0; else process_wt "$cur_path" "$cur_branch" "$cur_det"; fi
  cur_path=; cur_branch=; cur_det=0
}
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    "worktree "*) flush_wt; cur_path=${line#worktree } ;;
    "branch refs/heads/"*) cur_branch=${line#branch refs/heads/} ;;
    detached) cur_det=1 ;;
  esac
done < <(git -C "$ROOT" worktree list --porcelain 2>/dev/null)
flush_wt

# ---- Supabase lock（LS-70：本機容器序列化，持有者由 scripts/ops/supabase-lock.sh --status 讀 holder 檔）----
# 用腳本所在目錄的 supabase-lock.sh（與 patrol.sh 同一份 harness），不從 --repo 找：lock 路徑由它自己依 config.toml 推。
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ -f "$here/supabase-lock.sh" ]; then
  lock_line=$(bash "$here/supabase-lock.sh" --status 2>&1) || lock_line="（狀態讀取失敗：${lock_line}）"
else
  lock_line="（無 ${here}/supabase-lock.sh）"
fi

# ---- 專屬模擬器（LS-83）：detect-simulator.sh 建的 <票號>-<機型無空白> 用完不刪，>7 天未用只列不刪＋印
#      simctl delete 指令，交人判斷是否真的沒人在用；不在這裡自動砍（機型與 UDID 對不對得上人工判斷更保險）。
#      無 xcrun（非 macOS、或這次 simctl 查詢本身失敗）就整段跳過，不當成異常（PR/worktree 段的 fail-soft 同款）。
#      simctl list devices -j 不用 jq 解析（patrol.sh 一貫不依賴 jq，只有測試驗證用它）：純文字 pretty-print
#      每個裝置物件一行一個 key，用 awk 以「單行 {／}」為物件邊界的簡易狀態機取四個欄位。
SIM_LINES=; J_SIM=; sim_flagged=0
BOOT_LINES=; J_BOOT=; boot_total=0; boot_flagged=0; boot_nonexempt=
# LS-100：可注入 SIMCTL_LIST_JSON 直接餵合成 JSON（patrol.test.sh 用）；未設就照常呼叫真的 xcrun。
sim_raw="${SIMCTL_LIST_JSON:-$(xcrun simctl list devices -j 2>/dev/null)}" || sim_raw=
if [ -n "$sim_raw" ]; then
  sim_rows=$(printf '%s\n' "$sim_raw" | awk '
    { t = $0; sub(/^[ \t]*/, "", t); sub(/[ \t]*$/, "", t) }
    t == "{" { name=""; udid=""; last=""; dpath=""; state=""; next }
    t ~ /^"name"[ \t]*:/        { v=t; sub(/^"name"[ \t]*:[ \t]*"/, "", v); sub(/",?$/, "", v); name=v; next }
    t ~ /^"udid"[ \t]*:/        { v=t; sub(/^"udid"[ \t]*:[ \t]*"/, "", v); sub(/",?$/, "", v); udid=v; next }
    t ~ /^"lastBootedAt"[ \t]*:/{ v=t; sub(/^"lastBootedAt"[ \t]*:[ \t]*"/, "", v); sub(/",?$/, "", v); last=v; next }
    t ~ /^"dataPath"[ \t]*:/    { v=t; sub(/^"dataPath"[ \t]*:[ \t]*"/, "", v); sub(/",?$/, "", v); gsub(/\\\//, "/", v); dpath=v; next }
    t ~ /^"state"[ \t]*:/      { v=t; sub(/^"state"[ \t]*:[ \t]*"/, "", v); sub(/",?$/, "", v); state=v; next }
    t ~ /^}/ {
      # 陣列／物件收尾（"]"、外層 "}"）也可能以裸 "}" 開頭（尾端多個收尾大括號連在一起）——印過就清空，
      # 避免最後一台裝置的紀錄被檔尾那些收尾大括號重複印出。
      if (name != "" && udid != "") {
        # tab 是 bash `read` 永遠視為「IFS 空白」的字元、連續 tab 會被當一個分隔符壓縮、空欄位會被吞掉
        # （即使 IFS 只設成單一 tab 也一樣，LS-100 加 state 這個新尾欄時實測踩到：dpath 缺欄位留空、
        # 後面的 state 就被吞掉、往前遞補到 dpath 的位置）——lastBootedAt／dataPath／state 缺欄位一律
        # 改印 "-" 佔位，不留空欄位。
        printf "%s\t%s\t%s\t%s\t%s\n", name, udid, (last == "" ? "-" : last), (dpath == "" ? "-" : dpath), (state == "" ? "-" : state)
        name=""; udid=""; last=""; dpath=""; state=""
      }
    }
  ')
  # ---- Booted 模擬器（LS-100）：任何時候不該有 >1 台非 demo-* 的模擬器同時 Booted（用完忘記關）；
  #      demo-* 開頭的名稱豁免（demo worktree 的持久機，見 docs/COLLABORATION.md）。共用上面同一份
  #      sim_rows（同一次 xcrun 呼叫），不再多打一次。
  while IFS=$'\t' read -r boot_name boot_udid _boot_last _boot_dpath boot_state; do
    [ -n "$boot_name" ] || continue
    [ "$boot_state" = Booted ] || continue
    boot_total=$((boot_total + 1))
    case "$boot_name" in
      demo-*) boot_exempt=true ;;
      *) boot_exempt=false ;;
    esac
    J_BOOT="${J_BOOT:+${J_BOOT},}{\"name\":$(json_str "$boot_name"),\"udid\":$(json_str "$boot_udid"),\"exempt\":${boot_exempt}}"
    if [ "$boot_exempt" = false ]; then
      boot_nonexempt="${boot_nonexempt}${boot_name}"$'\t'"${boot_udid}"$'\n'
    fi
  done <<EOF
$sim_rows
EOF
  while IFS=$'\t' read -r sim_name sim_udid sim_last sim_dpath sim_state; do
    [ -n "$sim_name" ] || continue
    case "$sim_name" in
      LS-[0-9]*-*|main-*) ;;   # 只管 detect-simulator.sh 建的專屬裝置，其餘模擬器不是巡檢管轄範圍
      *) continue ;;
    esac
    sim_epoch=
    if [ -n "$sim_last" ] && [ "$sim_last" != - ]; then
      # lastBootedAt 是 ISO8601 UTC（如 2026-08-25T06:58:38Z）；BSD／GNU date 二選一能解就用，都解不了才退回目錄 mtime。
      # BSD `date -j -f` 的格式字串裡那個 "Z" 只是字面字元、不是時區指示，不加 TZ=UTC 會照本機時區解讀，
      # 時區不是 UTC 的機器算出來的 epoch 會偏掉（LS-83 R2 m5；GNU `date -d` 認得結尾 Z，不受影響）。
      sim_epoch=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$sim_last" +%s 2>/dev/null) \
        || sim_epoch=$(date -d "$sim_last" +%s 2>/dev/null) || sim_epoch=
    fi
    if [ -z "$sim_epoch" ] && [ -n "$sim_dpath" ] && [ "$sim_dpath" != - ]; then
      sim_dir=$(dirname "$sim_dpath")
      [ -e "$sim_dir" ] && sim_epoch=$(file_epoch "$sim_dir")
    fi
    [ -n "$sim_epoch" ] || continue   # 兩種時間都拿不到就不判——沒證據不亂標
    sim_age_days=$(( (now - sim_epoch) / 86400 ))
    if [ "$sim_age_days" -gt 7 ]; then
      sim_flagged=$((sim_flagged + 1))
      J_SIM="${J_SIM:+${J_SIM},}{\"name\":$(json_str "$sim_name"),\"udid\":$(json_str "$sim_udid"),\"age_days\":$(json_num "$sim_age_days")}"
      SIM_LINES="${SIM_LINES}  ⚠ ${sim_name}（${sim_udid}）${sim_age_days} 天未用 → xcrun simctl delete ${sim_udid}"$'\n'
      add_flag "[專屬模擬器 ${sim_name}] ${sim_age_days} 天未用 → xcrun simctl delete ${sim_udid}"
    fi
  done <<EOF
$sim_rows
EOF
fi
# 只在「同時有 >1 台非 demo-* 的 Booted 裝置」才算異常（單台通常是正在用的那台，不該標）；
# 逐台各發一筆 flag（同專屬模擬器段的慣例），--brief／--json 都靠既有的 add_flag／J_FLAGS 機制帶出去。
nonexempt_boot_count=$(printf '%s' "$boot_nonexempt" | awk 'END{print NR+0}')
if [ "$nonexempt_boot_count" -gt 1 ]; then
  while IFS=$'\t' read -r boot_name boot_udid; do
    [ -n "$boot_name" ] || continue
    boot_flagged=$((boot_flagged + 1))
    # PR #164 R1 I1：這台若還握著 push-gate.sh 用的鎖（scripts/ops/simulator-lock.sh，鍵＝UDID）就是
    # 正在跑 xcodebuild test，不是「用完沒關」——標「鎖中」、不建議關，避免巡檢自己造成 F1 那種
    # 「把還在測的機器關掉」的 race（§4-b 巡檢模板同步標「鎖中不關」）。
    if [ -d "/tmp/simulator-lock-${boot_udid}" ]; then
      BOOT_LINES="${BOOT_LINES}  ⚠ ${boot_name}（${boot_udid}）鎖中（push gate 進行中），勿關"$'\n'
      add_flag "[Booted 模擬器 ${boot_name}] 鎖中（push gate 進行中）——勿關，等它跑完自己會關"
    else
      BOOT_LINES="${BOOT_LINES}  ⚠ ${boot_name}（${boot_udid}）→ xcrun simctl shutdown ${boot_udid}"$'\n'
      add_flag "[Booted 模擬器 ${boot_name}] 同時有 ${nonexempt_boot_count} 台非 demo-* 模擬器 Booted、用完沒關 → xcrun simctl shutdown ${boot_udid}"
    fi
  done <<EOF
$boot_nonexempt
EOF
fi

# ---- 輸出 ----
stamp=$(date '+%Y-%m-%d %H:%M')
case "$MODE" in
  json)
    printf '{"generated_at":%s,"stamp":%s,"stale_minutes":%s,"root":%s,"fetched":%s,"fetch_warning":%s,"main_checkout":{"branch":%s,"behind_origin_main":%s,"dirty":%s,"flag":%s},"hooks":{"path":%s,"flag":%s},"branches":{"development_behind_main":%s,"test_behind_main":%s,"test_behind_development":%s,"test_not_in_development":%s,"main_ahead_minutes":%s,"drift":%s},"prs_skipped":%s,"prs":[%s],"worktrees":[%s],"supabase_lock":%s,"stale_simulators":[%s],"booted_simulators":[%s],"booted_flagged":%s,"flags":[%s]}\n' \
      "$now" "$(json_str "$stamp")" "$STALE" "$(json_str "$ROOT")" "$FETCHED" "$([ -n "$fetch_warn" ] && json_str "$fetch_warn" || printf null)" \
      "$(json_str "$mc_branch")" "$(json_num "$mc_behind")" "$mc_dirty" "$(json_str "$mc_flag")" \
      "$(json_str "$hooks_path")" "$(json_str "$hooks_flag")" \
      "$(json_num "$dev_main")" "$(json_num "$test_main")" "$(json_num "$test_dev")" "$(json_num "$dev_test")" "$(json_num "$main_ahead_m")" "$(json_str "$drift_flag")" \
      "$([ -n "$pr_skip" ] && json_str "$pr_skip" || printf null)" "$J_PRS" "$J_WTS" "$(json_str "$lock_line")" "$J_SIM" "$J_BOOT" "$(json_num "$boot_flagged")" "$J_FLAGS"
    ;;
  brief)
    echo "巡檢 ${stamp}（stale ≥${STALE}m）：PR ${pr_total}／異常 ${pr_flagged}${pr_skip:+（略過：${pr_skip}）} · worktree ${wt_total}／異常 ${wt_flagged} · 主 checkout ${mc_branch}（落後 origin/main ${mc_behind}） · dev←main ${dev_main} test←main ${test_main} test←dev ${test_dev} · 專屬模擬器逾期 ${sim_flagged} · Booted 異常 ${boot_flagged}"
    [ -n "$fetch_warn" ] && echo "${fetch_warn}"
    case "$lock_line" in free) ;; *) echo "Supabase lock：${lock_line}" ;; esac
    if [ -n "$FLAGS" ]; then printf '%s' "$FLAGS"; else echo "巡檢：無異常（git／PR 面；Linear 對照仍需 list_issues）"; fi
    ;;
  *)
    echo "== 巡檢 ${stamp}（stale ≥${STALE}m；root ${ROOT}）"
    [ -n "$fetch_warn" ] && echo "  ${fetch_warn}"
    echo "== PR（open）"
    if [ -n "$pr_skip" ]; then echo "  PR：略過（${pr_skip}）"; elif [ "$pr_total" -eq 0 ]; then echo "  （無 open PR）"; else printf '%s' "$PR_LINES"; fi
    echo "== 三分支（祖先鏈 test ⊂ development、main ⊂ development；晉升 promote.sh＝FF push，LS-85）"
    echo "  dev 落後 main: ${dev_main}  test 落後 main: ${test_main}  test 落後 dev: ${test_dev}  test 不在 dev: ${dev_test}"
    if [ -n "$drift_flag" ]; then echo "  ${drift_flag}"
    elif [ "$dev_main" != "?" ] && [ "$dev_main" -gt 0 ]; then echo "  main 領先 development ${dev_main}（最早 ${main_ahead_m:-?}m 前；hotfix 併入後待 back-merge，≥${STALE}m 才標）"
    else echo "  祖先鏈 ok"; fi
    echo "== 主 checkout"
    echo "  ${mc_branch} 落後 origin/main ${mc_behind} dirty=${mc_dirty}  ${mc_flag:-ok}"
    echo "== gate hooks（core.hooksPath＝.githooks 且三支 hook 可執行；沒裝＝本機 gate 靜默不跑，LS-87）"
    echo "  hooksPath=${hooks_path:-（未設定）}  ${hooks_flag:-ok}"
    echo "== worktree（local vs remote／未 push／dirty 停滯；base＝hotfix→origin/main、其餘→origin/development）"
    if [ -n "$WT_LINES" ]; then printf '%s' "$WT_LINES"; else echo "  （無）"; fi
    echo "== Supabase lock（本機容器序列化，scripts/ops/supabase-lock.sh；LS-70；⚠ tomb＝上次回收異常的殘留）"
    printf '%s\n' "$lock_line" | sed 's/^/  /'
    echo "== 專屬模擬器（scripts/gates/detect-simulator.sh 建的 <票號>-<機型>；LS-83；>7 天未用只列不刪）"
    if [ -n "$SIM_LINES" ]; then printf '%s' "$SIM_LINES"; else echo "  （無 xcrun 或無 >7 天未用的專屬模擬器）"; fi
    echo "== Booted 模擬器（LS-100；demo-* 豁免；>1 台非豁免同時 Booted＝用完沒關）"
    if [ -n "$BOOT_LINES" ]; then printf '%s' "$BOOT_LINES"; else echo "  （無異常；Booted ${boot_total} 台，非 demo-* ${nonexempt_boot_count} 台）"; fi
    echo "== Linear（需 orchestrator 用 MCP 對照：Ready 無人接／In Progress 無 worktree／QA 但 test 未含）"
    echo "  → list_issues state in (Ready, In Progress, In Review, QA)，對照上表 worktree／PR"
    ;;
esac

# ---- --linear（LS-103）：human／brief 模式串接 patrol-linear.sh 的動作清單；--json 不合併（見檔頭） ----
if [ "$DO_LINEAR" -eq 1 ]; then
  if [ "$MODE" = json ]; then
    echo "⚠ patrol：--linear 與 --json 不支援合併（Linear 半段是獨立 JSON 物件）→ 另跑 bash scripts/ops/patrol-linear.sh --json" >&2
  elif [ -x "${here}/patrol-linear.sh" ]; then
    echo
    if [ "$MODE" = brief ]; then
      bash "${here}/patrol-linear.sh" --brief --repo "$ROOT"
    else
      bash "${here}/patrol-linear.sh" --repo "$ROOT"
    fi
  else
    echo "⚠ patrol：--linear 但找不到 ${here}/patrol-linear.sh" >&2
  fi
fi
exit 0
