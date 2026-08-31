#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""scripts/ops/patrol_linear.py（LS-103）

patrol-linear.sh 的實際邏輯：用 curl 打 Linear GraphQL（team LS）取 open issues 與 cycles，
把巡檢的 Linear 半段機械化——狀態對照（對照本機 git）、cycle 對帳 (a)-(d)、lane 補位候補與
「→ 」動作清單、開票結構 (a)-(e)。分工同 scripts/gates/api_contract_check.py：bash 檔只管環境
（.env、curl／python3 是否存在、呼叫 patrol.sh 取 Booted 模擬器段），查詢與排序邏輯都在這裡。

只讀（GraphQL query，不呼叫任何 mutation）；HTTP 一律透過 `curl` 子行程送出——不用
urllib，是為了讓自測用 PATH 上的假 curl 攔截、餵固定 fixture（同 post-status.test.sh 的
stub gh 慣例），不必真的打 Linear。

用法：patrol_linear.py --root <repo 根> --team-key LS --team-id <uuid> --mode human|brief|json
      [--sim-lines-file <path>]（每行一條「[Booted 模擬器 …] …」，來自 patrol.sh --brief 的輸出）
環境：LINEAR_API_KEY 必須已 export（patrol-linear.sh 已檢查非空才會呼叫這支）。
exit 0＝查詢與輸出皆完成（有無異常都 0，異常在輸出裡）；1＝GraphQL／curl 失敗（fail loud）。

lane 上限常數（LANE_LIMITS）與候補排序 key 抄自 docs/COLLABORATION.md §5-b——那份文件才是
定案來源，這裡只是把它算出來；§5-b 改了常數要手動同步這裡（沒有自動對帳，同 patrol.sh
Supabase lock／simulator 常數的既有模式）。
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys

GRAPHQL_URL = "https://api.linear.app/graphql"
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))  # pen-open.sh 與本檔同目錄（R1 F2）

# docs/COLLABORATION.md §5-b：同 lane 狀態 In Progress + In Review 的票數上限。lane:product 不派工、
# 不在這裡列（永遠跳過）。改了上限要同步這裡與 §5-b 表格，兩邊沒有機械對帳（巡檢承載，同既有模式）。
LANE_LIMITS = {"lane:harness": 1, "lane:backend": 3, "lane:design": 1, "lane:ui": 1}
WIP_STATES = ("In Progress", "In Review")
BACKLOG_STATES = ("Backlog", "Spec")
# cycle 對帳 (a) 的「active」定義抄自 §4-b 巡檢 cron 模板本文（狀態名稱，不是 state.type）
ACTIVE_STATE_NAMES = ("Ready", "In Progress", "In Review", "QA", "Design", "Spec")
SIZE_RANK = {"size:S": 0, "size:M": 1, "size:L": 2}
SKIP_ISSUE = "LS-96"  # 常駐待辦池：永不列為候補、永不派（§5-b「harness 優先序」）

ISSUES_QUERY = """
query($after: String, $teamKey: String!) {
  issues(first: 50, after: $after, filter: { team: { key: { eq: $teamKey } }, state: { type: { nin: ["completed", "canceled"] } } }) {
    pageInfo { hasNextPage endCursor }
    nodes {
      identifier
      title
      description
      priority
      createdAt
      state { name type }
      labels { nodes { name } }
      cycle { id number }
      project { name }
      projectMilestone { name }
      parent { identifier }
      inverseRelations { nodes { type issue { identifier state { type } } } }
    }
  }
}
"""

# R1 F7：先用 isActive filter 精準抓「目前作用中」的 cycle——原本 first:20 無 filter，cycle 累積超過
# 20 個且預設排序沒把 active 排進第一頁時會抓不到，退回選「endsAt 最大的過去 cycle」把在飛票的
# cycle 動作全部指回舊 cycle（PLAUSIBLE 事故）。加 filter 讓 API 端保證回傳的就是 active，不靠猜。
CYCLES_QUERY_ACTIVE = """
query($teamId: String!) {
  team(id: $teamId) {
    cycles(first: 20, filter: { isActive: { eq: true } }) { nodes { id number startsAt endsAt isActive } }
  }
}
"""

