#!/bin/bash
# main-checkout-guard.sh 自測（LS-154）。CI rules job 每個 PR 都跑。
# fixture：`mktemp -d` 建臨時 repo（主 checkout）＋linked worktree（.claude/worktrees/LS-1）
# ＋repo 外目錄（scratchpad／memory）＋另一個 repo 的主 checkout，不依賴真實路徑；每組樣本
# 以 env CLAUDE_PROJECT_DIR=<fixture 主 checkout> 餵 hook JSON（tool_name／tool_input／cwd）。
# 「前饋必有反饋」對 gate 本身也適用：W1–W5 若退化這裡會紅；mutation 段把 git-dir==common-dir
# 判斷拿掉，斷言負樣本因此變綠（證明該判斷是關鍵、不是巧合過關）。
# R2（merge-review R1 comment 94035c1a）：G 段——GIT_DIR 等變數污染下 worktree 仍放行（minor 1，
# mutation M3 拿掉 env 剝除必須變紅）；S5–S7——逃生門認 `env VAR=1` 前綴、非最前面不認且訊息寫明
# 位置（minor 2）；N2b——LS-145 第三起事故形狀 Edit 主 checkout .github/workflows/ci.yml（informational 1）；
# T1——hook 跑完不在 hooks 目錄留 __pycache__（自查：留了會把主 checkout 弄 dirty）。
# LS-157（R2 comment 47ab021a N1／informational 1＋3、LS-154 收尾實測）：G4–G6——未列名 GIT_OBJECT_DIRECTORY 下
# 主 checkout 仍 W1 擋、worktree／scratchpad 仍放行；X 段——安全網：目標落在 hook 解析出的 repo 根之下但 rev-parse 說
# 不在 repo 內 → W0 deny 並印 stderr 首行（mutation M4 把全剝換回五個具名：worktree 變紅、主 checkout 退成 W0；
# M5 拿掉安全網：壞 .git 根下 Write 變綠）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="${root}/scripts/hooks/main-checkout-guard.sh"
guard_py="${root}/scripts/hooks/main_checkout_guard.py"
engine_py="${root}/scripts/hooks/pretool_engine.py"
fail=0
bash_bin=$(bash -c 'type -P bash' 2>/dev/null || echo /bin/bash)

# ---- fixture ----
fx=$(mktemp -d)
trap 'rm -rf "$fx"' EXIT
main="$fx/repo"
wt="$main/.claude/worktrees/LS-1"
git init -q -b main "$main"
git -C "$main" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m init
git -C "$main" worktree add -q "$wt" -b feature/LS-1-x
mkdir -p "$main/docs" "$main/supabase/migrations" "$main/scripts/ops" "$main/.claude/memory" "$main/.github/workflows" \
  "$wt/docs" "$wt/supabase/migrations" "$fx/scratch" "$fx/home/.claude/projects/p" "$fx/other"
# 真實環境：~/.claude/projects/<proj>/memory 是指向主 checkout .claude/memory/ 的 symlink（realpath 落在主 checkout）
ln -s "$main/.claude/memory" "$fx/home/.claude/projects/p/memory"
printf 'x\n' > "$main/docs/a.md"
printf 'x\n' > "$main/.github/workflows/ci.yml"
printf 'x\n' > "$wt/docs/a.md"
printf 'x\n' > "$fx/scratch/LS-1-new.sql"
git init -q -b main "$fx/other"   # 另一個 repo 的主 checkout：不在本專案範圍，不擋
# LS-157 1a：.git 檔指向不存在的 gitdir → rev-parse 對其下任何目錄都回「fatal: not a git repository: …」（安全網樣本）
mkdir -p "$fx/broken/sub"
printf 'gitdir: %s/nonexistent-gitdir\n' "$fx" > "$fx/broken/.git"

# ---- JSON 組裝（python3 處理跳脫；命令可含引號／換行）----
mkjson() {   # $1=tool_name $2=cwd $3=tool_input key $4=value
  python3 -c 'import json,sys; print(json.dumps({"tool_name":sys.argv[1],"cwd":sys.argv[2],"tool_input":{sys.argv[3]:sys.argv[4]}}))' "$@"
}
bash_json() { mkjson Bash "$1" command "$2"; }        # $1=cwd $2=command
file_json() { mkjson "$1" "$2" file_path "$3"; }      # $1=tool $2=cwd $3=path

