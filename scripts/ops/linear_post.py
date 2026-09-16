#!/usr/bin/env python3
"""Linear API 備援（LS-308 B1；MCP 斷線／token 過期時用）：
  python3 linear_post.py get <issue> [--comments]        → 印 title／state／labels／description，--comments 再列全部 comment
  python3 linear_post.py comment <issue> <body-file>      → 印新 comment id
  python3 linear_post.py state <issue> <state-name>       → 改狀態（依 team 的 workflow state 名稱）

沿 scripts/ops/linear-archive.py 的 load_key()（key 永不印出，讀 LINEAR_API_KEY 環境變數或 ./.env）；
不重複貼一份，兩支腳本共用同一個 key 讀取路徑，改一邊不會漏另一邊（同 A3 lib/pencil-mcp.sh 的理由）。
LINEAR_API_URL 可覆寫 GraphQL endpoint（預設 https://api.linear.app/graphql）——自測指向本機假伺服器
（python3 -m http.server 類 stub），不打正式 Linear API。

錯誤處置：HTTP 層失敗（連線拒絕／逾時／4xx／5xx）或回應內含 GraphQL "errors" 都印錯誤內容到 stderr、exit 1；
key 本身永不出現在任何輸出（stdout／stderr）。
"""
import importlib.util
import json
import os
import sys
import urllib.error
import urllib.request

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
API = os.environ.get("LINEAR_API_URL", "https://api.linear.app/graphql")


def _load_archive_module():
    spec = importlib.util.spec_from_file_location(
        "linear_archive", os.path.join(SCRIPT_DIR, "linear-archive.py")
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def gql(key, query, variables):
    body = json.dumps({"query": query, "variables": variables}).encode()
    req = urllib.request.Request(
        API,
        data=body,
        headers={"Authorization": key, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            out = json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:
            payload = json.loads(e.read())
        except (ValueError, json.JSONDecodeError):
            payload = {"http_status": e.code, "reason": e.reason}
        print(json.dumps(payload, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(json.dumps({"connection_error": str(e.reason)}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
    if "errors" in out:
        print(json.dumps(out["errors"], ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
    return out["data"]


def issue_lookup(key, identifier):
    data = gql(
        key,
        "query($i:String!){ issue(id:$i){ id team{ id } } }",
        {"i": identifier},
    )
    if not data.get("issue"):
        print(json.dumps({"error": f"issue not found: {identifier}"}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
    return data["issue"]


def cmd_get(key, args):
    if len(args) < 1:
        print(__doc__)
        sys.exit(2)
    issue, with_comments = args[0], "--comments" in args[1:]
    q = """query($i:String!){ issue(id:$i){ identifier title description
      state{ name } labels{ nodes{ name } } cycle{ number } parent{ identifier }
      comments(first:100){ nodes{ id createdAt body } } } }"""
    data = gql(key, q, {"i": issue})
    d = data.get("issue")
    if not d:
        print(json.dumps({"error": f"issue not found: {issue}"}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
    print(f"# {d['identifier']} {d['title']}")
    print(
        f"state={d['state']['name']} labels={[lb['name'] for lb in d['labels']['nodes']]} "
        f"cycle={(d['cycle'] or {}).get('number')} parent={(d['parent'] or {}).get('identifier')}"
    )
    print()
    print(d["description"] or "")
    if with_comments:
        for c in d["comments"]["nodes"]:
            print(f"\n--- comment {c['id'][:8]} {c['createdAt']}\n{c['body']}")


def cmd_comment(key, args):
    if len(args) < 2:
        print(__doc__)
        sys.exit(2)
    issue, path = args[0], args[1]
    with open(path, encoding="utf-8") as f:
        body = f.read()
    node = issue_lookup(key, issue)
    data = gql(
        key,
        'mutation($iid:String!,$b:String!){ commentCreate(input:{issueId:$iid, body:$b}){ success comment{ id } } }',
        {"iid": node["id"], "b": body},
    )
    if not data["commentCreate"]["success"]:
        print(json.dumps({"error": "commentCreate returned success=false"}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
    print(data["commentCreate"]["comment"]["id"])


def cmd_state(key, args):
    if len(args) < 2:
        print(__doc__)
        sys.exit(2)
    issue, state_name = args[0], args[1]
    node = issue_lookup(key, issue)
    states = gql(
        key,
        'query($t:ID!){ workflowStates(filter:{team:{id:{eq:$t}}}){ nodes{ id name } } }',
        {"t": node["team"]["id"]},
    )["workflowStates"]["nodes"]
    match = [s for s in states if s["name"] == state_name]
    if not match:
        print(
            json.dumps({"error": "state not found", "available": [s["name"] for s in states]}, ensure_ascii=False),
            file=sys.stderr,
        )
        sys.exit(1)
    data = gql(
        key,
        'mutation($iid:String!,$s:String!){ issueUpdate(id:$iid, input:{stateId:$s}){ success issue{ identifier state{ name } } } }',
        {"iid": node["id"], "s": match[0]["id"]},
    )
    if not data["issueUpdate"]["success"]:
        print(json.dumps({"error": "issueUpdate returned success=false"}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
    print(data["issueUpdate"]["issue"]["identifier"], data["issueUpdate"]["issue"]["state"]["name"])


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("get", "comment", "state"):
        print(__doc__)
        sys.exit(2)
    mode = sys.argv[1]
    args = sys.argv[2:]
    la = _load_archive_module()
    key = la.load_key()
    if mode == "get":
        cmd_get(key, args)
    elif mode == "comment":
        cmd_comment(key, args)
    elif mode == "state":
        cmd_state(key, args)


if __name__ == "__main__":
    main()
