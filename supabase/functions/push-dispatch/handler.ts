// LS-172（LS-22 後端子票）— push-dispatch 的核心邏輯（可測試部分）。
//
// 拆成 handler.ts（純邏輯＋依賴注入）＋index.ts（Deno.serve 進入點＋真正的
// supabase-js client／APNs provider 建構）兩個檔案，理由與慣例同
// `delete-account`（見該檔頭）：index.ts 若直接呼叫 Deno.serve()，測試只是
// import 它就會嘗試綁定 HTTP listener。
//
// 呼叫方式（`docs/API.md` §10「Edge Functions」push-dispatch 段已明文；LS-196
// 訂正鑑權機制）：`POST {SUPABASE_URL}/functions/v1/push-dispatch`，只接受
// service 憑證——`_shared/keys.ts` 的 `isAuthorizedServiceCall()`：`apikey`
// header 等於任一 `SUPABASE_SECRET_KEYS` 值（正式站的新式 `sb_secret_…` default
// key），或（過渡）`Authorization: Bearer` 等於 `SUPABASE_SERVICE_ROLE_KEY`——
// 不是「JWT 合法即可」，anon key 也是合法 JWT。同 `purge-storage`（LS-196）的
// 既有理由：正式站執行期注入的 `SUPABASE_SERVICE_ROLE_KEY` 已非 legacy
// service_role JWT（LS-153 i4 煙測），原本純 bearer 比對這條守門在正式站無法
// 通過；`supabase/config.toml` 的 `[functions.push-dispatch] verify_jwt =
// false` 關掉平台層 JWT 驗證，改在程式內驗證。設計給排程呼叫（pg_cron／pg_net
// 或外部排程，見 docs/API.md §10「排程」——本票只記載清單，不建立），不是給
// app client 用的公開端點。
//
// 核心流程：claim（SQL 面 `public.claim_notification_events()`，先標記
// `sent_at` 再處理——即使這裡送出失敗也不回滾，寧可漏送不重送，見下方
// `runDispatch` 的說明與 docs/API.md）→ 逐事件查對象（`public.
// notification_recipients()`）→ 組文案 → 逐 token 呼叫 APNs → 410／
// `BadDeviceToken` 清掉失效 token。

// LS-175：新增 "media"（批次上傳照片彙總）／"family"（media 事件的 target，見
// migration `20260904170849_media_notification_target_family.sql`／
// `20260904170933_media_notification_events.sql` 檔頭的完整推導：media 表
// 沒有 album_id／diary_id，AFTER INSERT trigger 觸發當下這批照片會不會、會掛進
// 哪個相簿／日記這個資訊還不存在，所以 target 只能是整個家庭）。
//
// **"report" kind（LS-149，merge-review R1 m2）**：`notification_kind` 資料庫
// 列舉在 LS-149（`20260903091313_notification_kind_report.sql`）就已經有這個
// 值，`report_content()`（`20260903091317_report_block_rpc.sql:757`）也確實會
// 寫入 kind='report' 的事件——但 push-dispatch（LS-172）落地時的
// `NotificationKind` union 與 `index.ts` 的型別守門從一開始就沒有涵蓋它：若
// `claim_notification_events()` claim 到一批混著 report 事件，未涵蓋的守門會
// 判整批（不只 report 那幾筆）失敗，SQL 面卻已經標記 `sent_at`——這一批會被
// 永久漏送（LS-96 池項 `841d97da`，merge-reviewer R1 於 PR #284 覆核成立）。
// 這裡補上 "report"，讓守門認得它、不再拖垮整批；`buildMessageBody` 的
// `report` 分支文案是中性 fallback（是否要推播、推播給誰是產品決定，不是本次
// 修的範圍——這裡只保證「不再整批漏送」，見該分支的說明）。
import {
  isAuthorizedServiceCall,
  resolveSecretKey,
  type SecretKeyEnv,
} from "../_shared/keys.ts";

export type NotificationKind =
  | "comment"
  | "reaction"
  | "diary"
  | "album"
  | "media"
  | "report";
export type ContentTargetType =
  | "album"
  | "media"
  | "diary"
  | "comment"
  | "family";

