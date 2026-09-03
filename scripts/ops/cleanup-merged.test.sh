#!/bin/bash
# cleanup-merged.sh 的自測（LS-86；R2 起涵蓋 merge-review R1 逐條重演）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對清理腳本也適用：若退化成——已併入卻不列／不刪、未併入卻被刪、dirty worktree
# 被清掉（tracked 修改或白名單以外的未追蹤非 ignored 檔）、只剩 ignored 產物的 worktree 又被當 dirty 略過
# （LS-141：dirty 判定加回 --ignored 就紅）、Pen 開著該 worktree 的 .pen 仍被移除（LS-141）、尚未開工的
# worktree 未指名／票未收案就被清（LS-141）、保護分支或目前所在目錄（含子目錄）
# 被碰、遠端分支明明有 open PR 卻被 push --delete、gh 不可用時悍然刪除、dry-run 產生副作用、
# LS-<n> 篩選誤中鄰近票號（LS-20 誤中 LS-200）、只同步過（pull --ff-only／reset --hard／rebase）
# 卻被當成已併入、本機 remote-tracking ref 未 prune 造成假陽性、剛併入（可能仍在飛）就被清、
# 失敗的動作被算成已清理——這裡會紅。
# ①-⑥ 用同一個合成 repo：file:// 裸 origin（main／development）＋clone 當主 checkout；多個
# worktree／本機分支／遠端分支各一種形狀。所有「已併入」的分支各自建好、push 後用一條
# integrate 分支一次 merge 齊全再單次 push 到 development（避免逐一 push 到 development 時
# 彼此不是對方祖先、fast-forward 互撞）；commit 一律用 gold（老時間戳，同 patrol.test.sh 的
# OLD／gold 慣例）——cleanup-merged.sh 預設 --min-age 10 分鐘，不 backdate 全部會被年齡門檻擋下
# 變成假綠。gh 用 PATH 上的 stub（模擬 `gh pr list --state open --json headRefName` 這一次批次
# 查詢，依 GH_STUB_PR_OPEN 清單回報哪些分支有 open PR）。
# ⑦-⑭ 各自用獨立的迷你合成 repo（同攻擊腳本 scratchpad LS-86-attack2.sh／LS-86-attack3.sh 的
# 重現手法）逐條驗證 merge-review R1 的 B1／M1／M2／m1／M3／M4-a／M4-b／m3。
# ⑪ 自 LS-141 起反轉 M3：只剩 ignored 產物 → 可清＋審計清單；⑰ Pen 開著 → 拒刪；⑱ 尚未開工＋指名＋
# （--force-unstarted 或 stub Linear completed）→ 可清。pen CLI 用 PEN_BIN 指到 stub（pen-open.sh 認得的
# 覆寫點，同 pen-open.test.sh）；Linear 用 PATH 前置的假 curl（同 patrol-linear.test.sh）；LINEAR_API_KEY
# 一開始 unset，只在 ⑱ 個別案例以 env 帶入 stub token。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cleanup="${root}/scripts/ops/cleanup-merged.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
# R2（merge-review R1 M4-b）：cleanup-merged.sh 預設 --min-age 10（分鐘）——最後 commit 太新一律
# 略過。凡是這個檔案裡「應該被判定已併入、可清」的 fixture，commit 都要用 gold（老時間戳）建，
# 不然全部會被年齡門檻擋下、變成假綠（同 patrol.test.sh 的 OLD／gold 慣例）。
OLD=2020-01-01T00:00:00Z
gold() { env GIT_AUTHOR_DATE="$OLD" GIT_COMMITTER_DATE="$OLD" git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

has()   { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✓ $1"; else echo "✗ ${1}（輸出應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; fi; }
rc_is() { if [ "$3" -eq "$2" ]; then echo "✓ $1"; else echo "✗ ${1}（期望 exit ${2}，實得 ${3}）" >&2; printf '%s\n' "$4" | sed 's/^/    /' >&2; fail=1; fi; }
exists_wt() { [ -d "$1" ] && echo "✓ $2" || { echo "✗ ${2}（worktree 目錄消失，本不該被動）" >&2; fail=1; }; }
gone_wt()   { if [ -d "$1" ]; then echo "✗ ${2}（worktree 目錄仍在，本該被移除）" >&2; fail=1; else echo "✓ $2"; fi; }
has_branch() { git -C "$1" show-ref --verify -q "refs/heads/$2" && echo "✓ $3" || { echo "✗ ${3}（本機分支 $2 不見了，本不該被刪）" >&2; fail=1; }; }
no_branch()  { git -C "$1" show-ref --verify -q "refs/heads/$2" && { echo "✗ ${3}（本機分支 $2 仍在，本該被刪）" >&2; fail=1; } || echo "✓ $3"; }
has_remote() { git -C "$1" ls-remote --exit-code "$2" "refs/heads/$3" >/dev/null 2>&1 && echo "✓ $4" || { echo "✗ ${4}（遠端分支 $3 不見了，本不該被刪）" >&2; fail=1; }; }
no_remote()  { git -C "$1" ls-remote --exit-code "$2" "refs/heads/$3" >/dev/null 2>&1 && { echo "✗ ${4}（遠端分支 $3 仍在，本該被刪）" >&2; fail=1; } || echo "✓ $4"; }

# ---- stub gh：模擬 `gh pr list --state open --json headRefName --limit N -q '.[].headRefName'`
#      （m2 起 cleanup-merged.sh 只打這一次批次查詢，不再逐分支呼叫 --head）——印出
#      GH_STUB_PR_OPEN（空白分隔）清單，每行一個分支名，代表這些分支目前各有一個 open PR。
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'EOF'
#!/bin/bash
for b in ${GH_STUB_PR_OPEN:-}; do printf '%s\n' "$b"; done
EOF
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" GH_STUB_PR_OPEN="LS-11-remote-haspr"

# ---- stub pen（LS-141）：cleanup-merged.sh 移除前跑 pen-open.sh --status，後者只認 `pen interactive --app desktop`
#      輸出的「Currently active canvas editor: `…`」那一行。PEN_STUB_PATH 有值就印那一行，否則模擬沒有 active 文件
#      （pen-open --status 因此 exit 2 → cleanup-merged 印警告、視為未開）。全程用 PEN_BIN 指過來，不碰真的 Pen。
cat > "$work/bin/pen-stub" <<'EOF'
#!/bin/bash
[ "${1:-}" = interactive ] || exit 1
cat >/dev/null
if [ -n "${PEN_STUB_PATH:-}" ]; then printf 'Currently active canvas editor: `%s`\n' "$PEN_STUB_PATH"; else echo "(no active document)"; fi
EOF
chmod +x "$work/bin/pen-stub"
export PEN_BIN="$work/bin/pen-stub"
unset PEN_STUB_PATH

# ---- stub curl（LS-141）：模擬 cleanup-merged.sh linear_state 打的 Linear GraphQL。argv 記到 CURL_STUB_LOG（驗
#      token 只走 -K - 的 stdin config、不進 argv）；stdin 丟棄；依 LINEAR_STUB_TYPE 回固定 JSON，未設回 GraphQL error。
cat > "$work/bin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${CURL_STUB_LOG:-/dev/null}"
cat >/dev/null
id=$(printf '%s' "$*" | grep -oE 'LS-[0-9]+' | head -1)
case "${LINEAR_STUB_TYPE:-}" in
  completed) printf '{"data":{"issue":{"identifier":"%s","state":{"name":"Done","type":"completed"}}}}\n' "$id" ;;
  canceled)  printf '{"data":{"issue":{"identifier":"%s","state":{"name":"Canceled","type":"canceled"}}}}\n' "$id" ;;
  started)   printf '{"data":{"issue":{"identifier":"%s","state":{"name":"In Progress","type":"started"}}}}\n' "$id" ;;
  *) echo '{"errors":[{"message":"stub curl：LINEAR_STUB_TYPE 未設"}]}' ;;
