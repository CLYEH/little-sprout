#!/bin/bash
# LS-26：.pen 設計稿落地檢查。
# Pencil MCP 沒有 save 工具，編輯只存在 app 記憶體；落地靠複製 autosave 備份
# （~/.pencil/backup/<sha1 of "file://<絕對路徑>">，無副檔名）。本檢查擋
# 「沒真的落地」：0 bytes／壞 JSON／空結構；配 --expect-nodes 可再擋「落地檔
# 比記憶體舊」（節點數與畫布不符）。
# 用法：design-landing-check.sh <path.pen> [--expect-nodes N]
set -euo pipefail

f="${1:-}"
expect="${3:-}"
if [ "${2:-}" = "--expect-nodes" ] && [ -z "${expect}" ]; then
  echo "✗ design-landing gate：--expect-nodes 需要數值" >&2
  exit 1
fi
if [ -z "${f}" ] || [ ! -f "${f}" ]; then
  echo "✗ design-landing gate：找不到檔案「${f:-<未給路徑>}」" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "✗ design-landing gate：需要 python3 解析 .pen 結構（macOS 內建；PATH 異常請修復）" >&2
  exit 1
fi

PYTHONIOENCODING=utf-8 python3 - "${f}" "${expect}" <<'PY'
import json, os, sys
p, expect = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")
size = os.path.getsize(p)
if size == 0:
    print(f"✗ design-landing gate：{p} 是 0 bytes——編輯沒有落地", file=sys.stderr); sys.exit(1)
try:
    with open(p, encoding="utf-8") as fh:
        d = json.load(fh)
except json.JSONDecodeError as e:
    print(f"✗ design-landing gate：{p} 不是有效 JSON（{e.msg} @ line {e.lineno}）——落地檔損壞，回收工程序步驟 2 重新複製", file=sys.stderr); sys.exit(1)
except (OSError, UnicodeDecodeError) as e:
    print(f"✗ design-landing gate：{p} 讀取失敗（{type(e).__name__}: {e}）——這不是落地問題，先修檔案權限／編碼", file=sys.stderr); sys.exit(1)
if not isinstance(d, dict):
    print(f"✗ design-landing gate：{p} 頂層不是物件（{type(d).__name__}）——不是 .pen 格式", file=sys.stderr); sys.exit(1)
ver = d.get("version")
stack = list(d.get("children") or [])
nodes = 0
while stack:
    n = stack.pop()
    if isinstance(n, dict):
        nodes += 1
        stack.extend(n.get("children") or [])
if not ver or nodes < 1:
    print(f"✗ design-landing gate：{p} 結構空（version={ver}，nodes={nodes}）", file=sys.stderr); sys.exit(1)
if expect:
    if nodes != int(expect):
        print(f"✗ design-landing gate：{p} 節點數 {nodes} ≠ 畫布預期 {expect}——落地檔比記憶體舊（autosave 未含最新編輯），回收工程序步驟 2", file=sys.stderr); sys.exit(1)
themes = list((d.get("themes") or {}).keys())
extra = f"，節點數與畫布一致（{expect}）" if expect else ""
print(f"✓ design-landing gate 通過：version={ver}，nodes={nodes}，themes={themes}，{size} bytes{extra}")
PY
