// LS-122：設計收工溢出掃描——四支掃描的正典腳本（取代 ui-designer／visual-reviewer 每輪臨場手寫的 JS）。
//
// 為什麼要正典化：LS-119 R5 的兩個 BLOCKER（角托縮進紙面 148 點錯位、相鄰格角托跨 parent 重疊 80 筆）與
// MJ-6（instance descendants 才 enable 的影片徽章被裁）都是既有兩支掃描結構上抓不到的類別；橫列溢出收據 115 vs
// reviewer 實測 233 則是臨場腳本系統性漏掉每個印品家族的 Corner BR。同型缺陷在 R1／R2／R3 反覆出現——「機械式 gate
// 攔截違規」在這一類是空的（LS-122 票文）。
//
// 用法（兩種執行環境，同一份檔案）：
//   1. Pencil `execute`：把本檔全文當作 snippet 送進 mcp__pencil__execute。檔尾偵測到 `Get`／`Print` 存在時，會用
//      `Get(visit, {resolveInstances:true})` 收集全樹快照（含 instance descendants，id 為 `instanceId/childId` 路徑）、
//      算絕對座標、跑四支掃描，`Print` 一行 SUMMARY ＋ 一行收據用 JSON（`total_nodes`／`scanned_nodes`／`scans`）。
//      `total_nodes` 用**未展開 instance** 的走訪計數（與 design-landing-check.sh --print-nodes／pen-land.sh 同一語意），
//      `scanned_nodes` 才是展開後實際掃過的節點數。設計端把 JSON 抄進 `design/evidence/<票號>-r<n>-overflow.json`，補
//      `ticket`／`round`／`head_sha` 與每筆 `classification`（可依分類合併為代表＋「同類 N 例」，見 ui-designer.md）。
//   2. node：`require` 本檔取得純函數（`scanAll` 與四支 `scan*`），`scripts/design/overflow-scan.test.js` 用合成節點樹
//      驗演算法；CI rules job 的自測 step 跑它。掃描核心不碰 Pencil API，Pen 不在時也能驗。
//
// 節點快照格式（純函數的唯一輸入）：陣列，父先於子（top-down），每筆：
//   {id, name, parent (父 id；頂層為 null), type, enabled (布林), x, y, w, h}  —— x/y/w/h 為**絕對座標** AABB。
// 語意（皆先做 disabled 子樹傳遞：`enabled:false` 的節點與其全部後代不參與任何一支）：
//   (a) sibling_intersection：同一父節點下兩兩 AABB 交集面積 > AREA_MIN（含畫布 root 層兩板相鄰，既有語意）。
//   (b) row_overflow：子節點右緣超出父節點右緣 > TOL（既有語意；逐子節點檢查、不在容器第一筆命中就停，Corner TR／BR
//       全部涵蓋）。
//   (c) cross_parent_collision：同一板（root 直屬 frame）內、**父節點不同**、非祖先／後代關係的任兩節點 AABB 交集
//       面積 > AREA_MIN。去重規則：若兩節點在最近共同祖先下的兩個「祖先兄弟」本身就交集（已由 (a) 報過，交集是繼承
//       來的），不再逐後代重報；只報「祖先兄弟不交集、後代卻交集」＝有節點溢出自己的容器撞到別家（角托 corner-out
//       撞相鄰格、徽章溢出 Photo Wrap 撞鄰居都是這類）。白名單以 classification 記錄。
//   (d) corner_anchor：每個直接子節點含 `Corner TL/TR/BL/BR` 的容器（印品），取容器實測 W／H，斷言
//       Corner TR／BR 的 x ＝ W − 21、Corner BL／BR 的 y ＝ H − 21（21 ＝ 角托 26 − corner-out 5，
//       .claude/skills/little-sprout-brand/references/motifs.md「角托一律壓過紙緣 `corner-out` 5pt」、tokens.md
//       `corner-out` 5），允差 TOL；LS-119 R3 MJ-7 核對腳本的同一語意（`y=H−21`／`x=W−21`，H/W 取各 instance 實測值）。
//       `points` ＝ 斷言數（TR 1、BL 1、BR 2；TL 在本規則無遠緣斷言），`mismatch` ＝ 失敗數。角托錯位不接受白名單，
//       收據 gate 要求 mismatch == 0（design-evidence-check.sh）。
// 輸出每筆都帶 name／parent 等欄位方便分類；design-evidence-check.sh 只驗 node／node_a／node_b／classification 與
// corner_anchor 的三個整數，多出的欄位不影響 gate。

