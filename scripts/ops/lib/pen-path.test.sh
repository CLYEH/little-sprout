#!/bin/bash
# lib/pen-path.sh 的自測（LS-480）：pen_resolve_path 的預設／絕對／相對／symlink／負案，與 pen_backup_path 的 sha1 公式。
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail=0
n=0
ok() { echo "✓ $1"; n=$((n + 1)); }
bad() { echo "✗ $1" >&2; fail=1; }

# shellcheck source=pen-path.sh
source "${root}/scripts/ops/lib/pen-path.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
wt="$(cd "$work" && mkdir -p wt/design wt/docs/design-proposals/s && cd wt && pwd -P)"
printf '%s' '{}' > "${wt}/design/littlesprout.pen"
printf '%s' '{}' > "${wt}/docs/design-proposals/s/p.pen"
printf '%s' 'x' > "${wt}/docs/design-proposals/s/notes.txt"

pen_resolve_path t "$wt" ""; rc=$?
if [ "$rc" -eq 0 ] && [ "$PEN_RESOLVED_PATH" = "${wt}/design/littlesprout.pen" ]; then ok '省略 --pen → <root>/design/littlesprout.pen（預設不變）'; else bad "省略應回主稿（rc=${rc} 得「${PEN_RESOLVED_PATH}」）"; fi

pen_resolve_path t "$wt"; rc=$?
if [ "$rc" -eq 0 ] && [ "$PEN_RESOLVED_PATH" = "${wt}/design/littlesprout.pen" ]; then ok '少傳第三參數等同省略'; else bad "少傳參數應回主稿（rc=${rc}）"; fi

pen_resolve_path t "$wt" docs/design-proposals/s/p.pen; rc=$?
if [ "$rc" -eq 0 ] && [ "$PEN_RESOLVED_PATH" = "${wt}/docs/design-proposals/s/p.pen" ]; then ok '相對 root 的路徑 → 絕對路徑'; else bad "相對路徑解析錯（rc=${rc} 得「${PEN_RESOLVED_PATH}」）"; fi

pen_resolve_path t "$wt" "${wt}/docs/design-proposals/s/p.pen"; rc=$?
if [ "$rc" -eq 0 ] && [ "$PEN_RESOLVED_PATH" = "${wt}/docs/design-proposals/s/p.pen" ]; then ok '絕對路徑原樣'; else bad "絕對路徑解析錯（rc=${rc}）"; fi

ln -s "${wt}/docs/design-proposals/s" "${work}/link"
pen_resolve_path t "$wt" "${work}/link/p.pen"; rc=$?
if [ "$rc" -eq 0 ] && [ "$PEN_RESOLVED_PATH" = "${wt}/docs/design-proposals/s/p.pen" ]; then ok '目錄含 symlink → 實體路徑（backup sha1 與 Pen active 路徑以實體路徑為準）'; else bad "symlink 應正規化（rc=${rc} 得「${PEN_RESOLVED_PATH}」）"; fi

err="$(pen_resolve_path tag "$wt" docs/design-proposals/s/nope.pen 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -qF '✗ tag：' && printf '%s' "$err" | grep -qF '不存在' && printf '%s' "$err" | grep -qF '用法'; then ok '不存在 → return 2＋「✗ <tag>：…不存在」＋用法'; else bad "不存在應 return 2（rc=${rc}）"; fi

err="$(pen_resolve_path tag "$wt" docs/design-proposals/s/notes.txt 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -qF '須指向 .pen 檔'; then ok '非 .pen 副檔名 → return 2'; else bad "非 .pen 應 return 2（rc=${rc}）"; fi

rm -f "${wt}/design/littlesprout.pen"
err="$(pen_resolve_path tag "$wt" "" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -qF "✗ tag：找不到「${wt}/design/littlesprout.pen」"; then ok '主稿不存在 → return 2，訊息格式與舊版「找不到「<路徑>」」一致'; else bad "主稿不存在訊息不符（rc=${rc}：${err}）"; fi

bp="$(pen_backup_path /a/b.pen /bk)"
exp="/bk/$(printf '%s' 'file:///a/b.pen' | shasum | awk '{print $1}')"
if [ "$bp" = "$exp" ]; then ok 'pen_backup_path：<dir>/<sha1("file://<abs>")>'; else bad "backup 路徑公式不符（得「${bp}」期望「${exp}」）"; fi
bp="$(PEN_BACKUP_DIR=/envbk pen_backup_path /a/b.pen)"
case "$bp" in /envbk/*) ok 'pen_backup_path：預設吃 $PEN_BACKUP_DIR' ;; *) bad "應吃 PEN_BACKUP_DIR（得「${bp}」）" ;; esac

if [ "$fail" -ne 0 ]; then
  echo "✗ pen-path 自測失敗" >&2
  exit 1
fi
echo "✓ pen-path 自測通過（${n} 組樣本）"
