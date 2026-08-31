#!/usr/bin/env python3
r"""LS-104 R3：pretool.sh 的 Bash 命令評估引擎（取代 R1 版本的 bash O(n^2) 逐字迴圈）。

被 scripts/hooks/pretool.sh 呼叫：命令字串經 stdin 傳入（避免 argv 跳脫問題），
輸出只在 deny 時印一行 reason 文字，exit code 2＝deny、0＝allow。任何未預期例外
一律印訊息＋exit 2（fail-closed）——呼叫端 pretool.sh 對「rc 不是 0 或 2」也一律
視為 deny（見 pretool.sh 對本腳本呼叫處的註解）。

設計（見 merge-reviewer R1 comment，LS-104 票 comment 7a97f88a）：
  Pass 1 `strip_heredocs`：單趟字元掃描，track 引號狀態＋comment 狀態，只有「不在引號
    內、不在 comment 內」的 `<<[-~]?TAG` 才算真正的 heredoc 起點——修 R1 F2（假 heredoc：
    引號內／comment 內的 `<<TAG` 字面不再誤吞後續真命令）。comment 文字（不在引號內、
    詞首出現的 `#` 到行尾）整段丟棄，heredoc 內文（含終止行）整段丟棄，其餘字元原樣保留
    （含真正的 heredoc 起始那一行本身）。
  Pass 2 `tokenize_segments`：對 pass 1 剝除後的字串做引號感知斷詞＋切段，**正確處理
    反斜線**（unquoted 反斜線+任意字元 → 逐字還原那個字元；反斜線+換行＝續行，兩者一併吞掉；雙引號內只有
    `\"`／`\\`／`` \` ``／`\$`／`\`+換行 五種序列有跳脫意義，其餘反斜線原樣保留）——
    修 R1 F3（反斜線跳脫先前完全不處理，導致引號提前關閉／token 被切碎＝漏放，方向
    與 §7 文件宣稱的相反）。單引號內完全逐字。雙引號／unquoted 內的 `$(...)`／反引號
    一律擷取內文供遞迴評估。每個 token 記錄「是否曾經過引號」（用於命令位置正規化時
    排除誤判透明前綴詞／保留動詞）。每個段落同時記錄「原始文字」（供退回整段字面比對
    使用）。
  命令位置正規化＋退回機制（R1 F1）：段落內第一個非 `VAR=val` token，剝除黏連的
    `(`／`{`／`!`／`)`／`}`／`;`／`&`（剝到空字串就換下一個 token，同「透明前綴詞」
    處理）、取 basename（處理絕對／相對路徑），再檢查是否為透明前綴詞（command／
    builtin／exec／env／sudo／nohup／time／timeout／stdbuf／caffeinate／script）——
    是就再往後取下一個 token 重複整套正規化（上限 16 層）。正規化後的結果若不是「乾淨
    的裸識別字（只含字母數字底線點加減號、字母/底線開頭）且不是 shell 保留字
    （if/then/else/elif/fi/for/do/done/while/until/case/esac/in/select/function）」，
    視為「命令位置認不得」——這也自然涵蓋 `${IFS}` 這類展開黏連在命令位置的形狀
    （token 裡含 `$`／`{`／`}` 不符合裸識別字規則）。命令位置認不得的段落，不做逐一
    token 精確比對，改用**舊版整段字面比對**（regex 對該段原始文字掃描，等同 LS-104
    之前 H1/H2/H3 的字面比對邏輯）——寧可誤擋也不漏放（R1 F1／F5 的共同修法）。
    命令位置認得的段落，才用「exact token equality」的精確比對（LS-104 R1 的原始設計，
    誤擋面小）。
  `$(...)`／反引號／`bash -c`／`sh -c` payload 遞迴：深度上限 8。R3（merge-reviewer R2
    comment 5a170052，F1 blocker）：R2 版的 `-c` 偵測只認「`-c` 這個 token 緊接在
    `bash`／`sh` 後面」，`-lc`／`-cx`／`-ic` 這類併入短旗標團、或 `-e -c`／`-o pipefail -c`／
    `--norc -c` 這類前面插旗標，都偵測不到、也不遞迴——且 `evaluate()` 對 `check_precise`
    回 OK 沒有任何 fallback，等於命令位置認得 bash/sh 但沒解析出 payload 就整條放行（比
    main 現行 hook 弱，回歸）。R3 修法（見票文建議兩者都做）：(1) 廣義化 `-c` 偵測——只要
    命令位置已經是 bash/sh，任何單一 `-` 開頭、全字母、含字母 c 的旗標 token（`-c`／
    `-lc`／`-cx`／...）都視為「之後下一個 token 是 -c payload」，不再要求它緊接在
    bash/sh 後面；(2) 兜底——`check_precise` 對 bash/sh 段落回 OK（代表沒能遞迴出 payload，
    例如純腳本呼叫 `bash foo.sh args`，或未來仍有漏的旗標形狀）時，`evaluate()` 額外對該
    段原始文字補跑一次 `check_fallback`，任何「認得 bash/sh 但沒解析出 payload」的路徑都
    不會裸放行。
  H2 檔名比對（ENV_FILE_RE）容忍尾端 glob 萬用字元（`*`／`?`／`[`／`]`），修 R1 F5
    的 glob 繞路（`.env*` 這類）。
  H3 重入判定／wrapper 字面比對：整條命令（pass1 剝除後）字面比對，語意同 R1（wrapper
    判斷不看段落邊界，因為 wrapper 慣例是整條命令只有一段）。

failure 路徑：任何未被下面邏輯明確攔到的例外，一律在 __main__ 的 try/except 轉成
  exit 2＋固定文字（fail-closed，不當作 allow）。
"""
import sys
import re
import os

