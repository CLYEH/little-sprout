#!/bin/bash
# scripts/gates/prod-push-guard.sh（LS-78）
#
# **PreToolUse fail-closed gate**：擋 agent 對正式站的部署面指令，除非同一條命令帶使用者當次給的
# `PROD-PUSH-APPROVED-BY-USER=<今日 YYYY-MM-DD>` 字面。`.claude/settings.json` 的 wiring 接
# `|| exit 2`（腳本壞掉＝deny），腳本內部亦 fail-closed（空 stdin／JSON 解析失敗／python3 缺席／
# 意外中止 → deny）。選 fail-closed 的理由：漏擋＝未經人審的 schema／資料／secret 寫進有真實家庭
# 資料的正式站，不可逆；擋錯只是多一次回報使用者（極性判準見 scripts/hooks/README.md）。
#
# 規則（docs/COLLABORATION.md §6「DB migration gate」末段「正式站 `supabase db push` 每次需使用者
# 當次授權」引用本段為涵蓋清單的唯一來源，§7 對照表同；R2 改版，LS-78）：
#   命令文字（先把行尾 `\`＋換行摺成空白，再用 shlex 依引號切 token，`; && || | & ( ) 換行 反引號` 是運算子
#   token、引號內的這些字元不算）任一處出現 `supabase` token（basename 等於 supabase，前面是 timeout／
#   env／sudo／xargs／npx／`supabase-lock.sh --`／then／{ 等任何東西都算；`bash|sh|zsh -c '…'`／`eval '…'`
#   的引號內文遞迴再掃），取其後到下一個運算子 token 為止的 args，屬下列任一 → 視為「打正式站」：
#     (a) 帶 `--linked`（任何子指令；含唯讀的 `db query --linked`／`db dump --linked`）
#     (b) 帶 `--db-url` 且 host 不在 127.0.0.1／localhost／host.docker.internal（值取不出來或是
#         `$VAR` 之類無法判斷者一律視為非 localhost，fail closed）
#     (c) 預設 linked 的寫入類子指令：`db push`、`migration repair`、`config push`、`storage rm|cp|mv`
#         （storage 三者依 CLI help 只列 --linked／--local，預設值未實測，保守當 linked），沒有 `--local`、
#         也沒有 localhost 的 `--db-url` 時
#     (d) 沒有本機模式、一律打遠端的子指令：`functions deploy`、`functions delete`、`secrets set`、
#         `secrets unset`（票文只列 db push／migration up／--db-url，其餘同屬正式站寫入面，orchestrator 裁定納入）
#   `migration up` 不帶 --linked／遠端 --db-url 時預設是本機（CLI 預設 --local），放行。
#   本機 `supabase start`／`stop`／`status`／`db reset`／`db query`（無 --linked）放行。
#   子指令比對只看不含空白的 args token（引號內整段 SQL 之類不參與），regex 對串起來的 args 比對，所以
#   `supabase --workdir x db push` 這種旗標夾在 supabase 與子指令之間仍會擋。
#   heredoc（R3／R4，LS-78）：`<<`／`<<-` 到獨佔行終止符之間的內文，是否照掃只看「含 `<<` 的那個 simple command
#   的首詞（去掉重導向／env 賦值／env／sudo／timeout 等 wrapper 後）」加上其後以 `|` 串接的各段首詞：
#   首詞是 bash／sh／zsh／dash／ksh 且沒有腳本路徑參數（`bash <<X`、`bash -s <<X`、`sh - <<X`）、或 source／`.`／eval
#   → 保留內文照掃；`bash scripts/ops/x.sh <<X`（首個非旗標參數含 `/` 或 `.sh` 結尾）是腳本的 stdin、不是被執行的命令，
#   略過；其餘（cat／tee／python3／node／`gh … --body-file -`／`supabase db query` 等）一律略過——DB 票的 verdict／PR body
#   草稿、handoff 檔（`cat > f <<X … X && bash …handoff-evidence-check.sh f`）、LS-308 備援
#   （`bash scripts/ops/linear-post.sh comment … /dev/stdin <<X`）幾乎都要寫到 `supabase db push` 字樣。同行其他
#   `&&`／`;` 分段的命令字不算；在 `$(`／反引號內退回整行有無 shell 字。`<<` 本行（含後接 `&& supabase db push --linked`）
#   與終止符之後的行照掃；找不到終止符就整段不剝（fail closed）；引號內的 `<<` 不算。
#   shlex 遇到未閉合引號等 ValueError 時 fail closed：把整段原文當 args 再判一次。
#   「打正式站」且命令全文（不分位置）沒有 `PROD-PUSH-APPROVED-BY-USER=<今日>` → deny。
#   今日＝`date +%F`；環境變數 `PROD_PUSH_GUARD_TODAY=YYYY-MM-DD` 可覆寫（只供自測；hook 行程的環境
#   變數，agent 寫在命令前綴的同名賦值不影響 hook）。過期日期、少一位、日期後再接數字皆不算。
#   寫法：連字號名稱不是合法 shell 賦值，前綴要用 `env PROD-PUSH-APPROVED-BY-USER=<日期> supabase db push …`
#   （或同命令內 `echo`／註解帶字面）。
#   token 只有使用者能在對話中給出：orchestrator 不得自行生成，deny 理由刻意只印格式佔位
#   `<YYYY-MM-DD>`，不印今日日期。
#
# 已知盲區（靠規約 §6「不改寫指令繞過」與 auto-mode 分類器）：把指令包進 .sh 腳本再執行（命令文字
# 不含 supabase，如 `bash scripts/ops/foo.sh`）、變數展開組字串、旗標夾在子指令兩個字之間
# （`db --workdir x push`）、`ssh`／`docker exec` 等引號內遠端命令、`psql`／`curl` 直打
# Management API 或正式站連線字串、`python3 - <<X` 等非 shell 直譯器 heredoc 內文裡 `subprocess.run(["supabase",
# "db","push"])` 這類程式碼、先用 cat heredoc 寫出 .sh 再下一行 `bash x.sh`、`xargs supabase <<X`（子指令與旗標在內文）、
# 跨行引號內的偽 heredoc、`$((1<<2))` 算術位移被誤認 heredoc、引號包住的多行命令替換內的 heredoc（R3／R4 接受的盲區）——這些不經此 hook。已知誤擋（寧可擋錯）：無引號的 `supabase db push`
# 字樣出現在 echo 散文、`# supabase db push` 整行註解。
#
# deny 輸出：stdout `{"hookSpecificOutput":{…"permissionDecision":"deny","permissionDecisionReason":"…"}}`
# ＋stderr 同一句理由，exit 2；允許＝exit 0 無輸出。reason 只放本檔案自己寫的靜態文字，不回顯命令內容。
# 自測：scripts/gates/prod-push-guard.test.sh（掛 CI rules job）。生效：改完 settings.json 需 `/hooks`
# 或重開 session 才載入新 matcher。
set -u

