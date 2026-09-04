// LS-172（LS-22 後端子票）— push-dispatch 的核心邏輯（可測試部分）。
//
// 拆成 handler.ts（純邏輯＋依賴注入）＋index.ts（Deno.serve 進入點＋真正的
// supabase-js client／APNs provider 建構）兩個檔案，理由與慣例同
// `delete-account`（見該檔頭）：index.ts 若直接呼叫 Deno.serve()，測試只是
// import 它就會嘗試綁定 HTTP listener。
//
// 呼叫方式（`docs/API.md` §10「Edge Functions」push-dispatch 段已明文）：
// `POST {SUPABASE_URL}/functions/v1/push-dispatch`，只接受 `service_role` bearer
// （比對 `SUPABASE_SERVICE_ROLE_KEY` 本身，同 `purge-storage` 既有慣例，不是「JWT
// 合法即可」——anon key 也是合法 JWT）。設計給排程呼叫（pg_cron／pg_net 或外部排程，
// 見 docs/API.md §10「排程」——本票只記載清單，不建立），不是給 app client 用的
// 公開端點。
//
// 核心流程：claim（SQL 面 `public.claim_notification_events()`，先標記
// `sent_at` 再處理——即使這裡送出失敗也不回滾，寧可漏送不重送，見下方
// `runDispatch` 的說明與 docs/API.md）→ 逐事件查對象（`public.
// notification_recipients()`）→ 組文案 → 逐 token 呼叫 APNs → 410／
// `BadDeviceToken` 清掉失效 token。

export type NotificationKind = "comment" | "reaction" | "diary" | "album";
export type ContentTargetType = "album" | "media" | "diary" | "comment";

export interface ClaimedEvent {
  id: string;
  familyId: string;
  kind: NotificationKind;
  targetType: ContentTargetType;
  targetId: string;
  actorId: string | null;
  /** 已在 SQL 端 COALESCE 過（NULL actor 或查不到 profiles 時 fallback「家人」）。 */
  actorDisplayName: string;
  eventCount: number;
  occurredAt: string;
}

export interface RecipientToken {
  userId: string;
  token: string;
  platform: string;
}

export type ApnsOutcome =
  | { ok: true }
  | { ok: false; invalidToken: boolean; error: string };

export interface ApnsProvider {
  send(token: string, title: string, body: string): Promise<ApnsOutcome>;
}

export interface Deps {
  /** 用於比對 Authorization Bearer 的期望值；undefined＝部署設定缺失（fail loud）。 */
  expectedServiceRoleKey: string | undefined;
  /** 單次 claim 呼叫的上限（比照 purge-storage 的 BATCH_SIZE 概念）。 */
  batchLimit: number;
  /** 安全上限：避免佇列量體異常大時單次 invocation 執行時間失控（比照 purge-storage 的 MAX_BATCHES）。 */
  maxBatches: number;
  claimEvents(
    limit: number,
  ): Promise<{ events: ClaimedEvent[]; error?: string }>;
  getRecipients(
    eventId: string,
  ): Promise<{ recipients: RecipientToken[]; error?: string }>;
  apnsProvider: ApnsProvider;
  removeDeviceToken(token: string): Promise<{ ok: boolean; error?: string }>;
  log(message: string): void;
}

// ---------------------------------------------------------------------------
// 文案彙總矩陣（票文明定，繁中、長輩可讀）
// ---------------------------------------------------------------------------

export const APP_TITLE = "萌芽日記";

const TARGET_LABEL: Record<ContentTargetType, string> = {
  diary: "日記",
  album: "相簿",
  media: "照片",
  comment: "留言",
};

