#!/bin/bash
# ci-wait.sh 的自測（LS-299）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對這支腳本也適用：若參數解析忘記檢查數量、完成判定看錯欄位、`--job` 誤看整個 run
# 的狀態、gh 連續失敗沒有在第 3 次退場、或拿掉逾時退出邏輯後陷入無窮迴圈——這裡會紅。
#
# PATH 前置一支假 `gh`：`run view <id> --json … --jobs` 依「這是第幾次呼叫」用 `$GH_RUN_JSON_SEQUENCE`
# （空白分隔的罐頭 JSON 檔案路徑清單）回對應一份，序列用完後停在最後一份（同 promote-follow.test.sh 既有
# 手法）；`$GH_FAIL_CALLS`（逗號分隔的呼叫序號清單）命中的那幾次呼叫直接 `exit 1`、不印任何 JSON，模擬
# `gh` 本身失敗（curl 逾時之類）。真正呼叫 gh 的其餘引數只記一筆 log，不驗。
# R2（merge-review R1 B1）另 PATH 前置一支假 `date`：只在設了 `$DATE_SEQUENCE` 且引數恰為 `+%s` 時接管
# （依呼叫次數回對應的模擬秒數，序列用完停在最後一份），其餘一律 passthrough 給真 `date`——ci-wait.sh
# 只在兩處呼叫 `date +%s`（`start_ts`／每輪迴圈開頭的逾時檢查），這讓我們能用極短的真實執行時間模擬
# 「跨好幾輪 gh 失敗、模擬時鐘卻已經走了很久」的節奏，不必真的等待整支腳本的 `--interval`／`--max-minutes`。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/ops/ci-wait.sh"
fail=0
n=0
ok() { echo "✓ $1"; n=$((n + 1)); }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP 22 組＋mutation（無 jq）：stub gh 需要 jq 跑 --json 表達式，ci-wait 自測整支未跑"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

bin="$work/bin"
mkdir -p "$bin" "$work/state" "$work/fixtures"

cat > "$bin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${GH_LOG:?}"
case "$1 $2" in
  "run view")
    cnt_file="${GH_STATE_DIR:?}/viewcount"
    n=0
    [ -f "$cnt_file" ] && n=$(cat "$cnt_file")
    n=$((n + 1))
    echo "$n" > "$cnt_file"
    case ",${GH_FAIL_CALLS:-}," in
      *",${n},"*) exit 1 ;;
    esac
    chosen=""
    i=0
    for f in ${GH_RUN_JSON_SEQUENCE:?}; do
      i=$((i + 1))
      chosen="$f"
      [ "$i" -ge "$n" ] && break
    done
    cat "$chosen"
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$bin/gh"

real_date=$(command -v date)
cat > "$bin/date" <<EOF
#!/bin/bash
if [ "\$1" = "+%s" ] && [ -n "\${DATE_SEQUENCE:-}" ]; then
  cnt_file="\${DATE_STATE_DIR:?}/datecount"
  n=0
  [ -f "\$cnt_file" ] && n=\$(cat "\$cnt_file")
  n=\$((n + 1))
  echo "\$n" > "\$cnt_file"
  chosen=""
  i=0
  for v in \${DATE_SEQUENCE}; do
    i=\$((i + 1))
    chosen="\$v"
    [ "\$i" -ge "\$n" ] && break
  done
  echo "\$chosen"
  exit 0
fi
exec "${real_date}" "\$@"
EOF
chmod +x "$bin/date"
export PATH="$bin:$PATH"
export GH_LOG="$work/gh.log" GH_STATE_DIR="$work/state" DATE_STATE_DIR="$work/state"

