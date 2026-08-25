#!/usr/bin/env bash
# LS-6 — 本地 DB 測試 runner（RLS 隔離／owner 不變量／trigger／RLS plan 效能）
#
# 用法：
#   supabase start（或只要 DB：supabase db start）
#   supabase db reset          # 套用 supabase/migrations
#   bash supabase/tests/run.sh
#
# LS-11：CI（.github/workflows/ci.yml 的 db job）額外帶 SUPABASE_DB_URL＝
# `supabase status -o env` 印出的 DB_URL，走 host psql 那條路；本機／QA 備援沿用
# 既有離散參數（SUPABASE_DB_HOST/PORT/USER/NAME）或 SUPABASE_DB_CONTAINER。
#
# fail loud：任何一個測試檔非 0 結束就立刻中止並回傳非 0，不會有「跳過等於通過」。
# 測試檔本身用 DO 區塊斷言，失敗時 RAISE EXCEPTION，psql 帶 ON_ERROR_STOP 直接非 0 結束。
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
evidence_dir="$here/evidence"

# 連線參數拆開放，不組成含帳密的連線字串：一來 repo 裡不出現任何形似金鑰的字串，
# 二來本機預設值（supabase start 的 shadow DB）本來就不該被當成可攜的設定。
db_host="${SUPABASE_DB_HOST:-127.0.0.1}"
db_port="${SUPABASE_DB_PORT:-54322}"
db_user="${SUPABASE_DB_USER:-postgres}"
db_name="${SUPABASE_DB_NAME:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
container="${SUPABASE_DB_CONTAINER:-supabase_db_little-sprout}"

# LS-11：CI（supabase CLI local stack）用這條——直接吃 `supabase status -o env` 印出的
# DB_URL，不用假設 host/port 剛好對得上 config.toml，換 port 也不必回頭改這個腳本或 CI。
# 沒帶就留空、走下面離散參數那條路：兩者預設值等價，都是 supabase CLI local stack 的
# 標準連線（postgres:postgres@127.0.0.1:54322/postgres），只是給法不同。
db_url="${SUPABASE_DB_URL:-}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$evidence_dir"

# psql 不一定裝在 host 上；沒有的話就借用 supabase 的 DB container 裡那一份。
if command -v psql >/dev/null 2>&1 && [ -n "$db_url" ]; then
  channel="host psql → SUPABASE_DB_URL"
  run_sql() {
    psql "$db_url" -v ON_ERROR_STOP=1 --no-psqlrc -q -f "$1"
  }
elif command -v psql >/dev/null 2>&1; then
  channel="host psql → ${db_host}:${db_port}/${db_name}"
  run_sql() {
    psql -h "$db_host" -p "$db_port" -U "$db_user" -d "$db_name" \
      -v ON_ERROR_STOP=1 --no-psqlrc -q -f "$1"
  }
elif docker exec "$container" true >/dev/null 2>&1; then
  channel="docker exec $container psql"
  run_sql() {
    docker exec -i "$container" \
      psql -U "$db_user" -d "$db_name" -v ON_ERROR_STOP=1 --no-psqlrc -q < "$1"
  }
else
  # ${container} 的大括號是必要的，不是風格：macOS 內建的 bash 3.2 會把緊接在後面的
  # 全形括號「）」的位元組當成變數名稱的一部分，`$container）` 於是變成查一個不存在的
  # 變數，在 set -u 下直接以「unbound variable」中止——正好發生在「連不到 DB、
  # 要印出診斷訊息」的那條路徑上，把真正的失敗原因蓋掉（LS-34 開發時實際踩到）。
  echo "✗ 找不到 psql，也連不到 DB container（${container}）。請先執行 supabase start。" >&2
  exit 1
fi

echo "→ 連線方式：$channel"

