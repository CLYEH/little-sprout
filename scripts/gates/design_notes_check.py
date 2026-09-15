#!/usr/bin/env python3
"""LS-168 設計稿 Notes 板節點 id 存在性 gate（供 design-notes-check.sh 呼叫）。

為什麼：LS-142 的 Notes 板「數字／id 落後最後一次改稿」五度復發（R3／R4／R5／R6 後 merge-review c51f982f 又抓到
4 個死節點 id：Agczg 段的 Q8xZl9／s4VXMV、oYEi0 段現在式的 C0GuD／CVOkb），全靠 reviewer 人工掃 Notes 才抓到。
「引用的節點 id 是否還存在於稿內」可機械驗，這支就驗這一件事。

判定方式（沿用 merge-review c51f982f 的死 id 掃描做法，不是「反引號包住的 token」——實測 LS-142 kHDk4／LS-152 b3nzDp
兩塊 Notes 板 0 個反引號，id 一律裸寫，如「詳見 EBlnw」「原 Q8xZl9/s4VXMV」；只抓反引號會在正是本票要抓的板上掃到 0）：
  1. Notes 板＝頂層 frame 名稱含「實作註記」或「Handoff Notes」。
  2. 從 Notes 板所有 text 節點的 content 抽出「id 形」裸 token：`[A-Za-z0-9]{5,6}`、兩側不接英數、非純數字
     （Pencil id 5–6 碼英數，實測稿內 7746 個 id 長度分佈 5:6539／6:1207，含全小寫 vrqoe、全大寫 CCMAE、首大寫 Bdnlp）。
  3. 只把「曾經是稿內節點 id、head 已不存在」的 token 算死 id：候選集＝merge-base 快照 ∪ 本 PR 範圍內每個觸碰 .pen 的
     commit 快照的 id 全集 − head 快照 id 全集。形狀相同的英文字（height／false／Layout／Stress……LS-21 Notes yec61 實測
     10 個）從來不是 id、不會被誤判；別票早在 merge-base 之前就刪掉的舊債（yec61 的 wnBM1／y6JCGh）也不在候選集內、
     不擋本票（a106f940 同一原則：他票舊債另開 chore）。代價：本 PR 同一個 commit 內建又刪的 id、與從未存在過的打字錯
     id 抓不到——盲區明寫在 design-notes-check.sh 檔頭。
  4. 沿革標記白名單（LS-142 R7 慣例，merge-review R2 f26cdb44 認可的寫法）：死 id 所在**子句**（以 。；;\\n，, 切）含任一
     HISTORY_MARKERS 即視為沿革敘述、不算缺失（印成 info 行）。用子句而非整句，是因為 oYEi0 段「（原 Q8xZl9/s4VXMV）…
     新 id 為 C0GuD」整句含「原」、但「新 id 為 C0GuD」這個子句是現在式活指標——merge-review R1 MN-N5 就是這一筆，整句
     白名單會漏掉它（LS-142 R6 head 8cd2359 實測）。
  5. `→` 不是子句級標記（merge-review R1 N3：development 4 塊 Notes 板 216 個箭頭幾乎全是數字轉場「1134→1031」，子句級 `→`
     讓 60 個活 id 引用位置預先被放行、方向是誤放行）：只有死 id **緊鄰箭頭左側**（`<id>\\s*→`，「舊→新」的舊）才算沿革；
     右側是現行 id，必須存在（死了就是缺失）。

署名年齡片語 NBSP（LS-202；LS-96 池項 ed90c6ab）：Notes 規則「署名年齡片語必 NBSP」原本沒有 gate，LS-194 BL-1 是 VR 逐字比 codepoint
才抓到。這支順便驗：`cmp/Card Album`／`cmp/Card Diary` 兩個元件定義內的 text 節點，與全稿每個 ref 指向它們的實例的 `descendants`
`content` 覆寫，凡 `歲`／`個月`（`個` `月` 之間允許 WJ）**前面的空白序列**只准 U+00A0／U+2060／換行——序列含 U+0020 即命中，印節點
（或 實例 id／override 鍵）與 codepoint 序列。範圍只到這兩個元件：全稿 text 一律掃會把 Notes 板的散文（yec61 16 筆、kHDk4 11 筆）與
LS-21／LS-47 legacy 板的舊 Age Text 全數帶進來（development 實測 88 筆）。**--base 增量**：命中所在的頂層節點（板或元件定義）在
merge-base→head 之間 JSON 有變更（含新增）才算違規（紅）；未觸碰的板上的既有命中列「（舊債）」警告、不擋——他票舊債另開 chore
（a106f940 同一原則）。代價：觸碰某板就得順手修掉它上面所有署名 U+0020（方向是紅、不是漏放）。

畫面級屬性清單（LS-300；LS-96 池項 3aa46c78）：LS-125／126 QA 視覺 FAIL 四項全是「稿有、實作漏」——推入式畫面隱藏 Tab Bar、
Tab-root 只用自訂標題、失敗文案分支，設計稿 Notes 板有寫、ios-dev 沒逐條對。這支順便驗：本 PR 新增的**畫面板**（頂層 frame，
名稱形如「<群組> / <編號或名稱>」——`SCREEN_BOARD_NAME_RE`，排除 Notes 板本身與 `cmp/` 元件定義）在 head 快照裡，是否每一個**正典畫面**
都能在 Notes 板文字裡找到一列（`SCREEN_ATTR_HEADING_RE` 命中「畫面級屬性」之後的文字範圍內，以**任一變體板名子字串**比對——不驗欄位
內容完不完整，只驗「這個正典畫面有沒有被提到」，欄位規格見 `docs/COLLABORATION.md` §1／`.claude/agents/ui-designer.md`）。新增＝id 不在
base（merge-base）快照裡（同 NBSP 的 `touched_roots` 判斷新增/變更，這裡只取「新增」）。

**R2（merge-review R1 M1）正典畫面歸併**：深色／AX3／iPad（含編號後綴 `-iPad`）這類同一畫面的裝置／外觀變體，原版把每個變體板各自
當一塊「新畫面板」，對 LS-251 分支（六畫面、實測 30 個新增板）逼出 30 行缺列——但票文「畫面級屬性」欄位本身就含「深色特例」「AX3
特例」「iPad 重排 vs 放大」，設計意圖是**一個畫面一行、深色/AX3/iPad 差異記在該行的欄位裡**，不是要求每個變體各自成行。`canonicalize_screen_name()`
把板名去掉群組前綴（`A11y`／`Stress` 這類衍生群組與其對應的基準群組同編號即視為同一正典畫面）與已知裝飾字樣（`DERIVED_SUFFIX_RE`：
` · 深色`、` · Dynamic Type AX3（…）`、編號後綴 `-iPad`、`(iPhone)`／`(iPad …)`／`（不裁切）` 這類裝置註記）後算出 canonical_id——有
板編號（`[0-9]+[A-Za-z]?`，如 `01`／`04b`／`06a`）的畫面只取編號本身當 id（忽略其餘描述文字），沒有編號的名稱型畫面則退回去裝飾後的
描述文字當 id（LS-251 實測：30 個變體板 → 8 個正典畫面 `01／02／03／04／04b／05／06a／06b`，與 merge-review R1 M1 預期一致）。
`new_screen_boards()` 回傳正典畫面群組（含全部 member 變體），`screen_attr_missing()` 對每個正典畫面只要**任一** member 的完整板名
出現在「畫面級屬性」段之後即算放行（member 越多、放行條件越寬鬆，不是越嚴格——這是刻意的，見下方）。Notes 板完全沒有「畫面級屬性」
段 → 所有正典畫面全部列為缺失；段落存在但某正典畫面的所有 member 都沒被提到 → 只列該正典畫面（訊息印 canonical_id＋代表描述文字＋
全部 member 板 id，方便回頭對應稿內哪些板）。

輸出：每筆缺失一行「✗ 板 <rootId>（名稱）／節點 <textId>／缺失 id <token>：<子句>」；沿革 info 行以「（沿革）」開頭；署名 NBSP
違規一行「✗ 署名 NBSP：板 …／節點|實例 …：「<內容>」<單位> 前 <codepoints>」、舊債以「（舊債）署名 NBSP：」開頭；畫面級屬性缺列
一行「✗ 畫面級屬性缺列：正典畫面 <canonical_id>（<代表描述文字>；板 id：<member id 逗號列>）——Notes 未含「畫面級屬性」段，或段內
未提及任一變體名稱」；
最後一行摘要。exit 0＝無缺失且無 NBSP／畫面級屬性違規；1＝有缺失或違規；2＝參數／git／JSON 錯誤（fail closed）。

用法：design_notes_check.py --pen <repo 相對路徑> --head <sha> --base <merge-base sha> [--history <sha> ...]
  --head／--base／--history 皆以 `git show <sha>:<pen>` 讀快照（在 repo 內執行）；--history 為本 PR 範圍內觸碰 .pen 的
  commit（不含 head 亦可，重複無妨）。design-notes-check.sh 負責算這些 sha，本檔只做判定。
"""
import json
import re
import subprocess
import sys

