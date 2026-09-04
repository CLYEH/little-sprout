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
#
# LS-181（B7 enum 加值的消費端處置）：
#   用法：breaking-section-check.sh [--findings FILE] < PR body
#   --findings FILE＝migration-breaking-check.sh 的整份輸出落檔（CI rules job 把 `$findings` 寫進 $RUNNER_TEMP 再傳；
#   push-gate 沒有 PR body、不呼叫）。檔內每行 `CONSUMER\t<enum>\t<路徑>\t…` 的路徑（去重）都必須在 BREAKING 段內
#   有一行「含該路徑＋處置」：
#     - 已更新：同一行帶 7–40 位小寫 hex 的 commit SHA（獨立 token，同 pr-body-check「已修」行慣例）；或
#     - 不需更新：標記之後（可接冒號／括號）至少一個非空白字元的理由。
#   BREAKING 段＝第一個有效 `BREAKING:` 行起，到下一個 Markdown 標題行（行首 `#`）或 body 結尾。段外寫的不算
#   ——消費端盤點要跟 BREAKING 摘要放一起，reviewer 一眼看完。缺任一路徑即紅並逐一列出缺哪些（不在第一個就停）。
#   沒有 --findings、或檔內沒有 CONSUMER 行 → 只驗上面的既有規則（B1–B6 的 BREAKING 不帶消費端清單）。
#   同一路徑被兩個 enum 列到（handler.ts 同時消費 notification_kind／content_target_type）只要交代一次。
#   路徑比對是 fixed-string 子字串（`docs/API.md` 寫成 `` `docs/API.md` `` 也認）；處置是否屬實靠 merge-reviewer。
# exit 0＝有效；1＝無效（無 BREAKING: 行、或缺消費端處置）；2＝參數／--findings 讀不到（fail closed，CI 的 `!` 一樣紅）。
set -uo pipefail
export LC_ALL=C

findings=""
while [ $# -gt 0 ]; do
  case "$1" in
    --findings) findings=${2:?--findings 需要檔名}; shift 2 ;;
    *) echo "✗ breaking-section-check：未知參數 $1" >&2; exit 2 ;;
  esac
done
if [ -n "$findings" ] && { [ ! -f "$findings" ] || [ ! -r "$findings" ]; }; then
  echo "✗ breaking-section-check：--findings 不是可讀的一般檔：$findings（fail closed）" >&2
  exit 2
fi

body=$(mktemp)
trap 'rm -f "$body"' EXIT
cat > "$body" || exit 2

# ① 既有規則：行首 BREAKING:＋同行摘要
grep -qE '^[[:space:]]*BREAKING:[[:space:]]*[^[:space:]]' "$body" || exit 1

# ② LS-181：消費端逐一處置
[ -n "$findings" ] || exit 0
paths=$(awk -F'\t' '$1 == "CONSUMER" && $3 != "" {print $3}' "$findings" | sort -u)
[ -n "$paths" ] || exit 0

section=$(awk 'on && /^[[:space:]]*#/ {exit} /^[[:space:]]*BREAKING:[[:space:]]*[^[:space:]]/ {on=1} on {print}' "$body")
missing=""
n=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  ok=0
  while IFS= read -r line; do
    case "$line" in
      *"$p"*) ;;
      *) continue ;;
    esac
    case "$line" in
      *已更新*)
        # 獨立 hex token 7–40 位（前後不得是英數；反引號／空白／行首行尾皆可）
        if printf '%s' "$line" | grep -qE '(^|[^0-9A-Za-z])[0-9a-f]{7,40}([^0-9A-Za-z]|$)'; then ok=1; fi
        ;;
    esac
    if [ "$ok" -eq 0 ]; then
      case "$line" in
        *不需更新*)
          # 標記之後去掉空白與常見標點（冒號／括號／逗號／破折號）還有東西才算理由
          rest=$(printf '%s' "${line##*不需更新}" | tr -d ' \t\r：:（(）),，—-')
          [ -n "$rest" ] && ok=1
          ;;
      esac
    fi
    [ "$ok" -eq 1 ] && break
  done <<< "$section"
  if [ "$ok" -eq 1 ]; then n=$((n + 1)); else missing="${missing}${p}"$'\n'; fi
done <<< "$paths"

if [ -n "$missing" ]; then
  echo "✗ breaking-section-check：BREAKING: 段未逐一交代 enum 加值的消費端（缺下列路徑；每個路徑需同一行寫「已更新 <commit sha>」或「不需更新：<理由>」，且要在 BREAKING: 行之後、下一個標題之前）：" >&2
  printf '%s' "$missing" | sed 's/^/    /' >&2
  exit 1
fi
echo "✓ breaking-section-check：BREAKING: 段已逐一交代 ${n} 個消費端路徑"
exit 0
