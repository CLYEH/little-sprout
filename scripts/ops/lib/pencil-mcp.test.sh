#!/bin/bash
# scripts/ops/lib/pencil-mcp.test.sh — pencil_mcp_probe 的自測（LS-308）。
# stub `pgrep`（mcp-server 樣式讀 $STUB_MCP_PIDS）、`ps`（`-o ppid=／-o command= -p <pid>` 依 $STUB_PS_DB 的
# 「pid ppid command」表回答）。同一套判定邏輯已被 pen-status.sh／pen-open.sh 各自的 *.test.sh 用整合測試
# 覆蓋過一次；這裡另外對 lib 本身做一次隔離的單元自測（source 後直接呼叫函式、不透過任何一支呼叫端），
# 確保之後任何一邊改壞判定邏輯都能在最靠近源頭的地方先紅，不必等到呼叫端的整合測試才發現。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
lib="${root}/scripts/ops/lib/pencil-mcp.sh"
fail=0
n=0
ok() { echo "✓ $1"; n=$((n + 1)); }
bad() { echo "✗ $1" >&2; fail=1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bin="${work}/bin"; mkdir -p "$bin"
export STUB_MCP_PIDS="${work}/mcp.pids" STUB_PS_DB="${work}/ps.db"

cat > "${bin}/pgrep" <<'STUB'
#!/bin/bash
case "$*" in
  *mcp-server*) [ -s "${STUB_MCP_PIDS:?}" ] && cat "${STUB_MCP_PIDS}" ;;
esac
exit 0
STUB
cat > "${bin}/ps" <<'STUB'
#!/bin/bash
mode=; pid=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) mode=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -f "${STUB_PS_DB:?}" ] || exit 0
row=$(awk -v p="$pid" '$1 == p { $1=""; sub(/^ /, ""); print }' "${STUB_PS_DB}")
[ -n "$row" ] || exit 0
ppid=${row%% *}
cmd=${row#* }
case "$mode" in
  ppid=) printf '%s\n' "$ppid" ;;
  command=) printf '%s\n' "$cmd" ;;
esac
exit 0
STUB
chmod +x "${bin}/pgrep" "${bin}/ps"
export PATH="${bin}:${PATH}"

set_mcp() { printf '%s\n' "$1" > "$STUB_MCP_PIDS"; }
set_mcp_parent() { printf '%s %s -\n' "$1" "$2" >> "$STUB_PS_DB"; printf '%s 1 %s\n' "$2" "$3" >> "$STUB_PS_DB"; }
# set_ps_row <pid> <ppid> <cmd>：LS-309——直接寫一列「這個 pid 自己的 ppid／command」，供組 $PPID 鏈夾具用
# （set_mcp_parent 只夠描述「mcp-server pid → 其父行程」兩層，鏈式測試需要任意長度、任意層的 pid/ppid/cmd）。
set_ps_row() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$STUB_PS_DB"; }
reset() { : > "$STUB_MCP_PIDS"; : > "$STUB_PS_DB"; unset PENCIL_MCP_TOTAL PENCIL_MCP_OWN_PID PENCIL_MCP_OTHER PENCIL_MCP_OWN_INFERRED PENCIL_MCP_START_PID; }

# shellcheck source=pencil-mcp.sh
source "$lib"

# ---- ① 無 mcp-server 行程 → TOTAL=0、OWN 空、OTHER=0 ----
reset
pencil_mcp_probe
if [ "$PENCIL_MCP_TOTAL" -eq 0 ] && [ -z "$PENCIL_MCP_OWN_PID" ] && [ "$PENCIL_MCP_OTHER" -eq 0 ]; then
  ok '① 無 mcp-server 行程 → TOTAL=0、OWN 空、OTHER=0'
else
  bad "① 應全部為零／空（實得 TOTAL=${PENCIL_MCP_TOTAL} OWN=${PENCIL_MCP_OWN_PID} OTHER=${PENCIL_MCP_OTHER}）"
fi

# ---- ② 一支、父行程是活著的 claude → OWN=該 pid、OTHER=0 ----
reset; set_mcp 24097; set_mcp_parent 24097 900 claude
pencil_mcp_probe
if [ "$PENCIL_MCP_TOTAL" -eq 1 ] && [ "$PENCIL_MCP_OWN_PID" = 24097 ] && [ "$PENCIL_MCP_OTHER" -eq 0 ]; then
  ok '② 父行程是活著的 claude → OWN=該 pid、OTHER=0'
else
  bad "② 應 OWN=24097 OTHER=0（實得 TOTAL=${PENCIL_MCP_TOTAL} OWN=${PENCIL_MCP_OWN_PID} OTHER=${PENCIL_MCP_OTHER}）"