# expect <label> <want_exit> <payload> [VAR=val ...]：allow（0）驗 stdout 無輸出（stderr 可有註記）；
# deny（2）驗 stdout 含 deny JSON。額外參數以 env 覆寫子行程環境（放在 CLAUDE_PROJECT_DIR 之後，後者優先）。
expect() {
  local label=$1 want=$2 payload=$3 out got
  shift 3
  out=$(printf '%s' "$payload" | env CLAUDE_PROJECT_DIR="$main" "$@" "$bash_bin" "$guard" 2>"$fx/stderr")
  got=$?
  if [ "$got" -ne "$want" ]; then
    echo "✗ ${label}（期望 exit ${want}，實得 ${got}；stdout：${out}；stderr：$(cat "$fx/stderr")）" >&2
    fail=1
    return
  fi
  if [ "$want" -eq 0 ]; then
    if [ -n "$out" ]; then
      echo "✗ ${label}（allow 應 stdout 無輸出，實得：${out}）" >&2
      fail=1
      return
    fi
  else
    case "$out" in
      *'"permissionDecision":"deny"'*|*'"permissionDecision": "deny"'*) : ;;
      *) echo "✗ ${label}（deny 應輸出 deny JSON，實得：${out}）" >&2; fail=1; return ;;
    esac
    case "$(cat "$fx/stderr")" in
      *'主 checkout 禁寫'*|*'fail-closed'*) : ;;
      *) echo "✗ ${label}（deny 的 stderr 應含理由，實得：$(cat "$fx/stderr")）" >&2; fail=1; return ;;
    esac
  fi
  echo "✓ ${label}"
}

# ============================================================
# 正樣本（allow）
# ============================================================
expect 'P1 Write worktree 內檔案' 0 "$(file_json Write "$main" "$wt/docs/new.md")"
expect 'P2 Edit worktree 內既有檔案' 0 "$(file_json Edit "$main" "$wt/docs/a.md")"
expect 'P3 Write scratchpad（repo 外）' 0 "$(file_json Write "$main" "$fx/scratch/LS-1-body.md")"
expect 'P4 Write memory 目錄（symlink → 主 checkout .claude/memory/，白名單）' 0 "$(file_json Write "$main" "$fx/home/.claude/projects/p/memory/MEMORY.md")"
expect 'P4b Write 主 checkout .claude/memory/ 直接路徑（白名單）' 0 "$(file_json Write "$main" "$main/.claude/memory/notes.md")"
expect 'P5 Write 相對路徑、cwd 是 worktree' 0 "$(file_json Write "$wt" "docs/rel.md")"
expect 'P6 Write 另一個 repo 的主 checkout（不在本專案範圍）' 0 "$(file_json Write "$main" "$fx/other/x.txt")"
expect 'P7 Write 白名單 .claude/patrol-state.json' 0 "$(file_json Write "$main" "$main/.claude/patrol-state.json")"
expect 'P8 git -C root pull' 0 "$(bash_json "$main" "git -C $main pull")"
expect 'P9 git -C root worktree add' 0 "$(bash_json "$main" "git -C $main worktree add $main/.claude/worktrees/LS-2 -b feature/LS-2-y origin/development")"
expect 'P10 git 唯讀（status／log／diff／rev-parse／merge-base／branch／fetch／tag／stash list）' 0 \
  "$(bash_json "$main" "git status; git log --oneline -3; git diff; git rev-parse HEAD; git merge-base main HEAD; git branch -a; git fetch origin; git tag; git stash list")"
