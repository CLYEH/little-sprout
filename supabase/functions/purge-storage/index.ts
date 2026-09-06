// LS-153 — 消化 public.purge_storage_queue：呼叫 Storage Admin API 實際刪除
// private.purge_expired() 硬刪 media 列之後留下的物件路徑，成功即刪除該筆佇列列
// （純佇列語意，見 supabase/migrations/20260903110908_purge_expired.sql 對
// purge_storage_queue 的說明）。
//
// R2（merge-review R1 comment e71a797f，minor findings）：
//   - **逐路徑核對回傳**：storage.remove() 對「整個 bucket 都打不到」這種情況也
//     回傳 `error: null`（本機實測對一個不存在的 bucket 呼叫
//     `.remove(["whatever/path.jpg"])` 得到 `{ data: [], error: null }`）——只有
//     出現在 `data[].name` 裡的路徑才視為「這次呼叫確認處理完成」。
//   - **批次與排序**：`order by enqueued_at` 保證讀取順序穩定，並迴圈重複讀取／
//     處理直到佇列清空或達到安全上限。
//
// R3（merge-review R2 comment 7420f7b9，F1 major——毒丸隊頭阻塞）：R2 版本「無法
// 確認已刪的列永遠留在佇列、下次重試」本身沒有錯，但沒有出口——這些列的
// `enqueued_at` 不會變，`order by enqueued_at limit BATCH_SIZE` 每次都只讀得到
// 它們，佇列滿 BATCH_SIZE 筆無法確認的列之後，後面任何列都再也讀不到（e2e 實測
// 重現：200 筆「物件已不存在」的舊列擋住 2 筆真實物件，`processed` 永遠是 0）。
// 這裡採 reviewer 建議的兩個修法並用：
//   (i) `purge_storage_queue` 新增 attempts／last_error／next_attempt_at 三欄
//       （見該 migration）。remove() 呼叫本身出錯，或呼叫 getBucket() 確認不到
//       bucket 存在時，透過 public.purge_storage_queue_mark_failed()（SECURITY
//       DEFINER）記一次失敗：attempts 遞增、退避設定 next_attempt_at；達
//       MAX_ATTEMPTS（見下方常數）次視為死信，SELECT 端的
//       `where attempts < MAX_ATTEMPTS` 之後不會再選到它（停放，仍保留列供稽核，
//       不再佔住隊頭）。
//   (ii) reviewer F1 修法 (ii) 的精神：remove() 呼叫沒有出錯、但某些路徑沒有出現
//        在回傳的 `data[]` 裡時，先對這批路徑所在的 bucket 呼叫一次
//        `getBucket()` 確認 bucket 本身存在——如果 bucket 存在，「路徑沒出現在
//        `data[]` 裡」語意上就是「物件已經不存在」（不論是這次呼叫就發現它不在，
//        還是上一次呼叫已經真的刪除、但那次 `.delete().in("id", doneIds)`
//        失敗留下的殘影——兩者的目的都已達成），可以安全 dequeue，不需要等到
//        `attempts` 用盡；如果 bucket 不存在（R1 F5 的洞），才落入 (i) 的
//        attempts／退避／死信路徑。這樣「物件真的已經不存在」與「環境本身有問題
//        （bucket 打不到／remove() 呼叫出錯）」被分開處理：前者立刻自我修復，
//        後者才會累積 attempts、最終死信停放供人工介入。
// 迴圈不再因為單一批次有任何一筆未確認就中止（R2 版本的 `doneIds.length <
// queue.length` 中止條件正是 F1 的成因之一——見上方 R3 說明）：只要還沒到達
// MAX_BATCHES、且這一輪的 SELECT 仍讀得到列（表示還有未達死信門檻、且不在退避中
// 的列），就繼續下一輪；SELECT 端的 attempts／next_attempt_at 篩選條件本身就會讓
// 「這一輪已經標記失敗、進入退避」的列在同一次 invocation 內不會被重複讀到，佇列
// 自然收斂到空或全部退避中，不需要額外的「整批確認完成才繼續」條件。
//
// i3（merge-review R2 informational，PLAUSIBLE）：`.delete().in("id", doneIds)`
// 帶 BATCH_SIZE（200）個 UUID 會組出數千字元的 URL，接近部分 proxy 的 URI 長度
// 上限。改成固定大小（50）分段呼叫，降低單次請求的 URL 長度，不依賴 BATCH_SIZE
// 未來會不會調大。
//
// R4（merge-review R3 comment 04987043，minor 2——死信無觀測出口）：死信停放
// 之後 EF 回應永遠是 processed:0/failed:0 HTTP 200，跟「佇列本來就空」看起來
// 一樣，Storage 清除可以永久停擺而沒有人知道。回應 JSON 加 `parked` 欄位（見
// 檔尾），並 console.log 一行——不擴充 private.purge_runs（那張表是
// purge_expired() 的 DB 端結果，混進 EF 自己的觀測會耦合兩件事）。巡檢 SQL 見
// docs/API.md §6，由 orchestrator 接排程時一併接進巡檢。
//
// 已知限制（如實揭露，見 docs/API.md §6「自動清除」與本票 handoff）：本機已用
// `supabase functions serve --no-verify-jwt`（經 scripts/ops/supabase-lock.sh）
// 對這支函式做過端對端手動驗證，但**沒有**寫成 `supabase/tests/` 底下可重複執行的
// 自動化測試——這個 repo 目前沒有任何 Deno/Edge Function 的測試治具（見票 R1／R2
// handoff 的 harness 缺口記錄）。R3 e2e 驗證腳本留在票的 handoff／scratchpad，
// 供之後建置治具時參考。
//
// 呼叫方式（LS-196 訂正）：這支函式**只接受 service 憑證**——不是給 app client
// 呼叫的公開端點。`supabase/config.toml` 的 `[functions.purge-storage]
// verify_jwt = false`（本票新增）關掉平台層 JWT 驗證——下面改用
// `_shared/keys.ts` 的 `isAuthorizedServiceCall()` 在程式內驗：`apikey` header
// 等於任一 `SUPABASE_SECRET_KEYS` 值（正式站的新式 `sb_secret_…` default
// key），或（過渡）`Authorization: Bearer` 等於 `SUPABASE_SERVICE_ROLE_KEY`。
//
// **為什麼原本的守門在正式站從未通過過（LS-153 i4 煙測，comment
// 0535eab8）**：這支函式原本用 `verify_jwt` 預設開啟＋`bearer ===
// SUPABASE_SERVICE_ROLE_KEY` 的比對——但正式站 `supabase secrets list` 回報的
// `SUPABASE_SERVICE_ROLE_KEY` sha256 digest 不等於 CLI／Management API 回報的
// legacy service_role JWT（專案已建新式 `sb_secret_` default key，EF 執行期
// 注入的值從一開始就不是那把 legacy JWT）——`bearer !== serviceRoleKey`
// 因此對任何外部呼叫者都是 401，這條「只接受 service_role」守門實質上從沒真的
// 通過過。改用 `isAuthorizedServiceCall()`（見 `_shared/keys.ts` 檔頭）之後，
// 正式站呼叫改送 `apikey: sb_secret_…`（同官方「Migrating to publishable and
// secret API keys」§Step 4 遷移指引），過渡期仍接受 legacy bearer，兩條路徑
// 並存直到所有呼叫端都已改用新式 key。pg_cron／pg_net 呼叫範本見
// `docs/API.md` §6「purge-storage 呼叫方式」。正式站的排程接線（pg_cron／pg_net
// 呼叫這支函式）由 orchestrator 依 LS-78 授權狀態決定，不在本票落地範圍——見
// migration 檔頭「規格分歧與取捨 c)」。

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { isAuthorizedServiceCall, resolveSecretKey } from "../_shared/keys.ts";

