#!/bin/bash
# scripts/ops/linear-post.sh — Linear API 備援（LS-308 B1）。
#
# 背景（0059bb4f，14:10，P2）：Linear MCP token 過期時，所有需要貼 comment／改狀態／讀票的 agent 全部卡住——
# `mcp__linear__*` 工具整批失敗，沒有備援路徑。本腳本是 bash 包一層，直接打 GraphQL API（不經 MCP），供
# agent handoff 指定「改用備援」時使用。
#
# 用法：
#   bash scripts/ops/linear-post.sh get <issue> [--comments]      印 title／state／labels／description（--comments 再列全部留言）
#   bash scripts/ops/linear-post.sh comment <issue> <body-file>   貼留言，印新 comment id
#   bash scripts/ops/linear-post.sh state <issue> <state-name>    改狀態（依 team 的 workflow state 名稱）
#
# 需要 LINEAR_API_KEY（環境變數或 cwd 的 .env，見 scripts/ops/linear-archive.py 的 load_key()；key 永不印出）。
# LINEAR_API_URL 可覆寫 GraphQL endpoint（自測用，指向本機假伺服器，不打正式 Linear API）。
# Exit：0＝成功；1＝GraphQL／HTTP 錯誤（錯誤內容印到 stderr）；2＝用法錯誤。
#
# 自測：scripts/ops/linear-post.test.sh（本機假伺服器，三種子命令正負夾具；掛 CI rules job）。
set -uo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_BIN=${LINEAR_POST_PY_BIN:-python3}
exec "$PY_BIN" "${script_dir}/linear_post.py" "$@"
