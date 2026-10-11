#!/bin/bash
# pen-bounds-probe.sh 的自測（LS-480）：假 ioreg（PATH 前置）＋假 pen（get_app_state 與 execute 回 PROBE-BOUNDS 行），
# 全程不碰真的 Pen／螢幕鎖定狀態。驗：鎖屏 → exit 3 且不打 pen；bounds 偏移 >1pt → exit 3；吻合／≤1pt → exit 0；
# --ids 新節點；fail closed 的 exit 2 各案（active 非目標檔／pen 無回應／.pen 不存在／ids 缺）；以及兩支 mutation
# （拿掉鎖屏檢查、拿掉偏移判斷）證明案例有鑑別力。
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${root}/scripts/design/pen-bounds-probe.sh"
fail=0
n=0
ok() { echo "✓ $1"; n=$((n + 1)); }
bad() { echo "✗ $1" >&2; fail=1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bin="${work}/bin"; mkdir -p "$bin"
export PROBE_LOCK="${work}/lock" PROBE_STATE="${work}/state" PROBE_BOUNDS="${work}/bounds" PROBE_CALLS="${work}/calls"

# 假 ioreg：依 $PROBE_LOCK（true／false）印 plist 片段（真機格式：<key>IOConsoleLocked</key> 下一行 <true/>）
cat > "${bin}/ioreg" <<'STUB'
#!/bin/bash
echo '<?xml version="1.0"?><plist><array><dict>'
echo '	<key>IOConsoleUsers</key><array/>'
echo '	<key>IOConsoleLocked</key>'
echo "	<$(cat "${PROBE_LOCK:?}")/>"
echo '</dict></array></plist>'
STUB
# 假 pen：get_app_state 印 $PROBE_STATE；execute 對 $PROBE_BOUNDS（每行「id x y」）中、id 出現在送來 snippet 裡的列印 PROBE-BOUNDS
cat > "${bin}/pen" <<'STUB'
#!/bin/bash
[ "$1" = interactive ] || exit 1
input="$(cat)"
case "$input" in
  *execute\(*)
    echo x >> "${PROBE_CALLS:?}"
    while read -r id x y; do
      [ -n "$id" ] || continue
      case "$input" in *"$id"*) printf 'PROBE-BOUNDS id=%s x=%s y=%s\n' "$id" "$x" "$y" ;; esac
    done < "${PROBE_BOUNDS:?}"
    ;;
  *) printf 'Currently active canvas editor: `%s`\n' "$(cat "${PROBE_STATE:?}")" ;;
esac
STUB
chmod +x "${bin}/ioreg" "${bin}/pen"
export PATH="${bin}:${PATH}"
export PEN_OPEN_TIMEOUT=2 PEN_OPEN_ATTEMPT_TIMEOUT=1 PEN_OPEN_POLL_INTERVAL=1 PEN_PROBE_TIMEOUT=5
export PEN_BACKUP_DIR="${work}/backup"; mkdir -p "$PEN_BACKUP_DIR"

wt="$(cd "$work" && mkdir -p wt/design wt/docs/design-proposals/s && cd wt && pwd -P)"
# 主稿：三個頂層板 b1(10,20) b2(500,20) b3(990,20)；b1 內有 child c1(x=5,y=8)（巢狀）
cat > "${wt}/design/littlesprout.pen" <<'JSON'
{"version":1,"children":[
 {"id":"b1","x":10,"y":20,"children":[{"id":"c1","x":5,"y":8,"children":[]}]},
 {"id":"b2","x":500,"y":20,"children":[]},
 {"id":"b3","x":990,"y":20,"children":[]},
 {"id":"b4","x":1500,"y":20,"children":[]}]}
JSON
cp "${wt}/design/littlesprout.pen" "${wt}/docs/design-proposals/s/prop.pen"
prop="${wt}/docs/design-proposals/s/prop.pen"
main="${wt}/design/littlesprout.pen"

