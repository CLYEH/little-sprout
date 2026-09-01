#!/bin/bash
# 結案清理（LS-86）：掃描已完全併入 origin/main／origin/development 的 worktree／本機分支／遠端分支，
# 列出後在 --apply 模式下才實際清除；預設 dry-run（只列不動）。安全底線：絕不刪未併入的東西；
# dirty worktree（含未追蹤殘留）一律略過並列出，只有 --force 且殘留全部命中白名單
# （__pycache__/、.DS_Store）才視為可清；保護分支（main/test/development）、主 checkout、
# 呼叫端目前所在目錄一律不碰；每個實際刪除動作前都先印出清單（dry-run 本身就是清單）。
#
# 用法：cleanup-merged.sh [--dry-run|--apply] [--force] [LS-<n>] [--repo <path>]
#   --dry-run      （預設）只列出將執行的動作，不做任何變更
#   --apply        實際執行：git worktree remove／git branch -D／git push origin --delete
#   --force        worktree 的未提交殘留若「全部」命中白名單（__pycache__/、.DS_Store）視為可清
#                  （改用 git worktree remove --force）；其餘 dirty 一律略過，不受本旗標影響
#   LS-<n>         只處理票號含這個字串的 worktree／分支／遠端分支（word-boundary 比對，
#                  LS-8 不會誤中 LS-86）
#   --repo <path>  任一 worktree 路徑皆可；主 checkout 由 git-common-dir 推得（同 patrol.sh）
#
# 開頭會 git fetch origin 一次（同 promote.sh 的 (a)）；失敗只警告、續用本機 origin/* 參考點。
#
# 對象（票文 LS-86 G1）：
#  (a) worktree：分支已完全併入 origin/main 或 origin/development、且 worktree 乾淨
#      → git worktree remove ＋ git branch -D
#  (b) 本機分支：已併入、無對應 worktree → git branch -D
#  (c) 遠端分支：origin 上已併入、非保護、無 open PR → git push origin --delete
#      （GitHub delete_branch_on_merge=true 生效後應罕見——非 0 印提醒：多半是 CLI 直接 push
#        未經 PR 併入的分支，不代表 auto-delete 失效，仍值得核對設定值）
#  (d) mktemp -d 建的暫存殘留 worktree（路徑／目錄名落在系統暫存目錄樣式）：與 (a) 同一套
#      「乾淨＋已併入」判定，只是額外標記方便辨識，不放寬安全門檻——路徑落在暫存目錄
#      不表示內容可以不驗證就丟
#
# 已併入的判定：merge-base --is-ancestor <ref> 對 origin/main 或 origin/development 任一為真即算
#（兩個 base 只要 fetch 得到就都檢查；一個都找不到 fail closed）。branch -D 而非 -d：已經用
# merge-base 精確核對過安全性，不必再靠 git 對「目前 HEAD」的相對判斷（那個判斷在 ROOT 目前
# checkout 不是 development／main 的祖先鏈上時可能誤判成不安全、擋下我們已驗證過的安全刪除）。
#
# exit 0＝掃描／清理完成（無論有無找到項目）；1＝--apply 模式下至少一個動作實際失敗（fail loud）；
#      2＝參數或環境錯誤（不在 git repo、找不到 origin/main 與 origin/development 兩個 base）。
# 自測：scripts/ops/cleanup-merged.test.sh（合成 repo，掛 CI rules job）。規約：docs/COLLABORATION.md §2、§7。
set -uo pipefail

MODE=dry-run; FORCE=0; FILTER=; REPO=
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE=dry-run ;;
    --apply) MODE=apply ;;
    --force) FORCE=1 ;;
    --repo)
      [ -n "${2:-}" ] || { echo "✗ cleanup-merged：--repo 缺值" >&2; exit 2; }
      REPO=$2; shift ;;
    -h|--help)
      echo "用法：cleanup-merged.sh [--dry-run|--apply] [--force] [LS-<n>] [--repo <path>]（說明見檔頭註解）"; exit 0 ;;
    LS-[0-9]*) FILTER=$1 ;;
    -*) echo "✗ cleanup-merged：未知參數 $1" >&2; exit 2 ;;
    *) echo "✗ cleanup-merged：未知參數 $1" >&2; exit 2 ;;
  esac
  shift
done

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

