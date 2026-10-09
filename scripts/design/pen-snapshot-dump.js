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
//   - **LS-431 起逐板走訪、分段單位＝板數**（取代 LS-377 的位元組預算分段；來源 LS-425 R4：19k 節點稿在 document 級
//     `Get(visit, {resolveInstances:true})` 整份展開走訪，光走訪 380 塊頂層板不讀座標就 2.2 秒、連 50000 位元組的段都
//     `InternalError: interrupted`，設計者改成逐板 `Get(rootId, …)` 才 6 段跑完，與整份走訪的 r3 dump 逐列等價）：
//     一次 execute 只 dump「一段」——先做一趟**未展開**的頂層走訪（`skipChildren`，只拿頂層板 id 順序與總數 `of`），
//     再從頂層板序 `SNAP_ROOTS = [lo, hi]`（前置全域宣告，未設＝[0, ∞)）起，**每塊板各跑兩趟 scoped `Get(boardId, …)`**
//     （① `resolveInstances:false` 收該板的 `ref` 對照表、② `resolveInstances:true` 展開並累加絕對座標、收 rows），最多
//     `SNAP_BOARDS`（未設＝40）塊板就停；展開走訪永遠只碰單一板的子樹，不再有 document 級展開。板是不可再切的單位：
//     不再有「在子樹內依列序切」，所以 `SNAP-DONE` 的 `skip=` 與 `from=` 恆為 0（欄位保留，讓 node 端 `parseSnapshotDump` 的
//     首尾相接驗證與既有 r1–r4 的舊格式 dump 都不用改）。每段印 `SNAP<k> [...]` 行（k＝lo×1000000＋段內已印列數＋1，跨段嚴格
//     遞增，node 端 parser 依 k 排序串接時順序仍是 pre-order，見 overflow-scan.js `parseSnapshotDump`；單一 Print 行以約 50000
//     位元組為上限——Pencil 單次 Print >約 7 萬字元會自動落本機檔案，所以一段通常有多行、整段輸出常被 MCP 落檔），再印一行
//     `SNAP-TIMING boards=<段內板數> root_walk_ms=… ref_walk_ms=… expand_walk_ms=… print_ms=…`（量測用，parser 不認、可不貼），最後一行
//     `SNAP-DONE roots=[lo,next) next=<下一段起點的頂層序> skip=0 of=<頂層總數> total_rows=<n> bytes=<b> from=0`。
//     呼叫端迴圈：lo=0 → 跑一段 → 讀 `next` 當下一段的 `SNAP_ROOTS = [next, Infinity]` → 直到 `next` 等於 `of`；各段的
//     `SNAP<k>` 與 `SNAP-DONE` 行**全部**貼進同一個 dump 檔。
//     **node 端會驗**（overflow-scan.js `parseSnapshotDump`，LS-377 R2）：各段 `SNAP-DONE` 的起點（`roots=[lo,…)`＋`from=`）必須
//     首尾相接、從 (0,0) 起、最後一段 `next==of` 且 `skip=0`、各段 `total_rows` 加總等於實際貼進來的列數——缺中段／缺尾段／
//     漏貼 SNAP 行一律報錯 exit 非 0，不會產出只涵蓋部分稿的收據。**沒帶 `SNAP_ROOTS` 只會得到第一段**。
//     `SNAP_ROOT_COUNT_ONLY = true`：只印 `SNAP-ROOT-COUNT n=<頂層總數>`（不走訪子樹）。
//     **單段 interrupted 的處置（上限 3 次）**：同一個 lo 把 `SNAP_BOARDS` 對半重跑（40→20→10→5），第 4 次仍 interrupted 就停下
//     回報（不得再縮；那是環境問題——先 `open -a Pen` 置前景再試，見下）。
//     **執行前 `open -a Pen` 把 Pen 置於前景**（LS-377：背景時 execute 明顯較易 interrupted，置前景即過）。
//     `SNAP_ROOTS`／`SNAP_BOARDS`／`SNAP_ROOT_COUNT_ONLY` 是 Pencil execute 的全域變數，會在後續呼叫間殘留（見 execute 回應
//     「Global variables … carry over」）——每一次呼叫都明確宣告 `SNAP_ROOTS`／`SNAP_BOARDS`，不要依賴上一次。
//     **舊參數明確拒絕（fail loud，不靜默忽略）**：`SNAP_BATCH_ROWS`（LS-377 前）、`SNAP_MAX_BYTES`（LS-377 的段大小旋鈕，現在
//     對半重跑它不會讓段變小、會無限重試同一段）、非 0 的 `SNAP_SKIP`（板不再於子樹內切）一律 throw；`SNAP_SKIP = 0` 放行。
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