# 前置檢查：schema 真的套用了嗎？沒套用就跑測試，會得到一堆看不懂的錯誤
preflight="$tmp/preflight.sql"
cat > "$preflight" <<'SQL'
do $$
begin
  if to_regprocedure('private.family_ids()') is null then
    raise exception '找不到 private.family_ids()：migration 尚未套用，請先執行 supabase db reset';
  end if;
  if not exists (
    select 1 from pg_class c
     where c.relname = 'media' and c.relnamespace = 'public'::regnamespace and c.relrowsecurity
  ) then
    raise exception 'public.media 沒有啟用 RLS：schema 不完整';
  end if;
end;
$$;
SQL
if ! run_sql "$preflight" > "$tmp/preflight.out" 2>&1; then
  cat "$tmp/preflight.out" >&2
  exit 1
fi

for f in "$here"/[0-9][0-9]_*.sql; do
  name="$(basename "$f")"
  out="$tmp/$name.out"
  echo "→ $name"
  if run_sql "$f" > "$out" 2>&1; then
    sed 's/^/    /' "$out"
    echo "  ✓ $name"
  else
    echo "  ✗ $name 失敗：" >&2
    sed 's/^/    /' "$out" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# 併發測試：owner 不變量在 READ COMMITTED 下的序列化
#
# 為什麼不能寫成上面那種單檔 SQL：要重現的時序需要「兩個交易同時開著」，
# 一個 session 內做不到。這裡開兩個真的並行的 psql，用時間差對齊時序：
#   S1  BEGIN → 降級/移除 owner1 →（壓住 3 秒不 commit）→ COMMIT
#   S2  等 1.2 秒 → 降級/移除 owner2 → 必須被阻塞、解除阻塞後必須噴 LS001
# 斷言寫在 S2 與 verify 的 SQL 裡（等待秒數、LS001、最終 owner 數 ≥1）。
# ---------------------------------------------------------------------------
cc_dir="$here/concurrency"

run_sql_bg() {  # $1=sql 檔 $2=輸出檔；結束碼寫到 $2.rc
  # set +e：失敗的結束碼是這裡的觀測目標，不能讓 errexit 把 subshell 直接帶走
  ( set +e; run_sql "$1" > "$2" 2>&1; echo "$?" > "$2.rc" ) &
}

owner_guard_case() {  # $1=場景名 $2=S1 檔名 $3=S2 檔名
  local label="$1" s1="$cc_dir/$2" s2="$cc_dir/$3"
  local s1_out="$tmp/$2.out" s2_out="$tmp/$3.out" setup_out="$tmp/owner_guard_setup.out"
  echo "→ 併發：$label"

  if ! run_sql "$cc_dir/owner_guard_setup.sql" > "$setup_out" 2>&1; then
    echo "  ✗ 併發場景資料建立失敗：" >&2; sed 's/^/    /' "$setup_out" >&2; exit 1
  fi

  run_sql_bg "$s1" "$s1_out"
  run_sql_bg "$s2" "$s2_out"
  wait

  local rc1 rc2 failed=0
  rc1="$(cat "$s1_out.rc")"; rc2="$(cat "$s2_out.rc")"
  sed 's/^/    S1 /' "$s1_out"
  sed 's/^/    S2 /' "$s2_out"
  # ${rc1}／${rc2} 的大括號是必要的，不是風格：macOS 內建的 bash 3.2 會把緊接在後面的
  # 全形括號「）」的位元組當成變數名稱的一部分，`$rc1）` 於是變成查一個不存在的
  # 變數，在 set -u 下直接以「unbound variable」中止——正好發生在「測試失敗、
  # 要印出診斷訊息」的那條路徑上，把真正的失敗原因蓋掉（LS-34 開發時實際踩到）。
  [ "$rc1" = 0 ] || { echo "  ✗ S1 非 0 結束（rc=${rc1}）" >&2; failed=1; }
  [ "$rc2" = 0 ] || { echo "  ✗ S2 非 0 結束（rc=${rc2}）" >&2; failed=1; }

  if ! run_sql "$cc_dir/owner_guard_verify.sql" > "$tmp/owner_guard_verify.out" 2>&1; then
    sed 's/^/    /' "$tmp/owner_guard_verify.out" >&2; failed=1
  else
    sed 's/^/    /' "$tmp/owner_guard_verify.out"
  fi

  [ "$failed" = 0 ] || { echo "  ✗ 併發：$label 失敗" >&2; exit 1; }
  echo "  ✓ 併發：$label"
}

