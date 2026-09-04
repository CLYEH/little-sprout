// LS-172（LS-22 後端子票）— Edge Function push-dispatch：消化
// `notification_events` 待送佇列，彙總成一則則長輩可讀的中文文案，呼叫 APNs。
//
// 核心邏輯（含依賴注入介面）在 handler.ts——這個檔案只負責「用 Deno 環境變數與
// supabase-js 建構真正的依賴」＋掛上 Deno.serve()，理由與慣例同 delete-account／
// purge-storage（見兩者 index.ts 檔頭）。
//
// 契約細節（呼叫方式、鑑權、secrets、部署、漏送不重送的取捨）見 docs/API.md §10
// 「Edge Functions」push-dispatch 段。

import { createClient } from "npm:@supabase/supabase-js@2.114";
import {
  type BatchRecipientRow,
  type ClaimedEvent,
  type Deps,
  handleRequest,
  isContentTargetType,
  isNotificationKind,
  parseStubResponse,
  StubApnsProvider,
} from "./handler.ts";
import { buildRealApnsProvider } from "./apns.ts";

// SUPABASE_URL／SUPABASE_SERVICE_ROLE_KEY 由 Supabase 平台在每個 Edge Function
// 執行環境自動注入（部署後）；本機 `supabase functions serve` 也會從 .env 或平台
// 預設值提供同名變數。fail loud（同 delete-account／purge-storage 既有先例）：
// 這是平台自動注入的變數，缺任一個代表部署設定本身有問題，不是「當作沒有事件可
// 處理」悄悄放行。放在模組層級——isolate 冷啟動就會直接失敗，比藏在
// buildProdDeps() 裡、每個請求都重新算一次還快看到問題。
const supabaseUrl = Deno.env.get("SUPABASE_URL");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

if (!supabaseUrl || !serviceRoleKey) {
  throw new Error("SUPABASE_URL／SUPABASE_SERVICE_ROLE_KEY 未設定");
}

// 伺服器端一次性使用的 service client，不是瀏覽器 session client，不需要（也不該）
// 啟動自動刷新 token 的計時器（同 delete-account minor-3 既有慣例）。
const adminClient = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// PUSH_DISPATCH_PROVIDER（非 secret，純環境開關）：本機／CI 明確設成 "stub" 才用
// StubApnsProvider（只記錄 payload，不打真正的 APNs）；未設定或設成 "apns" 一律走
// 真正的 APNs——buildRealApnsProvider 缺任一 secret 就 fail loud，不會因為忘記設定
// secrets 而悄悄變成 stub 行為，「本機／CI 用 stub」必須是明確選擇，不是缺 secrets
// 時的自動降級。放在模組層級（同上方 supabaseUrl／serviceRoleKey 的理由）：isolate
// 冷啟動就會直接失敗，不必等第一個請求進來。**這裡是模組層級單例**——同一個
// isolate 存活期間的所有請求（可能橫跨遠超過 1 小時）共用同一個 apnsProvider
// 實例，這正是 apns.ts 的 `cachedJwt` 需要主動過期判斷＋403 重簽重試的原因
// （LS-172 R2，merge-reviewer M1；見 apns.ts `buildRealApnsProvider` 內的完整
// 說明）——不能假設「provider 實例的生命週期＝單一請求」。
// PUSH_DISPATCH_STUB_RESPONSE（LS-96 池項 `531a0975`，非 secret，純測試開關，
// 只在 PUSH_DISPATCH_PROVIDER=stub 時有意義）：讓 `supabase functions serve`
// 起的真實 HTTP 端點也能注入 410／BadDeviceToken，Stub E2E 才驗得到
// `runDispatch` 真正呼叫 `removeDeviceToken()` 這條路徑，不必再靠「打真正
// PostgREST DELETE」的等價驗證繞過去。解析邏輯（含 fail loud）在 handler.ts
// 的 `parseStubResponse`，理由同該函式檔頭說明。正式站部署不設定這個變數
// （見 docs/API.md §10 部署清單）。
const apnsProvider =
  (Deno.env.get("PUSH_DISPATCH_PROVIDER") ?? "apns") === "stub"
    ? new StubApnsProvider(
      parseStubResponse(Deno.env.get("PUSH_DISPATCH_STUB_RESPONSE")),
    )
    : buildRealApnsProvider(
      {
        teamId: Deno.env.get("APNS_TEAM_ID"),
        keyId: Deno.env.get("APNS_KEY_ID"),
        p8: Deno.env.get("APNS_P8"),
        bundleId: Deno.env.get("APNS_BUNDLE_ID"),
        env: Deno.env.get("APNS_ENV"),
      },
      fetch,
    );

