#!/bin/bash
# large-file-read-guard.sh／large_file_read_guard.py 自測（LS-239 範圍 2；R2 merge-review R1
# B1/M1/M2 修正後重寫）。CI rules job 每個 PR 都跑。「前饋必有反饋」對 gate 本身也適用：若
# (a) 身分判斷（agent_id）、(b) tasks/*.output 有界／無界判斷、(c) 大檔＋無 offset/limit 判斷、
# (d) 圖片／PDF 排除任一退化，這裡會紅。同 pretool.test.sh／background-bash-guard.test.sh 的
# 慣例：純 bash 3.2，不用陣列／${var,,}。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="${root}/scripts/hooks/large-file-read-guard.sh"
engine_py="${root}/scripts/hooks/large_file_read_guard.py"
fail=0
n=0
skipped=0   # LS-256：jq 缺席時少跑的組數，收工印 SKIP（不再靜默少跑仍印通過）
ok() { echo "✓ $1"; n=$((n + 1)); }
bad() { echo "✗ $1" >&2; fail=1; }
esc() { printf '%s' "$1" | sed 's/[.[\*^$]/\\&/g'; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
bash_bin=$(bash -c 'type -P bash' 2>/dev/null || echo /bin/bash)
real_jq=$(bash -c 'type -P jq' 2>/dev/null || true)

# ---- 準備 fixture 檔 ----
big_file="$work/big.txt"
head -c 5000 /dev/zero > "$big_file"
small_file="$work/small.txt"
printf 'hello\n' > "$small_file"
mkdir -p "$work/proj/tasks"
tasks_output="$work/proj/tasks/abc123.output"
printf '%s' "small enough" > "$tasks_output"
big_png="$work/proj/big.png"
head -c 20000 /dev/zero > "$big_png"
big_pdf="$work/proj/BIG.PDF"
head -c 20000 /dev/zero > "$big_pdf"
dir_path="$work/proj"

# ---- payload builders ----
# read_json <file_path> [offset] [limit]：無身分欄位（主 session）
read_json() {
  local fp=$1 off=${2:-} lim=${3:-}
  local extra=""
  [ -n "$off" ] && extra="${extra},\"offset\":${off}"
  [ -n "$lim" ] && extra="${extra},\"limit\":${lim}"
  printf '{"tool_name":"Read","tool_input":{"file_path":"%s"%s}}' "$fp" "$extra"
}
# read_json_limit_raw <file_path> <limit 的 JSON 原始字面（含引號皆可）>：供非法型別／邊界值測試
read_json_limit_raw() {
  printf '{"tool_name":"Read","tool_input":{"file_path":"%s","limit":%s}}' "$1" "$2"
}
# read_json_agent_id <agent_id json 值> <file_path>：有 agent_id、無 agent_type
read_json_agent_id() {
  printf '{"tool_name":"Read","agent_id":%s,"tool_input":{"file_path":"%s"}}' "$1" "$2"
}
# read_json_agent_type <agent_type json 值> <file_path>：有 agent_type、無 agent_id（--agent 主 session）
read_json_agent_type() {
  printf '{"tool_name":"Read","agent_type":%s,"tool_input":{"file_path":"%s"}}' "$1" "$2"
}
# read_json_both <agent_id json 值> <agent_type json 值> <file_path>：兩者皆有（正常 subagent）
read_json_both() {
  printf '{"tool_name":"Read","agent_id":%s,"agent_type":%s,"tool_input":{"file_path":"%s"}}' "$1" "$2" "$3"
}
# bash_json <command>：無身分欄位（主 session）
bash_json() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }
# bash_json_agent_id <agent_id json 值> <command>
bash_json_agent_id() { printf '{"tool_name":"Bash","agent_id":%s,"tool_input":{"command":"%s"}}' "$1" "$2"; }

# expect <label> <want_exit> <payload> [guard_path]：allow（want=0）驗無 stdout；deny（want=2）驗
# stdout 含 deny JSON。guard_path 預設 $guard，mutation 段落改指向 mutant 目錄下的 wrapper。
expect() {
  local label=$1 want=$2 payload=$3 gp=${4:-$guard} out got
  out=$(printf '%s' "$payload" | "$bash_bin" "$gp" 2>/dev/null)
  got=$?
  if [ "$got" -ne "$want" ]; then
    bad "${label}（期望 exit ${want}，實得 ${got}；輸出：${out}）"
    return
  fi
  if [ "$want" -eq 0 ]; then
    if [ -n "$out" ]; then
      bad "${label}（allow 應無 stdout，實得：${out}）"
      return
    fi
  else
    case "$out" in
      *'"permissionDecision":"deny"'*) ;;
      *) bad "${label}（exit=${want} 但輸出缺 deny JSON：${out}）"; return ;;
    esac
  fi
  ok "${label}"
}

