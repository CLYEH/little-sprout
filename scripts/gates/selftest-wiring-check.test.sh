#!/bin/bash
# selftest-wiring-check.sh 的自測（LS-267）。CI `rules` job 跑。
# 夾具 repo root（三支假自測）＋四份夾具 ci.yml 驗正負樣本、allowlist 與「註解提及不算掛」；
# 另對**真的** `.github/workflows/ci.yml` 驗差集為空，並用 mutation（拿掉真 ci.yml 的一行呼叫）
# 證明這支 gate 真的看得見那個差集——正是 LS-264 M1 的事故形狀（`qa-e2e.test.sh` 躺在 repo 裡沒被跑）。
# 「前饋必有反饋」對這支腳本本身也適用：判準退化（雙向差集、註解排除、allowlist、參數 fail closed）這裡會紅。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/scripts/gates/selftest-wiring-check.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ---- 夾具 repo root：三支假自測（兩支 .test.sh、一支 .test.js）----
fix="${work}/fixrepo"
mkdir -p "${fix}/scripts/gates" "${fix}/scripts/design"
: > "${fix}/scripts/gates/a.test.sh"
: > "${fix}/scripts/gates/b.test.sh"
: > "${fix}/scripts/design/x.test.js"
# 干擾項：不是自測的腳本不該被列入
: > "${fix}/scripts/gates/a.sh"

cat > "${work}/ci-ok.yml" <<'YML'
      - name: Gate 自測
        run: |
          rc=0
          bash scripts/gates/a.test.sh || rc=1
          bash scripts/gates/b.test.sh || rc=1
          node scripts/design/x.test.js || rc=1
          exit "$rc"
YML

cat > "${work}/ci-missing.yml" <<'YML'
      - name: Gate 自測
        run: |
          rc=0
          bash scripts/gates/a.test.sh || rc=1
          node scripts/design/x.test.js || rc=1
          exit "$rc"
YML

cat > "${work}/ci-extra.yml" <<'YML'
      - name: Gate 自測
        run: |
          rc=0
          bash scripts/gates/a.test.sh || rc=1
          bash scripts/gates/b.test.sh || rc=1
          bash scripts/gates/ghost.test.sh || rc=1
          node scripts/design/x.test.js || rc=1
          exit "$rc"
YML

# 註解裡提到 b.test.sh（ci.yml 的說明註解常這樣寫），但沒有任何一行會執行它
cat > "${work}/ci-comment.yml" <<'YML'
      - name: Gate 自測
        run: |
          rc=0
          bash scripts/gates/a.test.sh || rc=1
          # 這段沿用 scripts/gates/b.test.sh 的判準（只是提到，沒有真的跑）
          node scripts/design/x.test.js || rc=1
          exit "$rc"
YML

run_fix() { bash "$check" --repo-root "$fix" --ci "$1" 2>&1; }

expect_rc() { # <名稱> <期望 rc> <實得 rc> <輸出>
  if [ "$2" = "$3" ]; then echo "✓ $1"; else echo "✗ ${1}（期望 exit ${2}，實得 ${3}）" >&2; printf '%s\n' "$4" | sed 's/^/    /' >&2; fail=1; fi
}
has() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "✓ $1"; else echo "✗ ${1}（輸出應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; fi; }

# ---- ① 夾具一致 → exit 0 ----
out=$(run_fix "${work}/ci-ok.yml"); rc=$?
expect_rc '① 夾具清單一致 → exit 0' 0 "$rc" "$out"
has '① 印出支數（3 支，不含非自測的 a.sh）' "$out" '3 支自測全部掛在 ci.yml'

# ---- ② ci.yml 少一支 → exit 1 並點名（票文驗收的 mutation 形狀，夾具版）----
out=$(run_fix "${work}/ci-missing.yml"); rc=$?
expect_rc '② ci.yml 少一支 → exit 1' 1 "$rc" "$out"
has '② 點名缺的那一支' "$out" 'scripts/gates/b.test.sh'
has '② 說明是哪個方向的差集' "$out" '存在於 repo，但 ci.yml 沒有任何一行會執行它'
has '② 指出 allowlist 逃生口' "$out" 'selftest-wiring-allowlist.txt'

