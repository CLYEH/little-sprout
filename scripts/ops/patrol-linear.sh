#!/bin/bash
# 巡檢的 Linear 半段機械化（LS-103）：用 .env 的 LINEAR_API_KEY 直接打 Linear GraphQL（team LS，
# teamId 020782d9-b525-46e1-8805-965cff30d7d2），把 docs/COLLABORATION.md §4-b 巡檢 cron 模板第 2–5
# 步（狀態對照、cycle 對帳 (a)-(d)、lane 補位候補、開票結構 (a)-(e)）算出來，印出 orchestrator 只需
# 逐行執行的「動作清單」（→ 開頭）。§5-b 的 lane 上限機械化：patrol.sh 本身沒有 Linear token，這支
# 補上那半邊（§4-b／§5-b「巡檢承載」欄同步改「✅」）。
#
# 實際查詢／排序／cycle 對帳邏輯在 scripts/ops/patrol_linear.py（同 api-contract-check.sh／
# api_contract_check.py 的分工：bash 只管環境與串接，重邏輯在 python）。Booted 模擬器段直接沿用
# patrol.sh（同一份已測過的 xcrun/simctl 邏輯，不重造輪子）：呼叫 patrol.sh --brief --no-pr
# --no-fetch，抓「[Booted 模擬器 …]」開頭的旗標行轉交 python 排版。
#
# 用法：patrol-linear.sh [--json|--brief|--closed <n,n,…>] [--repo <path>]
#   （預設）human 模式，印五段：狀態對照／cycle 對帳／lane 補位＋候補＋動作清單／開票結構／Booted 模擬器
#   --brief  只印動作清單（hook／cron 摘要用）
#   --json   單一 JSON 物件給程式讀
#   --closed <n,n,…>  （LS-187）只回答「這些票號哪些已 Done／Canceled」：每行「LS-<n>\t<state.name>」、無者印空，
#            不跑整份報表、**不回頭呼叫 patrol.sh**（patrol.sh --linear 的專屬模擬器段從這裡進來，回頭呼叫會遞迴）。
#            exit 0＝查過；3＝缺 LINEAR_API_KEY 略過（呼叫端退回只用 worktree 判定）；2＝票號格式錯；1＝查詢失敗。
#   --repo   指定 repo（任一 worktree 路徑皆可；預設取腳本所在 repo，ROOT 解到主 checkout）
#
# .env 只認 key 名、source 注入、不印不寫檔（docs/COLLABORATION.md §6／§7 H2）。缺
# LINEAR_API_KEY（.env 未設或本身缺檔）→ 印「略過（無 LINEAR_API_KEY）」、exit 0（--closed 為 exit 3），不炸——這是
# 已知盲區（token 缺時退回人工，見票文與 §4-b 對照表新增列）。
#
# 自測：scripts/ops/patrol-linear.test.sh（PATH 前置假 curl 回固定 GraphQL JSON fixture，不打真
# API）掛 CI rules job（LS-103）。CI 沒有 LINEAR_API_KEY，這支腳本本身在 CI 只會印「略過」，真正
# 驗證的是自測腳本（餵假 token＋假 curl）。
set -uo pipefail

MODE=human; REPO=; CLOSED_NUMS=
while [ $# -gt 0 ]; do
  case "$1" in
    --brief) MODE=brief ;;
    --json) MODE=json ;;
    --closed)
      [ -n "${2:-}" ] || { echo "✗ patrol-linear：--closed 缺值" >&2; exit 2; }
      case "$2" in *[!0-9,]*|,*|*,|*,,*|'') echo "✗ patrol-linear：--closed 須為逗號分隔的票號數字（得到「$2」）" >&2; exit 2 ;; esac
      MODE=closed; CLOSED_NUMS=$2; shift ;;
    --repo)
      [ -n "${2:-}" ] || { echo "✗ patrol-linear：--repo 缺值" >&2; exit 2; }
      REPO=$2; shift ;;
    -h|--help)
      echo "用法：patrol-linear.sh [--json|--brief|--closed <n,n,…>] [--repo <path>]（說明見檔頭）"; exit 0 ;;
    *) echo "✗ patrol-linear：未知參數 $1" >&2; exit 2 ;;
  esac
  shift
