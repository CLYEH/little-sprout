#!/bin/bash
# migration-immutable-check.sh 的自測（LS-80）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若已併入 base 的 migration 被改／改名／刪除卻放行、純新增被誤擋、
# 逃生口未經 commit body（給了 --pr-body 時還要 PR body）雙重宣告卻放行、逃生口標記被散文提及／格式不符
# 也算數、或找不到 ref 時靜默跳過——這裡會紅。
# 合成 repo：development 當一般 fix|feature 情境的 target；main 當 hotfix 情境的 target，用來重演 LS-57 R2
# （hotfix 直接改已併入 main 的既有 migration）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/scripts/gates/migration-immutable-check.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
R="$work/repo"
M=supabase/migrations

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
mig() {   # mig <檔名> [內容]：寫 migration 檔並 commit
  mkdir -p "$R/$M"; printf '%s\n' "${2:-select 1;}" > "$R/$M/$1"; g add -A; g commit -qm "feat(db): LS-1 $1"
}
branch() {   # branch <新分支名> <起點分支>
  g checkout -q "$2" && g checkout -q -b "$1"
}
commit_body() {   # commit_body <subject> <body>：改 README 觸發一個帶指定 body 的 commit
  echo "x-$RANDOM" >> "$R/README.md"
  g add -A
  g commit -qm "$1" -m "$2"
}

