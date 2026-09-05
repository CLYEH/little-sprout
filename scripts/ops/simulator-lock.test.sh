#!/bin/bash
# simulator-lock.sh 的自測（LS-83；LS-207 c18ef27f 補 --udid 字級／外觀自動調整；R2 修 merge-review R1
# fd783f6c F4／F5）。CI Ops 腳本自測 step 跑它。
# 互斥／逾時／死鎖回收／signal 處理的核心邏輯已透過 push-gate.test.sh 把真正的 simulator-lock.sh 複製進合成 repo
# 反覆驗證（該檔案是 push-gate.sh 唯一的呼叫端）；這裡只補 LS-207 新增的 --udid 行為——push-gate.sh 目前不傳
# --udid，所以這支腳本的既有呼叫端完全不受影響（udid 變數預設空、下面的邏輯全部門檻在 `[ -n "$udid" ]`）。
# 「前饋必有反饋」：若 --udid 給了卻不調整字級／外觀、SIMLOCK_KEEP_UI=1 沒有真的跳過、查詢失敗或 unknown／
# unsupported 仍當原值存起來、兩個 key 因為對方失敗被一起放棄、或復原失敗被靜默吞掉，這裡會紅。
# R2 F5：設定目標值改成 large（對齊 tap-target-check.sh 宣稱的量測基準；系統預設也是 large，R1 誤設成 medium）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lock_sh="${root}/scripts/ops/simulator-lock.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export SIMULATOR_LOCK_POLL=0.2

has()   { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✓ $1"; else echo "✗ ${1}（輸出應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✗ ${1}（輸出不應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; else echo "✓ $1"; fi; }
rc_is() { if [ "$3" -eq "$2" ]; then echo "✓ $1"; else echo "✗ ${1}（期望 exit ${2}，實得 ${3}）" >&2; printf '%s\n' "$4" | sed 's/^/    /' >&2; fail=1; fi; }

# ---- 假 xcrun：只認 `xcrun simctl ui <udid> <key> [<value>]`；把每次呼叫記一行到 $XCRUN_LOG（含 query／set 區分）；
#      query（無 value）依 XCRUN_MODE 決定回什麼、是否失敗；set（有 value）依 XCRUN_MODE 決定成功與否。
#      XCRUN_MODE 可用 `<content_size 模式>:<appearance 模式>` 兩段式（用 : 分隔）分別控制兩個 key，模式沒有
#      冒號就兩個 key 共用同一個模式（既有樣本相容）。
bin="$work/bin"; mkdir -p "$bin"
cat > "$bin/xcrun" <<'EOS'
#!/bin/bash
log="${XCRUN_LOG:?}"
raw_mode="${XCRUN_MODE:-ok}"
case "$raw_mode" in
  *:*) mode_content=${raw_mode%%:*}; mode_appearance=${raw_mode#*:} ;;
  *) mode_content=$raw_mode; mode_appearance=$raw_mode ;;
esac
if [ "$1" = simctl ] && [ "$2" = ui ]; then
  udid=$3; key=$4; val=${5:-}
  case "$key" in
    content_size) mode=$mode_content ;;
    appearance) mode=$mode_appearance ;;
    *) mode=$raw_mode ;;
  esac
  if [ -n "$val" ]; then
    printf 'set %s %s %s\n' "$udid" "$key" "$val" >> "$log"
    [ "$mode" = setfail ] && exit 1
    exit 0
  else
    printf 'query %s %s\n' "$udid" "$key" >> "$log"
    case "$mode" in
      queryfail) exit 1 ;;
      unknown) echo "unknown"; exit 0 ;;
      unsupported) echo "unsupported"; exit 0 ;;
    esac
    case "$key" in
      content_size) echo "extraLarge" ;;
      appearance) echo "dark" ;;
    esac
    exit 0
  fi
fi
echo "stub xcrun：不認得的呼叫 $*" >&2
exit 1
EOS
chmod +x "$bin/xcrun"
export PATH="$bin:$PATH"
export XCRUN_LOG="$work/xcrun.log"

run() {   # run <lock dir> <XCRUN_MODE> <額外參數…> -- <命令…>
  local dir=$1 mode=$2; shift 2
  : > "$XCRUN_LOG"
  XCRUN_MODE="$mode" bash "$lock_sh" --dir "$dir" "$@" 2>&1
}