# expect_has <text> <substr> <label>：LS-301 起改用共用庫（scripts/gates/lib/selftest-helpers.sh）
# 的 expect_has（here-string 比對，避免 pipefail 下的 SIGPIPE 誤判，LS-270／LS-295）；語意不變——找到
# 即計入 ok()，找不到印 ✗＋原文並把本檔的 fail 旗標設 1（R2 merge-review R1 自我複查：舊版只回傳布林
# 值、呼叫端沒接判斷式，8 處斷言全是靜默無效的裝飾，改成這個版本才會真的讓測試紅）。本檔已有 fail=0
# 的旗標變數，這裡補一個同名的 fail() 函式（bash 函式與變數不同命名空間，`fail=1` 賦值與 `fail "msg"`
# 呼叫不衝突）讓共用庫的 expect_has 失敗時仍會設到這個旗標。
fail() { echo "✗ $1" >&2; fail=1; }
source "${root}/scripts/gates/lib/selftest-helpers.sh"
reset_all() {
  : > "$GH_LOG"; rm -rf "$GH_STATE_DIR"; mkdir -p "$GH_STATE_DIR"
  unset GH_FAIL_CALLS GH_RUN_JSON_SEQUENCE DATE_SEQUENCE
}
# fx <名稱> <JSON> → 落一個罐頭檔，印路徑
fx() { printf '%s' "$2" > "$work/fixtures/$1.json"; echo "$work/fixtures/$1.json"; }
viewcalls() { cat "${GH_STATE_DIR}/viewcount" 2>/dev/null || echo 0; }
datecalls() { cat "${DATE_STATE_DIR}/datecount" 2>/dev/null || echo 0; }

# ---- ① 缺參數 → exit 2、不呼叫 gh ----
reset_all
out="$(bash "$script" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && [ ! -s "$GH_LOG" ]; then
  ok "① 缺參數 → exit 2、不呼叫 gh"
else
  echo "✗ ① 缺參數應 exit 2 且不呼叫 gh（實得 exit ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi

# ---- ② run 完成 success → exit 0，印 conclusion=success ----
reset_all
s=$(fx s-success '{"status":"completed","conclusion":"success","jobs":[{"name":"rules","status":"completed","conclusion":"success","steps":[]},{"name":"lint","status":"completed","conclusion":"success","steps":[]}]}')
out="$(GH_RUN_JSON_SEQUENCE="$s" bash "$script" 2001 --interval 0 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "② run success → exit 0"; else echo "✗ ② run success 應 exit 0（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
expect_has "$out" 'conclusion=success' '② 印 conclusion=success'
expect_has "$out" 'job rules：success' '② 印各 job 結論'

# ---- ③ run 完成 failure → exit 1，印 conclusion=failure ----
reset_all
f=$(fx f-failure '{"status":"completed","conclusion":"failure","jobs":[{"name":"rules","status":"completed","conclusion":"failure","steps":[]}]}')
out="$(GH_RUN_JSON_SEQUENCE="$f" bash "$script" 2002 --interval 0 2>&1)"; rc=$?
if [ "$rc" -eq 1 ]; then ok "③ run failure → exit 1"; else echo "✗ ③ run failure 應 exit 1（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
expect_has "$out" 'conclusion=failure' '③ 印 conclusion=failure'

# ---- ④ 到 --max-minutes 仍在跑 → exit 3，印「仍在跑」與再跑指令 ----
reset_all
r=$(fx r-running '{"status":"in_progress","conclusion":null,"jobs":[{"name":"rules","status":"in_progress","conclusion":null,"steps":[]}]}')
out="$(GH_RUN_JSON_SEQUENCE="$r" bash "$script" 2003 --max-minutes 0 --interval 0 2>&1)"; rc=$?
if [ "$rc" -eq 3 ]; then ok "④ 到 max-minutes 仍在跑 → exit 3"; else echo "✗ ④ 應 exit 3（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
expect_has "$out" '仍在跑' '④ 印「仍在跑」'
expect_has "$out" 'bash scripts/ops/ci-wait.sh 2003' '④ 印再跑指令'

