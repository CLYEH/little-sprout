// scripts/design/pen-snapshot-dump.js 的自測（LS-377 R2 起；LS-431 改寫為逐板走訪版）。
// pen-snapshot-dump.js 是 Pencil execute snippet（沒有 require、只認全域 Get／Print）——這裡用假的 Pencil（`makeEnv`）對合成稿
// 跑它。假 Pencil 的成本模型（LS-431 的核心假設，來源 LS-425 R4 實測）：
//   · document 級 `Get(visit, {resolveInstances:true})`＝整份展開，成本＝**全稿展開節點數**（不論 skipChildren）——19k 節點稿光這樣
//     走一遍就 interrupted；
//   · document 級未展開 `Get(visit)`＝每個被訪問的節點 1（skipChildren 剪掉子樹）；
//   · scoped `Get(boardId, visit, opts)`＝該板子樹被訪問的節點數；
//   · 單次 execute 累計成本超過 `cap` 就丟 `InternalError: interrupted`（＝「單段節點數上限」）。
// 驗：① 逐板分段串接後與整份一次 dump 逐列相同（含 instance 展開子節點的複合 id、ref 榫接、中文名稱）；② 每段成本在上限內，
// 而「改回整份展開走訪」「分段單位失效（一段吞全部板）」的 mutant 會在假 Pencil 裡 interrupted；③ 段間續跑與 interrupted 退避序列；
// ④ 各段輸出接 overflow-scan.js `parseSnapshotDump` 的連續性驗證能通過，缺段會被拒；⑤ 舊參數（SNAP_BATCH_ROWS／SNAP_MAX_BYTES／
// 非 0 SNAP_SKIP）明確拒絕；⑥ 其他 mutation（拿掉 ref 榫接／座標累加／SNAP-DONE next）斷言必須紅。
// 夾具等價（可選）：`PEN_SNAPSHOT_FIXTURE=<舊格式 dump 檔，逗號分隔多個>`（例如 LS-425 的 r3／r4 dump）會把 dump 的列還原成假稿，
// 驗新 dump 在 N∈{40,20,7,1} 與原列逐列相同；`PEN_SNAPSHOT_NEWDUMP_OUT=<目錄>` 另把新格式 dump 寫出供 `--from-snapshot` 重放。
// 未設 PEN_SNAPSHOT_FIXTURE 時印「略過」（夾具太大不進 repo，見 LS-431 handoff）。
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
const firstLine = (e) => String(e && e.message ? e.message : e).split("\n")[0].slice(0, 200);