# 找不到 active（例如兩個 cycle 交接空檔）才退回這支無 filter 查詢找 upcoming——僅在上面那支查詢
# 為空時才呼叫，正常情況（永遠有一個 active cycle）只打一次。
CYCLES_QUERY_ALL = """
query($teamId: String!) {
  team(id: $teamId) {
    cycles(first: 20) { nodes { id number startsAt endsAt isActive } }
  }
}
"""

DOCUMENTS_QUERY = """
query($cycleId: ID!) {
  documents(filter: { cycle: { id: { eq: $cycleId } } }) { nodes { id title } }
}
"""

# R1 F1：恢復「cycle 一行（編號／剩餘天數／票數 完成/總數）」需要的票數統計——ISSUES_QUERY 為了狀態對照
# 只抓非 completed/canceled 的票，算不出「完成」數，所以另開一支只查目前 cycle 底下所有票的 state.type
# （不受該 filter 限制）。first:250 是合理上限（cycle 週期短，實務不會超過）。
CYCLE_ISSUES_QUERY = """
query($cycleId: ID!) {
  cycle(id: $cycleId) { issues(first: 250) { nodes { state { type } } } }
}
"""


def gql(token, query, variables, timeout=25):
    body = json.dumps({"query": query, "variables": variables})
    # R1 F3：token 不能走 argv——curl 存活的那幾百毫秒內，同機同使用者任何行程都能用 ps 讀到完整 argv
    # （本 repo 就有腳本在做全表列舉，見 pen-open.sh 的 `ps -Ao command`），而這是遠端長期 PAT，外洩面比
    # demo-otp.sh 那支本機 service_role 更需要收斂。改用 `curl -K -`（--config 從 stdin 讀），只把
    # Authorization 這一行放進 config／走 stdin；URL／Content-Type／body 不含密鑰，仍走 argv。
    config = 'header = "Authorization: %s"\n' % token
    try:
        proc = subprocess.run(
            [
                "curl", "-sS", "--max-time", str(timeout), "-X", "POST", GRAPHQL_URL,
                "-H", "Content-Type: application/json",
                "--data", body,
                "-K", "-",
            ],
            input=config, capture_output=True, text=True, timeout=timeout + 5,
        )
    except Exception as exc:  # noqa: BLE001 - fail loud, 印出來讓人判斷
        sys.stderr.write("✗ patrol-linear：curl 呼叫失敗（%s）\n" % exc)
        sys.exit(1)
    if proc.returncode != 0:
        sys.stderr.write(
            "✗ patrol-linear：curl 失敗（exit %d）：%s\n" % (proc.returncode, proc.stderr.strip())
        )
        sys.exit(1)
    try:
        data = json.loads(proc.stdout)
    except ValueError:
        sys.stderr.write("✗ patrol-linear：GraphQL 回應不是合法 JSON：%s\n" % proc.stdout[:300])
        sys.exit(1)
    if "errors" in data:
        sys.stderr.write(
            "✗ patrol-linear：GraphQL 錯誤：%s\n" % json.dumps(data["errors"], ensure_ascii=False)
        )
        sys.exit(1)
    # R1 F5：回應是合法 JSON、沒有 errors，但也沒有可用的 data 物件（例如 {"data":null}）——
    # 不補這個檢查會讓呼叫端（fetch_issues 等）對 None 取 subscript 炸出原始 Python traceback，
    # 不是可讀的 fail-loud 訊息。
    if not isinstance(data.get("data"), dict):
        sys.stderr.write(
            "✗ patrol-linear：GraphQL 回應缺少可用的 data 物件：%s\n" % proc.stdout[:300]
        )
        sys.exit(1)
    return data["data"]