// **已知、刻意的規格分歧（票文字面 vs. 實際可用資料，見 migration 檔頭第 2 段的
// 同類記錄方式）**：票文給的範例把 `album` kind 對應到「爸爸新增了 50 張照片」，
// 但 `notification_events` 的 `album` kind 只在**建立相簿本身**時觸發
// （`private.notify_album_created()`，見
// `20260825020000_comments_reactions_notifications.sql` 第 3 段），`target_id`
// 是每本相簿自己的 id——不同相簿天生無法合併（合併鍵含 `target_id`），
// `event_count` 對這個 kind 在目前的 trigger 設計下恆為 1，且完全沒有「這本相簿
// 裡有幾張照片」這個訊號（上傳照片進相簿走 `media`／`album_media`，LS-58 沒有幫
// 這兩張表建立任何 trigger）。這裡不虛構一個資料庫給不出來的數字，`album` 訊息
// 改成不帶張數的「新增了相簿」；`event_count > 1`（今天的 trigger 設計下不會發生，
// 防禦性保留）才帶數字，且單位是「本」不是「張」。`diary` kind 同理（`target_id`
// 也是日記自己的 id，`event_count` 同樣恆為 1）。這個決定記在這裡、PR body、
// 也記進 docs/API.md 的 push-dispatch 段，不是靜默偏離票文。
export function buildMessageBody(
  kind: NotificationKind,
  eventCount: number,
  targetType: ContentTargetType,
  actorDisplayName: string,
): string {
  const label = TARGET_LABEL[targetType];
  switch (kind) {
    case "comment":
      return eventCount <= 1
        ? `${actorDisplayName}在你的${label}留言`
        : `你的${label}收到了 ${eventCount} 則新留言`;
    case "reaction":
      return eventCount <= 1
        ? `${actorDisplayName}喜歡了你的${label}`
        : `${eventCount} 個人喜歡了你的${label}`;
    case "diary":
      return eventCount <= 1
        ? `${actorDisplayName}寫了一篇日記`
        : `${actorDisplayName}新增了 ${eventCount} 篇日記`;
    case "album":
      return eventCount <= 1
        ? `${actorDisplayName}新增了相簿`
        : `${actorDisplayName}新增了 ${eventCount} 本相簿`;
  }
}

// ---------------------------------------------------------------------------
// StubApnsProvider：本機／CI 用，只記錄 payload，不打真正的 APNs；可注入
// respond callback 模擬任意結果（含 410／BadDeviceToken，供測試驗證失效 token
// 清除路徑）。
// ---------------------------------------------------------------------------

export type StubApnsResponder = (token: string) => ApnsOutcome;

export class StubApnsProvider implements ApnsProvider {
  readonly calls: { token: string; title: string; body: string }[] = [];
  constructor(
    private readonly responder: StubApnsResponder = () => ({ ok: true }),
  ) {}

  send(token: string, title: string, body: string): Promise<ApnsOutcome> {
    this.calls.push({ token, title, body });
    return Promise.resolve(this.responder(token));
  }
}

// ---------------------------------------------------------------------------
// runDispatch：claim → 逐事件查對象 → 組文案 → 逐 token 送出 → 失效 token 清除。
//
// **漏送不重送（票文明定的取捨，寫入 docs/API.md）**：claimEvents 內部（SQL 面）
// 已經先標記 sent_at，這裡任何一步失敗（getRecipients 出錯、單一 token 送出
// 失敗）都只記 log、繼續處理下一個事件／token，不會讓已 claim 的事件回頭重新
// 標記成待送——寧可某一則通知漏送，也不要因為重送導致同一則通知被重複推播
// 給已經收到的人。批次迴圈的安全上限（maxBatches）比照 purge-storage 既有
// 慣例，避免佇列量體異常大時單次 invocation 執行時間失控。
// ---------------------------------------------------------------------------

export interface DispatchSummary {
  claimed: number;
  recipients: number;
  sent: number;
  failed: number;
  tokensRemoved: number;
}