esac
EOF
chmod +x "$work/bin/curl"
unset LINEAR_API_KEY LINEAR_STUB_TYPE

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
  echo "$b" > "$wts/$b/${b}.txt"; g -C "$wts/$b" add -A; gold -C "$wts/$b" commit -qm "feat: ${b}"
  g -C "$wts/$b" push -q origin "$b"
done

# 純遠端案例（無本機分支／worktree，not has_real_history 涵蓋範圍——那只看本機分支 reflog）：
# 同樣要有真的 commit，用暫時 worktree 建好、push 後整個丟掉即可。
remote_only="LS-10-remote-nopr LS-11-remote-haspr LS-12-remote-nogh"
for b in $remote_only; do
  wt -b "$b" "$work/scratch-$b" origin/development
  echo "$b" > "$work/scratch-$b/${b}.txt"; g -C "$work/scratch-$b" add -A; gold -C "$work/scratch-$b" commit -qm "feat: ${b}"
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
has   '① 列出 LS-3-dirty-merged dirty、略過' "$out" 'LS-3-dirty-merged：dirty（tracked 修改或未追蹤非 ignored 檔），略過'
has   '① 列出 LS-4-whitelist dirty、略過（未加 --force）' "$out" 'LS-4-whitelist：dirty（tracked 修改或未追蹤非 ignored 檔），略過'
has   '① 列出 LS-5-temp-merged 標「暫存殘留」' "$out" '（暫存殘留）（LS-5-temp-merged，已併入且乾淨）'
has_dev_absent=$(printf '%s' "$out" | grep -c 'dev-wt'); [ "$has_dev_absent" -eq 0 ] && echo "✓ ① 保護分支 worktree（development）不進表" || { echo "✗ ① 保護分支 worktree 不應進表" >&2; fail=1; }
has_det_absent=$(printf '%s' "$out" | grep -c 'detached-wt'); [ "$has_det_absent" -eq 0 ] && echo "✓ ① detached worktree 不進表" || { echo "✗ ① detached worktree 不應進表" >&2; fail=1; }
has   '① LS-8-local-merged 本機分支將被刪（已併入、無 worktree）' "$out" 'LS-8-local-merged（已併入、無 worktree）'
has   '① LS-9-local-unmerged 未併入、略過' "$out" 'LS-9-local-unmerged：未併入或尚未開工，略過'
has   '① LS-10-remote-nopr 遠端將被刪（已併入、無 open PR）' "$out" 'origin/LS-10-remote-nopr（已併入、無 open PR）'
has   '① LS-11-remote-haspr 遠端有 open PR、略過' "$out" 'LS-11-remote-haspr：已併入但仍有 open PR，略過'
has   '① LS-13-fresh-never-started 尚未開工、略過（不得誤判已併入而清掉）' "$out" 'LS-13-fresh-never-started：尚未開工（與 base 相同、從未有過自己的 commit），略過'
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
has   '③ 標示「目前所在目錄，絕不碰」' "$out3" '目前所在目錄'
exists_wt "$wts/LS-7-selfprotect" '③ LS-7-selfprotect worktree 仍在（cwd 保護生效）'
has_branch "$repo" LS-7-selfprotect '③ LS-7-selfprotect 本機分支仍在'