def fetch_issues(token, team_key):
    issues = []
    cursor = None
    while True:
        data = gql(token, ISSUES_QUERY, {"after": cursor, "teamKey": team_key})
        conn = data["issues"]
        issues.extend(conn["nodes"])
        page = conn["pageInfo"]
        if page.get("hasNextPage"):
            cursor = page.get("endCursor")
        else:
            break
    return issues


def fetch_cycles(token, team_id):
    data = gql(token, CYCLES_QUERY_ACTIVE, {"teamId": team_id})
    team = data.get("team")
    active = team["cycles"]["nodes"] if team else []
    if active:
        return active
    data = gql(token, CYCLES_QUERY_ALL, {"teamId": team_id})
    team = data.get("team")
    if not team:
        return []
    return team["cycles"]["nodes"]


def fetch_cycle_documents(token, cycle_id):
    data = gql(token, DOCUMENTS_QUERY, {"cycleId": cycle_id})
    return data["documents"]["nodes"]


def fetch_cycle_issue_states(token, cycle_id):
    data = gql(token, CYCLE_ISSUES_QUERY, {"cycleId": cycle_id})
    cyc = data.get("cycle") or {}
    return [n["state"]["type"] for n in (cyc.get("issues") or {}).get("nodes", [])]


def cycle_progress(token, current):
    """回傳 (完成票數, 總票數)；current 為 None／缺 id 回 (None, None)——這是巡檢摘要的附加資訊，
    查不到不 fail loud（不擋主流程）。"""
    if not current or not current.get("id"):
        return None, None
    states = fetch_cycle_issue_states(token, current["id"])
    total = len(states)
    done = sum(1 for t in states if t == "completed")
    return done, total


def parse_iso(ts):
    if not ts:
        return 0.0
    s = ts.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        return datetime.datetime.fromisoformat(s).timestamp()
    except ValueError:
        s2 = re.sub(r"\.\d+", "", s)
        try:
            return datetime.datetime.fromisoformat(s2).timestamp()
        except ValueError:
            return 0.0


def label_names(issue):
    return {n["name"] for n in (issue.get("labels") or {}).get("nodes", [])}


def lane_of(issue):
    labels = label_names(issue)
    for lane in LANE_LIMITS:
        if lane in labels:
            return lane
    return None


def size_of(issue):
    labels = label_names(issue)
    for lbl in SIZE_RANK:
        if lbl in labels:
            return lbl
    return None


def has_lane_label(issue):
    return any(l.startswith("lane:") for l in label_names(issue))


def blockers(issue):
    nodes = (issue.get("inverseRelations") or {}).get("nodes", [])
    return [r["issue"] for r in nodes if r.get("type") == "blocks"]


def blocked_by_resolved(issue):
    bs = blockers(issue)
    return all((b.get("state") or {}).get("type") in ("completed", "canceled") for b in bs)


def priority_rank(issue):
    p = issue.get("priority") or 0
    try:
        p = int(p)
    except (TypeError, ValueError):
        p = 0
    return 5 if p == 0 else p  # Linear：0=無優先序，排序上反而墊底（不是最高）


def size_rank(issue):
    return SIZE_RANK.get(size_of(issue), 3)  # 缺 size 排在 L 之後


def sort_key(issue):
    return (priority_rank(issue), size_rank(issue), parse_iso(issue.get("createdAt")))


def classify_candidate(issue):
    """回傳 'ok'／'skip'／'not_backlog'／'blocked'／'spec'／'structure'。"""
    if issue["identifier"] == SKIP_ISSUE:
        return "skip"
    if issue["state"]["name"] not in BACKLOG_STATES:
        return "not_backlog"
    if not blocked_by_resolved(issue):
        return "blocked"
    if "## 驗收" not in (issue.get("description") or ""):
        return "spec"
    project = issue.get("project")
    milestone = issue.get("projectMilestone")
    if not project:
        return "structure"
    if str((project or {}).get("name") or "").startswith("Phase") and not milestone:
        return "structure"
    return "ok"


