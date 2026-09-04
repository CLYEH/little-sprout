// scripts/design/overflow-scan.js 的自測（LS-122）。CI rules job 自測 step 跑 `node scripts/design/overflow-scan.test.js`。
// 純函數對合成節點樹（絕對座標）驗四支掃描的語意；每條斷言都對應一個 LS-119 R5 抓到的盲區、既有語意、或 merge-review R1
// 的反例（B1 40pt 角托、B2 角托與紙面是兄弟／板層角托、MJ-2 祖先刻意接縫 1pt 底下的真碰撞），斷言的是**精確的命中集合**
// （不是「至少有一筆」）——演算法退化（少比一支、祖先後代沒排除、disabled 沒傳遞、Corner BR 漏掉、跨 parent 去重吃掉溢出
// 類、角托尺寸寫死、紙面誤取父節點）任一種都會讓集合改變而紅。
"use strict";
const assert = require("assert");
const path = require("path");
const { scanAll, scanCornerAnchor, scanTextOcclusion, buildIndex, compactLines, canon, canonNode, fnv1a64, hex64, treeHash, treeHashLines } = require(path.join(__dirname, "overflow-scan.js"));

function N(id, parent, x, y, w, h, extra) {
  return Object.assign({ id, name: id, parent, type: "frame", enabled: true, x, y, w, h }, extra || {});
}
// corners(prefix, parentId, paper, size, opts)：依 corner-out 5 規則放四顆角托（絕對座標），paper 為角托咬住的紙面 AABB
function corners(prefix, parentId, paper, size, opts) {
  const o = opts || {};
  const dy = o.blbrDy || 0;
  const on = o.enabled !== false;
  const s = size || 26;
  const L = paper.x - 5, T = paper.y - 5, R = paper.x + paper.w - s + 5, B = paper.y + paper.h - s + 5;
  return [
    N(prefix + "/Corner TL", parentId, L, T, s, s, { name: "Corner TL", enabled: on }),
    N(prefix + "/Corner TR", parentId, R, T, s, s, { name: "Corner TR", enabled: on }),
    N(prefix + "/Corner BL", parentId, L, B + dy, s, s, { name: "Corner BL", enabled: on }),
    N(prefix + "/Corner BR", parentId, R, B + dy, s, s, { name: "Corner BR", enabled: on }),
  ];
}
function pairs(flagged) {
  return flagged.map((f) => [f.node_a, f.node_b].sort().join("|")).sort();
}
function ids(flagged, key) {
  return flagged.map((f) => f[key]).sort();
}
function P(a, b) {
  return [a, b].sort().join("|");
}