const BATCH_SIZE = 200; // 每批讀取／刪除的筆數，對齊 Storage remove() API 一次呼叫的合理批次大小。
const MAX_BATCHES = 20; // 安全上限（20 × 200 = 4000 筆／次 invocation）：避免佇列量體異常大時單次執行時間失控。
const MAX_ATTEMPTS = 5; // 超過這個重試次數視為死信，SELECT 不再選到（停放，見上方 R3 說明）。
const DELETE_CHUNK_SIZE = 50; // dequeue 時 .in() 帶的 id 數上限（i3），避免 URL 過長。

// LS-213 範圍 2（來源 LS-96 comment 996220e9，本機容器實測確認：PUT 一個物件到
// media bucket、刻意不 insert media 列，purge_expired() 執行後 purge_storage_queue
// 未收到這筆，物件仍原封不動留在 storage.objects——purge_expired()／既有的
// purge_storage_queue 消化邏輯只處理「media 列被硬刪之後」的方向，不會反向掃描
// storage.objects 找「從未有對應 media 列」的物件）：
//   ORPHAN_SCAN_BATCH_SIZE：每次 invocation 最多「候選」（R2 起：真正超過寬限期
//     且形狀合規的物件，不是看過的檔案數，見下方 scanFamilyOrphans）數上限，
//     避免單次 invocation 執行時間失控——與上面既有的 BATCH_SIZE／MAX_BATCHES
//     是同一種安全上限精神，只是這裡的成本主要來自 storage.list() 的分層呼叫
//     次數與 media 反查次數，不是佇列列數。
//   ORPHAN_GRACE_MS：與 private.soft_delete_unreferenced_media() 的預設寬限期
//     （'24 hours'，見 supabase/migrations/20260906050606_soft_delete_unreferenced_media.sql
//     與 docs/API.md §6）同一個 24 小時——避免正常上傳流程中「Storage PUT 剛
//     完成、insert media 列還沒來得及跑」的物件被誤判為孤兒。兩處常數各自獨立
//     維護（一個是 SQL interval 常值、一個是 Edge Function 的毫秒常數），改動時
//     必須同步兩處與 docs/API.md 的說明。
//   LIST_PAGE_SIZE：storage.list() 單頁上限，用 offset 續頁涵蓋超過一頁的資料夾
//     （R2，merge-review R1 F3：原版本每層只查一頁，超過 1000 項的資料夾第
//     1001 項之後永遠看不到）。
//
// R2（merge-review R1 comment 80d7242c，PR #339 head c0cc2d9，F1／F2／F3 三個
// 問題重寫本節掃描邏輯，詳細背景見 supabase/migrations/
// 20260906050606_soft_delete_unreferenced_media.sql 檔頭 R2 段與 1d／1e 段）：
//   F1（major，實測重現餓死）：原本 `considered` 計「看過的檔案數」（含正常有
//     對應列、還在寬限期內的物件），而且每次 invocation 都從 bucket 根目錄重頭
//     走、沒有續掃游標——storage.list() 預設 sortBy=name asc，排序在前的家庭
//     一旦累積夠多物件，預算就在那裡用完，後面所有家庭永遠掃不到，且回應外觀
//     跟「沒有孤兒」無法區分。改法：(a) `considered` 只在確認「形狀合規＋超過
//     寬限期」時才 +1（scanFamilyOrphans 裡）；(b) 持久化續掃游標
//     （public.orphan_scan_cursor，見 migration 1d 段），家庭清單走 round-robin
//     ——從游標之後開始、繞回開頭，直到繞完一整圈（scanCompleted=true）或候選
//     預算用完，兩者先到就停，保證每次 invocation 都在往前推進，不會困在同一批
//     家庭；(c) 回應與 log 明示 scanCompleted／cursor，不再跟「無孤兒」同外觀。
//   F2（major，實測重現 HTTP 414）：原本用兩支 `.in()` GET 查詢反查
//     candidatePaths（上限 500），90 條路徑就撞 URI 過長。改用
//     public.purge_storage_unknown_media_paths() RPC（POST body 傳陣列，見
//     migration 1e 段），一次反查一整個家庭的候選路徑，沒有 URL 長度上限。
//   F3（minor）：(i) 四層 list() 都加 offset 續頁（listAllPaged）；(ii) 這支函式
//     的呼叫點從佇列消化迴圈**之前**移到**之後**（見檔尾 Deno.serve），讓既有
//     硬刪路徑產生的佇列優先消化，掃描慢不會拖延既有清除工作——新掃到的孤兒改成
//     下一次 invocation 才被消化（一次 invocation 的延遲，換取既有佇列不被拖累）。
const ORPHAN_SCAN_BATCH_SIZE = 500;
const ORPHAN_GRACE_MS = 24 * 60 * 60 * 1000;
const LIST_PAGE_SIZE = 1000;

