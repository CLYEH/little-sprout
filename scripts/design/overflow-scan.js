// LS-122：設計收工溢出掃描——正典腳本（取代 ui-designer／visual-reviewer 每輪臨場手寫的 JS）；四支（LS-122）→ 第五支
// text_occlusion（LS-168）→ 第六支 board_clip＋收據 scan_scope＋cross_parent_collision 候選過濾（LS-185）。
//
// 為什麼要正典化：LS-119 R5 的兩個 BLOCKER（角托縮進紙面 148 點錯位、相鄰格角托跨 parent 重疊 80 筆）與
// MJ-6（instance descendants 才 enable 的影片徽章被裁）都是既有兩支掃描結構上抓不到的類別；橫列溢出收據 115 vs
// reviewer 實測 233 則是臨場腳本系統性漏掉每個印品家族的 Corner BR。同型缺陷在 R1／R2／R3 反覆出現——「機械式 gate
// 攔截違規」在這一類是空的（LS-122 票文）。
//
// 用法（兩種執行環境，同一份檔案）：
//   1. Pencil `execute`：把本檔全文當作 snippet 送進 mcp__pencil__execute，**第一行先加** `SCAN_BOARDS = ["<root frame
//      id 或 name>", ...];`（本票觸碰的板，含動過的 cmp/* 元件定義）——LS-122 實跑證實跨 execute 的全域**不保留**（另一次
//      execute 設的 SCAN_BOARDS 到下一次是 undefined），旗標必須與腳本同一個 snippet；`SCAN_CROSS_ALL`／`SCAN_VERBOSE` 同理
//      （LS-119 R6／LS-122 實跑：含檔頭註解原樣送、一次成功，comment e58d5688）。檔尾偵測到 `Get`／`Print`
//      存在時，會用 `Get(visit, {resolveInstances:true})` 收集全樹快照（含 instance descendants，id 為 `instanceId/childId`
//      路徑）、算絕對座標、跑四支掃描，`Print`：一行 SUMMARY ＋ 每支掃描一段**分類彙整**（同名對／同容器歸一類：
//      `<n>× <name_a> × <name_b> @ <parent> e.g. <idA>×<idB>`，corner_anchor 的 in-scope 錯位與 unresolved 逐筆、
//      document 錯位按板計數）——真實稿的完整 JSON 有 26 萬字元、超過 MCP 回應上限（R6 實跑），所以預設不印；要完整
//      陣列時設 `SCAN_VERBOSE = true`（每支掃描一個 Print，仍可能被轉存成檔案）。`total_nodes` 用**未展開 instance**
//      的走訪計數（與 design-landing-check.sh --print-nodes／pen-land.sh 同一語意），`scanned_nodes` 才是展開後實際掃過
//      的節點數。設計端依彙整段寫 `design/evidence/<票號>-r<n>-overflow.json`：每類一筆代表（e.g. 的 id）＋
//      `classification`（含「同類 N 例」），補 `ticket`／`round`／`head_sha`，`tree_hash` 抄 SUMMARY 的值（LS-168；見
//      ui-designer.md）。`SCAN_OVERLAY_RE = "Action Bar|…"`（字串）覆寫第五支的覆蓋層名稱，`SCAN_HASH_DEBUG = "<id>"` 印
//      該節點的雜湊行。`SCAN_HASH_ONLY = true` 只跑雜湊走訪、印 `SUMMARY-HASH total_nodes=… tree_hash=…`；`SCAN_SKIP_HASH = true`
//      跑六支不算雜湊（SUMMARY 印 `tree_hash=skipped`；兩旗標同時設會 throw）——8000 節點級的稿一次 execute 跑完雜湊＋六支會 `InternalError:
//      interrupted`（LS-152 VR R3 實測），拆成同一稿態、中間無任何寫入的連續兩次唯讀 execute，收據 `tree_hash` 抄第一次（LS-171）。
//      `SCAN_SCOPE = "boards"`（LS-185）把快照限縮到 SCAN_BOARDS 子樹再跑六支，SUMMARY 與收據 `scan_scope` 如實標 `boards`（預設
//      `document`＝全稿；見下方 scan_scope 段）。
//   2. node：`require` 本檔取得純函數（`scanAll` 與六支 `scan*`、`treeHash`／`treeHashLines`／`canonNode`），
//      `scripts/design/overflow-scan.test.js` 用合成節點樹驗演算法、並以 python 交叉驗 tree_hash 同值；CI rules job 的自測
//      step 跑它。掃描核心不碰 Pencil API，Pen 不在時也能驗。注意：.pen JSON 只存 root／absolute 節點的 x／y，layout 子節點
//      的絕對座標要 Pencil 版面引擎才算得出——離線 node 能驗的是演算法與 tree_hash，不是真實稿的六支數字。
//
// 節點快照格式（純函數的唯一輸入）：陣列，父先於子（top-down，陣列順序＝繪製順序，第五支據此判 z-order），每筆：
//   {id, name, parent (父 id；頂層為 null), type, enabled (布林), clip (布林，第五／六支用), image (布林，fill 含 image——第六支
//   把它當可見葉節點；.pen 沒有 image 型別，照片是帶 image fill 的 frame／rectangle), x, y, w, h}  —— x/y/w/h 為**絕對座標** AABB。
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
//   (e) text_occlusion（LS-168，第五支）：同一板內任一 `type:"text"` 節點，與名稱命中 OVERLAY_RE（Action Bar／Tab Bar／
//       Capsule／Footer／Toast／Banner；Pencil 端 `SCAN_OVERLAY_RE = "…"` 或 node `opts.overlayRe` 可覆寫）、**非其祖先**、且
//       **繪製順序在它之後**（快照陣列順序＝pre-order＝繪製順序，後者蓋前者：同一容器內較後的兄弟、或較後兄弟的子樹）
//       的容器，text 的**可見矩形**（自身 AABB ∩ 所有 `clip:true` 祖先——捲動容器裁掉的部分不算被蓋）與覆蓋層 AABB 交集面積
//       > 0 即報（`node`／`overlay`／`overlap`）。同一個 text 對同一條祖先鏈上的多個覆蓋層只報最外層那個。LS-152 R1 BL-2（`Label` × `Action Bar`：釘底動作帶壓住 EULA 法務連結）、BL-3（`Value` × `Tab Bar`：
//       膠囊蓋住「2.1／5 GB」）與 LS-67 R1「主鈕蓋住隱私揭露文字」同 class，四支的 BLEED_RE 名稱一個都不命中、結構上抓不到，
//       visual-reviewer 每輪自建第五支才抓到（f1cf27d0）。**範圍同 corner_anchor**：`flagged` 只算 `boards`（SCAN_BOARDS）內
//       的板、全稿另列 `document_flagged` 供參考不擋（LS-21 時間軸等既有板的 feed 文字捲到浮動膠囊底下是滾動態的常態，全稿
//       計會讓每張後續 PR 都紅；本票的板要做到「整列在膠囊上方或下方」，VR R1 BL-3 的標準）；**不接受白名單**：收據
//       `scans.text_occlusion.flagged` 必為空（design-evidence-check.sh）。Scrim／Sheet 不在預設 OVERLAY_RE：modal 層蓋住底稿
//       是刻意的 z-order（VR R1 就是先扣掉這類才得到真實遮蔽 3 筆；含進去時每張 sheet 板的 Status Bar 時間都會被報），要看
//       全貌自行覆寫 `SCAN_OVERLAY_RE`。
//   (f) board_clip（LS-185，第六支）：root frame 有 `clip:true` 的板（真實稿 153 張畫面板都是；`cmp/*` 元件定義根不 clip、不掃），
//       其後代**可見節點**（快照 `image:true` 的節點不論有無子節點都以自身 AABB 參與——照片是帶 image fill 的 frame／rectangle，
//       Photo Wrap／Thumb 這種帶子標籤的照片框伸出板外時子標籤可能仍在板內，merge-review R1 minor-2；其餘只算沒有 live 子節點且
//       type 為 text／icon／path／rectangle／ellipse 的葉節點）的矩形超出 root 邊界 > TOL（0.5，沿 row_overflow 的邊緣允差；不用 text_occlusion 的面積
//       > 0，那對邊緣裁切會把版面捨入的 0.01pt 也報）即報 `{board, node, overflow_px, side}`——side 取四邊中溢出最大者
//       （top／left／bottom／right），overflow_px 為該邊的量。節點矩形先 ∩ root **以下**的 `clip:true` 祖先（同第五支的可見
//       矩形慣例）——精確條件：中間 clip 祖先只把可見區域縮成「節點 AABB ∩ 該祖先 AABB」，可見區域為空（被整個裁掉，LS-142 上傳
//       佇列 List 在 Footer 上方結束的形狀）才不報；**若該祖先本身伸出 root，其內、板外的節點仍以 root 裁切判定＝照報**。LS-177 R2
//       `y7KAW` Content（`y=−671, h=1213, clip:true`，掛在無 clip 的 Body 下）就**不是**不報的例子：Content 自身伸出板頂約 600pt，
//       裡面位於板外的 Header／列文字全會報——捲動模擬的正確做法是「板尺寸的 clip 視窗＋內層長欄」，不是把長欄本身設 clip
//       （merge-review R1 minor-1）。名稱命中 OVERLAY_RE 的節點及其子樹不算（固定覆蓋層
//       本身伸出板外是常態；root 自己的名字不參與比對）。LS-120 R2 六個 spacer 把 `Card Diary 1`／`Load More` 推出板外被 clip、
//       LS-177 R2 「Header Row 移到 y=−770 捲離畫面」都是四支＋第五支結構上抓不到、reviewer 用板矩形對葉節點才抓到的類別
//       （LS-96 池項 83392d32）。**範圍同 corner_anchor**：`flagged` 只算 `boards` 內、全稿另列 `document_flagged`；收據
//       `scans.board_clip.flagged` 必為空（design-evidence-check.sh；不接受白名單——刻意出血請把元素包進與板同尺寸的 `clip:true`
//       容器，結構上宣告裁切意圖），`document_flagged` 每筆給 classification，刻意出血的他票板用固定字面 `intentional_bleed`。
//       **不做旋轉換算**：`ctx.bounds` 對旋轉節點回的已是旋轉後包絡框（LS-120 R4／R5 覆核到 0.01pt，LS-96 `4d8ce8dd`／`596d3bca`
//       撤回旋轉盲點），任何一支都不得再套旋轉公式。
//   scan_scope（LS-185）：SUMMARY 與 `scanAll` 輸出頂層 `scan_scope`＝`document`（預設，全稿快照）或 `boards`（Pencil 端
//       `SCAN_SCOPE = "boards"`／node `opts.scanScope`：快照先限縮到 SCAN_BOARDS 的子樹再跑六支，沒有 SCAN_BOARDS 會 throw），
//       每支輸出各帶同值 `scope`。目的是讓收據分得清 `document_*`／各支 flagged 是全稿數字還是限縮板的數字——LS-120 R3／R4 逐板
//       `Get(boardId)` 繞過逾時後 `corner_anchor.document_*` 塌縮成 boards 值、LS-177 R1／R2 `cross_parent_collision` 限縮 17 板，
//       收據語意都靠 scan_note 文字自述（VR MJ-9／MN-5；LS-96 `83694378`）。設計端在 `boards` 模式下 `document_*` 就是限縮值，
//       收據照印、不得改標成 `document`。
//   大稿分段跑法（LS-185 記錄；LS-177 R1 handoff bcfa06d5、LS-120 R6 `767eb2cb`）：9416 節點級的稿單次 execute 連雜湊帶六支
//       會 `InternalError: interrupted`，且**間歇發生**（同一 snippet 原樣重送第二次常成功）——跟 snippet 內 O(n²) 配對的絕對
//       大小與 O(n·depth) 陣列累加寫法相關，不是節點數門檻。實跑可用的手法：①雜湊拆段——`SCAN_HASH_ONLY` 一趟仍逾時時，
//       依 Get 走訪 index 把全樹切成 9 段（前 4 段各 1500 節點、中 4 段各 750、末段 416），每段一次唯讀 execute 算 FNV-1a 64
//       局部和（同 `addLimbs`），shell 端 python 對 9 個局部和 mod 2^64 相加，結果與 `design_tree_hash.py` 單次全稿逐位元相同
//       （`01ed2a473acf4ddd`）；重算時先用一次便宜的 index 查詢確認改動節點落在哪段，只重算那幾段。②六支分函式——
//       sibling_intersection＋row_overflow 一趟、corner_anchor＋text_occlusion＋board_clip 一趟、cross_parent_collision 單獨一趟
//       （本票起已先過濾 BLEED_RE 候選再配對候選×其餘，配對數由 n²/2 降到 |候選|·n，結果集逐位元不變），仍逾時就
//       `SCAN_SCOPE = "boards"` 限縮並在收據如實標 `scope`。所有趟次都必須是同一稿態、中間無任何寫入（LS-168「單次掃描」定義）。
//   tree_hash（LS-168，收據新鮮度）：未展開 instance 的全樹（與 total_nodes 同一次走訪）每節點一行
//       `<父 id>\t<index>\t<canon(node 去掉 children)>`（canon＝鍵排序、無空白 JSON、數字用 JS Number#toString），每行 UTF-8
//       做 FNV-1a 64 後逐行相加 mod 2^64（順序無關、不用排序），印在 SUMMARY 與收據 `tree_hash`（16 碼 hex）。
//       design-evidence-check.sh 用 scripts/gates/design_tree_hash.py 對 `head_sha` 那份 .pen 算同一演算法比對——不符即
//       「收據不是對這份 .pen 單一次掃描」（LS-152 r1 兩段拼接、LS-142 r4 拆段跑，gate 原本全盲）。Pencil execute 沒有
//       crypto，所以用 FNV-1a 而非 SHA-256；`SCAN_HASH_DEBUG = "<節點 id>"` 會 Print 該節點那一行，與 .py `--dump <id>` 對照。
//       **LS-171**：雜湊走訪必須 `Get(visit, {includePathGeometry: true})`——Pencil `Get` 預設把 path 節點的 `geometry` 省略成
//       字面字串 `"..."`（LS-152 VR R3 三方比對 6383b2fa：py＝js `03e7804b035d8e4b`、Pencil 不帶選項 `84420d7b6419b40e`，把磁碟
//       JSON 的 8 個 geometry 改成 `"..."` 即重現；帶選項後三方同值），且 `cmp/Photo Corner` 全專案共用，漏帶就對所有含 path
//       的稿 fail-closed。空字串 geometry（`mzo0K`）兩端都是 `""`，原樣參與雜湊。overflow-scan.test.js 以原始碼斷言釘住這個選項。
//       盲區：只證明「收據對應這份 .pen 的節點樹」（`children` 全樹；頂層 `variables`／`themes`／`fileToken` 不在雜湊內——
//       Pencil `Get` 只走節點樹，掃描後只改 design token 再落地看不到，merge-review R1 N4），不證明五支數字算對（那要 CI 跑 Pencil）。
// 輸出每筆都帶 name／parent 等欄位方便分類；design-evidence-check.sh 只驗 node／node_a／node_b／classification、
// corner_anchor 的整數計數與 boards、text_occlusion.flagged 與 board_clip.flagged 為空、scan_scope 合法、tree_hash，多出的欄位
// 不影響 gate。

