#!/bin/bash
# LS-146 — 審核用 demo 帳號＋示範家庭資料種子（PLAN §9-B「審核用 demo 帳號」）
#
# 目的：App Store 審核員全新裝置只憑 docs/store/review-notes.md 的帳號資訊，就要能
# 走完登入→時間軸→相簿→留言。這支腳本建立那個「審核專用家庭」：owner＋member 各一個
# 帳號、2 個孩子檔案、20 筆 media（18 張照片＋2 支影片，含縮圖三欄與 duration_seconds）、
# 5 則日記（含多寶貝標記）、留言與愛心反應、一組長期有效的邀請碼。
#
# 冪等：所有資料以固定 UUID（見下方常數）標記；每次執行先刪除同一標記的既有資料（DB
# 用 family_id 級聯＋auth.users 以固定 id 比對（不是 email，見下）、Storage 用同一組
# 固定路徑批次刪除）再重建，可重複執行、計數不變。auth.users 清理鍵演進：LS-146 R1
# F4 從 email 前綴收斂成精確比對（避免正式站誤刪撞名真實使用者）；LS-162 R2（B1
# blocker／N1）再收斂一次——email 現在是操作者傳入的參數（見下方 --owner-email／
# --member-email），精確比對 email 已不足以防呆（傳入的可能剛好是別人真的在用的信箱，
# reviewer 本機實跑重現：真實帳號被換成種子固定 uuid、家庭成員關係隨 cascade 消失）。
# 現在改成：寫入前在同一份 SQL、同一個 --single-transaction 交易內先查 email 是否已
# 存在且 id 不是本腳本固定 uuid（別人的帳號）→ raise exception、整份回捲、fail loud，
# 絕不刪除；只有 id＝固定 uuid 才視為「自己的列」，清理鍵也從 email 改成 id（換 email
# 重跑不再撞 users_pkey）。
#
# 寫入方式：直接以 postgres／service_role 身分寫 SQL（模式同
# supabase/tests/00_fixtures.sql），不透過 create_diary_entry／create_comment 等
# RPC——這些 RPC 是給 authenticated 角色的授權邊界，postgres/service_role 本來就不受
# 表級 RPC-only grant 收斂影響（docs/API.md §2／§3 逐表說明的是 authenticated 的路徑），
# 直寫的資料語意與 trigger 行為（feed_items／feed_item_children／
# storage_used_bytes／add_creator_as_owner／deletion_attribution）跟走 App 操作
# 完全一致，只是省去逐支 RPC 呼叫的往返。
#
# 長期有效邀請碼：docs/API.md §4 create_invite 的 p_expires_at 上限是「現在～現在+30
# 天」（超出 → LS017，RPC 層的安全邊界，不是資料表本身的 CHECK）——這支腳本要的是
# 「審核期間不會過期」的碼，直接對 invites 表 INSERT 一列、expires_at 設現在+3 年，
# 繞過 RPC 的 30 天上限（表本身只要求 expires_at NOT NULL，沒有上限 CHECK，見
# supabase/migrations/20260822120000_init_schema.sql `create table public.invites`）。
#
# 影片素材：不用 `simctl io recordVideo`——實測會撞 CoreSimulator 全主機層級的
# recording 鎖（其他 worktree／agent 同時使用模擬器就報 "Host recording is already in
# progress"，清鎖需要 killall CoreSimulatorService，牽連其他 worktree），改用
# scripts/ops/review-demo-genvideo.swift（AVFoundation 直接合成 mp4，不碰模擬器）。
#
# 用法：
#   bash scripts/ops/review-demo-seed.sh --target local              種本機（本機一律經 supabase-lock）
#   bash scripts/ops/review-demo-seed.sh --target prod                只印計畫，不連線、不寫入（沒有 --yes）
#   bash scripts/ops/review-demo-seed.sh --target prod --yes --owner-email <addr>
#                                                                      種正式站（讀 .env 取連線，見下；owner-email 必填見下）
#   bash scripts/ops/review-demo-seed.sh --target prod --yes --storage-only
#                                                                      續傳（LS-240）：DB 已是本輪資料、只有 Storage
#                                                                      上傳段中途失敗時用——見下方「--storage-only」段
#
# --storage-only（LS-240，來源：LS-96 池項 `3f23757a` 09-13 事故——SQL 段成功後 Storage 上傳
#   第 9 張因 504 中止，只能整份重跑）：跳過 SQL 段（不清理／不重建 DB，也不動 auth.users，因此
#   **不需要 `--owner-email`**）與 Storage 批次清理（續傳的前提是先前已成功上傳的物件還在，
#   清理會把它們也刪掉，違背「續傳」的本意）；仍會照常準備照片／影片素材，對本輪 20 筆
#   media 對應的 40 個固定路徑（原檔＋縮圖）逐一用 Storage list API 探測是否已存在（不用
#   HEAD——見下方 storage_exists 函式註解的實測理由），只對缺的
#   物件上傳（沿用既有的 service-role Bearer／apikey 認證方式，不新增讀取憑證的管道）。
#   `--target local`／`--target prod --yes` 皆可搭配；prod 分支仍照常需要 `.env` 三個連線變數
#   （見下方「環境」段，未特別為 --storage-only 放寬）。
#
# --owner-email／--member-email（LS-162）：覆寫 owner／member 帳號的 email，不帶時維持
#   下方 OWNER_EMAIL／MEMBER_EMAIL 兩個固定預設值。**`--target prod --yes` 時 --owner-email
#   必填，且不得以 `@little-sprout.app` 結尾**（比對大小寫不敏感，LS-162 R2 i2）——那個
#   網域非我們所有（LS-148 查重：`littlesprout.app` 為競品），寄到那裡的信審核員收不到；
#   缺值或網域不符會在讀 `.env` 之前就 `exit 2`，不連線、不觸碰任何 prod 憑證。email 值
#   一律經格式健檢（含拒絕單引號，LS-162 R2 i1），local／prod 皆套用。
#
# --owner-password（LS-162 R2，方案 B 轉向：使用者 2026-09-04 13:22 改採帳號密碼登入，
#   OTP 方案 C 停用）：owner 帳號改用密碼登入。**不帶時**（＝正式站預設用法）自動產生
#   20 字元英數強密碼、只印終端一次，不寫進任何檔案／log／review-notes.md，僅短暫
#   存在於本次執行的 mktemp -d 暫存目錄，行程結束由 trap 清除。**顯式帶
#   --owner-password 時**（例如本機測試自帶固定密碼）例外：i-d（merge-review R2）
#   ——`--target local` 會把原始參數 re-exec 進 supabase-lock.sh，密碼會明碼出現在
#   該次命令列（`ps` 看得到）與 supabase-lock.sh 的 holder 檔（實測 `-rw-r--r--`，
#   執行期間存在）；prod 分支不經 lock、且預設就是自動產生，所以正式站實際送審用的
#   那組密碼不受這個例外影響。密碼雜湊用 pgcrypto 的 crypt(pw, gen_salt('bf', 10))
#   （bcrypt cost 10，跟 GoTrue 自己建帳號用的 cost 對齊）直接寫在種子 SQL 裡，取捨：
#   改走 GoTrue admin API `POST /auth/v1/admin/users` 會是這支腳本唯一一個跳出
#   「postgres 身分直寫 SQL」模式、多一次網路往返、且落在 --single-transaction 保護
#   之外的步驟；直接在 SQL 內雜湊維持單一交易，SQL 失敗照樣整份回捲，執行前會先查
#   pgcrypto 的 crypt(text,text) 是否 resolvable（不只查有沒有裝 extension，也查
#   目前連線的 search_path 叫不叫得到——i-b merge-review R2），缺了 fail loud（不會
#   無聲跳過密碼或存明文）。member 帳號維持 Email OTP，不受影響。email 一律正規化成
#   小寫再使用（M1 merge-review R2，見下方常數區塊），跟 GoTrue 自己的儲存慣例對齊。
#
# 環境：
#   --target local：用 `supabase status -o env` 取得本機 DB_URL／API_URL／SERVICE_ROLE_KEY。
#   --target prod --yes：`source .env` 後讀 SUPABASE_DB_URL／SUPABASE_URL／
#     SUPABASE_SERVICE_ROLE_KEY 三個環境變數（本腳本不印出其值，也不嘗試從
#     SUPABASE_ACCESS_TOKEN／SUPABASE_DB_PASSWORD 反推連線字串——正式站連線資訊需要
#     操作者自己先把這三個變數放進 .env；截至 LS-146 撰寫當下 .env 尚未定義它們，
#     見 PR body／handoff）。
#
# Storage 上傳重試（LS-240，同一起事故）：上傳段每個物件對暫時性錯誤（curl exit
#   56／7／28＝連線／接收/逾時失敗，或 HTTP 5xx／429）最多重試 3 次、退避
#   1s→2s→4s，全部試完仍失敗才印 ✗ 並中止；其餘錯誤（其他 curl exit、4xx 除 429）
#   視為永久性錯誤，不重試立刻回報。sleep 呼叫外部命令 `sleep`，自測以 PATH 前置
#   假身注入拉快測試（同 curl／supabase 等既有假身慣例），正式路徑不變。
#
# psql 偵測（LS-240，同一起事故：host 沒有 link 的 psql，libpq 裝在
#   `/opt/homebrew/opt/libpq/bin` 卻不在 PATH 上——brew 不自動 link 是為了避免跟
#   macOS 系統 `psql` 衝突）：`command -v psql` 找不到時依序試
#   `/opt/homebrew/opt/libpq/bin/psql`、`/usr/local/opt/libpq/bin/psql`，再退回既有
#   的 docker exec 備援；仍找不到才印 `brew install libpq` 安裝提示並 exit。
#   `SEED_PSQL_CANDIDATES`（空白分隔）可覆寫這份候選清單，供自測用假路徑，正式
#   路徑不受影響。
#
# 本票只做本機驗證：LS-146／LS-240 不會以 --target prod --yes 執行，正式站落地留待使用者核可。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() { echo "用法：review-demo-seed.sh --target local|prod [--yes] [--owner-email <addr>] [--member-email <addr>] [--owner-password <pw>] [--storage-only]"; }

