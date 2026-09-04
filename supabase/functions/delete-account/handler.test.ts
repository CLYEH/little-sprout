// LS-151 — handler.ts 的 Deno 單元測試。全部用注入的 fake Deps／fetch，不連線
// 到任何真正的 Supabase 專案或第三方 API（Apple／Google），也不需要
// `supabase functions serve`（見 docs/API.md §10「本機測試」）。
//
// 跑法：`deno test supabase/functions/delete-account/`（不需要 --allow-net，
// 這裡的每一個 fetchImpl 都是 fake，不會真的發出網路請求）。

import { assertEquals } from "jsr:@std/assert@1";
import { FakeTime } from "jsr:@std/testing@1/time";
import {
  type DeleteAuthUserResult,
  type DeletionRequestedStatus,
  type Deps,
  type FinalizeAccountDeletionResult,
  findProviderToken,
  handleRequest,
  type Identity,
  revokeAppleToken,
  revokeGoogleToken,
} from "./handler.ts";

// ---------------------------------------------------------------------------
// 共用 fake 建構器：每個測試只覆寫它關心的欄位，其餘用「正常放行」的預設值，
// 避免每個測試案例都要重複貼一整份 Deps。
// ---------------------------------------------------------------------------
function makeDeps(overrides: Partial<Deps> = {}): Deps {
  return {
    getCallerUser: (authHeader) =>
      Promise.resolve(
        authHeader === "Bearer valid-token" ? { id: "user-1" } : null,
      ),
    getDeletionRequestedAt: (): Promise<DeletionRequestedStatus> =>
      Promise.resolve({ found: true, requested: true }),
    getIdentities: (): Promise<Identity[]> => Promise.resolve([]),
    finalizeAccountDeletion: (): Promise<FinalizeAccountDeletionResult> =>
      Promise.resolve({ ok: true }),
    deleteAuthUser: (): Promise<DeleteAuthUserResult> =>
      Promise.resolve({ ok: true, notFound: false }),
    fetchImpl: (() => {
      throw new Error("fetchImpl 不該在這個測試被呼叫");
    }) as unknown as typeof fetch,
    appleClientId: undefined,
    appleClientSecret: undefined,
    ...overrides,
  };
}

// M2（merge-review R1）：模擬「fetch 被黑洞」——連線建立後永遠不回應，也不主動
// 拒絕。真正的 fetch 收到 AbortSignal 之後，signal 觸發 abort 時會 reject；這裡
// 複刻同一個行為（監聽 init.signal 的 abort 事件才 reject），這樣才能驗證
// handler.ts 傳入的 AbortSignal.timeout(5000) 真的會讓「不回來的 fetch」在 5 秒
// 後被中止，而不是隨便一個永遠不 resolve 的 Promise（那樣就算 handler.ts 忘記
// 傳 signal，測試也測不出差異）。
function blackholeFetch(): typeof fetch {
  return ((_url: string | URL, init?: RequestInit) => {
    return new Promise<Response>((_resolve, reject) => {
      const signal = init?.signal;
      if (!signal) return; // 沒有帶 signal：故意永遠不 settle，逼測試自己發現
      if (signal.aborted) {
        reject(new DOMException("The signal has been aborted", "TimeoutError"));
        return;
      }
      signal.addEventListener("abort", () => {
        reject(new DOMException("The signal has been aborted", "TimeoutError"));
      });
    });
  }) as unknown as typeof fetch;
}

function req(authHeader: string | null): Request {
  const headers = new Headers();
  if (authHeader !== null) headers.set("Authorization", authHeader);
  return new Request("https://example.test/functions/v1/delete-account", {
    method: "POST",
    headers,
  });
}

// ---------------------------------------------------------------------------
// 1. 鑑權
// ---------------------------------------------------------------------------

Deno.test("沒有 Authorization header → 401", async () => {
  const res = await handleRequest(req(null), makeDeps());
  assertEquals(res.status, 401);
});

