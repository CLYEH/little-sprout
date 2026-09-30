// scripts/design/pen-snapshot-dump.js 的自測（LS-377 R2，merge-review M1 c；由 LS-377 一次性夾具收進 repo）。
// pen-snapshot-dump.js 是 Pencil execute snippet（沒有 require、只認全域 Get／Print）——這裡用假的 Get／Print 對合成樹跑它，
// 驗：① 依位元組預算分段、呼叫端依 SNAP-DONE 的 next／skip 續跑，串接後與單次全量逐列相同（含單一超大子樹在子樹內續跑、
// 中文名稱以 UTF-8 位元組計）；② 各段輸出接 overflow-scan.js `parseSnapshotDump` 的連續性驗證能通過，而「只跑第一段」「缺中段」
// 「缺尾段」會被拒；③ `SNAP_BATCH_ROWS` 明確拒絕；④ mutation：拿掉預算判斷／拿掉子樹內續跑的列跳過，斷言必須紅。
// CI rules job 自測 step 跑 `node scripts/design/pen-snapshot-dump.test.js`。
"use strict";
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const M = require("./overflow-scan.js");

const SRC_PATH = path.join(__dirname, "pen-snapshot-dump.js");
const SRC = fs.readFileSync(SRC_PATH, "utf8");

let n = 0;
function ok(name, fn) { fn(); n++; console.log("✓ " + name); }

// 合成樹：7 個頂層節點，第 i 個有 i+1 個子節點，第 3 個特別大（40 子節點，單獨就超過小預算）；子節點名稱交替中文／英文
const ROOTS = [];
for (let i = 0; i < 7; i++) {
  const kids = [];
  const nk = i === 3 ? 40 : i + 1;
  for (let j = 0; j < nk; j++) kids.push({ id: `r${i}c${j}`, name: j % 2 ? "中文名稱" : "n", type: "text", bounds: { x: j, y: 1, width: 5, height: 6 } });
  ROOTS.push({ id: `r${i}`, name: "root" + i, type: "frame", bounds: { x: i * 100, y: 0, width: 90, height: 50 }, kids });
}
const TOTAL_ROWS = ROOTS.reduce((a, r) => a + 1 + r.kids.length, 0);

function makeGet() {
  return function Get(visit) {
    const walk = (node, parentCtx, index) => {
      let skip = false;
      const c = { parentCtx, index, bounds: node.bounds, skipChildren() { skip = true; } };
      visit({ id: node.id, name: node.name, type: node.type, enabled: true }, c);
      if (skip) return;
      (node.kids || []).forEach((k, i) => walk(k, { node: { id: node.id } }, i));
    };
    ROOTS.forEach((r, i) => walk(r, null, i));
  };
}
function run(globals, src) {
  const out = [];
  const names = Object.keys(globals);
  new Function("Get", "Print", ...names, src || SRC)(makeGet(), (s) => out.push(s), ...names.map((k) => globals[k]));
  return out;
}
const DONE_RE = /^SNAP-DONE roots=\[(\d+),(\d+)\) next=(\d+) skip=(\d+) of=(\d+) total_rows=(\d+) bytes=(\d+) from=(\d+)$/;
// 呼叫端迴圈（ui-designer.md 步驟②的做法）：依 SNAP-DONE 的 next／skip 續跑到 next==of 且 skip==0；回傳所有輸出行與段數
function drive(budget, src, maxSegs) {
  let lo = 0, skip = 0, segs = 0, all = [];
  for (;;) {
    const out = run({ SNAP_ROOTS: [lo, Infinity], SNAP_SKIP: skip, SNAP_MAX_BYTES: budget }, src);
    all = all.concat(out); segs++;
    const m = DONE_RE.exec(out[out.length - 1]);
    assert.ok(m, "每段最後一行必須是 SNAP-DONE：" + out[out.length - 1]);
    const next = +m[3], nskip = +m[4], of = +m[5];
    if (next >= of && nskip === 0) break;
    assert.ok(next > lo || nskip > skip, "續跑沒有前進（無窮迴圈）");
    lo = next; skip = nskip;
    if (segs > (maxSegs || 200)) { if (maxSegs) return { lines: all, segs, runaway: true }; throw new Error("段數異常多"); }
  }
  return { lines: all, segs };
}
const rowsOf = (lines) => M.parseSnapshotDump(lines.join("\n"));
const FULL = drive(1e9);

ok("單次全量（預算極大）＝一段、SNAP-DONE 標 next==of；列數＝合成樹總節點數", () => {
  assert.strictEqual(FULL.segs, 1);
  assert.strictEqual(rowsOf(FULL.lines).length, TOTAL_ROWS);
});

ok("依預算分段：50000／1500／400 各得 1／≥4／≥10 段，串接後與單次全量逐列相同；每個 Print 行的 UTF-8 位元組數不超過預算（單列本身超過預算不在此列）", () => {
  const want = rowsOf(FULL.lines);
  for (const [budget, minSegs] of [[50000, 1], [1500, 4], [400, 10]]) {
    const d = drive(budget);
    assert.ok(d.segs >= minSegs, "預算 " + budget + " 至少 " + minSegs + " 段（實得 " + d.segs + "）");
    assert.deepStrictEqual(rowsOf(d.lines), want, "預算 " + budget + "：串接後應與單次全量相同");
    for (const l of d.lines) if (/^SNAP\d/.test(l)) assert.ok(Buffer.byteLength(l) <= budget + 64, "預算 " + budget + " 的 Print 行過長：" + Buffer.byteLength(l));
  }
});

