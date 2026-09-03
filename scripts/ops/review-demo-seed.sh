#!/bin/bash
# LS-146 — 審核用 demo 帳號＋示範家庭資料種子（PLAN §9-B「審核用 demo 帳號」）
#
# 目的：App Store 審核員全新裝置只憑 docs/store/review-notes.md 的帳號資訊，就要能
# 走完登入→時間軸→相簿→留言。這支腳本建立那個「審核專用家庭」：owner＋member 各一個
# 帳號、2 個孩子檔案、20 筆 media（18 張照片＋2 支影片，含縮圖三欄與 duration_seconds）、
# 5 則日記（含多寶貝標記）、留言與愛心反應、一組長期有效的邀請碼。
#
# 冪等：所有資料以固定 UUID（見下方常數）＋email 前綴 review-demo@ 標記；每次執行先刪除
# 同一標記的既有資料（DB 用 family_id 級聯、Storage 用同一組固定路徑批次刪除）再重建，
# 可重複執行、計數不變。
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
#   bash scripts/ops/review-demo-seed.sh --target prod --yes          種正式站（讀 .env 取連線，見下）
#
# 環境：
#   --target local：用 `supabase status -o env` 取得本機 DB_URL／API_URL／SERVICE_ROLE_KEY。
#   --target prod --yes：`source .env` 後讀 SUPABASE_DB_URL／SUPABASE_URL／
#     SUPABASE_SERVICE_ROLE_KEY 三個環境變數（本腳本不印出其值，也不嘗試從
#     SUPABASE_ACCESS_TOKEN／SUPABASE_DB_PASSWORD 反推連線字串——正式站連線資訊需要
#     操作者自己先把這三個變數放進 .env；截至 LS-146 撰寫當下 .env 尚未定義它們，
#     見 PR body／handoff）。
#
# 本票只做本機驗證：LS-146 不會以 --target prod --yes 執行，正式站落地留待使用者核可。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() { echo "用法：review-demo-seed.sh --target local|prod [--yes]"; }

# F1（merge-review R1）：":133" 要在還沒在 lock 內時把原始參數原封不動 re-exec 進
# supabase-lock.sh，但下面的解析迴圈會把 "$@" shift 光——先存一份不受影響的副本。
# bash 3.2 + set -u 下展開可能為空的陣列要用 ${arr[@]+"${arr[@]}"} 這個寫法（PR #122
# 系列既有慣例，同 supabase-lock.sh 的陣列處理）。
orig_args=("$@")

target=""
yes=0
while [ $# -gt 0 ]; do
  case "$1" in
    --target) target=${2:-}; shift 2 ;;
    --yes) yes=1; shift ;;
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
INVITE_CODE=LSDEMO
OWNER_EMAIL=review-demo@little-sprout.app
MEMBER_EMAIL=review-demo-member@little-sprout.app
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
  cat <<PLAN
→ 審核用 demo 資料種子計畫（LS-146，target=${target}）
  family_id：${FAMILY_ID}（審核家庭）
  帳號：owner ${OWNER_EMAIL}／member ${MEMBER_EMAIL}（Email OTP 登入）
  孩子檔案：2（${CHILD1_ID}／${CHILD2_ID}）
  media：20（18 張照片＋2 支影片，縮圖三欄＋duration_seconds 皆補齊）
  日記：5（含多寶貝標記：其中 2 篇同時標 2 個孩子）
  留言／愛心：各 4
  邀請碼：${INVITE_CODE}（直寫 expires_at=now()+3年，繞過 create_invite RPC 的 30 天上限）
  冪等：重跑先刪除 family_id=$FAMILY_ID 與 email like 'review-demo%' 的既有資料（DB 級聯＋
        Storage 依固定路徑批次刪除），計數不因重跑改變
PLAN
}

if [ "$target" = prod ]; then
  print_plan
  if [ "$yes" -ne 1 ]; then
    echo "（未帶 --yes：只印計畫，不連線、不寫入任何資料——LS-146 本票就停在這裡，正式站落地待使用者核可）"
    exit 0
  fi
  echo "⚠ review-demo-seed：--target prod --yes，即將對正式站寫入審核用 demo 資料" >&2
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

