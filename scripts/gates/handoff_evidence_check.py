#!/usr/bin/env python3
"""LS-211 handoff 逐項證據 gate 邏輯（供 handoff-evidence-check.sh 呼叫）。

來源：LS-96 池項 `1ff7b8d8`（LS-191 收尾／LS-210：QA handoff 項 1 用歡迎頁測試綠作證，實際未點過
設定頁——驗收項與證據未一對一）。解析 handoff／QA 裁決／merge-review verdict 文件裡「已驗證」等價
段落的每一個列項（`-`／數字），要求每項至少含一種「怎麼驗」證據：
  (a) 測試名——`test[A-Z]\\w*`（XCTest 方法命名慣例）或 `\\w+Tests`（測試類別／suite 名，含
      `Foo.Tests`／`Foo/Tests` 這類接在後面的形狀，`\\w+Tests` 本身已涵蓋）；每個候選再驗證真的
      存在於 repo（在 --repo 指定的目錄跑，預設當前 git repo 根）——防止「引用不存在的測試名」
      矇混過關（同源 LS-96 池項 `0e49f3e3`：handoff 申報不可信、要能被機械驗證）。**R2（merge-review
      R1 F1）**：存在性判定放寬為「任一成立即算存在」——
        1. `git grep -P "func <name>\\b|class <name>\\b|struct <name>\\b|enum <name>\\b|extension <name>\\b"`
           （涵蓋一般宣告，`extension` 涵蓋 `TimelineStoreVideoTests.swift` 這種檔名與內部宣告的型別
           不同名的檔案——真實案例：檔內其實是 `extension TimelineStoreTests`）；
        2. `git ls-files -- "*<name>.swift"` 非空（檔名本身就是合法「怎麼驗」指向，不要求檔內一定要
           宣告同名型別——上一條涵蓋不了「純粹用檔名指涉一份測試」這種常見寫法）；
        3. `git ls-files` 裡有任一路徑的目錄成分等於 `<name>`（涵蓋 `LittleSproutTests`／
           `LittleSproutUITests` 這種**測試 target 名**，`xcodebuild test -only-testing:LittleSproutTests`
           是本 repo 標準句，target 名不是 class 也不是檔名，只有目錄名對得上）。
      候選還需先過兩道**不驗證**（R2 F1）的過濾：
        - **glob 形狀**：候選緊鄰在 `*` 之後（如 `` `*IPadTests` ``）——這是在描述「不存在一個叫這個
          名字的東西」的萬用字元寫法，不是在引用一個具體名稱，一律跳過存在性檢查。
        - **同句含否定詞**：候選所在的子句（上一個 `。！？\\n、；：，` 或 `——` 到候選之間）含
          「沒有」「無」「不存在」「未」——「本 feature 沒有獨立 `*IPadTests` 類別」是正確的否定陳述，
          不是「引用了一個叫 IPadTests 的東西」，把它判成造假是這條規則本身的誤判（真實案例：
          LS-191 QA comment `c541cd06` 逐字原文就踩到這裡）。
        - **mutation 語境**：列項所在的整個區塊含「mutation」（含 mutant／大小寫不敏感）、「改回」
          或「→ 紅」——這類敘述常見刻意使用「不存在的假名」（如 `BogusTests`）示範「拿掉檢查後假
          名矇混過關」，此語境下的候選名稱是示範文字、不是申報，一律跳過存在性檢查（ios-dev.md
          硬規則「每支 mutation 必列三段」與這條證據規則本來就會打架，這裡讓步）。
  (b) 路徑——含 `.png`／`.log`／`.test.sh`／`scratchpad/`／`evidence/` 子字串；另外**經驗擴充**：
      含 `.swift` 的原始碼檔案引用（如 `FamilyMemberActionVisibility.swift:89-100`）也算——這是
      code-review 型驗證（非執行期測試／截圖）的合法「怎麼驗」指向。真實樣本 LS-192 QA comment
      `88fb24bc` 項 6（LS058/059/060 錯誤碼分流）就是靠這種引用交代怎麼驗的；若不接受，會把一份
      已充分交代查證方式的驗收硬判成不合格，讓 gate 自己變成了新的誤判來源。**R2（merge-review R1
      F1(c)）**：`.test.sh` 是 harness 票 handoff 的標準證據形式（`<gate>.test.sh` 第 n 組），原本
      系統性不被承認，補上。
  (c) 命令——含 `xcodebuild`、`bash scripts/`、`gh run view` 或 `.xcresult` 子字串（R2 補後兩者：
      merge-review verdict 常用 `gh run view --job --log` 核對 CI、`.xcresult` 是測試結果檔）。

段落偵測（涵蓋三種實際慣例，見 LS-211 handoff 附的真實樣本與 merge-review R1 `b212dd78`）：
  - CLAUDE.md 的 ios-dev handoff 格式：字面「已驗證」開頭的段（`## 已驗證`／`**已驗證**`／純文字
    「已驗證」開頭的行），段內逐行 `-` 列點，每行各自獨立要求證據。
  - QA／merge-review 裁決的實際慣例（真實樣本 LS-191 `c541cd06`／LS-192 `88fb24bc`）：段落標題是
    `## 逐條驗收`／`**逐條驗收**`（非字面「已驗證」，但同義詞——標題文字含「驗收」二字），項目用
    「`N. **標題** ✓：…`」或「`**N. 標題 ✓**`」數字編號（數字可能在粗體內或粗體外）；底下若接
    `-` 子列點視為該編號項的延伸細節，吸收進同一個項目的證據池、不當獨立列項——這兩份真實樣本裡
    編號項底下的 `-` 子列點是同一件事的分項舉證，不是各自獨立的驗收條件（純 `-` 列表、前面沒有
    數字編號項時，才逐行各自獨立成項——ios-dev handoff 慣例）。
  - merge-review verdict 慣例（R2，來源 merge-review R1 F3）：標題含「查實」（如「## 逐條查實」）
    也算——merge-reviewer 的 verdict 骨架用「Findings」列問題、「逐條查實」列對票文每一條的驗證，
    後者才是本 gate 該掃的「已驗證」等價段落。
  段落結束＝遇到下一個「標題型」行（`##`／`###` 標題，或整行粗體且不是「數字編號」開頭）——不論
  新標題內容是什麼，一律視為段落結束（「起到下一段」）。段落起始的判定：標題文字含子字串
  「已驗證」「驗收」或「查實」（涵蓋「已驗證」「逐條驗收」「驗收條件」「逐條查實」等寫法）。

已知限制（merge-review R1 informational，記錄不修，理由見 comment `b212dd78`）：
  - N6(a) 段落中間出現「整行粗體且結尾無標點」的行會被判定為標題、提早結束段落，其後列項不檢查
    ——`is_heading_line` 對粗體行的判定沒有排除段落內部的強調用語。
  - N6(b) `find_section` 只取第一個含「驗收」／「查實」／「已驗證」關鍵字的標題；若文件先有一個
    沒有證據的「## 驗收條件」（票文抄錄）才接「## 逐條驗收」（真正的逐項驗證），會誤檢查前者。
  - N9 本 gate 只驗「有沒有寫怎麼驗」，驗不出「證據與宣稱是否對應」這種語意問題（`1ff7b8d8`(b)：
    QA 用歡迎頁測試證明設定頁能開 sheet，這種「證據↔宣稱錯配」機械面仍是空的）。

exit：0＝全過；1＝任一項缺證據或引用的測試名不存在；2＝找不到檔案／不在 git repo 且未給 --repo
（fail closed）。
"""
import re
import subprocess
import sys