COLL_REF = "docs/COLLABORATION.md §7"

# ---- 命令位置正規化用表 ----
TRANSPARENT = {
    "command", "builtin", "exec", "env", "sudo", "nohup", "time", "timeout",
    "stdbuf", "caffeinate", "script",
}
RESERVED_KEYWORDS = {
    "if", "then", "else", "elif", "fi", "for", "do", "done", "while", "until",
    "case", "esac", "in", "select", "function",
}
IDENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.+-]*$")
ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

# R3（merge-reviewer R2 comment 5a170052，F1 blocker）：`bash`/`sh` 的 `-c` 偵測原本只認
# 「`-c` 這個 token 緊接在 `bash`/`sh` 後面」這一種形狀，`-c` 併入短旗標團（`-lc`/`-cx`/`-ic`）
# 或前面插了其他旗標（`-e -c`/`-o pipefail -c`/`--norc -c`）都偵測不到、也不會遞迴，且
# `evaluate()` 對 `check_precise` 回 OK 沒有 fallback 兜底，等於整條放行——比 main 現行 hook 弱
# （回歸）。修法：只看「命令位置已認得是 bash/sh」這件事本身（不要求 -c 前一個 token 恰好是
# bash/sh），凡是單一 `-` 開頭、其餘全為字母的旗標 token（可以是 `-c` 本身或任意順序的短旗標團
# 如 `-lc`/`-cx`）只要含字母 c，就把它之後的下一個 token 當成 -c 的 payload 遞迴（雙寫 `--norc`
# 這種長旗標因為開頭是 `--` 不會誤觸發）。此偵測本身若因為未來新旗標形狀而漏接，evaluate()
# 對 bash/sh 的 OK 結果一律再補跑一次 check_fallback(raw) 兜底（見 evaluate()），任何「認得
# bash/sh 但沒解析出 payload」的路徑都不會裸放行。
BASH_SHORT_FLAG_RE = re.compile(r"^-[A-Za-z]+$")

READ_VERBS = {
    "cat", "less", "head", "tail", "awk", "cut", "sed", "grep", "bat", "xxd",
    "base64", "strings", "rg", "wc",
    # R1 I2：補 sort/paste/dd/od/nl/more/open/perl/jq（票文列的清單；python3 -c 另外處理）
    "sort", "paste", "dd", "od", "nl", "more", "open", "perl", "jq",
}
ENV_FILE_RE = re.compile(r"^(?:.*/)?\.env(?:\.[A-Za-z0-9_.-]+)?[*?\[\]]*$")
RUNSH_RE = re.compile(r"(?:^|.*/)run\.sh$")
PROTECTED_BRANCH_RE = re.compile(r"(?:^|[^A-Za-z0-9_])(?:development|test|main)(?:[^A-Za-z0-9_]|$)")

