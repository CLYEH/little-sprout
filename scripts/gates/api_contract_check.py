#!/usr/bin/env python3
"""LS-41 API 契約對帳邏輯（PR #58 review 主修＋F1/F2/F5/F6，供 api-contract-check.sh 呼叫）。

兩種模式：
  --text <api_md> <migrations_dir>
      純文字解析 supabase/migrations/*.sql。本機 push-gate 用，best-effort，不需要
      跑起 DB。已知限制（catalog 模式沒有這些限制，因為它問的是套用完 migrations
      之後的真實 pg_catalog，不是重新剖析 SQL 原始碼）：
        - 動態 DDL：`execute 'create function public.x(...) ...'` 這種把 DDL **字面**寫在
          字串常值裡的寫法，純文字掃描一樣撈得到（regex 不分辨它在不在引號內）；只有
          用 `||` 拼接或 `format('%I')` 佔位組出名稱的**拼接式**動態 DDL 才解析不到，
          會被漏掉而不是報錯（LS-54 N7 更正：原註解籠統寫成「EXECUTE 動態 DDL 解析不到」）。
        - CREATE FUNCTION 的參數解析假設每個參數都有名稱前綴（本專案所有 migration
          目前皆如此）；若未來出現不具名參數用多字型別（如 `timestamp with time
          zone`），第一個字會被誤判成參數名。這種寫法本專案從未用過，是已知但目前
          不影響任何實際 migration 的限制。
        - 只認得 `--` 行內／獨立行註解，不處理 `/* */` 區塊註解（本專案未使用後者）。

  --catalog <api_md> <rpc_file> <table_file>
      比對呼叫端已用 psql 查出、寫進兩個檔案的活資料庫 pg_catalog 結果。CI db job
      用，是權威來源（已套用全部 migrations 的真實 schema，不受文字解析限制影響）。
      rpc_file 每行一筆 `name(p_x type, ...)`（來自 pg_get_function_identity_
      arguments；本機 supabase db reset 後實測澄清：這支函式其實**會**保留參數名，
      不是純型別列表——所以這裡沿用跟 CREATE FUNCTION 文字解析同一套「名稱＋型別」
      拆法，見下方 text_param_type）；table_file 每行一個表名。

兩種模式最終都呼叫同一個 compare_and_report()，對照 docs/API.md §9 的
<!-- API-CONTRACT:RPC/TABLES --> 區塊，任一邊多、任一邊少（含幽靈項）都 fail loud。

  --kotlin <api_md> <android_dir>        （LS-477，Android 前置 A3）
      掃 Android 呼叫端（`<android_dir>/**/*.kt`），把「client 實際會打的東西」對帳 docs/API.md——方向與
      Swift 側不同：Swift 側由 error-codes-check.sh 做三方集合相等（API.md §5 ↔ LSErrorCode ↔ migrations），
      這裡 Android 還沒有等價的「全碼列舉」型別，所以只擋**幽靈引用**（client 引用了契約裡不存在的東西）：
        (1) RPC：`rpc("name"`／`postgrest.rpc(\n "name"`／`rpc(function = "name"`——name 必須在 §9
            API-CONTRACT:RPC 區塊的函式名集合裡（只比名稱，不比參數型別：呼叫端參數是 JSON 物件，沒有 SQL 型別可比）。
            第一個引數不是字串字面值（變數／常數）→ fail loud，本掃描器不解析常數（要求呼叫處寫字面值，
            這樣 grep 一下就知道 client 打了哪些 RPC）。`fun rpc(` 這種定義不算呼叫。
        (2) 錯誤碼：程式碼（非註解）裡的 `"LSnnn"` 字串字面值必須在 §5 錯誤碼表的首欄集合裡。
      不掃 `build/`、`.gradle/`、`.kotlin/` 與 `test/`、`androidTest/`、`testFixtures/` 目錄（測試可刻意用假名稱示範
      「未知碼」fallback，不是 production 呼叫端）。註解（`//`、巢狀 `/* */`）內的提及不算。android/ 尚無任何呼叫端時
      兩個集合皆空 → 綠（印 0 支／0 個）。已知限制：字串模板 `${}` 內的巢狀引號、unicode 轉義拼出的名稱不解析。
"""
import re
import sys
import pathlib

