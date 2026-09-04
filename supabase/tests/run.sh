#!/usr/bin/env bash
# LS-6 — 本地 DB 測試 runner（RLS 隔離／owner 不變量／trigger／RLS plan 效能）
#
# 用法：
#   supabase start（或只要 DB：supabase db start）
#   bash scripts/ops/supabase-lock.sh -- supabase db reset   # 套用 supabase/migrations（經 lock：容器是所有 worktree 共用的，LS-70）
#   bash supabase/tests/run.sh                                 # 未在 lock 內會自己經 lock 重跑
#
# LS-11：CI（.github/workflows/ci.yml 的 db job）額外帶 SUPABASE_DB_URL＝
# `supabase status -o env` 印出的 DB_URL，走 host psql 那條路；本機／QA 備援沿用
# 既有離散參數（SUPABASE_DB_HOST/PORT/USER/NAME）或 SUPABASE_DB_CONTAINER。
#
# fail loud：任何一個測試檔非 0 結束就立刻中止並回傳非 0，不會有「跳過等於通過」。
# 測試檔本身用 DO 區塊斷言，失敗時 RAISE EXCEPTION，psql 帶 ON_ERROR_STOP 直接非 0 結束。
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# LS-70：本機容器是所有 worktree 共用的（LS-57／LS-66 同時 reset 互踩）——未在 scripts/ops/supabase-lock.sh 的
# lock 內就經 lock 重新執行自己。「在不在 lock 內」只問 lock 腳本（--held：holder pid 是否本程序祖先），不讀
# SUPABASE_LOCK_HELD——環境變數可被殘留／假造（PR #122 R1 m3：假變數直接連上共用容器）或被洗掉（R1 m2：
# run.sh ⟷ lock 無窮 exec）；祖先關係兩種情況都判得對，遞迴自然終止。lock 腳本不在（舊分支）只警告，照跑。
lock_sh="$here/../../scripts/ops/supabase-lock.sh"
if [ -f "$lock_sh" ]; then
  if ! bash "$lock_sh" --held 2>/dev/null; then
    echo "→ 未在 Supabase lock 內，改經 scripts/ops/supabase-lock.sh 重新執行（等其他 worktree 的 reset／測試結束）"
    exec bash "$lock_sh" -- bash "${BASH_SOURCE[0]}" "$@"
  fi
else
  echo "⚠ 找不到 ${lock_sh}：未經 lock 直接執行，與其他 worktree 的 supabase db reset 可能互踩（LS-70）" >&2
fi

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

# LS-110 R1 F2：96_ 的角色路徑探針（auth_admin/profiles_trigger_probe.sql）要用
# supabase_auth_admin（GoTrue 寫 auth.users 用的身分）連線，不能沿用上面 $db_user
# 的連線。密碼固定用 supabase CLI local stack 的預設值（config.toml 沒有自訂
# [db] 密碼，本機／CI 皆同）——不是硬掰的字面常數，可用 SUPABASE_DB_AUTH_ADMIN_PASSWORD
# 覆蓋。
auth_admin_password="${SUPABASE_DB_AUTH_ADMIN_PASSWORD:-postgres}"

# psql 不一定裝在 host 上；沒有的話就借用 supabase 的 DB container 裡那一份。
if command -v psql >/dev/null 2>&1 && [ -n "$db_url" ]; then
  channel="host psql → SUPABASE_DB_URL"
  run_sql() {
    psql "$db_url" -v ON_ERROR_STOP=1 --no-psqlrc -q -f "$1"
  }
  run_sql_as_auth_admin() {
    psql "$(printf '%s' "$db_url" | sed -E "s#//[^:@/]+(:[^@/]*)?@#//supabase_auth_admin:${auth_admin_password}@#")" \
      -v ON_ERROR_STOP=1 --no-psqlrc -q -f "$1"
  }
elif command -v psql >/dev/null 2>&1; then
  channel="host psql → ${db_host}:${db_port}/${db_name}"
  run_sql() {
    psql -h "$db_host" -p "$db_port" -U "$db_user" -d "$db_name" \
      -v ON_ERROR_STOP=1 --no-psqlrc -q -f "$1"
  }
  run_sql_as_auth_admin() {
    PGPASSWORD="$auth_admin_password" psql -h "$db_host" -p "$db_port" -U supabase_auth_admin -d "$db_name" \
      -v ON_ERROR_STOP=1 --no-psqlrc -q -f "$1"
  }
