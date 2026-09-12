#!/bin/bash
# stale-xcodebuild-check.sh 的自測（LS-236；R2 補 merge-review F1／F4）。CI `rules` job 跑。
# stub `pgrep`（印 $STUB_PGREP_OUT 檔案內容，忽略實際 pattern——測試自己控制要不要有「殘留」）／
# `ps`（依 $STUB_PS_DB，一行一筆 `pid\tetime\tcommand\tppid`，對 `-p <pid>` 依旗標形狀回兩種輸出：
# `-o pid=,etime=,command=` 印一行摘要，`-o ppid=` 印該 pid 的父行程 pid，供 F4 的父子鏈核對用）——
# 不碰本機真正在跑的行程；⑫ 額外用**真的系統 pgrep／ps**（不 stub）驗證 pattern 本身的自我誤判回歸。
# 「前饋必有反饋」對這支腳本本身也適用：若偵測拿掉、exit code 退化、逃生口失效、鎖持有放行核對候選
# 是否為其子孫的判斷被拿掉，這裡會紅。
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

# ---- stub ps：$STUB_PS_DB 一行一筆 `pid\tetime\tcommand\tppid`；`-p <pid>` 依旗標形狀回兩種輸出——
#      `-o pid=,etime=,command=`（無 header，貼近真 ps 形狀：前導空白＋pid＋空白＋etime＋空白＋command）
#      或 `-o ppid=`（只印該 pid 的父行程 pid，供 F4 的 is_holder_descendant() 父子鏈核對用）----
export STUB_PS_DB="${work}/ps.db"
: > "$STUB_PS_DB"
cat > "${bin}/ps" <<'STUB'
#!/bin/bash
db="${STUB_PS_DB:?}"
[ -f "$db" ] || exit 1
if [ "$1" = "-o" ] && [ "$2" = "ppid=" ] && [ "$3" = "-p" ]; then
  target=$4
  while IFS=$'\t' read -r pid etime cmd ppid || [ -n "$pid" ]; do
    [ -n "$pid" ] || continue
    if [ "$pid" = "$target" ]; then
      printf '%s\n' "${ppid:-0}"
      exit 0
    fi
  done < "$db"
  exit 1
fi
target=
prev=
for a in "$@"; do
  if [ "$prev" = "-p" ]; then target=$a; fi
  prev=$a
done
[ -n "$target" ] || exit 1
while IFS=$'\t' read -r pid etime cmd ppid || [ -n "$pid" ]; do
  [ -n "$pid" ] || continue
  if [ "$pid" = "$target" ]; then
    printf '%5s %s %s\n' "$pid" "$etime" "$cmd"
    exit 0
  fi
done < "$db"
exit 1
STUB
chmod +x "${bin}/ps"

REAL_PATH="$PATH"
export PATH="${bin}:${PATH}"
unset PUSH_GATE_ALLOW_STALE_XCODEBUILD

set_pgrep() { printf '%s\n' "$@" > "$STUB_PGREP_OUT"; }
clear_pgrep() { : > "$STUB_PGREP_OUT"; }
# set_ps <pid> <etime> <cmd> [<ppid>]：ppid 選填，供 F4 父子鏈核對用（不需要時留空即可，不影響既有樣本）。
set_ps() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "$STUB_PS_DB"; }
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

