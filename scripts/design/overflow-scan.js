// LS-122：設計收工溢出掃描——四支掃描的正典腳本（取代 ui-designer／visual-reviewer 每輪臨場手寫的 JS）。
//
// 為什麼要正典化：LS-119 R5 的兩個 BLOCKER（角托縮進紙面 148 點錯位、相鄰格角托跨 parent 重疊 80 筆）與
// MJ-6（instance descendants 才 enable 的影片徽章被裁）都是既有兩支掃描結構上抓不到的類別；橫列溢出收據 115 vs
// reviewer 實測 233 則是臨場腳本系統性漏掉每個印品家族的 Corner BR。同型缺陷在 R1／R2／R3 反覆出現——「機械式 gate
// 攔截違規」在這一類是空的（LS-122 票文）。
//
// 用法（兩種執行環境，同一份檔案）：
//   1. Pencil `execute`：先用一次 execute 設定本票觸碰的板 `SCAN_BOARDS = ["<root frame id 或 name>", ...]`（不加
//      const／let，全域才跨 execute 保留；含本票動過的 cmp/* 元件定義），再把本檔全文當作 snippet 送進
//      mcp__pencil__execute（LS-119 R6 實跑：含檔頭註解原樣送、一次成功，comment e58d5688）。檔尾偵測到 `Get`／`Print`
//      存在時，會用 `Get(visit, {resolveInstances:true})` 收集全樹快照（含 instance descendants，id 為 `instanceId/childId`
//      路徑）、算絕對座標、跑四支掃描，`Print`：一行 SUMMARY ＋ 每支掃描一段**分類彙整**（同名對／同容器歸一類：
//      `<n>× <name_a> × <name_b> @ <parent> e.g. <idA>×<idB>`，corner_anchor 的 in-scope 錯位與 unresolved 逐筆、
//      document 錯位按板計數）——真實稿的完整 JSON 有 26 萬字元、超過 MCP 回應上限（R6 實跑），所以預設不印；要完整
//      陣列時設 `SCAN_VERBOSE = true`（每支掃描一個 Print，仍可能被轉存成檔案）。`total_nodes` 用**未展開 instance**
//      的走訪計數（與 design-landing-check.sh --print-nodes／pen-land.sh 同一語意），`scanned_nodes` 才是展開後實際掃過
//      的節點數。設計端依彙整段寫 `design/evidence/<票號>-r<n>-overflow.json`：每類一筆代表（e.g. 的 id）＋
//      `classification`（含「同類 N 例」），補 `ticket`／`round`／`head_sha`（見 ui-designer.md）。
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
//       面積 > AREA_MIN。去重＝只報「最外層」的一對（merge-review R1 MJ-2 修正）：若 a 沒溢出自己的父 pa（a ⊆ pa，允差 TOL）
//       且 pa 也與 b 交集、pa 不是 b 的祖先，則 (a,b) 是 (pa,b) 的後代重複、不報（b 側同理）；一路往上到兩側都各自沒溢出
//       時，最外層那對就是同 parent 的兄弟＝(a) 已報過的繼承交集。反之只要某側溢出自己的容器（角托 corner-out 撞相鄰格、
//       徽章溢出 Photo Wrap 撞鄰居——即使祖先刻意接縫 1pt）就一定報到那個溢出節點。**預設只報「易出血類別」**（任一側名稱
//       命中 BLEED_RE：Corner／Badge／Dragging Photo／Drop Target／Insert Line／Stack Sheet——LS-119 R6 實跑 386 筆多是
//       Spacer × Corner Shape、Feed × Home Indicator Area 這類不可見排版框），`SCAN_CROSS_ALL = true`（node：opts.crossAll）
//       才全報。白名單以 classification 記錄。
//   (d) corner_anchor：每個直接子節點含 `Corner TL/TR/BL/BR` 的節點是一個「容器」（角托的父）。角托咬住的**紙面**不一定是
//       父：現行稿有三種結構——角托是紙面的子（`Photo Wrap`）、角托與紙面 `Print` 是兄弟（`Print Stage`）、角托直接掛在
//       板上而紙面是兄弟 `Print`（iPad 板）。因此紙面由候選（父＋同 parent 的兄弟）中挑「與四顆角托期望位置吻合軸數最多」
//       者（吻合軸數 ≥ 一半才算找到；找不到列 `unresolved`，不計 mismatch、收據需給分類）。期望位置＝角托外緣壓過紙緣
//       `corner-out` 5pt（tokens.md `corner-out` 5；motifs.md「角托一律壓過紙緣 `corner-out` 5pt」）：
//         TL=(P.x−5, P.y−5)、TR=(P.x+P.w−cw+5, P.y−5)、BL=(P.x−5, P.y+P.h−ch+5)、BR=(P.x+P.w−cw+5, P.y+P.h−ch+5)
//       其中 cw／ch 是該顆角托**實測**寬高（merge-review R1 B1：不得假設 26——iPad 版有 40×40）。每顆角托 x／y 各一個斷言，
//       `points`＝斷言數，`mismatch`＝失敗數，允差 TOL。**範圍（orchestrator 裁定 a106f940）**：`mismatch`／`flagged`／
//       `containers`／`points` 只算 `boards`（本票觸碰的板，SCAN_BOARDS）內的容器；全稿數字另列 `document_*` 供參考、
//       不擋 gate（他票舊債另開 chore）。角托錯位不接受白名單，收據 gate 要求 mismatch == 0（design-evidence-check.sh）。
// 輸出每筆都帶 name／parent 等欄位方便分類；design-evidence-check.sh 只驗 node／node_a／node_b／classification、
// corner_anchor 的整數計數與 boards，多出的欄位不影響 gate。

