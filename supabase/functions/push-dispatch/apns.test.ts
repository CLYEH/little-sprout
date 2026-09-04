// LS-172 — apns.ts 的 Deno 單元測試。全部用注入的 fake `fetch`，不打真正的
// api.push.apple.com／api.sandbox.push.apple.com。JWT 的簽章正確性用**真的**
// Web Crypto（`crypto.subtle.generateKey` 產生一把測試用 P-256 金鑰對，不是
// 任何真實的 Apple 憑證）現場驗證，不是只檢查字串形狀——證明 buildRealApnsProvider
// 產生的 JWT 真的能被對應的公鑰驗證通過，不只是「看起來像一個 JWT」。
//
// 跑法：`deno test supabase/functions/push-dispatch/`（不需要 --allow-net）。

import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { FakeTime } from "jsr:@std/testing@1/time";
import { buildRealApnsProvider } from "./apns.ts";

// ---------------------------------------------------------------------------
// 測試用 P-256 金鑰對＋輔助函式（base64url 編解碼）
// ---------------------------------------------------------------------------

async function makeTestP8(): Promise<{ p8: string; publicKey: CryptoKey }> {
  const keyPair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const pkcs8 = await crypto.subtle.exportKey("pkcs8", keyPair.privateKey);
  let binary = "";
  for (const b of new Uint8Array(pkcs8)) binary += String.fromCharCode(b);
  const b64 = btoa(binary);
  const lines = b64.match(/.{1,64}/g) ?? [b64];
  const pem = `-----BEGIN PRIVATE KEY-----\n${
    lines.join("\n")
  }\n-----END PRIVATE KEY-----`;
  return { p8: pem, publicKey: keyPair.publicKey };
}

