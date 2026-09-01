#!/bin/bash
# cleanup-merged.sh 的自測（LS-86）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對清理腳本也適用：若退化成——已併入卻不列／不刪、未併入卻被刪、dirty worktree
# 被清掉（含白名單以外的殘留）、保護分支或目前所在目錄被碰、遠端分支明明有 open PR 卻被
# push --delete、gh 不可用時悍然刪除、dry-run 產生副作用、LS-<n> 篩選誤中鄰近票號（LS-20 誤中
# LS-200）——這裡會紅。
# 合成 repo：file:// 裸 origin（main／development）＋clone 當主 checkout；多個 worktree／本機
# 分支／遠端分支各一種形狀。所有「已併入」的分支各自建好、push 後用一條 integrate 分支一次
# merge 齊全再單次 push 到 development（避免逐一 push 到 development 時彼此不是對方祖先、
# fast-forward 互撞）。gh 用 PATH 上的 stub（依 --head 決定回報幾個 open PR）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cleanup="${root}/scripts/ops/cleanup-merged.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

has()   { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✓ $1"; else echo "✗ ${1}（輸出應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; fi; }
rc_is() { if [ "$3" -eq "$2" ]; then echo "✓ $1"; else echo "✗ ${1}（期望 exit ${2}，實得 ${3}）" >&2; printf '%s\n' "$4" | sed 's/^/    /' >&2; fail=1; fi; }
exists_wt() { [ -d "$1" ] && echo "✓ $2" || { echo "✗ ${2}（worktree 目錄消失，本不該被動）" >&2; fail=1; }; }
gone_wt()   { if [ -d "$1" ]; then echo "✗ ${2}（worktree 目錄仍在，本該被移除）" >&2; fail=1; else echo "✓ $2"; fi; }
has_branch() { git -C "$1" show-ref --verify -q "refs/heads/$2" && echo "✓ $3" || { echo "✗ ${3}（本機分支 $2 不見了，本不該被刪）" >&2; fail=1; }; }
no_branch()  { git -C "$1" show-ref --verify -q "refs/heads/$2" && { echo "✗ ${3}（本機分支 $2 仍在，本該被刪）" >&2; fail=1; } || echo "✓ $3"; }
has_remote() { git -C "$1" ls-remote --exit-code "$2" "refs/heads/$3" >/dev/null 2>&1 && echo "✓ $4" || { echo "✗ ${4}（遠端分支 $3 不見了，本不該被刪）" >&2; fail=1; }; }
no_remote()  { git -C "$1" ls-remote --exit-code "$2" "refs/heads/$3" >/dev/null 2>&1 && { echo "✗ ${4}（遠端分支 $3 仍在，本該被刪）" >&2; fail=1; } || echo "✓ $4"; }

# ---- stub gh：依 --head 決定回報幾個 open PR（GH_STUB_PR_OPEN 空白分隔的分支清單）----
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'EOF'
#!/bin/bash
head=
while [ $# -gt 0 ]; do case "$1" in --head) head=$2; shift ;; esac; shift; done
case " ${GH_STUB_PR_OPEN:-} " in
  *" ${head} "*) echo 1 ;;
  *) echo 0 ;;
esac
EOF
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" GH_STUB_PR_OPEN="LS-11-remote-haspr"

# ---- 合成 repo ----
remote="$work/remote.git"; g init -q --bare -b main "$remote"
seed="$work/seed"; g init -q -b main "$seed"
echo a > "$seed/file.txt"; g -C "$seed" add -A; g -C "$seed" commit -qm 'chore: LS-0 seed'
g -C "$seed" branch development
g -C "$seed" remote add origin "$remote"; g -C "$seed" push -q origin main development

# 每個要模擬「已併入」的項目各自一條分支＋一個 commit，各自 push 自己的分支名；全部建完後用
# integrate 分支依序 merge、單次 push 到 development（避免互不為祖先造成 FF 互撞）。
merged_branches="LS-1-merged-clean LS-3-dirty-merged LS-4-whitelist LS-5-temp-merged LS-7-selfprotect LS-10-remote-nopr LS-11-remote-haspr LS-12-remote-nogh"
for b in $merged_branches; do
  g -C "$seed" checkout -q main
  g -C "$seed" checkout -q -b "$b"
  echo "$b" > "$seed/${b}.txt"; g -C "$seed" add -A; g -C "$seed" commit -qm "feat: ${b}"
  g -C "$seed" push -q origin "$b"