const AREA_MIN = 4;
const TOL = 0.5;
const CORNER_OUT = 5;
const CORNER_RE = /\bCorner (TL|TR|BL|BR)\b/;
const BLEED_RE = /Corner|Badge|Dragging Photo|Drop Target|Insert Line|Stack Sheet/i;

function r2(v) {
  return Math.round(v * 100) / 100;
}

function overlapArea(a, b) {
  const w = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x);
  const h = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y);
  return w > 0 && h > 0 ? w * h : 0;
}

function contains(outer, inner) {
  return inner.x >= outer.x - TOL && inner.y >= outer.y - TOL &&
    inner.x + inner.w <= outer.x + outer.w + TOL && inner.y + inner.h <= outer.y + outer.h + TOL;
}

function buildIndex(nodes) {
  const byId = new Map();
  for (const n of nodes) {
    if (byId.has(n.id)) throw new Error("overflow-scan：節點 id 重複 " + n.id);
    byId.set(n.id, n);
  }
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
  const roots = nodes.filter((n) => n.parent == null);
  return { byId, liveNodes, kids, chain, roots };
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

function scanCrossParentCollision(nodes, idx, opts) {
  const { byId, liveNodes, chain } = idx || buildIndex(nodes);
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
    return contains(pa, a) && overlapArea(pa, b) > AREA_MIN;
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
        if (overlapArea(a, b) <= AREA_MIN) continue;
        if (!all && !BLEED_RE.test(a.name || "") && !BLEED_RE.test(b.name || "")) continue;
        const cb = chain.get(b.id);
        if (ca.includes(b.id) || cb.includes(a.id)) continue;
        if (coveredByParent(a, b, cb) || coveredByParent(b, a, ca)) continue;
        flagged.push(pairEntry(a, b, { parent_a: a.parent, parent_b: b.parent, board, board_name: boardName }));
      }
    }
  }
  return { flagged };
}

function cornerExpected(paper, variant, c) {
  return {
    x: variant === "TR" || variant === "BR" ? paper.x + paper.w - c.w + CORNER_OUT : paper.x - CORNER_OUT,
    y: variant === "BL" || variant === "BR" ? paper.y + paper.h - c.h + CORNER_OUT : paper.y - CORNER_OUT,
  };
}

function resolveBoards(list, roots) {
  const out = [];
  for (const entry of list || []) {
    const hits = roots.filter((r) => r.id === entry || r.name === entry).map((r) => r.id);
    for (const h of hits.length ? hits : [entry]) if (!out.includes(h)) out.push(h);
  }
  return out;
}

