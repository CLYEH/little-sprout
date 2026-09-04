#!/usr/bin/env python3
# main_checkout_guard.py — LS-154：擋 agent 寫入主 checkout（PreToolUse hook 的判定引擎）。
# 由 scripts/hooks/main-checkout-guard.sh 呼叫（stdin 餵完整 hook JSON：tool_name／tool_input／
# cwd），本檔案不直接註冊進 settings.json。來源：LS-96 待辦池 f22f0645（2026-09-03 同日兩起
# agent 把檔案寫進主 checkout：LS-143 自報、LS-149 migration 留在主 checkout untracked）。
#
# 「主 checkout」用 git 語意判定、不寫死路徑：對目標路徑最近存在的祖先目錄跑
#     git -C <dir> rev-parse --path-format=absolute --git-dir --git-common-dir
# 兩者相等 ⇔ 該目錄屬於 repo 的主 working tree（linked worktree 的 git-dir 是
# <common>/worktrees/<name>，不相等）。只管「本專案」那個 repo：以 $CLAUDE_PROJECT_DIR（Claude
# Code 執行 hook 時必帶；缺則退 hook JSON 的 cwd）所在 repo 的 common-dir 為準，其他 repo 的主
# checkout 不在本 hook 範圍（票文「不做：擋 repo 外路徑的寫入」）；兩者都不在 git repo 內時退成
# 「任何主 checkout 都擋」並 stderr 註記（只會發生在手動餵 JSON 的情境）。
#
# 規則（任一命中即 deny：stdout 印 deny JSON、stderr 印同一句理由、exit 2）：
#   W1（Write／Edit／MultiEdit／NotebookEdit）：tool_input.file_path（NotebookEdit 為
#       notebook_path；相對路徑以 cwd 解析）落在主 checkout。白名單只有兩處本機狀態（皆 gitignore）：
#       `.claude/patrol-state.json`（LS-144 巡檢狀態檔，正常由 patrol.sh 寫、不經 hook；票文明定）、
#       `.claude/memory/`（auto-memory；`~/.claude/projects/<proj>/memory` 是指向它的 symlink，
#       realpath 後落在主 checkout，orchestrator 寫 memory 是日常動作）。
#   W2（Bash）：命令含「寫入樣式」且目標落在主 checkout——
#       重導 `>`／`>>`／`N>`／`N>>`／`&>`／`>|`（獨立或黏連 token；`>&N` fd 複製不算）；
#       `tee`／`touch`／`mkdir`／`rm`／`rmdir`／`truncate` 的所有位置參數；`cp`／`mv`／`install`／
#       `rsync`／`ln` 的目的地（最後一個位置參數，或 `-t DIR`／`--target-directory=DIR`）；
#       `sed`／`perl` 帶 `-i`／`--in-place` 時的檔案參數（`-e`／`-f` 之後的 script 不算檔案；
#       沒有 `-e`／`-f` 時第一個位置參數是 script）。相對路徑以 hook JSON 的 cwd 解析，並沿命令
#       追蹤 `cd`／`pushd`（`cd <root> && echo > f` 擋；`cd -`／目的地含 `$` 之後的相對路徑判不出）。
#   W3（Bash）：`git [-C <dir>] <sub>` 的 <sub> 會改 working tree／index／HEAD（add／am／apply／
#       checkout／cherry-pick／clean／commit／merge／mv／rebase／reset／restore／revert／rm／
#       switch；stash 除 list／show 外）且 <dir>（缺則 cwd）是主 checkout。pull／fetch／tag／
#       worktree／status／log／diff／show／rev-parse／merge-base／branch／push 等一律不擋
#       （pull 是主 checkout 跟上 main 的正規動作；push 由 push-gate 管）。
#   W4（Bash）：直譯器（python／python3／node／perl／ruby／php／osascript／swift）的 `-c`／`-e`
#       等 payload、heredoc 內文、`<<<` herestring 提到主 checkout 的絕對路徑——讀寫無法判定，
#       一律擋（寧嚴勿鬆；讀檔請改用 Read／cat）。shell（bash／sh／zsh／dash／ksh／csh／tcsh）
#       的 `-c` payload 與 heredoc 內文改遞迴整套規則重評；`$(...)`／反引號內文亦遞迴
#       （深度上限同 pretool_engine.MAX_DEPTH）。
#   W5（Bash）：命令無法斷詞（引號／heredoc／`$(` 不平衡）時退回整段字面比對——原始文字同時含
#       主 checkout 絕對路徑與寫入動詞／重導字面即擋（fail-closed 的粗粒度兜底）。
#   W0：stdin 空／JSON 壞／git 缺席／rev-parse 非「not a git repository」的失敗／本檔案未預期
#       例外 → deny（fail-closed）。
#
# 放行但 stderr 註記（fail-open 只限真的判不出的情況，記入 docs/COLLABORATION.md §7 盲區）：
#   目標 token 含 `$`／反引號（變數展開無法還原）、`cd` 目的地判不出之後的相對路徑、無法斷詞
#   但字面沒有主 checkout 路徑＋寫入樣式。
#
# 開關：環境變數 LS_ALLOW_MAIN_CHECKOUT_WRITE=1（hook 行程的環境＝啟動 claude 的 shell）整支放行；
# Bash 命令文字在**整條命令最前面**的命令位置前綴（`VAR=val`／`env` 串）帶 `LS_ALLOW_MAIN_CHECKOUT_WRITE=1`
# 亦放行該次呼叫——`LS_ALLOW_MAIN_CHECKOUT_WRITE=1 rm …`、`env LS_ALLOW_MAIN_CHECKOUT_WRITE=1 rm …`、
# `FOO=1 env LS_ALLOW_MAIN_CHECKOUT_WRITE=1 rm …` 皆可（前綴賦值的值可帶引號：`FOO="a b" LS_ALLOW…=1 rm …`，
# LS-157；開關本身加引號 `"LS_ALLOW…=1" rm …` 在 bash 裡不是賦值，不認）；`cd x && LS_ALLOW…=1 rm …`（非最前面）
# 不算，deny 訊息會寫明位置限制（merge-review R1 minor 2，comment 94035c1a）。Write／Edit 沒有命令文字可帶，
# 只認環境變數。兩者皆 stderr 註明。預設關。
#
# 前綴穿透（LS-157 1b，R2 informational 1／3）：命令位置前的 `VAR=val` 帶引號值（`FOO="a b" rm …`，tokenizer 收成
# 單一帶引號 token）、透明前綴詞（env／sudo／nohup／nice／time…）緊接的 `-` 旗標（`env -i rm …`）都跳過、穿透到
# 真正的命令再套規則——先前這些 token 被當成「命令名」，後續參數不再過寫入規則，無聲放行。`nice` 補進透明前綴
# 詞表（pretool_engine.TRANSPARENT 沒有它）。旗標帶獨立參數的前綴（`sudo -u bob`／`nice -n 5`／`timeout 5`）該參數
# 會被當成命令名而放行，仍是盲區（§7）。
# 即將建立的 worktree（LS-157 1c，LS-154 收尾實測誤擋）：目標落在 `<root>/.claude/worktrees/<name>/…`（W1／W2 需
# `<name>` 之下至少一層；W3 的 git 目錄可以就是 `<name>` 本身）且 `<name>` 尚不存在 → 視為 worktree 放行並 stderr
# 註記（`git worktree add … && cd … && git merge …` 同一條命令的形狀）；`<root>/.claude/worktrees/` 本身與
# `<root>/.claude/worktrees/<name>` 這一層的檔案寫入／mkdir 仍擋。
#
# 環境衛生（merge-review R1 minor 1，比照 scripts/gates/push-gate.sh LS-73）：hook 行程若帶
# GIT_DIR／GIT_WORK_TREE／GIT_INDEX_FILE／GIT_PREFIX／GIT_COMMON_DIR，`git rev-parse` 對任何 `-C` 目錄
# 都回同一個 git-dir／common-dir → 每個 linked worktree 都被判成主 checkout（產線全停、訊息還叫人
# 「去 worktree」）。LS-157（R2 N1 comment 47ab021a）：只剝五個具名不夠——GIT_OBJECT_DIRECTORY 指向不存在
# 路徑時 rev-parse 對主 checkout 也回「not a git repository」，被歸成「不在 repo 內」→ 整支 gate 無聲
# fail-open。改為呼叫 git 前剝除**所有** GIT_* 前綴變數（rev-parse 純本地、無網路，剝 GIT_CONFIG_*／
# GIT_SSH_COMMAND 只會更乾淨），並加安全網：目標 realpath 落在 hook 自己解析出的 repo 根（$CLAUDE_PROJECT_DIR，
# 缺則自 cwd 上溯找含 .git 的目錄；不靠 git）字首之下、但 rev-parse 仍說不在 repo 內 → W0 deny 並印
# rev-parse 的 stderr 首行（fail-closed）；repo 外路徑（scratchpad／/tmp／$HOME）不受影響。另設
# sys.dont_write_bytecode：import pretool_engine 不得在 scripts/hooks/ 留 __pycache__（hook 跑在主 checkout
# 那份，留了就把主 checkout 弄 dirty）。
#
# 前處理（heredoc 剝除、引號感知斷詞、`$(...)` 擷取、透明前綴詞表）直接 import 同目錄的
# pretool_engine.py（LS-104），不重寫第二套 tokenizer。
import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pretool_engine as E  # noqa: E402