# ---- ⑤ --job 只看該 job：目標 job 已完成 success，其餘 job／整個 run 仍 in_progress → 仍應 exit 0 ----
reset_all
j=$(fx j-job-done '{"status":"in_progress","conclusion":null,"jobs":[{"name":"rules","status":"completed","conclusion":"success","steps":[]},{"name":"ci","status":"in_progress","conclusion":null,"steps":[]}]}')
out="$(GH_RUN_JSON_SEQUENCE="$j" bash "$script" 2004 --job rules --interval 0 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "⑤ --job 目標 job 已完成、其餘仍在跑 → exit 0（不受拖累）"; else echo "✗ ⑤ 應 exit 0（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
expect_has "$out" 'job「rules」conclusion=success' '⑤ 印目標 job 的結論'

# ---- ⑤b --job 指定不存在的 job 名 → 視為仍在跑，到 max-minutes exit 3（不誤判成完成）----
reset_all
out="$(GH_RUN_JSON_SEQUENCE="$j" bash "$script" 2005 --job no-such-job --max-minutes 0 --interval 0 2>&1)"; rc=$?
if [ "$rc" -eq 3 ]; then ok "⑤b --job 指定不存在的 job → 視為仍在跑 → exit 3"; else echo "✗ ⑤b 應 exit 3（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi

# ---- ⑥ gh 連續失敗 3 次 → exit 2 ----
reset_all
out="$(GH_FAIL_CALLS="1,2,3" GH_RUN_JSON_SEQUENCE="$s" bash "$script" 2006 --interval 0 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then ok "⑥ gh 連續失敗 3 次 → exit 2"; else echo "✗ ⑥ 應 exit 2（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
expect_has "$out" '連續失敗 3 次' '⑥ 印失敗訊息'

# ---- ⑦ gh 失敗兩次後第三次恢復 → 不誤判，照常判定完成（fail_streak 未跨過 3 就不該提早 exit 2）----
reset_all
out="$(GH_FAIL_CALLS="1,2" GH_RUN_JSON_SEQUENCE="$s" bash "$script" 2007 --interval 0 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "⑦ gh 失敗兩次後恢復 → 不誤判，照常 exit 0"; else echo "✗ ⑦ 應 exit 0（實得 ${rc}）——連續失敗計數可能沒有在成功時歸零" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi

# ---- ⑧ B1（merge-review R1，major，已修）：「失敗、失敗、成功」節奏——逾時檢查在每一輪迴圈最前面
#        都要先比對 elapsed，不論這一輪是要重試還是要查詢完成度；修前只有成功分支會檢查，連續失敗的
#        迭代完全跳過逾時檢查，elapsed 一路累積到下一次成功呼叫才重新比對，逾時退出點可能晚於
#        --max-minutes 好幾個 --interval（reviewer 實測 71s／60s 預算，超出 18%）。
#        用假 `date`（`$DATE_SEQUENCE`）把「模擬時鐘」與真實 sleep 脫鉤：budget＝1 分鐘（60s），
#        模擬時鐘每次 `date +%s` 呼叫走 25s——call#1＝start_ts=0；iter1 逾時檢查（call#2）＝25＜60→
#        呼叫 gh（第 1 次，GH_FAIL_CALLS 命中失敗）；iter2 逾時檢查（call#3）＝50＜60→呼叫 gh（第 2
#        次，失敗）；iter3 逾時檢查（call#4）＝75≥60→應立刻 exit 3，不再多打第 3 次 gh。----
reset_all
d8_r=$(fx r2-running '{"status":"in_progress","conclusion":null,"jobs":[{"name":"rules","status":"in_progress","conclusion":null,"steps":[]}]}')
out="$(GH_FAIL_CALLS="1,2" GH_RUN_JSON_SEQUENCE="$d8_r" DATE_SEQUENCE="0 25 50 75 100 125" bash "$script" 2008 --max-minutes 1 --interval 0 2>&1)"; rc=$?
if [ "$rc" -eq 3 ]; then ok "⑧ 失敗、失敗、逾時 → exit 3（失敗分支也先比對 elapsed，不多繞一輪）"; else echo "✗ ⑧ 應 exit 3（實得 ${rc}）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; fi
expect_has "$out" '已耗時 1 分 15 秒' '⑧ 印已耗時 1 分 15 秒（75s＝budget 60s＋恰好一輪的模擬時鐘步進，不是好幾輪）'
d8_calls=$(viewcalls)
if [ "$d8_calls" = 2 ]; then ok "⑧ gh 只被呼叫 2 次（逾時後沒有多打第 3 次，證明失敗分支確實先比對 elapsed 才決定要不要再呼叫 gh）"; else echo "✗ ⑧ gh 呼叫次數應為 2（實得 ${d8_calls}）——逾時後可能多打了一次 gh" >&2; fail=1; fi

