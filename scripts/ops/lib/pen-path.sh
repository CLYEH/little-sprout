#!/bin/bash
# scripts/ops/lib/pen-path.sh — .pen 目標路徑解析共用庫（LS-480）
#
# 背景：pen-land.sh／pen-open.sh／pen-read.sh／pen-status.sh／pen-bounds-probe.sh 過去各自寫死
# `<root>/design/littlesprout.pen`；提案檔（docs/design-proposals/**/*.pen）無法用正典腳本切檔與落地
# （LS-471 實測，R2／R3／R3b 三次靠手動複製 ~/.pencil/backup/<sha1>）。使用者 2026-10-11 指示：預設仍是主稿路徑，
# 但可用 `--pen <path>` 自訂。五支腳本 `source` 本檔，共用同一套解析、避免各抄一份日後漂移（LS-267 R2 M1 同型教訓）。
#
# 提供：
#   pen_resolve_path <tag> <root-abs> [<pen-arg>]
#       解析 .pen 目標的**絕對路徑**到全域變數 PEN_RESOLVED_PATH。
#       - <pen-arg> 省略／空字串＝`<root>/design/littlesprout.pen`（行為與舊版一字不變：不要求副檔名、不做 realpath）。
#       - 否則 <pen-arg> 為絕對路徑或相對 <root> 的路徑；須存在、為檔案、副檔名 `.pen`；目錄做 `pwd -P`（Pen 回報的
#         active 路徑與 autosave backup 的 sha1 都以實體路徑為準，symlink 不正規化會對不上）。
#       - 失敗印 `✗ <tag>：…` 到 stderr 並 return 2（呼叫端 `|| exit 2`）。
#   pen_backup_path <abs-pen-path> [<backup-dir>]
#       印 autosave backup 路徑：`<backup-dir 預設 $PEN_BACKUP_DIR 或 ~/.pencil/backup>/<sha1("file://<abs>")>`
#       （算法同 pen-land.sh 檔頭；patrol_linear.py design_forced_full 的 Python 側同公式）。
#
# 自測：scripts/ops/lib/pen-path.test.sh。
pen_resolve_path() {
  local tag=$1 root=$2 arg=${3:-} p dir
  PEN_RESOLVED_PATH=""
  if [ -z "$arg" ]; then
    p="${root}/design/littlesprout.pen"
    [ -f "$p" ] || {
      echo "✗ ${tag}：找不到「${p}」" >&2
      return 2
    }
    PEN_RESOLVED_PATH=$p
    return 0
  fi
  case "$arg" in
    /*) p=$arg ;;
    *) p="${root}/${arg}" ;;
  esac
  case "$p" in
    *.pen) ;;
    *)
      echo "✗ ${tag}：--pen 須指向 .pen 檔（得到「${arg}」）。用法：--pen <絕對路徑或相對 ${root} 的 .pen 路徑>；省略＝${root}/design/littlesprout.pen" >&2
      return 2
      ;;
  esac
  [ -f "$p" ] || {
    echo "✗ ${tag}：--pen 指向的檔案不存在「${p}」。用法：--pen <絕對路徑或相對 ${root} 的 .pen 路徑>；省略＝${root}/design/littlesprout.pen" >&2
    return 2
  }
  dir=$(cd "$(dirname "$p")" 2>/dev/null && pwd -P) || {
    echo "✗ ${tag}：--pen 的目錄無法進入「$(dirname "$p")」" >&2
    return 2
  }
  PEN_RESOLVED_PATH="${dir}/$(basename "$p")"
  return 0
}

pen_backup_path() {
  local abs=$1 dir=${2:-${PEN_BACKUP_DIR:-$HOME/.pencil/backup}} sha
  sha=$(printf '%s' "file://${abs}" | shasum | awk '{print $1}')
  printf '%s/%s\n' "$dir" "$sha"
}