# i1（merge-review R1）：email 值原封不動插進種子 SQL 字面（下方 auth.users insert／
# 清理 SQL），local／prod 皆套用——單引號會破壞 SQL 字面（fail loud，非資料風險，因為
# --single-transaction 會整份回捲，但早一步擋掉比等 SQL 語法錯誤訊息友善）；基本格式
# 健檢（要有 @ 與網域裡的 .）擋掉明顯打錯的字串，代價是幾乎零成本的 case 比對。
validate_email() {  # $1=參數名（供錯誤訊息用） $2=email 值
  label=$1; val=$2
  case "$val" in
    *\'*) echo "✗ review-demo-seed：$label 不可含單引號（會破壞直寫 SQL 字面）：$val" >&2; exit 2 ;;
  esac
  case "$val" in
    *@*) ;;
    *) echo "✗ review-demo-seed：$label 看起來不像 email（缺 @）：$val" >&2; exit 2 ;;
  esac
  case "${val#*@}" in
    *.*) ;;
    *) echo "✗ review-demo-seed：$label 看起來不像 email（網域缺 .）：$val" >&2; exit 2 ;;
  esac
  [ -n "${val%%@*}" ] || { echo "✗ review-demo-seed：$label 看起來不像 email（@ 前面是空的）：$val" >&2; exit 2; }
}

# F1（merge-review R1）：":133" 要在還沒在 lock 內時把原始參數原封不動 re-exec 進
# supabase-lock.sh，但下面的解析迴圈會把 "$@" shift 光——先存一份不受影響的副本。
# bash 3.2 + set -u 下展開可能為空的陣列要用 ${arr[@]+"${arr[@]}"} 這個寫法（PR #122
# 系列既有慣例，同 supabase-lock.sh 的陣列處理）。
orig_args=("$@")

target=""
yes=0
owner_email_opt=""
member_email_opt=""
owner_password_opt=""
storage_only=0
while [ $# -gt 0 ]; do
  case "$1" in
    --storage-only) storage_only=1; shift ;;
    --target)
      # F5（merge-review R1）：漏帶值時 ${2:-} 是空字串、shift 2 在只剩 1 個參數時會失敗
      # （set -uo pipefail 沒有 -e，失敗的 shift 不會中止腳本）——不擋住就是 while 條件
      # 恆真的無聲無限迴圈。比照 supabase-lock.sh 的 --timeout 分支先驗證有下一個參數。
      [ -n "${2:-}" ] || { echo "✗ review-demo-seed：--target 缺值" >&2; usage >&2; exit 2; }
      target=$2; shift 2 ;;
    --yes) yes=1; shift ;;
    --owner-email)
      [ -n "${2:-}" ] || { echo "✗ review-demo-seed：--owner-email 缺值" >&2; usage >&2; exit 2; }
      owner_email_opt=$2; shift 2 ;;
    --member-email)
      [ -n "${2:-}" ] || { echo "✗ review-demo-seed：--member-email 缺值" >&2; usage >&2; exit 2; }
      member_email_opt=$2; shift 2 ;;
    --owner-password)
      [ -n "${2:-}" ] || { echo "✗ review-demo-seed：--owner-password 缺值" >&2; usage >&2; exit 2; }
      owner_password_opt=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "✗ review-demo-seed：未知參數 $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$target" in
  local|prod) ;;
  *) echo "✗ review-demo-seed：需要 --target local|prod" >&2; usage >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# 固定識別碼（冪等的核心：每次都是同一組 UUID／email，重跑先刪同標記資料再重建）
# ---------------------------------------------------------------------------
FAMILY_ID=de000000-0000-4000-8000-000000000001
OWNER_ID=d1000000-0000-4000-8000-000000000001
MEMBER_ID=d1000000-0000-4000-8000-000000000002
CHILD1_ID=d2000000-0000-4000-8000-000000000001
CHILD2_ID=d2000000-0000-4000-8000-000000000002
INVITE_ID=d4000000-0000-4000-8000-000000000001
# LS-281：審核家庭的相簿。沒有相簿＋沒有 album_media 連結，20 筆種子 media 就完全符合
# private.soft_delete_unreferenced_media()（LS-213，pg_cron 每日 19:30 UTC＝台北 03:30）
# 的軟刪條件「deleted_at is null＋created_at 超過 24h＋不掛在任何 diary_media／album_media」
# ——正式站 2026-09-13 03:30 已經真的把 20 筆全部軟刪過一次（LS-248 handoff R1／R2）。
# 這裡建一本相簿並把 20 筆 media 全掛進 album_media，讓種子資料天生不符合那個條件；
# 同時補上 LS-147 送審截圖需要的相簿分頁內容（原本是空狀態）。
ALBUM_ID=d8000000-0000-4000-8000-000000000001
# 相簿標題同時是冪等查找鍵（見下方 albums 段的 do 區塊）：正式站套用不走整份種子重灌
# （那會刪掉並重建整個家庭），而是只補這一本相簿＋連結，靠「同 family_id＋同 title＋
# 未軟刪」查得到就不重建。標題含單引號會破壞直寫 SQL 字面，這是寫死的常數、不是參數，
# 不需要 validate_email 那種健檢。
ALBUM_TITLE=阿公阿嬤家過年
# 這串碼是要印在 App Review Notes 給人照抄的（merge-review R1 i2）：原本 LSDEMO 含字母
# 'O'，跟 create_invite RPC 產碼字母表 23456789ABCDEFGHJKLMNPQRSTUVWXYZ（排除
# 0/O/1/I 以免長輩手抄誤認，20260825070627_invite_code_6.sql）刻意要避開的歧義字元同一類
# ——這裡是直寫、不受該字母表機械約束，但沒理由自己選一個它要避開的字元，換成 7。
INVITE_CODE=LSDEM7
# LS-162：owner／member email 可用 --owner-email／--member-email 覆寫；不帶時維持這兩個
# little-sprout.app 預設值（僅供本機使用——正式站執行的必填／網域檢查見下方 prod+yes 分支）。
OWNER_EMAIL="${owner_email_opt:-review-demo@little-sprout.app}"
MEMBER_EMAIL="${member_email_opt:-review-demo-member@little-sprout.app}"
validate_email "--owner-email" "$OWNER_EMAIL"
validate_email "--member-email" "$MEMBER_EMAIL"
# M1（merge-review R2）：驗證原始輸入之後才正規化——錯誤訊息（上面 validate_email）
# 照操作者打的字顯示，但下游一律用小寫。GoTrue 對 email 寫入時正規化成小寫、查詢
# 也不分大小寫；這裡先把輸入轉小寫，是**主要**修法：下游 print_plan／SQL insert／
# 錯誤訊息全部改用同一份已正規化的值，讓這支腳本自己寫進 auth.users 的資料本來就
# 跟 GoTrue 的儲存慣例一致，「同一個人類可見地址、大小寫不同、唯一索引擋不住、
# 變成兩列」的情況從源頭就不會發生（唯一索引本身是大小寫敏感的，正規化輸入才是
# 真正的防線）。下方 SQL 的 guard／insert 另外用 lower() 包一層是**次要**防線
# （defense-in-depth：即使這裡的正規化被繞過或未來改掉，SQL 端仍然正確）。
OWNER_EMAIL=$(printf '%s' "$OWNER_EMAIL" | tr '[:upper:]' '[:lower:]')
MEMBER_EMAIL=$(printf '%s' "$MEMBER_EMAIL" | tr '[:upper:]' '[:lower:]')
# 上傳路徑的 {yyyy}/{mm} 固定（docs/API.md §6：這段取的是「上傳時間」，不是拍攝時間）——
# 種子腳本每次重跑都要落在同一個路徑，Storage 側的批次刪除才能用固定清單、不必先 list。
SEED_YM=2026/09

media_ids=()
for i in $(seq 1 20); do media_ids+=("$(printf 'd3000000-0000-4000-8000-%012x' "$i")"); done
diary_ids=(d5000000-0000-4000-8000-000000000001 d5000000-0000-4000-8000-000000000002 \
  d5000000-0000-4000-8000-000000000003 d5000000-0000-4000-8000-000000000004 \
  d5000000-0000-4000-8000-000000000005)
comment_ids=(d6000000-0000-4000-8000-000000000001 d6000000-0000-4000-8000-000000000002 \
  d6000000-0000-4000-8000-000000000003 d6000000-0000-4000-8000-000000000004)
reaction_ids=(d7000000-0000-4000-8000-000000000001 d7000000-0000-4000-8000-000000000002 \
  d7000000-0000-4000-8000-000000000003 d7000000-0000-4000-8000-000000000004)

