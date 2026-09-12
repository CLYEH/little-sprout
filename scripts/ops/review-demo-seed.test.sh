#!/bin/bash
# review-demo-seed.sh 自測（LS-240）。CI rules job 每個 PR 都跑。
#
# 涵蓋範圍：①上傳重試（curl exit 56／7／28、HTTP 5xx／429 最多重試 3 次，退避
# 1s→2s→4s；其餘錯誤不重試）②--storage-only 續傳（跳過 SQL／清理／--owner-email，
# 只對 Storage 缺的物件補上傳）③psql 偵測（PATH 找不到時依序試 libpq 候選路徑，
# 再退回 docker exec，仍找不到才印安裝提示）④既有 --target local 全流程仍綠。
#
# 比照 qa-e2e.test.sh／patrol-linear.test.sh：PATH 換上假的 supabase／curl／
# swift／sips／qlmanage／docker／psql（可切換存在與否），完全不碰真容器、真網路、
# 真的 AVFoundation 影片合成。SUPABASE_LOCK_DIR 隔離成自測用的合成目錄（同
# patrol.test.sh 慣例）——`--target local` 仍會走真正的 scripts/ops/supabase-lock.sh
# （不是假身），只是鎖目錄是隔離的，驗證的是「這支腳本＋真鎖」整合起來的行為，
# 不是鎖本身（supabase-lock.test.sh 已經測過鎖）。
#
# 安全前提（不得對正式站跑，見票規約）：本測試對 `--target prod --yes` 的驗證只到
# 「有沒有在讀 .env 之前就先擋下 --owner-email／網域檢查」這一步——本 worktree 沒有
# `.env`（gitignored，全新 worktree／CI runner 皆同），所以 `--target prod --yes`
# 一定會在 `[ -f "$ROOT/.env" ] || exit 2` 這一步安全中止，從未真的讀取／連線任何
# prod 憑證；若哪天這個 worktree 意外出現 `.env`，這裡的 D 組會提早在別的斷言失敗，
# 不會失敗打靶到正式站（never runs --owner-password/pgcrypto 之後的任何步驟）。
#
# psql 偵測（C 組）刻意把 PATH 上「含真的 psql 執行檔」的目錄濾掉（strip_dirs_with_exe），
# 不依賴「本機剛好沒把 libpq link 進 PATH」這個環境巧合——CI runner 或换一台開發機都
# 應該得到同樣的判定。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ops/review-demo-seed.sh"
fail=0; n=0
ok() { echo "✓ $1"; n=$((n + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export SUPABASE_LOCK_DIR="$work/lock"
export FAKE_WORK="$work"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# ---- 固定路徑常數（手算對齊 review-demo-seed.sh 的 FAMILY_ID／SEED_YM／media_ids 公式：
#      printf 'd3000000-0000-4000-8000-%012x' 1 → ...0001，src_idx=(1-1)%5=0→design-canvas/family.jpg→.jpg）----
FAMILY_ID=de000000-0000-4000-8000-000000000001
SEED_YM=2026/09
MEDIA1_ORIG="${FAMILY_ID}/${SEED_YM}/d3000000-0000-4000-8000-000000000001.jpg"
MEDIA1_THUMB="${FAMILY_ID}/${SEED_YM}/d3000000-0000-4000-8000-000000000001_thumb.jpg"

bin="$work/bin"; mkdir -p "$bin"

cat > "$bin/supabase" <<'STUB'
#!/bin/bash
if [ "$1" = status ]; then
  printf 'DB_URL="postgresql://fake-user:fake@127.0.0.1:1/postgres"\nAPI_URL="%s"\nSERVICE_ROLE_KEY="fake-service-key"\n' "${FAKE_API_URL:-http://127.0.0.1:9/fake}"  # gate:allow-example（假 DB_URL，供假身 supabase status 輸出用，非真憑證）
  exit 0
fi
exit 1
STUB

# swift review-demo-genvideo.swift <output.mp4> [seconds]：假身忽略內容，直接產生空檔＋印固定秒數。
cat > "$bin/swift" <<'STUB'
#!/bin/bash
: > "$2"
echo 2
STUB

# sips：`-g pixelWidth|pixelHeight <src>` 印固定尺寸（模擬 review-demo-seed.sh 的 awk 解析格式）；
# `-s ... <src> --out <dst>` 只需要在 <dst> 產生一個檔案。
cat > "$bin/sips" <<'STUB'
#!/bin/bash
case "$1" in
  -g)
    metric=$2; src=$3
    echo "$src"
    case "$metric" in
      pixelWidth) echo "  pixelWidth: 800" ;;
      pixelHeight) echo "  pixelHeight: 600" ;;
    esac
    ;;
  -s)
    found_src=""
    while [ $# -gt 0 ]; do
      if [ "$1" = "--out" ]; then : > "$2"; shift 2; else found_src=$1; shift; fi
    done
    ;;
esac
exit 0
STUB

# qlmanage：故意不產生縮圖（no-op），逼腳本走既有的「複製照片縮圖頂替」備援路徑——
# 這條路徑本來就有自測覆蓋的環境依賴（無 GUI session），假身讓行為在任何機器上都確定。
cat > "$bin/qlmanage" <<'STUB'
#!/bin/bash
exit 0
STUB

# docker：psql docker-exec 備援用（C 組）。FAKE_DOCKER_MODE=ok（預設）連線探測與實際執行皆成功；
# down 皆失敗。
cat > "$bin/docker" <<'STUB'
#!/bin/bash
echo "docker $*" >> "$FAKE_WORK/docker.log"
case "${FAKE_DOCKER_MODE:-ok}" in
  ok) exit 0 ;;
  down) exit 1 ;;
