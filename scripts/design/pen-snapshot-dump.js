// LS-289：Pencil execute 用的唯讀快照 dump snippet——把 scripts/design/overflow-scan.js `scanAll` 需要的節點快照
// （與該檔 `canonNode`／`snapVisit` 同構的欄位子集：root 列表、absolute 座標、clip 祖先、ref／descendants、文字節點
// 寬高含 textGrowth）印成緊湊陣列，交給 node 端 `overflow-scan.js --from-snapshot` 讀取、跑「未修改的」`scanAll`＋
// 六支＋`withResultHashes`。動機：10.3k–10.5k 節點稿在 Pencil `execute` 沙盒跑完整 92 KB 正典腳本（雜湊＋六支）
// 必 `InternalError: interrupted`，`SCAN_BATCH` 分批（LS-226）仍每輪 5–8 次 interrupted 需縮段重試——本檔只做「唯讀
// 走訪＋印快照」這一件事，比帶六支演算法的全文輕得多，一次 execute 就能跑完（LS-289 來源：LS-280 VR R2–R6 六輪皆
// 手動走這條路徑才穩定，見 LS-280 comment `0cc95d688` 的「做法揭露」段）。**本檔唯讀，不寫入 .pen 任何內容。**
//
// 用法：把本檔全文當作 snippet 送進 mcp__pencil__execute（不需要另外設 SCAN_BOARDS 之類的旗標——本檔一律 dump
// 全稿，範圍限縮交給 node 端 `overflow-scan.js --from-snapshot --boards a,b,…` 處理，snapshot 階段沒有「掃描範圍」
// 這個概念）：
//   - 每筆節點壓成陣列（欄位順序固定，與 `vr-scan.js`／`vr-scan2.js` 的 parser、`snap-r2.json`／`snap-r3.json` 的
//     實測輸入完全一致）：
//       [id, name, parent, type, ref, enabled(0/1), clip(0/1), image(0/1), x, y, w, h]
//     `ref` 為 `null` 代表沒有 ref（未解析到已知元件）。`x`／`y`／`w`／`h` 為絕對座標 AABB——與 overflow-scan.js
//     `snapVisit` 同語意：`x`／`y` 由父節點的絕對座標＋`c.bounds` 的相對位移逐層累加算出（Pencil `Get` 的
//     `c.bounds` 是相對父節點的位移，不是絕對座標），`w`／`h` 直接取 `c.bounds.width`／`height`（Pencil 版面引擎
//     已算好的展開後尺寸，text 節點的高已含 `textGrowth` 撐開的高度，不需要另外處理）。
//   - **LS-377 起依位元組預算分段**（取代舊版 `SNAP_BATCH_ROWS` 依列數切批——14k 節點稿整份一次送必 `InternalError:
//     interrupted`，且 Print 單次輸出 >約 7 萬字元時 Pencil 會自動把那次 Print 落到本機檔案、MCP 回應改印檔案路徑）：
//     一次 execute 只 dump「一段」——從頂層（depth-1）子節點序 `SNAP_ROOTS = [lo, hi]`（前置全域宣告，未設＝[0, ∞)）起，
//     依序收整棵子樹，累計 rows 的 UTF-8 位元組數（`JSON.stringify(row)` 加逗號）到 `SNAP_MAX_BYTES`（未設＝50000）就停在
//     下一個頂層節點之前。**單一子樹本身就超過預算時**（實測 14k–18k 節點稿有頂層板的 rows 就 >64 KB；而 `pen` CLI／
//     MCP 單次 execute 回應約 64 KB 就被截斷，DONE 行會遺失）改在該子樹內依 pre-order 列序切：`SNAP_SKIP = m` 跳過
//     該頂層節點（序 lo）的前 m 列（仍走訪、累加座標，只是不印），印到預算為止，`SNAP-DONE` 的 `skip=` 告訴下一段從第幾列續。
//     每段印 `SNAP<k> [...]` 行（一段通常只有一行；k＝lo×1000000＋skip＋段內已印列數＋1，跨段嚴格遞增，node 端 parser
//     依 k 排序串接時順序仍是 pre-order，見 overflow-scan.js `parseSnapshotDump`），最後一行
//     `SNAP-DONE roots=[lo,next) next=<下一段起點的頂層序> skip=<下一段 SNAP_SKIP> of=<頂層總數> total_rows=<n> bytes=<b>`。
//     呼叫端迴圈：lo=0、skip=0 → 跑一段 → 讀 `next`／`skip` 當下一段的 `SNAP_ROOTS = [next, ∞]`／`SNAP_SKIP` → 直到
//     `next` 等於 `of`；各段的 `SNAP<k>` 行全部貼進同一個 dump 檔。
//     `SNAP_ROOT_COUNT_ONLY = true`：只印 `SNAP-ROOT-COUNT n=<頂層總數>`（不走訪子樹）。
//     **單段 interrupted 的處置（上限 3 次）**：同一個 lo 把 `SNAP_MAX_BYTES` 對半重跑（50000→25000→12500→6250），
//     第 4 次仍 interrupted 就停下回報（不得再縮；那是環境問題——先 `open -a Pen` 置前景再試，見下）。
//     **執行前 `open -a Pen` 把 Pen 置於前景**（LS-377：背景時 execute 明顯較易 interrupted，置前景即過）。
//     `SNAP_ROOTS`／`SNAP_SKIP`／`SNAP_MAX_BYTES`／`SNAP_ROOT_COUNT_ONLY` 是 Pencil execute 的全域變數，會在後續呼叫間殘留
//     （見 execute 回應「Global variables … carry over」）——每一次呼叫都明確宣告 `SNAP_ROOTS`／`SNAP_SKIP`，不要依賴上一次。
//   - **ref 判準（LS-207）**：`resolveInstances:true` 展開後的樹裡，實例根節點本身沒有 `n.ref`（已被展開成子樹）——
//     跟 overflow-scan.js 檔尾 Pencil execute 區塊完全相同的做法：本腳本先跑一次 `resolveInstances:false` 的唯讀
//     走訪，把每個 `type:"ref"` 節點的 `id → ref`（元件 id）收進對照表 `refMap`；再用 `resolveInstances:true`
//     展開走訪時，用同一個節點 `id` 查表把 `ref` 榫接回去（同一個實例根節點在兩次走訪 id 相同，只有它的子孫在
//     展開版多出 `instanceId/childId` 複合 id）。查不到就印 `null`，node 端 `isCorner` 退回名稱備援（`Corner
//     TL/TR/BL/BR`），行為與正常 in-Pencil 路徑一致。
//   - 走訪順序＝pre-order（父先於子，繪製順序）；`Get` 沒有回傳就丟出 `overflow-scan：父節點尚未走訪` 這類錯誤時，
//     代表 Pencil 的走訪順序假設不成立，直接讓它中斷（fail loud，不吞錯）。
//
// 取回：把每個 `SNAP<k> [...]` 行（或其落檔內容）原樣貼進同一個檔案（保留整行形狀，行序不拘、可與其他 SNAP<k>
// 行交錯），交給 `node scripts/design/overflow-scan.js --from-snapshot <dump 檔> --tree-hash <16 碼 hex>
// --total-nodes <n> [--boards a,b,… ] [--out receipt.json]`——`--tree-hash`／`--total-nodes` 是必填：本檔只 dump
// 展開後的緊湊快照，無法從中重算出與 `.pen` 原始未展開全樹相同的 `tree_hash`（那需要全部節點的完整屬性，不只
// 六支演算法要用的這 12 個欄位），須另外用既有 `SCAN_HASH_ONLY` 走訪（見 overflow-scan.js 檔頭「用法」第 1 段）
// 或 `scripts/gates/design_tree_hash.py` 對同一稿態離線算好再傳入（LS-280 R2／R3 實際做法：後者，對已落地 commit
// 的 `.pen` 離線重算）。