print_plan() {
  if [ "$storage_only" -eq 1 ]; then
    cat <<PLAN
→ 審核用 demo 資料種子計畫（LS-240 --storage-only，target=${target}）
  family_id：${FAMILY_ID}（審核家庭，沿用既有資料，不動 DB／不動 auth.users）
  media：20（18 張照片＋2 支影片＝40 個固定 Storage 路徑：原檔＋縮圖）
  續傳：只對 Storage 缺的物件補上傳（list API 逐一判缺），不清理既有物件、不需要 --owner-email
PLAN
    return
  fi
  cat <<PLAN
→ 審核用 demo 資料種子計畫（LS-146，target=${target}）
  family_id：${FAMILY_ID}（審核家庭）
  帳號：owner ${OWNER_EMAIL}（密碼登入，方案 B）／member ${MEMBER_EMAIL}（Email OTP 登入）
  孩子檔案：2（${CHILD1_ID}／${CHILD2_ID}）
  media：20（18 張照片＋2 支影片，縮圖三欄＋duration_seconds 皆補齊）
  相簿：1（「${ALBUM_TITLE}」，封面取 hero；20 筆 media 全數掛進 album_media，sort_order 0–19）
  日記：5（含多寶貝標記：其中 2 篇同時標 2 個孩子）
  留言／愛心：各 4
  邀請碼：${INVITE_CODE}（直寫 expires_at=now()+3年，繞過 create_invite RPC 的 30 天上限）
  冪等：重跑先刪除 family_id=$FAMILY_ID 與 owner/member 兩個固定 uuid 帳號的既有資料
        （DB 級聯＋Storage 依固定路徑批次刪除），計數不因重跑改變；寫入前會先確認
        owner/member email 不是別人正在用的帳號（不是固定 uuid 就拒絕執行，見下）
PLAN
}

if [ "$target" = prod ]; then
  print_plan
  if [ "$yes" -ne 1 ]; then
    echo "（未帶 --yes：只印計畫，不連線、不寫入任何資料——LS-146 本票就停在這裡，正式站落地待使用者核可）"
    exit 0
  fi
  # LS-162：正式站真的執行前先驗 owner-email——退出點要早於下面的 `source .env`，兩個
  # 負案都不能碰到任何 prod 連線資訊。必須是操作者明確傳入的地址（不接受沿用預設值），
  # 且不得是 @little-sprout.app（該網域非我們所有，審核員收不到信，見腳本檔頭與
  # docs/store/review-notes.md）。LS-240：--storage-only 不動 auth.users，整段跳過。
  if [ "$storage_only" -eq 0 ]; then
    if [ -z "$owner_email_opt" ]; then
      echo "✗ review-demo-seed：--target prod --yes 需要 --owner-email（不得沿用預設 review-demo@little-sprout.app，該網域非我們所有、審核員收不到信，LS-162）" >&2
      exit 2
    fi
    # i2（merge-review R1）：DNS 網域不分大小寫——比對前先轉小寫，否則
    # someone@LITTLE-SPROUT.APP 會通過檢查但仍是同一個收不到信的網域。
    owner_email_lower=$(printf '%s' "$OWNER_EMAIL" | tr '[:upper:]' '[:lower:]')
    case "$owner_email_lower" in
      *@little-sprout.app)
        echo "✗ review-demo-seed：--owner-email 不得使用 @little-sprout.app 網域（非我們所有，審核員收不到信，LS-162）" >&2
        exit 2 ;;
    esac
  fi
  if [ "$storage_only" -eq 1 ]; then
    echo "⚠ review-demo-seed：--target prod --yes --storage-only，即將確認／補齊正式站 Storage 物件（不寫 DB、不動帳號）" >&2
  else
    echo "⚠ review-demo-seed：--target prod --yes，即將對正式站寫入審核用 demo 資料（owner=${OWNER_EMAIL}）" >&2
  fi
  [ -f "$ROOT/.env" ] || { echo "✗ 找不到 $ROOT/.env" >&2; exit 2; }
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
  : "${SUPABASE_DB_URL:?prod 連線需要 .env 定義 SUPABASE_DB_URL（見腳本頭註解；本腳本不嘗試從 SUPABASE_ACCESS_TOKEN/SUPABASE_DB_PASSWORD 反推）}"
  : "${SUPABASE_URL:?prod 連線需要 .env 定義 SUPABASE_URL}"
  : "${SUPABASE_SERVICE_ROLE_KEY:?prod 連線需要 .env 定義 SUPABASE_SERVICE_ROLE_KEY}"
  DB_URL=$SUPABASE_DB_URL
  API_URL=$SUPABASE_URL
  SERVICE_KEY=$SUPABASE_SERVICE_ROLE_KEY
else
  # 本機：一律經 supabase-lock（容器是所有 worktree 共用的，LS-70）——未在 lock 內就自己
  # 重新經 lock 執行一次（同 supabase/tests/run.sh 的既有慣例，見該檔檔頭）。
  lock_sh="$ROOT/scripts/ops/supabase-lock.sh"
  if [ -f "$lock_sh" ]; then
    if ! bash "$lock_sh" --held 2>/dev/null; then
      echo "→ 未在 Supabase lock 內，改經 scripts/ops/supabase-lock.sh 重新執行" >&2
      exec bash "$lock_sh" -- bash "${BASH_SOURCE[0]}" ${orig_args[@]+"${orig_args[@]}"}
    fi
  else
    echo "⚠ 找不到 ${lock_sh}：未經 lock 直接執行，與其他 worktree 的 supabase 操作可能互踩（LS-70）" >&2
  fi
  env_out=$(supabase status -o env 2>/dev/null) || { echo "✗ 讀不到本機 supabase status（先執行 supabase start）" >&2; exit 2; }
  DB_URL=$(printf '%s\n' "$env_out" | sed -nE 's/^DB_URL="(.*)"$/\1/p')
  API_URL=$(printf '%s\n' "$env_out" | sed -nE 's/^API_URL="(.*)"$/\1/p')
  SERVICE_KEY=$(printf '%s\n' "$env_out" | sed -nE 's/^SERVICE_ROLE_KEY="(.*)"$/\1/p')
  [ -n "$DB_URL" ] && [ -n "$API_URL" ] && [ -n "$SERVICE_KEY" ] || { echo "✗ 讀不到本機 DB_URL／API_URL／SERVICE_ROLE_KEY" >&2; exit 2; }
  print_plan
fi

