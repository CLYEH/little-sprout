#!/bin/bash
# background-bash-guard.sh／background_bash_guard.py 自測（LS-215）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若 (a) run_in_background 判斷、(b) 身分判斷、(c) 命令文字慣用
# 形狀比對任一退化，這裡會紅。同 pretool.test.sh／main-checkout-guard.test.sh 的慣例：純 bash 3.2，
# 不用陣列／${var,,}。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="${root}/scripts/hooks/background-bash-guard.sh"
engine_py="${root}/scripts/hooks/background_bash_guard.py"
fail=0
n=0
ok() { echo "✓ $1"; n=$((n + 1)); }
bad() { echo "✗ $1" >&2; fail=1; }

# ---- payload builders ----
# bash_json <command>：無 agent_type、無 run_in_background（主 session 一般前景命令的形狀）
bash_json() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }
# bash_json_rb <command> <true|false>：無 agent_type、帶 run_in_background
bash_json_rb() { printf '{"tool_name":"Bash","tool_input":{"command":"%s","run_in_background":%s}}' "$1" "$2"; }
# bash_json_agent <agent_type json 值(含引號或裸值)> <command> <true|false>
bash_json_agent() { printf '{"tool_name":"Bash","agent_type":%s,"tool_input":{"command":"%s","run_in_background":%s}}' "$1" "$2" "$3"; }
# bash_json_agent_norb <agent_type json 值> <command>：tool_input 完全沒有 run_in_background 鍵
# （真實最常見形狀——一般前景 Bash 呼叫的 tool_input 本來就不會帶這個鍵；R2 merge-review N8：
# ①c 原本誤用跟 ①c2 完全相同的 payload，兩組其實測的是同一件事，鍵缺席這個形狀反而沒被測到）
bash_json_agent_norb() { printf '{"tool_name":"Bash","agent_type":%s,"tool_input":{"command":"%s"}}' "$1" "$2"; }

