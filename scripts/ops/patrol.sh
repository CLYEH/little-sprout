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
#   --json         單一 JSON 物件（欄位見檔尾 json 分支；LS-198 加 sim_linear_note＝專屬模擬器段這輪有沒有問 Linear），不依賴 jq
#   --no-fetch     不先 git fetch origin（預設會 fetch，看門狗 PATROL_FETCH_TIMEOUT 秒、預設 10；逾時或失敗只警告，
#                  退回本機 origin/* 續跑——hook timeout 30s 不能被黑洞位址的 TCP 逾時（實測 75s）撐爆）
#   --no-pr        略過 gh pr list（自測用；gh 未裝或失敗時本來就會自動略過並標示原因，不會炸）
#   --repo <path>  指定 repo（任一 worktree 路徑皆可；預設取腳本所在 repo）；主 checkout 由 git-common-dir 推得
#   --linear       human／brief 模式末段串接 scripts/ops/patrol-linear.sh（狀態對照／cycle 對帳／lane 補位／
#                  開票結構的 Linear 半段機械化，LS-103）；缺 LINEAR_API_KEY 時它自己印「略過」不炸。與 --json
#                  合併未支援（Linear 半段是獨立 JSON 物件，契約不合併）——這裡只印警告，另跑
#                  `patrol-linear.sh --json`。LS-187 起專屬模擬器段也靠它（`patrol-linear.sh --closed <n,…>`）查
#                  「worktree 仍在的票是否已 Done／Canceled」——patrol.sh 自己仍不碰 token；缺 key 只用 worktree 判定。
#
# 停滯判定（§4-b 三型態；stale＝上面的分鐘數）：
#   PR       CONFLICTING／UNSTABLE／BEHIND／CHANGES_REQUESTED 立即標；CLEAN 且 APPROVED 立即標「可併」；
#            其餘 CLEAN 超過 stale 標 ⏳；BLOCKED（及其他未列名狀態）超過 stale 改查 check bucket 分三流
#            （LS-233）：pending→CI 跑中／全綠仍卡→缺必要 status／有 fail→check 紅，取代舊版籠統「無
#            動作（CI 沒回報？）」（草稿不標）
#   分支     有 commit 但分支從未 push、最後 commit 超過 PATROL_PUSH_GRACE_MIN（預設 30 分，> push-gate 看門狗 25 分，LS-207 R2）
#            且真的 pgrep 不到該 worktree 下的 push-gate.sh 行程；領先 remote 且最後 commit 超過 stale（push gate 卡？）；
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
# LS-267（LS-239 R3）：orchestrator 巡檢改成自己直接跑本腳本、再用 `grep -E '⚠|✗|→|lane:|current cycle|無異常'`
# 過濾進 context（§4-b cron 模板）——**旗標行沒有任何一個標記就會被整行濾掉、等於沒巡到**。既有旗標裡有好
# 幾支只帶 ⏳（等待型：dirty 停滯、尚未開工、已 push 無 PR）或純敘述（`[Pen] 開錯檔`、`[Linear] 段失敗`、
# runtime 不一致、Booted「鎖中——勿關」），所以這裡統一補：沒有 ⚠／✗／→ 的旗標一律在 `[段]` 之後補一個 ⚠，
# 維持既有 `[段] …` 開頭格式（`--json` 的 flags 與人類段同一份字串，兩邊一致）。自測 patrol.test.sh ㉛a／㉛b。
add_flag() {
  local m=$1
  case "$m" in
    *⚠*|*✗*|*→*) ;;
    "["*"] "*) m="${m%%] *}] ⚠ ${m#*] }" ;;
    *) m="⚠ ${m}" ;;
  esac
  FLAGS="${FLAGS}${m}"$'\n'; J_FLAGS="${J_FLAGS:+${J_FLAGS},}$(json_str "$m")"
}

