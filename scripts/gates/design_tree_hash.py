#!/usr/bin/env python3
"""LS-168 .pen 全樹雜湊（tree_hash）——design-evidence-check.sh 用來驗「收據對應 head_sha 那份 .pen」。

必須與 scripts/design/overflow-scan.js 的 `canonNode`／`treeHash`（Pencil execute 內印在 SUMMARY 的 tree_hash）
逐位元同值；overflow-scan.test.js 與 design-evidence-check.test.sh 各有 js／py 交叉一致案釘住。演算法（兩邊同一份規格）：
  1. 走訪未展開 instance 的全樹（與 total_nodes 同語意：JSON children 樹＝Pencil `Get(visit)` 不帶 resolveInstances），
     每個節點一行：`<父 id 或空>\\t<在父 children 中的 index>\\t<canon(node 去掉 children)>`。
     canon＝鍵排序（code point 序）、無空白的 JSON；數字用 JavaScript Number#toString 規則（整數值不帶 .0、
     指數表示只在 ≥1e21 或 <1e-6 時出現）；字串照 JSON 轉義（雙引號／反斜線／控制字元）。
  2. 每行 UTF-8 bytes 做 FNV-1a 64；全部逐行相加 mod 2^64（可交換，不依賴走訪順序、不用排序——JS 的 UTF-16 排序與
     python 的 code point 排序對 BMP 外字元順序不同，所以不能靠排序取得順序無關性）。
  3. 輸出 16 碼小寫 hex。
Pencil execute 環境沒有 crypto，所以選 FNV-1a 而非 SHA-256；64 位元夠分辨「不是同一份稿」，不是密碼學承諾。

用法：design_tree_hash.py <path.pen>            印 tree_hash
      design_tree_hash.py <path.pen> --dump <id>  印該節點的那一行（與 JS `SCAN_HASH_DEBUG = "<id>"` 對照除錯）
也可被 import：tree_hash(doc: dict) -> str。
"""
import json
import math
import sys

FNV_OFFSET = 0xCBF29CE484222325
FNV_PRIME = 0x100000001B3
MASK64 = (1 << 64) - 1


def js_number(x):
    """JavaScript Number#toString 的十進位規則（ECMA-262 Number::toString）。"""
    if isinstance(x, bool):
        return "true" if x else "false"
    if isinstance(x, int):
        x = float(x) if abs(x) >= 10**21 else x
        if isinstance(x, int):
            return str(x)
    if math.isnan(x):
        return "NaN"
    if math.isinf(x):
        return "Infinity" if x > 0 else "-Infinity"
    if x == 0:
        return "0"
    if x.is_integer() and abs(x) < 1e21:
        return str(int(x))
    sign = "-" if x < 0 else ""
    r = repr(abs(x))  # 最短可還原表示，與 JS 相同的數字序列
    if "e" in r or "E" in r:
        mant, exp = r.lower().split("e")
        exp = int(exp)
    else:
        mant, exp = r, 0
    if "." in mant:
        ip, fp = mant.split(".")
    else:
        ip, fp = mant, ""
    digits = (ip + fp).lstrip("0")
    # n＝小數點位置（digits 的前 n 位為整數部分），k＝有效位數
    n = len(ip.lstrip("0")) + exp if ip.strip("0") else exp - (len(fp) - len(fp.lstrip("0")))
    digits = digits.rstrip("0") or "0"
    k = len(digits)
    if k <= n <= 21:
        return sign + digits + "0" * (n - k)
    if 0 < n <= 21:
        return sign + digits[:n] + "." + digits[n:]
    if -6 < n <= 0:
        return sign + "0." + "0" * (-n) + digits
    e = n - 1
    es = ("+" if e >= 0 else "-") + str(abs(e))
    if k == 1:
        return sign + digits + "e" + es
    return sign + digits[0] + "." + digits[1:] + "e" + es


def canon(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return js_number(v)
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, list):
        return "[" + ",".join(canon(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{" + ",".join(json.dumps(k, ensure_ascii=False) + ":" + canon(v[k]) for k in sorted(v)) + "}"
    raise TypeError("canon：不支援的型別 %s" % type(v).__name__)


def node_line(node, parent_id, index):
    body = {k: v for k, v in node.items() if k != "children"}
    return "%s\t%d\t%s" % (parent_id or "", index, canon(body))


def fnv1a64(data):
    h = FNV_OFFSET
    for b in data:
        h ^= b
        h = (h * FNV_PRIME) & MASK64
    return h


def iter_lines(doc):
    stack = [(c, "", i) for i, c in reversed(list(enumerate(doc.get("children") or [])))]
    while stack:
        n, pid, idx = stack.pop()
        if not isinstance(n, dict):
            continue
        yield node_line(n, pid, idx)
        kids = n.get("children") or []
        for i in range(len(kids) - 1, -1, -1):
            stack.append((kids[i], n.get("id") or "", i))


def tree_hash(doc):
    total = 0
    for line in iter_lines(doc):
        total = (total + fnv1a64(line.encode("utf-8"))) & MASK64
    return "%016x" % total


def main(argv):
    if not argv or argv[0].startswith("--"):
        sys.stderr.write("用法：design_tree_hash.py <path.pen> [--dump <id>]\n")
        return 2
    try:
        with open(argv[0], encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        sys.stderr.write("✗ design_tree_hash：%s 讀取／解析失敗（%s）\n" % (argv[0], exc))
        return 2
    if len(argv) >= 3 and argv[1] == "--dump":
        want = argv[2]
        for line in iter_lines(doc):
            if ('"id":%s' % json.dumps(want)) in line:
                print(line)
                return 0
        sys.stderr.write("✗ design_tree_hash：找不到節點 %s\n" % want)
        return 1
    print(tree_hash(doc))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