COLL_REF = "docs/COLLABORATION.md §7"
SWITCH = "LS_ALLOW_MAIN_CHECKOUT_WRITE"
FILE_TOOLS = ("Write", "Edit", "MultiEdit", "NotebookEdit")
# 主 checkout 內的本機狀態白名單（相對 toplevel；皆 gitignore）：巡檢狀態檔（LS-144）、auto-memory
# 目錄（`~/.claude/projects/<proj>/memory` 是指向主 checkout `.claude/memory/` 的 symlink，realpath
# 後落在主 checkout——orchestrator 寫 memory 是日常動作，不能擋）。
ALLOWLIST_REL = {".claude/patrol-state.json"}
ALLOWLIST_PREFIX = (".claude/memory/",)

ALL_ARGS_CMDS = {"tee", "touch", "mkdir", "rm", "rmdir", "truncate"}
DEST_CMDS = {"cp", "mv", "install", "rsync", "ln"}
INPLACE_CMDS = {"sed", "perl"}
INTERPRETERS = {"python", "python3", "node", "perl", "ruby", "php", "osascript", "swift"}
PAYLOAD_FLAGS = {"-c", "-e", "-E", "-p", "-r", "--eval", "--print"}
SHELLS = set(E.SHELLC_SHELLS)
TRANSPARENT = set(E.TRANSPARENT) | {"nice"}  # LS-157 1b：engine 詞表沒有 nice（R2 informational 1 實測放行）
WORKTREES_REL = (".claude", "worktrees")     # LS-157 1c：即將建立的 worktree 所在
GIT_MUTATING = {
    "add", "am", "apply", "checkout", "cherry-pick", "clean", "commit", "merge", "mv",
    "rebase", "reset", "restore", "revert", "rm", "switch",
}
GIT_STASH_READONLY = {"list", "show"}
GIT_GLOBAL_OPTS_WITH_ARG = {"-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"}