# ---- 段落標題判定 ----
SECTION_KEYWORD_RE = re.compile(r"已驗證|驗收|查實")  # HANDOFF-SECTION-KEYWORD
HEADING_HASH_RE = re.compile(r"^#{2,6}\s+(.*)$")
BOLD_ONLY_RE = re.compile(r"^\*\*([^*].*?)\*\*\s*$")
PLAIN_YIYANZHENG_RE = re.compile(r"^已驗證")

# ---- 列項起始判定：`1. 標題`／`**1. 標題**`（數字可能在粗體內或粗體外）----
NUMBERED_ITEM_RE = re.compile(r"^\*{0,2}[0-9]+\.\s+")
DASH_ITEM_RE = re.compile(r"^-\s+")

# ---- 證據判定（HANDOFF-EVIDENCE-*：mutation 標記，勿改標記文字本身）----
TEST_NAME_RE = re.compile(r"\btest[A-Z][A-Za-z0-9_]*\b|\b[A-Za-z_][A-Za-z0-9_]*Tests\b")  # HANDOFF-EVIDENCE-TESTNAME
PATH_RE = re.compile(r"\.png|\.log|\.test\.sh|scratchpad/|evidence/|\.swift\b")  # HANDOFF-EVIDENCE-PATH
COMMAND_RE = re.compile(r"xcodebuild|bash scripts/|gh run view|\.xcresult")  # HANDOFF-EVIDENCE-COMMAND