done
g -C "$seed" checkout -q main
g -C "$seed" checkout -q -b integrate origin/development
for b in $merged_branches; do g -C "$seed" merge -q --no-edit "$b"; done
g -C "$seed" push -q origin integrate:development
g -C "$seed" checkout -q main
g -C "$seed" branch -D integrate
for b in $merged_branches; do g -C "$seed" branch -D "$b"; done

repo="$work/repo"; g clone -q "$remote" "$repo"
wts="$repo/.claude/worktrees"; mkdir -p "$wts"
wt() { g -C "$repo" worktree add "$@" >/dev/null 2>&1 || { echo "✗ 建 worktree 失敗：$*" >&2; exit 1; }; }

# ① LS-1-merged-clean：worktree，內容取自已併入 development 的 origin 分支，乾淨
wt -b LS-1-merged-clean "$wts/LS-1-merged-clean" origin/LS-1-merged-clean

# ② LS-2-unmerged：worktree，從 development 切出後自己加一個獨有 commit，未併入
wt -b LS-2-unmerged "$wts/LS-2-unmerged" origin/development
echo 2 > "$wts/LS-2-unmerged/two.txt"; g -C "$wts/LS-2-unmerged" add -A; g -C "$wts/LS-2-unmerged" commit -qm 'feat: two'

# ③ LS-3-dirty-merged：worktree，內容已併入，但有未提交的 tracked 變更
wt -b LS-3-dirty-merged "$wts/LS-3-dirty-merged" origin/LS-3-dirty-merged
echo dirty >> "$wts/LS-3-dirty-merged/LS-3-dirty-merged.txt"

# ④ LS-4-whitelist：worktree，內容已併入，殘留只有白名單（__pycache__/、.DS_Store）
wt -b LS-4-whitelist "$wts/LS-4-whitelist" origin/LS-4-whitelist
mkdir -p "$wts/LS-4-whitelist/__pycache__"; echo x > "$wts/LS-4-whitelist/__pycache__/x.pyc"
touch "$wts/LS-4-whitelist/.DS_Store"

# ⑤ LS-5-temp-merged：暫存路徑（mktemp -d，非 .claude/worktrees 下），內容已併入、乾淨
tmp_wt="$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXX")"; rmdir "$tmp_wt"
wt -b LS-5-temp-merged "$tmp_wt" origin/LS-5-temp-merged

# ⑥ 保護分支 worktree（development）與 detached worktree：絕不可被列出或碰
wt "$work/dev-wt" development
wt --detach "$work/detached-wt"

# ⑦ LS-7-selfprotect：worktree，內容已併入、乾淨，但呼叫時 cwd 就在裡面 → 絕不可被動
wt -b LS-7-selfprotect "$wts/LS-7-selfprotect" origin/LS-7-selfprotect

# ⑧⑨ 本機分支（無 worktree）：一個已併入、一個未併入（皆從 development 切，事後才知道結果）
g -C "$repo" fetch -q origin
g -C "$repo" branch LS-8-local-merged origin/development
g -C "$repo" branch LS-9-local-unmerged origin/development
( cd "$repo" && g checkout -q LS-9-local-unmerged && echo 9 > nine.txt && g add nine.txt && g commit -qm 'feat: nine' && g checkout -q main )

# LS-<n> 篩選邊界：LS-20 不得誤中 LS-200（皆已併入的本機分支）
g -C "$repo" branch LS-20-bound origin/development
g -C "$repo" branch LS-200-bound origin/development

# LS-10/11/12（純遠端、無本機分支／worktree）已經在 merged_branches 迴圈 push 過，development
# 也已併入它們——不需要在 repo 這邊另外建任何東西。

g -C "$repo" fetch -q origin