owner_guard_case "同時降級兩位 owner" owner_guard_s1_demote.sql owner_guard_s2_demote.sql
owner_guard_case "同時移除兩位 owner" owner_guard_s1_delete.sql owner_guard_s2_delete.sql

# ---------------------------------------------------------------------------
# LS-33 併發測試：邀請碼名額競態、同一筆申請同時核准與拒絕
#
# 作法與上面的 owner_guard_case 相同（兩個真的並行的 psql，用時間差對齊時序），
# 差別在於這兩個場景的資料與最終狀態斷言各自不同，所以把 setup/s1/s2/verify
# 四個檔案參數化。owner_guard_case 維持原樣不動——它的 setup 與 verify 是寫死的。
# ---------------------------------------------------------------------------
race_case() {  # $1=場景名 $2=setup $3=s1 $4=s2 $5=verify
  local label="$1" setup="$cc_dir/$2" s1="$cc_dir/$3" s2="$cc_dir/$4" verify="$cc_dir/$5"
  local setup_out="$tmp/$2.out" s1_out="$tmp/$3.out" s2_out="$tmp/$4.out" verify_out="$tmp/$5.out"
  echo "→ 併發：$label"

  if ! run_sql "$setup" > "$setup_out" 2>&1; then
    echo "  ✗ 併發場景資料建立失敗：" >&2; sed 's/^/    /' "$setup_out" >&2; exit 1
  fi
  sed 's/^/    setup /' "$setup_out"

  run_sql_bg "$s1" "$s1_out"
  run_sql_bg "$s2" "$s2_out"
  wait

  local rc1 rc2 failed=0
  rc1="$(cat "$s1_out.rc")"; rc2="$(cat "$s2_out.rc")"
  sed 's/^/    S1 /' "$s1_out"
  sed 's/^/    S2 /' "$s2_out"
  # ${rc1} 的大括號是必要的，不是風格：macOS 內建的 bash 3.2 會把緊接在後面的
  # 全形括號「）」的位元組當成變數名稱的一部分，`$rc1）` 於是變成查一個不存在的
  # 變數，在 set -u 下直接以「unbound variable」中止——正好發生在「測試失敗、
  # 要印出診斷訊息」的那條路徑上，把真正的失敗原因蓋掉（本票開發時實際踩到）。
  [ "$rc1" = 0 ] || { echo "  ✗ S1 非 0 結束（rc=${rc1}）" >&2; failed=1; }
  [ "$rc2" = 0 ] || { echo "  ✗ S2 非 0 結束（rc=${rc2}）" >&2; failed=1; }

  if ! run_sql "$verify" > "$verify_out" 2>&1; then
    sed 's/^/    /' "$verify_out" >&2; failed=1
  else
    sed 's/^/    /' "$verify_out"
  fi

  [ "$failed" = 0 ] || { echo "  ✗ 併發：$label 失敗" >&2; exit 1; }
  echo "  ✓ 併發：$label"
}

race_case "兩人同搶邀請碼最後一個名額" \
  join_race_setup.sql join_race_s1.sql join_race_s2.sql join_race_verify.sql

# 核准／拒絕的競態要跑兩個方向：先動的那一邊反正會在自己的 UPDATE 上取得列鎖，
# 所以單一方向只證明得了「後動的那支 RPC」有鎖。兩個方向合起來才涵蓋
# approve_join 與 reject_join 各自的 `for update`（mutation test 逼出來的結論：
# 只有方向 A 時，拿掉 approve_join 的鎖，整組測試仍然全綠）。
race_case "同一筆申請：核准先動，拒絕必須被擋下" \
  approve_reject_race_setup.sql approve_reject_race_s1_approve.sql \
  approve_reject_race_s2_reject.sql approve_reject_race_verify_approved.sql
