// LS-122：設計收工溢出掃描——正典腳本（取代 ui-designer／visual-reviewer 每輪臨場手寫的 JS）；四支（LS-122）→ 第五支
// text_occlusion（LS-168）→ 第六支 board_clip＋收據 scan_scope＋cross_parent_collision 候選過濾（LS-185）→ corner_anchor 角托
// 候選改 `ref → cmp/Photo Corner` 判準＋六支各帶 `scope`／`document_count`（LS-202）。
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
//      路徑）、算絕對座標、跑六支掃描，`Print`：一行 SUMMARY ＋ 每支掃描一段**分類彙整**（同名對／同容器歸一類：
//      `<n>× <name_a> × <name_b> @ <parent> e.g. <idA>×<idB>`，corner_anchor 的 in-scope 錯位與 unresolved 逐筆、
//      document 錯位按板計數）——真實稿的完整 JSON 有 26 萬字元、超過 MCP 回應上限（R6 實跑），所以預設不印；要完整
//      陣列時設 `SCAN_VERBOSE = true`（每支掃描一個 Print，仍可能被轉存成檔案；另逐容器印 `CORNERS <容器> n=<角托數>`，LS-202）。`total_nodes` 用**未展開 instance**
//      的走訪計數（與 design-landing-check.sh --print-nodes／pen-land.sh 同一語意），`scanned_nodes` 才是展開後實際掃過
//      的節點數。設計端依彙整段寫 `design/evidence/<票號>-r<n>-overflow.json`：每類一筆代表（e.g. 的 id）＋
//      `classification`（含「同類 N 例」），補 `ticket`／`round`／`head_sha`，`tree_hash` 抄 SUMMARY 的值（LS-168；見
//      ui-designer.md）。`SCAN_OVERLAY_RE = "Action Bar|…"`（字串）覆寫第五支的覆蓋層名稱，`SCAN_HASH_DEBUG = "<id>"` 印
//      該節點的雜湊行。`SCAN_HASH_ONLY = true` 只跑雜湊走訪、印 `SUMMARY-HASH total_nodes=… tree_hash=…`；`SCAN_SKIP_HASH = true`
//      跑六支不算雜湊，**必須同時帶 `SCAN_TREE_HASH = "<第一趟的 16 碼 tree_hash>"`**（LS-226：result_hash 綁 tree_hash，沒帶就 throw；
//      兩旗標同時設會 throw）——這是 LS-171 的兩趟舊法（同一稿態、中間無任何寫入的連續兩次唯讀 execute）；9000 節點級的稿改用
//      下方 1b 的**分批模式**，一趟 execute 只做一批 root、不再逾時。`SCAN_SCOPE = "boards"`（LS-185）把快照限縮到 SCAN_BOARDS 子樹
//      再跑六支，SUMMARY 與收據 `scan_scope` 如實標 `boards`（預設 `document`＝全稿；見下方 scan_scope 段）。不分批時 SCAN 段之後另印
//      一行 `RESULT-JSON {…}`＝收據形狀的完整 JSON（見下方「收據形狀」段；含六支 `result_hash`），設計端照抄進收據再補 `ticket`／
//      `round`／`head_sha`／`scan_note` 與每筆代表的 `classification`。
//   1b. 分批模式（LS-226，取代 LS-171／LS-185 的手工拆段）：snippet 第一行加 `SCAN_BATCH = <k>`（1 起算的批號；每批 root 數預設
//      DEFAULT_BATCH_SIZE=20，`SCAN_BATCH_SIZE = <n>` 覆寫）或 `SCAN_BATCH_ROOTS = [lo, hi]`（明確的全稿 root 序範圍 [lo,hi)——某批太重
//      時只把那一段再切小、不必重跑其他批），每次 execute 只做那一批：① 一趟全稿**未展開**走訪（不在本批的 root `skipChildren`）收全部
//      root 的 AABB／名稱／enabled＋本批 root 子樹的 tree_hash 局部和 `hash_part`／未展開節點數 `total_nodes`／refMap；② 本批每個 root
//      各一趟 `Get(rootId, visit, {resolveInstances:true})` 收展開快照（scope=boards 時只展開 SCAN_BOARDS 內的 root）；③ 其餘 root 以
//      **裸節點**放進快照（root 層兩板相鄰的 sibling 配對才算得到、板名解析才看得到全部板），六支只以本批 root 子樹內的節點當主節點
//      （scanAll `opts.batch` → `primaryRoots`）——除 root 層 sibling 外六支的配對都不跨板，所以各批依 root 序串接＝不分批的結果，
//      跨批配對由腳本自己算、不會漏（overflow-scan.test.js 釘住 K=1…7 與裸 root 快照逐位元相同＋拿掉裸 root 的 mutation 少配對）。
//      Print：`SUMMARY-BATCH …`、`TIMING …`、`BATCH-JSON {…}`（收據形狀，另帶 `batch.roots`／`batch.root_count`／`hash_part`／各支
//      `result_hash_part`）。把每批的 execute 輸出原文各存一檔，node 端 `node scripts/design/overflow-scan.js --merge <批檔…> --out
//      <merged.json>` 驗各批 root 範圍首尾相接、蓋滿 `[0, root_count)`、同一稿態參數一致，六支合併（三支 O(n²) 以 class 鍵合併 count、
//      其餘陣列串接、整數相加）、`tree_hash`＝各批 `hash_part` mod 2^64 相加、每支 `result_hash`＝各批局部和＋標頭三行，stderr 印與
//      不分批同格式的 SUMMARY／WARNING／SCAN 段、stdout（或 --out）印最終單一 JSON。LS-208 head（9899 節點／231 root）實跑：19 批、
//      每批 execute 約 1.5–4 s（全稿走訪固定 ~1.2–2.3 s＋本批展開走訪＋六支 <0.5 s），合併結果與 r6 收據六支 document_count／
//      tree_hash／total_nodes／ref_hits／unresolved 逐欄相同（.claude/evidence/LS-226/r1）。某批 `InternalError: interrupted`（間歇性）
//      先原樣重試一次、再不行就把 `SCAN_BATCH_ROOTS` 切小重跑那一段。分批期間不得寫入文件（各批必須同一稿態，tree_hash 對不上 CI 就紅）；
//      分批模式與 SCAN_HASH_ONLY／SCAN_SKIP_HASH 互斥、SCAN_BATCH 與 SCAN_BATCH_ROOTS 擇一。
//   2. node：`require` 本檔取得純函數（`scanAll` 與六支 `scan*`、`treeHash`／`treeHashLines`／`canonNode`、分批的 `batchRange`／
//      `mergeBatches`／`compactScans`／`withResultHashes`），`scripts/design/overflow-scan.test.js` 用合成節點樹驗演算法、並以 python
//      交叉驗 tree_hash／result_hash 同值；CI rules job 的自測 step 跑它。直接執行＝`--merge` CLI（見 1b；node 端環境變數
//      `SCAN_BATCH_SIZE` 覆寫 batchRange 的預設批大小）。掃描核心不碰 Pencil API，Pen 不在時也能驗。注意：.pen JSON 只存 root／absolute
//      節點的 x／y，layout 子節點的絕對座標要 Pencil 版面引擎才算得出——離線 node 能驗的是演算法與 tree_hash，不是真實稿的六支數字。
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
//   (d) corner_anchor：角托候選＝**ref 判準 ∪ 名稱備援**（LS-202；ref 判準真正生效見 LS-207）：`ref` 解析到 `cmp/Photo Corner`
//       的實例（元件 id 集合＝字面 PHOTO_CORNER_ID `GEBcf` ∪ 快照 roots 裡名稱為 `cmp/Photo Corner` 的元件定義——元件重建換 id
//       時名稱是備援；`SCAN_SCOPE=boards` 限縮快照沒有元件定義根時就只剩字面 id），**或**名稱命中 CORNER_NAME_RE `Corner TL/TR/BL/BR`
//       （LS-122 起的舊判準，票文「名稱只作備援」；merge-review R1 minor-1：Pencil `Get` 若讀不到 `n.ref`，只靠 ref 會讓第四支靜默歸零、
//       收據 `containers=0/mismatch=0` 全綠——備援保證最壞退回本票之前的行為；development 上「只在名稱判準」＝0，補回零代價）。
//       **LS-207 實測缺口**：`Get(visit, {resolveInstances:true})` 展開後的樹裡，實例根節點本身**沒有** `type:"ref"`／`n.ref`
//       （已被展開成子樹，LS-201 VR R2／R3 實測），LS-202 當時假設的 ref 判準因此在真實稿貢獻 0；改成另跑一次
//       `{resolveInstances:false}` 的快照，把每個 `type:"ref"` 節點的 `id → ref`（元件 id）收進對照表，再套到展開後那棵樹裡
//       同 id 的節點上（同一個實例根節點在兩次走訪 id 相同，只有它的子孫在展開版多出 `instanceId/childId` 複合 id；見檔尾
//       Pencil execute 區塊）——ref 判準補的是 `cmp/Profile Print`／App icon 的 `Mount TL/BR`（以 ref 存在、名稱不是 Corner …，
//       LS-194 VR：實測 corner-out 3.8pt 屬盲區，LS-96 `0617b9ae`）；`Mount TL/BR` 若恰為兩顆對角（`cmp/Profile Print` 樣式）
//       且找不到吻合紙面，`unresolved` 該筆會附 `classification: "mount_pair"` 分類（LS-207）。方位取自名稱 `/\b(TL|TR|BL|BR)\b/`
//       （`Corner TL`／`Mount BR` 都認得；無方位進 `unresolved`）；名稱不像角托、ref 也對不到已知元件 id 的節點不算。
//       **`ref_hits`**（LS-207）：獨立輸出「ref 判準命中節點數」（不論最終是否成一個合法容器），`ref_hits === 0` 是判準本身
//       沒接上的哨兵——與 `document_containers === 0`（判準接上了但一顆角托都沒有／全部落在 `unresolved`）分開看，因為後者
//       在 ref 判準失效、只剩名稱備援時仍可能非零（development 現稿名稱判準就有 220 個）。`document_containers === 0` 時
//       SUMMARY 後與 compactLines 各印 `⚠` 行：`scope=document`＝第四支停擺（design-evidence-check.sh 對這種收據紅、且該
//       cutoff 下 `document_containers` 必填）；`scope=boards` 只印提示（限縮快照可能真的沒有印品、判不出停擺，R3
//       minor-2）；`containers === 0` 而 document 非零只印提示（LS-133 r1–r3／LS-177 r1 的 boards 本來就沒有印品，屬正常）；
//       `ref_hits === 0` 時 `scope=document` 同樣是 design-evidence-check.sh 判紅的 cutoff（腳本含 `ref_hits` 欄位才驗，
//       舊收據沒有這個鍵就放行）。每個直接子節點含角托候選的節點是一個「容器」（角托的父）。角托咬住的**紙面**不一定是
//       父：現行稿有三種結構——角托是紙面的子（`Photo Wrap`）、角托與紙面 `Print` 是兄弟（`Print Stage`）、角托直接掛在
//       板上而紙面是兄弟 `Print`（iPad 板）。因此紙面由候選（父＋同 parent 的兄弟）中挑「與四顆角托期望位置吻合軸數最多」
//       者（吻合軸數 ≥ 一半才算找到；找不到列 `unresolved`，不計 mismatch、收據需給分類）。期望位置＝角托外緣壓過紙緣
//       `corner-out` 5pt（tokens.md `corner-out` 5；motifs.md「角托一律壓過紙緣 `corner-out` 5pt」）：
//         TL=(P.x−5, P.y−5)、TR=(P.x+P.w−cw+5, P.y−5)、BL=(P.x−5, P.y+P.h−ch+5)、BR=(P.x+P.w−cw+5, P.y+P.h−ch+5)
//       其中 cw／ch 是該顆角托**實測**寬高（merge-review R1 B1：不得假設 26——iPad 版有 40×40）。每顆角托 x／y 各一個斷言，
//       `points`＝斷言數，`mismatch`＝失敗數，允差 TOL。**範圍（orchestrator 裁定 a106f940）**：`mismatch`／`flagged`／
//       `containers`／`points`／`unresolved` 只算 `boards`（本票觸碰的板，SCAN_BOARDS）內的容器；全稿數字另列 `document_*`
//       （含 `document_unresolved`，LS-202——ref 判準把 41 個他票 `Mount` 容器帶進視野，若 `unresolved` 仍全稿計，每張後續收據都得替
//       它們逐筆分類）供參考、不擋 gate（他票舊債另開 chore）。角托錯位不接受白名單，收據 gate 要求 mismatch == 0
//       （design-evidence-check.sh）。`container_corners` 逐容器列角托數（SCAN_VERBOSE 印 `CORNERS` 行）。
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
//       每支輸出各帶同值 `scope` 與 `document_count`（LS-202：該支在**掃描快照**裡的命中數——有 `document_flagged` 的三支取其長度、
//       其餘三支取 `flagged` 長度。**`document_count` 不是永遠等於全稿數**：只設 SCAN_BOARDS 不限縮時快照＝全稿、它就是全稿數；
//       `scope=boards` 時快照已限縮、它就是限縮值（任何一支都看不到全稿——要全稿得掃兩次，違背限縮的目的），讀收據必須與該支
//       `scope` 併讀，`scope=boards` 的 `document_count` 不得拿去當全稿舊債基準（merge-review R1 info-1）。收據照抄——LS-177 R1／R2
//       `cross_parent_collision` 限縮 17 板時收據沒有任何欄位說明限縮外的數，LS-96 `ba1ec045`；design-evidence-check.sh 驗六支皆有
//       這兩個欄位）。目的是讓收據分得清 `document_*`／各支 flagged 是全稿數字還是限縮板的數字——LS-120 R3／R4 逐板
//       `Get(boardId)` 繞過逾時後 `corner_anchor.document_*` 塌縮成 boards 值、LS-177 R1／R2 `cross_parent_collision` 限縮 17 板，
//       收據語意都靠 scan_note 文字自述（VR MJ-9／MN-5；LS-96 `83694378`）。設計端在 `boards` 模式下 `document_*` 就是限縮值，
//       收據照印、不得改標成 `document`。
//   大稿分段跑法（歷史記錄，LS-226 起一律改用上方 1b 分批模式；LS-185 記錄；LS-177 R1 handoff bcfa06d5、LS-120 R6 `767eb2cb`）：9416 節點級的稿單次 execute 連雜湊帶六支
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
//   收據形狀（LS-226）：`RESULT-JSON`／`--merge` 的輸出＝收據本體。三支 O(n²)（sibling_intersection／row_overflow／cross_parent_collision）
//       的 `flagged` 只留「每類一筆代表」：`class`＝同名對／同容器鍵（sibling `name_a × name_b @ parent_name`、cross `… @ board_name`、
//       row `parent_name :: name`，與 SCAN 彙整段同一把鍵）、`count`＝同類筆數、`classes`＝類數，`document_count` 仍是全量；其餘三支的
//       `flagged`／`unresolved`／`document_*` 原樣完整。設計端補 `ticket`／`round`／`head_sha`／`scan_note`（必填，自述跑法與範圍）與每筆
//       代表的 `classification`（gate 驗非空；腳本不代寫）。
//   result_hash（LS-226，六支各一、收據必填）：對下列各行做 FNV-1a 64 後 mod 2^64 相加（同 tree_hash 的加總法，順序無關）的 16 碼 hex：
//       `scan=<支名>`、`scope=<頂層 scan_scope>`、`tree_hash=<收據 tree_hash>`、in-scope `flagged` 每筆一行 `flagged=<身分>`、corner_anchor
//       另對 in-scope `unresolved` 每筆一行 `unresolved=<container>`；身分＝sibling／cross `node_a|node_b`、row `node`、corner_anchor
//       `corner:axis`、text_occlusion `node|overlay`、board_clip `node`。三支 O(n²) 在壓成代表前對全量算（收據存代表、CI 不能重算，但同一
//       稿態重跑腳本必得同值）；corner_anchor／text_occlusion／board_clip 的 in-scope 陣列收據完整，design-evidence-check.sh 用
//       scripts/gates/design_tree_hash.py 同規格重算比對（fail-closed）——陣列被改過、hash 從別次掃描抄來、或 tree_hash 對不上都紅。
//       盲區：只證明「收據對應這份 .pen 的節點樹」（`children` 全樹；頂層 `variables`／`themes`／`fileToken` 不在雜湊內——
//       Pencil `Get` 只走節點樹，掃描後只改 design token 再落地看不到，merge-review R1 N4），不證明各支掃描的數字算對（那要 CI 跑 Pencil）。
// 輸出每筆都帶 name／parent 等欄位方便分類；design-evidence-check.sh 只驗 node／node_a／node_b／classification、
// corner_anchor 的整數計數與 boards、text_occlusion.flagged 與 board_clip.flagged 為空、scan_scope 合法、tree_hash，多出的欄位
// 不影響 gate。

