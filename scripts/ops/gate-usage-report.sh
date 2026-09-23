#!/bin/bash
# gate-usage-report.sh — LS-351 範圍 2：gate 30 天攔截盤點（退役候選表）。只讀、不刪任何 gate。
#
# 背景（09-23 流程覆盤）：scripts/gates 95 支、scripts/ops 54 支、hook 17 支，已出現 gate 的 gate
# （LS-292／294／295／301）。§7 退役條件：30 天零攔截且無同型事故——本腳本只算前半（攔截次數），
# 「無同型事故」與最終退役名單由使用者裁決後另票刪除。
#
# 對象：scripts/gates/*.sh 與 scripts/hooks/*.sh（皆排除 *.test.sh）。
# 攔截次數兩個來源（輸出表「來源」欄標明）：
#   CI  ：`gh run list --created ">=<N 天前>" --status failure`（上限 --max-runs）逐支 `gh run view --log-failed`，
#         只看帶時間戳、非 step 腳本回顯（無 ESC[36;1m）、非自測 step（step 名含「自測」——自測紅是 gate 本身壞了、
#         不是攔截）、且含 ✗ 或 ::error 的行；行內出現 gate 名（檔名去 .sh）
#         即該 run 記該 gate 1 次（同 run 同 gate 不重複計）。紅行認不出 gate 名者彙整成「未歸屬」列（job／step ×次數），
#         不歸給任何 gate——寧可讓人看見、不猜。
#   git log 近似：本機 hook（pre-commit／pre-push／PreToolUse）沒有攔截 log，退而以 `git log --all --since=<N>.days`
#         的 commit 訊息近似：同一行同時出現 gate 名與「攔／擋／紅／deny／block」字樣，且該 commit 沒有改動該 gate
#         檔本身（gate 自己的開發 commit 不算攔截）。這是下限近似——本機被擋後改好再 commit 的多半不會留字。
# 退役候選＝兩個來源合計 0 次（Y）；gh 不可用時 CI 段略過，表頭與輸出末尾註明，候選僅供參考。
#
# 用法：gate-usage-report.sh [--days N] [--repo <path>] [--no-ci] [--max-runs N]
#   --days N      統計天數（預設 30）
#   --repo <path> repo 根（預設本檔所在 repo）
#   --no-ci       不打 gh（只用 git log 近似）
#   --max-runs N  最多讀幾支失敗 run 的 log（預設 200；超過時輸出註明截斷）
# 輸出：markdown 表（gate｜N 天攔截次數｜來源｜退役候選 Y/N）＋未歸屬列＋註記。exit 0＝完成；2＝參數／環境錯誤。
# 自測 scripts/ops/gate-usage-report.test.sh（PATH stub gh，合成 repo）。
set -uo pipefail

days=30; repo=; no_ci=0; max_runs=200
while [ $# -gt 0 ]; do
  case "$1" in
    --days) days=${2:-}; shift 2 ;;
    --repo) repo=${2:-}; shift 2 ;;
    --no-ci) no_ci=1; shift ;;
    --max-runs) max_runs=${2:-}; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "✗ gate-usage-report：未知參數 $1" >&2; exit 2 ;;
  esac
done
case "$days" in ''|*[!0-9]*) echo "✗ gate-usage-report：--days 需為正整數" >&2; exit 2 ;; esac
case "$max_runs" in ''|*[!0-9]*) echo "✗ gate-usage-report：--max-runs 需為正整數" >&2; exit 2 ;; esac
[ -n "$repo" ] || repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "✗ gate-usage-report：${repo} 不是 git repo" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "✗ gate-usage-report：需要 python3" >&2; exit 2; }

GATE_REPO="$repo" GATE_DAYS="$days" GATE_NO_CI="$no_ci" GATE_MAX_RUNS="$max_runs" python3 - <<'PY'
import datetime, glob, json, os, re, shutil, subprocess, sys

repo = os.environ["GATE_REPO"]
days = int(os.environ["GATE_DAYS"])
no_ci = os.environ["GATE_NO_CI"] == "1"
max_runs = int(os.environ["GATE_MAX_RUNS"])

paths = []
for pat in ("scripts/gates/*.sh", "scripts/hooks/*.sh"):
    paths += sorted(p for p in glob.glob(os.path.join(repo, pat)) if not p.endswith(".test.sh"))
gates = [(os.path.relpath(p, repo), os.path.basename(p)[:-3]) for p in paths]
# 名稱比對用整字邊界（前後不是英數／-／_），避免 `push-gate` 命中 `push-gate-x`、`pretool` 命中 `pretool_engine`
def name_re(name):
    return re.compile(r"(?<![A-Za-z0-9_-])%s(?![A-Za-z0-9_-])" % re.escape(name))
gate_res = {name: name_re(name) for _, name in gates}

