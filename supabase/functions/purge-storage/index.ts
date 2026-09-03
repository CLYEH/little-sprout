// LS-153 — 消化 public.purge_storage_queue：呼叫 Storage Admin API 實際刪除
// private.purge_expired() 硬刪 media 列之後留下的物件路徑，成功即刪除該筆佇列列
// （純佇列語意，見 supabase/migrations/20260903110908_purge_expired.sql 對
// purge_storage_queue 的說明——沒有處理狀態欄，處理完直接 DELETE，失敗的列留著
// 下次重試，天生冪等）。
//
// 已知限制（如實揭露，見 docs/API.md §6「自動清除」與本票 handoff）：這支函式**沒有
// 經過任何自動化測試**——本機開發環境沒有建置 Deno Edge Runtime 的整合測試（真正
// 呼叫 Storage Admin API 需要對本機 supabase_storage_little-sprout 容器打一輪完整
// 的上傳／刪除流程，這裡沒有時間建置這套治具），只有人工 code review 等級的把關。
// `purge_storage_queue` 佇列內容本身（哪些路徑該進佇列）已由
// supabase/tests/101_purge_expired.sql 完整覆蓋，缺的只是「佇列建好之後，這支函式
// 真的把它消化掉」這一段。
//
// 呼叫方式：這支函式**只接受 service_role**——不是給 app client 呼叫的公開端點。
// Supabase 的 verify_jwt（預設開啟，supabase/config.toml 沒有針對本函式覆寫）先擋掉
// 沒有帶合法 JWT 的請求；下面再明確比對 Authorization Bearer token 必須等於
// SUPABASE_SERVICE_ROLE_KEY 本身——只驗證「JWT 合法」不夠，anon key 也是合法 JWT，
// 這裡要的是「呼叫者持有 service_role 金鑰」這件更窄的事。正式站的呼叫時機（pg_cron
// 排程／外部排程呼叫這支函式）由 orchestrator 依 LS-78 授權狀態決定，不在本票落地
// 範圍——見 migration 檔頭「規格分歧與取捨 c)」。

import { createClient } from "npm:@supabase/supabase-js@2";

const BATCH_SIZE = 200; // 每次呼叫只處理一批，避免單次執行時間過長；佇列有殘留下次排程會繼續處理。

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

  const { data: queue, error: queueError } = await supabase
    .from("purge_storage_queue")
    .select("id, bucket_id, object_path")
    .limit(BATCH_SIZE)
    .returns<QueueRow[]>();

  if (queueError) {
    return new Response(
      JSON.stringify({ error: `讀取 purge_storage_queue 失敗：${queueError.message}` }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }

  if (!queue || queue.length === 0) {
    return new Response(
      JSON.stringify({ processed: 0, failed: 0 }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  }

  // 依 bucket_id 分組：目前唯一的值是 'media'（media_storage_sync 的既有慣例），但
  // 不假設——storage.remove() 的呼叫本身就是逐 bucket 進行的，佇列若日後被用來裝
  // 別的 bucket，這裡不需要改。
  const byBucket = new Map<string, QueueRow[]>();
  for (const row of queue) {
    const list = byBucket.get(row.bucket_id) ?? [];
    list.push(row);
    byBucket.set(row.bucket_id, list);
  }

  let processed = 0;
  const failures: { object_path: string; error: string }[] = [];
  const doneIds: string[] = [];

  for (const [bucketId, rows] of byBucket) {
    const paths = rows.map((r) => r.object_path);
    const { error: removeError } = await supabase.storage.from(bucketId).remove(paths);

    if (removeError) {
      // 整批失敗（例如 bucket 打不到）：全部留在佇列，下次排程自然重試——不逐一
      // 猜測 storage-js remove() 回傳陣列裡哪些路徑算「有處理到」（未經測試環境
      // 驗證過那個回傳格式，寧可整批留著重試，也不要憑猜測誤刪佇列列）。
      for (const r of rows) failures.push({ object_path: r.object_path, error: removeError.message });
      continue;
    }

    // Storage 的 remove() 對「本來就不存在」的路徑一樣視為達成目標狀態（物件不在
    // bucket 裡），沒有 error 就整批視為處理完成。
    for (const r of rows) {
      doneIds.push(r.id);
      processed++;
    }
  }

  if (doneIds.length > 0) {
    const { error: deleteError } = await supabase
      .from("purge_storage_queue")
      .delete()
      .in("id", doneIds);

    if (deleteError) {
      // Storage 物件確實刪了，但佇列列沒清掉——下次執行會對已經不存在的物件再呼叫
      // 一次 remove()（冪等、安全），只是多做一次無意義的 API 呼叫，不是資料錯誤。
      return new Response(
        JSON.stringify({
          processed,
          failed: failures.length,
          failures,
          warning: `Storage 物件已刪除，但清空 purge_storage_queue 失敗：${deleteError.message}`,
        }),
        { status: 207, headers: { "Content-Type": "application/json" } },
      );
    }
  }

  return new Response(
    JSON.stringify({ processed, failed: failures.length, failures }),
    { status: failures.length > 0 ? 207 : 200, headers: { "Content-Type": "application/json" } },
  );
});