MODE_KEYWORDS = {"in", "out", "inout", "variadic"}

# F2：型別別名——CREATE 用短別名寫、DROP／catalog 用 Postgres format_type() 的展開式
# 寫（例如 timestamptz 在 catalog 裡一律回報成 timestamp with time zone），兩邊必須
# 視為同一型別，否則 DROP 抵銷不了對應的 CREATE、catalog 模式也永遠對不上文件裡的
# 短寫法。全部正規化到左邊的短別名（與現有 docs/API.md 的寫法一致）。
TYPE_ALIASES = {
    "timestamp with time zone": "timestamptz",
    "character varying": "varchar",
    "int4": "integer",
    "int": "integer",
    "bool": "boolean",
}


def normalize_type(t: str) -> str:
    t = re.split(r"\bdefault\b", t.strip(), flags=re.IGNORECASE)[0]
    t = re.sub(r"\s+", " ", t).strip().lower()
    return TYPE_ALIASES.get(t, t)


def strip_mode_keyword(tokens):
    """F6：IN/OUT/INOUT/VARIADIC 是參數模式前綴，不是名稱也不是型別的一部分。
    LS-54 N1：OUT 參數整個丟掉（回傳 []）——它不是呼叫端要傳的東西，Postgres 的函式識別
    簽章（pg_get_function_identity_arguments，catalog 模式的來源）也不含它；文字模式若保留
    OUT，同一支函式在本機文字模式與 CI catalog 模式會算出不同簽章。IN/INOUT/VARIADIC 都是
    識別簽章的一部分，只剝掉關鍵字、保留後面的名稱＋型別。"""
    if tokens and tokens[0].lower() == "out":
        return []
    if tokens and tokens[0].lower() in MODE_KEYWORDS:
        return tokens[1:]
    return tokens


def split_top_level(s: str):
    """依『深度為 0 的逗號』切參數列，型別本身若帶括號（如 numeric(10,2)）不會被誤切。"""
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


def text_param_type(piece: str):
    """CREATE FUNCTION 的參數列來源是『p_x uuid』這種名稱＋型別——扣掉 mode 前綴後，
    第一個 token 是參數名，其餘（可能多字，如 timestamp with time zone）合起來是型別。"""
    tokens = strip_mode_keyword(piece.split())
    if len(tokens) >= 2:
        return normalize_type(" ".join(tokens[1:]))
    if len(tokens) == 1:
        return normalize_type(tokens[0])
    return None


def bare_param_type(piece: str):
    """DROP FUNCTION 的參數列、以及 pg_get_function_identity_arguments 的輸出都
    只有型別、沒有參數名——扣掉 mode 前綴之後剩下的『整段』就是型別本身，不能像
    text_param_type 那樣拆第一個字當名稱，否則 'timestamp with time zone' 這種
    多字型別會被誤判成有名稱（第一個字被錯當參數名）。"""
    tokens = strip_mode_keyword(piece.split())
    return normalize_type(" ".join(tokens)) if tokens else None


def text_param_types(params_raw: str):
    return [t for t in (text_param_type(p) for p in split_top_level(params_raw) if p.strip()) if t is not None]


def bare_param_types(params_raw: str):
    return [t for t in (bare_param_type(p) for p in split_top_level(params_raw) if p.strip()) if t is not None]


def blank_sql_comments(sql: str) -> str:
    """用等長空白蓋掉 `--` 之後到行尾的內容，刻意保留原始字元位移（offset）不變——
    這樣才能拿同一組 offset 回頭查『原始文字』的同一段範圍有沒有 `--`
    （F5：簽章括號區間內混進行內註解時要 fail loud，不是靜默相信『註解一律獨立成行』
    這個曾經錯過一次的假設——storage_policies.sql 就有反例，見該檔案 insert into
    storage.buckets 那段的行內註解）。"""
    out = []
    for line in sql.split("\n"):
        idx = line.find("--")
        out.append(line[:idx] + " " * (len(line) - idx) if idx >= 0 else line)
    return "\n".join(out)


