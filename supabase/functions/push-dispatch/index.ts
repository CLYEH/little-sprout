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
  type ClaimedEvent,
  type ContentTargetType,
  type Deps,
  handleRequest,
  type NotificationKind,
  type RecipientToken,
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
// 冷啟動就會直接失敗，不必等第一個請求進來、也不必每個請求都重新簽一次 JWT——同一個
// isolate 存活期間的所有請求共用同一個 provider 實例，APNs 官方建議的「同一把 JWT
// 在效期內（最長 1 小時）重複使用」因此天然涵蓋到跨請求，不只是單一請求內的多次送出。
const apnsProvider =
  (Deno.env.get("PUSH_DISPATCH_PROVIDER") ?? "apns") === "stub"
    ? new StubApnsProvider()
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

// 型別守門：資料庫的 enum 值只可能是這幾種，供 buildProdDeps 的行轉換使用。
function isNotificationKind(v: unknown): v is NotificationKind {
  return v === "comment" || v === "reaction" || v === "diary" || v === "album";
}
function isContentTargetType(v: unknown): v is ContentTargetType {
  return v === "album" || v === "media" || v === "diary" || v === "comment";
}

function buildProdDeps(): Deps {
  return {
    expectedServiceRoleKey: serviceRoleKey,
    batchLimit: BATCH_LIMIT,
    maxBatches: MAX_BATCHES,

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

    async getRecipients(eventId) {
      const { data, error } = await adminClient.rpc("notification_recipients", {
        p_event_id: eventId,
      });
      if (error) return { recipients: [], error: error.message };
      const rows = (data ?? []) as Array<Record<string, unknown>>;
      const recipients: RecipientToken[] = rows.map((row) => ({
        userId: String(row.user_id),
        token: String(row.token),
        platform: String(row.platform),
      }));
      return { recipients };
    },

    apnsProvider,

    async removeDeviceToken(token) {
      const { error } = await adminClient.from("device_tokens").delete().eq(
        "token",
        token,
      );
      if (error) return { ok: false, error: error.message };
      return { ok: true };
    },

    log(message) {
      console.log(message);
    },
  };
}

Deno.serve((req) => handleRequest(req, buildProdDeps()));