ok("單一超大子樹（頂層 r3，41 列）在預算 400 下於子樹內依列序切、SNAP-DONE 回報 skip>0 的續跑點", () => {
  const out = run({ SNAP_ROOTS: [3, Infinity], SNAP_SKIP: 0, SNAP_MAX_BYTES: 400 });
  const m = DONE_RE.exec(out[out.length - 1]);
  assert.strictEqual(+m[3], 3, "停在同一個頂層節點");
  assert.ok(+m[4] > 0 && +m[4] < 41, "skip 在子樹內：" + m[4]);
  assert.strictEqual(+m[8], 0, "from＝本段 SNAP_SKIP");
});

ok("M1（呼叫端契約）：不帶 SNAP_ROOTS 只得到第一段——parseSnapshotDump 因 next<of 拒收（不再靜默產出部分快照）", () => {
  const out = run({ SNAP_MAX_BYTES: 1500 });
  const m = DONE_RE.exec(out[out.length - 1]);
  assert.ok(+m[3] < +m[5], "夾具前提：單次呼叫沒走完（next " + m[3] + " of " + m[5] + "）");
  assert.throws(() => M.parseSnapshotDump(out.join("\n")), /缺尾段/);
});

ok("缺中段／缺尾段／漏貼 SNAP 行：parseSnapshotDump 全部拒收並指出補跑點", () => {
  const d = drive(1500);
  const doneIdx = d.lines.map((l, i) => (DONE_RE.test(l) ? i : -1)).filter((i) => i >= 0);
  assert.ok(doneIdx.length >= 4);
  // 每段的行 = 上一個 DONE 之後到本段 DONE（含）
  const segLines = doneIdx.map((di, k) => d.lines.slice(k === 0 ? 0 : doneIdx[k - 1] + 1, di + 1));
  const join = (segs) => [].concat(...segs).join("\n");
  assert.doesNotThrow(() => M.parseSnapshotDump(join(segLines)), "對照：完整串接能過");
  assert.throws(() => M.parseSnapshotDump(join(segLines.filter((_, k) => k !== 1))), /沒有首尾相接/, "缺中段");
  assert.throws(() => M.parseSnapshotDump(join(segLines.slice(0, -1))), /缺尾段/, "缺尾段");
  const noSnap = segLines.map((s, k) => (k === 1 ? s.filter((l) => !/^SNAP\d/.test(l)) : s));
  assert.throws(() => M.parseSnapshotDump(join(noSnap)), /total_rows 加總/, "某段的 SNAP 行沒貼、只貼了它的 DONE");
});

ok("SNAP_BATCH_ROWS 明確拒絕（不是靜默忽略）", () => {
  assert.throws(() => run({ SNAP_BATCH_ROWS: 5000 }), /SNAP_BATCH_ROWS 已不再支援/);
});

ok("SNAP_ROOT_COUNT_ONLY：只印頂層總數、不走訪子樹", () => {
  assert.deepStrictEqual(run({ SNAP_ROOT_COUNT_ONLY: true }), ["SNAP-ROOT-COUNT n=7"]);
});

ok("mutation：拿掉位元組預算判斷（`segBytes + curBytes <= MAX_BYTES` 改恆真）→ 預算 400 也只有一段而且被小預算的 Print 行上限打破——斷言 ≥10 段轉紅", () => {
  const needle = "segBytes + curBytes <= MAX_BYTES";
  assert.ok(SRC.includes(needle), "夾具前提：原始碼含預算判斷");
  const mutated = SRC.replace(needle, "true");
  const segs = drive(400, mutated).segs;
  assert.ok(segs < 10, "拿掉預算判斷後段數應掉到 <10（實得 " + segs + "），原斷言 ≥10 會紅");
});

ok("mutation：拿掉子樹內續跑的列跳過（`visitedInRoot < SKIP` 改恆假）→ 續跑段永遠重收前面的列、永不走完（原斷言「續跑走完且逐列相同」轉紅）", () => {
  const needle = "visitedInRoot < SKIP";
  assert.ok(SRC.includes(needle), "夾具前提：原始碼含列跳過");
  const mutated = SRC.replace(needle, "false");
  const d = drive(400, mutated, 60); // 有上限：續跑永遠收前面的列、永不走完（skip 無限增長）——原斷言「續跑會走完且與全量逐列相同」必紅
  assert.ok(d.runaway, "拿掉列跳過後續跑應停不下來（60 段仍未走完；原本 ≤ 20 段走完），實得 " + d.segs + " 段、runaway=" + d.runaway);
  assert.ok(drive(400).segs <= 20, "對照：未變異版本 20 段內走完");
});

console.log("pen-snapshot-dump.test.js：全數通過（" + n + " 組）");
