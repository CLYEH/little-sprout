#!/bin/bash
# PR body 票號檢查（LS-63）：PR body 的「檔頭段」必須含本票票號 `LS-<n>`（票號取自工作分支名）。
# 來源：2026-08-24 LS-53 與 LS-56 兩個 agent 同時用 scratchpad/pr-body.md 暫存 PR body，LS-56 覆寫後
# LS-53 的 `gh pr edit 78` 把 LS-56 的 body 貼上 PR #78——若當時含核可標記或 BREAKING: 段落會誤觸 gate。
# 檔名規約（暫存檔一律 LS-<n>-<用途>.<ext>）在 repo 外、無法機械驗；這裡驗的是它要防的結果：body 貼錯票。
# agent 在 `gh pr create/edit --body-file <f>` 前呼叫；CI rules job 對 github.event.pull_request.body 以 head
# 分支票號再驗（伺服器端兜底）；自測 pr-body-check.test.sh。規約見 docs/COLLABORATION.md §3、§7。
#
# 用法：pr-body-check.sh [--branch <name>] [--verify] <body-file>
#   --branch  分支名，預設當前分支（CI 的 checkout 是 detached merge ref，必須傳 $HEAD）。不符
#             (feature|fix|hotfix)/LS-<n>-<slug> 即 exit 2——promote／back-merge 的 head 是保護分支，沒有本票可比。
#   --verify  反查申報（LS-140，見下）：CI rules job 帶；本機 `source .env` 後亦可（不帶 key 只驗格式＋git）。
#   本機驗 body 一律用 CI 的完整形式 `pr-body-check.sh <f> --branch <分支> --verify`，**勿接管線（`| tail -1`），以 exit code
#   分支**——管線會吃掉 exit code、`| tail` 只看 stdout 也看不到 stderr 的 ✗（LS-185 兩次把紅 body 推上 PR：一次 `| tail -1`、
#   一次不帶 `--verify` 只驗了格式）。紅時最後一行一律在 stdout 印 `✗ pr-body-check：未通過…`，接了 `| tail -1` 也看得到（LS-186）。
#
# 檔頭段：從檔頭到第一個「內容段落」結束為止——開頭的空白行與 Markdown 標題行（`#` 開頭）不算內容、但一併
#   納入；第一個非空白非標題行起算內容段落，遇下一個空白行結束。這樣 PR 模板的「## Ticket／空行／LS-<n>」
#   與「Ticket: LS-<n> …」（PR #90）、「## Ticket／LS-<n> …」（PR #78）三種實際形狀都是同一段。
#   [[:space:]] 含 CR，web UI 貼上的 CRLF 也認得。
# 票號比對：整字——`LS-63` 不被 `LS-630` 滿足；大小寫敏感（分支 regex 亦然）。檔頭段之後貼錯內容（第二段起
#   是別票的 body）看不出來，靠 merge-reviewer scope 維度。
#
# LS-140 申報可驗證（來源 LS-96 池項 9f348e36／fd2fe81e：LS-125 R2 handoff 申報「記入 LS-96」四條實際一則沒寫、
#   R3 申報「已修」但 commit 裡沒有該變更，都靠 merge-reviewer 逐條到 LS-96 查實才抓到）。檔頭段之外再對全 body 逐行掃：
#   (a) 含 `LS-96`（整字）／「入池」／「待辦池」的行必須帶 ≥8 位小寫 hex 的 comment id（獨立英數 token；UUID 首段即可）；
#   (b) 含「已修」的行必須帶 7–40 位小寫 hex 的 commit SHA，且 SHA 須**緊鄰在「已修」之後**（中間只允許空白、反引號、`*`
#       粗體標記、半形／全形左括號）：「已修 `7c2ff80`」「**已修** `7c2ff80`」「已修（7c2ff80）」算，「已修：見 `7c2ff80`」
#       「…`d87d4334` …皆已修」不算——行內其他 hex（Linear comment id、issue uuid 片段）不再是候選（LS-186：LS-185 PR body
#       標題行的 review comment id 被當 SHA 反查、CI 紅兩次；comment id 請放在 SHA 之後的括號裡）。
#   刻意全 body 掃、不辨「處置語境」（判語境太脆）：引用而非申報的行（「LS-138 已修」「不另立 LS-96 池項」）會誤中，
#   由 agent 改寫措辭避開字樣或補 id；LS-96 行多個 hex token 時任一可驗即過、「已修」行則只看緊鄰候選（一行多個「已修」各取各的）。
#   --verify 反查：(a) 用 LINEAR_API_KEY 打 Linear GraphQL 列出 LS-96 全部 comment id（分頁）做前綴比對——`comment(id:)`
#   只吃完整 UUID、不吃 agent 慣寫的 8 位前綴（2026-09-03 實測回「Entity not found: Comment」）；(b) 候選 SHA 須
#   `git cat-file -e <sha>^{commit}` 且 `git merge-base --is-ancestor <sha> HEAD`（CI 的 HEAD 是 PR merge ref，PR commits
#   皆為祖先；已在 base 上的 commit 也是祖先——盲區，COLLABORATION §7）；緊鄰候選沒有一個是 commit object（comment id 形狀、
#   打錯的 SHA）→ 紅「已修行需附 commit SHA 於『已修』之後」，是 commit 但非祖先 → 紅「不在 PR commits 內」（LS-186）。
#   無 LINEAR_API_KEY → 印「反查略過」只驗格式＋git
#   （CI 需 secrets.LINEAR_API_KEY）；curl／GraphQL 失敗 exit 2（fail closed）。token 只走 curl `-K -`（stdin config）不進
#   argv（同 patrol_linear.py R1 F3）。
# exit 0＝全過；1＝違規（空 body、模板未填、票號不在檔頭段、檔頭段是他票、LS-96 行缺 comment id、「已修」行缺 SHA、
#   --verify 反查不到；最後一行 stdout 必為 `✗ pr-body-check：未通過…`）；2＝參數／分支／環境錯誤（fail closed）。
# 紅了之後：改 PR body 不會讓 CI 自動重跑（on: pull_request 不含 edited；gh run rerun 重放舊 payload），要 close/reopen PR
#   或再 push 一個 commit——失敗輸出會提示（PR #93 review F1；LS-37 在 DESTRUCTIVE-APPROVED 踩過同坑，COLLABORATION §6）。
set -uo pipefail