# ---- ④ LS-<n> 篩選邊界：只清 LS-20-bound，LS-200-bound 不受影響 ----
out4="$(bash "$cleanup" --apply --repo "$repo" LS-20 2>&1)"; rc4=$?
rc_is '④ 篩選 LS-20 exit 0' 0 "$rc4" "$out4"
no_branch  "$repo" LS-20-bound  '④ LS-20-bound 已刪（篩選命中）'
has_branch "$repo" LS-200-bound '④ LS-200-bound 未受影響（LS-20 不誤中 LS-200，word-boundary）'

# ---- ⑤ --apply（不加 --force，不篩選，M4-a 起要求明確 --all）：merged+clean 全部清掉；
#        dirty／unmerged／whitelist（未加 --force）／保護分支／detached／haspr 一律不動 ----
out5="$(bash "$cleanup" --apply --all --repo "$repo" 2>&1)"; rc5=$?
rc_is '⑤ apply exit 0（無失敗）' 0 "$rc5" "$out5"
has   '⑤ 摘要列出實際刪除數' "$out5" '摘要（apply）'
has   '⑤ Pen 讀不到（stub 無 active 文件）→ 印警告、視為未開、照常清理（LS-141）' "$out5" 'pen-open.sh --status 讀不到 Pen 目前文件'
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

# ==== merge-review R1 逐條重演（B1／M1／M2／m1／M3／M4-a／M4-b／m3）====
# 每條各自用一個獨立的迷你合成 repo（同攻擊腳本 scratchpad LS-86-attack2.sh／LS-86-attack3.sh
# 的重現手法），避免跟上面 ①-⑥ 共用的主測試 repo 互相干擾。

# ---- ⑦ B1：worktree 從落後的本機 development 切出，開工前只 `pull --ff-only` 同步一次
#        （沒有自己的 commit）→ tip 與 base 相同但 reflog 有非 Created/checkout 條目，
#        has_real_history 修法前會誤判「已併入」而清掉 ----
b1=$work/b1; mkdir -p "$b1"
g init -q --bare -b main "$b1/remote.git"
g init -q -b main "$b1/seed"
echo a > "$b1/seed/f.txt"; g -C "$b1/seed" add -A; g -C "$b1/seed" commit -qm seed
g -C "$b1/seed" branch development
g -C "$b1/seed" remote add origin "$b1/remote.git"; g -C "$b1/seed" push -q origin main development
g clone -q "$b1/remote.git" "$b1/repo"; mkdir -p "$b1/repo/.claude/worktrees"
g -C "$b1/repo" branch devlocal origin/development
g -C "$b1/repo" worktree add -q -b LS-901-sync "$b1/repo/.claude/worktrees/LS-901-sync" devlocal
echo b >> "$b1/seed/f.txt"; g -C "$b1/seed" checkout -q development; g -C "$b1/seed" commit -qam adv; g -C "$b1/seed" push -q origin development
g -C "$b1/repo" fetch -q origin
g -C "$b1/repo/.claude/worktrees/LS-901-sync" pull -q --ff-only origin development
out7="$(bash "$cleanup" --apply --repo "$b1/repo" LS-901 2>&1)"; rc7=$?
rc_is '⑦ B1 exit 0' 0 "$rc7" "$out7"
has   '⑦ B1 判定尚未開工（只同步過、非已併入可清）' "$out7" '尚未開工'
exists_wt "$b1/repo/.claude/worktrees/LS-901-sync" '⑦ B1 worktree 仍在（has_real_history 擋下誤殺）'
has_branch "$b1/repo" LS-901-sync '⑦ B1 本機分支仍在'

# ---- ⑧ M1：cwd 在 worktree 的子目錄（不是根目錄本身）→ 自我保護仍須生效 ----
m1w=$work/m1w; mkdir -p "$m1w"
g init -q --bare -b main "$m1w/remote.git"
g init -q -b main "$m1w/seed"
echo a > "$m1w/seed/f.txt"; g -C "$m1w/seed" add -A; g -C "$m1w/seed" commit -qm seed
g -C "$m1w/seed" branch development
g -C "$m1w/seed" remote add origin "$m1w/remote.git"; g -C "$m1w/seed" push -q origin main development
g clone -q "$m1w/remote.git" "$m1w/repo"; mkdir -p "$m1w/repo/.claude/worktrees"
g -C "$m1w/repo" worktree add -q -b LS-902-sub "$m1w/repo/.claude/worktrees/LS-902-sub" origin/development
mkdir -p "$m1w/repo/.claude/worktrees/LS-902-sub/scripts"
echo x > "$m1w/repo/.claude/worktrees/LS-902-sub/x.txt"; g -C "$m1w/repo/.claude/worktrees/LS-902-sub" add -A
gold -C "$m1w/repo/.claude/worktrees/LS-902-sub" commit -qm x
g -C "$m1w/repo/.claude/worktrees/LS-902-sub" push -q origin LS-902-sub
g -C "$m1w/seed" fetch -q origin; g -C "$m1w/seed" checkout -q development
g -C "$m1w/seed" merge -q --no-edit origin/LS-902-sub; g -C "$m1w/seed" push -q origin development
g -C "$m1w/repo" fetch -q origin
out8="$(cd "$m1w/repo/.claude/worktrees/LS-902-sub/scripts" && bash "$cleanup" --apply --repo "$m1w/repo" LS-902 2>&1)"; rc8=$?
rc_is '⑧ M1 exit 0' 0 "$rc8" "$out8"
has   '⑧ M1 標示目前所在目錄（子目錄）保護' "$out8" '目前所在目錄'
exists_wt "$m1w/repo/.claude/worktrees/LS-902-sub" '⑧ M1 worktree 仍在（cwd 在子目錄也受保護）'
has_branch "$m1w/repo" LS-902-sub '⑧ M1 本機分支仍在'