# ---- ⑦ 有殘留但帶的鎖目錄目前有效持有中（holder pid 存活）**且候選是 holder 的子行程**→ 視為合法
#        排隊／執行中的另一個呼叫，放行不擋（LS-236 R1：兩個 worktree 併發退回共用 UDID、
#        simulator-lock.sh 自然序列化的常見情境——push-gate.test.sh ⑧ 用真正的 detect-simulator.sh／
#        push-gate.sh 重現過這個假陽性；R2 merge-review F4：候選的 ppid 明確設成 holder pid，模擬
#        simulator-lock.sh 直接把 xcodebuild 當自己的子行程執行的真實情境，而不是只要 holder 活著就
#        整批放行）----
clear_pgrep; clear_ps
lockdir7="${work}/lock7"
mkdir -p "$lockdir7"
sleep 30 & holder7_pid=$!
disown
printf 'pid=%s\nstarted=%s\n' "$holder7_pid" "$(date +%s)" > "${lockdir7}/holder"
set_pgrep 5555
set_ps 5555 00:00:10 "xcodebuild test -destination platform=iOS Simulator,id=${UDID}" "$holder7_pid"
out7=$(bash "$check" "$UDID" "$lockdir7" 2>&1); rc7=$?
kill "$holder7_pid" 2>/dev/null
if [ "$rc7" -eq 0 ] && [ -z "$out7" ]; then
  echo "✓ ⑦ 鎖有效持有中＋候選是 holder 子行程 → 視為合法、exit 0、不印警告"
else
  echo "✗ ⑦ 鎖有效持有中應 exit 0 且無輸出（實得 exit ${rc7}）" >&2; printf '%s\n' "$out7" | sed 's/^/    /' >&2; fail=1
fi

# ---- ⑦a（F4）鎖有效持有中，但候選是 holder 的「孫行程」（多層父子鏈，經一層中繼行程）→ 仍應視為合法
#        （驗證 is_holder_descendant() 真的往上追多層，不是只比對直接 ppid）----
clear_pgrep; clear_ps
sleep 30 & holder7a_pid=$!
disown
printf 'pid=%s\nstarted=%s\n' "$holder7a_pid" "$(date +%s)" > "${lockdir7}/holder"
set_pgrep 5556
set_ps 5556 00:00:10 "xcodebuild test -destination platform=iOS Simulator,id=${UDID}" 9001
set_ps 9001 00:00:12 "some-intermediate-wrapper" "$holder7a_pid"
out7a=$(bash "$check" "$UDID" "$lockdir7" 2>&1); rc7a=$?
kill "$holder7a_pid" 2>/dev/null
if [ "$rc7a" -eq 0 ] && [ -z "$out7a" ]; then
  echo "✓ ⑦a 候選是 holder 的孫行程（經一層中繼）→ 仍視為合法、exit 0"
else
  echo "✗ ⑦a 候選是 holder 孫行程應 exit 0（實得 exit ${rc7a}）" >&2; printf '%s\n' "$out7a" | sed 's/^/    /' >&2; fail=1
fi

# ---- ⑦b（F4，核心負樣本）鎖有效持有中，但候選跟這把鎖的 holder 完全無關（ppid 是別的、不相干的
#        pid）→ 仍當殘留，exit 2（LS-236 R2 merge-review F4 的具體重現：A 合法持鎖跑 xcodebuild 時，
#        若剛好還有一個不受任何鎖保護的殘留 xcodebuild 也在同一顆共用 UDID 上跑，舊版「holder 活著
#        就整批放行」會連這個殘留也放過）----
clear_pgrep; clear_ps
sleep 30 & holder7b_pid=$!
disown
printf 'pid=%s\nstarted=%s\n' "$holder7b_pid" "$(date +%s)" > "${lockdir7}/holder"
unrelated_ppid=1
set_pgrep 5557
set_ps 5557 00:05:00 "xcodebuild test -destination platform=iOS Simulator,id=${UDID}" "$unrelated_ppid"
out7b=$(bash "$check" "$UDID" "$lockdir7" 2>&1); rc7b=$?
kill "$holder7b_pid" 2>/dev/null
if [ "$rc7b" -eq 2 ]; then
  echo "✓ ⑦b 鎖有效持有中但候選跟 holder 無關 → 仍視為殘留、exit 2"
else
  echo "✗ ⑦b 候選跟 holder 無關應 exit 2（實得 exit ${rc7b}）" >&2; printf '%s\n' "$out7b" | sed 's/^/    /' >&2; fail=1