def extract_paren_block(text: str, start_after: int):
    """start_after 指向『已消耗的開頭 (』之後那個字元；回傳括號內文字的 [start, end) 範圍。"""
    depth, i = 1, start_after
    while i < len(text) and depth > 0:
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
        i += 1
    return start_after, i - 1


def line_of(text: str, pos: int) -> int:
    return text[:pos].count("\n") + 1


def extract_schema_from_text(migrations_dir: str):
    files = sorted(pathlib.Path(migrations_dir).glob("*.sql"))
    if not files:
        print(f"✗ api-contract gate：{migrations_dir} 底下沒有任何 .sql 檔", file=sys.stderr)
        sys.exit(1)

    raw = "\n".join(f.read_text(encoding="utf-8") for f in files)
    clean = blank_sql_comments(raw)  # 與 raw 等長、offset 一致，只是註解變空白

    rpcs = {}
    tables = set()

    # LS-121：CREATE／DROP 依「文字中出現的先後位置」排序成單一序列後依序重播，
    # 不是「先蒐集全部 CREATE、再套用全部 DROP」兩個獨立批次——批次模式下，DROP
    # 永遠贏過同一批次裡的任何 CREATE，不管 CREATE 實際上出現在 DROP 之前還是
    # 之後。這對「同一支（或稍後一支）migration 內 DROP 舊簽名、CREATE 回完全
    # 相同簽名」這種合法寫法會誤判成「這支 RPC 已經不存在」——Postgres 的
    # `CREATE OR REPLACE FUNCTION` 不允許改變回傳型別（例如 `RETURNS TABLE(...)`
    # 的欄位改名／改型別），只能先 DROP 再重建，但簽章（參數型別列表）常常維持
    # 不變，此時批次模式看到的就是「同一個簽章又 CREATE 又 DROP」，取的是 DROP
    # 贏。改成單一時間序重播後，DROP 之後若真的又出現一次同簽名 CREATE，會正確地
    # 把它加回去；「CREATE 之後 DROP、之後沒有再 CREATE」則正確地移除——跟原本
    # 批次模式在「沒有位置反轉」的一般情況下行為完全相同，見
    # `scripts/gates/api-contract-check.test.sh` ①-⑫ 沿用原始 fixture 不動、
    # ⑬ 是本次新增的專屬案例。
    events = []
    for m in re.finditer(r"create\s+table\s+(?:if\s+not\s+exists\s+)?([A-Za-z_][\w.]*)\s*\(", clean, re.IGNORECASE):
        events.append((m.start(), "create_table", m))
    for m in re.finditer(r"create\s+(?:or\s+replace\s+)?function\s+([A-Za-z_][\w.]*)\s*\(", clean, re.IGNORECASE):
        events.append((m.start(), "create_function", m))
    for m in re.finditer(r"drop\s+function\s+(?:if\s+exists\s+)?([A-Za-z_][\w.]*)", clean, re.IGNORECASE):
        events.append((m.start(), "drop_function", m))
    for m in re.finditer(r"drop\s+table\s+(?:if\s+exists\s+)?([A-Za-z_][\w.]*)", clean, re.IGNORECASE):
        events.append((m.start(), "drop_table", m))
    # LS-205（LS-96 池項 ca99c6ae i1）：view 跟表一樣是 PostgREST 讀得到的 API 表面（第一支是
    # album_summaries），一併納入同一份 tables 集合對帳。CREATE VIEW 名稱後不一定緊接 `(`——
    # album_summaries 是 `create view public.album_summaries with (security_invoker = true) as
    # select ...`，欄位列表也可能整個省略——所以這裡跟 create_table／create_function 不同，只抓到
    # 名稱就收工，不要求後面接括號。
    for m in re.finditer(r"create\s+(?:or\s+replace\s+)?view\s+([A-Za-z_][\w.]*)", clean, re.IGNORECASE):
        events.append((m.start(), "create_view", m))
    for m in re.finditer(r"drop\s+view\s+(?:if\s+exists\s+)?([A-Za-z_][\w.]*)", clean, re.IGNORECASE):
        events.append((m.start(), "drop_view", m))
    events.sort(key=lambda e: e[0])

    for _, kind, m in events:
        target = m.group(1)
        lname = target.lower()

        if kind in ("create_table", "create_function", "create_view"):
            if lname.startswith("private."):
                continue  # 刻意不對外的 schema，不算 API 表面，略過不追蹤
            if not lname.startswith("public."):
                # F1：沒有 schema 限定前綴的宣告 fail loud，不能悄悄漏掉一支 RPC／表／view
                ln = line_of(raw, m.start())
                keyword_label = {"create_function": "函式", "create_table": "資料表", "create_view": "view"}[kind]
                print(
                    f"✗ api-contract gate：第 {ln} 行附近有一個沒有 schema 限定前綴的"
                    f"{keyword_label}宣告「{target}」——必須明確寫成 public.xxx 或"
                    f" private.xxx，否則本檢查器可能悄悄漏掉一支 RPC／表而不自知",
                    file=sys.stderr,
                )
                sys.exit(1)
            name = lname.split(".", 1)[1]
            if kind == "create_function":
                start, end = extract_paren_block(clean, m.end())
                if "--" in raw[start:end]:
                    # F5：簽章括號區間內混進行內註解——本文字解析器無法保證安全處理，
                    # 寧可 fail loud 也不要悄悄解析錯（storage_policies.sql 已有
                    # 行內註解的先例，不能再假設『註解一律獨立成行』）
                    ln = line_of(raw, start)
                    print(
                        f"✗ api-contract gate：第 {ln} 行附近 {target} 的參數列裡"
                        f"偵測到 `--`——本文字解析器無法安全處理簽章括號內夾雜的行內"
                        f"註解，請把註解移到 create function 那行之前（參數列括號外——括號區間內"
                        f"不論獨立行或行尾都會被判定），或改用 --catalog 模式驗證",
                        file=sys.stderr,
                    )
                    sys.exit(1)
                sig = f"{name}({', '.join(text_param_types(clean[start:end]))})"
                rpcs[sig] = True
            else:
                tables.add(name)

        elif kind == "drop_function":
            # F1 的 fail-loud 只要求對 CREATE 適用；DROP 維持既有寬鬆行為，只處理
            # public.* 的 drop（private./未限定的 drop 不影響追蹤中的 API 表面）。
            if not lname.startswith("public."):
                continue
            name = lname.split(".", 1)[1]
            rest = clean[m.end():]
            stripped = rest.lstrip()
            if stripped.startswith("("):
                # 有明確參數列：本解析器把 DROP FUNCTION 的參數列一律當成「只有型別、
                # 沒有參數名」（Postgres 的 DROP FUNCTION 語法技術上兩種寫法都合法，
                # 但只有型別才是慣例寫法，也是本專案若真的寫 DROP FUNCTION 時預期的
                # 風格——只列型別才符合「DROP 只需要型別就能識別 overload」的語意）。
                # 已知限制：若手動在 DROP FUNCTION 裡也寫了參數名（例如
                # `drop function public.foo(a text)`），第一個字會被誤判成型別的一部分
                # 而配對失敗。
                paren_open = m.end() + (len(rest) - len(stripped))
                start, end = extract_paren_block(clean, paren_open + 1)
                sig = f"{name}({', '.join(bare_param_types(clean[start:end]))})"
                rpcs.pop(sig, None)
            else:
                # F2：無參數列的 DROP FUNCTION 只在該名稱當下唯一（不 overload）時
                # Postgres 才會放行——不去猜是哪一個，把重播到此刻為止追蹤到的同名
                # overload 全部移除，這是不會漏刪、且與「無括號 drop 本來就要求唯一」
                # 語意一致的做法。
                for sig in [s for s in rpcs if s.startswith(name + "(")]:
                    rpcs.pop(sig, None)

        elif kind in ("drop_table", "drop_view"):
            if lname.startswith("public."):
                tables.discard(lname.split(".", 1)[1])

    return set(rpcs.keys()), tables