done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -n "$REPO" ] || REPO="$(cd "${here}/../.." && pwd)"
[ -d "$REPO" ] || { echo "✗ patrol-linear：找不到 repo 目錄 ${REPO}" >&2; exit 2; }
common=$(git -C "$REPO" rev-parse --git-common-dir 2>/dev/null) || { echo "✗ patrol-linear：${REPO} 不是 git repo" >&2; exit 2; }
case "$common" in /*) ;; *) common="${REPO}/${common}" ;; esac
ROOT=$(cd "$(dirname "$common")" && pwd)

# .env 在主 checkout 根（跨 worktree 共用，同 patrol.sh 的 ROOT 解法），不是每個 worktree 各一份。
# R1 F4：不用 set -a——那會把 .env 裡「全部」key（本機實測含 Supabase DB 密碼／access token／Figma PAT
# 等與本功能無關的 secret）export 進之後所有子程序（patrol.sh／git／xcrun／python3／curl）。只需要
# LINEAR_API_KEY，下面已明確 export 那一個。
if [ -f "${ROOT}/.env" ]; then
  # shellcheck disable=SC1091
  source "${ROOT}/.env"
fi

if [ -z "${LINEAR_API_KEY:-}" ]; then
  case "$MODE" in
    json) echo '{"skipped":true,"reason":"no LINEAR_API_KEY"}' ;;
    closed) echo "巡檢（Linear 半段）：--closed 略過（無 LINEAR_API_KEY）——${ROOT}/.env 補上後才會查票狀態" >&2; exit 3 ;;
    *) echo "巡檢（Linear 半段）：略過（無 LINEAR_API_KEY）——${ROOT}/.env 補上後才會打 GraphQL，見 docs/COLLABORATION.md §7" ;;
  esac
  exit 0
fi

command -v python3 >/dev/null 2>&1 || { echo "✗ patrol-linear：需要 python3" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "✗ patrol-linear：需要 curl" >&2; exit 1; }

# ---- --closed（LS-187）：只查票狀態就走，不碰 patrol.sh（它正是呼叫端，回頭呼叫會遞迴）----
if [ "$MODE" = closed ]; then
  export LINEAR_API_KEY
  python3 "${here}/patrol_linear.py" \
    --root "$ROOT" --team-key LS --team-id 020782d9-b525-46e1-8805-965cff30d7d2 \
    --closed "$CLOSED_NUMS"
  exit $?
fi

# ---- Booted 模擬器段沿用 patrol.sh：抓 --brief 輸出裡「[Booted 模擬器 …]」開頭的旗標行 ----
sim_lines_file=$(mktemp "${TMPDIR:-/tmp}/patrol-linear-sim.XXXXXX") || { echo "✗ patrol-linear：mktemp 失敗" >&2; exit 2; }
# R1 I5：trap 也要清 .raw——原本只清 base 檔，中途被中斷（patrol.sh 那段卡住／收到訊號）會把
# 這個暫存檔留在 TMPDIR。
trap 'rm -f "$sim_lines_file" "${sim_lines_file}.raw"' EXIT
if [ -x "${here}/patrol.sh" ]; then
  bash "${here}/patrol.sh" --brief --no-pr --no-fetch --repo "$ROOT" 2>/dev/null > "${sim_lines_file}.raw" || true
  while IFS= read -r line; do
    case "$line" in
      "[Booted 模擬器"*) printf '%s\n' "$line" >> "$sim_lines_file" ;;
    esac
  done < "${sim_lines_file}.raw"
  rm -f "${sim_lines_file}.raw"
fi

export LINEAR_API_KEY
python3 "${here}/patrol_linear.py" \
  --root "$ROOT" --team-key LS --team-id 020782d9-b525-46e1-8805-965cff30d7d2 \
  --mode "$MODE" --sim-lines-file "$sim_lines_file"
rc=$?
exit "$rc"