elif docker exec "$container" true >/dev/null 2>&1; then
  channel="docker exec $container psql"
  run_sql() {
    docker exec -i "$container" \
      psql -U "$db_user" -d "$db_name" -v ON_ERROR_STOP=1 --no-psqlrc -q < "$1"
  }
  # docker exec 走 unix socket＋peer auth，非 $db_user 的角色一律驗證失敗（實測：
  # supabase_auth_admin 會拿「Peer authentication failed」）；容器內部一定聽 TCP
  # 5432（不論外部 port mapping 是哪一個 port），改連那邊即可換角色連線。
  run_sql_as_auth_admin() {
    docker exec -i "$container" \
      psql "host=127.0.0.1 port=5432 user=supabase_auth_admin dbname=${db_name} password=${auth_admin_password}" \
      -v ON_ERROR_STOP=1 --no-psqlrc -q < "$1"
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

# LS-149：兩位數編號在 99_media_duration.sql 用完了（第一次真的撞到上限）。原本的
# `[0-9][0-9]_*.sql` 只吃恰好兩位數，改成 `[0-9]*_*.sql`（一位數以上皆可）以容納三位數
# 檔名；但 shell glob 預設的字典排序對「跨位數」的數字排序是錯的（例如 "100_..." 會排在
# "10_..." 之前，因為第三個字元 '0' < '_'）。改用 `sort -V`（version sort，逐段比較數字
# 而不是逐字元比較字串）取代 glob 天生的字典序，兩位數與三位數才會照數值大小排列
# （00 < 10 < ... < 99 < 100）。
# LS-149 R2（merge-reviewer PR #248 R1 minor-3）：`for f in $(...)` 讓 `sort -V` 的輸出
# 經過 word splitting 逐一斷開——原本兩位數的 glob 寫法天生抗路徑含空白，這次放寬 glob
# 時無意中丟掉了這個性質（repo clone 到含空白的路徑，例如 `~/Library/Mobile Documents/…`，
# 會找不存在的檔案而不是照常執行；外層 `set -Eeuo pipefail` 讓症狀是難以理解的中止，不是
# 清楚的錯誤）。改用 `while read` 讀 process substitution，每行完整保留、不做 word
# splitting，路徑含空白也能正確逐檔處理。
while IFS= read -r f; do
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
done < <(printf '%s\n' "$here"/[0-9]*_*.sql | sort -V)

# ---------------------------------------------------------------------------
# LS-110 R1 F2：96_profiles_auto_create.sql 的六段情境測試都是以 $db_user（本機／CI
# 預設 postgres）身分驗證 trigger；正式站寫 auth.users 的是 GoTrue 的
# supabase_auth_admin，這裡另外用真正的角色連線插入一次，確認 trigger 在該角色下
# 仍成功、profiles 確實拿到列——不只是「postgres 能跑」（該檔第 7 段已把 owner／
# SECURITY DEFINER／trigger 啟用狀態釘成結構性斷言，這裡補上實際連線的證據）。
# 插入與驗證分兩檔／兩種連線身分：supabase_auth_admin 對 public.profiles 沒有任何
# grant（正式路徑上不需要，也不應該有），驗證與清理必須換回一般連線才讀得到。
# ---------------------------------------------------------------------------
auth_admin_insert="$here/auth_admin/profiles_trigger_probe_insert.sql"
auth_admin_verify="$here/auth_admin/profiles_trigger_probe_verify.sql"
name="auth_admin/profiles_trigger_probe（supabase_auth_admin 角色路徑）"
insert_out="$tmp/auth_admin_probe_insert.out"
verify_out="$tmp/auth_admin_probe_verify.out"
echo "→ $name"
if ! run_sql_as_auth_admin "$auth_admin_insert" > "$insert_out" 2>&1; then
  echo "  ✗ $name 失敗（supabase_auth_admin insert）：" >&2
  sed 's/^/    /' "$insert_out" >&2
  exit 1
fi
sed 's/^/    /' "$insert_out"
if ! run_sql "$auth_admin_verify" > "$verify_out" 2>&1; then
  echo "  ✗ $name 失敗（驗證／清理）：" >&2
  sed 's/^/    /' "$verify_out" >&2
  exit 1
fi
sed 's/^/    /' "$verify_out"
echo "  ✓ $name"

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

# ---------------------------------------------------------------------------
# LS-155 R2（merge-review R1 M1）：三連線併發——比 race_case 多一個背景 session
# （S0），用來撐開一個天然存在但單靠兩個 session 的 pg_sleep offset 難以穩定命中
# 的時序視窗（見 delete_account_vs_finalize_media_setup.sql 檔頭）。S0／S1／S2 三個
# session 皆背景平行啟動，全部等完才驗證——三者的 rc 都要是 0（reviewer 實測 R1
# 版本這裡會有一邊收到 40P01，R2 修法後三個 session 都必須正常完成，不只是「不
# crash」）。
# ---------------------------------------------------------------------------
race_case3() {  # $1=場景名 $2=setup $3=s0 $4=s1 $5=s2 $6=verify
  local label="$1" setup="$cc_dir/$2" s0="$cc_dir/$3" s1="$cc_dir/$4" s2="$cc_dir/$5" verify="$cc_dir/$6"
  local setup_out="$tmp/$2.out" s0_out="$tmp/$3.out" s1_out="$tmp/$4.out" s2_out="$tmp/$5.out" verify_out="$tmp/$6.out"
  echo "→ 併發（三連線）：$label"

  if ! run_sql "$setup" > "$setup_out" 2>&1; then
    echo "  ✗ 併發場景資料建立失敗：" >&2; sed 's/^/    /' "$setup_out" >&2; exit 1
  fi
  sed 's/^/    setup /' "$setup_out"

  run_sql_bg "$s0" "$s0_out"
  run_sql_bg "$s1" "$s1_out"
  run_sql_bg "$s2" "$s2_out"
  wait

  local rc0 rc1 rc2 failed=0
  rc0="$(cat "$s0_out.rc")"; rc1="$(cat "$s1_out.rc")"; rc2="$(cat "$s2_out.rc")"
  sed 's/^/    S0 /' "$s0_out"
  sed 's/^/    S1 /' "$s1_out"
  sed 's/^/    S2 /' "$s2_out"
  [ "$rc0" = 0 ] || { echo "  ✗ S0 非 0 結束（rc=${rc0}）" >&2; failed=1; }
  [ "$rc1" = 0 ] || { echo "  ✗ S1 非 0 結束（rc=${rc1}）——40P01 死鎖會落在這裡" >&2; failed=1; }
  [ "$rc2" = 0 ] || { echo "  ✗ S2 非 0 結束（rc=${rc2}）——40P01 死鎖會落在這裡" >&2; failed=1; }

  if ! run_sql "$verify" > "$verify_out" 2>&1; then
    sed 's/^/    /' "$verify_out" >&2; failed=1
  else
    sed 's/^/    /' "$verify_out"
  fi

  [ "$failed" = 0 ] || { echo "  ✗ 併發（三連線）：$label 失敗" >&2; exit 1; }
  echo "  ✓ 併發（三連線）：$label"
}

race_case "兩人同搶邀請碼最後一個名額" \
  join_race_setup.sql join_race_s1.sql join_race_s2.sql join_race_verify.sql

# LS-90：邀請碼改 6 碼後，撞碼重試迴圈的併發覆蓋——兩線同時 create_invite
# 不應互相干擾（不卡死、不噴非預期錯誤、兩邊碼互不相同）。
race_case "兩連線同時 create_invite" \
  invite_create_race_setup.sql invite_create_race_s1.sql invite_create_race_s2.sql \
  invite_create_race_verify.sql

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

# LS-121 併發場景：兩個連線同時 update_diary_entry 覆蓋同一篇日記的孩子標記
# （不同的目標集合）。終態必須是其中一方的完整集合，不能混合——與
# diary_edit_vs_delete 那組不同，這裡兩個方向的 RPC 相同（都是 update_diary_entry），
# 驗的是同一支 RPC 內部「刪多補少」與 `for update` 鎖的交互，不是兩支不同 RPC
# 互斥，所以只需要一個方向（S1 先動、S2 後動）。
race_case "同一篇日記：兩連線同時覆蓋孩子標記，終態必須是後 commit 一方的完整集合" \
  diary_children_race_setup.sql diary_children_race_s1.sql \
  diary_children_race_s2.sql diary_children_race_verify.sql

# LS-121 R2（merge-reviewer PR #218 review M2）：set_album_children 完全沒有對
# albums 下 UPDATE，開頭那句 `for update` 是唯一的序列化點（不像 update_diary_entry
# 還有一句對 diaries 本體的 UPDATE 順便取鎖）——這組是這把鎖唯一有鑑別力的回歸測試，
# mutation 自證見 PR handoff。
race_case "同一本相簿：兩連線同時覆蓋孩子標記，終態必須是後 commit 一方的完整集合" \
  album_children_race_setup.sql album_children_race_s1.sql \
  album_children_race_s2.sql album_children_race_verify.sql

# LS-143 併發場景：兩位共同 owner（沒有其他成員）幾乎同時呼叫 delete_my_account()。
# 跟 owner_guard_case 驗的是同一顆既有 trigger（LS-6／LS-15），換成帳號刪除這個新的
# 觸發路徑——S1 先離開家庭並持鎖 3 秒，S2 1.2 秒後被同一把家庭列鎖擋住，解除阻塞後
# 因為 S1 已經離開、自己也離開會讓家庭剩 0 位 owner，必須正確拿到 LS001（見
# delete_account_race_s2.sql 的說明），不是死鎖、也不是誤放行。
race_case "兩位共同 owner 幾乎同時刪除帳號：後動者必須被阻塞後正確拿到 LS001" \
  delete_account_race_setup.sql delete_account_race_s1.sql \
  delete_account_race_s2.sql delete_account_race_verify.sql

# LS-143 R2（merge-review R1 m2）：approve_join() 先動、delete_my_account() 後動——
# 剛核准加入的成員不得被「唯一成員」候選判斷連坐 cascade 刪除。見 migration 檔頭
# 「併發設計」m2 段落與 delete_account_vs_approve_join_s2.sql 的說明。
race_case "approve_join 先動、delete_my_account 後動：剛核准的成員不得被連坐 cascade 刪除" \
  delete_account_vs_approve_join_setup.sql delete_account_vs_approve_join_s1.sql \
  delete_account_vs_approve_join_s2.sql delete_account_vs_approve_join_verify.sql

# LS-153 併發場景：purge_expired() 硬刪一個孩子檔案（deleted_at 已超過 30 天保護窗）
# 與 owner 同時嘗試 set_child_deleted(false) 還原同一個孩子。S1 先動並持鎖 3 秒，S2
# 1.2 秒後被同一列的排他鎖擋住，解除阻塞後必須讀到「這一列已經不存在」（LS041），
# 不是 LS043（那個碼假設列還在只是還原窗口過期）也不是誤放行成功還原。見
# purge_vs_restore_child_s2_restore.sql 的說明。
race_case "purge_expired 先動、owner 還原同一個孩子後動：後動者必須被阻塞後正確拿到 LS041" \
  purge_vs_restore_child_setup.sql purge_vs_restore_child_s1_purge.sql \
  purge_vs_restore_child_s2_restore.sql purge_vs_restore_child_verify.sql

# LS-155 R2（merge-review R1 M1，實測重現 40P01）：呼叫者已退出但留有 media 的
# 家庭（X）與呼叫者仍是成員的家庭（A），與同時在跑的另一位成員的
# finalize_account_deletion() 三連線時序——R1 版本這裡會死鎖（reviewer 實測，見
# delete_account_vs_finalize_media_setup.sql 檔頭引用的證據），R2 修法後三個
# session 都必須正常完成、無 40P01。三連線（多一個 S0 撐開視窗）用 race_case3。
race_case3 "已退出但留有 media 的家庭 vs 仍是成員的家庭：與 finalize_account_deletion 三連線不得死鎖" \
  delete_account_vs_finalize_media_setup.sql delete_account_vs_finalize_media_s0.sql \
  delete_account_vs_finalize_media_s1.sql delete_account_vs_finalize_media_s2.sql \
  delete_account_vs_finalize_media_verify.sql

# LS-155 R3（merge-review R2 9779da79 R2-M1，N1／N2 兩種撐窗方式各實測重現
# 40P01）：情況 2（唯一成員家庭）當時仍在合併迴圈之外（先鎖 families、cascade
# 才碰 family_members），與情況 3／finalize_account_deletion() 的鎖序相反，且
# 情況 2／3 是兩個各自遞增序但涵蓋不同家庭子集的迴圈，合起來不是全域遞增序。這裡
# 搬 N2（真實在飛上傳撐窗，不是人工鎖）：U1 是兩個唯一成員家庭的唯一成員，S 裡
# 留著早已退出的 U2 的 media，U1 自己的背景上傳佔住 S2 的 families 列鎖；U1／U2
# 同時呼叫 delete_my_account()。R3 修法（情況 2 併進同一個遞增序迴圈）後三個
# session 皆須正常完成、無 40P01。沿用 race_case3 同一支三連線 runner（沒有另開
# 一支同形狀的 helper，見 handoff）。
race_case3 "情況2（唯一成員家庭）vs 情況3 media：U1 自己在飛上傳撐窗，兩個 delete_my_account() 不得死鎖" \
  delete_account_case2_vs_media_setup.sql delete_account_case2_vs_media_s0.sql \
  delete_account_case2_vs_media_s1.sql delete_account_case2_vs_media_s2.sql \
  delete_account_case2_vs_media_verify.sql

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
  'f5000000-0000-4000-8000-000000000001',
  'f8000000-0000-4000-8000-000000000001',
  'f0000000-0000-4000-8000-000000000001',
  '9a000000-0000-4000-8000-000000000001',
  'd3000000-0000-4000-8000-000000000001',
  'd5000000-0000-4000-8000-000000000001',
  'f9000000-0000-4000-8000-000000000001',
  'e8000000-0000-4000-8000-000000000001',
  'e8000000-0000-4000-8000-000000000002',
  'ed000000-0000-4000-8000-000000000001',
  'ed000000-0000-4000-8000-000000000002'
);
delete from auth.users where id in (
  'd0000000-0000-4000-8000-000000000001',
  'd0000000-0000-4000-8000-000000000002',
  'd1000000-0000-4000-8000-000000000001',
  'd2000000-0000-4000-8000-000000000001',
  'd4000000-0000-4000-8000-000000000001',
  'd4000000-0000-4000-8000-000000000002',
  'd6000000-0000-4000-8000-000000000001',
  'd7000000-0000-4000-8000-000000000001',
  'e8000000-0000-4000-8000-000000000011',
  'e8000000-0000-4000-8000-000000000012',
  'e8000000-0000-4000-8000-000000000013',
  'ed000000-0000-4000-8000-000000000011',
  'ed000000-0000-4000-8000-000000000012',
  'ea000000-0000-4000-8000-000000000001',
  'ea000000-0000-4000-8000-000000000002',
  'ea000000-0000-4000-8000-000000000003',
  'eb000000-0000-4000-8000-000000000001',
  'eb000000-0000-4000-8000-000000000002',
  'eb000000-0000-4000-8000-000000000003',
  'ec000000-0000-4000-8000-000000000001',
  'e1000000-0000-4000-8000-000000000001',
  'e2000000-0000-4000-8000-000000000001',
  'a9000000-0000-4000-8000-000000000001',
  'a8000000-0000-4000-8000-000000000001',
  'a7000000-0000-4000-8000-000000000001',
  'a6000000-0000-4000-8000-000000000001',
  'a5000000-0000-4000-8000-000000000001',
  'a4000000-0000-4000-8000-000000000001',
  'a3000000-0000-4000-8000-000000000001',
  'a2000000-0000-4000-8000-000000000001',
  'a1000000-0000-4000-8000-000000000001',
  'b9000000-0000-4000-8000-000000000001'
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