esac
STUB

# sleep：LS-240「sleep 可注入」——記錄呼叫的秒數、立刻返回，拉快重試測試（正式路徑仍是真的 sleep）。
cat > "$bin/sleep" <<'STUB'
#!/bin/bash
echo "$1" >> "$FAKE_WORK/sleep.log"
exit 0
STUB

# curl：依 -X 判斷 method、抓 http* 開頭的參數當 url、抓 -d 之後的參數當 body，記錄每次呼叫；
#   DELETE                     → 一律成功（FAKE_CURL_DELETE_EXIT 可覆寫）。
#   POST .../object/list/media → --storage-only 存在性判斷（LS-240：改用 list API，不用 HEAD——
#     實測本機 storage-api 對物件下載端點的 HEAD 回應宣告 Content-Length 卻不送出對應 body，
#     keep-alive 連線會掛住到逾時，見 review-demo-seed.sh storage_exists 函式註解）：從 -d 的
#     JSON body 解出 prefix／search 兜回完整路徑，路徑列在 FAKE_CURL_MISSING_PATHS（空白分隔）
#     就回 `[]`（不存在），否則回一個非空 JSON 陣列（存在）。
#   POST .../object/media/<path>（上傳）→ FAKE_CURL_ALWAYS_FAIL_PATH 指定的路徑每次都回
#     FAKE_CURL_ALWAYS_FAIL_MODE；FAKE_CURL_FLAKY_PATH 指定的路徑只在第一次呼叫回
#     FAKE_CURL_FLAKY_MODE，之後成功；其餘一律回 200。MODE 值：curl56／curl7／curl28／curl6
#     （curl exit）、http500／http429／http404（HTTP status）。
cat > "$bin/curl" <<'STUB'
#!/bin/bash
method=GET; url=; body=
prev=
for a in "$@"; do
  case "$prev" in -X) method=$a ;; -d) body=$a ;; esac
  case "$a" in http*) url=$a ;; esac
  prev=$a
done
echo "${method} ${url}" >> "$FAKE_WORK/curl.log"

fail_as() {
  case "$1" in
    curl56) exit 56 ;;
    curl7) exit 7 ;;
    curl28) exit 28 ;;
    curl6) exit 6 ;;
    http500) printf '500'; exit 0 ;;
    http429) printf '429'; exit 0 ;;
    http404) printf '404'; exit 0 ;;
    *) printf '200'; exit 0 ;;
  esac
}