# expect <label> <want_exit> <payload>：allow（want=0）驗無 stdout；deny（want=2）驗 stdout 含 deny JSON。
expect() {
  local label=$1 want=$2 payload=$3 out got
  out=$(printf '%s' "$payload" | bash "$guard" 2>/dev/null)
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
# ① 正樣本
# ============================================================
expect '①a 主 session（無 agent_type）背景 promote.sh（allow）' 0 \
  "$(bash_json_rb 'bash scripts/ops/promote.sh development test' true)"
expect '①c ios-dev 前景 git push（tool_input 完全沒有 run_in_background 鍵，allow）' 0 \
  "$(bash_json_agent_norb '"ios-dev"' 'git push -u origin HEAD')"
expect '①c2 ios-dev 前景 git push（run_in_background:false 明寫，allow）' 0 \
  "$(bash_json_agent '"ios-dev"' 'git push -u origin HEAD' false)"

# ①b 身分不明放行＋stderr（agent_type 存在但不可採信：空字串／非字串型別）——分開驗 stdout（應空）
# 與 exit（應 0）與 stderr（應含註記），不能只看 exit code。
errfile=$(mktemp)
out=$(printf '%s' "$(bash_json_agent '""' 'ls -la' true)" | bash "$guard" 2>"$errfile")
got=$?
if [ "$got" -eq 0 ] && [ -z "$out" ] && grep -qF '查不到身分' "$errfile"; then
  ok '①b1 身分不明（agent_type 空字串）：allow 且 stderr 含「查不到身分」註記'
else
  bad "①b1 應 allow＋stderr 註記（實得 exit ${got}，stdout=${out}，stderr=$(cat "$errfile"))"
fi
out=$(printf '%s' "$(bash_json_agent '123' 'ls -la' true)" | bash "$guard" 2>"$errfile")
got=$?
if [ "$got" -eq 0 ] && [ -z "$out" ] && grep -qF '查不到身分' "$errfile"; then
  ok '①b2 身分不明（agent_type 為數字非字串）：allow 且 stderr 含「查不到身分」註記'
else
  bad "①b2 應 allow＋stderr 註記（實得 exit ${got}，stdout=${out}，stderr=$(cat "$errfile"))"
fi
rm -f "$errfile"

# ①d 放行清單四種（xcrun simctl boot／simctl boot 不帶 xcrun／tail -f／caffeinate）——刻意搭配一個
# KEYWORD_RE 會命中的字尾，證明遮蔽邏輯把該片段（含它自己的 `&`）整段拿掉、不留下可與後面 keyword
# 湊對的裸 `&`，而不是「這幾個字根本沒出現在同一條命令」這種弱測試。
expect '①d1 xcrun simctl boot … & 後接 run.sh 字面（allow，遮蔽後無裸 & 可湊對）' 0 \
  "$(bash_json 'xcrun simctl boot ABCD-1234 & bash supabase/tests/run.sh')"
expect '①d2 simctl boot（無 xcrun 前綴）… & 後接 xcodebuild（allow）' 0 \
  "$(bash_json 'simctl boot ABCD-1234 & xcodebuild test -scheme X')"
expect '①d3 tail -f … & 後接 push-gate 字面（allow）' 0 \
  "$(bash_json 'tail -f /tmp/log.txt & bash scripts/gates/push-gate.sh')"
expect '①d4 caffeinate & 後接 .test.sh 字面（allow）' 0 \
  "$(bash_json 'caffeinate & bash scripts/hooks/foo.test.sh')"

# ①e R2（merge-review N1，minor）：引號內的 `&`（URL query string、`sed` 取代字面）不是背景化運算子
# ——reviewer 實測樣本（非假設），修前皆誤 deny，修後應 allow。
expect '①e1 curl URL query string 內的 &（雙引號，allow）' 0 \
  "$(bash_json 'for i in 1 2 3; do curl -s \"https://abc.supabase.co/functions/v1/f?a=1&b=2\"; sleep 5; done')"
expect '①e2 curl URL query string ＋ pipe while（雙引號，allow）' 0 \
  "$(bash_json 'curl -s \"https://abc.supabase.co/a?b=1&c=2\" | while read -r l; do echo \"$l\"; done')"
expect '①e3 gh api query string ＋ until sleep（雙引號，allow）' 0 \
  "$(bash_json 'until gh api \"repos/o/r/actions/runs?branch=main&per_page=1\" | grep -q supabase; do sleep 20; done')"
expect '①e4 sed 取代字面的 &（單引號）＋真正的 run.sh／sleep（allow，keyword 存在也不誤擋）' 0 \
  "$(bash_json "sed -i '' 's/foo/&bar/' x.sh; bash supabase/tests/run.sh; sleep 1")"

# ============================================================
# ② 負樣本
# ============================================================
# (a) run_in_background:true ＋ 身分在名單內——六個身分都要各擋一次（票文列的完整名單）
expect '②a1 ios-dev run_in_background:true（deny）' 2 \
  "$(bash_json_agent '"ios-dev"' 'git push -u origin HEAD' true)"
expect '②a2 qa run_in_background:true（deny）' 2 \
  "$(bash_json_agent '"qa"' 'xcodebuild test' true)"
expect '②a3 merge-reviewer run_in_background:true（deny）' 2 \
  "$(bash_json_agent '"merge-reviewer"' 'xcodebuild test' true)"
expect '②a4 dead-code-sweeper run_in_background:true（deny）' 2 \
  "$(bash_json_agent '"dead-code-sweeper"' 'git grep -n foo' true)"
expect '②a5 ui-designer run_in_background:true（deny）' 2 \
  "$(bash_json_agent '"ui-designer"' 'sleep 60' true)"
expect '②a6 visual-reviewer run_in_background:true（deny）' 2 \
  "$(bash_json_agent '"visual-reviewer"' 'sleep 60' true)"
# 對照：已知但不在名單內的 subagent（如 Explore／general-purpose）不受 (a) 影響
expect '②a-對照 Explore run_in_background:true（allow，不在名單）' 0 \
  "$(bash_json_agent '"Explore"' 'ls -la' true)"
expect '②a-對照 general-purpose run_in_background:true（allow，不在名單）' 0 \
  "$(bash_json_agent '"general-purpose"' 'ls -la' true)"

# (b) 命令文字「背景化再等」慣用形狀（四種）——與身分無關，這裡用「無 agent_type」代表任何呼叫者
# 皆擋，且各搭配一個 KEYWORD_RE 字面
expect '②b1 nohup … & ＋ run.sh（deny）' 2 \
  "$(bash_json 'nohup bash supabase/tests/run.sh > /tmp/o.log 2>&1 &')"
expect '②b2 (…) & subshell ＋ git push（deny）' 2 \
  "$(bash_json '(git push origin main) &')"
expect '②b3 … & 後接 wait ＋ xcodebuild（deny）' 2 \
  "$(bash_json 'xcodebuild test -scheme X > /tmp/o.log 2>&1 &\nwait')"
expect '②b4 … & 後接 sleep 輪詢 ＋ push-gate（deny）' 2 \
  "$(bash_json 'bash scripts/gates/push-gate.sh > /tmp/o.log 2>&1 & sleep 30; cat /tmp/o.log')"
expect '②b5 … & 後接 while 輪詢 ＋ supabase（deny）' 2 \
  "$(bash_json 'bash scripts/ops/supabase-lock.sh -- supabase db reset & while true; do sleep 5; done')"
expect '②b6 … & 後接 until 輪詢 ＋ .test.sh（deny）' 2 \
  "$(bash_json 'bash foo.test.sh & until false; do sleep 1; done')"
# 對照：單純背景化、沒有 wait/sleep/while/until 跟進，即使含 keyword 也不算（規則描述的是
# 「背景化再等」，不是「背景化」本身——見票文（b)）
expect '②b-對照 純背景化 run.sh 無輪詢跟進（allow）' 0 \
  "$(bash_json 'bash supabase/tests/run.sh &')"
# 對照：慣用形狀存在但沒有任何 KEYWORD_RE 字面（allow）
expect '②b-對照 nohup … & 但無 keyword（allow）' 0 \
  "$(bash_json 'nohup echo hi > /tmp/o.log 2>&1 &')"

# 非 Bash 工具不受影響
expect '③ 非 Bash 工具（Write，allow）' 0 '{"tool_name":"Write","agent_type":"ios-dev","tool_input":{"file_path":"foo.txt"}}'

# ============================================================
# ③ fail-closed 三種
# ============================================================
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
bash_bin=$(bash -c 'type -P bash' 2>/dev/null || echo /bin/bash)
real_jq=$(bash -c 'type -P jq' 2>/dev/null || true)

mkdir -p "$work/nopy" "$work/badpy"
cat > "$work/badpy/python3" <<'STUB'
#!/bin/bash
exit 137
STUB
chmod +x "$work/badpy/python3"

out=$(printf '%s' "$(bash_json 'echo hi')" | env PATH="$work/nopy" "$bash_bin" "$guard" 2>&1); got=$?
if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
  ok '③ PATH 缺 python3（deny）'
else
  bad "③ PATH 缺 python3 應 deny（實得 exit ${got}：${out}）"
fi

out=$(printf '%s' "$(bash_json 'echo hi')" | env PATH="$work/badpy" "$bash_bin" "$guard" 2>&1); got=$?
if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
  ok '③ python3 以非預期 rc 結束（deny，rc 不是 0/2 一律 fail-closed）'
else
  bad "③ python3 異常應 deny（實得 exit ${got}：${out}）"
fi

missing_py_work=$(mktemp -d)
cp "$guard" "$missing_py_work/background-bash-guard.sh"
# 故意不拷貝 background_bash_guard.py，模擬部署時漏了這個檔案
out=$(printf '%s' "$(bash_json 'echo hi')" | "$bash_bin" "$missing_py_work/background-bash-guard.sh" 2>&1); got=$?
if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
  ok '③ background_bash_guard.py 檔案不存在（deny）'
else
  bad "③ 引擎檔缺席應 deny（實得 exit ${got}：${out}）"
fi
rm -rf "$missing_py_work"

# 空 stdin／壞 JSON（同 pretool.sh／main-checkout-guard.sh 慣例，順手驗過）
expect 'fail-closed：空 stdin（deny）' 2 ''
expect 'fail-closed：JSON 語法壞掉（deny）' 2 '{"tool_name":'
expect 'fail-closed：JSON 頂層不是物件（deny）' 2 '[1,2,3]'

# ============================================================
# ④ settings.json 接線斷言
# ============================================================
settings_json="${root}/.claude/settings.json"
if [ -n "$real_jq" ]; then
  bg_cmd=$("$real_jq" -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.type == "command") | .command' "$settings_json" 2>/dev/null | grep -F 'background-bash-guard.sh' || true)
else
  bg_cmd=$(python3 -c "
import json
d = json.load(open('$settings_json'))
for entry in d.get('hooks', {}).get('PreToolUse', []):
    if entry.get('matcher') == 'Bash':
        for h in entry.get('hooks', []):
            if h.get('type') == 'command' and 'background-bash-guard.sh' in h.get('command', ''):
                print(h['command'])
" 2>/dev/null)
fi
if [ -n "$bg_cmd" ]; then
  ok '④① settings.json 的 PreToolUse matcher=Bash 有一條呼叫 background-bash-guard.sh'
else
  bad '④① settings.json 找不到 matcher=Bash 呼叫 background-bash-guard.sh 的 PreToolUse command'
fi
case "$bg_cmd" in
  *'|| exit 2'*) ok '④② command 帶 || exit 2（wiring 層 fail-closed）' ;;
  *) bad "④② command 沒有 || exit 2（實得：${bg_cmd}）" ;;
