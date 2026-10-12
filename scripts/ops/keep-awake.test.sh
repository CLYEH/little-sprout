#!/bin/bash
# keep-awake.sh 的自測（LS-512）。全程指到暫存 domain／暫存狀態目錄／假 caffeinate／假 ioreg，
# 不動真的 com.apple.screensaver、不碰真的 caffeinate 行程、不寫 ~/.little-sprout。
# 驗：start 記原值＋寫 0＋起 hold／caffeinate＋status 0；重複 start 冪等（不重複起行程、原值不被 0 蓋掉）；
# 接手手動狀態（idleTime 已 0、無 json、已有 caffeinate → 原值記 300、不重複起 caffeinate）；status 三種 exit 2；
# restore 還原；租約過期 → hold 自動 restore；每次 start 續租（超過單一租約長度仍活著）。
# mutation：hold 永不判過期 → 租約過期案紅；start 把 0 當原值 → 接手案紅。
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ops/keep-awake.sh"
fail=0
# 非 macOS（CI ubuntu runner 沒有 defaults）：keep-awake.sh 本身就印略過 exit 0，無從驗起，SKIP 並說明
if ! command -v defaults >/dev/null 2>&1; then echo "⚠ 無 defaults（非 macOS）：keep-awake 自測 SKIP"; exit 0; fi
work="$(mktemp -d)"
cleanup() {
  # 把測試期間可能殘留的 hold／假 caffeinate 清掉（樣式含本次暫存目錄，不會誤中真行程）
  pkill -f "$work" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

ok()  { echo "✓ $1"; }
bad() { echo "✗ $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "${1}（期望「${3}」，實得「${2}」）"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "${1}（輸出應含「${3}」）" "$2"; fi; }

# 假 caffeinate：-w <pid> → 該 pid 活著就活著（同真 caffeinate -w 語意）；否則睡 60 秒
cat > "$work/fake-caffeinate" <<'EOF'
#!/bin/bash
w=
while [ $# -gt 0 ]; do case "$1" in -w) w=$2; shift 2 ;; *) shift ;; esac; done
if [ -n "$w" ]; then while kill -0 "$w" 2>/dev/null; do sleep 1; done; else sleep 60; fi
EOF
chmod +x "$work/fake-caffeinate"
# 假 ioreg：存在 $work/locked 檔就回 IOConsoleLocked=true；-c IOHIDSystem 回 5 秒閒置
cat > "$work/fake-ioreg" <<EOF
#!/bin/bash
case "\$*" in
  *IOHIDSystem*) echo '    | "HIDIdleTime" = 5000000000' ;;
  *) if [ -e "$work/locked" ]; then printf '<key>IOConsoleLocked</key>\n<true/>\n'; else printf '<key>IOConsoleLocked</key>\n<false/>\n'; fi ;;
esac
EOF
chmod +x "$work/fake-ioreg"

new_env() {  # new_env <n>：每個案例一組獨立的 domain／狀態目錄，互不污染
  export KEEP_AWAKE_STATE_DIR="$work/state$1" KEEP_AWAKE_DEFAULTS_DOMAIN="$work/dom$1"
  export KEEP_AWAKE_CAFFEINATE_BIN="$work/fake-caffeinate" KEEP_AWAKE_CAFFEINATE_PATTERN="$work/fake-caffeinate -d -i -s"
  export KEEP_AWAKE_IOREG_BIN="$work/fake-ioreg" KEEP_AWAKE_POLL_SEC=1
  unset KEEP_AWAKE_LEASE_FILE
  rm -f "$work/locked"
}
idle() { defaults read "$KEEP_AWAKE_DEFAULTS_DOMAIN" idleTime 2>/dev/null; }
ncaff() { pgrep -f "$work/fake-caffeinate -d -i -s" 2>/dev/null | wc -l | tr -d ' '; }
hold_pid() { sed -n 's/.*"hold_pid":\([0-9]*\).*/\1/p' "$KEEP_AWAKE_STATE_DIR/keep-awake.json"; }
orig_idle() { sed -n 's/.*"original_idle_time":\([0-9]*\).*/\1/p' "$KEEP_AWAKE_STATE_DIR/keep-awake.json"; }
wait_for() {  # wait_for <秒> <命令…>：命令成功就回 0，逾時回 1
  local n=$1; shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 1; n=$((n - 1)); done; return 1
}
idle_is() { [ "$(idle)" = "$1" ]; }
gone() { ! kill -0 "$1" 2>/dev/null; }
no_caff() { [ "$(ncaff)" = 0 ]; }

# ① start：記原值 300、寫 0、起 hold＋caffeinate、status exit 0
new_env 1
defaults write "$KEEP_AWAKE_DEFAULTS_DOMAIN" idleTime -int 300
out=$(bash "$script" start 2>&1); rc=$?
eq '① start exit 0' "$rc" 0
has '① start 印狀態行' "$out" 'keep-awake：start ok（原 idleTime=300'
eq '① idleTime 已寫 0' "$(idle)" 0
eq '① json 記原值 300' "$(orig_idle)" 300
[ -f "$KEEP_AWAKE_STATE_DIR/keep-awake.lease" ] && ok '① 租約檔已建' || bad '① 租約檔不存在'
eq '① 租約檔內容＝預設 3600' "$(tr -d '[:space:]' < "$KEEP_AWAKE_STATE_DIR/keep-awake.lease")" 3600
h1=$(hold_pid); kill -0 "$h1" 2>/dev/null && ok '① hold 行程在' || bad '① hold 行程不在'
eq '① 只有一支 caffeinate' "$(ncaff)" 1
st=$(bash "$script" status 2>&1); rc=$?
eq '① status exit 0' "$rc" 0
has '① status 帶 idleTime=0／locked=false／HIDIdleTime=5s' "$st" 'idleTime=0 '
has '① status locked=false' "$st" 'locked=false'
has '① status HIDIdleTime=5s' "$st" 'HIDIdleTime=5s'
if printf '%s' "$st" | grep -qE 'lease剩餘=3[0-9]+s( |$)'; then ok '① status 租約剩餘為「<數字>s」'; else bad '① status 租約剩餘格式不對' "$st"; fi
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then bad "${1}（輸出不應含「${3}」）" "$2"; else ok "$1"; fi; }
hasnt '① status 租約剩餘不重複印秒數' "$st" 's3'