// ---- 假稿：由「dump 列」(id,name,parent,type,ref,enabled,clip,image,x,y,w,h) 還原 ----
// 還原規則（對 LS-425 r3／r4 的 31k 列實測成立：複合 id 列的父必為 ref 列或複合 id 列；ref 列的非複合子節點是實例自己的 children）：
//   · 展開版＝全部列；未展開版＝剔除「展開才有」的列（id 含 "/"，或祖先是展開才有的列）；
//   · 非複合 id 且 ref 非 null 的列：未展開版 `type:"ref", ref`，展開版 `type:<列 type>`、**沒有 ref**（LS-207 實測：Pencil 展開後實例根沒有 n.ref）；
//   · bounds 為相對父節點的位移（pa + rel === a 逐列驗過，不成立時微調 ulp）。
function buildDoc(rows) {
  const byId = new Map();
  const kids = new Map();
  const roots = [];
  for (const r of rows) {
    byId.set(r[0], r);
    if (r[2] == null) roots.push(r[0]);
    else { if (!kids.has(r[2])) kids.set(r[2], []); kids.get(r[2]).push(r[0]); }
  }
  const expandedOnly = new Map();
  const isExpOnly = (id) => {
    if (expandedOnly.has(id)) return expandedOnly.get(id);
    const r = byId.get(id);
    const v = id.includes("/") || (r[2] != null && isExpOnly(r[2]));
    expandedOnly.set(id, v);
    return v;
  };
  const rel = (a, pa) => {
    let d = a - pa;
    for (let k = 0; k < 8 && pa + d !== a; k++) d = pa + d < a ? d + Math.max(Math.abs(d) * 2.3e-16, 5e-324) : d - Math.max(Math.abs(d) * 2.3e-16, 5e-324);
    if (pa + d !== a) throw new Error("測試夾具：無法還原相對座標 " + a + " - " + pa);
    return d;
  };
  const nodeOf = (id, expanded) => {
    const r = byId.get(id);
    const composite = id.includes("/");
    const isRefRoot = !composite && r[4] != null;
    const node = { id, name: r[1], type: expanded ? r[3] : (isRefRoot ? "ref" : r[3]), enabled: r[5] === 1 ? undefined : false, clip: r[6] === 1 ? true : undefined };
    if (r[7] === 1) node.fill = { type: "image", enabled: true };
    if (isRefRoot && !expanded) node.ref = r[4];
    if (composite && r[4] != null) node.ref = r[4];
    const p = r[2] != null ? byId.get(r[2]) : null;
    const bounds = { x: p ? rel(r[8], p[8]) : r[8], y: p ? rel(r[9], p[9]) : r[9], width: r[10], height: r[11] };
    return { node, bounds };
  };
  const childIds = (id, expanded) => (kids.get(id) || []).filter((k) => expanded || !isExpOnly(k));
  const countExpanded = rows.length;
  return { roots, nodeOf, childIds, countExpanded, byId };
}

// 假 Pencil：回傳 { Get, Print, out, stats }。cap＝單次 execute 成本上限（Infinity＝不限）
function makeEnv(doc, cap) {
  const out = [];
  const stats = { cost: 0, calls: [] };
  const charge = (k) => { stats.cost += k; if (stats.cost > cap) throw new Error("InternalError: interrupted"); };
  function Get(...args) {
    let id = null, visit, opts;
    if (typeof args[0] === "string") { id = args[0]; visit = args[1]; opts = args[2] || {}; } else { visit = args[0]; opts = args[1] || {}; }
    const expanded = opts.resolveInstances === true;
    stats.calls.push({ scoped: id != null, expanded });
    const walk = (nid, parentCtx, index) => {
      charge(1);
      const { node, bounds } = doc.nodeOf(nid, expanded);
      let skip = false;
      const c = { parentCtx, index, bounds, skipChildren() { skip = true; } };
      visit(node, c);
      if (skip) return;
      doc.childIds(nid, expanded).forEach((k, i) => walk(k, { node: { id: nid } }, i));
    };
    if (id == null) {
      if (expanded) charge(doc.countExpanded); // 假設：document 級展開＝整份展開，成本是全稿展開節點數
      doc.roots.forEach((r, i) => walk(r, null, i));
    } else {
      if (!doc.byId.has(id)) throw new Error("測試夾具：找不到 id " + id);
      walk(id, null, doc.roots.indexOf(id));
    }
  }
  return { Get, Print: (s) => out.push(s), out, stats };
}

