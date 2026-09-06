// LS-222 —— purge-storage 孤兒掃描子系統，從 index.ts 抽出（收口 LS-213 R2
// merge-review comment 0e4c0eed 的 N2／N3）：
//
//   N3（路徑規則單一來源）：過去 scanFamilyOrphans() 用本地 MEDIA_OBJECT_PATH_RE
//     篩選候選，跟 SQL 端 private.is_media_object_path() 不等價（縮圖分支：TS
//     允許任何既有副檔名、SQL 只認 .jpg）——落差區間的物件會被「永遠掃到、永遠
//     靜默丟棄」，沒有任何計數回報。改法：這裡不再做任何形狀判斷，候選只用建立
//     時間（寬限期）篩，形狀合法性交給 Deps.classifyPaths()（真正實作見 index.ts，
//     呼叫 public.purge_storage_classify_orphan_paths() RPC，內部用
//     private.is_media_object_path()）判定；不合法的路徑計入 dropped，不再靜默
//     消失。
//   N2（游標分段寫回）：writeCursor 現在在每個家庭前綴掃完後就呼叫一次
//     （scanOrphanStorageObjects 的迴圈內，見下方），不是等整趟掃描結束才寫一次
//     ——invocation 中途因為 wall-clock 被中止時，下一次至少從最後寫回的那個家庭
//     續掃，不會歸零進度回到這一輪一開始的起點。
//   並發語意（last-writer-wins）：兩次重疊的 invocation 各自讀到某個游標值、各自
//     跑完（或跑到一半）之後各自寫回——最後寫入的那個值生效。這不會造成漏掃：
//     游標的值永遠是「某個寫入者這次真的處理完的家庭」，resume 規則
//     （familyIds.findIndex(f => f > resumeAfter)）的起點只會落在某個已處理家庭的
//     後繼，被覆寫只可能讓游標往回退（下一輪多掃一點、不會跳過沒掃過的家庭）；
//     入列端 on conflict do nothing 天生冪等，重複掃到同一個物件不會產生重複列
//     （見 docs/API.md §6「LS-222」段的完整說明）。
//
// 為什麼抽成獨立檔案：這裡的邏輯需要 Deno 單元測試覆蓋（含 LS-222 票文點名的
// `_thumb.png` 落差樣本 → 計入 dropped 案例），但 index.ts 頂層直接呼叫
// Deno.serve()，import 就會啟動 HTTP listener——同 delete-account／push-dispatch
// 既有的 handler.ts／index.ts 拆分理由（見 delete-account/index.ts 檔頭）。佇列
// 消化本體（Storage 物件實際刪除、attempts／退避／死信）不在本次變更範圍內，
// 維持原樣留在 index.ts，這裡只管孤兒掃描這一個子系統。
//
// 依賴注入：這個模組完全不 import `@supabase/supabase-js`，也不知道
// storage.list()／supabase.rpc() 的實際型別——真正的實作（wiring 到 Storage
// bucket／postgrest RPC）由 index.ts 的 buildOrphanScanDeps() 提供，deno test
// 用 fake Deps 完全不連線任何真正的 Supabase 專案。

export interface StorageEntry {
  id: string | null;
  name: string;
  created_at?: string | null;
}

export interface ClassifyResult {
  orphanPaths: string[];
  invalidPaths: string[];
}

export interface EnqueueResult {
  enqueued: number;
  dropped: number;
}

type RpcResult<T> = { ok: true; result: T } | { ok: false; error: string };

export interface OrphanScanDeps {
  /** 分頁列出 path 底下的項目（bucket.list 的 offset 續頁封裝）；失敗回 null 並把
   * 原因塞進 warnings——呼叫端據此跳過這個分支，不當成「這裡是空的」悄悄放行。 */
  listPaged(
    path: string,
    label: string,
    warnings: string[],
  ): Promise<StorageEntry[] | null>;
  /** public.purge_storage_classify_orphan_paths()：路徑形狀合法性（唯一判準
   * private.is_media_object_path()）與是否有對應 media 列，一支 RPC 回傳兩個
   * 子集合。 */
  classifyPaths(paths: string[]): Promise<RpcResult<ClassifyResult>>;
  /** public.purge_storage_queue_enqueue_orphans_v2()：把確認過的孤兒路徑排入
   * 佇列，回傳實際新增筆數與（防禦性重驗）被丟棄筆數。 */
  enqueueOrphans(
    familyId: string,
    paths: string[],
  ): Promise<RpcResult<EnqueueResult>>;
  /** public.orphan_scan_cursor 的讀取；讀取失敗 fail-open（從頭開始掃，頂多重複
   * 掃到已經掃過的家庭，不影響正確性），失敗原因塞進 warnings。 */
  readCursor(warnings: string[]): Promise<string | null>;
  /** public.orphan_scan_cursor 的寫入（upsert）。N2：現在每個家庭前綴掃完都會
   * 呼叫一次，不是整趟掃描結束才呼叫一次；寫入失敗只記 warning，不影響這次已經
   * 算好的 enqueued／dropped 結果。 */
  writeCursor(lastFamilyId: string | null, warnings: string[]): Promise<void>;
}

