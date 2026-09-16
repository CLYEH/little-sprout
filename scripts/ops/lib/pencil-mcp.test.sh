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
reset() { : > "$STUB_MCP_PIDS"; : > "$STUB_PS_DB"; unset PENCIL_MCP_TOTAL PENCIL_MCP_OWN_PID PENCIL_MCP_OTHER; }

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

if [ "$fail" -ne 0 ]; then
  echo "✗ pencil-mcp 自測失敗" >&2
  exit 1
fi
echo "✓ pencil-mcp 自測通過（${n} 組樣本）"