function base64UrlDecode(s: string): Uint8Array {
  const padded = s.replace(/-/g, "+").replace(/_/g, "/") +
    "===".slice((s.length + 3) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

const VALID_SECRETS_BASE = {
  teamId: "TEAMID1234",
  keyId: "KEYID5678",
  bundleId: "com.example.littlesprout",
  env: "sandbox",
};

function fakeFetchCapturing(
  capture: { url?: string; init?: RequestInit },
  status = 200,
  responseBody: unknown = null,
): typeof fetch {
  return ((url: string | URL, init?: RequestInit) => {
    capture.url = String(url);
    capture.init = init;
    return Promise.resolve(
      new Response(
        responseBody === null ? null : JSON.stringify(responseBody),
        { status },
      ),
    );
  }) as unknown as typeof fetch;
}

// ---------------------------------------------------------------------------
// 1.（票文明定）缺任一 secret → fail loud，不送
// ---------------------------------------------------------------------------

Deno.test("buildRealApnsProvider：五個 secrets 齊全才建構得起來，缺任一個都丟例外（fail loud）", async () => {
  const { p8 } = await makeTestP8();
  const full = { ...VALID_SECRETS_BASE, p8 };
  const fields: (keyof typeof full)[] = [
    "teamId",
    "keyId",
    "p8",
    "bundleId",
    "env",
  ];
  for (const field of fields) {
    const broken = { ...full, [field]: undefined };
    assertThrows(
      () => buildRealApnsProvider(broken, fetch),
      Error,
      undefined,
      `缺 ${field} 應該丟出例外，卻沒有`,
    );
  }
  // 五個都給齊：不該丟例外。
  buildRealApnsProvider(full, fetch);
});

Deno.test("buildRealApnsProvider：全部缺失（未設定任何 APNs secrets）→ 例外訊息點名全部五個環境變數", () => {
  try {
    buildRealApnsProvider(
      {
        teamId: undefined,
        keyId: undefined,
        p8: undefined,
        bundleId: undefined,
        env: undefined,
      },
      fetch,
    );
    throw new Error("應該要丟例外，卻沒有");
  } catch (err) {
    const message = String(err);
    for (
      const name of [
        "APNS_TEAM_ID",
        "APNS_KEY_ID",
        "APNS_P8",
        "APNS_BUNDLE_ID",
        "APNS_ENV",
      ]
    ) {
      assert(message.includes(name), `例外訊息應該提到 ${name}：${message}`);
    }
  }
});

// ---------------------------------------------------------------------------
// 2. JWT 正確性：header/payload 內容、簽章可用對應公鑰驗證通過（不是假裝簽過）
// ---------------------------------------------------------------------------

Deno.test("buildRealApnsProvider：送出的 JWT 是合法的 ES256——header/payload 正確、簽章可用對應公鑰驗證通過", async () => {
  const { p8, publicKey } = await makeTestP8();
  const capture: { url?: string; init?: RequestInit } = {};
  const provider = buildRealApnsProvider(
    { ...VALID_SECRETS_BASE, p8 },
    fakeFetchCapturing(capture, 200),
  );

  const before = Math.floor(Date.now() / 1000);
  const outcome = await provider.send("device-token-abc", "標題", "內文");
  assertEquals(outcome, { ok: true });

  const headers = capture.init?.headers as Record<string, string>;
  assert(headers.authorization.startsWith("bearer "));
  const jwt = headers.authorization.slice("bearer ".length);
  const [headerB64, payloadB64, sigB64] = jwt.split(".");

  const header = JSON.parse(
    new TextDecoder().decode(base64UrlDecode(headerB64)),
  );
  const payload = JSON.parse(
    new TextDecoder().decode(base64UrlDecode(payloadB64)),
  );
  assertEquals(header.alg, "ES256");
  assertEquals(header.kid, "KEYID5678");
  assertEquals(payload.iss, "TEAMID1234");
  assert(typeof payload.iat === "number");
  assert(payload.iat >= before, "iat 應該接近呼叫當下的時間");

  const signature = base64UrlDecode(sigB64);
  const signingInput = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
  const verified = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    publicKey,
    signature as unknown as BufferSource,
    signingInput as unknown as BufferSource,
  );
  assertEquals(verified, true, "JWT 簽章必須能用對應的公鑰驗證通過");
});

Deno.test("buildRealApnsProvider：JWT 在同一個 provider 實例內重複使用，不每次呼叫都重簽（Apple 建議做法）", async () => {
  const { p8 } = await makeTestP8();
  const seenAuths: string[] = [];
  const fetchImpl = ((_url: string | URL, init?: RequestInit) => {
    seenAuths.push((init?.headers as Record<string, string>).authorization);
    return Promise.resolve(new Response(null, { status: 200 }));
  }) as unknown as typeof fetch;
  const provider = buildRealApnsProvider(
    { ...VALID_SECRETS_BASE, p8 },
    fetchImpl,
  );
  await provider.send("tok-1", "t", "b");
  await provider.send("tok-2", "t", "b");
  assertEquals(seenAuths.length, 2);
  assertEquals(seenAuths[0], seenAuths[1], "兩次呼叫應該重用同一把 JWT");
});

Deno.test("buildRealApnsProvider：不同 provider 實例各自簽出不同的 JWT（不是全域快取）", async () => {
  // FakeTime 把 Date.now() 收斂成可控制的假時鐘（同 delete-account/handler.test.ts
  // 既有慣例）：JWT 是 lazy 簽的（第一次 send() 才真正呼叫 Date.now()，見
  // apns.ts「Apple 建議同一把 JWT…」段），所以要 tick 的時間點是**兩次 send()
  // 之間**，不是兩次 buildRealApnsProvider() 建構之間——建構本身不讀時鐘。
  const time = new FakeTime();
  try {
    const { p8 } = await makeTestP8();
    const seenAuths: string[] = [];
    const makeFetch = (): typeof fetch =>
      ((_url: string | URL, init?: RequestInit) => {
        seenAuths.push((init?.headers as Record<string, string>).authorization);
        return Promise.resolve(new Response(null, { status: 200 }));
      }) as unknown as typeof fetch;
    const providerA = buildRealApnsProvider(
      { ...VALID_SECRETS_BASE, p8 },
      makeFetch(),
    );
    const providerB = buildRealApnsProvider(
      { ...VALID_SECRETS_BASE, p8 },
      makeFetch(),
    );
    await providerA.send("tok-a", "t", "b");
    time.tick(1000); // iat 是整秒時間戳，兩次 send() 之間要跨過至少 1 秒才會不同
    await providerB.send("tok-b", "t", "b");
    assertEquals(seenAuths.length, 2);
    assert(
      seenAuths[0] !== seenAuths[1],
      "不同 provider 實例（等同不同 invocation）應該各自簽出不同的 JWT（iat 不同）",
    );
  } finally {
    time.restore();
  }
});

// ---------------------------------------------------------------------------
// 3. 端點選擇：env=sandbox／production 打不同 host；path／topic／body 正確
// ---------------------------------------------------------------------------

Deno.test("buildRealApnsProvider：env=sandbox → 打 api.sandbox.push.apple.com，路徑/topic/body 正確", async () => {
  const { p8 } = await makeTestP8();
  const capture: { url?: string; init?: RequestInit } = {};
  const provider = buildRealApnsProvider(
    { ...VALID_SECRETS_BASE, p8, env: "sandbox" },
    fakeFetchCapturing(capture, 200),
  );
  await provider.send("tok-xyz", "萌芽日記", "測試內文");
  assertEquals(
    capture.url,
    "https://api.sandbox.push.apple.com/3/device/tok-xyz",
  );
  const headers = capture.init?.headers as Record<string, string>;
  assertEquals(headers["apns-topic"], "com.example.littlesprout");
  assertEquals(headers["apns-push-type"], "alert");
  const body = JSON.parse(capture.init?.body as string);
  assertEquals(body.aps.alert.title, "萌芽日記");
  assertEquals(body.aps.alert.body, "測試內文");
});

Deno.test("buildRealApnsProvider：env=production → 打正式 api.push.apple.com", async () => {
  const { p8 } = await makeTestP8();
  const capture: { url?: string; init?: RequestInit } = {};
  const provider = buildRealApnsProvider(
    { ...VALID_SECRETS_BASE, p8, env: "production" },
    fakeFetchCapturing(capture, 200),
  );
  await provider.send("tok-1", "t", "b");
  assertEquals(capture.url, "https://api.push.apple.com/3/device/tok-1");
});

Deno.test("buildRealApnsProvider：env 是其他任意值（非 'production'）→ 一律視為 sandbox（安全預設，不誤打正式站）", async () => {
  const { p8 } = await makeTestP8();
  const capture: { url?: string; init?: RequestInit } = {};
  const provider = buildRealApnsProvider(
    { ...VALID_SECRETS_BASE, p8, env: "development" },
    fakeFetchCapturing(capture, 200),
  );
  await provider.send("tok-1", "t", "b");
  assertEquals(
    capture.url,
    "https://api.sandbox.push.apple.com/3/device/tok-1",
  );
});

// ---------------------------------------------------------------------------
// 4. 失效 token 判定：410／400+BadDeviceToken → invalidToken:true；其他 → false
// ---------------------------------------------------------------------------

Deno.test("buildRealApnsProvider：410 Unregistered → invalidToken:true", async () => {
  const { p8 } = await makeTestP8();
  const provider = buildRealApnsProvider(
    { ...VALID_SECRETS_BASE, p8 },
    fakeFetchCapturing({}, 410, { reason: "Unregistered" }),
  );
  const outcome = await provider.send("tok", "t", "b");
  assertEquals(outcome.ok, false);
  if (!outcome.ok) {
    assertEquals(outcome.invalidToken, true);
    assert(outcome.error.includes("410"));
  }
});

Deno.test("buildRealApnsProvider：400 BadDeviceToken → invalidToken:true", async () => {
  const { p8 } = await makeTestP8();
  const provider = buildRealApnsProvider(
    { ...VALID_SECRETS_BASE, p8 },
    fakeFetchCapturing({}, 400, { reason: "BadDeviceToken" }),
  );
  const outcome = await provider.send("tok", "t", "b");
  assertEquals(outcome.ok, false);
  if (!outcome.ok) assertEquals(outcome.invalidToken, true);
});

Deno.test("buildRealApnsProvider：400 但 reason 不是 BadDeviceToken → invalidToken:false（不誤刪還有效的 token）", async () => {
  const { p8 } = await makeTestP8();
  const provider = buildRealApnsProvider(
    { ...VALID_SECRETS_BASE, p8 },
    fakeFetchCapturing({}, 400, { reason: "TopicDisallowed" }),
  );
  const outcome = await provider.send("tok", "t", "b");
  assertEquals(outcome.ok, false);
  if (!outcome.ok) assertEquals(outcome.invalidToken, false);
});

Deno.test("buildRealApnsProvider：500 伺服器錯誤 → invalidToken:false（環境問題，不是 token 問題）", async () => {
  const { p8 } = await makeTestP8();
  const provider = buildRealApnsProvider(
    { ...VALID_SECRETS_BASE, p8 },
    fakeFetchCapturing({}, 500, { reason: "InternalServerError" }),
  );
  const outcome = await provider.send("tok", "t", "b");
  assertEquals(outcome.ok, false);
  if (!outcome.ok) assertEquals(outcome.invalidToken, false);
});

Deno.test("buildRealApnsProvider：回應不是合法 JSON（例如空 body）→ 不丟例外，reason 視為空字串", async () => {
  const { p8 } = await makeTestP8();
  const provider = buildRealApnsProvider(
    { ...VALID_SECRETS_BASE, p8 },
    fakeFetchCapturing({}, 410, null),
  );
  const outcome = await provider.send("tok", "t", "b");
  assertEquals(outcome.ok, false);
  if (!outcome.ok) assertEquals(outcome.invalidToken, true); // 410 本身就夠，不需要 reason
});

// ---------------------------------------------------------------------------
// 5.（LS-172 R2，merge-reviewer M1）JWT 過期處理：45 分鐘齡期重簽＋403
// ExpiredProviderToken 重簽重試一次。index.ts 把 provider 建在模組層級，同一個
// isolate 可能存活遠超過 1 小時，這裡驗證「provider 實例不重建、時間推移」與
// 「APNs 回報 403」兩種情境都會正確重簽，且重試最多一次（不是無限重試）。
// ---------------------------------------------------------------------------

function makeSequencedFetch(
  responses: { status: number; body?: unknown }[],
  seenAuths: string[],
): typeof fetch {
  let i = 0;
  return ((_url: string | URL, init?: RequestInit) => {
    seenAuths.push((init?.headers as Record<string, string>).authorization);
    const r = responses[Math.min(i, responses.length - 1)];
    i++;
    return Promise.resolve(
      new Response(r.body === undefined ? null : JSON.stringify(r.body), {
        status: r.status,
      }),
    );
  }) as unknown as typeof fetch;
}

Deno.test("buildRealApnsProvider：同一個 provider 實例內，時間推移超過 45 分鐘 → 下一次 send() 重簽新 JWT（不是永遠沿用舊的）", async () => {
  const time = new FakeTime();
  try {
    const { p8 } = await makeTestP8();
    const seenAuths: string[] = [];
    const fetchImpl = makeSequencedFetch(
      [{ status: 200 }, { status: 200 }],
      seenAuths,
    );
    const provider = buildRealApnsProvider(
      { ...VALID_SECRETS_BASE, p8 },
      fetchImpl,
    );

    await provider.send("tok-1", "t", "b");
    time.tick(46 * 60 * 1000); // 46 分鐘，超過 45 分鐘的重簽門檻
    await provider.send("tok-2", "t", "b");

    assertEquals(seenAuths.length, 2);
    assert(
      seenAuths[0] !== seenAuths[1],
      "超過 45 分鐘後應該重簽新 JWT，不該沿用舊的（否則 isolate 溫熱夠久就會永遠用同一把過期的 JWT）",
    );
  } finally {
    time.restore();
  }
});

Deno.test("buildRealApnsProvider：45 分鐘內的兩次 send() 仍沿用同一把 JWT（沒有過度重簽）", async () => {
  const time = new FakeTime();
  try {
    const { p8 } = await makeTestP8();
    const seenAuths: string[] = [];
    const fetchImpl = makeSequencedFetch(
      [{ status: 200 }, { status: 200 }],
      seenAuths,
    );
    const provider = buildRealApnsProvider(
      { ...VALID_SECRETS_BASE, p8 },
      fetchImpl,
    );

    await provider.send("tok-1", "t", "b");
    time.tick(10 * 60 * 1000); // 10 分鐘，遠低於 45 分鐘門檻
    await provider.send("tok-2", "t", "b");

    assertEquals(seenAuths.length, 2);
    assertEquals(seenAuths[0], seenAuths[1], "45 分鐘內不該重簽");
  } finally {
    time.restore();
  }
});

Deno.test("buildRealApnsProvider：收到 403 ExpiredProviderToken → 重簽並重試一次，重試成功則整體回報 ok:true", async () => {
  // 用 FakeTime 分兩階段：先送一次成功的（快取住一把 JWT），tick 1 秒後再送一次——
  // 這次第一次嘗試沿用快取的舊 JWT 但被 Apple 拒絕（模擬「45 分鐘估計不準，Apple
  // 端提前判定過期」），觸發重簽重試。tick 1 秒是必要的（同「不同 provider 實例」
  // 既有測試的理由）：iat 是整秒時間戳，同一秒內重簽會簽出位元組相同的 JWT（本機
  // 實測 Deno 的 ECDSA 簽章對相同輸入是確定性的），不 tick 就無法用「JWT 字串不同」
  // 證明重簽真的發生過。
  const time = new FakeTime();
  try {
    const { p8 } = await makeTestP8();
    const seenAuths: string[] = [];
    const fetchImpl = makeSequencedFetch(
      [
        { status: 200 }, // 第一次 send()：建立並快取一把 JWT
        { status: 403, body: { reason: "ExpiredProviderToken" } }, // 第二次 send() 的第一次嘗試：沿用快取，被拒絕
        { status: 200 }, // 重簽後的重試：成功
      ],
      seenAuths,
    );
    const provider = buildRealApnsProvider(
      { ...VALID_SECRETS_BASE, p8 },
      fetchImpl,
    );

    await provider.send("tok-1", "t", "b");
    time.tick(1000);
    const outcome = await provider.send("tok-2", "t", "b");

    assertEquals(outcome, { ok: true });
    assertEquals(
      seenAuths.length,
      3,
      "第一次 send() 打 1 次；第二次 send() 打 2 次（初次+重試）",
    );
    assertEquals(
      seenAuths[0],
      seenAuths[1],
      "第二次 send() 的第一次嘗試應該沿用快取的舊 JWT（還沒超過 45 分鐘）",
    );
    assert(
      seenAuths[1] !== seenAuths[2],
      "重簽後重試的那次應該用新 JWT，不是原本被拒絕的那把",
    );
  } finally {
    time.restore();
  }
});

Deno.test("buildRealApnsProvider：收到 403 ExpiredProviderToken → 重試一次後仍然失敗，不會再重試第二次（最多一次）", async () => {
  const { p8 } = await makeTestP8();
  const seenAuths: string[] = [];
  const fetchImpl = makeSequencedFetch(
    [
      { status: 403, body: { reason: "ExpiredProviderToken" } },
      { status: 403, body: { reason: "ExpiredProviderToken" } },
      { status: 200 }, // 如果真的重試了第三次，這裡會回 200 讓測試「意外」通過——用來反證沒有第三次呼叫
    ],
    seenAuths,
  );
  const provider = buildRealApnsProvider(
    { ...VALID_SECRETS_BASE, p8 },
    fetchImpl,
  );

  const outcome = await provider.send("tok", "t", "b");
  assertEquals(outcome.ok, false);
  if (!outcome.ok) {
    assertEquals(
      outcome.invalidToken,
      false,
      "ExpiredProviderToken 是憑證問題，不是失效 token，不該被判定成 invalidToken",
    );
    assert(outcome.error.includes("403"));
  }
  assertEquals(
    seenAuths.length,
    2,
    "只能重試一次——第三次呼叫代表重試邏輯變成無限重試（或誤觸發了不該有的第二次重試）",
  );
});

Deno.test("buildRealApnsProvider：403 但 reason 不是 ExpiredProviderToken → 不觸發重簽重試，只打一次", async () => {
  const { p8 } = await makeTestP8();
  const seenAuths: string[] = [];
  const fetchImpl = makeSequencedFetch(
    [{ status: 403, body: { reason: "InvalidProviderToken" } }, {
      status: 200,
    }],
    seenAuths,
  );
  const provider = buildRealApnsProvider(
    { ...VALID_SECRETS_BASE, p8 },
    fetchImpl,
  );

  const outcome = await provider.send("tok", "t", "b");
  assertEquals(outcome.ok, false);
  if (!outcome.ok) assertEquals(outcome.invalidToken, false);
  assertEquals(
    seenAuths.length,
    1,
    "只有 ExpiredProviderToken 這個特定 reason 才觸發重簽重試",
  );
});
