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
//   - 依 `SNAP_BATCH_ROWS`（未設時預設 400）把 rows 切批，每批一行 `Print("SNAP<k> [...]")`（k 從 1 起算、
//     不拘印出順序，node 端 parser 只把所有 `SNAP<n> [...]` 行的陣列串接，見 overflow-scan.js `parseSnapshotDump`）。
//     **Print 單次輸出 >約 7 萬字元時 Pencil 會自動把那次 Print 的內容落到本機檔案**（MCP 回應改印檔案路徑，不是
//     內容本身）——這是 Pencil MCP 本身的行為，不是本腳本處理的；若某個 `SNAP<k>` 批次觸發這個情況，直接讀那個
//     本機檔案內容當作那一行的替代（檔案內容＝原本 `Print` 會印出的那一行文字，原樣是 `SNAP<k> [...]` 的形狀），
//     跟其餘沒落檔的 `SNAP<k>` 行一起貼進同一份 dump 檔交給 node 端；調小 `SNAP_BATCH_ROWS`（例如 200）可以讓
//     每一行都低於門檻、不必處理落檔這一步。
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

var BATCH_ROWS = typeof SNAP_BATCH_ROWS !== "undefined" && SNAP_BATCH_ROWS ? Number(SNAP_BATCH_ROWS) : 400;

// LS-207：resolveInstances:false 對照表——只收 type:"ref" 節點的 id → ref（元件 id）
var refMap = {};
Get(function (n) {
  if (n.type === "ref" && n.ref != null) refMap[n.id] = n.ref;
}, { resolveInstances: false });

// 展開走訪：累加絕對座標＋收 rows
var abs = {};
var rows = [];
Get(function (n, c) {
  var pid = c.parentCtx ? c.parentCtx.node.id : null;
  if (abs[n.id]) throw new Error("pen-snapshot-dump：Get 走訪到重複 id " + n.id);
  if (pid != null && !abs[pid]) throw new Error("pen-snapshot-dump：父節點 " + pid + " 尚未走訪（訪問序非 pre-order），無法累加絕對座標");
  var pa = pid != null ? abs[pid] : { x: 0, y: 0 };
  var b = c.bounds;
  var a = { x: pa.x + b.x, y: pa.y + b.y };
  abs[n.id] = a;
  var ref = n.ref != null ? n.ref : (refMap[n.id] != null ? refMap[n.id] : null);
  rows.push([
    n.id, n.name || "", pid, n.type || "", ref,
    n.enabled !== false ? 1 : 0,
    n.clip === true ? 1 : 0,
    hasImageFill(n.fill) ? 1 : 0,
    a.x, a.y, b.width, b.height,
  ]);
}, { resolveInstances: true });

var batch = [];
var k = 0;
var flush = function () {
  if (!batch.length) return;
  k++;
  Print("SNAP" + k + " " + JSON.stringify(batch));
  batch = [];
};
for (var i = 0; i < rows.length; i++) {
  batch.push(rows[i]);
  if (batch.length >= BATCH_ROWS) flush();
}
flush();
Print("SNAP-DONE total_rows=" + rows.length + " batches=" + k);