# ============================================================
# ① B1：Bash 無界讀取 tasks/*.output 仍擋（deny）
# ============================================================
expect '①a 裸 cat tasks/*.output（deny，無界）' 2 "$(bash_json "cat ${tasks_output}")"
expect '①b cat tasks/*.output > 檔案（deny，整檔重導向）' 2 "$(bash_json "cat ${tasks_output} > ${work}/copy.txt")"
expect '①c less tasks/*.output（deny，無界）' 2 "$(bash_json "less ${tasks_output}")"
expect '①d grep ... tasks/*.output | cat（deny，最後一段 cat 不是有界形狀）' 2 \
  "$(bash_json "grep foo ${tasks_output} | cat")"
expect '①e tail -n 41 tasks/*.output（deny，超過行數上限 40）' 2 "$(bash_json "tail -n 41 ${tasks_output}")"
expect '①f tail -c 8193 tasks/*.output（deny，超過位元組上限 8192）' 2 "$(bash_json "tail -c 8193 ${tasks_output}")"

# ============================================================
# ② B1 修法：Bash 有界讀取 tasks/*.output 放行（allow）——真實流量重放樣本
# ============================================================
expect '②a tail -2 tasks/*.output（allow，裸 -N 形式且 ≤40）' 0 "$(bash_json "tail -2 ${tasks_output}")"
expect '②b head -5 tasks/*.output（allow）' 0 "$(bash_json "head -5 ${tasks_output}")"
expect '②c cat tasks/*.output | tail -2（allow，最後一段有界——真實流量樣本）' 0 \
  "$(bash_json "cat ${tasks_output} | tail -2")"
expect '②d tail -c 200000 | grep | tail -n 6（allow，agent-liveness-signal.md 樣板本尊）' 0 \
  "$(bash_json "tail -c 200000 ${tasks_output} | grep -oE \\\"a\\\" | tail -n 6")"
expect '②e wc -l tasks/*.output（allow，摘要型動詞）' 0 "$(bash_json "wc -l ${tasks_output}")"
expect '②f grep foo tasks/*.output（allow，單段摘要型動詞）' 0 "$(bash_json "grep foo ${tasks_output}")"
expect '②g stat tasks/*.output（allow）' 0 "$(bash_json "stat ${tasks_output}")"
expect '②h ls tasks/*.output（allow）' 0 "$(bash_json "ls ${tasks_output}")"
expect '②i tail -n 40 tasks/*.output（allow，剛好在上限）' 0 "$(bash_json "tail -n 40 ${tasks_output}")"
expect '②j 分號分隔：tail -1 tasks/*.output; echo done（allow，第二段不相干）' 0 \
  "$(bash_json "tail -1 ${tasks_output}; echo done")"
expect '②k 已知盲區：變數間接 O=path; grep $O | tail -3（allow，票文明示不追）' 0 \
  "$(bash_json "O=${tasks_output}; grep -E a \$O | tail -3")"
expect '②l 非 tasks/*.output 的 cat（allow，Bash 側不做一般化大檔偵測，已知盲區）' 0 \
  "$(bash_json "cat ${big_file}")"

# ============================================================
# ③ Read 側 tasks/*.output：limit ≤40 放行，否則擋
# ============================================================
expect '③a Read tasks/*.output limit=40（allow，剛好在上限）' 0 "$(read_json "$tasks_output" "" 40)"
expect '③b Read tasks/*.output limit=41（deny，超過上限）' 2 "$(read_json "$tasks_output" "" 41)"
expect '③c Read tasks/*.output 無 limit（deny）' 2 "$(read_json "$tasks_output")"
expect '③d Read tasks/*.output limit=100000（deny，繞過已收斂——對照 R1 舊漏洞）' 2 \
  "$(read_json "$tasks_output" "" 100000)"