// 板 B：格狀牆——兩格 gap 8、角托 corner-out 5（5+5=10 > 8 必然重疊 2pt，LS-119 R5 BL-2）
const B = N("B", null, 0, 0, 400, 400);
const G = N("G", "B", 0, 0, 400, 200);
const C1 = N("C1", "G", 0, 0, 100, 178);
const C2 = N("C2", "G", 108, 0, 100, 178);
// 板 B2：與 B 在畫布 root 層相鄰重疊（既有語意：root 層兩板交集要報）；內含兩個交集的兄弟，各有一個**沒溢出**的子節點
const B2 = N("B2", null, 350, 0, 400, 400);
const S1 = N("S1", "B2", 350, 0, 100, 100);
const S2 = N("S2", "B2", 400, 0, 100, 100);
const T1 = N("T1", "S1", 360, 10, 80, 20, { type: "text" });
const T2 = N("T2", "S2", 410, 10, 80, 20, { type: "text" });
// 板 B3：disabled 子樹——D（enabled:false）與其子 DC 都蓋住兄弟 E，且 DC 內有角托；全部不得參與任何一支
const B3 = N("B3", null, 1000, 0, 400, 400);
const D = N("D", "B3", 1000, 0, 200, 200, { enabled: false });
const DC = N("DC", "D", 1000, 0, 200, 200);
const E = N("E", "B3", 1050, 50, 200, 200);
// 板 B4：instance descendants（id 為 instanceId/childId 路徑）——徽章右緣超出 Photo Wrap 8pt（LS-119 R5 MJ-6）
const B4 = N("B4", null, 2000, 0, 400, 400);
const INST = N("inst", "B4", 2000, 0, 329, 200, { type: "ref" });
const WRAP = N("inst/wrap", "inst", 2000, 0, 329, 200);
const BADGE = N("inst/wrap/badge", "inst/wrap", 2237, 170, 100, 26);
// 板 B5：角托錯位——BL／BR 的 y 少 8（LS-119 R5 BL-1：角托 y 用字面值推、非實測容器高）
const B5 = N("B5", null, 3000, 0, 400, 400, { name: "LS-99 / 05 示範板" });
const C3 = N("C3", "B5", 3000, 0, 100, 178);
// 板 B6：徽章溢出 Photo Wrap 撞到兄弟 caption（祖先兄弟 wrap／cap 不交集、後代 badge 與 cap 交集 → 跨 parent 要報）
const B6 = N("B6", null, 4000, 0, 400, 400);
const W6 = N("W6", "B6", 4000, 0, 300, 200);
const CAP6 = N("CAP6", "B6", 4000, 200, 300, 30, { type: "text" });
const BADGE6 = N("BADGE6", "W6", 4200, 190, 100, 26);
// 板 B7（merge-review R1 MJ-2 反例 A2）：PHOTO 與 BAND 刻意重疊 1pt 接縫（(a) 報一筆、可白名單）；BADGE（PHOTO 的子）溢出
// PHOTO 下緣 11pt、與 TITLE（BAND 的子）真碰撞——祖先兄弟交集不得把它靜音
const B7 = N("B7", null, 5000, 0, 400, 500);
const PHOTO7 = N("PHOTO7", "B7", 5000, 0, 400, 300);
const BAND7 = N("BAND7", "B7", 5000, 299, 400, 120);
const BADGE7 = N("BADGE7", "PHOTO7", 5150, 250, 100, 61);
const TITLE7 = N("TITLE7", "BAND7", 5100, 300, 200, 40, { type: "text" });
// 板 B8（merge-review R1 B1：Cxqc2 實數）：40×40 角托是紙面 Photo Wrap 的子，TR.x=420−40+5=385、BL.y=570−40+5=535 守 5pt 規則
const B8 = N("B8", null, 6000, 0, 500, 700);
const PW8 = N("PW8", "B8", 6000, 0, 420, 570);
// 板 B9（merge-review R1 B2：HqrJw 實數）：角托與紙面 Print 是兄弟、父是 Print Stage（h=292）；紙面＝Print(16,5,361,230.1)
const B9 = N("B9", null, 7000, 0, 500, 400);
const STAGE9 = N("STAGE9", "B9", 7000, 0, 393, 292);
const PRINT9 = N("PRINT9", "STAGE9", 7016, 5, 361, 230.1);
// 板 B10（merge-review R1 B2：BDrtd 實數）：40×40 角托直接掛在板上，紙面是兄弟 Print(40,273,420×582)
const B10 = N("B10", null, 8000, 0, 834, 1194);
const PRINT10 = N("PRINT10", "B10", 8040, 273, 420, 582);
// 板 B11：四顆角托全部亂放（對不上父也對不上兄弟 Print）→ unresolved（不計 mismatch、收據需分類）
const B11 = N("B11", null, 9000, 0, 500, 400);
const STAGE11 = N("STAGE11", "B11", 9000, 0, 393, 292);
const PRINT11 = N("PRINT11", "STAGE11", 9016, 5, 361, 230);
const LOST = ["TL", "TR", "BL", "BR"].map((v, i) => N("STAGE11/Corner " + v, "STAGE11", 9020 + i * 40, 250, 26, 26, { name: "Corner " + v }));
// 板 B14：非易出血類別的跨 parent 碰撞（Feed 溢出 Column 撞到兄弟 Home Indicator Area）——預設過濾、SCAN_CROSS_ALL 才報
const B14 = N("B14", null, 11000, 0, 400, 400);
const COL14 = N("COL14", "B14", 11000, 0, 400, 300, { name: "Column" });
const FEED14 = N("FEED14", "COL14", 11000, 0, 400, 320, { name: "Feed" });
const HOME14 = N("HOME14", "B14", 11000, 300, 400, 100, { name: "Home Indicator Area" });
// 板 B13：他票舊債——角托 BL／BR y 多 3（不在 SCAN_BOARDS 內時只進 document_mismatch，不擋）
const B13 = N("B13", null, 10000, 0, 400, 400, { name: "LS-17 / 01 舊板" });
const C4 = N("C4", "B13", 10000, 0, 100, 178);

const nodes = [
  B, G, C1, C2, ...corners("C1", "C1", C1), ...corners("C2", "C2", C2),
  B2, S1, S2, T1, T2,
  B3, D, DC, E, ...corners("DC", "DC", DC),
  B4, INST, WRAP, BADGE,
  B5, C3, ...corners("C3", "C3", C3, 26, { blbrDy: -8 }),
  B6, W6, CAP6, BADGE6,
  B7, PHOTO7, BAND7, BADGE7, TITLE7,
  B8, PW8, ...corners("PW8", "PW8", PW8, 40),
  B9, STAGE9, PRINT9, ...corners("STAGE9", "STAGE9", PRINT9),
  B10, PRINT10, ...corners("B10", "B10", PRINT10, 40),
  B11, STAGE11, PRINT11, ...LOST,
  B13, C4, ...corners("C4", "C4", C4, 26, { blbrDy: 3 }),
  B14, COL14, FEED14, HOME14,
];

const out = scanAll(nodes);
const s = out.scans;
let n = 0;
function ok(name, fn) {
  fn();
  n++;
  console.log("✓ " + name);
}

ok("輸出形狀：五支鍵齊全、corner_anchor 計數為整數、scanned_nodes 為輸入節點數", () => {
  assert.deepStrictEqual(Object.keys(s).sort(), ["corner_anchor", "cross_parent_collision", "row_overflow", "sibling_intersection", "text_occlusion"]);
  for (const k of ["containers", "points", "mismatch", "document_containers", "document_points", "document_mismatch"]) assert.ok(Number.isInteger(s.corner_anchor[k]), k);
  assert.ok(Array.isArray(s.corner_anchor.boards) && Array.isArray(s.corner_anchor.unresolved));
  assert.strictEqual(out.scanned_nodes, nodes.length);
});

ok("buildIndex：disabled 子樹傳遞（D／DC／DC 的角托不參與）；節點 id 重複一律 throw（不靜默覆蓋）", () => {
  const live = buildIndex(nodes).liveNodes.map((x) => x.id);
  assert.ok(!live.includes("D") && !live.includes("DC") && !live.includes("DC/Corner BR"));
  assert.ok(live.includes("E"));
  assert.throws(() => buildIndex([B, N("B", null, 1, 1, 1, 1)]), /id 重複/);
});

