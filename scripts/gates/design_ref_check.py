#!/usr/bin/env python3
"""LS-316 設計 PR body `Design:` 行內容 gate（供 design-ref-check.sh 呼叫）。

判定方式、支援寫法、盲區皆見 design-ref-check.sh 檔頭；這支只做解析與比對，不算 git／head 的 sha
（design-ref-check.sh 負責）。

用法：design_ref_check.py --body <body 檔路徑> --pen <repo 相對路徑> --head <sha>
  --pen／--head 以 `git show <sha>:<pen>` 讀快照（在 repo 內執行）；--body 直接用 open() 讀（PR body 是
  暫存檔，不進版控，沒有 git 物件可 show）。
"""
import json
import re
import subprocess
import sys

# 同 design_notes_check.py 慣例：本模組若再 import 同目錄模組，不得在 scripts/gates/ 留 __pycache__。
sys.dont_write_bytecode = True

DESIGN_LINE_RE = re.compile(r"^Design:\s*(.*)$")
# id 形＝5–6 碼英數（design_notes_check.py 既有慣例：Pencil id 實測皆 5–6 碼），可選反引號包住。
NAMED_ENTRY_RE = re.compile(r"^(?P<name>.*\S)\s*（\s*`?(?P<id>[A-Za-z0-9]{5,6})`?\s*）\s*$")
ID_ONLY_RE = re.compile(r"^`?(?P<id>[A-Za-z0-9]{5,6})`?$")


def die(msg):
    sys.stderr.write("✗ design_ref_check：%s\n" % msg)
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


def top_level_names(doc):
    """id → name，僅頂層節點（含 reusable component——與板同一層級的頂層 children，不特別過濾）。"""
    out = {}
    for c in doc.get("children") or []:
        if isinstance(c, dict) and isinstance(c.get("id"), str):
            out[c["id"]] = c.get("name") or ""
    return out


def normalize(s):
    return re.sub(r"\s+", " ", s.strip())


def design_lines(body_text):
    """body 裡所有 `Design:` 開頭的行（去頭尾空白後比對），回傳冒號之後的內容（未拆條目）。"""
    out = []
    for line in body_text.splitlines():
        m = DESIGN_LINE_RE.match(line.strip())
        if m:
            out.append(m.group(1).strip())
    return out


def split_entries(content):
    if "、" in content:
        parts = content.split("、")
    elif "," in content:
        parts = content.split(",")
    else:
        parts = [content]
    return [p.strip() for p in parts if p.strip()]


def all_entries(lines):
    """所有 Design: 行拆出的條目（跳過空內容的行，如模板留空的「Design:」）。"""
    out = []
    for content in lines:
        if content:
            out.extend(split_entries(content))
    return out


def check(entries, id_to_name):
    """回傳 (missing, mismatched, skipped)。
    missing＝[(entry, id)]、mismatched＝[(entry, id, claimed, actual)]、skipped＝[entry]（形狀不明，不算違規）。
    """
    missing = []
    mismatched = []
    skipped = []
    for entry in entries:
        m = NAMED_ENTRY_RE.match(entry)
        if m:
            eid = m.group("id")
            claimed = normalize(m.group("name"))
            if eid not in id_to_name:
                missing.append((entry, eid))
            else:
                actual = normalize(id_to_name[eid])
                if actual != claimed:
                    mismatched.append((entry, eid, claimed, actual))
            continue
        m = ID_ONLY_RE.match(entry)
        if m:
            eid = m.group("id")
            if eid not in id_to_name:
                missing.append((entry, eid))
            continue
        skipped.append(entry)
    return missing, mismatched, skipped


def main(argv):
    body_path = pen = head = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--body":
            body_path = argv[i + 1] if i + 1 < len(argv) else None
            i += 2
        elif a == "--pen":
            pen = argv[i + 1] if i + 1 < len(argv) else None
            i += 2
        elif a == "--head":
            head = argv[i + 1] if i + 1 < len(argv) else None
            i += 2
        else:
            die("未知參數 %s" % a)
    if not body_path or not pen or not head:
        die("缺 --body／--pen／--head")

    try:
        with open(body_path, encoding="utf-8") as fh:
            body_text = fh.read()
    except OSError as exc:
        die("讀不到 body 檔 %s（%s）" % (body_path, exc))

    lines = design_lines(body_text)
    if not lines:
        print("✓ design-ref gate：body 無 Design: 行，交既有非空檢查決定")
        return 0

    entries = all_entries(lines)
    if not entries:
        # LS-316 基準跑 PR #33：舊票「Design:」欄位留空（模板未填的 harness 票），此時 .pen 在該 PR 的
        # head 甚至可能根本不存在（比 .pen 存在更早的歷史 PR）——沒有條目可核對就不必讀快照，
        # 避免對「本來就沒東西要驗」的案例 fail closed。
        print("✓ design-ref gate：Design 行 %d 條、條目 0 筆——無條目可核對" % len(lines))
        return 0

    doc = load_snapshot(head, pen)
    id_to_name = top_level_names(doc)
    missing, mismatched, skipped = check(entries, id_to_name)

    for entry, eid in missing:
        print("✗ Design 行「%s」：id %s 不在 .pen 頂層節點內" % (entry, eid), file=sys.stderr)
    for entry, eid, claimed, actual in mismatched:
        print("✗ Design 行「%s」：body 寫板名「%s」，.pen 頂層節點 %s 實際名稱「%s」" % (entry, claimed, eid, actual), file=sys.stderr)
    for entry in skipped:
        print("（略過）Design 行「%s」：無法解析為「板名（id）」或純 id，未核對（design-ref-check 盲區）" % entry)

    summary = "Design 行 %d 條、條目 %d 筆、缺 id %d、名稱不符 %d、略過 %d" % (
        len(lines), len(entries), len(missing), len(mismatched), len(skipped))
    if missing or mismatched:
        print("✗ design-ref gate：%s——board 名稱／id 須與 .pen 頂層節點一致（LS-316）" % summary, file=sys.stderr)
        return 1
    print("✓ design-ref gate 通過：%s" % summary)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