expect '③e Read tasks/*.output limit=0（deny，非正整數）' 2 "$(read_json_limit_raw "$tasks_output" 0)"
expect '③f Read tasks/*.output limit="40"（deny，字串型別不採信）' 2 \
  "$(read_json_limit_raw "$tasks_output" '"40"')"

# ============================================================
# ④ M1：圖片／PDF 排除 H-LF(b)，不受 4 KB／offset／limit 規則約束
# ============================================================
expect '④a Read 大 .png 無 offset/limit（allow，圖片排除）' 0 "$(read_json "$big_png")"
expect '④b Read 大 .PDF（大寫）無 offset/limit（allow，副檔名比對不分大小寫）' 0 "$(read_json "$big_pdf")"
expect '④c 對照：Read 大 .txt 無 offset/limit（deny，非圖片仍套規則）' 2 "$(read_json "$big_file")"

# ============================================================
# ⑤ i5：Read 目錄不觸發大檔規則（不是一般檔案）
# ============================================================
expect '⑤a Read 目錄路徑（allow，非一般檔案，交給 Read 工具自己報錯）' 0 "$(read_json "$dir_path")"

# ============================================================
# ⑥ M2：身分判準改用 agent_id（不是 agent_type）
# ============================================================
expect '⑥a 有 agent_id 無 agent_type（allow，subagent——2.1.270 schema：agent_id 才是判準）' 0 \
  "$(read_json_agent_id '"agent-1"' "$tasks_output")"
expect '⑥b 有 agent_type 無 agent_id（deny，--agent 啟動的主 session——R1 M2 修正的假陰）' 2 \
  "$(read_json_agent_type '"general-purpose"' "$tasks_output")"
expect '⑥c 兩者皆缺席（deny，經典主 session）' 2 "$(read_json "$tasks_output")"
expect '⑥d 兩者皆存在（allow，正常 subagent 呼叫）' 0 \
  "$(read_json_both '"agent-1"' '"ios-dev"' "$tasks_output")"
expect '⑥e Bash 側同樣看 agent_id（allow，subagent 裸 cat 也放行）' 0 \
  "$(bash_json_agent_id '"agent-1"' "cat ${tasks_output}")"

# ⑥f／⑥g 身分不明放行＋stderr（agent_id 存在但不可採信：空字串／非字串型別）
errfile=$(mktemp)
out=$(printf '%s' "$(read_json_agent_id '""' "$big_file")" | "$bash_bin" "$guard" 2>"$errfile")
got=$?
if [ "$got" -eq 0 ] && [ -z "$out" ] && grep -qF '無法採信' "$errfile"; then
  ok '⑥f 身分不明（agent_id 空字串）：allow 且 stderr 含「無法採信」註記'
else
  bad "⑥f 應 allow＋stderr 註記（實得 exit ${got}，stdout=${out}，stderr=$(cat "$errfile"))"
fi
out=$(printf '%s' "$(read_json_agent_id '123' "$big_file")" | "$bash_bin" "$guard" 2>"$errfile")
got=$?
if [ "$got" -eq 0 ] && [ -z "$out" ] && grep -qF '無法採信' "$errfile"; then
  ok '⑥g 身分不明（agent_id 為數字非字串）：allow 且 stderr 含「無法採信」註記'
else
  bad "⑥g 應 allow＋stderr 註記（實得 exit ${got}，stdout=${out}，stderr=$(cat "$errfile"))"
fi
rm -f "$errfile"

# ============================================================
# ⑦ 其餘負樣本（沿用 R1，確認基本情境無回歸）
# ============================================================
expect '⑦a 主 session Read 小檔、無 offset／limit（allow）' 0 "$(read_json "$small_file")"
expect '⑦b 主 session Read 大檔、帶 offset（allow，已限縮讀取範圍）' 0 "$(read_json "$big_file" 1)"
expect '⑦c 主 session Read 不存在的檔案（allow，交給 Read 工具自己報錯）' 0 \
  "$(read_json "$work/nope-does-not-exist.txt")"
expect '⑦d 非 Read／Bash 工具（Write，allow）' 0 \
  "$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$big_file")"

# ============================================================
# ⑧ fail-closed 三種
# ============================================================
mkdir -p "$work/nopy" "$work/badpy"
cat > "$work/badpy/python3" <<'STUB'
#!/bin/bash
exit 137
STUB
chmod +x "$work/badpy/python3"