# 方案 B（LS-162 R2）：解出 owner 密碼——只在真的要寫入 DB 時才做（prod 無 --yes 早就
# exit 0 了，走不到這裡；LS-240 --storage-only 不動 auth.users，整段跳過）。操作者自帶
# --owner-password 就用那組；否則自動產生 20 字元英數強密碼，只印終端這一次（不寫進
# review-notes.md／log／任何持久檔案）。
if [ "$storage_only" -eq 0 ]; then
  if [ -n "$owner_password_opt" ]; then
    OWNER_PASSWORD=$owner_password_opt
  else
    # 純英數：密碼會被原封不動插進種子 SQL 字面（crypt('${OWNER_PASSWORD}', …)），避開
    # 符號可以不用另外處理跳脫；用 48 bytes 的 base64 隨機源，過濾後仍有遠多於 20 個
    # 英數字元可截取。
    OWNER_PASSWORD=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-20)
    [ ${#OWNER_PASSWORD} -ge 20 ] || { echo "✗ review-demo-seed：自動產生的 owner 密碼長度不足（openssl／tr 異常）" >&2; exit 1; }
    echo "⚠ review-demo-seed：已自動產生 owner 密碼（只顯示這一次，請立即記下並填入 App Store Connect Review Notes，不會再印出）：${OWNER_PASSWORD}" >&2
  fi
  case "$OWNER_PASSWORD" in
    *\'*) echo "✗ review-demo-seed：--owner-password 不可含單引號（會破壞直寫 SQL 字面）" >&2; exit 2 ;;
  esac
fi

command -v sips >/dev/null 2>&1 || { echo "✗ review-demo-seed：找不到 sips（macOS 內建工具）" >&2; exit 2; }
command -v swift >/dev/null 2>&1 || { echo "✗ review-demo-seed：找不到 swift CLI" >&2; exit 2; }

# psql 不一定裝在 host 上；沒有的話依序試已知的 libpq 安裝位置，再借用 supabase 本機 DB
# container 裡那一份（同 supabase/tests/run.sh 既有慣例）——這整段只有真的要跑 SQL 時才需要
# （LS-240 --storage-only 不動 DB，整段跳過，也因此不必裝 psql）；docker exec 備援只在
# --target local 用得到，prod 一律要求能找到 psql（正式站不會借用本機 docker container）。
if [ "$storage_only" -eq 0 ]; then
  db_container="${SUPABASE_DB_CONTAINER:-supabase_db_little-sprout}"
  psql_bin=""
  if command -v psql >/dev/null 2>&1; then
    psql_bin=psql
  else
    # LS-240（同 LS-96 池項 `3f23757a`）：libpq 常見透過 brew 裝但刻意不 link 進 PATH
    # （避免跟 macOS 系統 psql 衝突）——依序試已知安裝位置。SEED_PSQL_CANDIDATES（空白
    # 分隔）可覆寫供自測用假路徑，預設是兩個真實已知安裝位置。
    IFS=' ' read -r -a libpq_candidates <<< "${SEED_PSQL_CANDIDATES:-/opt/homebrew/opt/libpq/bin/psql /usr/local/opt/libpq/bin/psql}"
    for candidate in "${libpq_candidates[@]}"; do
      if [ -x "$candidate" ]; then
        psql_bin=$candidate
        echo "→ host PATH 沒有 psql，改用 ${psql_bin}" >&2
        break
      fi
    done
  fi
  if [ -n "$psql_bin" ]; then
    # F2（merge-review R1）：--single-transaction——沒有它，psql -f 逐句 autocommit，
    # ON_ERROR_STOP=1 只保證「出錯就停」不保證「出錯就回捲」；seed.sql 檔尾的自我檢查
    # DO 區塊 raise exception 時，前面的 auth.users／families／children… 早就各自
    # commit 了，留下半套審核家庭。加這個旗標讓整份 SQL 檔全有或全無。
    run_sql() { "$psql_bin" "$DB_URL" -v ON_ERROR_STOP=1 --no-psqlrc -q --single-transaction -f "$1"; }
  elif [ "$target" = local ] && docker exec "$db_container" true >/dev/null 2>&1; then
    echo "→ host 沒有 psql，改用 docker exec ${db_container}" >&2
    run_sql() { docker exec -i "$db_container" psql -U postgres -d postgres -v ON_ERROR_STOP=1 --no-psqlrc -q --single-transaction < "$1"; }
  else
    echo "✗ review-demo-seed：找不到 psql（PATH／/opt/homebrew/opt/libpq/bin／/usr/local/opt/libpq/bin 皆無），也連不到 DB container（${db_container}）——請先 brew install libpq" >&2
    exit 2
  fi
fi

# LS-240 R2（merge-review m2）：--storage-only 最常見的情境是「全部已存在」的重跑
# （操作者只是想確認要不要救援）——這種情況完全不需要準備照片／影片素材（sips／
# AVFoundation 合成是最耗時的步驟），因此在準備素材之前先把本輪 40 個固定路徑
# （原檔＋縮圖）跟 Storage 既有物件比對一次：全部都在就直接印摘要、跳過素材準備／
# SQL／清理／上傳迴圈；只要缺一個就照舊完整跑（不做「只準備缺的那幾個」這種更細緻
# 但複雜度不成比例的最佳化——缺件本來就是少見的救援情境，見下方 storage_only_all_present
# 之後的 if／else）。photo_sources 因此提早到這裡宣告（原本在「1. 準備照片素材」段）。
photo_ext_for() {  # $1=素材來源路徑 → 印出副檔名（png｜jpg）；抽出來給早判斷與素材準備共用
  case "$1" in
    *.png) echo png ;;
    *) echo jpg ;;
  esac
}
# LS-248：後三個來源原本是 LS-46 佔位圖（design/hero-grandma.png／invite-grandma.png／
# join-parents.png），跟 App Store 海報用的是同一批——LS-234 決定 1b 改用 Codex 生圖
# 之後，海報已換成 LS-247 三張定稿，demo 家庭若還灌舊佔位圖，LS-147 拿 demo 帳號拍的
# 送審截圖裡就還是非出貨資產。這裡改指同一批定稿（design/appstore-photos/*.jpg，
# 2160×1190、JPEG q90、各 <500 KB，選圖與判準見 design/appstore-photos/SELECTION.md）。
# 前兩個來源（design-canvas／design-canvas-d 的 family.jpg）不是 LS-46 佔位圖，維持不動。
# 副檔名連帶從 .png 變成 .jpg：storage_path 是 {media_id}.{ext}，所以這三個來源對應的
# 10 筆 media（i=3,4,5,8,9,10,13,14,15,18，src_idx=(i-1)%5∈{2,3,4}）路徑也跟著換，舊
# .png 物件由既有批次清理（下方「清理既有 Storage 物件」列舉四種副檔名）收掉。
photo_sources=(
  "$ROOT/design-canvas/family.jpg"
  "$ROOT/design-canvas-d/family.jpg"
  "$ROOT/design/appstore-photos/hero.jpg"
  "$ROOT/design/appstore-photos/invite.jpg"
  "$ROOT/design/appstore-photos/join.jpg"
)
for f in "${photo_sources[@]}"; do
  [ -f "$f" ] || { echo "✗ review-demo-seed：找不到照片素材 $f" >&2; exit 1; }
done

# LS-240 R2（merge-review m1／m2）：--storage-only 一次列出整個資料夾（<family>/<yyyy>/<mm>，
# 本輪 40 個物件全落在同一個 prefix 底下）再本地比對，取代原本逐物件打 list（m2：次數從
# 40 次降成 1 次）；這一次呼叫套用跟 storage_put() 一樣的暫時性錯誤重試（curl exit
# 56／7／28、HTTP 5xx／429，退避 1s→2s→4s），把「list 本身暫時失敗」跟「真的回空陣列」
# 分開（m1：前者原本會被誤判成「物件不存在」，觸發不必要的重傳，可能撞上 M1 的
# duplicate 情境）；重試耗盡仍失敗就 fail loud 中止，不是靜默當成缺漏或當成都存在。
# --max-time 10（m2）避免卡住的連線無限期掛住（同 storage_put() 的理由）。
existing_objects_body=""
existing_objects_listed=0
existing_objects_retries=0
# N1（LS-240 R2 自測時發現）：這支函式**不能**用 `x=$(list_existing_objects)` 這種command
# substitution 呼叫——command substitution 會把函式丟進子 shell 執行，子 shell 裡的
# `exit 1`（fail loud）只會結束子 shell 本身、父行程渾然不覺並繼續往下跑；`existing_objects_*`
# 這幾個全域變數在子 shell 裡的修改（快取）也不會回寫到父 shell，導致 m1／m2 兩個修法都
# 靜默失效（實測：40 個物件各自重新觸發一次完整重試循環，且持續失敗時腳本沒有真的中止，
# 見自測 R2 除錯過程）。改成直接呼叫（不接 `$()`），用全域變數 `existing_objects_body`
# 傳回結果，讓 `exit`／快取都留在同一個 shell 裡。
list_existing_objects() {   # 設定全域變數 existing_objects_body；只真的打一次
  [ "$existing_objects_listed" -eq 1 ] && return 0
  local resp curl_rc attempt=1 max_retries=3 retry_num=0 delay
  while :; do
    resp=$(curl -sS --max-time 10 -X POST "$API_URL/storage/v1/object/list/media" \
      -H "Authorization: Bearer $SERVICE_KEY" -H "apikey: $SERVICE_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"prefix\":\"${FAMILY_ID}/${SEED_YM}\",\"limit\":200}")
    curl_rc=$?
    case "$resp" in
      \[*\]) break ;;   # 合法 JSON 陣列（含空陣列 []）視為成功回應
    esac
    if [ "$retry_num" -ge "$max_retries" ]; then
      echo "✗ review-demo-seed：--storage-only 列出 Storage 既有物件失敗（重試 ${max_retries} 次仍失敗，curl exit ${curl_rc}），無法判斷缺漏，中止" >&2
      exit 1
    fi
    case "$retry_num" in 0) delay=1 ;; 1) delay=2 ;; *) delay=4 ;; esac
    echo "  ⚠ 列出 Storage 既有物件暫時性錯誤（curl exit ${curl_rc}），${delay}s 後重試（第 $((attempt + 1)) 次嘗試）" >&2
    sleep "$delay"
    retry_num=$((retry_num + 1))
    existing_objects_retries=$((existing_objects_retries + 1))
    attempt=$((attempt + 1))
  done
  existing_objects_body=$resp
  existing_objects_listed=1
}

# LS-240：--storage-only 續傳——判斷物件是否已存在於 Storage（用上面快取的 list 結果本地
# 比對，不逐一物件打網路），已存在就略過、不重新上傳。原本用 HEAD 判斷（票文原意），實測
# 本機 storage-api 對物件下載端點的 HEAD 回應會宣告 Content-Length 卻不實際送出對應 body
# （keep-alive 連線因此掛住直到逾時，curl exit 28；2026-09-13 本機 --target local 全流程
# 驗證時發現，見 handoff）——改用 Storage 既有的 list API，仍沿用既有的 service-role
# Bearer／apikey 認證方式，不新增讀取憑證的管道。
storage_exists() {  # $1=storage path（含 family_id/yyyy/mm/filename，不含 bucket 前綴）
  local path=$1 file
  file=${path##*/}
  list_existing_objects
  case "$existing_objects_body" in
    *"\"name\":\"${file}\""*) return 0 ;;
    *) return 1 ;;
  esac
}