export interface FamilyOrphanResult {
  considered: number;
  enqueued: number;
  dropped: number;
}

export interface OrphanScanResult {
  enqueued: number;
  dropped: number;
  scanCompleted: boolean;
  cursor: string | null;
}

// 一次處理完一個家庭前綴的所有 year/month/file（原子單位，不在家庭內部中途停下
// ——理由同 LS-213 R2 的既有設計：至少保證每次 invocation 對「這一個家庭」的
// 候選數全部算完，round-robin 才有意義；若單一家庭的候選數就超過 batchSize，
// 這裡仍會把它處理完（軟上限，不是硬中斷），代價是那次 invocation 會比預算稍貴，
// 換取「至少一個完整家庭前進」的簡單保證，見 LS-222 票文與 N2 findings 的 PLAUSIBLE
// 情境說明）。回傳這個家庭貢獻的候選數、新排入佇列數與被丟棄數。
export async function scanFamilyOrphans(
  deps: OrphanScanDeps,
  familyId: string,
  cutoffMs: number,
  warnings: string[],
): Promise<FamilyOrphanResult> {
  const yearEntries = await deps.listPaged(familyId, `${familyId}/`, warnings);
  if (yearEntries === null) return { considered: 0, enqueued: 0, dropped: 0 };

  // N3：不再用本地 regex 篩形狀——這裡只收集「過了寬限期」的候選路徑，形狀合法
  // 性完全交給下面的 deps.classifyPaths()（唯一判準 private.is_media_object_path()）。
  const pastGraceCandidates: string[] = [];

  for (const yearEntry of yearEntries) {
    if (yearEntry.id !== null) continue; // 檔案，不是資料夾。
    if (yearEntry.name === "avatars") continue; // 頭像路徑不寫 media 表，排除（LS-213 票文範圍 2）。

    const yearPath = `${familyId}/${yearEntry.name}`;
    const monthEntries = await deps.listPaged(
      yearPath,
      `${yearPath}/`,
      warnings,
    );
    if (monthEntries === null) continue;

    for (const monthEntry of monthEntries) {
      if (monthEntry.id !== null) continue;

      const monthPath = `${yearPath}/${monthEntry.name}`;
      const fileEntries = await deps.listPaged(
        monthPath,
        `${monthPath}/`,
        warnings,
      );
      if (fileEntries === null) continue;

      for (const fileEntry of fileEntries) {
        if (fileEntry.id === null) continue; // 巢狀資料夾，不合法形狀（形狀判斷仍在 classifyPaths 這一關，這裡只排除明顯不是檔案的項目）。
        const path = `${monthPath}/${fileEntry.name}`;
        const createdAtMs = fileEntry.created_at
          ? Date.parse(fileEntry.created_at)
          : NaN;
        if (!Number.isFinite(createdAtMs) || createdAtMs > cutoffMs) continue; // 還在寬限期內，不計入候選。
        pastGraceCandidates.push(path);
      }
    }
  }

  if (pastGraceCandidates.length === 0) {
    return { considered: 0, enqueued: 0, dropped: 0 };
  }
  const considered = pastGraceCandidates.length;

  const classified = await deps.classifyPaths(pastGraceCandidates);
  if (!classified.ok) {
    warnings.push(
      `orphan scan：路徑分類失敗（${familyId}）：${classified.error}`,
    );
    return { considered, enqueued: 0, dropped: 0 };
  }

  const { orphanPaths, invalidPaths } = classified.result;
  let dropped = invalidPaths.length;
  // N3：形狀不合規的路徑不再靜默消失——這裡明確計入 dropped 並發 warning，讓
  // EF 回應／log 都看得到，不是只在候選階段被排除、外觀上跟「本來就沒有孤兒」
  // 一樣。
  if (invalidPaths.length > 0) {
    warnings.push(
      `orphan scan：${invalidPaths.length} 個路徑形狀不合規（不符 ` +
        `private.is_media_object_path()），已從候選中丟棄，不會被排入清除` +
        `佇列（${familyId}）：${invalidPaths.join(", ")}`,
    );
  }

  if (orphanPaths.length === 0) {
    return { considered, enqueued: 0, dropped };
  }

  const enqueueResult = await deps.enqueueOrphans(familyId, orphanPaths);
  if (!enqueueResult.ok) {
    warnings.push(
      `orphan scan：寫入 purge_storage_queue 失敗（${familyId}）：${enqueueResult.error}`,
    );
    return { considered, enqueued: 0, dropped };
  }

  // 防禦性重驗（enqueueOrphans 底層 RPC 對前綴／形狀再驗一次）多丟棄的筆數也算
  // 進 dropped——正常情況下這裡應該恆為 0（classifyPaths 已經先驗過一次），非 0
  // 代表兩層驗證的認定對不上，值得留在計數裡被觀測到，而不是被吸收成「消失了」。
  dropped += enqueueResult.result.dropped;

  return {
    considered,
    enqueued: enqueueResult.result.enqueued,
    dropped,
  };
}

