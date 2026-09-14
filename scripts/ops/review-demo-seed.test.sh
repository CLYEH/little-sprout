#!/bin/bash
# review-demo-seed.sh 自測（LS-240）。CI rules job 每個 PR 都跑。
#
# 涵蓋範圍：①上傳重試（curl exit 56／7／28、HTTP 5xx／429 最多重試 3 次，退避
# 1s→2s→4s；其餘錯誤不重試）②--storage-only 續傳（跳過 SQL／清理／--owner-email，
# 只對 Storage 缺的物件補上傳，一次 list 而非逐一物件打 list，全部已存在時跳過素材
# 準備）③psql 偵測（PATH 找不到時依序試 libpq 候選路徑，再退回 docker exec，仍找不到
# 才印安裝提示）④既有 --target local 全流程仍綠。
#
# R2（merge-review R1 `b0371118`）新增：
#   M1（major）：重試對同一 path 原樣重送非冪等 POST——若第一次其實已落地、只是回應
#     斷掉，重送會撞 duplicate（reviewer 實測本機 storage-api 回 HTTP 400、body code
#     KeyAlreadyExists，不是 409），原本不在重試白名單而立即失敗。修法：第 2 次起的
#     嘗試加 `-H "x-upsert: true"`，M1 組驗證這個情境最終成功。
#   m1：`storage_exists()`／`list_existing_objects()` 對暫時性失敗也重試（同 storage_put()
#     的退避序列），不誤判成「不存在」；L 組驗證重試成功與窮盡重試 fail loud 兩條路徑。
#   m2：--storage-only 判缺改成一次 list 整個資料夾再本地比對（不再逐物件打 list），
#     全部已存在時跳過照片／影片素材準備；B 組驗證 list 呼叫次數與 sips／swift 是否
#     被呼叫。
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
# CI 實際事故（PR #373 rules job）：C／D 組覆蓋 PATH 時若剛好連 bash 自己的所在目錄都被濾掉
# （GH Actions runner 預裝 psql 在 /usr/bin，跟 bash 同目錄——strip_dirs_with_exe 見下——本機
# macOS／自建 docker image 沒裝 psql 所以重現不出來），run() 系列用裸 `bash "$script"` 會落到
# 「bash: command not found」（exit 127），而不是腳本本身的斷言失敗。這裡在任何 PATH 覆寫
# 之前就把目前的 bash 絕對路徑存起來，run() 系列一律用這個絕對路徑起子行程——PATH 覆寫只
# 影響 review-demo-seed.sh 內部查找 psql／docker 的邏輯，不影響「有沒有辦法先把它跑起來」。
REAL_BASH="${BASH:-$(command -v bash)}"
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

# 本輪 40 個固定路徑（20 media × 原檔＋縮圖）——手算對齊 review-demo-seed.sh 的公式
# （photo_sources 5 個來源，副檔名依序 jpg,jpg,jpg,jpg,jpg；i<=18 為照片、19-20 為影片），
# 供假 curl 的 list 端點組「全部存在」的回應用（m2：一次列出整個資料夾）。
# LS-248：後三個來源從 LS-46 佔位圖（*.png）換成 LS-247 定稿（design/appstore-photos/*.jpg），
# 副檔名連帶從 png 變 jpg——這串常數是「storage_path＝{media_id}.{ext}」的手算對照，來源清單
# 改了這裡就得跟著改（實測：只改腳本不改這裡，B1／B2／L1 三組會因為 10 條路徑對不上而轉紅）。
PHOTO_EXT_BY_IDX=(jpg jpg jpg jpg jpg)
ALL_MEDIA_PATHS=()
for i in $(seq 1 20); do
  id=$(printf 'd3000000-0000-4000-8000-%012x' "$i")
  if [ "$i" -le 18 ]; then
    src_idx=$(( (i - 1) % 5 ))
    ext=${PHOTO_EXT_BY_IDX[$src_idx]}
    ALL_MEDIA_PATHS+=("${FAMILY_ID}/${SEED_YM}/${id}.${ext}")
  else
    ALL_MEDIA_PATHS+=("${FAMILY_ID}/${SEED_YM}/${id}.mp4")
  fi
  ALL_MEDIA_PATHS+=("${FAMILY_ID}/${SEED_YM}/${id}_thumb.jpg")
