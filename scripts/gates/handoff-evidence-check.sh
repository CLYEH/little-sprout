#!/bin/bash
# Handoff 逐項證據 gate（LS-211）。實際解析邏輯在 handoff_evidence_check.py（python3，跨 macOS／
# ubuntu-latest 都內建，同 privacy-manifest-check.sh 呼叫 privacy_manifest_check.py 的既有慣例）。
#
# 用法：handoff-evidence-check.sh <handoff.md> [--repo <dir>] [--rubric <path>] [--require-selfcheck]
#   <handoff.md>  待查的 handoff／QA 裁決／merge-review verdict 文字檔（可先用 mcp__linear__list_comments
#                 抓 comment 原文存成 scratchpad 檔案再餵給本腳本）。
#   --repo <dir>  驗證測試名存在的 repo 根目錄；預設當前 git repo（`git rev-parse --show-toplevel`）。
#   --rubric <path>        LS-352：自檢段比對用的 rubric；預設 <repo>/docs/REVIEW-RUBRIC.md。
#   --require-selfcheck    LS-352：缺「## 自檢（依 docs/REVIEW-RUBRIC.md）」段即紅（ios-dev 交件前自驗、merge-reviewer
#                          驗實作者 handoff 時帶；QA 裁決／verdict 不帶）。段落存在時不論帶不帶都驗。
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
用法：handoff-evidence-check.sh <handoff.md> [--repo <dir>] [--rubric <path>] [--require-selfcheck]
解析 handoff／QA 裁決／merge-review verdict 裡「已驗證」等價段落（## 已驗證｜**已驗證**｜「已驗證」
行起，或標題含「驗收」／「查實」如「逐條驗收」「逐條查實」）的每一個列項，要求每項至少含一種
「怎麼驗」證據：測試名（存在性驗證，見 handoff_evidence_check.py 檔頭）、路徑（.png/.log/.test.sh/
scratchpad//evidence//.swift/.py/.sh/.md/.yml/.json，子字串比對不驗證存在）、白名單目錄路徑（必須
驗證真的存在且未逃出 --repo：supabase/functions/**/*.ts、supabase/migrations/*.sql、
supabase/tests/*.sql、supabase/**/*.sh、docs/**/*.md、.claude/**/*.md、scripts/**/*.sh、
.github/workflows/*.yml），或命令（xcodebuild／bash scripts/／gh run view／.xcresult）。
LS-300：另認一個可選子段「畫面級屬性（逐條勾選）」（標題含「畫面級屬性」）——存在時逐列驗板名／
✓✗／證據三者；不存在時不影響既有 handoff（不強制要求）。
LS-352：「自檢」段（標題以「自檢」開頭）——條目從 rubric（預設 docs/REVIEW-RUBRIC.md）的 `- R<n>.<m>` 行解析；
自檢段每列須 R<n>.<m> 起頭＋狀態（通過／不適用／已知未處理）＋證據（含 file:line），編號集合須與 rubric 完全
相同（缺／多／重複逐條點名）。段落存在一律驗；不存在只在 --require-selfcheck 時紅。
exit：0＝全過；1＝有違規（含引用的白名單路徑不存在、畫面級屬性子段缺板名／✓✗／證據、自檢段缺段或與 rubric 不符）；2＝參數／環境錯誤（含 rubric 讀不到或格式錯）。
EOF
    exit 0
    ;;
esac

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
py="${self_dir}/handoff_evidence_check.py"

command -v python3 >/dev/null 2>&1 || { echo "✗ handoff-evidence-check：需要 python3（macOS 與 ubuntu-latest 皆內建）" >&2; exit 2; }
[ -f "$py" ] || { echo "✗ handoff-evidence-check：找不到 ${py}" >&2; exit 2; }
[ $# -ge 1 ] || { echo "✗ handoff-evidence-check：用法 handoff-evidence-check.sh <handoff.md> [--repo <dir>] [--rubric <path>] [--require-selfcheck]" >&2; exit 2; }

exec python3 "$py" "$@"