expect 'P11 bash scripts/ops/promote.sh（cwd 主 checkout）' 0 "$(bash_json "$main" "bash scripts/ops/promote.sh development test")"
expect 'P12 bash scripts/gates/pr-body-check.sh' 0 "$(bash_json "$main" "bash scripts/gates/pr-body-check.sh $fx/scratch/LS-1-body.md")"
expect 'P13 sed -n 純讀主 checkout 檔案' 0 "$(bash_json "$main" "sed -n '1,5p' $main/docs/a.md")"
expect 'P14 cat｜grep 純讀' 0 "$(bash_json "$main" "cat $main/docs/a.md | grep x")"
expect 'P15 gh pr create --body-file（scratchpad）' 0 "$(bash_json "$main" "gh pr create --base main --body-file $fx/scratch/LS-1-body.md")"
expect 'P16 重導到 scratchpad（cwd 主 checkout）' 0 "$(bash_json "$main" "echo hi > $fx/scratch/out.txt")"
expect 'P17 重導 /dev/null 與 fd 複製' 0 "$(bash_json "$main" "ls 2>/dev/null; echo x >&2; cmd 2>&1 | tail -3")"
expect 'P18 cd 進 worktree 後相對路徑寫檔' 0 "$(bash_json "$main" "cd $wt && echo hi > f.txt")"
expect 'P19 cp 來源在主 checkout、目的地在外' 0 "$(bash_json "$main" "cp $main/docs/a.md $fx/scratch/")"
expect 'P20 tee 到 scratchpad' 0 "$(bash_json "$main" "xcodebuild test 2>&1 | tee $fx/scratch/build.log")"
expect 'P21 git commit 在 worktree（-C）' 0 "$(bash_json "$main" "git -C $wt add -A && git -C $wt commit -m 'feat: LS-1 x'")"
expect 'P22 git commit、cwd 是 worktree' 0 "$(bash_json "$wt" "git add -A && git commit -m 'feat: LS-1 x'")"
expect 'P23 sed -i 在 worktree 檔案' 0 "$(bash_json "$main" "sed -i '' 's/a/b/' $wt/docs/a.md")"
expect 'P24 heredoc 給 cat 寫到 scratchpad（內文提到主 checkout 路徑不算）' 0 \
  "$(bash_json "$main" "cat > $fx/scratch/LS-1-body.md <<'EOF'
see $main/docs/a.md
EOF")"
expect 'P25 python3 heredoc 只碰 scratchpad' 0 \
  "$(bash_json "$main" "python3 - <<'EOF'
open('$fx/scratch/x.json','w').write('{}')
EOF")"
expect 'P26 Read 工具不在範圍（放行）' 0 "$(file_json Read "$main" "$main/docs/a.md")"
expect 'P27 mkdir／touch 在 scratchpad' 0 "$(bash_json "$main" "mkdir -p $fx/scratch/d && touch $fx/scratch/d/x")"

# ============================================================
# 負樣本（deny）
# ============================================================
expect 'N1 Write 主 checkout' 2 "$(file_json Write "$main" "$main/LS-1-probe.txt")"
expect 'N2 Edit 主 checkout 既有檔案' 2 "$(file_json Edit "$main" "$main/docs/a.md")"
expect 'N2b Edit 主 checkout .github/workflows/ci.yml（LS-145 第三起事故形狀）' 2 "$(file_json Edit "$main" "$main/.github/workflows/ci.yml")"
expect 'N3 MultiEdit 主 checkout' 2 "$(file_json MultiEdit "$main" "$main/scripts/ops/x.sh")"
expect 'N4 NotebookEdit 主 checkout（notebook_path）' 2 "$(mkjson NotebookEdit "$main" notebook_path "$main/n.ipynb")"
expect 'N5 Write 相對路徑、cwd 是主 checkout' 2 "$(file_json Write "$main" "LS-1-probe.txt")"
expect 'N6 Write .claude/worktrees/ 底下但不在任何 worktree 內' 2 "$(file_json Write "$main" "$main/.claude/worktrees/stray.txt")"
expect 'N6b Write .claude/ 其他檔案不在白名單（settings.json）' 2 "$(file_json Write "$main" "$main/.claude/settings.json")"
expect 'N7 Write 主 checkout 不存在的深層目錄' 2 "$(file_json Write "$main" "$main/supabase/migrations/new/x.sql")"
expect 'N8 tee 主 checkout' 2 "$(bash_json "$main" "echo hi | tee $main/x")"
expect 'N9 cp 進主 checkout supabase/migrations/' 2 "$(bash_json "$main" "cp $fx/scratch/LS-1-new.sql $main/supabase/migrations/")"
expect 'N10 cd 主 checkout && echo > f' 2 "$(bash_json "$fx/scratch" "cd $main && echo hi > f")"
expect 'N11 sed -i 主 checkout 檔案' 2 "$(bash_json "$fx/scratch" "sed -i '' 's/a/b/' $main/docs/a.md")"
expect 'N12 相對路徑重導、cwd 是主 checkout（fail-closed）' 2 "$(bash_json "$main" "echo hi > out.txt")"
expect 'N13 mv 進主 checkout' 2 "$(bash_json "$fx/scratch" "mv LS-1-new.sql $main/supabase/migrations/")"
expect 'N14 >> 黏連目標' 2 "$(bash_json "$fx/scratch" "cmd 2>>$main/err.log")"
expect 'N15 &> 主 checkout' 2 "$(bash_json "$fx/scratch" "cmd &>$main/all.log")"
expect 'N16 install 進主 checkout' 2 "$(bash_json "$fx/scratch" "install -m 644 x $main/scripts/ops/x.sh")"
expect 'N17 rsync 進主 checkout' 2 "$(bash_json "$fx/scratch" "rsync -a src/ $main/docs/")"
expect 'N18 rm 主 checkout 檔案' 2 "$(bash_json "$fx/scratch" "rm -f $main/docs/a.md")"
expect 'N19 touch／mkdir 主 checkout' 2 "$(bash_json "$fx/scratch" "mkdir -p $main/newdir")"
expect 'N20 git -C root checkout（W3）' 2 "$(bash_json "$fx/scratch" "git -C $main checkout -b feature/LS-9-z")"
expect 'N21 git commit、cwd 是主 checkout（W3）' 2 "$(bash_json "$main" "git add -A && git commit -m x")"
expect 'N22 git stash（bare＝push，W3）' 2 "$(bash_json "$main" "git stash")"
expect 'N23 bash -c 包重導到主 checkout（遞迴）' 2 "$(bash_json "$fx/scratch" "bash -c 'echo hi > $main/x'")"
expect 'N24 python3 heredoc 提到主 checkout 路徑（W4）' 2 \
  "$(bash_json "$fx/scratch" "python3 - <<'EOF'