# LS-202：本模組若再 import 同目錄模組，不得在 scripts/gates/ 留 __pycache__（worktree dirty、cleanup 需 --force，LS-96 c4c10429）；
# 自己被 import 時的 .pyc 由 .gitignore `__pycache__/` 兜底（模組內的旗標擋不住「被別人 import」那一次）
sys.dont_write_bytecode = True

ID_TOKEN_RE = re.compile(r"(?<![A-Za-z0-9])[A-Za-z0-9]{5,6}(?![A-Za-z0-9])")
NOTES_NAME_RE = re.compile(r"實作註記|Handoff Notes")
CLAUSE_SPLIT_RE = re.compile(r"[。；;\n，,]")
# 沿革標記（子句級）。「原」排除「原因」；「刪」限「刪 X」「已刪除」「刪除重建」「刪除舊」這幾種寫法，避免 LS-152 Notes 大量
# 「刪除帳號」流程敘述把同子句的活指標整個放行。`→` 不在此表（R1 N3）：改由 ARROW_AFTER_RE 只放行緊鄰箭頭左側的 id。
HISTORY_MARKERS = (
    r"已刪除", r"刪除重建", r"刪除舊", r"刪 ", r"原(?!因)", r"當時", r"已被", r"取代", r"舊", r"重建", r"曾",
    r"不存在", r"已改", r"已於",
)
HISTORY_RE = re.compile("|".join(HISTORY_MARKERS))
# 「舊 id→新 id」：token 之後緊接（可有空白）箭頭 → 這個 token 是被取代的舊 id
ARROW_AFTER_RE = re.compile(r"\s*→")
# LS-202 署名年齡片語：單位（歲／個月，個月中間允許 WJ）前的空白序列只准 NBSP／WJ／換行；序列含 U+0020 即違規
CARD_COMPONENT_NAMES = ("cmp/Card Album", "cmp/Card Diary")
AGE_UNIT_RE = re.compile("([  ⁠\n]+)(歲|個⁠?月)")
SPACE = " "
# LS-300：新增畫面板的名稱形狀「<群組> / <編號或名稱>」（如 `Import / 01 匯入整理頁 (iPhone)`）；
# Notes 板本身的名稱（如 `Import / 實作註記 · Handoff Notes (ios-dev)`）也含「/」，必須先過
# NOTES_NAME_RE 排除；`cmp/` 開頭的元件定義另外排除。字元類別故意寬鬆（只要求「/」左右各至少一個
# 非空白字元），不窄化到特定群組字面（「Import」「Growth」……）——票文字面只給範例，不是列舉。
SCREEN_BOARD_NAME_RE = re.compile(r"^\S[^/]*/\s*\S")
SCREEN_ATTR_HEADING_RE = re.compile(r"畫面級屬性")
# LS-300 R2（merge-review R1 M1）：正典畫面歸併——深色／AX3／iPad 等衍生變體去掉這些裝飾字樣後視為同一正典畫面
# （見 canonicalize_screen_name）。裝飾樣式：編號後綴 `-iPad`（如 `01-iPad`）、`· 深色`、`· Dynamic Type AX3（…）`
# （AX3 字級附註內容不定，用 `[^）]*` 吃掉整個全形括號）、裝置註記 `(iPhone)`／`(iPad …)`（半形括號、內容不定）、
# `（不裁切）`（全形括號，LS-251 iPad 板慣用附註）。`Stress`／`A11y` 這類衍生「群組」（頂層前綴，如 `A11y / 01 …`）
# 不在這支正則裡處理——群組前綴在 `canonicalize_screen_name` 直接整段丟棄（只留「/」之後的文字），與基準群組同編號
# 自然歸併，不需要另外列出群組名稱字面（避免每加一種新衍生群組名稱就要回頭補正則）。
DERIVED_SUFFIX_RE = re.compile(
    r"-iPad\b"
    r"|[·‧]\s*深色"
    r"|[·‧]\s*Dynamic Type AX3（[^）]*）"
    r"|\(iPhone\)"
    r"|\(iPad[^)]*\)"
    r"|（不裁切）"
)
# 板編號：開頭一到多位數字＋可選一個英文字母（`01`／`04b`／`06a`）。`(?:-\w+)?` 消耗但不擷取編號後綴（如 `-iPad`）——
# canonical_id 只取編號本身，`-iPad` 這類裝置後綴不影響分組。
BOARD_NUMBER_RE = re.compile(r"^([0-9]+[A-Za-z]?)(?:-\w+)?")


