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
# 測試用 xcodebuild 假身（LS-83 R2 F1）：只吃一個「秒數」參數，睡那麼久後印一個可辨識的完成標記——
# 用來驗證 simulator-lock.sh 本身「同一把鎖下第二個呼叫要等第一個放掉」這個序列化行為（push-gate.sh
# 賴以生效的機制），不需要真的跑 xcodebuild。**這不驗證 push-gate.sh 是否真的把 xcodebuild test 接上
# 這條路徑**——push-gate.sh 拿掉 simulator-lock.sh 包裹、只留 stub 本身測綠一樣會全過（merge-reviewer
# R2 F3 實測）；接線本身由後面讀 push-gate.sh 原文的斷言（⑨）負責。
cat > "$work/bin/xcodebuild" <<'STUB'
#!/bin/bash
sleep "${1:-0}"
echo "xcodebuild-stub-done"
STUB
chmod +x "$work/bin/xcodebuild"
export PATH="$work/bin:$PATH"
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

# ---- ④ DETECT_SIMULATOR_SHARED=1：直接退回共用第一台，不查也不建專屬、也不再持鎖（LS-83 R2 F1：
#        R1 版本會在這裡短暫持鎖，但鎖了也沒用——早在 xcodebuild test 真正跑之前就放掉；序列化現在
#        整個移到 push-gate.sh 包 xcodebuild 那段。detect-simulator.sh 自己應該立刻回、不等任何東西，
#        即使湊巧有東西佔著一個同名的舊式鎖路徑也一樣，才不會憑空多一個等待點）----
db4="$work/db4"; fresh_db "$db4"
rm -rf "$work/stale-old-style-lock"
bash "${root}/scripts/ops/simulator-lock.sh" --dir "$work/stale-old-style-lock" -- sleep 5 &
holder_pid=$!
sleep 0.5
t0=$(date +%s)
out4=$(STUB_DB="$db4" DETECT_SIMULATOR_SHARED=1 run_in "$work/wt/LS-101")
t1=$(date +%s)
kill "$holder_pid" 2>/dev/null; wait "$holder_pid" 2>/dev/null
u4=$(id_of "$out4")
if [ "$u4" = SHARED-UDID ]; then echo "✓ ④ 強制共用 → 回共用第一台 UDID"; else echo "✗ ④ 應為 SHARED-UDID，實得 ${u4}" >&2; fail=1; fi
if grep -qF 'LS-101' "$db4"; then echo "✗ ④ 強制共用不該建立專屬裝置" >&2; fail=1; else echo "✓ ④ 強制共用未建立專屬裝置"; fi
if [ $((t1 - t0)) -le 1 ]; then echo "✓ ④ 立即回傳、detect-simulator.sh 自己不再持鎖（$((t1 - t0))s）"; else echo "✗ ④ 應立即回傳，實花 $((t1 - t0))s（detect-simulator.sh 是不是還在碰鎖？）" >&2; fail=1; fi

# ---- ⑤ push-gate 現在把「執行 xcodebuild test」整段包進 simulator-lock.sh、以 destination 的 UDID 為鍵
#        （LS-83 R2 F1）：這裡直接驗那個機制——同一把鎖下先背景佔住（模擬第一個 worktree 正在跑 xcodebuild
#        test），第二個 xcodebuild（stub）呼叫要等它放掉才跑，且確實執行到（有輸出），不是被跳過 ----
lock5="$work/pushgate-lock"
rm -rf "$lock5"
bash "${root}/scripts/ops/simulator-lock.sh" --dir "$lock5" -- xcodebuild 3 >/dev/null 2>&1 &
holder_pid=$!
sleep 0.5
t0=$(date +%s)
out5=$(bash "${root}/scripts/ops/simulator-lock.sh" --dir "$lock5" -- xcodebuild 0 2>/dev/null)
t1=$(date +%s)
wait "$holder_pid" 2>/dev/null
waited=$((t1 - t0))
if [ "$waited" -ge 2 ]; then echo "✓ ⑤ 同一 UDID 第二個 xcodebuild（stub）等了約 ${waited}s 才跑"; else echo "✗ ⑤ 應等待 ≥2s，實得 ${waited}s（push-gate 用的鎖沒發揮作用？）" >&2; fail=1; fi
has '⑤ 等到 lock 後第二個 xcodebuild 確實有執行（有輸出，不是被跳過）' "$out5" 'xcodebuild-stub-done'

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