const AREA_MIN = 4;
const TOL = 0.5;
const CORNER_OUT = 5;
const CORNER_RE = /\bCorner (TL|TR|BL|BR)\b/;
const BLEED_RE = /Corner|Badge|Dragging Photo|Drop Target|Insert Line|Stack Sheet/i;
const OVERLAY_RE = /Action Bar|Tab Bar|Capsule|Footer|Toast|Banner/;
// 第六支的可見葉節點型別（.pen 實測型別集：frame／text／ref／icon／rectangle／note／path／ellipse；frame 只有帶 image fill 才算）
const LEAF_TYPE_RE = /^(text|icon|path|rectangle|ellipse)$/;
const SCAN_SCOPES = ["document", "boards"];

function hasImageFill(fill) {
  const one = (f) => !!f && typeof f === "object" && f.type === "image" && f.enabled !== false;
  return Array.isArray(fill) ? fill.some(one) : one(fill);
}

function resolveOverlayRe(opts) {
  return opts && opts.overlayRe ? (opts.overlayRe instanceof RegExp ? opts.overlayRe : new RegExp(String(opts.overlayRe))) : OVERLAY_RE;
}

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
    // LS-185（LS-96 32754383）：預設只報「任一側命中 BLEED_RE」的對，所以先把候選挑出來，只配對候選×其餘、不再全配對後才過濾
    // ——配對數 n²/2 → |候選|·n（真實稿 15359 個展開節點裡候選是少數）。走訪順序仍是 (i, j) 字典序、a＝arr[i]、b＝arr[j]，
    // 輸出與全配對版逐位元相同（overflow-scan.test.js 以舊實作對跑）；`crossAll` 時人人都是候選＝原本的全配對。
    const cand = [];
    const isCand = new Array(arr.length);
    for (let i = 0; i < arr.length; i++) {
      isCand[i] = all || BLEED_RE.test(arr[i].name || "");
      if (isCand[i]) cand.push(i);
    }
    const check = (i, j) => {
      const a = arr[i], b = arr[j];
      if (a.parent === b.parent) return;
      if (overlapArea(a, b) <= AREA_MIN) return;
      const ca = chain.get(a.id), cb = chain.get(b.id);
      if (ca.includes(b.id) || cb.includes(a.id)) return;
      if (coveredByParent(a, b, cb) || coveredByParent(b, a, ca)) return;
      flagged.push(pairEntry(a, b, { parent_a: a.parent, parent_b: b.parent, board, board_name: boardName }));
    };
    let ci = 0;
    for (let i = 0; i < arr.length; i++) {
      while (ci < cand.length && cand[ci] <= i) ci++;
      if (isCand[i]) {
        for (let j = i + 1; j < arr.length; j++) check(i, j);
      } else {
        for (let k = ci; k < cand.length; k++) check(i, cand[k]);
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

function scanTextOcclusion(nodes, idx, opts) {
  const { byId, liveNodes, chain, roots } = idx || buildIndex(nodes);
  const re = resolveOverlayRe(opts);
  const boards = resolveBoards(opts && opts.boards, roots);
  const scoped = boards.length > 0;
  const order = new Map();
  nodes.forEach((n, i) => order.set(n.id, i));
  const texts = new Map();
  const overlays = new Map();
  for (const n of liveNodes) {
    const c = chain.get(n.id);
    const board = c[c.length - 1];
    if (n.type === "text") {
      if (!texts.has(board)) texts.set(board, []);
      texts.get(board).push(n);
    } else if (re.test(n.name || "")) {
      if (!overlays.has(board)) overlays.set(board, []);
      overlays.get(board).push(n);
    }
  }
  // text 的可見矩形＝自身 AABB ∩ 所有 `clip:true` 祖先（捲動容器裁掉的部分不算被蓋——LS-142 16 上傳佇列的列捲到 Footer 底下
  // 是被 list 裁掉、不是被 Footer 蓋；Pencil 的 bounds 本身不裁切，所以要自己算）
  function visibleRect(t) {
    let r = { x: t.x, y: t.y, w: t.w, h: t.h };
    for (const aid of chain.get(t.id).slice(1)) {
      const a = byId.get(aid);
      if (!a || a.clip !== true) continue;
      const x1 = Math.max(r.x, a.x), y1 = Math.max(r.y, a.y);
      const x2 = Math.min(r.x + r.w, a.x + a.w), y2 = Math.min(r.y + r.h, a.y + a.h);
      r = { x: x1, y: y1, w: Math.max(0, x2 - x1), h: Math.max(0, y2 - y1) };
    }
    return r;
  }
  const out = { boards, flagged: [], document_flagged: [] };
  for (const [board, ts] of texts) {
    const os = overlays.get(board) || [];
    if (!os.length) continue;
    const boardName = byId.get(board).name;
    const inScope = !scoped || boards.includes(board);
    for (const t of ts) {
      const ct = chain.get(t.id);
      const v = visibleRect(t);
      if (!(v.w > 0 && v.h > 0)) continue;
      const hits = os.filter((o) => !ct.includes(o.id) && order.get(o.id) > order.get(t.id) && overlapArea(v, o) > 0);
      for (const o of hits) {
        const co = chain.get(o.id);
        if (hits.some((p) => p !== o && co.includes(p.id))) continue;
        const entry = {
          node: t.id, name: t.name, parent: t.parent, overlay: o.id, overlay_name: o.name, board, board_name: boardName,
          overlap: [r2(Math.min(v.x + v.w, o.x + o.w) - Math.max(v.x, o.x)), r2(Math.min(v.y + v.h, o.y + o.h) - Math.max(v.y, o.y))],
        };
        out.document_flagged.push(entry);
        if (inScope) out.flagged.push(entry);
      }
    }
  }
  return out;
}

// (f) LS-185 第六支：可見葉節點伸出有 clip 的 root frame 邊界（語意見檔頭）
function scanBoardClip(nodes, idx, opts) {
  const { byId, liveNodes, kids, chain, roots } = idx || buildIndex(nodes);
  const re = resolveOverlayRe(opts);
  const boards = resolveBoards(opts && opts.boards, roots);
  const scoped = boards.length > 0;
  const out = { boards, flagged: [], document_flagged: [] };
  for (const n of liveNodes) {
    if (n.parent == null) continue;
    // 可見節點：帶 image fill 的節點不論有無子節點都以自身 AABB 參與（merge-review R1 minor-2：Photo Wrap／Thumb＋Video Badge 這種
    // 「照片框帶子標籤」伸出板外時，子標籤在板內、框本身卻沒人報）；其餘只算沒有 live 子節點的 text／icon／path／rectangle／ellipse
    const isLeaf = !(kids.get(n.id) || []).length;
    if (!(n.image === true || (isLeaf && LEAF_TYPE_RE.test(n.type || "")))) continue;
    const c = chain.get(n.id);
    const root = byId.get(c[c.length - 1]);
    if (root.clip !== true) continue;
    // 名稱命中 OVERLAY_RE 的節點及其子樹不算（root 自己的名字不比對——板名含 Banner 不該讓整板免掃）
    if (c.slice(0, -1).some((id) => re.test(byId.get(id).name || ""))) continue;
    // 可見矩形：∩ root 以下的 clip:true 祖先——被中間 clip 容器整個裁掉的是捲動模擬，不是被板裁掉
    let r = { x: n.x, y: n.y, w: n.w, h: n.h };
    for (const aid of c.slice(1, -1)) {
      const a = byId.get(aid);
      if (!a || a.clip !== true) continue;
      const x1 = Math.max(r.x, a.x), y1 = Math.max(r.y, a.y);
      const x2 = Math.min(r.x + r.w, a.x + a.w), y2 = Math.min(r.y + r.h, a.y + a.h);
      r = { x: x1, y: y1, w: Math.max(0, x2 - x1), h: Math.max(0, y2 - y1) };
    }
    if (!(r.w > 0 && r.h > 0)) continue;
    const over = { top: root.y - r.y, left: root.x - r.x, bottom: r.y + r.h - (root.y + root.h), right: r.x + r.w - (root.x + root.w) };
    let side = null, max = TOL;
    for (const s of ["top", "left", "bottom", "right"]) if (over[s] > max) { max = over[s]; side = s; }
    if (!side) continue;
    const entry = { board: root.id, board_name: root.name, node: n.id, name: n.name, parent: n.parent, type: n.type, overflow_px: r2(max), side };
    out.document_flagged.push(entry);
    if (!scoped || boards.includes(root.id)) out.flagged.push(entry);
  }
  return out;
}

// scan_scope=boards：把快照限縮到 boards 子樹（root id 由 resolveBoards 解好）再跑六支
function restrictToBoards(nodes, boardIds) {
  const keep = new Set(boardIds);
  const byId = new Map(nodes.map((n) => [n.id, n]));
  const rootOf = (n) => {
    let cur = n;
    while (cur && cur.parent != null && byId.has(cur.parent)) cur = byId.get(cur.parent);
    return cur ? cur.id : null;
  };
  return nodes.filter((n) => keep.has(rootOf(n)));
}

// ---- tree_hash：canon／FNV-1a 64（無 BigInt，16 位元 limb）／逐行相加。與 scripts/gates/design_tree_hash.py 同規格 ----
function canon(v) {
  if (v === null || v === undefined) return "null";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") return Number.isFinite(v) ? String(v) : (v !== v ? "NaN" : (v > 0 ? "Infinity" : "-Infinity"));
  if (typeof v === "string") return JSON.stringify(v);
  if (Array.isArray(v)) return "[" + v.map(canon).join(",") + "]";
  if (typeof v === "object") {
    const keys = Object.keys(v).filter((k) => v[k] !== undefined).sort();
    return "{" + keys.map((k) => JSON.stringify(k) + ":" + canon(v[k])).join(",") + "}";
  }
  return JSON.stringify(v);
}

function canonNode(node, parentId, index) {
  const body = {};
  for (const k of Object.keys(node)) if (k !== "children") body[k] = node[k];
  return (parentId == null ? "" : parentId) + "\t" + index + "\t" + canon(body);
}

function utf8Bytes(str) {
  const out = [];
  for (let i = 0; i < str.length; i++) {
    let c = str.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
      const d = str.charCodeAt(i + 1);
      if (d >= 0xdc00 && d <= 0xdfff) { c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00); i++; }
    }
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
    else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
  }
  return out;
}

