#!/bin/bash
# QA 端到端情境驅動（LS-158）：不依賴 mobile-mcp，用 `LittleSproutUITests/QA/QASmokeTests`（XCUITest）
# 對本機 Supabase 容器實跑「登入／發佈／瀏覽」三條多步驟路徑，截圖與 Storage log 落地成驗收證據。
#
# 來源：LS-129／130 QA（`4cb41a06`／`d731c417`）BLOCKED——mobile-mcp 每次互動把模擬器前景重設回主畫面，
# 多步驟操作做不了；同一 build 用 `xcodebuild test -only-testing:LittleSproutUITests` 可正常驅動。
#
# 用法：qa-e2e.sh <login|publish|browse> [--sim <模擬器名>] [--ticket LS-<n>] [--email <收件信箱>]
#   login    歡迎頁 → Email → Mailpit 取 6 碼 → 確認登入 → 落點（三岔路或時間軸）
#   publish  先 `simctl addmedia` LittleSproutUITests/QA/Fixtures 的照片＋影片 →（登入／建家庭）→ 新增回憶 → 相簿選圖 → 發佈 → 卡片出現
#   browse   （登入／建家庭）→ 日記卡 → 詳情 → 返回 → 相簿分頁 → 時間軸（時間軸空的話先發一篇純文字當對象）
#   每個情境都先 `simctl keychain reset`、從未登入狀態開始、各自 OTP 登入同一帳號——不沿用上一個情境留在 Keychain 的
#   session：共用容器隨時可能被他票 reset（本票實測：browse 沿用 login 的 session，中間 QA 冒煙 reset 過，建家庭被後端拒），
#   舊 session 對應的使用者已不存在會把環境問題誤報成 app 缺陷；OTP 一次 ~10 秒、`max_frequency = "1s"`，重登不貴。
#   --sim     指定既有模擬器（名稱須精確）；預設 `<票號>-iPhone17Pro`，不存在就建（iPhone 17 Pro、最新 iOS runtime）
#   --ticket  票號；預設從目前 worktree 目錄名推（`.claude/worktrees/LS-<n>`），推不出就要求明給
#   --email   三個情境共用的測試帳號（預設 qa-e2e@ls.test；同一帳號才讓 browse 看得到 publish 剛發的那篇）
#   **只准在票 worktree 內跑**（merge-review R1 N1）：hold 的持有者判定看 worktree（LS-170 §6），從主 checkout 取得的 hold
#   會讓主 checkout 上的 orchestrator／reviewer 全部直通、鎖形同虛設——主 checkout（git-dir＝git-common-dir）一律 exit 2。
# 環境變數：LS_QA_MAILPIT 覆寫 Mailpit URL（預設讀 `supabase status` 的 MAILPIT_URL，再退 http://127.0.0.1:54324）；
#   LS_LOCK_SH 覆寫 supabase-lock.sh 路徑（只給自測塞 stub 用，R1 N2）。
#
# 做的事（順序即防線）：
#   1. 情境名／票號檢查（錯即 exit 2，不碰任何工具）。
#   2. `supabase status -o env` 讀 API_URL／ANON_KEY／MAILPIT_URL——取不到＝容器沒跑，exit 2；再各打一次
#      health（Mailpit `/api/v1/info`、GoTrue `/auth/v1/health`）確認可達。
#   3. 模擬器：找／建專屬機、boot（自己 boot 的收工自己 shutdown，LS-100；本來就 Booted 的不動）。
#   4. 情境前置：一律 keychain reset（見上）；publish 另 addmedia fixtures。
#   5. `supabase-lock.sh --hold "<票號> qa-e2e <情境>" --max-minutes 25`——整段 UI 操作期間其他 worktree 的
#      db reset 排隊（LS-159／LS-170）；呼叫者已經持有（同 worktree，`--hold` 回專屬 exit 3）就沿用、不重複 hold、
#      收工也不代釋放——判 exit code，不比對人類訊息（R1 N2）。
#   6. `xcodebuild test -only-testing:LittleSproutUITests/QASmokeTests`，環境以 TEST_RUNNER_LS_QA_* 交給
#      runner（xcodebuild 剝前綴），UI test 再經 launchEnvironment 注入 app（SupabaseClientFactory.qaOverride，DEBUG）。
#   7. 證據：`.claude/evidence/<票號>/qa-e2e/<情境>-<時間>/`——xcodebuild.log、result.xcresult、
#      screens/<情境>-<序號>-<步驟>.png（xcresulttool export attachments 後依 manifest 改名；Xcode 失敗時自動收的
#      螢幕錄影／UI snapshot／debug description 另放 diagnostics/）、storage.log
#      （`docker logs --since <開跑時間>` supabase_storage 容器；失敗只註記不擋）。
# exit：0＝情境通過；1＝情境失敗（xcodebuild test 紅，log 尾段印出）；2＝參數／環境／模擬器錯誤（fail closed）。
# 自測：qa-e2e.test.sh（PATH shim，不實跑 xcodebuild）。規約：.claude/agents/qa.md、docs/COLLABORATION.md §4-b／§7。
set -uo pipefail

