#!/bin/bash
# fork-guard.sh／fork_guard.py 自測（LS-254）。CI rules job 每個 PR 都跑。「前饋必有反饋」對 gate 本身
# 也適用：若 (a) 身分判斷（agent_id）、(b) subagent_type 比對、(c) fail-open 極性任一退化，這裡會紅。
# 同 large-file-read-guard.test.sh 慣例：純 bash 3.2，不用陣列／${var,,}。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="${root}/scripts/hooks/fork-guard.sh"
engine_py="${root}/scripts/hooks/fork_guard.py"
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

# ---- payload builders ----
# agent_json <subagent_type>：無身分欄位（主 session）
agent_json() {
  printf '{"tool_name":"Agent","tool_input":{"subagent_type":"%s","prompt":"讀票文回結論","description":"研究"}}' "$1"
}
# agent_json_agent_id <agent_id json 值> <subagent_type>：有 agent_id、無 agent_type
agent_json_agent_id() {
  printf '{"tool_name":"Agent","agent_id":%s,"tool_input":{"subagent_type":"%s","prompt":"讀票文回結論","description":"研究"}}' "$1" "$2"
}
# agent_json_agent_type <agent_type json 值> <subagent_type>：有 agent_type、無 agent_id（--agent 啟動的主 session）
agent_json_agent_type() {
  printf '{"tool_name":"Agent","agent_type":%s,"tool_input":{"subagent_type":"%s","prompt":"x","description":"y"}}' "$1" "$2"
}
# agent_json_both <agent_id json 值> <agent_type json 值> <subagent_type>：兩者皆有（正常 subagent）
agent_json_both() {
  printf '{"tool_name":"Agent","agent_id":%s,"agent_type":%s,"tool_input":{"subagent_type":"%s","prompt":"x","description":"y"}}' "$1" "$2" "$3"
}

# expect <label> <want_exit> <payload> [guard_path]：allow（want=0）驗無 stdout；deny（want=2）驗 stdout 含
# deny JSON 且 stderr 含「禁派 fork」一行。guard_path 預設 $guard，mutation 段落改指向 mutant 目錄下的 wrapper。
expect() {
  local label=$1 want=$2 payload=$3 gp=${4:-$guard} out got errfile
  errfile=$(mktemp)
  out=$(printf '%s' "$payload" | "$bash_bin" "$gp" 2>"$errfile")
  got=$?
  if [ "$got" -ne "$want" ]; then
    bad "${label}（期望 exit ${want}，實得 ${got}；stdout：${out}；stderr：$(cat "$errfile")）"
    rm -f "$errfile"; return
  fi
  if [ "$want" -eq 0 ]; then
    if [ -n "$out" ]; then
      bad "${label}（allow 應無 stdout，實得：${out}）"
      rm -f "$errfile"; return
    fi
  else
    case "$out" in
      *'"permissionDecision":"deny"'*'LS-254：worker agent 禁派 fork'*) ;;
      *) bad "${label}（exit=${want} 但 stdout 缺 deny JSON／LS-254 理由：${out}）"; rm -f "$errfile"; return ;;
    esac
    if ! grep -qF 'LS-254：worker agent 禁派 fork' "$errfile"; then
      bad "${label}（deny 時 stderr 應含一行「LS-254：worker agent 禁派 fork」，實得：$(cat "$errfile")）"
      rm -f "$errfile"; return
    fi
    if ! grep -qF 'Explore' "$errfile"; then
      bad "${label}（deny 訊息應指向替代方案 Explore，實得：$(cat "$errfile")）"
      rm -f "$errfile"; return
    fi
  fi
  rm -f "$errfile"
  ok "${label}"
}

# expect_open <label> <payload> <stderr 必含> [env PATH]：fail-open——exit 0、無 stdout、stderr 含指定字樣
expect_open() {
  local label=$1 payload=$2 must=$3 path_override=${4:-} out got errfile
  errfile=$(mktemp)
  if [ -n "$path_override" ]; then
    out=$(printf '%s' "$payload" | PATH="$path_override" "$bash_bin" "$guard" 2>"$errfile")
  else
    out=$(printf '%s' "$payload" | "$bash_bin" "$guard" 2>"$errfile")
  fi
  got=$?
  if [ "$got" -eq 0 ] && [ -z "$out" ] && grep -qF -- "$must" "$errfile"; then
    ok "${label}"
  else
    bad "${label}（應 exit 0、無 stdout、stderr 含「${must}」；實得 exit ${got}，stdout=${out}，stderr=$(cat "$errfile")）"
  fi
  rm -f "$errfile"
}