branch=; file=; verify=0
while [ $# -gt 0 ]; do
  case "$1" in
    --branch)
      if [ -z "${2:-}" ]; then echo "✗ pr-body-check：--branch 缺值" >&2; exit 2; fi
      branch=$2; shift 2 ;;
    --verify) verify=1; shift ;;
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
# 所有違規出口共用（LS-186）：止血指示到 stderr 之後，最後一行到 stdout 印 ✗——`| tail -1` 只看得到 stdout，上面的 ✗ 全在 stderr，
# LS-185 就是這樣把紅 body 當綠推上 PR 的。exit code 仍是唯一正式判據。
red_exit() {
  echo "$rerun_hint" >&2
  echo "✗ pr-body-check：未通過（exit 1）——原因見上方 ✗ 各行；請以 exit code 分支，勿接 | tail"
  exit 1
}

if [ -z "$head_text" ]; then
  echo "✗ pr-body-check：PR body 是空的（或只有空白）——檔頭段必須含本票票號 ${ticket}。" >&2
  red_exit
fi

if ! printf '%s' "$head_text" | grep -qE "(^|[^A-Za-z0-9])${ticket}([^0-9]|$)"; then
  others=$(printf '%s' "$head_text" | grep -oE 'LS-[1-9][0-9]*' | sort -u | paste -s -d, - | sed 's/,/, /g')
  echo "✗ pr-body-check：PR body 檔頭段沒有本票票號 ${ticket}（分支 ${branch}）：" >&2
  printf '%s' "$head_text" | sed 's/^/    | /' >&2
  if [ -n "$others" ]; then
    echo "  檔頭段含其他票號（${others}）：若為刻意引用可忽略此句、只需補上 ${ticket}；若非，請確認 body 檔是否被平行 agent 覆寫（LS-53／LS-56 事故；COLLABORATION §3：暫存檔一律 LS-<n>-<用途>.<ext>）。" >&2
  else
    echo "  檔頭段沒有任何 LS-<n>：PR 模板的「LS-」還沒填，或票號寫在更下面——請在檔頭段（Ticket 行）寫 ${ticket}。" >&2
  fi
  red_exit
