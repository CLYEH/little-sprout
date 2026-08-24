#!/bin/bash
# BREAKING 段落偵測（LS-53）：讀 stdin（PR body），`BREAKING:` 位於行首且同一行有內容才算有效。
# exit 0＝有效；其餘＝無效（grep 讀取錯誤也算無效，fail closed）。
# 供 CI rules job 使用（migration 被 migration-breaking-check.sh 判 BREAKING 時）；負向測試在
# breaking-section-check.test.sh（docs/COLLABORATION.md §6、§7）。
#
# 比照 destructive-approval-check.sh（LS-45）的行錨定：純子字串比對會被散文提及（「本 PR 不需
# BREAKING: 段落」）滿足。規則：`BREAKING:` 在行首（允許前導空白；[[:space:]] 含 CR，web UI 貼上的
# CRLF 也認得），冒號後同一行必須有非空白內容——受影響的呼叫端／app 版本／遷移路徑的一句摘要，
# 細節可在下方列點。`**BREAKING:**`、`- BREAKING:`、`> BREAKING:`、只有標頭下一行才寫內容皆不算：
# 標記須裸寫、摘要與標頭同行，機械可驗。
set -uo pipefail

grep -qE '^[[:space:]]*BREAKING:[[:space:]]*[^[:space:]]'