# ---- 舊版整段字面比對用表（命令位置認不得的段落退回這一套；語意等同 LS-88／R1 舊版）----
FB_NOVERIFY_RE = re.compile(r"(?:^|[^A-Za-z0-9_-])--no-verify(?:[^A-Za-z0-9_-]|$)")
FB_GITCOMMIT_RE = re.compile(r"git[ \t]+commit")
FB_DASHN_RE = re.compile(r"(?:^|[ \t])-n(?:[ \t]|$)")
FB_GITPUSH_RE = re.compile(r"git[ \t]+push")
FB_FORCE_RE = re.compile(r"(?:^|[ \t])(?:--force(?:-with-lease)?|-f)(?:[ \t]|$)")
FB_PLUSREF_RE = re.compile(r"(?:^|[ \t])\+[A-Za-z0-9._/-]+")
FB_PROTECTED_RE = re.compile(r"(?:^|[^A-Za-z0-9_])(?:development|test|main)(?:[^A-Za-z0-9_]|$)")
FB_ENVFILE_RE = re.compile(r"(?:^|[^A-Za-z0-9_])\.env(?:\.[A-Za-z0-9_.-]+)?(?:$|[^A-Za-z0-9_.-])")
FB_READVERB_RE = re.compile(
    r"(?:^|[^A-Za-z0-9_])(?:cat|less|head|tail|awk|cut|sed|grep|bat|xxd|base64|strings|rg|wc|"
    r"sort|paste|dd|od|nl|more|open|perl|jq|python3)(?:$|[^A-Za-z0-9_])"
)
FB_REDIR_ENV_RE = re.compile(r"<[ \t]*['\"]?\.env")
FB_GREP_OFLAG_RE = re.compile(r"-[A-Za-z]*o[A-Za-z]*\b")
FB_GREP_EQ_RE = re.compile(r"=['\"]")
FB_CUT_D_RE = re.compile(r"-d[ \t]*=")
FB_CUT_F_RE = re.compile(r"-f[ \t]*1\b")
FB_SUBARESET_RE = re.compile(r"supabase[ \t]+db[ \t]+reset")
FB_RUNSH_RE = re.compile(r"(?:^|[^A-Za-z0-9_])run\.sh(?:$|[^A-Za-z0-9_.-])")
WRAPPER_RE = re.compile(r"supabase-lock\.sh\b.*[ \t]--(?:[ \t]|$)")
# R2（probe a18）：`alias` 字面以命令位置出現在任何一段，代表這條命令有定義別名的意圖——見
# evaluate() 對 ALIAS_DEFINED_RE 的用法。要求 alias 前面是分段邊界（行首／`;`／`&&`／`||`／
# `&`／`|`／換行）或字串開頭，避免「alias」出現在無關字串裡誤觸發（雖然誤觸發只是多跑一次
# fallback 掃描，不會誤 deny，但沒必要）。
ALIAS_DEFINED_RE = re.compile(r"(?:^|[;&|\n])\s*alias(?:[ \t]|$)")

MAX_DEPTH = 8


class Ambiguous(Exception):
    pass


# ============================================================================
# Pass 1：heredoc／comment 剝除（quote-aware 單趟字元掃描）
# ============================================================================
def strip_heredocs(s):
    n = len(s)
    i = 0
    out = []
    q = None  # None / "'" / '"'
    in_comment = False
    pending = []  # [(tag, strip_tabs), ...]
    consuming = None  # (tag, strip_tabs) or None
    bad = False

    while i < n:
        if consuming is not None:
            nl = s.find("\n", i)
            if nl == -1:
                line = s[i:]
                i = n
            else:
                line = s[i:nl]
                i = nl + 1
            tag, strip_tabs = consuming
            check = line.lstrip("\t") if strip_tabs else line
            if check == tag:
                consuming = pending.pop(0) if pending else None
            continue

        ch = s[i]

        if q == "'":
            out.append(ch)
            if ch == "'":
                q = None
            i += 1
            continue

        if ch == "\\" and q != "'":
            out.append(ch)
            if i + 1 < n:
                out.append(s[i + 1])
                i += 2
            else:
                i += 1
            continue

        if q == '"':
            out.append(ch)
            if ch == '"':
                q = None
            i += 1
            continue

        if in_comment:
            if ch == "\n":
                out.append(ch)
                in_comment = False
                if pending:
                    consuming = pending.pop(0)
            i += 1
            continue

        if ch == "'":
            q = "'"
            out.append(ch)
            i += 1
            continue
        if ch == '"':
            q = '"'
            out.append(ch)
            i += 1
            continue

        if ch == "#":
            prev = out[-1] if out else None
            if prev is None or prev in (" ", "\t", "\n", ";", "&", "|", "("):
                in_comment = True
                i += 1
                continue
            out.append(ch)
            i += 1
            continue

        if ch == "\n":
            out.append(ch)
            i += 1
            if pending:
                consuming = pending.pop(0)
            continue

        if ch == "<" and i + 1 < n and s[i + 1] == "<" and not (i + 2 < n and s[i + 2] == "<"):
            out.append("<<")
            j = i + 2
            mod = ""
            if j < n and s[j] in ("-", "~"):
                mod = s[j]
                out.append(mod)
                j += 1
            while j < n and s[j] in (" ", "\t"):
                out.append(s[j])
                j += 1
            tag = None
            if j < n and s[j] == "'":
                k = s.find("'", j + 1)
                if k == -1:
                    bad = True
                    i = n
                    continue
                tag = s[j + 1:k]
                out.append(s[j:k + 1])
                j = k + 1
            elif j < n and s[j] == '"':
                k = s.find('"', j + 1)
                if k == -1:
                    bad = True
                    i = n
                    continue
                tag = s[j + 1:k]
                out.append(s[j:k + 1])
                j = k + 1
            else:
                m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", s[j:])
                if m:
                    tag = m.group(0)
                    out.append(tag)
                    j += len(tag)
            if tag is not None:
                pending.append((tag, mod == "-"))
            i = j
            continue

        out.append(ch)
        i += 1

    if consuming is not None or pending or q is not None:
        bad = True

    return "".join(out), bad


