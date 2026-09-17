#!/bin/bash
# LS-318（來源 LS-127／LS-316 同型再犯，LS-96 池項 `28fd134b` M1）：ci.yml 裡任何呼叫「讀 PR head 內容」
# 的 gate script 的 step，若沒有把 PR head sha 傳進去，checkout 到的其實是 refs/pull/N/merge（PR head
# ＋base tip 的雙親合併 commit）——LS-127 已為三支 .pen gate（design-evidence-check／design-notes-check／
# design-identity-header-check）修過這個同型 bug，LS-316 新接線（pr-body-check.sh --verify／
# design-ref-check.sh）又漏了一次，且當時沒有任何自測擋。這支把「呼叫清單命中的 step 必須把 HEAD_SHA
# 傳進 env 且呼叫行帶 --head-sha」這條慣例機械化，靜態掃 .github/workflows/ci.yml（不執行、不需 CI 環境）。
#
# 呼叫清單（新增/移除只改這行；找不到清單裡任何一個字串的 step 一律跳過，命中一個都沒有也不算異常）：
CALL_LIST="pr-body-check.sh design-ref-check.sh design-evidence-check.sh design-notes-check.sh design-identity-header-check.sh"
#
# 白名單（step 名稱字面完全比對；只放行「呼叫清單命中但這個 step 這次呼叫其實不需要 head-sha」的情況——
# 目前現行 ci.yml 沒有這種案例，格式先留給以後用，多項以半角 `;` 分隔、每項「<step 名稱>|<理由>」——
# 注意是半角分號，全形「；」不會被 ci_head_sha_check.py 當分隔字元）：
WHITELIST=""
#
# 判定細節、python 不依賴 PyYAML 的理由見 ci_head_sha_check.py 檔頭。
# 用法：ci-head-sha-check.sh [--repo-root <dir>] [--ci <path>]（自測用；正式呼叫不帶參數，兩者互斥）
# exit：0＝命中呼叫清單的 step 全部合規（或整檔沒有命中任何一項）；1＝有缺失；2＝參數／找不到檔案／無 python3。
# 自測：scripts/gates/ci-head-sha-check.test.sh（合成 ci.yml 正負樣本＋對真 ci.yml 的 mutation），掛
# CI rules job「Gate 腳本自測」step 與 selftest-wiring-check.sh。
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${here}/../.."
ci=""

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root)
      [ -n "${2:-}" ] || { echo "✗ ci-head-sha-check：--repo-root 缺值" >&2; exit 2; }
      root="$2"; shift 2 ;;
    --ci)
      [ -n "${2:-}" ] || { echo "✗ ci-head-sha-check：--ci 缺值" >&2; exit 2; }
      ci="$2"; shift 2 ;;
    *) echo "✗ ci-head-sha-check：未知參數「$1」。用法：ci-head-sha-check.sh [--repo-root <dir>] [--ci <file>]" >&2; exit 2 ;;
  esac
done

root="$(cd "$root" 2>/dev/null && pwd)" || { echo "✗ ci-head-sha-check：--repo-root 不是目錄" >&2; exit 2; }
ci="${ci:-${root}/.github/workflows/ci.yml}"
[ -f "$ci" ] || { echo "✗ ci-head-sha-check：找不到 ci.yml（${ci}）" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "✗ ci-head-sha-check：需要 python3" >&2; exit 2; }

py="${here}/ci_head_sha_check.py"
[ -f "$py" ] || { echo "✗ ci-head-sha-check：找不到 ${py}" >&2; exit 2; }

python3 "$py" "$ci" "$CALL_LIST" "$WHITELIST"
