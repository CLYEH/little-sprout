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

輸出：每筆缺失一行「✗ 板 <rootId>（名稱）／節點 <textId>／缺失 id <token>：<子句>」；沿革 info 行以「（沿革）」開頭；
最後一行摘要。exit 0＝無缺失；1＝有缺失；2＝參數／git／JSON 錯誤（fail closed）。

用法：design_notes_check.py --pen <repo 相對路徑> --head <sha> --base <merge-base sha> [--history <sha> ...]
  --head／--base／--history 皆以 `git show <sha>:<pen>` 讀快照（在 repo 內執行）；--history 為本 PR 範圍內觸碰 .pen 的
  commit（不含 head 亦可，重複無妨）。design-notes-check.sh 負責算這些 sha，本檔只做判定。
"""
import json
import re
import subprocess
import sys

ID_TOKEN_RE = re.compile(r"(?<![A-Za-z0-9])[A-Za-z0-9]{5,6}(?![A-Za-z0-9])")
NOTES_NAME_RE = re.compile(r"實作註記|Handoff Notes")
CLAUSE_SPLIT_RE = re.compile(r"[。；;\n，,]")
# 沿革標記（子句級）。「原」排除「原因」；「刪」限「刪 X」「已刪除」「刪除重建」「刪除舊」這幾種寫法，避免 LS-152 Notes 大量
# 「刪除帳號」流程敘述把同子句的活指標整個放行。
HISTORY_MARKERS = (
    r"已刪除", r"刪除重建", r"刪除舊", r"刪 ", r"原(?!因)", r"當時", r"已被", r"取代", r"舊", r"→", r"重建", r"曾",
    r"不存在", r"已改", r"已於",
)
HISTORY_RE = re.compile("|".join(HISTORY_MARKERS))


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
                if HISTORY_RE.search(clause):
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
    candidates = set(all_ids(load_snapshot(base, pen)))
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
    summary = "Notes 板 %d 塊、head id %d、本 PR 範圍曾存在而 head 已無的 id %d、沿革引用 %d、缺失 %d" % (
        len(boards), len(head_ids), len(dead_candidates), len(history), len(missing))
    if missing:
        print("✗ design-notes gate：%s——Notes 引用了本 PR 刪掉的節點 id，改成現行 id，或在同一子句用沿革標記（原／當時／已刪除／取代舊／→）說明它已不存在（LS-168）" % summary, file=sys.stderr)
        return 1
    print("✓ design-notes gate 通過：%s" % summary)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
