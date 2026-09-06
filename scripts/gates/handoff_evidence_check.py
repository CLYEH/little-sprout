#!/usr/bin/env python3
"""LS-211 handoff 逐項證據 gate 邏輯（供 handoff-evidence-check.sh 呼叫）。

來源：LS-96 池項 `1ff7b8d8`（LS-191 收尾／LS-210：QA handoff 項 1 用歡迎頁測試綠作證，實際未點過
設定頁——驗收項與證據未一對一）。解析 handoff／QA 裁決／merge-review verdict 文件裡「已驗證」等價
段落的每一個列項（`-`／數字），要求每項至少含一種「怎麼驗」證據：
  (a) 測試名——`test[A-Z]\\w*`（XCTest 方法命名慣例）或 `\\w+Tests`（測試類別／suite 名，含
      `Foo.Tests`／`Foo/Tests` 這類接在後面的形狀，`\\w+Tests` 本身已涵蓋）；每個候選再以
      `git grep -q -E "func <name>\\b|class <name>\\b"` 驗證真的存在於 repo（在 --repo 指定的目錄
      跑，預設當前 git repo 根）——防止「引用不存在的測試名」矇混過關（同源 LS-96 池項 `0e49f3e3`：
      handoff 申報不可信、要能被機械驗證）。
  (b) 路徑——含 `.png`／`.log`／`scratchpad/`／`evidence/` 子字串；另外**經驗擴充**：含 `.swift`
      的原始碼檔案引用（如 `FamilyMemberActionVisibility.swift:89-100`）也算——這是 code-review
      型驗證（非執行期測試／截圖）的合法「怎麼驗」指向。真實樣本 LS-192 QA comment `88fb24bc`
      項 6（LS058/059/060 錯誤碼分流）就是靠這種引用交代怎麼驗的；若不接受，會把一份已充分交代
      查證方式的驗收硬判成不合格，讓 gate 自己變成了新的誤判來源。
  (c) 命令——含 `xcodebuild` 或 `bash scripts/` 子字串。

段落偵測（涵蓋兩種實際慣例，見 LS-211 handoff 附的兩個真實樣本）：
  - CLAUDE.md 的 ios-dev handoff 格式：字面「已驗證」開頭的段（`## 已驗證`／`**已驗證**`／純文字
    「已驗證」開頭的行），段內逐行 `-` 列點，每行各自獨立要求證據。
  - QA／merge-review 裁決的實際慣例（真實樣本 LS-191 `c541cd06`／LS-192 `88fb24bc`）：段落標題是
    `## 逐條驗收`／`**逐條驗收**`（非字面「已驗證」，但同義詞——標題文字含「驗收」二字），項目用
    「`N. **標題** ✓：…`」或「`**N. 標題 ✓**`」數字編號（數字可能在粗體內或粗體外）；底下若接
    `-` 子列點視為該編號項的延伸細節，吸收進同一個項目的證據池、不當獨立列項——這兩份真實樣本裡
    編號項底下的 `-` 子列點是同一件事的分項舉證，不是各自獨立的驗收條件（純 `-` 列表、前面沒有
    數字編號項時，才逐行各自獨立成項——ios-dev handoff 慣例）。
  段落結束＝遇到下一個「標題型」行（`##`／`###` 標題，或整行粗體且不是「數字編號」開頭）——不論
  新標題內容是什麼，一律視為段落結束（「起到下一段」）。段落起始的判定：標題文字含子字串
  「已驗證」或「驗收」（涵蓋「已驗證」「逐條驗收」「驗收條件」等寫法）。

已知限制（非本票兩個真實樣本所需，未實作）：明確標記 `⊘`（未驗證／略過）的列項目前仍要求證據，
不會因為自陳未驗證而豁免——如需要，留給下一張觸碰本檔的票補。

exit：0＝全過；1＝任一項缺證據或引用的測試名不存在；2＝找不到檔案／不在 git repo 且未給 --repo
（fail closed）。
"""
import re
import subprocess
import sys

# ---- 段落標題判定 ----
SECTION_KEYWORD_RE = re.compile(r"已驗證|驗收")  # HANDOFF-SECTION-KEYWORD
HEADING_HASH_RE = re.compile(r"^#{2,6}\s+(.*)$")
BOLD_ONLY_RE = re.compile(r"^\*\*([^*].*?)\*\*\s*$")
PLAIN_YIYANZHENG_RE = re.compile(r"^已驗證")

# ---- 列項起始判定：`1. 標題`／`**1. 標題**`（數字可能在粗體內或粗體外）----
NUMBERED_ITEM_RE = re.compile(r"^\*{0,2}[0-9]+\.\s+")
DASH_ITEM_RE = re.compile(r"^-\s+")

# ---- 證據判定（HANDOFF-EVIDENCE-*：mutation 標記，勿改標記文字本身）----
TEST_NAME_RE = re.compile(r"\btest[A-Z][A-Za-z0-9_]*\b|\b[A-Za-z_][A-Za-z0-9_]*Tests\b")  # HANDOFF-EVIDENCE-TESTNAME
PATH_RE = re.compile(r"\.png|\.log|scratchpad/|evidence/|\.swift\b")  # HANDOFF-EVIDENCE-PATH
COMMAND_RE = re.compile(r"xcodebuild|bash scripts/")  # HANDOFF-EVIDENCE-COMMAND


def fail(msg):
    sys.stderr.write("✗ handoff-evidence-check：%s\n" % msg)
    sys.exit(2)


