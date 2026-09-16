#!/usr/bin/env python3
"""LS-309 C：Identity Header 年齡字串 NBSP gate（供 design-identity-header-check.sh 呼叫）。

為什麼：`design_notes_check.py` 既有的署名 NBSP 檢查（`age_hits()`）只掃 `cmp/Card Album`／`cmp/Card Diary`
兩個元件定義＋其實例的 descendants 覆寫——LS-252 VR R2/R3（comment `8dbba1c8` B-3）實測發現 01／04／06 三張
板各自的 Identity Header（板頭顯示姓名＋年齡的區塊，不是卡片元件、是板自己的節點）年齡字串共 9 處全部違反
稿內自訂的 NBSP 規則，而既有 gate 完全掃不到（範圍就限定在那兩個元件），只能靠人工 hex dump 才抓到
（LS-96 池項 `285d3310`）。這支補這個缺口：掃**本 PR 觸碰的板**（頂層節點，取法同
`design-evidence-check.sh`／`design_notes_check.py` 的 `touched_roots()`——merge-base→head 之間 JSON 有變更
即觸碰）子樹內的所有 text 節點與 ref 實例 descendants 覆寫，不限定在特定元件名稱之內（Identity Header 不是
共用元件、是板自己的節點，掃「這塊板的整棵子樹」才蓋得到）。

稿內標準（`cmp/Card Diary` 參照節點 `zk1yE`，規則寫在 Notes `epDnW`，LS-194／LS-201 沿革；LS-252 VR comment
`8dbba1c8` B-3 逐 codepoint 核對）：
  "2 歲 3 個⁠月" → codepoint `32 a0 6b72 a0 33 a0 500b 2060 6708`
  即：{歲數} U+00A0 歲 U+00A0 {月數} U+00A0 個 U+2060 月 ——**四個分隔位置**：歲數與「歲」之間、「歲」與月數
  之間、月數與「個」之間皆須恰為**一個** U+00A0（NBSP）；「個」與「月」之間須恰為**一個** U+2060（word
  joiner）。任何偏差（缺分隔、退化成一般空白 U+0020、多字元、換行等）都算違規——LS-252 R3 實測踩過「分隔
  整個不見」與「NBSP 退化成 U+0020」兩種錯法（comment `ba033c73` B-3）。
  月齡單獨呈現（不足一歲、無「歲」段）的樣式「N 個月」比照：{月數} U+00A0 個 U+2060 月，只驗月數與「個」
  之間、「個」與「月」之間兩個分隔（沒有「歲」段就沒有前兩個分隔可驗）。

與 `design_notes_check.py` 既有的 NBSP 檢查（`AGE_UNIT_RE`）不同：那支只驗「單位前的空白序列裡有沒有混進
U+0020」（寬鬆偵測，範圍限定在兩個卡片元件）；這支對每個分隔位置**逐一比對是否恰為期望的單一 codepoint**
（嚴格驗證，範圍是本 PR 觸碰的整塊板）——兩支互補，不是取代（既有的仍保留在 `design-notes-check.sh`，
掃它自己範圍內的舊債；這支專治 Identity Header 這一類「不在共用元件內」的年齡字串）。

用法：design_identity_header_check.py --pen <repo 相對路徑> --head <sha> --base <merge-base sha>
  --head／--base 皆以 `git show <sha>:<pen>` 讀快照（在 repo 內執行，經 design_notes_check.load_snapshot）。

輸出：每筆違規一行「✗ Identity Header 年齡 NBSP：板 <id>（<name>）／<owner>：「<內容前 80 字>」內「<命中片段>」
（<樣式>）分隔＝…（須 U+00A0…）」；最後一行摘要。exit 0＝無違規；1＝有違規；2＝參數／git／JSON 錯誤（fail closed）。
"""
import re
import sys
from pathlib import Path

# 與 design_notes_check.py 同目錄，reuse load_snapshot／die／touched_roots／text_nodes（不手抄一份，稿快照讀取
# 與「觸碰的板」判定跟 Notes gate 完全同源，不會兩邊各自維護一套判準然後漂移）
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.dont_write_bytecode = True
import design_notes_check as dnc  # noqa: E402

NBSP = " "
WJ = "⁠"
# 分隔字元類別：非數字、非「歲」「個」「月」的字元皆可能是分隔（含 U+0020／U+00A0／U+2060／換行／全形空白……），
# 零或多個——零個代表「分隔整個不見」，這本身就是要抓的違規之一（LS-252 R3 實測樣式）
_SEP = r"[^\d歲個月]*"
FULL_AGE_RE = re.compile(r"(\d+)(" + _SEP + r")歲(" + _SEP + r")(\d+)(" + _SEP + r")個(" + _SEP + r")月")
MONTHS_ONLY_RE = re.compile(r"(\d+)(" + _SEP + r")個(" + _SEP + r")月")