# ---- ① --udid 給了、查詢與設定都成功 → 取鎖後查原值、設 large/light、跑命令、釋放前復原原值 ----
out1="$(run "$work/l1" ok --udid UDID-1 -- echo ran)"; rc=$?
rc_is '① exit 0' 0 "$rc" "$out1"
has   '① 命令有執行' "$out1" 'ran'
has   '① 印已調整（含 UDID）' "$out1" '已將 UDID-1 字級／外觀改為 content_size=large appearance=light（釋放時復原）'
has   '① 印已復原 content_size（含原值）' "$out1" '已復原 UDID-1 content_size=extraLarge'
has   '① 印已復原 appearance（含原值）' "$out1" '已復原 UDID-1 appearance=dark'
log1="$(cat "$XCRUN_LOG")"
want1=$'query UDID-1 content_size\nset UDID-1 content_size large\nquery UDID-1 appearance\nset UDID-1 appearance light\nset UDID-1 content_size extraLarge\nset UDID-1 appearance dark'
if [ "$log1" = "$want1" ]; then echo "✓ ① xcrun 呼叫順序：查詢＋設 large→查詢＋設 light→（命令）→各自復原原值"; else echo "✗ ① xcrun 呼叫順序不對" >&2; echo "    實得：" >&2; printf '%s\n' "$log1" | sed 's/^/      /' >&2; fail=1; fi

# ---- ② 沒有 --udid（既有呼叫端 push-gate.sh 現況）→ 完全不呼叫 xcrun ui、行為不變 ----
out2="$(run "$work/l2" ok -- echo ran2)"; rc=$?
rc_is '② 無 --udid → exit 0' 0 "$rc" "$out2"
has   '② 命令有執行' "$out2" 'ran2'
if [ -s "$XCRUN_LOG" ]; then echo "✗ ② 無 --udid 不應呼叫 xcrun" >&2; cat "$XCRUN_LOG" >&2; fail=1; else echo "✓ ② 無 --udid 不呼叫 xcrun（既有呼叫端零影響）"; fi

# ---- ③ SIMLOCK_KEEP_UI=1 → 即使給了 --udid 也整段跳過（含查詢） ----
: > "$XCRUN_LOG"
out3="$(SIMLOCK_KEEP_UI=1 XCRUN_MODE=ok bash "$lock_sh" --dir "$work/l3" --udid UDID-3 -- echo ran3 2>&1)"; rc=$?
rc_is '③ SIMLOCK_KEEP_UI=1 → exit 0' 0 "$rc" "$out3"
has   '③ 命令有執行' "$out3" 'ran3'
hasnt '③ 不印已調整' "$out3" '已將'
if [ -s "$XCRUN_LOG" ]; then echo "✗ ③ SIMLOCK_KEEP_UI=1 不應呼叫 xcrun（連查詢都不該）" >&2; cat "$XCRUN_LOG" >&2; fail=1; else echo "✓ ③ SIMLOCK_KEEP_UI=1 整段跳過、不呼叫 xcrun"; fi

# ---- ④ 查詢失敗（兩個 key 都查不到）→ 都不設定、都不復原、各印一次警告、命令照跑（不擋鎖） ----
out4="$(run "$work/l4" queryfail --udid UDID-4 -- echo ran4)"; rc=$?
rc_is '④ 查詢失敗仍 exit 0（不擋命令）' 0 "$rc" "$out4"
has   '④ 命令有執行' "$out4" 'ran4'
has   '④ 印讀不到 content_size 的警告' "$out4" '讀不到 UDID-4 目前 content_size'
has   '④ 印讀不到 appearance 的警告' "$out4" '讀不到 UDID-4 目前 appearance'
hasnt '④ 不印已調整' "$out4" '已將'
hasnt '④ 不印已復原' "$out4" '已復原'
log4="$(cat "$XCRUN_LOG")"
if printf '%s' "$log4" | grep -qF 'set UDID-4'; then echo "✗ ④ 查詢失敗卻仍呼叫了 set（應該完全不設定）" >&2; printf '%s\n' "$log4" >&2; fail=1; else echo "✓ ④ 查詢失敗不呼叫任何 set"; fi

# ---- ④-b LS-207 R2（F4）：查詢回應合法但是 unknown／unsupported（simctl ui help 明列的合法值，不是查詢失敗）
#        → 視同查不到，不當原值存起來、不設定、不復原（否則復原時會對模擬器下不存在的值） ----
out4b="$(run "$work/l4b" unknown:unsupported --udid UDID-4B -- echo ran4b)"; rc=$?
rc_is '④-b 回應 unknown／unsupported 仍 exit 0' 0 "$rc" "$out4b"
has   '④-b 命令有執行' "$out4b" 'ran4b'
has   '④-b content_size=unknown 視同查不到、印警告' "$out4b" '讀不到 UDID-4B 目前 content_size'
has   '④-b appearance=unsupported 視同查不到、印警告' "$out4b" '讀不到 UDID-4B 目前 appearance'
hasnt '④-b 不印已調整' "$out4b" '已將'
log4b="$(cat "$XCRUN_LOG")"
if printf '%s' "$log4b" | grep -qF 'set UDID-4B'; then echo "✗ ④-b unknown／unsupported 卻仍呼叫了 set" >&2; printf '%s\n' "$log4b" >&2; fail=1; else echo "✓ ④-b unknown／unsupported 不呼叫任何 set"; fi