const AREA_MIN = 4;
const TOL = 0.5;
const CORNER_INSET = 21;
const CORNER_RE = /\bCorner (TL|TR|BL|BR)\b/;

function r2(v) {
  return Math.round(v * 100) / 100;
}

function overlapArea(a, b) {
  const w = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x);
  const h = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y);
  return w > 0 && h > 0 ? w * h : 0;
}

function buildIndex(nodes) {
  const byId = new Map();
  for (const n of nodes) byId.set(n.id, n);
  const live = new Map();
  const chain = new Map();
  for (const n of nodes) {
    const c = [n.id];
    let on = n.enabled !== false;
    let p = n.parent == null ? null : byId.get(n.parent);
    while (p) {
      c.push(p.id);
      if (p.enabled === false) on = false;
      p = p.parent == null ? null : byId.get(p.parent);
    }
    live.set(n.id, on);
    chain.set(n.id, c);
  }
  const liveNodes = nodes.filter((n) => live.get(n.id));
  const kids = new Map();
  for (const n of liveNodes) {
    const key = n.parent == null ? null : n.parent;
    if (!kids.has(key)) kids.set(key, []);
    kids.get(key).push(n);
  }
  return { byId, liveNodes, kids, chain };
}

function pairEntry(a, b, extra) {
  return Object.assign(
    { node_a: a.id, node_b: b.id, name_a: a.name, name_b: b.name },
    extra,
    { overlap: [r2(Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x)), r2(Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y))] }
  );
}

function scanSiblingIntersection(nodes, idx) {
  const { byId, kids } = idx || buildIndex(nodes);
  const flagged = [];
  for (const [pid, arr] of kids) {
    const parent = pid == null ? null : byId.get(pid);
    for (let i = 0; i < arr.length; i++) {
      for (let j = i + 1; j < arr.length; j++) {
        if (overlapArea(arr[i], arr[j]) > AREA_MIN) {
          flagged.push(pairEntry(arr[i], arr[j], { parent: pid == null ? null : pid, parent_name: parent ? parent.name : "root" }));
        }
      }
    }
  }
  return { flagged };
}

function scanRowOverflow(nodes, idx) {
  const { byId, liveNodes } = idx || buildIndex(nodes);
  const flagged = [];
  for (const n of liveNodes) {
    if (n.parent == null) continue;
    const p = byId.get(n.parent);
    if (!p) continue;
    const over = n.x + n.w - (p.x + p.w);
    if (over > TOL) {
      flagged.push({ node: n.id, name: n.name, parent: p.id, parent_name: p.name, overflow: r2(over) });
    }
  }
  return { flagged };
}

function scanCrossParentCollision(nodes, idx) {
  const { byId, liveNodes, chain } = idx || buildIndex(nodes);
  const boards = new Map();
  for (const n of liveNodes) {
    const c = chain.get(n.id);
    const board = c[c.length - 1];
    if (!boards.has(board)) boards.set(board, []);
    boards.get(board).push(n);
  }
  const flagged = [];
  for (const [board, arr] of boards) {
    for (let i = 0; i < arr.length; i++) {
      const a = arr[i];
      const ca = chain.get(a.id);
      for (let j = i + 1; j < arr.length; j++) {
        const b = arr[j];
        if (a.parent === b.parent) continue;
        const cb = chain.get(b.id);
        if (ca.includes(b.id) || cb.includes(a.id)) continue;
        if (overlapArea(a, b) <= AREA_MIN) continue;
        let ia = ca.length - 1;
        let ib = cb.length - 1;
        while (ia > 0 && ib > 0 && ca[ia - 1] === cb[ib - 1]) {
          ia--;
          ib--;
        }
        const sa = byId.get(ca[ia - 1]);
        const sb = byId.get(cb[ib - 1]);
        if (overlapArea(sa, sb) > AREA_MIN) continue;
        flagged.push(pairEntry(a, b, { parent_a: a.parent, parent_b: b.parent, board }));
      }
    }
  }
  return { flagged };
}