def cycle_number_of(issue):
    c = issue.get("cycle")
    return c.get("number") if c else None


def pen_open_status(script_dir):
    """呼叫 pen-open.sh --status，回傳目前 Pen active 文件路徑；讀不到／出錯回傳 None。這是
    design_forced_full() 的盡力而為輸入之一，不是硬 gate——查不到就當作這條路徑無法判定，改看
    backup mtime 那條路徑（見 design_forced_full）。可用 PEN_OPEN_SH 覆寫路徑（自測 stub 用）。"""
    script = os.environ.get("PEN_OPEN_SH") or os.path.join(script_dir, "pen-open.sh")
    if not (os.path.isfile(script) and os.access(script, os.X_OK)):
        return None
    try:
        proc = subprocess.run([script, "--status"], capture_output=True, text=True, timeout=20)
    except Exception:  # noqa: BLE001 - best-effort，不 fail loud
        return None
    if proc.returncode != 0:
        return None
    out = proc.stdout.strip()
    return out or None


def design_forced_full(issues, root, script_dir):
    """R1 F2（§5-b 例外）：design 與 ui 共用單一 Pen 全域實例，ui 票在讀取設計稿階段期間 design lane
    視為滿——否則巡檢可能同時補位派出兩張要動 Pen 的票，撞同一份文件（LS-81／LS-91 同型事故）。

    機械判定二擇一：① `pen-open.sh --status` 回傳的目前 active 路徑＝該 ui 票 worktree 的
    design/littlesprout.pen；② 該檔案的 Pen autosave backup（sha1(file://<abs path>)，同
    pen-land.sh 的算法）mtime 落在 30 分鐘內。任一步找不到 worktree／pen-open.sh 不可執行／backup
    目錄不存在都當作「無法判定為滿」，不 fail loud——這是盡力而為的輔助判斷，§5-b 主要仍靠規約承載
    （patrol-linear.sh 不追蹤 Pen 是否真的忙碌到什麼程度，只做這個粗略、保守但非完備的信號）。
    """
    ui_in_progress = [i for i in issues if lane_of(i) == "lane:ui" and i["state"]["name"] == "In Progress"]
    if not ui_in_progress:
        return False
    worktrees = worktree_tickets(root)
    active_path = pen_open_status(script_dir)
    active_real = os.path.realpath(active_path) if active_path else None
    now = datetime.datetime.now(datetime.timezone.utc).timestamp()
    backup_dir = os.environ.get("PEN_BACKUP_DIR") or os.path.join(os.path.expanduser("~"), ".pencil", "backup")
    for issue in ui_in_progress:
        n = ticket_number(issue["identifier"])
        if n is None:
            continue
        wt = worktrees.get(n)
        if not wt:
            continue
        want = os.path.join(wt, "design", "littlesprout.pen")
        if active_real and active_real == os.path.realpath(want):
            return True
        sha = hashlib.sha1(("file://%s" % want).encode("utf-8")).hexdigest()
        backup = os.path.join(backup_dir, sha)
        try:
            mtime = os.path.getmtime(backup)
        except OSError:
            continue
        if now - mtime < 1800:
            return True
    return False


def lane_wip(issues, lane, root=None, script_dir=None):
    wip = sum(1 for i in issues if lane_of(i) == lane and i["state"]["name"] in WIP_STATES)
    if lane == "lane:design" and root is not None and script_dir is not None:
        if design_forced_full(issues, root, script_dir):
            wip = max(wip, LANE_LIMITS[lane])
    return wip