# ---- ⑤ 兩個 key 都設定失敗 → 各印一次警告、命令照跑、不呼叫復原（沒有真的改過任何一個） ----
out5="$(run "$work/l5" setfail --udid UDID-5 -- echo ran5)"; rc=$?
rc_is '⑤ 設定失敗仍 exit 0（不擋命令）' 0 "$rc" "$out5"
has   '⑤ 命令有執行' "$out5" 'ran5'
has   '⑤ 印 content_size 設定失敗警告' "$out5" '設定 UDID-5 content_size=large 失敗'
has   '⑤ 印 appearance 設定失敗警告' "$out5" '設定 UDID-5 appearance=light 失敗'
hasnt '⑤ 不印已復原（沒有真的改過，沒有東西要復原）' "$out5" '已復原'
log5="$(cat "$XCRUN_LOG")"
if [ "$(printf '%s\n' "$log5" | grep -cF 'set UDID-5')" -eq 2 ]; then echo "✓ ⑤ 兩個 key 都各自嘗試設定過一次（不是短路成一個），沒有復原呼叫"; else echo "✗ ⑤ set 呼叫次數不對（應為 2）" >&2; printf '%s\n' "$log5" >&2; fail=1; fi

# ---- ⑤-b LS-207 R2（F4 失敗情境 A）：content_size 設定成功、appearance 設定失敗 → 只復原 content_size，
#        appearance 不受影響（不因對方失敗被一起放棄）；R1 用 && 短路，這種部分套用會讓 content_size 永遠復原不到 ----
out5b="$(run "$work/l5b" ok:setfail --udid UDID-5B -- echo ran5b)"; rc=$?
rc_is '⑤-b 部分失敗仍 exit 0' 0 "$rc" "$out5b"
has   '⑤-b 印 content_size 已調整' "$out5b" 'content_size=large'
has   '⑤-b 印 appearance 設定失敗警告' "$out5b" '設定 UDID-5B appearance=light 失敗'
has   '⑤-b content_size 有被復原' "$out5b" '已復原 UDID-5B content_size=extraLarge'
hasnt '⑤-b appearance 沒有被復原（沒有真的改過）' "$out5b" '已復原 UDID-5B appearance'
log5b="$(cat "$XCRUN_LOG")"
if printf '%s' "$log5b" | grep -qF 'set UDID-5B appearance dark'; then echo "✗ ⑤-b 不該對 appearance 呼叫復原 set" >&2; printf '%s\n' "$log5b" >&2; fail=1; else echo "✓ ⑤-b 沒有對 appearance 呼叫復原"; fi
if printf '%s' "$log5b" | grep -qF 'set UDID-5B content_size extraLarge'; then echo "✓ ⑤-b 有對 content_size 呼叫復原（原值 extraLarge）"; else echo "✗ ⑤-b 沒有對 content_size 呼叫復原" >&2; printf '%s\n' "$log5b" >&2; fail=1; fi

# ---- ⑤-c 鏡像案：content_size 設定失敗、appearance 設定成功 → 只復原 appearance ----
out5c="$(run "$work/l5c" setfail:ok --udid UDID-5C -- echo ran5c)"; rc=$?
rc_is '⑤-c 部分失敗仍 exit 0' 0 "$rc" "$out5c"
has   '⑤-c 印 content_size 設定失敗警告' "$out5c" '設定 UDID-5C content_size=large 失敗'
has   '⑤-c 印 appearance 已調整' "$out5c" 'appearance=light'
hasnt '⑤-c content_size 沒有被復原' "$out5c" '已復原 UDID-5C content_size'
has   '⑤-c appearance 有被復原' "$out5c" '已復原 UDID-5C appearance=dark'