// 型別守門（LS-175，merge-review R1 m2）：資料庫的 enum 值只可能是這幾種，
// 原本定義在 `index.ts`——但 `index.ts` 在模組層級呼叫 `Deno.serve()`
// （merge-review R1-i2），任何 `import` 都會嘗試綁定 HTTP listener，導致這兩支
// 純函式從落地起就沒有任何測試覆蓋，正是 LS-149 新增 `'report'` 這件事能悄悄
// 漏掉守門這麼久的結構原因。搬到這裡（純函式、無副作用，跟本檔其餘 helper 同一
// 類）之後 `index.ts` 改成 `import` 這裡的版本，`handler.test.ts` 才能直接測到
// 正式碼、不是另外複製一份會漂移的影子版本。**這只完成 merge-review R1-i2 建議
// 的一半**（守衛本身搬過來了，`claimEvents` 內把 row 轉成 `ClaimedEvent` 的
// 行轉換邏輯仍留在 `index.ts`）——i2 完整範圍是否記入 LS-96、記成什麼形狀，由
// orchestrator 裁定，本檔不擅自宣稱 i2 已完整處理。
export function isNotificationKind(v: unknown): v is NotificationKind {
  return v === "comment" || v === "reaction" || v === "diary" ||
    v === "album" || v === "media" || v === "report";
}
export function isContentTargetType(v: unknown): v is ContentTargetType {
  return v === "album" || v === "media" || v === "diary" || v === "comment" ||
    v === "family";
}

/**
 * `claim_notification_events()` 的原始回傳列（`Record<string, unknown>`，
 * supabase-js RPC 回傳不帶型別）轉成 `ClaimedEvent[]` 的行轉換——LS-96 池項
 * `a6f28382` 第 2 條（LS-175 merge-review R1-i2，R2 只搬了型別守門一半）：
 * 原本連同 `isNotificationKind`／`isContentTargetType` 一起留在 `index.ts`，
 * 因為 `index.ts` 在模組層級呼叫 `Deno.serve()`，這段行轉換邏輯（含「未知 kind
 * 整批視為失敗」這個 fail-loud 分支）從落地起就沒有任何測試覆蓋。搬到這裡之後
 * `index.ts` 的 `claimEvents` 只剩「呼叫 RPC → 把結果餵給這支純函式」的接線，
 * 行為與搬遷前逐字等價（純粹把同一段程式碼移動位置，沒有改寫任何一行判斷式）。
 */
export function mapClaimedEventRows(
  rows: Array<Record<string, unknown>>,
): { events: ClaimedEvent[]; error?: string } {
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
}

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
  /** service 呼叫鑑權用的原始環境變數（LS-196，見 `_shared/keys.ts`）：
   * `isAuthorizedServiceCall()` 據此判斷 `apikey`／legacy bearer 是否合法，
   * `resolveSecretKey()` 據此判斷「有沒有任何一把可用的金鑰」（都缺＝部署設定
   * 缺失，fail loud）。 */
  authEnv: SecretKeyEnv;
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
  // LS-175：kind="media" 的訊息不透過 TARGET_LABEL 組字（直接寫「新增了…張照片」，
  // 不是「在你的{標籤}留言」這種句型），這個 key 只是讓 Record<ContentTargetType,
  // string> 保持窮舉、編譯期不漏任何一個列舉值——沒有任何分支會實際讀到它。
  family: "家庭",
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
    // LS-175：批次上傳彙總——票文明定範例 event_count=50 →「新增了 50 張照片」。
    // event_count<=1 用「一張」而不是阿拉伯數字 1（同 diary／album 的既有風格：
    // 單一動作用自然語句，不是「新增了 1 張照片」這種生硬的數字）。target_type
    // 恆為 "family"（見 migration 檔頭），這裡不像 comment／reaction 需要
    // TARGET_LABEL——訊息本身就是完整句子，不需要「在你的 xxx」這種目標子句。
    case "media":
      return eventCount <= 1
        ? `${actorDisplayName}新增了一張照片`
        : `${actorDisplayName}新增了 ${eventCount} 張照片`;
    // LS-175（merge-review R1 m2）：中性 fallback，不是產品定案文案——目的只是
    // 「report 事件不再讓整批 claim 靜默漏送」（見上方 union 的說明），不是把
    // 檢舉通知的完整產品體驗做完。不用 actor 名字（`report_content()` 的
    // actor 是檢舉人，不是被檢舉內容的作者，直接套用 comment/reaction 那種
    // 「{actor} 對你的 xxx 做了什麼」句型會誤導收件人以為檢舉人在跟自己互動）；
    // target_type 是被檢舉內容原本的類型（album/media/diary/comment，見
    // `report_content()` 傳入 `record_notification_event` 的 `r.target_type`），
    // `TARGET_LABEL` 在這裡可以直接沿用。是否要推播、要推播給誰（例如只給
    // owner，不是全家庭）是產品決定，留給後續票，這裡不擴大範圍。
    case "report":
      return eventCount <= 1
        ? `你的${label}收到一則檢舉`
        : `你的${label}收到了 ${eventCount} 則檢舉`;
  }
}