# ② 冪等：再 start → 同一支 hold、原值仍 300（不被 0 蓋掉）、仍只有一支 caffeinate
out=$(bash "$script" start --lease 1800 2>&1); rc=$?
eq '② 第二次 start exit 0' "$rc" 0
eq '② hold pid 不變（沒重複起）' "$(hold_pid)" "$h1"
eq '② 原值仍 300' "$(orig_idle)" 300
eq '② 仍只有一支 caffeinate' "$(ncaff)" 1
eq '② 租約檔內容更新為 --lease 1800' "$(tr -d '[:space:]' < "$KEEP_AWAKE_STATE_DIR/keep-awake.lease")" 1800

# ③ restore：idleTime 回 300、hold／caffeinate 結束、json／租約刪除；再 restore 冪等
out=$(bash "$script" restore 2>&1); rc=$?
eq '③ restore exit 0' "$rc" 0
eq '③ idleTime 回原值 300' "$(idle)" 300
wait_for 5 gone "$h1" && ok '③ hold 已結束' || bad '③ hold 仍在'
wait_for 5 no_caff && ok '③ caffeinate 已結束' || bad '③ caffeinate 仍在'
[ ! -e "$KEEP_AWAKE_STATE_DIR/keep-awake.json" ] && [ ! -e "$KEEP_AWAKE_STATE_DIR/keep-awake.lease" ] && ok '③ json／租約已刪' || bad '③ json／租約仍在'
bash "$script" status >/dev/null 2>&1; rc=$?
eq '③ restore 後 status exit 2（idleTime≠0、無 caffeinate）' "$rc" 2
bash "$script" restore >/dev/null 2>&1; rc=$?
eq '③ 再 restore 冪等 exit 0' "$rc" 0
eq '③ 再 restore 不動 idleTime' "$(idle)" 300

# ④ 接手手動狀態：idleTime 已 0、沒有 json、已有人起的 caffeinate → 原值記 300（不是 0）、不重複起 caffeinate
new_env 4
defaults write "$KEEP_AWAKE_DEFAULTS_DOMAIN" idleTime -int 0
"$KEEP_AWAKE_CAFFEINATE_BIN" -d -i -s -t 43200 </dev/null >/dev/null 2>&1 &
manual=$!
sleep 0.5
bash "$script" start >/dev/null 2>&1; rc=$?
eq '④ 接手 start exit 0' "$rc" 0
eq '④ 原值記 300（不把 0 當原值）' "$(orig_idle)" 300
eq '④ 沿用既有 caffeinate、不重複起' "$(ncaff)" 1
bash "$script" restore >/dev/null 2>&1
eq '④ restore 還原成 300' "$(idle)" 300
kill "$manual" 2>/dev/null

