#!/bin/bash
# large-file-read-guard.sh／large_file_read_guard.py 自測（LS-239 範圍 2）。CI rules job 每個 PR
# 都跑。「前饋必有反饋」對 gate 本身也適用：若 (a) 身分判斷、(b) tasks/*.output 判斷、(c) 大檔＋
# 無 offset/limit 判斷任一退化，這裡會紅。同 pretool.test.sh／background-bash-guard.test.sh 的
# 慣例：純 bash 3.2，不用陣列／${var,,}。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="${root}/scripts/hooks/large-file-read-guard.sh"
engine_py="${root}/scripts/hooks/large_file_read_guard.py"
fail=0
n=0
ok() { echo "✓ $1"; n=$((n + 1)); }
bad() { echo "✗ $1" >&2; fail=1; }

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

# ---- payload builders ----
# read_json <file_path> [offset] [limit]：無 agent_type
read_json() {
  local fp=$1 off=${2:-} lim=${3:-}
  local extra=""
  [ -n "$off" ] && extra="${extra},\"offset\":${off}"
  [ -n "$lim" ] && extra="${extra},\"limit\":${lim}"
  printf '{"tool_name":"Read","tool_input":{"file_path":"%s"%s}}' "$fp" "$extra"
}
# read_json_agent <agent_type json 值> <file_path>
read_json_agent() {
  printf '{"tool_name":"Read","agent_type":%s,"tool_input":{"file_path":"%s"}}' "$1" "$2"
}
# bash_json <command>：無 agent_type
bash_json() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }
# bash_json_agent <agent_type json 值> <command>
bash_json_agent() { printf '{"tool_name":"Bash","agent_type":%s,"tool_input":{"command":"%s"}}' "$1" "$2"; }

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
# ① 正樣本（deny）
# ============================================================
expect '①a 主 session Read tasks/*.output（deny）' 2 "$(read_json "$tasks_output")"
expect '①b 主 session Bash cat tasks/*.output（deny）' 2 "$(bash_json "cat ${tasks_output}")"
expect '①c 主 session Bash 管線 cat tasks/*.output | head -20（deny，同段落內出現即算）' 2 \
  "$(bash_json "cat ${tasks_output} | head -20")"
expect '①d 主 session Read 超過約 4 KB 的檔案、無 offset／limit（deny）' 2 "$(read_json "$big_file")"

# ============================================================
# ② 負樣本（allow）
# ============================================================
expect '②a subagent（ios-dev）Read 同一個 tasks/*.output（allow）' 0 \
  "$(read_json_agent '"ios-dev"' "$tasks_output")"
expect '②b subagent（qa）Bash cat 同一個 tasks/*.output（allow）' 0 \
  "$(bash_json_agent '"qa"' "cat ${tasks_output}")"
expect '②c 主 session Read 小檔、無 offset／limit（allow）' 0 "$(read_json "$small_file")"
expect '②d 主 session Read 大檔、帶 offset（allow，已限縮讀取範圍）' 0 "$(read_json "$big_file" 1)"
expect '②e 主 session Read 大檔、帶 limit（allow，已限縮讀取範圍）' 0 "$(read_json "$big_file" "" 100)"
expect '②f 主 session Bash cat 一般檔案（非 tasks/*.output，allow——已知盲區：本 gate 不做一般大檔
  偵測，見 large_file_read_guard.py 檔頭）' 0 "$(bash_json "cat ${small_file}")"
expect '②g 主 session Read 不存在的檔案（allow，交給 Read 工具自己報錯）' 0 \
  "$(read_json "$work/nope-does-not-exist.txt")"
expect '②h 非 Read／Bash 工具（Write，allow）' 0 \
  "$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$big_file")"

# ②i 身分不明放行＋stderr（agent_type 存在但不可採信：空字串／非字串型別）——分開驗 stdout（應空）
# 與 exit（應 0）與 stderr（應含註記），不能只看 exit code。
errfile=$(mktemp)
out=$(printf '%s' "$(read_json_agent '""' "$big_file")" | "$bash_bin" "$guard" 2>"$errfile")
got=$?
if [ "$got" -eq 0 ] && [ -z "$out" ] && grep -qF '無法採信' "$errfile"; then
  ok '②i1 身分不明（agent_type 空字串）：allow 且 stderr 含「無法採信」註記'