open('$main/x','w').write('hi')
EOF")"
expect 'N25 python3 -c 提到主 checkout 路徑（W4）' 2 "$(bash_json "$fx/scratch" "python3 -c \"open('$main/x','w')\"")"
expect 'N26 命令替換內 tee 主 checkout（遞迴）' 2 "$(bash_json "$fx/scratch" "echo \$(date | tee $main/x)")"
expect 'N27 cp -t 主 checkout' 2 "$(bash_json "$fx/scratch" "cp -t $main/docs a.md")"
expect 'N28 引號不平衡＋字面含主 checkout 路徑與重導（W5 fail-closed）' 2 "$(bash_json "$fx/scratch" "echo 'oops > $main/x")"
expect 'N29 env 透明前綴後的 tee' 2 "$(bash_json "$fx/scratch" "FOO=1 env BAR=2 tee $main/x")"
expect 'N30 >| 主 checkout' 2 "$(bash_json "$fx/scratch" "echo hi >| $main/x")"

# ============================================================
# 開關
# ============================================================
expect 'S1 LS_ALLOW_MAIN_CHECKOUT_WRITE=1（環境變數）放行主 checkout Write' 0 \
  "$(file_json Write "$main" "$main/LS-1-probe.txt")" LS_ALLOW_MAIN_CHECKOUT_WRITE=1
case "$(cat "$fx/stderr")" in
  *LS_ALLOW_MAIN_CHECKOUT_WRITE=1*) echo '✓ S1b 開關放行時 stderr 有註明' ;;
  *) echo "✗ S1b 開關放行應 stderr 註明（實得：$(cat "$fx/stderr")）" >&2; fail=1 ;;
esac
expect 'S2 開關值不是 1 不放行' 2 "$(file_json Write "$main" "$main/LS-1-probe.txt")" LS_ALLOW_MAIN_CHECKOUT_WRITE=0
expect 'S3 Bash 命令以 LS_ALLOW_MAIN_CHECKOUT_WRITE=1 開頭放行該次' 0 \
  "$(bash_json "$fx/scratch" "LS_ALLOW_MAIN_CHECKOUT_WRITE=1 mv $main/stray.sql $wt/supabase/migrations/")"
expect 'S4 開關字面不在命令開頭不放行' 2 "$(bash_json "$fx/scratch" "echo LS_ALLOW_MAIN_CHECKOUT_WRITE=1; tee $main/x")"
expect 'S5 env LS_ALLOW_MAIN_CHECKOUT_WRITE=1 <cmd>（POSIX 形式）放行' 0 \
  "$(bash_json "$fx/scratch" "env LS_ALLOW_MAIN_CHECKOUT_WRITE=1 rm $main/stray.sql")"