# ---- ③ ci.yml 列了 repo 沒有的檔 → exit 1（反方向差集）----
out=$(run_fix "${work}/ci-extra.yml"); rc=$?
expect_rc '③ ci.yml 有、repo 沒有 → exit 1' 1 "$rc" "$out"
has '③ 點名多出來的那一支' "$out" 'scripts/gates/ghost.test.sh'
has '③ 說明是哪個方向的差集' "$out" 'repo 裡沒有這個檔'

# ---- ④ allowlist 具名豁免 → ② 的樣本轉綠；allowlist 只放行它列的那一支 ----
printf '# 理由：本支刻意不在 CI 跑（測試用）\nscripts/gates/b.test.sh\n' > "${fix}/scripts/gates/selftest-wiring-allowlist.txt"
out=$(run_fix "${work}/ci-missing.yml"); rc=$?
expect_rc '④ allowlist 具名豁免 → exit 0' 0 "$rc" "$out"
has '④ 印出 allowlist 支數' "$out" 'allowlist 1 支'
out=$(run_fix "${work}/ci-extra.yml"); rc=$?
expect_rc '④ allowlist 不放行反方向差集（ci.yml 有、repo 沒有仍紅）' 1 "$rc" "$out"
rm -f "${fix}/scripts/gates/selftest-wiring-allowlist.txt"

# ---- ⑤ 註解提及不算「有在跑」（假綠防線）----
out=$(run_fix "${work}/ci-comment.yml"); rc=$?
expect_rc '⑤ 只在註解被提到 → 仍算沒掛，exit 1' 1 "$rc" "$out"
has '⑤ 點名 b.test.sh' "$out" 'scripts/gates/b.test.sh'

# ---- ⑥ mutant：拿掉「只認呼叫行」的限制（退回整檔 grep）→ ⑤ 的紅樣本轉綠 ----
mut="${work}/mut-comment.sh"
sed 's|^grep -hE .*|cat "$ci" \\|' "$check" > "$mut"
grep -q '^cat "\$ci" \\$' "$mut" || { echo "✗ ⑥ mutant 沒被正確合成（selftest-wiring-check.sh 的 grep 行形狀變了）" >&2; fail=1; }
out=$(bash "$mut" --repo-root "$fix" --ci "${work}/ci-comment.yml" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  echo "✓ ⑥ mutant（退回整檔 grep）：⑤ 的紅樣本轉綠——證明「只認呼叫行」這條判準確實是 ⑤ 紅的原因"
else
  echo "✗ ⑥ mutant 未如預期翻轉（實得 exit ${rc}）——⑤ 的紅可能來自別的原因，註解排除等於零覆蓋" >&2
  printf '%s\n' "$out" | sed 's/^/    /' >&2; fail=1
fi

# ---- ⑦ 真 repo：差集為空（票文驗收條件）----
out=$(bash "$check" 2>&1); rc=$?
expect_rc '⑦ 真 repo 差集為空 → exit 0' 0 "$rc" "$out"

# ---- ⑧ mutation：從真 ci.yml 拿掉一行呼叫（LS-264 M1 的事故形狀）→ 該支被點名、exit 1 ----
real_ci="${root}/.github/workflows/ci.yml"
grep -v '^[[:space:]]*bash scripts/ops/qa-e2e.test.sh' "$real_ci" > "${work}/ci-real-mut.yml"
out=$(bash "$check" --ci "${work}/ci-real-mut.yml" 2>&1); rc=$?
expect_rc '⑧ 真 ci.yml 拿掉 qa-e2e.test.sh 那一行 → exit 1' 1 "$rc" "$out"
has '⑧ 點名 qa-e2e.test.sh' "$out" 'scripts/ops/qa-e2e.test.sh'

# ---- ⑨ 參數／環境 fail closed ----
out=$(bash "$check" --ci "${work}/does-not-exist.yml" 2>&1); rc=$?
expect_rc '⑨ --ci 指向不存在的檔 → exit 2' 2 "$rc" "$out"
has '⑨ 說明找不到 ci.yml' "$out" '找不到 ci.yml'
out=$(bash "$check" --repo-root "${work}/nope" 2>&1); rc=$?
expect_rc '⑨ --repo-root 不是目錄 → exit 2' 2 "$rc" "$out"
out=$(bash "$check" --wat 2>&1); rc=$?
expect_rc '⑨ 未知參數 → exit 2' 2 "$rc" "$out"

if [ "$fail" -eq 0 ]; then
  echo "✓ selftest-wiring-check 自測通過（9 組樣本）"
fi
exit "$fail"