# ---- ① dry-run：零副作用，全部項目照原樣列出 ----
before_wt_count=$(git -C "$repo" worktree list --porcelain | grep -c '^worktree ')
before_branches=$(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads/ | sort)
out="$(bash "$cleanup" --dry-run --repo "$repo" 2>&1)"; rc=$?
rc_is '① dry-run exit 0' 0 "$rc" "$out"
has   '① dry-run 標示模式' "$out" 'cleanup-merged（dry-run 模式'
has   '① 列出 LS-1-merged-clean 已併入且乾淨（將移除）' "$out" '（LS-1-merged-clean，已併入且乾淨）'
has   '① 列出 LS-2-unmerged 未併入、略過' "$out" 'LS-2-unmerged：未併入（尚有獨有 commit），略過'
has   '① 列出 LS-3-dirty-merged dirty、略過' "$out" 'LS-3-dirty-merged：dirty，略過'
has   '① 列出 LS-4-whitelist dirty、略過（未加 --force）' "$out" 'LS-4-whitelist：dirty，略過'
has   '① 列出 LS-5-temp-merged 標「暫存殘留」' "$out" '（暫存殘留）（LS-5-temp-merged，已併入且乾淨）'
has_dev_absent=$(printf '%s' "$out" | grep -c 'dev-wt'); [ "$has_dev_absent" -eq 0 ] && echo "✓ ① 保護分支 worktree（development）不進表" || { echo "✗ ① 保護分支 worktree 不應進表" >&2; fail=1; }
has_det_absent=$(printf '%s' "$out" | grep -c 'detached-wt'); [ "$has_det_absent" -eq 0 ] && echo "✓ ① detached worktree 不進表" || { echo "✗ ① detached worktree 不應進表" >&2; fail=1; }
has   '① LS-8-local-merged 本機分支將被刪（已併入、無 worktree）' "$out" 'LS-8-local-merged（已併入、無 worktree）'
has   '① LS-9-local-unmerged 未併入、略過' "$out" 'LS-9-local-unmerged：未併入，略過'
has   '① LS-10-remote-nopr 遠端將被刪（已併入、無 open PR）' "$out" 'origin/LS-10-remote-nopr（已併入、無 open PR）'
has   '① LS-11-remote-haspr 遠端有 open PR、略過' "$out" 'LS-11-remote-haspr：已併入但仍有 1 個 open PR，略過'
after_wt_count=$(git -C "$repo" worktree list --porcelain | grep -c '^worktree ')
after_branches=$(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads/ | sort)
[ "$before_wt_count" -eq "$after_wt_count" ] && echo "✓ ① dry-run 未變動 worktree 數量" || { echo "✗ ① dry-run 不應變動 worktree 數量（前 ${before_wt_count} 後 ${after_wt_count}）" >&2; fail=1; }
[ "$before_branches" = "$after_branches" ] && echo "✓ ① dry-run 未變動本機分支清單" || { echo "✗ ① dry-run 不應變動本機分支清單" >&2; fail=1; }
has_remote "$repo" "$remote" LS-10-remote-nopr '① dry-run 未刪遠端分支 LS-10-remote-nopr'

# ---- ② gh 不可用（PATH 換成 /usr/bin:/bin，沒有 gh）：dry-run 應標「gh 不可用」且不動遠端分支 ----
out2="$(PATH=/usr/bin:/bin bash "$cleanup" --dry-run --repo "$repo" 2>&1)"; rc2=$?
rc_is '② gh 不可用時 exit 仍 0' 0 "$rc2" "$out2"
has   '② LS-12-remote-nogh 標「gh 不可用」、略過' "$out2" 'LS-12-remote-nogh：已併入但 gh 不可用'
has_remote "$repo" "$remote" LS-12-remote-nogh '② gh 不可用時未刪遠端分支 LS-12-remote-nogh'

# ---- ③ 目前所在目錄保護：cwd＝LS-7-selfprotect（已併入且乾淨，本可清）時絕不可被動；
#        用篩選 LS-7 把這次 apply 限定在它自己身上，避免這一步順便處理掉其他票 ----
out3="$(cd "$wts/LS-7-selfprotect" && bash "$cleanup" --apply --repo "$repo" LS-7 2>&1)"; rc3=$?
rc_is '③ cwd 自我保護 exit 0' 0 "$rc3" "$out3"
has   '③ 標示「目前所在目錄，絕不碰」' "$out3" '目前所在目錄，絕不碰'
exists_wt "$wts/LS-7-selfprotect" '③ LS-7-selfprotect worktree 仍在（cwd 保護生效）'
has_branch "$repo" LS-7-selfprotect '③ LS-7-selfprotect 本機分支仍在'