race_case "同一筆申請：拒絕先動，核准必須被擋下" \
  approve_reject_race_setup.sql approve_reject_race_s1_reject.sql \
  approve_reject_race_s2_approve.sql approve_reject_race_verify_rejected.sql

# LS-48 併發場景（merge-reviewer PR #60 review F5）：同一篇日記的編輯（update_diary_entry）
# 與軟刪（set_diary_deleted）同時發生。兩個方向缺一不可，理由同上一組
# approve_reject_race（mutation test 的教訓）：只跑單一方向，先動的那邊反正會在自己的
# UPDATE 上取鎖，測不出後動那支 RPC 自己的 `for update` 有沒有真的存在。
race_case "同一篇日記：編輯先動，軟刪必須被阻塞後才成功" \
  diary_edit_vs_delete_setup.sql diary_edit_vs_delete_s1_update.sql \
  diary_edit_vs_delete_s2_delete.sql diary_edit_vs_delete_verify_update_won.sql
race_case "同一篇日記：軟刪先動，編輯必須被阻塞後拿到 LS020" \
  diary_edit_vs_delete_setup.sql diary_edit_vs_delete_s1_delete.sql \
  diary_edit_vs_delete_s2_update.sql diary_edit_vs_delete_verify_delete_won.sql

# LS-52 併發場景（merge-reviewer PR #70 review F2）：同一本相簿的直接 UPDATE（內容
# 編輯）與 set_album_deleted（軟刪）同時發生。兩個方向缺一不可，理由同上一組——只跑
# 單一方向，先動的那邊反正會在自己的 UPDATE 上取鎖，測不出後動那邊的寫入有沒有真的
# 被序列化。**與 diary_edit_vs_delete 不同**：albums 沒有「已軟刪除不能編輯」的規則，
# 兩個方向的最終狀態都是「編輯與軟刪皆生效」，不是其中一邊被擋下——見對應 verify
# 檔案與 s2_update.sql 檔頭的說明。
race_case "同一本相簿：直接編輯先動，軟刪必須被阻塞後才成功" \
  album_edit_vs_delete_setup.sql album_edit_vs_delete_s1_update.sql \
  album_edit_vs_delete_s2_delete.sql album_edit_vs_delete_verify_edit_first.sql
race_case "同一本相簿：軟刪先動，直接編輯必須被阻塞後才成功" \
  album_edit_vs_delete_setup.sql album_edit_vs_delete_s1_delete.sql \
  album_edit_vs_delete_s2_update.sql album_edit_vs_delete_verify_delete_first.sql

# LS-52 併發場景，comments 版本，結構同上。
race_case "同一則留言：直接編輯先動，軟刪必須被阻塞後才成功" \
  comment_edit_vs_delete_setup.sql comment_edit_vs_delete_s1_update.sql \
  comment_edit_vs_delete_s2_delete.sql comment_edit_vs_delete_verify_edit_first.sql
race_case "同一則留言：軟刪先動，直接編輯必須被阻塞後才成功" \
  comment_edit_vs_delete_setup.sql comment_edit_vs_delete_s1_delete.sql \
  comment_edit_vs_delete_s2_update.sql comment_edit_vs_delete_verify_delete_first.sql