const AREA_MIN = 4;
const TOL = 0.5;
const CORNER_OUT = 5;
// LS-202：角托＝ref 指向 cmp/Photo Corner 的實例（元件 id 為主、元件名稱備援）∪ 名稱命中 CORNER_NAME_RE（LS-122 舊判準，R2 minor-1 補回
// 作備援——Pencil 端 ref 讀不到時第四支不得靜默歸零）；方位取自名稱
const PHOTO_CORNER_ID = "GEBcf";
const PHOTO_CORNER_NAME = "cmp/Photo Corner";
const CORNER_NAME_RE = /\bCorner (TL|TR|BL|BR)\b/;
const CORNER_VARIANT_RE = /\b(TL|TR|BL|BR)\b/;
// LS-207：cmp/Profile Print／App icon 用 `Mount TL`／`Mount BR` 命名同一顆 cmp/Photo Corner 元件（對角兩顆，非四角托全套）；
// ref 判準接上後這些節點會被 isCorner 命中，但常找不到吻合紙面（版面結構與印品母題不同）——unresolved 該筆改附
// classification: "mount_pair" 分類，不當成未知失敗。
const MOUNT_NAME_RE = /\bMount (TL|TR|BL|BR)\b/;
const BLEED_RE = /Corner|Badge|Dragging Photo|Drop Target|Insert Line|Stack Sheet/i;
const OVERLAY_RE = /Action Bar|Tab Bar|Capsule|Footer|Toast|Banner/;
// 第六支的可見葉節點型別（.pen 實測型別集：frame／text／ref／icon／rectangle／note／path／ellipse；frame 只有帶 image fill 才算）
const LEAF_TYPE_RE = /^(text|icon|path|rectangle|ellipse)$/;
const SCAN_SCOPES = ["document", "boards"];
// LS-226：分批預設批大小（每批的頂層 root 數；SCAN_BATCH_SIZE 覆寫，見 defaultBatchSize）——依 LS-208 head（231 root／9899 節點／
// 16017 展開節點）實測調定：execute 沙盒約 2.5–6 秒 wall-clock 就會間歇 `InternalError: interrupted`（同長度有時過有時不過），
// 一批＝一次全稿 root 走訪（固定約 1.2–1.6 秒）＋本批板子的展開走訪＋雜湊＋六支，目標每批 ≤ 2–3 秒
const DEFAULT_BATCH_SIZE = 20;

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
  // LS-226：id → 在快照陣列的位置（pre-order＝繪製順序）；第五支的 z-order 比較與分批範圍 [lo,hi) 都用它
  const pos = new Map();
  nodes.forEach((n, i) => pos.set(n.id, i));
  return { byId, liveNodes, kids, chain, roots, pos };
}

