#!/bin/bash
# 核可標記改認使用者本人的 PR comment（LS-123）：抓 PR 的 issue comments，只取 user.login ＝ repo owner 的
# comment，逐則把 body 以 stdin 送給既有的標記 gate（例如 destructive-approval-check.sh 的整行錨定判定），
# 任一則命中即 exit 0。標記規則本身不在這裡——由傳入的 gate 決定（獨佔一行、允許前後空白／CRLF、散文提及不算）。
#
# 來源：LS-121 PR #218——使用者 02:41Z 在 PR body 蓋 DESTRUCTIVE-APPROVED，ios-dev R2 `gh pr edit --body-file`
# 整份覆寫 body 把標記洗掉；使用者 03:08Z 改留 comment（id 5503728612，body 恰為 `DESTRUCTIVE-APPROVED`），
# 但 CI rules job 只讀 github.event.pull_request.body，comment 完全不看。使用者裁決：「DESTRUCTIVE-APPROVED
# 我放在 comment 裡，建議未來也這樣做，這樣就不會被誤刪」。comment 不隨 body 覆寫消失，且是 gate 執行時經
# API 即時抓的——留了 comment 後 `gh run rerun --failed` 就看得到，不像 body 標記要 close/reopen。
#
# 用法：approval-comment-check.sh <pr-number> <gate-command> [args…]
#   <gate-command>：讀 stdin、命中 exit 0 的任何命令。CI 用法：
#     bash scripts/gates/approval-comment-check.sh "$PR_NUMBER" bash scripts/gates/destructive-approval-check.sh
#   migration-immutable-check.sh --pr-number 內部傳 `grep -qE "$marker_re"`（regex 單一來源，不複製到這裡）。
#   repo／owner：讀 GITHUB_REPOSITORY／GITHUB_REPOSITORY_OWNER（Actions 預設環境變數；owner 即
#   github.repository_owner）；本機缺這兩個時退回 `gh repo view --json nameWithOwner,owner`。
#   comment 由 `gh api repos/<repo>/issues/<pr>/comments --paginate` 取得（GH_TOKEN 由呼叫端給；CI 的 rules job
#   要有 issues: read／pull-requests: read）；逐頁串接的 `[…][…]` 與 --slurp 的 `[[…],[…]]` 兩種形狀都認得。
#
# exit 0＝至少一則 owner comment 命中（stdout 印命中的 comment id／時間，供審查對照）；
# exit 1＝沒有任何 owner comment 命中（含零則 comment）；
# exit 2＝gh 失敗／回應非 JSON／缺 repo 或 owner／參數錯（fail closed——呼叫端把非 0 一律當未核可）。
#
# 盲區（同 body 標記，COLLABORATION §7）：本 gate 只驗「誰留的、形式對不對」——agent 拿使用者的 gh token 技術上
# 仍留得了 comment，核可真實性靠規約禁止（不得代寫、不得刪／改使用者留言）＋orchestrator 把關；只看現存 comment，
# 被刪掉的 comment 等於沒核可；user.login 整字精確比對（GitHub 回的是正典大小寫）。
set -uo pipefail

pr=${1:-}
if ! printf '%s' "$pr" | grep -qE '^[1-9][0-9]*$'; then
  echo "✗ approval-comment-check：<pr-number> 須為正整數（實得「${pr}」）" >&2
  exit 2
fi
shift
[ $# -ge 1 ] || { echo "✗ approval-comment-check：缺 <gate-command>（讀 stdin、命中 exit 0 的命令）" >&2; exit 2; }

command -v gh >/dev/null 2>&1 || { echo "✗ approval-comment-check：需要 gh" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "✗ approval-comment-check：需要 python3" >&2; exit 2; }

repo=${GITHUB_REPOSITORY:-}
owner=${GITHUB_REPOSITORY_OWNER:-}
if [ -z "$repo" ] || [ -z "$owner" ]; then
  view=$(gh repo view --json nameWithOwner,owner --jq '.nameWithOwner + " " + .owner.login' 2>/dev/null) || view=
  [ -n "$repo" ] || repo=${view%% *}
  [ -n "$owner" ] || owner=${view##* }
fi
if [ -z "$repo" ] || [ -z "$owner" ]; then
  echo "✗ approval-comment-check：無法判定 repo／owner（GITHUB_REPOSITORY／GITHUB_REPOSITORY_OWNER 未設且 gh repo view 失敗）——fail closed" >&2
  exit 2
fi

raw=$(gh api "repos/${repo}/issues/${pr}/comments" --paginate)
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "✗ approval-comment-check：gh api repos/${repo}/issues/${pr}/comments 失敗（exit ${rc}）——fail closed，視為未核可" >&2
  exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 解析＋過濾作者（純轉換，交給 python3）：每則 owner comment 輸出一筆「<id> <created_at>\n<body>\0」，
# NUL 分隔讓多行 body 原樣保留（含 CRLF），bash 端 read -d '' 逐筆讀。
# 回應走檔案而非 stdin：`python3 -` 的 stdin 已被 heredoc（腳本本身）佔用。
printf '%s' "$raw" > "$work/raw.json"
python3 - "$owner" "$work/raw.json" > "$work/records" <<'PY'
import json, sys

owner = sys.argv[1]
with open(sys.argv[2], encoding="utf-8") as f:
    text = f.read()
dec = json.JSONDecoder()
items = []


def flatten(node):
    if isinstance(node, list):
        for x in node:
            flatten(x)
    elif isinstance(node, dict):
        items.append(node)
    else:
        raise ValueError("comment 陣列內出現非物件元素")


try:
    i, n = 0, len(text)
    docs = 0
    while True:
        while i < n and text[i].isspace():
            i += 1
        if i >= n:
            break
        doc, i = dec.raw_decode(text, i)
        docs += 1
        if isinstance(doc, dict) and "message" in doc and "id" not in doc:
            raise ValueError("gh 回的是錯誤物件：%s" % doc.get("message"))
        flatten(doc)
    if docs == 0:
        raise ValueError("空回應")
except ValueError as e:
    sys.stderr.write("✗ approval-comment-check：gh api 回應不是 comment JSON 陣列（%s）——fail closed\n" % e)
    sys.exit(2)

out = sys.stdout
for c in items:
    user = c.get("user") or {}
    if user.get("login") != owner:
        continue
    out.write("%s %s\n%s\0" % (c.get("id"), c.get("created_at"), c.get("body") or ""))
PY
rc=$?
[ "$rc" -eq 0 ] || exit 2

nl=$'\n'
total=0
while IFS= read -r -d '' rec; do
  total=$((total + 1))
  meta=${rec%%"$nl"*}
  body=${rec#*"$nl"}
  if printf '%s' "$body" | "$@"; then
    echo "✓ approval-comment-check：PR #${pr} 使用者本人（${owner}）的 comment 命中核可標記（comment ${meta%% *} @ ${meta#* }）"
    exit 0
  fi
done < "$work/records"

echo "✗ approval-comment-check：PR #${pr} 共 ${total} 則使用者本人（${owner}）的 comment，無一則命中核可標記（標記須獨佔一行，散文提及／反引號包起不算；非本人的 comment 不算）" >&2
exit 1