export async function runDispatch(deps: Deps): Promise<DispatchSummary> {
  const summary: DispatchSummary = {
    claimed: 0,
    recipients: 0,
    sent: 0,
    failed: 0,
    tokensRemoved: 0,
  };

  let batches = 0;
  while (batches < deps.maxBatches) {
    const { events, error: claimError } = await deps.claimEvents(
      deps.batchLimit,
    );
    if (claimError) {
      // fail loud（記 log）但不中止：這一輪還沒 claim 到任何新事件，沒有
      // 「已標記卻沒處理」的風險，直接結束這次 invocation，交給下次排程重試。
      deps.log(`push-dispatch: claimEvents 失敗：${claimError}`);
      break;
    }
    if (events.length === 0) break;
    batches++;
    summary.claimed += events.length;

    for (const event of events) {
      const { recipients, error: recError } = await deps.getRecipients(
        event.id,
      );
      if (recError) {
        // 這個事件的 sent_at 已經被 claim 標記——查對象失敗只能略過（漏送），
        // 不會、也不能回頭重新標記成待送（見上方檔頭「漏送不重送」）。
        deps.log(
          `push-dispatch: getRecipients(${event.id}) 失敗：${recError}`,
        );
        continue;
      }
      if (recipients.length === 0) continue; // 沒有人符合條件（例如唯一收件人剛好封鎖了 actor），不算失敗
      summary.recipients += recipients.length;

      const body = buildMessageBody(
        event.kind,
        event.eventCount,
        event.targetType,
        event.actorDisplayName,
      );

      for (const recipient of recipients) {
        const outcome = await deps.apnsProvider.send(
          recipient.token,
          APP_TITLE,
          body,
        );
        if (outcome.ok) {
          summary.sent++;
          continue;
        }
        if (outcome.invalidToken) {
          summary.tokensRemoved++;
          const removed = await deps.removeDeviceToken(recipient.token);
          if (!removed.ok) {
            deps.log(
              `push-dispatch: removeDeviceToken(${recipient.token}) 失敗：${removed.error}`,
            );
          }
          continue;
        }
        summary.failed++;
        deps.log(
          `push-dispatch: 送出失敗 token=${recipient.token} error=${outcome.error}`,
        );
      }
    }
  }

  return summary;
}

// ---------------------------------------------------------------------------
// handleRequest：method／鑑權檢查 → runDispatch → 固定形狀的 JSON 回應。
// ---------------------------------------------------------------------------

function jsonResponse(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

export async function handleRequest(
  req: Request,
  deps: Deps,
): Promise<Response> {
  if (req.method !== "POST") {
    return jsonResponse(405, { error: "只接受 POST" });
  }

  if (!deps.expectedServiceRoleKey) {
    // fail loud：部署設定本身有問題（SUPABASE_SERVICE_ROLE_KEY 未注入），不是
    // 「當作沒有事件可處理」悄悄回 200（同 purge-storage／delete-account 既有先例）。
    return jsonResponse(500, {
      error: "SUPABASE_SERVICE_ROLE_KEY 未設定",
    });
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const bearer = authHeader.startsWith("Bearer ")
    ? authHeader.slice("Bearer ".length)
    : "";
  if (bearer !== deps.expectedServiceRoleKey) {
    return jsonResponse(401, { error: "只接受 service_role 呼叫" });
  }

  try {
    const summary = await runDispatch(deps);
    deps.log(
      `push-dispatch: claimed=${summary.claimed} recipients=${summary.recipients} ` +
        `sent=${summary.sent} failed=${summary.failed} tokens_removed=${summary.tokensRemoved}`,
    );
    return jsonResponse(200, {
      claimed: summary.claimed,
      recipients: summary.recipients,
      sent: summary.sent,
      failed: summary.failed,
      tokens_removed: summary.tokensRemoved,
    });
  } catch (err) {
    // 500 body 一律固定文案，不外洩原始錯誤（同 delete-account 既有慣例）。
    deps.log(`push-dispatch: 未預期例外：${String(err)}`);
    return jsonResponse(500, { error: "push_dispatch_failed" });
  }
}