// 64 位元以四個 16 位元 limb 表示（低→高）；prime 0x100000001b3 = 2^40 + 0x1b3
function fnv1a64(str) {
  let h0 = 0x2325, h1 = 0x8422, h2 = 0x9ce4, h3 = 0xcbf2;
  for (const b of utf8Bytes(str)) {
    h0 ^= b;
    const t0 = h0 * 0x1b3;
    const t1 = h1 * 0x1b3 + (t0 >>> 16);
    const t2 = h2 * 0x1b3 + (t1 >>> 16) + ((h0 << 8) & 0xffff);
    const t3 = h3 * 0x1b3 + (t2 >>> 16) + (h0 >>> 8) + ((h1 & 0xff) << 8);
    h0 = t0 & 0xffff; h1 = t1 & 0xffff; h2 = t2 & 0xffff; h3 = t3 & 0xffff;
  }
  return [h0, h1, h2, h3];
}

function hex64(limbs) {
  return limbs.slice().reverse().map((l) => ("0000" + l.toString(16)).slice(-4)).join("");
}

function addLimbs(acc, limbs) {
  let carry = 0;
  for (let i = 0; i < 4; i++) {
    const s = acc[i] + limbs[i] + carry;
    acc[i] = s & 0xffff;
    carry = s >>> 16;
  }
  return acc;
}