# ---- ⑧ mutation：把逾時判斷式改成「只在 fail_streak 歸零（上一輪沒有失敗）時才生效」——重現修前的
#        缺陷形狀（失敗分支的迭代完全跳過逾時檢查的『後果』：即使已經逾時，只要還在連續失敗中就不退出）。
#        同一份「失敗、失敗、成功」節奏夾具下（第 3 次 gh 呼叫改為成功、回「仍在跑」，讓迴圈撐過修前
#        會漏檢的那兩輪失敗），mutant 應該撐到模擬時鐘 100s（1 分 40 秒）才退出——比原版的 75s 多墊了
#        整整一輪（多打了一次原本不該打的 gh call），證明這段判斷式就是 B1 修法的來源。----
anchor_b1='if [ "$elapsed" -ge "$max_seconds" ]; then'
mut_b1="$work/ci-wait-mutant-b1.sh"
if ! grep -qF "$anchor_b1" "$script"; then
  echo "✗ ⑧ mutation 錨點（逾時判斷式）不在 ci-wait.sh，mutation 測試無法成立：${anchor_b1}" >&2; fail=1
else
  sed "s/$(printf '%s' "$anchor_b1" | sed 's/[.[\*^$]/\\&/g')/if [ \"\$fail_streak\" -eq 0 ] \&\& [ \"\$elapsed\" -ge \"\$max_seconds\" ]; then/" "$script" > "$mut_b1"
  chmod +x "$mut_b1"
  if diff -q "$script" "$mut_b1" >/dev/null 2>&1; then
    echo "✗ ⑧ mutant 與原始檔完全相同（sed 未命中，mutation 測試本身無效）" >&2; fail=1
  else
    reset_all
    d8b_r=$(fx r2b-running '{"status":"in_progress","conclusion":null,"jobs":[{"name":"rules","status":"in_progress","conclusion":null,"steps":[]}]}')
    out="$(GH_FAIL_CALLS="1,2" GH_RUN_JSON_SEQUENCE="$d8b_r" DATE_SEQUENCE="0 25 50 75 100 125" bash "$mut_b1" 2009 --max-minutes 1 --interval 0 2>&1)"; rc=$?
    d8b_calls=$(viewcalls)
    if [ "$rc" -eq 3 ] && grep -qF '已耗時 1 分 40 秒' <<<"$out" && [ "$d8b_calls" = 3 ]; then
      ok "⑧ mutant：逾時判斷只在 fail_streak 歸零時才生效後，同一份夾具撐到 100s（1 分 40 秒、多打了第 3 次 gh）才退出——比原版多墊一輪，證明 B1 的修法（失敗分支也要先比對 elapsed）就是原版只墊 75s／2 次 gh 呼叫的原因"
    else
      echo "✗ ⑧ mutant 應在 elapsed=100（1 分 40 秒、gh 呼叫 3 次）才 exit 3（實得 exit ${rc}，gh 呼叫 ${d8b_calls} 次）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
    fi
  fi
fi