// 比照 supabase/migrations/20260904060700_avatar_object_path.sql 的
// private.is_media_object_path()（原檔／縮圖那一支形狀，不含 avatars/ 分支——
// 頭像路徑在下面掃描時直接跳過那個資料夾，不會走到這支 regex）。
const MEDIA_OBJECT_PATH_RE =
  /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/(\d{4})\/(0[1-9]|1[0-2])\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?:_thumb)?\.(?:jpg|jpeg|png|heic|heif|mp4|mov)$/;

interface QueueRow {
  id: string;
  bucket_id: string;
  object_path: string;
}

// 直接用官方的 SupabaseClient 型別（未帶 Database 泛型，同 createClient() 在本檔
// 沒有生成型別可用時的既有用法），不手刻一份對照 storage／postgrest 型別的最小
// 介面——那份介面容易漏掉真正型別的欄位（例如 FileObject 的 id 在資料夾項目上是
// null）而在 `deno check` 才被抓到。`ReturnType<typeof createClient>` 看似更精確，
// 但因為 createClient 本身是多載泛型函式，不帶呼叫引數推導出來的型別與呼叫端
// `createClient(url, key)` 實際解析到的多載不是同一個，反而在 deno check 炸出
// 兩者不相容——直接用未帶泛型的 SupabaseClient（等同全部型別參數走預設值）最穩。
type AdminClient = SupabaseClient;
type StorageBucket = ReturnType<AdminClient["storage"]["from"]>;