# ---- ⑤-d LS-207 R2（F4）：復原呼叫本身失敗 → 大聲印 ⚠ 並點名 UDID／key／原值，不再被 >/dev/null 2>&1 吞掉 ----
#      XCRUN_MODE 的 restorefail：查詢與初次設定都成功（讓 ui_changed 為真），第二次對同一個 key 下同一個原值
#      的「set」（即復原呼叫）才失敗——用一個計數檔區分「初次設定」與「復原」兩次 set。
cat > "$bin/xcrun" <<'EOS'
#!/bin/bash
log="${XCRUN_LOG:?}"
mode="${XCRUN_MODE:-ok}"
if [ "$1" = simctl ] && [ "$2" = ui ]; then
  udid=$3; key=$4; val=${5:-}
  if [ -n "$val" ]; then
    printf 'set %s %s %s\n' "$udid" "$key" "$val" >> "$log"
    if [ "$mode" = restorefail ]; then
      case "$val" in large|light) exit 0 ;; *) exit 1 ;; esac   # large/light＝初次設定（成功）；其餘（原值）＝復原（失敗）
    fi
    exit 0
  else
    printf 'query %s %s\n' "$udid" "$key" >> "$log"
    case "$key" in
      content_size) echo "extraLarge" ;;
      appearance) echo "dark" ;;
    esac
    exit 0
  fi
fi
echo "stub xcrun：不認得的呼叫 $*" >&2
exit 1
EOS
chmod +x "$bin/xcrun"
out5d="$(run "$work/l5d" restorefail --udid UDID-5D -- echo ran5d)"; rc=$?
rc_is '⑤-d 復原失敗仍 exit 0（不擋命令，命令早就跑完了）' 0 "$rc" "$out5d"
has   '⑤-d 命令有執行' "$out5d" 'ran5d'
has   '⑤-d 復原 content_size 失敗時大聲印 ⚠ 並點名 UDID／原值' "$out5d" '復原 UDID-5D content_size=extraLarge 失敗'
has   '⑤-d 復原 appearance 失敗時大聲印 ⚠ 並點名 UDID／原值' "$out5d" '復原 UDID-5D appearance=dark 失敗'
hasnt '⑤-d 復原失敗不得謊稱已復原' "$out5d" '已復原 UDID-5D'

# ---- ⑥ 命令本身失敗（exit 非 0）→ 仍要復原（EXIT trap 涵蓋非 0 退出） ----
cat > "$bin/xcrun" <<'EOS'
#!/bin/bash
log="${XCRUN_LOG:?}"
if [ "$1" = simctl ] && [ "$2" = ui ]; then
  udid=$3; key=$4; val=${5:-}
  if [ -n "$val" ]; then printf 'set %s %s %s\n' "$udid" "$key" "$val" >> "$log"; exit 0
  else printf 'query %s %s\n' "$udid" "$key" >> "$log"; case "$key" in content_size) echo extraLarge ;; appearance) echo dark ;; esac; exit 0; fi
fi
exit 1
EOS
chmod +x "$bin/xcrun"
out6="$(run "$work/l6" ok --udid UDID-6 -- sh -c 'exit 7')"; rc=$?
rc_is '⑥ 命令 exit 7 → 包裝也 exit 7' 7 "$rc" "$out6"
has   '⑥ 命令失敗仍印已復原 content_size' "$out6" '已復原 UDID-6 content_size'
has   '⑥ 命令失敗仍印已復原 appearance' "$out6" '已復原 UDID-6 appearance'

# ---- 命令型負控：拿掉 apply_sim_ui／restore_sim_ui 呼叫點 → ① 的 xcrun 呼叫應歸零 ----
mut="$work/simulator-lock.no-ui.sh"
awk '!/^apply_sim_ui$/ && !/^release\(\) \{ restore_sim_ui;/ { print; next } /^release\(\) \{ restore_sim_ui;/ { print "release() { if read_holder && [ \"$h_pid\" = \"$$\" ]; then rm -rf \"$lock\"; fi; }" }' "$lock_sh" > "$mut"
if grep -q '^apply_sim_ui$' "$mut" || grep -q 'restore_sim_ui;' "$mut"; then
  echo "✗ mutant 仍含 apply_sim_ui／restore_sim_ui 呼叫（awk 拿掉失敗，負控本身無效）" >&2; fail=1
else
  echo "✓ mutant 已拿掉 apply_sim_ui／restore_sim_ui 呼叫點"
fi
: > "$XCRUN_LOG"
outm="$(XCRUN_MODE=ok bash "$mut" --dir "$work/lm" --udid UDID-M -- echo ranm 2>&1)"; rcm=$?
if [ "$rcm" -eq 0 ] && [ ! -s "$XCRUN_LOG" ]; then
  echo "✓ mutant：拿掉呼叫點後給 --udid 也不再碰 xcrun（證明 ① 的行為確實來自 apply_sim_ui／restore_sim_ui）"