storage_only_all_present=0
if [ "$storage_only" -eq 1 ]; then
  all_present=1
  for i in $(seq 1 20); do
    id=${media_ids[$((i-1))]}
    if [ "$i" -le 18 ]; then
      src_idx=$(( (i - 1) % ${#photo_sources[@]} ))
      ext=$(photo_ext_for "${photo_sources[$src_idx]}")
      orig_path="${FAMILY_ID}/${SEED_YM}/${id}.${ext}"
    else
      orig_path="${FAMILY_ID}/${SEED_YM}/${id}.mp4"
    fi
    thumb_path="${FAMILY_ID}/${SEED_YM}/${id}_thumb.jpg"
    if ! storage_exists "$orig_path" || ! storage_exists "$thumb_path"; then
      all_present=0
      break
    fi
  done
  [ "$all_present" -eq 1 ] && storage_only_all_present=1
fi

if [ "$storage_only_all_present" -eq 1 ]; then
  echo "→ --storage-only：本輪 40 個固定路徑已全部存在於 Storage，略過素材準備／SQL／清理／上傳"
  echo "✓ review-demo-seed --storage-only 完成：0 個物件已上傳、40 個已存在略過，重試 ${existing_objects_retries} 次"
else

work=$(mktemp -d "${TMPDIR:-/tmp}/ls146-review-demo-seed.XXXXXX")
trap 'rm -rf "$work"' EXIT

# ---------------------------------------------------------------------------
# 1. 準備照片素材：沿用既有 design/ 圖檔（不新增二進位檔進 repo），各自產生一份縮圖
#    （長邊 512、JPEG 品質 0.8，docs/API.md §6 縮圖規格），快取重用於多個 media 列。
# ---------------------------------------------------------------------------
mkdir -p "$work/thumbs"
photo_ext=(); photo_ctype=(); photo_bytes=(); photo_w=(); photo_h=(); photo_thumb=(); photo_tw=(); photo_th=()
for idx in "${!photo_sources[@]}"; do
  src=${photo_sources[$idx]}
  ext=$(photo_ext_for "$src")
  case "$ext" in png) ctype=image/png ;; *) ctype=image/jpeg ;; esac
  thumb="$work/thumbs/photo_${idx}_thumb.jpg"
  sips -s format jpeg -s formatOptions 80 -Z 512 "$src" --out "$thumb" >/dev/null
  photo_ext[$idx]=$ext
  photo_ctype[$idx]=$ctype
  photo_bytes[$idx]=$(wc -c < "$src" | tr -d ' ')
  photo_w[$idx]=$(sips -g pixelWidth "$src" | awk '/pixelWidth/{print $2}')
  photo_h[$idx]=$(sips -g pixelHeight "$src" | awk '/pixelHeight/{print $2}')
  photo_thumb[$idx]=$thumb
  photo_tw[$idx]=$(sips -g pixelWidth "$thumb" | awk '/pixelWidth/{print $2}')
  photo_th[$idx]=$(sips -g pixelHeight "$thumb" | awk '/pixelHeight/{print $2}')
done
echo "→ 照片素材備妥（${#photo_sources[@]} 個來源，各含縮圖）"

# ---------------------------------------------------------------------------
# 2. 準備影片素材：AVFoundation 合成（見檔頭「影片素材」說明），各自量測實際秒數與縮圖。
# ---------------------------------------------------------------------------
mkdir -p "$work/videos" "$work/video_thumbs"
video_files=(); video_durations=(); video_thumb=(); video_tw=(); video_th=()
for i in 1 2; do
  vf="$work/videos/video_${i}.mp4"
  secs=$([ "$i" -eq 1 ] && echo 2.4 || echo 3.6)
  dur=$(swift "$ROOT/scripts/ops/review-demo-genvideo.swift" "$vf" "$secs") || {
    echo "✗ review-demo-seed：影片合成失敗（review-demo-genvideo.swift）" >&2; exit 1;
  }
  video_files+=("$vf")
  video_durations+=("$dur")
  qlmanage -t -s 512 -o "$work/video_thumbs" "$vf" >/dev/null 2>&1
  png="$work/video_thumbs/$(basename "$vf").png"
  jpg="$work/video_thumbs/video_${i}_thumb.jpg"
  if [ -f "$png" ]; then
    sips -s format jpeg -s formatOptions 80 -Z 512 "$png" --out "$jpg" >/dev/null
  else
    # qlmanage 偶爾在無 GUI session 產不出縮圖：退回對影片本身做同規格縮放
    # （sips 讀不懂 mp4 內容會失敗，此時保留 photo 來源的第一張縮圖頂替，
    # 好過整個種子腳本中止——僅本機開發防線，正式站需要人工確認縮圖產生正常）。
    cp "${photo_thumb[0]}" "$jpg"
    echo "  ⚠ qlmanage 未產生 video_${i} 縮圖，暫以照片縮圖頂替（本機環境限制，見腳本註解）" >&2
  fi
  video_thumb+=("$jpg")
  video_tw+=("$(sips -g pixelWidth "$jpg" | awk '/pixelWidth/{print $2}')")
  video_th+=("$(sips -g pixelHeight "$jpg" | awk '/pixelHeight/{print $2}')")
done
echo "→ 影片素材備妥（2 支，實測秒數：${video_durations[*]}）"

# ---------------------------------------------------------------------------
# 3. DB：清理＋重建（單一 psql session，postgres 身分繞過 RLS／RPC-only 收斂）
#    LS-240：--storage-only 整段跳過（不動 DB）——這裡面的 SQL 字面組裝也用到
#    OWNER_PASSWORD／OWNER_EMAIL 等只在 storage_only=0 時才會設定的值，一併跳過。
# ---------------------------------------------------------------------------
if [ "$storage_only" -eq 0 ]; then
sql_file="$work/seed.sql"
cat > "$sql_file" <<SQL
\set ON_ERROR_STOP on

-- LS-162 R2（B1 blocker）：email 現在是操作者傳入的參數（見腳本檔頭 --owner-email／
-- --member-email），有可能剛好是「一個真人正在用的信箱」——LS-146 R1 F4 把 auth.users
-- 清理從前綴收斂成精確比對，理由是「prod 執行會誤刪撞名的真實使用者」；LS-162 R1 被
-- reviewer 實跑重現：這個風險從參數化 email 這個正門走回來了（seed exit 0、真實帳號
-- 連同家庭成員關係被靜默換掉）。這裡在**同一份 SQL、同一個 --single-transaction 交易**
-- 內先查：owner／member email 若已存在、且該列 id 不是本腳本固定 uuid（別人的帳號，
-- 不是上一輪種子自己建的）→ raise exception 印出該列 id／created_at／所屬家庭數，
-- 整份回捲、shell 非 0 結束，絕不刪除；不做 shell 先查一次、再送第二個 psql 的
-- check-then-act（那樣會留下窗口）。此檢查對 --target local／prod 一視同仁。
--
-- M1（merge-review R2 blocker）：這裡的比對額外包 lower()——${OWNER_EMAIL}／
-- ${MEMBER_EMAIL} 在 shell 端已正規化成小寫（主要修法，見腳本檔頭 validate_email
-- 呼叫之後那段），這裡的 lower() 是次要防線：GoTrue 對 email 寫入正規化成小寫、
-- 查詢也不分大小寫，若這裡不比對 auth.users.email 欄位本身的小寫形式，遇到不是
-- 這支腳本寫入、casing 不明的既有列時比對仍可能落空——擋不住的後果是 guard 完全
-- 不響、seed 回報成功，但正式站 auth.users 的 email 唯一索引是大小寫敏感的，
-- 同一個人類可見地址會被種出第二列，兩種大小寫寫法最後都登不進去（R2 實跑重現）。
do \$\$
declare
  r record;
  n_families int;
begin
  for r in
    select id, email, created_at from auth.users
    where lower(email) in (lower('${OWNER_EMAIL}'), lower('${MEMBER_EMAIL}'))
      and id not in ('${OWNER_ID}', '${MEMBER_ID}')
  loop
    select count(*) into n_families from public.family_members where user_id = r.id;
    raise exception 'review-demo-seed 拒絕執行：email % 已存在於 auth.users，id=%（created_at=%，所屬家庭數=%）不是本腳本固定 uuid——這是別人的帳號，不會被刪除。請換一個 email，或確認這組地址真的沒人在用。',
      r.email, r.id, r.created_at, n_families;
  end loop;
end;
\$\$;

-- LS-162 方案 B：owner 帳號改用密碼登入，encrypted_password 用 pgcrypto 的
-- crypt(pw, gen_salt('bf', 10))（bcrypt cost 10，跟 GoTrue 自己建帳號用的 cost
-- 對齊——i-c merge-review R2：pgcrypto 預設 cost 6，這裡明寫 10，一個數字的事）
-- 直接在 SQL 內雜湊——取捨與改走 GoTrue admin API 的說明見腳本檔頭
-- 「--owner-password」段。
--
-- i-b（merge-review R2）：原本查 pg_extension 只驗證「extension 有沒有裝」，沒驗證
-- 「crypt() 這個函式在目前連線的 search_path 下叫不叫得到」——pgcrypto 裝在
-- extensions schema，若 prod 連線的 search_path 不含它，這個檢查會通過、然後在
-- 下面真正呼叫 crypt() 時才炸（雖然一樣在交易內、一樣 fail loud，只是錯誤訊息
-- 離現場遠一點）。改成直接查 crypt(text,text) 這個函式簽章是否 resolvable，
-- 這是 reviewer 驗證過的寫法，同時驗到「裝了」與「叫得到」兩件事。
do \$\$
begin
  if to_regprocedure('crypt(text,text)') is null then
    raise exception 'review-demo-seed 拒絕執行：pgcrypto 的 crypt(text,text) 不可用（extension 未安裝，或裝在目前連線 search_path 找不到的 schema），無法建立 owner 密碼（方案 B 需要它）';
  end if;
end;
\$\$;

-- 冪等清理：固定 family_id 級聯掉 family_members／children／media／diaries／
-- diary_children／comments／reactions／invites／feed_items／feed_item_children；
-- auth.users 這句改用 id（本腳本固定 uuid）而不是 email 當清理鍵（N1）——上面的存在性
-- 檢查已經確保「email 存在但 id 不是我們的」會在到這裡之前就整份回捲，這裡只需要處理
-- 「id 是我們的、email 可能換了」這一種情況：按 id 刪除重建，換 email 重跑才不會撞
-- users_pkey。
delete from public.families where id = '${FAMILY_ID}';
delete from auth.users where id in ('${OWNER_ID}', '${MEMBER_ID}');

-- confirmation_token／recovery_token／email_change_token_new／email_change 四欄在
-- auth.users 沒有欄位預設值（\d auth.users 實測：其餘 token 類欄位皆有 ''::character
-- varying 預設，唯獨這四個沒有）——supabase/tests/00_fixtures.sql 省略這四欄插入時
-- 落成 NULL 對 RLS 測試無妨（fixtures 只用 SET request.jwt.claims 偽造身分，從不
-- 真的打 GoTrue API），但這裡要讓帳號真的能走 GoTrue 登入（owner 密碼／member Email
-- OTP）：GoTrue（Go）用非 nullable 的 string 欄位掃這四欄，掃到 NULL 直接 500
-- （"converting NULL to string is unsupported"，LS-146 實測在本機 Mailpit 打 /otp 時
-- 炸出來）。真正由 GoTrue 建立的使用者這四欄恆為空字串，這裡比照補上，不留 NULL。
-- LS-162 方案 B：owner 另外補 encrypted_password（上面已雜湊）與 email_confirmed_at
-- （grant_type=password 登入要求信箱已確認，不像 OTP 是 /verify 端點事後才補上）；
-- member 維持原樣（OTP 流程會在 /verify 成功時自己補上 email_confirmed_at）。
--
-- M1（merge-review R2）：email 欄位額外包 lower()——次要防線，同上方 guard 的理由；
-- 主要防線是 shell 端已正規化（腳本檔頭 validate_email 呼叫之後那段），這裡的
-- lower() 讓「就算某天那段正規化被改掉」這條 SQL 語句本身仍然正確、不依賴上游。
insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                         email_confirmed_at, created_at, updated_at,
                         raw_app_meta_data, raw_user_meta_data,
                         confirmation_token, recovery_token, email_change_token_new, email_change)