function run(doc, globals, src, cap) {
  const env = makeEnv(doc, cap == null ? Infinity : cap);
  const names = Object.keys(globals);
  new Function("Get", "Print", ...names, src || SRC)(env.Get, env.Print, ...names.map((k) => globals[k]));
  return { lines: env.out, stats: env.stats };
}
const DONE_RE = /^SNAP-DONE roots=\[(\d+),(\d+)\) next=(\d+) skip=(\d+) of=(\d+) total_rows=(\d+) bytes=(\d+) from=(\d+)$/;
// 呼叫端迴圈（ui-designer.md 步驟②的做法）：依 SNAP-DONE 的 next 續跑到 next==of；回傳所有輸出行、段數與每段成本
function drive(doc, boards, src, cap, maxSegs) {
  let lo = 0, segs = 0, all = [];
  const costs = [];
  for (;;) {
    const r = run(doc, { SNAP_ROOTS: [lo, Infinity], SNAP_BOARDS: boards }, src, cap);
    all = all.concat(r.lines); segs++; costs.push(r.stats.cost);
    const m = DONE_RE.exec(r.lines[r.lines.length - 1]);
    assert.ok(m, "每段最後一行必須是 SNAP-DONE：" + r.lines[r.lines.length - 1]);
    assert.strictEqual(+m[4], 0, "skip 恆為 0（板不可再切）");
    assert.strictEqual(+m[8], 0, "from 恆為 0");
    const next = +m[3], of = +m[5];
    if (next >= of) break;
    assert.ok(next > lo, "續跑沒有前進（無窮迴圈）");
    lo = next;
    if (segs > (maxSegs || 500)) throw new Error("段數異常多");
  }
  return { lines: all, segs, costs };
}
const rowsOf = (lines) => M.parseSnapshotDump(lines.join("\n"));
const normRows = (rows) => rows.map((r) => [r.id, r.name, r.parent, r.type, r.ref === undefined ? null : r.ref, r.enabled ? 1 : 0, r.clip ? 1 : 0, r.image ? 1 : 0, r.x, r.y, r.w, r.h]);

// ---- 合成稿：24 塊板；每塊板有 instance（展開才有複合 id 子孫，含巢狀）、中文／英文名稱、disabled／clip／image 各一 ----
const SYN = [];
const NBOARDS = 24;
for (let i = 0; i < NBOARDS; i++) {
  const rid = "b" + i, bx = i * 500, by = (i % 3) * 1000 + 0.5;
  SYN.push([rid, "板 " + i, null, "frame", null, 1, 1, 0, bx, by, 393, 852]);
  const nk = i === 7 ? 30 : 3 + (i % 5);
  for (let j = 0; j < nk; j++) SYN.push([`${rid}t${j}`, j % 2 ? "中文名稱" : "n" + j, rid, "text", null, j === 2 ? 0 : 1, 0, j === 1 ? 1 : 0, bx + 10 + j, by + 5 + j * 0.1, 50, 20]);
  const inst = `${rid}i`;
  SYN.push([inst, "Status Bar", rid, "frame", "OeXop", 1, 0, 0, bx + 1, by + 2, 393, 62]);
  SYN.push([`${inst}/a`, "Status Time", inst, "text", null, 1, 0, 0, bx + 29, by + 22, 31, 22]);
  SYN.push([`${inst}/b`, "指示器", inst, "frame", null, 1, 1, 0, bx + 298, by + 24, 68, 18]);
  SYN.push([`${inst}/b/c`, "signal", `${inst}/b`, "icon", null, 1, 0, 0, bx + 299, by + 25, 17, 12]);
  SYN.push([`${rid}z`, "Footer", rid, "frame", null, 1, 0, 0, bx, by + 800, 393, 52]);
}
const SYNDOC = buildDoc(SYN);
const FULL = drive(SYNDOC, 1e9);

ok("合成稿單次全量（SNAP_BOARDS 極大）＝一段、SNAP-DONE next==of；逐列等於合成稿（instance 複合 id、ref 榫接、中文名稱、disabled／clip／image 欄）", () => {
  assert.strictEqual(FULL.segs, 1);
  const got = normRows(rowsOf(FULL.lines));
  assert.deepStrictEqual(got, SYN);
  // 前提確認：實例根有 ref（來自未展開對照表）、展開子孫沒有
  assert.strictEqual(got.find((r) => r[0] === "b0i")[4], "OeXop");
  assert.strictEqual(got.find((r) => r[0] === "b0i/b/c")[4], null);
});