# ============================================================================
# Pass 2：quote-aware 斷詞＋切段（含 $(...) ／反引號擷取、正確反斜線語意）
# ============================================================================
def tokenize_segments(s):
    """回傳 (segments, cmdsubs)；segments 是 list of dict：
       {"tokens": [(text, had_quotes), ...], "raw": <該段原始文字（供退回比對）>}
       未平衡的引號／$(...)／反引號一律 raise Ambiguous。
    """
    n = len(s)
    i = 0
    segments = []
    cur_tokens = []
    cur_tok_chars = []
    tok_has_content = False
    tok_had_quotes = False
    cmdsubs = []
    seg_start = 0

    def flush_tok():
        nonlocal cur_tok_chars, tok_has_content, tok_had_quotes
        if cur_tok_chars or tok_has_content:
            cur_tokens.append(("".join(cur_tok_chars), tok_had_quotes))
        cur_tok_chars = []
        tok_has_content = False
        tok_had_quotes = False

    def flush_seg(end_idx):
        nonlocal cur_tokens, seg_start
        flush_tok()
        if cur_tokens:
            segments.append({"tokens": cur_tokens, "raw": s[seg_start:end_idx]})
        cur_tokens = []

    while i < n:
        ch = s[i]

        # R2（probe2 x06「dollar-single-quote」）：ANSI-C quoting `$'...'`——沒有這條，`$` 先被
        # 當一般字元吃掉，剩下的 `'...'` 再被下面的一般單引號規則接手，結果 token 變成
        # 「$」+內文黏在一起（如 `$.env`），永遠比不中 `.env` 這種 exact-match 規則（漏放）。
        # 真實 bash 對 `$'...'` 內的反斜線會做完整跳脫展開（`\n`→換行等），我們不需要還原成
        # 那些真實字元——只要把跳脫序列裡「反斜線+下一個字元」的下一個字元原樣留下即可（跟本
        # 檔案其他地方的反斜線處理一致的保守近似），足以讓 `$'.env'` 正確變成內容為 `.env` 的
        # token。
        if ch == "$" and i + 1 < n and s[i + 1] == "'":
            content, j = _scan_ansi_c_quote(s, i + 2, n)
            cur_tok_chars.append(content)
            tok_has_content = True
            tok_had_quotes = True
            i = j
            continue

        if ch == "'":
            j = s.find("'", i + 1)
            if j == -1:
                raise Ambiguous()
            cur_tok_chars.append(s[i + 1:j])
            tok_has_content = True
            tok_had_quotes = True
            i = j + 1
            continue

        if ch == "\\":
            if i + 1 >= n:
                raise Ambiguous()
            nxt = s[i + 1]
            if nxt == "\n":
                i += 2
                continue
            cur_tok_chars.append(nxt)
            tok_has_content = True
            i += 2
            continue

        if ch == "$" and i + 1 < n and s[i + 1] == "(":
            inner, j = _scan_cmdsub(s, i + 2, n)
            cmdsubs.append(inner)
            tok_has_content = True
            i = j
            continue

        if ch == "`":
            j = s.find("`", i + 1)
            if j == -1:
                raise Ambiguous()
            cmdsubs.append(s[i + 1:j])
            tok_has_content = True
            i = j + 1
            continue

        if ch == '"':
            buf, j = _scan_dquote(s, i + 1, n, cmdsubs)
            cur_tok_chars.append(buf)
            tok_has_content = True
            tok_had_quotes = True
            i = j
            continue

        if ch in (" ", "\t"):
            flush_tok()
            i += 1
            continue

        if ch == "\n" or ch == ";":
            flush_seg(i)
            i += 1
            seg_start = i
            continue

        if ch == "&":
            flush_seg(i)
            i += 2 if (i + 1 < n and s[i + 1] == "&") else 1
            seg_start = i
            continue

        if ch == "|":
            flush_seg(i)
            i += 2 if (i + 1 < n and s[i + 1] == "|") else 1
            seg_start = i
            continue

        if ch == "<":
            flush_tok()
            if i + 1 < n and s[i + 1] == "<":
                if i + 2 < n and s[i + 2] == "<":
                    cur_tokens.append(("<<<", False))
                    i += 3
                else:
                    cur_tokens.append(("<<", False))
                    i += 2
            else:
                cur_tokens.append(("<", False))
                i += 1
            continue

        cur_tok_chars.append(ch)
        tok_has_content = True
        i += 1

    flush_seg(n)
    return segments, cmdsubs