if (typeof Get !== "function" || typeof Print !== "function") {
  throw new Error("pen-snapshot-dump：只能當 Pencil execute snippet 跑（沒有全域 Get／Print，這裡是 node 或其他環境）");
}

function hasImageFill(fill) {
  // 必須與 scripts/design/overflow-scan.js 的 hasImageFill 同規格（Pencil execute snippet 不能 require()，只能重複
  // 這段小函式；改動任一邊記得同步另一邊——overflow-scan.test.js「原始碼斷言」類測試釘不到跨檔一致，靠 code review）
  var one = function (f) { return !!f && typeof f === "object" && f.type === "image" && f.enabled !== false; };
  return Array.isArray(fill) ? fill.some(one) : one(fill);
}

var MAX_BYTES = typeof SNAP_MAX_BYTES !== "undefined" && SNAP_MAX_BYTES ? Number(SNAP_MAX_BYTES) : 50000;
var RANGE = typeof SNAP_ROOTS !== "undefined" && Array.isArray(SNAP_ROOTS) ? SNAP_ROOTS : null;
var LO = RANGE ? Number(RANGE[0]) : 0;
var HI = RANGE && RANGE[1] != null && RANGE[1] !== Infinity ? Number(RANGE[1]) : Infinity;
var SKIP = typeof SNAP_SKIP !== "undefined" && SNAP_SKIP ? Number(SNAP_SKIP) : 0;