ok("逐板分段：SNAP_BOARDS＝1／3／5／7／24 各得 24／8／5／4／1 段，串接後與單次全量逐列相同，每段 SNAP-DONE 的 skip／from 恆為 0，且 parseSnapshotDump 首尾相接驗證通過", () => {
  const want = rowsOf(FULL.lines);
  for (const [b, segs] of [[1, 24], [3, 8], [5, 5], [7, 4], [24, 1]]) {
    const d = drive(SYNDOC, b);
    assert.strictEqual(d.segs, segs, "SNAP_BOARDS=" + b + " 段數");
    assert.deepStrictEqual(rowsOf(d.lines), want, "SNAP_BOARDS=" + b + "：串接後應與單次全量相同");
  }
});

ok("SNAP_ROOTS 的 hi 是上界（[2,5) 只收板 2..4）、預設 SNAP_BOARDS＝40 一段吞下 24 塊板、SNAP_ROOT_COUNT_ONLY 只印總數", () => {
  const r = run(SYNDOC, { SNAP_ROOTS: [2, 5] });
  const m = DONE_RE.exec(r.lines[r.lines.length - 1]);
  assert.deepStrictEqual([+m[1], +m[2], +m[3], +m[5]], [2, 5, 5, NBOARDS]);
  assert.deepStrictEqual(rowsFromDump(r.lines.join("\n")).filter((x) => x[2] == null).map((x) => x[0]), ["b2", "b3", "b4"]);
  const d = run(SYNDOC, {});
  const dm = DONE_RE.exec(d.lines[d.lines.length - 1]);
  assert.deepStrictEqual([+dm[3], +dm[5]], [NBOARDS, NBOARDS], "預設 40 板／段、24 塊板一段走完");
  assert.deepStrictEqual(run(SYNDOC, { SNAP_ROOT_COUNT_ONLY: true }).lines, ["SNAP-ROOT-COUNT n=24"]);
});

ok("輸出含 SNAP-TIMING 量測行（parser 不認它也不受影響），單一 SNAP Print 行不超過約 50000 位元組", () => {
  const big = [];
  for (let i = 0; i < 3000; i++) big.push([`big${i}`, "中文名稱".repeat(5), i ? "bigroot" : null, "text", null, 1, 0, 0, i, i, 5, 5]);
  big[0][0] = "bigroot";
  const r = run(buildDoc(big), { SNAP_ROOTS: [0, Infinity] });
  assert.ok(r.lines.some((l) => /^SNAP-TIMING boards=1 root_walk_ms=\d+ ref_walk_ms=\d+ expand_walk_ms=\d+ print_ms=\d+$/.test(l)));
  const snapLines = r.lines.filter((l) => /^SNAP\d/.test(l));
  assert.ok(snapLines.length > 1, "單板 3000 列要切成多個 Print 行（實得 " + snapLines.length + "）");
  for (const l of snapLines) assert.ok(Buffer.byteLength(l) <= 50000 + 200, "Print 行過長：" + Buffer.byteLength(l));
  assert.strictEqual(M.parseSnapshotDump(r.lines.join("\n")).length, 3000);
});

// ---- 單段節點數上限（假 Pencil 的 interrupted）----
const costOf = (b) => Math.max(...drive(SYNDOC, b).costs);
const CAP = costOf(4);

ok("單段節點數上限：逐板版在 cap（＝SNAP_BOARDS=4 的最大單段成本 " + CAP + "）內跑完 N=4，而 document 級整份展開一趟就超過 cap（" + SYNDOC.countExpanded + " > " + CAP + "）", () => {
  assert.doesNotThrow(() => drive(SYNDOC, 4, SRC, CAP));
  assert.ok(SYNDOC.countExpanded > CAP, "夾具前提：整份展開成本 > cap");
  assert.ok(costOf(8) > CAP && costOf(2) < CAP, "段成本隨板數單調增（板數是分段旋鈕）：N=2 " + costOf(2) + "／N=4 " + CAP + "／N=8 " + costOf(8));
});