# ============================================================
# ① 四格（票文驗收）：主 session／subagent × fork／Explore
# ============================================================
expect '①a 主 session × fork（allow——orchestrator 自己的 fork 不受影響）' 0 "$(agent_json fork)"
expect '①b 主 session × Explore（allow）' 0 "$(agent_json Explore)"
expect '①c subagent × fork（deny，stdout deny JSON＋stderr 一行替代方案）' 2 "$(agent_json_agent_id '"agent-1"' fork)"
expect '①d subagent × Explore（allow）' 0 "$(agent_json_agent_id '"agent-1"' Explore)"

# ============================================================
# ② 壞 JSON 與其他 fail-open（票文：解析失敗 exit 0 並 stderr 註明）
# ============================================================
expect_open '②a JSON 壞掉（allow，stderr 註明 fail-open）' 'not json' 'fail-open'
expect_open '②b stdin 是空的（allow，stderr 註明 fail-open）' '' 'fail-open'
expect_open '②c 頂層不是物件（allow，stderr 註明 fail-open）' '[1,2]' 'fail-open'
mkdir -p "$work/nopy" "$work/badpy"
printf '#!/bin/bash\nexit 137\n' > "$work/badpy/python3"
chmod +x "$work/badpy/python3"
expect_open '②d python3 不存在（allow，stderr 註明 fail-open）' "$(agent_json_agent_id '"agent-1"' fork)" 'python3 不存在' "$work/nopy"
expect_open '②e python3 以異常 rc 結束（allow，stderr 註明 fail-open）' "$(agent_json_agent_id '"agent-1"' fork)" '執行異常' "$work/badpy:/usr/bin:/bin"

# ============================================================
# ③ 身分判準補充（agent_id 才是判準，不是 agent_type；同 large-file-read-guard R2 M2）
# ============================================================
expect '③a 有 agent_type 無 agent_id × fork（allow——--agent 啟動的主 session）' 0 \
  "$(agent_json_agent_type '"general-purpose"' fork)"
expect '③b agent_id＋agent_type 皆有 × fork（deny——正常 subagent 呼叫）' 2 \
  "$(agent_json_both '"agent-1"' '"ui-designer"' fork)"
expect '③c subagent × general-purpose（allow——只擋字面 fork，寫檔與否是規約層）' 0 \
  "$(agent_json_agent_id '"agent-1"' general-purpose)"
expect '③d subagent × 具名 agent ios-dev（allow）' 0 "$(agent_json_agent_id '"agent-1"' ios-dev)"
expect_open '③e 身分不明（agent_id 空字串）× fork（allow＋stderr 無法採信）' \
  "$(agent_json_agent_id '""' fork)" '無法採信'
expect_open '③f 身分不明（agent_id 為數字非字串）× fork（allow＋stderr 無法採信）' \
  "$(agent_json_agent_id '123' fork)" '無法採信'
expect '③g subagent、tool_input 缺 subagent_type（allow）' 0 \
  '{"tool_name":"Agent","agent_id":"agent-1","tool_input":{"prompt":"x"}}'
expect '③h subagent、非 Agent 工具（Bash，allow——matcher 只掛 Agent，引擎雙保險）' 0 \
  '{"tool_name":"Bash","agent_id":"agent-1","tool_input":{"subagent_type":"fork","command":"ls"}}'
expect '③i subagent × "Fork"（大小寫不同，allow——只認字面 fork；Agent 工具的 subagent_type 本就大小寫敏感）' 0 \
  "$(agent_json_agent_id '"agent-1"' Fork)"

# ============================================================
# ④ mutation：兩組，證明關鍵判斷確實是造成 allow/deny 的原因
# ============================================================
# ④a：拿掉身分判斷（一律視為 subagent）→ ①a（主 session × fork，應 allow）翻成 deny
mut=$(mktemp -d)
cp "$guard" "$engine_py" "$mut/"
anchor=$(esc 'if identity != "subagent":')
if ! grep -qF 'if identity != "subagent":' "$engine_py"; then
  bad "④a mutation 錨點（身分判斷）不在 fork_guard.py"
else
  sed "s/${anchor}/if False:/" "$engine_py" > "$mut/fork_guard.py"
  if ! diff -q "$engine_py" "$mut/fork_guard.py" >/dev/null 2>&1; then
    expect '④a mutant：拿掉身分判斷後，①a（主 session × fork）變成 deny（原本的 allow 確由該判斷造成）' 2 \
      "$(agent_json fork)" "$mut/fork-guard.sh"
  else
    bad '④a mutant 與原始檔完全相同（sed 未命中，mutation 測試本身無效）'
  fi
fi
rm -rf "$mut"

# ④b：拿掉 subagent_type 比對（一律視為 fork）→ ①d（subagent × Explore，應 allow）翻成 deny
mut2=$(mktemp -d)
cp "$guard" "$engine_py" "$mut2/"
anchor2=$(esc 'if ti.get("subagent_type") == "fork":')
if ! grep -qF 'if ti.get("subagent_type") == "fork":' "$engine_py"; then
  bad "④b mutation 錨點（subagent_type 比對）不在 fork_guard.py"