ok("(a) 兄弟交集：root 層兩板相鄰、S1×S2、PHOTO7×BAND7 接縫 1pt、角托蓋住兄弟紙面（B9／B10 各 4 對）；gap 8 的兩格不報；disabled 的 D×E 不報", () => {
  const want = [P("B", "B2"), P("S1", "S2"), P("PHOTO7", "BAND7")];
  for (const v of ["TL", "TR", "BL", "BR"]) want.push(P("PRINT9", "STAGE9/Corner " + v), P("PRINT10", "B10/Corner " + v));
  assert.deepStrictEqual(pairs(s.sibling_intersection.flagged), want.sort());
  const root = s.sibling_intersection.flagged.find((f) => f.node_a === "B");
  assert.strictEqual(root.parent, null);
  assert.strictEqual(root.parent_name, "root");
});

ok("(b) 橫列溢出：四個印品（含 40pt 的 PW8）的 Corner TR 與 BR 全部列出（不在第一筆停）、instance 路徑徽章右緣溢出 8；只看右緣；DC 角托不報", () => {
  const want = ["inst/wrap/badge"];
  for (const c of ["C1", "C2", "C3", "C4", "PW8"]) want.push(c + "/Corner TR", c + "/Corner BR");
  assert.deepStrictEqual(ids(s.row_overflow.flagged, "node"), want.sort());
  const badge = s.row_overflow.flagged.find((f) => f.node === "inst/wrap/badge");
  assert.strictEqual(badge.overflow, 8);
  assert.strictEqual(badge.parent, "inst/wrap");
});

ok("(c) 跨 parent 碰撞：相鄰格角托 TR×TL、BR×BL；B6 徽章×caption；MJ-2 A2 接縫 1pt 底下的 BADGE7 溢出 → 報最外層 BADGE7×BAND7（TITLE7 為其後代重複不重報）；T1×T2（各自沒溢出）不重報；祖先／後代不報；不跨板；非易出血類別（Feed×Home Indicator Area）預設不報", () => {
  const want = [P("C1/Corner TR", "C2/Corner TL"), P("C1/Corner BR", "C2/Corner BL"), P("BADGE6", "CAP6"), P("BADGE7", "BAND7")];
  assert.deepStrictEqual(pairs(s.cross_parent_collision.flagged), want.sort());
  const idx = buildIndex(nodes);
  for (const f of s.cross_parent_collision.flagged) {
    assert.notStrictEqual(f.parent_a, f.parent_b);
    assert.ok(!idx.chain.get(f.node_a).includes(f.node_b) && !idx.chain.get(f.node_b).includes(f.node_a), "祖先／後代不得成對");
    assert.strictEqual(idx.chain.get(f.node_a).slice(-1)[0], f.board);
    assert.strictEqual(idx.chain.get(f.node_b).slice(-1)[0], f.board);
    assert.strictEqual(f.board_name, idx.byId.get(f.board).name);
  }
  assert.deepStrictEqual(s.cross_parent_collision.flagged.find((f) => f.node_a === "C1/Corner TR").overlap, [2, 26]);
});

ok("(c) SCAN_CROSS_ALL（crossAll）：非易出血類別也報——多出 FEED14×HOME14（Feed 溢出 Column 撞 Home Indicator Area），其餘集合不變", () => {
  const all = scanAll(nodes, { crossAll: true }).scans.cross_parent_collision.flagged;
  assert.deepStrictEqual(pairs(all), pairs(s.cross_parent_collision.flagged).concat([P("FEED14", "HOME14")]).sort());
});

ok("(c) MJ-2 A3：BAND 下移 1pt（祖先兄弟不交集）時同一缺陷同樣報得出來（A2／A3 結果一致：BADGE7×BAND7）", () => {
  const band = N("BAND7", "B7", 5000, 300, 400, 120);
  const r = scanAll([B7, PHOTO7, band, BADGE7, TITLE7], { crossAll: true }).scans;
  assert.deepStrictEqual(pairs(r.sibling_intersection.flagged), []);
  assert.deepStrictEqual(pairs(r.cross_parent_collision.flagged), [P("BADGE7", "BAND7")]);
});

ok("compactLines：每支掃描一段分類彙整（同名對歸一類、附代表 id），corner_anchor 段列 in-scope 錯位／unresolved／document 按板計數", () => {
  const text = compactLines(scanAll(nodes, { boards: ["B5"] })).join("\n");
  assert.ok(text.includes("SCAN sibling_intersection flagged=11 classes="));
  assert.ok(text.includes("  4× PRINT9 × Corner TL @ STAGE9 e.g. PRINT9×STAGE9/Corner TL") === false, "同名對才歸一類：四顆角托名字不同，各自一類");
  assert.ok(text.includes("  1× PRINT9 × Corner TL @ STAGE9 e.g. PRINT9×STAGE9/Corner TL"));
  assert.ok(text.includes("  1× Corner TR × Corner TL @ B e.g. C1/Corner TR×C2/Corner TL"));
  assert.ok(text.includes("SCAN row_overflow flagged=11 classes="));
  assert.ok(text.includes("  1× C1 :: Corner TR e.g. C1/Corner TR (+5)"));
  assert.ok(text.includes('SCAN corner_anchor boards=["B5"] containers/points/mismatch=1/8/2 document=7/56/4 unresolved=1'));
  assert.ok(text.includes("  MISMATCH C3(C3) Corner BL y exp=157 act=149 paper=C3 board=LS-99 / 05 示範板"));
  assert.ok(text.includes("  UNRESOLVED STAGE11(STAGE11) 找不到吻合的紙面（父或兄弟） best="));
  assert.ok(text.includes("  DOCUMENT 2× board LS-17 / 01 舊板(B13) e.g. container C4"));
});