# 先 fetch 一次（同 promote.sh 的 (a)）：讓「已併入」判定盡量對齊目前遠端狀態。過期的本機
# origin/* 只會讓判定偏保守（漏標，不會多刪）——open PR 查詢另外走 gh 即時 API，不受此影響——
# 所以失敗只警告續跑，不 fail closed。
git -C "$ROOT" fetch -q origin 2>/dev/null || echo "⚠ cleanup-merged：git fetch origin 失敗，續用本機 origin/* 參考點（可能過期）" >&2

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
has_real_history() {  # $1 = 本機分支名；true＝reflog 顯示曾經動過（不只是「建立／checkout」）
  # 只看 is_merged_ref 會誤殺剛建好、還沒開工的 worktree／分支：新分支從 origin/development
  # 切出來、0 commit 時，它的 tip 本來就等於（因此是祖先於）origin/development，會被
  # is_merged_ref 判定「已併入」——但那不是「已併入被遺忘」，是「還沒開始工作」，刪了就是把
  # 剛建好、準備要用的 worktree 基礎設施砍掉（同 patrol.sh 的 merged 判定：since=0 還要 reflog
  # 有真的動過才算「已併入」，不然算「尚未開工」）。只對本機分支有意義（reflog 是本機概念）；
  # (c) 段的純遠端分支不用這個檢查——遠端分支要存在必須先有人 push 過至少一個 commit，正常
  # workflow 不會出現「push 一個跟 base 一模一樣、從未有內容的分支」這種情況。
  local had
  had=$(git -C "$ROOT" reflog show --format=%gs "refs/heads/$1" 2>/dev/null | grep -vcE '^(branch: Created|checkout: )' || true)
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
has_only_whitelisted_residue() {  # $1 = git status --porcelain 輸出（可能多行）；全部命中白名單才算
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      *__pycache__*|*.DS_Store) ;;
      *) return 1 ;;
    esac
  done <<EOF
$1
EOF
  return 0
}
act() {  # $1 = 人讀描述；其餘 = 實際指令（陣列，不經字串重解析，路徑帶空白／引號也安全）
  local desc="$1"; shift
  if [ "$MODE" = dry-run ]; then
    printf '  [dry-run] %s\n' "$desc"
  else
    local out
    if out=$("$@" 2>&1); then
      printf '  → %s\n' "$desc"
    else
      printf '  ✗ 失敗：%s\n' "$desc" >&2
      printf '%s\n' "$out" | sed 's/^/      /' >&2
      fail=$((fail + 1))
    fi
  fi
}