interface StorageEntry {
  id: string | null;
  name: string;
  created_at?: string | null;
}

function chunk<T>(items: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) {
    out.push(items.slice(i, i + size));
  }
  return out;
}

// R2 F3（i）：分頁走完一個路徑底下的所有項目，不假設一頁（1000 筆）就是全部。
// 失敗時把原因塞進 warnings 並回傳 null（呼叫端據此跳過這個分支，不當成「這裡是
// 空的」悄悄放行）。
async function listAllPaged(
  bucket: StorageBucket,
  path: string,
  warnings: string[],
  label: string,
): Promise<StorageEntry[] | null> {
  const all: StorageEntry[] = [];
  let offset = 0;
  for (;;) {
    const { data, error } = await bucket.list(path, {
      limit: LIST_PAGE_SIZE,
      offset,
    });
    if (error) {
      warnings.push(`orphan scan：列出 ${label} 失敗：${error.message}`);
      return null;
    }
    if (!data || data.length === 0) break;
    all.push(...data);
    if (data.length < LIST_PAGE_SIZE) break;
    offset += LIST_PAGE_SIZE;
  }
  return all;
}

// R2 F1（b）：讀寫 public.orphan_scan_cursor（單列，bucket_id='media'）。讀取
// 失敗 fail-open——從頭開始掃，頂多重複掃到已經掃過的家庭，不影響正確性，只
// influence 這次 invocation 的公平性；寫入失敗只記 warning，不影響這次已經算好
// 的 enqueued 結果（下次 invocation 的續掃點會退回上一個游標，最壞情況是多繞
// 一點路，不會漏掃）。
async function readScanCursor(
  supabase: AdminClient,
  warnings: string[],
): Promise<string | null> {
  const { data, error } = await supabase
    .from("orphan_scan_cursor")
    .select("last_family_id")
    .eq("bucket_id", "media")
    .maybeSingle();
  if (error) {
    warnings.push(`orphan scan：讀取續掃游標失敗：${error.message}`);
    return null;
  }
  const row = data as { last_family_id: string | null } | null;
  return row?.last_family_id ?? null;
}

async function writeScanCursor(
  supabase: AdminClient,
  lastFamilyId: string | null,
  warnings: string[],
): Promise<void> {
  const { error } = await supabase
    .from("orphan_scan_cursor")
    .upsert(
      {
        bucket_id: "media",
        last_family_id: lastFamilyId,
        updated_at: new Date().toISOString(),
      },
      { onConflict: "bucket_id" },
    );
  if (error) {
    warnings.push(`orphan scan：寫入續掃游標失敗：${error.message}`);
  }
}

