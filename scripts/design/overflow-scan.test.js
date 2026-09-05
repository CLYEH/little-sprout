// scripts/design/overflow-scan.js 的自測（LS-122）。CI rules job 自測 step 跑 `node scripts/design/overflow-scan.test.js`。
// 純函數對合成節點樹（絕對座標）驗各支掃描的語意（支數以 overflow-scan.js 檔頭為準）；每條斷言都對應一個 LS-119 R5 抓到的盲區、既有語意、或 merge-review R1
// 的反例（B1 40pt 角托、B2 角托與紙面是兄弟／板層角托、MJ-2 祖先刻意接縫 1pt 底下的真碰撞），斷言的是**精確的命中集合**
// （不是「至少有一筆」）——演算法退化（少比一支、祖先後代沒排除、disabled 沒傳遞、Corner BR 漏掉、跨 parent 去重吃掉溢出
// 類、角托尺寸寫死、紙面誤取父節點）任一種都會讓集合改變而紅。
"use strict";
const assert = require("assert");
const path = require("path");
const { scanAll, scanCornerAnchor, scanTextOcclusion, scanBoardClip, buildIndex, compactLines, canon, canonNode, fnv1a64, hex64, treeHash, treeHashLines, PHOTO_CORNER_ID } = require(path.join(__dirname, "overflow-scan.js"));