REDIR_RE = re.compile(r"^(\d*)(>>|>)(.*)$")
INPLACE_RE = re.compile(r"^-[A-Za-z]*i|^--in-place")
UNRESOLVABLE_RE = re.compile(r"[$`]")
ABS_PATH_RE = re.compile(r"(?:^|[^A-Za-z0-9_.~-])((?:~|/)[A-Za-z0-9_./~+@-]+)")
FB_WRITE_RE = re.compile(
    r">|(?:^|[\s;&|(])(?:tee|cp|mv|install|rsync|ln|touch|mkdir|rm|rmdir|truncate)\s"
    r"|(?:^|[\s;&|(])(?:sed|perl)\s+(?:-[A-Za-z]*\s+)*-[A-Za-z]*i|--in-place"
)
HEREDOC_START_RE = re.compile(r"<<[-~]?[ \t]*(?:'([^']*)'|\"([^\"]*)\"|([A-Za-z_][A-Za-z0-9_]*))")
# 命令位置前綴：任意 `VAR=val`／`env` 串之後緊接開關賦值（R1 minor 2：原本只認最前綴一種形狀，
# POSIX 慣用的 `env VAR=1 cmd` 被擋且訊息沒說位置限制 → 重試迴圈）。值可帶引號（`FOO="a b"`；LS-157，
# R2 informational 3：`\S*` 吃不下含空白的引號值，先前該形只是掉進 W2 盲區才「能過」）——引號只能由引號
# 分支吃、不平衡即不匹配，避免回溯爆炸。
_PREFIX_VAL = r"(?:\"[^\"]*\"|'[^']*'|[^\s\"'])*"
INLINE_SWITCH_RE = re.compile(
    r"^\s*(?:(?:env|[A-Za-z_][A-Za-z0-9_]*=" + _PREFIX_VAL + r")\s+)*" + re.escape(SWITCH) + r"=1(?:\s|$)"
)