// ---------------------------------------------------------------------------
// StubApnsProvider：本機／CI 用，只記錄 payload，不打真正的 APNs；可注入
// respond callback 模擬任意結果（含 410／BadDeviceToken，供測試驗證失效 token
// 清除路徑）。
// ---------------------------------------------------------------------------

export type StubApnsResponder = (token: string) => ApnsOutcome;

// LS-96 池項 `531a0975`（LS-172 QA `23af6837`）：`StubApnsProvider()` 原本只能
// 靠 deno 單元測試直接 construct `new StubApnsProvider(responder)` 才能注入
// 410／BadDeviceToken——`supabase functions serve` 起的真實 HTTP 端點沒有任何
// 環境變數／機制能觸發失效 token 分支，Stub E2E 因此只能改用「真正 PostgREST
// DELETE」等價驗證，驗不到 `runDispatch` 真正呼叫 `removeDeviceToken` 這條路徑。
// 這支函式讀取 `PUSH_DISPATCH_STUB_RESPONSE` 環境變數，把它轉成
// `index.ts` 可以直接餵給 `new StubApnsProvider(...)` 的 responder；放在這裡
// （純函式、無副作用）而不是 index.ts，理由同 `isNotificationKind` 等——
// `index.ts` 在模組層級呼叫 `Deno.serve()`，這支函式若留在那裡就無法被
// `handler.test.ts` 直接測到。
//
// 目前只支援 `"410"`（模擬 APNs 410 Unregistered，`ApnsOutcome.invalidToken`
// 分支——`removeDeviceToken()` 會被呼叫、`tokens_removed` 會累加）。**fail
// loud**：設了但值不認得就直接丟例外，不悄悄退回預設的 `ok:true`——那樣會讓
// 打錯字的環境變數看起來像「一切正常」，卻其實根本沒有注入到任何東西。
export function parseStubResponse(
  value: string | undefined,
): StubApnsResponder | undefined {
  if (value === undefined || value === "") return undefined;
  if (value === "410") {
    return () => ({
      ok: false,
      invalidToken: true,
      error: "APNs 410 Unregistered（PUSH_DISPATCH_STUB_RESPONSE 注入）",
    });
  }
  throw new Error(
    `PUSH_DISPATCH_STUB_RESPONSE 不支援的值：${
      JSON.stringify(value)
    }（目前只支援 "410"）`,
  );
}

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

export async function handleRequest(
  req: Request,
  deps: Deps,
): Promise<Response> {
  if (req.method !== "POST") {
    return jsonResponse(405, { error: "只接受 POST" });
  }

  // LS-196：鑑權判定改用 `_shared/keys.ts`（常數時間比對已下沉到那支共用
  // helper，`purge-storage` 同型）。
  if (!resolveSecretKey(deps.authEnv)) {
    // fail loud：部署設定本身有問題（SUPABASE_SECRET_KEYS／SUPABASE_SERVICE_ROLE_KEY
    // 皆未注入），不是「當作沒有事件可處理」悄悄回 200（同 purge-storage／
    // delete-account 既有先例）。
    return jsonResponse(500, {
      error: "SUPABASE_SECRET_KEYS／SUPABASE_SERVICE_ROLE_KEY 皆未設定",
    });
  }

  if (!isAuthorizedServiceCall(req.headers, deps.authEnv)) {
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
