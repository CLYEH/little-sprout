#!/bin/bash
# detect-simulator.sh／simulator-lock.sh 的自測（LS-83）。CI rules job 跑。
# 「前饋必有反饋」對這支腳本也適用：若退化——多 worktree 又解析回同一台裝置、強制共用時不排隊、
# CI 模式誤建或誤鎖、建立失敗不退回共用——這裡會紅。stub `xcrun`（純文字 db，一行一台裝置：
# name\tudid\tos）取代真的 simctl，不碰本機真正的模擬器；bash 3.2（`${name}` 展開，不用陣列／`${var,,}`）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
detect="${root}/scripts/gates/detect-simulator.sh"
fail=0

has()   { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✓ $1"; else echo "✗ ${1}（輸出應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; fi; }
id_of() { printf '%s' "$1" | sed -n 's/^platform=iOS Simulator,id=\(.*\)$/\1/p'; }   # 從整段輸出取 UDID
is_dest_ok() {   # 輸出必須是合法的 `platform=iOS Simulator,id=<非空>` 一行，且不含 name=／OS=（LS-83 的重點）
  local label=$1 out=$2 uid
  uid=$(id_of "$out")
  if [ -z "$uid" ]; then echo "✗ ${label}（輸出不是合法的 platform=iOS Simulator,id=<UDID>：${out}）" >&2; fail=1; return 1; fi
  if printf '%s' "$out" | grep -qE 'name=|OS='; then echo "✗ ${label}（輸出不應再含 name=／OS=：${out}）" >&2; fail=1; return 1; fi
  echo "✓ ${label}（id=${uid}）"
  return 0
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/wt"

# ---- stub xcrun：純文字 db（$STUB_DB，一行一台裝置 name\tudid\tos），吃 detect-simulator.sh 會呼叫的四種
#      simctl 子命令；STUB_NO_DEVICETYPE=1 讓 devicetypes 查詢查不到（模擬「建立失敗」）----
cat > "$work/bin/xcrun" <<'STUB'
#!/bin/bash
set -uo pipefail
db="${STUB_DB:?}"
[ -f "$db" ] || : > "$db"
[ "${1:-}" = simctl ] || exit 1
shift
cmd=${1:-}; shift || true
case "$cmd" in
  list)
    what=${1:-}; shift || true
    case "$what" in
      devices)
        echo "== Devices =="
        echo "-- iOS ${STUB_OS:-26.0} --"
        while IFS=$'\t' read -r n u _os || [ -n "$n" ]; do
          [ -n "$n" ] || continue
          echo "    ${n} (${u}) (Shutdown)"
        done < "$db"
        ;;
      runtimes)
        echo "== Runtimes =="
        rid=$(printf 'iOS-%s' "${STUB_OS:-26.0}" | tr '.' '-')
        echo "iOS ${STUB_OS:-26.0} (${STUB_OS:-26.0}.1 - 23A1) - com.apple.CoreSimulator.SimRuntime.${rid}"
        ;;
      devicetypes)
        echo "== Device Types =="
        if [ "${STUB_NO_DEVICETYPE:-0}" != 1 ]; then
          echo "${STUB_MODEL:-iPhone 17 Pro} (com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro)"
        fi
        ;;
      *) exit 1 ;;
    esac
    ;;
  create)
    name=${1:-}
    n=0
    while :; do
      udid=$(printf 'UUID-%05d' "$n")
      grep -qF "$(printf '\t%s\t' "$udid")" "$db" 2>/dev/null || break
      n=$((n + 1))
    done
    printf '%s\t%s\t%s\n' "$name" "$udid" "${STUB_OS:-26.0}" >> "$db"
    echo "$udid"
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$work/bin/xcrun"
export PATH="$work/bin:$PATH"
export DETECT_SIMULATOR_LOCK_DIR="$work/simlock"   # 全程用測試自己的鎖目錄，不碰本機真正 /tmp/simulator-lock-*
# GitHub Actions runner 對每個 step 都設 CI=true——不清掉的話，本檔案繼承來的環境會讓 detect-simulator.sh
# 把每個情境都判成 CI 模式（不查／不建專屬模擬器、不鎖），非 CI 情境的斷言全部假紅（PR #154 CI rules 紅、
# coordinator 2026-08-25 回報）。這裡統一清成「非 CI」，需要 CI 模式的情境（⑥）自己用 `CI=true` 前綴覆蓋
# ——bash 的臨時變數指定對函式呼叫一樣有效，只在該次呼叫生效，不影響這裡 unset 之後的其餘情境。
unset CI