def _clean_env():
    """呼叫 git 前剝除所有 GIT_* 變數（R1 minor 1 原建議；R2 N1：只剝五個具名時 GIT_OBJECT_DIRECTORY 等仍讓
    rev-parse 回「not a git repository」→ 整支 gate 無聲 fail-open）。"""
    # LS-157 mutation anchor：自測會把 startswith("GIT_") 換回五個具名變數——GIT_OBJECT_DIRECTORY 下 worktree
    # 正樣本必須變紅、主 checkout 負樣本的 deny 必須從 W1 退成 W0（只剩安全網在擋）。
    return {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


_ROOT_HINT = None  # main() 設定：hook 自己解析出的 repo 根 realpath（不靠 git），供 repo_dirs 的安全網用


def root_hint(cwd):
    """$CLAUDE_PROJECT_DIR 的 realpath；缺則自 cwd 上溯找第一個含 .git 的目錄；都沒有 → None。"""
    p = os.environ.get("CLAUDE_PROJECT_DIR")
    if p:
        return os.path.realpath(p)
    d = os.path.realpath(cwd)
    while True:
        if os.path.lexists(os.path.join(d, ".git")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def _under_root(d):
    return bool(_ROOT_HINT) and (d == _ROOT_HINT or d.startswith(_ROOT_HINT + os.sep))


def _under_root_msg(path, stderr):
    first = (stderr.strip().splitlines() or ["(rev-parse 無 stderr)"])[0][:160]
    return (f"{path} 落在 repo 根 {_ROOT_HINT} 之下，但 git rev-parse 判定不在 repo 內（{first}）"
            "——環境／.git 異常時不放行")


class GuardError(Exception):
    pass


class Deny(Exception):
    def __init__(self, rule, detail):
        super().__init__(detail)
        self.rule = rule
        self.detail = detail


NOTES = []


def note(msg):
    NOTES.append(msg)


# ============================================================================
# git 語意：主 checkout 判定
# ============================================================================
_CACHE = {}


def repo_dirs(path):
    """回傳 (git_dir, common_dir) 絕對 realpath；不在任何 git repo → None。path 可不存在
    （取最近存在的祖先目錄）。git 缺席／rev-parse 非「不是 repo」的失敗 → GuardError（fail-closed）。"""
    d = path
    while not os.path.isdir(d):
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent
    d = os.path.realpath(d)
    if d in _CACHE:
        return _CACHE[d]
    try:
        r = subprocess.run(
            ["git", "-C", d, "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"],
            capture_output=True, text=True, timeout=5,
            env=_clean_env(),  # LS-154 R2 mutation anchor：自測換成 env=None，GIT_DIR 下 worktree 樣本必須變紅
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        raise GuardError(f"git rev-parse 無法執行（{type(e).__name__}）")
    if r.returncode != 0:
        if "not a git repository" in r.stderr:
            if _under_root(d):
                # LS-157 mutation anchor（安全網）：自測會把下一行換成 pass，壞 .git 根下的 Write 必須因此變綠
                raise GuardError(_under_root_msg(path, r.stderr))
            res = None
        else:
            raise GuardError(f"git rev-parse 失敗（rc={r.returncode}）：{r.stderr.strip()[:120]}")
    else:
        lines = r.stdout.splitlines()
        if len(lines) < 2:
            raise GuardError("git rev-parse 輸出不足兩行")
        res = (os.path.realpath(lines[0]), os.path.realpath(lines[1]))
    _CACHE[d] = res
    return res


def is_main_checkout(git_dir, common_dir):
    # LS-154 mutation anchor：自測會把下一行換成 `return False`，負樣本必須因此變綠。
    return git_dir == common_dir


def resolve(tok, cwd):
    """把 token 變成絕對 normpath；含 `$`／反引號或相對路徑但 cwd 判不出 → None（stderr 註記）。"""
    if not tok:
        return None
    if UNRESOLVABLE_RE.search(tok):
        note(f"目標「{tok}」含變數展開／命令替換，無法解析，放行（盲區，見 {COLL_REF}）")
        return None
    p = os.path.expanduser(tok) if tok.startswith("~") else tok
    if not os.path.isabs(p):
        if cwd is None:
            note(f"目標「{tok}」是相對路徑但目前目錄判不出（cd 目的地無法解析），放行（盲區，見 {COLL_REF}）")
            return None
        p = os.path.join(cwd, p)
    return os.path.normpath(p)


# ============================================================================
# Bash 斷詞輔助
# ============================================================================
def heredoc_bodies(raw):
    """依 `<<TAG` 出現順序回傳 heredoc 內文（粗略：從下一行起到等於 TAG 的那一行）。"""
    bodies = []
    pending = []
    cur = None
    for line in raw.split("\n"):
        if cur is not None:
            tag, strip_tabs, buf = cur
            check = line.lstrip("\t") if strip_tabs else line
            if check == tag:
                bodies.append("\n".join(buf))
                cur = pending.pop(0) if pending else None
            else:
                buf.append(line)
            continue
        for m in HEREDOC_START_RE.finditer(line):
            tag = m.group(1) or m.group(2) or m.group(3)
            pending.append((tag, m.group(0).startswith("<<-"), []))
        if pending:
            cur = pending.pop(0)
    if cur is not None:
        bodies.append("\n".join(cur[2]))
    return bodies


def find_cmd(pairs):
    """回傳 (basename, idx)；跳過 VAR=val（含帶引號值——tokenizer 把 `FOO="a b"` 收成單一 hq token，LS-157 1b）、
    透明前綴（env／sudo／command／nohup／nice／time…）及其緊接的 `-` 旗標（`env -i`；旗標的獨立參數判不出，盲區）。"""
    idx = 0
    n = len(pairs)
    guard = 0
    after_prefix = False
    while idx < n and guard < 16:
        guard += 1
        text, hq = pairs[idx]
        if text == "":
            idx += 1
            continue
        if E.ASSIGN_RE.match(text):
            idx += 1
            continue
        if after_prefix and not hq and text.startswith("-"):
            idx += 1
            continue
        base = text.rsplit("/", 1)[-1]
        if not hq and base in TRANSPARENT:
            after_prefix = True
            idx += 1
            continue
        return base, idx
    return None, None


def positionals(args):
    out = []
    dashdash = False
    for t, q in args:
        if dashdash or q or not t.startswith("-") or t == "-":
            if t != "":
                out.append(t)
        elif t == "--":
            dashdash = True
    return out


def dest_of(cmd, args):
    for i, (t, q) in enumerate(args):
        if q:
            continue
        if t in ("-t", "--target-directory") and i + 1 < len(args):
            return args[i + 1][0]
        if t.startswith("--target-directory="):
            return t.split("=", 1)[1]
    pos = positionals(args)
    if not pos:
        return None
    dest = pos[-1]
    if cmd == "rsync" and ":" in dest:
        note(f"rsync 目的地「{dest}」看似遠端規格，略過")
        return None
    return dest


def inplace_files(args):
    files = []
    explicit_script = False
    skip = False
    for t, q in args:
        if skip:
            skip = False
            continue
        if not q and t in ("-e", "-E", "-f", "--expression", "--file"):
            explicit_script = True
            skip = True
            continue
        if not q and (t.startswith(("-e", "-E", "-f", "--expression=", "--file=")) and len(t) > 2):
            explicit_script = True
            continue
        if not q and t.startswith("-") and t != "-":
            continue
        if t != "":
            files.append(t)
    if not explicit_script and files:
        files = files[1:]  # 第一個位置參數是 script
    return files


def git_parse(args, cur):
    """回傳 (repo_dir_or_None, subcommand_or_None, rest)。`-C` 相對於前一個 `-C`。"""
    d = cur
    i = 0
    n = len(args)
    while i < n:
        t, q = args[i]
        if not q and t == "-C":
            d = resolve(args[i + 1][0], d) if i + 1 < n else d
            i += 2
            continue
        if not q and t in GIT_GLOBAL_OPTS_WITH_ARG:
            i += 2
            continue
        if not q and t.startswith("-"):
            i += 1
            continue
        if t == "":
            i += 1
            continue
        return d, t, args[i + 1:]
    return d, None, []


# ============================================================================
# 主判定
# ============================================================================
class Guard:
    def __init__(self, cwd):
        self.cwd = cwd
        self._project = False  # lazy：False＝尚未算

    @property
    def project(self):
        if self._project is False:
            self._project = None
            for cand in (os.environ.get("CLAUDE_PROJECT_DIR"), self.cwd):
                if cand:
                    r = repo_dirs(cand)
                    if r:
                        self._project = r[1]
                        break
            if self._project is None:
                note("CLAUDE_PROJECT_DIR／cwd 皆不在 git repo 內，改為任何主 checkout 都擋")
        return self._project

    def hits(self, abspath, as_dir=False):
        """abspath 落在本專案 repo 的主 checkout（且不在白名單）→ True。as_dir=True 表示 abspath 是要在其中
        跑 git 的目錄（W3），即將建立的 worktree 可以就是 `<name>` 這一層。"""
        r = repo_dirs(abspath)
        if r is None:
            return False
        git_dir, common = r
        if self.project is not None and common != self.project:
            return False
        if not is_main_checkout(git_dir, common):
            return False
        # realpath 兩邊對齊（macOS /var → /private/var；不存在的尾段 realpath 會原樣保留）
        top = os.path.dirname(common)
        rel = os.path.relpath(os.path.realpath(abspath), top)
        parts = rel.split(os.sep)
        # LS-157 1c：<root>/.claude/worktrees/<name>/… 且 <name> 尚不存在 → 即將建立的 worktree，放行
        if (tuple(parts[:2]) == WORKTREES_REL and len(parts) >= (3 if as_dir else 4)
                and not os.path.lexists(os.path.join(top, *parts[:3]))):
            note(f"目標「{abspath}」位於尚未建立的 worktree {parts[2]} 之下，視為 worktree 放行（LS-157）")
            return False
        return rel not in ALLOWLIST_REL and not rel.startswith(ALLOWLIST_PREFIX)

    def check(self, tok, cur, rule, what):
        ap = resolve(tok, cur)
        if ap is not None and self.hits(ap):
            raise Deny(rule, f"{what} → {ap}")

    # ---- Bash ----
    def eval_bash(self, cmd, cwd, depth):
        if depth > E.MAX_DEPTH:
            note("巢狀深度超過上限，停止遞迴")
            return
        bodies = heredoc_bodies(cmd)
        stripped, bad = E.strip_heredocs(cmd)
        if bad:
            self.fallback(cmd, cwd, "heredoc／引號不平衡")
            return
        stripped = stripped.replace(">|", "> ")
        try:
            segs, subs = E.tokenize_segments(stripped)
        except E.Ambiguous:
            self.fallback(cmd, cwd, "引號／$( )／反引號不平衡")
            return
        cur = cwd
        for seg in segs:
            pairs = [(E.clean_tok(t, q), q) for t, q in seg["tokens"]]
            seg_bodies = []
            for t, q in pairs:
                if not q and t == "<<" and bodies:
                    seg_bodies.append(bodies.pop(0))
            cur = self.eval_segment(pairs, seg_bodies, cur, depth)
        for sub in subs:
            self.eval_bash(sub, cur, depth + 1)

    def eval_segment(self, pairs, bodies, cur, depth):
        # W2 重導（段內任何位置）
        for i, (t, q) in enumerate(pairs):
            if q:
                continue
            m = REDIR_RE.match(t)
            if not m:
                continue
            target = m.group(3)
            if not target:
                target = pairs[i + 1][0] if i + 1 < len(pairs) else ""
            if not target or target.startswith("&"):
                continue
            self.check(target, cur, "W2", f"重導 {m.group(1)}{m.group(2)} {target}")

        cmd, idx = find_cmd(pairs)
        if cmd is None:
            return cur
        args = pairs[idx + 1:]

        if cmd in ("cd", "pushd"):
            pos = positionals(args)
            if not pos:
                return os.path.expanduser("~") if cmd == "cd" else None
            if pos[0] == "-":
                note("cd - 目的地無法解析，之後的相對路徑判不出（盲區）")
                return None
            return resolve(pos[0], cur)
        if cmd == "popd":
            return None

        if cmd in ALL_ARGS_CMDS:
            for t in positionals(args):
                self.check(t, cur, "W2", f"{cmd} {t}")
        if cmd in DEST_CMDS:
            dest = dest_of(cmd, args)
            if dest:
                self.check(dest, cur, "W2", f"{cmd} 目的地 {dest}")
        if cmd in INPLACE_CMDS and any((not q) and INPLACE_RE.match(t) for t, q in args):
            for t in inplace_files(args):
                self.check(t, cur, "W2", f"{cmd} -i {t}")
        if cmd == "git":
            d, sub, rest = git_parse(args, cur)
            mutating = sub in GIT_MUTATING or (
                sub == "stash" and (positionals(rest)[:1] or ["push"])[0] not in GIT_STASH_READONLY
            )
            if mutating and d is not None and self.hits(d, as_dir=True):
                raise Deny("W3", f"git {sub} 改動主 checkout working tree → {d}")
        if cmd in SHELLS:
            for i, (t, q) in enumerate(args):
                if q or i + 1 >= len(args):
                    continue
                if (E.BASH_SHORT_FLAG_RE.match(t) and "c" in t) or t == "<<<":
                    self.eval_bash(args[i + 1][0], cur, depth + 1)
            for body in bodies:
                self.eval_bash(body, cur, depth + 1)
        if cmd in INTERPRETERS:
            payloads = list(bodies)
            for i, (t, q) in enumerate(args):
                if not q and (t in PAYLOAD_FLAGS or t == "<<<") and i + 1 < len(args):
                    payloads.append(args[i + 1][0])
            for p in payloads:
                for m in ABS_PATH_RE.finditer(p):
                    path = m.group(1)
                    if UNRESOLVABLE_RE.search(path):
                        continue
                    ap = resolve(path, cur)
                    if ap is not None and self.hits(ap):
                        raise Deny("W4", f"{cmd} 內嵌程式碼提到主 checkout 路徑 {path}（讀寫無法判定，一律擋；讀檔請改用 Read／cat）")
        return cur

    def fallback(self, raw, cur, why):
        if FB_WRITE_RE.search(raw):
            for m in ABS_PATH_RE.finditer(raw):
                p = m.group(1)
                if UNRESOLVABLE_RE.search(p):
                    continue
                ap = resolve(p, cur)
                if ap is not None and self.hits(ap):
                    raise Deny("W5", f"命令無法完整斷詞（{why}），字面含主 checkout 路徑 {p} 與寫入樣式，fail-closed")
        note(f"命令無法完整斷詞（{why}），字面未見主 checkout 絕對路徑＋寫入樣式，放行（盲區，見 {COLL_REF}）")


# ============================================================================
# 輸出
# ============================================================================
def emit_deny(reason):
    sys.stdout.write(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }, ensure_ascii=False))
    sys.stderr.write(reason + "\n")
    sys.exit(2)


def flush_notes():
    for n in NOTES:
        sys.stderr.write(f"main-checkout-guard：{n}\n")


def main():
    raw = sys.stdin.read()
    if not raw.strip():
        emit_deny(f"W0：stdin 是空的，無法判斷 tool_input（fail-closed，見 {COLL_REF}）")
    try:
        d = json.loads(raw)
        if not isinstance(d, dict):
            raise ValueError("top-level not object")
    except Exception:
        emit_deny(f"W0：hook JSON 無法解析（fail-closed，見 {COLL_REF}）")
    tool = str(d.get("tool_name") or "")
    ti = d.get("tool_input")
    ti = ti if isinstance(ti, dict) else {}
    cwd = str(d.get("cwd") or "") or os.getcwd()
    global _ROOT_HINT
    _ROOT_HINT = root_hint(cwd)

    if os.environ.get(SWITCH) == "1":
        sys.stderr.write(f"main-checkout-guard：{SWITCH}=1（環境變數），放行 {tool}（主 checkout 寫入未受檢）\n")
        return 0

    g = Guard(cwd)
    try:
        if tool in FILE_TOOLS:
            path = str(ti.get("file_path") or ti.get("notebook_path") or "")
            if not path:
                note(f"{tool} 沒有 file_path／notebook_path，放行")
            else:
                g.check(path, cwd, "W1", f"{tool} {path}")
        elif tool == "Bash":
            command = str(ti.get("command") or "")
            if INLINE_SWITCH_RE.match(command):
                sys.stderr.write(f"main-checkout-guard：命令位置前綴帶 {SWITCH}=1，放行本次 Bash（主 checkout 寫入未受檢）\n")
                return 0
            g.eval_bash(command, cwd, 0)
        else:
            return 0
    except Deny as dn:
        emit_deny(
            f"{dn.rule}：主 checkout 禁寫（{dn.detail}）——請在自己的 worktree（.claude/worktrees/LS-<n>）作業；"
            f"harness 改動走 hotfix worktree（COLLABORATION §2 Worktree 規約／§7）；明確需要時以 "
            f"`{SWITCH}=1 <cmd>` 或 `env {SWITCH}=1 <cmd>` 開頭（整條命令最前面；Write／Edit 只認環境變數）放行該次"
        )
    flush_notes()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except GuardError as e:
        emit_deny(f"W0：{e}（fail-closed，見 {COLL_REF}）")
    except Exception as e:  # noqa: BLE001 - fail-closed on ANY unexpected error
        emit_deny(f"W0：main_checkout_guard.py 執行異常（{type(e).__name__}），fail-closed，見 {COLL_REF}")