command -v sips >/dev/null 2>&1 || { echo "✗ review-demo-seed：找不到 sips（macOS 內建工具）" >&2; exit 2; }
command -v swift >/dev/null 2>&1 || { echo "✗ review-demo-seed：找不到 swift CLI" >&2; exit 2; }

# psql 不一定裝在 host 上；沒有的話借用 supabase 本機 DB container 裡那一份（同
# supabase/tests/run.sh 既有慣例）——這條路徑只在 --target local 用得到，prod 一律要求
# host 有 psql（正式站不會借用本機 docker container）。
db_container="${SUPABASE_DB_CONTAINER:-supabase_db_little-sprout}"
if command -v psql >/dev/null 2>&1; then
  run_sql() { psql "$DB_URL" -v ON_ERROR_STOP=1 --no-psqlrc -q -f "$1"; }
elif [ "$target" = local ] && docker exec "$db_container" true >/dev/null 2>&1; then
  echo "→ host 沒有 psql，改用 docker exec ${db_container}" >&2
  run_sql() { docker exec -i "$db_container" psql -U postgres -d postgres -v ON_ERROR_STOP=1 --no-psqlrc -q < "$1"; }
else
  echo "✗ review-demo-seed：找不到 psql，也連不到 DB container（${db_container}）" >&2
  exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/ls146-review-demo-seed.XXXXXX")
trap 'rm -rf "$work"' EXIT

# ---------------------------------------------------------------------------
# 1. Storage 清理（先刪，冪等）：路徑完全由固定 media_ids＋固定 SEED_YM 決定，不必先 list。
# ---------------------------------------------------------------------------
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
curl -sS -X DELETE "$API_URL/storage/v1/object/media" \
  -H "Authorization: Bearer $SERVICE_KEY" -H "apikey: $SERVICE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"prefixes\":${del_paths_json}}" -o /dev/null
echo "  ✓ 批次刪除請求已送出（不存在的路徑會被忽略）"

# ---------------------------------------------------------------------------
# 2. 準備照片素材：沿用既有 design/ 圖檔（不新增二進位檔進 repo），各自產生一份縮圖
#    （長邊 512、JPEG 品質 0.8，docs/API.md §6 縮圖規格），快取重用於多個 media 列。
# ---------------------------------------------------------------------------
photo_sources=(
  "$ROOT/design-canvas/family.jpg"
  "$ROOT/design-canvas-d/family.jpg"
  "$ROOT/design/hero-grandma.png"
  "$ROOT/design/invite-grandma.png"
  "$ROOT/design/join-parents.png"
)
for f in "${photo_sources[@]}"; do
  [ -f "$f" ] || { echo "✗ review-demo-seed：找不到照片素材 $f" >&2; exit 1; }
done

mkdir -p "$work/thumbs"
photo_ext=(); photo_ctype=(); photo_bytes=(); photo_w=(); photo_h=(); photo_thumb=(); photo_tw=(); photo_th=()
for idx in "${!photo_sources[@]}"; do
  src=${photo_sources[$idx]}
  case "$src" in
    *.png) ext=png; ctype=image/png ;;
    *) ext=jpg; ctype=image/jpeg ;;
  esac
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
# 3. 準備影片素材：AVFoundation 合成（見檔頭「影片素材」說明），各自量測實際秒數與縮圖。
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
# 4. DB：清理＋重建（單一 psql session，postgres 身分繞過 RLS／RPC-only 收斂）
# ---------------------------------------------------------------------------
sql_file="$work/seed.sql"
cat > "$sql_file" <<SQL
\set ON_ERROR_STOP on

-- 冪等清理：固定 family_id 級聯掉 family_members／children／media／diaries／
-- diary_children／comments／reactions／invites／feed_items／feed_item_children；
-- email 前綴 review-demo@ 額外收一次網，涵蓋萬一 family_id 對不上但帳號還在的情況。
delete from public.families where id = '${FAMILY_ID}';
delete from auth.users where email like 'review-demo%';

