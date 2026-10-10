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
# 當次授權」、§7 對照表）：
#   命令位置（命令串首、或 ; && || | 換行 ( 之後，可帶 env 賦值／sudo／env／time／xargs／npx／
#   `bash scripts/ops/supabase-lock.sh --`／`bash -c '…'` 這類前綴）出現 `supabase …`，且屬下列任一 → 視為「打正式站」：
#     (a) 帶 `--linked`（任何子指令）
#     (b) 帶 `--db-url` 且 host 不在 127.0.0.1／localhost／host.docker.internal（值取不出來或是
#         `$VAR` 之類無法判斷者一律視為非 localhost，fail closed）
#     (c) `db push` 且沒有 `--local`、也沒有 localhost 的 `--db-url`（`db push` 預設就是 linked）
#     (d) `functions deploy`／`secrets set`（沒有本機模式，一律打遠端；票文只列 db push／migration
#         up／--db-url，這兩個同屬正式站部署面，orchestrator 裁定納入）
#   `migration up` 不帶 --linked／遠端 --db-url 時預設是本機（CLI 預設 --local），放行。
#   本機 `supabase start`／`stop`／`status`／`db reset`／`db query`（無 --linked）放行。
#   「打正式站」且命令全文（不分位置）沒有 `PROD-PUSH-APPROVED-BY-USER=<今日>` → deny。
#   今日＝`date +%F`；環境變數 `PROD_PUSH_GUARD_TODAY=YYYY-MM-DD` 可覆寫（只供自測；hook 行程的環境
#   變數，agent 寫在命令前綴的同名賦值不影響 hook）。過期日期、少一位、日期後再接數字皆不算。
#   寫法：連字號名稱不是合法 shell 賦值，前綴要用 `env PROD-PUSH-APPROVED-BY-USER=<日期> supabase db push …`
#   （或同命令內 `echo`／註解帶字面）；本檔解析認得 env 後帶連字號名稱的 token。
#   token 只有使用者能在對話中給出：orchestrator 不得自行生成，deny 理由刻意只印格式佔位
#   `<YYYY-MM-DD>`，不印今日日期。
#
# 已知盲區（靠規約 §6「不改寫指令繞過」與 auto-mode 分類器）：把指令包進 .sh 腳本再執行（命令文字
# 不含 supabase，如 `bash scripts/ops/foo.sh`）、`supabase --workdir x db push` 這種旗標夾在子指令
# 中間、變數展開組字串、`psql`／`curl` 直打 Management API 或正式站連線字串——這些不經此 hook。
# 子指令比對是對 supabase 之後的字串做 regex，不剖析旗標值。
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
SEP = re.compile(r"\$\(|&&|\|\||[;|\n()`]|\s&\s")
WRAPPERS = {"env", "sudo", "time", "command", "exec", "nohup", "xargs", "npx", "bunx", "nice", "builtin"}
SHELLS = {"bash", "sh", "zsh"}


def toks(seg):
    try:
        return shlex.split(seg)
    except ValueError:
        return seg.split()


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
    """args＝supabase 之後的 token。回傳 True＝打正式站。"""
    text = " ".join(args)
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
    if re.search(r"(?:^|\s)(functions\s+deploy|secrets\s+set)(?=\s|$)", text):
        return True
    if re.search(r"(?:^|\s)db\s+push(?=\s|$)", text) and dburl is None and not has_local:
        return True
    return False


def scan(command, depth=0):
    for seg in SEP.split(command):
        t = toks(seg)
        i = 0
        while i < len(t):
            tok = t[i]
            base = os.path.basename(tok)
            if re.match(r"^[A-Za-z_][\w-]*=", tok) or base in WRAPPERS:
                i += 1
            elif base == "supabase":
                if remote_target(t[i + 1:]):
                    return True
                break
            elif base == "supabase-lock.sh":
                j = t.index("--") if "--" in t[i:] else None
                if j is None:
                    break
                i = j + 1
            elif base in SHELLS:
                c = next((k for k in range(i + 1, len(t)) if re.match(r"^-[a-z]*c[a-z]*$", t[k])), None)
                if c is not None and c + 1 < len(t) and depth < 3:
                    if scan(t[c + 1], depth + 1):
                        return True
                    break
                i += 1
            else:
                break
    return False


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