function scanCornerAnchor(nodes, idx) {
  const { byId, liveNodes } = idx || buildIndex(nodes);
  const groups = new Map();
  for (const n of liveNodes) {
    const m = CORNER_RE.exec(n.name || "");
    if (!m || n.parent == null || !byId.get(n.parent)) continue;
    if (!groups.has(n.parent)) groups.set(n.parent, []);
    groups.get(n.parent).push({ node: n, variant: m[1] });
  }
  let points = 0;
  const flagged = [];
  for (const [pid, corners] of groups) {
    const p = byId.get(pid);
    for (const { node, variant } of corners) {
      const checks = [];
      if (variant === "TR" || variant === "BR") checks.push(["x", p.w - CORNER_INSET, node.x - p.x]);
      if (variant === "BL" || variant === "BR") checks.push(["y", p.h - CORNER_INSET, node.y - p.y]);
      for (const [axis, expected, actual] of checks) {
        points++;
        if (Math.abs(actual - expected) > TOL) {
          flagged.push({
            container: p.id,
            container_name: p.name,
            corner: node.id,
            corner_name: node.name,
            axis,
            expected: r2(expected),
            actual: r2(actual),
          });
        }
      }
    }
  }
  return { containers: groups.size, points, mismatch: flagged.length, flagged };
}

function scanAll(nodes) {
  const idx = buildIndex(nodes);
  return {
    scanned_nodes: nodes.length,
    scans: {
      sibling_intersection: scanSiblingIntersection(nodes, idx),
      row_overflow: scanRowOverflow(nodes, idx),
      cross_parent_collision: scanCrossParentCollision(nodes, idx),
      corner_anchor: scanCornerAnchor(nodes, idx),
    },
  };
}

if (typeof Get === "function" && typeof Print === "function") {
  let total = 0;
  Get(() => {
    total++;
  });
  const abs = {};
  const snap = [];
  Get((n, c) => {
    const pid = c.parentCtx ? c.parentCtx.node.id : null;
    const pa = pid != null && abs[pid] ? abs[pid] : { x: 0, y: 0 };
    const b = c.bounds;
    const a = { x: pa.x + b.x, y: pa.y + b.y };
    abs[n.id] = a;
    snap.push({ id: n.id, name: n.name || "", parent: pid, type: n.type || "", enabled: n.enabled !== false, x: a.x, y: a.y, w: b.width, h: b.height });
  }, { resolveInstances: true });
  const out = scanAll(snap);
  out.total_nodes = total;
  const s = out.scans;
  Print(
    "SUMMARY total_nodes=" + total + " scanned_nodes=" + out.scanned_nodes +
      " sibling_intersection=" + s.sibling_intersection.flagged.length +
      " row_overflow=" + s.row_overflow.flagged.length +
      " cross_parent_collision=" + s.cross_parent_collision.flagged.length +
      " corner_anchor=" + s.corner_anchor.containers + "/" + s.corner_anchor.points + "/" + s.corner_anchor.mismatch
  );
  Print(JSON.stringify(out));
} else if (typeof module === "object" && module && module.exports) {
  module.exports = { AREA_MIN, TOL, CORNER_INSET, CORNER_RE, buildIndex, overlapArea, scanSiblingIntersection, scanRowOverflow, scanCrossParentCollision, scanCornerAnchor, scanAll };
}