def require_lowercase(name: str, label: str) -> str:
    """LS-54 N3：catalog 回報的是真實名稱——未加引號的識別字 Postgres 已經折成小寫，
    所以這裡出現大寫只可能是 `"Widgets"` 這種引號識別字。原本一律 .lower() 會讓
    public.widgets 與 public."Widgets" 塌成同一個名字、靜默逃過對帳；本專案不用引號
    識別字，出現就是異常，fail loud 而不是悄悄正規化。"""
    if name != name.lower():
        print(
            f"✗ api-contract gate（catalog 模式）：{label}名稱「{name}」含大寫——本專案不使用"
            f"引號識別字，catalog 出現大寫名稱代表 schema 裡混進了 \"Quoted\" 識別字；本檢查器"
            f"不做大小寫正規化（會讓 widgets 與 \"Widgets\" 塌成同一項），請修正 migration",
            file=sys.stderr,
        )
        sys.exit(1)
    return name


def extract_schema_from_catalog(rpc_file: str, table_file: str):
    # 實測澄清（本機 supabase db reset 後對 pg_get_function_identity_arguments 的
    # 真實輸出）：與一開始從 Postgres 文件推斷的不同，這支函式**會**保留參數名
    # （例如回傳 "p_family_id uuid, p_role text, ..."），不是純型別列表——所以這裡
    # 跟 CREATE FUNCTION 文字解析用同一支 text_param_type（名稱＋型別），不是
    # bare_param_type。零參數函式回傳空字串，split_top_level("") 正確給出 []。
    rpcs = set()
    for line in pathlib.Path(rpc_file).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        paren = line.index("(")
        name = require_lowercase(line[:paren].strip(), "RPC")
        args_str = line[paren + 1 : -1]  # 我們自己下的 SQL 保證最後一個字元就是對應的 ')'
        rpcs.add(f"{name}({', '.join(text_param_types(args_str))})")

    tables = set(
        require_lowercase(line.strip(), "資料表")
        for line in pathlib.Path(table_file).read_text(encoding="utf-8").splitlines()
        if line.strip()
    )
    return rpcs, tables