expect 'S6 FOO=1 env LS_ALLOW_MAIN_CHECKOUT_WRITE=1 <cmd>（賦值與 env 混合前綴）放行' 0 \
  "$(bash_json "$fx/scratch" "FOO=1 env LS_ALLOW_MAIN_CHECKOUT_WRITE=1 tee $main/x")"
expect 'S7 cd x && LS_ALLOW_MAIN_CHECKOUT_WRITE=1 <cmd>（非最前面）不放行' 2 \
  "$(bash_json "$fx/scratch" "cd $fx/scratch && LS_ALLOW_MAIN_CHECKOUT_WRITE=1 rm $main/docs/a.md")"
case "$(cat "$fx/stderr")" in
  *'env LS_ALLOW_MAIN_CHECKOUT_WRITE=1 <cmd>'*'整條命令最前面'*) echo '✓ S7b deny 訊息寫明兩種前綴形式與位置限制' ;;
  *) echo "✗ S7b deny 訊息應寫明 env 形式與位置限制（實得：$(cat "$fx/stderr")）" >&2; fail=1 ;;
esac

# ============================================================
# git 環境變數污染（R1 minor 1）：GIT_DIR 等在 hook 環境時，rev-parse 對任何 -C 目錄都回同一值，
# 未剝除會把所有 worktree 判成主 checkout（產線全停）
# ============================================================
expect 'G1 GIT_DIR＋GIT_WORK_TREE 設定下 worktree Write 仍放行' 0 \
  "$(file_json Write "$main" "$wt/docs/x.md")" GIT_DIR="$main/.git" GIT_WORK_TREE="$main"
expect 'G2 GIT_DIR 設定下主 checkout Write 仍擋' 2 \
  "$(file_json Write "$main" "$main/LS-1-probe.txt")" GIT_DIR="$main/.git"
expect 'G3 GIT_COMMON_DIR／GIT_INDEX_FILE／GIT_PREFIX 設定下 worktree Bash 重導仍放行' 0 \
  "$(bash_json "$wt" "echo hi > f.txt")" GIT_COMMON_DIR="$main/.git" GIT_INDEX_FILE="$main/.git/index" GIT_PREFIX=docs/
# LS-157 1a（R2 N1）：未列名的 GIT_OBJECT_DIRECTORY 指向不存在路徑時，rev-parse 對主 checkout 也回「not a git repository」
# → 只剝五個具名的舊版整支 gate 無聲 fail-open（實測 exit 0、stderr 空）
expect 'G4 GIT_OBJECT_DIRECTORY=/nonexist 下主 checkout Write 仍擋' 2 \
  "$(file_json Write "$main" "$main/LS-1-probe.txt")" GIT_OBJECT_DIRECTORY=/nonexist
case "$(cat "$fx/stderr")" in
  *'W1：'*) echo '✓ G4b 該 deny 是 W1 正常判定（不是靠安全網 W0）' ;;
  *) echo "✗ G4b GIT_OBJECT_DIRECTORY 下主 checkout deny 應為 W1（實得：$(cat "$fx/stderr")）" >&2; fail=1 ;;
esac
expect 'G5 GIT_OBJECT_DIRECTORY=/nonexist 下 worktree Write 仍放行' 0 \
  "$(file_json Write "$main" "$wt/docs/x.md")" GIT_OBJECT_DIRECTORY=/nonexist
expect 'G6 GIT_OBJECT_DIRECTORY=/nonexist 下 scratchpad Write 仍放行（repo 外路徑不受影響）' 0 \
  "$(file_json Write "$main" "$fx/scratch/x.md")" GIT_OBJECT_DIRECTORY=/nonexist

# ============================================================
# 安全網（LS-157 1a）：目標落在 hook 解析出的 repo 根（CLAUDE_PROJECT_DIR，缺則 cwd 上溯）之下、rev-parse 卻說
# 不在 repo 內（壞 .git／環境異常）→ W0 deny 並印 rev-parse stderr 首行；repo 外路徑行為不變
# ============================================================
expect 'X1 CLAUDE_PROJECT_DIR 指向 .git 壞掉的根，其下 Write → deny（fail-closed）' 2 \
  "$(file_json Write "$fx/broken" "$fx/broken/x.txt")" CLAUDE_PROJECT_DIR="$fx/broken"
case "$(cat "$fx/stderr")" in
  *'W0：'*'not a git repository'*) echo '✓ X1b deny 訊息是 W0 且含 rev-parse 的 stderr 首行' ;;
  *) echo "✗ X1b deny 訊息應為 W0 且含 rev-parse stderr 首行（實得：$(cat "$fx/stderr")）" >&2; fail=1 ;;
