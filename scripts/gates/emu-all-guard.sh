#!/bin/bash
# scripts/gates/emu-all-guard.sh（LS-477，Android 前置 A3；iOS 對應物＝LS-469 的 simctl all guard）
#
# **PreToolUse fail-open gate**：擋 agent 的「一次影響所有 emulator／別票 emulator」Bash 指令。多個 worktree／agent
# 共用同一台機器的 adb server 與 emulator：一個 agent 為了「收乾淨自己的」下 `adb emu kill`（沒帶 -s 時
# 對唯一在線的 emulator 生效、多台時報錯，行為取決於當下有幾台）或 `adb kill-server`（砍掉共用 server，別人所有 adb 連線斷線、
# 進行中的 connected test 全掛），或把別票的 AVD 刪掉——正是 LS-462／LS-464 期間 iOS 側 `xcrun simctl shutdown all`
# 誤關別人模擬器的 Android 版。
#
# 極性＝fail-open（scripts/hooks/README.md 的判準）：漏擋的後果是「別人的 emulator 被關、重開機即可」，可事後補救；
# 擋錯（或 hook 自己壞掉）則會讓整條產線的 Bash 全卡死——所以 settings.json 的 command **不接 `|| exit 2`**，
# 腳本內部亦 fail-open（stdin 空／python3 缺席／JSON 壞／引擎異常 → exit 0 並 stderr 註明）。只有引擎明確判 deny 才 exit 2。
# 與 prod-push-guard.sh（fail-closed，漏擋＝不可逆寫進正式站）相反，理由同 fork-guard。
#
# 規則（命令文字先剝掉非 shell 直譯器接收端的 heredoc 內文，再用 shlex 依引號切 token，`; && || | & ( ) 換行 反引號` 是運算子 token；
# 只有出現在**命令位置**的 `adb`／`avdmanager`（basename 比對；前面可有 env 賦值、env／sudo／timeout／nohup／xargs 等 wrapper、
# then／do 等關鍵字）才檢查，`echo adb kill-server`、引號內的字樣、commit message 不算；`bash|sh|zsh -c '…'`／`eval '…'` 的引號內文遞迴再掃）：
#   K1  `adb … kill-server`（任何旗標組合）——共用 server 不得砍。
#   K2  `adb … emu kill` 沒有 `-s <serial>`——`-e`／`-d`／不帶都不算（「唯一一台」的假設在多 worktree 下不成立）。
#       `adb -s emulator-5554 emu kill`、`adb -s "$SERIAL" emu kill` 放行（-s 後面有值即可，值是變數也行）。
#   K3  `avdmanager … delete avd`：`-n`／`--name` 的名稱必須以 `LS-<本票>-` 開頭；本票號從 hook JSON 的 `cwd`
#       （票 worktree 路徑 `…/.claude/worktrees/LS-<n>…`）推，推不出來（不在票 worktree）一律 deny；名稱缺或含無法判斷的
#       變數展開（`LS-$N-Pixel8`）→ deny，要求寫字面名稱。清別人的／殘留的 AVD 請走 `bash scripts/ops/cleanup-merged.sh --apply LS-<n>`。
# 已知盲區（不經此 hook）：把指令包進 .sh 腳本再執行（命令文字不含 adb，如 `bash scripts/ops/foo.sh`）、`for s in $(adb devices …); do
# adb -s $s emu kill; done` 這種帶 -s 的迴圈（形式上是逐台指定，語意仍是全殺）、`pkill -f emulator`／`killall qemu-system-*`、
# ssh／docker exec 內的遠端命令、heredoc 餵給 `cat … | bash`（管線接收端不追）、變數組字串。已知誤擋：無引號、位於命令位置的
# `adb kill-server` 出現在 echo 以外的散文裡（極少見）。
#
# deny 輸出：stdout `{"hookSpecificOutput":{…"permissionDecision":"deny","permissionDecisionReason":"…"}}`＋stderr 同一句理由，exit 2；
# 允許＝exit 0 無輸出。reason 只放本檔案自己寫的靜態文字，不回顯命令內容。
# 自測：scripts/gates/emu-all-guard.test.sh（正負樣本＋fail-open＋settings.json 接線極性＋mutation，掛 CI rules job）。
# 生效：改完 settings.json 需 `/hooks` 或重開 session 才載入新 matcher。
set -u

COLL_REF="docs/COLLABORATION.md §7"

json_deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$1"
}
fail_open() {
  echo "emu-all-guard：$1，fail-open 放行（見 ${COLL_REF}）" >&2
  exit 0
}