// 舊版參數一律明確拒絕——靜默忽略會讓呼叫端以為自己控制了段大小／拿到全量（Pencil execute 沙盒沒有 process.exit，拋錯即
// execute 失敗＝fail loud）。這些全域也可能是上一次呼叫殘留的（execute 會保留全域）：第一行加 `<名稱> = undefined;` 即清掉。
if (typeof SNAP_BATCH_ROWS !== "undefined") {
  throw new Error("pen-snapshot-dump：SNAP_BATCH_ROWS 已不再支援（LS-377 起依段分、LS-431 起逐板分段）——改用 SNAP_BOARDS（預設 40）＋SNAP_ROOTS 續跑，見本檔檔頭；若是上一次呼叫殘留的全域，第一行加 SNAP_BATCH_ROWS = undefined;");
}
if (typeof SNAP_MAX_BYTES !== "undefined") {
  throw new Error("pen-snapshot-dump：SNAP_MAX_BYTES 已不再支援（LS-431 起分段單位是板數，位元組預算改不了段大小、interrupted 時對半它會無限重試同一段）——改用 SNAP_BOARDS（預設 40，interrupted 時對半）；若是上一次呼叫殘留的全域，第一行加 SNAP_MAX_BYTES = undefined;");
}
if (typeof SNAP_SKIP !== "undefined" && SNAP_SKIP && Number(SNAP_SKIP) !== 0) {
  throw new Error("pen-snapshot-dump：SNAP_SKIP=" + SNAP_SKIP + " 已不再支援（LS-431 起一塊板是不可再切的單位，續跑點只有板序 SNAP_ROOTS = [next, Infinity]；SNAP-DONE 的 skip 恆為 0）");
}

function hasImageFill(fill) {
  // 必須與 scripts/design/overflow-scan.js 的 hasImageFill 同規格（Pencil execute snippet 不能 require()，只能重複
  // 這段小函式；改動任一邊記得同步另一邊——overflow-scan.test.js「原始碼斷言」類測試釘不到跨檔一致，靠 code review）
  var one = function (f) { return !!f && typeof f === "object" && f.type === "image" && f.enabled !== false; };
  return Array.isArray(fill) ? fill.some(one) : one(fill);
}

var LINE_BYTES = 50000; // 單一 Print 行的 UTF-8 位元組上限（Pencil 單次 Print >約 7 萬字元會自動落檔；與分段大小無關）
var BOARDS = typeof SNAP_BOARDS !== "undefined" && SNAP_BOARDS ? Number(SNAP_BOARDS) : 40;
if (!(BOARDS >= 1)) throw new Error("pen-snapshot-dump：SNAP_BOARDS 必須是 ≥1 的整數（收到 " + SNAP_BOARDS + "）");
var RANGE = typeof SNAP_ROOTS !== "undefined" && Array.isArray(SNAP_ROOTS) ? SNAP_ROOTS : null;
var LO = RANGE ? Number(RANGE[0]) : 0;
var HI = RANGE && RANGE[1] != null && RANGE[1] !== Infinity ? Number(RANGE[1]) : Infinity;

// 頂層板 id 順序（未展開、skipChildren：只訪頂層節點）；頂層板順序＝文件 children 順序
var ids = [];
var tRoot = Date.now();
Get(function (n, c) { if (!c.parentCtx) { ids.push(n.id); c.skipChildren(); } });
var rootWalkMs = Date.now() - tRoot;
var rootTotal = ids.length;

if (typeof SNAP_ROOT_COUNT_ONLY !== "undefined" && SNAP_ROOT_COUNT_ONLY === true) {
  Print("SNAP-ROOT-COUNT n=" + rootTotal);
} else {
  if (LO > rootTotal) throw new Error("pen-snapshot-dump：SNAP_ROOTS 起點 " + LO + " 超過頂層板總數 " + rootTotal);
  var end = Math.min(HI, LO + BOARDS, rootTotal);

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

  var abs = {};
  var rows = [];
  var refMap = {};      // LS-207：id → 元件 id；每塊板開始前重建（實例根節點與其 ref 同在一塊板內）
  var segBytes = 0;
  var refWalkMs = 0;
  var expandWalkMs = 0;

  var collectRefs = function (n) {
    if (n.type === "ref" && n.ref != null) refMap[n.id] = n.ref;
  };
  var visit = function (n, c) {
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
    rows.push(row);
  };

  // 逐板：每塊板各跑 scoped Get（未展開收 refMap → 展開收 rows），展開走訪只碰單一板的子樹——不得改回 document 級展開
  // （LS-431：整份展開走訪 19k 節點稿即 interrupted）。root 節點在 scoped Get 裡 parentCtx 為 null、bounds 即絕對座標。
  for (var bi = LO; bi < end; bi++) {
    refMap = {};
    var t0 = Date.now();
    Get(ids[bi], collectRefs, { resolveInstances: false });
    refWalkMs += Date.now() - t0;
    t0 = Date.now();
    Get(ids[bi], visit, { resolveInstances: true });
    expandWalkMs += Date.now() - t0;
  }

  // 依同一位元組上限切 Print 行（一段通常多行；單列本身超過上限仍獨佔一行）
  var tPrint = Date.now();
  var batch = [];
  var batchBytes = 0;
  var printed = 0;
  var flush = function () {
    if (!batch.length) return;
    Print("SNAP" + (LO * 1000000 + printed + 1) + " " + JSON.stringify(batch));
    printed += batch.length;
    batch = []; batchBytes = 0;
  };
  for (var i = 0; i < rows.length; i++) {
    var rb = utf8Len(JSON.stringify(rows[i])) + 1;
    if (batch.length && batchBytes + rb > LINE_BYTES) flush();
    batch.push(rows[i]);
    batchBytes += rb;
    segBytes += rb;
  }
  flush();
  Print("SNAP-TIMING boards=" + (end - LO) + " root_walk_ms=" + rootWalkMs + " ref_walk_ms=" + refWalkMs + " expand_walk_ms=" + expandWalkMs + " print_ms=" + (Date.now() - tPrint));
  Print("SNAP-DONE roots=[" + LO + "," + end + ") next=" + end + " skip=0 of=" + rootTotal + " total_rows=" + rows.length + " bytes=" + segBytes + " from=0");
}