fi
echo "✓ PR body 檔頭段含本票票號 ${ticket}"

# ---- LS-140：申報可驗證——全 body 逐行掃 (a) LS-96 行要 comment id、(b)「已修」行要 commit SHA ----
pool=LS-96
# 一行內的獨立英數 token 中，全為小寫 hex 且長度在 {$2,$3} 者，逗號串（$3 空＝無上限）。LC_ALL=C：CJK 位元組 ≥0x80，
# 永不落在 [0-9A-Za-z]，token 邊界因此穩定；反引號／括號／連字號都是邊界，UUID 首段、`sha` 皆可抽出。
hex_tokens() {
  printf '%s' "$1" | LC_ALL=C grep -oE '[0-9A-Za-z]+' | LC_ALL=C grep -E "^[0-9a-f]{$2,$3}\$" | paste -s -d, -
}
# 「已修」的 SHA 候選（LS-186）：每個「已修」之後、只隔著空白／反引號／`*`（粗體）／半形或全形左括號的第一個獨立英數 token，
# 且須為 7–40 位小寫 hex；行內其他 hex（comment id、uuid 片段）不算。先取整個英數 token 再驗 hex 與長度：`已修 x9f348e36y`
# 不會被截成合格候選。LC_ALL=C 下 `已修`／`（` 是位元組序列的字面交替（不放進中括號——多位元組進 [] 會拆成單一位元組）。
fix_shas() {
  printf '%s' "$1" | LC_ALL=C grep -oE '已修([[:space:]]|`|\*|\(|（)*[0-9A-Za-z]+' \
    | LC_ALL=C sed -E 's/^已修([[:space:]]|`|\*|\(|（)*//' | LC_ALL=C grep -E '^[0-9a-f]{7,40}$' | paste -s -d, -
}
n=0; bad_a=0; bad_b=0; pool_claims=; fix_claims=
while IFS= read -r line || [ -n "$line" ]; do
  n=$((n + 1))
  line=${line%$'\r'}
  is_pool=0
  case "$line" in *入池*|*待辦池*) is_pool=1 ;; esac
  if [ "$is_pool" -eq 0 ] && printf '%s' "$line" | grep -qE "(^|[^A-Za-z0-9])${pool}([^0-9]|$)"; then is_pool=1; fi
  if [ "$is_pool" -eq 1 ]; then
    ids=$(hex_tokens "$line" 8 '')
    if [ -z "$ids" ]; then
      echo "✗ pr-body-check：第 ${n} 行提到 ${pool}／入池／待辦池，但沒有 comment id（≥8 位 hex）：" >&2
      echo "    | ${line}" >&2
      bad_a=1
    else
      pool_claims="${pool_claims}${n} ${ids}"$'\n'
    fi
  fi
  case "$line" in
    *已修*)
      shas=$(fix_shas "$line")
      if [ -z "$shas" ]; then
        echo "✗ pr-body-check：第 ${n} 行含「已修」，但沒有 commit SHA 緊鄰在『已修』之後（7–40 位小寫 hex；行內其他 hex 不算候選）：" >&2
        echo "    | ${line}" >&2
        bad_b=1
      else
        fix_claims="${fix_claims}${n} ${shas}"$'\n'
      fi ;;
  esac
done < "$file"
if [ "$bad_a" -eq 1 ]; then
  echo "  記入 ${pool} 必附 comment id：先 mcp__linear__save_comment 寫進 ${pool} 取得 id，再把 id（前 8 位以上）寫在同一行，如「記入 ${pool} \`9f348e36\`」；沒有 id 的「記入」視為沒寫。" >&2
