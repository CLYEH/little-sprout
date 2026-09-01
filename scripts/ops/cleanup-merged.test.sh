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

repo="$work/repo"; g clone -q "$remote" "$repo"
wts="$repo/.claude/worktrees"; mkdir -p "$wts"
wt() { g -C "$repo" worktree add "$@" >/dev/null 2>&1 || { echo "✗ 建 worktree 失敗：$*" >&2; exit 1; }; }

# 每個要模擬「已併入」的 worktree／本機分支項目：從 origin/development 切出、**在這個 worktree
# 自己身上真的 commit**（reflog 記在這條分支自己頭上——has_real_history 驗的正是這個，不能用
# 「憑空建一條指到某個 commit 的分支」蒙混，那樣 reflog 只有 branch: Created，會被判定「尚未
# 開工」而不是「已併入」，同 cleanup-merged.sh 的安全設計），push 自己的分支名。全部建完＋push
# 後（見下方）用一條 integrate 分支一次 merge 齊全再單次 push 到 development（避免逐一 push
# 到 development 時彼此不是對方祖先、fast-forward 互撞）。
merged_branches="LS-1-merged-clean LS-3-dirty-merged LS-4-whitelist LS-5-temp-merged LS-7-selfprotect LS-8-local-merged LS-20-bound LS-200-bound"
for b in $merged_branches; do
  wt -b "$b" "$wts/$b" origin/development
  echo "$b" > "$wts/$b/${b}.txt"; g -C "$wts/$b" add -A; g -C "$wts/$b" commit -qm "feat: ${b}"
  g -C "$wts/$b" push -q origin "$b"
done

# 純遠端案例（無本機分支／worktree，not has_real_history 涵蓋範圍——那只看本機分支 reflog）：
# 同樣要有真的 commit，用暫時 worktree 建好、push 後整個丟掉即可。
remote_only="LS-10-remote-nopr LS-11-remote-haspr LS-12-remote-nogh"
for b in $remote_only; do
  wt -b "$b" "$work/scratch-$b" origin/development
  echo "$b" > "$work/scratch-$b/${b}.txt"; g -C "$work/scratch-$b" add -A; g -C "$work/scratch-$b" commit -qm "feat: ${b}"
  g -C "$work/scratch-$b" push -q origin "$b"
  g -C "$repo" worktree remove "$work/scratch-$b"
done

# seed 這邊 fetch 見到所有分支（皆已 push 到 origin），integrate 一次 merge 齊全、單次 push 到
# development——development 只被推一次，不會有逐一 push 互相不是祖先的 FF 衝突。
g -C "$seed" fetch -q origin
g -C "$seed" checkout -q -b integrate origin/development
for b in $merged_branches $remote_only; do g -C "$seed" merge -q --no-edit "origin/${b}"; done
g -C "$seed" push -q origin integrate:development
g -C "$seed" checkout -q main
g -C "$seed" branch -D integrate

# ⑧⑨ 本機分支（無 worktree）：LS-8-local-merged 已在上面迴圈建好 worktree＋commit＋push，
# development 也已併入它——現在移除 worktree（但保留分支本身，reflog 仍留著剛才的 commit
# 紀錄），模擬「worktree 已被移除、本機分支殘留」這個 (b) 段真正要處理的形狀。
g -C "$repo" worktree remove "$wts/LS-8-local-merged"

# LS-<n> 篩選邊界（LS-20 不得誤中 LS-200）同理：worktree 已建好＋commit＋push＋併入，移除
# worktree 只留本機分支。
g -C "$repo" worktree remove "$wts/LS-20-bound"
g -C "$repo" worktree remove "$wts/LS-200-bound"

g -C "$repo" fetch -q origin

# ② LS-2-unmerged：worktree，從（已推進的）development 切出後自己加一個獨有 commit，未併入
wt -b LS-2-unmerged "$wts/LS-2-unmerged" origin/development
echo 2 > "$wts/LS-2-unmerged/two.txt"; g -C "$wts/LS-2-unmerged" add -A; g -C "$wts/LS-2-unmerged" commit -qm 'feat: two'

# ⑨ LS-9-local-unmerged：本機分支（無 worktree），從 development 切出後加一個獨有 commit
g -C "$repo" branch LS-9-local-unmerged origin/development
( cd "$repo" && g checkout -q LS-9-local-unmerged && echo 9 > nine.txt && g add nine.txt && g commit -qm 'feat: nine' && g checkout -q main )

# ③④ 追加 dirty／殘留內容（LS-3、LS-4 的 worktree 已存在，內容已併入；這裡只加測項要驗的
# 額外狀態，不動 has_real_history 需要的原始 commit）
echo dirty >> "$wts/LS-3-dirty-merged/LS-3-dirty-merged.txt"
mkdir -p "$wts/LS-4-whitelist/__pycache__"; echo x > "$wts/LS-4-whitelist/__pycache__/x.pyc"
touch "$wts/LS-4-whitelist/.DS_Store"

# ⑤ LS-5-temp-merged 的 worktree 目前在 .claude/worktrees 下（上面迴圈建的），搬到暫存路徑
# （mktemp -d，basename 符合 tmp.* 樣式）驗「暫存殘留」標記——先 remove 再用 origin 分支重建
# 在暫存路徑，reflog 仍是原分支的，has_real_history 不受影響。
g -C "$repo" worktree remove "$wts/LS-5-temp-merged"
tmp_wt="$(mktemp -d "${TMPDIR:-/tmp}/tmp.XXXXXX")"; rmdir "$tmp_wt"
g -C "$repo" worktree add -q "$tmp_wt" LS-5-temp-merged >/dev/null 2>&1 || { echo "✗ 重建 LS-5-temp-merged 於暫存路徑失敗" >&2; exit 1; }

# ⑥ 保護分支 worktree（development）與 detached worktree：絕不可被列出或碰
wt "$work/dev-wt" development
wt --detach "$work/detached-wt"

# ⑬ LS-13-fresh-never-started：worktree 剛從 development 切出、0 commit、從未異動過——
# 即使 tip 與 base 相同（is_merged_ref 會判 true），has_real_history 應擋下，不得被當成
# 「已併入」清掉（這正是本票新增的安全修正：剛建好、還沒開工的 worktree 不能被誤殺）。
wt -b LS-13-fresh-never-started "$wts/LS-13-fresh-never-started" origin/development

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
has   '① LS-9-local-unmerged 未併入、略過' "$out" 'LS-9-local-unmerged：未併入或尚未開工，略過'
has   '① LS-10-remote-nopr 遠端將被刪（已併入、無 open PR）' "$out" 'origin/LS-10-remote-nopr（已併入、無 open PR）'
has   '① LS-11-remote-haspr 遠端有 open PR、略過' "$out" 'LS-11-remote-haspr：已併入但仍有 1 個 open PR，略過'
has   '① LS-13-fresh-never-started 尚未開工、略過（不得誤判已併入而清掉）' "$out" 'LS-13-fresh-never-started：尚未開工（與 base 相同、從未有過獨有 commit），略過'
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
exists_wt "$wts/LS-13-fresh-never-started" '⑤ LS-13-fresh-never-started worktree 仍在（尚未開工，has_real_history 擋下誤殺）'
has_branch "$repo" LS-13-fresh-never-started '⑤ LS-13-fresh-never-started 本機分支仍在'
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