# ⑤ status 三種 exit 2：idleTime≠0／無 caffeinate／locked=true
new_env 5
defaults write "$KEEP_AWAKE_DEFAULTS_DOMAIN" idleTime -int 300
bash "$script" start >/dev/null 2>&1
bash "$script" status >/dev/null 2>&1; eq '⑤ 正常 exit 0' "$?" 0
touch "$work/locked"
st=$(bash "$script" status 2>&1); rc=$?
eq '⑤ locked=true → exit 2' "$rc" 2
has '⑤ locked=true 印在狀態行' "$st" 'locked=true'
rm -f "$work/locked"
defaults write "$KEEP_AWAKE_DEFAULTS_DOMAIN" idleTime -int 300
bash "$script" status >/dev/null 2>&1; eq '⑤ idleTime≠0 → exit 2' "$?" 2
defaults write "$KEEP_AWAKE_DEFAULTS_DOMAIN" idleTime -int 0
pkill -f "$work/fake-caffeinate -d -i -s" 2>/dev/null; sleep 0.3
# hold 的輪詢會把 caffeinate 補回來——先殺 hold 再殺 caffeinate 才驗得到「無 caffeinate」
kill "$(hold_pid)" 2>/dev/null; sleep 0.3; pkill -f "$work/fake-caffeinate -d -i -s" 2>/dev/null; sleep 0.3
st=$(bash "$script" status 2>&1); rc=$?
eq '⑤ 無 caffeinate → exit 2' "$rc" 2
has '⑤ 無 caffeinate 印「無」' "$st" 'caffeinate=無'
bash "$script" restore >/dev/null 2>&1

# ⑥ 每次 start 續租：lease 3 秒、每 2 秒續一次，跑 7 秒（> 單一租約）hold 仍活著、idleTime 仍 0
new_env 6
defaults write "$KEEP_AWAKE_DEFAULTS_DOMAIN" idleTime -int 300
bash "$script" start --lease 3 >/dev/null 2>&1; h6=$(hold_pid)
for _ in 1 2 3; do sleep 2; bash "$script" start --lease 3 >/dev/null 2>&1; done
kill -0 "$h6" 2>/dev/null && ok '⑥ 持續續租 → 超過單一租約長度 hold 仍活著' || bad '⑥ 續租了 hold 卻死了'
eq '⑥ 續租期間 idleTime 仍 0' "$(idle)" 0

# ⑦ 租約過期：停止續租 → hold 在 lease＋一個輪詢週期內自動 restore（idleTime 回 300、hold／caffeinate 結束、檔案清掉）
wait_for 8 idle_is 300 && ok '⑦ 租約過期 → hold 自動還原 idleTime=300' || bad "⑦ 租約過期後 idleTime 仍為「$(idle)」"
wait_for 5 gone "$h6" && ok '⑦ hold 已自行結束' || bad '⑦ hold 仍在'
wait_for 5 no_caff && ok '⑦ caffeinate 已結束' || bad '⑦ caffeinate 仍在'
[ ! -e "$KEEP_AWAKE_STATE_DIR/keep-awake.json" ] && ok '⑦ json 已刪' || bad '⑦ json 仍在'

# ⑧ 參數錯誤
new_env 8
bash "$script" start --lease abc >/dev/null 2>&1; eq '⑧ --lease 非整數 exit 2' "$?" 2
bash "$script" bogus >/dev/null 2>&1; eq '⑧ 未知子命令 exit 2' "$?" 2

# ⑨ mutation 1：hold 永不判過期（`-lt 0` → `-lt -99999`）→ ⑦ 的租約過期案轉紅（idleTime 停在 0）
mut1="$work/keep-awake-mut1.sh"
sed 's/\[ "\$rem" -lt 0 \]/[ "$rem" -lt -99999 ]/' "$script" > "$mut1"
if ! diff -q "$script" "$mut1" >/dev/null 2>&1; then
  new_env 9
  defaults write "$KEEP_AWAKE_DEFAULTS_DOMAIN" idleTime -int 300
  bash "$mut1" start --lease 2 >/dev/null 2>&1; h9=$(hold_pid)
  sleep 6
  eq '⑨ mutant：hold 不判過期 → 租約過期後 idleTime 仍為 0（⑦ 的還原確由過期判斷造成）' "$(idle)" 0
  bash "$mut1" restore >/dev/null 2>&1
else
  bad '⑨ mutation 1 的 sed 未命中（負控本身無效）'
fi
# ⑩ mutation 2：start 把 0 當原值（無條件取目前值）→ ④ 接手案轉紅（原值記成 0）
mut2="$work/keep-awake-mut2.sh"
sed 's/^  if \[ -n "\$orig" \] && \[ "\${cur:-x}" = 0 \]; then :$/  if false; then :/; s/^  elif \[ -n "\$cur" \] && \[ "\$cur" != 0 \]; then orig=\$cur$/  elif [ -n "$cur" ]; then orig=$cur/' "$script" > "$mut2"
if ! diff -q "$script" "$mut2" >/dev/null 2>&1; then
  new_env 10
  defaults write "$KEEP_AWAKE_DEFAULTS_DOMAIN" idleTime -int 0
  bash "$mut2" start >/dev/null 2>&1
  eq '⑩ mutant：把 0 當原值 → 接手時原值被記成 0（④ 的「記 300」確由 0 判斷造成）' "$(orig_idle)" 0
  # mutant 的 restore 會寫回 0 到暫存 domain，無妨；清行程
  bash "$mut2" restore >/dev/null 2>&1
else
  bad '⑩ mutation 2 的 sed 未命中（負控本身無效）'
fi

if [ "$fail" -eq 0 ]; then echo "✓ keep-awake 自測通過"; fi
exit "$fail"
