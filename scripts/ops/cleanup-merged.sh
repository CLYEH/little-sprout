#!/bin/bash
# 結案清理（LS-86）：掃描已完全併入 origin/main／origin/development 的 worktree／本機分支／遠端分支，
# 列出後在 --apply 模式下才實際清除；預設 dry-run（只列不動）。安全底線：絕不刪未併入的東西；
# dirty worktree（tracked 修改或未追蹤且非 ignored 的檔——LS-141 起 dirty 判定只看 `git status --porcelain`
# 不帶 --ignored，見下方 LS-141 段）一律略過並列出，只有殘留全部命中白名單（__pycache__/、.DS_Store，
# R2 起精確路徑元件比對，見 m1）且帶 --force 才視為可清；gitignore 掉的產物一律視為可丟、移除前印出清單供審計；
# 保護分支（main/test/development）、主 checkout、呼叫端目前所在目錄或其子目錄（R2 起，見 M1）
# 一律不碰；每個實際刪除動作前都先印出清單（dry-run 本身就是清單）。
#
# 用法：cleanup-merged.sh [--dry-run|--apply] [--force] [--force-unstarted] [--all] [--min-age <分鐘>] [LS-<n>] [--repo <path>]
#   --dry-run      （預設）只列出將執行的動作，不做任何變更
#   --apply        實際執行：git worktree remove／git branch -D／git push origin --delete。
#                  **必須**帶 LS-<n> 篩選或 --all 之一（R2 起強制，見 M4）——不帶票號的全域
#                  --apply 是 merge-review R1 M4 實跑重現的危險模式：會把「已併入但 agent 仍在
#                  同一個 worktree 續作下一輪」的在飛工作一併清掉。
#   --force        worktree 的殘留（tracked 修改／未追蹤非 ignored 檔）若「全部」命中白名單（__pycache__/、
#                  .DS_Store，精確路徑元件／basename 比對，不是子字串）視為可清（改用
#                  git worktree remove --force）；其餘殘留一律略過，不受本旗標影響。
#   --force-unstarted  （LS-141，限搭配指名 LS-<n>）「尚未開工」的 worktree（tip 與 base 相同、從未有自己的
#                  commit）也允許移除——票已 Canceled／Done 但本機無 LINEAR_API_KEY 可查時的替代旗標；有 key 時
#                  不必帶，腳本自己查 Linear 狀態（state.type 為 completed／canceled 才放行）。
#   --all          明確表示「這次真的要不帶票號全域清理」，解除上面 --apply 的票號要求
#   --min-age      分鐘數，預設 10：分支最後一次 commit 距現在若小於此值一律略過，不論是否已
#                  併入——剛併入的分支很可能是 agent 準備續作下一輪的同一個 worktree（R2 M4）
#   LS-<n>         只處理票號含這個字串的 worktree／分支／遠端分支（word-boundary 比對，
#                  LS-8 不會誤中 LS-86）
#   --repo <path>  任一 worktree 路徑皆可；主 checkout 由 git-common-dir 推得（同 patrol.sh）
#
# 開頭會 git fetch --prune origin 一次（同 promote.sh 的 (a)；R2 起加 --prune，見 M2：不 prune
# 會讓本機 refs/remotes/origin/* 殘留早被 GitHub delete_branch_on_merge 或別人手動刪掉的分支，
# (c) 段對著這些幽靈 ref 跑 push --delete 必定失敗）。fetch 失敗只警告、續用本機 origin/* 參考點
# （過期只會讓判定偏保守，不會多刪；open PR 查詢另外走 gh 即時 API，不受此影響）。
#
# 對象（票文 LS-86 G1）：
#  (a) worktree：分支已完全併入 origin/main 或 origin/development、真的有過自己的 commit
#      （has_real_history，見下）、乾淨（LS-141 起不含 ignored 內容）、非近期異動（--min-age，見 M4）
#      → git worktree remove ＋ git branch -D；指名 LS-<n> 且票已 completed／canceled（或 --force-unstarted）
#      時「尚未開工」的 worktree 也一併移除（LS-141）
#  (b) 本機分支：條件同 (a) 但無對應 worktree → git branch -D
#  (c) 遠端分支：origin 上已併入、非保護、無 open PR、非近期異動 → git push origin --delete
#      （GitHub delete_branch_on_merge=true 生效後應罕見；R2 起 fetch 已加 --prune，若這裡仍常態
#        非 0，才需要懷疑 delete_branch_on_merge 設定或有人繞過 PR 直接 push 分支）
#  (d) mktemp -d 建的暫存殘留 worktree（路徑／目錄名落在系統暫存目錄樣式）：與 (a) 同一套判定，
#      只是額外標記方便辨識，不放寬安全門檻。R2 起 --apply 預設要求票號或 --all，這類無票號
#      命名的暫存 worktree 只能靠 --all 清（不再是「唯一路徑剛好是最危險的無差別 apply」）。
#
# 已併入的判定：merge-base --is-ancestor <ref> 對 origin/main 或 origin/development 任一為真即算
#（兩個 base 只要 fetch 得到就都檢查；一個都找不到 fail closed）。squash／rebase 併入的分支
# 不會被 --is-ancestor 命中（安全方向：漏清不誤刪）——本 repo 已在 GitHub 關閉 squash／rebase
# merge（COLLABORATION §7 promote 那列），故現況不受影響。
#
# has_real_history（R2 修正，merge-review R1 B1）：只看「reflog 是否有過 branch:Created／checkout:
# 以外的條目」分辨不出「做完工作」與「只是同步過」——git pull --ff-only／git reset --hard／
# git rebase／git merge（fast-forward）都會留下非 Created／checkout 的 reflog 條目，但分支從頭到尾
# 沒有自己的 commit，tip 仍等於 base。改成只認 reflog subject 開頭是 "commit"（commit／
# commit (initial)／commit (amend)／commit (merge)——這是 git 對「這個 ref 因為一次 commit 動作
# 前進」的唯一用語；pull／reset/rebase 的中繼步驟／fast-forward merge 都不是這個字首）。reflog
# append-only、只要「曾經」出現一筆就永遠 true，不因後續 reset／rebase 而消失——安全方向：只會
# 讓真做過事的分支持續被判定「已併入」，不會反過來把真做過事的分支誤判成「沒做過」。
# 依賴 reflog：gc.reflogExpire（預設 90 天）過期後老分支會退回 false，只會「漏清」不會「誤
# 刪」，方向安全；reflog 存在 $GIT_COMMON_DIR/logs/refs/heads/，不受 worktree 搬移／
# git worktree repair 影響。
#
# 安全機制總覽（R2 起）：
#  - cwd 自我保護：前綴比對（呼叫端在 worktree 根目錄「或其任何子目錄」都算，R2 修正 M1）
#  - --apply 預設要求 LS-<n> 或 --all（R2 修正 M4-a）
#  - --min-age 門檻：最後 commit 太新（可能還在飛）一律略過（R2 修正 M4-b）
#  - 刪除前立即重驗一次 is_merged_ref／has_real_history／乾淨度，縮小 TOCTOU 窗（R2 修正
#    M4-c；無法完全消除——bash 單執行緒下這是實務上能做到的最大縮窄，真正的鎖化留待後續票）
#  - dirty／殘留判定只看 plain porcelain（LS-141 推翻 R2 M3），白名單精確路徑元件比對（R2 修正 m1）
#  - 移除前查 Pen 目前 active 文件是否落在該 worktree 內，是則拒刪（LS-141）
#
# LS-141（來源 LS-96 池項 25a4ff4d／c7dae0e8／b410b190／aab3d640；推翻 R2 M3「ignored 內容視為 dirty」）：
#  - dirty 判定改回 plain `git status --porcelain`（不帶 --ignored）：只有 tracked 修改或未追蹤且非 ignored 的
#    檔才算 dirty。gitignore 掉的產物（Config/Secrets.xcconfig、supabase/.temp/、supabase/tests/evidence/、
#    .claude/evidence/……）一律視為可丟——每張 iOS／backend 票的 worktree 都必然有這些，M3 的判定讓腳本對真實
#    worktree 永遠沒用（2026-09-02～03 重踩 6 次，每次靠人手動 `git worktree remove --force`）。移除前另用
#    `--ignored=matching` 列出將一併丟掉的 ignored 路徑（dry-run 與 apply 都印，供審計：`.claude/evidence/<票>/`
#    若還沒引用到 Linear／PR，這是最後看見它的機會）。`git worktree remove` 對只含 ignored 檔的 worktree 不需
#    --force（git 2.47 實測），仍照原樣不帶 --force；若日後 git 版本改為拒絕，act() 會 fail loud，方向安全。
#  - 指名 `--apply LS-<n>` 時「尚未開工」的 worktree：Linear 狀態 completed／canceled（有 LINEAR_API_KEY 時以
#    GraphQL 查 state.type；token 只走 curl `-K -` stdin config、不進 argv，同 patrol_linear.py R1 F3）或帶
#    `--force-unstarted` → 允許移除（worktree remove＋branch -D）；否則照舊略過並印提示。不指名（--all）永不套用。
#  - 移除前呼叫 `pen-open.sh --status`（整次執行只呼叫一次、快取）：Pen 目前 active 文件落在該 worktree 內 →
#    拒刪並印處置（LS-119 事故：移掉 worktree 後 Pen 留下幽靈文件，最後只能 SIGKILL 重啟、全部 pencil MCP 斷線）。
#    --status 讀不到（Pen 沒開／pen CLI 不在 PATH）→ 印警告後視為未開、繼續（否則沒裝 pen 的機器與 CI 永遠
#    清不了）。盲區：--status 只回報 active 那一份，背景視窗開著同一路徑偵測不到。
#
# exit 0＝掃描／清理完成（無論有無找到項目）；1＝--apply 模式下至少一個動作實際失敗（fail loud）；
#      2＝參數或環境錯誤（不在 git repo、找不到 origin/main 與 origin/development 兩個 base、
#      --apply 未帶 LS-<n> 或 --all）。
# 自測：scripts/ops/cleanup-merged.test.sh（合成 repo，掛 CI rules job）。規約：docs/COLLABORATION.md §2、§7。
set -uo pipefail