values
  ('${OWNER_ID}', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', lower('${OWNER_EMAIL}'),
   crypt('${OWNER_PASSWORD}', gen_salt('bf', 10)), now(), now(), now(), '{}', '{}', '', '', '', ''),
  ('${MEMBER_ID}', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', lower('${MEMBER_EMAIL}'),
   NULL, NULL, now(), now(), '{}', '{}', '', '', '', '');

-- auth.users 的 AFTER INSERT trigger 已自動建立 profiles 列（display_name 推導自
-- email），這裡 on conflict 覆寫成好認的顯示名稱（同 00_fixtures.sql 慣例）。
insert into public.profiles (id, display_name) values
  ('${OWNER_ID}', '審核用家長'),
  ('${MEMBER_ID}', '審核用家人')
on conflict (id) do update set display_name = excluded.display_name;

-- families 的 AFTER INSERT trigger（add_creator_as_owner）會把 created_by 寫成 owner，
-- 這裡只需要再補 member。
insert into public.families (id, name, created_by) values
  ('${FAMILY_ID}', '審核示範家庭', '${OWNER_ID}');

insert into public.family_members (family_id, user_id, role, can_upload) values
  ('${FAMILY_ID}', '${MEMBER_ID}', 'member', true);

insert into public.children (id, family_id, name, birthday) values
  ('${CHILD1_ID}', '${FAMILY_ID}', '小樹', date '2022-04-12'),
  ('${CHILD2_ID}', '${FAMILY_ID}', '小果', date '2024-01-08');

-- 長期有效邀請碼：直寫繞過 create_invite RPC 的 30 天上限（docs/API.md §4，見腳本檔頭）。
insert into public.invites (id, family_id, code, role, created_by, max_uses, used_count, expires_at)
values ('${INVITE_ID}', '${FAMILY_ID}', '${INVITE_CODE}', 'member', '${OWNER_ID}', 20, 0,
        now() + interval '3 years');
SQL