# ---- ⑧ 專屬機排第一台時仍選到原廠機（LS-83 R2 F2）：db 裡先放一台名稱像專屬機的裝置（一樣含 "iPhone"
#        子字串），再放真正的原廠機——「清單第一台可用 iPhone」的偵測不能被同名污染挑錯，否則後續
#        devicetype／runtime 查找全部落空、shared_udid 也會指錯裝置 ----
db8="$work/db8"
printf 'LS-999-iPhoneAir\tFAKE-DEDICATED-UDID\t26.0\niPhone 17 Pro\tREAL-STOCK-UDID\t26.0\n' > "$db8"
mkdir -p "$work/wt/LS-104"
out8=$(STUB_DB="$db8" CI=true run_in "$work/wt/LS-104")
u8=$(id_of "$out8")
if [ "$u8" = REAL-STOCK-UDID ]; then echo "✓ ⑧ 專屬機排第一台時仍正確選到原廠機"; else echo "✗ ⑧ 應為 REAL-STOCK-UDID，實得 ${u8}（挑到專屬機了？）" >&2; fail=1; fi


# ---- ⑨ 接線斷言（比照 scripts/gates/push-ref-check.test.sh:73 的模式）：push-gate.sh 實際執行
#        xcodebuild test 那一行必須被 scripts/ops/simulator-lock.sh 包住，不能只是在旁邊的註解提到
#        （merge-reviewer R2 F3：R1 的修復本體——push-gate.sh 真的把 xcodebuild test 包進 lock——
#        沒有任何斷言釘住；reviewer 實測把 push-gate.sh 的 simulator-lock.sh 包裹拿掉，⑤ 照樣全綠，
#        因為 ⑤ 只驗 simulator-lock.sh 自己會不會排隊，從不讀 push-gate.sh 的原文）。跳過註解行
#        （`^[ \t]*#`）只認真正呼叫的程式碼行，避免「鎖被拿掉但緊鄰的註解還在」造成誤判為已接線 ----
gate="${root}/scripts/gates/push-gate.sh"
wired=$(awk '
  /^[ \t]*#/ { next }
  /scripts\/ops\/simulator-lock\.sh/ { saw_lock = NR; next }
  /xcodebuild test/ { if (saw_lock != "" && NR == saw_lock + 1) { print "yes"; exit } }
' "$gate")
if [ "$wired" = yes ]; then
  echo "✓ ⑨ push-gate.sh 的 xcodebuild test 確實被 scripts/ops/simulator-lock.sh 包住（不是只在註解提到）"
else
  echo "✗ ⑨ push-gate.sh 的 xcodebuild test 沒有被 scripts/ops/simulator-lock.sh 包住——接線斷了" >&2
  fail=1
fi

# ---- ⑩ demo-* 常駐機排第一台時仍選到原廠機（PR #164 R1 F2）：demo 環境的持久機（`demo-<機型無空白>`）
#        一樣含 "iPhone" 子字串、且不是本腳本管的「本 worktree 專屬機」——一旦它排在清單較前面（例如某
#        OS 分節唯一的候選就是它），原本會被誤判成「共用第一台」，連帶被 push-gate.sh 的模擬器用完必關
#        （LS-100）選中並關掉，而 demo 機理應豁免。db 裡先放 demo 機、再放原廠機，驗證挑選仍正確跳過 ----
db10="$work/db10"
printf 'demo-iPhoneAir\tFAKE-DEMO-UDID\t26.0\niPhone 17 Pro\tREAL-STOCK-UDID2\t26.0\n' > "$db10"
mkdir -p "$work/wt/LS-105"
out10=$(STUB_DB="$db10" CI=true run_in "$work/wt/LS-105")
u10=$(id_of "$out10")
if [ "$u10" = REAL-STOCK-UDID2 ]; then echo "✓ ⑩ demo-* 常駐機排第一台時仍正確選到原廠機"; else echo "✗ ⑩ 應為 REAL-STOCK-UDID2，實得 ${u10}（挑到 demo 機了？）" >&2; fail=1; fi

if [ "$fail" -eq 0 ]; then
  echo "✓ detect-simulator／simulator-lock 自測通過"
fi
exit "$fail"