ok("原始碼走訪形狀（結構斷言）：未展開 document 級走訪只有頂層枚舉那一趟（有 skipChildren）；所有展開走訪都是 scoped Get(boardId, …)", () => {
  const r = run(SYNDOC, { SNAP_ROOTS: [0, Infinity], SNAP_BOARDS: 3 });
  const docLevel = r.stats.calls.filter((c) => !c.scoped);
  assert.deepStrictEqual(docLevel, [{ scoped: false, expanded: false }], "document 級只剩頂層枚舉");
  assert.ok(r.stats.calls.filter((c) => c.scoped && c.expanded).length === 3 && r.stats.calls.filter((c) => c.scoped && !c.expanded).length === 3, "每板各一趟 scoped 未展開＋一趟 scoped 展開");
});

// 呼叫端協定參考實作（ui-designer.md 步驟②）：interrupted 就把同一個 lo 的 SNAP_BOARDS 對半重跑（40→20→10→5），第 4 次仍 interrupted 就停下回報
function driveWithBackoff(doc, cap, startBoards) {
  const tried = [];
  let lo = 0, boards = startBoards, fails = 0;
  for (;;) {
    tried.push(boards);
    let r;
    try { r = run(doc, { SNAP_ROOTS: [lo, Infinity], SNAP_BOARDS: boards }, SRC, cap); } catch (e) {
      if (!/InternalError: interrupted/.test(e.message)) throw e;
      if (++fails > 3) return { stopped: true, tried };
      boards = Math.max(1, Math.floor(boards / 2));
      continue;
    }
    fails = 0;
    const m = DONE_RE.exec(r.lines[r.lines.length - 1]);
    if (+m[3] >= +m[5]) return { stopped: false, tried };
    lo = +m[3]; boards = startBoards;
  }
}

ok("interrupted 退避序列：40→20→10 成功（cap 讓 40／20 超過、10 通過），之後每段回到 40 再試；cap 小到任何板數都過不了＝第 4 次失敗（SNAP_BOARDS=5）後停下回報", () => {
  const cap10 = costOf(10);
  assert.ok(costOf(20) > cap10, "夾具前提");
  const r = driveWithBackoff(SYNDOC, cap10, 40);
  assert.strictEqual(r.stopped, false);
  assert.deepStrictEqual(r.tried.slice(0, 3), [40, 20, 10], "第一段退避序列");
  const stop = driveWithBackoff(SYNDOC, NBOARDS, 40); // cap＝頂層枚舉那趟的成本，任何一塊板都走不進去
  assert.strictEqual(stop.stopped, true);
  assert.deepStrictEqual(stop.tried, [40, 20, 10, 5], "40→20→10→5 都 interrupted ＝停下回報（不得再縮）");
});

ok("M1（呼叫端契約）：不帶 SNAP_ROOTS 只得到第一段——parseSnapshotDump 因 next<of 拒收（不再靜默產出部分快照）", () => {
  const r = run(SYNDOC, { SNAP_BOARDS: 5 });
  assert.throws(() => M.parseSnapshotDump(r.lines.join("\n")), /缺尾段/);
});

ok("缺中段／缺尾段／漏貼 SNAP 行：parseSnapshotDump 全部拒收並指出補跑點", () => {
  const d = drive(SYNDOC, 5);
  const doneIdx = d.lines.map((l, i) => (DONE_RE.test(l) ? i : -1)).filter((i) => i >= 0);
  assert.ok(doneIdx.length >= 4);
  const segLines = doneIdx.map((di, k) => d.lines.slice(k === 0 ? 0 : doneIdx[k - 1] + 1, di + 1));
  const join = (segs) => [].concat(...segs).join("\n");
  assert.doesNotThrow(() => M.parseSnapshotDump(join(segLines)), "對照：完整串接能過");
  assert.throws(() => M.parseSnapshotDump(join(segLines.filter((_, k) => k !== 1))), /沒有首尾相接/, "缺中段");
  assert.throws(() => M.parseSnapshotDump(join(segLines.slice(0, -1))), /缺尾段/, "缺尾段");
  const noSnap = segLines.map((s, k) => (k === 1 ? s.filter((l) => !/^SNAP\d/.test(l)) : s));
  assert.throws(() => M.parseSnapshotDump(join(noSnap)), /total_rows 加總/, "某段的 SNAP 行沒貼、只貼了它的 DONE");
});