def extract_doc_block(text: str, tag: str):
    m = re.search(r"<!--\s*API-CONTRACT:" + tag + r"\s*\n(.*?)-->", text, re.DOTALL)
    if m is None:
        return None
    return set(l.strip() for l in m.group(1).split("\n") if l.strip())


def compare_and_report(schema_rpcs, schema_tables, api_md_path, mode_label):
    doc_text = pathlib.Path(api_md_path).read_text(encoding="utf-8")
    doc_rpcs = extract_doc_block(doc_text, "RPC")
    doc_tables = extract_doc_block(doc_text, "TABLES")

    ok = True
    if doc_rpcs is None:
        print(f"✗ api-contract gate（{mode_label}）：{api_md_path} 缺少 <!-- API-CONTRACT:RPC ... --> 區塊", file=sys.stderr)
        ok = False
    if doc_tables is None:
        print(f"✗ api-contract gate（{mode_label}）：{api_md_path} 缺少 <!-- API-CONTRACT:TABLES ... --> 區塊", file=sys.stderr)
        ok = False
    if not ok:
        sys.exit(1)

    missing_rpc = schema_rpcs - doc_rpcs
    ghost_rpc = doc_rpcs - schema_rpcs
    if missing_rpc or ghost_rpc:
        ok = False
        print(f"✗ api-contract gate（{mode_label}）：RPC 清單對不上 docs/API.md 的 API-CONTRACT:RPC 區塊", file=sys.stderr)
        for s in sorted(missing_rpc):
            print(f"  - schema 有、文件沒有（漏寫）：{s}", file=sys.stderr)
        for s in sorted(ghost_rpc):
            print(f"  - 文件有、schema 沒有（幽靈 RPC）：{s}", file=sys.stderr)

    missing_tables = schema_tables - doc_tables
    ghost_tables = doc_tables - schema_tables
    if missing_tables or ghost_tables:
        ok = False
        print(f"✗ api-contract gate（{mode_label}）：表清單對不上 docs/API.md 的 API-CONTRACT:TABLES 區塊", file=sys.stderr)
        for s in sorted(missing_tables):
            print(f"  - schema 有、文件沒有（漏寫）：{s}", file=sys.stderr)
        for s in sorted(ghost_tables):
            print(f"  - 文件有、schema 沒有（幽靈表）：{s}", file=sys.stderr)

    if not ok:
        sys.exit(1)

    print(f"✓ api-contract gate（{mode_label}）通過：RPC {len(schema_rpcs)} 支、表 {len(schema_tables)} 張，docs/API.md 與 schema 一致")