set_lock() { printf '%s' "$1" > "$PROBE_LOCK"; }
set_active() { printf '%s' "$1" > "$PROBE_STATE"; }
set_bounds() { printf '%s\n' "$@" > "$PROBE_BOUNDS"; }
calls() { wc -l < "$PROBE_CALLS" 2>/dev/null | tr -d ' ' || echo 0; }
reset() { set_lock false; set_active "$main"; : > "$PROBE_CALLS"; set_bounds "b1 10 20" "b2 500 20" "b3 990 20"; rm -f "${PEN_BACKUP_DIR}"/*; }
run() { bash "$script" --root "$wt" "$@"; }

# ① 鎖屏 → exit 3、印未刷新訊息、完全不打 pen（execute 零次）
reset; set_lock true
out="$(run 2>&1)"; got=$?
if [ "$got" -eq 3 ] && printf '%s' "$out" | grep -qF '⚠ Pen 版面未刷新（鎖屏？先解鎖並 open -a Pen）' && printf '%s' "$out" | grep -qF 'IOConsoleLocked' && [ "$(calls)" -eq 0 ]; then
  ok '① 鎖屏（IOConsoleLocked＝true）→ exit 3＋未刷新訊息，不打 pen'
else
  bad "① 鎖屏應 exit 3 且 execute 零次（實得 ${got}，execute ${out:+$(calls)} 次）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
# ② 未鎖屏、bounds 吻合 → exit 0（頂層前三個板都探到）
reset
out="$(run 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF '3 個探針節點' && [ "$(calls)" -eq 1 ]; then
  ok '② 未鎖屏＋bounds 吻合 → exit 0（自動取頂層前 3 個有明確 x/y 的板）'
else
  bad "② 吻合應 exit 0（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
# ③ LS-471 R3 症狀：y 系統性 +50 → exit 3＋OFFSET 列
reset; set_bounds "b1 10 70" "b2 500 70" "b3 990 70"
out="$(run 2>&1)"; got=$?
if [ "$got" -eq 3 ] && printf '%s' "$out" | grep -qF '⚠ Pen 版面未刷新' && printf '%s' "$out" | grep -qF 'OFFSET' && printf '%s' "$out" | grep -qF 'Get=(10,70)'; then
  ok '③ Get bounds y+50 偏移（LS-471 R3 症狀）→ exit 3＋OFFSET 列'
else
  bad "③ y+50 應 exit 3（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
# ④ 只有第三個節點偏移（x 錯位）也要抓；差 ≤1pt（0.5）不誤報
reset; set_bounds "b1 10 20" "b2 500 20" "b3 1190 20"
out="$(run 2>&1)"; got=$?
if [ "$got" -eq 3 ]; then ok '④ 單一探針節點 x 錯位 → exit 3'; else bad "④ 單點偏移應 exit 3（實得 ${got}）"; fi
reset; set_bounds "b1 10.5 20" "b2 500 19.5" "b3 990 20"
out="$(run 2>&1)"; got=$?
if [ "$got" -eq 0 ]; then ok '④b 差 0.5pt（≤1pt 容差）→ exit 0 不誤報'; else bad "④b 容差內應 exit 0（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2; fi
# ⑤ --pen 提案檔：探針用該檔（active 也要是該檔）；backup 比磁碟新時以 backup 為參考（含新建節點，--ids）
reset; set_active "$prop"
out="$(run --pen docs/design-proposals/s/prop.pen 2>&1)"; got=$?
if [ "$got" -eq 0 ]; then ok '⑤a --pen 提案檔（相對路徑）＋active＝提案檔＋吻合 → exit 0'; else bad "⑤a 應 exit 0（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2; fi
reset; set_active "$main"
out="$(run --pen docs/design-proposals/s/prop.pen 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '探測目標'; then ok '⑤b active 不是目標檔 → exit 2（先 pen-open.sh），不比 bounds'; else bad "⑤b active≠目標應 exit 2（實得 ${got}）"; fi
reset; set_active "$prop"
new_backup() { printf '%s' "$1" > "$(printf '%s' "file://${prop}" | shasum | awk '{print "'"${PEN_BACKUP_DIR}"'/" $1}')"; }
new_backup '{"version":1,"children":[{"id":"b1","x":10,"y":20,"children":[]},{"id":"nw","x":300,"y":400,"children":[{"id":"nwc","x":7,"y":9,"children":[]}]}]}'
set_bounds "nw 300 450"
out="$(run --pen "$prop" --ids nw 2>&1)"; got=$?
if [ "$got" -eq 3 ]; then ok '⑤c --ids 新建節點（只在 backup、磁碟檔沒有）y+50 → exit 3'; else bad "⑤c 新節點偏移應 exit 3（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2; fi
set_bounds "nw 300 400"
out="$(run --pen "$prop" --ids nw 2>&1)"; got=$?
if [ "$got" -eq 0 ]; then ok '⑤d --ids 新建節點吻合 → exit 0'; else bad "⑤d 應 exit 0（實得 ${got}）"; fi
set_bounds "nwc 307 409"   # 巢狀節點：絕對座標（父 300,400 + 7,9）也接受
out="$(run --pen "$prop" --ids nwc 2>&1)"; got=$?
if [ "$got" -eq 0 ]; then ok '⑤e 巢狀節點 Get 回累加絕對座標也接受（scoped Get 座標系兩者擇一，PLAUSIBLE）'; else bad "⑤e 巢狀絕對座標應 exit 0（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2; fi
set_bounds "nwc 7 9"
out="$(run --pen "$prop" --ids nwc 2>&1)"; got=$?
if [ "$got" -eq 0 ]; then ok '⑤f 巢狀節點 Get 回相對父節點座標亦接受'; else bad "⑤f 巢狀相對座標應 exit 0（實得 ${got}）"; fi
out="$(run --pen "$prop" --ids ghost 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF 'ghost'; then ok '⑤g --ids 節點在參考檔找不到 → exit 2（等 autosave），不當通過'; else bad "⑤g 缺節點應 exit 2（實得 ${got}）"; fi
# ⑥ fail closed：pen 對探針完全無回應 → exit 2；.pen 不存在／缺參數 → exit 2
reset; set_bounds ""
out="$(run 2>&1)"; got=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '沒有回 PROBE-BOUNDS'; then ok '⑥a Pen 無回應 → exit 2（不當通過）'; else bad "⑥a 無回應應 exit 2（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2; fi
reset
out="$(run --pen docs/design-proposals/s/nope.pen 2>&1)"; got=$?
out2="$(run --pen 2>&1)"; got2=$?
out3="$(run --bogus 2>&1)"; got3=$?
if [ "$got" -eq 2 ] && printf '%s' "$out" | grep -qF '不存在' && [ "$got2" -eq 2 ] && [ "$got3" -eq 2 ]; then ok '⑥b --pen 不存在／缺參數／未知旗標 → exit 2＋用法'; else bad "⑥b 負案應 exit 2（實得 ${got}／${got2}／${got3}）"; fi
# ⑦ 找不到 ioreg（非 macOS）→ 印一行說明、略過鎖屏檢查仍做 bounds 比對
reset
out="$(PEN_PROBE_IOREG_BIN=/nonexistent/ioreg run 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF '略過鎖屏檢查'; then ok '⑦ 找不到 ioreg → 略過鎖屏檢查、bounds 比對照做（exit 0）'; else bad "⑦ 無 ioreg 應略過並 exit 0（實得 ${got}）"; fi
# ⑧ 不產檔：探針跑完（含 exit 3）後 root 內沒有任何新檔（沒有收據、沒有暫存殘留）
reset; set_lock true
before_files="$(find "$wt" -type f | sort | tr '\n' ' ')"
run >/dev/null 2>&1
reset; set_bounds "b1 10 70" "b2 500 70" "b3 990 70"; run >/dev/null 2>&1
after_files="$(find "$wt" -type f | sort | tr '\n' ' ')"
if [ "$before_files" = "$after_files" ]; then ok '⑧ exit 3 不產任何檔（root 內檔案清單前後相同）'; else bad "⑧ exit 3 不得產檔（前：${before_files}／後：${after_files}）"; fi

# ⑨ mutation：拿掉鎖屏檢查 → ①轉放行（證明 ① 有鑑別力）；拿掉偏移判斷 → ③ 轉 exit 0
mroot="${work}/mut"; mkdir -p "${mroot}/scripts/design" "${mroot}/scripts/ops/lib"
cp "${root}/scripts/ops/lib/pen-path.sh" "${mroot}/scripts/ops/lib/"
mutate() { # <名稱> <python 取代前> <python 取代後>
  python3 - "$script" "${mroot}/scripts/design/$1.sh" "$2" "$3" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
assert sys.argv[3] in src, "mutation 目標不存在：" + sys.argv[3]
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(sys.argv[3], sys.argv[4], 1))
PY
}
mutate mut-nolock "*'<true/>'*)" "*'NEVER-MATCH'*)"
reset; set_lock true
out="$(PEN_PROBE_OPEN_SH="${root}/scripts/ops/pen-open.sh" bash "${mroot}/scripts/design/mut-nolock.sh" --root "$wt" 2>&1)"; got=$?
if [ "$got" -eq 0 ]; then ok '⑨a mutation（鎖屏判斷拿掉）→ 鎖屏案例轉 exit 0（① 確實靠鎖屏檢查才紅）'; else bad "⑨a mutation 後鎖屏案例應轉 exit 0（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2; fi
mutate mut-nooffset 'ok = max(rel) <= tol' 'ok = True'
reset; set_bounds "b1 10 70" "b2 500 70" "b3 990 70"
out="$(PEN_PROBE_OPEN_SH="${root}/scripts/ops/pen-open.sh" bash "${mroot}/scripts/design/mut-nooffset.sh" --root "$wt" 2>&1)"; got=$?
if [ "$got" -eq 0 ]; then ok '⑨b mutation（偏移比對恆通過）→ y+50 案例轉 exit 0（③ 確實靠 bounds 比對才紅）'; else bad "⑨b mutation 後偏移案例應轉 exit 0（實得 ${got}）"; printf '%s\n' "$out" | sed 's/^/    /' >&2; fi

if [ "$fail" -ne 0 ]; then
  echo "✗ pen-bounds-probe 自測失敗" >&2
  exit 1
fi
echo "✓ pen-bounds-probe 自測通過（${n} 組樣本）"
