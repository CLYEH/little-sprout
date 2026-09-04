// LS-172 — handler.ts 的 Deno 單元測試。全部用注入的 fake Deps／StubApnsProvider，
// 不連線到任何真正的 Supabase 專案或 APNs（同 delete-account/handler.test.ts 既有
// 慣例）。
//
// 跑法：`deno test supabase/functions/push-dispatch/`（不需要 --allow-net，這裡的
// 每一個依賴都是 fake，不會真的發出網路請求）。

import { assertEquals } from "jsr:@std/assert@1";
import {
  type ApnsOutcome,
  type ApnsProvider,
  APP_TITLE,
  type BatchRecipientRow,
  buildMessageBody,
  type ClaimedEvent,
  type Deps,
  handleRequest,
  runDispatch,
  StubApnsProvider,
} from "./handler.ts";

// ---------------------------------------------------------------------------
// 共用 fake 建構器
// ---------------------------------------------------------------------------

function makeEvent(overrides: Partial<ClaimedEvent> = {}): ClaimedEvent {
  return {
    id: "event-1",
    familyId: "family-1",
    kind: "diary",
    targetType: "diary",
    targetId: "target-1",
    actorId: "actor-1",
    actorDisplayName: "媽媽",
    eventCount: 1,
    occurredAt: "2026-09-04T00:00:00Z",
    ...overrides,
  };
}

function makeDeps(overrides: Partial<Deps> = {}): Deps {
  return {
    expectedServiceRoleKey: "service-role-secret",
    batchLimit: 50,
    maxBatches: 20,
    concurrency: 8,
    timeBudgetMs: 60_000,
    now: () => 0, // 固定假時鐘：預設情境不測時間預算，維持既有測試的行為不變
    claimEvents: () => Promise.resolve({ events: [] }),
    getRecipients: () => Promise.resolve({ recipients: [] }),
    apnsProvider: new StubApnsProvider(),
    removeDeviceToken: () => Promise.resolve({ ok: true, deleted: true }),
    log: () => {},
    ...overrides,
  };
}

/** 讓一個 microtask 佇列排隊排隊的 await 有機會跑完，供併發測試用——所有 fake
 * 依賴都是已經 resolve 的 Promise 或 `new Promise` 的手動 resolve，不涉及真正的
 * I/O，用 setTimeout 反而不必要地脆弱（依賴 timer 精度），純 microtask flush
 * 才是這裡真正需要的。 */
function flushMicrotasks(times = 5): Promise<void> {
  return (async () => {
    for (let i = 0; i < times; i++) await Promise.resolve();
  })();
}

// claimEvents 的 fake 預設必須是「有狀態」的：真正的 claim_notification_events()
// 標記 sent_at 之後，同一批事件不會再被下一次呼叫選中（見 migration 與
// 103_push_dispatch.sql 的「claim 兩次不重疊」驗證）。這裡的 fake 若每次呼叫都
// 回傳同一批事件，runDispatch 的 while 迴圈會一路呼叫到 maxBatches 安全上限
// 才停，把同一批事件重複算好幾輪——不是要測的行為，也會讓 summary 的期望值算
// 不出來。這個 helper 讓「只在第一次呼叫回傳這批事件、之後回空」成為預設，
// 貼近真實語意。
function onceThenEmpty(
  events: ClaimedEvent[],
): (limit: number) => Promise<{ events: ClaimedEvent[]; error?: string }> {
  let called = false;
  return () => {
    if (called) return Promise.resolve({ events: [] });
    called = true;
    return Promise.resolve({ events });
  };
}

function req(method: string, authHeader: string | null): Request {
  const headers = new Headers();
  if (authHeader !== null) headers.set("Authorization", authHeader);
  return new Request("https://example.test/functions/v1/push-dispatch", {
    method,
    headers,
  });
}

// ---------------------------------------------------------------------------
// 1. 文案彙總矩陣（票文明定的三個範例逐字對照，其餘組合驗證分支邏輯）
// ---------------------------------------------------------------------------