function pairEntry(a, b, extra) {
  return Object.assign(
    { node_a: a.id, node_b: b.id, name_a: a.name, name_b: b.name },
    extra,
    { overlap: [r2(Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x)), r2(Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y))] }
  );
}

// LS-226 分批：opts.primaryRoots＝本批負責的 root id 集合——六支只處理「主節點」（配對的 a／i／text／容器／葉節點）的 root 落在集合內
// 的項目，配對對象不受限（同板的節點一定同批；root 層兩板相鄰的配對由 a 所在批補算，每對恰被順序較前的那一側算一次，見檔頭「分批模式」）
function primaryFilter(idx, opts) {
  const set = opts && opts.primaryRoots;
  if (!set) return null;
  return (n) => {
    const c = idx.chain.get(n.id);
    return set.has(c[c.length - 1]);
  };
}

function scanSiblingIntersection(nodes, idx, opts) {
  const index = idx || buildIndex(nodes);
  const { byId, liveNodes, kids } = index;
  const isPrimary = primaryFilter(index, opts);
  // LS-226：外層改以主節點 a 的快照位置為序（liveNodes 的順序＝pre-order），每個 a 只配對同父、排在它之後的兄弟 b——命中集合與
  // 舊的逐 parent 雙迴圈相同，輸出順序改為 (pos a, pos b) 字典序（舊寫法依 parent 群組出現序，父子群組會交錯），分批時各批依序
  // 串接才能與不分批逐位元相同（mergeBatches）
  const slot = new Map();
  for (const arr of kids.values()) arr.forEach((n, i) => slot.set(n.id, i));
  const flagged = [];
  for (const a of liveNodes) {
    if (isPrimary && !isPrimary(a)) continue;
    const pid = a.parent == null ? null : a.parent;
    const arr = kids.get(pid);
    const parent = pid == null ? null : byId.get(pid);
    for (let j = slot.get(a.id) + 1; j < arr.length; j++) {
      if (overlapArea(a, arr[j]) > AREA_MIN) {
        flagged.push(pairEntry(a, arr[j], { parent: pid, parent_name: parent ? parent.name : "root" }));
      }
    }
  }
  return { flagged };
}