# ---- ⑨ M2：遠端分支已被刪除（GitHub auto-delete 或他人手動刪），本機 remote-tracking ref
#        未 prune → fetch --prune 後這條 ref 應直接消失，(c) 段不該再看到它、更不該因為
#        對幽靈 ref push --delete 而失敗 ----
m2=$work/m2; mkdir -p "$m2"
g init -q --bare -b main "$m2/remote.git"
g init -q -b main "$m2/seed"
echo a > "$m2/seed/f.txt"; g -C "$m2/seed" add -A; g -C "$m2/seed" commit -qm seed
g -C "$m2/seed" branch development
g -C "$m2/seed" remote add origin "$m2/remote.git"; g -C "$m2/seed" push -q origin main development
g clone -q "$m2/remote.git" "$m2/repo"; mkdir -p "$m2/repo/.claude/worktrees"
g -C "$m2/repo" worktree add -q -b LS-903-gone "$m2/repo/.claude/worktrees/LS-903-gone" origin/development
echo c > "$m2/repo/.claude/worktrees/LS-903-gone/c.txt"; g -C "$m2/repo/.claude/worktrees/LS-903-gone" add -A
gold -C "$m2/repo/.claude/worktrees/LS-903-gone" commit -qm c
g -C "$m2/repo/.claude/worktrees/LS-903-gone" push -q origin LS-903-gone
g -C "$m2/seed" fetch -q origin; g -C "$m2/seed" checkout -q development
g -C "$m2/seed" merge -q --no-edit origin/LS-903-gone; g -C "$m2/seed" push -q origin development
g -C "$m2/seed" push -q origin --delete LS-903-gone
g -C "$m2/repo" worktree remove "$m2/repo/.claude/worktrees/LS-903-gone"; g -C "$m2/repo" branch -D LS-903-gone >/dev/null
# 刻意不先 fetch --prune：repo 這時本機仍帶著 stale 的 refs/remotes/origin/LS-903-gone
out9="$(bash "$cleanup" --apply --repo "$m2/repo" LS-903 2>&1)"; rc9=$?
rc_is '⑨ M2 exit 0（--prune 後幽靈 ref 已消失，不會因它失敗）' 0 "$rc9" "$out9"
if printf '%s' "$out9" | grep -q '失敗'; then echo "✗ ⑨ M2 不應印出任何失敗（stale ref 應已被 fetch --prune 清掉）" >&2; printf '%s\n' "$out9" | sed 's/^/    /' >&2; fail=1; else echo "✓ ⑨ M2 無失敗訊息"; fi
stale_ref=$(git -C "$m2/repo" for-each-ref --format='%(refname)' refs/remotes/origin/LS-903-gone)
[ -z "$stale_ref" ] && echo "✓ ⑨ M2 stale ref 已被 fetch --prune 清掉" || { echo "✗ ⑨ M2 stale ref 仍在（fetch 沒有 --prune）" >&2; fail=1; }

# ---- ⑩ m1：--force 白名單須對「路徑」做精確元件比對，不是對整行文字做子字串／字尾比對 ----
m1x=$work/m1x; mkdir -p "$m1x"
g init -q --bare -b main "$m1x/remote.git"
g init -q -b main "$m1x/seed"
echo a > "$m1x/seed/f.txt"; g -C "$m1x/seed" add -A; g -C "$m1x/seed" commit -qm seed
g -C "$m1x/seed" branch development
g -C "$m1x/seed" remote add origin "$m1x/remote.git"; g -C "$m1x/seed" push -q origin main development
g clone -q "$m1x/remote.git" "$m1x/repo"; mkdir -p "$m1x/repo/.claude/worktrees"
g -C "$m1x/repo" worktree add -q -b LS-904-wl "$m1x/repo/.claude/worktrees/LS-904-wl" origin/development
echo d > "$m1x/repo/.claude/worktrees/LS-904-wl/d.txt"; g -C "$m1x/repo/.claude/worktrees/LS-904-wl" add -A
gold -C "$m1x/repo/.claude/worktrees/LS-904-wl" commit -qm d
g -C "$m1x/repo/.claude/worktrees/LS-904-wl" push -q origin LS-904-wl
g -C "$m1x/seed" fetch -q origin; g -C "$m1x/seed" checkout -q development
g -C "$m1x/seed" merge -q --no-edit origin/LS-904-wl; g -C "$m1x/seed" push -q origin development
g -C "$m1x/repo" fetch -q origin
printf 'IRREPLACEABLE\n' > "$m1x/repo/.claude/worktrees/LS-904-wl/notes-on-__pycache__-cleanup.md"
printf 'precious\n' > "$m1x/repo/.claude/worktrees/LS-904-wl/evidence.DS_Store"
out10="$(bash "$cleanup" --apply --force --repo "$m1x/repo" LS-904 2>&1)"; rc10=$?
rc_is '⑩ m1 exit 0' 0 "$rc10" "$out10"
exists_wt "$m1x/repo/.claude/worktrees/LS-904-wl" '⑩ m1 worktree 仍在（子字串／字尾誤命中白名單已修正）'
has_branch "$m1x/repo" LS-904-wl '⑩ m1 本機分支仍在'
[ -e "$m1x/repo/.claude/worktrees/LS-904-wl/notes-on-__pycache__-cleanup.md" ] && echo "✓ ⑩ m1 notes-on-__pycache__-cleanup.md 仍在" || { echo "✗ ⑩ m1 notes-on-__pycache__-cleanup.md 被誤刪" >&2; fail=1; }
[ -e "$m1x/repo/.claude/worktrees/LS-904-wl/evidence.DS_Store" ] && echo "✓ ⑩ m1 evidence.DS_Store 仍在" || { echo "✗ ⑩ m1 evidence.DS_Store 被誤刪" >&2; fail=1; }