Deno.test("buildMessageBody：diary，event_count=1 → 「媽媽寫了一篇日記」（票文範例逐字對照）", () => {
  assertEquals(
    buildMessageBody("diary", 1, "diary", "媽媽"),
    "媽媽寫了一篇日記",
  );
});

Deno.test("buildMessageBody：comment，target_type=diary → 「阿嬤在你的日記留言」（票文範例逐字對照）", () => {
  assertEquals(
    buildMessageBody("comment", 1, "diary", "阿嬤"),
    "阿嬤在你的日記留言",
  );
});

Deno.test("buildMessageBody：reaction，target_type=media，event_count=3 → 「3 個人喜歡了你的照片」（票文範例逐字對照）", () => {
  assertEquals(
    buildMessageBody("reaction", 3, "media", "隨便誰"),
    "3 個人喜歡了你的照片",
  );
});

Deno.test("buildMessageBody：reaction，event_count=1 → 帶 actor 名字，不是「1 個人」", () => {
  assertEquals(
    buildMessageBody("reaction", 1, "album", "爸爸"),
    "爸爸喜歡了你的相簿",
  );
});

Deno.test("buildMessageBody：comment，event_count>1 → 不指名單一 actor（可能是多人留言）", () => {
  assertEquals(
    buildMessageBody("comment", 5, "album", "任何人"),
    "你的相簿收到了 5 則新留言",
  );
});

Deno.test("buildMessageBody：album，event_count=1 → 不虛構照片張數（見 handler.ts 檔頭的規格分歧記錄）", () => {
  assertEquals(buildMessageBody("album", 1, "album", "爸爸"), "爸爸新增了相簿");
});

Deno.test("buildMessageBody：album，event_count>1（防禦性分支，今天的 trigger 設計下不會發生）→ 帶「本」不帶「張」", () => {
  assertEquals(
    buildMessageBody("album", 2, "album", "爸爸"),
    "爸爸新增了 2 本相簿",
  );
});

Deno.test("buildMessageBody：diary，event_count>1（防禦性分支）", () => {
  assertEquals(
    buildMessageBody("diary", 2, "diary", "媽媽"),
    "媽媽新增了 2 篇日記",
  );
});

Deno.test("buildMessageBody：comment，target_type=comment（回覆留言）", () => {
  assertEquals(
    buildMessageBody("comment", 1, "comment", "阿公"),
    "阿公在你的留言留言",
  );
});

// ---------------------------------------------------------------------------
// 2. runDispatch：claim → recipients → 送出 → 統計，逐項行為
// ---------------------------------------------------------------------------

Deno.test("runDispatch：沒有待送事件 → 全部歸零，不呼叫 getRecipients／apnsProvider", async () => {
  let getRecipientsCalled = false;
  const provider = new StubApnsProvider();
  const deps = makeDeps({
    claimEvents: () => Promise.resolve({ events: [] }),
    getRecipients: () => {
      getRecipientsCalled = true;
      return Promise.resolve({ recipients: [] });
    },
    apnsProvider: provider,
  });
  const summary = await runDispatch(deps);
  assertEquals(summary, {
    claimed: 0,
    recipients: 0,
    sent: 0,
    failed: 0,
    tokensRemoved: 0,
    stoppedEarly: false,
  });
  assertEquals(getRecipientsCalled, false);
  assertEquals(provider.calls.length, 0);
});