def lane_candidates(issues, lane, current_cycle_number):
    """回傳 (排序後 ok 候補 identifier 清單－目前 cycle 內, 排序後 ok 候補清單－全部, 是否需 scope+)。"""
    lane_issues = [i for i in issues if lane_of(i) == lane]
    in_cycle_ok = sorted(
        (i for i in lane_issues if classify_candidate(i) == "ok" and cycle_number_of(i) == current_cycle_number),
        key=sort_key,
    )
    all_ok = sorted((i for i in lane_issues if classify_candidate(i) == "ok"), key=sort_key)
    if in_cycle_ok:
        return in_cycle_ok, all_ok, False
    outside_ok = sorted(
        (i for i in all_ok if cycle_number_of(i) != current_cycle_number), key=sort_key
    )
    return [], outside_ok, bool(outside_ok)


def lane_pending(issues, lane):
    """R1 F1：classify_candidate() 算出的 'spec'／'structure' 排除原因之前只用來丟棄候補，沒有輸出
    出口——票文缺「## 驗收」或缺 project／Phase 票缺 milestone 的票會靜默停滯，沒人知道要去補。
    回傳 (待 Spec identifier 清單, 待結構 identifier 清單)，依票號排序。"""
    lane_issues = [i for i in issues if lane_of(i) == lane]
    pending_spec = [i["identifier"] for i in lane_issues if classify_candidate(i) == "spec"]
    pending_structure = [i["identifier"] for i in lane_issues if classify_candidate(i) == "structure"]
    pending_spec.sort(key=lambda ident: ticket_number(ident) or 0)
    pending_structure.sort(key=lambda ident: ticket_number(ident) or 0)
    return pending_spec, pending_structure


# ---------------- git 對照（狀態對照段；section 1）----------------

def git(root, *args):
    return subprocess.run(["git", "-C", root] + list(args), capture_output=True, text=True)


def worktree_tickets(root):
    res = git(root, "worktree", "list", "--porcelain")
    tickets = {}
    for line in res.stdout.splitlines():
        if line.startswith("worktree "):
            path = line[len("worktree "):].strip()
            m = re.match(r"^LS-(\d+)$", os.path.basename(path))
            if m:
                tickets[int(m.group(1))] = path
    return tickets


def ticket_number(identifier):
    m = re.match(r"^LS-(\d+)$", identifier or "")
    return int(m.group(1)) if m else None


def commits_for_ticket(root, n, ref="origin/development"):
    res = git(root, "log", "--format=%H\t%s", ref)
    if res.returncode != 0:
        return None  # ref 不存在／找不到——不判定，別亂標
    pattern = re.compile(r"(^|[^0-9])LS-%d([^0-9]|$)" % n)
    hits = []
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        sha, _, subject = line.partition("\t")
        if pattern.search(subject):
            hits.append(sha)
    return hits


def is_ancestor(root, sha, ref):
    res = git(root, "merge-base", "--is-ancestor", sha, ref)
    return res.returncode == 0


def state_crosscheck(root, issues):
    lines = []
    worktrees = worktree_tickets(root)
    for issue in issues:
        n = ticket_number(issue["identifier"])
        if n is None:
            continue
        name = issue["state"]["name"]
        if name == "Ready" and n not in worktrees:
            lines.append(
                "%s Ready 無人接（無 .claude/worktrees/LS-%d）→ 建 worktree＋branch 並派工" % (issue["identifier"], n)
            )
        elif name == "In Progress" and n not in worktrees:
            lines.append(
                "%s In Progress 卻無 .claude/worktrees/LS-%d → 查勤（agent 是否還在跑？）" % (issue["identifier"], n)
            )
        elif name == "QA":
            shas = commits_for_ticket(root, n)
            if shas is None:
                lines.append("%s QA：origin/development 不存在或讀不到，略過對照" % issue["identifier"])
            elif not shas:
                lines.append("%s QA：origin/development 找不到對應 commit（票號比對失敗？）→ 人工確認" % issue["identifier"])
            else:
                missing = [s for s in shas if not is_ancestor(root, s, "origin/test")]
                if missing:
                    lines.append(
                        "%s QA 但 test 未含（%d 個 commit 不在 origin/test）→ bash scripts/ops/promote.sh development test"
                        % (issue["identifier"], len(missing))
                    )
    return lines