# ---- ⑪ LS-141（推翻 R2 M3）：worktree 只剩 gitignore 掉的產物（Config/Secrets.xcconfig、supabase/.temp/、
#        supabase/tests/evidence/——每張 iOS／backend 票的 worktree 必有）→ 視為乾淨可清，dry-run 與 apply 都先印出
#        被丟掉的 ignored 路徑（審計）；同 repo 另一個 worktree 除了 ignored 產物還有未追蹤非 ignored 檔 → 仍是
#        dirty、略過不動（--force 也不放行：不是白名單）。mutation：worktree_status 加回 --ignored=matching → 這裡紅 ----
m3=$work/m3ignore; mkdir -p "$m3"
g init -q --bare -b main "$m3/remote.git"
g init -q -b main "$m3/seed"
printf 'Secrets.xcconfig\nsupabase/.temp/\nsupabase/tests/evidence/\n' > "$m3/seed/.gitignore"
echo a > "$m3/seed/f.txt"; g -C "$m3/seed" add -A; g -C "$m3/seed" commit -qm seed
g -C "$m3/seed" branch development
g -C "$m3/seed" remote add origin "$m3/remote.git"; g -C "$m3/seed" push -q origin main development
g clone -q "$m3/remote.git" "$m3/repo"; mkdir -p "$m3/repo/.claude/worktrees"
for b in LS-905-ignored LS-908-untracked; do
  g -C "$m3/repo" worktree add -q -b "$b" "$m3/repo/.claude/worktrees/$b" origin/development
  echo "$b" > "$m3/repo/.claude/worktrees/$b/${b}.txt"; g -C "$m3/repo/.claude/worktrees/$b" add -A
  gold -C "$m3/repo/.claude/worktrees/$b" commit -qm "feat: $b"
  g -C "$m3/repo/.claude/worktrees/$b" push -q origin "$b"
done
g -C "$m3/seed" fetch -q origin; g -C "$m3/seed" checkout -q development
g -C "$m3/seed" merge -q --no-edit origin/LS-905-ignored origin/LS-908-untracked; g -C "$m3/seed" push -q origin development
g -C "$m3/repo" fetch -q origin
wt905="$m3/repo/.claude/worktrees/LS-905-ignored"; wt908="$m3/repo/.claude/worktrees/LS-908-untracked"
mkdir -p "$wt905/Config" "$wt905/supabase/.temp" "$wt905/supabase/tests/evidence"
printf 'SUPABASE_ANON_KEY = xxx\n' > "$wt905/Config/Secrets.xcconfig"
echo 1.2.3 > "$wt905/supabase/.temp/cli-latest"; echo '{}' > "$wt905/supabase/tests/evidence/plan.json"
mkdir -p "$wt908/supabase/.temp"; echo 1.2.3 > "$wt908/supabase/.temp/cli-latest"; echo scratch > "$wt908/scratch.txt"
[ -z "$(git -C "$wt905" status --porcelain)" ] && [ -n "$(git -C "$wt905" status --porcelain --ignored=matching)" ] \
  && echo "✓ ⑪ 前提成立：LS-905 plain porcelain 乾淨、--ignored=matching 有 ignored 產物" || { echo "✗ ⑪ 前提不成立" >&2; fail=1; }
out11d="$(bash "$cleanup" --dry-run --repo "$m3/repo" LS-905 2>&1)"; rc11d=$?
rc_is '⑪ dry-run exit 0' 0 "$rc11d" "$out11d"
has   '⑪ dry-run 列 LS-905 為已併入且乾淨（ignored 不算 dirty）' "$out11d" '（LS-905-ignored，已併入且乾淨）'
has   '⑪ dry-run 印出審計標題' "$out11d" '將一併丟棄的 ignored 產物'
has   '⑪ dry-run 審計列出 Config/Secrets.xcconfig' "$out11d" 'Config/Secrets.xcconfig'
has   '⑪ dry-run 審計列出 supabase/.temp/' "$out11d" 'supabase/.temp/'
has   '⑪ dry-run 審計列出 supabase/tests/evidence/' "$out11d" 'supabase/tests/evidence/'
exists_wt "$wt905" '⑪ dry-run 未動 LS-905 worktree'
out11="$(bash "$cleanup" --apply --repo "$m3/repo" LS-905 2>&1)"; rc11=$?
rc_is '⑪ apply exit 0' 0 "$rc11" "$out11"
has   '⑪ apply 移除前印出審計' "$out11" '將一併丟棄的 ignored 產物'
gone_wt "$wt905" '⑪ LS-905-ignored worktree 已移除（只剩 ignored 產物 → 可清）'
no_branch "$m3/repo" LS-905-ignored '⑪ LS-905-ignored 本機分支已刪'
out11u="$(bash "$cleanup" --apply --repo "$m3/repo" LS-908 2>&1)"; rc11u=$?
rc_is '⑪ 未追蹤非 ignored → apply exit 0' 0 "$rc11u" "$out11u"
has   '⑪ LS-908 判 dirty、略過、點名 scratch.txt' "$out11u" '?? scratch.txt'
exists_wt "$wt908" '⑪ LS-908-untracked worktree 仍在（未追蹤非 ignored 檔仍是 dirty）'
[ -e "$wt908/scratch.txt" ] && echo "✓ ⑪ scratch.txt 仍在" || { echo "✗ ⑪ scratch.txt 被誤刪" >&2; fail=1; }
out11uf="$(bash "$cleanup" --apply --force --repo "$m3/repo" LS-908 2>&1)"; rc11uf=$?
rc_is '⑪ 未追蹤非 ignored＋--force → exit 0' 0 "$rc11uf" "$out11uf"
exists_wt "$wt908" '⑪ LS-908-untracked worktree 仍在（--force 不放行非白名單殘留）'
has_branch "$m3/repo" LS-908-untracked '⑪ LS-908-untracked 本機分支仍在'

