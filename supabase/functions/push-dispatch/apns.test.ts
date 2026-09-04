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