# ---- fetch（看門狗：逾時／失敗只警告，退回本機 origin/* 續巡；PR #99 R1）----
# macOS 沒有 coreutils timeout：背景跑 git fetch、另一個背景 sleep 到期就 kill 它；被 SIGTERM 的 git 回 143 → 視為逾時。
# 所有背景子程序的 fd 都接 /dev/null——殘留的 sleep／ssh 若還握著本程序的 stdout，呼叫端的 $() 會等到它們結束才收到 EOF。
FETCH_TIMEOUT=${PATROL_FETCH_TIMEOUT:-10}
case "$FETCH_TIMEOUT" in ''|*[!0-9]*) echo "✗ patrol：PATROL_FETCH_TIMEOUT 須為整數秒（得到「${FETCH_TIMEOUT}」）" >&2; exit 2 ;; esac
# LS-176 磁碟水位：可用 <PATROL_DISK_MIN_GB（預設 20）GB 標 ⚠；Devices／DerivedData 體積只在標 ⚠ 時才 du（Devices 64 GB
# 本機實測 du 要 18 秒，不能每輪 cron／每次 SessionStart hook（30s 上限）都付），且掛看門狗 PATROL_DU_TIMEOUT——逾時體積印
# 「?」不炸。預設依模式：--brief（SessionStart hook 用，30s 上限還要扣掉 fetch 看門狗 10s）8 秒；human／--json（cron 與人工，
# 沒有 hook 預算）25 秒——低水位時 Devices 通常正是最肥的那個，cron 這一路要印得出真數字才有處置依據。
DISK_MIN_GB=${PATROL_DISK_MIN_GB:-20}
case "$DISK_MIN_GB" in ''|*[!0-9]*) echo "✗ patrol：PATROL_DISK_MIN_GB 須為整數 GB（得到「${DISK_MIN_GB}」）" >&2; exit 2 ;; esac
# LS-207（a7b0f49e）：本地有 commit、遠端無同名分支——「領先 remote」旗標要求 remote 分支存在（`-n "$r"`），
# 漏抓「從未 push 過」這種連 remote 分支都不存在的情況（LS-191 當晚：長命令背景化沒人回頭看，`git push` 究竟
# 跑了沒、卡了沒都不知道）。給寬限期（比 STALE 短——push 該很快發生，不必等到 45 分鐘的一般停滯門檻）：未超過
# 只印 info（可能還在跑 push gate），超過才標 ⚠。
# LS-207 R2（merge-review R1 fd783f6c F6）：預設從 20 分調到 30 分——push-gate.sh 的 unit tests 看門狗
# （PUSH_GATE_XCODEBUILD_TIMEOUT_MIN，預設 25 分，LS-199）比舊寬限期長，健康但慢的 push 會在第 21～25 分鐘
# 之間被誤標；30 分確保「看門狗還沒判定逾時」的情況下寬限期一定還沒到。另外文案原本宣稱「無 push 行程」但
# 其實從沒偵測過任何行程，判準只是「最後一個 commit 已經過了 N 分鐘」——現在真的用 pgrep 掃 push-gate.sh 行程、
# 再用 lsof 核對其 cwd 是否落在這個 worktree 之下，行程真的在跑就不標（pgrep／lsof 不可用時保守 fail-open：
# 當作沒在跑，退回只看時間，不因為偵測工具缺失而永遠不標）。
PUSH_GRACE_MIN=${PATROL_PUSH_GRACE_MIN:-30}
case "$PUSH_GRACE_MIN" in ''|*[!0-9]*) echo "✗ patrol：PATROL_PUSH_GRACE_MIN 須為整數分鐘（得到「${PUSH_GRACE_MIN}」）" >&2; exit 2 ;; esac
# LS-207 R2（F6）：$1＝worktree 絕對路徑；0＝該 worktree 目前真的有 push-gate.sh 在跑（不誤標）、1＝沒有（或偵測
# 不了）。PATROL_PGREP／PATROL_LSOF 可覆寫供自測餵假身，不碰真的系統行程表。
PGREP_BIN=${PATROL_PGREP:-pgrep}
LSOF_BIN=${PATROL_LSOF:-lsof}
push_gate_running_for() {
  local w=$1 pid cwd
  command -v "$PGREP_BIN" >/dev/null 2>&1 || return 1
  command -v "$LSOF_BIN" >/dev/null 2>&1 || return 1
  for pid in $("$PGREP_BIN" -f 'push-gate\.sh' 2>/dev/null); do
    cwd=$("$LSOF_BIN" -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
    case "$cwd" in "$w"|"$w"/*) return 0 ;; esac
  done
  return 1
}
DU_TIMEOUT=${PATROL_DU_TIMEOUT:-}
if [ -z "$DU_TIMEOUT" ]; then if [ "$MODE" = brief ]; then DU_TIMEOUT=8; else DU_TIMEOUT=25; fi; fi
case "$DU_TIMEOUT" in ''|*[!0-9]*) echo "✗ patrol：PATROL_DU_TIMEOUT 須為整數秒（得到「${DU_TIMEOUT}」）" >&2; exit 2 ;; esac
# LS-187：專屬模擬器段每輪都印 CoreSimulator/Devices 體積，但上面「不能每輪都付 18 秒」的取捨不變——du 結果快取在
# PATROL_DU_CACHE（預設 ${TMPDIR:-/tmp}/patrol-du-devices-<uid>；自測指到自己的 work 目錄），PATROL_DU_CACHE_MIN（預設 360）
# 分鐘內且路徑相同直接沿用；過期才在 human／--json 現量一次並回寫，--brief（hook 預算）不量、只讀快取（沒有印 ?）。
DU_CACHE_MIN=${PATROL_DU_CACHE_MIN:-360}
case "$DU_CACHE_MIN" in ''|*[!0-9]*) echo "✗ patrol：PATROL_DU_CACHE_MIN 須為整數分鐘（得到「${DU_CACHE_MIN}」）" >&2; exit 2 ;; esac
du_cache="${PATROL_DU_CACHE:-${TMPDIR:-/tmp}/patrol-du-devices-$(id -u)}"
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

# ---- LS-233：BLOCKED（含其他未列名 mergeStateStatus）超過 stale 時，查 check bucket 分三流，取代
#      舊版籠統「⏳ <st> <age>m 無動作（CI 沒回報？）」——這句對「CI 其實還在跑」（09-12 #365：age 已
#      超過 stale 只是 PR 沒被互動更新 updatedAt，跟 CI 有沒有在跑無關）與「必要 status 根本沒回報」
#      （09-12 #366：gh pr checks 五項全綠，因為它只列「已有回報」的項目，完全沒回報過的必要 context
#      不會出現在清單裡，mergeStateStatus 卻仍卡 BLOCKED）這兩種假象都誤判成「CI 沒回報」。只在原本
#      就會被標記的（age ≥ stale 的 catch-all 分支）才多查——不對 CLEAN／CONFLICTING／DIRTY／UNSTABLE／
#      BEHIND 查（這幾種已有自己明確的訊息與成因，不是本票兩起事故的根因），成本只落在真的卡住的 PR。
pr_check_flag() {  # $1=PR號 $2=head oid（40 hex） $3=base branch 名（不含 origin/） $4=mergeStateStatus
  local n=$1 oid=$2 base=$3 st=$4
  local sha7=${oid:0:7}
  local rows rc name bucket link started_m rid pend='' pend_count=0 pend_max_m='' fail_names='' fail_ids='' present=$'\n'
  # merge-review R1 m2：pending 的「已跑多久」改用 gh pr checks 的 startedAt（CI 實際開始時間），不是
  # PR 的 updatedAt 年齡——09-12 #365 正是「PR 沒被互動更新、但 CI 剛開跑」的反例，用 updatedAt 會誤導
  # 成「CI 卡了 48 分」。同一次呼叫加 startedAt 欄位（不加呼叫）；只對 pending 的項目算「距今幾分」，取
  # 最早開始（＝elapsed 最大）的那個當代表；沒有任何 pending 項帶得到 startedAt 就印 ?。
  # merge-review R2 delta m4：Go 零值 `0001-01-01T00:00:00Z`（commit status 未曾設過 started_at 時的預設
  # 值，本 repo 真資料如 `gh pr checks 355` 的 merge-review 項）餵給 fromdateiso8601 會直接讓整條 -q
  # 以 rc=1 中止（`// ""` 只擋 null／缺欄位，擋不了這個非空字串）——三分流因此整個退化成「查詢失敗」。
  # 補一個字串前綴守門，視同缺值（印 ?）。
  # merge-review R3 delta m4（i5）：CI（Ubuntu jq）對這個零值不會炸——`fromdateiso8601` 是否對某個值
  # 拋錯是 C 函式庫層級的行為（gmtime 範圍驗證），macOS／BSD 與 glibc 的實作不一致，本機兩個版本
  # （jq 1.6、系統版 jq-1.7.1-apple）都會炸，CI 的 Ubuntu jq 不會——純字串前綴守門本身跟這個平台差異
  # 無關（比對發生在呼叫 fromdateiso8601 之前，永遠一致），**但只涵蓋這一個已知值**；`try … catch`
  # 補的是另一類保護：任何其他真的解析不了的字串（如格式對不上的垃圾值）在「所有」jq 版本上都是
  # strptime 格式比對失敗、不是範圍驗證差異，try/catch 能一致地接住。兩者互補、不是互斥，都留著。
  rows=$(cd "$ROOT" && gh pr checks "$n" --json name,bucket,link,startedAt \
    -q '.[] | [.name, .bucket, .link, (if .bucket == "pending" then ((.startedAt // "") as $s | if $s == "" or ($s | startswith("0001-01-01")) then "" else (try (((now - ($s | fromdateiso8601)) / 60) | floor | tostring) catch "") end) else "" end)] | @tsv' 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '⚠ %s 但 gh pr checks 查詢失敗（exit %s）→ 人工看 PR #%s 頁面' "$st" "$rc" "$n"
    return
  fi
  while IFS=$'\t' read -r name bucket link started_m; do
    [ -n "$name" ] || continue
    present="${present}${name}"$'\n'
    case "$bucket" in
      pending)
        pend="${pend:+${pend}、}${name}"; pend_count=$((pend_count + 1))
        case "$started_m" in
          ''|*[!0-9]*) ;;
          *) if [ -z "$pend_max_m" ] || [ "$started_m" -gt "$pend_max_m" ]; then pend_max_m=$started_m; fi ;;
        esac
        ;;
      fail)
        fail_names="${fail_names:+${fail_names}、}${name}"
        rid=$(printf '%s' "$link" | grep -oE '/runs/[0-9]+' | head -1 | grep -oE '[0-9]+')
        fail_ids="${fail_ids:+${fail_ids}、}${name}${rid:+#${rid}}"
        ;;
    esac
  done <<EOF
$rows
EOF
  # merge-review R1 m1：fail 優先於 pending（原本 pending 存在就提早 return，fail 被整個吞掉——
  # 09-12 #355 那種「必要 job 已經紅、另一個 job 還在跑」的形狀會被誤報成「CI 跑中」，白等到 pending
  # 那個也跑完才看得到紅，正是本票要消滅的等待）。fail 存在時，pending 併入同一句提示，不分開判斷。
  if [ -n "$fail_names" ]; then
    printf '✗ check 紅：%s → gh run rerun <run-id> --failed（flaky）或修（run id：%s）%s' \
      "$fail_names" "${fail_ids:-未取得，見 PR #${n} 頁面}" "${pend:+；另 ${pend_count} 項跑中（${pend}）}"
    return
  fi
  if [ -n "$pend" ]; then
    printf '⏳ CI 跑中 %sm（%s）' "${pend_max_m:-?}" "$pend"
    return
  fi
  # 全綠或查無資料：gh pr checks 只列「已有回報」的項目，完全沒回報過的必要 context 不會出現──查
  # protection 的必要清單、與現有 status contexts 比對，找出真正缺的那個（09-12 #366 根因）。
  local req ctx missing='' status_ctx
  req=$(cd "$ROOT" && gh api "repos/:owner/:repo/branches/${base}/protection/required_status_checks" -q '.contexts[]' 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$req" ]; then
    printf '⚠ check 全綠仍 %s＝缺必要 status → 無法讀 protection（repos/…/branches/%s/protection/required_status_checks）→ 人工查 gh api repos/…/commits/%s/status' "$st" "$base" "$sha7"
    return
  fi
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    case "$present" in *$'\n'"${ctx}"$'\n'*) ;; *) missing="${missing:+${missing}、}${ctx}" ;; esac
  done <<EOF
$req
EOF
  status_ctx=$(cd "$ROOT" && gh api "repos/:owner/:repo/commits/${oid}/status" -q '[.statuses[].context] | join("、")' 2>/dev/null)
  [ -n "$status_ctx" ] || status_ctx="（無）"
  if [ -n "$missing" ]; then
    printf '⚠ check 全綠仍 %s＝缺必要 status（現有 status contexts：%s；缺：%s）→ gh api repos/…/commits/%s/status 看缺 merge-review／qa；head 是 merge commit 就依 §2 貼 promote: no content diff（post-status.sh %s merge-review success "…" --expect %s），否則派 review' \
      "$st" "$status_ctx" "$missing" "$sha7" "$sha7" "$sha7"
  else
    printf '⚠ %s 但 check／status 均已回報且無缺項（gh pr checks 全綠、protection 必要清單皆滿足）→ 人工看 PR #%s 頁面 merge 按鈕提示' "$st" "$n"
  fi
}

# ---- PR（open）：gh 未裝／失敗一律略過並標示原因，不炸 ----
PR_CHECKED=0; pr_skip=; pr_total=0; pr_flagged=0; PR_LINES=; J_PRS=; PR_HEADS=; pr_raw=
# gh 的 stderr 另存暫存檔，不併進 TSV（2>&1 會把警告行當成一筆 PR 讀進去；PR #99 R1）
gh_err=$(mktemp "${TMPDIR:-/tmp}/patrol-gh.XXXXXX") || { echo "✗ patrol：mktemp 失敗" >&2; exit 2; }
trap 'rm -f "$gh_err"' EXIT
if [ "$DO_PR" -eq 0 ]; then pr_skip="--no-pr"
elif ! command -v gh >/dev/null 2>&1; then pr_skip="gh 未安裝"
elif pr_raw=$(cd "$ROOT" && gh pr list --state open --limit 50 \
      --json number,title,headRefName,baseRefName,mergeStateStatus,updatedAt,reviewDecision,isDraft,headRefOid \
      -q '.[] | [.number, .mergeStateStatus, (if (.reviewDecision // "") == "" then "-" else .reviewDecision end), (((now - (.updatedAt | fromdateiso8601)) / 60) | floor), .headRefName, .baseRefName, (.isDraft | tostring), .headRefOid, .title] | @tsv' 2>"$gh_err"); then
  PR_CHECKED=1
else
  pr_skip="gh 失敗：$(head -1 "$gh_err" 2>/dev/null)"
fi
if [ "$PR_CHECKED" -eq 1 ] && [ -n "$pr_raw" ]; then
  while IFS=$'\t' read -r n st rd age head base draft oid title; do
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
        *) if [ "$age" -ge "$STALE" ]; then flag=$(pr_check_flag "$n" "$oid" "$base" "$st"); fi ;;
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
mc_dirty_files=$(git -C "$ROOT" diff --name-only HEAD 2>/dev/null)
if [ -z "$mc_dirty_files" ]; then mc_dirty=0; else mc_dirty=$(printf '%s\n' "$mc_dirty_files" | wc -l | tr -d ' '); fi
mc_flag=
if [ "$mc_branch" != main ]; then
  mc_flag="⚠ 主 checkout 不在 main（${mc_branch}）——派工前切回 main 並 pull"
elif [ "$mc_behind" != "?" ] && [ "$mc_behind" -gt 0 ]; then
  mc_flag="⚠ 主 checkout 落後 origin/main ${mc_behind} commit → 先 git pull --ff-only origin main 再派工（agent 定義讀自主 checkout）"
fi
if [ "$mc_dirty" -gt 0 ]; then
  # LS-236（來源：LS-208 收尾事故，LS-96 池項 `797c7149`）：唯一 dirty 檔就是 design/littlesprout.pen 時，
  # 十之八九是 `pen-open.sh <主 checkout> --kill` 清場重開時 Pen 把記憶體中另一份票檔內容寫回——給可執行的
  # 還原指令，不要印泛用的「N 個未提交變更」警告（那句只會讓人聯想到「該開 hotfix worktree 補 commit」，
  # 但這裡從來就不該有人手動編輯過主 checkout 的 .pen，正確處置是還原、不是落地）。
  if [ "$mc_dirty" -eq 1 ] && [ "$mc_dirty_files" = "design/littlesprout.pen" ]; then
    mc_flag="${mc_flag:+${mc_flag}；}⚠ 主 checkout design/littlesprout.pen 未提交（Pen 寫回 → bash scripts/ops/pen-open.sh --restore）"
  else
    mc_flag="${mc_flag:+${mc_flag}；}⚠ 主 checkout 有 ${mc_dirty} 個未提交變更（harness 改動也該在 hotfix worktree）"
  fi
fi
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
# ---- 螢幕鎖定（LS-220：鎖定會讓模擬器 Keychain SecItem* 回 -34018，QA e2e 逾時訊息與 session 沒建立長得
# 一模一樣，見 docs/COLLABORATION.md §4-b 排障順序 (b)；ioreg 查不到該鍵＝未鎖定，不視為錯誤）----
# LS-220 merge-review R2 M1：`CGSSessionScreenIsLocked` 這鍵實際印在 `IOConsoleUsers` 這個內嵌 dict
# 裡（本機實測 `ioreg -n Root -d1 | grep -o 'IOConsoleUsers[^)]*'`，未鎖定時整個 dict 是逗號分隔、
# `=` 兩側無空白的緊湊格式，例如 `{"kCGSSessionOnConsoleKey"=Yes,...,"kCGSSessionUserIDKey"=501}`；
# 鎖定時同一個 dict 會多一個逗號分隔項 `"CGSSessionScreenIsLocked"=Yes`，同樣無空白）——R1 誤植成
# Root 頂層、`=` 兩側各一個空白的形狀（`"CGSSessionScreenIsLocked" = Yes`），對真機輸出永遠比對不到、
# 永遠不會觸發。改成鍵名比對、`=` 兩側空白可有可無（`grep -Eq` 容忍兩種寫法，防未來 ioreg 版本或
# `-a`／人類可讀格式差異）。`ioreg -c IOConsoleUsers` 實測不是這個屬性所在的類別名，會印出整棵樹、
# 抓不到目標，維持用 `ioreg -n Root -d1` 這個既有來源。
screen_lock_flag=
if ioreg -n Root -d1 2>/dev/null | grep -Eq 'CGSSessionScreenIsLocked"[[:space:]]*=[[:space:]]*Yes'; then
  screen_lock_flag="⚠ 主機螢幕鎖定中——模擬器 Keychain 會回 -34018，QA e2e／互動式驗證卡住前先請使用者解鎖（§4-b 排障順序 (b)）"
fi
[ -n "$screen_lock_flag" ] && add_flag "[screen-lock] ${screen_lock_flag}"

[ -n "$hooks_flag" ] && add_flag "[hooks] ${hooks_flag}"

# ---- worktree ----
wt_total=0; wt_flagged=0; WT_LINES=; J_WTS=; design_wt=0
process_wt() {
  local w=$1 b=$2 det=$3
  local name l r= ahead=0 behind=0 base mb since=0 had=0 lc lm= dirty=0 dmax=0 dm= wt_ts wm= pr= flag= info= f t commit_txt dirty_txt merged=false wt_ticket=
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
  # LS-180：分支名含 design（設計票慣例 feature/LS-<n>-…-design）＝設計票在飛 → 下方 Pencil 連線探針段才跑
  case "$b" in *design*|*Design*) design_wt=1 ;; esac
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
    if [ "${lm:-0}" -ge "$PUSH_GRACE_MIN" ] && ! push_gate_running_for "$w"; then
      flag="⚠ 分支未 push（${since} commit 只在本機，最後 commit ${lm}m 前，>${PUSH_GRACE_MIN}分未偵測到 push-gate.sh 行程，LS-207）"
    elif [ "${lm:-0}" -ge "$PUSH_GRACE_MIN" ]; then
      info="${since} commit 尚未 push（${lm:-0}m 前，push-gate.sh 仍在跑）"
    else
      info="${since} commit 尚未 push（${lm:-0}m 前，可能還在跑 push gate）"
    fi
  elif [ -n "$r" ] && [ "$ahead" != "?" ] && [ "$ahead" -gt 0 ]; then
    if [ "${lm:-0}" -ge "$STALE" ]; then flag="⚠ 領先 remote ${ahead} commit 已 ${lm}m 未 push（push gate 卡？）"
    else info="領先 remote ${ahead}（${lm:-0}m 前，可能還在跑 push gate）"; fi
  fi
  if [ -n "$r" ] && [ "$behind" != "?" ] && [ "$behind" -gt 0 ]; then flag="${flag:+${flag}；}⚠ 落後 remote ${behind} commit（remote 有本機沒有的 commit）"; fi
  if [ "$dirty" -gt 0 ] && [ "${dm:-0}" -ge "$STALE" ]; then flag="${flag:+${flag}；}⏳ ${dirty} 個未提交變更、最後改動 ${dm}m 前（停滯？）"; fi
  if [ "$since" = 0 ] && [ "$dirty" -eq 0 ]; then
    if [ "$merged" = true ]; then
      # LS-86：判定與 cleanup-merged.sh 的 (a) 一致（since=0＝分支已是 base 祖先），直接指到那支
      # 腳本而非裸 git worktree remove——它多做了 dirty／保護分支／目前所在目錄的安全檢查，先
      # dry-run 看清單再 --apply。能從 worktree 目錄名解出票號（<票號>-<slug> 慣例）就帶上去。
      wt_ticket=$(printf '%s' "$name" | grep -oE '^LS-[0-9]+' || true)
      flag="${flag:+${flag}；}⚠ 分支已併入 base、worktree 未移除 → bash scripts/ops/cleanup-merged.sh --dry-run${wt_ticket:+ ${wt_ticket}}（確認後 --apply，LS-86）"
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
WT_INDEX=   # LS-187：每筆「<路徑>\t<分支>」（含主 checkout／detached），專屬模擬器段查「票 worktree 是否還在磁碟」用
flush_wt() {
  [ -n "$cur_path" ] || return 0
  WT_INDEX="${WT_INDEX}${cur_path}"$'\t'"${cur_branch}"$'\n'
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
# LS-159：QA 持有（hold）時另讀 holder 檔的 label／到期 epoch 給 --json；human／--brief 那一行由 --status 自帶「持有中（label，剩餘 n 分）」
hold_label=; hold_expires=; lock_path=
if [ -f "$here/supabase-lock.sh" ]; then
  lock_path=$(bash "$here/supabase-lock.sh" --path 2>/dev/null)
  if [ -n "$lock_path" ] && [ -f "$lock_path/holder" ]; then
    hold_label=$(sed -n 's/^cmd=hold://p' "$lock_path/holder" 2>/dev/null | head -1)
    [ -n "$hold_label" ] && hold_expires=$(sed -n 's/^expires_at=//p' "$lock_path/holder" 2>/dev/null | head -1)
  fi
fi
# LS-207（ca35c579）：排隊可見化——supabase-lock.sh --hold 排隊時在 `<lock 路徑>.waiters/` 寫 `<票號>-<pid>-<起始>`
# 空檔（取得或放棄即刪）。這裡數等待者與最久等待分鐘；持有者是 hold（有 hold_expires）且剩餘 >10 分、又有
# 等待者時印 ⚠ 排隊——LS-164／202 QA 在 --hold 內阻塞近 100 分鐘、orchestrator 只看到「無產出」才知道要查。
lock_waiters=0; lock_waiters_max_min=0; lock_queue_flag=; lock_hold_remain_min=
if [ -n "$lock_path" ] && [ -d "${lock_path}.waiters" ]; then
  now_epoch=$(date +%s)
  for wf in "${lock_path}.waiters"/*; do
    [ -f "$wf" ] || continue
    # LS-207 R2（merge-review R1 fd783f6c F3）：holder 那路有 is_stale＋reclaim＋tomb，waiter 這路原本完全沒有——
    # SIGKILL／crash（INT/TERM/HUP 才有 trap 清）留下的殘留檔會被永遠算進「排隊中」，讓 ⚠ 排隊／`lock_waiters`
    # 變成常駐假警報。檔名已帶 pid，這裡用 kill -0 驗活；不活就回收（rm，不計入排隊數）；解析不出 pid 的檔名
    # （不該發生，但寧可誤報也不亂刪）原樣計入、不動它。
    wpid=$(basename "$wf" | sed -E 's/^(.*)-([0-9]+)-([0-9]+)$/\2/')
    case "$wpid" in
      ''|*[!0-9]*) ;;
      *) if ! kill -0 "$wpid" 2>/dev/null; then rm -f "$wf" 2>/dev/null; continue; fi ;;
    esac
    lock_waiters=$((lock_waiters + 1))
    wstarted=$(basename "$wf" | sed -E 's/^(.*)-([0-9]+)-([0-9]+)$/\3/')
    case "$wstarted" in
      ''|*[!0-9]*) ;;
      *) wm=$(( (now_epoch - wstarted + 59) / 60 )); [ "$wm" -gt "$lock_waiters_max_min" ] && lock_waiters_max_min=$wm ;;
    esac
  done
  if [ "$lock_waiters" -gt 0 ]; then
    case "${hold_expires:-}" in
      ''|*[!0-9]*) ;;
      *) lock_hold_remain_min=$(( (hold_expires - now_epoch + 59) / 60 )); [ "$lock_hold_remain_min" -lt 0 ] && lock_hold_remain_min=0
         if [ "$lock_hold_remain_min" -gt 10 ]; then
           lock_queue_flag="⚠ 排隊 ${lock_waiters}（最久 ${lock_waiters_max_min} 分）"
           add_flag "[Supabase lock] ${lock_queue_flag}——持有者「${hold_label}」剩餘 ${lock_hold_remain_min} 分，該檢查是否卡住（LS-207）"
         fi
         ;;
    esac
  fi
fi

# ---- Supabase 容器啟動時間一致性（LS-260；來源 LS-96 池項 `b2947c3f`）----
# LS-246 QA R2：本機 `supabase_auth`／`supabase_db` 曾被單獨重啟、`rest`／`kong` 沒有（uptime 差 7 天），
# OTP 登入後 `GET /rest/v1/profiles` 回 401、App 卡「伺服器發生問題」，QA 以整組 `supabase stop` →
# `supabase start` 排除，多花一段排障。查過 repo 內沒有任何腳本會在**本機**單獨重啟單一容器——唯一會動
# 容器生命週期的 `scripts/ci/db-reset-retry.sh` 走 `supabase stop --no-backup` → `supabase db start`，
# 後者本身就是部分啟動（只起 db 群），但它以 `CI` 守門（`:26-28`）、本機呼叫在碰 supabase 之前就
# exit 2，只有明示逃生口 `LS_DB_RESET_RETRY_ALLOW_LOCAL=1` 能繞過（**R2 i1 訂正**：R1 這段寫成
# 「repo 內沒有腳本會單獨重啟」，略過了「CI 路徑本身是部分啟動、只是已被守門」這半句）。本機的來源
# 因此只可能是人工或外部操作。源頭修不了，就讓巡檢看得見結果（判準見下方 R2 M2 的分批比形狀）。docker 不在／沒有 supabase 容器在跑 → 靜默略過（fail-open，同 gh
# 未安裝的處理；巡檢本身不該因為沒開容器就變成「有異常」）。`docker ps`／`docker inspect` 是唯讀操作，
# 不受 supabase-lock 規約管轄（LS-183 明列的例外）。PATROL_DOCKER 可換假身供自測。
DOCKER_BIN=${PATROL_DOCKER:-docker}
SUPA_SKEW_MIN=${PATROL_SUPABASE_SKEW_MIN:-60}
case "$SUPA_SKEW_MIN" in ''|*[!0-9]*) echo "✗ patrol：PATROL_SUPABASE_SKEW_MIN 須為整數分鐘（得到「${SUPA_SKEW_MIN}」）" >&2; exit 2 ;; esac
# LS-260 R2 M2：StartedAt 相差幾秒內算「同一次操作」（分批用）——`supabase db reset` 重啟那幾台
# 實測落在數秒到數十秒內，120 秒有足夠餘裕又遠小於 60 分門檻。
# LS-264（來源 LS-96 池項 `fda1b06c` m2）：120 秒是固定常數，而它要涵蓋的是「db 重啟 → 跑完 migrations
# → 其餘幾台重啟」這整段——LS-260 實測餘裕只剩 14 秒，migration 一多就會超過，reset 偽陽性整個回來。
# 本輪改成**優先由 `supabase-lock.sh` 的 `hold.log` 推導 reset 時窗**（見下方 awk 的 winstart），
# 這個常數退居沒有 hold.log 可讀時的退路。
SUPA_BATCH_SEC=${PATROL_SUPABASE_BATCH_SEC:-120}
case "$SUPA_BATCH_SEC" in ''|*[!0-9]*) echo "✗ patrol：PATROL_SUPABASE_BATCH_SEC 須為整數秒（得到「${SUPA_BATCH_SEC}」）" >&2; exit 2 ;; esac
# hold.log 路徑由 supabase-lock.sh 自己推（`--path` 已在上面取過 lock_path）；讀不到就退回 SUPA_BATCH_SEC。
supa_hold_log=; [ -n "${lock_path:-}" ] && [ -f "${lock_path}.hold.log" ] && supa_hold_log="${lock_path}.hold.log"
# hold.log 的行首時間是**本地時間**，容器 StartedAt 是 UTC。一次 date 同時取 epoch 與本地時間字串，
# 讓 awk 自己算時差（同本檔「不碰 date -j／date -d」的既有理由：GNU／BSD 旗標不同）。
supa_now_pair=$(date '+%s %Y-%m-%dT%H:%M:%S')
SUPA_LINE=; supa_containers=0; supa_skew_m=0; supa_shape=; supa_intra_m=0; supa_intra_oldest=-; supa_intra_newest=-
if command -v "$DOCKER_BIN" >/dev/null 2>&1; then
  supa_names=$("$DOCKER_BIN" ps --filter name=supabase_ --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
  case "${supa_names// /}" in
    '') SUPA_LINE="（無執行中的 supabase_* 容器）" ;;
    *)
      # 一次 inspect 全部容器（每台各 fork 一次 docker 在 SessionStart hook 的 30s 預算下太貴）。
      # StartedAt 是 RFC3339 UTC；awk 內自己換算 epoch（days-from-civil），不碰 date -j／date -d
      # ——同本檔開頭「時間一律用 epoch、不碰 date -j／date -d」的既有理由（GNU／BSD 旗標不同）。
      # 精度到秒（小數秒丟棄）：門檻本來就是分鐘級。
      #
      # LS-260 R2 M2（merge-review R1 `870bf760`）：R1 版本對「全部容器的 max-min」設門檻，會被
      # **例行的 `supabase db reset`** 觸發——reset 只重建／重啟 `db`／`auth`／`storage`／`realtime`
      # ／`analytics`，`rest`／`kong`／`studio`／`vector`／`pg_meta`／`edge_runtime` 維持原 uptime。
      # stack 常連續跑數小時到數天，任何 uptime > 門檻之後的 reset 都會掛旗標，並建議做一次有破壞性
      # 的整組重啟（LS-184：起停共用容器會打斷持有者）。R1 handoff 申報的「84 分真實事故」經 reviewer
      # 比對 `docker inspect .Created`／`.State.StartedAt` 與 hold.log 時間，正是本票實作者自己那次
      # reset 造成的**偽陽性**（訂正見 R2 handoff）。
      #
      # 改判準（reviewer 建議 (a)＋(b) 的合成）：先把容器依 StartedAt **分批**（相差 ≤
      # `SUPA_BATCH_SEC` 秒視為同一次操作），再看**最新那一批的成員集合**：
      #   - 集合 == 現存的 reset 群組（`db`／`auth`／`storage`／`realtime`／`analytics` 取交集）
      #     → 判為例行 `supabase db reset`，**不掛旗標**（human 段註明形狀）。
      #   - 否則才看 `rest`／`kong`／`db`／`auth` 這四台之間的 skew（LS-246 症狀的直接關係人：
      #     auth／db 重啟而 rest／kong 沒有 → REST 401），超過門檻才掛旗標。
      #
      # LS-264 m2（來源 LS-96 池項 `fda1b06c`）：分批視窗改由 `hold.log` 推導，`SUPA_BATCH_SEC` 退為退路。
      # R2 當時寫「為什麼不改讀 hold.log：`supabase-lock.sh` 只記 `cmd=` 的第一個字（`cmd=supabase`），
      # reset／stop／start／status 長得一模一樣」——那句話對「分辨是哪個子命令」成立，但這裡根本不需要
      # 分辨：要的只是**那一次容器操作是幾點開始的**。hold.log 每次取鎖都留一行帶時間的 `取得`（`--`
      # 包裝與 `--hold` 都有），取「不晚於最新容器 StartedAt 的最近一次取鎖時間」當視窗起點，凡在其後
      # 啟動的容器都算同一次操作——migrations 跑 5 分鐘也涵蓋得住，不必猜一個固定秒數。
      # 兩道保險：(1) 視窗起點離最新容器超過 `SUPA_SKEW_MIN` 分就不採用（太舊的取鎖與這次重啟無關，
      # 硬採會把所有容器併成一批、反而把 LS-246 那種真事故洗成 uniform）；(2) 沒有 hold.log／解析不出
      # 時間（新機器、/tmp 被清）就退回 `SUPA_BATCH_SEC` 的固定秒數分批，行為與 LS-260 相同。
      #
      # LS-264 m3（同池項）：形狀判為 db-reset 時，R2 版本整段靜音——「非 reset 群組裡有人落單重啟」
      # （例如 kong 比 rest 晚 5 天才被單獨重啟）會被例行 reset 完全遮蔽。改成只排除**跨群組**那段差：
      # 最新一批（reset 群組）內部、其餘容器內部各自再比一次 focus skew，任一超過門檻照樣掛旗標。
      supa_parsed=$( { "$DOCKER_BIN" inspect --format '{{.Name}} {{.State.StartedAt}}' $supa_names 2>/dev/null | sed 's/^/C /'
                       [ -n "$supa_hold_log" ] && grep -a '取得' "$supa_hold_log" 2>/dev/null | tail -n 100 | sed 's/^/H /'
                       true
                     } | awk -v batch="${SUPA_BATCH_SEC}" -v maxwin="$((SUPA_SKEW_MIN * 60))" -v nowpair="$supa_now_pair" '
        function epoch(s,   a, y, m, d, H, M, S, yy, era, yoe, doy, doe, days) {
          split(s, a, /[-T:]/)
          y = a[1] + 0; m = a[2] + 0; d = a[3] + 0; H = a[4] + 0; M = a[5] + 0; S = int(a[6])
          if (y < 1970 || m < 1 || m > 12) return -1
          yy = y - (m <= 2 ? 1 : 0)
          era = int((yy >= 0 ? yy : yy - 399) / 400)
          yoe = yy - era * 400
          doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
          doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
          days = era * 146097 + doe - 719468
          return days * 86400 + H * 3600 + M * 60 + S
        }
        # `supabase_<role>_<project>` → role；`edge_runtime`／`pg_meta` 會被切成 edge／pg，
        # 但判準只用到 db／auth／storage／realtime／analytics／rest／kong，皆為單字 role。
        function role(nm,   a) { split(nm, a, "_"); return a[2] }
        BEGIN {
          split("db auth storage realtime analytics", r, " ")
          for (i in r) resetset[r[i]] = 1
          split("rest kong db auth", f, " ")
          for (i in f) focus[f[i]] = 1
          # hold.log 是本地時間、容器 StartedAt 是 UTC：用「同一次 date 取到的 epoch 與本地時間字串」
          # 反推時差（本地字串當 UTC 解出來的 epoch − 真 epoch）。
          split(nowpair, np, " ")
          tzoff = (np[2] == "" ? 0 : epoch(np[2]) - (np[1] + 0))
          winstart = -1
        }
        # hold.log 的取鎖行：`YYYY-MM-DD HH:MM:SS … 取得 …`（`--` 包裝與 `--hold` 兩種都是這個行首）
        $1 == "H" && NF >= 3 {
          he = epoch($2 "T" $3)
          if (he >= 0) { nh++; holds[nh] = he - tzoff }
          next
        }
        $1 == "C" && NF >= 3 {
          nm = $2; sub(/^\//, "", nm)
          e = epoch($3)
          if (e < 0) next
          n++; names[n] = role(nm); epochs[n] = e; full[n] = nm
          if (role(nm) in resetset) present_reset[role(nm)] = 1
          if (role(nm) in focus) {
            if (fmn == "" || e < fmn) { fmn = e; fmnn = nm }
            if (fmx == "" || e > fmx) { fmx = e; fmxn = nm }
          }
        }
        END {
          if (n == 0) exit 0
          top = 0
          for (i = 1; i <= n; i++) if (epochs[i] > top) top = epochs[i]
          # m2：視窗起點＝不晚於 top 的最近一次取鎖時間（離 top 超過 maxwin 秒就不採用）；
          #     取不到就退回「以 top 為錨、差 <= batch 秒算同一批」的固定秒數分批。
          for (i = 1; i <= nh; i++)
            if (holds[i] <= top && holds[i] > winstart) winstart = holds[i]
          if (winstart >= 0 && top - winstart > maxwin) winstart = -1
          nb = 0
          for (i = 1; i <= n; i++) {
            inb = (winstart >= 0) ? (epochs[i] >= winstart) : (top - epochs[i] <= batch)
            grp[i] = inb ? 1 : 0
            if (inb) { nb++; batchset[names[i]] = 1 }
          }
          # 形狀判定：最新一批的成員集合是否恰好等於「現存的 reset 群組」
          shape = "other"
          same = 1
          for (r2 in present_reset) if (!(r2 in batchset)) same = 0
          for (b in batchset) if (!(b in present_reset)) same = 0
          if (same && nb > 0 && nb < n) shape = "db-reset"
          if (nb == n) shape = "uniform"
          # m3：群組內 focus skew（最新一批內部、其餘容器內部各算一次，取較大的那組）——
          #     只有「跨群組」那段差被排除，群組內落單重啟仍看得見。
          intra = 0; intraold = "-"; intranew = "-"
          for (i = 1; i <= n; i++) {
            if (!(names[i] in focus)) continue
            g = grp[i]
            if (gmn[g] == "" || epochs[i] < gmn[g]) { gmn[g] = epochs[i]; gmnn[g] = full[i] }
            if (gmx[g] == "" || epochs[i] > gmx[g]) { gmx[g] = epochs[i]; gmxn[g] = full[i] }
          }
          for (g = 0; g <= 1; g++) {
            if (gmn[g] == "") continue
            d = gmx[g] - gmn[g]
            if (d > intra) { intra = d; intraold = gmnn[g]; intranew = gmxn[g] }
          }
          printf "%d\t%d\t%s\t%s\t%s\t%d\t%s\t%s\n", n, (fmx == "" ? 0 : fmx - fmn), (fmnn == "" ? "-" : fmnn), (fmxn == "" ? "-" : fmxn), shape, intra, intraold, intranew
        }
      ')
      if [ -n "$supa_parsed" ]; then
        supa_containers=$(printf '%s' "$supa_parsed" | cut -f1)
        supa_skew_m=$(( $(printf '%s' "$supa_parsed" | cut -f2) / 60 ))
        supa_oldest=$(printf '%s' "$supa_parsed" | cut -f3)
        supa_newest=$(printf '%s' "$supa_parsed" | cut -f4)
        supa_shape=$(printf '%s' "$supa_parsed" | cut -f5)
        supa_intra_m=$(( $(printf '%s' "$supa_parsed" | cut -f6) / 60 ))
        supa_intra_oldest=$(printf '%s' "$supa_parsed" | cut -f7)
        supa_intra_newest=$(printf '%s' "$supa_parsed" | cut -f8)
        case "$supa_shape" in
          uniform)  supa_note="整組同一次啟動" ;;
          db-reset)
            if [ "$supa_intra_m" -gt "$SUPA_SKEW_MIN" ]; then
              supa_note="最新一批＝db／auth／storage／realtime／analytics，形狀符合例行 supabase db reset，但群組內最大差 ${supa_intra_m} 分 > ${SUPA_SKEW_MIN}"
            else
              supa_note="最新一批＝db／auth／storage／realtime／analytics，形狀符合例行 supabase db reset，不掛旗標（群組內最大差 ${supa_intra_m} 分）"
            fi
            ;;
          *)        supa_note="最新一批不是 reset 群組" ;;
        esac
        SUPA_LINE="容器 ${supa_containers} 個，rest／kong／db／auth 之間最大差 ${supa_skew_m} 分（最舊 ${supa_oldest}／最新 ${supa_newest}；門檻 ${SUPA_SKEW_MIN} 分；${supa_note}）"
        if [ "$supa_shape" != db-reset ] && [ "$supa_shape" != uniform ] && [ "$supa_skew_m" -gt "$SUPA_SKEW_MIN" ]; then
          # LS-260 R2 m4：整組重啟包成**一次** lock（R1 拆成兩次獨立 lock，兩次之間別人可以合法取得
          # lock 並看到整組是停的）；這個包法與 qa.md／`pretool.test.sh` H3b-s⑦ 認可的寫法一致。
          add_flag "[Supabase 容器] ⚠ 容器啟動時間不一致（rest／kong／db／auth 之間最舊 ${supa_oldest} 與最新 ${supa_newest} 差 ${supa_skew_m} 分 > ${SUPA_SKEW_MIN}，且最新一批不是 db reset 的群組）——單獨重啟過的容器與其他容器不同步（LS-246 QA：auth／db 重啟、rest／kong 沒有 → REST 401、App 卡「伺服器發生問題」）。請在同一次 lock 內整組重啟：bash scripts/ops/supabase-lock.sh -- bash -c \"supabase stop && supabase start\"（LS-260）"
        elif [ "$supa_shape" = db-reset ] && [ "$supa_intra_m" -gt "$SUPA_SKEW_MIN" ]; then
          # LS-264 m3：例行 reset 只解釋得了「跨群組」那段差；群組內部（reset 群組內、或其餘容器內）
          # 還差這麼多，代表有人單獨重啟過其中一台——正是 LS-246 要抓的形狀，不能被 reset 遮蔽。
          add_flag "[Supabase 容器] ⚠ 群組內啟動時間不一致（形狀符合例行 db reset，但同一群組內最舊 ${supa_intra_oldest} 與最新 ${supa_intra_newest} 差 ${supa_intra_m} 分 > ${SUPA_SKEW_MIN}）——跨群組差已排除，這段差只可能是單獨重啟（LS-246 QA：auth／db 重啟、rest／kong 沒有 → REST 401、App 卡「伺服器發生問題」）。請在同一次 lock 內整組重啟：bash scripts/ops/supabase-lock.sh -- bash -c \"supabase stop && supabase start\"（LS-264）"
        fi
      else
        SUPA_LINE="（docker inspect 讀不到 StartedAt，略過）"
      fi
      ;;
  esac
else
  SUPA_LINE="（docker 未安裝，略過）"
fi

# ---- 近 N 日 CI 同類紅計數（LS-260；來源 LS-96 池項 `ec152d21`）----
# §5-b 的「同類事故 ≥2 次升 High」此前靠 orchestrator 人工記憶計數：LS-253 是第 3 次 ci-ipad 同測試紅
# 才開票、LS-257 是第 2 次 ci timeout 才開票，兩次都延遲。這裡把它機械化：近 `PATROL_REDS_DAYS` 天
# （預設 7）conclusion 為 failure／cancelled 的 run，抽出「失敗的測試名」與「失敗型別」當簽章，同一個
# 簽章出現在 ≥2 個 run 就掛旗標。
#
# 成本控制（這段會打網路，cron 每 26 分＋SessionStart hook 30s 預算都跑得到）：
#   - `gh run list` 一次拿清單（含 conclusion），只對 conclusion=failure 的 run 下載失敗 job 的 log；
#     conclusion=cancelled 的不下載（LS-257 那種「步驟全 success 卻 cancelled」＝撞 job timeout，型別
#     本身就是簽章）。
#   - **每個 run 的簽章只算一次並落盤快取**（`PATROL_REDS_CACHE`，預設 `$TMPDIR/patrol-reds-cache`）：
#     已完成的 run 其失敗內容不會再變，穩態下每輪只需下載 0–2 個新 run 的 log。單輪新下載上限
#     `PATROL_REDS_MAX_FETCH`（預設 5），超過的 run 這輪先不算、下一輪再補（寧可少報也不要拖垮巡檢）。
#   - 快取檔超過 2×N 天自動清掉。
# fail-soft：`--no-pr`（自測／離線）、gh 未安裝、`gh run list` 失敗（離線／未登入）一律只註記、不掛旗標
# ——同本檔 PR 段對 gh 的既有處理，巡檢不該因為沒網路就變成「有異常」。
GH_BIN=${PATROL_GH:-gh}
REDS_DAYS=${PATROL_REDS_DAYS:-7}
REDS_MAX_FETCH=${PATROL_REDS_MAX_FETCH:-5}
REDS_CACHE=${PATROL_REDS_CACHE:-${TMPDIR:-/tmp}/patrol-reds-cache}
# LS-260 R2 m1（merge-review R1）：快取以 run id 為 key、不帶簽章格式版本——簽章規則一改，舊檔
# 照樣被讀進來。reviewer 實地重現過：用本 head 跑 patrol 時讀到更早草稿版寫下的快取，印出
# 「⚠ 同類紅 10 次」的假警報（內容是現行程式碼根本不會產生的字串）。路徑加一段版本，簽章規則
# 變更就把常數往上跳，舊批整批自然失效（也不必手動清 /tmp）。
REDS_CACHE_VER=v2   # R2 M3 加了 class: 簽章，簽章集合變了 → 跳號讓 v1 快取整批失效
# LS-260 R2 i3（merge-review R1）：乾淨快取那一輪 reviewer 實測 15.2 s（序列 `gh run view`，其中
# `--log-failed` 會抓整包 log），而 SessionStart hook 的預算是 30 s，本段原本沒有任何時間上界（只有
# 「筆數」上限）。加一個純 deadline 比對的時間預算：每次要打網路前先看時間，超過就這輪不再抓、下一輪
# 再補（不 fork 背景看門狗——同本檔對 gh 的既有慣例，也避免多一個要回收的子程序）。
REDS_BUDGET_SEC=${PATROL_REDS_BUDGET_SEC:-20}
case "$REDS_BUDGET_SEC" in ''|*[!0-9]*) echo "✗ patrol：PATROL_REDS_BUDGET_SEC 須為整數秒（得到「${REDS_BUDGET_SEC}」）" >&2; exit 2 ;; esac
# LS-260 R2 M1：cancelled job 跑滿幾分鐘才算「撞 job timeout-minutes」（見下方分類邏輯的實測分離度）
REDS_TIMEOUT_MIN=${PATROL_REDS_TIMEOUT_MIN:-30}
case "$REDS_DAYS" in ''|*[!0-9]*) echo "✗ patrol：PATROL_REDS_DAYS 須為整數天（得到「${REDS_DAYS}」）" >&2; exit 2 ;; esac
case "$REDS_MAX_FETCH" in ''|*[!0-9]*) echo "✗ patrol：PATROL_REDS_MAX_FETCH 須為整數（得到「${REDS_MAX_FETCH}」）" >&2; exit 2 ;; esac
case "$REDS_TIMEOUT_MIN" in ''|*[!0-9]*) echo "✗ patrol：PATROL_REDS_TIMEOUT_MIN 須為整數分鐘（得到「${REDS_TIMEOUT_MIN}」）" >&2; exit 2 ;; esac
REDS_LINES=; reds_note=; J_REDS=; reds_flagged=0; reds_runs=0; reds_oldest=
if [ "$DO_PR" -ne 1 ]; then
  reds_note="略過（--no-pr）"
elif ! command -v "$GH_BIN" >/dev/null 2>&1; then
  reds_note="gh 未安裝，略過"
else
  # LS-260 R2 M3（merge-review R1）：R1 用 `--limit 40` 再由 jq 過濾 7 日——reviewer 實測那 40 筆
  # 只涵蓋約 **19 小時**（近 7 日 failure／cancelled 共 63 個，40 筆內只有 13 個），人類段卻照樣
  # 印「近 7 日 … 13 個」，數字不實；而票文要解的正是「同類紅間距常跨數十個 run」（實測近 7 日兩次
  # `ci-ipad` 紅只有一次落在 40 筆窗內）。改成：`--created` 讓 GitHub 端就按日期過濾（成本仍是一次
  # API 呼叫）＋ `--limit 200` 拉高上限；日期字串用 BSD／GNU 兩種寫法試，兩種都不行就不帶
  # `--created`、退回純 `--limit 200`＋jq 過濾（fail-soft，不因為 date 旗標差異就整段停擺）。
  # 另外把 `createdAt` 也取回來，人類段才印得出「實際涵蓋到哪一筆」，不再空口宣稱 7 日。
  reds_since=$(date -u -v-"${REDS_DAYS}"d +%F 2>/dev/null) \
    || reds_since=$(date -u -d "${REDS_DAYS} days ago" +%F 2>/dev/null) || reds_since=
  reds_list=$(cd "$ROOT" && "$GH_BIN" run list --limit 200 ${reds_since:+--created ">=${reds_since}"} \
    --json databaseId,headBranch,createdAt,conclusion \
    --jq ".[] | select(.conclusion == \"failure\" or .conclusion == \"cancelled\") | select((.createdAt | fromdateiso8601) > (now - ${REDS_DAYS} * 86400)) | [.databaseId, .conclusion, .headBranch, .createdAt] | @tsv" 2>/dev/null)
  if [ -z "$reds_list" ]; then
    reds_note="近 ${REDS_DAYS} 日無 failure／cancelled 的 run（或 gh 查詢失敗／未登入，fail-soft 不擋）"
  else
    reds_cache_dir="${REDS_CACHE}/${REDS_CACHE_VER}"
    mkdir -p "$reds_cache_dir" 2>/dev/null
    find "$REDS_CACHE" -type f -mtime "+$((REDS_DAYS * 2))" -delete 2>/dev/null
    reds_fetched=0; reds_sigs=; reds_budget_hit=0
    reds_deadline=$(( $(date +%s) + REDS_BUDGET_SEC ))
    while IFS=$'\t' read -r r_id r_concl r_branch r_created; do
      [ -n "$r_id" ] || continue
      reds_runs=$((reds_runs + 1))
      # gh 回傳是新到舊，最後一筆即最舊；直接覆寫，不另外比對字串
      [ -n "$r_created" ] && reds_oldest=$r_created
      cache_f="${reds_cache_dir}/${r_id}"
      if [ ! -f "$cache_f" ]; then
        # 額度用完就先不算這個 run（不寫快取），下一輪再補——`cancelled` 那條雖然只查 JSON、比較便宜，
        # 但同樣是一次網路往返，一併受額度管，巡檢的單輪成本才有上界。
        [ "$reds_fetched" -ge "$REDS_MAX_FETCH" ] && continue
        # i3：時間預算用完就跟筆數上限一樣「這輪先不算」，不寫快取、下一輪再補
        if [ "$(date +%s)" -ge "$reds_deadline" ]; then reds_budget_hit=1; continue; fi
        if [ "$r_concl" = cancelled ]; then
          # cancelled 有兩種形狀，只有其中一種是事故：
          #   (a) 撞 job `timeout-minutes`（LS-257 的真事故，要計數）；
          #   (b) 被 `concurrency: cancel-in-progress` 取消的過期 run／人工取消——每次連續 push 都會
          #       產生一個，計進去會變成一條永遠亮著的假警報。
          #
          # LS-260 R2 M1（merge-review R1 `870bf760`）：本段原本用「步驟全 success」判 (a)，那正是
          # LS-257 R1 merge-review 已經**推翻**的形狀——`scripts/ops/promote-follow.sh:75-80` 檔頭寫明
          # 「撞 timeout 那一刻正在跑的步驟會被 GitHub 記成 cancelled，這個更嚴格的條件反而漏掉票要
          # 解決的主場景」。reviewer 對近 7 日 38 個 cancelled run 逐一實測：舊判準命中 **0/38**
          # （timeout 簽章永遠產生不出來，項 4 對 LS-257 那類事故完全無效）。
          #
          # 改成兩條件並用：
          #   1. 無任何 step 是 `failure`／`timed_out`——與 `promote-follow.sh` 的 `no_failure_steps()`
          #      同一判準（Rule 6：兩個相衝突的判準取較新且經 review 修正的那個）。單獨用太鬆
          #      （reviewer 實測 36/38），所以再加第 2 條。
          #   2. 存在 `conclusion=cancelled` 的 job，其 `completedAt-startedAt` ≥
          #      `PATROL_REDS_TIMEOUT_MIN`（預設 30 分）——真正撞 timeout 的 job 一定跑很久，
          #      被 concurrency 取代的過期 run 通常幾十秒到十幾分鐘就被砍。
          # 本機對近 7 日 cancelled run 實測的分離度（`<有無 failure step>／<最久 cancelled job 秒數>`）：
          # 真 timeout 2454／2132／1988，concurrency 取消 1554／1321／1303／1187／1091／1002／571／
          # 333／56，有 failure step 的 2 個（55／340）另被條件 1 擋掉——1800 秒把兩群切得很開。
          # 判準用 `--json jobs`（純 JSON，比 `--log-failed` 下載整包 log 便宜得多），同樣進快取。
          reds_fetched=$((reds_fetched + 1))
          r_shape=$(cd "$ROOT" && "$GH_BIN" run view "$r_id" --json jobs --jq \
            '[.jobs[].steps[]?.conclusion] as $sc | ([.jobs[] | select(.conclusion == "cancelled" and .startedAt != null and .completedAt != null) | ((.completedAt | fromdateiso8601) - (.startedAt | fromdateiso8601))] | max // 0) as $d | "\(if ($sc | any(. == "failure" or . == "timed_out")) then 1 else 0 end)\t\($d)"' 2>/dev/null)
          r_hasfail=$(printf '%s' "$r_shape" | cut -f1); r_cansec=$(printf '%s' "$r_shape" | cut -f2)
          case "${r_hasfail}|${r_cansec}" in
            0\|*[!0-9]*|0\|) : > "$cache_f" ;;   # 秒數解析不出來（gh 失敗／欄位缺）→ 空簽章，不臆測
            0\|*)
              if [ "$r_cansec" -ge $((REDS_TIMEOUT_MIN * 60)) ]; then
                printf 'timeout（cancelled、無 failure／timed_out step、cancelled job ≥%s 分——撞 job timeout-minutes）\n' "$REDS_TIMEOUT_MIN" > "$cache_f"
              else
                : > "$cache_f"                   # (b) 過期／人工取消：日常，不計數
              fi
              ;;
            *) : > "$cache_f" ;;                 # 有 failure／timed_out step，或整段讀不到 → 不計數
          esac
        else
          reds_fetched=$((reds_fetched + 1))
          reds_log=$(cd "$ROOT" && "$GH_BIN" run view "$r_id" --log-failed 2>/dev/null)
          reds_tests=$(printf '%s\n' "$reds_log" | grep -oE "Test Case '[^']+' failed" \
            | sed -E "s/^Test Case '//; s/' failed\$//" | sort -u)
          {
            [ -n "$reds_tests" ] && printf '%s\n' "$reds_tests"
            # LS-260 R2 M3 附帶（merge-review R1 informational）：簽章只用**測試方法名**時，同一個
            # 測試類別的不同方法不會聚合——reviewer 實測近 7 日兩次 `ci-ipad` 紅正是
            # `SettingsViewIPadTests` 的兩個不同方法，§5-b 的「同類」實務上是類別／根因層級。
            # 方法名之外再記一條 `class:<模組.類別>`，兩種粒度各自計數（類別層級的門檻自然更容易到，
            # 這正是要的：LS-253 那種「同一個測試檔反覆紅」會提早被看見）。
            [ -n "$reds_tests" ] && printf '%s\n' "$reds_tests" \
              | sed -nE 's/^-\[([^][[:space:]]+)[[:space:]].*\]$/class:\1/p' | sort -u
            case "$reds_log" in
              *"has exceeded the maximum execution time"*|*"timed out"*|*"Timed out"*) printf 'timeout（步驟逾時）\n' ;;
            esac
          } > "$cache_f"
        fi
      fi
      # 同一個 run 內同名測試重複出現只算一次（`sort -u` 已在寫入時做過；cancelled 那條只有一行）
      while IFS= read -r sig; do
        [ -n "$sig" ] || continue
        reds_sigs="${reds_sigs}${sig}"$'\n'
      done < "$cache_f"
    done <<EOF
$reds_list
EOF
    if [ -n "$reds_sigs" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        r_n=${line%%$'\t'*}; r_sig=${line#*$'\t'}
        reds_flagged=$((reds_flagged + 1))
        REDS_LINES="${REDS_LINES}  ⚠ 同類紅 ${r_n} 次（${r_sig}）→ 依 §5-b 升票"$'\n'
        J_REDS="${J_REDS:+${J_REDS},}{\"signature\":$(json_str "$r_sig"),\"runs\":${r_n}}"
        add_flag "[CI 同類紅] ⚠ 同類紅 ${r_n} 次（${r_sig}）→ 依 §5-b「同類事故 ≥2 次升 High」開票，別再靠人工記憶計數（LS-260）"
      done <<EOF
$(printf '%s' "$reds_sigs" | sort | uniq -c | awk '$1 >= 2 { n = $1; $1 = ""; sub(/^ +/, ""); printf "%d\t%s\n", n, $0 }' | sort -rn)
EOF
    fi
    reds_budget_note=; [ "$reds_budget_hit" -eq 1 ] && reds_budget_note="；本輪時間預算 ${REDS_BUDGET_SEC} 秒用完，剩下的下一輪再算"
    reds_note="近 ${REDS_DAYS} 日 failure／cancelled run ${reds_runs} 個（實際涵蓋到 ${reds_oldest:-?}；本輪新下載 log ${reds_fetched} 個，上限 ${REDS_MAX_FETCH}${reds_budget_note}；快取 ${reds_cache_dir}）"
  fi
fi

# ---- Pencil 連線（LS-180）：有 design 分支 worktree（設計票在飛）時跑 scripts/ops/pen-status.sh——Pen 行程／目前路徑／
#      MCP socket 探針一行；探針非 0（Pen 沒開／路徑讀不到／mcp-server 與 Pen 之間沒有 socket 連線）就 add_flag，指示
#      orchestrator 派設計票前先請使用者在 Claude Code 執行 /mcp 重連 pencil。沒有 design worktree 不呼叫（探針會打
#      pen CLI，不必每輪付）。PATROL_PEN_STATUS_SH 可換假身（自測用，避免碰真的 Pen）。
PENCIL_LINE=; pencil_rc=0; pencil_ran=0
if [ "$design_wt" -eq 1 ]; then
  pencil_ran=1
  pssh="${PATROL_PEN_STATUS_SH:-${here}/pen-status.sh}"
  if [ -f "$pssh" ]; then
    PENCIL_LINE=$(bash "$pssh" 2>&1); pencil_rc=$?
  else
    PENCIL_LINE="Pencil：探針腳本不存在（${pssh}）"; pencil_rc=2
  fi
  if [ "$pencil_rc" -ne 0 ]; then
    add_flag "[Pencil] ${PENCIL_LINE} → 設計票派工前先請使用者在 Claude Code 執行 /mcp 重連 pencil，重連後再派（LS-180）"
  fi
fi

# ---- Pen 開錯檔偵測（實作票，LS-209）：Pen 目前開著的文件若落在某票的 worktree（`.claude/worktrees/LS-<n>/`）
#      且該票 lane 不是 design → 印 ⚠「Pen 開錯檔（實作票 LS-<n>）」——LS-188／LS-192 fork 動 Pen 越權編輯／把
#      Pen 切到實作票 worktree 的事後偵測（規則本身在 ios-dev.md 硬規則與 agent-tools-check.sh 的 tools: 白名單
#      擋，但那擋不住 orchestrator 派的 fork／general-purpose 子 agent 自帶完整工具集——這裡是巡檢層的第二道網）。
#      獨立於上面的「Pencil 連線」段（那段只在 design 分支 worktree 在飛時才跑，抓不到「根本沒有設計票、但 Pen
#      卻被實作票 agent 打開」這個情境——這正是本段存在的理由）。PATROL_PEN_STATUS_SH 可覆寫供自測餵假身（同上面
#      「Pencil 連線」段共用同一個 override，假身自己決定怎麼回應 `--path`）：`pen-status.sh --path` 內部自己會先
#      pgrep 確認 Pen 行程真的在跑（便宜）才呼叫 pen-open.sh --status（貴——會起 pen CLI 走 IPC），Pen 沒開就不查、
#      空輸出＋exit 1。lane 查詢走既有管道
#      patrol-linear.sh --lane（LS-96 池項 cf3707fa 指定「用既有的 Linear 查詢管道」）：查不到（無
#      LINEAR_API_KEY／查詢失敗）印 `?`、不擋（fail-open）——只有明確查到「不是 lane:design」（含查無此票／
#      無 lane 標籤）才 add_flag。
# PEN_WRONG_LINE 宣告特意放在下面的 LS209-PEN-WRONG 標記區塊之外——區塊本身是自測 mutation 拿掉驗證用（見
# patrol.test.sh ㉖），變數宣告若跟著被拿掉，`set -u` 下游任何 `[ -n "$PEN_WRONG_LINE" ]` 讀取都會炸「unbound
# variable」，這會讓 mutation 測到的是「腳本壞掉」而不是「這段偵測邏輯確實是負樣本變綠的原因」。
PEN_WRONG_LINE=
# LS209-PEN-WRONG-START
# LS-211 I-c（來源 LS-96 池項 edbc460c）：改讀 `pen-status.sh --path` 的機器可讀輸出，不再自己用 sed
# 依 PENCIL_LINE 的中文組合字串字面格式（「… · 路徑 <path> · …」）截路徑——那段措辭只要改一個字就會
# 靜默截不到值、退回舊路徑（pen_path 變空、這整段偵測 fail-open 不擋，卻沒有任何錯誤訊息），gate 自己
# 也驗不出這種退化。`--path` 是 pen-status.sh 自己的正式輸出契約（讀不到就是空輸出＋exit 1），比對它
# 的輸出格式改由 pen-status.sh 自己的自測負責，這裡不必再重寫一次解析邏輯。merge-review R1 m4 原本用
# 「沿用 PENCIL_LINE 解析結果」省下 design_wt=1 時的第二次 pen CLI IPC；改為一律呼叫 `--path`（成本
# 遠低於 pen-status.sh 全量檢查——不跑 mcp-server／lsof 交集，只多一次 pgrep＋pen-open.sh --status）
# 換取不依賴字面格式的穩定性，接受 design_wt=1 時多一次 IPC 的代價。
pssh2="${PATROL_PEN_STATUS_SH:-${here}/pen-status.sh}"
pen_path=
if [ -f "$pssh2" ]; then
  pen_path=$(bash "$pssh2" --path 2>/dev/null)
fi
pen_wt_ticket=$(printf '%s' "${pen_path:-}" | grep -oE '\.claude/worktrees/LS-[0-9]+' | grep -oE 'LS-[0-9]+' | head -1)
if [ -n "$pen_wt_ticket" ]; then
  plsh_lane="${PATROL_LINEAR_SH:-${here}/patrol-linear.sh}"
  pen_lane=; lane_rc=1
  if [ -x "$plsh_lane" ]; then
    pen_lane=$(bash "$plsh_lane" --lane "${pen_wt_ticket#LS-}" --repo "$ROOT" 2>/dev/null); lane_rc=$?
  fi
  if [ "$lane_rc" -ne 0 ]; then
    PEN_WRONG_LINE="Pen：目前開在 ${pen_wt_ticket} worktree，lane ?（查詢失敗，不擋）"
  elif [ "$pen_lane" != "lane:design" ]; then
    PEN_WRONG_LINE="⚠ Pen 開錯檔（實作票 ${pen_wt_ticket}）"
    add_flag "[Pen] 開錯檔（實作票 ${pen_wt_ticket}；lane=${pen_lane:-無}，非 lane:design——不得在實作票 worktree 開 Pen，見 ios-dev.md 硬規則）"
  fi
fi
# LS209-PEN-WRONG-END

# ---- 專屬模擬器（LS-83／LS-187）：detect-simulator.sh 建的 <票號>-<機型無空白> 用完不刪，由這段事後抓。
#      第一層（LS-187；使用者 2026-09-05 指出 4 台 Done 票殘機——Done 後 7 天內、皆 Shutdown——巡檢 20+ 輪沒抓）：每台
#      LS-<n>-* 看「票」——該票 worktree 已不在磁碟（git worktree list 沒有任何一筆「目錄存在且 basename 或分支整字含
#      LS-<n>」；整字比對同 cleanup-merged.sh matches_filter，LS-17 不中 LS-174），或 --linear 下 Linear 狀態 completed／
#      canceled（worktree 仍在；查詢走 patrol-linear.sh --closed，patrol.sh 自己仍不碰 token；缺 key／失敗只用 worktree
#      判定並在段末註明）→ ⚠＋動作行「→ bash scripts/ops/cleanup-merged.sh --apply LS-<n>」（(e) 段連刪專屬機＋DerivedData，
#      worktree 早已清也照清，LS-176／LS-187）。Booted 的不列刪、只印 ⓘ（LS-100 的 Booted 段管關機；關掉後下一輪自然落入
#      第一層）。第二層沿 LS-83：其餘（worktree 在、票未結案）與 main-* 一律 >7 天未用只列不刪＋印 simctl delete 指令，
#      交人判斷是否真的沒人在用；不在這裡自動砍（機型與 UDID 對不對得上人工判斷更保險）。
#      段末印 Xcode 預設機台數（名稱非 LS-<n>-／main-／demo-／qa- 開頭；未列入清理，修剪需使用者裁定）與
#      CoreSimulator/Devices 體積（du 快取，見磁碟水位段）。--brief 只帶旗標行與表頭台數。
#      無 xcrun（非 macOS、或這次 simctl 查詢本身失敗）就整段跳過，不當成異常（PR/worktree 段的 fail-soft 同款）。
#      simctl list devices -j 不用 jq 解析（patrol.sh 一貫不依賴 jq，只有測試驗證用它）：純文字 pretty-print
#      每個裝置物件一行一個 key，用 awk 以「單行 {／}」為物件邊界的簡易狀態機取五個欄位。
SIM_LINES=; J_SIM=; J_ORPHAN=; sim_flagged=0; sim_orphans=0; sim_default=0; sim_linear_note=; sim_rt_mismatch=0; sim_pinned_os=
BOOT_LINES=; J_BOOT=; boot_total=0; boot_flagged=0; boot_nonexempt=
plsh="${PATROL_LINEAR_SH:-${here}/patrol-linear.sh}"   # 可覆寫供自測餵假身（R1 F6；LS-187 --closed 也走這支）
WT_HAS_MEMO=   # LS-198（LS-187 R1 info-2）：ticket_has_worktree 一輪內每票只掃一次 WT_INDEX——每筆「\n<票號>\t<0|1>」，前置收票號與逐台判定各叫一次，30 台 LS-* 省約 1.2s
ticket_has_worktree() {  # $1＝LS-<n>；git worktree list 任一筆目錄存在、且 basename 或分支整字含該票號 → 0
  local p b hit=1
  case "$WT_HAS_MEMO" in   # 換行在前、tab 在後夾住票號：LS-3 不會命中 LS-30 的記錄、LS-40 不會命中 LS-4 的
    *$'\n'"${1}"$'\t'0*) return 0 ;;
    *$'\n'"${1}"$'\t'1*) return 1 ;;
  esac
  while IFS=$'\t' read -r p b; do
    [ -n "$p" ] && [ -d "$p" ] || continue   # 記錄在、目錄已刪（prunable）＝不在
    if printf '%s %s' "$(basename "$p")" "$b" | grep -qE "(^|[^0-9])${1}([^0-9]|\$)"; then hit=0; break; fi
  done <<EOF
$WT_INDEX
EOF
  WT_HAS_MEMO="${WT_HAS_MEMO}"$'\n'"${1}"$'\t'"${hit}"
  return "$hit"
}
closed_state_of() { printf '%s\n' "${SIM_CLOSED:-}" | awk -F'\t' -v t="$1" '$1 == t { print $2; exit }'; }  # $1＝LS-<n>；印 Done／Canceled 名稱或空
# LS-100：可注入 SIMCTL_LIST_JSON 直接餵合成 JSON（patrol.test.sh 用）；未設就照常呼叫真的 xcrun。
sim_raw="${SIMCTL_LIST_JSON:-$(xcrun simctl list devices -j 2>/dev/null)}" || sim_raw=
if [ -n "$sim_raw" ]; then
  # LS-205：`simctl list devices -j` 把裝置依 runtime 分組（頂層 key＝
  # `"com.apple.CoreSimulator.SimRuntime.iOS-26-5"`，不是逐台裝置的欄位）——多加一條規則抓這個 key、
  # 換算成人類看的版本號（同 detect-simulator.sh 的 iOS-26-5 → 26.5 換算），掛在 rt（第六欄）跟著
  # 該分組底下每一台裝置一起印出；換組才更新，同組多台裝置沿用同一個 rt，不用每次都重算。
  sim_rows=$(printf '%s\n' "$sim_raw" | awk '
    { t = $0; sub(/^[ \t]*/, "", t); sub(/[ \t]*$/, "", t) }
    t ~ /^"com\.apple\.CoreSimulator\.SimRuntime\./ {
      rt = t
      sub(/^"/, "", rt); sub(/".*/, "", rt)
      sub(/^.*SimRuntime\.iOS-/, "", rt)
      gsub(/-/, ".", rt)
      cur_rt = rt
      next
    }
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
        # 後面的 state 就被吞掉、往前遞補到 dpath 的位置）——lastBootedAt／dataPath／state／rt 缺欄位一律
        # 改印 "-" 佔位，不留空欄位。
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", name, udid, (last == "" ? "-" : last), (dpath == "" ? "-" : dpath), (state == "" ? "-" : state), (cur_rt == "" ? "-" : cur_rt)
        name=""; udid=""; last=""; dpath=""; state=""
      }
    }
  ')
  # ---- Booted 模擬器（LS-100）：任何時候不該有 >1 台非 demo-* 的模擬器同時 Booted（用完忘記關）；
  #      demo-* 開頭的名稱豁免（demo worktree 的持久機，見 docs/COLLABORATION.md）。共用上面同一份
  #      sim_rows（同一次 xcrun 呼叫），不再多打一次。
  while IFS=$'\t' read -r boot_name boot_udid _boot_last _boot_dpath boot_state _boot_rt; do
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
  # LS-187 第一層前置：票 worktree 仍在的 LS-<n> 收成一串票號，--linear 時一次問 patrol-linear.sh --closed 哪些已結案
  # （worktree 已不在的不必問，直接是殘機）。
  sim_query_nums=; SIM_CLOSED=
  while IFS=$'\t' read -r sim_name _ _ _ _ _; do
    case "$sim_name" in LS-[0-9]*-*) ;; *) continue ;; esac
    sim_t=${sim_name#LS-}; sim_t=${sim_t%%-*}
    ticket_has_worktree "LS-${sim_t}" || continue
    case ",${sim_query_nums}," in *",${sim_t},"*) ;; *) sim_query_nums="${sim_query_nums:+${sim_query_nums},}${sim_t}" ;; esac
  done <<EOF