# expect <期望 exit code> <樣本名稱> <輸出必含字串|''> <checker 參數…>
expect() {
  local want=$1 name=$2 must=$3 out got
  shift 3
  out="$(cd "$R" && bash "$check" "$@" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ] && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; }; then
    echo "✓ ${name}"
  else
    echo "✗ ${name}（期望 exit ${want}${must:+、輸出含「${must}」}，實得 ${got}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}
hasnt() {   # hasnt <名稱> <不得含> <checker 參數…>
  local name=$1 no=$2 out; shift 2
  out="$(cd "$R" && bash "$check" "$@" 2>&1)"
  if printf '%s' "$out" | grep -qF -- "$no"; then echo "✗ ${name}（輸出不應含「${no}」）" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1; else echo "✓ ${name}"; fi
}

# ---- 合成 repo：development 有兩個既有 migration；main 從同一點分出 ----
mkdir -p "$R"; g init -q -b development
echo x > "$R/README.md"; g add -A; g commit -qm 'chore(harness): LS-1 init'
mig 20260101000000_init.sql
mig 20260102000000_two.sql
g branch -q main development

# ① 正向：本分支只新增，不動既有檔 → exit 0
branch feature/LS-2-add development
mig 20260103000000_three.sql
expect 0 '① 只新增既有檔不動 → exit 0' '' --base development
hasnt  '① 不誤報任何違規' '✗' --base development

# ② 修改既有檔 → 紅
branch feature/LS-3-modify development
mig 20260101000000_init.sql 'select 2;'
expect 1 '② 修改既有 migration → exit 1' '修改：supabase/migrations/20260101000000_init.sql' --base development
expect 1 '② 印正確做法' '新增一張新版本號的 migration' --base development
expect 1 '② 印逃生口說明' 'MIGRATION-REWRITE-APPROVED: LS-<n>' --base development

# ③ 刪除既有檔 → 紅
branch feature/LS-4-delete development
g rm -q "$M/20260102000000_two.sql"; g commit -qm 'fix(db): LS-1 remove'
expect 1 '③ 刪除既有 migration → exit 1' '刪除：supabase/migrations/20260102000000_two.sql' --base development

# ④ 改名既有檔 → 紅（即使內容不變），訊息含新舊路徑
branch feature/LS-5-rename development
g mv "$M/20260101000000_init.sql" "$M/20260101000000_init_v2.sql"; g commit -qm 'chore(db): LS-1 rename'
expect 1 '④ 改名既有 migration（內容不變）→ exit 1' '改名：supabase/migrations/20260101000000_init.sql → supabase/migrations/20260101000000_init_v2.sql' --base development

# ④b typechange：既有 migration 換成 symlink（指到別的檔）→ 紅（R1 major：--diff-filter=MRD 漏收 T，
# 已改 MRDT；攻擊構造照 R1 review 實跑重現的形狀）
branch feature/LS-5b-symlink development
rm -f "$R/$M/20260101000000_init.sql"
printf 'drop table foo; -- EVIL\n' > "$R/$M/evil.sql"
ln -s evil.sql "$R/$M/20260101000000_init.sql"
g add -A; g commit -qm 'fix(db): LS-1 symlink swap'
expect 1 '④b typechange：既有 migration 換成 symlink → exit 1' '類型變更（檔↔symlink／submodule）：supabase/migrations/20260101000000_init.sql' --base development

# ④c typechange：既有 migration 換成 gitlink（160000，submodule 形狀）→ 紅
branch feature/LS-5c-gitlink development
g update-index --add --cacheinfo 160000,0000000000000000000000000000000000000001,"$M/20260101000000_init.sql"
g commit -qm 'fix(db): LS-1 gitlink swap'
expect 1 '④c typechange：既有 migration 換成 gitlink → exit 1' '類型變更（檔↔symlink／submodule）：supabase/migrations/20260101000000_init.sql' --base development

# ⑤ 只改 README，未碰 migrations → 綠
branch feature/LS-6-readme development
echo r >> "$R/README.md"; g add -A; g commit -qm 'docs: LS-1 readme'
expect 0 '⑤ 未動 migrations → exit 0' '' --base development

# ⑥ 本分支自己新增、又在本分支內修改（從未併入 base）→ 綠，不算「改動已存在檔」
branch feature/LS-7-addmodify development
mig 20260104000000_new.sql
mig 20260104000000_new.sql 'select 9;'
expect 0 '⑥ 本分支新增又自己改 → exit 0（未併入 base 的檔不受限）' '' --base development

# ⑦ supabase/tests/ 下同名變更不算（只管 migrations/ 目錄）
branch feature/LS-7b-tests development
mkdir -p "$R/supabase/tests"; echo 'select 1;' > "$R/supabase/tests/20260101000000_init.sql"; g add -A; g commit -qm 'test(db): LS-1 add test'
expect 0 '⑦ supabase/tests/ 下的變更不算違規' '' --base development

# ⑧ 逃生口：commit body 獨佔一行宣告，未給 --pr-body → 綠並印出宣告
branch feature/LS-8-escape development
mig 20260101000000_init.sql 'select 3;'
commit_body 'chore(db): LS-8 note' 'MIGRATION-REWRITE-APPROVED: LS-8'$'\n''理由：尚未部署到正式站，修正 typo'
expect 0 '⑧ commit body 宣告逃生口、未給 --pr-body → exit 0' 'MIGRATION-REWRITE-APPROVED: LS-8' --base development
expect 0 '⑧ 印出提醒 PR body 須同步宣告' 'PR body 須同段落宣告' --base development

# ⑨ 逃生口＋ --pr-body 沒有同步宣告 → 紅
echo 'Ticket: LS-8 沒有宣告逃生口' > "$work/pr-body-no.txt"
expect 1 '⑨ commit 宣告但 PR body 沒有同步 → exit 1' 'PR body 沒有同樣獨佔一行的宣告' --base development --pr-body "$work/pr-body-no.txt"

# ⑩ 逃生口＋ --pr-body 也同步宣告 → 綠
printf 'Ticket: LS-8\nMIGRATION-REWRITE-APPROVED: LS-8\n' > "$work/pr-body-yes.txt"
expect 0 '⑩ commit 與 PR body 都宣告 → exit 0' 'PR body 已宣告逃生口' --base development --pr-body "$work/pr-body-yes.txt"

# ⑪ 逃生口標記非獨佔一行（前後有其他文字）→ 不算數，仍紅（同 LS-45／LS-50 的行錨定）
branch feature/LS-9-fakeescape development
mig 20260102000000_two.sql 'select 4;'
commit_body 'chore(db): LS-9 note' '這次不需要 MIGRATION-REWRITE-APPROVED: LS-9，因為沒改內容'
expect 1 '⑪ 逃生口標記非獨佔一行（散文提及）→ 仍紅' '修改：supabase/migrations/20260102000000_two.sql' --base development
branch feature/LS-9b-boldescape development
mig 20260102000000_two.sql 'select 5;'
commit_body 'chore(db): LS-9b note' '**MIGRATION-REWRITE-APPROVED: LS-9b**'
expect 1 '⑪ 逃生口標記被粗體包起 → 仍紅' '修改：' --base development

# ⑫ LS-57 R2 重演：hotfix 從 main 切、直接修改已併入 main 的既有 migration（LS-70 的撞號 gate 不擋內容改動）
g checkout -q main
mig 20260825030000_children_write_path_and_soft_delete.sql "select raise_exception('LS040');"
branch hotfix/LS-80-reenact main
mig 20260825030000_children_write_path_and_soft_delete.sql "select raise_exception('42501');"
expect 1 '⑫ LS-57 R2 重演：hotfix 改已併入 main 的既有 migration → exit 1' '修改：supabase/migrations/20260825030000_children_write_path_and_soft_delete.sql' --base main

# ⑬ 參數／ref 錯誤 fail closed（exit 2）
expect 2 '⑬ 缺 --base → exit 2' '缺 --base' --head development
expect 2 '⑬ --base 缺值 → exit 2' '缺值' --base
expect 2 '⑬ --base 不存在 → exit 2' '找不到' --base origin/nope
expect 2 '⑬ --head 不存在 → exit 2' '找不到' --base development --head nope
expect 2 '⑬ 未知參數 → exit 2' '未知參數' --base development --bogus
expect 2 '⑬ --pr-body 缺值 → exit 2' '缺值' --base development --pr-body
expect 2 '⑬ --pr-body 讀不到檔 → exit 2' '讀不到' --base development --pr-body "$work/nope.txt"

if [ "$fail" -eq 0 ]; then
  echo "✓ migration-immutable-check 自測通過"
fi
exit "$fail"