function scanRowOverflow(nodes, idx, opts) {
  const index = idx || buildIndex(nodes);
  const { byId, liveNodes } = index;
  const isPrimary = primaryFilter(index, opts);
  const flagged = [];
  for (const n of liveNodes) {
    if (n.parent == null) continue;
    if (isPrimary && !isPrimary(n)) continue;
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
  const primaryRoots = opts && opts.primaryRoots ? opts.primaryRoots : null;
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
    if (primaryRoots && !primaryRoots.has(board)) continue;
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

// LS-202：角托元件 id 集合＝字面 GEBcf ∪ 快照 roots 裡名為 cmp/Photo Corner 的元件定義（元件重建換 id 時的名稱備援）；
// 限縮快照沒有元件定義根時就只剩字面 id
function cornerComponentIds(roots) {
  const ids = [PHOTO_CORNER_ID];
  for (const r of roots || []) if (r.name === PHOTO_CORNER_NAME && !ids.includes(r.id)) ids.push(r.id);
  return ids;
}

function scanCornerAnchor(nodes, idx, opts) {
  const index = idx || buildIndex(nodes);
  const { byId, liveNodes, kids, chain, roots } = index;
  const isPrimary = primaryFilter(index, opts);
  const boards = resolveBoards(opts && opts.boards, roots);
  const scoped = boards.length > 0;
  const cornerIds = cornerComponentIds(roots);
  // LS-207：ref 判準不再要求 n.type === "ref"——resolveInstances:true 展開後的樹裡實例根節點本身已不是 type:"ref"（LS-201
  // VR R2／R3 實測），判準只看 n.ref 有沒有解析到已知角托元件 id；ref 由呼叫端（node module 的合成快照，或 Pencil execute
  // 區塊用 resolveInstances:false 對照表回填，見檔尾）提供，這裡不管來源。名稱備援（R2 minor-1）保證 ref 讀不到時最壞退回
  // LS-122 的名稱判準，而不是 containers=0 全綠。
  const isCorner = (n) => (n.ref != null && cornerIds.includes(n.ref)) || CORNER_NAME_RE.test(n.name || "");
  // ref_hits（LS-207；R2 修 merge-review R1 fd783f6c F7）：ref 判準本身的哨兵——獨立於後面的容器／紙面比對，只數
  // 「有多少活節點的 ref 解析到角托元件 id」。===0 代表 ref 判準完全沒接上（快照沒有 ref 欄位，或對照表沒建成）；
  // 即使如此，名稱備援仍可能讓 document_containers 非零（development 現稿名稱判準本身就有 220 個），所以兩個
  // 哨兵要分開看。**只計實例層（排除 cmp/ 定義子樹）**：component 定義子樹（頂層 root 名稱以 `cmp/` 開頭）在
  // resolveInstances:false／true 兩次走訪的節點 id 都是原生 id，定義內部若剛好也有 ref 節點一定 join 得上、
  // 會把 ref_hits 撐成非零——但真正要接住的盲區是**板上的實例**（如 41 個 Mount 容器）的展開版複合 id
  // （instanceId/childId）對不上 refMap 的原生 id 鍵，這種情況下 ref_hits_instances 才會誠實地維持 0；純用
  // 「有沒有任何 ref 命中」當哨兵會被定義子樹的命中蓋掉、看不出實例層真的接上了沒。ref_hits_defs 另外輸出、
  // 純供人工核對用，不影響 gate 判定。
  let refHitsInstances = 0, refHitsDefs = 0;
  for (const n of liveNodes) {
    if (n.ref == null || !cornerIds.includes(n.ref)) continue;
    if (isPrimary && !isPrimary(n)) continue;
    const c = chain.get(n.id);
    const rootId = c && c.length ? c[c.length - 1] : null;
    const root = rootId != null ? byId.get(rootId) : null;
    if (root && typeof root.name === "string" && root.name.indexOf("cmp/") === 0) refHitsDefs++;
    else refHitsInstances++;
  }
  const refHits = refHitsInstances;
  const groups = new Map();
  for (const n of liveNodes) {
    if (!isCorner(n) || n.parent == null || !byId.get(n.parent)) continue;
    if (isPrimary && !isPrimary(n)) continue;
    const m = CORNER_VARIANT_RE.exec(n.name || "");
    if (!groups.has(n.parent)) groups.set(n.parent, []);
    groups.get(n.parent).push({ node: n, variant: m ? m[1] : null });
  }
  const out = {
    boards, containers: 0, points: 0, mismatch: 0, flagged: [], unresolved: [], ref_hits: refHits, ref_hits_defs: refHitsDefs,
    document_containers: 0, document_points: 0, document_mismatch: 0, document_flagged: [], document_unresolved: [], container_corners: [],
  };
  for (const [pid, corners] of groups) {
    const p = byId.get(pid);
    const c = chain.get(pid);
    const board = c[c.length - 1];
    const boardName = byId.get(board).name;
    const inScope = !scoped || boards.includes(board);
    const base = { container: pid, container_name: p.name, board, board_name: boardName, corners: corners.map((k) => k.node.id) };
    out.container_corners.push({ container: pid, container_name: p.name, board, board_name: boardName, n: corners.length, in_scope: inScope });
    // LS-207：Mount TL/BR 群（cmp/Profile Print／App icon 對角兩顆）先分類，不論最後在哪個判定點落到 unresolved
    const isMountPair = corners.length > 0 && corners.every((k) => MOUNT_NAME_RE.test(k.node.name || ""));
    const unresolved = (extra) => {
      const entry = Object.assign({}, base, extra);
      if (isMountPair) {
        entry.classification = "mount_pair";
        entry.reason = (entry.reason || "") + "——Mount 群（cmp/Profile Print／App icon 對角兩顆錨點，非印品母題角托，LS-207）";
      }
      out.document_unresolved.push(entry);
      if (inScope) out.unresolved.push(entry);
    };
    const noVariant = corners.filter((k) => !k.variant);
    if (noVariant.length) {
      unresolved({ reason: "角托名稱無方位 TL/TR/BL/BR：" + noVariant.map((k) => k.node.name || k.node.id).join("、") });
      continue;
    }
    if (corners.length !== 4 && corners.length !== 2) {
      unresolved({ reason: "角托數 " + corners.length + "（規則①四角托／②兩對角）" });
      continue;
    }
    const totalAxes = corners.length * 2;
    const candidates = [p].concat((kids.get(pid) || []).filter((s) => !isCorner(s) && s.w > 0 && s.h > 0));
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
      unresolved({
        reason: "找不到吻合的紙面（父或兄弟）",
        best_candidate: best ? best.cand.id : null, best_candidate_name: best ? best.cand.name : null,
        best_score: best ? best.score : 0, total_axes: totalAxes,
      });
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
  const { byId, liveNodes, chain, roots, pos } = idx || buildIndex(nodes);
  const re = resolveOverlayRe(opts);
  const boards = resolveBoards(opts && opts.boards, roots);
  const scoped = boards.length > 0;
  const primaryRoots = opts && opts.primaryRoots ? opts.primaryRoots : null;
  const order = pos;
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
    if (primaryRoots && !primaryRoots.has(board)) continue;
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
  const index = idx || buildIndex(nodes);
  const { byId, liveNodes, kids, chain, roots } = index;
  const isPrimary = primaryFilter(index, opts);
  const re = resolveOverlayRe(opts);
  const boards = resolveBoards(opts && opts.boards, roots);
  const scoped = boards.length > 0;
  const out = { boards, flagged: [], document_flagged: [] };
  for (const n of liveNodes) {
    if (n.parent == null) continue;
    if (isPrimary && !isPrimary(n)) continue;
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

// FNV-1a 64：狀態以 (hi, lo) 兩個 uint32 表示，prime 0x100000001b3 = 2^40 + 0x1b3——h·2^40 只把 lo 的低 24 位元推進 hi（(lo<<8)>>>0），
// h·0x1b3 兩段各乘後進位，每 byte 兩次乘法；UTF-8 位元組就地產生、不建陣列（LS-226：Pencil 沙盒實測舊的四 limb＋utf8Bytes 陣列寫法
// 2.9 µs/字元，雜湊是分批裡最貴的一段）。回傳仍是四個 16 位元 limb（低→高），hex64／addLimbs 介面與 design_tree_hash.py 規格不變
function fnv1a64(str) {
  let hi = 0xcbf29ce4, lo = 0x84222325;
  const mix = (b) => {
    lo = (lo ^ b) >>> 0;
    const L = lo * 0x1b3;
    hi = (hi * 0x1b3 + Math.floor(L / 4294967296) + ((lo << 8) >>> 0)) >>> 0;
    lo = L >>> 0;
  };
  for (let i = 0; i < str.length; i++) {
    let c = str.charCodeAt(i);
    if (c < 0x80) { mix(c); continue; }
    if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
      const d = str.charCodeAt(i + 1);
      if (d >= 0xdc00 && d <= 0xdfff) { c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00); i++; }
    }
    if (c < 0x800) { mix(0xc0 | (c >> 6)); mix(0x80 | (c & 63)); }
    else if (c < 0x10000) { mix(0xe0 | (c >> 12)); mix(0x80 | ((c >> 6) & 63)); mix(0x80 | (c & 63)); }
    else { mix(0xf0 | (c >> 18)); mix(0x80 | ((c >> 12) & 63)); mix(0x80 | ((c >> 6) & 63)); mix(0x80 | (c & 63)); }
  }
  return [lo & 0xffff, lo >>> 16, hi & 0xffff, hi >>> 16];
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
  // LS-226：opts.batch={index,size?} → 只處理 root 落在本批（全稿 root 順序 [lo,hi)）的主節點；輸出附 batch 描述供 mergeBatches。
  // 分批依「限縮前」的全稿 root 清單切（scope=boards 時 Pencil 端仍把全部 root 以裸節點放進快照，見檔尾），限縮後不在 scanned 的
  // root 自然沒有主節點；scanned_nodes 只數本批 root 底下的節點，merge 相加＝全量
  const allRoots = nodes.filter((n) => n.parent == null);
  const b = batchRange(allRoots.length, opts && opts.batch);
  const primaryRoots = b ? new Set(allRoots.slice(b.lo, b.hi).map((r) => r.id)) : null;
  const so = Object.assign({}, opts, { primaryRoots });
  // opts.timing={} 時逐支記錄毫秒（Pencil 端印 TIMING 行、調批大小用）
  const timed = (key, fn) => {
    const t0 = Date.now();
    const r = fn();
    if (opts && opts.timing) opts.timing[key] = Date.now() - t0;
    return r;
  };
  // LS-202：每支帶 scope＋document_count（該支在整份快照裡的命中數；scope=boards 時是限縮值；分批時是該批的部分數，merge 重算）
  const tag = (o) => Object.assign({ scope, document_count: (o.document_flagged || o.flagged).length }, o);
  const out = {
    scanned_nodes: primaryRoots ? scanned.filter((n) => primaryRoots.has(idx.chain.get(n.id).slice(-1)[0])).length : scanned.length,
    scan_scope: scope,
    scans: {
      sibling_intersection: tag(timed("sibling_intersection", () => scanSiblingIntersection(scanned, idx, so))),
      row_overflow: tag(timed("row_overflow", () => scanRowOverflow(scanned, idx, so))),
      cross_parent_collision: tag(timed("cross_parent_collision", () => scanCrossParentCollision(scanned, idx, so))),
      corner_anchor: tag(timed("corner_anchor", () => scanCornerAnchor(scanned, idx, so))),
      text_occlusion: tag(timed("text_occlusion", () => scanTextOcclusion(scanned, idx, so))),
      board_clip: tag(timed("board_clip", () => scanBoardClip(scanned, idx, so))),
    },
  };
  if (b) {
    out.batch = { roots: [b.lo, b.hi], root_count: allRoots.length };
    if (b.index != null) Object.assign(out.batch, { index: b.index, total: b.total, size: b.size });
  }
  return out;
}

// ---- LS-226 分批＋加總（語意見檔頭「分批模式」）----
const SCAN_KEYS = ["sibling_intersection", "row_overflow", "cross_parent_collision", "corner_anchor", "text_occlusion", "board_clip"];

// 批大小預設值：Pencil 端以 SCAN_BATCH_SIZE 全域覆寫、node 端以環境變數 SCAN_BATCH_SIZE 覆寫（單位＝每批頂層 root 數）
function defaultBatchSize() {
  const env = typeof process === "object" && process && process.env ? process.env.SCAN_BATCH_SIZE : undefined;
  if (env == null || env === "") return DEFAULT_BATCH_SIZE;
  const n = Number(env);
  if (!Number.isInteger(n) || n < 1) throw new Error("overflow-scan：環境變數 SCAN_BATCH_SIZE 須為 ≥1 的整數（收到 " + JSON.stringify(env) + "）");
  return n;
}

// rootCount＝全稿頂層 root 數。兩種寫法：{index, size?}＝等寬批（批 index（1 起算）負責 root 順序 [(index−1)·size, index·size)）；
// {roots: [lo, hi]}＝明確範圍（某批太重時可只把那一段再切小，不必重跑其他批——merge 只驗各批 [lo,hi) 首尾相接、蓋滿 [0, rootCount)）
function batchRange(rootCount, batch) {
  if (!batch) return null;
  if (Array.isArray(batch.roots)) {
    const lo = Number(batch.roots[0]), hi = Number(batch.roots[1]);
    if (!Number.isInteger(lo) || !Number.isInteger(hi) || lo < 0 || hi <= lo || hi > rootCount) throw new Error("overflow-scan：batch.roots 須為 [lo, hi)、0 ≤ lo < hi ≤ root 數 " + rootCount + "（收到 " + JSON.stringify(batch.roots) + "）");
    return { lo, hi, root_count: rootCount };
  }
  const size = batch.size != null ? Number(batch.size) : defaultBatchSize();
  const index = Number(batch.index);
  if (!Number.isInteger(size) || size < 1) throw new Error("overflow-scan：batch.size 須為 ≥1 的整數（收到 " + JSON.stringify(batch.size) + "）");
  const total = Math.max(1, Math.ceil(rootCount / size));
  if (!Number.isInteger(index) || index < 1 || index > total) throw new Error("overflow-scan：batch.index 須在 1.." + total + "（root 數=" + rootCount + "、size=" + size + "；收到 " + JSON.stringify(batch.index) + "）");
  return { index, total, size, lo: (index - 1) * size, hi: Math.min(index * size, rootCount), root_count: rootCount };
}

function hexToLimbs(hex) {
  if (typeof hex !== "string" || !/^[0-9a-f]{16}$/.test(hex)) throw new Error("overflow-scan merge：hash_part 須為 16 碼小寫 hex（收到 " + JSON.stringify(hex) + "）");
  const limbs = [];
  for (let i = 0; i < 4; i++) limbs.push(parseInt(hex.slice(16 - 4 * (i + 1), 16 - 4 * i), 16));
  return limbs;
}

// parts＝各批的 scanAll 輸出（Pencil 端 BATCH-JSON 另帶 total_nodes／hash_part／flags）。驗 K／size／root_count／scan_scope／flags
// 一致、批次不缺不重、root 範圍首尾相接、每支的 scope／boards 各批相同，任一不符即 throw；六支一律「陣列串接、整數計數相加、
// document_count 重算」，scanned_nodes／total_nodes 相加、hash_part mod 2^64 相加——合併結果與不分批的 scanAll 逐位元相同
// （各批依 root 順序串接＝不分批的輸出順序；overflow-scan.test.js 釘住）
function mergeBatches(parts) {
  if (!Array.isArray(parts) || !parts.length) throw new Error("overflow-scan merge：沒有任何批次");
  for (const p of parts) if (!p || !p.batch || !Array.isArray(p.batch.roots) || !Number.isInteger(p.batch.roots[0]) || !Number.isInteger(p.batch.roots[1]) || !Number.isInteger(p.batch.root_count)) throw new Error("overflow-scan merge：批次缺 batch.roots=[lo,hi]／batch.root_count（不是分批模式的輸出）");
  const sorted = parts.slice().sort((p, q) => p.batch.roots[0] - q.batch.roots[0]);
  const first = sorted[0];
  const K = sorted.length;
  const label = (p) => "roots=[" + p.batch.roots.join(",") + ")";
  const same = (key, get) => {
    const want = JSON.stringify(get(first));
    for (const p of sorted) if (JSON.stringify(get(p)) !== want) throw new Error("overflow-scan merge：" + label(p) + " 那批的 " + key + "=" + JSON.stringify(get(p)) + " ≠ 第一批 " + want + "（不是同一稿態／同一參數的分批）");
  };
  same("batch.root_count", (p) => p.batch.root_count);
  same("scan_scope", (p) => p.scan_scope);
  same("flags", (p) => p.flags);
  const hashed = sorted.filter((p) => p.hash_part != null).length;
  if (hashed !== 0 && hashed !== K) throw new Error("overflow-scan merge：只有 " + hashed + "/" + K + " 批帶 hash_part");
  const counted = sorted.filter((p) => p.total_nodes != null).length;
  if (counted !== 0 && counted !== K) throw new Error("overflow-scan merge：只有 " + counted + "/" + K + " 批帶 total_nodes");
  let cursor = 0;
  for (const p of sorted) {
    const r = p.batch.roots;
    if (r[0] !== cursor) throw new Error("overflow-scan merge：" + label(p) + " 與前一批不相接（期望起點 " + cursor + "——缺一批、重複、或不同 size 的批混在一起）");
    if (r[1] <= r[0]) throw new Error("overflow-scan merge：" + label(p) + " 範圍為空");
    cursor = r[1];
    if (!Number.isInteger(p.scanned_nodes)) throw new Error("overflow-scan merge：" + label(p) + " 缺 scanned_nodes");
    for (const k of SCAN_KEYS) {
      if (!p.scans || !p.scans[k] || !Array.isArray(p.scans[k].flagged)) throw new Error("overflow-scan merge：" + label(p) + " 缺 scans." + k + ".flagged");
      if (!Number.isInteger(p.scans[k].document_count) || p.scans[k].document_count < 0) throw new Error("overflow-scan merge：" + label(p) + " 的 scans." + k + ".document_count 不是非負整數");
    }
  }
  if (cursor !== first.batch.root_count) throw new Error("overflow-scan merge：各批 roots 串接到 " + cursor + " ≠ root_count " + first.batch.root_count + "（缺最後幾批）");
  // 各批先壓成代表形狀（BATCH-JSON 本來就是；完整陣列的批也收）——三支 O(n²) 以 class 鍵合併 count、代表取最早那批的；其餘三支陣列串接
  const norm = sorted.map((p) => compactScans(p.scans));
  const scans = {};
  for (const k of SCAN_KEYS) {
    same("scans." + k + ".scope", (p) => p.scans[k].scope);
    same("scans." + k + ".boards", (p) => p.scans[k].boards);
    const partSum = () => {
      const acc = [0, 0, 0, 0];
      for (const sc of norm) addLimbs(acc, hexToLimbs(sc[k].result_hash_part));
      return hex64(acc);
    };
    if (CLASS_KEYS[k]) {
      const m = new Map();
      for (const sc of norm) for (const f of sc[k].flagged) {
        if (typeof f.class !== "string" || !Number.isInteger(f.count) || f.count < 1) throw new Error("overflow-scan merge：scans." + k + ".flagged 有一筆缺 class／count（不是分批輸出的代表形狀）");
        const hit = m.get(f.class);
        if (hit) hit.count += f.count; else m.set(f.class, Object.assign({}, f));
      }
      scans[k] = { scope: first.scans[k].scope, document_count: norm.reduce((acc, sc) => acc + sc[k].document_count, 0), classes: m.size, flagged: [...m.values()], result_hash_part: partSum() };
      continue;
    }
    const merged = Object.assign({}, norm[0][k]);
    for (const key of Object.keys(merged)) {
      const v = merged[key];
      if (key === "scope" || key === "boards" || key === "document_count" || key === "result_hash_part") continue;
      if (Array.isArray(v)) merged[key] = [].concat(...norm.map((sc) => Array.isArray(sc[k][key]) ? sc[k][key] : []));
      else if (Number.isInteger(v)) merged[key] = norm.reduce((acc, sc) => acc + (Number.isInteger(sc[k][key]) ? sc[k][key] : 0), 0);
    }
    merged.document_count = (merged.document_flagged || merged.flagged).length;
    merged.result_hash_part = partSum();
    scans[k] = merged;
  }
  let out = { scanned_nodes: sorted.reduce((acc, p) => acc + p.scanned_nodes, 0), scan_scope: first.scan_scope, scans };
  if (counted) out.total_nodes = sorted.reduce((acc, p) => acc + p.total_nodes, 0);
  if (hashed) {
    const acc = [0, 0, 0, 0];
    for (const p of sorted) addLimbs(acc, hexToLimbs(p.hash_part));
    out.tree_hash = hex64(acc);
    out = withResultHashes(out);
  }
  if (first.flags != null) out.flags = first.flags;
  out.batching = { batches: K, root_count: first.batch.root_count, roots: sorted.map((p) => p.batch.roots) };
  return out;
}

// 一行 SUMMARY（Pencil 端不分批／merge 後同一格式）；flags={crossAll, overlayRe} 只影響標註字樣
function summaryLine(out, flags) {
  const f = flags || out.flags || {};
  const crossAll = !!(f.crossAll || f.cross_all), overlayRe = !!(f.overlayRe || f.custom_overlay_re);
  const s = out.scans;
  return "SUMMARY total_nodes=" + out.total_nodes + " scanned_nodes=" + out.scanned_nodes + " scan_scope=" + out.scan_scope +
    " sibling_intersection=" + s.sibling_intersection.document_count +
    " row_overflow=" + s.row_overflow.document_count +
    " cross_parent_collision=" + s.cross_parent_collision.document_count + (crossAll ? "(all)" : "(bleed-only)") +
    " text_occlusion=" + s.text_occlusion.flagged.length + "/" + s.text_occlusion.document_flagged.length + (overlayRe ? "(custom-re)" : "") +
    " board_clip=" + s.board_clip.flagged.length + "/" + s.board_clip.document_flagged.length +
    " corner_anchor=" + s.corner_anchor.containers + "/" + s.corner_anchor.points + "/" + s.corner_anchor.mismatch +
    " document=" + s.corner_anchor.document_containers + "/" + s.corner_anchor.document_points + "/" + s.corner_anchor.document_mismatch +
    " ref_hits=" + s.corner_anchor.ref_hits + "(defs=" + s.corner_anchor.ref_hits_defs + ")" +
    " unresolved=" + s.corner_anchor.unresolved.length + "/" + s.corner_anchor.document_unresolved.length + " boards=" + JSON.stringify(s.corner_anchor.boards) +
    " tree_hash=" + out.tree_hash;
}

// LS-202 R2 minor-1：corner_anchor 歸零警示——scope=document 時 document_containers=0 是第四支停擺（快照沒讀到 ref 且名稱備援也沒命中），
// 收據不得交；R3 minor-2：scope=boards 限縮快照可能真的沒有印品、判不出停擺，只印提示（第一張全稿收據才看得出量級）；
// containers=0 而 document 非零只是 boards 內沒有印品（LS-133 r1–r3／LS-177 r1 屬正常），提示核對 SCAN_BOARDS 即可。
// LS-207：ref_hits===0 是 ref 判準本身的哨兵，跟 document_containers 分開印（可同時成立、也可能只有一個成立——名稱備援讓
// document_containers 非零時，ref_hits 仍可能是 0，代表 ref 判準完全沒接上，只是被名稱備援蓋住看不出來）。
function cornerWarnings(ca) {
  const warnings = [];
  if (ca.ref_hits === 0) {
    warnings.push("⚠ corner_anchor ref_hits=0：ref 判準沒有命中任何節點——快照沒有 ref 欄位、或 resolveInstances:false 對照表沒建成／沒套上（LS-207）；document_containers 若仍非零只是名稱備援撐住，ref 判準本身仍是壞的，Mount TL/BR 這類非 Corner 命名的角托看不到。");
  }
  if (ca.document_containers === 0) {
    if (ca.scope === "boards") {
      warnings.push("⚠ corner_anchor document_containers=0（scope=boards）：限縮快照內沒有角托容器——boards 含印品類板時先核對 SCAN_BOARDS／快照 ref；本來沒有印品屬正常。限縮模式判不出第四支有沒有停擺，第一張 scope=document 收據要看 document_containers 量級（development 現稿應 ≥261，LS-207）");
    } else {
      warnings.push("⚠ corner_anchor document_containers=0：整份快照沒有任何角托容器——第四支停擺（Pencil 快照沒讀到 ref、名稱備援 Corner TL/… 也沒命中），這份收據不得交，先查快照欄位（LS-202 R2）");
    }
  } else if (ca.containers === 0) {
    warnings.push("⚠ corner_anchor containers=0：boards 內沒有角托容器（document=" + ca.document_containers + "）——boards 含印品類板時先核對 SCAN_BOARDS 有沒有漏列；boards 本來就沒有印品則屬正常（LS-133／LS-177 r1）");
  }
  return warnings;
}

// ---- 收據形狀（LS-226）----
// 三支 O(n²)（sibling_intersection／row_overflow／cross_parent_collision）的 flagged 全量在真實稿是數千筆（LS-208 r6：2066／560／321，
// 完整 JSON 26 萬字元），收據與分批輸出都只留「每類一筆代表」：`class`＝同名對／同容器鍵（與 compactLines 彙整段同一把鍵）、
// `count`＝同類筆數、其餘欄位＝該類第一筆（快照序）原樣、`classes`＝類數；`document_count` 仍是全量。設計端在每筆代表補
// `classification` 文字（gate 驗非空，腳本不代寫）。其餘三支的 flagged／unresolved／document_* 陣列原樣完整（in-scope 必為空、
// 全稿數字通常小、gate 要逐筆看），`container_corners` 只留在 scanAll 輸出（診斷用，SCAN_VERBOSE 印 CORNERS 行）。
const CLASS_KEYS = {
  sibling_intersection: (f) => f.name_a + " × " + f.name_b + " @ " + f.parent_name,
  cross_parent_collision: (f) => f.name_a + " × " + f.name_b + " @ " + f.board_name,
  row_overflow: (f) => f.parent_name + " :: " + f.name,
};
// ---- result_hash（LS-226）----
// 每支一個 16 碼 hex：對下列各行做 FNV-1a 64 後 mod 2^64 相加（同 tree_hash 的加總法，順序無關、不排序）：
//   "scan=<支名>"、"scope=<頂層 scan_scope>"、"tree_hash=<收據 tree_hash>"、in-scope `flagged` 每筆一行 "flagged=<身分>"、
//   corner_anchor 另對 in-scope `unresolved` 每筆一行 "unresolved=<container>"。身分（IDENTITY）：sibling_intersection／
//   cross_parent_collision `node_a|node_b`、row_overflow `node`、corner_anchor `corner:axis`、text_occlusion `node|overlay`、board_clip `node`。
// 三支 O(n²) 在壓成代表**之前**對全量 flagged 算（收據只存代表、CI 不能重算，但同一稿態重跑腳本必得同值＝收據對得回這次掃描）；
// 其餘三支的 in-scope 陣列收據原樣完整，design-evidence-check.sh 用 design_tree_hash.py 同規格重算 corner_anchor／text_occlusion／
// board_clip 比對（fail-closed）。分批：各批先算身分行的局部和 `result_hash_part`（不含三行標頭），merge 相加、最後加標頭＝不分批同值。
const IDENTITY = {
  sibling_intersection: (f) => f.node_a + "|" + f.node_b,
  cross_parent_collision: (f) => f.node_a + "|" + f.node_b,
  row_overflow: (f) => f.node,
  corner_anchor: (f) => f.corner + ":" + f.axis,
  text_occlusion: (f) => f.node + "|" + f.overlay,
  board_clip: (f) => f.node,
};
function resultHashLines(key, scan) {
  const lines = scan.flagged.map((f) => "flagged=" + IDENTITY[key](f));
  if (key === "corner_anchor") for (const u of scan.unresolved) lines.push("unresolved=" + u.container);
  return lines;
}
function sumLines(lines, acc) {
  const a = acc || [0, 0, 0, 0];
  for (const l of lines) addLimbs(a, fnv1a64(l));
  return a;
}
function resultHash(key, scanScope, treeHash, part) {
  return hex64(sumLines(["scan=" + key, "scope=" + scanScope, "tree_hash=" + treeHash], hexToLimbs(part)));
}
// 代表形狀的 result_hash_part → result_hash（需要頂層 tree_hash／scan_scope；tree_hash 不是 16 碼 hex 就 throw——SCAN_SKIP_HASH 要帶 SCAN_TREE_HASH）
function withResultHashes(out) {
  if (typeof out.tree_hash !== "string" || !/^[0-9a-f]{16}$/.test(out.tree_hash)) throw new Error("overflow-scan：算 result_hash 需要 16 碼 hex 的 tree_hash（收到 " + JSON.stringify(out.tree_hash) + "）");
  const scans = {};
  for (const k of SCAN_KEYS) {
    const o = Object.assign({}, out.scans[k]);
    o.result_hash = resultHash(k, out.scan_scope, out.tree_hash, o.result_hash_part);
    delete o.result_hash_part;
    scans[k] = o;
  }
  return Object.assign({}, out, { scans });
}

// scans（scanAll 輸出或已是代表形狀）→ 代表形狀；冪等（`classes` 已在＝已壓過，原樣回）。代表順序＝各類第一筆的快照序，不排序
// （分批 merge 依 root 序串接各批的類，與不分批壓出的順序相同；排序只在 compactLines 印字時做）。六支各補 `result_hash_part`
// （已有就沿用——完整陣列的輸出在這裡算、代表形狀的輸出只能沿用）
function compactScans(scans) {
  const out = {};
  for (const k of SCAN_KEYS) {
    const o = scans[k];
    if (!o || !Array.isArray(o.flagged)) throw new Error("overflow-scan：缺 scans." + k + ".flagged");
    if (!CLASS_KEYS[k]) {
      const c = Object.assign({}, o);
      delete c.container_corners;
      if (c.result_hash_part == null && c.result_hash == null) c.result_hash_part = hex64(sumLines(resultHashLines(k, o)));
      out[k] = c;
      continue;
    }
    if (o.classes != null) {
      if (o.result_hash_part == null && o.result_hash == null) throw new Error("overflow-scan：scans." + k + " 已是代表形狀卻沒有 result_hash_part（舊版腳本的分批輸出，重跑）");
      out[k] = o;
      continue;
    }
    const m = new Map();
    for (const f of o.flagged) {
      const key = CLASS_KEYS[k](f);
      const hit = m.get(key);
      if (hit) hit.count++; else m.set(key, Object.assign({}, f, { class: key, count: 1 }));
    }
    out[k] = { scope: o.scope, document_count: o.document_count, classes: m.size, flagged: [...m.values()], result_hash_part: hex64(sumLines(resultHashLines(k, o))) };
  }
  return out;
}
function compactResult(out) {
  return Object.assign({}, out, { scans: compactScans(out.scans) });
}

function compactLines(out) {
  const s = compactScans(out.scans);
  const agg = (items, keyFn, exFn) => {
    const m = new Map();
    for (const it of items) {
      const k = keyFn(it);
      if (!m.has(k)) m.set(k, { n: 0, ex: exFn(it) });
      m.get(k).n++;
    }
    return [...m.entries()].sort((p, q) => q[1].n - p[1].n);
  };
  const byCount = (arr) => arr.slice().sort((p, q) => q.count - p.count);
  // LS-202：每段標頭尾綴 scope／document_count（收據每支照抄這兩個欄位）
  const tail = (o) => " scope=" + o.scope + " document_count=" + o.document_count;
  const blocks = [];
  for (const key of ["sibling_intersection", "cross_parent_collision"]) {
    const o = s[key];
    blocks.push(["SCAN " + key + " flagged=" + o.document_count + " classes=" + o.classes + tail(o)].concat(byCount(o.flagged).map((f) => "  " + f.count + "× " + f.class + " e.g. " + f.node_a + "×" + f.node_b)).join("\n"));
  }
  const ro = s.row_overflow;
  blocks.push(["SCAN row_overflow flagged=" + ro.document_count + " classes=" + ro.classes + tail(ro)].concat(byCount(ro.flagged).map((f) => "  " + f.count + "× " + f.class + " e.g. " + f.node + " (+" + f.overflow + ")")).join("\n"));
  const ca = s.corner_anchor;
  const lines = ["SCAN corner_anchor boards=" + JSON.stringify(ca.boards) + " containers/points/mismatch=" + ca.containers + "/" + ca.points + "/" + ca.mismatch +
    " document=" + ca.document_containers + "/" + ca.document_points + "/" + ca.document_mismatch + " ref_hits=" + ca.ref_hits + "(defs=" + ca.ref_hits_defs + ")" + " unresolved=" + ca.unresolved.length + "/" + ca.document_unresolved.length + tail(ca)];
  for (const f of ca.flagged) lines.push("  MISMATCH " + f.container_name + "(" + f.container + ") " + f.corner_name + " " + f.axis + " exp=" + f.expected + " act=" + f.actual + " paper=" + f.paper_name + " board=" + f.board_name);
  for (const u of ca.unresolved) lines.push("  UNRESOLVED " + u.container_name + "(" + u.container + ") " + u.reason + (u.best_candidate_name ? " best=" + u.best_candidate_name + " " + u.best_score + "/" + u.total_axes : "") + " board=" + u.board_name);
  for (const [k, v] of agg(ca.document_flagged, (f) => f.board_name + "(" + f.board + ")", (f) => f.container)) lines.push("  DOCUMENT " + v.n + "× board " + k + " e.g. container " + v.ex);
  for (const [k, v] of agg(ca.document_unresolved.filter((u) => !ca.unresolved.includes(u)), (u) => u.board_name + "(" + u.board + ")", (u) => u.container)) lines.push("  DOCUMENT-UNRESOLVED " + v.n + "× board " + k + " e.g. container " + v.ex);
  for (const w of cornerWarnings(ca)) lines.push("  " + w);
  blocks.push(lines.join("\n"));
  const tx = s.text_occlusion;
  const to = agg(tx.flagged, (f) => f.name + " × " + f.overlay_name + " @ " + f.board_name + "(" + f.board + ")", (f) => f.node + "×" + f.overlay);
  const tl = ["SCAN text_occlusion boards=" + JSON.stringify(tx.boards) + " flagged=" + tx.flagged.length + " classes=" + to.length + " document=" + tx.document_flagged.length + tail(tx)]
    .concat(to.map(([k, v]) => "  " + v.n + "× " + k + " e.g. " + v.ex));
  for (const [k, v] of agg(tx.document_flagged.filter((f) => !tx.flagged.includes(f)), (f) => f.board_name + "(" + f.board + ")", (f) => f.node + "×" + f.overlay)) tl.push("  DOCUMENT " + v.n + "× board " + k + " e.g. " + v.ex);
  blocks.push(tl.join("\n"));
  const bc = s.board_clip;
  const bcRows = agg(bc.flagged, (f) => f.name + " " + f.side + " @ " + f.board_name + "(" + f.board + ")", (f) => f.node + " (+" + f.overflow_px + ")");
  const bl = ["SCAN board_clip boards=" + JSON.stringify(bc.boards) + " flagged=" + bc.flagged.length + " classes=" + bcRows.length + " document=" + bc.document_flagged.length + tail(bc)]
    .concat(bcRows.map(([k, v]) => "  " + v.n + "× " + k + " e.g. " + v.ex));
  for (const [k, v] of agg(bc.document_flagged.filter((f) => !bc.flagged.includes(f)), (f) => f.board_name + "(" + f.board + ")", (f) => f.node + " " + f.side + " (+" + f.overflow_px + ")")) bl.push("  DOCUMENT " + v.n + "× board " + k + " e.g. " + v.ex);
  blocks.push(bl.join("\n"));
  return blocks;
}

// node CLI（LS-226）：`--merge <batch-1> … <batch-K> [--out <merged.json>]`——每個檔可以是 BATCH-JSON 本體，或含 `BATCH-JSON ` 行的
// execute 輸出原文；合併結果 JSON 寫 --out（否則 stdout），SUMMARY／WARNING／SCAN 彙整段印 stderr（與不分批的 Pencil 輸出同格式）
function extractBatchJson(text, name) {
  const t = String(text).trim();
  if (t.startsWith("{")) return JSON.parse(t);
  const line = t.split("\n").find((l) => l.startsWith("BATCH-JSON "));
  if (!line) throw new Error("overflow-scan merge：" + name + " 既不是 JSON、也找不到 `BATCH-JSON ` 行");
  return JSON.parse(line.slice("BATCH-JSON ".length));
}
function cli(argv, fs, stdout, stderr) {
  const usage = "用法：node scripts/design/overflow-scan.js --merge <batch-1> … <batch-K> [--out <merged.json>]";
  if (argv[0] !== "--merge") { stderr(usage); return 2; }
  const files = [];
  let outPath = null;
  for (let i = 1; i < argv.length; i++) {
    if (argv[i] === "--out") {
      outPath = argv[++i];
      if (!outPath) { stderr("✗ --out 缺值\n" + usage); return 2; }
    } else files.push(argv[i]);
  }
  if (!files.length) { stderr("✗ --merge 後至少要一個批次檔\n" + usage); return 2; }
  let merged;
  try {
    merged = mergeBatches(files.map((f) => extractBatchJson(fs.readFileSync(f, "utf8"), f)));
  } catch (e) {
    stderr("✗ " + (e && e.message ? e.message : e));
    return 1;
  }
  stderr(summaryLine(merged));
  for (const w of cornerWarnings(merged.scans.corner_anchor)) stderr("WARNING " + w);
  for (const block of compactLines(merged)) stderr(block);
  const json = JSON.stringify(merged) + "\n";
  if (outPath) fs.writeFileSync(outPath, json); else stdout(json);
  return 0;
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
  // LS-226：SCAN_BATCH=<k>（1 起算，等寬批、SCAN_BATCH_SIZE 覆寫每批 root 數）或 SCAN_BATCH_ROOTS=[lo,hi]（明確 root 範圍）→ 本次
  // execute 只做這一批
  const batchIndex = typeof SCAN_BATCH !== "undefined" && SCAN_BATCH != null ? Number(SCAN_BATCH) : null;
  const batchSize = typeof SCAN_BATCH_SIZE !== "undefined" && SCAN_BATCH_SIZE != null ? Number(SCAN_BATCH_SIZE) : undefined;
  const batchRoots = typeof SCAN_BATCH_ROOTS !== "undefined" && Array.isArray(SCAN_BATCH_ROOTS) ? SCAN_BATCH_ROOTS : null;
  const batchSpec = batchRoots ? { roots: batchRoots } : (batchIndex != null ? { index: batchIndex, size: batchSize } : null);
  if (hashOnly && skipHash) throw new Error("overflow-scan：SCAN_HASH_ONLY 與 SCAN_SKIP_HASH 互斥——第一次只設 SCAN_HASH_ONLY（雜湊），第二次只設 SCAN_SKIP_HASH（六支掃描）；同時設會既不算雜湊也不跑掃描（LS-171 R1 N4）");
  if (batchSpec && (hashOnly || skipHash)) throw new Error("overflow-scan：SCAN_BATCH 分批模式自帶 tree_hash 分段，不得與 SCAN_HASH_ONLY／SCAN_SKIP_HASH 併用（LS-226）");
  if (batchRoots && batchIndex != null) throw new Error("overflow-scan：SCAN_BATCH 與 SCAN_BATCH_ROOTS 擇一（LS-226）");
  const timing = {};
  const tick = (key, t0) => { timing[key] = Date.now() - t0; };
  const timingLine = () => "TIMING " + Object.keys(timing).map((k) => k + "=" + timing[k] + "ms").join(" ");
  // 雜湊走訪＝未展開全樹（total_nodes 的唯一來源）；LS-171 includePathGeometry 必帶——Pencil Get 預設把 path 的 geometry 省略成
  // "..."，雜湊會與 js／py 不同（見檔頭）。不分批時整棵一趟；分批模式不走這裡（各批在 roots 走訪裡算自己 root 子樹的局部和）
  const hashWalk = () => {
    const t0 = Date.now();
    let count = 0;
    const hashAcc = [0, 0, 0, 0];
    Get((n, c) => {
      count++;
      if (skipHash) return;
      const line = canonNode(n, c.parentCtx ? c.parentCtx.node.id : null, c.index);
      addLimbs(hashAcc, fnv1a64(line));
      if (hashDebug && n.id === hashDebug) Print("HASHLINE " + line);
    }, { includePathGeometry: true });
    timing.hash_walk = Date.now() - t0;
    return { count, acc: hashAcc };
  };
  if (hashOnly) {
    const h = hashWalk();
    Print("SUMMARY-HASH total_nodes=" + h.count + " tree_hash=" + hex64(h.acc));
    Print(timingLine());
  } else {
  let t0 = Date.now();
  const abs = {};
  const snap = [];
  // LS-207：resolveInstances:true 展開後的樹裡，實例根節點本身已不是 type:"ref"、沒有 n.ref（LS-201 VR R2／R3 實測，
  // LS-202 當時的假設不成立）——另跑一次 resolveInstances:false 的走訪，把每個 type:"ref" 節點的 id → ref（元件 id）收進
  // 對照表；同一個實例根節點在兩次走訪的 id 相同（只有它的子孫在展開版多出 instanceId/childId 複合 id，根節點自己的 id
  // 不變），所以下面展開版走訪時可以用 id 查表把 ref 榫接回去。查不到就是 undefined，isCorner 退回名稱備援，行為不變。
  // 這次走訪不算 total_nodes（雜湊走訪才是 total 的唯一來源）。
  const refMap = {};
  const snapVisit = (n, c) => {
    const pid = c.parentCtx ? c.parentCtx.node.id : null;
    if (abs[n.id]) throw new Error("overflow-scan：Get 走訪到重複 id " + n.id);
    if (pid != null && !abs[pid]) throw new Error("overflow-scan：父節點 " + pid + " 尚未走訪（訪問序非 pre-order），無法累加絕對座標");
    const pa = pid != null ? abs[pid] : { x: 0, y: 0 };
    const b = c.bounds;
    const a = { x: pa.x + b.x, y: pa.y + b.y };
    abs[n.id] = a;
    // LS-207：ref 優先用展開版節點自己的 n.ref（若 Pencil 哪天真的保留）、查不到才退回 resolveInstances:false 對照表——
    // 兩者擇一有值即可，corner_anchor 的 ref_hits／isCorner 只看這個欄位最終有沒有值，不管來源（LS-202 舊註解）
    const ref = n.ref != null ? n.ref : refMap[n.id];
    snap.push({ id: n.id, name: n.name || "", parent: pid, type: n.type || "", ref, enabled: n.enabled !== false, clip: n.clip === true, image: hasImageFill(n.fill), x: a.x, y: a.y, w: b.width, h: b.height });
  };
  if (!batchSpec) {
    Get((n) => {
      if (n.type === "ref" && n.ref != null) refMap[n.id] = n.ref;
    }, { resolveInstances: false });
    tick("ref_walk", t0);
    t0 = Date.now();
    Get(snapVisit, { resolveInstances: true });
    tick("snapshot_walk", t0);
    t0 = Date.now();
    const out = scanAll(snap, { boards: scope, crossAll, overlayRe, scanScope, timing });
    tick("scans", t0);
    const s = out.scans;
    if (scope.length === 0) Print("WARNING SCAN_BOARDS 未設定：corner_anchor 以全稿計 mismatch，收據 gate 會因 boards 為空而紅——在本 snippet 第一行加 SCAN_BOARDS=[...] 再重跑（跨 execute 的全域不保留）");
    const h = hashWalk();
    out.total_nodes = h.count;
    // LS-226：SCAN_SKIP_HASH 那趟要帶 SCAN_TREE_HASH（第一趟 SUMMARY-HASH 印的值）——result_hash 綁 tree_hash，沒有就算不出、收據 gate 會紅
    const givenHash = typeof SCAN_TREE_HASH !== "undefined" && SCAN_TREE_HASH ? String(SCAN_TREE_HASH) : "";
    if (skipHash && !/^[0-9a-f]{16}$/.test(givenHash)) throw new Error("overflow-scan：SCAN_SKIP_HASH 須同時設 SCAN_TREE_HASH = \"<第一趟 SUMMARY-HASH 的 16 碼 tree_hash>\"（result_hash 綁 tree_hash，LS-226）；或改用 SCAN_BATCH 分批模式");
    out.tree_hash = skipHash ? givenHash : hex64(h.acc);
    out.flags = { cross_all: crossAll, custom_overlay_re: !!overlayRe };
    Print(summaryLine(out, { crossAll, overlayRe }));
    for (const w of cornerWarnings(s.corner_anchor)) Print("WARNING " + w);
    for (const block of compactLines(out)) Print(block);
    // LS-226：收據形狀的完整 JSON（三支 O(n²) 每類一筆代表；與 --merge 的輸出同形）——設計端照抄進收據再補 ticket／round／head_sha／
    // scan_note 與每筆代表的 classification
    Print("RESULT-JSON " + JSON.stringify(withResultHashes(compactResult(out))));
    Print(timingLine());
    if (verbose) for (const cc of s.corner_anchor.container_corners) Print("CORNERS " + cc.container_name + "(" + cc.container + ") n=" + cc.n + (cc.in_scope ? "" : " (document)") + " board=" + cc.board_name + "(" + cc.board + ")");
    if (verbose) for (const key of Object.keys(s)) Print("JSON " + key + " " + JSON.stringify(s[key]));
  } else {
    // LS-226 分批（一批一次 execute）：① roots 走訪（skipChildren，只訪 231 個頂層節點）拿全稿 root 順序＋每個 root 的絕對 AABB／
    // 名稱／enabled；② 本批 root＝全稿 root 順序 [lo,hi)——每個先走一趟未展開（refMap＋雜湊局部和＋未展開節點數），再走一趟展開
    // （快照）；scope=boards 時展開走訪只做 SCAN_BOARDS 內的 root，雜湊仍做本批全部 root（total_nodes／tree_hash 永遠是全稿）；
    // ③ 不在本批（或不在 SCAN_BOARDS）的 root 以**裸節點**放進快照——root 層兩板相鄰的 sibling 配對才算得到、resolveBoards／
    // cornerComponentIds 才看得到全部板名，它們的子樹不進快照、也不是主節點（scanAll 以 primaryRoots 過濾）。
    const roots = [];
    let unexpanded = 0;
    const hashAcc = [0, 0, 0, 0];
    // 等寬批的 [lo,hi) 不需要 root 總數就算得出、明確範圍亦然；總數在走訪後才由 batchRange 驗
    const bsize = batchSpec.size != null ? Number(batchSpec.size) : (batchSpec.roots ? 0 : defaultBatchSize());
    const wantLo = batchSpec.roots ? Number(batchSpec.roots[0]) : (Number(batchSpec.index) - 1) * bsize;
    const wantHi = batchSpec.roots ? Number(batchSpec.roots[1]) : wantLo + bsize;
    // ① 全稿未展開走訪：root 層記 AABB／名稱；不在 [lo,hi) 的 root skipChildren；本批 root 子樹算雜湊局部和＋數節點＋收 refMap。
    //    LS-171：includePathGeometry 必帶；不帶 resolveInstances（＝未展開，total_nodes 語意）
    Get((n, c) => {
      if (!c.parentCtx) {
        const b = c.bounds;
        roots.push({ id: n.id, name: n.name || "", parent: null, type: n.type || "", ref: undefined, enabled: n.enabled !== false, clip: n.clip === true, image: hasImageFill(n.fill), x: b.x, y: b.y, w: b.width, h: b.height });
        if (c.index < wantLo || c.index >= wantHi) { c.skipChildren(); return; }
      }
      unexpanded++;
      if (n.type === "ref" && n.ref != null) refMap[n.id] = n.ref;
      const line = canonNode(n, c.parentCtx ? c.parentCtx.node.id : null, c.index);
      addLimbs(hashAcc, fnv1a64(line));
      if (hashDebug && n.id === hashDebug) Print("HASHLINE " + line);
    }, { includePathGeometry: true });
    tick("roots_hash_walk", t0);
    const br = batchRange(roots.length, batchSpec);
    const scanRootIds = scanScope === "boards" ? resolveBoards(scope, roots) : null;
    const bare = new Set();
    t0 = Date.now();
    // ② 本批每個 root（scope=boards 時限 SCAN_BOARDS 內）各走一趟展開的 scoped Get 收快照
    for (let i = 0; i < roots.length; i++) {
      const r = roots[i];
      if (i < br.lo || i >= br.hi || (scanRootIds && !scanRootIds.includes(r.id))) { bare.add(r.id); continue; }
      Get(r.id, snapVisit, { resolveInstances: true });
    }
    tick("snapshot_walk", t0);
    // ③ 快照＝全稿 root 順序：本批已走訪的 root 子樹原樣（snap 已依走訪順序 push），其餘 root 只放裸節點——用一趟重排保證 pre-order
    const byRoot = new Map();
    let cur = null;
    for (const n of snap) {
      if (n.parent == null) { cur = []; byRoot.set(n.id, cur); }
      cur.push(n);
    }
    const ordered = [];
    for (const r of roots) {
      if (bare.has(r.id)) { ordered.push(r); continue; }
      const sub = byRoot.get(r.id);
      if (!sub) throw new Error("overflow-scan：root " + r.id + " 應已走訪卻不在快照裡（分批期間不得寫入）");
      for (const n of sub) ordered.push(n);
    }
    t0 = Date.now();
    const out = scanAll(ordered, { boards: scope, crossAll, overlayRe, scanScope, batch: batchSpec, timing });
    tick("scans", t0);
    if (out.batch.roots[0] !== br.lo || out.batch.roots[1] !== br.hi || out.batch.root_count !== roots.length) throw new Error("overflow-scan：scanAll 的批次描述 " + JSON.stringify(out.batch) + " 與走訪算出的 " + JSON.stringify(br) + " 不一致");
    if (scope.length === 0) Print("WARNING SCAN_BOARDS 未設定：corner_anchor 以全稿計 mismatch，收據 gate 會因 boards 為空而紅——在本 snippet 第一行加 SCAN_BOARDS=[...] 再重跑（跨 execute 的全域不保留）");
    // 批次輸出＝收據形狀（三支 O(n²) 只留每類一筆代表＋count；merge 以 class 鍵合併）——完整陣列一批就可能數百筆、設計端抄不動
    const part = { batch: out.batch, total_nodes: unexpanded, hash_part: hex64(hashAcc), scanned_nodes: out.scanned_nodes, scan_scope: out.scan_scope, flags: { cross_all: crossAll, custom_overlay_re: !!overlayRe }, scans: compactScans(out.scans) };
    const s = out.scans;
    Print("SUMMARY-BATCH " + (br.index != null ? br.index + "/" + br.total + " size=" + br.size + " " : "") + "roots=[" + br.lo + "," + br.hi + ")/" + roots.length + " total_nodes=" + unexpanded + " scanned_nodes=" + out.scanned_nodes + " scan_scope=" + out.scan_scope +
      " sibling_intersection=" + s.sibling_intersection.document_count + " row_overflow=" + s.row_overflow.document_count + " cross_parent_collision=" + s.cross_parent_collision.document_count +
      " corner_anchor=" + s.corner_anchor.containers + "/" + s.corner_anchor.points + "/" + s.corner_anchor.mismatch + " text_occlusion=" + s.text_occlusion.flagged.length + "/" + s.text_occlusion.document_flagged.length +
      " board_clip=" + s.board_clip.flagged.length + "/" + s.board_clip.document_flagged.length + " hash_part=" + part.hash_part);
    Print(timingLine());
    Print("BATCH-JSON " + JSON.stringify(part));
  }
  }
} else if (typeof module === "object" && module && module.exports) {
  module.exports = { AREA_MIN, TOL, CORNER_OUT, PHOTO_CORNER_ID, PHOTO_CORNER_NAME, CORNER_NAME_RE, CORNER_VARIANT_RE, BLEED_RE, OVERLAY_RE, LEAF_TYPE_RE, SCAN_SCOPES, DEFAULT_BATCH_SIZE, SCAN_KEYS, hasImageFill, buildIndex, overlapArea, contains, cornerExpected, cornerComponentIds, cornerWarnings, CLASS_KEYS, IDENTITY, resultHashLines, resultHash, withResultHashes, compactScans, compactResult, compactLines, pairEntry, primaryFilter, scanSiblingIntersection, scanRowOverflow, scanCrossParentCollision, scanCornerAnchor, scanTextOcclusion, scanBoardClip, restrictToBoards, scanAll, batchRange, defaultBatchSize, mergeBatches, summaryLine, extractBatchJson, cli, canon, canonNode, fnv1a64, hex64, addLimbs, treeHash, treeHashLines };
  if (typeof require === "function" && require.main === module) {
    process.exitCode = cli(process.argv.slice(2), require("fs"), (t) => process.stdout.write(t), (t) => process.stderr.write(t + "\n"));
  }
} else {
  throw new Error("overflow-scan：既不是 Pencil execute（無 Get／Print）也不是 node module 環境，無處輸出");
}