# ---- media（20 列：18 張照片＋2 支影片）----
{
  echo "insert into public.media"
  echo "  (id, family_id, storage_path, thumb_path, thumb_width, thumb_height, type,"
  echo "   byte_size, taken_at, width, height, uploaded_by, duration_seconds) values"
  n=20
  for i in $(seq 1 "$n"); do
    id=${media_ids[$((i-1))]}
    uploader=$([ $((i % 2)) -eq 0 ] && echo "$MEMBER_ID" || echo "$OWNER_ID")
    days_ago=$((n - i))
    if [ "$i" -le 18 ]; then
      src_idx=$(( (i - 1) % ${#photo_sources[@]} ))
      ext=${photo_ext[$src_idx]}
      storage_path="${FAMILY_ID}/${SEED_YM}/${id}.${ext}"
      thumb_path="${FAMILY_ID}/${SEED_YM}/${id}_thumb.jpg"
      row="'${id}', '${FAMILY_ID}', '${storage_path}', '${thumb_path}', ${photo_tw[$src_idx]}, ${photo_th[$src_idx]}, 'photo', ${photo_bytes[$src_idx]}, now() - interval '${days_ago} days', ${photo_w[$src_idx]}, ${photo_h[$src_idx]}, '${uploader}', NULL"
    else
      vidx=$((i - 19))   # 0 或 1
      vbytes=$(wc -c < "${video_files[$vidx]}" | tr -d ' ')
      storage_path="${FAMILY_ID}/${SEED_YM}/${id}.mp4"
      thumb_path="${FAMILY_ID}/${SEED_YM}/${id}_thumb.jpg"
      row="'${id}', '${FAMILY_ID}', '${storage_path}', '${thumb_path}', ${video_tw[$vidx]}, ${video_th[$vidx]}, 'video', ${vbytes}, now() - interval '${days_ago} days', 640, 480, '${uploader}', ${video_durations[$vidx]}"
    fi
    sep=$([ "$i" -lt "$n" ] && echo "," || echo ";")
    printf "  (%s)%s\n" "$row" "$sep"
  done
} >> "$sql_file"

# ---- albums（1 本）＋ album_media（20 筆連結，sort_order 0–19）----
# LS-281。三件事值得寫下來：
#   1. 位置：必須排在 media insert 之後——albums_cover_same_family_fkey 是
#      (family_id, cover_media_id) → public.media (family_id, id) 的複合外鍵，封面那筆
#      media 不存在就建不起來；album_media 的兩條複合外鍵同理。
#   2. 順序：sort_order 直接取 media_ids 的順序（0–19）。media_ids 是
#      printf 'd3000000-…-%012x' i 依 i=1..20 產生的，而照片素材是
#      src_idx=(i-1)%5 逐一輪替 photo_sources——所以「media_ids 的順序」就是票文說的
#      「photo_sources 順序」，相簿裡照片的排列與時間軸的種子順序一致，不另外排序。
#   3. 冪等：以「同 family_id＋同 title＋未軟刪」查找既有相簿，查得到就沿用它的 id、
#      不重建（不是靠 ALBUM_ID 主鍵衝突）——整份種子重跑時家庭已被刪掉、這裡一定是
#      新建；但正式站補資料走的是「只補相簿＋連結、不重灌家庭」的路徑（見
#      .claude/evidence/LS-281/ 的套用 SQL，與這段同一個形狀），那裡相簿可能已經存在，
#      查找式冪等讓同一段 SQL 兩條路徑都安全。album_media 的 on conflict do nothing
#      則讓連結本身可重複執行；已經被 diary_media（或本表）引用過的 media 不會因此多出
#      第二筆連結列。
# 為什麼要有這本相簿：見上方 ALBUM_ID 常數的註解（LS-213 每日軟刪排程）。
{
  cat <<SQL
do \$\$
declare
  v_album_id uuid;
begin
  select id into v_album_id
    from public.albums
   where family_id = '${FAMILY_ID}' and title = '${ALBUM_TITLE}' and deleted_at is null;

  if v_album_id is null then
    insert into public.albums (id, family_id, title, cover_media_id, created_by)
    values ('${ALBUM_ID}', '${FAMILY_ID}', '${ALBUM_TITLE}', '${media_ids[2]}', '${OWNER_ID}')
    returning id into v_album_id;
  end if;

  insert into public.album_media (album_id, media_id, family_id, sort_order)
  select v_album_id, s.media_id, '${FAMILY_ID}', s.sort_order
    from (values
SQL
  for i in $(seq 1 20); do
    sep=$([ "$i" -lt 20 ] && echo "," || echo "")
    printf "      ('%s'::uuid, %s)%s\n" "${media_ids[$((i-1))]}" "$((i - 1))" "$sep"
  done
  cat <<SQL
    ) as s(media_id, sort_order)
  on conflict (album_id, media_id) do nothing;
end;
\$\$;
SQL
} >> "$sql_file"

# ---- diaries（5 則；author 交替 owner/member）＋ diary_children（多寶貝標記：#3、#5 同時標兩個孩子）----
diary_bodies=(
  "今天小樹自己在客廳走了好幾步，笑得好開心。"
  "小果第一次翻身成功，全家都在旁邊歡呼。"
  "帶小樹跟小果去公園曬太陽，兩個都睡得很熟。"
  "小樹會說「謝謝」了，講得字正腔圓。"
  "難得兩個孩子同時睡午覺，家裡安靜得不可思議。"
)
diary_children_map=("$CHILD1_ID" "$CHILD2_ID" "${CHILD1_ID},${CHILD2_ID}" "$CHILD1_ID" "${CHILD1_ID},${CHILD2_ID}")
{
  echo "insert into public.diaries (id, family_id, author_id, body, entry_date) values"
  for i in 1 2 3 4 5; do
    did=${diary_ids[$((i-1))]}
    author=$([ $((i % 2)) -eq 0 ] && echo "$MEMBER_ID" || echo "$OWNER_ID")
    days_ago=$((6 - i))
    body=${diary_bodies[$((i-1))]}
    sep=$([ "$i" -lt 5 ] && echo "," || echo ";")
    printf "  ('%s', '%s', '%s', '%s', current_date - %s)%s\n" "$did" "$FAMILY_ID" "$author" "$body" "$days_ago" "$sep"
  done
  echo "insert into public.diary_children (family_id, diary_id, child_id) values"
  rows=()
  for i in 1 2 3 4 5; do
    did=${diary_ids[$((i-1))]}
    IFS=',' read -ra kids <<< "${diary_children_map[$((i-1))]}"
    for cid in "${kids[@]}"; do
      rows+=("  ('${FAMILY_ID}', '${did}', '${cid}')")
    done
  done
  total=${#rows[@]}
  for idx in "${!rows[@]}"; do
    sep=$([ "$idx" -lt $((total - 1)) ] && echo "," || echo ";")
    printf "%s%s\n" "${rows[$idx]}" "$sep"
  done
} >> "$sql_file"

# ---- comments（4）：留言目標打散在照片與日記上 ----
cat >> "$sql_file" <<SQL
insert into public.comments (id, family_id, target_type, target_id, author_id, body) values
  ('${comment_ids[0]}', '${FAMILY_ID}', 'media', '${media_ids[0]}', '${MEMBER_ID}', '拍得好可愛！'),
  ('${comment_ids[1]}', '${FAMILY_ID}', 'diary', '${diary_ids[2]}', '${MEMBER_ID}', '兩個都好乖，辛苦你們了。'),
  ('${comment_ids[2]}', '${FAMILY_ID}', 'media', '${media_ids[5]}', '${OWNER_ID}', '這張要洗出來放相框。'),
  ('${comment_ids[3]}', '${FAMILY_ID}', 'diary', '${diary_ids[0]}', '${OWNER_ID}', '第一次走路真的是大事！');

insert into public.reactions (id, family_id, target_type, target_id, user_id) values
  ('${reaction_ids[0]}', '${FAMILY_ID}', 'media', '${media_ids[0]}', '${OWNER_ID}'),
  ('${reaction_ids[1]}', '${FAMILY_ID}', 'media', '${media_ids[0]}', '${MEMBER_ID}'),
  ('${reaction_ids[2]}', '${FAMILY_ID}', 'diary', '${diary_ids[2]}', '${MEMBER_ID}'),
  ('${reaction_ids[3]}', '${FAMILY_ID}', 'diary', '${diary_ids[0]}', '${OWNER_ID}');

-- 自我檢查：跟票面驗收數字一一對上，冪等重跑時這裡的數字不應改變。
do \$\$
declare
  n_members int; n_children int; n_media int; n_diaries int; n_diary_children int;
  n_comments int; n_reactions int; n_invites int; n_feed int; used bigint;
  n_albums int; n_album_media int; n_unlinked int;
begin
  select count(*) into n_members from public.family_members where family_id = '${FAMILY_ID}';
  select count(*) into n_children from public.children where family_id = '${FAMILY_ID}';
  select count(*) into n_media from public.media where family_id = '${FAMILY_ID}';
  select count(*) into n_diaries from public.diaries where family_id = '${FAMILY_ID}';
  select count(*) into n_diary_children from public.diary_children where family_id = '${FAMILY_ID}';
  select count(*) into n_comments from public.comments where family_id = '${FAMILY_ID}';
  select count(*) into n_reactions from public.reactions where family_id = '${FAMILY_ID}';
  select count(*) into n_invites from public.invites where family_id = '${FAMILY_ID}';
  select count(*) into n_feed from public.feed_items where family_id = '${FAMILY_ID}';
  select storage_used_bytes into used from public.families where id = '${FAMILY_ID}';
  select count(*) into n_albums from public.albums
   where family_id = '${FAMILY_ID}' and deleted_at is null;
  select count(*) into n_album_media from public.album_media where family_id = '${FAMILY_ID}';
  -- LS-281 的核心保證：這個數字只要不是 0，明天凌晨 03:30 的
  -- private.soft_delete_unreferenced_media() 就會把這些列軟刪掉（判準逐字對齊
  -- 20260906050606_soft_delete_unreferenced_media.sql：deleted_at is null＋
  -- type in ('photo','video')＋不掛在任何 diary_media／album_media；那支函式另有
  -- created_at 超過 24h 的寬限期，這裡刻意**不**加寬限期條件——種子剛寫入的列在寬限期
  -- 內看起來還是安全的，但 24 小時後就不是了，自我檢查要抓的正是這種「今天綠、明天被洗掉」。
  select count(*) into n_unlinked from public.media m
   where m.family_id = '${FAMILY_ID}'
     and m.deleted_at is null
     and m.type in ('photo', 'video')
     and not exists (select 1 from public.diary_media dm
                      where dm.family_id = m.family_id and dm.media_id = m.id)
     and not exists (select 1 from public.album_media am
                      where am.family_id = m.family_id and am.media_id = m.id);

  -- families 的 AFTER INSERT trigger（add_creator_as_owner）會把 owner 自己也寫進
  -- family_members（同 00_fixtures.sql 的既有慣例：owner 不是額外角色，是這張表裡的
  -- 一列）——這裡只顯式 INSERT 了 member 一列，加上 trigger 補的 owner 一列，共 2。
  if n_members <> 2 then raise exception 'SEED FAIL：family_members（owner+member）應為 2，實際 %', n_members; end if;
  if n_children <> 2 then raise exception 'SEED FAIL：children 應為 2，實際 %', n_children; end if;
  if n_media <> 20 then raise exception 'SEED FAIL：media 應為 20，實際 %', n_media; end if;
  if n_diaries <> 5 then raise exception 'SEED FAIL：diaries 應為 5，實際 %', n_diaries; end if;
  if n_diary_children <> 7 then raise exception 'SEED FAIL：diary_children 應為 7（1+1+2+1+2），實際 %', n_diary_children; end if;
  if n_comments <> 4 then raise exception 'SEED FAIL：comments 應為 4，實際 %', n_comments; end if;
  if n_reactions <> 4 then raise exception 'SEED FAIL：reactions 應為 4，實際 %', n_reactions; end if;
  if n_invites <> 1 then raise exception 'SEED FAIL：invites 應為 1，實際 %', n_invites; end if;
  -- LS-281：feed_items 從 25 變 26——albums_feed_insert（20260822120100_triggers.sql
  -- 第 2 段的 private.feed_sync_albums()）會替新相簿補一列 kind='album' 的時間軸項目。
  if n_feed <> 26 then raise exception 'SEED FAIL：feed_items 應為 26（20 media + 5 diary + 1 album），實際 %', n_feed; end if;
  if used <= 0 then raise exception 'SEED FAIL：storage_used_bytes 應 > 0，實際 %', used; end if;
  if n_albums <> 1 then raise exception 'SEED FAIL：albums 應為 1（${ALBUM_TITLE}），實際 %', n_albums; end if;
  if n_album_media <> 20 then raise exception 'SEED FAIL：album_media 應為 20（20 筆 media 全數掛進相簿），實際 %', n_album_media; end if;
  if n_unlinked <> 0 then raise exception 'SEED FAIL：未掛任何 diary_media／album_media 的未刪 media 應為 0（否則會被 LS-213 每日 03:30 排程軟刪），實際 %', n_unlinked; end if;

  raise notice 'ok review-demo-seed：members(owner+member)=2 children=2 media=20 albums=1 album_media=20 unlinked_media=0 diaries=5 diary_children=7 comments=4 reactions=4 invites=1 feed_items=26 storage_used_bytes=%', used;
end;
\$\$;
SQL
fi

if [ "$storage_only" -eq 1 ]; then
  echo "→ --storage-only：跳過 SQL 段與帳號建立，沿用既有 DB 資料"
else
  echo "→ 套用 SQL（${sql_file}）"
  # N1（merge-review R2）：這句失敗時 --single-transaction（F2）已經把 DB 完整回捲，Storage
  # 這裡還沒被碰過（清理搬到下面、SQL 成功之後才做，見下）——「中止」現在才真的是全有或
  # 全無，訊息不再誤導操作者以為「回捲了＝什麼都沒動」卻其實 Storage 已經被清空。
  run_sql "$sql_file" || { echo "✗ review-demo-seed：SQL 套用失敗（見上方錯誤），中止——DB 已回捲，Storage 未動（清理與上傳都排在 SQL 成功之後）" >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# 4. Storage：清理舊物件＋上傳新物件（DB 已確認寫入成功才動 Storage，這是本步驟排在 SQL
#    之後的唯一理由——見下方 N1 說明）
# ---------------------------------------------------------------------------
# N1（merge-review R2）：清理原本是最先做的「step 1」，SQL 若在中段失敗，
# --single-transaction（F2）能讓 DB 完整回捲，但已經刪掉的 40 個 Storage 物件無從回捲——
# DB 看起來完好、Storage 卻是空的，20 筆 media 的 storage_path／thumb_path 全指向不存在
# 的物件（reviewer 實跑重現：storage_objects 40→0、orphan 20/20；重跑會自癒，但當下就是
# 20 張破圖，App Review 沒有第二次機會）。搬到這裡（SQL 成功之後、上傳之前）之後，SQL
# 失敗時 Storage 原封不動，真正做到全有或全無；這裡只依賴 media_ids／FAMILY_ID／
# SEED_YM／API_URL／SERVICE_KEY，在 SQL 之前就已備妥，搬動不影響清理本身的正確性。
# LS-240：--storage-only 整段跳過清理——續傳的前提是先前已成功上傳的物件還在，清理會把
# 它們也刪掉，違背「續傳」的本意。
if [ "$storage_only" -eq 1 ]; then
  echo "→ --storage-only：略過批次清理（續傳只補缺物件，不清掉先前已成功上傳的內容）"
else
  echo "→ 清理既有 Storage 物件（$FAMILY_ID/$SEED_YM/…）"
  del_paths_json="["
  first=1
  add_path() {
    [ "$first" -eq 1 ] || del_paths_json="${del_paths_json},"
    del_paths_json="${del_paths_json}\"${1}\""
    first=0
  }
  for id in "${media_ids[@]}"; do
    # 縮圖副檔名恆為 .jpg（docs/API.md §6），只有一種可能，不必列舉
    add_path "${FAMILY_ID}/${SEED_YM}/${id}_thumb.jpg"
    # 原檔副檔名依素材種類而定（4 種可能），這裡是「清舊資料」的寬鬆一步——列出全部
    # 可能副檔名，不存在的路徑由 Storage API 靜默忽略，比對照 DB 現況窄縮更省事、也更
    # 保守（換了素材來源時舊副檔名的孤兒物件也會一併清掉）。
    for ext in jpg jpeg png mp4; do
      add_path "${FAMILY_ID}/${SEED_YM}/${id}.${ext}"
    done
  done
  del_paths_json="${del_paths_json}]"
  # F3（merge-review R1）：加 -f 讓非 2xx 直接判定失敗——這裡失敗時 DB 已經是最新狀態，
  # Storage 物件則新舊混雜（有些清了、有些沒清），不是「什麼都沒動」，訊息據實反映。
  if ! curl -sS -f -X DELETE "$API_URL/storage/v1/object/media" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "apikey: $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"prefixes\":${del_paths_json}}" -o /dev/null; then
    echo "✗ review-demo-seed：Storage 批次刪除失敗（$API_URL/storage/v1/object/media）——DB 已重建完成，Storage 物件可能新舊混雜；重跑一次會自動收斂（清理具冪等性）" >&2
    exit 1
  fi
  echo "  ✓ 批次刪除請求已送出（不存在的路徑會被忽略）"
fi

# ---------------------------------------------------------------------------
# LS-240：上傳重試——curl exit 56／7／28（連線／接收/逾時失敗）或 HTTP 5xx／429（伺服器
# 端暫時性錯誤）最多重試 3 次、退避 1s→2s→4s；其餘錯誤（其他 curl exit、4xx 除 429）視為
# 永久性錯誤，不重試立刻回報失敗。改用 `-w '%{http_code}'` 取代原本的 `-f`——`-f` 會把所有
# HTTP >=400 一律轉成 curl exit 22，沒辦法分辨「該重試的 5xx／429」跟「不該重試的其他
# 4xx」；sleep 呼叫外部命令，自測以 PATH 前置假身注入拉快測試，正式路徑不變。
#
# M1（merge-review R1 major）：重試對「同一個 path」原樣重送非冪等的 POST——若第一次嘗試
# 其實已經把物件寫進去了、只是回應階段斷掉（curl exit 56／28／504 依定義都發生在 body
# 送出之後，正是 LS-96 池項 `3f23757a` 那次事故的形狀），重送會撞 duplicate。reviewer 實測
# 本機 storage-api：同 path 重送回 **HTTP 400**（body code＝`KeyAlreadyExists`，不是 409），
# 原本的 `is_retryable_http` 不含 400 → 判定成永久性錯誤、印「不重試」中止，本票要救的
# 情境反而救不到。修法：第 2 次起的嘗試加 `-H "x-upsert: true"`（reviewer 實測回 200 且
# `Id` 與首傳相同，等同覆寫成功）；首次嘗試維持不加，保留「不該存在卻存在」這個訊號。
# ---------------------------------------------------------------------------
upload_ok_count=0
upload_skip_count=0
upload_retry_count=0
is_retryable_curl_rc() { case "$1" in 56|7|28) return 0 ;; *) return 1 ;; esac; }
is_retryable_http() { case "$1" in 5??|429) return 0 ;; *) return 1 ;; esac; }

storage_put() {  # $1=本機檔案 $2=storage path（不含 bucket 前綴） $3=content-type
  local file=$1 path=$2 ctype=$3
  local attempt=1 max_retries=3 retry_num=0 delay http_code curl_rc
  local upsert_hdr=()
  while :; do
    # M1：第 2 次起（重試）才加 x-upsert，讓「其實已落地」的重送變成覆寫成功而不是
    # duplicate 錯誤；--max-time 30（m2）避免卡住的連線無限期掛住，讓 curl exit 28
    # 真的能觸發、進到上面這條重試路徑，而不是腳本整支卡死。
    if [ "$attempt" -gt 1 ]; then upsert_hdr=(-H "x-upsert: true"); else upsert_hdr=(); fi
    http_code=$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -X POST "$API_URL/storage/v1/object/media/$path" \
      -H "Authorization: Bearer $SERVICE_KEY" -H "apikey: $SERVICE_KEY" \
      -H "Content-Type: $ctype" ${upsert_hdr[@]+"${upsert_hdr[@]}"} --data-binary "@$file")
    curl_rc=$?
    [ -n "$http_code" ] || http_code=000
    if [ "$curl_rc" -eq 0 ]; then
      case "$http_code" in
        2??)
          upload_ok_count=$((upload_ok_count + 1))
          [ "$attempt" -eq 1 ] || echo "  ✓ 上傳成功（第 ${attempt} 次嘗試，重試 ${retry_num} 次）：$path" >&2
          return 0 ;;
      esac
    fi
    if { [ "$curl_rc" -ne 0 ] && is_retryable_curl_rc "$curl_rc"; } || { [ "$curl_rc" -eq 0 ] && is_retryable_http "$http_code"; }; then
      if [ "$retry_num" -ge "$max_retries" ]; then
        echo "✗ 上傳失敗（重試 ${max_retries} 次仍失敗，curl exit ${curl_rc}，HTTP ${http_code}）：$path" >&2
        return 1
      fi
      case "$retry_num" in 0) delay=1 ;; 1) delay=2 ;; *) delay=4 ;; esac
      echo "  ⚠ 上傳暫時性錯誤（curl exit ${curl_rc}，HTTP ${http_code}），${delay}s 後重試（第 $((attempt + 1)) 次嘗試）：$path" >&2
      sleep "$delay"
      retry_num=$((retry_num + 1))
      upload_retry_count=$((upload_retry_count + 1))
      attempt=$((attempt + 1))
      continue
    fi
    echo "✗ 上傳失敗（curl exit ${curl_rc}，HTTP ${http_code}，不重試）：$path" >&2
    return 1
  done
}