else
  bad "②i1 應 allow＋stderr 註記（實得 exit ${got}，stdout=${out}，stderr=$(cat "$errfile"))"
fi
out=$(printf '%s' "$(read_json_agent '123' "$big_file")" | "$bash_bin" "$guard" 2>"$errfile")
got=$?
if [ "$got" -eq 0 ] && [ -z "$out" ] && grep -qF '無法採信' "$errfile"; then
  ok '②i2 身分不明（agent_type 為數字非字串）：allow 且 stderr 含「無法採信」註記'
else
  bad "②i2 應 allow＋stderr 註記（實得 exit ${got}，stdout=${out}，stderr=$(cat "$errfile"))"
fi
rm -f "$errfile"

# ============================================================
# ③ fail-closed 三種
# ============================================================
mkdir -p "$work/nopy" "$work/badpy"
cat > "$work/badpy/python3" <<'STUB'
#!/bin/bash
exit 137
STUB
chmod +x "$work/badpy/python3"

expect '③a stdin 是空的（deny，fail-closed）' 2 ''
out=$(printf 'not json' | "$bash_bin" "$guard" 2>/dev/null); got=$?
[ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) ok '③b JSON 壞掉（deny，fail-closed）' ;; *) bad "③b 應 deny：${out}" ;; esac || bad "③b 應 exit 2（實得 ${got}）"

out=$(PATH="$work/nopy:/usr/bin:/bin" printf '%s' "$(read_json "$small_file")" | PATH="$work/nopy" "$bash_bin" "$guard" 2>/dev/null); got=$?
[ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) ok '③c python3 不存在（deny，fail-closed）' ;; *) bad "③c 應 deny：${out}" ;; esac || bad "③c 應 exit 2（實得 ${got}）"

out=$(printf '%s' "$(read_json "$small_file")" | PATH="$work/badpy:/usr/bin:/bin" "$bash_bin" "$guard" 2>/dev/null); got=$?
[ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) ok '③d python3 以異常 rc 結束（deny，fail-closed）' ;; *) bad "③d 應 deny：${out}" ;; esac || bad "③d 應 exit 2（實得 ${got}）"

# ============================================================
# ④ mutation：拿掉 tasks/*.output 判斷（Read 側）→ ①a 正樣本必須變成 allow
# ============================================================
mut=$(mktemp -d)
cp "$guard" "$engine_py" "${root}/scripts/hooks/pretool_engine.py" "$mut/"
anchor_a='if _is_tasks_output(file_path):'
if ! grep -qF "$anchor_a" "$engine_py"; then
  bad "④ mutation 錨點（tasks/*.output 判斷）不在 large_file_read_guard.py，mutation 測試無法成立：${anchor_a}"
else
  sed "s/${anchor_a}/if False:/" "$engine_py" > "$mut/large_file_read_guard.py"
  if ! diff -q "$engine_py" "$mut/large_file_read_guard.py" >/dev/null 2>&1; then
    expect '④ mutant：拿掉 tasks/*.output 判斷後，①a 正樣本變成 allow（原本的 deny 確由該判斷造成）' 0 \
      "$(read_json "$tasks_output")" "$mut/large-file-read-guard.sh"
  else
    bad '④ mutant 與原始檔完全相同（sed 未命中，mutation 測試本身無效）'
  fi
fi
rm -rf "$mut"

# ============================================================
# ⑤ mutation：拿掉大檔＋無 offset/limit 判斷 → ①d 正樣本必須變成 allow
# ============================================================
mut2=$(mktemp -d)
cp "$guard" "$engine_py" "${root}/scripts/hooks/pretool_engine.py" "$mut2/"
anchor_b='if _large_without_window(file_path, ti.get("offset"), ti.get("limit")):'
if ! grep -qF "$anchor_b" "$engine_py"; then
  bad "⑤ mutation 錨點（大檔判斷）不在 large_file_read_guard.py，mutation 測試無法成立：${anchor_b}"