RESPONDED=
COLL_REF="docs/COLLABORATION.md §6"

json_deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$1"
}

final_deny() {
  json_deny "$1"
  printf '%s\n' "$1" >&2
  RESPONDED=1
  exit 2
}

final_allow() {
  RESPONDED=1
  exit 0
}

on_exit() {
  if [ -z "$RESPONDED" ]; then
    json_deny "LS-78：prod-push-guard.sh 未預期中止（fail-closed），見 ${COLL_REF}"
    exit 2
  fi
}
trap on_exit EXIT

input=
IFS= read -r -d '' input || true
[ -n "$input" ] || final_deny "LS-78：stdin 是空的，無法判斷 tool_input（fail-closed），見 ${COLL_REF}"
command -v python3 >/dev/null 2>&1 || final_deny "LS-78：python3 不存在，無法判斷命令（fail-closed），見 ${COLL_REF}"

today=${PROD_PUSH_GUARD_TODAY:-$(date +%F)}

# 判定引擎：stdin 收 hook JSON。rc 0＝放行；2＝正式站部署面且無當日 token（stdout 無內容）；3＝JSON 壞。
# 以 heredoc 賦值（不用 `python3 -c "$(…)"` 單引號包法，引擎內可自由使用單雙引號）；命令字串走 stdin，不經 argv（避免超長命令撞 ARG_MAX）。
IFS= read -r -d '' ENGINE <<'PYEOF' || true
import json, os, re, shlex, sys
from urllib.parse import urlparse

LOCAL_HOSTS = {"127.0.0.1", "localhost", "host.docker.internal"}
OPS = set(";|&()\n`")
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
ALWAYS_REMOTE = r"(?:^|\s)(?:functions\s+(?:deploy|delete)|secrets\s+(?:set|unset))(?=\s|$)"
DEFAULT_LINKED = r"(?:^|\s)(?:db\s+push|migration\s+repair|config\s+push|storage\s+(?:rm|cp|mv))(?=\s|$)"


def tokenize(cmd, punct):
    s = shlex.shlex(cmd, posix=True, punctuation_chars=punct)
    s.whitespace_split = True
    s.commenters = ""
    s.whitespace = " \t\r"
    return list(s)