$sim_rows
EOF
  if [ -n "$sim_query_nums" ]; then
    if [ "$DO_LINEAR" -ne 1 ]; then sim_linear_note="票狀態未查（未帶 --linear），只用 worktree 判定"
    elif [ ! -x "$plsh" ]; then sim_linear_note="找不到 ${plsh}，票狀態未查、只用 worktree 判定"
    else
      SIM_CLOSED=$(bash "$plsh" --closed "$sim_query_nums" --repo "$ROOT" 2>/dev/null); sim_closed_rc=$?
      case "$sim_closed_rc" in
        0) sim_linear_note="票狀態已查 Linear（LS-${sim_query_nums//,/、LS-}）" ;;
        3) SIM_CLOSED=; sim_linear_note="無 LINEAR_API_KEY，票狀態未查、只用 worktree 判定" ;;
        *) SIM_CLOSED=; sim_linear_note="Linear 票狀態查詢失敗（patrol-linear.sh --closed exit ${sim_closed_rc}），只用 worktree 判定" ;;
      esac
    fi
  fi
  # LS-205：`.ios-runtime` 釘住版——專屬機（LS-<n>-*／main-*）runtime 跟這個不一樣就標 ⚠ runtime，
  # 獨立於下面第一層／第二層清理判斷之外（機器可能完全「健康」——票還在飛、7 天內用過——但釘的 runtime
  # 早就跟 CI 不一樣了，既有兩層清理邏輯看不到這個訊號）。缺這個檔就整段跳過，不當異常（過渡期／自測沿用）。
  sim_pinned_os=
  [ -f "${ROOT}/.ios-runtime" ] && sim_pinned_os=$(tr -d '[:space:]' < "${ROOT}/.ios-runtime")
  while IFS=$'\t' read -r sim_name sim_udid sim_last sim_dpath sim_state sim_rt; do
    [ -n "$sim_name" ] || continue
    sim_ticket=
    case "$sim_name" in
      LS-[0-9]*-*) sim_ticket=${sim_name#LS-}; sim_ticket="LS-${sim_ticket%%-*}" ;;
      main-*) ;;                # 主 checkout 專屬機：沒有票可看，只走第二層
      demo-*|qa-*) continue ;;  # demo 常駐機（LS-100 豁免）／qa 驗收機：不是這段管轄
      *) sim_default=$((sim_default + 1)); continue ;;   # Xcode 預設機：只計數，不列入清理（修剪需使用者裁定）
    esac
    if [ -n "$sim_pinned_os" ] && [ -n "$sim_rt" ] && [ "$sim_rt" != - ] && [ "$sim_rt" != "$sim_pinned_os" ]; then
      # merge-review R1 M1：這一類不進 `sim_flagged`（「待清」語意——LS-83／LS-187 既有兩層清理判斷
      # 用的計數器，`patrol.test.sh` ⑭ 明文斷言那個數字）、也不叫 `add_flag`（`add_flag` 同時餵
      # `--brief`「巡檢：無異常」的判定與 flag 清單——併入後本機受管機幾乎必然 ≠ 釘住版，會讓「無異常」
      # 永久消失、且不可行動：本機沒有那個 runtime 就是沒有，不會因為巡檢再吐一次而改變）。獨立計數
      # `sim_rt_mismatch`，只進 `SIM_LINES`（一律印出的細項）與下面的彙總數字，不影響「有無異常」。
      sim_rt_mismatch=$((sim_rt_mismatch + 1))
      SIM_LINES="${SIM_LINES}  ⚠ runtime ${sim_name}（${sim_udid}）iOS ${sim_rt} ≠ 釘住版 iOS ${sim_pinned_os}（提示不擋，不計入待清）"$'\n'
      # LS-260（LS-96 池項 `1b7a0d5d`；orchestrator 09-14 裁決）：**在飛票**（worktree 仍在）的專屬機
      # 另外進旗標行——LS-246 的一小時就花在「CI 紅、本機重現不出」，而 runtime 差異只寫在一律印出的
      # 細項裡，orchestrator 派工時看不到。語意仍是「提示不擋」（patrol 本來就恆 exit 0、這裡也不計入
      # `sim_flagged` 待清），只是讓它出現在 `--brief` 的 flag 清單上、附上該怎麼用這個訊號。
      # worktree 已不在的（殘機）不掛：那台的可行動原因是 cleanup，runtime 差沒有任何人會去處理。
      if [ -n "$sim_ticket" ] && ticket_has_worktree "$sim_ticket"; then
        add_flag "[專屬模擬器 ${sim_name}] runtime iOS ${sim_rt} ≠ 釘住版 iOS ${sim_pinned_os}（${sim_ticket} 在飛中）——提示不擋；若 CI 紅而本機重現不出，先懷疑 runtime 差（LS-260）"
      fi
    fi
    if [ -n "$sim_ticket" ]; then
      sim_why=; sim_reason=
      if ! ticket_has_worktree "$sim_ticket"; then
        sim_reason=no_worktree; sim_why="票 ${sim_ticket} 的 worktree 已不在（殘機）"
      else
        sim_closed_name=$(closed_state_of "$sim_ticket")
        [ -n "$sim_closed_name" ] && { sim_reason=ticket_closed; sim_why="票 ${sim_ticket} 已 ${sim_closed_name}（worktree 仍在）"; }
      fi
      if [ -n "$sim_reason" ]; then
        if [ "$sim_state" = Booted ]; then
          SIM_LINES="${SIM_LINES}  ⓘ ${sim_name}（${sim_udid}）${sim_why}，但 Booted 不列刪（LS-100：Booted 段管關機，關掉後下一輪再清）"$'\n'
          continue
        fi
        sim_orphans=$((sim_orphans + 1)); sim_flagged=$((sim_flagged + 1))
        J_ORPHAN="${J_ORPHAN:+${J_ORPHAN},}{\"name\":$(json_str "$sim_name"),\"udid\":$(json_str "$sim_udid"),\"ticket\":$(json_str "$sim_ticket"),\"reason\":$(json_str "$sim_reason"),\"state\":$(json_str "$sim_state")}"
        SIM_LINES="${SIM_LINES}  ⚠ ${sim_name}（${sim_udid}）${sim_why} → bash scripts/ops/cleanup-merged.sh --apply ${sim_ticket}"$'\n'
        add_flag "[專屬模擬器 ${sim_name}] ${sim_why} → bash scripts/ops/cleanup-merged.sh --apply ${sim_ticket}"
        continue
      fi
    fi
    # 第二層（LS-83）：>7 天未用
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

