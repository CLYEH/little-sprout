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
#   (b) 含「已修」的行必須帶 7–40 位小寫 hex 的 commit SHA，且只認**同一行「已修」之後的第一個 hex token**：「已修 `7c2ff80`」
#       「**已修**（commit `7c2ff80`）」「已修：`7c2ff80`」「已修，改用 X。commit `7c2ff80`。」「| 已修：… | `7c2ff80` |」都算；
#       「…`d87d4334` …皆已修」不算（hex 在「已修」之前）；「已修（comment `d87d4334`，commit `7c2ff80`）」--verify 紅（第一個
#       hex 是 comment id）——「已修」之前的 hex 與第一個之後的 hex 都不是候選（LS-186：LS-185 PR body 標題行的 review comment id
#       被當 SHA 反查、CI 紅兩次；R1 版「緊鄰」會擋掉 repo 歷史 28% 的申報寫法，merge-review R1 minor-1 改採此規則。comment id
#       請寫在 SHA 之後）。
#   刻意全 body 掃、不辨「處置語境」（判語境太脆）：引用而非申報的行（「LS-138 已修」「不另立 LS-96 池項」）會誤中，
#   由 agent 改寫措辭避開字樣或補 id；LS-96 行多個 hex token 時任一可驗即過、「已修」行只看第一個「已修」之後的第一個 hex。
#   --verify 反查：(a) 用 LINEAR_API_KEY 打 Linear GraphQL 列出 LS-96 全部 comment id（分頁）做前綴比對——`comment(id:)`
#   只吃完整 UUID、不吃 agent 慣寫的 8 位前綴（2026-09-03 實測回「Entity not found: Comment」）；(b) 候選 SHA 須
#   `git cat-file -e <sha>^{commit}` 且 `git merge-base --is-ancestor <sha> HEAD`（CI 的 HEAD 是 PR merge ref，PR commits
#   皆為祖先；已在 base 上的 commit 也是祖先——盲區，COLLABORATION §7）；「已修」之後的第一個 hex 不是 commit object（comment id
#   形狀、打錯的 SHA）→ 紅「已修行需附 commit SHA 於『已修』之後」，是 commit 但非祖先 → 紅「不在 PR commits 內」（LS-186）。
#   無 LINEAR_API_KEY → 印「反查略過」只驗格式＋git
#   LS-198（LS-186 R2 info-1／2）：格式模式分不出短 SHA 與純數字 token（CI run id、migration 檔名前綴 20260904212530 都是 7–40 位
#   [0-9a-f]）——不帶 --verify 時對純數字候選印一行 ⚠ 警告、exit 不變（裁判仍是 --verify 的 git cat-file）；--verify 紅「不是本 repo
#   的 commit」時補「檔名／行號裡的數字也算 hex token，把 SHA 放『已修』後第一個」（殘餘誤紅多是 migration 檔名排在 SHA 之前）。
#   （CI 需 secrets.LINEAR_API_KEY）；curl／GraphQL 失敗 exit 2（fail closed）。token 只走 curl `-K -`（stdin config）不進
#   argv（同 patrol_linear.py R1 F3）。
#   LS-207（7902dc20）：curl 連線層失敗（逾時／連不上）先重試 3 次（退避 5／15／30s，PR_BODY_CHECK_LINEAR_BACKOFF 可覆寫供自測）
#   才 fail closed，訊息「Linear 不可達（重試 N 次仍逾時／連不上），非 body 問題」——單次 Linear API 間歇性逾時不該讓 agent／
#   reviewer 誤以為是 PR body 本身有問題。JSON 格式錯／GraphQL errors／回應不是本票 issue 這類「有回應但內容不對」不重試
#   （不是連線問題，重試也不會變好），維持原本立即 die。
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
# 「已修」的 SHA 候選（LS-186）：同一行第一個「已修」之後、第一個為 7–40 位小寫 hex 的獨立英數 token（token 規則同 hex_tokens：
# `x9f348e36y` 不算、`commit`／`：`／`，` 這類非 hex token 跳過）；「已修」之前的 hex（LS-185 標題行的 comment id）與之後的
# 第二個起都不算。`${1#*已修}` 是位元組字面比對，C／UTF-8 locale 皆穩。R1 版要求緊鄰（只隔空白／反引號／*／左括號）會擋掉
# repo 歷史 28% 的申報寫法（merge-review R1 minor-1 實測 60 個 PR），R2 改為此規則。
fix_shas() {
  local rest=${1#*已修}
  [ "$rest" != "$1" ] || return 0
  hex_tokens "$rest" 7 40 | cut -d, -f1
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
        echo "✗ pr-body-check：第 ${n} 行含「已修」，但『已修』之後沒有 commit SHA（7–40 位小寫 hex 的獨立 token；「已修」之前的 hex 不算）：" >&2
        echo "    | ${line}" >&2
        bad_b=1
      else
        fix_claims="${fix_claims}${n} ${shas}"$'\n'
        # LS-198：格式模式對純數字候選只警告不紅——它可能是 CI run id／migration 檔名前綴，--verify 才裁得出來
        if [ "$verify" -eq 0 ]; then
          case "$shas" in
            *[!0-9]*) ;;
            *) echo "⚠ pr-body-check：第 ${n} 行「已修」之後的第一個 hex token ${shas} 是純數字——若它是 CI run id／migration 檔名前綴而不是 commit SHA，--verify 會紅；檔名／行號裡的數字也算 hex token，把 SHA 放『已修』後第一個（LS-198）" ;;
          esac
        fi
      fi ;;
  esac