Deno.test("Authorization 存在但 JWT 無效／使用者已不存在（getCallerUser 回 null）→ 401", async () => {
  const res = await handleRequest(req("Bearer garbage"), makeDeps());
  assertEquals(res.status, 401);
});

// ---------------------------------------------------------------------------
// 2. 守門：deletion_requested_at 必須非 NULL，否則不放行（票文「不得讓未走 RPC
//    的人直接刪」——這是核心安全需求，不是邊角案例）。
// ---------------------------------------------------------------------------

Deno.test("profiles 存在但 deletion_requested_at 是 NULL → 400，不呼叫 deleteAuthUser", async () => {
  let deleteCalled = false;
  const deps = makeDeps({
    getDeletionRequestedAt: () =>
      Promise.resolve({ found: true, requested: false }),
    deleteAuthUser: () => {
      deleteCalled = true;
      return Promise.resolve({ ok: true, notFound: false });
    },
  });
  const res = await handleRequest(req("Bearer valid-token"), deps);
  assertEquals(res.status, 400);
  assertEquals(deleteCalled, false, "未通過守門時絕不能呼叫 deleteAuthUser");
});

Deno.test("profiles 列完全不存在 → 400（不是 500，不是靜默放行）", async () => {
  const deps = makeDeps({
    getDeletionRequestedAt: () =>
      Promise.resolve({ found: false, requested: false }),
  });
  const res = await handleRequest(req("Bearer valid-token"), deps);
  assertEquals(res.status, 400);
});

// ---------------------------------------------------------------------------
// 3. 主流程：通過守門之後，成功刪除 → 200
// ---------------------------------------------------------------------------

Deno.test("通過守門且刪除成功 → 200，body 含 deleted:true", async () => {
  const res = await handleRequest(req("Bearer valid-token"), makeDeps());
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.deleted, true);
  assertEquals(body.alreadyDeleted, false);
});

// ---------------------------------------------------------------------------
// 4. 冪等：deleteAuthUser 回報「使用者不存在」→ 200（已達成目的，不是失敗）
// ---------------------------------------------------------------------------

Deno.test("deleteAuthUser 回報使用者不存在（notFound）→ 200，alreadyDeleted:true", async () => {
  const deps = makeDeps({
    deleteAuthUser: () => Promise.resolve({ ok: false, notFound: true }),
  });
  const res = await handleRequest(req("Bearer valid-token"), deps);
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.deleted, true);
  assertEquals(body.alreadyDeleted, true);
});

// ---------------------------------------------------------------------------
// 5. 真正的刪除失敗（非 notFound）→ 500，明確錯誤，不是靜默 200
// ---------------------------------------------------------------------------

Deno.test("deleteAuthUser 回報非 notFound 的失敗 → 500", async () => {
  const deps = makeDeps({
    deleteAuthUser: () =>
      Promise.resolve({ ok: false, notFound: false, error: "GoTrue 5xx" }),
  });
  const res = await handleRequest(req("Bearer valid-token"), deps);
  assertEquals(res.status, 500);
});

// N2（merge-review R2）：500 body 一律固定文案，原始錯誤（可能含其他家庭的
// UUID、GoTrue／內部 SQL 片段）絕不能出現在回應裡——只進 console.error。
Deno.test("deleteAuthUser 失敗時 body 不含原始錯誤字串（只有固定文案＋stage）", async () => {
  const secretDetail = "家庭 fb000000-secret-uuid 必須至少保留一位 owner";
  const deps = makeDeps({
    deleteAuthUser: () =>
      Promise.resolve({ ok: false, notFound: false, error: secretDetail }),
  });
  const res = await handleRequest(req("Bearer valid-token"), deps);
  const bodyText = await res.text();
  assertEquals(bodyText.includes(secretDetail), false);
  assertEquals(bodyText.includes("secret-uuid"), false);
  const body = JSON.parse(bodyText);
  assertEquals(body.error, "deletion_failed");
  assertEquals(body.stage, "auth_delete");
});