case "$method" in
  DELETE)
    exit "${FAKE_CURL_DELETE_EXIT:-0}"
    ;;
  POST)
    case "$url" in
      */object/list/media)
        prefix=$(printf '%s' "$body" | sed -nE 's/.*"prefix":"([^"]*)".*/\1/p')
        search=$(printf '%s' "$body" | sed -nE 's/.*"search":"([^"]*)".*/\1/p')
        path="${prefix}/${search}"
        for miss in ${FAKE_CURL_MISSING_PATHS:-}; do
          [ "$path" = "$miss" ] && { printf '[]'; exit 0; }
        done
        printf '[{"name":"%s"}]' "$search"; exit 0
        ;;
      *)
        path=${url#*/object/media/}
        if [ -n "${FAKE_CURL_ALWAYS_FAIL_PATH:-}" ] && [ "$path" = "$FAKE_CURL_ALWAYS_FAIL_PATH" ]; then
          fail_as "${FAKE_CURL_ALWAYS_FAIL_MODE:-curl56}"
        fi
        if [ -n "${FAKE_CURL_FLAKY_PATH:-}" ] && [ "$path" = "$FAKE_CURL_FLAKY_PATH" ]; then
          mkdir -p "$FAKE_WORK/attempts"
          marker="$FAKE_WORK/attempts/flaky"
          count=0
          [ -f "$marker" ] && count=$(cat "$marker")
          count=$((count + 1))
          echo "$count" > "$marker"
          [ "$count" -eq 1 ] && fail_as "${FAKE_CURL_FLAKY_MODE:-curl56}"
        fi
        printf '200'; exit 0
        ;;
    esac
    ;;
  *) printf '200'; exit 0 ;;