done
export FAKE_CURL_ALL_PATHS="${ALL_MEDIA_PATHS[*]}"

bin="$work/bin"; mkdir -p "$bin"

cat > "$bin/supabase" <<'STUB'
#!/bin/bash
if [ "$1" = status ]; then
  printf 'DB_URL="postgresql://fake-user:fake@127.0.0.1:1/postgres"\nAPI_URL="%s"\nSERVICE_ROLE_KEY="fake-service-key"\n' "${FAKE_API_URL:-http://127.0.0.1:9/fake}"  # gate:allow-example（假 DB_URL，供假身 supabase status 輸出用，非真憑證）
  exit 0
fi
exit 1
STUB

# swift review-demo-genvideo.swift <output.mp4> [seconds]：假身忽略內容，直接產生空檔＋印固定秒數；
# 留一個 INVOKED 標記檔供 m2（全部已存在時應跳過素材準備）斷言用。
cat > "$bin/swift" <<'STUB'
#!/bin/bash
touch "$FAKE_WORK/INVOKED-swift"
: > "$2"
echo 2
STUB

# sips：`-g pixelWidth|pixelHeight <src>` 印固定尺寸（模擬 review-demo-seed.sh 的 awk 解析格式）；
# `-s ... <src> --out <dst>` 只需要在 <dst> 產生一個檔案；同樣留 INVOKED 標記檔。
cat > "$bin/sips" <<'STUB'
#!/bin/bash
touch "$FAKE_WORK/INVOKED-sips"
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