// R2：一次處理完一個家庭前綴的所有 year/month/file（原子單位，不在家庭內部中途
// 停下——理由見上方 F1 說明：至少保證每次 invocation 對「這一個家庭」的候選數
// 全部算完，round-robin 才有意義；若單一家庭的候選數就超過
// ORPHAN_SCAN_BATCH_SIZE，這裡仍會把它處理完（軟上限，不是硬中斷），代價是那次
// invocation 會比預算稍貴，換取「至少一個完整家庭前進」的簡單保證）。回傳這個
// 家庭貢獻的候選數與新排入佇列數。
async function scanFamilyOrphans(
  bucket: StorageBucket,
  supabase: AdminClient,
  familyId: string,
  cutoffMs: number,
  warnings: string[],
): Promise<{ considered: number; enqueued: number }> {
  const yearEntries = await listAllPaged(
    bucket,
    familyId,
    warnings,
    `${familyId}/`,
  );
  if (yearEntries === null) return { considered: 0, enqueued: 0 };

  let considered = 0;
  const candidatePaths: string[] = [];

  for (const yearEntry of yearEntries) {
    if (yearEntry.id !== null) continue; // 檔案，不是資料夾。
    if (yearEntry.name === "avatars") continue; // 頭像路徑不寫 media 表，排除（票文範圍 2）。

    const yearPath = `${familyId}/${yearEntry.name}`;
    const monthEntries = await listAllPaged(
      bucket,
      yearPath,
      warnings,
      `${yearPath}/`,
    );
    if (monthEntries === null) continue;

    for (const monthEntry of monthEntries) {
      if (monthEntry.id !== null) continue;

      const monthPath = `${yearPath}/${monthEntry.name}`;
      const fileEntries = await listAllPaged(
        bucket,
        monthPath,
        warnings,
        `${monthPath}/`,
      );
      if (fileEntries === null) continue;

      for (const fileEntry of fileEntries) {
        if (fileEntry.id === null) continue; // 巢狀資料夾，不合法形狀，跳過。
        const path = `${monthPath}/${fileEntry.name}`;
        if (!MEDIA_OBJECT_PATH_RE.test(path)) continue; // 不是本規約認得的物件形狀——R2 F1：不計入候選預算。
        const createdAtMs = fileEntry.created_at
          ? Date.parse(fileEntry.created_at)
          : NaN;
        if (!Number.isFinite(createdAtMs) || createdAtMs > cutoffMs) continue; // 還在寬限期內——R2 F1：不計入候選預算。
        considered++; // R2 F1：預算只計「候選（形狀合規＋超過寬限期）」，不是看過的檔案數。
        candidatePaths.push(path);
      }
    }
  }

  if (candidatePaths.length === 0) return { considered, enqueued: 0 };

  // R2 F2：一次 RPC 反查整個家庭的候選路徑，取代原本的 GET .in() 查詢字串（見
  // migration 第 1e 段），沒有 URL 長度上限。
  const { data: orphanPathsRaw, error: filterError } = await supabase.rpc(
    "purge_storage_unknown_media_paths",
    { p_paths: candidatePaths },
  );
  if (filterError) {
    warnings.push(
      `orphan scan：對照 media 表失敗（${familyId}）：${filterError.message}`,
    );
    return { considered, enqueued: 0 };
  }
  const orphanPaths = (orphanPathsRaw as string[] | null) ?? [];
  if (orphanPaths.length === 0) return { considered, enqueued: 0 };

  // service_role 對 purge_storage_queue 只有 select／delete（既有設計，見
  // migration 第 2 段），沒有 insert——透過 SECURITY DEFINER 函式表達「這批
  // 路徑（同一家庭）需要排入清除佇列」，不是直接 upsert 這張表（LS-213 範圍
  // 2 動工時 supabase functions serve 實測重現 permission denied，見
  // supabase/migrations/20260906050606_soft_delete_unreferenced_media.sql
  // 第 1c 段）。
  const { data: enqueuedCount, error: rpcError } = await supabase.rpc(
    "purge_storage_queue_enqueue_orphans",
    {
      p_bucket_id: "media",
      p_family_id: familyId,
      p_object_paths: orphanPaths,
    },
  );
  if (rpcError) {
    warnings.push(
      `orphan scan：寫入 purge_storage_queue 失敗（${familyId}）：${rpcError.message}`,
    );
    return { considered, enqueued: 0 };
  }

  return {
    considered,
    enqueued: typeof enqueuedCount === "number"
      ? enqueuedCount
      : orphanPaths.length,
  };
}

interface OrphanScanResult {
  enqueued: number;
  scanCompleted: boolean;
  cursor: string | null;
}