esac
# 既有 pretool.sh／main-checkout-guard.sh 兩條 PreToolUse 仍在（只加不刪）
if [ -n "$real_jq" ]; then
  old1=$("$real_jq" -r '.hooks.PreToolUse[] | select(.matcher == "Bash|Read|Grep") | .hooks[0].command' "$settings_json" 2>/dev/null)
  old2=$("$real_jq" -r '.hooks.PreToolUse[] | select(.matcher == "Bash|Write|Edit|MultiEdit|NotebookEdit") | .hooks[0].command' "$settings_json" 2>/dev/null)
  case "$old1" in *pretool.sh*) ok '④③ 既有 Bash|Read|Grep（pretool.sh）條目仍在' ;; *) bad "④③ pretool.sh 條目消失（實得：${old1}）" ;; esac
  case "$old2" in *main-checkout-guard.sh*) ok '④④ 既有 Bash|Write|Edit|MultiEdit|NotebookEdit（main-checkout-guard.sh）條目仍在' ;; *) bad "④④ main-checkout-guard.sh 條目消失（實得：${old2}）" ;; esac
fi

# ============================================================
# ⑤ mutation：拿掉 run_in_background 判斷 → ②a1 負樣本必須變綠
# ============================================================
mut=$(mktemp -d)
cp "$guard" "$engine_py" "${root}/scripts/hooks/pretool_engine.py" "$mut/"
anchor_rb='ti.get("run_in_background") is True and identity in BLOCKED_AGENTS:'
if ! grep -qF "$anchor_rb" "$engine_py"; then
  bad "⑤ mutation 錨點（run_in_background）不在 background_bash_guard.py，mutation 測試無法成立：${anchor_rb}"