fi
has '⑦b 印出殘留警告' "$out7b" '⚠ 殘留 xcodebuild'
has '⑦b 印出該無關候選的 pid' "$out7b" 'pid=5557'

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
sed 's/if \[ -n "\$h" \] \&\& kill -0 "\$h" 2>\/dev\/null; then/if false; then/' "$check" > "$mut_lock"
if grep -qF 'if false; then' "$mut_lock"; then
  echo "✓ ⑩ mutate：確認已把「鎖有效持有中」判斷改成恆假"
else
  echo "✗ ⑩ mutate：找不到鎖持有判斷行，負控本身無效" >&2; fail=1
fi
clear_pgrep; clear_ps
mkdir -p "$lockdir7"
sleep 30 & holder10_pid=$!
disown
printf 'pid=%s\nstarted=%s\n' "$holder10_pid" "$(date +%s)" > "${lockdir7}/holder"
set_pgrep 5555
set_ps 5555 00:00:10 "xcodebuild test -destination platform=iOS Simulator,id=${UDID}" "$holder10_pid"
outm10=$(bash "$mut_lock" "$UDID" "$lockdir7" 2>&1); rcm10=$?
kill "$holder10_pid" 2>/dev/null
if [ "$rcm10" -eq 2 ]; then
  echo "✓ ⑩ mutant（拿掉鎖持有判斷）：⑦的綠樣本改判成 exit 2——證明鎖持有判斷是這裡在放行"
else
  echo "✗ ⑩ mutant 未如預期翻轉（實得 exit ${rcm10}）" >&2; printf '%s\n' "$outm10" | sed 's/^/    /' >&2; fail=1
fi

# ==== ⑩a（F4）mutation：把 is_holder_descendant() 改成恆真（不管候選跟 holder 有沒有關係都放行）→
#      ⑦b 的紅樣本（候選跟 holder 無關）必須變綠 ====
mut_desc="${work}/stale-xcodebuild-check.always-descendant.sh"
sed 's/^is_holder_descendant() {$/is_holder_descendant() { return 0; #/' "$check" > "$mut_desc"
if grep -qF 'is_holder_descendant() { return 0; #' "$mut_desc"; then
  echo "✓ ⑩a mutate：確認已把 is_holder_descendant() 改成恆真"
else
  echo "✗ ⑩a mutate：找不到函式定義行，負控本身無效" >&2; fail=1
fi
clear_pgrep; clear_ps
sleep 30 & holder10a_pid=$!
disown
printf 'pid=%s\nstarted=%s\n' "$holder10a_pid" "$(date +%s)" > "${lockdir7}/holder"
set_pgrep 5557
set_ps 5557 00:05:00 "xcodebuild test -destination platform=iOS Simulator,id=${UDID}" 1
outm10a=$(bash "$mut_desc" "$UDID" "$lockdir7" 2>&1); rcm10a=$?
kill "$holder10a_pid" 2>/dev/null
if [ "$rcm10a" -eq 0 ]; then
  echo "✓ ⑩a mutant（恆真的 is_holder_descendant）：⑦b 的紅樣本改判成 exit 0——證明父子鏈核對是這裡在擋跟 holder 無關的候選"
else
  echo "✗ ⑩a mutant 未如預期翻轉（實得 exit ${rcm10a}）" >&2; printf '%s\n' "$outm10a" | sed 's/^/    /' >&2; fail=1
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