ok("(d) 角托錨點（全稿）：7 個容器解析到紙面、每容器 8 個斷言＝56 點；C3（−8）與 C4（+3）各 BL.y／BR.y 錯位 → document_mismatch 4；B11 進 unresolved；DC 不算", () => {
  const ca = s.corner_anchor;
  assert.deepStrictEqual([ca.document_containers, ca.document_points, ca.document_mismatch], [7, 56, 4]);
  assert.deepStrictEqual([ca.boards, ca.containers, ca.points, ca.mismatch], [[], 7, 56, 4], "未設 boards：全稿即範圍");
  assert.deepStrictEqual(ids(ca.document_flagged, "corner"), ["C3/Corner BL", "C3/Corner BR", "C4/Corner BL", "C4/Corner BR"]);
  for (const f of ca.document_flagged.filter((f) => f.container === "C3")) {
    assert.deepStrictEqual([f.paper, f.axis, f.expected, f.actual], ["C3", "y", 157, 149]);
  }
  assert.deepStrictEqual(ca.unresolved.map((u) => u.container), ["STAGE11"]);
  assert.strictEqual(ca.unresolved[0].best_score * 2 < ca.unresolved[0].total_axes, true);
});

ok("(d) B1：40×40 角托以自身實測寬高推期望（PW8＝Cxqc2 實數 385／535）→ 0 mismatch；若角托被搬到 26pt 假設的 399／549 反而錯位 4 點", () => {
  assert.strictEqual(scanCornerAnchor([B8, PW8, ...corners("PW8", "PW8", PW8, 40)]).mismatch, 0);
  const wrong = corners("PW8", "PW8", PW8, 40).map((c) => Object.assign({}, c, {
    x: c.name === "Corner TR" || c.name === "Corner BR" ? 6399 : c.x,
    y: c.name === "Corner BL" || c.name === "Corner BR" ? 549 : c.y,
  }));
  const r = scanCornerAnchor([B8, PW8, ...wrong]);
  assert.deepStrictEqual([r.points, r.mismatch], [8, 4]);
});

ok("(d) B2：角托與紙面是兄弟（HqrJw）→ 紙面取 Print 不取父 Print Stage；板層角托（BDrtd）→ 紙面取兄弟 Print；把 BL／BR y 改成用 Stage 高推就錯位 2 點且期望值來自 Print", () => {
  assert.strictEqual(scanCornerAnchor([B9, STAGE9, PRINT9, ...corners("STAGE9", "STAGE9", PRINT9)]).mismatch, 0);
  assert.strictEqual(scanCornerAnchor([B10, PRINT10, ...corners("B10", "B10", PRINT10, 40)]).mismatch, 0);
  const byStage = corners("STAGE9", "STAGE9", PRINT9).map((c) => Object.assign({}, c, {
    y: c.name === "Corner BL" || c.name === "Corner BR" ? STAGE9.y + STAGE9.h - 26 + 5 : c.y,
  }));
  const r = scanCornerAnchor([B9, STAGE9, PRINT9, ...byStage]);
  assert.deepStrictEqual([r.points, r.mismatch], [8, 2]);
  for (const f of r.flagged) assert.deepStrictEqual([f.paper, f.axis, f.expected], ["PRINT9", "y", r2(PRINT9.y + PRINT9.h - 26 + 5)]);
});

ok("(d) 範圍（a106f940）：boards=['B5'] → mismatch 只算 B5（2），document_mismatch 仍 4、C4 只在 document_flagged；boards 可用 root name；空 boards＝全稿", () => {
  const r = scanAll(nodes, { boards: ["B5"] }).scans.corner_anchor;
  assert.deepStrictEqual([r.boards, r.containers, r.points, r.mismatch], [["B5"], 1, 8, 2]);
  assert.deepStrictEqual([r.document_containers, r.document_points, r.document_mismatch], [7, 56, 4]);
  assert.deepStrictEqual(ids(r.flagged, "container"), ["C3", "C3"]);
  assert.deepStrictEqual(ids(r.document_flagged, "container"), ["C3", "C3", "C4", "C4"]);
  const byName = scanAll(nodes, { boards: ["LS-17 / 01 舊板", "nope"] }).scans.corner_anchor;
  assert.deepStrictEqual([byName.boards, byName.mismatch, byName.document_mismatch], [["B13", "nope"], 2, 4]);
});