def _scan_cmdsub(s, j, n):
    """從 `$(` 之後（j 指向內文起點）掃到對應的 `)`，處理巢狀括號與內部引號。"""
    depth = 1
    start = j
    cq = None
    while j < n and depth > 0:
        cch = s[j]
        if cq:
            if cch == "\\" and cq == '"' and j + 1 < n:
                j += 2
                continue
            if cch == cq:
                cq = None
            j += 1
            continue
        if cch == "\\" and j + 1 < n:
            j += 2
            continue
        if cch in ("'", '"'):
            cq = cch
            j += 1
            continue
        if cch == "(":
            depth += 1
        elif cch == ")":
            depth -= 1
            if depth == 0:
                return s[start:j], j + 1
        j += 1
    raise Ambiguous()


def _scan_ansi_c_quote(s, j, n):
    """從 `$'` 之後（j 指向內文起點）掃到對應的 `'`，回傳 (內文, 結束後下一個 index)。
    反斜線在這裡一律當「跳脫下一個字元」處理（不還原成真實的 \\n／\\t 等控制字元——見呼叫端
    註解，對 exact-match 比對而言足夠）。"""
    buf = []
    while j < n:
        cch = s[j]
        if cch == "\\" and j + 1 < n:
            buf.append(s[j + 1])
            j += 2
            continue
        if cch == "'":
            return "".join(buf), j + 1
        buf.append(cch)
        j += 1
    raise Ambiguous()


def _scan_dquote(s, j, n, cmdsubs):
    """從 `"` 之後（j 指向內文起點）掃到對應的 `"`，回傳 (內文, 結束後下一個index)。"""
    buf = []
    while j < n:
        cch = s[j]
        if cch == '"':
            return "".join(buf), j + 1
        if cch == "\\" and j + 1 < n and s[j + 1] in ('"', "\\", "`", "$", "\n"):
            if s[j + 1] != "\n":
                buf.append(s[j + 1])
            j += 2
            continue
        if cch == "$" and j + 1 < n and s[j + 1] == "(":
            inner, j2 = _scan_cmdsub(s, j + 2, n)
            cmdsubs.append(inner)
            j = j2
            continue
        if cch == "`":
            k = s.find("`", j + 1)
            if k == -1:
                raise Ambiguous()
            cmdsubs.append(s[j + 1:k])
            j = k + 1
            continue
        buf.append(cch)
        j += 1
    raise Ambiguous()


# ============================================================================
# 命令位置正規化
# ============================================================================
STRIP_CHARS = "(){}!;&"

# R1 F1 類別 5「間接執行」：xargs／eval／alias 把「真正要跑什麼」寫在同一段的後半段（或
# 定義後另待呼叫），我們沒有能力知道它們實際會執行什麼——一律當「命令位置認不得」退回
# 整段字面比對（票文原文點名這幾個）。find 只有帶 -exec 才算（find 本身多數用途無害）。
INDIRECT_EXECUTORS = {"xargs", "eval", "alias"}
FUNC_DEF_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\(\)$")


def clean_tok(text, had_quotes):
    """去掉黏連在 token 兩端的分組/分隔符號（僅限未加引號的 token——引號内容保持原樣）。"""
    return text.strip(STRIP_CHARS) if not had_quotes else text