input=
IFS= read -r -d '' input || true
[ -n "$input" ] || fail_open "stdin 是空的，無法判斷 tool_input"
command -v python3 >/dev/null 2>&1 || fail_open "python3 不存在，無法判斷命令"

IFS= read -r -d '' ENGINE <<'PYEOF' || true
import json, os, re, shlex, sys

OPS = set(";|&()\n`")
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
WRAPPERS = {"env", "sudo", "time", "command", "exec", "nohup", "nice", "timeout", "gtimeout", "xargs", "stdbuf", "ionice"}
KEYWORDS = {"then", "do", "else", "elif", "if", "while", "until", "!", "{", "}"}
ADB_VALUE_OPTS = {"-s", "-t", "-H", "-P", "-L"}
REASONS = {
    "K1": "LS-477：adb kill-server 會砍掉共用的 adb server——別的 worktree／agent 的 adb 連線與進行中的 connected test 全部中斷。只關自己的 emulator：bash scripts/gates/detect-emulator.sh --stop（或 adb -s <serial> emu kill）",
    "K2": "LS-477：adb emu kill 必須帶 -s <serial>（-e／-d／不帶都不行）——多個 worktree 共用機器，無 -s 時關到誰取決於當下有幾台 emulator。先 adb devices 找出自己的 serial（detect-emulator.sh 印過），再 adb -s <serial> emu kill；或 bash scripts/gates/detect-emulator.sh --stop",
    "K3": "LS-477：avdmanager delete avd 只能刪本票自己的 AVD（-n LS-<本票>-Pixel8，字面名稱；本票號取自目前所在的票 worktree）。清別票／殘留的 AVD 請走 bash scripts/ops/cleanup-merged.sh --apply LS-<n>（會先檢查鎖並用 adb -s 關機）",
}


def tokenize(cmd, punct):
    s = shlex.shlex(cmd, posix=True, punctuation_chars=punct)
    s.whitespace_split = True
    s.commenters = ""
    s.whitespace = " \t\r"
    return list(s)


def is_op(tok):
    return tok != "" and all(ch in OPS for ch in tok)


REDIR = re.compile(r"^(?:<<-?|<<<|<&|>&|&>>?|>>|<|>\|?)$")


def first_word_is_shell_stdin(line):
    """這一行（含 `<<`）的首詞（去掉 env 賦值／wrapper）是 bash 等直譯器且沒有腳本路徑參數 → heredoc 內文會被當 shell 執行。"""
    try:
        words = tokenize(line, "();<>|&`")
    except ValueError:
        return True
    seg = []
    for w in words:
        if is_op(w):
            break
        seg.append(w)
    clean = []
    i = 0
    while i < len(seg):
        if REDIR.match(seg[i]):
            i += 2
        elif seg[i].isdigit() and i + 1 < len(seg) and REDIR.match(seg[i + 1]):
            i += 1
        else:
            clean.append(seg[i])
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


def heredoc_delims(line):
    """引號外的 `<<`／`<<-` 終止符 [(delim, dash)]；`<<<` 不算。"""
    found, q, i = [], None, 0
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
                found.append((next(g for g in m.groups()[1:] if g is not None), m.group(1) == "-"))
                i += m.end()
                continue
        i += 1
    return found


def strip_heredocs(command):
    """剝掉非 shell 直譯器接收端（cat／tee／python3／gh --body-file - 等）的 heredoc 內文——PR body、handoff 草稿常寫到
    被禁的字樣；終止符找不到就整段不剝（fail closed 於「照掃」這個方向）。"""
    lines = command.split("\n")
    out, i = [], 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        i += 1
        ds = heredoc_delims(line)
        if not ds:
            continue
        keep = first_word_is_shell_stdin(line)
        j, spans, ok = i, [], True
        for delim, dash in ds:
            k = j
            while k < len(lines) and (lines[k].lstrip("\t") if dash else lines[k]) != delim:
                k += 1
            if k >= len(lines):
                ok = False
                break
            spans.append((j, k))
            j = k + 1
        if not ok:
            continue
        for a, b in spans:
            if keep:
                out.extend(lines[a:b + 1])
        i = j
    return "\n".join(out)


def at_command_position(t, i):
    """t[i] 是命令字嗎？往回走：略過 env 賦值、wrapper 及其旗標／數字引數、shell 關鍵字，走到開頭或運算子 → 是。"""
    j = i - 1
    while j >= 0:
        p = t[j]
        if is_op(p):
            return True
        if re.match(r"^[A-Za-z_][\w-]*=", p) or os.path.basename(p) in WRAPPERS or p in KEYWORDS or p.startswith("-") or p.isdigit():
            j -= 1
            continue
        return False
    return True


