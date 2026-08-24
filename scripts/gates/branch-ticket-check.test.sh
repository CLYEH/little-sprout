#!/bin/bash
# branch-ticket-check.sh 的自測（LS-50）。CI rules job 每個 PR 都跑。
# 「前饋必有反饋」對 gate 本身也適用：若檢查退化成看不到異票號、Bundles: 宣告退回子字串比對、
# 保護分支 merge 回來的 commit 被誤擋、或缺 ref 時靜默放行，這裡會紅。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/scripts/gates/branch-ticket-check.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
R="$work/repo"

# 臨時 repo 與本機全域／系統 git 設定隔離：自測結果不能因人而異
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
# c <subject> [<body>]：空 commit（gate 只看訊息，內容無關）
c() {
  if [ $# -ge 2 ]; then g commit -q --allow-empty -m "$1" -m "$2"; else g commit -q --allow-empty -m "$1"; fi
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

mkdir -p "$R"
g init -q -b development
c 'chore(harness): LS-1 init'
c0=$(g rev-parse HEAD)
g update-ref refs/remotes/origin/development HEAD

# ① 事件原形：feature/LS-38 疊了 LS-31 的 commit → 紅，列出違規 commit
g checkout -q -b feature/LS-38-pink-tracks
c 'design(canvas): LS-31 軌 B r1'
c 'design(canvas): LS-31 軌 B r2'
c 'design(pen): LS-38 粉色 r1'
expect 1 '① 夾帶他票 commit → 紅並列出' '[LS-31] design(canvas): LS-31 軌 B r1' --base origin/development

# ② 本票 commit body 獨佔一行 Bundles: 宣告 → 綠且印出宣告
c 'docs(design): LS-38 宣告夾帶 LS-31' $'Bundles: LS-31\n理由：軌 B 三個 commit 一起交，LS-31 未開 PR'
expect 0 '② commit body Bundles: 宣告 → 綠且印出宣告' 'Bundles: LS-31' --base origin/development

# ③ --pr-body（CI）：逃生口使用必須在 PR 可見
printf 'Ticket: LS-38\n' > "$work/pr-none.md"
expect 1 '③ PR body 未宣告 → 紅' 'PR body' --base origin/development --pr-body "$work/pr-none.md"
printf 'Ticket: LS-38\r\n\r\n  Bundles: LS-31  \r\n理由：軌 B\r\n' > "$work/pr-ok.md"
expect 0 '③′ PR body 獨佔一行宣告（前導／尾隨空白、CRLF）→ 綠' 'PR body 已宣告 Bundles: LS-31' --base origin/development --pr-body "$work/pr-ok.md"
printf '本 PR 不需要 Bundles: LS-31 宣告\n' > "$work/pr-prose.md"
expect 1 '③″ PR body 散文提及不算' 'PR body' --base origin/development --pr-body "$work/pr-prose.md"
printf '**Bundles:** LS-31\n' > "$work/pr-bold.md"
expect 1 '③‴ PR body 粗體包起不算' 'PR body' --base origin/development --pr-body "$work/pr-bold.md"
printf 'Bundles: LS-31（軌 B）\n' > "$work/pr-trail.md"
expect 1 '③⁗ PR body 同行尾隨文字不算（理由寫下一行）' 'PR body' --base origin/development --pr-body "$work/pr-trail.md"
printf '本 PR 不含 Bundles: LS-31\n' > "$work/pr-lead.md"
expect 1 '③⁗′ PR body 句中提及、行尾恰是票號也不算（起點錨定）' 'PR body' --base origin/development --pr-body "$work/pr-lead.md"

# ④ commit body 散文提及不算宣告（行錨定）
g checkout -q -b feature/LS-39-prose "$c0"
c 'design(canvas): LS-31 軌 B r1'
c 'docs(design): LS-39 提及' '見 Bundles: LS-31 的討論'
expect 1 '④ commit body 散文提及 Bundles: 不算 → 紅' '[LS-31]' --base origin/development
c 'docs(design): LS-39 再提及' '見討論 Bundles: LS-31'
expect 1 '④′ commit body 句中提及、行尾恰是票號也不算（起點錨定）' '[LS-31]' --base origin/development

# ⑤ 一行宣告多票；宣告只涵蓋一部分 → 仍紅、只列未宣告的
c 'design(canvas): LS-32 another'
c 'docs(design): LS-39 宣告一半' 'Bundles: LS-31'
expect 1 '⑤ 宣告只涵蓋一部分 → 紅並列出未宣告的' '[LS-32]' --base origin/development
c 'docs(design): LS-39 宣告全部' 'Bundles: LS-31, LS-32'
expect 0 '⑤′ 一行宣告多票 → 綠' 'Bundles: LS-31, LS-32' --base origin/development

# ⑥ 乾淨分支（含 Revert 本票 commit）→ 綠
g checkout -q -b feature/LS-40-clean "$c0"
c 'feat(ios): LS-40 a'
c 'Revert "feat(ios): LS-40 a"'
expect 0 '⑥ 只有本票 commit（含 Revert）→ 綠' '分支票號乾淨（LS-40，2 commits）' --base origin/development

# ⑦ 無票號 commit → 紅（無從宣告）
c 'wip'
expect 1 '⑦ 無票號 commit → 紅' '[無票號] wip' --base origin/development
g reset -q --hard HEAD~1

# ⑧ 缺 base ref → exit 2（fail closed，不靜默放行）；origin/main 此時尚未建立
expect 2 '⑧ 找不到 --base ref → exit 2' 'git fetch' --base origin/main

# ⑨ --branch 非工作分支格式 → exit 2
expect 2 '⑨ --branch 是保護分支 → exit 2' '沒有本票票號' --base origin/development --branch development

# ⑩ --branch 覆寫（CI 的 detached checkout 形狀）：當前分支 LS-40，改以 LS-31 之名檢查 → LS-40 變異票
expect 1 '⑩ --branch 覆寫分支名 → 以覆寫者為準' '[LS-40] feat(ios): LS-40 a' --base origin/development --branch feature/LS-31-x

# ⑪ 把保護分支 merge 回來：他票 commit 已在 origin/main 上 → 排除、merge commit 排除 → 綠；拿掉 ref 就會紅
g checkout -q -b main "$c0"
c 'chore(harness): LS-3 hotfix on main'
g update-ref refs/remotes/origin/main HEAD
g checkout -q development
c 'feat(db): LS-2 dev moves on'
g update-ref refs/remotes/origin/development HEAD
g checkout -q feature/LS-40-clean
g merge -q --no-ff -m "Merge branch 'development' into feature/LS-40-clean" development
g merge -q --no-ff -m "Merge branch 'main' into feature/LS-40-clean" main
expect 0 '⑪ merge 回 development／main（他票 commit 已在保護分支）→ 綠' '分支票號乾淨（LS-40，2 commits）' --base origin/development
g update-ref -d refs/remotes/origin/main
expect 1 '⑪′ 拿掉 origin/main ref → 同一條分支變紅（證明排除靠的是保護分支 ref）' '[LS-3]' --base origin/development

if [ "$fail" -ne 0 ]; then
  echo "✗ branch-ticket-check 自測失敗" >&2
  exit 1
fi
echo "✓ branch-ticket-check 自測通過（19 組樣本）"
