#!/bin/bash
# API 契約對帳 gate（LS-41）。規約見 docs/COLLABORATION.md §7、docs/API.md §9。
#
# 從 supabase/migrations/*.sql 機械抽出 public schema 的 RPC 簽章與資料表清單，
# 對照 docs/API.md 最下方「機械對帳清單」（<!-- API-CONTRACT:RPC ... --> /
# <!-- API-CONTRACT:TABLES ... -->）。任一邊多、任一邊少都 FAIL（doc 缺項或
# schema 缺項都紅），印出差異——不是「有沒有動」這種弱驗證，是逐項比對。
#
# 用法：api-contract-check.sh [path-to-API.md] [path-to-migrations-dir]
#   兩個參數皆可省略，預設 docs/API.md 與 supabase/migrations（相對 repo 根）。
#   保留參數化是為了負向測試：對著臨時改壞的 API.md 副本跑，不必動到真正的文件。
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
api_md="${1:-${root}/docs/API.md}"
migrations_dir="${2:-${root}/supabase/migrations}"

if [ ! -f "${api_md}" ]; then
  echo "✗ api-contract gate：找不到 ${api_md}" >&2
  exit 1
fi
if [ ! -d "${migrations_dir}" ]; then
  echo "✗ api-contract gate：找不到 ${migrations_dir}" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "✗ api-contract gate：需要 python3 解析 migrations／API.md（macOS 與 ubuntu-latest 皆內建；PATH 異常請修復）" >&2
  exit 1
fi

PYTHONIOENCODING=utf-8 python3 - "${api_md}" "${migrations_dir}" <<'PY'
import re
import sys
import pathlib

api_md_path, migrations_dir = sys.argv[1], sys.argv[2]


def strip_sql_comments(sql: str) -> str:
    # 逐行砍掉 `--` 之後的內容。夠用：本專案的 migration 風格一律把註解獨立成行，
    # 不在同一行的程式碼後面接 `--` 尾註（讀過全部 migrations 逐檔確認過這個慣例）。
    return "\n".join(line[: line.find("--")] if "--" in line else line for line in sql.split("\n"))


def split_top_level(s: str):
    # 依「深度為 0 的逗號」切參數列，type 若帶 numeric(10,2) 這種內部括號不會被誤切。
    parts, depth, cur = [], 0, []
    for ch in s:
        if ch == "(":
            depth += 1
            cur.append(ch)
        elif ch == ")":
            depth -= 1
            cur.append(ch)
        elif ch == "," and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    if cur:
        parts.append("".join(cur))
    return parts


def normalize_type(t: str) -> str:
    t = re.split(r"\bdefault\b", t.strip(), flags=re.IGNORECASE)[0]
    return re.sub(r"\s+", " ", t).strip().lower()


def extract_paren_block(text: str, start_after: int):
    # start_after 指向已消耗的開頭 '(' 之後那個字元；回傳該括號內的原始文字。
    depth, i = 1, start_after
    while i < len(text) and depth > 0:
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
        i += 1
    return text[start_after : i - 1]


def param_types(params_raw: str):
    types = []
    for p in split_top_level(params_raw):
        p = p.strip()
        if not p:
            continue
        parts = p.split(None, 1)
        types.append(normalize_type(parts[1] if len(parts) == 2 else parts[0]))
    return types


def extract_schema(migrations_dir: str):
    files = sorted(pathlib.Path(migrations_dir).glob("*.sql"))
    if not files:
        print(f"✗ api-contract gate：{migrations_dir} 底下沒有任何 .sql 檔", file=sys.stderr)
        sys.exit(1)
    clean = strip_sql_comments("\n".join(f.read_text(encoding="utf-8") for f in files))

    rpcs = {}
    for m in re.finditer(r"create\s+(?:or\s+replace\s+)?function\s+public\.(\w+)\s*\(", clean, re.IGNORECASE):
        sig = f"{m.group(1)}({', '.join(param_types(extract_paren_block(clean, m.end())))})"
        rpcs[sig] = True
    for m in re.finditer(r"drop\s+function\s+(?:if\s+exists\s+)?public\.(\w+)\s*\(", clean, re.IGNORECASE):
        sig = f"{m.group(1)}({', '.join(param_types(extract_paren_block(clean, m.end())))})"
        rpcs.pop(sig, None)

    tables = set(m.group(1) for m in re.finditer(r"create\s+table\s+public\.(\w+)\s*\(", clean, re.IGNORECASE))
    for m in re.finditer(r"drop\s+table\s+(?:if\s+exists\s+)?public\.(\w+)", clean, re.IGNORECASE):
        tables.discard(m.group(1))

    return set(rpcs.keys()), tables


def extract_doc_block(text: str, tag: str):
    m = re.search(r"<!--\s*API-CONTRACT:" + tag + r"\s*\n(.*?)-->", text, re.DOTALL)
    if m is None:
        return None
    return set(l.strip() for l in m.group(1).split("\n") if l.strip())


schema_rpcs, schema_tables = extract_schema(migrations_dir)

doc_text = pathlib.Path(api_md_path).read_text(encoding="utf-8")
doc_rpcs = extract_doc_block(doc_text, "RPC")
doc_tables = extract_doc_block(doc_text, "TABLES")

ok = True

if doc_rpcs is None:
    print(f"✗ api-contract gate：{api_md_path} 缺少 <!-- API-CONTRACT:RPC ... --> 區塊", file=sys.stderr)
    ok = False
if doc_tables is None:
    print(f"✗ api-contract gate：{api_md_path} 缺少 <!-- API-CONTRACT:TABLES ... --> 區塊", file=sys.stderr)
    ok = False
if not ok:
    sys.exit(1)

missing_rpc = schema_rpcs - doc_rpcs
ghost_rpc = doc_rpcs - schema_rpcs
if missing_rpc or ghost_rpc:
    ok = False
    print("✗ api-contract gate：RPC 清單對不上 docs/API.md 的 API-CONTRACT:RPC 區塊", file=sys.stderr)
    for s in sorted(missing_rpc):
        print(f"  - schema 有、文件沒有（漏寫）：{s}", file=sys.stderr)
    for s in sorted(ghost_rpc):
        print(f"  - 文件有、schema 沒有（幽靈 RPC）：{s}", file=sys.stderr)

missing_tables = schema_tables - doc_tables
ghost_tables = doc_tables - schema_tables
if missing_tables or ghost_tables:
    ok = False
    print("✗ api-contract gate：表清單對不上 docs/API.md 的 API-CONTRACT:TABLES 區塊", file=sys.stderr)
    for s in sorted(missing_tables):
        print(f"  - schema 有、文件沒有（漏寫）：{s}", file=sys.stderr)
    for s in sorted(ghost_tables):
        print(f"  - 文件有、schema 沒有（幽靈表）：{s}", file=sys.stderr)

if not ok:
    sys.exit(1)

print(f"✓ api-contract gate 通過：RPC {len(schema_rpcs)} 支、表 {len(schema_tables)} 張，docs/API.md 與 migrations 一致")
PY