expect '⑧a stdin 是空的（deny，fail-closed）' 2 ''
out=$(printf 'not json' | "$bash_bin" "$guard" 2>/dev/null); got=$?
[ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) ok '⑧b JSON 壞掉（deny，fail-closed）' ;; *) bad "⑧b 應 deny：${out}" ;; esac || bad "⑧b 應 exit 2（實得 ${got}）"

out=$(printf '%s' "$(read_json "$small_file")" | PATH="$work/nopy" "$bash_bin" "$guard" 2>/dev/null); got=$?
[ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) ok '⑧c python3 不存在（deny，fail-closed）' ;; *) bad "⑧c 應 deny：${out}" ;; esac || bad "⑧c 應 exit 2（實得 ${got}）"

out=$(printf '%s' "$(read_json "$small_file")" | PATH="$work/badpy:/usr/bin:/bin" "$bash_bin" "$guard" 2>/dev/null); got=$?
[ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) ok '⑧d python3 以異常 rc 結束（deny，fail-closed）' ;; *) bad "⑧d 應 deny：${out}" ;; esac || bad "⑧d 應 exit 2（實得 ${got}）"

# ============================================================
# ⑨ mutation：五組，逐一證明關鍵判斷確實是造成 allow/deny 的原因
# ============================================================

# ⑨a：拿掉身分判斷（agent_id 一律視為缺席）→ ⑥a（subagent）翻成 deny
mut=$(mktemp -d)
cp "$guard" "$engine_py" "${root}/scripts/hooks/pretool_engine.py" "$mut/"
anchor=$(esc 'raw = d.get("agent_id", _MISSING)')
if ! grep -qF 'raw = d.get("agent_id", _MISSING)' "$engine_py"; then
  bad "⑨a mutation 錨點（身分判斷）不在 large_file_read_guard.py"
else
  sed "s/${anchor}/raw = _MISSING/" "$engine_py" > "$mut/large_file_read_guard.py"
  if ! diff -q "$engine_py" "$mut/large_file_read_guard.py" >/dev/null 2>&1; then
    expect '⑨a mutant：拿掉身分判斷後，⑥a（agent_id 存在）變成 deny（原本的 allow 確由該判斷造成）' 2 \
      "$(read_json_agent_id '"agent-1"' "$tasks_output")" "$mut/large-file-read-guard.sh"
  else
    bad '⑨a mutant 與原始檔完全相同（sed 未命中，mutation 測試本身無效）'
  fi
fi
rm -rf "$mut"

# ⑨b：拿掉 Bash 有界判斷（一律視為無界）→ ②a（tail -2，應 allow）翻成 deny
mut2=$(mktemp -d)
cp "$guard" "$engine_py" "${root}/scripts/hooks/pretool_engine.py" "$mut2/"
anchor2=$(esc 'if not _chain_is_bounded(stages):')
if ! grep -qF 'if not _chain_is_bounded(stages):' "$engine_py"; then
  bad "⑨b mutation 錨點（Bash 有界判斷）不在 large_file_read_guard.py"
else
  sed "s/${anchor2}/if True:/" "$engine_py" > "$mut2/large_file_read_guard.py"
  if ! diff -q "$engine_py" "$mut2/large_file_read_guard.py" >/dev/null 2>&1; then
    expect '⑨b mutant：拿掉 Bash 有界判斷後，②a（tail -2）變成 deny（原本的 allow 確由該判斷造成）' 2 \
      "$(bash_json "tail -2 ${tasks_output}")" "$mut2/large-file-read-guard.sh"
  else
    bad '⑨b mutant 與原始檔完全相同（sed 未命中，mutation 測試本身無效）'
  fi
fi
rm -rf "$mut2"

# ⑨c：拿掉圖片／PDF 排除 → ④a（大 .png）翻成 deny
mut3=$(mktemp -d)
cp "$guard" "$engine_py" "${root}/scripts/hooks/pretool_engine.py" "$mut3/"
anchor3=$(esc 'if ext in IMAGE_PDF_EXTS:')
if ! grep -qF 'if ext in IMAGE_PDF_EXTS:' "$engine_py"; then
  bad "⑨c mutation 錨點（圖片排除）不在 large_file_read_guard.py"