function N(id, parent, x, y, w, h, extra) {
  return Object.assign({ id, name: id, parent, type: "frame", enabled: true, x, y, w, h }, extra || {});
}
// LS-202：角托＝ref → cmp/Photo Corner（GEBcf）的實例；名稱只供方位。C() 造一顆角托 ref（真實稿 736 顆全是這個形狀）
function C(id, parent, x, y, s, name, extra) {
  return N(id, parent, x, y, s, s, Object.assign({ name, type: "ref", ref: PHOTO_CORNER_ID }, extra || {}));
}
// corners(prefix, parentId, paper, size, opts)：依 corner-out 5 規則放四顆角托（絕對座標），paper 為角托咬住的紙面 AABB
function corners(prefix, parentId, paper, size, opts) {
  const o = opts || {};
  const dy = o.blbrDy || 0;
  const on = o.enabled !== false;
  const s = size || 26;
  const L = paper.x - 5, T = paper.y - 5, R = paper.x + paper.w - s + 5, B = paper.y + paper.h - s + 5;
  return [
    C(prefix + "/Corner TL", parentId, L, T, s, "Corner TL", { enabled: on }),
    C(prefix + "/Corner TR", parentId, R, T, s, "Corner TR", { enabled: on }),
    C(prefix + "/Corner BL", parentId, L, B + dy, s, "Corner BL", { enabled: on }),
    C(prefix + "/Corner BR", parentId, R, B + dy, s, "Corner BR", { enabled: on }),
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
const LOST = ["TL", "TR", "BL", "BR"].map((v, i) => C("STAGE11/Corner " + v, "STAGE11", 9020 + i * 40, 250, 26, "Corner " + v));
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

ok("輸出形狀：六支鍵齊全、corner_anchor 計數為整數、scanned_nodes 為輸入節點數；每支帶 scope 與非負整數 document_count（LS-202）", () => {
  assert.deepStrictEqual(Object.keys(s).sort(), ["board_clip", "corner_anchor", "cross_parent_collision", "row_overflow", "sibling_intersection", "text_occlusion"]);
  for (const k of ["containers", "points", "mismatch", "document_containers", "document_points", "document_mismatch"]) assert.ok(Number.isInteger(s.corner_anchor[k]), k);
  assert.ok(Array.isArray(s.corner_anchor.boards) && Array.isArray(s.corner_anchor.unresolved) && Array.isArray(s.corner_anchor.document_unresolved) && Array.isArray(s.corner_anchor.container_corners));
  assert.strictEqual(out.scanned_nodes, nodes.length);
  for (const k of Object.keys(s)) {
    assert.strictEqual(s[k].scope, "document", k);
    assert.ok(Number.isInteger(s[k].document_count) && s[k].document_count >= 0, k + ".document_count");
  }
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

ok("compactLines：每支掃描一段分類彙整（同名對歸一類、附代表 id），corner_anchor 段列 in-scope 錯位／unresolved／document 按板計數；六段標頭尾綴 scope／document_count（LS-202）", () => {
  const text = compactLines(scanAll(nodes, { boards: ["B5"] })).join("\n");
  assert.ok(text.includes("SCAN sibling_intersection flagged=11 classes=11 scope=document document_count=11"), text.split("\n")[0]);
  assert.ok(text.includes("  4× PRINT9 × Corner TL @ STAGE9 e.g. PRINT9×STAGE9/Corner TL") === false, "同名對才歸一類：四顆角托名字不同，各自一類");
  assert.ok(text.includes("  1× PRINT9 × Corner TL @ STAGE9 e.g. PRINT9×STAGE9/Corner TL"));
  assert.ok(text.includes("  1× Corner TR × Corner TL @ B e.g. C1/Corner TR×C2/Corner TL"));
  assert.ok(text.includes("SCAN row_overflow flagged=11 classes="));
  assert.ok(/SCAN row_overflow flagged=11 classes=\d+ scope=document document_count=11/.test(text));
  assert.ok(/SCAN cross_parent_collision flagged=4 classes=\d+ scope=document document_count=4/.test(text));
  assert.ok(text.includes("  1× C1 :: Corner TR e.g. C1/Corner TR (+5)"));
  // B11 的 unresolved 不在 boards 內 → in-scope 0、document 1（LS-202 unresolved 同 mismatch 限 boards）
  assert.ok(text.includes('SCAN corner_anchor boards=["B5"] containers/points/mismatch=1/8/2 document=7/56/4 ref_hits=32(defs=0) unresolved=0/1 scope=document document_count=4'), text);
  assert.ok(text.includes("  MISMATCH C3(C3) Corner BL y exp=157 act=149 paper=C3 board=LS-99 / 05 示範板"));
  assert.ok(!text.includes("  UNRESOLVED STAGE11(STAGE11)"), "B11 不在 boards 內：不逐筆列 UNRESOLVED");
  assert.ok(text.includes("  DOCUMENT-UNRESOLVED 1× board B11(B11) e.g. container STAGE11"), text);
  assert.ok(text.includes("  DOCUMENT 2× board LS-17 / 01 舊板(B13) e.g. container C4"));
  assert.ok(/SCAN text_occlusion boards=\["B5"\] flagged=0 classes=0 document=0 scope=document document_count=0/.test(text));
  assert.ok(/SCAN board_clip boards=\["B5"\] flagged=0 classes=0 document=0 scope=document document_count=0/.test(text));
  const all = compactLines(scanAll(nodes)).join("\n");
  assert.ok(all.includes("  UNRESOLVED STAGE11(STAGE11) 找不到吻合的紙面（父或兄弟） best="), "空 boards＝全稿：B11 逐筆列 UNRESOLVED");
  assert.ok(all.includes("unresolved=1/1 "), all);
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
  assert.deepStrictEqual(ca.document_unresolved.map((u) => u.container), ["STAGE11"]);
  assert.strictEqual(ca.unresolved[0].best_score * 2 < ca.unresolved[0].total_axes, true);
  assert.deepStrictEqual(ca.container_corners.map((c) => c.container + ":" + c.n).sort(), ["C1:4", "C2:4", "C3:4", "C4:4", "PW8:4", "STAGE11:4", "STAGE9:4", "B10:4"].sort(), "container_corners 逐容器列角托數（DC 在 disabled 子樹、不列）");
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
  // LS-202：unresolved 同 mismatch 限 boards——B11 的 STAGE11 在 boards=['B5'] 時只進 document_unresolved
  assert.deepStrictEqual([r.unresolved.map((u) => u.container), r.document_unresolved.map((u) => u.container)], [[], ["STAGE11"]]);
  const b11 = scanAll(nodes, { boards: ["B11"] }).scans.corner_anchor;
  assert.deepStrictEqual([b11.unresolved.map((u) => u.container), b11.document_unresolved.map((u) => u.container), b11.containers], [["STAGE11"], ["STAGE11"], 0]);
});

ok("(d) 允差：0.5 內不算錯位、0.5 外算；兩對角容器（App icon ≤60pt）點數 4；沒有角托的樹 containers=0", () => {
  assert.strictEqual(scanCornerAnchor([B5, C3, ...corners("C3", "C3", C3, 26, { blbrDy: 0.4 })]).mismatch, 0);
  const off = scanCornerAnchor([B5, C3, ...corners("C3", "C3", C3, 26, { blbrDy: 0.6 })]);
  assert.deepStrictEqual([off.points, off.mismatch], [8, 2]);
  const icon = N("ICON", null, 0, 0, 60, 60);
  const two = [icon, C("ICON/Corner TL", "ICON", -5, -5, 26, "Corner TL"), C("ICON/Corner BR", "ICON", 39, 39, 26, "Corner BR")];
  const r = scanCornerAnchor(two);
  assert.deepStrictEqual([r.containers, r.points, r.mismatch, r.unresolved.length], [1, 4, 0, 0]);
  assert.deepStrictEqual(scanCornerAnchor([B, G]).containers, 0);
  const three = [icon, ...two.slice(1), C("ICON/Corner TR", "ICON", 39, -5, 26, "Corner TR")];
  assert.deepStrictEqual([scanCornerAnchor(three).containers, scanCornerAnchor(three).unresolved.length], [0, 1], "角托數 3 → unresolved");
});

// ───── LS-202 角托判準＝ref → cmp/Photo Corner（LS-96 0617b9ae：cmp/Profile Print 的 Mount TL/BR 名稱不是 Corner …，名稱判準永遠看不到） ─────
// 板 MA（cmp/Profile Print OePXK／lOPO7 實數）：Print 60×60、Photo (7.5,7.5,45,45)、Mount TL (−3.8,−3.8) 16.4、Mount BR (47.4,47.4) 16.4
// ——corner-out 3.8 而非 5：兩顆四軸全偏 1.2 > TOL，任何候選都 0/4 → unresolved（best=Print）；修成 corner-out 5（−5／48.6）→ 解析到 Print、4 點 0 錯位
const MA = N("MA", null, 20000, 0, 393, 852, { name: "LS-152 / 01 設定" });
const MAPRINT = N("MAPRINT", "MA", 20024, 100, 60, 60, { name: "Print" });
const MAPHOTO = N("MAPHOTO", "MAPRINT", 20031.5, 107.5, 45, 45, { name: "Photo", image: true });
const MATL = C("MAPRINT/Mount TL", "MAPRINT", 20024 - 3.8, 100 - 3.8, 16.4, "Mount TL");
const MABR = C("MAPRINT/Mount BR", "MAPRINT", 20024 + 47.4, 100 + 47.4, 16.4, "Mount BR");
const mountNodes = [MA, MAPRINT, MAPHOTO, MATL, MABR];

ok("(d) LS-202 Mount TL/BR：ref → GEBcf 但名稱不是 Corner … 的兩顆角托被算成一個兩對角容器——實數 corner-out 3.8 → unresolved（best=Print 0/4，不計 mismatch）；修成 corner-out 5 → containers 1／points 4／mismatch 0；名稱判準（退回舊實作）這個容器完全不存在", () => {
  const r = scanCornerAnchor(mountNodes);
  assert.deepStrictEqual([r.containers, r.points, r.mismatch, r.unresolved.length, r.document_unresolved.length], [0, 0, 0, 1, 1]);
  assert.deepStrictEqual([r.unresolved[0].container, r.unresolved[0].best_candidate, r.unresolved[0].best_score, r.unresolved[0].total_axes, r.unresolved[0].corners], ["MAPRINT", "MAPRINT", 0, 4, ["MAPRINT/Mount TL", "MAPRINT/Mount BR"]]);
  assert.deepStrictEqual(r.container_corners, [{ container: "MAPRINT", container_name: "Print", board: "MA", board_name: "LS-152 / 01 設定", n: 2, in_scope: true }]);
  const fixed = [MA, MAPRINT, MAPHOTO, C("MAPRINT/Mount TL", "MAPRINT", 20024 - 5, 100 - 5, 16.4, "Mount TL"), C("MAPRINT/Mount BR", "MAPRINT", 20024 + 48.6, 100 + 48.6, 16.4, "Mount BR")];
  const f = scanCornerAnchor(fixed);
  assert.deepStrictEqual([f.containers, f.points, f.mismatch, f.unresolved.length], [1, 4, 0, 0]);
  // 只差 y 偏 1（TOL 外）→ 解析到 Print（x 軸 2/4 吻合＝一半）、mismatch 2、期望值來自 Print
  const offY = [MA, MAPRINT, MAPHOTO, C("MAPRINT/Mount TL", "MAPRINT", 20024 - 5, 100 - 4, 16.4, "Mount TL"), C("MAPRINT/Mount BR", "MAPRINT", 20024 + 48.6, 100 + 49.6, 16.4, "Mount BR")];
  const o = scanCornerAnchor(offY);
  assert.deepStrictEqual([o.containers, o.points, o.mismatch, o.flagged.map((x) => x.paper + ":" + x.axis)], [1, 4, 2, ["MAPRINT:y", "MAPRINT:y"]]);
});

ok("(d) LS-202 R2 名稱備援（merge-review R1 minor-1）：只有名稱 Corner TL/TR/BL/BR、沒有 ref 的 frame 角托仍被算到（快照讀不到 ref 時最壞退回 LS-122 名稱判準，不得 containers=0 全綠）；ref 指向別的元件但名為 Corner … 也算；名為 Mount 而非 ref 不算；ref 指向 id 不同但名為 cmp/Photo Corner 的元件定義（元件名稱備援）照算；快照沒有元件定義根時退回字面 GEBcf", () => {
  const paper = N("PN", "MA", 20100, 300, 100, 178);
  const framey = corners("PN", "PN", paper).map((c) => Object.assign({}, c, { type: "frame", ref: undefined }));
  const fr = scanCornerAnchor([MA, paper, ...framey]);
  assert.deepStrictEqual([fr.containers, fr.points, fr.mismatch, fr.unresolved.length, fr.container_corners.map((c) => c.container + ":" + c.n)], [1, 8, 0, 0, ["PN:4"]], "名稱備援：無 ref 的 Corner TL/… frame 仍成容器");
  const otherRef = corners("PN", "PN", paper).map((c) => Object.assign({}, c, { ref: "bhroo" }));
  const ro = scanCornerAnchor([MA, paper, ...otherRef]);
  assert.deepStrictEqual([ro.containers, ro.points, ro.mismatch], [1, 8, 0], "ref 指向他元件但名稱是 Corner …：名稱備援仍算");
  const mountFrames = [MA, MAPRINT, MAPHOTO, Object.assign({}, MATL, { type: "frame", ref: undefined }), Object.assign({}, MABR, { type: "frame", ref: undefined })];
  assert.deepStrictEqual(scanCornerAnchor(mountFrames).container_corners, [], "Mount TL/BR 只靠 ref：名為 Mount 的非 ref frame 不算");
  const CMP = N("NEWID", null, 30000, 0, 26, 26, { name: "cmp/Photo Corner" });
  const byNameRef = corners("PN", "PN", paper).map((c) => Object.assign({}, c, { ref: "NEWID" }));
  const rn = scanCornerAnchor([CMP, MA, paper, ...byNameRef]);
  assert.deepStrictEqual([rn.containers, rn.points, rn.mismatch], [1, 8, 0], "元件重建換 id、名稱仍是 cmp/Photo Corner → 照算");
  const rn2 = scanCornerAnchor([MA, paper, ...byNameRef.map((c) => Object.assign({}, c, { name: c.name.replace("Corner", "Mount") }))]);
  assert.deepStrictEqual(rn2.containers, 0, "快照沒有那個元件定義根、ref 又不是 GEBcf、名稱也不是 Corner … → 不算");
  const rn3 = scanCornerAnchor([CMP, MA, paper, ...corners("PN", "PN", paper)]);
  assert.deepStrictEqual(rn3.containers, 1, "有名稱備援根時字面 GEBcf 仍算（id 為主）");
  const noVar = [MA, paper, ...corners("PN", "PN", paper).map((c, i) => (i === 0 ? Object.assign({}, c, { name: "Mount" }) : c))];
  const nv = scanCornerAnchor(noVar);
  assert.deepStrictEqual([nv.containers, nv.unresolved.length], [0, 1]);
  assert.ok(/角托名稱無方位/.test(nv.unresolved[0].reason) && nv.unresolved[0].reason.includes("Mount"), nv.unresolved[0].reason);
});

ok("(d) LS-202 document_count：只設 boards（不限縮）時六支 document_count 與全稿跑逐支相同、限 boards 的三支 flagged ≤ document_count；scanScope=boards 限縮後 document_count 為限縮值、scope=boards", () => {
  const full = scanAll(nodes).scans;
  const part = scanAll(nodes, { boards: ["B5"] }).scans;
  for (const k of Object.keys(full)) {
    assert.strictEqual(part[k].document_count, full[k].document_count, k);
    assert.strictEqual(full[k].document_count, (full[k].document_flagged || full[k].flagged).length, k + " 取自 document_flagged／flagged 長度");
    assert.ok(part[k].flagged.length <= part[k].document_count, k);
  }
  assert.deepStrictEqual([part.corner_anchor.flagged.length, part.corner_anchor.document_count], [2, 4]);
  assert.deepStrictEqual([full.sibling_intersection.document_count, full.row_overflow.document_count, full.cross_parent_collision.document_count], [11, 11, 4]);
  const shrunk = scanAll(nodes, { scanScope: "boards", boards: ["B5"] }).scans;
  for (const k of Object.keys(shrunk)) assert.strictEqual(shrunk[k].scope, "boards", k);
  assert.deepStrictEqual([shrunk.corner_anchor.document_count, shrunk.sibling_intersection.document_count], [2, 0]);
});

ok("LS-207 原始碼斷言：Pencil 端建 resolveInstances:false 的 ref 對照表（refMap）並在展開版快照榫接回 n.id → ref（resolveInstances:true 展開後的節點本身不再是 type:\"ref\"，LS-201 VR R2／R3 實測，光看 n.ref 會永遠是 undefined）；SUMMARY 後印 cornerWarnings 的 WARNING 行", () => {
  const src = require("fs").readFileSync(path.join(__dirname, "overflow-scan.js"), "utf8");
  assert.ok(/Get\(\(n\) => \{\s*if \(n\.type === "ref" && n\.ref != null\) refMap\[n\.id\] = n\.ref;/.test(src), "Pencil 端必須另跑一次 resolveInstances:false 建 refMap（LS-207）");
  assert.ok(/\{ resolveInstances: false \}/.test(src), "refMap 那次走訪必須是 resolveInstances:false");
  assert.ok(/const ref = n\.ref != null \? n\.ref : refMap\[n\.id\];/.test(src), "展開版走訪必須用 id 查 refMap 榫接回 ref（n.ref 優先、查不到才退回對照表）");
  assert.ok(/snap\.push\(\{[^}]*\bref\b/.test(src), "Pencil 端快照必須帶 ref 欄位");
  const a = src.indexOf('"SUMMARY total_nodes="');
  const b = src.indexOf("for (const block of compactLines(out)) Print(block)");
  assert.ok(a > 0 && b > a, "找不到 SUMMARY 到 compactLines 的視窗");
  assert.ok(/ref_hits=" \+ s\.corner_anchor\.ref_hits/.test(src.slice(a, b)), "SUMMARY 必須印 ref_hits（LS-207 哨兵）");
  assert.ok(/for \(const w of cornerWarnings\(s\.corner_anchor\)\) Print\("WARNING " \+ w\)/.test(src.slice(a, b)), "SUMMARY 之後必須 Print cornerWarnings（R2 minor-1：歸零要看得見）");
});

ok("(d) LS-202 R2 歸零警示：document_containers=0 → compactLines corner 段印「第四支停擺」⚠；boards 內 0 而 document 非零 → 只印 containers=0 提示（LS-133 形狀）；正常 → 無 ⚠。LS-207：[B,G,C1,C2] 完全沒有角托節點（ref／名稱都沒有）→ ref_hits 也是 0、多印一行 ref_hits 哨兵", () => {
  const { cornerWarnings } = require(path.join(__dirname, "overflow-scan.js"));
  const dead = compactLines(scanAll([B, G, C1, C2])).join("\n");
  assert.ok(dead.includes("  ⚠ corner_anchor document_containers=0：整份快照沒有任何角托容器——第四支停擺"), dead);
  assert.ok(dead.includes("  ⚠ corner_anchor ref_hits=0："), dead);
  const deadWarnings = cornerWarnings(scanAll([B, G, C1, C2]).scans.corner_anchor);
  assert.strictEqual(deadWarnings.length, 2, "ref_hits=0 與 document_containers=0 兩個哨兵都要印（LS-207）");
  assert.ok(deadWarnings.some((w) => w.startsWith("⚠ corner_anchor ref_hits=0：")), deadWarnings);
  assert.ok(deadWarnings.some((w) => w.includes("第四支停擺")), deadWarnings);
  // nodes 全稿本身有大量 ref 判準命中（C() 預設 ref:PHOTO_CORNER_ID），boards=["B2"] 只是 corner_anchor 的 in-scope 篩選、
  // 不限縮實際掃描的節點集合（scanScope 仍是預設 document）——ref_hits 算在全稿上，不受這個 boards 篩選影響，故仍 >0。
  const noPrints = compactLines(scanAll(nodes, { boards: ["B2"] })).join("\n");
  assert.ok(noPrints.includes("  ⚠ corner_anchor containers=0：boards 內沒有角托容器（document=7）"), noPrints);
  assert.ok(!noPrints.includes("第四支停擺"));
  assert.ok(!noPrints.includes("ref_hits=0"), "全稿 ref_hits 非 0，不該印 ref_hits 哨兵");
  const fine = compactLines(scanAll(nodes, { boards: ["B5"] })).join("\n");
  assert.ok(!fine.includes("⚠ corner_anchor"), fine);
  assert.deepStrictEqual(cornerWarnings(scanAll(nodes).scans.corner_anchor), []);
});

ok("(d) LS-202 R3 歸零警示依 scope 分流：scanScope=boards 限縮到沒有印品的板 → document_containers=0 只印「限縮快照內沒有角托容器」提示、不印「第四支停擺」；scope=document 全稿為 0 仍印停擺。LS-207：B2 板本身沒有任何角托節點，限縮後的快照 ref_hits 也是 0", () => {
  const { cornerWarnings } = require(path.join(__dirname, "overflow-scan.js"));
  const b = scanAll(nodes, { scanScope: "boards", boards: ["B2"] });
  assert.deepStrictEqual([b.scans.corner_anchor.scope, b.scans.corner_anchor.document_containers, b.scans.corner_anchor.containers, b.scans.corner_anchor.ref_hits], ["boards", 0, 0, 0]);
  const w = cornerWarnings(b.scans.corner_anchor);
  assert.strictEqual(w.length, 2, "限縮模式仍要兩行提示（ref_hits=0 ＋ 限縮快照沒有角托容器，不是靜默）");
  assert.ok(w.some((x) => x.startsWith("⚠ corner_anchor ref_hits=0：")), w);
  assert.ok(w.some((x) => x.startsWith("⚠ corner_anchor document_containers=0（scope=boards）：限縮快照內沒有角托容器") && !x.includes("第四支停擺") && !x.includes("不得交")), w);
  const text = compactLines(b).join("\n");
  assert.ok(text.includes("  ⚠ corner_anchor document_containers=0（scope=boards）") && !text.includes("第四支停擺"), text);
  const d = scanAll([B, G, C1, C2]).scans.corner_anchor;
  assert.strictEqual(d.scope, "document");
  assert.ok(cornerWarnings(d).some((x) => x.includes("第四支停擺")), "document 全稿歸零仍是停擺");
  assert.ok(cornerWarnings(Object.assign({}, d, { scope: undefined })).some((x) => x.includes("第四支停擺")), "直接呼叫 scanCornerAnchor（無 scope 標籤）視同 document");
});

ok("(d) LS-207 ref_hits：獨立計數，跟 document_containers 分開哨兵——ref 命中但全部落在 unresolved（document_containers 仍 0）時 ref_hits 非 0、不印 ref_hits=0 那行；ref 完全沒命中但名稱備援撐住 document_containers 非零時，ref_hits=0 那行仍要印（判準本身是壞的，只是被名稱備援蓋住）", () => {
  const { cornerWarnings } = require(path.join(__dirname, "overflow-scan.js"));
  // Mount TL/BR：ref 命中（isCorner 為真）但因為紙面對不上而 unresolved——document_containers=0，ref_hits 應為 2（非 0）
  const mountOnly = scanCornerAnchor(mountNodes);
  assert.deepStrictEqual([mountOnly.document_containers, mountOnly.ref_hits], [0, 2]);
  assert.deepStrictEqual(cornerWarnings(Object.assign({ scope: "document" }, mountOnly)), ["⚠ corner_anchor document_containers=0：整份快照沒有任何角托容器——第四支停擺（Pencil 快照沒讀到 ref、名稱備援 Corner TL/… 也沒命中），這份收據不得交，先查快照欄位（LS-202 R2）"], "ref_hits 非 0，不印 ref_hits=0 哨兵");
  // 純名稱備援（無 ref）：document_containers 非零，但 ref_hits 仍是 0——判準本身沒接上，只是被名稱備援蓋住
  const paper = N("PN2", "MA", 20200, 500, 100, 178);
  const nameOnly = corners("PN2", "PN2", paper).map((c) => Object.assign({}, c, { type: "frame", ref: undefined }));
  const r = scanCornerAnchor([MA, paper, ...nameOnly]);
  assert.deepStrictEqual([r.containers, r.ref_hits], [1, 0]);
  const rw = cornerWarnings(Object.assign({ scope: "document" }, r));
  assert.ok(rw.some((x) => x.startsWith("⚠ corner_anchor ref_hits=0：")), rw);
  assert.ok(!rw.some((x) => x.includes("第四支停擺")), "document_containers 非零，不印停擺那行");
});

ok("(d) LS-207 Mount TL/BR 群分類：找不到吻合紙面時 unresolved 附 classification: 'mount_pair'（不是未知失敗）；一般 Corner 群 unresolved 不受影響（無 classification 欄位）", () => {
  const r = scanCornerAnchor(mountNodes);
  assert.strictEqual(r.unresolved.length, 1);
  assert.strictEqual(r.unresolved[0].classification, "mount_pair");
  assert.ok(r.unresolved[0].reason.includes("Mount 群"), r.unresolved[0].reason);
  const three = [N("ICON2", null, 0, 0, 60, 60), C("ICON2/Corner TL", "ICON2", -5, -5, 26, "Corner TL"), C("ICON2/Corner TR", "ICON2", 39, -5, 26, "Corner TR"), C("ICON2/Corner BR", "ICON2", 39, 39, 26, "Corner BR")];
  const rr = scanCornerAnchor(three);
  assert.strictEqual(rr.unresolved.length, 1);
  assert.strictEqual(rr.unresolved[0].classification, undefined, "一般 Corner 群（非 Mount 命名）不得被誤標 mount_pair");
});

ok("(d) LS-207 R2（merge-review R1 fd783f6c F7，PLAUSIBLE）：ref_hits 只計實例層（board 上的 ref 節點），排除 cmp/ 定義子樹內部的 ref 節點——定義子樹的節點在 resolveInstances:false／true 兩次走訪 id 都是原生 id，一定 join 得上，只用「有沒有任何 ref 命中」當哨兵會被它撐起來、蓋掉板上實例真正沒接上這件事；ref_hits_defs 另外輸出供人工核對", () => {
  const { cornerWarnings } = require(path.join(__dirname, "overflow-scan.js"));
  const cmpRoot = N("CMPROOT", null, 0, 0, 100, 100, { name: "cmp/Weird Corner Def" });
  const defInnerRef = C("CMPROOT/Corner TL", "CMPROOT", -5, -5, 26, "Corner TL");
  const board2 = N("BOARD2", null, 500, 0, 200, 200, { name: "LS-207 F7 board" });
  const boardRef = C("BOARD2/Corner TL", "BOARD2", 495, -5, 26, "Corner TL");
  // 板上有一顆、定義子樹內部也有一顆 → ref_hits（實例層）只算板上那顆，ref_hits_defs 算定義子樹那顆
  const both = scanCornerAnchor([cmpRoot, defInnerRef, board2, boardRef]);
  assert.deepStrictEqual([both.ref_hits, both.ref_hits_defs], [1, 1]);
  // 只有定義子樹內部有 ref、板上完全沒有（模擬「實例層 join 失敗、只剩定義本身撐著」的真實盲區）→
  // ref_hits（實例層）必須是 0，即使天真地數「任何 ref 命中」會誤以為判準有接上（=1）
  const defOnly = scanCornerAnchor([cmpRoot, defInnerRef]);
  assert.deepStrictEqual([defOnly.ref_hits, defOnly.ref_hits_defs], [0, 1]);
  const naiveAnyRefHit = 1; // 對照組：舊版「liveNodes.filter(ref 命中).length」會算出 1，誤判判準已接上
  assert.notStrictEqual(defOnly.ref_hits, naiveAnyRefHit, "ref_hits 不得被定義子樹內部的 ref 撐起來");
  // ref_hits=0（即使 scope 標成 document）該印 ref_hits=0 的哨兵警告——證明這個案例真的會被 design-evidence-check 抓到
  const tagged = scanAll([cmpRoot, defInnerRef]).scans.corner_anchor;
  assert.ok(cornerWarnings(tagged).some((w) => w.startsWith("⚠ corner_anchor ref_hits=0：")), cornerWarnings(tagged));
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

ok("LS-171 原始碼斷言：Pencil 端雜湊走訪（const hashAcc … const abs = {} 之間的視窗）的 Get 帶 {includePathGeometry: true}；拆兩次旗標存在且互斥", () => {
  const src = require("fs").readFileSync(path.join(__dirname, "overflow-scan.js"), "utf8");
  // R1 N1：regex 的 [^]*? 會跨過雜湊走訪吃到快照走訪的 options，「把選項搬到快照走訪」（＝還原 bug）的突變體存活；改看雜湊走訪自己的視窗
  const a = src.indexOf("const hashAcc");
  const b = src.indexOf("const abs = {}");
  assert.ok(a > 0 && b > a, "找不到雜湊走訪的視窗（const hashAcc … const abs = {}）");
  const win = src.slice(a, b);
  assert.ok(win.includes("addLimbs(hashAcc, fnv1a64(line))"), "視窗內應是雜湊走訪");
  assert.ok(/includePathGeometry:\s*true/.test(win), "雜湊走訪的 Get 必須帶 includePathGeometry: true，否則 Pencil 端 geometry 是 \"...\"、tree_hash 與 CI 必不同（LS-171）");
  assert.ok(!/resolveInstances/.test(win), "雜湊走訪不得展開 instance（total_nodes 語意）");
  assert.ok(src.includes("SCAN_HASH_ONLY") && src.includes("SCAN_SKIP_HASH") && src.includes("SUMMARY-HASH"), "拆兩次 execute 的旗標／輸出必須存在");
  assert.ok(/hashOnly && skipHash[^]*?throw new Error/.test(src), "SCAN_HASH_ONLY 與 SCAN_SKIP_HASH 同時為 true 必須 throw（R1 N4）");
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

// ───── LS-185 第六支 board_clip（LS-120 R2 spacer 推出板外／LS-177 R2 Header Row 捲離畫面的形狀；板 393×852，各板 x 平移） ─────
// 板 KA（LS-120 R2 形狀，root clip:true）：Column 比板高、Card Diary 被推到 y=700 起——Caption text 底 975、Photo（frame 帶 image fill）
// 底 910 都伸出板底；Spacer（無子、無 image 的 frame）伸出但不可見、不報；Inner text 在板內不報；Edge text 只多 0.4（≤ TOL）不報；
// Icon x=−3 伸出左緣 → 報 left 3
const KA = N("KA", null, 0, 0, 393, 852, { name: "LS-120 / feed", clip: true });
const KACOL = N("KACOL", "KA", 0, 0, 393, 1000, { name: "Column" });
const KACARD = N("KACARD", "KACOL", 24, 700, 345, 300, { name: "Card Diary 1" });
const KAPHOTO = N("KAPHOTO", "KACARD", 24, 710, 345, 200, { name: "Photo", image: true });
const KACAP = N("KACAP", "KACARD", 24, 950, 200, 25, { name: "Caption", type: "text" });
const KASPACER = N("KASPACER", "KACOL", 0, 860, 393, 40, { name: "Spacer" });
const KAINNER = N("KAINNER", "KACOL", 24, 100, 200, 25, { name: "Inner", type: "text" });
const KAEDGE = N("KAEDGE", "KACOL", 24, 827.4, 200, 25, { name: "Edge", type: "text" });
const KAICON = N("KAICON", "KACOL", -3, 300, 22, 22, { name: "Icon", type: "icon" });
// 板 KB：與 KA 同幾何但 root 不 clip（cmp/* 元件定義的形狀）→ 一筆都不報
const KB = N("KB", null, 1000, 0, 393, 852, { name: "cmp/Feed" });
const KBCOL = N("KBCOL", "KB", 1000, 0, 393, 1000, { name: "Column" });
const KBCAP = N("KBCAP", "KBCOL", 1024, 950, 200, 25, { name: "Caption", type: "text" });
// 板 KC（clip）：Tab Bar（OVERLAY_RE）本身伸出板底、其 icon 也伸出 → 子樹不算；名字含 Capsule 的 text 自己伸出 → 不算；
// 非覆蓋層的兄弟 text 伸出 → 報（對照組）
const KC = N("KC", null, 2000, 0, 393, 852, { name: "KC 板", clip: true });
const KCTAB = N("KCTAB", "KC", 2016, 754, 361, 110, { name: "Tab Bar", type: "ref" });
const KCTABICON = N("KCTABICON", "KCTAB", 2040, 840, 24, 24, { name: "Home", type: "icon" });
const KCCAPS = N("KCCAPS", "KC", 2300, 840, 60, 25, { name: "Capsule Label", type: "text" });
const KCCTRL = N("KCCTRL", "KC", 2024, 840, 100, 25, { name: "Plain", type: "text" });
// 板 KD（LS-177 R2 y7KAW 形狀，clip）：Content clip:true 置於 y=−671、高 1213（底 542，在板內）——Content 內 y=−600 的 Header text
// 沒被 Content 裁掉、卻在板頂之上 → 報 top 600；Content 內 y=560 的 Account text 已被 Content 裁光 → 捲動模擬、不報；跨 Content
// 底緣的 Straddle text 可見部分 530→542 在板內 → 不報
const KD = N("KD", null, 3000, 0, 393, 852, { name: "LS-177 / 設定（已捲）", clip: true });
const KDBODY = N("KDBODY", "KD", 3000, 62, 393, 692, { name: "Body" });
const KDCONTENT = N("KDCONTENT", "KDBODY", 3000, -671, 393, 1213, { name: "Content", clip: true });
const KDHEAD = N("KDHEAD", "KDCONTENT", 3024, -600, 200, 25, { name: "Header Row Title", type: "text" });
const KDACC = N("KDACC", "KDCONTENT", 3024, 560, 200, 25, { name: "Account Row", type: "text" });
const KDSTRAD = N("KDSTRAD", "KDCONTENT", 3024, 530, 200, 25, { name: "Straddle", type: "text" });
// 板 KE（clip）：instance descendant（inst/label）伸出右緣 → 報路徑 id、right 20；disabled 的 text 伸出 → 不報；path／rectangle／ellipse
// 葉節點各伸出 → 都報（可見向量形狀）
const KE = N("KE", null, 4000, 0, 393, 852, { name: "KE 板", clip: true });
const KEINST = N("KEinst", "KE", 4000, 100, 393, 60, { name: "Row", type: "ref" });
const KELABEL = N("KEinst/label", "KEinst", 4300, 110, 113, 25, { name: "Label", type: "text" });
const KEOFF = N("KEOFF", "KE", 4024, 900, 100, 25, { name: "Hidden", type: "text", enabled: false });
const KEPATH = N("KEPATH", "KE", 4380, 200, 26, 26, { name: "Corner Shape", type: "path" });
const KERECT = N("KERECT", "KE", 4000, -84, 345, 515, { name: "Hero Photo", type: "rectangle" });
const KEELL = N("KEELL", "KE", 4200, 845, 27, 27, { name: "Knob", type: "ellipse" });
// 兩邊同時伸出（top 10、right 87）→ side 取溢出最大的 right，不是走訪順序第一個的 top
const KEBIG = N("KEBIG", "KE", 4380, -10, 100, 50, { name: "Two Sides", type: "rectangle" });
// 板 KF（clip，板名含 Banner）：root 自己的名字不參與 OVERLAY_RE 比對——內容伸出照報
const KF = N("KF", null, 5000, 0, 393, 852, { name: "LS-99 / Banner 示意板", clip: true });
const KFTXT = N("KFTXT", "KF", 5024, 840, 200, 25, { name: "Body Text", type: "text" });
// 板 KG（merge-review R1 minor-2）：帶 image fill 且有子節點的照片框（真實稿 Photo Wrap／Thumb＋Video Badge 的形狀）——框底伸出板 160、
// 子標籤與徽章都在板內 → 只報框本身一筆（子節點在板內不另報）；同板另一個完全在板內的照片框帶子節點 → 不報
const KG = N("KG", null, 6000, 0, 393, 852, { name: "KG 板", clip: true });
const KGWRAP = N("KGWRAP", "KG", 6024, 600, 345, 412, { name: "Photo Wrap", image: true });
const KGLBL = N("KGLBL", "KGWRAP", 6032, 610, 100, 25, { name: "Caption", type: "text" });
const KGBADGE = N("KGBADGE", "KGWRAP", 6300, 610, 40, 20, { name: "Video Badge", type: "icon" });
const KGWRAP2 = N("KGWRAP2", "KG", 6024, 100, 345, 200, { name: "Thumb", image: true });
const KGLBL2 = N("KGLBL2", "KGWRAP2", 6032, 110, 100, 25, { name: "Caption", type: "text" });

const clipNodes = [
  KA, KACOL, KACARD, KAPHOTO, KACAP, KASPACER, KAINNER, KAEDGE, KAICON,
  KB, KBCOL, KBCAP,
  KC, KCTAB, KCTABICON, KCCAPS, KCCTRL,
  KD, KDBODY, KDCONTENT, KDHEAD, KDACC, KDSTRAD,
  KE, KEINST, KELABEL, KEOFF, KEPATH, KERECT, KEELL, KEBIG,
  KF, KFTXT,
  KG, KGWRAP, KGLBL, KGBADGE, KGWRAP2, KGLBL2,
];
const clipAll = scanAll(clipNodes).scans.board_clip;
const clipHits = (arr) => arr.map((f) => f.node + ":" + f.side + ":" + f.overflow_px).sort();

ok("(f) board_clip：clip 板內 Caption text／image fill 的 Photo／左伸的 icon 都報（bottom 123／bottom 58／left 3）；不可見 Spacer、板內 text、只多 0.4 的 Edge 不報；四支＋第五支對這些確實無感", () => {
  assert.deepStrictEqual(clipHits(clipAll.flagged.filter((f) => f.board === "KA")), ["KACAP:bottom:123", "KAICON:left:3", "KAPHOTO:bottom:58"]);
  const cap = clipAll.flagged.find((f) => f.node === "KACAP");
  assert.deepStrictEqual([cap.board_name, cap.name, cap.parent, cap.type], ["LS-120 / feed", "Caption", "KACARD", "text"]);
  const five = scanAll([KA, KACOL, KACARD, KAPHOTO, KACAP, KASPACER, KAINNER, KAEDGE, KAICON], { crossAll: true }).scans;
  const mentions = (arr) => arr.filter((f) => /KACAP|KAPHOTO|KAICON/.test((f.node || "") + (f.node_a || "") + (f.node_b || "")));
  assert.deepStrictEqual(mentions(five.sibling_intersection.flagged).length + mentions(five.cross_parent_collision.flagged).length + mentions(five.text_occlusion.flagged).length, 0, "其餘各支指不到被裁的葉節點（row_overflow 只看右緣、看不到底／左）");
  assert.deepStrictEqual(mentions(five.row_overflow.flagged).map((f) => f.node), [], "row_overflow 對右緣沒溢出的三筆無感");
});

ok("(f) 無 clip 不報：同幾何的 KB（cmp/* 元件定義根不 clip）0 筆；把 KA 的 clip 拿掉也 0 筆", () => {
  assert.deepStrictEqual(clipHits(clipAll.flagged.filter((f) => f.board === "KB")), []);
  const noClip = Object.assign({}, KA, { clip: false });
  assert.deepStrictEqual(scanAll([noClip, KACOL, KACARD, KAPHOTO, KACAP, KASPACER, KAINNER, KAEDGE, KAICON]).scans.board_clip.flagged, []);
});

ok("(f) 覆蓋層不算：Tab Bar 的 icon 伸出板底、名字含 Capsule 的 text 自己伸出都不報；同板非覆蓋層的 Plain text 伸出照報；overlayRe 可覆寫（不含 Tab Bar 時 icon 就報）", () => {
  assert.deepStrictEqual(clipHits(clipAll.flagged.filter((f) => f.board === "KC")), ["KCCTRL:bottom:13"]);
  const custom = scanBoardClip([KC, KCTAB, KCTABICON, KCCAPS, KCCTRL], undefined, { overlayRe: "Capsule" }).flagged;
  assert.deepStrictEqual(clipHits(custom), ["KCCTRL:bottom:13", "KCTABICON:bottom:12"]);
});

ok("(f) 中間 clip 祖先（捲動模擬）：Content clip 內在板頂之上的 Header text 報 top 600；被 Content 裁光的 Account text 不報；跨 Content 底緣、可見部分在板內的 Straddle 不報；同幾何把 Content 的 clip 拿掉 → Account／Straddle 都變成被板裁", () => {
  assert.deepStrictEqual(clipHits(clipAll.flagged.filter((f) => f.board === "KD")), ["KDHEAD:top:600"]);
  const open = Object.assign({}, KDCONTENT, { clip: false });
  assert.deepStrictEqual(clipHits(scanAll([KD, KDBODY, open, KDHEAD, KDACC, KDSTRAD]).scans.board_clip.flagged), ["KDHEAD:top:600"], "Content 不 clip：Account 560→585、Straddle 530→555 都仍在板 852 內，不因 clip 移除而多報");
  const tall = Object.assign({}, KDCONTENT, { clip: false, y: 200 });
  const acc = Object.assign({}, KDACC, { y: 840 });
  assert.deepStrictEqual(clipHits(scanAll([KD, KDBODY, tall, acc]).scans.board_clip.flagged), ["KDACC:bottom:13"], "沒有中間 clip 時伸出板底的 text 直接報");
  const clipped = Object.assign({}, KDCONTENT, { y: 200, h: 600 });
  assert.deepStrictEqual(scanAll([KD, KDBODY, clipped, acc]).scans.board_clip.flagged, [], "同一 text 被 200→800 的 Content clip 裁光 → 捲動模擬、不報");
});

ok("(f) instance 路徑葉節點報 inst/label right 20；disabled 不報；path／rectangle／ellipse 可見形狀各報一筆（Hero Photo 上緣 −84 → top 84）；兩邊同時伸出取最大的 right 87；板名含 Banner 的 root 不豁免（KF 報一筆）", () => {
  assert.deepStrictEqual(clipHits(clipAll.flagged.filter((f) => f.board === "KE")), ["KEBIG:right:87", "KEELL:bottom:20", "KEPATH:right:13", "KERECT:top:84", "KEinst/label:right:20"]);
  assert.deepStrictEqual(clipHits(clipAll.flagged.filter((f) => f.board === "KF")), ["KFTXT:bottom:13"]);
  assert.ok(!clipAll.flagged.some((f) => f.node === "KEOFF"));
});

ok("(f) minor-2：帶 image fill 且有子節點的照片框以自身 AABB 參與——框底伸出板 160 而子標籤／徽章在板內 → 只報框一筆（子節點不另報）；完全在板內的照片框帶子節點不報；同幾何把 image 拿掉（純 frame 容器）就不報", () => {
  assert.deepStrictEqual(clipHits(clipAll.flagged.filter((f) => f.board === "KG")), ["KGWRAP:bottom:160"]);
  const wrap = clipAll.flagged.find((f) => f.node === "KGWRAP");
  assert.deepStrictEqual([wrap.name, wrap.type, wrap.parent], ["Photo Wrap", "frame", "KG"]);
  const plain = Object.assign({}, KGWRAP, { image: false });
  assert.deepStrictEqual(scanAll([KG, plain, KGLBL, KGBADGE, KGWRAP2, KGLBL2]).scans.board_clip.flagged, [], "無 image fill 的純容器 frame 仍不算可見節點");
});

ok("(f) 範圍（同 corner_anchor／text_occlusion）：boards=['KA'] → flagged 只算 KA（3）、document_flagged 全稿 10；空 boards＝全稿；compactLines 段含 in-scope 分類＋DOCUMENT 按板計數", () => {
  const r = scanAll(clipNodes, { boards: ["KA"] }).scans.board_clip;
  assert.deepStrictEqual([r.boards, r.flagged.length, r.document_flagged.length, clipAll.flagged.length], [["KA"], 3, 12, 12]);
  assert.deepStrictEqual(clipHits(r.flagged), clipHits(clipAll.flagged.filter((f) => f.board === "KA")));
  const text = compactLines(scanAll(clipNodes, { boards: ["KA"] })).join("\n");
  assert.ok(text.includes('SCAN board_clip boards=["KA"] flagged=3 classes=3 document=12'), text);
  assert.ok(text.includes("  1× Caption bottom @ LS-120 / feed(KA) e.g. KACAP (+123)"));
  assert.ok(text.includes("  DOCUMENT 1× board LS-177 / 設定（已捲）(KD) e.g. KDHEAD top (+600)"), text);
});

ok("(f) hasImageFill：物件／陣列 fill 含 type image 才算，enabled:false 的 image 不算，token 字串不算；原始碼斷言 Pencil 端快照帶 image 欄位", () => {
  const { hasImageFill } = require(path.join(__dirname, "overflow-scan.js"));
  assert.strictEqual(hasImageFill({ type: "image", url: "a.png" }), true);
  assert.strictEqual(hasImageFill([{ type: "solid", color: "$bg" }, { type: "image", url: "a.png" }]), true);
  assert.strictEqual(hasImageFill({ type: "image", enabled: false, url: "a.png" }), false);
  assert.strictEqual(hasImageFill("$accent"), false);
  assert.strictEqual(hasImageFill(undefined), false);
  const src = require("fs").readFileSync(path.join(__dirname, "overflow-scan.js"), "utf8");
  assert.ok(/image:\s*hasImageFill\(n\.fill\)/.test(src), "Pencil 端快照必須帶 image: hasImageFill(n.fill)，否則照片葉節點對第六支不可見");
});

// ───── LS-185 scan_scope ─────
ok("scan_scope：預設 document、每支帶 scope=document；boards 模式把快照限縮到 boards 子樹（scanned_nodes＝子樹大小、document_* 即限縮值）、每支 scope=boards、boards 可用板名；非法值／boards 模式無 boards 一律 throw", () => {
  const doc = scanAll(nodes);
  assert.strictEqual(doc.scan_scope, "document");
  for (const k of Object.keys(doc.scans)) assert.strictEqual(doc.scans[k].scope, "document", k);
  const b = scanAll(nodes, { scanScope: "boards", boards: ["B5"] });
  assert.deepStrictEqual([b.scan_scope, b.scanned_nodes], ["boards", 6]);
  for (const k of Object.keys(b.scans)) assert.strictEqual(b.scans[k].scope, "boards", k);
  assert.deepStrictEqual([b.scans.corner_anchor.containers, b.scans.corner_anchor.points, b.scans.corner_anchor.mismatch], [1, 8, 2]);
  assert.deepStrictEqual([b.scans.corner_anchor.document_containers, b.scans.corner_anchor.document_points, b.scans.corner_anchor.document_mismatch], [1, 8, 2], "限縮後 document_* 就是 boards 值——收據 scan_scope=boards 讓 gate／VR 分得清");
  assert.deepStrictEqual(pairs(b.scans.sibling_intersection.flagged), [], "B5 內沒有兄弟交集；其他板不進快照");
  const byName = scanAll(nodes, { scanScope: "boards", boards: ["LS-17 / 01 舊板"] });
  assert.deepStrictEqual([byName.scanned_nodes, byName.scans.corner_anchor.document_mismatch], [6, 2]);
  assert.throws(() => scanAll(nodes, { scanScope: "board" }), /scanScope 只接受 document\|boards/);
  assert.throws(() => scanAll(nodes, { scanScope: "boards" }), /需要非空 boards/);
  assert.throws(() => scanAll(nodes, { scanScope: "boards", boards: ["nope"] }), /限縮後快照為空/, "解析不到任何 root 的 boards 也 throw（不得默默掃空集合印全零收據）");
});

// ───── LS-185 cross_parent_collision 候選過濾＝全配對（逐位元）；舊實作照抄自 main b9470bc 的 scanCrossParentCollision ─────
const M = require(path.join(__dirname, "overflow-scan.js"));
function legacyCrossParent(nodes, idx, opts) {
  const { byId, liveNodes, chain } = idx || M.buildIndex(nodes);
  const all = !!(opts && opts.crossAll);
  const boards = new Map();
  for (const n of liveNodes) {
    const c = chain.get(n.id);
    const board = c[c.length - 1];
    if (!boards.has(board)) boards.set(board, []);
    boards.get(board).push(n);
  }
  function coveredByParent(a, b, chainB) {
    const pa = a.parent == null ? null : byId.get(a.parent);
    if (!pa || chainB.includes(pa.id)) return false;
    return M.contains(pa, a) && M.overlapArea(pa, b) > M.AREA_MIN;
  }
  const flagged = [];
  for (const [board, arr] of boards) {
    const boardName = byId.get(board).name;
    for (let i = 0; i < arr.length; i++) {
      const a = arr[i];
      const ca = chain.get(a.id);
      for (let j = i + 1; j < arr.length; j++) {
        const b = arr[j];
        if (a.parent === b.parent) continue;
        if (M.overlapArea(a, b) <= M.AREA_MIN) continue;
        if (!all && !M.BLEED_RE.test(a.name || "") && !M.BLEED_RE.test(b.name || "")) continue;
        const cb = chain.get(b.id);
        if (ca.includes(b.id) || cb.includes(a.id)) continue;
        if (coveredByParent(a, b, cb) || coveredByParent(b, a, ca)) continue;
        flagged.push(M.pairEntry(a, b, { parent_a: a.parent, parent_b: b.parent, board, board_name: boardName }));
      }
    }
  }
  return { flagged };
}
// 合成大板：seeded LCG，多個 parent、bleed 與非 bleed 名稱混雜、座標密集到處交集；部分節點刻意溢出自己的父（去重路徑兩側都走到）
function synthBoard(seed, count, bleedEvery) {
  let s = seed >>> 0;
  const rnd = () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296);
  const out = [N("SB" + seed, null, 0, 0, 2000, 2000, { name: "Synth " + seed, clip: true })];
  const parents = [];
  for (let p = 0; p < 12; p++) {
    const px = Math.floor(rnd() * 1500), py = Math.floor(rnd() * 1500);
    const par = N("SB" + seed + "/P" + p, "SB" + seed, px, py, 400, 400, { name: p % 3 === 0 ? "Photo Wrap" : "Column" });
    out.push(par);
    parents.push(par);
  }
  const names = ["Spacer", "Caption", "Corner TR", "Badge", "Feed", "Home Indicator Area", "Drop Target", "Label"];
  for (let i = 0; i < count; i++) {
    const par = parents[Math.floor(rnd() * parents.length)];
    const w = 20 + Math.floor(rnd() * 120), h = 20 + Math.floor(rnd() * 120);
    const x = par.x - 30 + Math.floor(rnd() * 440), y = par.y - 30 + Math.floor(rnd() * 440);
    const name = i % bleedEvery === 0 ? names[2 + (i % 3)] : names[[0, 1, 4, 5, 7][i % 5]];
    out.push(N("SB" + seed + "/n" + i, par.id, x, y, w, h, { name, type: i % 7 === 0 ? "text" : "frame" }));
  }
  return out;
}
ok("(c) 候選過濾等價：主 fixture（bleed-only／crossAll）、遮蔽 fixture、裁切 fixture、三顆 seed 的合成板（各 400 節點、bleed 每 9／5／2 個一個）新舊輸出 JSON 逐位元相同且非空", () => {
  const same = (arr, opts) => {
    const a = JSON.stringify(legacyCrossParent(arr, undefined, opts));
    const b = JSON.stringify(M.scanCrossParentCollision(arr, undefined, opts));
    assert.strictEqual(b, a);
    return JSON.parse(b).flagged.length;
  };
  assert.strictEqual(same(nodes), 4);
  assert.strictEqual(same(nodes, { crossAll: true }), 5);
  same(occNodes); same(occNodes, { crossAll: true });
  same(clipNodes); same(clipNodes, { crossAll: true });
  let total = 0;
  for (const [seed, every] of [[1, 9], [2, 5], [3, 2]]) {
    const arr = synthBoard(seed, 400, every);
    const k = same(arr);
    assert.ok(k > 0, "合成板 seed " + seed + " 應有 bleed 類命中（" + k + "）");
    assert.ok(same(arr, { crossAll: true }) > k, "crossAll 應報得更多");
    total += k;
  }
  assert.ok(total > 50, "三顆 seed 合計命中應夠多（" + total + "）才算有鑑別力");
});

ok("(c) 候選過濾效能：3000 節點單板（bleed 每 20 個一個）新實作比全配對快（只印比值，不斷言倍率——CI 機器抖動），結果仍相同", () => {
  const arr = synthBoard(7, 3000, 20);
  const t0 = Date.now(); const a = JSON.stringify(legacyCrossParent(arr)); const t1 = Date.now();
  const b = JSON.stringify(M.scanCrossParentCollision(arr)); const t2 = Date.now();
  assert.strictEqual(b, a);
  console.log("    cross_parent 3000 節點：全配對 " + (t1 - t0) + "ms → 候選過濾 " + (t2 - t1) + "ms（flagged " + JSON.parse(b).flagged.length + "）");
});

console.log("overflow-scan.test.js：全數通過（" + n + " 組）");