ok("(d) 允差：0.5 內不算錯位、0.5 外算；兩對角容器（App icon ≤60pt）點數 4；沒有角托的樹 containers=0", () => {
  assert.strictEqual(scanCornerAnchor([B5, C3, ...corners("C3", "C3", C3, 26, { blbrDy: 0.4 })]).mismatch, 0);
  const off = scanCornerAnchor([B5, C3, ...corners("C3", "C3", C3, 26, { blbrDy: 0.6 })]);
  assert.deepStrictEqual([off.points, off.mismatch], [8, 2]);
  const icon = N("ICON", null, 0, 0, 60, 60);
  const two = [icon, N("ICON/Corner TL", "ICON", -5, -5, 26, 26, { name: "Corner TL" }), N("ICON/Corner BR", "ICON", 39, 39, 26, 26, { name: "Corner BR" })];
  const r = scanCornerAnchor(two);
  assert.deepStrictEqual([r.containers, r.points, r.mismatch, r.unresolved.length], [1, 4, 0, 0]);
  assert.deepStrictEqual(scanCornerAnchor([B, G]).containers, 0);
  const three = [icon, ...two.slice(1), N("ICON/Corner TR", "ICON", 39, -5, 26, 26, { name: "Corner TR" })];
  assert.deepStrictEqual([scanCornerAnchor(three).containers, scanCornerAnchor(three).unresolved.length], [0, 1], "角托數 3 → unresolved");
});

function r2(v) {
  return Math.round(v * 100) / 100;
}

// ───── LS-168 第五支 text_occlusion（絕對座標取自 LS-152 VR R1 f1cf27d0 實測；板原點平移到 0） ─────
// 板 OE（BL-3 t5wI4）：Body 內 Row · 儲存空間 y 715→790（Label 725→750、Value 765→790），Tab Bar absolute (16,754,361,64)
// 排在 Body 之後 → Value × Tab Bar 交集 241×25；Label 不交集；Tab Bar 自己的「設定」text 是其後代、不報
const OE = N("OE", null, 0, 0, 393, 852, { name: "LS-152 / 01 設定" });
const EBODY = N("EBODY", "OE", 0, 62, 393, 692, { name: "Body" });
const EROW = N("EROW", "EBODY", 24, 715, 345, 75, { name: "Row · 儲存空間" });
const ELABEL = N("ELABEL", "EROW", 70, 725, 241, 25, { name: "Label", type: "text" });
const EVALUE = N("EVALUE", "EROW", 70, 765, 241, 25, { name: "Value", type: "text" });
const ETAB = N("ETAB", "OE", 16, 754, 361, 64, { name: "Tab Bar", type: "ref" });
const ETABTXT = N("ETABTXT", "ETAB", 300, 780, 40, 20, { name: "設定", type: "text" });
// 板 OF（BL-2 z042Yg）：Link Wrap 的 Label 底 731、Underline 底 733（rectangle，非 text）；Action Bar 726→802 排在 Body 之後；
// Action Bar 內 Button Wrap 也命中不了 OVERLAY_RE、Primary Label 是 Action Bar 後代 → 只報 Label × Action Bar
const OF = N("OF", null, 1000, 0, 393, 852, { name: "LS-152 / 08 EULA 同意頁" });
const FBODY = N("FBODY", "OF", 1000, 62, 393, 664, { name: "Body" });
const FLINK = N("FLINK", "FBODY", 1024, 700, 345, 33, { name: "Link Wrap" });
const FLABEL = N("FLABEL", "FLINK", 1024, 706, 306, 25, { name: "Label", type: "text" });
const FUNDER = N("FUNDER", "FLINK", 1024, 732, 238, 1, { name: "Underline", type: "rectangle" });
const FBAR = N("FBAR", "OF", 1000, 726, 393, 76, { name: "Action Bar" });
const FWRAP = N("FWRAP", "FBAR", 1000, 727, 393, 75, { name: "Button Wrap" });
const FBTN = N("FBTN", "FWRAP", 1024, 743, 345, 44, { name: "Agree Button", type: "ref" });
const FBTNTXT = N("FBTNTXT", "FBTN", 1150, 752, 90, 25, { name: "Primary Label", type: "text" });
// 板 OG（sheet）：Status Bar 的時間 text 在 Scrim 之下（Scrim 為後繪的 absolute 兄弟）——預設不報（Scrim 不在 OVERLAY_RE），
// 覆寫 overlayRe 含 Scrim 才報；Confirm Sheet 內的 text 在 Sheet Wrap 之下但 Sheet Wrap 是祖先 → 不報
const OG = N("OG", null, 2000, 0, 393, 852, { name: "LS-152 / 10 刪除日記 · 確認" });
const GSB = N("GSB", "OG", 2000, 0, 393, 62, { name: "Status Bar (Backdrop)", type: "ref" });
const GTIME = N("GTIME", "GSB", 2028, 20, 40, 20, { name: "Time", type: "text" });
const GSCRIM = N("GSCRIM", "OG", 2000, 0, 393, 852, { name: "Scrim" });
const GWRAP = N("GWRAP", "OG", 2000, 0, 393, 852, { name: "Sheet Wrap" });
const GSHEET = N("GSHEET", "GWRAP", 2000, 500, 393, 352, { name: "Confirm Sheet" });
const GTXT = N("GTXT", "GSHEET", 2024, 530, 345, 25, { name: "Title", type: "text" });
// 板 OH：z-order——Banner 先繪（排在內容之前）、內容 text 蓋在 Banner 上 → 不報；disabled 的 Toast 蓋住 text → 不報；
// 交集面積恰為 0（邊緣相接）→ 不報；Footer 內含 Toast 兩層都蓋住同一 text → 只報最外層 Footer
const OH = N("OH", null, 3000, 0, 393, 852, { name: "OH 板" });
const HBANNER = N("HBANNER", "OH", 3000, 0, 393, 60, { name: "Banner" });
const HTXT1 = N("HTXT1", "OH", 3024, 20, 200, 25, { name: "Over Banner", type: "text" });
const HTOAST = N("HTOAST", "OH", 3000, 100, 393, 40, { name: "Toast", enabled: false });
const HTXT2 = N("HTXT2", "OH", 3024, 110, 200, 25, { name: "Under Disabled Toast", type: "text" });
const HTXT3 = N("HTXT3", "OH", 3024, 300, 200, 25, { name: "Touching", type: "text" });
const HTOAST2 = N("HTOAST2", "OH", 3000, 325, 393, 40, { name: "Toast" });
const HTXT4 = N("HTXT4", "OH", 3024, 700, 200, 25, { name: "Under Footer", type: "text" });
const HFOOT = N("HFOOT", "OH", 3000, 690, 393, 100, { name: "Footer" });
const HFOOTTOAST = N("HFOOTTOAST", "HFOOT", 3000, 695, 393, 40, { name: "Toast" });
// 板 OI：與板 OH 的 Footer 在畫布座標上重疊的 text（不同板）→ 不跨板報
const OI = N("OI", null, 3000, 700, 393, 852, { name: "OI 板" });
const ITXT = N("ITXT", "OI", 3024, 705, 200, 25, { name: "Other Board Text", type: "text" });