else
  sed "s/${anchor2}/if True:/" "$engine_py" > "$mut2/fork_guard.py"
  if ! diff -q "$engine_py" "$mut2/fork_guard.py" >/dev/null 2>&1; then
    expect '④b mutant：拿掉 subagent_type 比對後，①d（subagent × Explore）變成 deny（原本的 allow 確由該判斷造成）' 2 \
      "$(agent_json_agent_id '"agent-1"' Explore)" "$mut2/fork-guard.sh"
  else
    bad '④b mutant 與原始檔完全相同（sed 未命中，mutation 測試本身無效）'
  fi
fi
rm -rf "$mut2"

# ============================================================
# ⑤ settings.json 接線斷言（只加不刪：既有四條 PreToolUse 仍在；本條不接 || exit 2）
# ============================================================
settings_json="${root}/.claude/settings.json"
if [ -n "$real_jq" ]; then
  fg_cmd=$("$real_jq" -r '.hooks.PreToolUse[] | select(.matcher == "Agent") | .hooks[] | select(.type == "command") | .command' "$settings_json" 2>/dev/null | grep -F 'fork-guard.sh' || true)
else
  fg_cmd=$(python3 -c "
import json
d = json.load(open('$settings_json'))
for entry in d.get('hooks', {}).get('PreToolUse', []):
    if entry.get('matcher') == 'Agent':
        for h in entry.get('hooks', []):
            if h.get('type') == 'command' and 'fork-guard.sh' in h.get('command', ''):
                print(h['command'])
" 2>/dev/null)
fi
if [ -n "$fg_cmd" ]; then
  ok '⑤① settings.json 的 PreToolUse matcher=Agent 有一條呼叫 fork-guard.sh'
else
  bad '⑤① settings.json 找不到 matcher=Agent 呼叫 fork-guard.sh 的 PreToolUse command'
fi
case "$fg_cmd" in
  *'|| exit 2'*) bad "⑤② fork-guard 的 command 不應接 || exit 2（fail-open 極性；實得：${fg_cmd}）" ;;
  *) ok '⑤② command 不接 || exit 2（wiring 層同樣 fail-open）' ;;
esac
if [ -n "$real_jq" ]; then
  old1=$("$real_jq" -r '.hooks.PreToolUse[] | select(.matcher == "Bash|Read|Grep") | .hooks[0].command' "$settings_json" 2>/dev/null)
  old2=$("$real_jq" -r '.hooks.PreToolUse[] | select(.matcher == "Bash|Write|Edit|MultiEdit|NotebookEdit") | .hooks[0].command' "$settings_json" 2>/dev/null)
  old3=$("$real_jq" -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0].command' "$settings_json" 2>/dev/null)
  old4=$("$real_jq" -r '.hooks.PreToolUse[] | select(.matcher == "Bash|Read") | .hooks[0].command' "$settings_json" 2>/dev/null)
  case "$old1" in *pretool.sh*) ok '⑤③ 既有 Bash|Read|Grep（pretool.sh）條目仍在' ;; *) bad "⑤③ pretool.sh 條目消失（實得：${old1}）" ;; esac
  case "$old2" in *main-checkout-guard.sh*) ok '⑤④ 既有 Bash|Write|Edit|MultiEdit|NotebookEdit（main-checkout-guard.sh）條目仍在' ;; *) bad "⑤④ main-checkout-guard.sh 條目消失（實得：${old2}）" ;; esac
  case "$old3" in *background-bash-guard.sh*) ok '⑤⑤ 既有 Bash（background-bash-guard.sh）條目仍在' ;; *) bad "⑤⑤ background-bash-guard.sh 條目消失（實得：${old3}）" ;; esac
  case "$old4" in *large-file-read-guard.sh*) ok '⑤⑥ 既有 Bash|Read（large-file-read-guard.sh）條目仍在' ;; *) bad "⑤⑥ large-file-read-guard.sh 條目消失（實得：${old4}）" ;; esac
else
  # LS-256（LS-96 池項 a7e9e910 i2）：jq 缺席不再靜默少跑——印 SKIP＋計數，收工總結帶出來
  echo "SKIP 4 組（無 jq）：⑤③–⑤⑥ settings.json 既有四條 PreToolUse 接線斷言未跑"
  skipped=$((skipped + 4))
fi

rm -rf "$work"
trap - EXIT

if [ "$fail" -eq 0 ]; then
  if [ "$skipped" -gt 0 ]; then
    echo "✓ fork-guard.sh 自測通過（${n} 組；SKIP ${skipped} 組（無 jq））"
  else
    echo "✓ fork-guard.sh 自測通過（${n} 組）"
  fi
fi
exit "$fail"