Deno.test("runDispatch：一個事件、兩個收件人，皆送出成功 → sent=2，文案只組一次（批次只發一則彙總，不展開成多則）", async () => {
  const provider = new StubApnsProvider();
  let getRecipientsCallCount = 0;
  const recipients: BatchRecipientRow[] = [
    { userId: "u1", token: "tok-1", platform: "ios", eventId: "event-1" },
    { userId: "u2", token: "tok-2", platform: "ios", eventId: "event-1" },
  ];
  let claimCallLimit: number | undefined;
  const claimOnce = onceThenEmpty([
    makeEvent({ eventCount: 5, kind: "reaction", targetType: "media" }),
  ]);
  const deps = makeDeps({
    claimEvents: (limit) => {
      claimCallLimit = limit;
      return claimOnce(limit);
    },
    getRecipients: () => {
      getRecipientsCallCount++;
      return Promise.resolve({ recipients });
    },
    apnsProvider: provider,
  });
  const summary = await runDispatch(deps);
  assertEquals(claimCallLimit, 50);
  assertEquals(summary.claimed, 1);
  assertEquals(summary.recipients, 2);
  assertEquals(summary.sent, 2);
  assertEquals(summary.failed, 0);
  assertEquals(summary.tokensRemoved, 0);
  assertEquals(getRecipientsCallCount, 1); // 一整批（這裡只有一個事件）只查一次對象，不逐事件 round trip
  // 批次只發一則彙總：兩個收件人拿到的文案完全相同（同一則 5 個人喜歡了你的照片），
  // 不是被展開成 5 則各自獨立的訊息。
  assertEquals(provider.calls.length, 2);
  assertEquals(provider.calls[0].body, "5 個人喜歡了你的照片");
  assertEquals(provider.calls[1].body, provider.calls[0].body);
  assertEquals(provider.calls[0].title, APP_TITLE);
});

Deno.test("runDispatch：批次取 recipients——一次 getRecipients 呼叫涵蓋整批 claimed 事件（不逐事件 round trip，LS-172 R2 m1）", async () => {
  const calls: string[][] = [];
  const events = [
    makeEvent({ id: "e1" }),
    makeEvent({ id: "e2" }),
    makeEvent({ id: "e3" }),
  ];
  const deps = makeDeps({
    claimEvents: onceThenEmpty(events),
    getRecipients: (eventIds) => {
      calls.push(eventIds);
      return Promise.resolve({ recipients: [] });
    },
  });
  await runDispatch(deps);
  assertEquals(
    calls.length,
    1,
    "3 個事件的一個批次應該只呼叫一次 getRecipients",
  );
  assertEquals([...calls[0]].sort(), ["e1", "e2", "e3"]);
});

Deno.test("runDispatch：APNs 回報 410（失效 token）→ tokensRemoved++，呼叫 removeDeviceToken，不計入 failed", async () => {
  const provider = new StubApnsProvider((token) =>
    token === "tok-dead"
      ? { ok: false, invalidToken: true, error: "APNs 410 Unregistered" }
      : { ok: true }
  );
  let removedToken: string | undefined;
  const deps = makeDeps({
    claimEvents: onceThenEmpty([makeEvent()]),
    getRecipients: () =>
      Promise.resolve({
        recipients: [
          {
            userId: "u1",
            token: "tok-dead",
            platform: "ios",
            eventId: "event-1",
          },
        ],
      }),
    apnsProvider: provider,
    removeDeviceToken: (token) => {
      removedToken = token;
      return Promise.resolve({ ok: true, deleted: true });
    },
  });
  const summary = await runDispatch(deps);
  assertEquals(summary.sent, 0);
  assertEquals(summary.failed, 0);
  assertEquals(summary.tokensRemoved, 1);
  assertEquals(removedToken, "tok-dead");
});

Deno.test("runDispatch：APNs 回報其他失敗（非失效 token）→ failed++，不呼叫 removeDeviceToken", async () => {
  let removeCalled = false;
  const provider = new StubApnsProvider(() => ({
    ok: false,
    invalidToken: false,
    error: "APNs 500 InternalServerError",
  }));
  const deps = makeDeps({
    claimEvents: onceThenEmpty([makeEvent()]),
    getRecipients: () =>
      Promise.resolve({
        recipients: [
          { userId: "u1", token: "tok-1", platform: "ios", eventId: "event-1" },
        ],
      }),
    apnsProvider: provider,
    removeDeviceToken: () => {
      removeCalled = true;
      return Promise.resolve({ ok: true, deleted: true });
    },
  });
  const summary = await runDispatch(deps);
  assertEquals(summary.failed, 1);
  assertEquals(summary.tokensRemoved, 0);
  assertEquals(removeCalled, false);
});