def _cps(s):
    return "+".join("U+%04X" % ord(ch) for ch in s) if s else "(缺)"


def _full_ok(m):
    return m.group(2) == NBSP and m.group(3) == NBSP and m.group(5) == NBSP and m.group(6) == WJ


def _months_ok(m):
    return m.group(2) == NBSP and m.group(3) == WJ


def scan_content(content):
    """回傳這段 content 裡的年齡字串違規清單：[(樣式, 命中片段, 分隔說明)]。"""
    violations = []
    full_spans = []
    for m in FULL_AGE_RE.finditer(content):
        full_spans.append((m.start(), m.end()))
        if not _full_ok(m):
            detail = "分隔＝%s／%s／%s／%s（須 U+00A0／U+00A0／U+00A0／U+2060）" % (
                _cps(m.group(2)), _cps(m.group(3)), _cps(m.group(5)), _cps(m.group(6)))
            violations.append(("N歲N個月", m.group(0), detail))
    for m in MONTHS_ONLY_RE.finditer(content):
        if any(m.start() < e and s < m.end() for s, e in full_spans):
            continue  # 已被「N歲N個月」樣式的尾段驗過，不重複算
        if not _months_ok(m):
            detail = "分隔＝%s／%s（須 U+00A0／U+2060）" % (_cps(m.group(2)), _cps(m.group(3)))
            violations.append(("N個月", m.group(0), detail))
    return violations


def instance_override_texts(root):
    """root 子樹內每個 ref 節點的 descendants content 覆寫：[(owner描述, content), ...]。"""
    out = []
    stack = [root]
    while stack:
        n = stack.pop()
        if not isinstance(n, dict):
            continue
        if n.get("type") == "ref":
            for key, ov in (n.get("descendants") or {}).items():
                if isinstance(ov, dict) and isinstance(ov.get("content"), str):
                    out.append(("實例 %s override %s" % (n.get("id"), key), ov["content"]))
        stack.extend(n.get("children") or [])
    return out


def identity_header_hits(head_doc, touched):
    """回傳 [(root_id, root_name, owner, content顯示用, 樣式, 命中片段, 分隔說明)]，只掃 touched 內的板子樹。
    排除 Notes 板（`dnc.NOTES_NAME_RE`）——那是給 ios-dev 讀的說明文字，不是實際渲染的 UI 年齡字串，逐字比對
    codepoint 對散文完全不合理（實測 LS-252 h5BNyi「今天年齡＝1 歲 4 個月＝16 個月大」這類句子會被誤判違規，
    但它是正確的中文標點寫法，不是 UI 節點）。"""
    hits = []
    for root in head_doc.get("children") or []:
        if not isinstance(root, dict) or root.get("id") not in touched:
            continue
        if dnc.NOTES_NAME_RE.search(root.get("name") or ""):
            continue
        sources = [("節點 %s" % t["id"], t["content"]) for t in dnc.text_nodes(root)]
        sources += instance_override_texts(root)
        for owner, content in sources:
            for style, snippet, detail in scan_content(content):
                hits.append((root["id"], root.get("name") or "", owner, content.replace("\n", "⏎"), style, snippet, detail))
    return hits


def main(argv):
    pen = head = base = None
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
        else:
            dnc.die("design_identity_header_check：未知參數 %s" % a)
    if not pen or not head or not base:
        dnc.die("design_identity_header_check：缺 --pen／--head／--base")

    head_doc = dnc.load_snapshot(head, pen)
    base_doc = dnc.load_snapshot(base, pen)
    touched = dnc.touched_roots(base_doc, head_doc)

    hits = identity_header_hits(head_doc, touched)
    for rid, rname, owner, content, style, snippet, detail in hits:
        print("✗ Identity Header 年齡 NBSP：板 %s（%s）／%s：「%s」內「%s」（%s）%s（與 cmp/Card Diary 參照節點 zk1yE 的 codepoint 序列相同才算正確，LS-309）"
              % (rid, rname, owner, content[:80], snippet, style, detail), file=sys.stderr)

    summary = "本 PR 觸碰板 %d 塊、年齡字串違規 %d" % (len(touched), len(hits))
    if hits:
        print("✗ design-identity-header gate：%s" % summary, file=sys.stderr)
        return 1
    print("✓ design-identity-header gate 通過：%s" % summary)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
