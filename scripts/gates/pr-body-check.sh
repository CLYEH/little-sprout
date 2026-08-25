#!/bin/bash
# PR body 票號檢查（LS-63）：PR body 的「檔頭段」必須含本票票號 `LS-<n>`（票號取自工作分支名）。
# 來源：2026-08-24 LS-53 與 LS-56 兩個 agent 同時用 scratchpad/pr-body.md 暫存 PR body，LS-56 覆寫後
# LS-53 的 `gh pr edit 78` 把 LS-56 的 body 貼上 PR #78——若當時含核可標記或 BREAKING: 段落會誤觸 gate。
# 檔名規約（暫存檔一律 LS-<n>-<用途>.<ext>）在 repo 外、無法機械驗；這裡驗的是它要防的結果：body 貼錯票。
# agent 在 `gh pr create/edit --body-file <f>` 前呼叫；CI rules job 對 github.event.pull_request.body 以 head
# 分支票號再驗（伺服器端兜底）；自測 pr-body-check.test.sh。規約見 docs/COLLABORATION.md §3、§7。
#
# 用法：pr-body-check.sh [--branch <name>] <body-file>
#   --branch  分支名，預設當前分支（CI 的 checkout 是 detached merge ref，必須傳 $HEAD）。不符
#             (feature|fix|hotfix)/LS-<n>-<slug> 即 exit 2——promote／back-merge 的 head 是保護分支，沒有本票可比。
#
# 檔頭段：從檔頭到第一個「內容段落」結束為止——開頭的空白行與 Markdown 標題行（`#` 開頭）不算內容、但一併
#   納入；第一個非空白非標題行起算內容段落，遇下一個空白行結束。這樣 PR 模板的「## Ticket／空行／LS-<n>」
#   與「Ticket: LS-<n> …」（PR #90）、「## Ticket／LS-<n> …」（PR #78）三種實際形狀都是同一段。
#   [[:space:]] 含 CR，web UI 貼上的 CRLF 也認得。
# 票號比對：整字——`LS-63` 不被 `LS-630` 滿足；大小寫敏感（分支 regex 亦然）。檔頭段之後貼錯內容（第二段起
#   是別票的 body）看不出來，靠 merge-reviewer scope 維度。
# exit 0＝檔頭段含本票票號；1＝違規（空 body、模板未填、票號不在檔頭段、檔頭段是他票）；2＝參數／分支錯誤（fail closed）。
# 紅了之後：改 PR body 不會讓 CI 自動重跑（on: pull_request 不含 edited；gh run rerun 重放舊 payload），要 close/reopen PR
#   或再 push 一個 commit——失敗輸出會提示（PR #93 review F1；LS-37 在 DESTRUCTIVE-APPROVED 踩過同坑，COLLABORATION §6）。
set -uo pipefail

branch=; file=
while [ $# -gt 0 ]; do
  case "$1" in
    --branch)
      if [ -z "${2:-}" ]; then echo "✗ pr-body-check：--branch 缺值" >&2; exit 2; fi
      branch=$2; shift 2 ;;
    -*) echo "✗ pr-body-check：未知參數 $1" >&2; exit 2 ;;
    *)
      if [ -n "$file" ]; then echo "✗ pr-body-check：只接受一個 body 檔（多給了 $1）" >&2; exit 2; fi
      file=$1; shift ;;
  esac
done
[ -n "$file" ] || { echo "✗ pr-body-check：缺 PR body 檔（gh pr create/edit 用的 --body-file）" >&2; exit 2; }
[ -r "$file" ] || { echo "✗ pr-body-check：讀不到 ${file}。" >&2; exit 2; }
[ -n "$branch" ] || branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo DETACHED)

ticket=$(printf '%s' "$branch" | sed -nE 's#^(feature|fix|hotfix)/(LS-[1-9][0-9]*)-[a-z0-9][a-z0-9-]*$#\2#p')
if [ -z "$ticket" ]; then
  echo "✗ pr-body-check：「${branch}」不是 (feature|fix|hotfix)/LS-<n>-<slug> 工作分支，沒有本票票號可比（CI 請傳 --branch \$HEAD）。" >&2
  exit 2
fi

# 抽檔頭段（純 bash 3.2：不依賴 awk 方言）。`|| [ -n "$line" ]` 讓最後一行沒有結尾換行時也讀得到。
head_text=; content=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    *[![:space:]]*) ;;
    *) if [ "$content" -eq 1 ]; then break; fi; continue ;;
  esac
  head_text="${head_text}${line}"$'\n'
  stripped="${line#"${line%%[![:space:]]*}"}"
  case "$stripped" in
    '#'*) ;;
    *) content=1 ;;
  esac
done < "$file"

rerun_hint="  修好 body 後 CI 不會自動重跑（pull_request 觸發不含 edited；gh run rerun 也只重放舊 body）——請 close/reopen PR 或再 push 一個 commit（LS-37 實測，COLLABORATION §6）。"

if [ -z "$head_text" ]; then
  echo "✗ pr-body-check：PR body 是空的（或只有空白）——檔頭段必須含本票票號 ${ticket}。" >&2
  echo "$rerun_hint" >&2
  exit 1
fi

if printf '%s' "$head_text" | grep -qE "(^|[^A-Za-z0-9])${ticket}([^0-9]|$)"; then
  echo "✓ PR body 檔頭段含本票票號 ${ticket}"
  exit 0
fi

others=$(printf '%s' "$head_text" | grep -oE 'LS-[1-9][0-9]*' | sort -u | paste -s -d, - | sed 's/,/, /g')
echo "✗ pr-body-check：PR body 檔頭段沒有本票票號 ${ticket}（分支 ${branch}）：" >&2
printf '%s' "$head_text" | sed 's/^/    | /' >&2
if [ -n "$others" ]; then
  echo "  檔頭段含其他票號（${others}）：若為刻意引用可忽略此句、只需補上 ${ticket}；若非，請確認 body 檔是否被平行 agent 覆寫（LS-53／LS-56 事故；COLLABORATION §3：暫存檔一律 LS-<n>-<用途>.<ext>）。" >&2
else
  echo "  檔頭段沒有任何 LS-<n>：PR 模板的「LS-」還沒填，或票號寫在更下面——請在檔頭段（Ticket 行）寫 ${ticket}。" >&2
fi
echo "$rerun_hint" >&2
exit 1