ok("舊參數明確拒絕：SNAP_BATCH_ROWS／SNAP_MAX_BYTES／非 0 SNAP_SKIP 一律 throw（不是靜默忽略）；SNAP_SKIP=0 放行", () => {
  assert.throws(() => run(SYNDOC, { SNAP_BATCH_ROWS: 5000 }), /SNAP_BATCH_ROWS 已不再支援/);
  assert.throws(() => run(SYNDOC, { SNAP_MAX_BYTES: 50000 }), /SNAP_MAX_BYTES 已不再支援/);
  assert.throws(() => run(SYNDOC, { SNAP_SKIP: 5 }), /SNAP_SKIP=5 已不再支援/);
  assert.doesNotThrow(() => run(SYNDOC, { SNAP_SKIP: 0, SNAP_ROOTS: [0, Infinity] }));
  assert.throws(() => run(SYNDOC, { SNAP_ROOTS: [99, Infinity] }), /超過頂層板總數/);
  assert.throws(() => run(SYNDOC, { SNAP_BOARDS: -1 }), /SNAP_BOARDS 必須是 ≥1/);
});

// ---- mutation：每個 mutant 都先確認 needle 存在、能編譯，再斷言「原斷言轉紅」且紅的原因是預期的斷言訊息 ----
function mutant(needle, replacement) {
  assert.ok(SRC.includes(needle), "夾具前提：原始碼含 " + needle);
  const src = SRC.replace(needle, replacement);
  assert.notStrictEqual(src, SRC);
  new Function("Get", "Print", src); // 編譯失敗＝build fail，不算紅
  return src;
}
// 等價性檢查（被 mutant 打破的原斷言）：逐板版在 cap 內分段跑完，串接後逐列等於合成稿，且 parseSnapshotDump 驗過
function checkEquivalence(src, boards, cap) {
  const d = drive(SYNDOC, boards, src, cap);
  assert.deepStrictEqual(normRows(rowsOf(d.lines)), SYN, "串接後應逐列等於合成稿");
}
function expectRed(name, src, boards, cap, re) {
  let msg = null;
  try { checkEquivalence(src, boards, cap); } catch (e) { msg = firstLine(e); }
  assert.ok(msg !== null, name + "：mutant 沒有被斷言抓到（原斷言仍綠）");
  assert.ok(re.test(msg), name + "：紅的原因不是預期的（build fail／crash 不算紅）：" + msg);
  console.log("    ↳ 紅：" + msg);
}

ok("對照：未變異版本通過等價性檢查（N＝4、cap）", () => {
  assert.doesNotThrow(() => checkEquivalence(SRC, 4, CAP));
});

ok("mutation：改回整份展開走訪（scoped `Get(ids[bi], visit, …)` 換成 document 級 `Get(filteredVisit, {resolveInstances:true})`）→ 單段節點數上限被假 Pencil 打穿，InternalError: interrupted", () => {
  const m = mutant("Get(ids[bi], visit, { resolveInstances: true });", "Get(function (n, c) { if (!c.parentCtx && n.id !== ids[bi]) { c.skipChildren(); return; } visit(n, c); }, { resolveInstances: true });");
  expectRed("整份展開", m, 4, CAP, /InternalError: interrupted/);
});

ok("mutation：分段單位失效（`LO + BOARDS` 拿掉，一段吞到範圍尾）→ 單段節點數超過上限，InternalError: interrupted", () => {
  const m = mutant("Math.min(HI, LO + BOARDS, rootTotal)", "Math.min(HI, rootTotal)");
  expectRed("一段吞全部板", m, 4, CAP, /InternalError: interrupted/);
});