usage() {
  echo "用法：qa-e2e.sh <login|publish|browse> [--sim <模擬器名>] [--ticket LS-<n>] [--email <收件信箱>]"
}

scenario=; sim_name=; sim_given=0; ticket=; email=
while [ $# -gt 0 ]; do
  case "$1" in
    --sim)
      [ -n "${2:-}" ] || { echo "✗ qa-e2e：--sim 缺值" >&2; exit 2; }
      sim_name=$2; sim_given=1; shift 2 ;;
    --ticket)
      [ -n "${2:-}" ] || { echo "✗ qa-e2e：--ticket 缺值" >&2; exit 2; }
      ticket=$2; shift 2 ;;
    --email)
      [ -n "${2:-}" ] || { echo "✗ qa-e2e：--email 缺值" >&2; exit 2; }
      email=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "✗ qa-e2e：未知參數 $1" >&2; usage >&2; exit 2 ;;
    *)
      if [ -n "$scenario" ]; then echo "✗ qa-e2e：多餘參數「$1」（情境只能一個）" >&2; usage >&2; exit 2; fi
      scenario=$1; shift ;;
  esac
done
[ -n "$scenario" ] || { echo "✗ qa-e2e：缺情境名" >&2; usage >&2; exit 2; }
case "$scenario" in
  login|publish|browse) ;;
  *) echo "✗ qa-e2e：情境「${scenario}」不存在，只接受 login|publish|browse" >&2; exit 2 ;;
esac

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "✗ qa-e2e：不在 git repo 內（在票 worktree 執行）" >&2; exit 2; }
# R1 N1：主 checkout 一律擋——git-dir 與 git-common-dir 同一個目錄就是主 checkout（worktree 的 git-dir 在 .git/worktrees/<名>）。
git_dir=$(git rev-parse --path-format=absolute --git-dir 2>/dev/null)
common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
if [ -z "$git_dir" ] || [ "$git_dir" = "$common_dir" ]; then
  echo "✗ qa-e2e：這是主 checkout（${root}）——請在票 worktree（.claude/worktrees/LS-<n>）內跑：hold 的持有者判定看 worktree，主 checkout 的 hold 會讓所有主 checkout 程序直通（LS-170 §6）" >&2
  exit 2
fi
if [ -z "$ticket" ]; then
  ticket=$(basename "$root" | grep -oE 'LS-[0-9]+' | head -1)
  [ -n "$ticket" ] || { echo "✗ qa-e2e：從 worktree 目錄名「$(basename "$root")」推不出票號——請在 .claude/worktrees/LS-<n> 內跑；固定 QA worktree（qa-test）才用 --ticket LS-<n>" >&2; exit 2; }
fi
case "$ticket" in
  LS-[0-9]*) ;;
  *) echo "✗ qa-e2e：--ticket 須為 LS-<n>（得到「${ticket}」）" >&2; exit 2 ;;
esac

# ---- 2. 本機容器 ----
# `supabase status` 偶爾在別的 worktree 同時跑 supabase CLI 時回空（2026-09-04 實測：容器健康、下一秒就正常），
# 讀三次再判定容器沒跑——不然 QA 會被一次瞬間失敗誤導成「環境壞了」。
status=; attempt=0
while [ "$attempt" -lt 3 ]; do
  status=$(supabase status -o env 2>/dev/null) && printf '%s' "$status" | grep -q '^API_URL=' && break
  attempt=$((attempt + 1)); sleep 2
done
env_value() { printf '%s\n' "$status" | sed -n "s/^$1=//p" | head -1 | tr -d '"'; }
api_url=$(env_value API_URL)
anon_key=$(env_value ANON_KEY)
mailpit=${LS_QA_MAILPIT:-$(env_value MAILPIT_URL)}
[ -n "$mailpit" ] || mailpit=http://127.0.0.1:54324
if [ -z "$api_url" ] || [ -z "$anon_key" ]; then
  echo "✗ qa-e2e：supabase status 取不到 API_URL／ANON_KEY（本機容器有跑嗎？在 repo 根 supabase start）" >&2
  exit 2