else
  echo "✗ mutant 應 exit 0 且不呼叫 xcrun（實得 exit ${rcm}）" >&2; cat "$XCRUN_LOG" >&2; fail=1
fi

# ---- mutation：把兩個 key 的獨立處理退回 R1 的 && 短路 → ⑤-b（content_size 成功、appearance 失敗）應該
#        變成 content_size 也不被復原（負控證明「獨立記錄」確實是 ⑤-b 綠的原因）----
mut2="$work/simulator-lock.and-shortcircuit.sh"
python3 - "$lock_sh" "$mut2" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
old = '''apply_one_ui_key() {
  local key=$1 want=$2 orig
  orig=$(xcrun simctl ui "$udid" "$key" 2>/dev/null) || orig=
  case "$orig" in
    ''|unknown|unsupported)
      echo "⚠ simulator-lock：讀不到 ${udid} 目前 ${key}（查詢失敗或回應 unknown／unsupported）——不調整、不復原" >&2
      return 0 ;;
  esac
  if xcrun simctl ui "$udid" "$key" "$want" >/dev/null 2>&1; then
    case "$key" in
      content_size) ui_orig_content_size=$orig; ui_content_changed=1 ;;
      appearance) ui_orig_appearance=$orig; ui_appearance_changed=1 ;;
    esac
  else
    echo "⚠ simulator-lock：設定 ${udid} ${key}=${want} 失敗（xcrun simctl ui …）——不擋鎖，照跑命令" >&2
  fi
}
apply_sim_ui() {
  [ -n "$udid" ] || return 0
  [ "${SIMLOCK_KEEP_UI:-}" = 1 ] && return 0
  apply_one_ui_key content_size large
  apply_one_ui_key appearance light
  if [ "$ui_content_changed" -eq 1 ] || [ "$ui_appearance_changed" -eq 1 ]; then
    echo "→ simulator-lock：已將 ${udid} 字級／外觀改為$([ "$ui_content_changed" -eq 1 ] && printf ' content_size=large')$([ "$ui_appearance_changed" -eq 1 ] && printf ' appearance=light')（釋放時復原）" >&2
  fi
}'''
new = '''apply_sim_ui() {
  [ -n "$udid" ] || return 0
  [ "${SIMLOCK_KEEP_UI:-}" = 1 ] && return 0
  ui_orig_content_size=$(xcrun simctl ui "$udid" content_size 2>/dev/null) || ui_orig_content_size=
  ui_orig_appearance=$(xcrun simctl ui "$udid" appearance 2>/dev/null) || ui_orig_appearance=
  if [ -z "$ui_orig_content_size" ] || [ -z "$ui_orig_appearance" ]; then return 0; fi
  if xcrun simctl ui "$udid" content_size large >/dev/null 2>&1 && xcrun simctl ui "$udid" appearance light >/dev/null 2>&1; then
    ui_content_changed=1; ui_appearance_changed=1
  fi
}'''
assert old in src, "找不到 apply_one_ui_key／apply_sim_ui 區塊，mutation 樣板需同步"
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PY
cat > "$bin/xcrun" <<'EOS'
#!/bin/bash
log="${XCRUN_LOG:?}"
mode_content=ok; mode_appearance=setfail
if [ "$1" = simctl ] && [ "$2" = ui ]; then
  udid=$3; key=$4; val=${5:-}
  case "$key" in content_size) mode=$mode_content ;; appearance) mode=$mode_appearance ;; esac
  if [ -n "$val" ]; then
    printf 'set %s %s %s\n' "$udid" "$key" "$val" >> "$log"
    [ "$mode" = setfail ] && exit 1
    exit 0
  else
    printf 'query %s %s\n' "$udid" "$key" >> "$log"
    case "$key" in content_size) echo extraLarge ;; appearance) echo dark ;; esac
    exit 0
  fi
fi
exit 1
EOS
chmod +x "$bin/xcrun"
: > "$XCRUN_LOG"
out_mut2="$(XCRUN_MODE=x bash "$mut2" --dir "$work/lmut2" --udid UDID-MUT2 -- echo ranmut2 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out_mut2" | grep -qF '已復原 UDID-MUT2 content_size'; then
  echo "✓ mutant（&& 短路）：appearance 失敗連累 content_size 也不被復原（負控證明 ⑤-b 綠是因為兩個 key 真的獨立處理）"
else
  echo "✗ mutant（&& 短路）應該讓 content_size 也復原不到（負控本身可能無效）" >&2; printf '%s\n' "$out_mut2" | sed 's/^/    /' >&2; fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ simulator-lock 自測通過"
fi
exit "$fail"
