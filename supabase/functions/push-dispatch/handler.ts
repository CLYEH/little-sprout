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

/** 批次 getRecipients（LS-172 R2，merge-reviewer m1）多帶一個 eventId，供呼叫端
 * 把同一次批次查詢回來的收件人列分回各自所屬的事件。 */
export interface BatchRecipientRow extends RecipientToken {
  eventId: string;
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
  /** 有上限的併發送出數（LS-172 R2，merge-reviewer m1）——同時最多幾個 in-flight 的 APNs 呼叫。 */
  concurrency: number;
  /** 時間預算（毫秒，LS-172 R2，merge-reviewer m1）：只在「開始下一批之前」檢查，
   * 已 claim 的批次一定完整跑完，見 runDispatch 檔頭與 docs/API.md §10 的取捨說明。 */
  timeBudgetMs: number;
  /** 注入的時鐘（epoch 毫秒）：production 用 Date.now，測試用假時鐘控制時間預算判斷，不需要真的 sleep。 */
  now(): number;
  claimEvents(
    limit: number,
  ): Promise<{ events: ClaimedEvent[]; error?: string }>;
  /** 批次查詢：一次 SQL 呼叫取整批 claimed 事件的對象（LS-172 R2，merge-reviewer
   * m1），不逐事件 round trip。回傳列各自帶 eventId，供呼叫端分組。 */
  getRecipients(
    eventIds: string[],
  ): Promise<{ recipients: BatchRecipientRow[]; error?: string }>;
  apnsProvider: ApnsProvider;
  /** `deleted`：DELETE 是否真的刪到列（true）還是該列本來就不存在（false）——
   * 只有真的刪到才該計入 tokensRemoved（LS-172 R2，merge-reviewer m2／i2）。
   * `ok=false` 時 `deleted` 無意義（一律當作 false）。 */
  removeDeviceToken(
    token: string,
  ): Promise<{ ok: boolean; deleted: boolean; error?: string }>;
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
// runDispatch：claim → 批次查對象 → 組文案 → 有上限併發送出 → 失效 token 清除。
//
// **漏送不重送（票文明定的取捨，寫入 docs/API.md）**：claimEvents 內部（SQL 面）
// 已經先標記 sent_at，這裡任何一步失敗（getRecipients 出錯、單一 token 送出
// 失敗）都只記 log、繼續處理下一批／下一個 token，不會讓已 claim 的事件回頭重新
// 標記成待送——寧可某一則通知漏送，也不要因為重送導致同一則通知被重複推播
// 給已經收到的人。批次迴圈的安全上限（maxBatches）比照 purge-storage 既有
// 慣例，避免佇列量體異常大時單次 invocation 執行時間失控。
//
// **時間預算（LS-172 R2，merge-reviewer m1）——「已 claim 但沒送」不能發生**：
// 時間預算只在「開始下一批之前」檢查；一旦一批事件被 claim（sent_at 已標記），
// 這批**一定會完整跑完**，不會半途中止——這是結構性保證，不需要精準預測「這批
// 要跑多久」。這個設計選擇（固定保守批次大小＋批次間檢查，而不是依剩餘時間動態
// 縮小批次）的完整取捨與殘餘風險見 docs/API.md §10。
//
// **有上限的併發（LS-172 R2，merge-reviewer m1）**：同一批內的所有送出工作
// （event × recipient 展開後的 token 清單）用 deps.concurrency 個 worker 平行
// 處理，不是原本的全序列——`summary`／`removedTokens` 的更新都是同步語句（JS
// 單執行緒，await 之間才會被交錯），沒有真正的資料競爭；但 removedTokens 的
// 「先佔位再 await」寫法仍是必要的（見下方），避免同一個 token 被兩個並發中的
// job 都判定成「還沒刪過」而重複計數（m2）。
// ---------------------------------------------------------------------------

export interface DispatchSummary {
  claimed: number;
  recipients: number;
  sent: number;
  failed: number;
  tokensRemoved: number;
  /** 因為時間預算將盡而提早停止 claim 新批次（不是佇列已空、也不是出錯中止）。 */
  stoppedEarly: boolean;
}

async function mapWithConcurrency<T>(
  items: T[],
  limit: number,
  fn: (item: T) => Promise<void>,
): Promise<void> {
  let nextIndex = 0;
  async function worker(): Promise<void> {
    while (nextIndex < items.length) {
      const i = nextIndex++;
      await fn(items[i]);
    }
  }
  const workerCount = Math.max(1, Math.min(limit, items.length));
  await Promise.all(Array.from({ length: workerCount }, () => worker()));
}

export async function runDispatch(deps: Deps): Promise<DispatchSummary> {
  const summary: DispatchSummary = {
    claimed: 0,
    recipients: 0,
    sent: 0,
    failed: 0,
    tokensRemoved: 0,
    stoppedEarly: false,
  };
  // 本次 invocation 內已經確認「刪過」（或確認「該列本來就不存在」）的 token——
  // 去重用；也是併發下防止同一 token 被重複 DELETE／重複計數的關鍵（見下方）。
  const removedTokens = new Set<string>();
  const deadline = deps.now() + deps.timeBudgetMs;

  let batches = 0;
  while (batches < deps.maxBatches) {
    if (deps.now() >= deadline) {
      summary.stoppedEarly = true;
      break;
    }

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

    const eventIds = events.map((e) => e.id);
    const { recipients, error: recError } = await deps.getRecipients(
      eventIds,
    );
    if (recError) {
      // 這批事件的 sent_at 已經被 claim 標記——批次查對象失敗只能整批略過
      // （漏送），不會、也不能回頭重新標記成待送（見上方檔頭「漏送不重送」）。
      // 繼續嘗試下一批，不是整支 invocation 直接中止。
      deps.log(
        `push-dispatch: getRecipients(批次 ${eventIds.length} 筆事件）失敗：${recError}`,
      );
      continue;
    }

    const recipientsByEvent = new Map<string, BatchRecipientRow[]>();
    for (const r of recipients) {
      const list = recipientsByEvent.get(r.eventId);
      if (list) list.push(r);
      else recipientsByEvent.set(r.eventId, [r]);
    }

    const jobs: { token: string; body: string }[] = [];
    for (const event of events) {
      const eventRecipients = recipientsByEvent.get(event.id) ?? [];
      if (eventRecipients.length === 0) continue; // 沒有人符合條件（例如唯一收件人剛好封鎖了 actor），不算失敗
      summary.recipients += eventRecipients.length;
      const body = buildMessageBody(
        event.kind,
        event.eventCount,
        event.targetType,
        event.actorDisplayName,
      );
      for (const r of eventRecipients) jobs.push({ token: r.token, body });
    }

    await mapWithConcurrency(jobs, deps.concurrency, async (job) => {
      const outcome = await deps.apnsProvider.send(
        job.token,
        APP_TITLE,
        job.body,
      );
      if (outcome.ok) {
        summary.sent++;
        return;
      }
      if (outcome.invalidToken) {
        if (removedTokens.has(job.token)) return; // 本次 invocation 已經處理過這個 token，不重複計數
        // 先佔位再 await：check 與 add 之間沒有任何 await，對 JS 單執行緒而言是
        // 原子的——併發中的另一個 job 就算幾乎同時打到同一個 token，也一定會在
        // 這一行之後才看到 removedTokens 已經有這個 token（m2：避免同一 token
        // 被重複 DELETE、重複計入 tokensRemoved）。
        removedTokens.add(job.token);
        const removed = await deps.removeDeviceToken(job.token);
        if (removed.error) {
          deps.log(
            `push-dispatch: removeDeviceToken(${job.token}) 失敗：${removed.error}`,
          );
        } else if (removed.deleted) {
          summary.tokensRemoved++;
        }
        // removed.ok && !removed.deleted：該列本來就不存在（例如已被更早一輪
        // 刪過）——不算失敗，也不計數；removedTokens 的佔位已經避免了重複嘗試。
        return;
      }
      summary.failed++;
      deps.log(
        `push-dispatch: 送出失敗 token=${job.token} error=${outcome.error}`,
      );
    });
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

// 常數時間字串比對（LS-172 R2，merge-reviewer i4）：bearer token 比對如果用
// `!==`，逐字元短路比較的耗時會隨「前面對到幾個字元」而異，理論上可被拿來做
// timing attack 猜出正確的 service_role key。這裡改成：不論長度是否相符，都把
// 兩個字串（UTF-8 位元組）逐位元組 XOR 累加到 `diff`，全部比完才判斷
// `diff === 0`——耗時只跟兩個字串的最大長度有關，跟「哪裡開始不一樣」無關。
// 長度不同時额外把 diff 標記為非 0（避免「長度不同就一定不等」被更快地判斷掉），
// 但仍然跑完整輪迴圈，不提早 return。
function timingSafeEqual(a: string, b: string): boolean {
  const bytesA = new TextEncoder().encode(a);
  const bytesB = new TextEncoder().encode(b);
  const len = Math.max(bytesA.length, bytesB.length, 1);
  let diff = bytesA.length === bytesB.length ? 0 : 1;
  for (let i = 0; i < len; i++) {
    const byteA = i < bytesA.length ? bytesA[i] : 0;
    const byteB = i < bytesB.length ? bytesB[i] : 0;
    diff |= byteA ^ byteB;
  }
  return diff === 0;
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
  if (!timingSafeEqual(bearer, deps.expectedServiceRoleKey)) {
    return jsonResponse(401, { error: "只接受 service_role 呼叫" });
  }

  try {
    const summary = await runDispatch(deps);
    deps.log(
      `push-dispatch: claimed=${summary.claimed} recipients=${summary.recipients} ` +
        `sent=${summary.sent} failed=${summary.failed} tokens_removed=${summary.tokensRemoved} ` +
        `stopped_early=${summary.stoppedEarly}`,
    );
    return jsonResponse(200, {
      claimed: summary.claimed,
      recipients: summary.recipients,
      sent: summary.sent,
      failed: summary.failed,
      tokens_removed: summary.tokensRemoved,
      stopped_early: summary.stoppedEarly,
    });
  } catch (err) {
    // 500 body 一律固定文案，不外洩原始錯誤（同 delete-account 既有慣例）。
    deps.log(`push-dispatch: 未預期例外：${String(err)}`);
    return jsonResponse(500, { error: "push_dispatch_failed" });
  }
}