-- confirmation_token／recovery_token／email_change_token_new／email_change 四欄在
-- auth.users 沒有欄位預設值（\d auth.users 實測：其餘 token 類欄位皆有 ''::character
-- varying 預設，唯獨這四個沒有）——supabase/tests/00_fixtures.sql 省略這四欄插入時
-- 落成 NULL 對 RLS 測試無妨（fixtures 只用 SET request.jwt.claims 偽造身分，從不
-- 真的打 GoTrue API），但這裡要讓帳號真的能走 Email OTP 登入：GoTrue（Go）用非
-- nullable 的 string 欄位掃這四欄，掃到 NULL 直接 500（"converting NULL to string is
-- unsupported"，LS-146 實測在本機 Mailpit 打 /otp 時炸出來）。真正由 GoTrue signup
-- 建立的使用者這四欄恆為空字串，這裡比照補上，不留 NULL。
insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at,
                         raw_app_meta_data, raw_user_meta_data,
                         confirmation_token, recovery_token, email_change_token_new, email_change)
values
  ('${OWNER_ID}', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', '${OWNER_EMAIL}', now(), now(), '{}', '{}', '', '', '', ''),
  ('${MEMBER_ID}', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', '${MEMBER_EMAIL}', now(), now(), '{}', '{}', '', '', '', '');

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
  if n_feed <> 25 then raise exception 'SEED FAIL：feed_items 應為 25（20 media + 5 diary），實際 %', n_feed; end if;
  if used <= 0 then raise exception 'SEED FAIL：storage_used_bytes 應 > 0，實際 %', used; end if;

  raise notice 'ok review-demo-seed：members(owner+member)=2 children=2 media=20 diaries=5 diary_children=7 comments=4 reactions=4 invites=1 feed_items=25 storage_used_bytes=%', used;
end;
\$\$;
SQL

echo "→ 套用 SQL（${sql_file}）"
run_sql "$sql_file" || { echo "✗ review-demo-seed：SQL 套用失敗（見上方錯誤），中止——不繼續上傳 Storage" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 5. Storage：上傳照片＋影片＋縮圖（DB 已確認寫入成功才上傳，讓失敗時容易重跑收斂）
# ---------------------------------------------------------------------------
storage_put() {  # $1=本機檔案 $2=storage path（不含 bucket 前綴） $3=content-type
  curl -sS -f -X POST "$API_URL/storage/v1/object/media/$2" \
    -H "Authorization: Bearer $SERVICE_KEY" -H "apikey: $SERVICE_KEY" \
    -H "Content-Type: $3" --data-binary "@$1" -o /dev/null
}

echo "→ 上傳 Storage 物件"
for i in $(seq 1 18); do
  id=${media_ids[$((i-1))]}
  src_idx=$(( (i - 1) % ${#photo_sources[@]} ))
  storage_put "${photo_sources[$src_idx]}" "${FAMILY_ID}/${SEED_YM}/${id}.${photo_ext[$src_idx]}" "${photo_ctype[$src_idx]}" \
    || { echo "✗ 上傳原圖失敗：media_id=$id" >&2; exit 1; }
  storage_put "${photo_thumb[$src_idx]}" "${FAMILY_ID}/${SEED_YM}/${id}_thumb.jpg" "image/jpeg" \
    || { echo "✗ 上傳縮圖失敗：media_id=$id" >&2; exit 1; }
done
for i in 19 20; do
  id=${media_ids[$((i-1))]}
  vidx=$((i - 19))
  storage_put "${video_files[$vidx]}" "${FAMILY_ID}/${SEED_YM}/${id}.mp4" "video/mp4" \
    || { echo "✗ 上傳影片失敗：media_id=$id" >&2; exit 1; }
  storage_put "${video_thumb[$vidx]}" "${FAMILY_ID}/${SEED_YM}/${id}_thumb.jpg" "image/jpeg" \
    || { echo "✗ 上傳影片縮圖失敗：media_id=$id" >&2; exit 1; }
done
echo "✓ review-demo-seed 完成：20 個原檔 + 20 個縮圖已上傳，DB 計數見上方 NOTICE"
echo "  邀請碼：${INVITE_CODE}　owner：${OWNER_EMAIL}　member：$MEMBER_EMAIL"