// ---------------------------------------------------------------------------
// 6. findProviderToken：常見欄位名稱都試得到；沒有欄位或沒有該 provider 的
//    identity 都回 undefined（不丟例外）。
// ---------------------------------------------------------------------------

Deno.test("findProviderToken：identity_data 裡有 provider_token 就找得到", () => {
  const identities: Identity[] = [
    { provider: "apple", identity_data: { provider_token: "abc123" } },
  ];
  assertEquals(findProviderToken(identities, "apple"), "abc123");
});

Deno.test("findProviderToken：沒有對應 provider 的 identity → undefined", () => {
  const identities: Identity[] = [{ provider: "email", identity_data: {} }];
  assertEquals(findProviderToken(identities, "apple"), undefined);
});

Deno.test("findProviderToken：identity 存在但 identity_data 沒有任何已知欄位 → undefined", () => {
  const identities: Identity[] = [
    {
      provider: "google",
      identity_data: { sub: "xyz", email: "a@example.test" },
    },
  ];
  assertEquals(findProviderToken(identities, "google"), undefined);
});

// ---------------------------------------------------------------------------
// 7. Apple 撤銷：缺 env → skip；有 env 但沒有 token → skip；env＋token 齊全 →
//    真的呼叫注入的 fetchImpl（用 fake fetch 驗證呼叫參數，不打真正的 Apple API）。
// ---------------------------------------------------------------------------

Deno.test("revokeAppleToken：缺 APPLE_CLIENT_ID/SECRET → 不呼叫 fetch，attempted:false", async () => {
  const deps = makeDeps({
    appleClientId: undefined,
    appleClientSecret: undefined,
  });
  const result = await revokeAppleToken(deps, []);
  assertEquals(result.attempted, false);
});

Deno.test("revokeAppleToken：env 齊全但找不到 Apple provider token → 不呼叫 fetch，attempted:false", async () => {
  const deps = makeDeps({ appleClientId: "cid", appleClientSecret: "csecret" });
  const result = await revokeAppleToken(deps, [{
    provider: "google",
    identity_data: {},
  }]);
  assertEquals(result.attempted, false);
});

Deno.test("revokeAppleToken：env＋token 齊全 → 呼叫注入的 fetchImpl，帶正確參數", async () => {
  let calledUrl: string | undefined;
  let calledBody: URLSearchParams | undefined;
  const fakeFetch = ((url: string | URL, init?: RequestInit) => {
    calledUrl = String(url);
    calledBody = init?.body as URLSearchParams;
    return Promise.resolve(new Response(null, { status: 200 }));
  }) as unknown as typeof fetch;

  const deps = makeDeps({
    appleClientId: "cid",
    appleClientSecret: "csecret",
    fetchImpl: fakeFetch,
  });
  const identities: Identity[] = [
    { provider: "apple", identity_data: { provider_token: "apple-token-123" } },
  ];
  const result = await revokeAppleToken(deps, identities);

  assertEquals(result.attempted, true);
  assertEquals(result.ok, true);
  assertEquals(calledUrl, "https://appleid.apple.com/auth/revoke");
  assertEquals(calledBody?.get("client_id"), "cid");
  assertEquals(calledBody?.get("client_secret"), "csecret");
  assertEquals(calledBody?.get("token"), "apple-token-123");
});

Deno.test("revokeAppleToken：fetch 回應非 2xx → attempted:true, ok:false，不丟例外", async () => {
  const fakeFetch = (() =>
    Promise.resolve(
      new Response(null, { status: 400 }),
    )) as unknown as typeof fetch;
  const deps = makeDeps({
    appleClientId: "cid",
    appleClientSecret: "csecret",
    fetchImpl: fakeFetch,
  });
  const identities: Identity[] = [
    { provider: "apple", identity_data: { provider_token: "t" } },
  ];
  const result = await revokeAppleToken(deps, identities);
  assertEquals(result.attempted, true);
  assertEquals(result.ok, false);
});