const occNodes = [
  OE, EBODY, EROW, ELABEL, EVALUE, ETAB, ETABTXT,
  OF, FBODY, FLINK, FLABEL, FUNDER, FBAR, FWRAP, FBTN, FBTNTXT,
  OG, GSB, GTIME, GSCRIM, GWRAP, GSHEET, GTXT,
  OH, HBANNER, HTXT1, HTOAST, HTXT2, HTXT3, HTOAST2, HTXT4, HFOOT, HFOOTTOAST,
  OI, ITXT,
];
const occ = scanAll(occNodes).scans.text_occlusion.flagged;
const occPairs = (f) => f.map((x) => x.node + "×" + x.overlay).sort();

ok("(e) 文字遮蔽：BL-3 Value × Tab Bar（241×25）、BL-2 Label × Action Bar 各報一筆；Label 不交集、Underline 非 text、Tab Bar／Action Bar 自己的後代 text 都不報；四支對這兩筆確實無感", () => {
  assert.deepStrictEqual(occPairs(occ.filter((x) => x.board === "OE" || x.board === "OF")), ["EVALUE×ETAB", "FLABEL×FBAR"]);
  const v = occ.find((x) => x.node === "EVALUE");
  assert.deepStrictEqual([v.overlay_name, v.board_name, v.overlap], ["Tab Bar", "LS-152 / 01 設定", [241, 25]]);
  const l = occ.find((x) => x.node === "FLABEL");
  assert.deepStrictEqual([l.overlay_name, l.overlap], ["Action Bar", [306, 5]]);
  const four = scanAll([OE, EBODY, EROW, ELABEL, EVALUE, ETAB, ETABTXT, OF, FBODY, FLINK, FLABEL, FUNDER, FBAR, FWRAP, FBTN, FBTNTXT], { crossAll: true }).scans;
  const named = (arr) => arr.filter((f) => /EVALUE|FLABEL/.test(f.node_a + f.node_b + (f.node || "")));
  assert.deepStrictEqual(named(four.cross_parent_collision.flagged).map((f) => f.node_a + "×" + f.node_b), [], "跨 parent 碰撞去重後只剩最外層 Body×Tab Bar／Body×Action Bar，指不到 text 節點");
});

ok("(e) z-order：Scrim 預設不算覆蓋層（modal 蓋底稿是刻意的）、overlayRe 覆寫含 Scrim 才報且 Sheet Wrap 對自己的後代不報；先繪的 Banner 不報；disabled Toast 不報；邊緣相接（面積 0）不報；Footer⊃Toast 只報最外層 Footer；不跨板", () => {
  assert.deepStrictEqual(occPairs(occ.filter((x) => x.board === "OG")), []);
  const withScrim = scanTextOcclusion(occNodes, undefined, { overlayRe: /Scrim|Sheet|Tab Bar|Action Bar/ }).flagged;
  assert.deepStrictEqual(occPairs(withScrim.filter((x) => x.board === "OG")), ["GTIME×GSCRIM", "GTIME×GWRAP"], "Scrim 與 Sheet Wrap 是兄弟（非祖先鏈）、各報一筆；Confirm Sheet 是 Sheet Wrap 的後代、只報最外層 Sheet Wrap");
  const strRe = scanTextOcclusion(occNodes, undefined, { overlayRe: "Scrim" }).flagged;
  assert.deepStrictEqual(occPairs(strRe), ["GTIME×GSCRIM"], "字串形式的覆寫（Pencil 端 SCAN_OVERLAY_RE）也可用");
  assert.deepStrictEqual(occPairs(occ.filter((x) => x.board === "OH")), ["HTXT4×HFOOT"]);
  assert.deepStrictEqual(occPairs(occ.filter((x) => x.board === "OI")), []);
});