MODE=dry-run; FORCE=0; FORCE_UNSTARTED=0; FILTER=; REPO=; ALLOW_ALL=0; MIN_AGE=10
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE=dry-run ;;
    --apply) MODE=apply ;;
    --force) FORCE=1 ;;
    --force-unstarted) FORCE_UNSTARTED=1 ;;
    --all) ALLOW_ALL=1 ;;
    --min-age)
      [ -n "${2:-}" ] || { echo "✗ cleanup-merged：--min-age 缺值" >&2; exit 2; }
      case "$2" in ''|*[!0-9]*) echo "✗ cleanup-merged：--min-age 須為整數分鐘（得到「$2」）" >&2; exit 2 ;; esac
      MIN_AGE=$2; shift ;;
    --repo)
      [ -n "${2:-}" ] || { echo "✗ cleanup-merged：--repo 缺值" >&2; exit 2; }
      REPO=$2; shift ;;
    -h|--help)
      echo "用法：cleanup-merged.sh [--dry-run|--apply] [--force] [--force-unstarted] [--all] [--min-age <分鐘>] [LS-<n>] [--repo <path>]（說明見檔頭註解）"; exit 0 ;;
    LS-[0-9]*) FILTER=$1 ;;
    -*) echo "✗ cleanup-merged：未知參數 $1" >&2; exit 2 ;;
    *) echo "✗ cleanup-merged：未知參數 $1" >&2; exit 2 ;;
  esac
  shift