KOTLIN_SKIP_DIRS = {"build", ".gradle", ".kotlin", ".idea", "test", "androidTest", "testFixtures"}


def strip_kotlin_comments(src: str) -> str:
    """把 Kotlin 註解（`//` 行註解、可巢狀的 `/* */`）換成等長空白（換行保留，行號不變）；字串字面值
    （含 `\"` 轉義、`\"\"\"` raw string）與字元字面值內容原樣保留——`"//"` 或 `"LS001 /* x */"` 不會被誤當註解。"""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        two = src[i:i + 2]
        if two == "//":
            j = src.find("\n", i)
            j = n if j == -1 else j
            out.append(" " * (j - i))
            i = j
        elif two == "/*":
            depth, j = 1, i + 2
            while j < n and depth > 0:
                if src.startswith("/*", j):
                    depth += 1
                    j += 2
                elif src.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            out.append("".join(ch if ch == "\n" else " " for ch in src[i:j]))
            i = j
        elif src.startswith('"""', i):
            j = src.find('"""', i + 3)
            j = n if j == -1 else j + 3
            out.append(src[i:j])
            i = j
        elif c == '"':
            j = i + 1
            while j < n and src[j] != '"' and src[j] != "\n":
                j += 2 if src[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(src[i:j])
            i = j
        elif c == "'":
            j = i + 1
            while j < n and src[j] != "'" and src[j] != "\n":
                j += 2 if src[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(src[i:j])
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


KOTLIN_RPC_CALL_RE = re.compile(r"(?<![\w])rpc\s*\(\s*(?:function\s*=\s*)?(\"[^\"\n]*\"|[^\s)][^\n]{0,40})")
KOTLIN_CODE_RE = re.compile(r'"(LS\d{3})"')


def kotlin_files(android_dir: str):
    root = pathlib.Path(android_dir)
    for f in sorted(root.rglob("*.kt")):
        rel_parts = f.relative_to(root).parts[:-1]
        if any(part in KOTLIN_SKIP_DIRS for part in rel_parts):
            continue
        yield f


def extract_kotlin_usage(android_dir: str):
    """回傳 (rpc_calls, unresolved, codes, file_count)：rpc_calls／codes 是 {名稱: [(檔, 行)]}，unresolved 是
    [(檔, 行, 片段)]（`rpc(` 的第一個引數不是字串字面值）。"""
    rpc_calls, codes, unresolved = {}, {}, []
    count = 0
    for f in kotlin_files(android_dir):
        count += 1
        raw = f.read_text(encoding="utf-8", errors="replace")
        clean = strip_kotlin_comments(raw)
        for m in KOTLIN_RPC_CALL_RE.finditer(clean):
            # `fun rpc(` 是定義、不是呼叫
            if re.search(r"\bfun\s+(?:[\w.<>]+\.)?$", clean[max(0, m.start() - 60):m.start()]):
                continue
            arg = m.group(1)
            ln = line_of(clean, m.start())
            if arg.startswith('"') and arg.endswith('"') and len(arg) >= 2:
                rpc_calls.setdefault(arg[1:-1], []).append((str(f), ln))
            else:
                unresolved.append((str(f), ln, arg.strip()))
        for m in KOTLIN_CODE_RE.finditer(clean):
            codes.setdefault(m.group(1), []).append((str(f), line_of(clean, m.start())))
    return rpc_calls, unresolved, codes, count


def doc_error_codes(api_md_path: str):
    """docs/API.md §5（`## 5.` 到下一個 `## `）表格列首欄的 `LSnnn`——同 error-codes-check.sh 的抽取規則。"""
    text = pathlib.Path(api_md_path).read_text(encoding="utf-8")
    codes, in_s5 = set(), False
    for line in text.split("\n"):
        if re.match(r"^## 5\. ", line):
            in_s5 = True
            continue
        if line.startswith("## "):
            in_s5 = False
        if in_s5 and line.lstrip().startswith("|"):
            cols = line.split("|")
            if len(cols) > 2:
                m = re.match(r"^\s*`(LS\d{3})`", cols[1])
                if m:
                    codes.add(m.group(1))
    return codes


def kotlin_scan(api_md_path: str, android_dir: str):
    doc_text = pathlib.Path(api_md_path).read_text(encoding="utf-8")
    doc_rpcs = extract_doc_block(doc_text, "RPC")
    if doc_rpcs is None:
        print(f"✗ api-contract gate（Kotlin 掃描器）：{api_md_path} 缺少 <!-- API-CONTRACT:RPC ... --> 區塊", file=sys.stderr)
        sys.exit(1)
    doc_rpc_names = {r.split("(", 1)[0] for r in doc_rpcs}
    doc_codes = doc_error_codes(api_md_path)
    if not doc_codes:
        print(f"✗ api-contract gate（Kotlin 掃描器）：{api_md_path} §5 表格抽不到任何首欄 `LSnnn`——節名或格式改了？", file=sys.stderr)
        sys.exit(1)
    if not pathlib.Path(android_dir).is_dir():
        print(f"✗ api-contract gate（Kotlin 掃描器）：找不到 {android_dir}", file=sys.stderr)
        sys.exit(1)
    rpc_calls, unresolved, codes, count = extract_kotlin_usage(android_dir)

    ok = True
    ghost_rpc = sorted(set(rpc_calls) - doc_rpc_names)
    if ghost_rpc:
        ok = False
        print("✗ api-contract gate（Kotlin 掃描器）：Android 呼叫了 docs/API.md §9 沒有的 RPC（幽靈呼叫——改名／下架／打錯字，或契約文件漏寫）", file=sys.stderr)
        for name in ghost_rpc:
            for f, ln in rpc_calls[name]:
                print(f"  - {name}  @ {f}:{ln}", file=sys.stderr)
    ghost_codes = sorted(set(codes) - doc_codes)
    if ghost_codes:
        ok = False
        print("✗ api-contract gate（Kotlin 掃描器）：Android 引用了 docs/API.md §5 沒有的錯誤碼（幽靈碼——後端不會丟，或文件漏寫）", file=sys.stderr)
        for code in ghost_codes:
            for f, ln in codes[code]:
                print(f"  - {code}  @ {f}:{ln}", file=sys.stderr)
    if unresolved:
        ok = False
        print("✗ api-contract gate（Kotlin 掃描器）：`rpc(` 的第一個引數不是字串字面值，本掃描器不解析變數／常數（請在呼叫處直接寫 rpc(\"name\") 或 rpc(function = \"name\")）", file=sys.stderr)
        for f, ln, frag in unresolved:
            print(f"  - {f}:{ln}  rpc({frag}…", file=sys.stderr)
    if not ok:
        sys.exit(1)
    print(
        f"✓ api-contract gate（Kotlin 掃描器）通過：掃 {count} 個 .kt 檔，RPC 呼叫 {len(rpc_calls)} 支"
        f"（全在 docs/API.md §9）、錯誤碼常數 {len(codes)} 個（全在 §5）"
    )


def main(argv):
    if len(argv) < 2:
        print(
            "用法：api_contract_check.py --text <api_md> <migrations_dir> | "
            "--catalog <api_md> <rpc_file> <table_file> | --kotlin <api_md> <android_dir>",
            file=sys.stderr,
        )
        sys.exit(2)
    mode = argv[0]
    if mode == "--text":
        api_md, migrations_dir = argv[1], argv[2]
        schema_rpcs, schema_tables = extract_schema_from_text(migrations_dir)
        compare_and_report(schema_rpcs, schema_tables, api_md, "text 模式／best-effort")
    elif mode == "--catalog":
        api_md, rpc_file, table_file = argv[1], argv[2], argv[3]
        schema_rpcs, schema_tables = extract_schema_from_catalog(rpc_file, table_file)
        compare_and_report(schema_rpcs, schema_tables, api_md, "catalog 模式／權威")
    elif mode == "--kotlin":
        if len(argv) < 3:
            print("用法：api_contract_check.py --kotlin <api_md> <android_dir>", file=sys.stderr)
            sys.exit(2)
        kotlin_scan(argv[1], argv[2])
    else:
        print(f"未知模式：{mode}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv[1:])