done < "$file"
if [ "$bad_a" -eq 1 ]; then
  echo "  記入 ${pool} 必附 comment id：先 mcp__linear__save_comment 寫進 ${pool} 取得 id，再把 id（前 8 位以上）寫在同一行，如「記入 ${pool} \`9f348e36\`」；沒有 id 的「記入」視為沒寫。" >&2
fi
if [ "$bad_b" -eq 1 ]; then
  echo "  已修行需附 commit SHA 於『已修』之後：每條「已修」必附 commit SHA（＋檔案:行號）寫在同一行、SHA 是「已修」之後的第一個 hex token，如「已修 \`7c2ff80\` \`Foo.swift:12\`」「**已修**（commit \`7c2ff80\`）」；comment id 寫在 SHA 之後（「已修 \`7c2ff80\`（comment \`d87d4334\`）」）；檔名／行號裡的數字也算 hex token（migration 前綴 \`20260904212530_…\`），把 SHA 放『已修』後第一個、檔名寫在 SHA 之後；沒有 SHA 的「已修」視為未修（LS-140／LS-186／LS-198）。" >&2
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

# ---- --verify (b)：「已修」之後的第一個 hex 候選須是 commit object 且為 HEAD 祖先（需在 repo 內執行）----
# 兩種紅分開講（LS-186）：候選不是 commit object（Linear comment id 形狀、打錯的 SHA）→「需附 commit SHA 於『已修』之後」；
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
    echo "✗ pr-body-check：第 ${ln} 行「已修」之後的第一個 hex token 不是本 repo 的 commit（候選：${toks}）——已修行需附 commit SHA 於『已修』之後，且 SHA 要寫在 comment id 之前；Linear comment id／issue uuid 片段、未 push 或他 repo 的 SHA 都不算（LS-186）；檔名／行號裡的數字也算 hex token（migration 前綴 \`20260904212530_…\`、CI run id），把 SHA 放『已修』後第一個、檔名寫在 SHA 之後（LS-198）。" >&2
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
import json, os, subprocess, sys, time

pool = sys.argv[1]
token = os.environ.get("LINEAR_API_KEY", "")
url = "https://api.linear.app/graphql"
query = ("query($id: String!, $after: String) { issue(id: $id) { identifier "
         "comments(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { id } } } }")