done

# M4-a（merge-review R1）：--apply 不帶票號等於一次掃全部分支——實跑重現會把「已併入但 agent
# 仍在同一個 worktree 續作下一輪」的在飛工作一併清掉。強制要求明確意圖：指定票號只清一票，
# 或 --all 表示真的要不篩選地全域清理。dry-run 永遠安全，不受此限制。
if [ "$MODE" = apply ] && [ -z "$FILTER" ] && [ "$ALLOW_ALL" -ne 1 ]; then
  echo "✗ cleanup-merged：--apply 不帶 LS-<n> 篩選＝一次掃全部，這是已知危險模式（會誤清在飛 worktree，merge-review R1 M4）。請指定 LS-<n> 只清一票，或明確加 --all 表示真的要全域清理。" >&2
  exit 2
fi
# LS-141：尚未開工的 worktree 只在「指名單票」時才可能被移除——不帶票號的 --force-unstarted 沒有意義，直接拒。
if [ "$FORCE_UNSTARTED" -eq 1 ] && [ -z "$FILTER" ]; then
  echo "✗ cleanup-merged：--force-unstarted 只能搭配指名 LS-<n>（尚未開工的 worktree 只在指名單票時才允許移除，LS-141）。" >&2
  exit 2
fi

[ -n "$REPO" ] || REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ -d "$REPO" ] || { echo "✗ cleanup-merged：找不到 repo 目錄 ${REPO}" >&2; exit 2; }
common=$(git -C "$REPO" rev-parse --git-common-dir 2>/dev/null) || { echo "✗ cleanup-merged：${REPO} 不是 git repo" >&2; exit 2; }
case "$common" in /*) ;; *) common="${REPO}/${common}" ;; esac
ROOT=$(cd "$(dirname "$common")" && pwd)
# git worktree list --porcelain 回報的路徑是「物理」路徑（macOS 上會把 /var/folders/... 解成
# /private/var/folders/...），plain `pwd` 回報的是「邏輯」路徑（保留呼叫端 cd 進來時用的原始
# symlink 寫法）——兩者字串不同，直接比對會誤判「不是同一個目錄」而讓自我保護形同虛設
# （自測 ③ 實跑抓到：cwd 保護沒生效，worktree 被正常清掉）。用 `pwd -P` 解成物理路徑才能對上。
PWD_REAL=$(cd "$(pwd -P)" && pwd -P)
now=$(date +%s)

# M2（merge-review R1）：不加 --prune 時，本機 refs/remotes/origin/* 會殘留早被 GitHub
# delete_branch_on_merge 或別人手動刪掉的分支——真實 repo 實測 22 條本機 tracking ref 對 5 條
# 遠端實際存在的分支，(c) 段對著幽靈 ref 跑 push --delete 100% 失敗且永遠不會收斂（每次重跑
# 重演）。--prune 讓本機視圖先對齊遠端現狀，(c) 段自然只看得到真的還存在的分支。
git -C "$ROOT" fetch -q --prune origin 2>/dev/null || echo "⚠ cleanup-merged：git fetch --prune origin 失敗，續用本機 origin/* 參考點（可能過期）" >&2

BASES=
for ref in origin/main origin/development; do
  git -C "$ROOT" rev-parse -q --verify "$ref" >/dev/null 2>&1 && BASES="${BASES}${ref} "
done
[ -n "$BASES" ] || { echo "✗ cleanup-merged：找不到 origin/main 或 origin/development（先 git fetch origin）" >&2; exit 2; }

# ---- 小工具 ----
is_protected() { case "$1" in main|test|development) return 0 ;; *) return 1 ;; esac; }
matches_filter() { [ -z "$FILTER" ] && return 0; printf '%s' "$1" | grep -qE "(^|[^0-9])${FILTER}([^0-9]|\$)"; }
is_merged_ref() {  # $1 = commit-ish；對 BASES 任一為 ancestor 即算已併入
  local c=$1 b
  for b in $BASES; do
    git -C "$ROOT" merge-base --is-ancestor "$c" "$b" 2>/dev/null && return 0
  done
  return 1
}
has_real_history() {  # $1 = 本機分支名；true＝reflog 顯示真的自己 commit 過（不是單純同步）
  # B1（merge-review R1）：只看「reflog 有沒有動過」分不出「做完工作」與「只是同步過」——
  # pull --ff-only／reset --hard／rebase／merge（fast-forward）都會留下非 Created／checkout 的
  # reflog 條目，但分支從未有過自己的 commit。改成只認 subject 開頭是 "commit" 的條目（commit／
  # commit (initial)／commit (amend)／commit (merge)——git 對「這個 ref 因為一次 commit 動作前進」
  # 的唯一用語），pull／reset／rebase 中繼步驟／fast-forward merge 的 subject 都不是這個字首。
  local had
  had=$(git -C "$ROOT" reflog show --format=%gs "refs/heads/$1" 2>/dev/null | grep -cE '^commit' || true)
  case "${had:-0}" in ''|*[!0-9]*) return 1 ;; esac
  [ "${had:-0}" -gt 0 ]
}
is_temp_path() {  # mktemp -d 產生、路徑未經整理的暫存 worktree：只看 basename 是否為 mktemp -d
  # 的預設樣式 tmp.XXXXXXXX——不看祖先目錄是否落在系統暫存目錄下，那樣太寬：本機或 CI 的整個
  # repo checkout／自測 work 目錄本身常常就在 $TMPDIR 之下（本票自測的合成 repo 正是這樣），
  # 對整段路徑比對會把一般乖乖放在 .claude/worktrees/<name> 下、名字正常的 worktree 也一併
  # 誤標成「暫存殘留」（自測①實跑抓到：LS-1-merged-clean 這種正常票號 worktree 被誤標）。
  local base
  base=$(basename "$1")
  case "$base" in tmp.*) return 0 ;; *) return 1 ;; esac
}
# m1／M3（merge-review R1）：白名單須對「路徑」做精確元件比對，不是對整行 porcelain 輸出做
# 子字串／字尾比對——原本 *__pycache__*／*.DS_Store 會誤放行 notes-on-__pycache__-cleanup.md
# （含子字串）與 evidence.DS_Store（字尾命中但不是精確檔名）。residue_path_from_line 從
# porcelain 行（LS-141 起為 plain porcelain，不再有 "!!" 行）取出路徑（rename 取新路徑、去掉 C-quote
# 包裹的引號），is_whitelisted_path 才是唯一的白名單判斷：__pycache__ 必須是完整路徑元件
# （自己或作為某層目錄），.DS_Store 必須是 basename 精確相等。
residue_path_from_line() {
  local line=$1 path
  path=${line:3}
  case "$path" in *' -> '*) path=${path#*' -> '} ;; esac
  case "$path" in \"*\") path=${path#\"}; path=${path%\"} ;; esac
  printf '%s' "$path"
}
is_whitelisted_path() {
  local p=${1%/}
  case "$p" in
    __pycache__|*/__pycache__) return 0 ;;
  esac
  case "$p" in
    */__pycache__/*) return 0 ;;
  esac
  case "$(basename "$p")" in
    .DS_Store) return 0 ;;
  esac
  return 1
}
has_only_whitelisted_residue() {  # $1 = git status --porcelain 輸出（可能多行）
  local line path
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path=$(residue_path_from_line "$line")
    is_whitelisted_path "$path" || return 1
  done <<EOF
$1
EOF
  return 0
}
# LS-141（推翻 R2 M3）：worktree_status 只看 plain porcelain（tracked 修改＋未追蹤非 ignored）；ignored 內容
# 由 worktree_ignored 另列、移除前印出供審計（print_ignored_audit），不再當 dirty 擋——M3 當時擔心的
# .claude/evidence/<票>/、.env 是每張票 worktree 必有的 ignored 產物，把它們算 dirty 等於腳本永遠清不了任何
# 真實 worktree（LS-96 25a4ff4d／c7dae0e8）。
worktree_status() { git -C "$1" status --porcelain 2>/dev/null; }
worktree_ignored() { git -C "$1" status --porcelain --ignored=matching 2>/dev/null | sed -n 's/^!! //p'; }
print_ignored_audit() {  # $1=worktree 路徑 $2=顯示名；列出將隨 worktree remove 一起消失的 ignored 路徑（審計）
  local ign
  ign=$(worktree_ignored "$1")
  [ -n "$ign" ] || return 0
  printf '  ⓘ %s 將一併丟棄的 ignored 產物（審計，LS-141）：\n' "$2"
  printf '%s\n' "$ign" | sed 's/^/      /'
}
# LS-141：Pen 目前 active 文件——整次執行只呼叫一次 pen-open.sh --status（pen CLI 每次最多等 8 秒），結果快取在
# PEN_ACTIVE（空＝讀不到／未開）。路徑經 pwd -P 解成物理路徑，才能與 git worktree list 回報的物理路徑比對。
PEN_CHECKED=0; PEN_ACTIVE=
pen_probe() {
  [ "$PEN_CHECKED" -eq 0 ] || return 0
  PEN_CHECKED=1
  local p d
  p=$(bash "${SELF_DIR}/pen-open.sh" --status 2>/dev/null) || p=
  if [ -z "$p" ]; then
    echo "⚠ cleanup-merged：pen-open.sh --status 讀不到 Pen 目前文件（Pen 沒開／pen CLI 不在 PATH）——視為 Pen 未開著任何 worktree 的 .pen，繼續（LS-141；只看 active 那一份，背景視窗偵測不到）" >&2
    return 0
  fi
  d=$(cd "$(dirname "$p")" 2>/dev/null && pwd -P) && p="${d}/$(basename "$p")"
  PEN_ACTIVE=$p
}
pen_guard() {  # $1=worktree 路徑 $2=分支 $3=顯示名；Pen 目前 active 文件落在該 worktree 內 → 記略過、印處置、回 1
  pen_probe
  [ -n "$PEN_ACTIVE" ] || return 0
  case "$PEN_ACTIVE" in "$1"/*) ;; *) return 0 ;; esac
  wt_skipped_pen=$((wt_skipped_pen + 1))
  OUT_WT="${OUT_WT}  ✗ ${3} ${2}：Pen 目前開著 ${PEN_ACTIVE}，拒刪（移掉會留下幽靈文件，LS-119 事故）——處置：先 bash scripts/ops/pen-open.sh ${ROOT} 把 Pen 切回主 checkout（該 worktree 有未落地變更則先 bash scripts/ops/pen-land.sh ${1}），再重跑本指令"$'\n'
  return 1
}
# LS-141：查 Linear 票狀態（只讀 GraphQL）。印「<state.type> <state.name>」；無 LINEAR_API_KEY／缺 curl 或 python3／
# 呼叫失敗／回應不是該票 → 印空、回 1（呼叫端視為「查不到」，不放行）。token 只走 curl -K - 的 stdin config。
linear_state() {  # $1 = LS-<n>
  [ -n "${LINEAR_API_KEY:-}" ] || return 1
  command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || return 1
  local body out
  body=$(printf '{"query":"query($id:String!){issue(id:$id){identifier state{name type}}}","variables":{"id":"%s"}}' "$1")
  out=$(printf 'header = "Authorization: %s"\n' "$LINEAR_API_KEY" \
    | curl -sS --max-time 25 -X POST https://api.linear.app/graphql -H 'Content-Type: application/json' --data "$body" -K - 2>/dev/null) || return 1
  printf '%s' "$out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
if not isinstance(d, dict) or d.get("errors"):
    sys.exit(1)
i = (d.get("data") or {}).get("issue") or {}
if i.get("identifier") != sys.argv[1]:
    sys.exit(1)
s = i.get("state") or {}
print("%s %s" % (s.get("type", ""), s.get("name", "")))
' "$1"
}
last_commit_epoch() { git -C "$ROOT" log -1 --format=%ct "$1" 2>/dev/null || true; }  # $1=commit-ish
too_recent() {  # $1=commit-ish；true＝最後 commit 距現在 < MIN_AGE 分鐘（M4-b）
  local ep age
  ep=$(last_commit_epoch "$1")
  case "$ep" in ''|*[!0-9]*) return 1 ;; esac   # 拿不到時間就不擋（fail-open 在這個方向是安全的：
                                                  # 沒有時間依據時仍會被上面的 merge／history 判定把關）
  age=$(( (now - ep) / 60 ))
  [ "$age" -lt "$MIN_AGE" ]
}
act() {  # $1 = 人讀描述；其餘 = 實際指令（陣列，不經字串重解析，路徑帶空白／引號也安全）
  # m3（merge-review R1）：回傳實際成功與否（dry-run／成功皆 0，失敗 1），呼叫端只在真的成功
  # 時才計入 _removed 計數——原本函式恆回 0（最後一條指令是 printf 或算術指定，兩者都是 0），
  # 呼叫端因此不論成功失敗都無條件 ++，摘要與 ⚠ 提示會謊報「已清理」。
  local desc="$1"; shift
  if [ "$MODE" = dry-run ]; then
    printf '  [dry-run] %s\n' "$desc"
    return 0
  fi
  local out
  if out=$("$@" 2>&1); then
    printf '  → %s\n' "$desc"
    return 0
  else
    printf '  ✗ 失敗：%s\n' "$desc" >&2
    printf '%s\n' "$out" | sed 's/^/      /' >&2
    fail=$((fail + 1))
    return 1
  fi
}

fail=0
wt_removed=0; wt_skipped_dirty=0; wt_skipped_unmerged=0; wt_skipped_recent=0; wt_skipped_race=0; wt_skipped_pen=0
br_removed=0; br_skipped_unmerged=0; br_skipped_recent=0
rb_removed=0; rb_skipped_pr=0; rb_skipped_nogh=0; rb_skipped_recent=0
OUT_WT=; OUT_BR=; OUT_RB=
WT_BRANCHES=$'\n'   # (a) 段處理過的分支列表，(b) 段要排除（避免對同一分支動兩次）

main_branch=$(git -C "$ROOT" symbolic-ref --short -q HEAD 2>/dev/null || echo '')

# ---- (a)(d) worktree ----
process_wt() {
  local w="$cur_path" b="$cur_branch" det="$cur_det" name temp_tag=
  name=$(basename "$w")
  [ "$det" -eq 1 ] && return
  [ -n "$b" ] || return
  # 這條分支「有對應 worktree」這件事，不論下面決定動不動它都成立——一定要在任何提早 return
  # 之前先記下來，(b) 段（本機分支、無 worktree）才不會誤判成「無 worktree」而獨立對同一條分支
  # 動手（自測③抓到：cwd 自我保護擋下 worktree 移除後，(b) 段仍嘗試 `git branch -D` 同一條分支——
  # 該分支其實正被另一個 worktree checkout 著，git 拒絕、被算成失敗，exit code 因此非 0）。
  WT_BRANCHES="${WT_BRANCHES}${b}"$'\n'
  is_protected "$b" && return
  [ "$w" = "$ROOT" ] && return
  # M1（merge-review R1）：原本是精確等值比對，呼叫端 cd 進 worktree 的「子目錄」（例如
  # <worktree>/scripts）就對不上、保護完全失效，worktree 在自己腳下被 remove。改成前綴比對：
  # cwd 等於 worktree 根目錄本身、或在其任何子目錄底下，都算「目前所在目錄，絕不碰」。
  case "$PWD_REAL" in
    "$w"|"$w"/*)
      OUT_WT="${OUT_WT}  ⚠ 略過（目前所在目錄或其子目錄，絕不碰）：${name} ${b}"$'\n'
      return
      ;;
  esac
  matches_filter "${b} ${name}" || return

  is_temp_path "$w" && temp_tag="（暫存殘留）"

  if [ ! -d "$w" ]; then
    if is_merged_ref "$b" && has_real_history "$b"; then
      act "prune 已消失的 worktree 記錄 ${name}${temp_tag}（${b}，已併入）" git -C "$ROOT" worktree prune
      if act "刪除本機分支 ${b}（已併入）" git -C "$ROOT" branch -D "$b"; then
        wt_removed=$((wt_removed + 1))
      fi
    else
      OUT_WT="${OUT_WT}  ⚠ ${name}${temp_tag} ${b}：目錄已不存在但分支未併入（或從未開工）→ 只 prune 記錄、不刪分支"$'\n'
      act "prune 已消失的 worktree 記錄 ${name}（分支未併入，不刪分支）" git -C "$ROOT" worktree prune
      wt_skipped_unmerged=$((wt_skipped_unmerged + 1))
    fi
    return
  fi

  local dirty force_needed=0
  dirty=$(worktree_status "$w")
  if [ -n "$dirty" ]; then
    if [ "$FORCE" -eq 1 ] && has_only_whitelisted_residue "$dirty"; then
      force_needed=1
    else
      wt_skipped_dirty=$((wt_skipped_dirty + 1))
      OUT_WT="${OUT_WT}  ⚠ ${name}${temp_tag} ${b}：dirty（tracked 修改或未追蹤非 ignored 檔），略過（$(printf '%s' "$dirty" | tr '\n' ';')）"$'\n'
      return
    fi
  fi

  if is_merged_ref "$b" && has_real_history "$b"; then
    # M4-b：最後 commit 太新——可能是 agent 剛完成 R1、準備在同一個 worktree 續作 R2，不能碰。
    if too_recent "$b"; then
      wt_skipped_recent=$((wt_skipped_recent + 1))
      OUT_WT="${OUT_WT}  ⏳ ${name}${temp_tag} ${b}：已併入但最後 commit 未滿 ${MIN_AGE} 分鐘，略過（避免誤清在飛續作，--min-age 可調整）"$'\n'
      return
    fi
    # M4-c：刪除前立即重驗一次（縮小 TOCTOU 窗——初次判定到這裡之間，理論上可能有別的行程
    # 對同一個 worktree 動了手腳；重驗不能完全消除窗口，但把窗口縮到「重驗到 act() 之間」這
    # 一瞬間，比原本「整個掃描過程」小得多）。
    local dirty2
    dirty2=$(worktree_status "$w")
    if ! is_merged_ref "$b" || ! has_real_history "$b" || { [ -n "$dirty2" ] && { [ "$FORCE" -ne 1 ] || ! has_only_whitelisted_residue "$dirty2"; }; }; then
      wt_skipped_race=$((wt_skipped_race + 1))
      OUT_WT="${OUT_WT}  ⚠ ${name}${temp_tag} ${b}：刪除前重驗發現狀態已變化，略過（可能有人正在動這個 worktree）"$'\n'
      return
    fi
    # LS-141：Pen 開著這個 worktree 的 .pen → 拒刪；否則先列出將一併丟掉的 ignored 產物（審計）再動手。
    pen_guard "$w" "$b" "${name}${temp_tag}" || return
    print_ignored_audit "$w" "${name}${temp_tag}"
    local ok=1
    if [ "$force_needed" -eq 1 ]; then
      act "移除 worktree ${name}${temp_tag}（${b}，殘留為白名單 __pycache__/.DS_Store，--force）" \
        git -C "$ROOT" worktree remove --force "$w" || ok=0
    else
      act "移除 worktree ${name}${temp_tag}（${b}，已併入且乾淨）" git -C "$ROOT" worktree remove "$w" || ok=0
    fi
    act "刪除本機分支 ${b}（已併入）" git -C "$ROOT" branch -D "$b" || ok=0
    [ "$ok" -eq 1 ] && wt_removed=$((wt_removed + 1))
  elif is_merged_ref "$b"; then
    # tip 與 base 相同、但 reflog 從未真的動過——這是「剛建好、還沒開工」，不是「已併入被遺忘」；
    # 刪了就是把準備要用的 worktree 基礎設施砍掉，預設絕不碰（has_real_history 檔頭註解）。
    # LS-141（LS-96 b410b190）：唯一例外＝指名單票且票已收案——Linear state.type 為 completed／canceled
    # （有 LINEAR_API_KEY 時自動查）或帶 --force-unstarted——此時 worktree 是票 Done／Canceled 後的空殼，
    # 一併 remove＋branch -D。不指名（--all）永不套用；--min-age 不看（tip 是 base 的 commit，時間與本票無關）。
    local why= hint= st=
    if [ -n "$FILTER" ]; then
      if [ "$FORCE_UNSTARTED" -eq 1 ]; then
        why="--force-unstarted"
      elif st=$(linear_state "$FILTER"); then
        case "${st%% *}" in
          completed|canceled) why="Linear ${FILTER} 狀態 ${st#* }／${st%% *}" ;;
          *) hint="（Linear ${FILTER} 狀態 ${st#* }／${st%% *}，非 completed／canceled；確定要清請加 --force-unstarted）" ;;
        esac
      elif [ -z "${LINEAR_API_KEY:-}" ]; then
        hint="（無 LINEAR_API_KEY 查不到 Linear 狀態；票已 Canceled／Done 請加 --force-unstarted）"
      else
        hint="（Linear 查詢失敗；票已 Canceled／Done 請加 --force-unstarted）"
      fi
    fi
    if [ -n "$why" ]; then
      local dirty2
      dirty2=$(worktree_status "$w")
      if [ -n "$dirty2" ] && { [ "$FORCE" -ne 1 ] || ! has_only_whitelisted_residue "$dirty2"; }; then
        wt_skipped_race=$((wt_skipped_race + 1))
        OUT_WT="${OUT_WT}  ⚠ ${name}${temp_tag} ${b}：刪除前重驗發現狀態已變化，略過（可能有人正在動這個 worktree）"$'\n'
        return
      fi
      pen_guard "$w" "$b" "${name}${temp_tag}" || return
      print_ignored_audit "$w" "${name}${temp_tag}"
      local ok=1
      if [ "$force_needed" -eq 1 ]; then
        act "移除 worktree ${name}${temp_tag}（${b}，尚未開工；${why}；殘留為白名單，--force）" git -C "$ROOT" worktree remove --force "$w" || ok=0
      else
        act "移除 worktree ${name}${temp_tag}（${b}，尚未開工；${why}）" git -C "$ROOT" worktree remove "$w" || ok=0
      fi
      act "刪除本機分支 ${b}（尚未開工；${why}）" git -C "$ROOT" branch -D "$b" || ok=0
      [ "$ok" -eq 1 ] && wt_removed=$((wt_removed + 1))
      return
    fi
    wt_skipped_unmerged=$((wt_skipped_unmerged + 1))
    OUT_WT="${OUT_WT}  ${name}${temp_tag} ${b}：尚未開工（與 base 相同、從未有過自己的 commit），略過${hint}"$'\n'
  else
    wt_skipped_unmerged=$((wt_skipped_unmerged + 1))
    OUT_WT="${OUT_WT}  ${name}${temp_tag} ${b}：未併入（尚有獨有 commit），略過"$'\n'
  fi
}
cur_path=; cur_branch=; cur_det=0; first=1
flush_wt() {
  [ -n "$cur_path" ] || return 0
  if [ "$first" -eq 1 ]; then first=0; else process_wt; fi
  cur_path=; cur_branch=; cur_det=0
}
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    "worktree "*) flush_wt; cur_path=${line#worktree } ;;
    "branch refs/heads/"*) cur_branch=${line#branch refs/heads/} ;;
    detached) cur_det=1 ;;
  esac
done < <(git -C "$ROOT" worktree list --porcelain 2>/dev/null)
flush_wt

# ---- (b) 本機分支（無 worktree）----
while IFS= read -r b; do
  [ -n "$b" ] || continue
  is_protected "$b" && continue
  [ -n "$main_branch" ] && [ "$b" = "$main_branch" ] && continue
  printf '%s' "$WT_BRANCHES" | grep -qxF "$b" && continue
  matches_filter "$b" || continue
  if is_merged_ref "$b" && has_real_history "$b"; then
    if too_recent "$b"; then
      br_skipped_recent=$((br_skipped_recent + 1))
      OUT_BR="${OUT_BR}  ⏳ ${b}：已併入但最後 commit 未滿 ${MIN_AGE} 分鐘，略過"$'\n'
      continue
    fi
    # M4-c：本機分支段沒有檔案系統 dirty 檢查可重驗，緊接在同一個檢查後面再問一次
    # is_merged_ref／has_real_history 不會有任何新資訊（零耗時、無中間動作）——真正有意義的
    # TOCTOU 縮窄只在 (a) worktree 段成立（有 `git status` 的重新掃描可以拉開時間差），這裡
    # 不做假重驗；`git branch -D` 本身若該分支被其他 worktree checkout 就會直接失敗、算進
    # fail（m3 修正），不是靜默誤刪。
    if act "刪除本機分支 ${b}（已併入、無 worktree）" git -C "$ROOT" branch -D "$b"; then
      br_removed=$((br_removed + 1))
    fi
  else
    br_skipped_unmerged=$((br_skipped_unmerged + 1))
    OUT_BR="${OUT_BR}  ${b}：未併入或尚未開工，略過"$'\n'
  fi
done < <(git -C "$ROOT" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)

# ---- (c) 遠端分支（origin，已併入、無 open PR）----
# 用 %(refname) 全名而非 %(refname:short) 取分支名：refs/remotes/origin/HEAD 這種 symbolic ref 的
# short 形式會被 git 縮成 "origin"（不是 "origin/HEAD"），字尾比對會誤判成一條叫 origin 的分支
# （dry-run 對本 repo實跑時抓到——origin/HEAD → symref origin/main 被誤列成 "origin/origin"）。
gh_ok=1
command -v gh >/dev/null 2>&1 || gh_ok=0
# m2（merge-review R1）：原本對每條候選分支各呼叫一次 `gh pr list --head <b>`（N+1），真實 repo
# 16 條候選、單次約 0.5s、序列跑掉 8 秒。改成一次 `gh pr list --state open` 取全部 open PR 的
# head 分支名建表，之後全部用本機字串比對——不受單次網路抖動影響，且只需一次 API 呼叫。
OPEN_PR_HEADS=
if [ "$gh_ok" -eq 1 ]; then
  OPEN_PR_HEADS=$(cd "$ROOT" && gh pr list --state open --json headRefName --limit 200 -q '.[].headRefName' 2>/dev/null) || { gh_ok=0; OPEN_PR_HEADS=; }
fi
has_open_pr() { [ -n "$OPEN_PR_HEADS" ] && printf '%s\n' "$OPEN_PR_HEADS" | grep -qxF "$1"; }
while IFS= read -r fullref; do
  [ -n "$fullref" ] || continue
  case "$fullref" in
    refs/remotes/origin/HEAD) continue ;;
    refs/remotes/origin/*) b=${fullref#refs/remotes/origin/} ;;
    *) continue ;;
  esac
  rb="origin/${b}"
  is_protected "$b" && continue
  matches_filter "$b" || continue
  is_merged_ref "$rb" || continue
  if too_recent "$rb"; then
    rb_skipped_recent=$((rb_skipped_recent + 1))
    OUT_RB="${OUT_RB}  ⏳ ${b}：已併入但最後 commit 未滿 ${MIN_AGE} 分鐘，略過"$'\n'
    continue
  fi
  if [ "$gh_ok" -eq 0 ]; then
    rb_skipped_nogh=$((rb_skipped_nogh + 1))
    OUT_RB="${OUT_RB}  ${b}：已併入但 gh 不可用、無法確認 open PR，略過（不確定就不動）"$'\n'
    continue
  fi
  if has_open_pr "$b"; then
    rb_skipped_pr=$((rb_skipped_pr + 1))
    OUT_RB="${OUT_RB}  ${b}：已併入但仍有 open PR，略過"$'\n'
    continue
  fi
  if act "刪除遠端分支 origin/${b}（已併入、無 open PR）" git -C "$ROOT" push origin --delete "$b"; then
    rb_removed=$((rb_removed + 1))
  fi
done < <(git -C "$ROOT" for-each-ref --format='%(refname)' refs/remotes/origin/ 2>/dev/null)

# ---- 輸出 ----
echo "== cleanup-merged（${MODE} 模式；root ${ROOT}；min-age ${MIN_AGE}m）"
echo "== (a)(d) worktree（已併入且乾淨 → remove＋刪本機分支；暫存路徑額外標「暫存殘留」）"
[ -n "$OUT_WT" ] && printf '%s' "$OUT_WT" || echo "  （無略過項；動作見上方 act 輸出）"
echo "== (b) 本機分支（已併入、無對應 worktree → 刪）"
[ -n "$OUT_BR" ] && printf '%s' "$OUT_BR" || echo "  （無）"
echo "== (c) 遠端分支（origin 已併入、無 open PR → push --delete）"
[ -n "$OUT_RB" ] && printf '%s' "$OUT_RB" || echo "  （無）"
if [ "$rb_removed" -gt 0 ]; then
  echo "  ⚠ ${rb_removed} 條遠端分支經 (c) 清理——fetch 已 --prune，這不是本機 stale ref 造成的假陽性；若持續非 0，才需要核對 gh api repos/<owner>/<repo> --jq .delete_branch_on_merge 是否被改回 false，或是否有人繞過 PR 直接 push 分支"
fi
echo "== 摘要（${MODE}）：worktree ${wt_removed}／本機分支 ${br_removed}／遠端分支 ${rb_removed}（略過：worktree dirty ${wt_skipped_dirty}、worktree 未併入 ${wt_skipped_unmerged}、worktree 太新 ${wt_skipped_recent}、worktree 重驗生變 ${wt_skipped_race}、worktree Pen 開著 ${wt_skipped_pen}、本機分支未併入 ${br_skipped_unmerged}、本機分支太新 ${br_skipped_recent:-0}、遠端無法確認或有 PR $((rb_skipped_pr + rb_skipped_nogh))、遠端太新 ${rb_skipped_recent:-0}）"
if [ "$MODE" = dry-run ]; then
  echo "（dry-run：以上為將執行的動作，尚未做任何變更；加 --apply 實際執行）"
fi

if [ "$MODE" = apply ] && [ "$fail" -gt 0 ]; then
  echo "✗ cleanup-merged：${fail} 個動作實際失敗，見上方" >&2
  exit 1
fi
exit 0