fi

# ---- ③ 一支、父行程非 claude → OWN 空、OTHER=1（防退化：不是「有行程就算 OWN」）----
reset; set_mcp 24097; set_mcp_parent 24097 1 launchd
pencil_mcp_probe
if [ "$PENCIL_MCP_TOTAL" -eq 1 ] && [ -z "$PENCIL_MCP_OWN_PID" ] && [ "$PENCIL_MCP_OTHER" -eq 1 ]; then
  ok '③ 父行程非 claude → OWN 空、OTHER=1（不是「有行程就算」）'
else
  bad "③ 應 OWN 空 OTHER=1（實得 TOTAL=${PENCIL_MCP_TOTAL} OWN=${PENCIL_MCP_OWN_PID} OTHER=${PENCIL_MCP_OTHER}）"
fi

# ---- ④ 三支：一支 own＋兩支殘留（父行程各自不同）→ OTHER=2 ----
reset; set_mcp $'24097\n24098\n24099'
set_mcp_parent 24097 900 claude; set_mcp_parent 24098 1 launchd; set_mcp_parent 24099 500 codex
pencil_mcp_probe
if [ "$PENCIL_MCP_TOTAL" -eq 3 ] && [ "$PENCIL_MCP_OWN_PID" = 24097 ] && [ "$PENCIL_MCP_OTHER" -eq 2 ]; then
  ok '④ 三支：一支 own＋兩支殘留 → OTHER=2（殘留數＝其餘 mcp-server 行程數）'
else
  bad "④ 應 OWN=24097 OTHER=2（實得 TOTAL=${PENCIL_MCP_TOTAL} OWN=${PENCIL_MCP_OWN_PID} OTHER=${PENCIL_MCP_OTHER}）"
fi

# ---- ⑤ 父行程 ps 查無資料（ppid 讀不到）→ OWN 空、OTHER=1（不誤判） ----
reset; set_mcp 24097
pencil_mcp_probe
if [ "$PENCIL_MCP_TOTAL" -eq 1 ] && [ -z "$PENCIL_MCP_OWN_PID" ] && [ "$PENCIL_MCP_OTHER" -eq 1 ]; then
  ok '⑤ 父行程資訊讀不到 → OWN 空、OTHER=1（不誤判 own）'
else
  bad "⑤ 應 OWN 空 OTHER=1（實得 TOTAL=${PENCIL_MCP_TOTAL} OWN=${PENCIL_MCP_OWN_PID} OTHER=${PENCIL_MCP_OTHER}）"
fi

# ---- ⑥ 呼叫兩次（重入）：全域變數每次都被覆寫，不會累加上一次的殘留 ----
reset; set_mcp $'24097\n24098'; set_mcp_parent 24097 900 claude; set_mcp_parent 24098 1 launchd
pencil_mcp_probe
reset; set_mcp 24097; set_mcp_parent 24097 900 claude
pencil_mcp_probe
if [ "$PENCIL_MCP_TOTAL" -eq 1 ] && [ "$PENCIL_MCP_OWN_PID" = 24097 ] && [ "$PENCIL_MCP_OTHER" -eq 0 ]; then
  ok '⑥ 重入呼叫：全域變數每次覆寫，不累加上一次的殘留'
else
  bad "⑥ 應 OTHER=0（實得 TOTAL=${PENCIL_MCP_TOTAL} OWN=${PENCIL_MCP_OWN_PID} OTHER=${PENCIL_MCP_OTHER}）"
fi

# ---- ⑦ LS-309：多支 claude 父行程、本 session 非最小 pid——$PPID 鏈精確比對，不再被 pgrep 枚舉順序／
#      「第一支父行程含 claude」這個寬鬆判準誤導。PENCIL_MCP_START_PID=5000 模擬「呼叫端的 $PPID 鏈」：
#      5000（cmd=some-shell）→ ppid 4000（cmd=another-shell）→ ppid 3000（cmd=usr-bin-claude，含 claude）
#      ＝本 session 真正的 claude 主行程 pid=3000。mcp-server 兩支：pid 100（pgrep 枚舉排第一、父行程 6000
#      的 cmd 也含 claude——這正是舊判準會選錯的「另一支 claude 父行程」，但 100 的 ppid≠3000，不是本 session）
#      與 pid 24097（ppid=3000，才是真正屬於本 session 的那支，pgrep 枚舉排第二、且 pid 數值也比 100 大）----
reset
export PENCIL_MCP_START_PID=5000
set_ps_row 5000 4000 some-shell
set_ps_row 4000 3000 another-shell
set_ps_row 3000 1 usr-bin-claude
set_mcp $'100\n24097'
set_ps_row 100 6000 -
set_ps_row 6000 1 claude
set_ps_row 24097 3000 -
pencil_mcp_probe
if [ "$PENCIL_MCP_TOTAL" -eq 2 ] && [ "$PENCIL_MCP_OWN_PID" = 24097 ] && [ "$PENCIL_MCP_OTHER" -eq 1 ] && [ "${PENCIL_MCP_OWN_INFERRED:-0}" -eq 0 ]; then
  ok '⑦ $PPID 鏈精確比對：本 session 的 claude 主行程 pid=3000，只有 ppid=3000 的 mcp-server（24097）算 OWN；另一支父行程也含 claude 字面但 ppid≠3000 的（100）算 OTHER，不被舊「第一支」判準誤選；OWN_INFERRED=0（精確比對，非推定）'