# curl：依 -X 判斷 method、抓 http* 開頭的參數當 url、抓 -d 之後的參數當 body、偵測 x-upsert
# header，記錄每次呼叫；
#   DELETE                     → 一律成功（FAKE_CURL_DELETE_EXIT 可覆寫）。
#   POST .../object/list/media → --storage-only 一次性判缺（R2 m2：改成一次列整個資料夾，
#     不逐物件打 list）：回應＝FAKE_CURL_ALL_PATHS 扣掉 FAKE_CURL_MISSING_PATHS（空白分隔）
#     之後剩下的 {"name":...} 陣列。FAKE_CURL_LIST_ALWAYS_FAIL=1 讓這個端點每次都回
#     FAKE_CURL_LIST_FAIL_MODE（m1：驗證持續失敗 fail loud）；只設 FAKE_CURL_LIST_FAIL_MODE
#     （不設 ALWAYS_FAIL）則只有第一次回該錯誤、之後正常（m1：驗證暫時性失敗會重試成功）。
#   POST .../object/media/<path>（上傳）→ FAKE_CURL_ALWAYS_FAIL_PATH 指定的路徑每次都回
#     FAKE_CURL_ALWAYS_FAIL_MODE；FAKE_CURL_FLAKY_PATH 指定的路徑只在第一次呼叫回
#     FAKE_CURL_FLAKY_MODE，之後成功；FAKE_CURL_DUP_PATH 指定的路徑第一次回 curl exit 56
#     （模擬「其實已落地、回應斷掉」），第二次起：有 x-upsert header 就回 200、沒有就回
#     400（R2 M1：模擬 reviewer 實測的 KeyAlreadyExists duplicate，不是 409）；其餘一律回
#     200。MODE 值：curl56／curl7／curl28／curl6（curl exit）、http500／http429／http404
#     （HTTP status）。
cat > "$bin/curl" <<'STUB'
#!/bin/bash
method=GET; url=; body=; has_upsert=0
prev=
for a in "$@"; do
  case "$prev" in -X) method=$a ;; -d) body=$a ;; esac
  case "$a" in http*) url=$a ;; esac
  [ "$a" = "x-upsert: true" ] && has_upsert=1
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
        if [ "${FAKE_CURL_LIST_ALWAYS_FAIL:-0}" = 1 ]; then
          fail_as "${FAKE_CURL_LIST_FAIL_MODE:-curl56}"
        elif [ -n "${FAKE_CURL_LIST_FAIL_MODE:-}" ]; then
          mkdir -p "$FAKE_WORK/attempts"
          marker="$FAKE_WORK/attempts/list"
          count=0
          [ -f "$marker" ] && count=$(cat "$marker")
          count=$((count + 1))
          echo "$count" > "$marker"
          [ "$count" -eq 1 ] && fail_as "$FAKE_CURL_LIST_FAIL_MODE"
        fi
        out="["
        first=1
        for p in ${FAKE_CURL_ALL_PATHS:-}; do
          skip=0
          for miss in ${FAKE_CURL_MISSING_PATHS:-}; do
            [ "$p" = "$miss" ] && { skip=1; break; }
          done
          [ "$skip" -eq 1 ] && continue
          name=${p##*/}
          [ "$first" -eq 1 ] || out="${out},"
          out="${out}{\"name\":\"${name}\"}"
          first=0
        done
        out="${out}]"
        printf '%s' "$out"; exit 0
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
        if [ -n "${FAKE_CURL_DUP_PATH:-}" ] && [ "$path" = "$FAKE_CURL_DUP_PATH" ]; then
          mkdir -p "$FAKE_WORK/attempts"
          marker="$FAKE_WORK/attempts/dup"
          count=0
          [ -f "$marker" ] && count=$(cat "$marker")
          count=$((count + 1))
          echo "$count" > "$marker"
          if [ "$count" -eq 1 ]; then
            fail_as curl56
          elif [ "$has_upsert" -eq 1 ]; then
            printf '200'; exit 0
          else
            printf '400'; exit 0
          fi
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
# LS-281：另外把 `-f <檔>` 的 SQL 原文抄一份到 $FAKE_WORK/psql-sql.log——F 組要斷言的是
# 「腳本真的產出了哪些 SQL」（相簿、20 筆 album_media 連結、自我檢查條文），不是腳本原始碼
# 的字面（那種斷言改個變數名就過得去）。種子的 SQL 檔是 mktemp 的暫存檔、跑完就被 trap
# 清掉，只有在這裡攔得到。
write_fake_psql() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'STUB'
#!/bin/bash
echo "psql $*" >> "$FAKE_WORK/psql.log"
has_f=0
prev=""
for a in "$@"; do
  [ "$a" = -f ] && has_f=1
  [ "$prev" = -f ] && [ -f "$a" ] && cat "$a" >> "$FAKE_WORK/psql-sql.log"
  prev="$a"
done
[ "$has_f" -eq 1 ] || cat > /dev/null
exit "${FAKE_PSQL_EXIT:-0}"
STUB
  chmod +x "$1"
}
write_fake_psql "$bin/psql"   # 預設狀態：psql 直接在 PATH 上找得到（A／B 組都要能跑完全流程）