fi
if [ "$bad_b" -eq 1 ]; then
  echo "  已修行需附 commit SHA 於『已修』之後：每條「已修」必附 commit SHA（＋檔案:行號）寫在同一行、SHA 緊跟「已修」，如「已修 \`7c2ff80\` \`Foo.swift:12\`」；comment id 放 SHA 後的括號（「已修 \`7c2ff80\`（comment \`d87d4334\`）」）；沒有 SHA 的「已修」視為未修（LS-140／LS-186）。" >&2
fi
if [ "$bad_a" -eq 1 ] || [ "$bad_b" -eq 1 ]; then
  echo "  全 body 逐行掃、不辨語境：此行若只是引用而非本 PR 的申報（如「LS-138 已修」「不另立 ${pool} 池項」），請改寫措辭避開字樣（LS-140，COLLABORATION §3／§7）。" >&2
  red_exit
fi
n_pool=$(printf '%s' "$pool_claims" | grep -c .)
n_fix=$(printf '%s' "$fix_claims" | grep -c .)
if [ "$verify" -eq 0 ]; then
  echo "✓ 申報格式：${pool} 行 ${n_pool} 條皆帶 comment id、「已修」行 ${n_fix} 條皆帶 SHA（--verify 才反查）"
  exit 0
fi

# ---- --verify (b)：「已修」緊鄰候選至少一個是 commit object 且為 HEAD 祖先（需在 repo 內執行）----
# 兩種紅分開講（LS-186）：候選全都不是 commit object（Linear comment id 形狀、打錯的 SHA）→「需附 commit SHA 於『已修』之後」；
# 是 commit 但不是 HEAD 祖先（他分支、未 push）→「不在 PR commits 內」。LS-185 當時兩者混成一句，實作者照著找不存在的 commit。
fail=0
while read -r ln toks; do
  [ -n "$ln" ] || continue
  ok=; is_commit=
  for t in $(printf '%s' "$toks" | tr , ' '); do
    git cat-file -e "${t}^{commit}" 2>/dev/null || continue
    is_commit=$t
    if git merge-base --is-ancestor "$t" HEAD 2>/dev/null; then ok=$t; break; fi
  done
  if [ -n "$ok" ]; then
    echo "✓ 第 ${ln} 行「已修」SHA ${ok} 在 PR commits 內"
  elif [ -z "$is_commit" ]; then
    echo "✗ pr-body-check：第 ${ln} 行「已修」之後的 token 不是本 repo 的 commit（候選：${toks}）——已修行需附 commit SHA 於『已修』之後；Linear comment id／issue uuid 片段、未 push 或他 repo 的 SHA 都不算（LS-186）。" >&2
    fail=1
  else
    echo "✗ pr-body-check：第 ${ln} 行「已修」的 SHA 不在 PR commits 內（候選：${toks}）——須 git cat-file -e <sha> 且 git merge-base --is-ancestor <sha> HEAD 皆成立（需在 repo 內執行）；請確認 SHA 抄自本分支的 commit、且已 push。" >&2
    fail=1
  fi
done <<< "$fix_claims"

# ---- --verify (a)：LS-96 comment id 前綴比對（列出全部 comment id；comment(id:) 不吃前綴）----
if [ -n "$pool_claims" ]; then
  if [ -z "${LINEAR_API_KEY:-}" ]; then
    echo "pr-body-check：反查略過（無 LINEAR_API_KEY）——${pool} comment id ${n_pool} 條只驗了格式；本機 source .env 後、CI 設 secrets.LINEAR_API_KEY 才會反查（LS-140）"
    if [ "${GITHUB_ACTIONS:-}" = true ]; then
      echo "::warning::pr-body-check：反查略過（無 LINEAR_API_KEY）——${pool} comment id 只驗了格式，請補 repo secret LINEAR_API_KEY（LS-140）"
    fi
  else
    command -v python3 >/dev/null 2>&1 || { echo "✗ pr-body-check：--verify 反查需要 python3" >&2; exit 2; }
    command -v curl >/dev/null 2>&1 || { echo "✗ pr-body-check：--verify 反查需要 curl" >&2; exit 2; }
    work=$(mktemp -d) || { echo "✗ pr-body-check：mktemp 失敗" >&2; exit 2; }
    trap 'rm -rf "$work"' EXIT
    # 只讀（GraphQL query）、分頁到底、一行一個 id 到 $work/ids；任何失敗 exit 2（fail closed）。
    python3 - "$pool" > "$work/ids" <<'PY'