else
  sed "s/${anchor3}/if False:/" "$engine_py" > "$mut3/large_file_read_guard.py"
  if ! diff -q "$engine_py" "$mut3/large_file_read_guard.py" >/dev/null 2>&1; then
    expect '⑨c mutant：拿掉圖片排除後，④a（大 .png）變成 deny（原本的 allow 確由該判斷造成）' 2 \
      "$(read_json "$big_png")" "$mut3/large-file-read-guard.sh"
  else
    bad '⑨c mutant 與原始檔完全相同（sed 未命中，mutation 測試本身無效）'
  fi
fi
rm -rf "$mut3"

# ⑨d：拿掉 Read 側 tasks/*.output 的 limit 上限判斷（一律放行）→ ③c（無 limit，應 deny）翻成 allow
mut4=$(mktemp -d)
cp "$guard" "$engine_py" "${root}/scripts/hooks/pretool_engine.py" "$mut4/"
anchor4=$(esc 'if _valid_bounded_limit(limit_val, TASKS_OUTPUT_LIMIT_MAX):')
if ! grep -qF 'if _valid_bounded_limit(limit_val, TASKS_OUTPUT_LIMIT_MAX):' "$engine_py"; then
  bad "⑨d mutation 錨點（tasks/*.output limit 上限）不在 large_file_read_guard.py"
else
  sed "s/${anchor4}/if True:/" "$engine_py" > "$mut4/large_file_read_guard.py"
  if ! diff -q "$engine_py" "$mut4/large_file_read_guard.py" >/dev/null 2>&1; then
    expect '⑨d mutant：拿掉 tasks/*.output limit 上限後，③c（無 limit）變成 allow（原本的 deny 確由該判斷造成）' 0 \
      "$(read_json "$tasks_output")" "$mut4/large-file-read-guard.sh"
  else
    bad '⑨d mutant 與原始檔完全相同（sed 未命中，mutation 測試本身無效）'
  fi
fi
rm -rf "$mut4"

# ⑨e：拿掉大檔＋無 offset/limit 判斷（H-LF(b)）→ ④c（大 .txt）翻成 allow
mut5=$(mktemp -d)
cp "$guard" "$engine_py" "${root}/scripts/hooks/pretool_engine.py" "$mut5/"
anchor5=$(esc 'if _large_without_window(file_path, ti.get("offset"), ti.get("limit")):')
if ! grep -qF 'if _large_without_window(file_path, ti.get("offset"), ti.get("limit")):' "$engine_py"; then
  bad "⑨e mutation 錨點（大檔判斷）不在 large_file_read_guard.py"
else
  sed "s/${anchor5}/if False:/" "$engine_py" > "$mut5/large_file_read_guard.py"
  if ! diff -q "$engine_py" "$mut5/large_file_read_guard.py" >/dev/null 2>&1; then
    expect '⑨e mutant：拿掉大檔判斷後，④c（大 .txt）變成 allow（原本的 deny 確由該判斷造成）' 0 \
      "$(read_json "$big_file")" "$mut5/large-file-read-guard.sh"
  else
    bad '⑨e mutant 與原始檔完全相同（sed 未命中，mutation 測試本身無效）'
  fi
fi
rm -rf "$mut5"

# ============================================================
# ⑪ R3（merge-review R2 major＋m1）：chain 切分的兩個洞＋ls/stat 首段放行
# ============================================================
expect '⑪a fd 複製 2>&1 不再被當 chain 分隔（allow，agent-liveness-signal.md 樣板加 2>&1）' 0 \
  "$(bash_json "tail -c 200000 ${tasks_output} 2>&1 | grep -oE \\\"a\\\" | tail -n 6")"
expect '⑪b &> 重導向不再被當 chain 分隔、末段仍有界（allow）' 0 \
  "$(bash_json "tail -n 6 ${tasks_output} &>/dev/null")"
expect '⑪c &> 重導向但無界末段（deny，&> 本身不代表有界，只是不再被切錯 chain）' 2 \
  "$(bash_json "cat ${tasks_output} &>/dev/null")"
expect '⑪d 多行管線（行尾 | 換行）摺成單行後仍判有界（allow）' 0 \
  "$(printf '{"tool_name":"Bash","tool_input":{"command":"tail -c 200000 %s |\\n  grep -oE \\"a\\" |\\n  tail -n 6"}}' "$tasks_output")"
expect '⑪e ls -la | awk（不接 stat/ls，末段非白名單）現在也放行——ls 首段即有界，不限末段（m1）' 0 \
  "$(bash_json "ls -la ${tasks_output} | awk '{print \$6,\$7,\$8}'")"