ok("(e) 範圍（同 corner_anchor）：boards=['OE'] → flagged 只算 OE（1）、document_flagged 仍 3；空 boards＝全稿；compactLines 段列 in-scope 分類＋DOCUMENT 按板計數", () => {
  const r = scanAll(occNodes, { boards: ["OE"] }).scans.text_occlusion;
  assert.deepStrictEqual([r.boards, occPairs(r.flagged), occPairs(r.document_flagged)], [["OE"], ["EVALUE×ETAB"], ["EVALUE×ETAB", "FLABEL×FBAR", "HTXT4×HFOOT"]]);
  const all = scanAll(occNodes).scans.text_occlusion;
  assert.deepStrictEqual([all.boards, occPairs(all.flagged)], [[], occPairs(all.document_flagged)]);
  const text = compactLines(scanAll(occNodes, { boards: ["OE"] })).join("\n");
  assert.ok(text.includes('SCAN text_occlusion boards=["OE"] flagged=1 classes=1 document=3'));
  assert.ok(text.includes("  1× Value × Tab Bar @ LS-152 / 01 設定(OE) e.g. EVALUE×ETAB"));
  assert.ok(text.includes("  DOCUMENT 1× board LS-152 / 08 EULA 同意頁(OF) e.g. FLABEL×FBAR"));
});

// 板 OJ（LS-142 16 上傳佇列 rTEGf 的形狀）：clip:true 的 List 在 Footer 上方結束（List 0→700、Footer 700→790），列的 text 捲到
// List 底緣外（690→715）——可見部分只到 700，與 Footer 不交集 → 不報；同一幾何把 List 的 clip 拿掉就是真的被蓋 → 報
const OJ = N("OJ", null, 4000, 0, 393, 852, { name: "OJ 板", clip: true });
const OJLIST = N("OJLIST", "OJ", 4000, 0, 393, 700, { name: "List", clip: true });
const OJROW = N("OJROW", "OJLIST", 4000, 690, 393, 25, { name: "Row" });
const OJTXT = N("OJTXT", "OJROW", 4024, 690, 200, 25, { name: "Timestamp", type: "text" });
const OJFOOT = N("OJFOOT", "OJ", 4000, 700, 393, 90, { name: "Footer" });
ok("(e) 裁切：text 被 clip:true 的祖先（捲動 List）裁掉的部分不算被蓋——List 在 Footer 上方結束時不報；同一幾何 List 不裁切就報（可見矩形 ∩ Footer）", () => {
  assert.deepStrictEqual(occPairs(scanAll([OJ, OJLIST, OJROW, OJTXT, OJFOOT]).scans.text_occlusion.flagged), []);
  const noClip = Object.assign({}, OJLIST, { clip: false });
  const r = scanAll([OJ, noClip, OJROW, OJTXT, OJFOOT]).scans.text_occlusion.flagged;
  assert.deepStrictEqual(occPairs(r), ["OJTXT×OJFOOT"]);
  assert.deepStrictEqual(r[0].overlap, [200, 15]);
  const half = Object.assign({}, OJLIST, { h: 705 });
  assert.deepStrictEqual(scanAll([OJ, half, OJROW, OJTXT, OJFOOT]).scans.text_occlusion.flagged[0].overlap, [200, 5], "List 伸進 Footer 5pt：只有那 5pt 可見部分算被蓋");
});

// ───── LS-168 tree_hash：canon／FNV-1a 64／逐行相加，與 scripts/gates/design_tree_hash.py 同值 ─────
const doc = {
  version: "2.17",
  children: [
    { type: "frame", id: "Ab12C", name: "板 一", x: 0, y: 0, width: 393, height: 852, layout: "vertical", padding: [8, "$screen-pad"], fill: { type: "gradient", size: { width: 1.6997455470737914 } },
      children: [
        { type: "text", id: "Tt9x", name: "Label 🎉", content: "多行\n\"引號\"\t\\ 反斜線", fontSize: "$fs-note" },
        { type: "ref", id: "Rr7q", ref: "Cmp1", name: "Row", width: "fill_container", descendants: { n1hzsr: { enabled: false, y: 0 }, Zz: { content: "值" } } },
      ] },
    { type: "frame", id: "Cmp1", name: "cmp/Row", x: 100, y: 254.5, width: 100, reusable: true, children: [{ type: "text", id: "Zz", name: "V", enabled: true }] },
    // LS-171：path 節點（cmp/Photo Corner 的 Corner Shape 形狀）＋空 geometry 的 path（真實稿 mzo0K）——Pencil Get 預設把 geometry 省略成 "..."
    { type: "path", id: "Pp5kQ", name: "Corner Shape", x: 0, y: 0, width: 26, height: 26, viewBox: [0, 0, 26, 26], fill: "#8E2447", geometry: "M0 14a14 14 0 0 1 14-14l12 0-26 26z" },
    { type: "path", id: "Sq9uR", name: "Squircle", width: 512, height: 512, viewBox: [0, 0, 512, 512], stroke: "#8E2447", strokeWidth: 3, geometry: "" },
  ],
};
const clone = () => JSON.parse(JSON.stringify(doc));
const H0 = treeHash(treeHashLines(doc));