def host_of(url):
    if not url:
        return ""
    u = url.strip("'\"")
    try:
        p = urlparse(u)
        if p.hostname:
            return p.hostname
    except ValueError:
        pass
    m = re.search(r"@([^:/?\s]+)", u)
    return m.group(1) if m else ""


def remote_target(args):
    """args＝supabase 之後、下一個運算子之前的 token。回傳 True＝打正式站。"""
    text = " ".join(a for a in args if not re.search(r"\s", a))
    linked = any(a == "--linked" or a.startswith("--linked=") for a in args)
    has_local = "--local" in args
    dburl = None
    for k, a in enumerate(args):
        if a == "--db-url":
            dburl = args[k + 1] if k + 1 < len(args) else ""
        elif a.startswith("--db-url="):
            dburl = a[len("--db-url="):]
    if linked:
        return True
    if dburl is not None and host_of(dburl) not in LOCAL_HOSTS:
        return True
    if re.search(ALWAYS_REMOTE, text):
        return True
    if re.search(DEFAULT_LINKED, text) and dburl is None and not has_local:
        return True
    return False


def is_op(tok):
    return tok != "" and all(ch in OPS for ch in tok)


def scan_tokens(t, depth):
    for i, tok in enumerate(t):
        base = os.path.basename(tok)
        if base == "supabase":
            j = i + 1
            while j < len(t) and not is_op(t[j]):
                j += 1
            if remote_target(t[i + 1:j]):
                return True
        elif (base in SHELLS or base == "eval") and depth < 3:
            if base == "eval":
                inner = t[i + 1] if i + 1 < len(t) else None
            else:
                c = next((k for k in range(i + 1, len(t)) if re.match(r"^-[a-z]*c[a-z]*$", t[k])), None)
                inner = t[c + 1] if c is not None and c + 1 < len(t) else None
            if inner and scan(inner, depth + 1):
                return True
    return False


REDIR = re.compile(r"^(?:<<-?|<<<|<&|>&|&>>?|>>|<|>\|?)$")
WRAPPERS = {"env", "sudo", "time", "command", "exec", "nohup", "nice", "timeout", "gtimeout"}


def stdin_is_shell(words):
    """這個 simple command 的 stdin 會被當 shell 命令執行嗎？首詞（去掉重導向／env 賦值／wrapper）是
    bash 等直譯器且沒有腳本路徑參數（`bash <<X`／`bash -s`／`sh -`），或 source／.／eval。
    `bash scripts/ops/x.sh <<X` 的 heredoc 是腳本的 stdin、不是被執行的命令，不算。"""
    clean = []
    i = 0
    while i < len(words):
        if REDIR.match(words[i]):
            i += 2
        elif words[i].isdigit() and i + 1 < len(words) and REDIR.match(words[i + 1]):
            i += 1
        else:
            clean.append(words[i])
            i += 1
    i = 0
    while i < len(clean):
        if re.match(r"^[A-Za-z_][\w-]*=", clean[i]):
            i += 1
        elif os.path.basename(clean[i]) in WRAPPERS:
            i += 1
            while i < len(clean) and (clean[i].startswith("-") or clean[i].isdigit()):
                i += 1
        else:
            break
    if i >= len(clean):
        return False
    cmd = os.path.basename(clean[i])
    args = clean[i + 1:]
    if cmd in ("source", ".", "eval"):
        return True
    if cmd in SHELLS:
        first = next((a for a in args if not a.startswith("-")), None)
        return not (first is not None and ("/" in first or first.endswith(".sh")))
    return False


def heredoc_keeps(line):
    """依序回傳該行每個 `<<` 的「內文要不要照掃」。看含 `<<` 的 simple command 首詞，加上其後以 `|` 串接的各段首詞；
    在 `$(`／反引號內則退回整行有無 shell 字。tokenize 失敗回 None（呼叫端一律保留）。"""
    try:
        toks = tokenize(line, "();<>|&`")
    except ValueError:
        return None
    segs = []
    cur = []
    sep = None
    for t in toks:
        if is_op(t):
            segs.append((sep, cur))
            cur = []
            sep = t
        else:
            cur.append(t)
    segs.append((sep, cur))
    line_has_shell = any(os.path.basename(t) in SHELLS or t in ("eval", "source", ".") for t in toks)
    keeps = []
    for k, (sep_k, words) in enumerate(segs):
        for _ in range(words.count("<<")):
            if sep_k in ("(", "`"):
                keeps.append(line_has_shell)
                continue
            keep = stdin_is_shell(words)
            j = k + 1
            while not keep and j < len(segs) and segs[j][0] in ("|", "|&"):
                keep = stdin_is_shell(segs[j][1])
                j += 1
            keeps.append(keep)
    return keeps