function treeHash(lines) {
  const acc = [0, 0, 0, 0];
  for (const line of lines) addLimbs(acc, fnv1a64(line));
  return hex64(acc);
}

// 從 .pen JSON 文件（未展開 instance）產生 tree_hash 的行；Pencil 端由 Get 走訪產生同樣的行（見檔尾）
function treeHashLines(doc) {
  const lines = [];
  const walk = (n, pid, i) => {
    lines.push(canonNode(n, pid, i));
    (n.children || []).forEach((c, j) => walk(c, n.id, j));
  };
  (doc.children || []).forEach((c, j) => walk(c, null, j));
  return lines;
}

function scanAll(nodes, opts) {
  const scope = opts && opts.scanScope != null ? String(opts.scanScope) : "document";
  if (!SCAN_SCOPES.includes(scope)) throw new Error("overflow-scan：scanScope 只接受 " + SCAN_SCOPES.join("|") + "（收到 " + JSON.stringify(scope) + "）");
  let scanned = nodes;
  if (scope === "boards") {
    const ids = resolveBoards(opts && opts.boards, nodes.filter((n) => n.parent == null));
    if (!ids.length) throw new Error("overflow-scan：scanScope=boards 需要非空 boards（Pencil 端在 snippet 第一行加 SCAN_BOARDS=[...]），否則限縮範圍是空的");
    scanned = restrictToBoards(nodes, ids);
    if (!scanned.length) throw new Error("overflow-scan：scanScope=boards 但 boards " + JSON.stringify(ids) + " 沒有對應到任何 root——限縮後快照為空，不得默默印全零收據");
  }
  const idx = buildIndex(scanned);
  const tag = (o) => Object.assign({ scope }, o);
  return {
    scanned_nodes: scanned.length,
    scan_scope: scope,
    scans: {
      sibling_intersection: tag(scanSiblingIntersection(scanned, idx)),
      row_overflow: tag(scanRowOverflow(scanned, idx)),
      cross_parent_collision: tag(scanCrossParentCollision(scanned, idx, opts)),
      corner_anchor: tag(scanCornerAnchor(scanned, idx, opts)),
      text_occlusion: tag(scanTextOcclusion(scanned, idx, opts)),
      board_clip: tag(scanBoardClip(scanned, idx, opts)),
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
  const tx = s.text_occlusion;
  const to = agg(tx.flagged, (f) => f.name + " × " + f.overlay_name + " @ " + f.board_name + "(" + f.board + ")", (f) => f.node + "×" + f.overlay);
  const tl = ["SCAN text_occlusion boards=" + JSON.stringify(tx.boards) + " flagged=" + tx.flagged.length + " classes=" + to.length + " document=" + tx.document_flagged.length]
    .concat(to.map(([k, v]) => "  " + v.n + "× " + k + " e.g. " + v.ex));
  for (const [k, v] of agg(tx.document_flagged.filter((f) => !tx.flagged.includes(f)), (f) => f.board_name + "(" + f.board + ")", (f) => f.node + "×" + f.overlay)) tl.push("  DOCUMENT " + v.n + "× board " + k + " e.g. " + v.ex);
  blocks.push(tl.join("\n"));
  const bc = s.board_clip;
  const bcRows = agg(bc.flagged, (f) => f.name + " " + f.side + " @ " + f.board_name + "(" + f.board + ")", (f) => f.node + " (+" + f.overflow_px + ")");
  const bl = ["SCAN board_clip boards=" + JSON.stringify(bc.boards) + " flagged=" + bc.flagged.length + " classes=" + bcRows.length + " document=" + bc.document_flagged.length]
    .concat(bcRows.map(([k, v]) => "  " + v.n + "× " + k + " e.g. " + v.ex));
  for (const [k, v] of agg(bc.document_flagged.filter((f) => !bc.flagged.includes(f)), (f) => f.board_name + "(" + f.board + ")", (f) => f.node + " " + f.side + " (+" + f.overflow_px + ")")) bl.push("  DOCUMENT " + v.n + "× board " + k + " e.g. " + v.ex);
  blocks.push(bl.join("\n"));
  return blocks;
}

if (typeof Get === "function" && typeof Print === "function") {
  const scope = typeof SCAN_BOARDS !== "undefined" && Array.isArray(SCAN_BOARDS) ? SCAN_BOARDS : [];
  const crossAll = typeof SCAN_CROSS_ALL !== "undefined" && SCAN_CROSS_ALL === true;
  const verbose = typeof SCAN_VERBOSE !== "undefined" && SCAN_VERBOSE === true;
  const overlayRe = typeof SCAN_OVERLAY_RE !== "undefined" && SCAN_OVERLAY_RE ? SCAN_OVERLAY_RE : undefined;
  const hashDebug = typeof SCAN_HASH_DEBUG !== "undefined" && SCAN_HASH_DEBUG ? String(SCAN_HASH_DEBUG) : "";
  const hashOnly = typeof SCAN_HASH_ONLY !== "undefined" && SCAN_HASH_ONLY === true;
  const skipHash = typeof SCAN_SKIP_HASH !== "undefined" && SCAN_SKIP_HASH === true;
  const scanScope = typeof SCAN_SCOPE !== "undefined" && SCAN_SCOPE ? String(SCAN_SCOPE) : "document";
  if (hashOnly && skipHash) throw new Error("overflow-scan：SCAN_HASH_ONLY 與 SCAN_SKIP_HASH 互斥——第一次只設 SCAN_HASH_ONLY（雜湊），第二次只設 SCAN_SKIP_HASH（五支）；同時設會既不算雜湊也不跑五支（LS-171 R1 N4）");
  let total = 0;
  const hashAcc = [0, 0, 0, 0];
  // LS-171：includePathGeometry 必帶——Pencil Get 預設把 path 的 geometry 省略成 "..."，雜湊會與 js／py 不同（見檔頭）
  Get((n, c) => {
    total++;
    if (skipHash) return;
    const line = canonNode(n, c.parentCtx ? c.parentCtx.node.id : null, c.index);
    addLimbs(hashAcc, fnv1a64(line));
    if (hashDebug && n.id === hashDebug) Print("HASHLINE " + line);
  }, { includePathGeometry: true });
  const treeHashHex = skipHash ? "skipped" : hex64(hashAcc);
  if (hashOnly) {
    Print("SUMMARY-HASH total_nodes=" + total + " tree_hash=" + treeHashHex);
  } else {
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
    snap.push({ id: n.id, name: n.name || "", parent: pid, type: n.type || "", enabled: n.enabled !== false, clip: n.clip === true, image: hasImageFill(n.fill), x: a.x, y: a.y, w: b.width, h: b.height });
  }, { resolveInstances: true });
  const out = scanAll(snap, { boards: scope, crossAll, overlayRe, scanScope });
  out.total_nodes = total;
  out.tree_hash = treeHashHex;
  const s = out.scans;
  if (scope.length === 0) Print("WARNING SCAN_BOARDS 未設定：corner_anchor 以全稿計 mismatch，收據 gate 會因 boards 為空而紅——在本 snippet 第一行加 SCAN_BOARDS=[...] 再重跑（跨 execute 的全域不保留）");
  Print(
    "SUMMARY total_nodes=" + total + " scanned_nodes=" + out.scanned_nodes + " scan_scope=" + out.scan_scope +
      " sibling_intersection=" + s.sibling_intersection.flagged.length +
      " row_overflow=" + s.row_overflow.flagged.length +
      " cross_parent_collision=" + s.cross_parent_collision.flagged.length + (crossAll ? "(all)" : "(bleed-only)") +
      " text_occlusion=" + s.text_occlusion.flagged.length + "/" + s.text_occlusion.document_flagged.length + (overlayRe ? "(custom-re)" : "") +
      " board_clip=" + s.board_clip.flagged.length + "/" + s.board_clip.document_flagged.length +
      " corner_anchor=" + s.corner_anchor.containers + "/" + s.corner_anchor.points + "/" + s.corner_anchor.mismatch +
      " document=" + s.corner_anchor.document_containers + "/" + s.corner_anchor.document_points + "/" + s.corner_anchor.document_mismatch +
      " unresolved=" + s.corner_anchor.unresolved.length + " boards=" + JSON.stringify(s.corner_anchor.boards) +
      " tree_hash=" + treeHashHex
  );
  for (const block of compactLines(out)) Print(block);
  if (verbose) for (const key of Object.keys(s)) Print("JSON " + key + " " + JSON.stringify(s[key]));
  }
} else if (typeof module === "object" && module && module.exports) {
  module.exports = { AREA_MIN, TOL, CORNER_OUT, CORNER_RE, BLEED_RE, OVERLAY_RE, LEAF_TYPE_RE, SCAN_SCOPES, hasImageFill, buildIndex, overlapArea, contains, cornerExpected, compactLines, pairEntry, scanSiblingIntersection, scanRowOverflow, scanCrossParentCollision, scanCornerAnchor, scanTextOcclusion, scanBoardClip, restrictToBoards, scanAll, canon, canonNode, fnv1a64, hex64, addLimbs, treeHash, treeHashLines };
} else {
  throw new Error("overflow-scan：既不是 Pencil execute（無 Get／Print）也不是 node module 環境，無處輸出");
}