# ---------------- cycle 對帳（section 2）----------------

def pick_current_cycle(cycles, now_epoch):
    """R1 F7：不再退回「endsAt 最大的過去 cycle」——選到已結束的 cycle 會讓 cycle 對帳 (a) 把所有
    在飛票的 cycle 動作指回舊 cycle（PLAUSIBLE 事故）。找不到 active／upcoming 就回 None，交由
    呼叫端印「無法判定」，不硬猜一個。"""
    active = [c for c in cycles if c.get("isActive")]
    if active:
        return active[0]
    upcoming = [c for c in cycles if parse_iso(c.get("startsAt")) > now_epoch]
    if upcoming:
        return min(upcoming, key=lambda c: parse_iso(c.get("startsAt")))
    return None


def cycle_reconciliation(token, issues, current, now_epoch):
    result = {"a": [], "b": [], "c": [], "d": []}
    actions = []
    if current is None:
        result["c"].append("無法判定當前 cycle（cycles 查詢為空）")
        return result, actions
    cn = current["number"]
    for issue in issues:
        if issue["state"]["name"] in ACTIVE_STATE_NAMES and cycle_number_of(issue) != cn:
            result["a"].append(issue["identifier"])
            actions.append("→ save_issue %s cycle=%s" % (issue["identifier"], cn))
    for issue in issues:
        if cycle_number_of(issue) == cn and issue["state"]["name"] in BACKLOG_STATES and not blocked_by_resolved(issue):
            result["b"].append(issue["identifier"])
    starts = parse_iso(current.get("startsAt"))
    ends = parse_iso(current.get("endsAt"))
    age_days = (now_epoch - starts) / 86400.0 if starts else 0
    if age_days >= 2:
        docs = fetch_cycle_documents(token, current["id"]) if current.get("id") else []
        wanted = "Cycle %s 規劃" % cn
        has_doc = any(wanted in (d.get("title") or "") for d in docs)
        if not has_doc:
            result["c"].append("Cycle %s 進入第 %d 天仍無「%s」Document" % (cn, int(age_days) + 1, wanted))
            actions.append("→ 建立「%s」Document" % wanted)
    remaining_h = (ends - now_epoch) / 3600.0 if ends else None
    if remaining_h is not None and remaining_h < 24:
        result["d"].append("Cycle %s 剩 %.1f 小時 → 準備回顧／規劃下一輪" % (cn, remaining_h))
    return result, actions


# ---------------- 開票結構（section 4）----------------

def ticket_structure(issues):
    """R1 I1：LS-96（常駐待辦池）永不派、永不進 cycle，票文本身不打算補 size／project——結構檢查
    豁免它，否則每輪都命中 (e) 且永遠不會被清掉，會訓練出「結構段可以忽略」的習慣。"""
    result = {"a": [], "b": [], "c": [], "d": [], "e": []}
    for issue in issues:
        ident = issue["identifier"]
        if ident == SKIP_ISSUE:
            continue
        project = issue.get("project")
        if not project:
            result["a"].append(ident)
        elif str(project.get("name") or "").startswith("Phase") and not issue.get("projectMilestone"):
            result["b"].append(ident)
        title = issue.get("title") or ""
        if (title.startswith("Task：") or title.startswith("Task:")) and not issue.get("parent"):
            result["c"].append(ident)
        if not has_lane_label(issue):
            result["d"].append(ident)
        if "lane:harness" in label_names(issue) and not size_of(issue):
            result["e"].append(ident)
    return result


# ---------------- 輸出 ----------------

