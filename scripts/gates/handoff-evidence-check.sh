#!/bin/bash
# Handoff 逐項證據 gate（LS-211）。實際解析邏輯在 handoff_evidence_check.py（python3，跨 macOS／
# ubuntu-latest 都內建，同 privacy-manifest-check.sh 呼叫 privacy_manifest_check.py 的既有慣例）。
#
# 用法：handoff-evidence-check.sh <handoff.md> [--repo <dir>]
#   <handoff.md>  待查的 handoff／QA 裁決／merge-review verdict 文字檔（可先用 mcp__linear__list_comments
#                 抓 comment 原文存成 scratchpad 檔案再餵給本腳本）。
#   --repo <dir>  驗證測試名存在的 repo 根目錄；預設當前 git repo（`git rev-parse --show-toplevel`）。
# exit：0＝全過；1＝任一列項缺『怎麼驗』證據、引用的測試名在 repo 內找不到，或引用的白名單目錄路徑
#      （見 --help）在 repo 內找不到；2＝參數／環境錯誤（fail closed）。
# 自測：handoff-evidence-check.test.sh（CI rules job）。qa／merge-reviewer 定義規定「貼 comment 前先跑本腳本、
# 把輸出附在 comment 末尾；紅則逐條說明是誤判或補證據」（R2：不要求一定要綠，因為工具本身仍有 N6／N9 已知
# 限制，見 handoff_evidence_check.py 檔頭——不得為了討好工具改寫正確敘述）；ios-dev 定義規定 handoff「已驗證」
# 每項附『怎麼驗』。規約見 docs/COLLABORATION.md §7。
set -uo pipefail

case "${1:-}" in
  --help|-h)
    cat <<'EOF'
用法：handoff-evidence-check.sh <handoff.md> [--repo <dir>]
解析 handoff／QA 裁決／merge-review verdict 裡「已驗證」等價段落（## 已驗證｜**已驗證**｜「已驗證」
行起，或標題含「驗收」／「查實」如「逐條驗收」「逐條查實」）的每一個列項，要求每項至少含一種
「怎麼驗」證據：測試名（存在性驗證，見 handoff_evidence_check.py 檔頭）、路徑（.png/.log/.test.sh/
scratchpad//evidence//.swift/.py/.sh/.md/.yml/.json，子字串比對不驗證存在）、白名單目錄路徑（必須
驗證真的存在：supabase/functions/**/*.ts、supabase/migrations/*.sql、
supabase/tests/*.sql、supabase/**/*.sh、docs/**/*.md、.claude/**/*.md、scripts/**/*.sh、
.github/workflows/*.yml），或命令（xcodebuild／bash scripts/／gh run view／.xcresult）。
exit：0＝全過；1＝有違規（含引用的白名單路徑不存在）；2＝參數／環境錯誤。
EOF
    exit 0
    ;;
esac

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
py="${self_dir}/handoff_evidence_check.py"

command -v python3 >/dev/null 2>&1 || { echo "✗ handoff-evidence-check：需要 python3（macOS 與 ubuntu-latest 皆內建）" >&2; exit 2; }
[ -f "$py" ] || { echo "✗ handoff-evidence-check：找不到 ${py}" >&2; exit 2; }
[ $# -ge 1 ] || { echo "✗ handoff-evidence-check：用法 handoff-evidence-check.sh <handoff.md> [--repo <dir>]" >&2; exit 2; }

exec python3 "$py" "$@"
