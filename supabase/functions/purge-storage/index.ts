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
//   ORPHAN_SCAN_BATCH_SIZE：每次 invocation 最多「考慮」（含形狀不符、寬限期內、
//     已有對應列）的物件數上限，避免家庭／物件量體異常大時單次執行時間失控——與
//     上面既有的 BATCH_SIZE／MAX_BATCHES 是同一種安全上限精神，只是這裡的成本
//     主要來自 storage.list() 的分層呼叫次數，不是佇列列數。
//   ORPHAN_GRACE_MS：與 private.soft_delete_unreferenced_media() 的預設寬限期
//     （'24 hours'，見 supabase/migrations/20260906050606_soft_delete_unreferenced_media.sql
//     與 docs/API.md §6）同一個 24 小時——避免正常上傳流程中「Storage PUT 剛
//     完成、insert media 列還沒來得及跑」的物件被誤判為孤兒。兩處常數各自獨立
//     維護（一個是 SQL interval 常值、一個是 Edge Function 的毫秒常數），改動時
//     必須同步兩處與 docs/API.md 的說明。
const ORPHAN_SCAN_BATCH_SIZE = 500;
const ORPHAN_GRACE_MS = 24 * 60 * 60 * 1000;

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

interface MediaPathRow {
  storage_path: string | null;
  thumb_path: string | null;
}

// 直接用官方的 SupabaseClient 型別（未帶 Database 泛型，同 createClient() 在本檔
// 沒有生成型別可用時的既有用法），不手刻一份對照 storage／postgrest 型別的最小
// 介面——那份介面容易漏掉真正型別的欄位（例如 FileObject 的 id 在資料夾項目上是
// null）而在 `deno check` 才被抓到。`ReturnType<typeof createClient>` 看似更精確，
// 但因為 createClient 本身是多載泛型函式，不帶呼叫引數推導出來的型別與呼叫端
// `createClient(url, key)` 實際解析到的多載不是同一個，反而在 deno check 炸出
// 兩者不相容——直接用未帶泛型的 SupabaseClient（等同全部型別參數走預設值）最穩。
type AdminClient = SupabaseClient;

function chunk<T>(items: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) {
    out.push(items.slice(i, i + size));
  }
  return out;
}