def build_report(token, root, team_key, team_id, sim_lines):
    issues = fetch_issues(token, team_key)
    cycles = fetch_cycles(token, team_id)
    now_epoch = datetime.datetime.now(datetime.timezone.utc).timestamp()
    current = pick_current_cycle(cycles, now_epoch)

    crosscheck = state_crosscheck(root, issues)
    cycle_check, cycle_actions = cycle_reconciliation(token, issues, current, now_epoch)
    structure = ticket_structure(issues)

    lanes = {}
    lane_actions = []
    for lane, limit in LANE_LIMITS.items():
        wip = lane_wip(issues, lane, root=root, script_dir=SCRIPT_DIR)
        in_cycle_ok, all_ok, needs_scope = lane_candidates(
            issues, lane, current["number"] if current else None
        )
        pending_spec, pending_structure = lane_pending(issues, lane)
        candidates_shown = in_cycle_ok if in_cycle_ok else all_ok
        entry = {
            "limit": limit,
            "wip": wip,
            "candidates": [i["identifier"] for i in candidates_shown],
            "chosen": None,
            "needs_scope_plus": needs_scope,
            "pending_spec": pending_spec,
            "pending_structure": pending_structure,
            "actions": [],
        }
        if wip < limit and candidates_shown:
            chosen = candidates_shown[0]
            entry["chosen"] = chosen["identifier"]
            if needs_scope:
                entry["actions"].append(
                    "→ save_issue %s cycle=%s（scope+，取自 cycle 外）" % (chosen["identifier"], current["number"] if current else "?")
                )
            entry["actions"].append(
                "→ save_issue %s state=Ready cycle=%s"
                % (chosen["identifier"], current["number"] if current else "?")
            )
            lane_actions.extend(entry["actions"])
        lanes[lane] = entry

    actions = list(cycle_actions) + list(lane_actions)

    # R1 F1：恢復 cycle 一行（編號／剩餘天數／票數 完成/總數）
    remaining_days = None
    if current and current.get("endsAt"):
        remaining_days = (parse_iso(current["endsAt"]) - now_epoch) / 86400.0
    tickets_done, tickets_total = cycle_progress(token, current)

    return {
        "skipped": False,
        "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        "current_cycle": (
            {
                "number": current["number"],
                "id": current.get("id"),
                "remaining_days": remaining_days,
                "tickets_done": tickets_done,
                "tickets_total": tickets_total,
            } if current else None
        ),
        "state_crosscheck": crosscheck,
        "cycle_check": cycle_check,
        "lanes": lanes,
        "structure": structure,
        "booted_simulator_flags": sim_lines,
        "actions": actions,
    }


def format_cycle_line(cc):
    """R1 F1：cycle 一行——編號／剩餘天數／票數 完成/總數（§4-b 舊模板第 6 步的內容，機械化後恢復）。"""
    if not cc:
        return "current cycle：無法判定"
    rd = cc.get("remaining_days")
    rd_str = ("%.1f 天" % rd) if rd is not None else "不明"
    total = cc.get("tickets_total")
    count_str = ("%s/%s 完成" % (cc.get("tickets_done"), total)) if total is not None else "不明"
    return "current cycle：%s（剩 %s；票數 %s）" % (cc["number"], rd_str, count_str)


def format_lane_line(lane, entry):
    """R1 F1／I2：五欄——上限／在飛／候補／待 Spec／待結構；候補全部來自 cycle 外（scope+）時標明
    並只印前 3 張，避免誤以為 cycle 內現成有這麼多候補（I2：真實跑過 12 張全 cycle 外的案例）。"""
    cand_list = entry["candidates"]
    if entry.get("needs_scope_plus") and cand_list:
        shown = cand_list[:3]
        more = "…" if len(cand_list) > 3 else ""
        cand = "%s%s（cycle 外，取第一張需 scope+）" % (", ".join(shown), more)
    elif cand_list:
        cand = ", ".join(cand_list)
    else:
        cand = "（無候補）"
    pend_spec = ", ".join(entry["pending_spec"]) if entry["pending_spec"] else "無"
    pend_structure = ", ".join(entry["pending_structure"]) if entry["pending_structure"] else "無"
    return "  %-14s 上限%d 在飛%d  候補：%s  待Spec：%s  待結構：%s" % (
        lane, entry["limit"], entry["wip"], cand, pend_spec, pend_structure
    )