# ---- ⑫ M4-a：--apply 不帶 LS-<n> 也不帶 --all → 直接拒絕、不做任何事（用主測試 repo，
#        驗證「拒絕」本身不會有任何副作用）----
before12_wt=$(git -C "$repo" worktree list --porcelain | grep -c '^worktree ')
before12_branches=$(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads/ | sort)
out12="$(bash "$cleanup" --apply --repo "$repo" 2>&1)"; rc12=$?
rc_is '⑫ M4-a 不帶票號且不帶 --all → exit 2' 2 "$rc12" "$out12"
has   '⑫ M4-a 訊息提示 LS-<n> 或 --all' "$out12" '--all'
after12_wt=$(git -C "$repo" worktree list --porcelain | grep -c '^worktree ')
after12_branches=$(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads/ | sort)
[ "$before12_wt" -eq "$after12_wt" ] && echo "✓ ⑫ M4-a 被拒絕時未變動 worktree 數量" || { echo "✗ ⑫ M4-a 不應變動 worktree 數量" >&2; fail=1; }
[ "$before12_branches" = "$after12_branches" ] && echo "✓ ⑫ M4-a 被拒絕時未變動本機分支清單" || { echo "✗ ⑫ M4-a 不應變動本機分支清單" >&2; fail=1; }

# ---- ⑬ M4-b：分支剛併入（commit 時間新，非 gold），即使加 --all 也不得清——避免清掉
#        「agent 剛完成這一輪、準備在同一個 worktree 續作下一輪」的在飛工作 ----
m4=$work/m4; mkdir -p "$m4"
g init -q --bare -b main "$m4/remote.git"
g init -q -b main "$m4/seed"
echo a > "$m4/seed/f.txt"; g -C "$m4/seed" add -A; g -C "$m4/seed" commit -qm seed
g -C "$m4/seed" branch development
g -C "$m4/seed" remote add origin "$m4/remote.git"; g -C "$m4/seed" push -q origin main development
g clone -q "$m4/remote.git" "$m4/repo"; mkdir -p "$m4/repo/.claude/worktrees"
g -C "$m4/repo" worktree add -q -b LS-906-round2 "$m4/repo/.claude/worktrees/LS-906-round2" origin/development
echo f > "$m4/repo/.claude/worktrees/LS-906-round2/f2.txt"; g -C "$m4/repo/.claude/worktrees/LS-906-round2" add -A
g -C "$m4/repo/.claude/worktrees/LS-906-round2" commit -qm f2   # 刻意不用 gold：模擬「剛剛才 commit」
g -C "$m4/repo/.claude/worktrees/LS-906-round2" push -q origin LS-906-round2
g -C "$m4/seed" fetch -q origin; g -C "$m4/seed" checkout -q development
g -C "$m4/seed" merge -q --no-edit origin/LS-906-round2; g -C "$m4/seed" push -q origin development
g -C "$m4/repo" fetch -q origin
out13="$(bash "$cleanup" --apply --all --repo "$m4/repo" 2>&1)"; rc13=$?
rc_is '⑬ M4-b exit 0' 0 "$rc13" "$out13"
has   '⑬ M4-b 標示最後 commit 未滿 min-age、略過' "$out13" '未滿'
exists_wt "$m4/repo/.claude/worktrees/LS-906-round2" '⑬ M4-b worktree 仍在（剛併入、--all 也不清）'
has_branch "$m4/repo" LS-906-round2 '⑬ M4-b 本機分支仍在'

# ---- ⑭ m3：實際失敗的動作不得計入已清理數——遠端寫入權限被拒（模擬推送失敗，非 stale ref）
#        時，摘要應誠實反映「遠端分支 0」且整體 exit 1（fail loud）。用 chmod 唯讀模擬寫入被拒，
#        對 root 無效（root 無視檔案權限）——以 root 執行時（少數 CI／容器環境）略過此案例，
#        不假裝驗證了什麼。 ----
if [ "$(id -u)" = 0 ]; then
  echo "⚠ ⑭ m3 略過（以 root 執行，chmod 唯讀對 root 無效，無法模擬推送失敗）"