esac
expect 'X2 同環境 scratchpad Write 仍放行（repo 外路徑行為不變）' 0 \
  "$(file_json Write "$fx/broken" "$fx/scratch/x.txt")" CLAUDE_PROJECT_DIR="$fx/broken"
out=$(printf '%s' "$(bash_json "$fx/broken/sub" "echo hi > x.txt")" | env -u CLAUDE_PROJECT_DIR "$bash_bin" "$guard" 2>"$fx/stderr"); got=$?
if [ "$got" -eq 2 ] && case "$(cat "$fx/stderr")" in *'W0：'*'not a git repository'*) true ;; *) false ;; esac; then
  echo '✓ X3 無 CLAUDE_PROJECT_DIR 時自 cwd 上溯找到壞 .git 根，其下相對路徑重導 → W0 deny'
else
  echo "✗ X3 cwd 上溯的安全網應 W0 deny（實得 exit ${got}：$(cat "$fx/stderr")）" >&2; fail=1
fi

# ============================================================
# 盲區註記（放行但 stderr 要說）
# ============================================================
expect 'B1 目標含 $VAR 判不出→放行' 0 "$(bash_json "$main" "echo hi > \$OUT/x.txt")"
case "$(cat "$fx/stderr")" in
  *無法解析*) echo '✓ B1b 判不出時 stderr 有註記' ;;
  *) echo "✗ B1b 判不出應 stderr 註記（實得：$(cat "$fx/stderr")）" >&2; fail=1 ;;
esac

# ============================================================
# fail-closed
# ============================================================
expect 'F1 空 stdin（deny）' 2 ''
expect 'F2 JSON 壞掉（deny）' 2 '{"tool_name":"Write","tool_input":'
expect 'F3 PATH 沒有 python3（deny）' 2 "$(file_json Write "$main" "$wt/docs/x.md")" PATH=/nonexistent

miss=$(mktemp -d "$fx/miss.XXXXXX")
cp "$guard" "$miss/"
out=$(printf '%s' "$(file_json Write "$main" "$wt/docs/x.md")" | env CLAUDE_PROJECT_DIR="$main" "$bash_bin" "$miss/main-checkout-guard.sh" 2>/dev/null); got=$?
if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
  echo '✓ F4 main_checkout_guard.py 檔案不存在（deny）'
else
  echo "✗ F4 引擎檔缺席應 deny（實得 exit ${got}：${out}）" >&2; fail=1
fi

crash=$(mktemp -d "$fx/crash.XXXXXX")
cp "$guard_py" "$engine_py" "$crash/"
awk '{ print } $0 == "input=" { print "exit 1  # LS-154 test：模擬腳本中途未捕捉錯誤" }' "$guard" > "$crash/main-checkout-guard.sh"
out=$(printf '%s' "$(file_json Write "$main" "$wt/docs/x.md")" | env CLAUDE_PROJECT_DIR="$main" "$bash_bin" "$crash/main-checkout-guard.sh" 2>/dev/null); got=$?
if [ "$got" -eq 2 ] && case "$out" in *'"permissionDecision":"deny"'*) true ;; *) false ;; esac; then
  echo '✓ F5 wrapper 中途未捕捉錯誤（注入 exit 1）仍 deny（trap 生效）'
else
  echo "✗ F5 trap 應把中途錯誤轉成 deny（實得 exit ${got}：${out}）" >&2; fail=1
fi

# ============================================================
# mutation：拿掉 git-dir==common-dir 判斷 → 負樣本必須變綠（證明該判斷是關鍵）
# ============================================================
mut=$(mktemp -d "$fx/mut.XXXXXX")
cp "$guard" "$engine_py" "$mut/"
anchor='return git_dir == common_dir'
if ! grep -q "$anchor" "$guard_py"; then
  echo "✗ M0 mutation 錨點「${anchor}」不在 main_checkout_guard.py，mutation 測試無法成立" >&2
  fail=1
