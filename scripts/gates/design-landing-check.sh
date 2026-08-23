#!/usr/bin/env bash
# LS-26：.pen 設計稿落地檢查。
# Pencil MCP 沒有 save 工具，編輯只存在 app 記憶體；落地靠複製 autosave 備份
# （~/.pencil/backup/<sha1 of "file://<絕對路徑>">，無副檔名）。本檢查擋
# 「沒真的落地」：0 bytes／壞 JSON／空結構。用法：design-landing-check.sh <path.pen>
set -euo pipefail

f="${1:-}"
if [ -z "${f}" ] || [ ! -f "${f}" ]; then
  echo "✗ design-landing gate：找不到檔案「${f:-<未給路徑>}」" >&2
  exit 1
fi

python3 - "${f}" <<'PY'
import json, os, sys
p = sys.argv[1]
size = os.path.getsize(p)
if size == 0:
    print(f"✗ design-landing gate：{p} 是 0 bytes——編輯沒有落地", file=sys.stderr); sys.exit(1)
try:
    with open(p) as fh:
        d = json.load(fh)
except Exception as e:
    print(f"✗ design-landing gate：{p} 不是有效 JSON（{type(e).__name__}）——落地檔可能損壞", file=sys.stderr); sys.exit(1)
ver = d.get("version")
kids = d.get("children") or []
def cnt(n):
    return 1 + sum(cnt(c) for c in n.get("children", [])) if isinstance(n, dict) else 0
nodes = sum(cnt(c) for c in kids)
if not ver or nodes < 1:
    print(f"✗ design-landing gate：{p} 結構空（version={ver}，nodes={nodes}）", file=sys.stderr); sys.exit(1)
themes = list((d.get("themes") or {}).keys())
print(f"✓ design-landing gate 通過：version={ver}，nodes={nodes}，themes={themes}，{size} bytes")
PY