Deno.test("runDispatch：tokensRemoved 只在 DELETE 真的刪到列時才計數——deleted:false（該列本來就不存在）不計數（LS-172 R2 m2/i2）", async () => {
  const provider = new StubApnsProvider(() => ({
    ok: false,
    invalidToken: true,
    error: "APNs 410 Unregistered",
  }));
  let removeCalls = 0;
  const deps = makeDeps({
    claimEvents: onceThenEmpty([makeEvent()]),
    getRecipients: () =>
      Promise.resolve({
        recipients: [
          { userId: "u1", token: "tok-1", platform: "ios", eventId: "event-1" },
        ],
      }),
    apnsProvider: provider,
    removeDeviceToken: () => {
      removeCalls++;
      return Promise.resolve({ ok: true, deleted: false });
    },
  });
  const summary = await runDispatch(deps);
  assertEquals(removeCalls, 1, "還是要嘗試 DELETE 一次");
  assertEquals(summary.tokensRemoved, 0, "沒有真的刪到列，不該計數");
});

Deno.test("runDispatch：同一個 token 在同一批出現兩次（兩個不同事件的收件人）→ 只 DELETE 一次、只計數一次（LS-172 R2 m2 去重）", async () => {
  const provider = new StubApnsProvider(() => ({
    ok: false,
    invalidToken: true,
    error: "APNs 410 Unregistered",
  }));
  let removeCalls = 0;
  const events = [makeEvent({ id: "e1" }), makeEvent({ id: "e2" })];
  const deps = makeDeps({
    claimEvents: onceThenEmpty(events),
    getRecipients: () =>
      Promise.resolve({
        recipients: [
          { userId: "u1", token: "tok-dup", platform: "ios", eventId: "e1" },
          { userId: "u1", token: "tok-dup", platform: "ios", eventId: "e2" },
        ],
      }),
    apnsProvider: provider,
    removeDeviceToken: () => {
      removeCalls++;
      return Promise.resolve({ ok: true, deleted: true });
    },
  });
  const summary = await runDispatch(deps);
  assertEquals(
    removeCalls,
    1,
    "同一個 token 在同一次 invocation 內不該被 DELETE 兩次",
  );
  assertEquals(summary.tokensRemoved, 1, "同一個 token 不該被計數兩次");
  assertEquals(summary.sent, 0);
});

Deno.test("runDispatch：getRecipients 失敗（整批）→ 記 log、這一批全部略過，但迴圈會繼續嘗試下一批（漏送不重送，見 handler.ts 檔頭）", async () => {
  const logs: string[] = [];
  let claimCallCount = 0;
  const provider = new StubApnsProvider();
  const deps = makeDeps({
    claimEvents: () => {
      claimCallCount++;
      if (claimCallCount === 1) {
        return Promise.resolve({
          events: [makeEvent({ id: "e1" }), makeEvent({ id: "e2" })],
        });
      }
      return Promise.resolve({ events: [] });
    },
    getRecipients: () =>
      Promise.resolve({ recipients: [], error: "DB 連線逾時" }),
    apnsProvider: provider,
    log: (m) => logs.push(m),
  });
  const summary = await runDispatch(deps);
  assertEquals(
    summary.claimed,
    2,
    "兩個事件都已經被 claim（sent_at 已標記），即使查對象整批失敗也要算進 claimed",
  );
  assertEquals(summary.sent, 0);
  assertEquals(
    claimCallCount,
    2,
    "第一批查對象失敗後，迴圈應該繼續嘗試下一批（不是整支 invocation 直接中止）",
  );
  assertEquals(
    logs.some((l) => l.includes("2 筆事件") && l.includes("DB 連線逾時")),
    true,
  );
});