fail=0
wt_removed=0; wt_skipped_dirty=0; wt_skipped_unmerged=0
br_removed=0; br_skipped_unmerged=0
rb_removed=0; rb_skipped_pr=0; rb_skipped_nogh=0
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
  if [ "$w" = "$PWD_REAL" ]; then
    OUT_WT="${OUT_WT}  ⚠ 略過（目前所在目錄，絕不碰）：${name} ${b}"$'\n'
    return
  fi
  matches_filter "${b} ${name}" || return

  is_temp_path "$w" && temp_tag="（暫存殘留）"

  if [ ! -d "$w" ]; then
    if is_merged_ref "$b" && has_real_history "$b"; then
      act "prune 已消失的 worktree 記錄 ${name}${temp_tag}（${b}，已併入）" git -C "$ROOT" worktree prune
      act "刪除本機分支 ${b}（已併入）" git -C "$ROOT" branch -D "$b"
      wt_removed=$((wt_removed + 1))
    else
      OUT_WT="${OUT_WT}  ⚠ ${name}${temp_tag} ${b}：目錄已不存在但分支未併入（或從未開工）→ 只 prune 記錄、不刪分支"$'\n'
      act "prune 已消失的 worktree 記錄 ${name}（分支未併入，不刪分支）" git -C "$ROOT" worktree prune
      wt_skipped_unmerged=$((wt_skipped_unmerged + 1))
    fi
    return
  fi

  local dirty force_needed=0
  dirty=$(git -C "$w" status --porcelain 2>/dev/null)
  if [ -n "$dirty" ]; then
    if [ "$FORCE" -eq 1 ] && has_only_whitelisted_residue "$dirty"; then
      force_needed=1
    else
      wt_skipped_dirty=$((wt_skipped_dirty + 1))
      OUT_WT="${OUT_WT}  ⚠ ${name}${temp_tag} ${b}：dirty，略過（$(printf '%s' "$dirty" | tr '\n' ';')）"$'\n'
      return
    fi
  fi

  if is_merged_ref "$b" && has_real_history "$b"; then
    if [ "$force_needed" -eq 1 ]; then
      act "移除 worktree ${name}${temp_tag}（${b}，殘留為白名單 __pycache__/.DS_Store，--force）" \
        git -C "$ROOT" worktree remove --force "$w"
    else
      act "移除 worktree ${name}${temp_tag}（${b}，已併入且乾淨）" git -C "$ROOT" worktree remove "$w"
    fi
    act "刪除本機分支 ${b}（已併入）" git -C "$ROOT" branch -D "$b"
    wt_removed=$((wt_removed + 1))
  elif is_merged_ref "$b"; then
    # tip 與 base 相同、但 reflog 從未真的動過——這是「剛建好、還沒開工」，不是「已併入被遺忘」；
    # 刪了就是把準備要用的 worktree 基礎設施砍掉，絕不能碰（has_real_history 檔頭註解）。
    wt_skipped_unmerged=$((wt_skipped_unmerged + 1))
    OUT_WT="${OUT_WT}  ${name}${temp_tag} ${b}：尚未開工（與 base 相同、從未有過獨有 commit），略過"$'\n'
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
    act "刪除本機分支 ${b}（已併入、無 worktree）" git -C "$ROOT" branch -D "$b"
    br_removed=$((br_removed + 1))
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
  if [ "$gh_ok" -eq 0 ]; then
    rb_skipped_nogh=$((rb_skipped_nogh + 1))
    OUT_RB="${OUT_RB}  ${b}：已併入但 gh 不可用、無法確認 open PR，略過（不確定就不動）"$'\n'
    continue
  fi
  pr_count=$(cd "$ROOT" && gh pr list --head "$b" --state open --json number -q 'length' 2>/dev/null) || pr_count=
  case "$pr_count" in
    ''|*[!0-9]*)
      rb_skipped_nogh=$((rb_skipped_nogh + 1))
      OUT_RB="${OUT_RB}  ${b}：已併入但查詢 open PR 失敗，略過（不確定就不動）"$'\n'
      continue ;;
  esac
  if [ "$pr_count" -gt 0 ]; then
    rb_skipped_pr=$((rb_skipped_pr + 1))
    OUT_RB="${OUT_RB}  ${b}：已併入但仍有 ${pr_count} 個 open PR，略過"$'\n'
    continue
  fi
  act "刪除遠端分支 origin/${b}（已併入、無 open PR）" git -C "$ROOT" push origin --delete "$b"
  rb_removed=$((rb_removed + 1))
done < <(git -C "$ROOT" for-each-ref --format='%(refname)' refs/remotes/origin/ 2>/dev/null)

# ---- 輸出 ----
echo "== cleanup-merged（${MODE} 模式；root ${ROOT}）"
echo "== (a)(d) worktree（已併入且乾淨 → remove＋刪本機分支；暫存路徑額外標「暫存殘留」）"
[ -n "$OUT_WT" ] && printf '%s' "$OUT_WT" || echo "  （無略過項；動作見上方 act 輸出）"
echo "== (b) 本機分支（已併入、無對應 worktree → 刪）"
[ -n "$OUT_BR" ] && printf '%s' "$OUT_BR" || echo "  （無）"
echo "== (c) 遠端分支（origin 已併入、無 open PR → push --delete）"
[ -n "$OUT_RB" ] && printf '%s' "$OUT_RB" || echo "  （無）"
if [ "$rb_removed" -gt 0 ]; then
  echo "  ⚠ ${rb_removed} 條遠端分支需 (c) 清理——GitHub delete_branch_on_merge 生效後應罕見；多半是 CLI 直接 push（未經 PR）併入的分支，不代表 auto-delete 失效，仍建議核對 gh api repos/<owner>/<repo> --jq .delete_branch_on_merge"
fi
echo "== 摘要（${MODE}）：worktree ${wt_removed}／本機分支 ${br_removed}／遠端分支 ${rb_removed}（略過：worktree dirty ${wt_skipped_dirty}、worktree 未併入 ${wt_skipped_unmerged}、本機分支未併入 ${br_skipped_unmerged}、遠端無法確認或有 PR $((rb_skipped_pr + rb_skipped_nogh))）"
if [ "$MODE" = dry-run ]; then
  echo "（dry-run：以上為將執行的動作，尚未做任何變更；加 --apply 實際執行）"
fi

if [ "$MODE" = apply ] && [ "$fail" -gt 0 ]; then
  echo "✗ cleanup-merged：${fail} 個動作實際失敗，見上方" >&2
  exit 1
fi
exit 0