def is_heading_line(line):
    """回傳 (is_heading, inner_text)。inner_text 是去掉 #／** 之後的文字（供關鍵字判定）；
    數字編號列項（`1. 標題`／`**1. 標題**`）不算標題（那是段落內的列項起點，優先判定）。"""
    stripped = line.strip()
    if not stripped:
        return False, ""
    if NUMBERED_ITEM_RE.match(stripped):
        return False, ""
    m = HEADING_HASH_RE.match(stripped)
    if m:
        return True, m.group(1)
    m = BOLD_ONLY_RE.match(stripped)
    if m:
        return True, m.group(1)
    if PLAIN_YIYANZHENG_RE.match(stripped):
        return True, stripped
    return False, ""


def find_section(lines):
    """回傳 (start_idx, end_idx)：0-based，end 為 exclusive，start 指向標題行的下一行（段落內容
    起點）；找不到回傳 None。只取第一個符合的段落（「解析『已驗證』段」為單數）。"""
    for i, line in enumerate(lines):
        is_head, inner = is_heading_line(line)
        if not is_head or not SECTION_KEYWORD_RE.search(inner):
            continue
        for j in range(i + 1, len(lines)):
            is_head2, _ = is_heading_line(lines[j])
            if is_head2:
                return (i + 1, j)
        return (i + 1, len(lines))
    return None


def split_items(lines, start, end):
    """回傳 [(item_start_line_no_1based, block_text)]——數字編號後接的 `-` 列點吸收進同一項；
    純 `-` 列表（前面沒有數字編號項）每個 `-` 各自獨立成項（ios-dev handoff 慣例）。"""
    items = []
    cur_start = None
    cur_lines = []
    mode = None  # None｜"number"｜"dash"

    def flush():
        if cur_start is not None:
            items.append((cur_start, "\n".join(cur_lines)))

    for idx in range(start, end):
        line = lines[idx]
        stripped = line.strip()
        if NUMBERED_ITEM_RE.match(stripped):
            flush()
            cur_start = idx + 1
            cur_lines = [line]
            mode = "number"
            continue
        if DASH_ITEM_RE.match(stripped):
            if mode == "number":
                cur_lines.append(line)
                continue
            flush()
            cur_start = idx + 1
            cur_lines = [line]
            mode = "dash"
            continue
        if cur_start is not None:
            cur_lines.append(line)
        # 段落內、還沒遇到第一個列項之前的純文字（如段落簡介）忽略。
    flush()
    return items


def test_name_candidates(text):
    return sorted({m.group(0) for m in TEST_NAME_RE.finditer(text)})


def test_name_exists(repo, name):
    # 用 --perl-regexp（-P）而非 -E：macOS 內建 git 2.47 的 -E（POSIX ERE）不支援 `\b`（單字邊界是
    # GNU／PCRE 擴充語法，非 POSIX 標準），實測 `git grep -q -E 'class Foo\b'` 對存在的 Foo 仍回
    # exit 1（誤判不存在）；`-P` 才真的支援 `\b`（實測 rc=0）。語意仍是「func <name>\b｜class
    # <name>\b」，只是用支援它的旗標。
    pattern = r"func %s\b|class %s\b" % (re.escape(name), re.escape(name))
    try:
        proc = subprocess.run(["git", "-C", repo, "grep", "-q", "-P", pattern], capture_output=True)
    except OSError as exc:
        fail("呼叫 git grep 失敗（%s）" % exc)
    return proc.returncode == 0


def has_evidence(text):
    return bool(TEST_NAME_RE.search(text) or PATH_RE.search(text) or COMMAND_RE.search(text))


def resolve_repo(repo):
    if repo is not None:
        return repo
    try:
        proc = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    except OSError as exc:
        fail("找不到 git（%s）且未給 --repo" % exc)
    if proc.returncode != 0:
        fail("不在 git repo 內且未給 --repo（fail closed）")
    return proc.stdout.strip()


def run(path, repo):
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError as exc:
        fail("讀不到 %s（%s）" % (path, exc))

    repo = resolve_repo(repo)
    lines = text.splitlines()
    section = find_section(lines)
    if section is None:
        fail(
            "找不到「已驗證」（或標題含『驗收』字樣，如「逐條驗收」）段落——handoff 必須有整理過"
            "的逐項驗證清單"
        )

    start, end = section
    items = split_items(lines, start, end)
    if not items:
        fail("「已驗證」段落內沒有任何列項（`-`／數字編號）")

    ok = True
    for line_no, block in items:
        missing_evidence = not has_evidence(block)
        bad_names = [n for n in test_name_candidates(block) if not test_name_exists(repo, n)]  # HANDOFF-BADNAMES-CHECK
        if missing_evidence:
            print(
                "✗ handoff-evidence-check：第 %d 行起的列項缺『怎麼驗』證據（須含測試名、"
                ".png/.log/scratchpad//evidence//.swift 路徑，或 xcodebuild／bash scripts/ 命令）" % line_no,
                file=sys.stderr,
            )
            ok = False
        for name in bad_names:
            print(
                "✗ handoff-evidence-check：第 %d 行引用的測試名 `%s` 在 repo 內找不到"
                "（`func %s`／`class %s` 皆無——git -C %s grep）" % (line_no, name, name, name, repo),
                file=sys.stderr,
            )
            ok = False
        if not missing_evidence and not bad_names:
            print("✓ 第 %d 行起的列項有證據" % line_no)
    return ok


def main(argv):
    args = argv[1:]
    repo = None
    path = None
    it = iter(args)
    for a in it:
        if a in ("--help", "-h"):
            print(__doc__)
            sys.exit(0)
        if a == "--repo":
            try:
                repo = next(it)
            except StopIteration:
                fail("--repo 缺值")
            continue
        if path is not None:
            fail("只接受一個 handoff 檔（多給了 %s）" % a)
        path = a
    if path is None:
        fail("用法：handoff_evidence_check.py <handoff.md> [--repo <dir>]")

    ok = run(path, repo)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main(sys.argv)
