#!/bin/bash
# stale-xcodebuild-check.sh 的自測（LS-236）。CI `rules` job 跑。
# stub `pgrep`（印 $STUB_PGREP_OUT 檔案內容，忽略實際 pattern——測試自己控制要不要有「殘留」）／
# `ps`（依 $STUB_PS_DB，一行一筆 `pid\tetime\tcommand`，對 `-p <pid>` 印出 `ps -o pid=,etime=,command=`
# 格式的一行）——不碰本機真正在跑的行程。
# 「前饋必有反饋」對這支腳本本身也適用：若偵測拿掉、exit code 退化、逃生口失效，這裡會紅。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/scripts/gates/stale-xcodebuild-check.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bin="${work}/bin"
mkdir -p "$bin"

# ---- stub pgrep：印 $STUB_PGREP_OUT 檔案內容（每行一個 pid），沒有該檔或為空即印空（模擬無殘留）----
export STUB_PGREP_OUT="${work}/pgrep.out"
: > "$STUB_PGREP_OUT"
cat > "${bin}/pgrep" <<'STUB'
#!/bin/bash
[ -s "${STUB_PGREP_OUT:?}" ] && cat "${STUB_PGREP_OUT}"
exit 0
STUB
chmod +x "${bin}/pgrep"

# ---- stub ps：$STUB_PS_DB 一行一筆 `pid\tetime\tcommand`；`-p <pid>` 命中才印一行（無 header，貼近
#      `ps -o pid=,etime=,command=` 的輸出形狀：前導空白＋pid＋空白＋etime＋空白＋command）----
export STUB_PS_DB="${work}/ps.db"
: > "$STUB_PS_DB"
cat > "${bin}/ps" <<'STUB'
#!/bin/bash
target=
prev=
for a in "$@"; do
  if [ "$prev" = "-p" ]; then target=$a; fi
  prev=$a
done
[ -n "$target" ] || exit 1
db="${STUB_PS_DB:?}"
[ -f "$db" ] || exit 1
while IFS=$'\t' read -r pid etime cmd || [ -n "$pid" ]; do
  [ -n "$pid" ] || continue
  if [ "$pid" = "$target" ]; then
    printf '%5s %s %s\n' "$pid" "$etime" "$cmd"
    exit 0
  fi
done < "$db"
exit 1
STUB
chmod +x "${bin}/ps"

export PATH="${bin}:${PATH}"
unset PUSH_GATE_ALLOW_STALE_XCODEBUILD

set_pgrep() { printf '%s\n' "$@" > "$STUB_PGREP_OUT"; }
clear_pgrep() { : > "$STUB_PGREP_OUT"; }
set_ps() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$STUB_PS_DB"; }
clear_ps() { : > "$STUB_PS_DB"; }

UDID=AAAAAAAA-1111-2222-3333-444444444444

has() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✓ $1"; else echo "✗ ${1}（輸出應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✗ ${1}（輸出不應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; else echo "✓ $1"; fi; }

# ---- ① 無殘留 → exit 0、無任何輸出 ----
clear_pgrep; clear_ps
out1=$(bash "$check" "$UDID" 2>&1); rc1=$?
if [ "$rc1" -eq 0 ] && [ -z "$out1" ]; then
  echo "✓ ① 無殘留 → exit 0、無輸出"
else
  echo "✗ ① 無殘留應 exit 0 且無輸出（實得 exit ${rc1}）" >&2; printf '%s\n' "$out1" | sed 's/^/    /' >&2; fail=1
fi

# ---- ② 有殘留（一個 pid）→ exit 2、印 pid／etime／命令前 80 字，且不自動 kill（不呼叫 kill）----
clear_pgrep; clear_ps
LONGCMD="xcodebuild test -scheme LittleSprout -destination platform=iOS Simulator,id=${UDID} -only-testing:LittleSproutTests -parallel-testing-enabled NO -quiet -extra-padding-to-make-this-line-exceed-eighty-characters-for-sure"
set_pgrep 4242
set_ps 4242 01:23:45 "$LONGCMD"
out2=$(bash "$check" "$UDID" 2>&1); rc2=$?
if [ "$rc2" -eq 2 ]; then echo "✓ ② 有殘留 → exit 2"; else echo "✗ ② 應 exit 2（實得 ${rc2}）" >&2; printf '%s\n' "$out2" | sed 's/^/    /' >&2; fail=1; fi
has '② 印出殘留 xcodebuild 標頭' "$out2" '⚠ 殘留 xcodebuild'
has '② 印出 pid' "$out2" 'pid=4242'
has '② 印出 etime' "$out2" 'etime=01:23:45'
has '② 印出命令前 80 字（截斷）' "$out2" "$(printf '%s' "$LONGCMD" | cut -c1-80)"
hasnt '② 命令超過 80 字的尾巴不應出現（證明真的有截斷，不是整行都印）' "$out2" 'eighty-characters-for-sure'
has '② 印出不自動 kill 的提示（含 kill <pid> 手動指引）' "$out2" 'kill <pid> 再重跑'
has '② 印出逃生口名稱' "$out2" 'PUSH_GATE_ALLOW_STALE_XCODEBUILD=1'