# ---- 磁碟水位（LS-176；LS-96 池項 7c9fe5bd／0e75271d：Devices 146 GB／77 台＋每 worktree 一份 DerivedData 兩次把磁碟
#      填滿、Docker VM 弄掛）：df 可用 <DISK_MIN_GB GB 印 ⚠ 並列 CoreSimulator/Devices／DerivedData 體積（du，看門狗）與
#      LS-* 專屬模擬器台數（從上面同一份 sim_rows 算，不再多打一次 xcrun）；處置指到 cleanup-merged.sh --apply LS-<n>
#      （LS-176 起連刪該票專屬機＋DerivedData）。df 讀不到就整段只印「略過」（同 xcrun 缺席的 fail-soft）；兩個目錄可用
#      PATROL_SIM_DEVICES_DIR／PATROL_DERIVED_DATA_DIR 覆寫（自測餵小假目錄，不對真的 ~/Library 跑 du）。
#      LS-187：Devices 體積改為每輪都要（專屬模擬器段末尾印），走檔頭的 du 快取（$du_cache／DU_CACHE_MIN）；水位段觸發時
#      沿用同一個值、只另量 DerivedData，不重複 du Devices。
disk_avail_gb=; disk_flag=; disk_devices_gb=; disk_derived_gb=; disk_dedicated=0; devices_du_src=
sim_devices_dir="${PATROL_SIM_DEVICES_DIR:-$HOME/Library/Developer/CoreSimulator/Devices}"
derived_data_dir="${PATROL_DERIVED_DATA_DIR:-$HOME/Library/Developer/Xcode/DerivedData}"
disk_avail_kb=$(df -Pk "$HOME" 2>/dev/null | awk 'NR == 2 { print $4 }')
case "$disk_avail_kb" in ''|*[!0-9]*) ;; *) disk_avail_gb=$((disk_avail_kb / 1048576)) ;; esac
if [ -n "${sim_rows:-}" ]; then
  disk_dedicated=$(printf '%s\n' "$sim_rows" | awk -F'\t' '$1 ~ /^LS-[0-9]+-/ { n++ } END { print n + 0 }')
