#!/usr/bin/env python3
"""Export Done/Canceled Linear issues (team LS) to markdown files, then optionally archive them.

usage: linear-archive.py --export DIR [--cutoff ISO] [--archive] [--dry-run]
  --export DIR   write DIR/LS-<n>.md per issue + DIR/README.md index
  --cutoff ISO   only issues completed/canceled before this UTC instant (default 2026-09-13T16:00:00Z = 09-14 00:00 Taipei)
  --dry-run      only list what would be exported/archived
  --archive      after a successful export, call issueArchive for each exported issue
Reads LINEAR_API_KEY from ./.env (never printed).
"""
import argparse, json, os, re, sys, time, urllib.request

TEAM_ID = "020782d9-b525-46e1-8805-965cff30d7d2"
API = "https://api.linear.app/graphql"

def load_key():
    key = os.environ.get("LINEAR_API_KEY")
    if key:
        return key
    try:
        with open(".env") as f:
            for line in f:
                line = line.strip()
                if line.startswith("LINEAR_API_KEY="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    sys.exit("LINEAR_API_KEY not found")

def gql(key, query, variables=None, retries=5):
    body = json.dumps({"query": query, "variables": variables or {}}).encode()
    req = urllib.request.Request(API, data=body, headers={"Content-Type": "application/json", "Authorization": key})
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                data = json.loads(r.read())
            if "errors" in data:
                raise RuntimeError(json.dumps(data["errors"])[:500])
            return data["data"]
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < retries - 1:
                time.sleep(5 * (attempt + 1)); continue
            raise
    raise RuntimeError("gql retries exhausted")

LIST_Q = """
query($team:String!,$after:String,$cutoff:DateTimeOrDuration!){
  team(id:$team){ issues(first:50, after:$after, orderBy:createdAt,
    filter:{ state:{ type:{ in:["completed","canceled"] } },
             or:[ {completedAt:{lt:$cutoff}}, {canceledAt:{lt:$cutoff}} ] }){
    pageInfo{hasNextPage endCursor}
    nodes{ id identifier title completedAt canceledAt state{name type} }
  } }
}"""

ISSUE_Q = """
query($id:String!){
  issue(id:$id){
    id identifier title description url priority priorityLabel estimate
    createdAt updatedAt startedAt completedAt canceledAt
    state{name type} labels{nodes{name}} cycle{number name}
    project{name} projectMilestone{name} assignee{name} creator{name}
    parent{identifier title} children{nodes{identifier title}}
    relations{nodes{type relatedIssue{identifier}}}
    inverseRelations{nodes{type issue{identifier}}}
    attachments{nodes{title url}}
    comments(first:100){ pageInfo{hasNextPage endCursor} nodes{ id body createdAt user{name} parent{id} } }
  }
}"""

COMMENTS_Q = """
query($id:String!,$after:String){
  issue(id:$id){ comments(first:100, after:$after){ pageInfo{hasNextPage endCursor} nodes{ id body createdAt user{name} parent{id} } } }
}"""

ARCHIVE_M = "mutation($id:String!){ issueArchive(id:$id){ success } }"

def list_issues(key, cutoff):
    out, after = [], None
    while True:
        d = gql(key, LIST_Q, {"team": TEAM_ID, "after": after, "cutoff": cutoff})
        page = d["team"]["issues"]
        out += page["nodes"]
        if not page["pageInfo"]["hasNextPage"]:
            return out
        after = page["pageInfo"]["endCursor"]

def fetch_issue(key, iid):
    d = gql(key, ISSUE_Q, {"id": iid})["issue"]
    comments = d["comments"]["nodes"]
    pi = d["comments"]["pageInfo"]
    while pi["hasNextPage"]:
        c = gql(key, COMMENTS_Q, {"id": iid, "after": pi["endCursor"]})["issue"]["comments"]
        comments += c["nodes"]; pi = c["pageInfo"]
    d["comments"] = comments
    return d

def md(issue):
    L = []
    L.append(f"# {issue['identifier']} {issue['title']}\n")
    L.append("| 欄位 | 值 |\n|---|---|")
    L.append(f"| 狀態 | {issue['state']['name']}（{issue['state']['type']}） |")
    L.append(f"| 優先序 | {issue.get('priorityLabel')} |")
    L.append(f"| 標籤 | {', '.join(n['name'] for n in issue['labels']['nodes']) or '—'} |")
    L.append(f"| Cycle | {issue['cycle']['number'] if issue.get('cycle') else '—'} |")
    L.append(f"| Project | {issue['project']['name'] if issue.get('project') else '—'} |")
    L.append(f"| Milestone | {issue['projectMilestone']['name'] if issue.get('projectMilestone') else '—'} |")
    L.append(f"| 估點 | {issue.get('estimate') if issue.get('estimate') is not None else '—'} |")
    L.append(f"| 建立 | {issue['createdAt']} |")
    L.append(f"| 開始 | {issue.get('startedAt') or '—'} |")
    L.append(f"| 完成 | {issue.get('completedAt') or issue.get('canceledAt') or '—'} |")
    L.append(f"| 建票者 | {issue['creator']['name'] if issue.get('creator') else '—'} |")
    L.append(f"| 指派 | {issue['assignee']['name'] if issue.get('assignee') else '—'} |")
    L.append(f"| URL | {issue['url']} |")
    if issue.get("parent"):
        L.append(f"| 父票 | {issue['parent']['identifier']} {issue['parent']['title']} |")
    kids = issue["children"]["nodes"]
    if kids:
        L.append(f"| 子票 | {', '.join(k['identifier'] for k in kids)} |")
    rels = [f"{r['type']}→{r['relatedIssue']['identifier']}" for r in issue["relations"]["nodes"] if r.get("relatedIssue")]
    rels += [f"{r['type']}←{r['issue']['identifier']}" for r in issue["inverseRelations"]["nodes"] if r.get("issue")]
    if rels:
        L.append(f"| 關係 | {', '.join(rels)} |")
    atts = issue["attachments"]["nodes"]
    if atts:
        L.append(f"| 附件 | {'; '.join(f'[{a['title']}]({a['url']})' for a in atts)} |")
    L.append("\n## 描述\n")
    L.append(issue.get("description") or "（無）")
    L.append(f"\n## 留言（{len(issue['comments'])}）\n")
    by_id = {c["id"]: c for c in issue["comments"]}
    for c in sorted(issue["comments"], key=lambda c: c["createdAt"]):
        who = c["user"]["name"] if c.get("user") else "—"
        reply = f"（回覆 {c['parent']['id'][:8]}）" if c.get("parent") else ""
        L.append(f"### {c['createdAt']} · {who} · `{c['id'][:8]}`{reply}\n")
        L.append(c["body"] or "")
        L.append("")
    return "\n".join(L) + "\n"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--export", required=True)
    ap.add_argument("--cutoff", default="2026-09-13T16:00:00Z")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--archive", action="store_true")
    a = ap.parse_args()
    key = load_key()
    issues = list_issues(key, a.cutoff)
    issues.sort(key=lambda i: int(i["identifier"].split("-")[1]))
    print(f"候選 {len(issues)} 張（completed/canceled 早於 {a.cutoff}）")
    if a.dry_run:
        for i in issues:
            print(f"  {i['identifier']}\t{i['state']['name']}\t{(i.get('completedAt') or i.get('canceledAt') or '')[:10]}\t{i['title'][:60]}")
        return
    os.makedirs(a.export, exist_ok=True)
    index = ["# Linear 封存票索引（team LS）\n", f"匯出時間：{time.strftime('%Y-%m-%dT%H:%M:%S%z')}；條件：completed／canceled 早於 {a.cutoff}；每票一檔 `LS-<n>.md`（描述＋全部留言）。\n",
             "| 票 | 狀態 | 完成 | Lane／標籤 | 標題 |", "|---|---|---|---|---|"]
    exported = []
    for i in issues:
        full = fetch_issue(key, i["id"])
        path = os.path.join(a.export, f"{full['identifier']}.md")
        with open(path, "w") as f:
            f.write(md(full))
        done = (full.get("completedAt") or full.get("canceledAt") or "")[:10]
        labels = ", ".join(n["name"] for n in full["labels"]["nodes"])
        title = full["title"].replace("|", "\\|")
        index.append(f"| [{full['identifier']}]({full['identifier']}.md) | {full['state']['name']} | {done} | {labels} | {title} |")
        exported.append(full)
        print(f"  ✓ {full['identifier']} 留言 {len(full['comments'])}")
    with open(os.path.join(a.export, "README.md"), "w") as f:
        f.write("\n".join(index) + "\n")
    print(f"匯出 {len(exported)} 張 → {a.export}")
    if a.archive:
        ok = 0
        for full in exported:
            path = os.path.join(a.export, f"{full['identifier']}.md")
            if not (os.path.exists(path) and os.path.getsize(path) > 0):
                print(f"  ✗ {full['identifier']} 匯出檔不存在，跳過封存"); continue
            r = gql(key, ARCHIVE_M, {"id": full["id"]})
            if r["issueArchive"]["success"]:
                ok += 1
            else:
                print(f"  ✗ {full['identifier']} 封存失敗")
        print(f"封存 {ok}/{len(exported)}")

if __name__ == "__main__":
    main()
