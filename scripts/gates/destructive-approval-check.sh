#!/bin/bash
# 破壞性 migration 核可標記偵測：讀 stdin（PR body），標記獨佔一行才算核可。
# exit 0＝有效核可；其餘＝未核可（grep 讀取錯誤也算未核可，fail closed）。
# 供 CI rules job 使用；負向測試在 destructive-approval-check.test.sh（docs/COLLABORATION.md §6、§7）。
#
# LS-45：改整行錨定。原本對整個 PR body 做純子字串比對，「等待使用者蓋 DESTRUCTIVE-APPROVED」
# 這種語意相反的提及也會放行（LS-37 PR #55 run 32626369903 實測）。現在標記必須獨佔一行：
# 允許前後空白（[[:space:]] 含 CR，web UI 貼上的 CRLF 也認得），同一行不得有任何其他字——
# 〈〉括起、前綴文字、尾隨文字、Markdown 粗體／反引號包起皆不算。
# 本 gate 只驗形式；標記由誰寫的（agent 技術上仍寫得進去）靠規約禁止＋orchestrator 把關。
set -uo pipefail

grep -qE '^[[:space:]]*DESTRUCTIVE-APPROVED[[:space:]]*$'