fi
# R1 I-2：curl 連不上時自己就印 000，失敗分支不再補印（曾印成 000000）；只有 curl 完全沒輸出才補 000。
http_code() { local code; code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null); printf '%s' "${code:-000}"; }
code=$(http_code "${mailpit}/api/v1/info")
[ "$code" = 200 ] || { echo "✗ qa-e2e：Mailpit ${mailpit} 不可達（HTTP ${code}）——OTP 取碼靠它（supabase start 會一起起）" >&2; exit 2; }
code=$(http_code -H "apikey: ${anon_key}" "${api_url}/auth/v1/health")
[ "$code" = 200 ] || { echo "✗ qa-e2e：GoTrue ${api_url}/auth/v1/health 回 HTTP ${code}——容器不健康" >&2; exit 2; }

# ---- 3. 模擬器（同 detect-simulator.sh 的專屬機命名：<票號>-<機型無空白>）----
find_udid() {   # $1＝精確裝置名；印第一個相符「可用」裝置的 UDID
  xcrun simctl list devices available 2>/dev/null | awk -v n="$1" '
    { line = $0; nm = line; sub(/^[ \t]*/, "", nm); sub(/ *\(.*/, "", nm)
      if (nm == n) { udid = line; sub(/^[^(]*\(/, "", udid); sub(/\).*/, "", udid); print udid; exit } }'
}
[ -n "$sim_name" ] || sim_name="${ticket}-iPhone17Pro"
udid=$(find_udid "$sim_name")
if [ -z "$udid" ]; then
  if [ "$sim_given" -eq 1 ]; then echo "✗ qa-e2e：--sim「${sim_name}」不存在或不可用（xcrun simctl list devices available）" >&2; exit 2; fi
  devicetype=$(xcrun simctl list devicetypes 2>/dev/null | grep -F 'iPhone 17 Pro (' | sed -E 's/.*\(([^()]+)\)[[:space:]]*$/\1/' | head -1)
  runtime=$(xcrun simctl list runtimes 2>/dev/null | grep '^iOS ' | tail -1 | sed -E 's/.* - (com\.apple\.[^[:space:]]+)[[:space:]]*$/\1/')
  if [ -z "$devicetype" ] || [ -z "$runtime" ]; then echo "✗ qa-e2e：找不到 iPhone 17 Pro devicetype／iOS runtime，無法建「${sim_name}」——改用 --sim 指定既有機" >&2; exit 2; fi
  udid=$(xcrun simctl create "$sim_name" "$devicetype" "$runtime") || { echo "✗ qa-e2e：simctl create「${sim_name}」失敗" >&2; exit 2; }
  echo "→ qa-e2e：已建立專屬模擬器 ${sim_name}（${udid}）"
fi
state=$(xcrun simctl list devices 2>/dev/null | grep -F "$udid" | sed -E 's/.*\((Booted|Shutdown|Booting|Shutting Down)\).*/\1/')
booted_by_me=0
if [ "$state" != Booted ]; then
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || { echo "✗ qa-e2e：模擬器 ${sim_name} boot 失敗" >&2; exit 2; }
  booted_by_me=1
fi

# ---- 4. 情境前置（每個情境都從未登入狀態開始，理由見檔頭）----
fixtures="${root}/LittleSproutUITests/QA/Fixtures"
xcrun simctl keychain "$udid" reset >/dev/null 2>&1 || { echo "✗ qa-e2e：simctl keychain reset 失敗——情境要從未登入狀態開始" >&2; exit 2; }
if [ "$scenario" = publish ]; then
  [ -f "$fixtures/qa-photo.jpg" ] && [ -f "$fixtures/qa-video.mp4" ] || { echo "✗ qa-e2e：缺 fixture（${fixtures}/qa-photo.jpg／qa-video.mp4）" >&2; exit 2; }
  xcrun simctl addmedia "$udid" "$fixtures/qa-photo.jpg" "$fixtures/qa-video.mp4" || { echo "✗ qa-e2e：simctl addmedia 失敗" >&2; exit 2; }
fi

# ---- 5. 持有 lock（LS-159／LS-170）----
lock_sh=${LS_LOCK_SH:-$here/supabase-lock.sh}   # R1 N2：自測以 stub 覆寫，涵蓋取得／沿用／失敗與 cleanup 三條路徑
held_by_me=0
hold_out=$(bash "$lock_sh" --hold "${ticket} qa-e2e ${scenario}" --max-minutes 25 2>&1); hold_rc=$?
case "$hold_rc" in
  0) held_by_me=1; echo "→ qa-e2e：${hold_out}" ;;
  3) echo "→ qa-e2e：沿用呼叫者既有的 hold，收工不代釋放（${hold_out}）" ;;   # supabase-lock.sh --hold 的專屬碼：已持有／已在 lock 內
  *)
    echo "✗ qa-e2e：取不到 Supabase lock（supabase-lock.sh exit ${hold_rc}）：${hold_out}" >&2
    [ "$booted_by_me" -eq 1 ] && xcrun simctl shutdown "$udid" >/dev/null 2>&1
    exit 2 ;;