else
  sed "s/$anchor/return False/" "$guard_py" > "$mut/main_checkout_guard.py"
  out=$(printf '%s' "$(file_json Write "$main" "$main/LS-1-probe.txt")" | env CLAUDE_PROJECT_DIR="$main" "$bash_bin" "$mut/main-checkout-guard.sh" 2>/dev/null); got=$?
  if [ "$got" -eq 0 ] && [ -z "$out" ]; then
    echo '✓ M1 拿掉 git-dir==common-dir 判斷後主 checkout Write 變成放行（原版 N1 deny 確由該判斷造成）'
  else
    echo "✗ M1 mutant 應放行主 checkout Write（實得 exit ${got}：${out}）——判斷不是靠錨點行？" >&2; fail=1
  fi
  out=$(printf '%s' "$(bash_json "$fx/scratch" "echo hi | tee $main/x")" | env CLAUDE_PROJECT_DIR="$main" "$bash_bin" "$mut/main-checkout-guard.sh" 2>/dev/null); got=$?
  if [ "$got" -eq 0 ]; then
    echo '✓ M2 mutant 對 Bash tee 主 checkout 同樣放行（W2 也走同一個判斷）'
  else
    echo "✗ M2 mutant 應放行 tee 主 checkout（實得 exit ${got}：${out}）" >&2; fail=1
  fi
fi

# R2 M3：拿掉呼叫 git 前的環境剝除（env=_clean_env() → env=None）→ GIT_DIR 下 worktree Write 必須變紅
# （證明 G1 綠是靠剝除、不是巧合）
mut3=$(mktemp -d "$fx/mut3.XXXXXX")
cp "$guard" "$engine_py" "$mut3/"
anchor3='env=_clean_env(),'
if ! grep -q "$anchor3" "$guard_py"; then
  echo "✗ M3 mutation 錨點「${anchor3}」不在 main_checkout_guard.py，mutation 測試無法成立" >&2
  fail=1
else
  sed "s/$anchor3/env=None,/" "$guard_py" > "$mut3/main_checkout_guard.py"
  out=$(printf '%s' "$(file_json Write "$main" "$wt/docs/x.md")" | env CLAUDE_PROJECT_DIR="$main" GIT_DIR="$main/.git" "$bash_bin" "$mut3/main-checkout-guard.sh" 2>/dev/null); got=$?
  if [ "$got" -eq 2 ]; then
    echo '✓ M3 拿掉 GIT_* 剝除後 GIT_DIR 下 worktree Write 變成 deny（G1 綠確由剝除造成）'
  else
    echo "✗ M3 mutant 應把 GIT_DIR 下 worktree Write 判成主 checkout（實得 exit ${got}：${out}）" >&2; fail=1
  fi
fi

# LS-157 M4：把 startswith("GIT_") 換回五個具名（R2 前的實作）→ GIT_OBJECT_DIRECTORY 下 worktree Write 必須變紅
# （G5 綠確由全剝造成）；同環境主 checkout Write 仍 deny、但理由退成 W0（只剩安全網在擋，不再是 W1 正常判定——
# 兩個修法在這個樣本上重疊，所以「負樣本變綠」不成立，改驗理由退化）
mut4=$(mktemp -d "$fx/mut4.XXXXXX")
cp "$guard" "$engine_py" "$mut4/"
anchor4='if not k.startswith("GIT_")'
if ! grep -q "$anchor4" "$guard_py"; then
  echo "✗ M4 mutation 錨點「${anchor4}」不在 main_checkout_guard.py，mutation 測試無法成立" >&2
  fail=1
else
  sed "s|$anchor4|if k not in (\"GIT_DIR\", \"GIT_WORK_TREE\", \"GIT_INDEX_FILE\", \"GIT_PREFIX\", \"GIT_COMMON_DIR\")|" "$guard_py" > "$mut4/main_checkout_guard.py"
  out=$(printf '%s' "$(file_json Write "$main" "$wt/docs/x.md")" | env CLAUDE_PROJECT_DIR="$main" GIT_OBJECT_DIRECTORY=/nonexist "$bash_bin" "$mut4/main-checkout-guard.sh" 2>/dev/null); got=$?
  if [ "$got" -eq 2 ]; then
    echo '✓ M4a 只剝五個具名後 GIT_OBJECT_DIRECTORY 下 worktree Write 變成 deny（G5 綠確由全剝造成）'
  else
    echo "✗ M4a mutant 應讓 GIT_OBJECT_DIRECTORY 下 worktree Write 變紅（實得 exit ${got}：${out}）" >&2; fail=1
  fi
  printf '%s' "$(file_json Write "$main" "$main/LS-1-probe.txt")" | env CLAUDE_PROJECT_DIR="$main" GIT_OBJECT_DIRECTORY=/nonexist "$bash_bin" "$mut4/main-checkout-guard.sh" >/dev/null 2>"$fx/stderr"; got=$?
  case "${got}:$(cat "$fx/stderr")" in
    2:*'W0：'*) echo '✓ M4b mutant 對主 checkout Write 的 deny 退成 W0（安全網接住 R2 N1 那條無聲 fail-open）' ;;
    *) echo "✗ M4b mutant 對主 checkout Write 應 W0 deny（實得 exit ${got}：$(cat "$fx/stderr")）" >&2; fail=1 ;;
  esac