import json, os, subprocess, sys

pool = sys.argv[1]
token = os.environ.get("LINEAR_API_KEY", "")
url = "https://api.linear.app/graphql"
query = ("query($id: String!, $after: String) { issue(id: $id) { identifier "
         "comments(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { id } } } }")


def die(msg):
    sys.stderr.write("✗ pr-body-check：%s——fail closed\n" % msg)
    sys.exit(2)


after = None
while True:
    body = json.dumps({"query": query, "variables": {"id": pool, "after": after}})
    # token 只走 stdin config（-K -），不進 argv（patrol_linear.py R1 F3：ps 讀得到 argv）
    try:
        proc = subprocess.run(
            ["curl", "-sS", "--max-time", "25", "-X", "POST", url,
             "-H", "Content-Type: application/json", "--data", body, "-K", "-"],
            input='header = "Authorization: %s"\n' % token, capture_output=True, text=True, timeout=30,
        )
    except Exception as exc:  # noqa: BLE001 - 印出來讓人判斷
        die("curl 呼叫失敗（%s）" % exc)
    if proc.returncode != 0:
        die("curl 失敗（exit %d）：%s" % (proc.returncode, proc.stderr.strip()[:300]))
    try:
        data = json.loads(proc.stdout)
    except ValueError:
        die("Linear GraphQL 回應不是合法 JSON：%s" % proc.stdout[:300])
    if not isinstance(data, dict):
        die("Linear GraphQL 回應不是物件：%s" % proc.stdout[:300])
    if data.get("errors"):
        die("Linear GraphQL 錯誤：%s" % json.dumps(data["errors"], ensure_ascii=False)[:500])
    issue = (data.get("data") or {}).get("issue") or {}
    if issue.get("identifier") != pool:
        die("Linear 回應不是 %s（identifier=%r）" % (pool, issue.get("identifier")))
    conn = issue.get("comments") or {}
    for node in conn.get("nodes") or []:
        print(node["id"])
    info = conn.get("pageInfo") or {}
    if not info.get("hasNextPage"):
        break
    cursor = info.get("endCursor")
    if not cursor or cursor == after:
        die("Linear 分頁 cursor 異常（hasNextPage 但 endCursor=%r）" % cursor)
    after = cursor
PY
    rc=$?
    [ "$rc" -eq 0 ] || { echo "✗ pr-body-check：${pool} comment 清單取得失敗（exit ${rc}）——fail closed" >&2; exit 2; }
    total=$(grep -c . "$work/ids")
    while read -r ln toks; do
      [ -n "$ln" ] || continue
      ok=
      for t in $(printf '%s' "$toks" | tr , ' '); do
        if grep -q "^${t}" "$work/ids"; then ok=$t; break; fi
      done
      if [ -n "$ok" ]; then
        echo "✓ 第 ${ln} 行 ${pool} comment ${ok} 存在（$(grep -m1 "^${ok}" "$work/ids")）"
      else
        echo "✗ pr-body-check：第 ${ln} 行的 comment id 在 ${pool} 找不到（候選：${toks}；${pool} 現有 ${total} 則 comment）——id 要抄 save_comment 回傳的 id（前 8 位以上）；寫錯票或根本沒寫都會落到這裡。" >&2
        fail=1
      fi
    done <<< "$pool_claims"
  fi
fi

if [ "$fail" -eq 1 ]; then
  red_exit
fi
echo "✓ 申報反查：${pool} 行 ${n_pool} 條、「已修」行 ${n_fix} 條"
exit 0