fi
du_with_timeout() {  # $@＝路徑；stdout 印 du -sk 各路徑一行（<KB>\t<路徑>）；exit 124＝逾時（背景 du 被 kill，同 fetch_with_timeout）
  (
    du -sk "$@" 2>/dev/null &
    dpid=$!
    ( sleep "$DU_TIMEOUT"; kill "$dpid" 2>/dev/null ) >/dev/null 2>&1 &
    wpid=$!
    wait "$dpid"; rc=$?
    kill "$wpid" 2>/dev/null
    [ "$rc" -eq 143 ] && exit 124
    exit "$rc"
  ) 2>/dev/null
}
size_gb_of() {  # $1＝路徑；從 $du_out 取該路徑的整數 GB，取不到（目錄不存在／du 逾時）印 ?
  local kb
  kb=$(printf '%s\n' "${du_out:-}" | awk -F'\t' -v p="$1" '$2 == p { print $1; exit }')
  case "$kb" in ''|*[!0-9]*) printf '?' ;; *) printf '%s' $((kb / 1048576)) ;; esac
}
disk_low=0
if [ -n "$disk_avail_gb" ] && [ "$disk_avail_gb" -lt "$DISK_MIN_GB" ]; then disk_low=1; fi
# LS-187：Devices 體積先看快取（一行「<epoch>\t<路徑>\t<KB>」；路徑不同＝自測換了假目錄，不沿用）
devices_kb=
if [ -f "$du_cache" ]; then
  IFS=$'\t' read -r c_epoch c_path c_kb < "$du_cache" || true
  case "${c_epoch:-x}${c_kb:-x}" in
    *[!0-9]*) ;;
    *) if [ "$c_path" = "$sim_devices_dir" ] && [ $(( (now - c_epoch) / 60 )) -lt "$DU_CACHE_MIN" ]; then
         devices_kb=$c_kb; devices_du_src="du 快取 $(( (now - c_epoch) / 60 ))m 前"
       fi ;;
  esac
