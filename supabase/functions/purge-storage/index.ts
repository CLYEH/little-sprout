// LS-153 — 消化 public.purge_storage_queue：呼叫 Storage Admin API 實際刪除
// private.purge_expired() 硬刪 media 列之後留下的物件路徑，成功即刪除該筆佇列列
// （純佇列語意，見 supabase/migrations/20260903110908_purge_expired.sql 對
// purge_storage_queue 的說明——沒有處理狀態欄，處理完直接 DELETE，失敗的列留著
// 下次重試，天生冪等）。
//
// R2（merge-review R1 comment e71a797f，minor findings，已用本機
// `supabase functions serve`（經 scripts/ops/supabase-lock.sh）實測修正）：
//   - **逐路徑核對回傳**（R1 的洞：storage.remove() 對「整個 bucket 都打不到」
//     這種情況也回傳 `error: null`——本機實測對一個不存在的 bucket 呼叫
//     `.remove(["whatever/path.jpg"])` 得到 `{ data: [], error: null }`，R1
//     版本把「沒有 error」直接當「整批都處理完成」，會把這種完全沒真的刪除任何
//     東西的批次全部 dequeue，佇列紀錄永久遺失、物件保證再也清不到）。
//     真實回傳格式（同樣本機實測，對一個存在的 bucket 傳兩個路徑，一個真的存在、
//     一個不存在）：`data` 陣列**只包含真的被移除的物件**（`name` 欄位＝輸入時的
//     完整路徑字串，不含 bucket 前綴），不存在的路徑**不會**出現在 `data` 裡、
//     也不會讓整體回傳 error。改法：只有出現在 `data[].name` 裡的路徑才視為
//     「這次呼叫確認處理完成」，才 dequeue；不在 `data` 裡的路徑一律留在佇列，
//     下次排程重試。**已知取捨**：一個物件若在「上次呼叫已經被 Storage 真的刪除、
//     但那次呼叫在刪除佇列列之前就當掉」的極端時序下，之後每次呼叫的
//     `remove()` 都會對一個早已不存在的路徑得到「不在 data 裡、沒有 error」的
//     結果，永遠不會被判定為「確認處理完成」，佇列列會停留、每天被重試一次——
//     這是可接受的殘留成本（純粹浪費一次 API 呼叫、不造成任何資料錯誤，實際
//     發生機率也極低：必須精準卡在「remove 成功後、DELETE 佇列列之前」這個窗口
//     當掉），換來的是「絕不會把沒有真的驗證過的路徑靜默判定成已處理」這個更
//     重要的正確性保證。
//   - **批次與排序**：R1 版本一次只讀 200 筆、沒有 `order by`，佇列超過一批就會
//     永遠卡在後段（每次呼叫都重新讀同一批、因為沒有排序不保證讀到同一批，
//     也可能造成部分列永遠讀不到）。改法：`order by enqueued_at` 保證讀取順序
//     穩定，並迴圈重複讀取／處理直到佇列清空或達到安全上限（避免真的佇列量體
//     過大時單次 invocation 執行時間失控——Edge Function 有執行時間上限）。
//
// 已知限制（如實揭露，見 docs/API.md §6「自動清除」與本票 handoff）：本機已用
// `supabase functions serve --no-verify-jwt`（經 scripts/ops/supabase-lock.sh）
// 對這支函式做過端對端手動驗證（見 handoff 附的實測記錄：真實上傳物件被正確
// 移除、不存在的路徑與不存在的 bucket 都不會被誤判成功、佇列列的增減行為符合
// 預期），但**沒有**寫成 `supabase/tests/` 底下可重複執行的自動化測試——這個
// repo 目前沒有任何 Deno/Edge Function 的測試治具（連最基本的語法檢查都沒有，
// 見 handoff「風險」欄的 harness 缺口記錄），本票沒有時間從零建置。
//
// 呼叫方式：這支函式**只接受 service_role**——不是給 app client 呼叫的公開端點。
// Supabase 的 verify_jwt（預設開啟，supabase/config.toml 沒有針對本函式覆寫）先擋掉
// 沒有帶合法 JWT 的請求；下面再明確比對 Authorization Bearer token 必須等於
// SUPABASE_SERVICE_ROLE_KEY 本身——只驗證「JWT 合法」不夠，anon key 也是合法 JWT，
// 這裡要的是「呼叫者持有 service_role 金鑰」這件更窄的事。正式站的呼叫時機（pg_cron
// 排程／外部排程呼叫這支函式）由 orchestrator 依 LS-78 授權狀態決定，不在本票落地
// 範圍——見 migration 檔頭「規格分歧與取捨 c)」。

import { createClient } from "npm:@supabase/supabase-js@2";

const BATCH_SIZE = 200; // 每批讀取／刪除的筆數，對齊 Storage remove() API 一次呼叫的合理批次大小。
const MAX_BATCHES = 20; // 安全上限（20 × 200 = 4000 筆／次 invocation）：避免佇列量體異常大時單次執行時間失控。

interface QueueRow {
  id: string;
  bucket_id: string;
  object_path: string;
}

