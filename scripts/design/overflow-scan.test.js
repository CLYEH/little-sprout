// scripts/design/overflow-scan.js 的自測（LS-122）。CI rules job 自測 step 跑 `node scripts/design/overflow-scan.test.js`。
// 純函數對合成節點樹（絕對座標）驗四支掃描的語意；每條斷言都對應一個 LS-119 R5 抓到的盲區或既有語意，斷言的是
// **精確的命中集合**（不是「至少有一筆」）——演算法退化（少比一支、祖先後代沒排除、disabled 沒傳遞、Corner BR 漏掉、
// 跨 parent 去重規則失效）任一種都會讓集合改變而紅。
"use strict";
const assert = require("assert");
const path = require("path");
const { scanAll, scanCornerAnchor, buildIndex } = require(path.join(__dirname, "overflow-scan.js"));

function N(id, parent, x, y, w, h, extra) {
  return Object.assign({ id, name: id, parent, type: "frame", enabled: true, x, y, w, h }, extra || {});
}
function corners(prefix, cell, opts) {
  const o = opts || {};
  const dy = o.blbrDy || 0;
  const on = o.enabled !== false;
  return [
    N(prefix + "/Corner TL", cell.id, cell.x - 5, cell.y - 5, 26, 26, { name: "Corner TL", enabled: on }),
    N(prefix + "/Corner TR", cell.id, cell.x + cell.w - 21, cell.y - 5, 26, 26, { name: "Corner TR", enabled: on }),
    N(prefix + "/Corner BL", cell.id, cell.x - 5, cell.y + cell.h - 21 + dy, 26, 26, { name: "Corner BL", enabled: on }),
    N(prefix + "/Corner BR", cell.id, cell.x + cell.w - 21, cell.y + cell.h - 21 + dy, 26, 26, { name: "Corner BR", enabled: on }),
  ];
}
function pairs(flagged) {
  return flagged.map((f) => [f.node_a, f.node_b].sort().join("|")).sort();
}
function ids(flagged, key) {
  return flagged.map((f) => f[key]).sort();
}

// 板 B：格狀牆——兩格 gap 8、角托 corner-out 5（5+5=10 > 8 必然重疊 2pt，LS-119 R5 BL-2）
const B = N("B", null, 0, 0, 400, 400);
const G = N("G", "B", 0, 0, 400, 200);
const C1 = N("C1", "G", 0, 0, 100, 178);
const C2 = N("C2", "G", 108, 0, 100, 178);
// 板 B2：與 B 在畫布 root 層相鄰重疊（既有語意：root 層兩板交集要報）；內含兩個交集的兄弟，各有一個子節點
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
const B5 = N("B5", null, 3000, 0, 400, 400);
const C3 = N("C3", "B5", 3000, 0, 100, 178);
// 板 B6：徽章溢出 Photo Wrap 撞到兄弟 caption（祖先兄弟 wrap／cap 不交集、後代 badge 與 cap 交集 → 跨 parent 要報）
const B6 = N("B6", null, 4000, 0, 400, 400);
const W6 = N("W6", "B6", 4000, 0, 300, 200);
const CAP6 = N("CAP6", "B6", 4000, 200, 300, 30, { type: "text" });
const BADGE6 = N("BADGE6", "W6", 4200, 190, 100, 26);

const nodes = [
  B, G, C1, C2, ...corners("C1", C1), ...corners("C2", C2),
  B2, S1, S2, T1, T2,
  B3, D, DC, E, ...corners("DC", DC),
  B4, INST, WRAP, BADGE,
  B5, C3, ...corners("C3", C3, { blbrDy: -8 }),
  B6, W6, CAP6, BADGE6,
];

const out = scanAll(nodes);
const s = out.scans;
let n = 0;
function ok(name, fn) {
  fn();
  n++;
  console.log("✓ " + name);
}

ok("輸出形狀：四支鍵齊全、corner_anchor 三個整數、scanned_nodes 為輸入節點數", () => {
  assert.deepStrictEqual(Object.keys(s).sort(), ["corner_anchor", "cross_parent_collision", "row_overflow", "sibling_intersection"]);
  for (const k of ["containers", "points", "mismatch"]) assert.ok(Number.isInteger(s.corner_anchor[k]), k);
  assert.strictEqual(out.scanned_nodes, nodes.length);
});

ok("disabled 子樹傳遞：enabled:false 節點與其後代都不參與（buildIndex 排除 D／DC／DC 的角托）", () => {
  const live = buildIndex(nodes).liveNodes.map((x) => x.id);
  assert.ok(!live.includes("D") && !live.includes("DC") && !live.includes("DC/Corner BR"));
  assert.ok(live.includes("E"));
});