# ---- ③ 有殘留（兩個 pid）→ 兩筆都印 ----
clear_pgrep; clear_ps
set_pgrep 111 222
set_ps 111 00:01:00 "xcodebuild test -destination platform=iOS Simulator,id=${UDID}"
set_ps 222 00:02:00 "xcodebuild build -destination platform=iOS Simulator,id=${UDID}"
out3=$(bash "$check" "$UDID" 2>&1); rc3=$?
[ "$rc3" -eq 2 ] && echo "✓ ③ 兩個殘留 pid → exit 2" || { echo "✗ ③ 應 exit 2（實得 ${rc3}）" >&2; fail=1; }
has '③ 印出第一個 pid' "$out3" 'pid=111'
has '③ 印出第二個 pid' "$out3" 'pid=222'

# ---- ④ 逃生口 PUSH_GATE_ALLOW_STALE_XCODEBUILD=1：有殘留仍 exit 0，印略過訊息 ----
clear_pgrep; clear_ps
set_pgrep 4242
set_ps 4242 01:23:45 "xcodebuild test -destination platform=iOS Simulator,id=${UDID}"
out4=$(PUSH_GATE_ALLOW_STALE_XCODEBUILD=1 bash "$check" "$UDID" 2>&1); rc4=$?
[ "$rc4" -eq 0 ] && echo "✓ ④ 逃生口生效 → exit 0" || { echo "✗ ④ 應 exit 0（實得 ${rc4}）" >&2; printf '%s\n' "$out4" | sed 's/^/    /' >&2; fail=1; }
has '④ 印出逃生口生效訊息' "$out4" 'PUSH_GATE_ALLOW_STALE_XCODEBUILD=1，略過'
hasnt '④ 不印殘留警告（逃生口跳過了整個檢查）' "$out4" '⚠ 殘留 xcodebuild'

# ---- ⑤ 用法錯誤：缺 UDID 參數 → exit 2 ----
out5=$(bash "$check" 2>&1); rc5=$?
[ "$rc5" -eq 2 ] && echo "✓ ⑤ 缺 UDID 參數 → exit 2" || { echo "✗ ⑤ 應 exit 2（實得 ${rc5}）" >&2; fail=1; }
has '⑤ 印出用法' "$out5" '用法'

# ---- ⑥ 不同 UDID 的殘留不誤判：pgrep 樣式命中另一顆 UDID 時，本腳本仍照樣印（因為呼叫端已經把
#        正確的 UDID 傳進來、pgrep 本身在真環境會用這顆 UDID 過濾）——這裡改用 stub 驗證「傳什麼 UDID
#        字面、輸出裡就該看得到那個字面」，避免把不相干的別台裝置也算進來 ----
clear_pgrep; clear_ps
OTHER_UDID=BBBBBBBB-1111-2222-3333-444444444444
set_pgrep 999
set_ps 999 00:00:30 "xcodebuild test -destination platform=iOS Simulator,id=${OTHER_UDID}"
out6=$(bash "$check" "$OTHER_UDID" 2>&1); rc6=$?
[ "$rc6" -eq 2 ] && echo "✓ ⑥ 對另一顆 UDID 一樣能偵測到殘留" || { echo "✗ ⑥ 應 exit 2（實得 ${rc6}）" >&2; fail=1; }
has '⑥ 訊息含目標 UDID' "$out6" "${OTHER_UDID}"

# ---- ⑦ 有殘留但帶的鎖目錄目前有效持有中（holder pid 存活）→ 視為合法排隊／執行中的另一個呼叫，
#        放行不擋（LS-236 R1：兩個 worktree 併發退回共用 UDID、simulator-lock.sh 自然序列化的常見情境
#        ——push-gate.test.sh ⑧ 用真正的 detect-simulator.sh／push-gate.sh 重現過這個假陽性）----
clear_pgrep; clear_ps
lockdir7="${work}/lock7"
mkdir -p "$lockdir7"
sleep 30 & holder7_pid=$!
disown
printf 'pid=%s\nstarted=%s\n' "$holder7_pid" "$(date +%s)" > "${lockdir7}/holder"
set_pgrep 5555
set_ps 5555 00:00:10 "xcodebuild test -destination platform=iOS Simulator,id=${UDID}"
out7=$(bash "$check" "$UDID" "$lockdir7" 2>&1); rc7=$?
kill "$holder7_pid" 2>/dev/null
if [ "$rc7" -eq 0 ] && [ -z "$out7" ]; then
  echo "✓ ⑦ 鎖有效持有中 → 視為合法、exit 0、不印警告"
else
  echo "✗ ⑦ 鎖有效持有中應 exit 0 且無輸出（實得 exit ${rc7}）" >&2; printf '%s\n' "$out7" | sed 's/^/    /' >&2; fail=1
fi