fi
need_devices_du=0
if [ -z "$devices_kb" ] && [ -d "$sim_devices_dir" ]; then
  # 沒快取：human／--json 現量；--brief 只在低水位才量（LS-176 原行為），否則印 ?
  if [ "$MODE" != brief ] || [ "$disk_low" -eq 1 ]; then need_devices_du=1; fi
fi
set --   # 位置參數早已被上面的參數迴圈 shift 光，這裡借來當「要量的目錄清單」（bash 3.2，不用陣列）
[ "$need_devices_du" -eq 1 ] && set -- "$@" "$sim_devices_dir"
[ "$disk_low" -eq 1 ] && [ -d "$derived_data_dir" ] && set -- "$@" "$derived_data_dir"
du_out=; du_rc=0
if [ $# -gt 0 ]; then du_out=$(du_with_timeout "$@"); du_rc=$?; fi
if [ -z "$devices_kb" ]; then
  if [ ! -d "$sim_devices_dir" ]; then devices_du_src="目錄不存在 ${sim_devices_dir}"
  elif [ "$need_devices_du" -eq 0 ]; then devices_du_src="brief 不量、無快取"
  else
    devices_kb=$(printf '%s\n' "${du_out:-}" | awk -F'\t' -v p="$sim_devices_dir" '$2 == p { print $1; exit }')
    case "$devices_kb" in
      ''|*[!0-9]*) devices_kb=; if [ "$du_rc" -eq 124 ]; then devices_du_src="du >${DU_TIMEOUT}s 逾時"; else devices_du_src="du 失敗"; fi ;;
      *) devices_du_src="du 剛量"
         # LS-198（LS-187 R1 info-3）：先寫同目錄暫存檔再 mv 覆蓋（rename 原子）——cron human 與 SessionStart --brief 併發時讀者不會讀到半行；失敗一律靜默（快取只是省時間）
         du_tmp="${du_cache}.tmp.$$"
         if printf '%s\t%s\t%s\n' "$now" "$sim_devices_dir" "$devices_kb" > "$du_tmp" 2>/dev/null; then mv -f "$du_tmp" "$du_cache" 2>/dev/null || rm -f "$du_tmp"; else rm -f "$du_tmp"; fi ;;
    esac
  fi