# ---- ⑫（merge-review R1 F1）pattern 自匹配回歸：用**真的系統 pgrep／ps**（不 stub，$REAL_PATH）驗證
#      `xcodebuild .*<UDID>` 這條 pattern 本身不會被「檔名含 xcodebuild 子字串的無關行程」誤判成殘留。
#      背景起一個真行程，執行檔路徑刻意取名含 `xcodebuild`（模擬本腳本自己或任何同類工具的檔名），
#      命令列上再帶一個跟目標 UDID 相同的字面（模擬「檔名含 xcodebuild、argv 剛好也提到這顆 UDID」的
#      巧合）——若 pattern 退化回舊版 `xcodebuild.*<UDID>`（`xcodebuild` 後不要求空白），這個真行程會
#      被誤判成殘留；修正後的 `xcodebuild .*<UDID>` 因為「xcodebuild」後面接的是 `-marker.sh`（沒有
#      空白）而不會誤判。----
real_udid="CCCCCCCC-1111-2222-3333-444444444444"
marker_dir="${work}/real-tools"
mkdir -p "$marker_dir"
marker_script="${marker_dir}/xcodebuild-marker.sh"
cat > "$marker_script" <<'MARKER'
#!/bin/bash
sleep 60
MARKER
chmod +x "$marker_script"
env PATH="$REAL_PATH" bash "$marker_script" "$real_udid" &
marker_pid=$!
disown
# 給行程表一點時間讓真的 pgrep／ps 看得到（背景行程剛 fork 出來偶爾還沒進系統表）
for _ in 1 2 3 4 5 6 7 8 9 10; do
  env PATH="$REAL_PATH" pgrep -f "xcodebuild-marker" >/dev/null 2>&1 && break
  sleep 0.2
done
out12=$(env PATH="$REAL_PATH" bash "$check" "$real_udid" 2>&1); rc12=$?
kill "$marker_pid" 2>/dev/null
if [ "$rc12" -eq 0 ] && [ -z "$out12" ]; then
  echo "✓ ⑫ 真 pgrep／ps：檔名含 xcodebuild 子字串的無關真行程不誤判為殘留（exit 0、無輸出）"
else
  echo "✗ ⑫ 應 exit 0 且無輸出（實得 exit ${rc12}）——pattern 可能又退化成自我誤判" >&2; printf '%s\n' "$out12" | sed 's/^/    /' >&2; fail=1
fi

# ==== ⑬（merge-review R1 F1）mutation：把 pattern 退回舊版寬鬆寫法（拿掉 `xcodebuild` 後的空白要求）
#      → ⑫ 的綠樣本必須變紅（真的被那個無關真行程誤判成殘留）====
mut_pattern="${work}/stale-xcodebuild-check.loose-pattern.sh"
sed 's/xcodebuild \.\*\${udid}/xcodebuild.*${udid}/' "$check" > "$mut_pattern"
if grep -qF 'pgrep -f "xcodebuild.*${udid}"' "$mut_pattern"; then
  echo "✓ ⑬ mutate：確認已把 pattern 退回舊版寬鬆寫法（拿掉空白要求）"
else
  echo "✗ ⑬ mutate：pattern 替換失敗，負控本身無效" >&2; fail=1
fi
env PATH="$REAL_PATH" bash "$marker_script" "$real_udid" &
marker_pid13=$!
disown
for _ in 1 2 3 4 5 6 7 8 9 10; do
  env PATH="$REAL_PATH" pgrep -f "xcodebuild-marker" >/dev/null 2>&1 && break
  sleep 0.2
done
outm13=$(env PATH="$REAL_PATH" bash "$mut_pattern" "$real_udid" 2>&1); rcm13=$?
kill "$marker_pid13" 2>/dev/null
if [ "$rcm13" -eq 2 ]; then
  echo "✓ ⑬ mutant（pattern 退回舊版）：⑫的綠樣本改判成 exit 2——證明 xcodebuild 後的空白要求是這裡在防自我誤判"
else
  echo "✗ ⑬ mutant 未如預期翻轉（實得 exit ${rcm13}）——pattern 修正可能已經零覆蓋" >&2; printf '%s\n' "$outm13" | sed 's/^/    /' >&2; fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ stale-xcodebuild-check 自測通過"
fi
exit "$fail"