esac
STUB
chmod +x "$bin"/*

# psql 假身內容（供直接裝在 $bin，或裝到 libpq 候選路徑）：吃掉 -f 之外的 stdin（docker-exec
# 分支用 stdin 餵檔），記錄呼叫，依 FAKE_PSQL_EXIT 決定成敗。
write_fake_psql() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'STUB'
#!/bin/bash
echo "psql $*" >> "$FAKE_WORK/psql.log"
has_f=0
for a in "$@"; do [ "$a" = -f ] && has_f=1; done
[ "$has_f" -eq 1 ] || cat > /dev/null
exit "${FAKE_PSQL_EXIT:-0}"
STUB
  chmod +x "$1"
}
write_fake_psql "$bin/psql"   # 預設狀態：psql 直接在 PATH 上找得到（A／B 組都要能跑完全流程）

# 從目前 PATH 濾掉「含真的 psql 執行檔」的目錄——C 組的「PATH 找不到 psql」情境不依賴本機環境
# 剛好沒裝／沒 link psql 這個巧合；其餘目錄（bash／git／sed／tr… 的來源）維持不動。
strip_dirs_with_exe() {
  local exe=$1 d out="" dirs
  local IFS=':'
  read -r -a dirs <<< "$PATH"
  for d in "${dirs[@]}"; do
    [ -n "$d" ] || continue
    [ -x "$d/$exe" ] && continue
    out="${out}${d}:"
  done
  printf '%s' "$out"
}
BASE_PATH=$(strip_dirs_with_exe psql)

PW='Ls240TestPw1234AAAA'   # 固定 --owner-password：繞過 openssl 自動產生密碼，測試不依賴它
run() {   # run [額外參數…]：固定 --target local --owner-password <fixed>
  PATH="$bin:$BASE_PATH" bash "$script" --target local --owner-password "$PW" "$@" 2>&1
}
run_prod() {   # run_prod [額外參數…]：固定 --target prod --yes（安全前提見檔頭）
  PATH="$bin:$BASE_PATH" bash "$script" --target prod --yes "$@" 2>&1
}
run_prod_plan() {   # run_prod_plan [額外參數…]：--target prod 不帶 --yes，只印計畫
  PATH="$bin:$BASE_PATH" bash "$script" --target prod "$@" 2>&1
}

reset_fakes() {
  rm -rf "$work/attempts" "$work/lock"
  : > "$work/curl.log"; : > "$work/sleep.log"; : > "$work/psql.log"; : > "$work/docker.log"
  unset FAKE_CURL_FLAKY_PATH FAKE_CURL_FLAKY_MODE FAKE_CURL_ALWAYS_FAIL_PATH FAKE_CURL_ALWAYS_FAIL_MODE
  unset FAKE_CURL_MISSING_PATHS FAKE_CURL_DELETE_EXIT FAKE_DOCKER_MODE FAKE_PSQL_EXIT SEED_PSQL_CANDIDATES
}
reset_fakes

expect() {   # expect <期望 exit> <名稱> <實得 exit> <輸出> [必含…]
  local want=$1 name=$2 got=$3 out=$4; shift 4
  local good=1 must
  [ "$got" -eq "$want" ] || good=0
  for must in "$@"; do printf '%s' "$out" | grep -qF -- "$must" || good=0; done
  if [ "$good" -eq 1 ]; then ok "$name"; else
    echo "✗ ${name}（期望 exit ${want}，實得 ${got}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
  fi
}
has()   { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else echo "✗ ${1}（應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✗ ${1}（不應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; else ok "$1"; fi; }
count_is() {   # count_is <名稱> <期望次數> <檔案> <字串>
  local name=$1 want=$2 file=$3 needle=$4 got
  got=$(grep -cF -- "$needle" "$file" 2>/dev/null || true)
  got=${got:-0}
  if [ "$got" -eq "$want" ]; then ok "$name"; else
    echo "✗ ${name}（期望 ${want} 次，實得 ${got} 次；${file} 內容：）" >&2; sed 's/^/    /' "$file" >&2; fail=1
  fi
}

# =============================================================================
# A 組：上傳重試（LS-240 範圍 1）——一律鎖定 media #1 原檔路徑（整份上傳流程的第一個物件，
# 失敗時腳本會在第一個物件就中止，不必等完 40 個物件），其餘 39 個沿用預設（一律成功）。
# =============================================================================

# ---- A0：既有 --target local 全流程仍綠（LS-240 驗收「現有流程綠」）----
out=$(run); got=$?
expect 0 'A0 既有 --target local 全流程仍綠' "$got" "$out" \
  '✓ review-demo-seed 完成：40 個物件已上傳（20 個原檔 + 20 個縮圖），重試 0 次'
count_is 'A0 40 次 POST（40 個 Storage 物件，無重試）' 40 "$work/curl.log" 'POST http'
count_is 'A0 未觸發任何 sleep（首次即成功、不重試）' 0 "$work/sleep.log" ''
reset_fakes

# ---- A1：curl exit 56 一次、第二次成功 → attempts=2（票文指定案例）----
export FAKE_CURL_FLAKY_PATH="$MEDIA1_ORIG" FAKE_CURL_FLAKY_MODE=curl56
out=$(run); got=$?
expect 0 'A1 curl exit 56 一次後成功 → exit 0' "$got" "$out" \
  "  ⚠ 上傳暫時性錯誤（curl exit 56，HTTP 000），1s 後重試（第 2 次嘗試）：${MEDIA1_ORIG}" \
  "  ✓ 上傳成功（第 2 次嘗試，重試 1 次）：${MEDIA1_ORIG}" \
  '重試 1 次，DB 計數見上方 NOTICE'
has 'A1 sleep 只呼叫一次、延遲 1s（attempts=2 只需 1 次退避）' "$(cat "$work/sleep.log")" '1'
count_is 'A1 sleep 恰呼叫 1 次' 1 "$work/sleep.log" '1'
reset_fakes

# ---- A2（票文規約「其餘 curl exit 不重試」）：curl exit 6（非 56/7/28）→ 立即失敗、不重試 ----
export FAKE_CURL_ALWAYS_FAIL_PATH="$MEDIA1_ORIG" FAKE_CURL_ALWAYS_FAIL_MODE=curl6
out=$(run); got=$?
expect 1 'A2 curl exit 6（不在重試白名單）→ 立即失敗' "$got" "$out" \
  "✗ 上傳失敗（curl exit 6，HTTP 000，不重試）：${MEDIA1_ORIG}" \
  "✗ 上傳原圖失敗：media_id=d3000000-0000-4000-8000-000000000001"
count_is 'A2 完全不呼叫 sleep' 0 "$work/sleep.log" ''
reset_fakes

# ---- A3：HTTP 500 一次後成功（票文「HTTP 5xx」的另一條觸發路徑）----
export FAKE_CURL_FLAKY_PATH="$MEDIA1_ORIG" FAKE_CURL_FLAKY_MODE=http500
out=$(run); got=$?
expect 0 'A3 HTTP 500 一次後成功 → exit 0' "$got" "$out" \
  "  ⚠ 上傳暫時性錯誤（curl exit 0，HTTP 500），1s 後重試（第 2 次嘗試）：${MEDIA1_ORIG}"
reset_fakes

# ---- A4：HTTP 429 一次後成功（票文明確列出的另一個 HTTP 重試碼）----
export FAKE_CURL_FLAKY_PATH="$MEDIA1_ORIG" FAKE_CURL_FLAKY_MODE=http429
out=$(run); got=$?
expect 0 'A4 HTTP 429 一次後成功 → exit 0' "$got" "$out" \
  "  ⚠ 上傳暫時性錯誤（curl exit 0，HTTP 429），1s 後重試（第 2 次嘗試）：${MEDIA1_ORIG}"
reset_fakes

# ---- A5：HTTP 404（不可重試的 4xx）→ 立即失敗 ----
export FAKE_CURL_ALWAYS_FAIL_PATH="$MEDIA1_ORIG" FAKE_CURL_ALWAYS_FAIL_MODE=http404
out=$(run); got=$?
expect 1 'A5 HTTP 404（不在重試白名單）→ 立即失敗' "$got" "$out" \
  "✗ 上傳失敗（curl exit 0，HTTP 404，不重試）：${MEDIA1_ORIG}"
count_is 'A5 完全不呼叫 sleep' 0 "$work/sleep.log" ''
reset_fakes

# ---- A6：持續失敗，窮盡 3 次重試（退避 1s→2s→4s）後仍失敗 → exit 1 ----
export FAKE_CURL_ALWAYS_FAIL_PATH="$MEDIA1_ORIG" FAKE_CURL_ALWAYS_FAIL_MODE=curl56
out=$(run); got=$?
expect 1 'A6 持續 curl exit 56、重試 3 次仍失敗 → exit 1' "$got" "$out" \
  "✗ 上傳失敗（重試 3 次仍失敗，curl exit 56，HTTP 000）：${MEDIA1_ORIG}"
sleep_log="$(cat "$work/sleep.log" | tr '\n' ',' )"
if [ "$sleep_log" = "1,2,4," ]; then ok 'A6 退避序列為 1s→2s→4s'; else
  echo "✗ A6 退避序列應為 1,2,4（實得 ${sleep_log}）" >&2; fail=1
fi
reset_fakes

# =============================================================================
# B 組：--storage-only 續傳（LS-240 範圍 2）
# =============================================================================

# ---- B1：40 個固定路徑全部已存在（list API 全回非空陣列）→ 全部略過，不上傳、不清理、不碰 SQL ----
out=$(run --storage-only); got=$?
expect 0 'B1 全部已存在 → 全部略過' "$got" "$out" \
  '✓ review-demo-seed --storage-only 完成：0 個物件已上傳、40 個已存在略過，重試 0 次'
count_is 'B1 完全不上傳（0 次上傳 POST）' 0 "$work/curl.log" 'object/media/'
count_is 'B1 40 次 list API 判缺' 40 "$work/curl.log" 'object/list/media'
count_is 'B1 不清理（0 次 DELETE）' 0 "$work/curl.log" 'DELETE http'
count_is 'B1 不碰 SQL（psql 未被呼叫）' 0 "$work/psql.log" ''
has 'B1 --storage-only 略過 SQL 段訊息' "$out" '→ --storage-only：跳過 SQL 段與帳號建立，沿用既有 DB 資料'
has 'B1 --storage-only 略過清理訊息' "$out" '→ --storage-only：略過批次清理（續傳只補缺物件，不清掉先前已成功上傳的內容）'
reset_fakes

# ---- B2（票文指定案例）：只有 media #1 原檔缺，其餘 39 個已存在 → 只上傳 1 個 ----
export FAKE_CURL_MISSING_PATHS="$MEDIA1_ORIG"
out=$(run --storage-only); got=$?
expect 0 'B2 缺 1 個物件 → 只補上傳那 1 個' "$got" "$out" \
  '✓ review-demo-seed --storage-only 完成：1 個物件已上傳、39 個已存在略過，重試 0 次'
count_is 'B2 只有 1 次上傳 POST（僅缺的那個物件）' 1 "$work/curl.log" 'object/media/'
if grep -F 'object/media/' "$work/curl.log" | grep -qF "$MEDIA1_ORIG"; then
  ok 'B2 POST 的目標路徑正確（media #1 原檔）'
else
  echo "✗ B2 POST 應打在 ${MEDIA1_ORIG}" >&2; sed 's/^/    /' "$work/curl.log" >&2; fail=1
fi
reset_fakes

# ---- B3（票文規約「不需要 --owner-email」）：--target prod --yes --storage-only 不需 --owner-email，
#      安全前提見檔頭：本 worktree 沒有 .env，會在讀 .env 之前的下一步「找不到 .env」安全中止 ----
out=$(run_prod --storage-only); got=$?
hasnt 'B3 --storage-only 不要求 --owner-email' "$out" 'yes 需要 --owner-email'
expect 2 'B3 --storage-only 略過 owner-email 後在找不到 .env 安全中止' "$got" "$out" '找不到' '.env'
has 'B3 --storage-only 對 prod 印確認／補齊訊息（不是「寫入」）' "$out" '即將確認／補齊正式站 Storage 物件（不寫 DB、不動帳號）'

echo "--- B 組完成 ---"

# =============================================================================
# C 組：psql 偵測（LS-240 範圍 3）——依序切換 PATH 上有無 psql／libpq 候選路徑／docker，
# 驗證優先序：PATH 直接找到 > 候選路徑 1 > 候選路徑 2 > docker exec 備援 > 安裝提示。
# =============================================================================

# ---- C1：psql 直接在 PATH 上（預設狀態，$bin/psql 已存在）→ 直接用，不印任何「改用」訊息 ----
out=$(run); got=$?
expect 0 'C1 PATH 上直接找到 psql → 全流程綠' "$got" "$out" '✓ review-demo-seed 完成'
hasnt 'C1 不印 libpq 候選路徑訊息' "$out" 'host PATH 沒有 psql'
hasnt 'C1 不印 docker exec 備援訊息' "$out" '改用 docker exec'
count_is 'C1 psql 被直接呼叫（非透過 docker）' 1 "$work/psql.log" 'psql'
reset_fakes

# ---- C2：PATH 上沒有 psql、候選路徑 1 存在 → 用候選路徑 1 ----
rm -f "$bin/psql"
write_fake_psql "$work/libpq1/psql"
export SEED_PSQL_CANDIDATES="$work/libpq1/psql $work/libpq2/psql"
out=$(run); got=$?
expect 0 'C2 候選路徑 1 存在 → 改用它、全流程綠' "$got" "$out" \
  "→ host PATH 沒有 psql，改用 ${work}/libpq1/psql" '✓ review-demo-seed 完成'
hasnt 'C2 不印 docker exec 備援訊息' "$out" '改用 docker exec'
reset_fakes
rm -rf "$work/libpq1"

# ---- C3：候選路徑 1 不存在、候選路徑 2 存在 → 用候選路徑 2（驗證依序嘗試、不是只看第一個）----
write_fake_psql "$work/libpq2/psql"
export SEED_PSQL_CANDIDATES="$work/libpq1/psql $work/libpq2/psql"
out=$(run); got=$?
expect 0 'C3 候選路徑 1 缺、候選路徑 2 存在 → 改用候選路徑 2' "$got" "$out" \
  "→ host PATH 沒有 psql，改用 ${work}/libpq2/psql" '✓ review-demo-seed 完成'
reset_fakes
rm -rf "$work/libpq2"

# ---- C4：PATH 與兩個候選路徑都沒有 psql，docker 可達 → 退回既有的 docker exec 備援 ----
export SEED_PSQL_CANDIDATES="$work/nope1/psql $work/nope2/psql"
export FAKE_DOCKER_MODE=ok
out=$(run); got=$?
expect 0 'C4 psql／候選路徑皆無、docker 可達 → 用 docker exec 備援' "$got" "$out" \
  '→ host 沒有 psql，改用 docker exec' '✓ review-demo-seed 完成'
count_is 'C4 psql 未被直接呼叫（改走 docker）' 0 "$work/psql.log" ''
reset_fakes

# ---- C5：psql／候選路徑／docker 全部不可用 → 印安裝提示、exit 2，不碰 photo/video 素材 ----
export SEED_PSQL_CANDIDATES="$work/nope1/psql $work/nope2/psql"
export FAKE_DOCKER_MODE=down
out=$(run); got=$?
expect 2 'C5 psql／候選路徑／docker 全無 → exit 2、印安裝提示' "$got" "$out" \
  '找不到 psql' '/opt/homebrew/opt/libpq/bin' '/usr/local/opt/libpq/bin' '請先 brew install libpq'
hasnt 'C5 未進到 Storage 上傳段（提早中止）' "$out" '→ 上傳 Storage 物件'
reset_fakes
write_fake_psql "$bin/psql"   # 還原成預設狀態，後續（若有）不受影響

echo "--- C 組完成 ---"

# =============================================================================
# D 組：--target prod 分支（僅驗證「有沒有在讀 .env 之前擋下」，見檔頭安全前提；不觸碰任何連線）
# =============================================================================

# ---- D0：--target prod --storage-only 不帶 --yes → 印新的 storage-only 計畫、exit 0，不連線 ----
out=$(run_prod_plan --storage-only); got=$?
expect 0 'D0 prod --storage-only 無 --yes → 只印計畫' "$got" "$out" \
  'LS-240 --storage-only' '不需要 --owner-email' \
  '（未帶 --yes：只印計畫，不連線、不寫入任何資料'
hasnt 'D0 不印「即將對正式站寫入」（storage-only 用另一句）' "$out" '即將對正式站寫入'
reset_fakes

# ---- D1：prod --yes（無 --storage-only、無 --owner-email）→ 維持既有行為，仍要求 --owner-email ----
out=$(run_prod); got=$?
expect 2 'D1 迴歸：非 storage-only 時 --owner-email 仍必填' "$got" "$out" '需要 --owner-email'
reset_fakes

# ---- D2：prod --yes --storage-only（無 --owner-email）→ 不擋 --owner-email，安全中止於找不到 .env ----
out=$(run_prod --storage-only); got=$?
hasnt 'D2 --storage-only 不擋 --owner-email' "$out" 'yes 需要 --owner-email'
expect 2 'D2 安全中止於找不到 .env（本 worktree 無 .env，見檔頭）' "$got" "$out" '找不到' '.env'
reset_fakes

# ---- D3：prod --yes --storage-only --owner-email 帶 @little-sprout.app → 網域檢查一併跳過，不因此擋下 ----
out=$(run_prod --storage-only --owner-email "someone@little-sprout.app"); got=$?
hasnt 'D3 --storage-only 跳過網域檢查' "$out" '不得使用 @little-sprout.app 網域'
expect 2 'D3 仍安全中止於找不到 .env' "$got" "$out" '找不到' '.env'
reset_fakes

echo "--- D 組完成 ---"

# =============================================================================
# Mutation 對照組（同 prod-purge-health.test.sh／queue_retry.test.sh 慣例：不在這裡自動
# 執行，本機手動跑一次、原文貼票 handoff，不進 commit）：
#   storage_put() 內的重試判斷
#     `if { [ "$curl_rc" -ne 0 ] && is_retryable_curl_rc "$curl_rc"; } || { [ "$curl_rc" -eq 0 ] && is_retryable_http "$http_code"; }; then`
#   拿掉（改成 `if false; then`）會讓 A1（curl exit 56 一次後成功）轉紅：不再重試、
#   直接印「✗ 上傳失敗（curl exit 56，HTTP 000，不重試）：<media #1 原檔路徑>」、exit 1，
#   跟預期的「exit 0、第 2 次嘗試成功」不符；A0（全部一次成功）不受影響（從未進入這個分支）。
# =============================================================================

if [ "$fail" -ne 0 ]; then
  echo "✗ review-demo-seed 自測失敗" >&2
  exit 1
fi
echo "✓ review-demo-seed 自測通過（${n} 組樣本）"