# ---- git log 近似 ----
KEYWORD_RE = re.compile(r"攔|擋|紅|deny|block", re.I)
git_counts = {name: 0 for _, name in gates}
res = subprocess.run(
    ["git", "-C", repo, "log", "--all", "--since=%d.days" % days, "--no-merges",
     "--format=%x1e%H%x1f%B%x1f", "--name-only"],
    capture_output=True, text=True)
if res.returncode != 0:
    sys.stderr.write("✗ gate-usage-report：git log 失敗：%s\n" % res.stderr.strip()[:300])
    sys.exit(2)
for rec in res.stdout.split("\x1e"):
    parts = rec.split("\x1f")
    if len(parts) < 3:
        continue
    msg, files = parts[1], set(f.strip() for f in parts[2].splitlines() if f.strip())
    lines = [l for l in msg.splitlines() if KEYWORD_RE.search(l)]
    if not lines:
        continue
    for path, name in gates:
        if path in files:
            continue  # gate 自己的開發 commit 不算攔截
        if any(gate_res[name].search(l) for l in lines):
            git_counts[name] += 1

# ---- CI ----
ci_counts = {name: 0 for _, name in gates}
unattributed = {}
ci_note = None
if no_ci:
    ci_note = "CI 段略過（--no-ci）"
elif not shutil.which("gh"):
    ci_note = "CI 段略過（找不到 gh）"
else:
    since = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)).strftime("%Y-%m-%d")
    lr = subprocess.run(
        ["gh", "run", "list", "--limit", "1000", "--created", ">=%s" % since, "--status", "failure",
         "--json", "databaseId"], capture_output=True, text=True, cwd=repo)
    try:
        run_ids = [r["databaseId"] for r in json.loads(lr.stdout)] if lr.returncode == 0 else None
    except ValueError:
        run_ids = None
    if run_ids is None:
        ci_note = "CI 段略過（gh run list 失敗：%s）" % (lr.stderr.strip()[:120] or "無訊息")
    else:
        scanned = run_ids[:max_runs]
        failed_views = 0
        # 帶時間戳的行：`<job>\t<step>\t<ISO 時間戳> <內容>`；step 腳本回顯帶 ESC[36;1m（或其字面 ^[[36;1m）
        LINE_RE = re.compile(r"^([^\t]*)\t([^\t]*)\t\d{4}-\d\d-\d\dT[\d:.]+Z (.*)$")
        for rid in scanned:
            vr = subprocess.run(["gh", "run", "view", str(rid), "--log-failed"],
                                capture_output=True, text=True, cwd=repo)
            if vr.returncode != 0:
                failed_views += 1
                continue
            hit = set()
            unhit_steps = set()
            for raw in vr.stdout.splitlines():
                m = LINE_RE.match(raw)
                if not m:
                    continue
                job, step, content = m.groups()
                if "[36;1m" in content or "自測" in step:
                    continue  # step 腳本回顯；自測 step 紅是 gate 自己壞了，不是攔截
                if "✗" not in content and "::error" not in content:
                    continue
                names = [n for n in gate_res if gate_res[n].search(content)]
                if names:
                    hit.update(names)
                else:
                    unhit_steps.add("%s／%s" % (job, step))
            for n in hit:
                ci_counts[n] += 1
            if not hit:
                for s in unhit_steps:
                    unattributed[s] = unattributed.get(s, 0) + 1
        ci_note = "CI：%d 天內失敗 run %d 支，讀 log %d 支" % (days, len(run_ids), len(scanned) - failed_views)
        if len(run_ids) > len(scanned):
            ci_note += "（--max-runs %d 截斷，其餘 %d 支未讀）" % (max_runs, len(run_ids) - len(scanned))
        if failed_views:
            ci_note += "（%d 支 gh run view 失敗）" % failed_views

print("| gate | %d 天攔截次數 | 來源 | 退役候選 |" % days)
print("|---|---|---|---|")
candidates = 0
for path, name in gates:
    c, g = ci_counts[name], git_counts[name]
    srcs = []
    if c:
        srcs.append("CI %d" % c)
    if g:
        srcs.append("git log 近似 %d" % g)
    if not srcs:
        srcs.append("—（CI＋git log 近似皆 0）" if not ci_note or ci_note.startswith("CI：") else "—（僅 git log 近似）")
    total = c + g
    cand = "Y" if total == 0 else "N"
    candidates += total == 0
    print("| `%s` | %d | %s | %s |" % (path, total, "、".join(srcs), cand))
print()
if unattributed:
    print("未歸屬的紅 step（✗／::error 行未出現任何 gate 名；不計入上表）：")
    for s, n in sorted(unattributed.items(), key=lambda kv: -kv[1]):
        print("- %s ×%d" % (s, n))
    print()
print("註：%s；git log 近似＝commit 訊息同行含 gate 名＋攔／擋／紅／deny／block 且未改動該 gate 檔。" % ci_note)
print("退役候選 %d／%d 支——僅統計前半條件（%d 天零攔截），「無同型事故」與最終名單由使用者裁決後另票刪除（§7）。" % (candidates, len(gates), days))
PY