else
  sed "s/$(printf '%s' "$anchor_rb" | sed 's/[.[\*^$]/\\&/g')/False and identity in BLOCKED_AGENTS:/" "$engine_py" > "$mut/background_bash_guard.py"
  if ! diff -q "$engine_py" "$mut/background_bash_guard.py" >/dev/null 2>&1; then
    out=$(printf '%s' "$(bash_json_agent '"ios-dev"' 'git push -u origin HEAD' true)" | "$bash_bin" "$mut/background-bash-guard.sh" 2>/dev/null); got=$?
    if [ "$got" -eq 0 ] && [ -z "$out" ]; then
      ok '⑤ mutant：拿掉 run_in_background 判斷後，ios-dev run_in_background:true 變成放行（原本的 deny 確由該判斷造成）'
    else
      bad "⑤ mutant 應放行 ios-dev run_in_background:true（實得 exit ${got}：${out}）——判斷不是靠錨點行？"
    fi
  else
    bad '⑤ mutant 與原始檔完全相同（sed 未命中，mutation 測試本身無效）'
  fi
fi
rm -rf "$mut"

# ============================================================
# ⑥ mutation：拿掉身分判斷 → ①a 主 session 樣本必須變紅
# ============================================================
mut2=$(mktemp -d)
cp "$guard" "$engine_py" "${root}/scripts/hooks/pretool_engine.py" "$mut2/"
anchor_id='identity in BLOCKED_AGENTS:'
if ! grep -qF "$anchor_id" "$engine_py"; then
  bad "⑥ mutation 錨點（身分判斷）不在 background_bash_guard.py，mutation 測試無法成立：${anchor_id}"