fi
[ -n "$devices_kb" ] && disk_devices_gb=$((devices_kb / 1048576))
if [ "$disk_low" -eq 1 ]; then
  disk_derived_gb=$(size_gb_of "$derived_data_dir")
  du_note=; [ "$du_rc" -eq 124 ] && du_note="（du >${DU_TIMEOUT}s 逾時，體積為 ?）"
  disk_flag="⚠ 磁碟可用 ${disk_avail_gb} GB < ${DISK_MIN_GB} GB：CoreSimulator/Devices ${disk_devices_gb:-?} GB、DerivedData ${disk_derived_gb} GB、LS-* 專屬模擬器 ${disk_dedicated} 台${du_note} → 對 Done 票跑 bash scripts/ops/cleanup-merged.sh --apply LS-<n>（LS-176 起連刪該票專屬機＋DerivedData）"
  add_flag "[磁碟] ${disk_flag}"
fi

# ---- --linear（LS-103）：先把 patrol-linear.sh 跑完，rc 才能影響下面的「異常」判定 ----
# R1 F6：不可讓 patrol-linear.sh 非 0 exit 被吞掉——舊版放在輸出區塊「之後」才呼叫，brief 模式的
# 「巡檢：無異常」摘要行早就印完，Linear 段失敗（PAT 過期／curl 錯誤）在 stdout 完全看不到、只有
# stderr 一行。改成提前執行、把輸出與 rc 存起來：非 0 就併入 add_flag（跟其他停滯型態同一套機制，
# 讓 FLAGS／J_FLAGS 反映出來，brief 的「無異常」行才不會誤判）；輸出區塊之後只印已經拿到的內容，
# 不重跑（避免呼叫兩次 patrol-linear.sh，它內部還會再呼叫一次 patrol.sh 取 Booted 模擬器段，成本加倍）。
linear_out=; linear_rc=0; linear_ran=0
# plsh（PATROL_LINEAR_SH 可覆寫供自測餵假身模擬非 0 exit，R1 F6）自 LS-187 起在專屬模擬器段前就定義（--closed 也走它）
if [ "$DO_LINEAR" -eq 1 ] && [ "$MODE" != json ]; then
  linear_ran=1
  if [ -x "$plsh" ]; then
    if [ "$MODE" = brief ]; then
      linear_out=$(bash "$plsh" --brief --repo "$ROOT" 2>&1)
    else
      linear_out=$(bash "$plsh" --repo "$ROOT" 2>&1)
    fi
    linear_rc=$?
  else
    linear_out="⚠ patrol：--linear 但找不到 ${plsh}"
    linear_rc=1
  fi
  if [ "$linear_rc" -ne 0 ]; then
    add_flag "[Linear] 段失敗（exit ${linear_rc}）"
  fi