# LS-52 併發場景，方向 C（merge-reviewer PR #70 review N1，第 2 輪）：作者把自己的
# 相簿直接 UPDATE 搬到自己也是 owner 的另一個家庭，與原家庭 owner 呼叫
# set_album_deleted 同時發生——這組場景（album_edit_vs_delete_s1_move_family.sql／
# s2_delete_after_move.sql／verify_move_blocked.sql，原本在這裡）已隨 LS-57 一起
# 退役：LS-57 把 albums／diaries／comments 的 family_id 收斂成不可變欄
# （private.enforce_deletion_attribution() trigger，見
# supabase/migrations/20260825040000_deletion_attribution.sql），作者的搬家 UPDATE
# 本身現在會直接被這支 trigger 擋下 42501，「family_id 可以被搬動」這個攻擊面在
# 前提上已經不成立，不需要再靠併發時序去驗證 `for update` 有沒有守住這個特定 race——
# 比照 LS-58 讓 comments 版同一場景退役的處理方式（見上一段這裡原本留的說明）。
# `FOR UPDATE` 鎖本身仍然保留在 set_album_deleted 裡（migration 是歷史紀錄不回頭
# 改），繼續為方向 A／B 的一般序列化把關。
#
# LS-57 併發場景：owner 軟刪 vs 作者同時嘗試還原——`for update` 鎖必須讓後動的一方
# 讀到先動一方已 commit 的 deleted_by，才能正確判斷「這不是我刪的」而擋下 LS027。
# 用 diaries 當代表（三張表走同一支共用 trigger、同一種鎖的形狀，機制相同，不重複
# 三份）。方向只需一個：owner 先動、作者後動——反過來（作者的還原先動）在這個資料
# 狀態下一定會先撞上還原鎖本身（作者對「當下還沒被任何人刪除」的日記呼叫還原是
# no-op，不構成有意義的 race），跟 diary_edit_vs_delete／album_edit_vs_delete 那種
# 「兩個方向各自證明一支 RPC 自己的鎖」不是同一種需要雙向覆蓋的情境。
race_case "同一篇日記：owner 軟刪先動，作者的還原必須被阻塞後正確拿到 LS027" \
  diary_delete_vs_restore_setup.sql diary_delete_vs_restore_s1_owner_delete.sql \
  diary_delete_vs_restore_s2_author_restore.sql diary_delete_vs_restore_verify.sql

# LS-58 併發場景：同一人對同一目標的兩次 toggle_reaction 幾乎同時發出，必須被
# pg_advisory_xact_lock 序列化——沒有這把鎖，兩次呼叫都會查到「還沒按過」而各自
# INSERT，第二次會撞 reactions_target_user_key 的 23505。
race_case "同一人對同一目標：雙 toggle_reaction 必須序列化且淨效果歸零" \
  reaction_toggle_race_setup.sql reaction_toggle_race_s1.sql \
  reaction_toggle_race_s2.sql reaction_toggle_race_verify.sql

# LS-66 併發場景：同一個孩子檔案的編輯（update_child）與軟刪（set_child_deleted）
# 同時發生。兩個方向都跑，但兩者的用途不對稱（R1 merge-reviewer PR #95 review M1
# 訂正——原本這裡宣稱「拿掉其中一支 RPC 的鎖，測試仍然是綠的」是兩個方向共同的理由，
# 四種 mutation 實測後發現不成立：阻塞永遠來自**先動那一邊自己的 UPDATE 語句**
# 持有的列鎖，這是 Postgres 對任何 UPDATE 的通用行為，跟後動那支 RPC 開頭有沒有寫
# `for update` 無關；兩個方向都只證明得了「後動那一邊」自己的 `for update` 是否
# 必要——本組只有「軟刪先動、update_child 後動」這個方向（第二個 race_case）真的
# 會在拿掉 update_child 的 `for update` 時變紅，因為 update_child 靠那句鎖住的
# SELECT 重讀 `deleted_at` 才不會用 READ COMMITTED 的舊快照放行一次不該成立的編輯；
# 「編輯先動、set_child_deleted 後動」這個方向（第一個 race_case）測不到
# set_child_deleted 開頭那句 `for update` 是否必要——那句鎖是讀 family_id 做授權
# 判斷的 TOCTOU 防線（LS-52 定下的規則），純防禦性，不是這組併發測試的必要條件，
# 詳細說明見 `children_edit_vs_delete_s2_delete.sql`／`_s1_delete.sql` 檔頭。
# children 跟 diaries 同型（已被軟刪不能編輯，拿 LS041），不是 albums 那種「兩者皆
# 生效」的型。
race_case "同一個孩子檔案：編輯先動，軟刪必須被阻塞後才成功" \
  children_edit_vs_delete_setup.sql children_edit_vs_delete_s1_update.sql \
  children_edit_vs_delete_s2_delete.sql children_edit_vs_delete_verify_update_won.sql