// LS-213 範圍 2：分頁掃 media bucket（{family_id}/{yyyy}/{mm}/{file} 三層資料夾）
// 找出「Storage 有物件、但 public.media 完全沒有列引用它（不論 storage_path 或
// thumb_path）」且建立時間超過寬限期的物件，寫進 public.purge_storage_queue
// （media_id 留 NULL——這批物件從來就沒有對應的 media 列，不像既有的硬刪路徑
// 那樣附得上 media_id）。**只寫入佇列，不在這裡自己呼叫 storage.remove()**：
// 新 enqueue 的列留給下一次 invocation 的既有消化迴圈處理（R2 起呼叫順序調整為
// 「先消化既有佇列、後掃描」，見檔尾 Deno.serve 與上方 F3 說明），重用已經測過、
// 有 attempts／退避／死信與 confirmed-delete 核對的既有消化邏輯，不重新實作一套
// 刪除路徑（DRY，且不重複「額度」顧慮——這批物件從來沒有 media 列，
// families.storage_used_bytes 從未把它們算進去，透過 purge_storage_queue 走既有
// 路徑刪除也完全不會觸發 media 表的 AFTER DELETE/UPDATE trigger，沒有重複扣款的
// 可能）。`purge_storage_queue_enqueue_orphans` 的 `on conflict do nothing`
// 天生冪等，同一個物件路徑下次掃到、若還沒被消化，不會報錯也不會產生重複列。
//
// R2（merge-review R1 F1，家庭層級 round-robin＋持久化游標）：見上方常數區塊與
// migration 1d 段的完整說明。回傳值含 scanCompleted／cursor，讓呼叫端／觀測面
// 能區分「這次掃完一整圈」跟「還沒掃完就先返回」，不再跟「沒有孤兒」同外觀。
async function scanOrphanStorageObjects(
  supabase: AdminClient,
  warnings: string[],
): Promise<OrphanScanResult> {
  const cutoffMs = Date.now() - ORPHAN_GRACE_MS;
  const bucket = supabase.storage.from("media");

  const resumeAfter = await readScanCursor(supabase, warnings);

  const familyEntries = await listAllPaged(
    bucket,
    "",
    warnings,
    "media bucket 根目錄",
  );
  if (familyEntries === null) {
    return { enqueued: 0, scanCompleted: false, cursor: resumeAfter };
  }

  const familyIds = familyEntries
    .filter((e) => e.id === null) // bucket 頂層不該有檔案，只認資料夾（家庭前綴）。
    .map((e) => e.name)
    .sort();

  if (familyIds.length === 0) {
    await writeScanCursor(supabase, null, warnings);
    return { enqueued: 0, scanCompleted: true, cursor: null };
  }

  // round-robin：從游標之後的第一個家庭開始（storage.list() 預設
  // sortBy=name asc 的字典序）；找不到比游標更大的（表示上次已經繞到最後）就
  // 從頭開始。
  let startIndex = 0;
  if (resumeAfter !== null) {
    const idx = familyIds.findIndex((f) => f > resumeAfter);
    startIndex = idx === -1 ? 0 : idx;
  }

  let considered = 0;
  let enqueued = 0;
  let lastProcessed: string | null = null;
  let scanCompleted = false;

  for (let visited = 0; visited < familyIds.length; visited++) {
    const familyId = familyIds[(startIndex + visited) % familyIds.length];
    const result = await scanFamilyOrphans(
      bucket,
      supabase,
      familyId,
      cutoffMs,
      warnings,
    );
    considered += result.considered;
    enqueued += result.enqueued;
    lastProcessed = familyId;

    if (visited + 1 >= familyIds.length) {
      scanCompleted = true; // 繞完一整圈：這次 invocation 內每個家庭都處理過一次。
      break;
    }
    if (considered >= ORPHAN_SCAN_BATCH_SIZE) {
      break; // 候選預算用完，停在這個已完整處理的家庭，下次從下一個家庭續掃。
    }
  }

  const newCursor = scanCompleted ? null : lastProcessed;
  await writeScanCursor(supabase, newCursor, warnings);

  return { enqueued, scanCompleted, cursor: newCursor };
}