# LS-207（7902dc20）：2026-09-05 22:13～22:40 Linear API 間歇逾時，curl 25s --max-time 逾時就 fail-closed，讓
# #322／#305／#321 各多等一輪——單次逾時不該立刻判「body 有問題」。重試 3 次（退避 5／15／30s；三次皆逾時／連不上
# 才 fail closed）；訊息標明「非 body 問題」，agent／reviewer 看到就知道要 rerun 而不是去查 PR body。JSON 格式錯／
# GraphQL errors／回應非本票 issue 這類「有回應但內容不對」不算連線問題，不重試（重試也不會變好）。
# 退避秒數可用 PR_BODY_CHECK_LINEAR_BACKOFF（逗號分隔）覆寫，自測用極短延遲跑到底、不真的等 50 秒。
# LS-207 R2（merge-review R1 fd783f6c F1）：重試預算是**跨分頁共用**的單一計數器，不是每頁各一份——LS-96
# 現有 >250 則 comment、`comments(first: 100)` 需 ≥3 頁，若每頁各自重試 3 次（退避 5/15/30s＋每次 curl 最多
# 25s），3 頁最壞可達 3×150s＝450s，會把 CI `rules` job（370s 已逼近 timeout-minutes 上限）直接 timeout 取消，
# 連帶讓剛加的 `if: always()` 兩支自測也跑不到。retries_used 是所有頁共用的全域計數器：不論在哪一頁失敗，
# 消耗的都是同一份 3 次額度，總退避時間固定 ≤ sum(LINEAR_BACKOFF)（預設 50s），不會隨頁數疊加。
_backoff_raw = os.environ.get("PR_BODY_CHECK_LINEAR_BACKOFF", "5,15,30")
try:
    LINEAR_BACKOFF = [float(x) for x in _backoff_raw.split(",") if x.strip() != ""]
except ValueError:
    LINEAR_BACKOFF = [5.0, 15.0, 30.0]
# LS-207 R2（merge-review R1 fd783f6c I6）：PR_BODY_CHECK_LINEAR_BACKOFF="" 這種只有空白／全被濾掉的輸入會讓
# LINEAR_BACKOFF 變空陣列——len(LINEAR_BACKOFF)==0 時重試預算等於 0 次，die() 訊息會印出無意義的「重試 0 次仍
# 逾時」；只有自測會刻意覆寫這個變數（真正呼叫端從不設），退回預設值比讓重試名額悄悄歸零更安全。
if not LINEAR_BACKOFF:
    LINEAR_BACKOFF = [5.0, 15.0, 30.0]


def die(msg):
    sys.stderr.write("✗ pr-body-check：%s——fail closed\n" % msg)
    sys.exit(2)


def curl_call(argv, input_str):
    """單次呼叫：回傳 (ok, proc, err)。連線層失敗（例外／非 0 exit，即逾時／連不上的形狀）不在這裡 die，交呼叫端重試。"""
    try:
        proc = subprocess.run(argv, input=input_str, capture_output=True, text=True, timeout=30)
    except Exception as exc:  # noqa: BLE001 - 印出來讓人判斷
        return False, None, "curl 呼叫失敗（%s）" % exc
    if proc.returncode != 0:
        return False, proc, "curl 失敗（exit %d）：%s" % (proc.returncode, proc.stderr.strip()[:300])
    return True, proc, None


# LS-207 R2（fd783f6c F1）：跨分頁共用的重試計數器（不是每頁各一份）——list 包一層才能在函式呼叫間變動。
retries_used = [0]


def curl_with_retry(argv, input_str):
    err = None
    while True:
        ok, proc, err = curl_call(argv, input_str)
        if ok:
            return proc
        if retries_used[0] >= len(LINEAR_BACKOFF):
            die("Linear 不可達（跨分頁共用重試預算已用完，累計重試 %d 次仍逾時／連不上），非 body 問題：%s" % (len(LINEAR_BACKOFF), err))
        time.sleep(LINEAR_BACKOFF[retries_used[0]])
        retries_used[0] += 1


after = None
while True:
    body = json.dumps({"query": query, "variables": {"id": pool, "after": after}})
    # token 只走 stdin config（-K -），不進 argv（patrol_linear.py R1 F3：ps 讀得到 argv）
    proc = curl_with_retry(
        ["curl", "-sS", "--max-time", "25", "-X", "POST", url,
         "-H", "Content-Type: application/json", "--data", body, "-K", "-"],
        'header = "Authorization: %s"\n' % token,
    )
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