if (typeof SNAP_ROOT_COUNT_ONLY !== "undefined" && SNAP_ROOT_COUNT_ONLY === true) {
  var rc = 0;
  Get(function (n, c) { if (!c.parentCtx) { rc++; c.skipChildren(); } });
  Print("SNAP-ROOT-COUNT n=" + rc);
} else {
  // UTF-8 位元組數（Print 落檔門檻看字元數，但 MCP 回應大小看位元組；中文名稱一字 3 bytes，用位元組較保守）
  var utf8Len = function (str) {
    var b = 0;
    for (var q = 0; q < str.length; q++) {
      var cc = str.charCodeAt(q);
      if (cc < 0x80) b += 1;
      else if (cc < 0x800) b += 2;
      else if (cc >= 0xd800 && cc <= 0xdbff) { b += 4; q++; }
      else b += 3;
    }
    return b;
  };
  var inRange = function (c) { return c.index >= LO && c.index < HI; };

  // LS-207：resolveInstances:false 對照表——只收 type:"ref" 節點的 id → ref（元件 id）；只走範圍內的頂層子樹
  var refMap = {};
  var rootTotal = 0;
  Get(function (n, c) {
    if (!c.parentCtx) {
      rootTotal++;
      if (!inRange(c)) { c.skipChildren(); return; }
    }
    if (n.type === "ref" && n.ref != null) refMap[n.id] = n.ref;
  }, { resolveInstances: false });

  // 展開走訪：累加絕對座標＋收 rows；以「頂層子樹」為單位依位元組預算收段
  var abs = {};
  var rows = [];        // 已接受的段內 rows
  var segBytes = 0;
  var segRoots = 0;
  var cur = [];         // 目前頂層子樹的 rows（下一個頂層節點開始或走訪結束時才決定收不收）
  var curBytes = 0;
  var curIdx = -1;
  var next = null;      // 停在哪個頂層序（null＝走到範圍尾）
  var nextSkip = 0;     // 停在該頂層子樹的第幾列（0＝從子樹開頭）
  var visitedInRoot = 0;
  var finalize = function () {
    if (curIdx < 0) return;
    if (segBytes + curBytes <= MAX_BYTES) {
      for (var r = 0; r < cur.length; r++) rows.push(cur[r]);
      segBytes += curBytes;
      segRoots++;
    } else if (segRoots === 0) {
      // 段內第一棵子樹就超過預算：在子樹內依列序切，至少收 1 列（保證前進）
      var took = 0;
      var tb = 0;
      while (took < cur.length) {
        var rb0 = utf8Len(JSON.stringify(cur[took])) + 1;
        if (took > 0 && tb + rb0 > MAX_BYTES) break;
        rows.push(cur[took]);
        tb += rb0;
        took++;
      }
      segBytes += tb;
      segRoots++;
      next = curIdx;
      nextSkip = (curIdx === LO ? SKIP : 0) + took;
    } else {
      next = curIdx;
    }
    cur = []; curBytes = 0; curIdx = -1;
  };
  Get(function (n, c) {
    if (!c.parentCtx) {
      if (!inRange(c) || next != null) { c.skipChildren(); return; }
      finalize();
      if (next != null) { c.skipChildren(); return; }
      curIdx = c.index;
      visitedInRoot = 0;
    }
    var pid = c.parentCtx ? c.parentCtx.node.id : null;
    if (abs[n.id]) throw new Error("pen-snapshot-dump：Get 走訪到重複 id " + n.id);
    if (pid != null && !abs[pid]) throw new Error("pen-snapshot-dump：父節點 " + pid + " 尚未走訪（訪問序非 pre-order），無法累加絕對座標");
    var pa = pid != null ? abs[pid] : { x: 0, y: 0 };
    var b = c.bounds;
    var a = { x: pa.x + b.x, y: pa.y + b.y };
    abs[n.id] = a;
    var ref = n.ref != null ? n.ref : (refMap[n.id] != null ? refMap[n.id] : null);
    var row = [
      n.id, n.name || "", pid, n.type || "", ref,
      n.enabled !== false ? 1 : 0,
      n.clip === true ? 1 : 0,
      hasImageFill(n.fill) ? 1 : 0,
      a.x, a.y, b.width, b.height,
    ];
    // 段起點那棵子樹的前 SKIP 列只走訪（座標要累加）、不收
    if (curIdx === LO && visitedInRoot < SKIP) { visitedInRoot++; return; }
    visitedInRoot++;
    cur.push(row);
    curBytes += utf8Len(JSON.stringify(row)) + 1;
  }, { resolveInstances: true });
  finalize();
  var nextRoot = next != null ? next : Math.min(HI, rootTotal);
  // 整棵子樹剛好被收完的情況（partial 切完後 nextSkip 已等於該子樹列數）由下一段自然收到 0 列、前進——不特判

  // 段內再依同一位元組預算切 Print 行（只有單一超大子樹獨佔一段時才會多行）
  var batch = [];
  var batchBytes = 0;
  var printed = 0;
  var flush = function () {
    if (!batch.length) return;
    Print("SNAP" + (LO * 1000000 + SKIP + printed + 1) + " " + JSON.stringify(batch));
    printed += batch.length;
    batch = []; batchBytes = 0;
  };
  for (var i = 0; i < rows.length; i++) {
    var rb = utf8Len(JSON.stringify(rows[i])) + 1;
    if (batch.length && batchBytes + rb > MAX_BYTES) flush();
    batch.push(rows[i]);
    batchBytes += rb;
  }
  flush();
  Print("SNAP-DONE roots=[" + LO + "," + nextRoot + ") next=" + nextRoot + " skip=" + nextSkip + " of=" + rootTotal + " total_rows=" + rows.length + " bytes=" + segBytes);
}