// LS-213 範圍 2：分頁掃 media bucket（{family_id}/{yyyy}/{mm}/{file} 三層資料夾）
// 找出「Storage 有物件、但 public.media 完全沒有列引用它（不論 storage_path 或
// thumb_path）」且建立時間超過寬限期的物件，寫進 public.purge_storage_queue
// （media_id 留 NULL——這批物件從來就沒有對應的 media 列，不像既有的硬刪路徑
// 那樣附得上 media_id）。**只寫入佇列，不在這裡自己呼叫 storage.remove()**：
// 這批新 enqueue 的列會被下面既有的 while 迴圈（同一次 invocation）當成一般
// 佇列列處理，重用已經測過、有 attempts／退避／死信與 confirmed-delete 核對的
// 既有消化邏輯，不重新實作一套刪除路徑（DRY，且不重複「額度」顧慮——這批物件
// 從來沒有 media 列，families.storage_used_bytes 從未把它們算進去，透過
// purge_storage_queue 走既有路徑刪除也完全不會觸發 media 表的
// AFTER DELETE/UPDATE trigger，沒有重複扣款的可能）。
// upsert(..., ignoreDuplicates: true) 天生冪等：同一個物件路徑下次掃到、若還沒
// 被消化，`on conflict (bucket_id, object_path) do nothing`（既有 unique
// constraint）會讓這次呼叫悄悄跳過，不會報錯也不會產生重複列。
async function scanOrphanStorageObjects(
  supabase: AdminClient,
  warnings: string[],
): Promise<number> {
  const cutoffMs = Date.now() - ORPHAN_GRACE_MS;
  let considered = 0;
  let enqueued = 0;
  const bucket = supabase.storage.from("media");

  const { data: familyEntries, error: familyErr } = await bucket.list("", {
    limit: 1000,
  });
  if (familyErr) {
    warnings.push(
      `orphan scan：列出 media bucket 根目錄失敗：${familyErr.message}`,
    );
    return 0;
  }

  familyLoop: for (const familyEntry of familyEntries ?? []) {
    if (considered >= ORPHAN_SCAN_BATCH_SIZE) break familyLoop;
    if (familyEntry.id !== null) continue; // bucket 頂層不該有檔案，只認資料夾（家庭前綴）。
    const familyId = familyEntry.name;

    const { data: yearEntries, error: yearErr } = await bucket.list(familyId, {
      limit: 1000,
    });
    if (yearErr) {
      warnings.push(`orphan scan：列出 ${familyId}/ 失敗：${yearErr.message}`);
      continue familyLoop;
    }

    yearLoop: for (const yearEntry of yearEntries ?? []) {
      if (considered >= ORPHAN_SCAN_BATCH_SIZE) break familyLoop;
      if (yearEntry.id !== null) continue yearLoop; // 檔案，不是資料夾。
      if (yearEntry.name === "avatars") continue yearLoop; // 頭像路徑不寫 media 表，排除（票文範圍 2）。

      const yearPath = `${familyId}/${yearEntry.name}`;
      const { data: monthEntries, error: monthErr } = await bucket.list(
        yearPath,
        { limit: 1000 },
      );
      if (monthErr) {
        warnings.push(
          `orphan scan：列出 ${yearPath}/ 失敗：${monthErr.message}`,
        );
        continue yearLoop;
      }

      monthLoop: for (const monthEntry of monthEntries ?? []) {
        if (considered >= ORPHAN_SCAN_BATCH_SIZE) break familyLoop;
        if (monthEntry.id !== null) continue monthLoop;

        const monthPath = `${yearPath}/${monthEntry.name}`;
        const { data: fileEntries, error: fileErr } = await bucket.list(
          monthPath,
          { limit: 1000 },
        );
        if (fileErr) {
          warnings.push(
            `orphan scan：列出 ${monthPath}/ 失敗：${fileErr.message}`,
          );
          continue monthLoop;
        }

        const candidatePaths: string[] = [];
        for (const fileEntry of fileEntries ?? []) {
          if (considered >= ORPHAN_SCAN_BATCH_SIZE) break;
          if (fileEntry.id === null) continue; // 巢狀資料夾，不合法形狀，跳過。
          considered++;

          const path = `${monthPath}/${fileEntry.name}`;
          if (!MEDIA_OBJECT_PATH_RE.test(path)) continue; // 不是本規約認得的物件形狀。
          const createdAtMs = fileEntry.created_at
            ? Date.parse(fileEntry.created_at)
            : NaN;
          if (!Number.isFinite(createdAtMs) || createdAtMs > cutoffMs) continue; // 還在寬限期內。
          candidatePaths.push(path);
        }

        if (candidatePaths.length === 0) continue monthLoop;

        // 對照 public.media：這批路徑裡哪些已經是某一列的 storage_path 或
        // thumb_path——分兩支查詢（storage_path、thumb_path 各查一次）而不是拼一句
        // OR filter，避免物件路徑進到 PostgREST filter 字串時的逃逸／引號問題。
        const [byStorage, byThumb] = await Promise.all([
          supabase.from("media").select("storage_path, thumb_path").in(
            "storage_path",
            candidatePaths,
          )
            .returns<MediaPathRow[]>(),
          supabase.from("media").select("storage_path, thumb_path").in(
            "thumb_path",
            candidatePaths,
          )
            .returns<MediaPathRow[]>(),
        ]);
        if (byStorage.error || byThumb.error) {
          warnings.push(
            `orphan scan：對照 media 表失敗（${monthPath}）：${
              (byStorage.error ?? byThumb.error)!.message
            }`,
          );
          continue monthLoop;
        }
        const knownPaths = new Set<string>();
        for (
          const row of [...(byStorage.data ?? []), ...(byThumb.data ?? [])]
        ) {
          if (row.storage_path) knownPaths.add(row.storage_path);
          if (row.thumb_path) knownPaths.add(row.thumb_path);
        }

        const orphanRows: {
          bucket_id: string;
          object_path: string;
          family_id: string;
          media_id: null;
        }[] = candidatePaths
          .filter((path) => !knownPaths.has(path))
          .map((path) => ({
            bucket_id: "media",
            object_path: path,
            family_id: familyId,
            media_id: null,
          }));

        if (orphanRows.length === 0) continue monthLoop;

        const { error: upsertError } = await supabase.from(
          "purge_storage_queue",
        ).upsert(orphanRows, {
          onConflict: "bucket_id,object_path",
          ignoreDuplicates: true,
        });
        if (upsertError) {
          warnings.push(
            `orphan scan：寫入 purge_storage_queue 失敗（${monthPath}）：${upsertError.message}`,
          );
          continue monthLoop;
        }
        enqueued += orphanRows.length;
      }
    }
  }

  return enqueued;
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

  // LS-213 範圍 2：先掃一次 Storage 找「從未有對應 media 列」的孤兒物件、寫進
  // purge_storage_queue，再讓下面既有的 while 迴圈把它們（連同既有硬刪路徑產生的
  // 佇列列）一起消化掉，同一次 invocation 內完成 enqueue＋刪除，不必等下一次排程。
  const orphanEnqueued = await scanOrphanStorageObjects(supabase, warnings);

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
    `purge-storage: parked=${parked ?? 0} orphanEnqueued=${orphanEnqueued}`,
  );

  return new Response(
    JSON.stringify({
      processed,
      failed: failures.length,
      failures,
      warnings,
      parked: parked ?? 0,
      orphanEnqueued,
    }),
    {
      status: failures.length > 0 || warnings.length > 0 ? 207 : 200,
      headers: { "Content-Type": "application/json" },
    },
  );
});