fi

# LS-157 M5：拿掉安全網 raise → 壞 .git 根下的 Write 變成放行（X1 紅確由安全網造成，不是 rev-parse 其他失敗路徑）
mut5=$(mktemp -d "$fx/mut5.XXXXXX")
cp "$guard" "$engine_py" "$mut5/"
anchor5='raise GuardError(_under_root_msg(path, r.stderr))'
if ! grep -q "$anchor5" "$guard_py"; then
  echo "✗ M5 mutation 錨點「${anchor5}」不在 main_checkout_guard.py，mutation 測試無法成立" >&2
  fail=1
else
  sed "s|$anchor5|pass|" "$guard_py" > "$mut5/main_checkout_guard.py"
  out=$(printf '%s' "$(file_json Write "$fx/broken" "$fx/broken/x.txt")" | env CLAUDE_PROJECT_DIR="$fx/broken" "$bash_bin" "$mut5/main-checkout-guard.sh" 2>/dev/null); got=$?
  if [ "$got" -eq 0 ] && [ -z "$out" ]; then
    echo '✓ M5 拿掉安全網後壞 .git 根下的 Write 變成放行（X1 deny 確由安全網造成）'
  else
    echo "✗ M5 mutant 應放行壞 .git 根下的 Write（實得 exit ${got}：${out}）" >&2; fail=1
  fi
fi

# ============================================================
# T1：hook 跑完不得在 hooks 目錄留 __pycache__（hook 跑在主 checkout那份，留了就把主 checkout 弄 dirty）
# ============================================================
pc=$(mktemp -d "$fx/pc.XXXXXX")
cp "$guard" "$guard_py" "$engine_py" "$pc/"
printf '%s' "$(bash_json "$main" "git status")" | env CLAUDE_PROJECT_DIR="$main" "$bash_bin" "$pc/main-checkout-guard.sh" >/dev/null 2>&1
if [ -d "$pc/__pycache__" ]; then
  echo "✗ T1 hook 執行後在 hooks 目錄留下 __pycache__/（主 checkout 會因此 dirty）" >&2; fail=1
else
  echo '✓ T1 hook 執行後 hooks 目錄無 __pycache__（sys.dont_write_bytecode）'
fi

# ============================================================
# settings.json 接線（同 pretool.test.sh I6）：matcher 含五個工具、command 呼叫本 hook、帶 || exit 2
# ============================================================
settings_json="${root}/.claude/settings.json"
w_cmd=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash|Write|Edit|MultiEdit|NotebookEdit") | .hooks[] | select(.type == "command") | .command' "$settings_json" 2>/dev/null)
if [ -n "$w_cmd" ]; then
  echo '✓ R1 settings.json 的 PreToolUse 有 matcher=Bash|Write|Edit|MultiEdit|NotebookEdit 的 command'
else
  echo "✗ R1 settings.json 找不到 matcher=Bash|Write|Edit|MultiEdit|NotebookEdit 的 PreToolUse command" >&2; fail=1
fi
case "$w_cmd" in
  *main-checkout-guard.sh*) echo '✓ R2 command 呼叫 main-checkout-guard.sh' ;;
  *) echo "✗ R2 command 沒有呼叫 main-checkout-guard.sh（實得：${w_cmd}）" >&2; fail=1 ;;
esac
case "$w_cmd" in
  *'|| exit 2'*) echo '✓ R3 command 帶 || exit 2（wiring 層 fail-closed）' ;;
  *) echo "✗ R3 command 沒有 || exit 2（實得：${w_cmd}）" >&2; fail=1 ;;
esac

if [ "$fail" -eq 0 ]; then
  echo "✓ main-checkout-guard.sh 自測通過"
fi
exit "$fail"