expect '⑪f stat | cut（stat 首段即有界，不限末段，m1）' 0 \
  "$(bash_json "stat ${tasks_output} | cut -c1-20")"
expect '⑪g for 迴圈 do ls -la … | awk（真實流量樣本：naive ; 切段把 do 當 tokens[0]，
  跳過前綴關鍵字後 ls 仍能被辨識，allow）' 0 \
  "$(bash_json "for a in x y; do ls -la ${tasks_output} | awk '{print \$6}'; done")"
expect '⑪h 對照：&& 仍照舊是 chain 分隔（deny，前段裸 cat 無界，&& 不受 fd 複製排除影響）' 2 \
  "$(bash_json "cat ${tasks_output} && echo done")"

# ⑪ mutation：拿掉 fd 複製排除 → ⑪a（2>&1 樣板）翻成 deny
mut6=$(mktemp -d)
cp "$guard" "$engine_py" "${root}/scripts/hooks/pretool_engine.py" "$mut6/"
anchor6=$(esc 'CHAIN_SPLIT_RE = re.compile(r"&&|\|\||;|(?<![&>])&(?!&|>)|\n")')
if ! grep -qF 'CHAIN_SPLIT_RE = re.compile(r"&&|\|\||;|(?<![&>])&(?!&|>)|\n")' "$engine_py"; then
  bad "⑪ mutation 錨點（fd 複製排除）不在 large_file_read_guard.py"
else
  sed "s/${anchor6}/CHAIN_SPLIT_RE = re.compile(r\"&&|\\\\|\\\\||;|\&(?!\&)|\\\\n\")/" "$engine_py" > "$mut6/large_file_read_guard.py"
  if ! diff -q "$engine_py" "$mut6/large_file_read_guard.py" >/dev/null 2>&1; then
    expect '⑪ mutant：拿掉 fd 複製排除後，⑪a（2>&1 樣板）變成 deny（原本的 allow 確由該判斷造成）' 2 \
      "$(bash_json "tail -c 200000 ${tasks_output} 2>&1 | grep -oE \\\"a\\\" | tail -n 6")" "$mut6/large-file-read-guard.sh"
  else
    bad '⑪ mutant 與原始檔完全相同（sed 未命中，mutation 測試本身無效）'
  fi
fi
rm -rf "$mut6"

# ⑫ mutation：拿掉多行管線摺疊 → ⑪d（多行管線）翻成 deny
mut7=$(mktemp -d)
cp "$guard" "$engine_py" "${root}/scripts/hooks/pretool_engine.py" "$mut7/"
anchor7=$(esc 'stripped = _collapse_pipe_continuations(stripped)  # R3：多行管線先摺成單行')
if ! grep -qF 'stripped = _collapse_pipe_continuations(stripped)  # R3：多行管線先摺成單行' "$engine_py"; then
  bad "⑫ mutation 錨點（多行管線摺疊呼叫點）不在 large_file_read_guard.py"
else
  sed "s/${anchor7}/pass  # mutated/" "$engine_py" > "$mut7/large_file_read_guard.py"
  if ! diff -q "$engine_py" "$mut7/large_file_read_guard.py" >/dev/null 2>&1; then
    expect '⑫ mutant：拿掉多行管線摺疊後，⑪d（多行管線）變成 deny（原本的 allow 確由該判斷造成）' 2 \
      "$(printf '{"tool_name":"Bash","tool_input":{"command":"tail -c 200000 %s |\\n  grep -oE \\"a\\" |\\n  tail -n 6"}}' "$tasks_output")" "$mut7/large-file-read-guard.sh"
  else
    bad '⑫ mutant 與原始檔完全相同（sed 未命中，mutation 測試本身無效）'
  fi
fi
rm -rf "$mut7"

# ⑬ mutation：拿掉 ls/stat 首段判斷（METADATA_ONLY_VERBS 檢查）→ ⑪e（ls|awk）翻成 deny
mut8=$(mktemp -d)
cp "$guard" "$engine_py" "${root}/scripts/hooks/pretool_engine.py" "$mut8/"
anchor8=$(esc 'if any(_stage_command_position(s) in METADATA_ONLY_VERBS for s in stages):')
if ! grep -qF 'if any(_stage_command_position(s) in METADATA_ONLY_VERBS for s in stages):' "$engine_py"; then
  bad "⑬ mutation 錨點（ls/stat 首段判斷）不在 large_file_read_guard.py"