# ---- mutation：拿掉 ci-wait.sh 的 MUTATION-TIMEOUT 區塊（逾時退出邏輯）→「仍在跑」夾具陷入無窮迴圈 ----
# 先切出 mutant，斷言區塊真的被拿掉；再用「仍在跑」夾具＋--max-minutes 0 對照：原版立刻 exit 3，
# mutant 版本背景起跑＋watchdog（2 秒後 TERM）——若 mutant 仍然「正常印出仍在跑並退出」，代表 mutation
# 沒有真的改變行為（gate 沒有守住這段）；若 2 秒內沒有自行退出、被 watchdog 強制中止，且 gh 呼叫次數
# 遠大於 1（證明真的在忙碌輪詢、不是卡在別處），才算證明 MUTATION-TIMEOUT 區塊就是「仍在跑就退出」的來源。
mutant="$work/ci-wait-mutant.sh"
awk '/# MUTATION-TIMEOUT-START/{skip=1; next} /# MUTATION-TIMEOUT-END/{skip=0; next} !skip' "$script" > "$mutant"
chmod +x "$mutant"
if grep -q 'MUTATION-TIMEOUT-START' "$mutant"; then
  echo "✗ mutation：awk 沒有把 MUTATION-TIMEOUT 區塊拿掉（自測本身壞了）" >&2; fail=1
else
  ok "mutation 前置：mutant 已不含 MUTATION-TIMEOUT 區塊"
fi

reset_all
still=$(fx m-still '{"status":"in_progress","conclusion":null,"jobs":[{"name":"rules","status":"in_progress","conclusion":null,"steps":[]}]}')
out_orig="$(GH_RUN_JSON_SEQUENCE="$still" bash "$script" 9001 --max-minutes 0 --interval 0 2>&1)"; rc_orig=$?
if [ "$rc_orig" -eq 3 ]; then
  ok "mutation 前置：原版對「仍在跑」夾具＋--max-minutes 0 立刻 exit 3（夾具本身沒問題）"
else
  echo "✗ mutation 前置：原版應 exit 3（實得 ${rc_orig}）——夾具本身壞了，mutation 對照沒有意義" >&2
  printf '%s\n' "$out_orig" | sed 's/^/    /' >&2; fail=1
fi

reset_all
mutant_out="$work/mutant-out.txt"; : > "$mutant_out"
( GH_RUN_JSON_SEQUENCE="$still" bash "$mutant" 9002 --max-minutes 0 --interval 0 > "$mutant_out" 2>&1 ) &
mpid=$!
( sleep 2; kill -TERM "$mpid" 2>/dev/null ) &
wpid=$!
wait "$mpid" 2>/dev/null
mrc=$?
kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
calls=$(viewcalls)

if grep -q '仍在跑' "$mutant_out"; then
  echo "✗ mutation：拿掉 MUTATION-TIMEOUT 區塊後仍然正常印出「仍在跑」並退出——mutation 沒有改變行為，這條規則沒有守住逾時退出邏輯" >&2
  printf '%s\n' "$mutant_out" | sed 's/^/    /' >&2
  fail=1
elif [ "$calls" -lt 5 ]; then
  echo "✗ mutation：mutant 在 2 秒內只呼叫 gh ${calls} 次——沒有真的在忙碌輪詢，watchdog 對照不成立" >&2
  fail=1
else
  ok "mutation：拿掉逾時退出後，「仍在跑」夾具陷入無窮迴圈（2 秒內呼叫 gh ${calls} 次、未自行退出，被 watchdog 強制中止 rc=${mrc}）——證明 MUTATION-TIMEOUT 區塊就是「仍在跑就退出」行為的來源"
fi

if [ "$fail" -eq 0 ]; then
  echo "✓ ci-wait.test.sh 全部通過（${n} 組＋mutation）"
else
  echo "✗ ci-wait.test.sh 有案例失敗" >&2
fi
exit "$fail"