ok("(a) 兄弟交集：root 層兩板相鄰要報、S1×S2 要報；gap 8 的兩格不報；disabled 的 D×E 不報", () => {
  assert.deepStrictEqual(pairs(s.sibling_intersection.flagged), ["B2|B", "S1|S2"].map((p) => p.split("|").sort().join("|")).sort());
  const root = s.sibling_intersection.flagged.find((f) => f.node_a === "B");
  assert.strictEqual(root.parent, null);
  assert.strictEqual(root.parent_name, "root");
});

ok("(b) 橫列溢出：三個印品的 Corner TR 與 Corner BR 全部列出（不在第一筆停）、instance 路徑徽章右緣溢出 8；只看右緣（B6 徽章是往下溢出，不在此支）；DC 角托不報", () => {
  assert.deepStrictEqual(ids(s.row_overflow.flagged, "node"), ["C1/Corner BR", "C1/Corner TR", "C2/Corner BR", "C2/Corner TR", "C3/Corner BR", "C3/Corner TR", "inst/wrap/badge"].sort());
  const badge = s.row_overflow.flagged.find((f) => f.node === "inst/wrap/badge");
  assert.strictEqual(badge.overflow, 8);
  assert.strictEqual(badge.parent, "inst/wrap");
});

ok("(c) 跨 parent 碰撞：相鄰格角托 TR×TL、BR×BL 兩筆（各屬不同 Print Cell）＋ B6 徽章×caption；祖先兄弟已交集者（T1×T2、T1×S2）不重報；祖先／後代不報；不跨板", () => {
  assert.deepStrictEqual(pairs(s.cross_parent_collision.flagged), ["BADGE6|CAP6", "C1/Corner BR|C2/Corner BL", "C1/Corner TR|C2/Corner TL"].sort());
  for (const f of s.cross_parent_collision.flagged) {
    assert.notStrictEqual(f.parent_a, f.parent_b);
    const idx = buildIndex(nodes);
    assert.ok(!idx.chain.get(f.node_a).includes(f.node_b) && !idx.chain.get(f.node_b).includes(f.node_a), "祖先／後代不得成對");
    assert.strictEqual(idx.chain.get(f.node_a).slice(-1)[0], f.board);
    assert.strictEqual(idx.chain.get(f.node_b).slice(-1)[0], f.board);
  }
  const c = s.cross_parent_collision.flagged.find((f) => f.node_a === "C1/Corner TR");
  assert.deepStrictEqual(c.overlap, [2, 26]);
});

ok("(d) 角托錨點：3 個容器（C1／C2／C3，DC 因 disabled 不算）、每容器 4 個斷言＝12 點、C3 的 BL.y／BR.y 各差 −8 → mismatch 2", () => {
  const ca = s.corner_anchor;
  assert.strictEqual(ca.containers, 3);
  assert.strictEqual(ca.points, 12);
  assert.strictEqual(ca.mismatch, 2);
  assert.strictEqual(ca.flagged.length, 2);
  assert.deepStrictEqual(ids(ca.flagged, "corner"), ["C3/Corner BL", "C3/Corner BR"]);
  for (const f of ca.flagged) {
    assert.strictEqual(f.container, "C3");
    assert.strictEqual(f.axis, "y");
    assert.strictEqual(f.expected, 157);
    assert.strictEqual(f.actual, 149);
  }
});

ok("(d) 角托錨點：修正 C3 後 mismatch 歸 0；允差 0.5 內不算錯位、0.5 外算", () => {
  const fixed = [B5, C3, ...corners("C3", C3, { blbrDy: 0.4 })];
  assert.strictEqual(scanCornerAnchor(fixed).mismatch, 0);
  const off = [B5, C3, ...corners("C3", C3, { blbrDy: 0.6 })];
  assert.strictEqual(scanCornerAnchor(off).mismatch, 2);
  assert.strictEqual(scanCornerAnchor(off).points, 4);
});

ok("(d) 角托錨點：只有兩對角的容器（App icon ≤60pt）點數＝BR 2 點；沒有角托的樹 containers=0", () => {
  const icon = N("ICON", null, 0, 0, 60, 60);
  const two = [icon, N("ICON/Corner TL", "ICON", -5, -5, 26, 26, { name: "Corner TL" }), N("ICON/Corner BR", "ICON", 39, 39, 26, 26, { name: "Corner BR" })];
  const r = scanCornerAnchor(two);
  assert.deepStrictEqual([r.containers, r.points, r.mismatch], [1, 2, 0]);
  assert.deepStrictEqual(scanCornerAnchor([B, G]).containers, 0);
});

console.log("overflow-scan.test.js：全數通過（" + n + " 組）");