esac
cleanup() {
  [ "$held_by_me" -eq 1 ] && bash "$lock_sh" --release
  [ "$booted_by_me" -eq 1 ] && xcrun simctl shutdown "$udid" >/dev/null 2>&1 && echo "→ qa-e2e：模擬器 ${sim_name} 已關（本腳本 boot 的）"
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT   # 同 supabase-lock.sh：訊號轉成帶碼的 exit，EXIT trap 一定跑到（釋放 hold、關自己 boot 的模擬器）
trap 'exit 143' TERM

# ---- 6. 跑 ----
stamp=$(date +%Y%m%d-%H%M%S)
out="${root}/.claude/evidence/${ticket}/qa-e2e/${scenario}-${stamp}"
mkdir -p "$out/screens"
log="$out/xcodebuild.log"; result="$out/result.xcresult"
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "→ qa-e2e：${scenario} @ ${sim_name}（${udid}）→ ${out}"
TEST_RUNNER_LS_QA_SCENARIO=$scenario \
TEST_RUNNER_LS_QA_API_URL=$api_url \
TEST_RUNNER_LS_QA_ANON_KEY=$anon_key \
TEST_RUNNER_LS_QA_MAILPIT=$mailpit \
TEST_RUNNER_LS_QA_EMAIL=${email:-qa-e2e@ls.test} \
xcodebuild test \
  -project "${root}/LittleSprout.xcodeproj" \
  -scheme LittleSprout \
  -destination "platform=iOS Simulator,id=${udid}" \
  -only-testing:LittleSproutUITests/QASmokeTests \
  -parallel-testing-enabled NO \
  -resultBundlePath "$result" \
  > "$log" 2>&1
rc=$?

# ---- 7. 證據 ----
if [ -d "$result" ]; then
  tmp_export=$(mktemp -d -t qa-e2e-attachments)
  if xcrun xcresulttool export attachments --path "$result" --output-path "$tmp_export" >/dev/null 2>&1 \
     && [ -f "$tmp_export/manifest.json" ]; then
    python3 - "$tmp_export" "$out/screens" "$out/diagnostics" "$scenario" <<'PY'
import json, os, re, shutil, sys
src, dst, diag, scenario = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
# suggestedHumanReadableName 形如 `login-01-welcome_0_<UUID>.png`（Xcode 匯出時加的序號＋UUID）——剝掉尾綴，
# 留 QADriver.snap 給的 `<情境>-<序號>-<步驟>`；同名（重跑同一步）才保留尾綴避免覆蓋。
# QADriver 以外的附件（Xcode 失敗時自動收的 Screen Recording／UI Snapshot／Synthesized Event／debug description／
# App UI hierarchy）不混進 screens/——另放 diagnostics/，失敗時仍看得到、通過時通常不存在。
for test in json.load(open(os.path.join(src, "manifest.json"))):
    for att in test.get("attachments", []):
        exported = att.get("exportedFileName"); name = att.get("suggestedHumanReadableName") or exported
        if not exported: continue
        ext = os.path.splitext(exported)[1] or ".png"
        base = re.sub(r"_\d+_[0-9A-Fa-f-]{36}$", "", os.path.splitext(name)[0] if name.endswith(ext) else name)
        folder = dst if base.startswith(scenario + "-") else diag
        os.makedirs(folder, exist_ok=True)
        target = os.path.join(folder, base + ext)
        if os.path.exists(target): target = os.path.join(folder, os.path.splitext(name)[0] + ext)
        shutil.move(os.path.join(src, exported), target)
PY
  else
    echo "⚠ qa-e2e：xcresulttool export attachments 失敗——截圖仍在 ${result}（Xcode 可開）" >&2
  fi
  rm -rf "$tmp_export"
fi
storage_container=$(docker ps --filter name=supabase_storage --format '{{.Names}}' 2>/dev/null | head -1)
if [ -n "$storage_container" ]; then
  docker logs --since "$since" "$storage_container" > "$out/storage.log" 2>&1 || echo "（docker logs ${storage_container} 失敗）" >> "$out/storage.log"
else
  echo "（找不到 supabase_storage 容器，未收 Storage log）" > "$out/storage.log"
fi

shots=$(ls "$out/screens" 2>/dev/null | wc -l | tr -d ' ')
if [ "$rc" -eq 0 ]; then
  echo "✓ qa-e2e：${scenario} 通過——截圖 ${shots} 張：${out}/screens/；Storage log：${out}/storage.log；xcresult：${result}"
  exit 0
fi
echo "✗ qa-e2e：${scenario} 失敗（xcodebuild exit ${rc}）——截圖 ${shots} 張：${out}/screens/；完整 log：${log}" >&2
grep -E 'error:|失敗|Failing tests|BUILD FAILED|TEST FAILED' "$log" | head -n 20 | sed 's/^/    /' >&2
exit 1