# 從目前 PATH 濾掉「含真的 psql 執行檔」的目錄——C 組的「PATH 找不到 psql」情境不依賴本機環境
# 剛好沒裝／沒 link psql 這個巧合。R2（CI 實際事故，PR #373 rules job）：不能把整個目錄丟掉——
# GH Actions runner 預裝的 psql 剛好跟 bash 同目錄（/usr/bin），整個丟掉連 bash／git／sed／tr
# 這些其他工具的來源也一併消失，導致 review-demo-seed.sh 內部「未在 lock 內就 exec bash
# supabase-lock.sh -- bash …」那段自我 re-exec（繼承同一份覆寫過的 PATH）找不到 bash（exit
# 127，「bash: command not found」，本機 macOS／自建 docker image 沒裝 psql 所以重現不出來）。
# 改成把該目錄「除了 $exe 之外的其他檔案都用 symlink 保留」成一個合成目錄，PATH 換成指到
# 這個合成目錄——真正做到「只有 $exe 找不到，其他工具都還在」，而不是整個目錄消失。
strip_dirs_with_exe() {
  local exe=$1 d out="" dirs i=0 shadow_root shadow_dir f base
  shadow_root="$work/shadow-${exe}"
  mkdir -p "$shadow_root"
  local IFS=':'
  read -r -a dirs <<< "$PATH"
  for d in "${dirs[@]}"; do
    [ -n "$d" ] || continue
    if [ -x "$d/$exe" ]; then
      i=$((i + 1))
      shadow_dir="$shadow_root/$i"
      mkdir -p "$shadow_dir"
      for f in "$d"/*; do
        [ -e "$f" ] || continue
        base=$(basename "$f")
        [ "$base" = "$exe" ] && continue
        ln -sf "$f" "$shadow_dir/$base" 2>/dev/null
      done
      out="${out}${shadow_dir}:"
    else
      out="${out}${d}:"
    fi
  done
  printf '%s' "$out"
}
BASE_PATH=$(strip_dirs_with_exe psql)

PW='Ls240TestPw1234AAAA'   # 固定 --owner-password：繞過 openssl 自動產生密碼，測試不依賴它
run() {   # run [額外參數…]：固定 --target local --owner-password <fixed>
  PATH="$bin:$BASE_PATH" "$REAL_BASH" "$script" --target local --owner-password "$PW" "$@" 2>&1
}
run_prod() {   # run_prod [額外參數…]：固定 --target prod --yes（安全前提見檔頭）
  PATH="$bin:$BASE_PATH" "$REAL_BASH" "$script" --target prod --yes "$@" 2>&1
}
run_prod_plan() {   # run_prod_plan [額外參數…]：--target prod 不帶 --yes，只印計畫
  PATH="$bin:$BASE_PATH" "$REAL_BASH" "$script" --target prod "$@" 2>&1
}

reset_fakes() {
  rm -rf "$work/attempts" "$work/lock" "$work/INVOKED-sips" "$work/INVOKED-swift"
  : > "$work/curl.log"; : > "$work/sleep.log"; : > "$work/psql.log"; : > "$work/docker.log"
  : > "$work/psql-sql.log"
  unset FAKE_CURL_FLAKY_PATH FAKE_CURL_FLAKY_MODE FAKE_CURL_ALWAYS_FAIL_PATH FAKE_CURL_ALWAYS_FAIL_MODE
  unset FAKE_CURL_MISSING_PATHS FAKE_CURL_DELETE_EXIT FAKE_DOCKER_MODE FAKE_PSQL_EXIT SEED_PSQL_CANDIDATES
  unset FAKE_CURL_DUP_PATH FAKE_CURL_LIST_FAIL_MODE FAKE_CURL_LIST_ALWAYS_FAIL
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
not_invoked() {   # not_invoked <名稱> <工具>（斷言 $work/INVOKED-<工具> 不存在）
  if [ -e "$work/INVOKED-$2" ]; then echo "✗ ${1}：不該呼叫 ${2}" >&2; fail=1; else ok "$1"; fi
}
was_invoked() {   # was_invoked <名稱> <工具>（斷言 $work/INVOKED-<工具> 存在）
  if [ -e "$work/INVOKED-$2" ]; then ok "$1"; else echo "✗ ${1}：應該呼叫 ${2}" >&2; fail=1; fi
}

# =============================================================================
# N1（CI 實際事故，PR #373 rules job）：PATH 只剩 fixture 目錄時仍能起子行程——不誤判成
# 「bash: command not found」。用 --help（唯一完全不需要任何外部工具、只印用法行就
# exit 0 的路徑）驗證：即使 PATH 窄到只剩 $bin（沒有 BASE_PATH、沒有任何系統目錄），
# "$REAL_BASH" 仍能正確啟動 review-demo-seed.sh 並執行到它自己的邏輯。
# =============================================================================
out=$(PATH="$bin" "$REAL_BASH" "$script" --help 2>&1); got=$?
expect 0 'N1 PATH 只剩 fixture 目錄仍能起子行程（不誤判成 bash: command not found）' "$got" "$out" \
  '用法：review-demo-seed.sh'
# 只斷言「bash 自己」找得到——PATH 窄到只剩 $bin 時，dirname 等其他系統工具本來就會缺
# （腳本頭幾行 ROOT= 那句），這是預期中、無關本項驗證重點的雜訊，不是本測試要抓的問題。
hasnt 'N1 不應出現「bash: command not found」（bash 自己要能被找到）' "$out" 'bash: command not found'
reset_fakes

echo "--- N1 完成 ---"

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

echo "--- A 組完成 ---"

# =============================================================================
# M1 組（merge-review R1 major）：重試對「同一個 path」原樣重送非冪等 POST——若第一次
# 其實已經把物件寫進去了、只是回應階段斷掉（curl exit 56／28／504 依定義都發生在 body
# 送出之後），重送會撞 duplicate。reviewer 實測本機 storage-api：同 path 重送回 HTTP 400
# （body code＝KeyAlreadyExists，不是 409）。修法：第 2 次起的嘗試加 x-upsert，讓「其實
# 已落地」的重送變成覆寫成功。這裡驗證修法後的最終行為；mutation（拿掉 x-upsert）驗證
# 見檔尾對照組。
# =============================================================================
export FAKE_CURL_DUP_PATH="$MEDIA1_ORIG"
out=$(run); got=$?
expect 0 'M1 首次 curl 56（已落地）、重試帶 x-upsert 解決 duplicate → exit 0' "$got" "$out" \
  '✓ review-demo-seed 完成：40 個物件已上傳（20 個原檔 + 20 個縮圖），重試 1 次，DB 計數見上方 NOTICE'
reset_fakes

echo "--- M1 組完成 ---"

# =============================================================================
# B 組：--storage-only 續傳（LS-240 範圍 2；R2 merge-review m2：一次 list 整個資料夾、
# 全部已存在時跳過素材準備）
# =============================================================================

# ---- B1：40 個固定路徑全部已存在（list API 一次回應含全部 40 個 name）→ 全部略過，
#      不上傳、不清理、不碰 SQL、不準備素材（m2） ----
out=$(run --storage-only); got=$?
expect 0 'B1 全部已存在 → 全部略過' "$got" "$out" \
  '→ --storage-only：本輪 40 個固定路徑已全部存在於 Storage，略過素材準備／SQL／清理／上傳' \
  '✓ review-demo-seed --storage-only 完成：0 個物件已上傳、40 個已存在略過，重試 0 次'
count_is 'B1 只 1 次 list API 判缺（m2：不再逐物件打 40 次）' 1 "$work/curl.log" 'object/list/media'
count_is 'B1 完全不上傳（0 次上傳 POST）' 0 "$work/curl.log" 'object/media/'
count_is 'B1 不清理（0 次 DELETE）' 0 "$work/curl.log" 'DELETE http'
count_is 'B1 不碰 SQL（psql 未被呼叫）' 0 "$work/psql.log" ''
not_invoked 'B1 全部已存在時不呼叫 sips（m2：素材白做）' sips
not_invoked 'B1 全部已存在時不呼叫 swift（m2：素材白做）' swift
reset_fakes

# ---- B2（票文指定案例）：只有 media #1 原檔缺，其餘 39 個已存在 → 只上傳 1 個，
#      且仍需要準備素材（缺件時不是「白做」） ----
export FAKE_CURL_MISSING_PATHS="$MEDIA1_ORIG"
out=$(run --storage-only); got=$?
expect 0 'B2 缺 1 個物件 → 只補上傳那 1 個' "$got" "$out" \
  '✓ review-demo-seed --storage-only 完成：1 個物件已上傳、39 個已存在略過，重試 0 次'
count_is 'B2 只 1 次 list API 判缺' 1 "$work/curl.log" 'object/list/media'
count_is 'B2 只有 1 次上傳 POST（僅缺的那個物件）' 1 "$work/curl.log" 'object/media/'
if grep -F 'object/media/' "$work/curl.log" | grep -qF "$MEDIA1_ORIG"; then
  ok 'B2 POST 的目標路徑正確（media #1 原檔）'
else
  echo "✗ B2 POST 應打在 ${MEDIA1_ORIG}" >&2; sed 's/^/    /' "$work/curl.log" >&2; fail=1
fi
was_invoked 'B2 缺件時仍準備照片素材' sips
was_invoked 'B2 缺件時仍準備影片素材' swift
reset_fakes

# ---- B3（票文規約「不需要 --owner-email」）：--target prod --yes --storage-only 不需 --owner-email，
#      安全前提見檔頭：本 worktree 沒有 .env，會在讀 .env 之前的下一步「找不到 .env」安全中止 ----
out=$(run_prod --storage-only); got=$?
hasnt 'B3 --storage-only 不要求 --owner-email' "$out" 'yes 需要 --owner-email'
expect 2 'B3 --storage-only 略過 owner-email 後在找不到 .env 安全中止' "$got" "$out" '找不到' '.env'
has 'B3 --storage-only 對 prod 印確認／補齊訊息（不是「寫入」）' "$out" '即將確認／補齊正式站 Storage 物件（不寫 DB、不動帳號）'
reset_fakes

echo "--- B 組完成 ---"

# =============================================================================
# L 組（merge-review R1 m1）：--storage-only 的 list 判缺呼叫本身具韌性——暫時性失敗
# 重試（同 storage_put() 的退避序列），持續失敗才 fail loud（不誤判成「都缺」或
# 「都在」，避免觸發不必要的重傳、可能撞上 M1 的 duplicate 情境）。
# =============================================================================

# ---- L1：list 呼叫 curl 56 一次後成功 → 40 個皆存在，只真的打了兩次網路 ----
export FAKE_CURL_LIST_FAIL_MODE=curl56
out=$(run --storage-only); got=$?
expect 0 'L1 list 呼叫 curl 56 一次後成功 → exit 0（40 個皆存在）' "$got" "$out" \
  '⚠ 列出 Storage 既有物件暫時性錯誤（curl exit 56），1s 後重試（第 2 次嘗試）' \
  '✓ review-demo-seed --storage-only 完成：0 個物件已上傳、40 個已存在略過'
count_is 'L1 list 只真的打了兩次（重試後成功、之後全走快取）' 2 "$work/curl.log" 'object/list/media'
reset_fakes

# ---- L2：list 呼叫持續失敗、窮盡 3 次重試 → fail loud，不誤報成功 ----
export FAKE_CURL_LIST_ALWAYS_FAIL=1 FAKE_CURL_LIST_FAIL_MODE=curl56
out=$(run --storage-only); got=$?
expect 1 'L2 list 呼叫持續失敗、窮盡 3 次重試 → fail loud（不誤判缺漏）' "$got" "$out" \
  '✗ review-demo-seed：--storage-only 列出 Storage 既有物件失敗（重試 3 次仍失敗，curl exit 56），無法判斷缺漏，中止'
hasnt 'L2 不誤報成功' "$out" '✓ review-demo-seed'
reset_fakes

echo "--- L 組完成 ---"

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
# E 組（LS-248）：資產清單本身——demo 家庭灌的照片必須是 LS-247 定稿，不得再是 LS-46
# 佔位圖。為什麼要一組直接讀來源清單的斷言，而不是靠 A／B／L 組的路徑對照間接釘住：
# 那些組只看得到副檔名（storage_path＝{media_id}.{ext}），把 hero-grandma.png 換成任何
# 一張別的 .jpg 都不會讓它們轉紅——但送審截圖裡出現的就是非出貨資產（LS-234 決定 1b
# 附條件①正是為了擋這件事）。這裡直接讀 photo_sources 陣列的字面。
# =============================================================================
sources_block=$(sed -n '/^photo_sources=(/,/^)/p' "$script")
has 'E1 photo_sources 含 LS-247 定稿 hero' "$sources_block" 'design/appstore-photos/hero.jpg'
has 'E1 photo_sources 含 LS-247 定稿 invite' "$sources_block" 'design/appstore-photos/invite.jpg'
has 'E1 photo_sources 含 LS-247 定稿 join' "$sources_block" 'design/appstore-photos/join.jpg'
hasnt 'E2 photo_sources 不得再含 LS-46 佔位圖 hero-grandma' "$sources_block" 'hero-grandma'
hasnt 'E2 photo_sources 不得再含 LS-46 佔位圖 invite-grandma' "$sources_block" 'invite-grandma'
hasnt 'E2 photo_sources 不得再含 LS-46 佔位圖 join-parents' "$sources_block" 'join-parents'
for asset in design/appstore-photos/hero.jpg design/appstore-photos/invite.jpg design/appstore-photos/join.jpg; do
  if [ -f "$root/$asset" ]; then ok "E3 資產存在於 repo：$asset"
  else echo "✗ E3 資產不存在於 repo：$asset（photo_sources 指到的檔案被改名／刪除，正式站種子會在素材檢查就中止）" >&2; fail=1; fi
done
echo "--- E 組完成 ---"

# =============================================================================
# F 組（LS-281）：相簿「阿公阿嬤家過年」＋ album_media 連結。
#
# 為什麼要有這一組：`private.soft_delete_unreferenced_media()`（LS-213，pg_cron 每日
# 19:30 UTC＝台北 03:30）軟刪「deleted_at is null＋超過 24h＋不掛在任何 diary_media／
# album_media」的 media——種子在 LS-281 之前一本相簿都不建、一條連結都不掛，20 筆 media
# 天生符合那個條件，正式站 2026-09-13 03:30 已經真的被全部軟刪過一次（LS-248 R1／R2）。
# A／B／L 組只看 Storage 路徑，完全看不到 DB 內容；E 組讀的是腳本原始碼字面。這一組驗的是
# 「腳本產給 psql 的 SQL 原文」（假 psql 把 -f 的檔案抄進 psql-sql.log），所以連
# sort_order 連不連續、自我檢查有沒有真的把「未連結 live media」數出來都釘得住。
# =============================================================================
OWNER_ID_T=d1000000-0000-4000-8000-000000000001
ALBUM_ID_T=d8000000-0000-4000-8000-000000000001
ALBUM_TITLE_T=阿公阿嬤家過年
COVER_ID_T=d3000000-0000-4000-8000-000000000003   # i=3 → src_idx=(3-1)%5=2 → photo_sources[2]＝hero.jpg

out=$(run); got=$?
expect 0 'F0 帶相簿的全流程仍綠' "$got" "$out" '✓ review-demo-seed 完成'
has 'F0 計畫列出相簿' "$out" "相簿：1（「${ALBUM_TITLE_T}」，封面取 hero；20 筆 media 全數掛進 album_media，sort_order 0–19）"
sql1=$(cat "$work/psql-sql.log")

has 'F1 SQL 建相簿（固定 id／封面 hero／created_by owner）' "$sql1" \
  "values ('${ALBUM_ID_T}', '${FAMILY_ID}', '${ALBUM_TITLE_T}', '${COVER_ID_T}', '${OWNER_ID_T}')"
has 'F2 冪等以「同 family＋同 title＋未軟刪」查找既有相簿' "$sql1" \
  "where family_id = '${FAMILY_ID}' and title = '${ALBUM_TITLE_T}' and deleted_at is null;"
has 'F2 查得到就沿用、不重建' "$sql1" 'if v_album_id is null then'
has 'F2 連結重複執行不報錯' "$sql1" 'on conflict (album_id, media_id) do nothing;'

# F3：20 筆連結、sort_order 0–19 連續，且順序＝media_ids 順序（＝photo_sources 輪替順序）。
f3_bad=0
for i in $(seq 1 20); do
  mid=$(printf 'd3000000-0000-4000-8000-%012x' "$i")
  printf '%s' "$sql1" | grep -qF -- "('${mid}'::uuid, $((i - 1)))" || {
    echo "✗ F3 album_media 缺 media #${i}（${mid}）或 sort_order 不是 $((i - 1))" >&2; f3_bad=1; }
done
if [ "$f3_bad" -eq 0 ]; then ok 'F3 album_media 20 筆、sort_order 0–19 連續且依 media_ids 順序'
else fail=1; fi
f3_n=$(printf '%s' "$sql1" | grep -cF -- "'::uuid, " || true)
if [ "${f3_n:-0}" -eq 20 ]; then ok 'F3 恰好 20 筆連結（沒有多掛）'
else echo "✗ F3 album_media 連結列應為 20，實得 ${f3_n:-0}" >&2; fail=1; fi

# F4：自我檢查條文——這三條是「今天綠、明天被 03:30 排程洗掉」的唯一機械防線。
has 'F4 自我檢查斷言 albums=1' "$sql1" 'if n_albums <> 1 then'
has 'F4 自我檢查斷言 album_media=20' "$sql1" 'if n_album_media <> 20 then'
has 'F4 自我檢查斷言未連結 live media=0' "$sql1" 'if n_unlinked <> 0 then'
has 'F4 未連結計數逐字對齊 LS-213 判準（diary_media）' "$sql1" \
  'and not exists (select 1 from public.diary_media dm'
has 'F4 未連結計數逐字對齊 LS-213 判準（album_media）' "$sql1" \
  'and not exists (select 1 from public.album_media am'
has 'F4 feed_items 期望值隨相簿改成 26' "$sql1" \
  "if n_feed <> 26 then"
has 'F4 完成 NOTICE 列出新計數' "$sql1" 'albums=1 album_media=20 unlinked_media=0'

# F5：冪等——重跑產生的相簿段 SQL 與第一次逐字元相同（不因重跑多建一本、也不換 id）。
album_section() { printf '%s' "$1" | sed -n '/select id into v_album_id/,/on conflict (album_id, media_id) do nothing;/p'; }
sec1=$(album_section "$sql1")
reset_fakes
out=$(run); got=$?
expect 0 'F5 第二次重跑仍綠' "$got" "$out" '✓ review-demo-seed 完成'
sec2=$(album_section "$(cat "$work/psql-sql.log")")
if [ "$sec1" = "$sec2" ] && [ -n "$sec1" ]; then ok 'F5 重跑產生的相簿段 SQL 逐字元相同（冪等）'
else echo "✗ F5 重跑產生的相簿段 SQL 不同（或抓不到）" >&2; diff <(printf '%s' "$sec1") <(printf '%s' "$sec2") >&2 || true; fail=1; fi
count_is 'F5 單次執行只建一本相簿' 1 "$work/psql-sql.log" 'insert into public.albums'
reset_fakes

echo "--- F 組完成 ---"

# =============================================================================
# Mutation 對照組（同 prod-purge-health.test.sh／queue_retry.test.sh 慣例：不在這裡自動
# 執行，本機手動跑一次、原文貼票 handoff，不進 commit）：
#   1. storage_put() 內的重試判斷
#        `if { [ "$curl_rc" -ne 0 ] && is_retryable_curl_rc "$curl_rc"; } || { [ "$curl_rc" -eq 0 ] && is_retryable_http "$http_code"; }; then`
#      拿掉（改成 `if false; then`）會讓 A1（curl exit 56 一次後成功）轉紅：不再重試、
#      直接印「✗ 上傳失敗（curl exit 56，HTTP 000，不重試）：<media #1 原檔路徑>」、exit 1，
#      跟預期的「exit 0、第 2 次嘗試成功」不符；A0（全部一次成功）不受影響（從未進入
#      這個分支）。
#   2.（R2 M1）storage_put() 內的 `if [ "$attempt" -gt 1 ]; then upsert_hdr=(-H "x-upsert: true"); ...`
#      改成一律 `upsert_hdr=()`（即拿掉 x-upsert）會讓 M1 組轉紅：第二次嘗試回到沒有
#      x-upsert 的行為，假 curl 回 HTTP 400（duplicate），因不在重試白名單而立即印
#      「✗ 上傳失敗（curl exit 0，HTTP 400，不重試）：<media #1 原檔路徑>」、exit 1，
#      跟預期的「exit 0、重試 1 次」不符；A0／A1 等其餘樣本不受影響（它們的路徑沒有
#      設 FAKE_CURL_DUP_PATH）。
# =============================================================================

if [ "$fail" -ne 0 ]; then
  echo "✗ review-demo-seed 自測失敗" >&2
  exit 1
fi
echo "✓ review-demo-seed 自測通過（${n} 組樣本）"