def die(msg):
    sys.stderr.write("✗ design_notes_check：%s\n" % msg)
    sys.exit(2)


def load_snapshot(sha, pen):
    r = subprocess.run(["git", "show", "%s:%s" % (sha, pen)], capture_output=True)
    if r.returncode != 0:
        die("git show %s:%s 失敗（%s）" % (sha[:7], pen, r.stderr.decode("utf-8", "replace").strip()))
    try:
        d = json.loads(r.stdout.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        die("%s:%s 不是合法 JSON（%s）" % (sha[:7], pen, exc))
    if not isinstance(d, dict) or not isinstance(d.get("children"), list):
        die("%s:%s 頂層不是 .pen 物件" % (sha[:7], pen))
    return d


def all_ids(doc):
    ids = set()
    stack = list(doc.get("children") or [])
    while stack:
        n = stack.pop()
        if isinstance(n, dict):
            if isinstance(n.get("id"), str):
                ids.add(n["id"])
            stack.extend(n.get("children") or [])
    return ids


def notes_boards(doc):
    return [r for r in doc.get("children") or [] if isinstance(r, dict) and NOTES_NAME_RE.search(r.get("name") or "")]


def text_nodes(root):
    out = []
    stack = [root]
    while stack:
        n = stack.pop()
        if not isinstance(n, dict):
            continue
        if n.get("type") == "text" and isinstance(n.get("content"), str):
            out.append(n)
        stack.extend(reversed(n.get("children") or []))
    return out


def clause_around(content, start, end):
    """含 token 的子句（切在 。；;\\n，, 之間），供沿革判定與訊息顯示。"""
    left = 0
    for m in CLAUSE_SPLIT_RE.finditer(content, 0, start):
        left = m.end()
    m = CLAUSE_SPLIT_RE.search(content, end)
    right = m.start() if m else len(content)
    return content[left:right].strip()


def card_components(doc):
    """cmp/Card Album／cmp/Card Diary 的元件定義（頂層 reusable frame，以名稱認——元件重建會換 id）。"""
    return [r for r in doc.get("children") or []
            if isinstance(r, dict) and r.get("reusable") and r.get("name") in CARD_COMPONENT_NAMES]


def age_hits(doc):
    """LS-202：回 [(root_id, root_name, owner, content, unit, codepoints)]——卡片元件定義內的 text，與全稿每個 ref → 卡片元件
    的實例 descendants content 覆寫，凡 歲／個月 前的空白序列含 U+0020 各一筆。owner＝「節點 <id>」或「實例 <refId> override <descId>」。"""
    comps = card_components(doc)
    comp_ids = {c["id"] for c in comps}
    hits = []

    def scan(content, root, owner):
        for m in AGE_UNIT_RE.finditer(content):
            run = m.group(1)
            if SPACE not in run:
                continue
            cps = "+".join("U+%04X" % ord(ch) for ch in run)
            hits.append((root["id"], root.get("name") or "", owner, content.replace("\n", "⏎"), m.group(2), cps))

    for c in comps:
        for t in text_nodes(c):
            scan(t["content"], c, "節點 %s" % t["id"])
    for root in doc.get("children") or []:
        stack = [root]
        while stack:
            n = stack.pop()
            if not isinstance(n, dict):
                continue
            if n.get("type") == "ref" and n.get("ref") in comp_ids:
                for key, ov in (n.get("descendants") or {}).items():
                    if isinstance(ov, dict) and isinstance(ov.get("content"), str):
                        scan(ov["content"], root, "實例 %s override %s" % (n.get("id"), key))
            stack.extend(reversed(n.get("children") or []))
    return hits


def touched_roots(base_doc, head_doc):
    """本 PR 觸碰的頂層節點 id：merge-base→head 之間 JSON 有變更或新增者（同 design-evidence-check.sh 的 boards 覆蓋判定）。"""
    def tops(doc):
        return {c["id"]: json.dumps(c, sort_keys=True, ensure_ascii=False)
                for c in doc.get("children") or [] if isinstance(c, dict) and isinstance(c.get("id"), str)}
    base_tops, head_tops = tops(base_doc), tops(head_doc)
    return {rid for rid, blob in head_tops.items() if base_tops.get(rid) != blob}


def canonicalize_screen_name(name):
    """LS-300 R2（merge-review R1 M1）：回傳 (canonical_id, display)。name 去掉群組前綴（第一個「/」之前的文字，
    含 `A11y`／`Stress` 這類衍生群組——與其對應的基準群組同編號即視為同一正典畫面）後：
      - 開頭是板編號（`BOARD_NUMBER_RE`，如 `01`／`04b`／`06a`）→ canonical_id 只取編號本身（忽略 `-iPad` 這類
        編號後綴與其餘描述文字／深色／AX3／裝置括號等裝飾），同編號的不同變體歸併成一個正典畫面。
      - 沒有編號（票文「<編號 或 名稱>」的名稱型畫面）→ canonical_id 退回去除已知裝飾字樣（`DERIVED_SUFFIX_RE`）
        後的描述文字本身。
    `display` 一律是去裝飾字樣、去頭尾空白、內部連續空白壓成一個空格的描述文字，供訊息與 Notes 代表列顯示。"""
    # DESIGN-NOTES-CANONICALIZE-CHECK
    _, _, rest = name.partition("/")
    rest = rest.strip()
    display = DERIVED_SUFFIX_RE.sub("", rest)
    display = re.sub(r"\s*[·‧]\s*$", "", display)
    display = re.sub(r"\s+", " ", display).strip()
    m = BOARD_NUMBER_RE.match(rest)
    if m:
        return "#" + m.group(1), display
    return "name:" + display, display


def new_screen_boards(base_doc, head_doc):
    """LS-300（R2，merge-review R1 M1）：本 PR 新增的**正典畫面**——head 快照裡符合 `SCREEN_BOARD_NAME_RE`（名稱
    形如「<群組> / <編號或名稱>」）、排除 Notes 板（`NOTES_NAME_RE`）與 `cmp/` 元件定義、且 id 不在 base
    （merge-base）快照裡的頂層節點，依 `canonicalize_screen_name()` 的 canonical_id 歸併——深色／AX3／iPad 等
    衍生變體不各自算一塊「新畫面板」。回傳 `[(canonical_id, display, [(id, name), ...]), ...]`：`display` 取該
    正典畫面第一個出現的 member 的描述文字，`members` 依 head 快照 children 順序（穩定輸出，方便訊息與 LS-251
    實跑核對）。"""
    base_ids = {c["id"] for c in base_doc.get("children") or [] if isinstance(c, dict) and isinstance(c.get("id"), str)}
    groups = {}
    order = []
    for c in head_doc.get("children") or []:
        if not isinstance(c, dict) or not isinstance(c.get("id"), str) or c["id"] in base_ids:
            continue
        name = c.get("name") or ""
        if NOTES_NAME_RE.search(name) or name.startswith("cmp/"):
            continue
        if not SCREEN_BOARD_NAME_RE.match(name):
            continue
        cid, display = canonicalize_screen_name(name)
        if cid not in groups:
            groups[cid] = {"display": display, "members": []}
            order.append(cid)
        groups[cid]["members"].append((c["id"], name))
    return [(cid, groups[cid]["display"], groups[cid]["members"]) for cid in order]


def screen_attr_missing(head_doc, canonical_boards):
    """LS-300（R2，merge-review R1 M1）：Notes 板文字裡「畫面級屬性」段（`SCREEN_ATTR_HEADING_RE` 首次命中之後的
    文字，跨全部 Notes 板、依 `notes_boards`／`text_nodes` 既有順序串接）是否提到每個正典畫面的**任一** member
    板名（子字串比對；member 越多、放行條件越寬鬆是刻意的——ui-designer 只要在 Notes 提到其中一個變體名稱，這個
    正典畫面就算有列，不必每個深色／AX3／iPad 變體各自出現）。段落完全不存在 → 全部正典畫面皆列為缺失；段落存在
    但某正典畫面的所有 member 都沒出現在該段之後的文字裡 → 只列該正典畫面。回傳缺失的
    `[(canonical_id, display, members), ...]` 子集（保留 canonical_boards 的順序）。"""
    if not canonical_boards:
        return []
    chunks = []
    for board in notes_boards(head_doc):
        for t in text_nodes(board):
            chunks.append(t["content"])
    joined = "\n".join(chunks)
    m = SCREEN_ATTR_HEADING_RE.search(joined)
    if not m:
        return list(canonical_boards)
    scoped = joined[m.start():]
    return [(cid, display, members) for cid, display, members in canonical_boards if not any(name in scoped for _, name in members)]  # DESIGN-NOTES-SCREEN-ATTR-CHECK


def check(head_doc, head_ids, dead_candidates):
    missing = []
    history = []
    for board in notes_boards(head_doc):
        for t in text_nodes(board):
            content = t["content"]
            for m in ID_TOKEN_RE.finditer(content):
                tok = m.group(0)
                if tok.isdigit() or tok in head_ids or tok not in dead_candidates:
                    continue
                clause = clause_around(content, m.start(), m.end())
                entry = (board["id"], board.get("name") or "", t["id"], tok, clause)
                if HISTORY_RE.search(clause) or ARROW_AFTER_RE.match(content, m.end()):
                    history.append(entry)
                else:
                    missing.append(entry)
    return missing, history


def main(argv):
    pen = head = base = None
    history_shas = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--pen":
            pen = argv[i + 1] if i + 1 < len(argv) else None
            i += 2
        elif a == "--head":
            head = argv[i + 1] if i + 1 < len(argv) else None
            i += 2
        elif a == "--base":
            base = argv[i + 1] if i + 1 < len(argv) else None
            i += 2
        elif a == "--history":
            i += 1
            while i < len(argv) and not argv[i].startswith("--"):
                history_shas.append(argv[i])
                i += 1
        else:
            die("未知參數 %s" % a)
    if not pen or not head or not base:
        die("缺 --pen／--head／--base")

    head_doc = load_snapshot(head, pen)
    head_ids = all_ids(head_doc)
    base_doc = load_snapshot(base, pen)
    candidates = set(all_ids(base_doc))
    seen = {head, base}
    for sha in history_shas:
        if sha in seen:
            continue
        seen.add(sha)
        candidates |= all_ids(load_snapshot(sha, pen))
    dead_candidates = candidates - head_ids

    boards = notes_boards(head_doc)
    missing, history = check(head_doc, head_ids, dead_candidates)
    for bid, bname, tid, tok, clause in history:
        print("（沿革）板 %s（%s）／節點 %s／舊 id %s：%s" % (bid, bname, tid, tok, clause[:120]))
    for bid, bname, tid, tok, clause in missing:
        print("✗ 板 %s（%s）／節點 %s／缺失 id %s：%s" % (bid, bname, tid, tok, clause[:120]), file=sys.stderr)

    # LS-202 署名年齡片語 NBSP：本 PR 觸碰的頂層節點（板／元件定義）上的命中＝違規，其餘＝舊債警告
    touched = touched_roots(base_doc, head_doc)
    nbsp_bad, nbsp_old = [], []
    for hit in age_hits(head_doc):
        (nbsp_bad if hit[0] in touched else nbsp_old).append(hit)
    for rid, rname, owner, content, unit, cps in nbsp_old:
        print("（舊債）署名 NBSP：板 %s（%s）／%s：「%s」%s 前 %s——本 PR 未觸碰此板，不擋（LS-202）" % (rid, rname, owner, content[:60], unit, cps))
    for rid, rname, owner, content, unit, cps in nbsp_bad:
        print("✗ 署名 NBSP：板 %s（%s）／%s：「%s」%s 前 %s（須 U+00A0；允許 U+2060／換行，LS-202）" % (rid, rname, owner, content[:60], unit, cps), file=sys.stderr)

    # LS-300（R2，merge-review R1 M1）：畫面級屬性清單——本 PR 新增的正典畫面（深色／AX3／iPad 等變體已歸併），
    # 是否每一個都在 Notes 板「畫面級屬性」段裡被提到（任一變體板名即算）。
    new_boards = new_screen_boards(base_doc, head_doc)
    screen_missing = screen_attr_missing(head_doc, new_boards)
    for cid, display, members in screen_missing:
        member_ids = "、".join(mid for mid, _ in members)
        print(
            "✗ 畫面級屬性缺列：正典畫面 %s（%s；板 id：%s）——Notes 未含「畫面級屬性」段，或段內未提及任一變體名稱（LS-300）"
            % (cid, display, member_ids), file=sys.stderr
        )

    summary = "Notes 板 %d 塊、head id %d、本 PR 範圍曾存在而 head 已無的 id %d、沿革引用 %d、缺失 %d、署名 NBSP 違規 %d（舊債 %d）、新增正典畫面 %d、畫面級屬性缺列 %d" % (
        len(boards), len(head_ids), len(dead_candidates), len(history), len(missing), len(nbsp_bad), len(nbsp_old), len(new_boards), len(screen_missing))
    problems = []
    if missing:
        problems.append("Notes 引用了本 PR 刪掉的節點 id，改成現行 id，或在同一子句用沿革標記（原／當時／已刪除／取代舊，或寫成「舊 id→新 id」把舊 id 放在箭頭左側）說明它已不存在（LS-168）")
    if nbsp_bad:
        problems.append("本 PR 觸碰的板／元件上，cmp/Card Album／cmp/Card Diary 署名的 歲／個月 前空白含 U+0020——改成 U+00A0（允許 U+2060／換行）後重落地（LS-202）")
    if screen_missing:
        problems.append("新增正典畫面未在 Notes「畫面級屬性」段逐畫面列出——每個畫面補一列（板名｜隱藏 Tab Bar｜標題｜釘底動作帶｜失敗文案鍵｜深色特例｜AX3 特例｜iPad 重排/放大），深色／AX3／iPad 變體記在該列欄位、不必各自成行，格式見 docs/COLLABORATION.md §1（LS-300）")
    if problems:
        print("✗ design-notes gate：%s——%s" % (summary, "；".join(problems)), file=sys.stderr)
        return 1
    print("✓ design-notes gate 通過：%s" % summary)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