const BATCH_LIMIT = 50; // 單次 claim 呼叫的上限，對齊 claim_notification_events() 的預設值。
const MAX_BATCHES = 20; // 安全上限（20 × 50 = 1000 筆／次 invocation），比照 purge-storage 既有慣例。
const CONCURRENCY = 8; // 有上限的併發送出數（LS-172 R2，merge-reviewer m1）。
// 時間預算（LS-172 R2，merge-reviewer m1）：60 秒是刻意保守的猜測值，不是任何
// Supabase／Deno Deploy 官方文件證實過的確切執行時間上限（本票沒有查證到權威
// 數字，不虛構一個「查證過」的事實）——選一個明顯遠低於典型 serverless 平台
// 逾時的值當安全邊際。時間預算只在「開始下一批之前」檢查，已 claim 的批次一定
// 完整跑完（結構性保證，不是估算），設計取捨與殘餘風險見 docs/API.md §10。
const TIME_BUDGET_MS = 60_000;

// 型別守門 `isNotificationKind`／`isContentTargetType`（資料庫的 enum 值只可能
// 是這幾種，供下面 `claimEvents` 的行轉換使用）搬進 `handler.ts` 了——這裡是
// `index.ts` 在模組層級呼叫 `Deno.serve()`（見檔尾），`import` 這個檔案會嘗試
// 綁定 HTTP listener，導致這兩支純函式從落地起就沒有任何測試覆蓋，正是
// LS-149 新增 `'report'` 這件事能悄悄漏掉守門這麼久的結構原因（merge-review
// R1-i2）。搬到 `handler.ts` 之後 `handler.test.ts` 才能直接測到正式碼；
// `'report'` 的守門缺口本身見 `handler.ts` 對這兩支函式的檔頭說明與 LS-96
// 池項 `841d97da`（LS-175 R2 已補上 `'report'`）。

function buildProdDeps(): Deps {
  return {
    expectedServiceRoleKey: serviceRoleKey,
    batchLimit: BATCH_LIMIT,
    maxBatches: MAX_BATCHES,
    concurrency: CONCURRENCY,
    timeBudgetMs: TIME_BUDGET_MS,
    now: () => Date.now(),

    async claimEvents(limit) {
      const { data, error } = await adminClient.rpc(
        "claim_notification_events",
        {
          p_limit: limit,
        },
      );
      if (error) return { events: [], error: error.message };
      const rows = (data ?? []) as Array<Record<string, unknown>>;
      const events: ClaimedEvent[] = [];
      for (const row of rows) {
        if (
          !isNotificationKind(row.kind) || !isContentTargetType(row.target_type)
        ) {
          // fail loud：schema 回傳了非預期的 enum 值，代表資料庫與這支函式的假設
          // 已經不同步——略過這一列並不安全（會用錯的文案發錯的訊息），直接算成
          // 這次 claimEvents 呼叫失敗，交給上層 log／中止這一輪迴圈。
          return {
            events: [],
            error: `claim_notification_events 回傳未知的 kind／target_type：${
              JSON.stringify(row)
            }`,
          };
        }
        events.push({
          id: String(row.id),
          familyId: String(row.family_id),
          kind: row.kind,
          targetType: row.target_type,
          targetId: String(row.target_id),
          actorId: row.actor_id === null ? null : String(row.actor_id),
          actorDisplayName: String(row.actor_display_name),
          eventCount: Number(row.event_count),
          occurredAt: String(row.occurred_at),
        });
      }
      return { events };
    },

    // 批次查詢（LS-172 R2，merge-reviewer m1）：一次 RPC 呼叫涵蓋整批 claimed
    // 事件的 event_id，不逐事件 round trip。SQL 面簽章已改成
    // notification_recipients(p_event_ids uuid[])，回傳列多帶 event_id 供這裡
    // 分組（見 migration 檔頭與 docs/API.md §10）。
    async getRecipients(eventIds) {
      const { data, error } = await adminClient.rpc("notification_recipients", {
        p_event_ids: eventIds,
      });
      if (error) return { recipients: [], error: error.message };
      const rows = (data ?? []) as Array<Record<string, unknown>>;
      const recipients: BatchRecipientRow[] = rows.map((row) => ({
        eventId: String(row.event_id),
        userId: String(row.user_id),
        token: String(row.token),
        platform: String(row.platform),
      }));
      return { recipients };
    },

    apnsProvider,

    // `.select("token")`（LS-172 R2，merge-reviewer i2）：要求 PostgREST 用
    // `Prefer: return=representation` 回傳實際被刪掉的列，藉此分辨「真的刪到
    // 東西」（data.length > 0）跟「該列本來就不存在」（data.length === 0，DELETE
    // 本身仍然成功，不是錯誤）——只請求 `token` 這一欄，對齊 migration 授予的
    // 欄位級 `select (token)` grant（device_tokens 對 service_role 沒有整表
    // SELECT，見 migration 檔頭第 4 段），要 `.select()` 預設的 `*` 會撞
    // permission denied。
    async removeDeviceToken(token) {
      const { data, error } = await adminClient
        .from("device_tokens")
        .delete()
        .eq("token", token)
        .select("token");
      if (error) return { ok: false, deleted: false, error: error.message };
      return { ok: true, deleted: (data ?? []).length > 0 };
    },

    log(message) {
      console.log(message);
    },
  };
}

Deno.serve((req) => handleRequest(req, buildProdDeps()));