def resolve_position(tokens):
    """回傳 (pos_tok_or_None, recognized_bool)。pos_tok 是正規化後（basename、剝括號）
    的字串；recognized=True 代表可信任精確比對，False 代表要退回整段字面比對。"""
    idx = 0
    n = len(tokens)
    while idx < n:
        text, had_quotes = tokens[idx]
        if not had_quotes and ASSIGN_RE.match(text):
            idx += 1
            continue
        break

    guard = 0
    while idx < n and guard < 16:
        guard += 1
        text, had_quotes = tokens[idx]

        # 函式定義 `name() { ... }`：整段其實是在定義一個函式，真正的命令在 `{ }` 內、
        # 跟這個 token 同一段——我們不追蹤函式定義/呼叫的對應關係，一律不信任、退回整段
        # 字面比對（票文「先定義 function 再呼叫」類別）。
        if not had_quotes and FUNC_DEF_RE.match(text):
            return text, False

        cleaned = clean_tok(text, had_quotes)
        if cleaned == "":
            idx += 1
            continue
        effective = cleaned.rsplit("/", 1)[-1] if "/" in cleaned else cleaned
        if not had_quotes and effective in TRANSPARENT:
            idx += 1
            continue
        if not had_quotes and effective in INDIRECT_EXECUTORS:
            return effective, False
        if not had_quotes and effective == "find":
            has_exec = any(
                (not hq and clean_tok(t, hq) == "-exec") for t, hq in tokens[idx:]
            )
            if has_exec:
                return effective, False
        if IDENT_RE.match(effective) and effective not in RESERVED_KEYWORDS:
            return effective, True
        return effective, False
    return None, False


# ============================================================================
# H1/H2/H3：命令位置可信時的精確 token 比對
# ============================================================================
def check_precise(cmd, tokens):
    has_no_verify = has_dash_n = has_commit = has_push = has_force = has_protected = False
    h2_hit = h2_redir = grep_o = grep_eq = cut_d = cut_f = False
    h3_run_sh = h3_supabase_reset = False
    expect_redir = False
    prevtok = ""
    awaiting_c_payload = False

    if RUNSH_RE.match(cmd):
        h3_run_sh = True

    for raw_text, had_quotes in tokens:
        # R1 F1：token 兩端黏連的括號/分隔符號先剝掉才比對（(git commit --no-verify) 這種
        # 括號黏連，最後一個 token 會是 "--no-verify)"，不剝掉就永遠比不中字面相等）。
        text = clean_tok(raw_text, had_quotes)

        # R2：拿掉「引號內不比對」的排除——引號只影響 shell 的斷詞／萬用字元展開，不會改變
        # 最終傳給程式的 argv 內容本身：`git commit "--no-verify"` 傳給 git 的 argv 跟不加
        # 引號完全一樣，git 一樣會當成 --no-verify 旗標解讀（reviewer probe a06「quoted flag」）。
        # exact-value 相等比對本來就只會在整個 token 剛好等於旗標字面時才命中，訊息型的引號
        # 內容（如 `'docs: 說明 --no-verify 規則'`）整段是一個 token、不會恰好等於 "--no-verify"，
        # 不需要額外靠「有沒有引號」排除。
        if cmd == "git":
            if text == "--no-verify":
                has_no_verify = True
            elif text == "-n":
                has_dash_n = True
            elif text == "commit":
                has_commit = True
            elif text == "push":
                has_push = True
            elif text in ("--force", "-f") or text.startswith("--force-with-lease"):
                has_force = True
            elif text.startswith("+"):
                has_force = True
            if PROTECTED_BRANCH_RE.search(text):
                has_protected = True

        if cmd in READ_VERBS:
            if ENV_FILE_RE.match(text):
                h2_hit = True
            if cmd == "grep":
                if re.match(r"^-[A-Za-z]*o[A-Za-z]*$", text):
                    grep_o = True
                if text.endswith("="):
                    grep_eq = True
            if cmd == "cut":
                if text == "-d=":
                    cut_d = True
                if prevtok == "-d" and text == "=":
                    cut_d = True
                if text == "-f1":
                    cut_f = True
                if prevtok == "-f" and text == "1":
                    cut_f = True

        if cmd == "python3" and prevtok == "-c":
            if re.search(r"(?:^|[^A-Za-z0-9_])\.env(?:\.[A-Za-z0-9_.-]+)?(?:$|[^A-Za-z0-9_.-])", raw_text):
                h2_hit = True

        if text == "<":
            expect_redir = True
        else:
            if expect_redir:
                if ENV_FILE_RE.match(text):
                    h2_redir = True
                expect_redir = False

        if cmd == "supabase" and prevtok == "db" and text == "reset":
            h3_supabase_reset = True
        if cmd in ("bash", "sh") and RUNSH_RE.match(text) and text != cmd:
            h3_run_sh = True

        # R3 F1：cmd（命令位置）已經是 bash/sh 才會進到這個函式；不再要求 `-c` 緊接在
        # bash/sh 後面——`-e -c`／`-o pipefail -c`／`--norc -c` 這類前面插旗標、或 `-lc`／
        # `-cx` 這類併入短旗標團的寫法，都在這裡被同一條規則抓到（見 BASH_SHORT_FLAG_RE
        # 定義處的說明）。
        if awaiting_c_payload:
            return ("RECURSE", raw_text)
        if cmd in ("bash", "sh") and BASH_SHORT_FLAG_RE.match(text) and "c" in text[1:]:
            awaiting_c_payload = True

        prevtok = text

    if has_no_verify:
        return ("DENY", f"H1：命令含 --no-verify，繞過 commit/push gate，見 {COLL_REF}")
    if has_commit and has_dash_n:
        return ("DENY", f"H1：git commit -n 等同 --no-verify，繞過 commit gate，見 {COLL_REF}")
    if has_push and has_force and has_protected:
        return ("DENY", f"H1：force push 目標為 development／test／main（受保護分支禁止 force push），見 {COLL_REF}")

    if h2_redir:
        return ("DENY", f"H2：以 < 重導向讀出 .env 內容，見 {COLL_REF}")
    if h2_hit:
        if not ((grep_o and grep_eq) or (cut_d and cut_f)):
            return ("DENY", f"H2：以讀取動詞讀出 .env 內容（非 key-only 形式），見 {COLL_REF}")

    if h3_supabase_reset or h3_run_sh:
        return ("H3_TRIGGER", None)

    return ("OK", None)