else
  m3f=$work/m3fail; mkdir -p "$m3f"
  g init -q --bare -b main "$m3f/remote.git"
  g init -q -b main "$m3f/seed"
  echo a > "$m3f/seed/f.txt"; g -C "$m3f/seed" add -A; g -C "$m3f/seed" commit -qm seed
  g -C "$m3f/seed" branch development
  g -C "$m3f/seed" remote add origin "$m3f/remote.git"; g -C "$m3f/seed" push -q origin main development
  g clone -q "$m3f/remote.git" "$m3f/repo"; mkdir -p "$m3f/repo/.claude/worktrees"
  g -C "$m3f/repo" worktree add -q -b LS-907-writeperm "$m3f/repo/.claude/worktrees/LS-907-writeperm" origin/development
  echo g > "$m3f/repo/.claude/worktrees/LS-907-writeperm/g.txt"; g -C "$m3f/repo/.claude/worktrees/LS-907-writeperm" add -A
  gold -C "$m3f/repo/.claude/worktrees/LS-907-writeperm" commit -qm g
  g -C "$m3f/repo/.claude/worktrees/LS-907-writeperm" push -q origin LS-907-writeperm
  g -C "$m3f/seed" fetch -q origin; g -C "$m3f/seed" checkout -q development
  g -C "$m3f/seed" merge -q --no-edit origin/LS-907-writeperm; g -C "$m3f/seed" push -q origin development
  g -C "$m3f/repo" worktree remove "$m3f/repo/.claude/worktrees/LS-907-writeperm"; g -C "$m3f/repo" branch -D LS-907-writeperm >/dev/null
  chmod -R a-w "$m3f/remote.git"   # fetch（唯讀）不受影響；push --delete 會因無寫入權限失敗
  out14="$(bash "$cleanup" --apply --repo "$m3f/repo" LS-907 2>&1)"; rc14=$?
  chmod -R u+w "$m3f/remote.git"   # 還原權限，讓收尾 trap 能刪掉 $work
  rc_is '⑭ m3 exit 1（推送失敗，fail loud）' 1 "$rc14" "$out14"
  has   '⑭ m3 印出失敗訊息' "$out14" '失敗'
  has   '⑭ m3 摘要遠端分支計數為 0（失敗不得算進已清理）' "$out14" '遠端分支 0'
fi

# ---- ⑮⑯ 參數與環境錯誤 fail closed ----
out15="$(bash "$cleanup" --unknown-flag --repo "$repo" 2>&1)"; rc15=$?
rc_is '⑮ 未知旗標 exit 2' 2 "$rc15" "$out15"
out16="$(bash "$cleanup" --repo "$work" 2>&1)"; rc16=$?
rc_is '⑯ --repo 指到非 git 目錄 exit 2' 2 "$rc16" "$out16"

# ---- ⑰ LS-141（LS-96 aab3d640，LS-119 事故）：Pen 目前 active 文件落在該 worktree 內 → 拒刪、印處置；
#        Pen 開的是別的路徑 → 照常清。stub 印的是 $work 的「邏輯」路徑（macOS 上 /var/folders/…），git 回報的
#        worktree 路徑是物理路徑（/private/var/…）——順便驗 cleanup-merged 有把 Pen 路徑 pwd -P 正規化 ----
p=$work/pen; mkdir -p "$p"
g init -q --bare -b main "$p/remote.git"
g init -q -b main "$p/seed"
echo a > "$p/seed/f.txt"; g -C "$p/seed" add -A; g -C "$p/seed" commit -qm seed
g -C "$p/seed" branch development
g -C "$p/seed" remote add origin "$p/remote.git"; g -C "$p/seed" push -q origin main development
g clone -q "$p/remote.git" "$p/repo"; mkdir -p "$p/repo/.claude/worktrees"
wt914="$p/repo/.claude/worktrees/LS-914-pen"
g -C "$p/repo" worktree add -q -b LS-914-pen "$wt914" origin/development
mkdir -p "$wt914/design"; echo '{}' > "$wt914/design/littlesprout.pen"; g -C "$wt914" add -A
gold -C "$wt914" commit -qm pen
g -C "$wt914" push -q origin LS-914-pen
g -C "$p/seed" fetch -q origin; g -C "$p/seed" checkout -q development
g -C "$p/seed" merge -q --no-edit origin/LS-914-pen; g -C "$p/seed" push -q origin development
g -C "$p/repo" fetch -q origin
out17="$(PEN_STUB_PATH="$wt914/design/littlesprout.pen" bash "$cleanup" --apply --repo "$p/repo" LS-914 2>&1)"; rc17=$?
rc_is '⑰ Pen 開著該 worktree → exit 0（拒刪算略過）' 0 "$rc17" "$out17"
has   '⑰ 標示拒刪' "$out17" 'Pen 目前開著'
has   '⑰ 印出處置（切回主 checkout）' "$out17" 'pen-open.sh'
has   '⑰ 摘要計入 Pen 開著 1' "$out17" 'worktree Pen 開著 1'
exists_wt "$wt914" '⑰ LS-914-pen worktree 仍在（Pen 開著，拒刪）'
has_branch "$p/repo" LS-914-pen '⑰ LS-914-pen 本機分支仍在'
out17b="$(PEN_STUB_PATH="$p/repo/design/littlesprout.pen" bash "$cleanup" --apply --repo "$p/repo" LS-914 2>&1)"; rc17b=$?
rc_is '⑰ Pen 開的是主 checkout → exit 0' 0 "$rc17b" "$out17b"
gone_wt "$wt914" '⑰ Pen 開的是別的路徑 → LS-914-pen worktree 正常移除'
no_branch "$p/repo" LS-914-pen '⑰ LS-914-pen 本機分支已刪'