Deno.test("runDispatch：時間預算將盡時停止 claim 新批次（stoppedEarly:true）；已經 claim 的批次仍完整跑完，不會半途而廢（LS-172 R2 m1）", async () => {
  let claimCallCount = 0;
  let nowValue = 0;
  const deps = makeDeps({
    now: () => nowValue,
    timeBudgetMs: 100,
    claimEvents: () => {
      claimCallCount++;
      if (claimCallCount === 1) {
        nowValue = 50; // claim 完成時，時間還在預算內
        return Promise.resolve({ events: [makeEvent({ id: "e1" })] });
      }
      // 不該執行到這裡：第二次呼叫之前應該已經被時間預算擋下。
      return Promise.resolve({ events: [makeEvent({ id: "e2" })] });
    },
    getRecipients: () => {
      nowValue = 200; // 處理第一批期間，時間預算耗盡（超過 100ms）
      return Promise.resolve({
        recipients: [
          { userId: "u1", token: "tok-1", platform: "ios", eventId: "e1" },
        ],
      });
    },
  });
  const summary = await runDispatch(deps);
  assertEquals(
    claimCallCount,
    1,
    "時間預算耗盡後不該再呼叫 claimEvents 認領新批次",
  );
  assertEquals(
    summary.claimed,
    1,
    "第一批（e1）已經 claim，一定要處理完，不能留下已 claim 但沒送的事件",
  );
  assertEquals(summary.sent, 1, "e1 這批即使跨越了時間預算，也要完整送完");
  assertEquals(summary.stoppedEarly, true);
});

Deno.test("runDispatch：併發送出有上限（deps.concurrency）——同一時間 in-flight 數不超過設定值（LS-172 R2 m1）", async () => {
  const CONCURRENCY = 2;
  let inFlight = 0;
  let maxInFlight = 0;
  const releasers: (() => void)[] = [];
  const provider: ApnsProvider = {
    send(_token: string): Promise<ApnsOutcome> {
      inFlight++;
      maxInFlight = Math.max(maxInFlight, inFlight);
      return new Promise((resolve) => {
        releasers.push(() => {
          inFlight--;
          resolve({ ok: true });
        });
      });
    },
  };
  const recipients: BatchRecipientRow[] = Array.from(
    { length: 5 },
    (_, i) => ({
      userId: `u${i}`,
      token: `tok-${i}`,
      platform: "ios",
      eventId: "event-1",
    }),
  );
  const deps = makeDeps({
    concurrency: CONCURRENCY,
    claimEvents: onceThenEmpty([makeEvent()]),
    getRecipients: () => Promise.resolve({ recipients }),
    apnsProvider: provider,
  });

  const runPromise = runDispatch(deps);
  await flushMicrotasks();
  assertEquals(
    inFlight,
    CONCURRENCY,
    "5 個工作、上限 2 個併發，應該恰好 2 個 in-flight，不是一次全部發起",
  );

  while (releasers.length > 0) {
    const release = releasers.shift()!;
    release();
    await flushMicrotasks();
    assertEquals(
      inFlight <= CONCURRENCY,
      true,
      `任何時刻 in-flight 都不該超過 ${CONCURRENCY}，實際 ${inFlight}`,
    );
  }

  const summary = await runPromise;
  assertEquals(summary.sent, 5);
  assertEquals(maxInFlight, CONCURRENCY);
});

Deno.test("runDispatch：claimEvents 回傳空陣列即停止迴圈（不會無限迴圈；空批次也不觸發 maxBatches 安全上限的例外路徑）", async () => {
  let callCount = 0;
  const deps = makeDeps({
    claimEvents: () => {
      callCount++;
      return Promise.resolve({ events: [] });
    },
  });
  await runDispatch(deps);
  assertEquals(callCount, 1);
});

Deno.test("runDispatch：claimEvents 每次都回滿批（模擬佇列很深）→ 迴圈跑到 maxBatches 安全上限就停止，不無限跑下去", async () => {
  let callCount = 0;
  const deps = makeDeps({
    batchLimit: 2,
    maxBatches: 3,
    claimEvents: () => {
      callCount++;
      return Promise.resolve({
        events: [
          makeEvent({ id: `e-${callCount}-a` }),
          makeEvent({ id: `e-${callCount}-b` }),
        ],
      });
    },
  });
  const summary = await runDispatch(deps);
  assertEquals(callCount, 3); // 恰好等於 maxBatches，不多不少
  assertEquals(summary.claimed, 6);
});

// ---------------------------------------------------------------------------
// 3. handleRequest：method／鑑權／回應格式
// ---------------------------------------------------------------------------

