#!/bin/bash
# ci-head-sha-check.sh 的自測（LS-318，來源 LS-127／LS-316 同型再犯）。CI rules job「Gate 腳本自測」step 跑，
# 也掛進 selftest-wiring-check.sh。
#
# 守三件事：
#   (1) 合成 ci.yml：呼叫清單命中的 step 必帶 env HEAD_SHA＋呼叫行帶 --head-sha 才綠；缺任一即紅並點名
#       step／腳本／行號；不在呼叫清單裡的呼叫不擋；註解裡提到呼叫清單腳本名不算命中（同
#       selftest-wiring-check.sh 既有慣例——現行 ci.yml「分支起點乾淨度」step 之後的說明註解就提到
#       `pr-body-check.sh`，是下一個 step 才真的呼叫，若不排除註解會把前一個 step 也誤判成命中）；
#       白名單放行「命中但不需要 head-sha」的 step。
#   (2) 對真實 .github/workflows/ci.yml 跑基準（必須綠）＋mutation（拿掉一處 --head-sha → 紅）。
#   (3) 參數 fail closed。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/scripts/gates/ci-head-sha-check.sh"
real_ci="${root}/.github/workflows/ci.yml"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# LS-301：先 source 共用助手庫（本檔沿 patrol.test.sh／patrol-filter.test.sh 既有的 3 參數
# `has <名稱> <haystack> <needle>` 慣例另包一層，簽章跟庫的 2 參數 `has <haystack> <needle>` 不同，
# 下面用同名 has() 覆寫——底層都是 SIGPIPE-safe 的 here-string `grep -qF`，行為等價）。
source "${root}/scripts/gates/lib/selftest-helpers.sh"
has()   { if grep -qF -- "$3" <<<"$2"; then echo "✓ $1"; else echo "✗ ${1}（輸出應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then echo "✗ ${1}（輸出不應含「${3}」）" >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fail=1; else echo "✓ $1"; fi; }
rc_is() { if [ "$3" -eq "$2" ]; then echo "✓ $1"; else echo "✗ ${1}（期望 exit ${2}，實得 ${3}）" >&2; printf '%s\n' "$4" | sed 's/^/    /' >&2; fail=1; fi; }

# ---- ① 基準：真實 ci.yml 必須綠（LS-127 後三支 .pen gate＋LS-316 兩處新接線皆已帶 head-sha）----
out1="$(bash "$check" --repo-root "$root" 2>&1)"; rc1=$?
rc_is '① 真實 ci.yml 基準 exit 0' 0 "$rc1" "$out1"
has   '① 真實 ci.yml：命中呼叫清單的 5 個 step 都已接好' "$out1" '5 個 step 命中呼叫清單'

# ---- ② mutation：真實 ci.yml 拿掉「Design gate」step 呼叫 design-ref-check.sh 那行的 --head-sha → 紅 ----
lineno2=$(grep -n 'bash scripts/gates/design-ref-check.sh .*--head-sha' "$real_ci" | head -1 | cut -d: -f1)
if [ -z "$lineno2" ]; then
  echo "✗ ② 在真實 ci.yml 找不到 design-ref-check.sh 的呼叫行（腳本形狀變了？）" >&2; fail=1
else
  mut2="$work/ci-mut2.yml"
  sed "${lineno2}s/ --head-sha \"\$HEAD_SHA\"//" "$real_ci" > "$mut2"
  if grep -qF -- '--head-sha "$HEAD_SHA"' <(sed -n "${lineno2}p" "$mut2"); then
    echo "✗ ② mutant 沒被正確合成（第 ${lineno2} 行仍帶 --head-sha）" >&2; fail=1
  else
    out2="$(bash "$check" --ci "$mut2" 2>&1)"; rc2=$?
    rc_is '② mutant（拿掉 design-ref-check.sh 呼叫行的 --head-sha）→ exit 1' 1 "$rc2" "$out2"
    has '② mutant 訊息點名 design-ref-check.sh 缺 --head-sha' "$out2" '沒有帶 --head-sha'
  fi
fi

# ---- 合成 ci.yml 夾具（③–⑦）：indent 與真實檔一致（6 空白起 `- name:`），單一 rules job ----
ci_fixture() {
  cat > "$work/ci-fixture.yml" <<'YAML'
name: CI
on: [pull_request]
jobs:
  rules:
    runs-on: ubuntu-latest
    steps:
      - name: 不相關 step（前一步，本身不呼叫任何 gate）
        run: echo hi

      # 這段註解只是提到 scripts/gates/design-notes-check.sh 的名字（描述下一個 step 要幹什麼），
      # 不是「不相關 step（前一步）」自己呼叫了它——註解不算命中（回歸真實 ci.yml 的「分支起點
      # 乾淨度」步在 pr-body-check.sh 那支 step 之前的說明段落）
      - name: 接線正確
        env:
          HEAD_SHA: ${{ github.event.pull_request.head.sha }}
        run: |
          bash scripts/gates/design-notes-check.sh design/littlesprout.pen --base origin/main --head-sha "$HEAD_SHA"

      - name: 缺 env HEAD_SHA
        run: |
          bash scripts/gates/design-ref-check.sh body.txt design/littlesprout.pen --head-sha "$HEAD_SHA"

      - name: 缺呼叫行的 head-sha
        env:
          HEAD_SHA: ${{ github.event.pull_request.head.sha }}
        run: |
          bash scripts/gates/design-evidence-check.sh design/littlesprout.pen --ticket LS-1

      - name: 不在呼叫清單裡的呼叫（branch-ticket-check.sh）
        run: |
          bash scripts/gates/branch-ticket-check.sh --branch foo

      - name: 白名單放行
        run: |
          bash scripts/gates/design-identity-header-check.sh design/littlesprout.pen --base origin/main
YAML
  printf '%s' "$work/ci-fixture.yml"
}
fixture="$(ci_fixture)"

# ---- ③ 接線正確的 step → 不進違規清單（用 hasnt 排除該 step 名稱出現在 ✗ 行）----
out3="$(bash "$check" --ci "$fixture" 2>&1)"; rc3=$?
rc_is '③ 夾具（無白名單）exit 1（缺 env／缺呼叫行 head-sha 各一個 step）' 1 "$rc3" "$out3"
hasnt '③「接線正確」不在違規清單裡' "$(printf '%s\n' "$out3" | grep '✗')" '接線正確'

# ---- ④ 缺 env HEAD_SHA → 紅，點名該 step 與呼叫清單腳本 ----
has '④「缺 env HEAD_SHA」被點名缺 env' "$out3" 'step「缺 env HEAD_SHA」命中呼叫清單'
has '④ 訊息帶出缺的 env 字面' "$out3" 'env 缺 HEAD_SHA: ${{ github.event.pull_request.head.sha }}'

# ---- ⑤ env 有給但呼叫行缺 --head-sha → 紅，點名該 step、腳本與行號 ----
lineno5=$(grep -n 'scripts/gates/design-evidence-check.sh' "$fixture" | head -1 | cut -d: -f1)
has '⑤「缺呼叫行的 head-sha」被點名缺 --head-sha 且帶行號' "$out3" "step「缺呼叫行的 head-sha」呼叫 design-evidence-check.sh（第 ${lineno5} 行）沒有帶 --head-sha"

# ---- ⑥ 不在呼叫清單裡的呼叫（branch-ticket-check.sh）不被擋，即使沒有 head-sha ----
hasnt '⑥「不在呼叫清單裡的呼叫」不進違規清單（branch-ticket-check.sh 不在呼叫清單）' "$(printf '%s\n' "$out3" | grep '✗')" '不在呼叫清單裡的呼叫'

# ---- ⑦ 白名單機制：改一份 ci-head-sha-check.sh 副本，把檔頭 WHITELIST 那行填「白名單放行」（票文格式：
#      「<step 名稱>|<理由>」）→ 該 step 不再是違規（雖然它命中 design-identity-header-check.sh 且沒接
#      head-sha），但另兩個缺失 step 仍紅——證明白名單只放行指名的那一個，不是整段判定失效 ----
# 兩支 mutant 副本都跟 ci-head-sha-check.sh 放同一個目錄（$work）——wrapper 用
# `$(dirname "${BASH_SOURCE[0]}")` 找旁邊的 ci_head_sha_check.py，複本搬去別的目錄就得帶著它走。
cp "${root}/scripts/gates/ci_head_sha_check.py" "$work/ci_head_sha_check.py"
mut_wl7="$work/ci-head-sha-check-wl7.sh"
sed 's/^WHITELIST=""$/WHITELIST="白名單放行|LS-318 自測：故意示範白名單格式"/' "$check" > "$mut_wl7"
if ! grep -q '白名單放行|LS-318 自測' "$mut_wl7"; then
  echo "✗ ⑦ mutant 沒被正確合成（檔頭 WHITELIST 那行形狀變了？）" >&2; fail=1
else
  out7="$(bash "$mut_wl7" --ci "$fixture" 2>&1)"; rc7=$?
  rc_is '⑦ 白名單放行「白名單放行」後：其餘兩個缺失仍紅（exit 1）' 1 "$rc7" "$out7"
  has   '⑦ 摘要含「白名單 1 個」' "$out7" '白名單 1 個'
  hasnt '⑦「白名單放行」不再出現在違規清單' "$(printf '%s\n' "$out7" | grep '✗')" '白名單放行'
  has   '⑦「缺 env HEAD_SHA」仍在違規清單（白名單只放行指名的那個 step）' "$out7" 'step「缺 env HEAD_SHA」'
fi

# ---- ⑧ 把 ③ 命中的三個 step 全部白名單掉 → exit 0 ----
mut_wl8="$work/ci-head-sha-check-wl8.sh"
sed 's/^WHITELIST=""$/WHITELIST="缺 env HEAD_SHA|自測;缺呼叫行的 head-sha|自測;白名單放行|自測"/' "$check" > "$mut_wl8"
out8="$(bash "$mut_wl8" --ci "$fixture" 2>&1)"; rc8=$?
rc_is '⑧ 三個命中的 step 都白名單掉 → exit 0' 0 "$rc8" "$out8"
has   '⑧ 摘要含「白名單 3 個」' "$out8" '白名單 3 個'

# ---- ⑨ 參數 fail closed ----
bad() { local name=$1; shift; local out; out="$(bash "$check" "$@" 2>&1)"; rc_is "$name" 2 "$?" "$out"; }
bad '⑨ 未知參數 → exit 2' --bogus
bad '⑨ --ci 指到不存在的檔 → exit 2' --ci "$work/沒有這個檔.yml"
bad '⑨ --repo-root 不是目錄 → exit 2' --repo-root "$work/沒有這個目錄"

if [ "$fail" -eq 0 ]; then
  echo "ci-head-sha-check.test.sh：全數通過"
else
  echo "ci-head-sha-check.test.sh：有樣本失敗" >&2
fi
exit "$fail"