// LS-213 範圍 2：分頁掃 media bucket（{family_id}/{yyyy}/{mm}/{file} 三層資料夾）
// 找出「Storage 有物件、但 public.media 完全沒有列引用它」且建立時間超過寬限期的
// 物件，透過 deps.enqueueOrphans() 寫進 public.purge_storage_queue（media_id 留
// NULL）。**只寫入佇列，不在這裡自己刪除物件**——新 enqueue 的列留給下一次
// invocation 的既有消化迴圈處理（見 index.ts）。
//
// LS-213 R2（merge-review R1 F1，家庭層級 round-robin＋持久化游標）：家庭清單走
// round-robin——從游標之後開始、繞回開頭，直到繞完一整圈（scanCompleted=true）
// 或候選預算用完，兩者先到就停，保證每次 invocation 都在往前推進，不會困在同一批
// 家庭。
//
// LS-222（N2）：游標在**每個家庭前綴掃完後**就寫回一次（迴圈內，不是迴圈外），
// invocation 中途被中止時下一次至少從最後寫回處續掃。
export async function scanOrphanStorageObjects(
  deps: OrphanScanDeps,
  cutoffMs: number,
  batchSize: number,
  warnings: string[],
): Promise<OrphanScanResult> {
  const resumeAfter = await deps.readCursor(warnings);

  const familyEntries = await deps.listPaged(
    "",
    "media bucket 根目錄",
    warnings,
  );
  if (familyEntries === null) {
    return {
      enqueued: 0,
      dropped: 0,
      scanCompleted: false,
      cursor: resumeAfter,
    };
  }

  const familyIds = familyEntries
    .filter((e) => e.id === null) // bucket 頂層不該有檔案，只認資料夾（家庭前綴）。
    .map((e) => e.name)
    .sort();

  if (familyIds.length === 0) {
    await deps.writeCursor(null, warnings);
    return { enqueued: 0, dropped: 0, scanCompleted: true, cursor: null };
  }

  // round-robin：從游標之後的第一個家庭開始（storage.list() 預設
  // sortBy=name asc 的字典序）；找不到比游標更大的（表示上次已經繞到最後，或
  // 游標指向的前綴已經不存在）就從頭開始——字串比較天生降級成「從下一個更大的
  // 前綴開始」，不會卡住。
  let startIndex = 0;
  if (resumeAfter !== null) {
    const idx = familyIds.findIndex((f) => f > resumeAfter);
    startIndex = idx === -1 ? 0 : idx;
  }

  let considered = 0;
  let enqueued = 0;
  let dropped = 0;
  let scanCompleted = false;
  let cursor: string | null = resumeAfter;

  for (let visited = 0; visited < familyIds.length; visited++) {
    const familyId = familyIds[(startIndex + visited) % familyIds.length];
    const result = await scanFamilyOrphans(deps, familyId, cutoffMs, warnings);
    considered += result.considered;
    enqueued += result.enqueued;
    dropped += result.dropped;

    const isLastVisit = visited + 1 >= familyIds.length;
    cursor = isLastVisit ? null : familyId; // 繞完一整圈：下一輪從頭開始，游標歸零。
    // N2：每個家庭前綴掃完就立刻寫回——這是本次收口的核心修法，見檔頭說明。
    await deps.writeCursor(cursor, warnings);

    if (isLastVisit) {
      scanCompleted = true;
      break;
    }
    if (considered >= batchSize) {
      break; // 候選預算用完，停在這個已完整處理且已寫回游標的家庭。
    }
  }

  return { enqueued, dropped, scanCompleted, cursor };
}