Deno.serve(async (req: Request) => {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const authEnv = {
    SUPABASE_SECRET_KEYS: Deno.env.get("SUPABASE_SECRET_KEYS"),
    SUPABASE_SERVICE_ROLE_KEY: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),
  };
  const secretKey = resolveSecretKey(authEnv);

  if (!secretKey || !supabaseUrl) {
    // fail loud：環境變數缺失是部署設定錯誤，不是「當作沒有佇列可處理」悄悄回 200。
    return new Response(
      JSON.stringify({
        error:
          "SUPABASE_URL／secret key 未設定（SUPABASE_SECRET_KEYS 或 SUPABASE_SERVICE_ROLE_KEY 皆缺）",
      }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }

  if (!isAuthorizedServiceCall(req.headers, authEnv)) {
    return new Response(
      JSON.stringify({ error: "只接受 service_role 呼叫" }),
      { status: 401, headers: { "Content-Type": "application/json" } },
    );
  }

  const supabase = createClient(supabaseUrl, secretKey);

  let processed = 0;
  const failures: { object_path: string; error: string }[] = [];
  const warnings: string[] = [];
  let batches = 0;

  // 記錄「這次 invocation 已經確認過存在／不存在」的 bucket，避免同一個 bucket
  // 在同一次 invocation 裡被 getBucket() 反覆確認（多個批次、同一個 bucket 常見，
  // 目前唯一的值就是 'media'）。
  const bucketExists = new Map<string, boolean>();

  async function markFailed(rows: QueueRow[], message: string) {
    if (rows.length === 0) return;
    const { error } = await supabase.rpc("purge_storage_queue_mark_failed", {
      p_ids: rows.map((r) => r.id),
      p_error: message,
    });
    if (error) {
      // 記失敗這個動作本身失敗：不影響這一輪已經算好的 processed／failures，
      // 只多記一條 warning——下次排程對這幾筆的 next_attempt_at 仍是舊值，
      // 最壞情況是比預期早一點被重試，不是資料錯誤。
      warnings.push(
        `purge_storage_queue_mark_failed 呼叫失敗：${error.message}`,
      );
    }
  }

  // 迴圈直到佇列清空（含：剩下的列全部在退避中或已死信停放，SELECT 篩不到）、或
  // 達到 MAX_BATCHES 安全上限。每一輪都重新查詢：這一輪已經 dequeue 掉的列、或
  // 剛被標記失敗（next_attempt_at 設進未來）的列，都不會再出現在下一輪的查詢
  // 結果——不需要「整批確認完成才繼續」這種額外條件（R2 版本的該條件正是 F1 的
  // 成因之一，R3 移除，見檔頭）。
  while (batches < MAX_BATCHES) {
    const nowIso = new Date().toISOString();
    const { data: queue, error: queueError } = await supabase
      .from("purge_storage_queue")
      .select("id, bucket_id, object_path")
      .lt("attempts", MAX_ATTEMPTS)
      .or(`next_attempt_at.is.null,next_attempt_at.lte.${nowIso}`)
      .order("enqueued_at", { ascending: true })
      .limit(BATCH_SIZE)
      .returns<QueueRow[]>();

    if (queueError) {
      return new Response(
        JSON.stringify({
          processed,
          failed: failures.length,
          failures,
          warnings,
          error: `讀取 purge_storage_queue 失敗：${queueError.message}`,
        }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }

    if (!queue || queue.length === 0) break;
    batches++;

    // 依 bucket_id 分組：目前唯一的值是 'media'（media_storage_queue_sync trigger
    // 的既有慣例），但不假設——storage.remove() 的呼叫本身就是逐 bucket 進行的。
    const byBucket = new Map<string, QueueRow[]>();
    for (const row of queue) {
      const list = byBucket.get(row.bucket_id) ?? [];
      list.push(row);
      byBucket.set(row.bucket_id, list);
    }

    const doneIds: string[] = [];

    for (const [bucketId, rows] of byBucket) {
      const paths = rows.map((r) => r.object_path);
      const { data: removed, error: removeError } = await supabase.storage.from(
        bucketId,
      ).remove(paths);

      if (removeError) {
        // remove() 呼叫本身出錯（非「物件不存在」，那種情況呼叫本身不會出錯，見
        // 檔頭）：真正的環境／服務問題，記一次失敗，交給 attempts／退避處理。
        await markFailed(rows, removeError.message);
        for (const r of rows) {
          failures.push({
            object_path: r.object_path,
            error: removeError.message,
          });
        }
        continue;
      }

      const removedPaths = new Set((removed ?? []).map((f) => f.name));
      const confirmedDone: QueueRow[] = [];
      const unconfirmed: QueueRow[] = [];
      for (const r of rows) {
        if (removedPaths.has(r.object_path)) {
          confirmedDone.push(r);
        } else {
          unconfirmed.push(r);
        }
      }

      if (unconfirmed.length > 0) {
        // remove() 對「bucket 本身打不到」與「bucket 存在但物件不存在」回傳完全
        // 相同（data: []、無 error，見檔頭）——額外呼叫 getBucket() 才能區分兩者
        // （F1 修法 (ii)，與 (i) 並用）。同一個 bucket 在這次 invocation 只確認
        // 一次。
        let exists = bucketExists.get(bucketId);
        if (exists === undefined) {
          const { error: bucketError } = await supabase.storage.getBucket(
            bucketId,
          );
          exists = !bucketError;
          bucketExists.set(bucketId, exists);
          if (bucketError) {
            warnings.push(
              `getBucket('${bucketId}') 失敗：${bucketError.message}`,
            );
          }
        }

        if (exists) {
          // bucket 確認存在，這些路徑沒出現在 data[] 裡＝物件已經不存在（這次
          // 呼叫就發現，或上一次已經刪除但 dequeue 失敗留下殘影）——目的已達成，
          // 安全 dequeue，不需要等 attempts 用盡（F1 修法 (ii)）。
          confirmedDone.push(...unconfirmed);
        } else {
          // bucket 本身打不到（R1 F5 的洞）：不能斷定物件狀態，全部記一次失敗，
          // 交給 attempts／退避／死信處理，不 dequeue。
          const message =
            `bucket 無法確認存在，路徑未在 remove() 回傳中確認已刪`;
          await markFailed(unconfirmed, message);
          for (const r of unconfirmed) {
            failures.push({ object_path: r.object_path, error: message });
          }
        }
      }

      for (const r of confirmedDone) {
        doneIds.push(r.id);
        processed++;
      }
    }

    if (doneIds.length > 0) {
      // i3：分段 DELETE（每段 ≤ DELETE_CHUNK_SIZE 個 id），避免單次 .in() 的 URL
      // 過長。任一段失敗不中止迴圈——那一段的 Storage 物件已經確認刪除，下一次
      // 呼叫的 remove() 會因為物件不存在、bucket 確認存在，透過上方 (ii) 的機制
      // 自動再次 dequeue，不會變成毒丸（只是多做一次無意義的 API 呼叫）。
      for (const idsChunk of chunk(doneIds, DELETE_CHUNK_SIZE)) {
        const { error: deleteError } = await supabase
          .from("purge_storage_queue")
          .delete()
          .in("id", idsChunk);

        if (deleteError) {
          warnings.push(
            `清空 purge_storage_queue 失敗（Storage 物件已確認刪除，下次呼叫會` +
              `自動重新 dequeue，見檔頭 F1 修法 (ii)）：${deleteError.message}`,
          );
        }
      }
    }
  }

  // R2（merge-review R1 F3 ii）：孤兒掃描排在既有佇列消化迴圈**之後**——既有
  // 硬刪路徑（purge_expired() 硬刪 media 之後由 trigger 入列）產生的佇列列優先
  // 消化，掃描（storage.list() 分層呼叫，成本相對高）不會拖延既有清除工作。這次
  // 掃到的孤兒留給下一次 invocation 的迴圈消化（一次 invocation 的延遲）。
  const orphanScan = await scanOrphanStorageObjects(supabase, warnings);

  // R4（merge-review R3 minor 2，comment 04987043）：死信停放本身沒有任何觀測
  // 出口——停放之後 EF 回應永遠是 processed:0/failed:0 HTTP 200，跟「佇列本來
  // 就空」看起來一樣，Storage 清除可以永久停擺而沒有人知道。最小改動：查一次
  // 目前停放（attempts >= MAX_ATTEMPTS）的列數，放進回應 JSON 與一行 log；不
  // 擴充 private.purge_runs（那張表是 purge_expired() 的 DB 端結果，EF 是獨立
  // invocation，混進同一張表只會讓兩件事的觀測耦合）。巡檢 SQL 見
  // docs/API.md §6：`select count(*) from public.purge_storage_queue where
  // attempts >= 5`，由 orchestrator 接 i4 排程時一併接進巡檢。
  const { count: parked } = await supabase
    .from("purge_storage_queue")
    .select("id", { count: "exact", head: true })
    .gte("attempts", MAX_ATTEMPTS);
  console.log(
    `purge-storage: parked=${
      parked ?? 0
    } orphanEnqueued=${orphanScan.enqueued} ` +
      `orphanScanCompleted=${orphanScan.scanCompleted} orphanScanCursor=${
        orphanScan.cursor ?? "null"
      }`,
  );

  return new Response(
    JSON.stringify({
      processed,
      failed: failures.length,
      failures,
      warnings,
      parked: parked ?? 0,
      orphanEnqueued: orphanScan.enqueued,
      // R2（merge-review R1 F1 c）：讓「還沒掃完一輪」與「這個 bucket 真的沒有
      // 孤兒」在回應裡可以區分——scanCompleted=false 時 cursor 非 null，代表下次
      // invocation 會從這裡續掃，不是「已經確認整個 bucket 都乾淨」。
      orphanScanCompleted: orphanScan.scanCompleted,
      orphanScanCursor: orphanScan.cursor,
    }),
    {
      status: failures.length > 0 || warnings.length > 0 ? 207 : 200,
      headers: { "Content-Type": "application/json" },
    },
  );
});