Deno.serve(async (req: Request) => {
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");

  if (!serviceRoleKey || !supabaseUrl) {
    // fail loud：環境變數缺失是部署設定錯誤，不是「當作沒有佇列可處理」悄悄回 200。
    return new Response(
      JSON.stringify({ error: "SUPABASE_URL／SUPABASE_SERVICE_ROLE_KEY 未設定" }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const bearer = authHeader.startsWith("Bearer ") ? authHeader.slice("Bearer ".length) : "";
  if (bearer !== serviceRoleKey) {
    return new Response(
      JSON.stringify({ error: "只接受 service_role 呼叫" }),
      { status: 401, headers: { "Content-Type": "application/json" } },
    );
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey);

  let processed = 0;
  const failures: { object_path: string; error: string }[] = [];
  let batches = 0;

  // 迴圈直到佇列清空、或連續 MAX_BATCHES 批都沒有清空（安全上限，見上方常數說明）。
  // 每一輪都重新查詢（不是把第一輪撈到的資料快取起來重複用）：這一輪已經 dequeue
  // 掉的列不會再出現在下一輪的查詢結果，天然避免重複處理同一筆。
  //
  // 迴圈只在「這一批剛好滿 BATCH_SIZE 筆、且整批全部確認處理完成」時才繼續下一輪
  // ——未確認處理的列不會被 dequeue，會繼續留在佇列最前面，下一輪的
  // `order by enqueued_at limit BATCH_SIZE` 只會重新讀到同一批（本機實測過：
  // 一批 3 筆、1 筆成功 2 筆失敗時，若不加這個條件，下一輪會對同樣那 2 筆失敗的
  // 路徑再打一次 remove()，得到重複的失敗紀錄，卻沒有任何新進展）——這樣才是
  // 「這批已經完全清空，佇列後面可能還有更多」的唯一可靠訊號。
  while (batches < MAX_BATCHES) {
    const { data: queue, error: queueError } = await supabase
      .from("purge_storage_queue")
      .select("id, bucket_id, object_path")
      .order("enqueued_at", { ascending: true })
      .limit(BATCH_SIZE)
      .returns<QueueRow[]>();

    if (queueError) {
      return new Response(
        JSON.stringify({ processed, failed: failures.length, failures, error: `讀取 purge_storage_queue 失敗：${queueError.message}` }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }

    if (!queue || queue.length === 0) break;

    // 依 bucket_id 分組：目前唯一的值是 'media'（media_storage_queue_sync trigger
    // 的既有慣例），但不假設——storage.remove() 的呼叫本身就是逐 bucket 進行的，
    // 佇列若日後被用來裝別的 bucket，這裡不需要改。
    const byBucket = new Map<string, QueueRow[]>();
    for (const row of queue) {
      const list = byBucket.get(row.bucket_id) ?? [];
      list.push(row);
      byBucket.set(row.bucket_id, list);
    }

    const doneIds: string[] = [];

    for (const [bucketId, rows] of byBucket) {
      const paths = rows.map((r) => r.object_path);
      const { data: removed, error: removeError } = await supabase.storage.from(bucketId).remove(paths);

      if (removeError) {
        // 整批（這個 bucket 這一輪的所有路徑）失敗：全部留在佇列，下次排程重試。
        for (const r of rows) failures.push({ object_path: r.object_path, error: removeError.message });
        continue;
      }

      // 逐路徑核對回傳（R2 修正，見檔頭）：只有真的出現在 `removed[].name` 裡的
      // 路徑才算「這次呼叫確認處理完成」。`removed` 對「本來就不存在的 bucket」
      // 也會是空陣列且沒有 error（本機實測），逐路徑核對因此同時擋住了 R1 的洞
      // （不存在的 bucket 整批被誤判成功）——不需要另外偵測 bucket 是否存在。
      const removedPaths = new Set((removed ?? []).map((f) => f.name));
      for (const r of rows) {
        if (removedPaths.has(r.object_path)) {
          doneIds.push(r.id);
          processed++;
        } else {
          failures.push({ object_path: r.object_path, error: "remove() 未在回傳的 data 中確認此路徑已處理" });
        }
      }
    }

    if (doneIds.length > 0) {
      const { error: deleteError } = await supabase
        .from("purge_storage_queue")
        .delete()
        .in("id", doneIds);

      if (deleteError) {
        // Storage 物件確實刪了，但佇列列沒清掉——下次執行會對已經不存在的物件再
        // 呼叫一次 remove()（冪等、安全，見上方 R2 已知取捨段落），只是多做一次
        // 無意義的 API 呼叫，不是資料錯誤。中止迴圈，不繼續下一批（避免同一種
        // DELETE 失敗連續發生、徒增 API 呼叫）。
        return new Response(
          JSON.stringify({
            processed,
            failed: failures.length,
            failures,
            warning: `Storage 物件已確認刪除，但清空 purge_storage_queue 失敗：${deleteError.message}`,
          }),
          { status: 207, headers: { "Content-Type": "application/json" } },
        );
      }
    }

    // 只有「這一批剛好滿 BATCH_SIZE、且整批都確認處理完成」才代表佇列前面已經
    // 清空、後面可能還有更多——其餘情況（沒滿一批＝這就是全部；有任何一筆沒被
    // 確認處理＝它會繼續卡在佇列最前面）繼續下一輪只會重複讀到同一批、重複得到
    // 同樣的結果，沒有任何新進展，直接結束。
    if (queue.length < BATCH_SIZE || doneIds.length < queue.length) break;

    batches++;
  }

  return new Response(
    JSON.stringify({ processed, failed: failures.length, failures }),
    { status: failures.length > 0 ? 207 : 200, headers: { "Content-Type": "application/json" } },
  );
});