Deno.test("handleRequest：非 POST（GET）→ 405，不呼叫 claimEvents", async () => {
  let claimCalled = false;
  const deps = makeDeps({
    claimEvents: () => {
      claimCalled = true;
      return Promise.resolve({ events: [] });
    },
  });
  const res = await handleRequest(
    req("GET", "Bearer service-role-secret"),
    deps,
  );
  assertEquals(res.status, 405);
  assertEquals(claimCalled, false);
});

Deno.test("handleRequest：expectedServiceRoleKey 未設定（部署設定缺失）→ 500，fail loud", async () => {
  const deps = makeDeps({ expectedServiceRoleKey: undefined });
  const res = await handleRequest(req("POST", "Bearer anything"), deps);
  assertEquals(res.status, 500);
  const body = await res.json();
  assertEquals(body.error, "SUPABASE_SERVICE_ROLE_KEY 未設定");
});

Deno.test("handleRequest：Authorization 缺失 → 401", async () => {
  const res = await handleRequest(req("POST", null), makeDeps());
  assertEquals(res.status, 401);
});

Deno.test("handleRequest：bearer 不等於 service_role key（例如帶 anon key）→ 401", async () => {
  const res = await handleRequest(
    req("POST", "Bearer some-anon-key"),
    makeDeps(),
  );
  assertEquals(res.status, 401);
});

Deno.test("handleRequest：bearer 長度與 service_role key 不同 → 401（LS-172 R2 i4：常數時間比對的長度分支也要正確判否）", async () => {
  const res = await handleRequest(req("POST", "Bearer short"), makeDeps());
  assertEquals(res.status, 401);
});

Deno.test("handleRequest：合法 service_role bearer → 200，body 含 claimed/recipients/sent/failed/tokens_removed/stopped_early 六個欄位（票文明定＋LS-172 R2 m1 新增）", async () => {
  const deps = makeDeps({
    claimEvents: onceThenEmpty([makeEvent()]),
    getRecipients: () =>
      Promise.resolve({
        recipients: [
          { userId: "u1", token: "tok-1", platform: "ios", eventId: "event-1" },
        ],
      }),
  });
  const res = await handleRequest(
    req("POST", "Bearer service-role-secret"),
    deps,
  );
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body, {
    claimed: 1,
    recipients: 1,
    sent: 1,
    failed: 0,
    tokens_removed: 0,
    stopped_early: false,
  });
});

Deno.test("handleRequest：runDispatch 拋出未預期例外 → 500，body 是固定文案，不外洩原始錯誤", async () => {
  const deps = makeDeps({
    claimEvents: () => {
      throw new Error("包含機密路徑 /etc/secret 的內部錯誤");
    },
  });
  const res = await handleRequest(
    req("POST", "Bearer service-role-secret"),
    deps,
  );
  assertEquals(res.status, 500);
  const bodyText = await res.text();
  assertEquals(bodyText.includes("機密路徑"), false);
  assertEquals(bodyText.includes("/etc/secret"), false);
  const body = JSON.parse(bodyText);
  assertEquals(body.error, "push_dispatch_failed");
});

// ---------------------------------------------------------------------------
// 4. StubApnsProvider 本身：記錄 payload、可注入任意回應（供本檔與 e2e 驗證使用）
// ---------------------------------------------------------------------------

Deno.test("StubApnsProvider：預設一律回 ok:true，並如實記錄每一次呼叫的 token/title/body", async () => {
  const provider = new StubApnsProvider();
  await provider.send("tok-a", "標題", "內文 A");
  await provider.send("tok-b", "標題", "內文 B");
  assertEquals(provider.calls, [
    { token: "tok-a", title: "標題", body: "內文 A" },
    { token: "tok-b", title: "標題", body: "內文 B" },
  ]);
});

Deno.test("StubApnsProvider：可注入 responder 依 token 回傳不同結果（模擬失效 token）", async () => {
  const provider = new StubApnsProvider((token) =>
    token === "tok-dead"
      ? { ok: false, invalidToken: true, error: "410" }
      : { ok: true }
  );
  const okOutcome = await provider.send("tok-alive", "t", "b");
  const deadOutcome = await provider.send("tok-dead", "t", "b");
  assertEquals(okOutcome, { ok: true });
  assertEquals(deadOutcome, { ok: false, invalidToken: true, error: "410" });
});