else
  sed "s/${anchor_b}/if False:/" "$engine_py" > "$mut2/large_file_read_guard.py"
  if ! diff -q "$engine_py" "$mut2/large_file_read_guard.py" >/dev/null 2>&1; then
    expect '⑤ mutant：拿掉大檔判斷後，①d 正樣本變成 allow（原本的 deny 確由該判斷造成）' 0 \
      "$(read_json "$big_file")" "$mut2/large-file-read-guard.sh"
  else
    bad '⑤ mutant 與原始檔完全相同（sed 未命中，mutation 測試本身無效）'
  fi
fi
rm -rf "$mut2"

# ============================================================
# ⑥ mutation：拿掉身分判斷（強制 is_main 恆真）→ ②a 負樣本（subagent）必須變成 deny
# ============================================================
mut3=$(mktemp -d)
cp "$guard" "$engine_py" "${root}/scripts/hooks/pretool_engine.py" "$mut3/"
anchor_id='is_main, note = _is_main_session(d)'
if ! grep -qF "$anchor_id" "$engine_py"; then
  bad "⑥ mutation 錨點（身分判斷）不在 large_file_read_guard.py，mutation 測試無法成立：${anchor_id}"
else
  sed "s/${anchor_id}/is_main, note = True, None/" "$engine_py" > "$mut3/large_file_read_guard.py"
  if ! diff -q "$engine_py" "$mut3/large_file_read_guard.py" >/dev/null 2>&1; then
    expect '⑥ mutant：拿掉身分判斷後，subagent Read tasks/*.output 變成 deny（原本的 allow 確由身分判斷造成）' 2 \
      "$(read_json_agent '"ios-dev"' "$tasks_output")" "$mut3/large-file-read-guard.sh"
  else
    bad '⑥ mutant 與原始檔完全相同（sed 未命中，mutation 測試本身無效）'
  fi
fi
rm -rf "$mut3"

# ============================================================
# ⑦ settings.json 接線斷言（只加不刪：既有三條 PreToolUse 仍在）
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
  ok '⑦① settings.json 的 PreToolUse matcher=Bash|Read 有一條呼叫 large-file-read-guard.sh'
else
  bad '⑦① settings.json 找不到 matcher=Bash|Read 呼叫 large-file-read-guard.sh 的 PreToolUse command'
fi
case "$lf_cmd" in
  *'|| exit 2'*) ok '⑦② command 帶 || exit 2（wiring 層 fail-closed）' ;;
  *) bad "⑦② command 沒有 || exit 2（實得：${lf_cmd}）" ;;
esac
if [ -n "$real_jq" ]; then
  old1=$("$real_jq" -r '.hooks.PreToolUse[] | select(.matcher == "Bash|Read|Grep") | .hooks[0].command' "$settings_json" 2>/dev/null)
  old2=$("$real_jq" -r '.hooks.PreToolUse[] | select(.matcher == "Bash|Write|Edit|MultiEdit|NotebookEdit") | .hooks[0].command' "$settings_json" 2>/dev/null)
  old3=$("$real_jq" -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0].command' "$settings_json" 2>/dev/null)
  case "$old1" in *pretool.sh*) ok '⑦③ 既有 Bash|Read|Grep（pretool.sh）條目仍在' ;; *) bad "⑦③ pretool.sh 條目消失（實得：${old1}）" ;; esac
  case "$old2" in *main-checkout-guard.sh*) ok '⑦④ 既有 Bash|Write|Edit|MultiEdit|NotebookEdit（main-checkout-guard.sh）條目仍在' ;; *) bad "⑦④ main-checkout-guard.sh 條目消失（實得：${old2}）" ;; esac
  case "$old3" in *background-bash-guard.sh*) ok '⑦⑤ 既有 Bash（background-bash-guard.sh）條目仍在' ;; *) bad "⑦⑤ background-bash-guard.sh 條目消失（實得：${old3}）" ;; esac
fi

rm -rf "$work"
trap - EXIT

if [ "$fail" -eq 0 ]; then
  echo "✓ large-file-read-guard.sh 自測通過（${n} 組）"
fi
exit "$fail"