fresh_db() { : > "$1"; printf 'iPhone 17 Pro\tSHARED-UDID\t26.0\n' > "$1"; }   # 每個情境各一份新 db，只帶「共用第一台」

run_in() {   # $1＝worktree 目錄（basename 即票號來源，非 git repo：detect-simulator.sh 退回 pwd）；其餘傳給 detect-simulator.sh
  local dir=$1; shift
  ( cd "$dir" && bash "$detect" "$@" )
}

# ---- ① 兩個 worktree 同時跑：各得不同 UDID，且各自的專屬裝置寫進 db ----
db1="$work/db1"; fresh_db "$db1"
mkdir -p "$work/wt/LS-101" "$work/wt/LS-102"
out1a=$(STUB_DB="$db1" run_in "$work/wt/LS-101") ; rc1a=$?
out1b=$(STUB_DB="$db1" run_in "$work/wt/LS-102") ; rc1b=$?
[ "$rc1a" -eq 0 ] && [ "$rc1b" -eq 0 ] && echo "✓ ① 兩個 worktree 皆 exit 0" || { echo "✗ ① exit 非 0（${rc1a}／${rc1b}）" >&2; fail=1; }
is_dest_ok '① LS-101 輸出合法' "$out1a"
is_dest_ok '① LS-102 輸出合法' "$out1b"
u1a=$(id_of "$out1a"); u1b=$(id_of "$out1b")
if [ -n "$u1a" ] && [ "$u1a" != "$u1b" ]; then echo "✓ ① 兩個 worktree 的 UDID 不同"; else echo "✗ ① 兩個 worktree 的 UDID 相同（${u1a}）" >&2; fail=1; fi
has '① db 記到 LS-101 專屬裝置' "$(cat "$db1")" 'LS-101-iPhone17Pro'
has '① db 記到 LS-102 專屬裝置' "$(cat "$db1")" 'LS-102-iPhone17Pro'

# ---- ② 同一個 worktree 再跑一次：沿用既有專屬裝置，不重建（UDID 不變）----
out2=$(STUB_DB="$db1" run_in "$work/wt/LS-101")
u2=$(id_of "$out2")
if [ "$u2" = "$u1a" ]; then echo "✓ ② 再跑一次沿用既有專屬模擬器（同 UDID）"; else echo "✗ ② 應沿用 ${u1a}，實得 ${u2}" >&2; fail=1; fi

# ---- ③ 非票號分支／主 checkout：worktree 目錄名不含 LS-<n> → 專屬裝置名用 main- 開頭 ----
db3="$work/db3"; fresh_db "$db3"
mkdir -p "$work/wt/maincheckout"
out3=$(STUB_DB="$db3" run_in "$work/wt/maincheckout")
is_dest_ok '③ 主 checkout（無票號）輸出合法' "$out3"
has '③ db 記到 main- 開頭的專屬裝置' "$(cat "$db3")" 'main-iPhone17Pro'

# ---- ④ DETECT_SIMULATOR_SHARED=1：直接退回共用第一台，不查也不建專屬 ----
db4="$work/db4"; fresh_db "$db4"
out4=$(STUB_DB="$db4" DETECT_SIMULATOR_SHARED=1 run_in "$work/wt/LS-101")
u4=$(id_of "$out4")
if [ "$u4" = SHARED-UDID ]; then echo "✓ ④ 強制共用 → 回共用第一台 UDID"; else echo "✗ ④ 應為 SHARED-UDID，實得 ${u4}" >&2; fail=1; fi
if grep -qF 'LS-101' "$db4"; then echo "✗ ④ 強制共用不該建立專屬裝置" >&2; fail=1; else echo "✓ ④ 強制共用未建立專屬裝置"; fi