fi

# ---- 輸出 ----
stamp=$(date '+%Y-%m-%d %H:%M')
case "$MODE" in
  json)
    printf '{"generated_at":%s,"stamp":%s,"stale_minutes":%s,"root":%s,"fetched":%s,"fetch_warning":%s,"main_checkout":{"branch":%s,"behind_origin_main":%s,"dirty":%s,"flag":%s},"hooks":{"path":%s,"flag":%s},"branches":{"development_behind_main":%s,"test_behind_main":%s,"test_behind_development":%s,"test_not_in_development":%s,"main_ahead_minutes":%s,"drift":%s},"prs_skipped":%s,"prs":[%s],"worktrees":[%s],"supabase_lock":%s,"supabase_containers":%s,"supabase_start_skew_minutes":%s,"hold_label":%s,"hold_expires_at":%s,"lock_waiters":%s,"lock_waiters_max_minutes":%s,"stale_simulators":[%s],"orphan_simulators":[%s],"sim_linear_note":%s,"default_simulators":%s,"rt_mismatch_simulators":%s,"booted_simulators":[%s],"booted_flagged":%s,"disk":{"avail_gb":%s,"min_gb":%s,"devices_gb":%s,"derived_data_gb":%s,"dedicated_simulators":%s,"flag":%s},"pencil":{"ran":%s,"line":%s,"rc":%s},"repeat_failures":[%s],"flags":[%s]}\n' \
      "$now" "$(json_str "$stamp")" "$STALE" "$(json_str "$ROOT")" "$FETCHED" "$([ -n "$fetch_warn" ] && json_str "$fetch_warn" || printf null)" \
      "$(json_str "$mc_branch")" "$(json_num "$mc_behind")" "$mc_dirty" "$(json_str "$mc_flag")" \
      "$(json_str "$hooks_path")" "$(json_str "$hooks_flag")" \
      "$(json_num "$dev_main")" "$(json_num "$test_main")" "$(json_num "$test_dev")" "$(json_num "$dev_test")" "$(json_num "$main_ahead_m")" "$(json_str "$drift_flag")" \
      "$([ -n "$pr_skip" ] && json_str "$pr_skip" || printf null)" "$J_PRS" "$J_WTS" "$(json_str "$lock_line")" "$(json_num "$supa_containers")" "$(json_num "$supa_skew_m")" "$([ -n "$hold_label" ] && json_str "$hold_label" || printf null)" "$(json_num "$hold_expires")" "$(json_num "$lock_waiters")" "$(json_num "$lock_waiters_max_min")" "$J_SIM" "$J_ORPHAN" "$([ -n "$sim_linear_note" ] && json_str "$sim_linear_note" || printf null)" "$sim_default" "$(json_num "$sim_rt_mismatch")" "$J_BOOT" "$(json_num "$boot_flagged")" \
      "$(json_num "$disk_avail_gb")" "$DISK_MIN_GB" "$(json_num "$disk_devices_gb")" "$(json_num "$disk_derived_gb")" "$disk_dedicated" "$(json_str "$disk_flag")" \
      "$([ "$pencil_ran" -eq 1 ] && printf true || printf false)" "$([ -n "$PENCIL_LINE" ] && json_str "$PENCIL_LINE" || printf null)" "$(json_num "$pencil_rc")" "$J_REDS" "$J_FLAGS"
    ;;
  brief)
    sim_rt_note=; [ "$sim_rt_mismatch" -gt 0 ] && sim_rt_note="（釘住 iOS ${sim_pinned_os}，提示不擋）"
    echo "巡檢 ${stamp}（stale ≥${STALE}m）：PR ${pr_total}／異常 ${pr_flagged}${pr_skip:+（略過：${pr_skip}）} · worktree ${wt_total}／異常 ${wt_flagged} · 主 checkout ${mc_branch}（落後 origin/main ${mc_behind}） · dev←main ${dev_main} test←main ${test_main} test←dev ${test_dev} · 專屬模擬器待清 ${sim_flagged}（殘機 ${sim_orphans}） · runtime 不一致 ${sim_rt_mismatch}${sim_rt_note} · Booted 異常 ${boot_flagged} · 磁碟可用 ${disk_avail_gb:-?} GB"
    [ -n "$fetch_warn" ] && echo "${fetch_warn}"
    case "$lock_line" in free) ;; *) echo "Supabase lock：${lock_line}" ;; esac
    [ -n "$lock_queue_flag" ] && echo "Supabase lock：${lock_queue_flag}——持有者「${hold_label}」剩餘 ${lock_hold_remain_min} 分"
    [ "$pencil_ran" -eq 1 ] && printf '%s\n' "$PENCIL_LINE"
    [ -n "$PEN_WRONG_LINE" ] && printf '%s\n' "$PEN_WRONG_LINE"
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
    echo "== 螢幕鎖定（LS-220；鎖定中會讓模擬器 Keychain 回 -34018，長得像 QA e2e 逾時失敗，§4-b 排障順序 (b)）"
    echo "  ${screen_lock_flag:-ok}"
    echo "== worktree（local vs remote／未 push／dirty 停滯；base＝hotfix→origin/main、其餘→origin/development）"
    if [ -n "$WT_LINES" ]; then printf '%s' "$WT_LINES"; else echo "  （無）"; fi
    echo "== Supabase lock（本機容器序列化，scripts/ops/supabase-lock.sh；LS-70；⚠ tomb＝上次回收異常的殘留；持有者剩餘 >10 分且有等待者才會另印排隊提示，LS-207）"
    printf '%s\n' "$lock_line" | sed 's/^/  /'
    [ -n "$lock_queue_flag" ] && echo "  ${lock_queue_flag}——持有者「${hold_label}」剩餘 ${lock_hold_remain_min} 分"
    echo "== Supabase 容器啟動時間（LS-260／LS-264；先依 StartedAt 分批（視窗起點取 supabase-lock hold.log 的最近一次取鎖，取不到才退回固定秒數），最新一批若不是 db reset 的群組、且 rest／kong／db／auth 之間差 >${SUPA_SKEW_MIN} 分＝有人單獨重啟過某台；形狀是 db reset 時改比群組內差，LS-246）"
    echo "  ${SUPA_LINE}"
    echo "== 近 ${REDS_DAYS} 日 CI 同類紅（LS-260；失敗測試名／失敗型別跨 run 聚合，同簽章 ≥2 個 run 即 ⚠ → §5-b 升 High）"
    [ -n "$reds_note" ] && echo "  ${reds_note}"
    if [ -n "$REDS_LINES" ]; then printf '%s' "$REDS_LINES"; else echo "  （無同簽章重複 ≥2 次的紅）"; fi
    echo "== Pencil 連線（LS-180；有 design 分支 worktree 時探：行程／目前路徑／MCP socket；✗ 先請使用者 /mcp 重連 pencil 再派設計票）"
    if [ "$pencil_ran" -eq 1 ]; then
      printf '%s\n' "$PENCIL_LINE" | sed 's/^/  /'
      [ "$pencil_rc" -ne 0 ] && echo "  → 設計票派工前先請使用者在 Claude Code 執行 /mcp 重連 pencil，重連後再派（LS-180）"
    else echo "  （無 design 分支 worktree，略過探針）"; fi
    echo "== Pen 開錯檔偵測（LS-209；Pen 目前文件若落在非 design lane 的票 worktree → ⚠，查不到 lane 印 ?、不擋）"
    if [ -n "$PEN_WRONG_LINE" ]; then echo "  ${PEN_WRONG_LINE}"; else echo "  （Pen 未開，或未開在任何票 worktree，或該票 lane 為 design）"; fi
    echo "== 專屬模擬器（scripts/gates/detect-simulator.sh 建的 <票號>-<機型>；LS-83／LS-187：票 worktree 已不在或已 Done／Canceled ⚠→cleanup-merged；其餘 >7 天未用只列不刪；Booted 不列刪；LS-205：runtime 與 .ios-runtime 不一致標 ⚠ runtime，獨立計數、不計入待清、不自動重建，merge-review R1 M1）"
    if [ -n "$SIM_LINES" ]; then printf '%s' "$SIM_LINES"; else echo "  （無 xcrun，或無殘機／逾期的專屬模擬器）"; fi
    if [ -n "${sim_rows:-}" ]; then
      sim_rt_note=; [ "$sim_rt_mismatch" -gt 0 ] && sim_rt_note="（釘住 iOS ${sim_pinned_os}，提示不擋）"
      echo "  Xcode 預設模擬器 ${sim_default} 台（未列入清理；修剪需使用者裁定） · runtime 不一致 ${sim_rt_mismatch}${sim_rt_note} · CoreSimulator/Devices ${disk_devices_gb:-?} GB（${devices_du_src:-無資料}）${sim_linear_note:+ · ${sim_linear_note}}"
    fi
    echo "== Booted 模擬器（LS-100；demo-* 豁免；>1 台非豁免同時 Booted＝用完沒關）"
    if [ -n "$BOOT_LINES" ]; then printf '%s' "$BOOT_LINES"; else echo "  （無異常；Booted ${boot_total} 台，非 demo-* ${nonexempt_boot_count} 台）"; fi
    echo "== 磁碟水位（LS-176；可用 <${DISK_MIN_GB} GB 標 ⚠ 並列 Devices／DerivedData 體積；PATROL_DISK_MIN_GB 可調）"
    if [ -n "$disk_flag" ]; then echo "  ${disk_flag}"
    elif [ -n "$disk_avail_gb" ]; then echo "  可用 ${disk_avail_gb} GB，LS-* 專屬模擬器 ${disk_dedicated} 台  ok"
    else echo "  （df 讀不到可用空間，略過）"; fi
    echo "== Linear（需 orchestrator 用 MCP 對照：Ready 無人接／In Progress 無 worktree／QA 但 test 未含）"
    echo "  → list_issues state in (Ready, In Progress, In Review, QA)，對照上表 worktree／PR"
    ;;
esac

# ---- --linear 輸出（內容已在上面跑好；--json 維持原提示，不合併，見檔頭）----
if [ "$DO_LINEAR" -eq 1 ]; then
  if [ "$MODE" = json ]; then
    echo "⚠ patrol：--linear 與 --json 不支援合併（Linear 半段是獨立 JSON 物件）→ 另跑 bash scripts/ops/patrol-linear.sh --json" >&2
  elif [ "$linear_ran" -eq 1 ]; then
    echo
    printf '%s\n' "$linear_out"
    [ "$linear_rc" -ne 0 ] && echo "⚠ Linear 半段失敗（exit ${linear_rc}）——見上方輸出／stderr"
  fi
fi
exit 0