def format_human(report, brief=False):
    lines = []
    cc = report["current_cycle"]
    if brief:
        lines.append("巡檢（Linear 半段）%s" % format_cycle_line(cc))
        lines.append("Lane 狀態：")
        for lane, entry in report["lanes"].items():
            lines.append(format_lane_line(lane, entry))
        lines.append("動作清單：")
        if report["actions"]:
            lines.extend(report["actions"])
        else:
            lines.append("（無待執行動作）")
        return "\n".join(lines)

    lines.append("== 巡檢（Linear 半段）%s" % report["generated_at"])
    lines.append("   %s" % format_cycle_line(cc))

    lines.append("== 1. 狀態對照（對照 git worktree／origin/test）")
    if report["state_crosscheck"]:
        for line in report["state_crosscheck"]:
            lines.append("  ⚠ %s" % line)
    else:
        lines.append("  （無異常）")

    lines.append("== 2. Cycle 對帳")
    ck = report["cycle_check"]
    lines.append("  (a) active 票不在本 cycle：%s" % (", ".join(ck["a"]) if ck["a"] else "無"))
    lines.append("  (b) cycle 內 Backlog／Spec blockedBy 未解（規劃錯誤）：%s" % (", ".join(ck["b"]) if ck["b"] else "無"))
    for msg in ck["c"]:
        lines.append("  (c) %s" % msg)
    if not ck["c"]:
        lines.append("  (c) 規劃 Document：ok")
    for msg in ck["d"]:
        lines.append("  (d) %s" % msg)
    if not ck["d"]:
        lines.append("  (d) 剩餘時間：ok")

    lines.append("== 3. Lane 補位")
    for lane, entry in report["lanes"].items():
        lines.append(format_lane_line(lane, entry))
        for a in entry["actions"]:
            lines.append("    %s" % a)

    lines.append("== 4. 開票結構")
    st = report["structure"]
    labels = {"a": "無 project", "b": "Phase 專案缺 milestone", "c": "Task：標題缺 parent", "d": "無 lane 標籤", "e": "lane:harness 缺 size"}
    for key in ("a", "b", "c", "d", "e"):
        lines.append("  (%s) %s：%s" % (key, labels[key], ", ".join(st[key]) if st[key] else "無"))

    lines.append("== 5. Booted 模擬器（沿用 patrol.sh）")
    if report["booted_simulator_flags"]:
        for line in report["booted_simulator_flags"]:
            lines.append("  %s" % line)
    else:
        lines.append("  （無異常）")

    lines.append("== 動作清單（逐行執行）")
    if report["actions"]:
        lines.extend(report["actions"])
    else:
        lines.append("（無待執行動作）")

    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--root", required=True)
    ap.add_argument("--team-key", required=True)
    ap.add_argument("--team-id", required=True)
    ap.add_argument("--mode", choices=["human", "brief", "json"], default="human")
    ap.add_argument("--sim-lines-file", default=None)
    args = ap.parse_args()

    token = os.environ.get("LINEAR_API_KEY", "")
    if not token:
        sys.stderr.write("✗ patrol-linear：LINEAR_API_KEY 未設定（patrol-linear.sh 應該已經擋在這之前）\n")
        sys.exit(1)

    sim_lines = []
    if args.sim_lines_file and os.path.isfile(args.sim_lines_file):
        with open(args.sim_lines_file, encoding="utf-8") as fh:
            sim_lines = [l.rstrip("\n") for l in fh if l.strip()]

    report = build_report(token, args.root, args.team_key, args.team_id, sim_lines)

    if args.mode == "json":
        print(json.dumps(report, ensure_ascii=False))
    else:
        print(format_human(report, brief=(args.mode == "brief")))
    sys.exit(0)


if __name__ == "__main__":
    main()