# ---- ⑤ DETECT_SIMULATOR_SHARED=1 第二個等 lock：先背景佔住共用 lock，第二次呼叫要等它放掉才回 ----
db5="$work/db5"; fresh_db "$db5"
rm -rf "$work/simlock"
bash "${root}/scripts/ops/simulator-lock.sh" --dir "$work/simlock" -- sleep 3 &
holder_pid=$!
sleep 0.5
t0=$(date +%s)
out5=$(STUB_DB="$db5" DETECT_SIMULATOR_SHARED=1 run_in "$work/wt/LS-102")
t1=$(date +%s)
wait "$holder_pid" 2>/dev/null
waited=$((t1 - t0))
if [ "$waited" -ge 2 ]; then echo "✓ ⑤ 強制共用時第二個等了約 ${waited}s（lock 被佔用）"; else echo "✗ ⑤ 應等待 ≥2s，實得 ${waited}s（lock 沒發揮作用？）" >&2; fail=1; fi
u5=$(id_of "$out5")
if [ "$u5" = SHARED-UDID ]; then echo "✓ ⑤ 等到 lock 後仍回共用第一台 UDID"; else echo "✗ ⑤ 應為 SHARED-UDID，實得 ${u5}" >&2; fail=1; fi

# ---- ⑥ CI 模式（CI=true）：不建、不 lock、直接回共用第一台，即使 lock 被佔住也不必等 ----
db6="$work/db6"; fresh_db "$db6"
rm -rf "$work/simlock"
bash "${root}/scripts/ops/simulator-lock.sh" --dir "$work/simlock" -- sleep 3 &
holder_pid=$!
sleep 0.5
t0=$(date +%s)
out6=$(STUB_DB="$db6" CI=true run_in "$work/wt/LS-101")
t1=$(date +%s)
kill "$holder_pid" 2>/dev/null; wait "$holder_pid" 2>/dev/null
waited=$((t1 - t0))
if [ "$waited" -le 1 ]; then echo "✓ ⑥ CI 模式立即回傳、不等共用 lock（${waited}s）"; else echo "✗ ⑥ CI 模式不該等 lock，實花 ${waited}s" >&2; fail=1; fi
u6=$(id_of "$out6")
[ "$u6" = SHARED-UDID ] && echo "✓ ⑥ CI 模式回共用第一台 UDID" || { echo "✗ ⑥ 應為 SHARED-UDID，實得 ${u6}" >&2; fail=1; }
if grep -qF 'LS-101' "$db6"; then echo "✗ ⑥ CI 模式不該建立專屬裝置" >&2; fail=1; else echo "✓ ⑥ CI 模式未建立專屬裝置"; fi

# ---- ⑦ 建立失敗（devicetype 查不到）→ 退回共用（lock 沒人占用時立即回）----
db7="$work/db7"; fresh_db "$db7"
mkdir -p "$work/wt/LS-103"
rm -rf "$work/simlock"
t0=$(date +%s)
out7=$(STUB_DB="$db7" STUB_NO_DEVICETYPE=1 run_in "$work/wt/LS-103")
t1=$(date +%s)
u7=$(id_of "$out7")
if [ "$u7" = SHARED-UDID ]; then echo "✓ ⑦ 建立失敗 → 退回共用第一台 UDID"; else echo "✗ ⑦ 應為 SHARED-UDID，實得 ${u7}" >&2; fail=1; fi
if [ $((t1 - t0)) -le 2 ]; then echo "✓ ⑦ lock 無人佔用時立即回（$((t1 - t0))s）"; else echo "✗ ⑦ 不該等待（花了 $((t1 - t0))s）" >&2; fail=1; fi

if [ "$fail" -eq 0 ]; then
  echo "✓ detect-simulator／simulator-lock 自測通過"
fi
exit "$fail"