function scanCornerAnchor(nodes, idx, opts) {
  const { byId, liveNodes, kids, chain, roots } = idx || buildIndex(nodes);
  const boards = resolveBoards(opts && opts.boards, roots);
  const scoped = boards.length > 0;
  const groups = new Map();
  for (const n of liveNodes) {
    const m = CORNER_RE.exec(n.name || "");
    if (!m || n.parent == null || !byId.get(n.parent)) continue;
    if (!groups.has(n.parent)) groups.set(n.parent, []);
    groups.get(n.parent).push({ node: n, variant: m[1] });
  }
  const out = { boards, containers: 0, points: 0, mismatch: 0, flagged: [], document_containers: 0, document_points: 0, document_mismatch: 0, document_flagged: [], unresolved: [] };
  for (const [pid, corners] of groups) {
    const p = byId.get(pid);
    const c = chain.get(pid);
    const board = c[c.length - 1];
    const boardName = byId.get(board).name;
    const inScope = !scoped || boards.includes(board);
    const base = { container: pid, container_name: p.name, board, board_name: boardName, corners: corners.map((k) => k.node.id) };
    if (corners.length !== 4 && corners.length !== 2) {
      out.unresolved.push(Object.assign({}, base, { reason: "角托數 " + corners.length + "（規則①四角托／②兩對角）" }));
      continue;
    }
    const totalAxes = corners.length * 2;
    const candidates = [p].concat((kids.get(pid) || []).filter((s) => !CORNER_RE.test(s.name || "") && s.w > 0 && s.h > 0));
    let best = null;
    for (const cand of candidates) {
      let score = 0;
      for (const { node, variant } of corners) {
        const e = cornerExpected(cand, variant, node);
        if (Math.abs(node.x - e.x) <= TOL) score++;
        if (Math.abs(node.y - e.y) <= TOL) score++;
      }
      if (!best || score > best.score) best = { cand, score };
    }
    if (!best || best.score * 2 < totalAxes) {
      out.unresolved.push(Object.assign({}, base, {
        reason: "找不到吻合的紙面（父或兄弟）",
        best_candidate: best ? best.cand.id : null, best_candidate_name: best ? best.cand.name : null,
        best_score: best ? best.score : 0, total_axes: totalAxes,
      }));
      continue;
    }
    out.document_containers++;
    out.document_points += totalAxes;
    if (inScope) {
      out.containers++;
      out.points += totalAxes;
    }
    for (const { node, variant } of corners) {
      const e = cornerExpected(best.cand, variant, node);
      for (const axis of ["x", "y"]) {
        if (Math.abs(node[axis] - e[axis]) <= TOL) continue;
        const entry = {
          container: pid, container_name: p.name, paper: best.cand.id, paper_name: best.cand.name, board, board_name: boardName,
          corner: node.id, corner_name: node.name, axis, expected: r2(e[axis]), actual: r2(node[axis]),
        };
        out.document_mismatch++;
        out.document_flagged.push(entry);
        if (inScope) {
          out.mismatch++;
          out.flagged.push(entry);
        }
      }
    }
  }
  return out;
}

function scanAll(nodes, opts) {
  const idx = buildIndex(nodes);
  return {
    scanned_nodes: nodes.length,
    scans: {
      sibling_intersection: scanSiblingIntersection(nodes, idx),
      row_overflow: scanRowOverflow(nodes, idx),
      cross_parent_collision: scanCrossParentCollision(nodes, idx, opts),
      corner_anchor: scanCornerAnchor(nodes, idx, opts),
    },
  };
}

function compactLines(out) {
  const s = out.scans;
  const agg = (items, keyFn, exFn) => {
    const m = new Map();
    for (const it of items) {
      const k = keyFn(it);
      if (!m.has(k)) m.set(k, { n: 0, ex: exFn(it) });
      m.get(k).n++;
    }
    return [...m.entries()].sort((p, q) => q[1].n - p[1].n);
  };
  const blocks = [];
  for (const key of ["sibling_intersection", "cross_parent_collision"]) {
    const items = s[key].flagged;
    const rows = agg(items, (f) => f.name_a + " × " + f.name_b + " @ " + (key === "sibling_intersection" ? f.parent_name : f.board_name), (f) => f.node_a + "×" + f.node_b);
    blocks.push(["SCAN " + key + " flagged=" + items.length + " classes=" + rows.length].concat(rows.map(([k, v]) => "  " + v.n + "× " + k + " e.g. " + v.ex)).join("\n"));
  }
  const ro = agg(s.row_overflow.flagged, (f) => f.parent_name + " :: " + f.name, (f) => f.node + " (+" + f.overflow + ")");
  blocks.push(["SCAN row_overflow flagged=" + s.row_overflow.flagged.length + " classes=" + ro.length].concat(ro.map(([k, v]) => "  " + v.n + "× " + k + " e.g. " + v.ex)).join("\n"));
  const ca = s.corner_anchor;
  const lines = ["SCAN corner_anchor boards=" + JSON.stringify(ca.boards) + " containers/points/mismatch=" + ca.containers + "/" + ca.points + "/" + ca.mismatch +
    " document=" + ca.document_containers + "/" + ca.document_points + "/" + ca.document_mismatch + " unresolved=" + ca.unresolved.length];
  for (const f of ca.flagged) lines.push("  MISMATCH " + f.container_name + "(" + f.container + ") " + f.corner_name + " " + f.axis + " exp=" + f.expected + " act=" + f.actual + " paper=" + f.paper_name + " board=" + f.board_name);
  for (const u of ca.unresolved) lines.push("  UNRESOLVED " + u.container_name + "(" + u.container + ") " + u.reason + (u.best_candidate_name ? " best=" + u.best_candidate_name + " " + u.best_score + "/" + u.total_axes : "") + " board=" + u.board_name);
  for (const [k, v] of agg(ca.document_flagged, (f) => f.board_name + "(" + f.board + ")", (f) => f.container)) lines.push("  DOCUMENT " + v.n + "× board " + k + " e.g. container " + v.ex);
  blocks.push(lines.join("\n"));
  return blocks;
}