# LS-240 R2：storage_exists()／list_existing_objects() 已提早到素材準備之前定義（見上方
# 「--storage-only 最常見的情境」區塊，merge-review m1／m2），這裡不重複定義。

ensure_uploaded() {  # $1=本機檔案 $2=storage path $3=content-type
  if [ "$storage_only" -eq 1 ] && storage_exists "$2"; then
    echo "  · Storage 已有此物件，略過：$2" >&2
    upload_skip_count=$((upload_skip_count + 1))
    return 0
  fi
  storage_put "$1" "$2" "$3"
}

echo "→ 上傳 Storage 物件"
for i in $(seq 1 18); do
  id=${media_ids[$((i-1))]}
  src_idx=$(( (i - 1) % ${#photo_sources[@]} ))
  ensure_uploaded "${photo_sources[$src_idx]}" "${FAMILY_ID}/${SEED_YM}/${id}.${photo_ext[$src_idx]}" "${photo_ctype[$src_idx]}" \
    || { echo "✗ 上傳原圖失敗：media_id=$id" >&2; exit 1; }
  ensure_uploaded "${photo_thumb[$src_idx]}" "${FAMILY_ID}/${SEED_YM}/${id}_thumb.jpg" "image/jpeg" \
    || { echo "✗ 上傳縮圖失敗：media_id=$id" >&2; exit 1; }
done
for i in 19 20; do
  id=${media_ids[$((i-1))]}
  vidx=$((i - 19))
  ensure_uploaded "${video_files[$vidx]}" "${FAMILY_ID}/${SEED_YM}/${id}.mp4" "video/mp4" \
    || { echo "✗ 上傳影片失敗：media_id=$id" >&2; exit 1; }
  ensure_uploaded "${video_thumb[$vidx]}" "${FAMILY_ID}/${SEED_YM}/${id}_thumb.jpg" "image/jpeg" \
    || { echo "✗ 上傳影片縮圖失敗：media_id=$id" >&2; exit 1; }
done
if [ "$storage_only" -eq 1 ]; then
  echo "✓ review-demo-seed --storage-only 完成：${upload_ok_count} 個物件已上傳、${upload_skip_count} 個已存在略過，重試 ${upload_retry_count} 次"
else
  echo "✓ review-demo-seed 完成：${upload_ok_count} 個物件已上傳（20 個原檔 + 20 個縮圖），重試 ${upload_retry_count} 次，DB 計數見上方 NOTICE"
  echo "  邀請碼：${INVITE_CODE}　owner：${OWNER_EMAIL}（密碼登入，密碼見上方僅印一次的提示或操作者自帶的 --owner-password）　member：${MEMBER_EMAIL}（Email OTP）"
fi

fi   # 關閉 storage_only_all_present 的 if／else（LS-240 R2 merge-review m2）