else
  sed "s/${anchor8}/if False:/" "$engine_py" > "$mut8/large_file_read_guard.py"
  if ! diff -q "$engine_py" "$mut8/large_file_read_guard.py" >/dev/null 2>&1; then
    expect '⑬ mutant：拿掉 ls/stat 首段判斷後，⑪e（ls|awk）變成 deny（原本的 allow 確由該判斷造成）' 2 \
      "$(bash_json "ls -la ${tasks_output} | awk '{print \$6,\$7,\$8}'")" "$mut8/large-file-read-guard.sh"
  else
    bad '⑬ mutant 與原始檔完全相同（sed 未命中，mutation 測試本身無效）'
  fi
fi
rm -rf "$mut8"

# ============================================================
# ⑭ settings.json 接線斷言（只加不刪：既有三條 PreToolUse 仍在）
# ============================================================
settings_json="${root}/.claude/settings.json"
if [ -n "$real_jq" ]; then
  lf_cmd=$("$real_jq" -r '.hooks.PreToolUse[] | select(.matcher == "Bash|Read") | .hooks[] | select(.type == "command") | .command' "$settings_json" 2>/dev/null | grep -F 'large-file-read-guard.sh' || true)
else
  lf_cmd=$(python3 -c "
import json
d = json.load(open('$settings_json'))
for entry in d.get('hooks', {}).get('PreToolUse', []):
    if entry.get('matcher') == 'Bash|Read':
        for h in entry.get('hooks', []):
            if h.get('type') == 'command' and 'large-file-read-guard.sh' in h.get('command', ''):
                print(h['command'])
" 2>/dev/null)
fi
if [ -n "$lf_cmd" ]; then
  ok '⑭① settings.json 的 PreToolUse matcher=Bash|Read 有一條呼叫 large-file-read-guard.sh'
else
  bad '⑭① settings.json 找不到 matcher=Bash|Read 呼叫 large-file-read-guard.sh 的 PreToolUse command'
fi
case "$lf_cmd" in
  *'|| exit 2'*) ok '⑭② command 帶 || exit 2（wiring 層 fail-closed）' ;;
  *) bad "⑭② command 沒有 || exit 2（實得：${lf_cmd}）" ;;
esac
if [ -n "$real_jq" ]; then
  old1=$("$real_jq" -r '.hooks.PreToolUse[] | select(.matcher == "Bash|Read|Grep") | .hooks[0].command' "$settings_json" 2>/dev/null)
  old2=$("$real_jq" -r '.hooks.PreToolUse[] | select(.matcher == "Bash|Write|Edit|MultiEdit|NotebookEdit") | .hooks[0].command' "$settings_json" 2>/dev/null)
  old3=$("$real_jq" -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0].command' "$settings_json" 2>/dev/null)
  case "$old1" in *pretool.sh*) ok '⑭③ 既有 Bash|Read|Grep（pretool.sh）條目仍在' ;; *) bad "⑭③ pretool.sh 條目消失（實得：${old1}）" ;; esac
  case "$old2" in *main-checkout-guard.sh*) ok '⑭④ 既有 Bash|Write|Edit|MultiEdit|NotebookEdit（main-checkout-guard.sh）條目仍在' ;; *) bad "⑭④ main-checkout-guard.sh 條目消失（實得：${old2}）" ;; esac
  case "$old3" in *background-bash-guard.sh*) ok '⑭⑤ 既有 Bash（background-bash-guard.sh）條目仍在' ;; *) bad "⑭⑤ background-bash-guard.sh 條目消失（實得：${old3}）" ;; esac
else
  # LS-256（LS-96 池項 a7e9e910 i2）：jq 缺席不再靜默少跑——印 SKIP＋計數，收工總結帶出來
  echo "SKIP 3 組（無 jq）：⑭③–⑭⑤ settings.json 既有三條 PreToolUse 接線斷言未跑"
  skipped=$((skipped + 3))
fi

rm -rf "$work"
trap - EXIT

if [ "$fail" -eq 0 ]; then
  if [ "$skipped" -gt 0 ]; then
    echo "✓ large-file-read-guard.sh 自測通過（${n} 組；SKIP ${skipped} 組（無 jq））"
  else
    echo "✓ large-file-read-guard.sh 自測通過（${n} 組）"
  fi
fi
exit "$fail"