# ---- ⑱ LS-141（LS-96 b410b190）：尚未開工（tip＝base、從未有自己的 commit）的 worktree——預設仍略過（⑤ LS-13
#        已驗 --all 不清）；指名單票時：無 key 無旗標 → 略過並提示；--force-unstarted → 清；stub Linear 回
#        completed → 清（token 只走 stdin，不進 curl argv）；回 started → 略過並提示；--force-unstarted 不帶票號 →
#        exit 2；dry-run 零副作用；有未追蹤檔仍是 dirty，旗標不繞過 ----
u=$work/unstarted; mkdir -p "$u"
g init -q --bare -b main "$u/remote.git"
g init -q -b main "$u/seed"
echo a > "$u/seed/f.txt"; g -C "$u/seed" add -A; g -C "$u/seed" commit -qm seed
g -C "$u/seed" branch development
g -C "$u/seed" remote add origin "$u/remote.git"; g -C "$u/seed" push -q origin main development
g clone -q "$u/remote.git" "$u/repo"; uwts="$u/repo/.claude/worktrees"; mkdir -p "$uwts"
for b in LS-910-flag LS-911-done LS-912-active LS-913-dry; do
  g -C "$u/repo" worktree add -q -b "$b" "$uwts/$b" origin/development
done
out18a="$(bash "$cleanup" --apply --repo "$u/repo" LS-910 2>&1)"; rc18a=$?
rc_is '⑱ 無 key 無旗標 exit 0' 0 "$rc18a" "$out18a"
has   '⑱ 無 key 無旗標 → 略過並提示 --force-unstarted' "$out18a" '無 LINEAR_API_KEY 查不到 Linear 狀態；票已 Canceled／Done 請加 --force-unstarted'
exists_wt "$uwts/LS-910-flag" '⑱ 無 key 無旗標 → worktree 仍在'
out18b="$(bash "$cleanup" --apply --force-unstarted --repo "$u/repo" LS-910 2>&1)"; rc18b=$?
rc_is '⑱ --force-unstarted exit 0' 0 "$rc18b" "$out18b"
has   '⑱ --force-unstarted 標示理由' "$out18b" '尚未開工；--force-unstarted'
gone_wt "$uwts/LS-910-flag" '⑱ --force-unstarted → LS-910-flag worktree 已移除'
no_branch "$u/repo" LS-910-flag '⑱ --force-unstarted → LS-910-flag 本機分支已刪'
out18c="$(LINEAR_API_KEY=lin_api_stubtoken LINEAR_STUB_TYPE=completed CURL_STUB_LOG="$u/curl.log" bash "$cleanup" --apply --repo "$u/repo" LS-911 2>&1)"; rc18c=$?
rc_is '⑱ Linear completed exit 0' 0 "$rc18c" "$out18c"
has   '⑱ Linear completed 標示理由' "$out18c" 'Linear LS-911 狀態 Done／completed'
gone_wt "$uwts/LS-911-done" '⑱ Linear completed → LS-911-done worktree 已移除'
no_branch "$u/repo" LS-911-done '⑱ Linear completed → LS-911-done 本機分支已刪'
grep -q 'LS-911' "$u/curl.log" && echo "✓ ⑱ stub curl 收到 LS-911 查詢" || { echo "✗ ⑱ stub curl 未收到 LS-911 查詢" >&2; fail=1; }
grep -q 'lin_api_stubtoken' "$u/curl.log" && { echo "✗ ⑱ token 出現在 curl argv（應只走 -K - stdin）" >&2; fail=1; } || echo "✓ ⑱ token 不進 curl argv"
out18d="$(LINEAR_API_KEY=lin_api_stubtoken LINEAR_STUB_TYPE=started bash "$cleanup" --apply --repo "$u/repo" LS-912 2>&1)"; rc18d=$?
rc_is '⑱ Linear started exit 0' 0 "$rc18d" "$out18d"
has   '⑱ Linear started → 略過並提示' "$out18d" 'In Progress／started，非 completed／canceled'
exists_wt "$uwts/LS-912-active" '⑱ Linear started → LS-912-active worktree 仍在'
has_branch "$u/repo" LS-912-active '⑱ Linear started → LS-912-active 本機分支仍在'
out18e="$(bash "$cleanup" --apply --all --force-unstarted --repo "$u/repo" 2>&1)"; rc18e=$?
rc_is '⑱ --force-unstarted 不帶票號 → exit 2' 2 "$rc18e" "$out18e"
exists_wt "$uwts/LS-912-active" '⑱ 被拒時未動任何 worktree'
out18f="$(bash "$cleanup" --dry-run --force-unstarted --repo "$u/repo" LS-913 2>&1)"; rc18f=$?
rc_is '⑱ dry-run＋--force-unstarted exit 0' 0 "$rc18f" "$out18f"
has   '⑱ dry-run 列出將移除' "$out18f" '[dry-run] 移除 worktree LS-913-dry'
exists_wt "$uwts/LS-913-dry" '⑱ dry-run 零副作用'
echo note > "$uwts/LS-913-dry/note.txt"
out18g="$(bash "$cleanup" --apply --force-unstarted --repo "$u/repo" LS-913 2>&1)"; rc18g=$?
rc_is '⑱ 尚未開工但有未追蹤檔＋旗標 exit 0' 0 "$rc18g" "$out18g"
has   '⑱ 旗標不繞過 dirty 判定' "$out18g" '?? note.txt'
exists_wt "$uwts/LS-913-dry" '⑱ 有未追蹤檔 → 旗標也不清'

if [ "$fail" -eq 0 ]; then echo "✓ cleanup-merged.test.sh 全綠"; else echo "✗ cleanup-merged.test.sh 有失敗" >&2; fi
exit "$fail"
