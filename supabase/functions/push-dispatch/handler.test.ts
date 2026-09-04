// LS-172 — handler.ts 的 Deno 單元測試。全部用注入的 fake Deps／StubApnsProvider，
// 不連線到任何真正的 Supabase 專案或 APNs（同 delete-account/handler.test.ts 既有
// 慣例）。
//
// 跑法：`deno test supabase/functions/push-dispatch/`（不需要 --allow-net，這裡的
// 每一個依賴都是 fake，不會真的發出網路請求）。

import { assertEquals } from "jsr:@std/assert@1";
import {
  APP_TITLE,
  buildMessageBody,
  type ClaimedEvent,
  type Deps,
  handleRequest,
  type RecipientToken,
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
    claimEvents: () => Promise.resolve({ events: [] }),
    getRecipients: () => Promise.resolve({ recipients: [] }),
    apnsProvider: new StubApnsProvider(),
    removeDeviceToken: () => Promise.resolve({ ok: true }),
    log: () => {},
    ...overrides,
  };
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
  });
  assertEquals(getRecipientsCalled, false);
  assertEquals(provider.calls.length, 0);
});

Deno.test("runDispatch：一個事件、兩個收件人，皆送出成功 → sent=2，文案只組一次（批次只發一則彙總，不展開成多則）", async () => {
  const provider = new StubApnsProvider();
  let getRecipientsCallCount = 0;
  const recipients: RecipientToken[] = [
    { userId: "u1", token: "tok-1", platform: "ios" },
    { userId: "u2", token: "tok-2", platform: "ios" },
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
  assertEquals(getRecipientsCallCount, 1); // 一個事件只查一次對象，不逐收件人重查
  // 批次只發一則彙總：兩個收件人拿到的文案完全相同（同一則 5 個人喜歡了你的照片），
  // 不是被展開成 5 則各自獨立的訊息。
  assertEquals(provider.calls.length, 2);
  assertEquals(provider.calls[0].body, "5 個人喜歡了你的照片");
  assertEquals(provider.calls[1].body, provider.calls[0].body);
  assertEquals(provider.calls[0].title, APP_TITLE);
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
        recipients: [{ userId: "u1", token: "tok-dead", platform: "ios" }],
      }),
    apnsProvider: provider,
    removeDeviceToken: (token) => {
      removedToken = token;
      return Promise.resolve({ ok: true });
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
        recipients: [{ userId: "u1", token: "tok-1", platform: "ios" }],
      }),
    apnsProvider: provider,
    removeDeviceToken: () => {
      removeCalled = true;
      return Promise.resolve({ ok: true });
    },
  });
  const summary = await runDispatch(deps);
  assertEquals(summary.failed, 1);
  assertEquals(summary.tokensRemoved, 0);
  assertEquals(removeCalled, false);
});

Deno.test("runDispatch：getRecipients 失敗（單一事件）→ 記 log、跳過，不中止整個迴圈（漏送不重送，見 handler.ts 檔頭）", async () => {
  const logs: string[] = [];
  const provider = new StubApnsProvider();
  const deps = makeDeps({
    claimEvents: onceThenEmpty([
      makeEvent({ id: "e1" }),
      makeEvent({ id: "e2" }),
    ]),
    getRecipients: (eventId) =>
      eventId === "e1"
        ? Promise.resolve({ recipients: [], error: "DB 連線逾時" })
        : Promise.resolve({
          recipients: [{ userId: "u1", token: "tok-1", platform: "ios" }],
        }),
    apnsProvider: provider,
    log: (m) => logs.push(m),
  });
  const summary = await runDispatch(deps);
  assertEquals(summary.claimed, 2);
  assertEquals(summary.sent, 1); // e2 仍然正常送出
  assertEquals(
    logs.some((l) => l.includes("e1") && l.includes("DB 連線逾時")),
    true,
  );
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

Deno.test("handleRequest：合法 service_role bearer → 200，body 含 claimed/recipients/sent/failed/tokens_removed 五個欄位（票文明定的回應形狀）", async () => {
  const deps = makeDeps({
    claimEvents: onceThenEmpty([makeEvent()]),
    getRecipients: () =>
      Promise.resolve({
        recipients: [{ userId: "u1", token: "tok-1", platform: "ios" }],
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