else
  sed "s/$(printf '%s' "$anchor_id" | sed 's/[.[\*^$]/\\&/g')/True:/" "$engine_py" > "$mut2/background_bash_guard.py"
  if ! diff -q "$engine_py" "$mut2/background_bash_guard.py" >/dev/null 2>&1; then
    out=$(printf '%s' "$(bash_json_rb 'bash scripts/ops/promote.sh development test' true)" | "$bash_bin" "$mut2/background-bash-guard.sh" 2>/dev/null); got=$?
    if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
      ok '⑥ mutant：拿掉身分判斷後，主 session（無 agent_type）背景 promote 變成 deny（原本的 allow 確由該判斷造成）'
    else
      bad "⑥ mutant 應 deny 主 session 背景 promote（實得 exit ${got}：${out}）——判斷不是靠錨點行？"
    fi
  else
    bad '⑥ mutant 與原始檔完全相同（sed 未命中，mutation 測試本身無效）'
  fi
fi
rm -rf "$mut2"

# ============================================================
# ⑦ R2（merge-review N1）mutation：拿掉引號感知遮蔽（改回直接對原始字面判斷）→ ①e 四組正樣本
# 必須翻紅（deny）——證明 allow 是 _mask_quoted 造成的，不是巧合。
# ============================================================
mut3=$(mktemp -d)
cp "$guard" "$engine_py" "${root}/scripts/hooks/pretool_engine.py" "$mut3/"
anchor_mask='unquoted = _mask_quoted(stripped)'
if ! grep -qF "$anchor_mask" "$engine_py"; then
  bad "⑦ mutation 錨點（引號感知遮蔽呼叫點）不在 background_bash_guard.py，mutation 測試無法成立：${anchor_mask}"
else
  sed "s/$(printf '%s' "$anchor_mask" | sed 's/[.[\*^$]/\\&/g')/unquoted = stripped/" "$engine_py" > "$mut3/background_bash_guard.py"
  if ! diff -q "$engine_py" "$mut3/background_bash_guard.py" >/dev/null 2>&1; then
    all_flipped=1
    for payload in \
      "$(bash_json 'for i in 1 2 3; do curl -s \"https://abc.supabase.co/functions/v1/f?a=1&b=2\"; sleep 5; done')" \
      "$(bash_json 'curl -s \"https://abc.supabase.co/a?b=1&c=2\" | while read -r l; do echo \"$l\"; done')" \
      "$(bash_json 'until gh api \"repos/o/r/actions/runs?branch=main&per_page=1\" | grep -q supabase; do sleep 20; done')" \
      "$(bash_json "sed -i '' 's/foo/&bar/' x.sh; bash supabase/tests/run.sh; sleep 1")"
    do
      out=$(printf '%s' "$payload" | "$bash_bin" "$mut3/background-bash-guard.sh" 2>/dev/null); got=$?
      if [ "$got" -ne 2 ] || ! case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
        all_flipped=0
        bad "⑦ mutant 應把「①e」正樣本翻成 deny（實得 exit ${got}：${out}）——判斷不是靠 _mask_quoted？"
      fi
    done
    if [ "$all_flipped" -eq 1 ]; then
      ok '⑦ mutant：拿掉引號感知遮蔽後，①e 四組正樣本全部變成 deny（原本的 allow 確由 _mask_quoted 造成）'
    fi
  else
    bad '⑦ mutant 與原始檔完全相同（sed 未命中，mutation 測試本身無效）'
  fi
fi
rm -rf "$mut3"

rm -rf "$work"
trap - EXIT

if [ "$fail" -eq 0 ]; then
  echo "✓ background-bash-guard.sh 自測通過（${n} 組）"
fi
exit "$fail"