def adb_verdict(args):
    """args＝adb 之後、下一個運算子之前。回傳 'K1'／'K2'／None。"""
    serial_ok = False
    i = 0
    while i < len(args):
        a = args[i]
        if a in ADB_VALUE_OPTS:
            has_val = i + 1 < len(args) and args[i + 1] != "" and not args[i + 1].startswith("-")
            if a == "-s" and has_val:
                serial_ok = True
            i += 2 if has_val else 1   # 缺值（下一個是旗標）只吃自己，別把後面的旗標／子命令一起吞掉
        elif a.startswith("-"):
            i += 1
        else:
            break
    sub = args[i:i + 2]
    if sub[:1] == ["kill-server"]:
        return "K1"
    if sub[:2] == ["emu", "kill"] and not serial_ok:
        return "K2"
    return None


def avd_verdict(args, ticket):
    """avdmanager delete avd：名稱須為字面 LS-<本票>-…。回傳 'K3'／None。"""
    if not any(args[k:k + 2] == ["delete", "avd"] for k in range(max(0, len(args) - 1))):
        return None
    name = None
    for k, a in enumerate(args):
        if a in ("-n", "--name"):
            name = args[k + 1] if k + 1 < len(args) else ""
        elif a.startswith("--name="):
            name = a[len("--name="):]
    if not ticket or not name:
        return "K3"
    if "$" in name or "`" in name:
        return "K3"
    return None if name.startswith("%s-" % ticket) else "K3"


def scan_tokens(t, ticket, depth):
    for i, tok in enumerate(t):
        base = os.path.basename(tok)
        if base in ("adb", "avdmanager") and at_command_position(t, i):
            j = i + 1
            while j < len(t) and not is_op(t[j]):
                j += 1
            v = adb_verdict(t[i + 1:j]) if base == "adb" else avd_verdict(t[i + 1:j], ticket)
            if v:
                return v
        elif (base in SHELLS or base == "eval") and depth < 3 and at_command_position(t, i):
            if base == "eval":
                inner = t[i + 1] if i + 1 < len(t) else None
            else:
                c = next((k for k in range(i + 1, len(t)) if re.match(r"^-[a-z]*c[a-z]*$", t[k])), None)
                inner = t[c + 1] if c is not None and c + 1 < len(t) else None
            if inner:
                v = scan(inner, ticket, depth + 1)
                if v:
                    return v
    return None


def scan(command, ticket, depth=0):
    command = strip_heredocs(command.replace("\\\n", " "))
    for punct in ("();<>|&\n`", "();<>|\n`"):
        try:
            v = scan_tokens(tokenize(command, punct), ticket, depth)
        except ValueError:
            # 引號未閉合等：退回空白切詞再判一次（fail toward 檢查，不放行）
            raw = command.split()
            v = None
            for i, w in enumerate(raw):
                b = os.path.basename(w)
                if b == "adb":
                    v = adb_verdict(raw[i + 1:]) or v
                elif b == "avdmanager":
                    v = avd_verdict(raw[i + 1:], ticket) or v
            return v
        if v:
            return v
    return None


try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(3)
ti = data.get("tool_input") if isinstance(data, dict) else None
cmd = ti.get("command") if isinstance(ti, dict) else None
if not isinstance(cmd, str) or not cmd:
    sys.exit(0)
cwd = data.get("cwd") if isinstance(data.get("cwd"), str) else os.getcwd()
m = re.search(r"/\.claude/worktrees/(LS-\d+)(?![\d])", cwd)
ticket = m.group(1) if m else None
v = scan(cmd, ticket)
if v:
    print(REASONS[v])
    sys.exit(2)
sys.exit(0)
PYEOF

out=$(printf '%s' "$input" | python3 -c "$ENGINE")
rc=$?
case "$rc" in
  0) exit 0 ;;
  2)
    [ -n "$out" ] || out="LS-477：偵測到會影響所有／別人 emulator 的 adb／avdmanager 指令（引擎未回傳理由文字），見 ${COLL_REF}"
    json_deny "$out"
    echo "$out" >&2
    exit 2
    ;;
  3) fail_open "hook JSON 解析失敗" ;;
  *) fail_open "判定引擎執行異常（rc=${rc}）" ;;
esac