# ============================================================================
# 舊版整段字面比對（命令位置認不得的段落退回這一套）
# ============================================================================
def check_fallback(raw):
    if FB_NOVERIFY_RE.search(raw):
        return f"H1：命令含 --no-verify，繞過 commit/push gate，見 {COLL_REF}"
    if FB_GITCOMMIT_RE.search(raw) and FB_DASHN_RE.search(raw):
        return f"H1：git commit -n 等同 --no-verify，繞過 commit gate，見 {COLL_REF}"
    if FB_GITPUSH_RE.search(raw) and (FB_FORCE_RE.search(raw) or FB_PLUSREF_RE.search(raw)) and FB_PROTECTED_RE.search(raw):
        return f"H1：force push 目標為 development／test／main（受保護分支禁止 force push），見 {COLL_REF}"

    if FB_REDIR_ENV_RE.search(raw):
        return f"H2：以 < 重導向讀出 .env 內容，見 {COLL_REF}"
    if FB_ENVFILE_RE.search(raw) and FB_READVERB_RE.search(raw):
        allow = (FB_GREP_OFLAG_RE.search(raw) and FB_GREP_EQ_RE.search(raw)) or \
                (FB_CUT_D_RE.search(raw) and FB_CUT_F_RE.search(raw))
        if not allow:
            return f"H2：以讀取動詞讀出 .env 內容（非 key-only 形式，命令位置認不得、退回整段字面比對），見 {COLL_REF}"

    if FB_SUBARESET_RE.search(raw) or FB_RUNSH_RE.search(raw):
        return "H3_TRIGGER"

    return None