Deno.test("revokeAppleToken：fetch 本身丟出例外 → 捕捉、不往外傳，ok:false", async () => {
  const fakeFetch = (() => {
    throw new Error("network down");
  }) as unknown as typeof fetch;
  const deps = makeDeps({
    appleClientId: "cid",
    appleClientSecret: "csecret",
    fetchImpl: fakeFetch,
  });
  const identities: Identity[] = [
    { provider: "apple", identity_data: { provider_token: "t" } },
  ];
  const result = await revokeAppleToken(deps, identities);
  assertEquals(result.attempted, true);
  assertEquals(result.ok, false);
});

// ---------------------------------------------------------------------------
// 8. Google 撤銷：不需要 client secret，只看 token 存在與否。
// ---------------------------------------------------------------------------

Deno.test("revokeGoogleToken：找不到 Google provider token → 不呼叫 fetch，attempted:false", async () => {
  const deps = makeDeps();
  const result = await revokeGoogleToken(deps, []);
  assertEquals(result.attempted, false);
});

Deno.test("revokeGoogleToken：有 token → 呼叫注入的 fetchImpl，帶 token 參數", async () => {
  let calledUrl: string | undefined;
  const fakeFetch = ((url: string | URL) => {
    calledUrl = String(url);
    return Promise.resolve(new Response(null, { status: 200 }));
  }) as unknown as typeof fetch;

  const deps = makeDeps({ fetchImpl: fakeFetch });
  const identities: Identity[] = [
    {
      provider: "google",
      identity_data: { refresh_token: "google-token-456" },
    },
  ];
  const result = await revokeGoogleToken(deps, identities);

  assertEquals(result.attempted, true);
  assertEquals(result.ok, true);
  assertEquals(
    calledUrl?.startsWith("https://oauth2.googleapis.com/revoke?token="),
    true,
  );
  assertEquals(calledUrl?.includes("google-token-456"), true);
});

// ---------------------------------------------------------------------------
// 9. 撤銷失敗絕不擋刪除（票文硬性要求）：即使 Apple／Google revoke 都失敗，
//    只要守門與刪除本身成功，仍然回 200。
// ---------------------------------------------------------------------------

Deno.test("Apple／Google 撤銷皆失敗，不影響帳號刪除本身成功 → 仍是 200", async () => {
  const failingFetch = (() =>
    Promise.resolve(
      new Response(null, { status: 500 }),
    )) as unknown as typeof fetch;
  const deps = makeDeps({
    appleClientId: "cid",
    appleClientSecret: "csecret",
    fetchImpl: failingFetch,
    getIdentities: (): Promise<Identity[]> =>
      Promise.resolve([
        { provider: "apple", identity_data: { provider_token: "t" } },
        { provider: "google", identity_data: { refresh_token: "g" } },
      ]),
  });
  const res = await handleRequest(req("Bearer valid-token"), deps);
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.deleted, true);
  assertEquals(body.revocations.apple.ok, false);
  assertEquals(body.revocations.google.ok, false);
});

// ---------------------------------------------------------------------------
// 10.（M2，merge-review R1 major）revoke fetch 沒有逾時上限的話，黑洞連線會讓
//    deleteAuthUser() 永遠不被呼叫——這裡驗證 AbortSignal.timeout(5000) 真的
//    生效：用「監聽 signal 才 reject」的 fetchImpl（見上面 blackholeFetch）＋
//    FakeTime 把 5 秒的等待壓縮成毫秒級，不需要真的等 5 秒。
// ---------------------------------------------------------------------------

Deno.test("revokeAppleToken：fetch 被黑洞（永不 resolve／reject）→ 5 秒後逾時，attempted:true ok:false，不會無限期卡住", async () => {
  const time = new FakeTime();
  try {
    const deps = makeDeps({
      appleClientId: "cid",
      appleClientSecret: "csecret",
      fetchImpl: blackholeFetch(),
    });
    const identities: Identity[] = [
      { provider: "apple", identity_data: { provider_token: "t" } },
    ];
    const resultPromise = revokeAppleToken(deps, identities);
    await time.tickAsync(5000);
    const result = await resultPromise;
    assertEquals(result.attempted, true);
    assertEquals(result.ok, false);
  } finally {
    time.restore();
  }
});