# ---- ⑧ 有殘留、有帶鎖目錄，但 holder 已死 → 仍視為殘留，照樣拒跑（鎖失效不代表行程無害）----
clear_pgrep; clear_ps
lockdir8="${work}/lock8"
mkdir -p "$lockdir8"
dead_pid=$(( $$ + 90000 ))   # 極不可能存在的 pid，模擬「持有者已死」
while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
printf 'pid=%s\nstarted=%s\n' "$dead_pid" "$(date +%s)" > "${lockdir8}/holder"
set_pgrep 6666
set_ps 6666 00:00:10 "xcodebuild test -destination platform=iOS Simulator,id=${UDID}"
out8=$(bash "$check" "$UDID" "$lockdir8" 2>&1); rc8=$?
[ "$rc8" -eq 2 ] && echo "✓ ⑧ 鎖的持有者已死 → 仍視為殘留、exit 2" || { echo "✗ ⑧ 應 exit 2（實得 ${rc8}）" >&2; printf '%s\n' "$out8" | sed 's/^/    /' >&2; fail=1; }
has '⑧ 印出殘留警告' "$out8" '⚠ 殘留 xcodebuild'

# ---- ⑨ 有殘留、帶的鎖目錄根本不存在（未傳、或路徑沒有 holder 檔）→ 照舊視為殘留（② 的無鎖路徑對照組，
#        改用明確不存在的路徑呼叫，確認「查不到鎖」與「沒傳鎖」走的是同一條防呆路徑）----
clear_pgrep; clear_ps
set_pgrep 7777
set_ps 7777 00:00:10 "xcodebuild test -destination platform=iOS Simulator,id=${UDID}"
out9=$(bash "$check" "$UDID" "${work}/no-such-lock-dir" 2>&1); rc9=$?
[ "$rc9" -eq 2 ] && echo "✓ ⑨ 鎖目錄不存在 → 仍視為殘留、exit 2" || { echo "✗ ⑨ 應 exit 2（實得 ${rc9}）" >&2; fail=1; }

# ==== ⑩ mutation：拿掉「鎖有效持有中則放行」判斷（改成恆假）→ ⑦ 的綠樣本必須變紅 ====
mut_lock="${work}/stale-xcodebuild-check.no-lock-skip.sh"
sed 's/if \[ -n "\$holder_pid" \] \&\& kill -0 "\$holder_pid" 2>\/dev\/null; then/if false; then/' "$check" > "$mut_lock"
if grep -qF 'if false; then' "$mut_lock"; then
  echo "✓ ⑩ mutate：確認已把「鎖有效持有中」判斷改成恆假"
else
  echo "✗ ⑩ mutate：找不到鎖持有判斷行，負控本身無效" >&2; fail=1
fi
clear_pgrep; clear_ps
mkdir -p "$lockdir7"
sleep 30 & holder7b_pid=$!
disown
printf 'pid=%s\nstarted=%s\n' "$holder7b_pid" "$(date +%s)" > "${lockdir7}/holder"
set_pgrep 5555
set_ps 5555 00:00:10 "xcodebuild test -destination platform=iOS Simulator,id=${UDID}"
outm10=$(bash "$mut_lock" "$UDID" "$lockdir7" 2>&1); rcm10=$?
kill "$holder7b_pid" 2>/dev/null
if [ "$rcm10" -eq 2 ]; then
  echo "✓ ⑩ mutant（拿掉鎖持有判斷）：⑦的綠樣本改判成 exit 2——證明鎖持有判斷是這裡在放行"
else
  echo "✗ ⑩ mutant 未如預期翻轉（實得 exit ${rcm10}）" >&2; printf '%s\n' "$outm10" | sed 's/^/    /' >&2; fail=1
fi

# ==== ⑪ mutation：拿掉 exit 2（改成 exit 0）→ ② 的紅樣本必須變綠 ====
mut="${work}/stale-xcodebuild-check.no-exit2.sh"
sed 's/^exit 2$/exit 0/' "$check" > "$mut"
if grep -qx 'exit 0' "$mut" && ! grep -qx 'exit 2' "$mut"; then
  echo "✓ ⑪ mutate：確認已把偵測到殘留時的 exit 2 換成 exit 0"
else
  echo "✗ ⑪ mutate：找不到唯一的 exit 2 行，負控本身無效" >&2; fail=1
fi
clear_pgrep; clear_ps
set_pgrep 4242
set_ps 4242 01:23:45 "xcodebuild test -destination platform=iOS Simulator,id=${UDID}"
outm=$(bash "$mut" "$UDID" 2>&1); rcm=$?
if [ "$rcm" -eq 0 ]; then
  echo "✓ ⑪ mutant（拿掉 exit 2）：②的紅樣本改判成 exit 0——證明 exit 2 是這裡在擋"
else
  echo "✗ ⑪ mutant 未如預期翻轉（實得 exit ${rcm}）" >&2; printf '%s\n' "$outm" | sed 's/^/    /' >&2; fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ stale-xcodebuild-check 自測通過"
fi
exit "$fail"
