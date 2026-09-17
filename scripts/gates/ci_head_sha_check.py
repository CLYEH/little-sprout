#!/usr/bin/env python3
"""LS-318 ci.yml head-sha 接線自測（供 ci-head-sha-check.sh 呼叫）。

判定方式、呼叫清單、白名單格式皆見 ci-head-sha-check.sh 檔頭；這支只做解析與比對，不碰檔案系統以外的
git／gh 呼叫。不用 PyYAML——本檔其餘 python gate（design_ref_check.py／design_notes_check.py 等）一貫只依
賴標準庫，CI runner 沒有保證裝 PyYAML；改用縮排狀態機找 step 邊界，只需認得 ci.yml 自己一貫的固定排版
（`- name:` 起始一個 step，下一個同縮排或更淺縮排的 `- name:` 結束這個 step）。

用法：ci_head_sha_check.py <ci.yml 路徑> <呼叫清單腳本名，以空白分隔> [白名單，以 ; 分隔的「step 名稱|理由」]
"""
import re
import sys

# 同 design_ref_check.py 慣例：本模組不留 __pycache__。
sys.dont_write_bytecode = True

STEP_RE = re.compile(r"^([ \t]*)-\s+name:\s*(.*?)\s*$")
HEAD_SHA_ENV_RE = re.compile(
    r"HEAD_SHA:\s*\$\{\{\s*github\.event\.pull_request\.head\.sha\s*\}\}"
)


def parse_steps(lines):
    """回傳 [(name, start_idx, end_idx)]，end_idx 為 exclusive（下一個同縮排或更淺 step 的起點，或 EOF）。"""
    starts = []
    for i, line in enumerate(lines):
        m = STEP_RE.match(line)
        if m:
            starts.append((i, len(m.group(1)), m.group(2)))
    steps = []
    for k, (start, indent, name) in enumerate(starts):
        end = len(lines)
        for nxt_start, nxt_indent, _ in starts[k + 1:]:
            if nxt_indent <= indent:
                end = nxt_start
                break
        steps.append((name, start, end))
    return steps


def _is_comment(line):
    return line.strip().startswith("#")


def find_violations(lines, call_list, whitelist):
    """回傳 (violations, checked, whitelisted) 三元組。

    註解裡的提及不算命中（同 selftest-wiring-check.sh 既有慣例——ci.yml 的說明註解常引用其他 step
    要呼叫的 gate script 名稱，例如「PR body 檔頭段」step 之前的說明段落會先提到
    `scripts/gates/pr-body-check.sh`，若不排除註解，這段話會被誤判成「前一個 step（分支起點乾淨度）
    也呼叫了 pr-body-check.sh」——block 邊界以「下一個 step 的 `- name:`」為界，說明註解在檔案順序上
    緊接在前一個 step 之後、下一個 step 之前）。
    """
    violations = []
    checked = 0
    whitelisted = 0
    for name, start, end in parse_steps(lines):
        block = lines[start:end]
        code_lines = [(off, raw) for off, raw in enumerate(block) if not _is_comment(raw)]
        code_text = "".join(raw for _, raw in code_lines)
        hit = [n for n in call_list if ("scripts/gates/%s" % n) in code_text]
        if not hit:
            continue
        checked += 1
        if name in whitelist:
            whitelisted += 1
            continue
        if not HEAD_SHA_ENV_RE.search(code_text):
            violations.append(
                'step「%s」命中呼叫清單 %s，但 env 缺 HEAD_SHA: ${{ github.event.pull_request.head.sha }}'
                % (name, hit)
            )
        for hn in hit:
            needle = "scripts/gates/%s" % hn
            call_lines = [(start + off + 1, raw) for off, raw in code_lines if needle in raw]
            missing = [ln for ln, raw in call_lines if "--head-sha" not in raw]
            for ln in missing:
                violations.append(
                    "step「%s」呼叫 %s（第 %d 行）沒有帶 --head-sha" % (name, hn, ln)
                )
    return violations, checked, whitelisted


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("✗ ci_head_sha_check：缺 <ci.yml 路徑> <呼叫清單>\n")
        return 2
    ci_path = argv[0]
    call_list = [n for n in argv[1].split() if n]
    whitelist = {}
    if len(argv) > 2 and argv[2]:
        for entry in argv[2].split(";"):
            if not entry:
                continue
            wname, _, reason = entry.partition("|")
            whitelist[wname] = reason

    try:
        with open(ci_path, encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError as exc:
        sys.stderr.write("✗ ci_head_sha_check：讀不到 %s（%s）\n" % (ci_path, exc))
        return 2

    violations, checked, whitelisted = find_violations(lines, call_list, whitelist)
    summary = "%d 個 step 命中呼叫清單（白名單 %d 個）" % (checked, whitelisted)

    if violations:
        for v in violations:
            sys.stderr.write("✗ %s\n" % v)
        sys.stderr.write(
            "✗ ci_head_sha_check：%s，%d 處缺 head-sha 接線（LS-127／LS-316 同型再犯；docs/COLLABORATION.md §7）\n"
            % (summary, len(violations))
        )
        return 1

    print("✓ ci_head_sha_check：%s，皆已接好 HEAD_SHA／--head-sha" % summary)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