Deno.test("revokeGoogleToken：fetch 被黑洞 → 5 秒後逾時，attempted:true ok:false，不會無限期卡住", async () => {
  const time = new FakeTime();
  try {
    const deps = makeDeps({ fetchImpl: blackholeFetch() });
    const identities: Identity[] = [
      { provider: "google", identity_data: { refresh_token: "g" } },
    ];
    const resultPromise = revokeGoogleToken(deps, identities);
    await time.tickAsync(5000);
    const result = await resultPromise;
    assertEquals(result.attempted, true);
    assertEquals(result.ok, false);
  } finally {
    time.restore();
  }
});

Deno.test("handleRequest：Apple／Google 兩邊 fetch 都被黑洞，仍在逾時後完成刪除（不永久卡住整個請求）→ 200", async () => {
  const time = new FakeTime();
  try {
    const deps = makeDeps({
      appleClientId: "cid",
      appleClientSecret: "csecret",
      fetchImpl: blackholeFetch(),
      getIdentities: (): Promise<Identity[]> =>
        Promise.resolve([
          { provider: "apple", identity_data: { provider_token: "t" } },
          { provider: "google", identity_data: { refresh_token: "g" } },
        ]),
    });
    const resPromise = handleRequest(req("Bearer valid-token"), deps);
    await time.tickAsync(5000);
    const res = await resPromise;
    assertEquals(res.status, 200);
    const body = await res.json();
    assertEquals(body.deleted, true);
    assertEquals(body.revocations.apple.ok, false);
    assertEquals(body.revocations.google.ok, false);
  } finally {
    time.restore();
  }
});

// ---------------------------------------------------------------------------
// 11.（R2，merge-review R1 B1／M1 第一道防線）finalize_account_deletion 的接線：
//    刪除前一定會呼叫，失敗就 fail loud（500，不繼續刪 auth.users）。
// ---------------------------------------------------------------------------

Deno.test("finalizeAccountDeletion 成功 → 繼續呼叫 deleteAuthUser，200", async () => {
  let finalizeCalled = false;
  let deleteCalled = false;
  const deps = makeDeps({
    finalizeAccountDeletion: () => {
      finalizeCalled = true;
      return Promise.resolve({ ok: true });
    },
    deleteAuthUser: () => {
      deleteCalled = true;
      return Promise.resolve({ ok: true, notFound: false });
    },
  });
  const res = await handleRequest(req("Bearer valid-token"), deps);
  assertEquals(res.status, 200);
  assertEquals(finalizeCalled, true);
  assertEquals(
    deleteCalled,
    true,
    "finalizeAccountDeletion 成功之後必須繼續呼叫 deleteAuthUser",
  );
});

Deno.test("finalizeAccountDeletion 失敗 → 500，不呼叫 deleteAuthUser（fail loud，不樂觀繼續刪除）", async () => {
  let deleteCalled = false;
  const deps = makeDeps({
    finalizeAccountDeletion: () =>
      Promise.resolve({ ok: false, error: "資料面清理失敗" }),
    deleteAuthUser: () => {
      deleteCalled = true;
      return Promise.resolve({ ok: true, notFound: false });
    },
  });
  const res = await handleRequest(req("Bearer valid-token"), deps);
  assertEquals(res.status, 500);
  assertEquals(
    deleteCalled,
    false,
    "finalizeAccountDeletion 失敗時絕不能繼續呼叫 deleteAuthUser",
  );
});