# ============================================================================
# evaluate：整套引擎入口，支援 $(...)／bash -c 遞迴
# ============================================================================
def evaluate(cmd, depth, wrapper_haystack):
    if depth > MAX_DEPTH:
        return f"H0：巢狀深度超過安全上限，fail-closed，見 {COLL_REF}"

    stripped, bad = strip_heredocs(cmd)
    if bad:
        return f"H0：heredoc 未正確終止或引號不平衡，切段失敗（歧義即 deny），見 {COLL_REF}"

    try:
        segments, cmdsubs = tokenize_segments(stripped)
    except Ambiguous:
        return f"H0：命令引號／$(...)／反引號不平衡，切段失敗（歧義即 deny），見 {COLL_REF}"

    if wrapper_haystack is None:
        wrapper_haystack = stripped

    for seg in segments:
        tokens = seg["tokens"]
        raw = seg["raw"]
        if not tokens:
            continue
        pos_tok, recognized = resolve_position(tokens)

        if recognized:
            kind, payload = check_precise(pos_tok, tokens)
            if kind == "DENY":
                return payload
            if kind == "H3_TRIGGER":
                reason = _h3_check(wrapper_haystack)
                if reason:
                    return reason
            if kind == "RECURSE":
                if depth >= MAX_DEPTH:
                    return f"H0：巢狀 bash/sh -c 超過安全深度上限，fail-closed，見 {COLL_REF}"
                r = evaluate(payload, depth + 1, wrapper_haystack)
                if r:
                    return r
            if kind == "OK" and pos_tok in ("bash", "sh"):
                # R3（merge-reviewer R2 comment 5a170052，F1 blocker 修法的兜底那一半）：命令位置
                # 認得是 bash/sh，但 check_precise 沒能遞迴出一個 -c payload（例如純粹呼叫
                # 一支腳本檔 `bash foo.sh args`，或未來 -c 偵測仍有漏的旗標形狀）——不得因為
                # 「認得 bash/sh」就直接放行，對這一段的原始文字再補跑一次舊版整段字面比對。
                # 「認得但沒解析出 payload」一律當「認不得」處理，方向與 F1 其他情形一致。
                reason = check_fallback(raw)
                if reason == "H3_TRIGGER":
                    reason = _h3_check(wrapper_haystack)
                if reason:
                    return reason
        else:
            reason = check_fallback(raw)
            if reason == "H3_TRIGGER":
                reason = _h3_check(wrapper_haystack)
            if reason:
                return reason

    # R2（reviewer probe a18「alias then call」）：`alias g=git; g commit --no-verify` 是
    # 「這一段定義、另一段才呼叫」的跨段落問題——我們不追蹤 alias 定義到後續呼叫的對應關係
    # （見檔頭已知盲區），但退一步：只要命令裡任何一段的命令位置是 `alias`，代表這條命令存在
    # 「定義別名」的意圖，此時額外對整條（heredoc 剝除後）命令文字跑一次舊版整段字面比對——
    # 抓不到「g 是 git 的別名」這種語意，但抓得到違規字面就在同一條命令的某處（最常見的形狀：
    # 定義完緊接著呼叫）。沒有 alias 就不觸發，不影響其餘不含 alias 的命令的誤擋面。
    if ALIAS_DEFINED_RE.search(stripped):
        reason = check_fallback(stripped)
        if reason == "H3_TRIGGER":
            reason = _h3_check(wrapper_haystack)
        if reason:
            return reason

    for sub in cmdsubs:
        if depth >= MAX_DEPTH:
            return f"H0：巢狀 $(...)／反引號超過安全深度上限，fail-closed，見 {COLL_REF}"
        r = evaluate(sub, depth + 1, wrapper_haystack)
        if r:
            return r

    return None


def _h3_check(wrapper_haystack):
    if WRAPPER_RE.search(wrapper_haystack):
        return None
    if _h3_reentrant():
        return None
    return (f"H3：supabase db reset／run.sh 未經 scripts/ops/supabase-lock.sh -- 包裹"
            f"（本機容器跨 worktree 共用，LS-70），見 {COLL_REF}")


def _h3_reentrant():
    lock_dir = os.environ.get("SUPABASE_LOCK_DIR")
    if not lock_dir:
        try:
            root = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
            cfg = os.path.join(root, "supabase", "config.toml")
            with open(cfg) as f:
                content = f.read()
            m = re.search(r'^project_id\s*=\s*"([^"]+)"', content, re.MULTILINE)
            if not m:
                return False
            lock_dir = f"/tmp/supabase-lock-{m.group(1)}"
        except OSError:
            return False
    holder_path = os.path.join(lock_dir, "holder")
    try:
        with open(holder_path) as f:
            content = f.read()
    except OSError:
        return False
    m = re.search(r"^pid=(\d+)$", content, re.MULTILINE)
    if not m:
        return False
    holder_pid = m.group(1)
    p = str(os.getpid())
    for _ in range(64):
        if p == holder_pid:
            return True
        try:
            out = os.popen(f"ps -o ppid= -p {p} 2>/dev/null").read().strip()
        except OSError:
            return False
        if not out or not out.isdigit() or out in ("0", "1"):
            return False
        p = out
    return False


def main():
    command = sys.stdin.read()
    reason = evaluate(command, 0, None)
    if reason:
        sys.stdout.write(reason)
        sys.exit(2)
    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:  # noqa: BLE001 - fail-closed on ANY unexpected error
        sys.stdout.write(f"H0：pretool_engine.py 執行異常（{type(e).__name__}），fail-closed，見 {COLL_REF}")
        sys.exit(2)