# ---- R2（merge-review R1 F1）：候選過濾——glob 形狀／同句否定詞／mutation 語境不驗存在性 ----
NEGATION_WORDS = ("沒有", "無", "不存在", "未")
CLAUSE_BOUNDARY_RE = re.compile(r"[。！？\n、；：，]|——")
MUTATION_CONTEXT_RE = re.compile(r"mutation|mutant|改回|→\s*紅", re.IGNORECASE)  # HANDOFF-MUTATION-CONTEXT


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
    起點）；找不到回傳 None。只取第一個符合的段落（「解析『已驗證』段」為單數；已知限制見 N6(b)）。"""
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


def is_glob_candidate(text, start):
    """候選緊鄰在 `*` 之後（如 `*IPadTests`）——萬用字元寫法，不是引用具體名稱。"""
    return start > 0 and text[start - 1] == "*"


def is_negated(text, start):
    """候選所在的子句（上一個子句邊界到候選之間）含否定詞——正確的否定陳述不算引用。"""
    before = text[:start]
    positions = [m.end() for m in CLAUSE_BOUNDARY_RE.finditer(before)]
    clause_start = positions[-1] if positions else 0
    clause = text[clause_start:start]
    return any(w in clause for w in NEGATION_WORDS)


def test_name_candidates(block):
    """回傳 [(name, skip_existence_check)]——skip 者仍算作候選（計入 has_evidence 的判斷依據，
    因為候選本身即符合 TEST_NAME_RE），但不驗證是否存在（glob／否定／mutation 語境）。"""
    is_mutation = bool(MUTATION_CONTEXT_RE.search(block))  # HANDOFF-MUTATION-CONTEXT-CHECK
    out = {}
    for m in TEST_NAME_RE.finditer(block):
        name = m.group(0)
        skip = is_mutation or is_glob_candidate(block, m.start()) or is_negated(block, m.start())  # HANDOFF-SKIP-CHECK
        # 同名候選只要有一次出現「不必驗」，整體就不必驗（同一列項內，只要有一次是合法的否定／
        # glob／mutation 語境提及，就不該因為另一次同名的字面重複而被判造假）。
        out[name] = out.get(name, False) or skip
    return sorted(out.items())


def _git_ls_files(repo):
    try:
        proc = subprocess.run(["git", "-C", repo, "ls-files"], capture_output=True, text=True)
    except OSError as exc:
        fail("呼叫 git ls-files 失敗（%s）" % exc)
    if proc.returncode != 0:
        fail("git ls-files 失敗（exit %d）：%s" % (proc.returncode, proc.stderr.strip()[:300]))
    return proc.stdout.splitlines()


def test_name_exists(repo, name):
    # 用 --perl-regexp（-P）而非 -E：macOS 內建 git 2.47 的 -E（POSIX ERE）不支援 `\b`（單字邊界是
    # GNU／PCRE 擴充語法，非 POSIX 標準），實測 `git grep -q -E 'class Foo\b'` 對存在的 Foo 仍回
    # exit 1（誤判不存在）；`-P` 才真的支援 `\b`（實測 rc=0）。
    # R2（merge-review R1 F1-1）：補 struct／enum／extension——`extension` 涵蓋檔名與內部宣告型別
    # 不同名的檔案（真實案例：`TimelineStoreVideoTests.swift` 內部其實是 `extension TimelineStoreTests`）。
    kinds = ("func", "class", "struct", "enum", "extension")
    pattern = "|".join(r"%s %s\b" % (k, re.escape(name)) for k in kinds)
    try:
        proc = subprocess.run(["git", "-C", repo, "grep", "-q", "-P", pattern], capture_output=True)
    except OSError as exc:
        fail("呼叫 git grep 失敗（%s）" % exc)
    if proc.returncode == 0:
        return True
    # R2（merge-review R1 F1-1）：檔名存在即算——不要求檔內一定要宣告同名型別，涵蓋純粹用檔名指涉
    # 一份測試檔的寫法。`*<name>.swift` 這個 pathspec 本身就會比對到完整相對路徑（含目錄），不需要
    # 額外處理路徑深度。
    try:
        proc2 = subprocess.run(
            ["git", "-C", repo, "ls-files", "--", "*%s.swift" % name], capture_output=True, text=True
        )
    except OSError as exc:
        fail("呼叫 git ls-files 失敗（%s）" % exc)
    if proc2.returncode == 0 and proc2.stdout.strip():
        return True
    # R2（merge-review R1 F1-1）：目錄存在即算——涵蓋 `LittleSproutTests`／`LittleSproutUITests` 這種
    # 測試 target 名（`xcodebuild test -only-testing:LittleSproutTests` 是本 repo 標準句，target 名
    # 不是 class 也不是檔名，只有目錄名對得上）。
    for relpath in _git_ls_files(repo):
        if name in relpath.split("/")[:-1]:
            return True
    return False


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
            "找不到「已驗證」（或標題含『驗收』／『查實』字樣，如「逐條驗收」「逐條查實」）段落"
            "——handoff 必須有整理過的逐項驗證清單"
        )

    start, end = section
    items = split_items(lines, start, end)
    if not items:
        fail("「已驗證」段落內沒有任何列項（`-`／數字編號）")

    ok = True
    for line_no, block in items:
        missing_evidence = not has_evidence(block)  # HANDOFF-MISSING-EVIDENCE-CHECK
        candidates = test_name_candidates(block)
        bad_names = [n for n, skip in candidates if not skip and not test_name_exists(repo, n)]  # HANDOFF-BADNAMES-CHECK
        if missing_evidence:
            print(
                "✗ handoff-evidence-check：第 %d 行起的列項缺『怎麼驗』證據（須含測試名、"
                ".png/.log/.test.sh/scratchpad//evidence//.swift 路徑，或 xcodebuild／bash scripts/／"
                "gh run view／.xcresult 命令）" % line_no,
                file=sys.stderr,
            )
            ok = False
        for name in bad_names:
            print(
                "✗ handoff-evidence-check：第 %d 行引用的測試名 `%s` 在 repo 內找不到"
                "（`func/class/struct/enum/extension %s`、同名檔案、同名目錄皆無——git -C %s）"
                % (line_no, name, name, repo),
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