// N2（merge-review R2）：finalize 失敗的 500 body 同樣不能外洩原始錯誤——
// finalize 的錯誤最容易夾帶其他家庭的 UUID（例如死鎖訊息裡的 relation/tuple
// 資訊），這裡刻意塞一個看起來像內部細節的字串來驗證它不會外流。
Deno.test("finalizeAccountDeletion 失敗時 body 不含原始錯誤字串（只有固定文案＋stage）", async () => {
  const secretDetail =
    'ERROR: deadlock detected while locking tuple (0,7) in relation "families"';
  const deps = makeDeps({
    finalizeAccountDeletion: () =>
      Promise.resolve({ ok: false, error: secretDetail }),
  });
  const res = await handleRequest(req("Bearer valid-token"), deps);
  const bodyText = await res.text();
  assertEquals(bodyText.includes("deadlock"), false);
  assertEquals(bodyText.includes("families"), false);
  const body = JSON.parse(bodyText);
  assertEquals(body.error, "deletion_failed");
  assertEquals(body.stage, "finalize");
});

// N1（merge-review R2）：finalize 回報 retryable（重試一次後仍是 40P01）時，
// handleRequest 必須回 503（可安全重試的暫時狀態），不是泛用的 500。
Deno.test("finalizeAccountDeletion 回報 retryable:true → 503（不是 500）", async () => {
  const deps = makeDeps({
    finalizeAccountDeletion: () =>
      Promise.resolve({
        ok: false,
        error: "deadlock detected",
        retryable: true,
      }),
  });
  const res = await handleRequest(req("Bearer valid-token"), deps);
  assertEquals(res.status, 503);
  const body = await res.json();
  assertEquals(body.error, "deletion_temporarily_unavailable");
  assertEquals(body.stage, "finalize");
});

// N5（merge-review R2）：finalize 排在撤銷之前——finalize 失敗時，Apple／Google
// 撤銷（不可逆動作）絕不能已經被呼叫。用會真的打 fetchImpl 的設定（帶
// appleClientId/secret＋identities）來證明順序，不是靠「沒設 token 所以本來就
// 不會呼叫」這種弱驗證。
Deno.test("finalize 排在撤銷之前：finalize 失敗時 revoke 的 fetchImpl 絕不能被呼叫", async () => {
  let fetchCalled = false;
  const deps = makeDeps({
    appleClientId: "cid",
    appleClientSecret: "csecret",
    getIdentities: (): Promise<Identity[]> =>
      Promise.resolve([
        { provider: "apple", identity_data: { provider_token: "t" } },
      ]),
    fetchImpl: (() => {
      fetchCalled = true;
      return Promise.resolve(new Response(null, { status: 200 }));
    }) as unknown as typeof fetch,
    finalizeAccountDeletion: () =>
      Promise.resolve({ ok: false, error: "資料面清理失敗" }),
  });
  const res = await handleRequest(req("Bearer valid-token"), deps);
  assertEquals(res.status, 500);
  assertEquals(
    fetchCalled,
    false,
    "finalize 尚未成功時就呼叫了 revoke 的 fetchImpl——撤銷（不可逆）不該搶在 finalize（可能失敗）之前",
  );
});

// ---------------------------------------------------------------------------
// 12.（minor-1，merge-review R1）只接受 POST——docs/API.md §10 寫的路徑是
//    「POST …/delete-account」，GET／DELETE／PUT 等其他 method 一律 405，不執行
//    任何刪除動作。
// ---------------------------------------------------------------------------

Deno.test("非 POST method（GET）→ 405，不呼叫 getCallerUser（一律先擋在 method 檢查）", async () => {
  let getCallerUserCalled = false;
  const deps = makeDeps({
    getCallerUser: () => {
      getCallerUserCalled = true;
      return Promise.resolve({ id: "user-1" });
    },
  });
  const request = new Request(
    "https://example.test/functions/v1/delete-account",
    {
      method: "GET",
    },
  );
  const res = await handleRequest(request, deps);
  assertEquals(res.status, 405);
  assertEquals(getCallerUserCalled, false);
});

Deno.test("非 POST method（DELETE）→ 405", async () => {
  const deps = makeDeps();
  const request = new Request(
    "https://example.test/functions/v1/delete-account",
    {
      method: "DELETE",
    },
  );
  const res = await handleRequest(request, deps);
  assertEquals(res.status, 405);
});