ok("mutation：拿掉 ref 榫接（`refMap[n.id] != null ? refMap[n.id] : null` 改恆 null）→ 實例根 ref 變 null，逐列等價斷言紅", () => {
  const m = mutant("(refMap[n.id] != null ? refMap[n.id] : null)", "null");
  expectRed("ref 榫接", m, 4, CAP, /串接後應逐列等於合成稿|Expected values to be strictly deep-equal/);
});

ok("mutation：絕對座標不累加（`pa.x + b.x` 改 `b.x`）→ 子孫座標變相對值，逐列等價斷言紅", () => {
  const m = mutant("x: pa.x + b.x", "x: b.x");
  expectRed("座標累加", m, 4, CAP, /串接後應逐列等於合成稿|Expected values to be strictly deep-equal/);
});

ok("mutation：SNAP-DONE 的 next 多報 1（`\" next=\" + end` 改 `end + 1`）→ 續跑漏一塊板，等價斷言紅（缺列或 parseSnapshotDump 拒收）", () => {
  const m = mutant("\") next=\" + end", "\") next=\" + (end + 1)");
  let red = null;
  try { checkEquivalence(m, 4, CAP); } catch (e) { red = firstLine(e); }
  assert.ok(red !== null, "mutant 沒被抓到");
  assert.ok(/沒有首尾相接|缺尾段|串接後應逐列等於合成稿|Expected values/.test(red), "紅的原因不對：" + red);
  console.log("    ↳ 紅：" + red);
});

// ---- 夾具等價（可選，需外部 dump 檔）----
const FIX = (process.env.PEN_SNAPSHOT_FIXTURE || "").split(",").map((s) => s.trim()).filter(Boolean);
if (!FIX.length) {
  console.log("↷ 略過夾具等價：未設 PEN_SNAPSHOT_FIXTURE（LS-425 r3／r4 dump 各 ~2.4 MB 不進 repo；重放方式見 LS-431 handoff）");
} else {
  for (const file of FIX) {
    ok("夾具等價 " + path.basename(file) + "：還原假稿後，新 dump 在 SNAP_BOARDS∈{40,20,7,1} 下逐列等於原 dump（同欄位／絕對座標／列順序）", () => {
      const text = fs.readFileSync(file, "utf8");
      const rawRows = rowsFromDump(text);
      const doc = buildDoc(rawRows);
      for (const b of [40, 20, 7, 1]) {
        const d = drive(doc, b, SRC, undefined, 1000);
        assert.deepStrictEqual(normRows(rowsOf(d.lines)), rawRows, file + " @SNAP_BOARDS=" + b);
        console.log("    · SNAP_BOARDS=" + b + "：" + d.segs + " 段、" + rawRows.length + " 列逐列相同、最大單段成本 " + Math.max(...d.costs) + "（整份展開成本 " + doc.countExpanded + "）");
        if (b === 40 && process.env.PEN_SNAPSHOT_NEWDUMP_OUT) {
          const out = path.join(process.env.PEN_SNAPSHOT_NEWDUMP_OUT, path.basename(file).replace(/\.txt$/, "") + ".new.txt");
          fs.writeFileSync(out, d.lines.join("\n") + "\n");
          console.log("    · 新格式 dump 已寫出 " + out);
        }
      }
    });
  }
}
function rowsFromDump(text) {
  const segs = [];
  for (const line of text.split("\n")) {
    const m = /^SNAP(\d+)\s+(\[.*\])\s*$/.exec(line.trim());
    if (m) segs.push([Number(m[1]), JSON.parse(m[2])]);
  }
  segs.sort((a, b) => a[0] - b[0]);
  return [].concat(...segs.map((s) => s[1]));
}

console.log("pen-snapshot-dump.test.js：全數通過（" + n + " 組）");