if (typeof Get === "function" && typeof Print === "function") {
  const scope = typeof SCAN_BOARDS !== "undefined" && Array.isArray(SCAN_BOARDS) ? SCAN_BOARDS : [];
  const crossAll = typeof SCAN_CROSS_ALL !== "undefined" && SCAN_CROSS_ALL === true;
  const verbose = typeof SCAN_VERBOSE !== "undefined" && SCAN_VERBOSE === true;
  let total = 0;
  Get(() => {
    total++;
  });
  const abs = {};
  const snap = [];
  Get((n, c) => {
    const pid = c.parentCtx ? c.parentCtx.node.id : null;
    if (abs[n.id]) throw new Error("overflow-scan：Get 走訪到重複 id " + n.id);
    if (pid != null && !abs[pid]) throw new Error("overflow-scan：父節點 " + pid + " 尚未走訪（訪問序非 pre-order），無法累加絕對座標");
    const pa = pid != null ? abs[pid] : { x: 0, y: 0 };
    const b = c.bounds;
    const a = { x: pa.x + b.x, y: pa.y + b.y };
    abs[n.id] = a;
    snap.push({ id: n.id, name: n.name || "", parent: pid, type: n.type || "", enabled: n.enabled !== false, x: a.x, y: a.y, w: b.width, h: b.height });
  }, { resolveInstances: true });
  const out = scanAll(snap, { boards: scope, crossAll });
  out.total_nodes = total;
  const s = out.scans;
  if (scope.length === 0) Print("WARNING SCAN_BOARDS 未設定：corner_anchor 以全稿計 mismatch，收據 gate 會因 boards 為空而紅——先用一次 execute 設 SCAN_BOARDS=[...] 再重跑");
  Print(
    "SUMMARY total_nodes=" + total + " scanned_nodes=" + out.scanned_nodes +
      " sibling_intersection=" + s.sibling_intersection.flagged.length +
      " row_overflow=" + s.row_overflow.flagged.length +
      " cross_parent_collision=" + s.cross_parent_collision.flagged.length + (crossAll ? "(all)" : "(bleed-only)") +
      " corner_anchor=" + s.corner_anchor.containers + "/" + s.corner_anchor.points + "/" + s.corner_anchor.mismatch +
      " document=" + s.corner_anchor.document_containers + "/" + s.corner_anchor.document_points + "/" + s.corner_anchor.document_mismatch +
      " unresolved=" + s.corner_anchor.unresolved.length + " boards=" + JSON.stringify(s.corner_anchor.boards)
  );
  for (const block of compactLines(out)) Print(block);
  if (verbose) for (const key of Object.keys(s)) Print("JSON " + key + " " + JSON.stringify(s[key]));
} else if (typeof module === "object" && module && module.exports) {
  module.exports = { AREA_MIN, TOL, CORNER_OUT, CORNER_RE, BLEED_RE, buildIndex, overlapArea, contains, cornerExpected, compactLines, scanSiblingIntersection, scanRowOverflow, scanCrossParentCollision, scanCornerAnchor, scanAll };
} else {
  throw new Error("overflow-scan：既不是 Pencil execute（無 Get／Print）也不是 node module 環境，無處輸出");
}