# ---- ④ LS-<n> 篩選邊界：只清 LS-20-bound，LS-200-bound 不受影響 ----
out4="$(bash "$cleanup" --apply --repo "$repo" LS-20 2>&1)"; rc4=$?
rc_is '④ 篩選 LS-20 exit 0' 0 "$rc4" "$out4"
no_branch  "$repo" LS-20-bound  '④ LS-20-bound 已刪（篩選命中）'
has_branch "$repo" LS-200-bound '④ LS-200-bound 未受影響（LS-20 不誤中 LS-200，word-boundary）'

# ---- ⑤ --apply（不加 --force，不篩選）：merged+clean 全部清掉；dirty／unmerged／
#        whitelist（未加 --force）／保護分支／detached／haspr 一律不動 ----
out5="$(bash "$cleanup" --apply --repo "$repo" 2>&1)"; rc5=$?
rc_is '⑤ apply exit 0（無失敗）' 0 "$rc5" "$out5"
has   '⑤ 摘要列出實際刪除數' "$out5" '摘要（apply）'
gone_wt "$wts/LS-1-merged-clean" '⑤ LS-1-merged-clean worktree 已移除'
no_branch "$repo" LS-1-merged-clean '⑤ LS-1-merged-clean 本機分支已刪'
exists_wt "$wts/LS-2-unmerged" '⑤ LS-2-unmerged worktree 仍在（未併入不動）'
has_branch "$repo" LS-2-unmerged '⑤ LS-2-unmerged 本機分支仍在'
exists_wt "$wts/LS-3-dirty-merged" '⑤ LS-3-dirty-merged worktree 仍在（dirty 不動）'
has_branch "$repo" LS-3-dirty-merged '⑤ LS-3-dirty-merged 本機分支仍在'
exists_wt "$wts/LS-4-whitelist" '⑤ LS-4-whitelist worktree 仍在（未加 --force，白名單殘留仍算 dirty）'
has_branch "$repo" LS-4-whitelist '⑤ LS-4-whitelist 本機分支仍在'
gone_wt "$tmp_wt" '⑤ LS-5-temp-merged（暫存路徑）worktree 已移除'
no_branch "$repo" LS-5-temp-merged '⑤ LS-5-temp-merged 本機分支已刪'
exists_wt "$work/dev-wt" '⑤ development worktree 仍在（保護分支絕不碰）'
exists_wt "$work/detached-wt" '⑤ detached worktree 仍在（detached 絕不碰）'
no_branch "$repo" LS-8-local-merged '⑤ LS-8-local-merged 本機分支已刪（已併入、無 worktree）'
has_branch "$repo" LS-9-local-unmerged '⑤ LS-9-local-unmerged 本機分支仍在（未併入）'
no_remote "$repo" "$remote" LS-10-remote-nopr '⑤ LS-10-remote-nopr 遠端分支已刪（已併入、無 open PR）'
has_remote "$repo" "$remote" LS-11-remote-haspr '⑤ LS-11-remote-haspr 遠端分支仍在（有 open PR）'
no_remote "$repo" "$remote" LS-12-remote-nogh '⑤ LS-12-remote-nogh 遠端分支已刪（本輪 gh 可用、無 open PR）'

# ---- ⑥ --force：LS-4-whitelist 的殘留全為白名單 → 應被清掉 ----
out6="$(bash "$cleanup" --apply --force --repo "$repo" LS-4 2>&1)"; rc6=$?
rc_is '⑥ --force exit 0' 0 "$rc6" "$out6"
has   '⑥ --force 訊息含「殘留為白名單」' "$out6" '殘留為白名單'
gone_wt "$wts/LS-4-whitelist" '⑥ LS-4-whitelist worktree 已用 --force 移除'
no_branch "$repo" LS-4-whitelist '⑥ LS-4-whitelist 本機分支已刪'

# ---- ⑦ 參數與環境錯誤 fail closed ----
out7="$(bash "$cleanup" --unknown-flag --repo "$repo" 2>&1)"; rc7=$?
rc_is '⑦ 未知旗標 exit 2' 2 "$rc7" "$out7"
out8="$(bash "$cleanup" --repo "$work" 2>&1)"; rc8=$?
rc_is '⑧ --repo 指到非 git 目錄 exit 2' 2 "$rc8" "$out8"

if [ "$fail" -eq 0 ]; then echo "✓ cleanup-merged.test.sh 全綠"; else echo "✗ cleanup-merged.test.sh 有失敗" >&2; fi
exit "$fail"