ok("tree_hash：canon 鍵序無關、去掉 children、行含父 id 與 index；FNV-1a 64 對照向量（''／'a'／'foobar'）；輸出 16 碼 hex", () => {
  assert.strictEqual(canon({ b: 1, a: [true, null, "x"] }), canon({ a: [true, null, "x"], b: 1 }));
  assert.strictEqual(canon({ b: 1, a: [true, null, "x"] }), '{"a":[true,null,"x"],"b":1}');
  assert.strictEqual(canonNode(doc.children[0], null, 0).split("\t").slice(0, 2).join("\t"), "\t0");
  assert.strictEqual(canonNode(doc.children[0].children[1], "Ab12C", 1).split("\t").slice(0, 2).join("\t"), "Ab12C\t1");
  assert.ok(!canonNode(doc.children[0], null, 0).includes("children"));
  assert.strictEqual(hex64(fnv1a64("")), "cbf29ce484222325");
  assert.strictEqual(hex64(fnv1a64("a")), "af63dc4c8601ec8c");
  assert.strictEqual(hex64(fnv1a64("foobar")), "85944171f73967e8");
  assert.ok(/^[0-9a-f]{16}$/.test(H0));
});

ok("tree_hash 敏感度：改一個節點的 x／enabled、兄弟換序、搬到別的父、改 descendants 覆寫、改 content 各自得到不同值；純 children 順序不變則相同", () => {
  const seen = new Set([H0]);
  const variants = [
    (d) => { d.children[1].x = 101; },
    (d) => { d.children[1].children[0].enabled = false; },
    (d) => { d.children[0].children.reverse(); },
    (d) => { const t = d.children[0].children.shift(); d.children[1].children.push(t); },
    (d) => { d.children[0].children[1].descendants.n1hzsr.y = 1; },
    (d) => { d.children[0].children[0].content += "。"; },
    (d) => { d.children[0].padding = [8, 24]; },
  ];
  for (const mut of variants) {
    const d = clone();
    mut(d);
    const h = treeHash(treeHashLines(d));
    assert.ok(!seen.has(h), "變體應得到新的 hash");
    seen.add(h);
  }
  assert.strictEqual(treeHash(treeHashLines(clone())), H0);
  const shuffled = treeHashLines(doc).reverse();
  assert.strictEqual(treeHash(shuffled), H0, "逐行相加：走訪順序無關（但 index 已在行內，兄弟換序仍會變）");
});

ok("LS-171 geometry：path 的 geometry 被省略成 \"...\"（Pencil Get 不帶 includePathGeometry 的輸出）→ tree_hash 不同；改一個字元也不同；空字串 geometry 原樣參與", () => {
  const d = clone();
  let n = 0;
  const walk = (x) => { if (x.geometry !== undefined) { x.geometry = "..."; n++; } (x.children || []).forEach(walk); };
  d.children.forEach(walk);
  assert.strictEqual(n, 2, "fixture 應有兩個帶 geometry 的 path（含一個空字串）");
  assert.notStrictEqual(treeHash(treeHashLines(d)), H0, "geometry 省略成 \"...\" 必須改變 tree_hash（gate 才抓得到 Pencil 端漏帶選項）");
  const e = clone();
  e.children[2].geometry += "z";
  assert.notStrictEqual(treeHash(treeHashLines(e)), H0);
  assert.ok(canonNode(doc.children[3], null, 3).includes('"geometry":""'), "空 geometry 以 \"\" 參與雜湊（真實稿 mzo0K 兩端皆為空字串）");
});

ok("LS-171 原始碼斷言：Pencil 端雜湊走訪的 Get 帶 {includePathGeometry: true}，且 SCAN_HASH_ONLY／SCAN_SKIP_HASH 拆兩次的旗標存在", () => {
  const src = require("fs").readFileSync(path.join(__dirname, "overflow-scan.js"), "utf8");
  const m = src.match(/Get\(\(n, c\) => \{[^]*?addLimbs\(hashAcc, fnv1a64\(line\)\);[^]*?\n  \}, (\{[^}]*\})\);/);
  assert.ok(m, "找不到雜湊走訪的 Get(visit, options) 呼叫");
  assert.ok(/includePathGeometry:\s*true/.test(m[1]), "雜湊走訪的 Get 必須帶 includePathGeometry: true，否則 Pencil 端 geometry 是 \"...\"、tree_hash 與 CI 必不同（LS-171）");
  assert.ok(src.includes("SCAN_HASH_ONLY") && src.includes("SCAN_SKIP_HASH") && src.includes("SUMMARY-HASH"), "拆兩次 execute 的旗標／輸出必須存在");
});

ok("tree_hash js／py 交叉一致：同一份合成 .pen（含 emoji／轉義／浮點／instance descendants／path geometry）python design_tree_hash.py 算出同值；--dump 行與 canonNode 逐字相同", () => {
  const fs = require("fs");
  const os = require("os");
  const { execFileSync } = require("child_process");
  const tmp = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "LS-168-hash-")), "synthetic.pen");
  fs.writeFileSync(tmp, JSON.stringify(doc));
  const py = path.join(__dirname, "..", "gates", "design_tree_hash.py");
  const got = execFileSync("python3", [py, tmp], { encoding: "utf8" }).trim();
  assert.strictEqual(got, H0);
  const dump = execFileSync("python3", [py, tmp, "--dump", "Rr7q"], { encoding: "utf8" }).replace(/\n$/, "");
  assert.strictEqual(dump, canonNode(doc.children[0].children[1], "Ab12C", 1));
  const dumpPath = execFileSync("python3", [py, tmp, "--dump", "Pp5kQ"], { encoding: "utf8" }).replace(/\n$/, "");
  assert.strictEqual(dumpPath, canonNode(doc.children[2], null, 2), "path 節點（含 geometry）的行 js／py 逐字相同");
  fs.rmSync(path.dirname(tmp), { recursive: true, force: true });
});

console.log("overflow-scan.test.js：全數通過（" + n + " 組）");