else
  bad "⑦ 應 OWN=24097 OTHER=1 OWN_INFERRED=0（實得 TOTAL=${PENCIL_MCP_TOTAL} OWN=${PENCIL_MCP_OWN_PID} OTHER=${PENCIL_MCP_OTHER} OWN_INFERRED=${PENCIL_MCP_OWN_INFERRED:-未設}）"
fi
unset PENCIL_MCP_START_PID

# ---- ⑧ LS-309：$PPID 鏈找不到本 session的 claude 主行程（鏈斷在 pid 1，非 Claude Code 下執行的情境）→
#      退回 LS-308 舊判準（第一支父行程命令含 claude 的 mcp-server），並標 PENCIL_MCP_OWN_INFERRED=1 ----
reset
export PENCIL_MCP_START_PID=7000
set_ps_row 7000 1 launchd
set_mcp 24097
set_mcp_parent 24097 900 claude
pencil_mcp_probe
if [ "$PENCIL_MCP_TOTAL" -eq 1 ] && [ "$PENCIL_MCP_OWN_PID" = 24097 ] && [ "$PENCIL_MCP_OTHER" -eq 0 ] && [ "${PENCIL_MCP_OWN_INFERRED:-0}" -eq 1 ]; then
  ok '⑧ $PPID 鏈找不到 claude 主行程（鏈斷在 pid 1）→ 退回舊判準（第一支父行程含 claude）並標 OWN_INFERRED=1（LS-309）'
else
  bad "⑧ 應 OWN=24097 OTHER=0 OWN_INFERRED=1（實得 TOTAL=${PENCIL_MCP_TOTAL} OWN=${PENCIL_MCP_OWN_PID} OTHER=${PENCIL_MCP_OTHER} OWN_INFERRED=${PENCIL_MCP_OWN_INFERRED:-未設}）"
fi
unset PENCIL_MCP_START_PID

# ---- ⑨ LS-309：$PPID 鏈超過深度上限（32；防禦性，ps 資料異常成環時不要無限迴圈）→ 視為找不到、退回舊判準 ----
reset
# 起點 pid=2（迴圈條件排除 pid=0／1，那兩個視為鏈終點，不能拿來當起點）接到一條 40 層都查不到 claude 字面的
# 鏈（2→3→…→41，每個 cmd 都是 noise、ppid 依序遞增），驗證深度上限會讓函式提前放棄，不會一路查到系統其他行程。
export PENCIL_MCP_START_PID=2
i=2
while [ "$i" -le 40 ]; do
  set_ps_row "$i" "$((i + 1))" "noise${i}"
  i=$((i + 1))
done
set_ps_row 41 1 noise41
set_mcp 24097
set_mcp_parent 24097 900 claude
pencil_mcp_probe
if [ "$PENCIL_MCP_TOTAL" -eq 1 ] && [ "$PENCIL_MCP_OWN_PID" = 24097 ] && [ "${PENCIL_MCP_OWN_INFERRED:-0}" -eq 1 ]; then
  ok '⑨ $PPID 鏈超過深度上限（40 層皆查不到 claude）→ 視為找不到、退回舊判準並標 OWN_INFERRED=1（防禦性，LS-309）'
else
  bad "⑨ 應 OWN=24097 OWN_INFERRED=1（實得 TOTAL=${PENCIL_MCP_TOTAL} OWN=${PENCIL_MCP_OWN_PID} OWN_INFERRED=${PENCIL_MCP_OWN_INFERRED:-未設}）"
fi
unset PENCIL_MCP_START_PID

if [ "$fail" -ne 0 ]; then
  echo "✗ pencil-mcp 自測失敗" >&2
  exit 1
fi
echo "✓ pencil-mcp 自測通過（${n} 組樣本）"