def heredocs_on(line):
    """回傳這一行（引號外）所有 heredoc：[(終止符, 是否 <<-, 內文是否照掃)]。"""
    found = []
    q = None
    i = 0
    while i < len(line):
        ch = line[i]
        if q:
            if ch == q:
                q = None
            elif ch == "\\" and q == '"':
                i += 1
        elif ch in "'\"":
            q = ch
        elif ch == "\\":
            i += 1
        elif line.startswith("<<<", i):
            i += 3
            continue
        elif line.startswith("<<", i):
            m = re.match(r"<<(-?)\s*(?:'([^']*)'|\"([^\"]*)\"|([^\s;|&()<>]+))", line[i:])
            if m:
                delim = next(g for g in m.groups()[1:] if g is not None)
                found.append((delim, m.group(1) == "-"))
                i += m.end()
                continue
        i += 1
    if not found:
        return []
    keeps = heredoc_keeps(line)
    if keeps is None or len(keeps) != len(found):
        keeps = [True] * len(found)
    return [(d, dash, kp) for (d, dash), kp in zip(found, keeps)]


def strip_heredocs(command):
    """剝掉非 shell 直譯器接收端（cat／tee／python3／gh --body-file - 等）的 heredoc 內文；終止符找不到就整行不剝（fail closed）。"""
    lines = command.split("\n")
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        i += 1
        hs = heredocs_on(line)
        if not hs:
            continue
        spans = []
        j = i
        ok = True
        for delim, dash, keep in hs:
            k = j
            while k < len(lines) and (lines[k].lstrip("\t") if dash else lines[k]) != delim:
                k += 1
            if k >= len(lines):
                ok = False
                break
            spans.append((j, k, keep))
            j = k + 1
        if not ok:
            continue
        for a, b, keep in spans:
            if keep:
                out.extend(lines[a:b + 1])
        i = j
    return "\n".join(out)


def scan(command, depth=0):
    command = strip_heredocs(command.replace("\\\n", " "))
    # 兩種標點集合各掃一次取聯集：含 & 時 URL 查詢字串的 & 會切斷 args（--db-url 後的 --linked 掉出去）；
    # 不含 & 時 `true&&supabase` 這種黏在一起的寫法看不到 supabase token。
    try:
        for punct in ("();<>|&\n`", "();<>|\n`"):
            if scan_tokens(tokenize(command, punct), depth):
                return True
        return False
    except ValueError:
        raw = command.split()
        return any(os.path.basename(w) == "supabase" for w in raw) and remote_target(raw)


try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(3)
ti = data.get("tool_input") if isinstance(data, dict) else None
cmd = ti.get("command") if isinstance(ti, dict) else None
if not isinstance(cmd, str) or not cmd:
    sys.exit(0)
if not scan(cmd):
    sys.exit(0)
tok = re.compile(r"(?<![\w-])PROD-PUSH-APPROVED-BY-USER=" + re.escape(os.environ["PPG_TODAY"]) + r"(?![\w-])")
sys.exit(0 if tok.search(cmd) else 2)
PYEOF

printf '%s' "$input" | PPG_TODAY="$today" python3 -c "$ENGINE"
rc=$?
case "$rc" in
  0) final_allow ;;
  2) final_deny "LS-78：偵測到對正式站的部署面指令（supabase db push／functions deploy／secrets set，或 --linked／非 localhost 的 --db-url），且同一條命令沒有使用者當次給的核可字面。正式站每次部署需使用者當次授權（${COLL_REF}）：請停下回報使用者；使用者在對話中給出 PROD-PUSH-APPROVED-BY-USER=<YYYY-MM-DD>（當日日期）後，把該字面原樣放進同一條命令，例如 env PROD-PUSH-APPROVED-BY-USER=<YYYY-MM-DD> supabase db push …（名稱含連字號，不是合法的 shell 賦值前綴，要經 env 或寫成同命令內的 echo／註解）。agent 不得自行生成日期或改寫指令繞過。本機容器（--local／127.0.0.1／localhost／host.docker.internal）不受限。" ;;
  3) final_deny "LS-78：hook JSON 解析失敗（fail-closed），見 ${COLL_REF}" ;;
  *) final_deny "LS-78：prod-push-guard 判定引擎執行異常（rc=${rc}，fail-closed），見 ${COLL_REF}" ;;
esac