race_case "同一個孩子檔案：軟刪先動，編輯必須被阻塞後拿到 LS041" \
  children_edit_vs_delete_setup.sql children_edit_vs_delete_s1_delete.sql \
  children_edit_vs_delete_s2_update.sql children_edit_vs_delete_verify_delete_won.sql

cleanup="$tmp/cc_cleanup.sql"
cat > "$cleanup" <<'SQL'
delete from public.families where id in (
  'fd000000-0000-4000-8000-000000000001',
  'fe000000-0000-4000-8000-000000000001',
  'ff000000-0000-4000-8000-000000000001',
  'f2000000-0000-4000-8000-000000000001',
  'f3000000-0000-4000-8000-000000000001',
  'f4000000-0000-4000-8000-000000000001',
  'f6000000-0000-4000-8000-000000000001',
  'f7000000-0000-4000-8000-000000000001',
  'f8000000-0000-4000-8000-000000000001',
  'f5000000-0000-4000-8000-000000000001'
);
delete from auth.users where id in (
  'd0000000-0000-4000-8000-000000000001',
  'd0000000-0000-4000-8000-000000000002',
  'ea000000-0000-4000-8000-000000000001',
  'ea000000-0000-4000-8000-000000000002',
  'ea000000-0000-4000-8000-000000000003',
  'eb000000-0000-4000-8000-000000000001',
  'eb000000-0000-4000-8000-000000000002',
  'eb000000-0000-4000-8000-000000000003',
  'a9000000-0000-4000-8000-000000000001',
  'a8000000-0000-4000-8000-000000000001',
  'a7000000-0000-4000-8000-000000000001',
  'a6000000-0000-4000-8000-000000000001',
  'a5000000-0000-4000-8000-000000000001',
  'a4000000-0000-4000-8000-000000000001',
  'a3000000-0000-4000-8000-000000000001',
  'a2000000-0000-4000-8000-000000000001',
  'a1000000-0000-4000-8000-000000000001'
);
SQL
run_sql "$cleanup" > /dev/null

# EXPLAIN 證據存檔（驗收條件 c 要求留存）
# LS-54 D2：evidence/ 已 gitignore，不再進 repo——產生時間、EXPLAIN ANALYZE 計時、規劃器估計值
# （ANALYZE 隨機取樣）、buffers hit 數、以及 NOTICE（stderr）與查詢輸出（stdout）在合流檔裡的
# 交錯順序每次跑都會變（本票實測：逐一遮掉前三種之後第五次仍在 buffers 上漂移），tracked 就是
# 本機跑一次測試必弄髒工作區。留存改由 CI db job 每次以 artifact 上傳（.github/workflows/ci.yml
# 的「上傳 RLS plan 證據」step），本機產出只給自己看。
perf_out="$tmp/50_rls_plan_no_percall_subquery.sql.out"
if [ -f "$perf_out" ]; then
  {
    echo "# LS-6 RLS plan 證據 —— 由 supabase/tests/run.sh 產生"
    echo "# 產生時間：$(date -u '+%Y-%m-%dT%H:%M:%SZ')（UTC）"
    # 連線通道與 server 版本一起記下來：證據要能自己說明它是在哪裡跑出來的
    echo "# 連線：$channel"
    echo "# Server：$(printf 'select version();' > "$tmp/ver.sql"; run_sql "$tmp/ver.sql" 2>/dev/null | sed -n '3p' | sed 's/^ *//')"
    echo "# 資料量：public.media 5 萬列、public.join_requests 2 千列、storage.objects 2 萬列（家庭 fc000000-0000-4000-8000-000000000001）"
    echo "# 判準：plan 不得出現 (SubPlan N) 形式的 qual 引用（hashed SubPlan 不命中此判準，不算違規），且所有節點 loops=1"
    echo
    cat "$perf_out"
  } > "$evidence_dir/explain_rls_plan.txt"
  echo "→ EXPLAIN 證據：$evidence_dir/explain_rls_plan.txt"
fi

echo "✓ 全部 DB 測試通過"
