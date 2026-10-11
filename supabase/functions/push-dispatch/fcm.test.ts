// LS-473 — fcm.ts 的 Deno 單元測試。全部用注入的 fake `fetch`，不打真正的
// oauth2.googleapis.com／fcm.googleapis.com。JWT 簽章用**真的** Web Crypto 產生的測試用
// RSA 金鑰對現場驗證（不是任何真實的 Google 憑證）。
//
// 跑法：`cd supabase/functions/push-dispatch && deno test`（不需要 --allow-net）。

import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { buildRealFcmProvider } from "./fcm.ts";

async function makeTestServiceAccount(): Promise<
  { json: string; publicKey: CryptoKey }
> {
  const keyPair = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );
  const pkcs8 = await crypto.subtle.exportKey("pkcs8", keyPair.privateKey);
  let binary = "";
  for (const b of new Uint8Array(pkcs8)) binary += String.fromCharCode(b);
  const b64 = btoa(binary);
  const pem = `-----BEGIN PRIVATE KEY-----\n${
    (b64.match(/.{1,64}/g) ?? [b64]).join("\n")
  }\n-----END PRIVATE KEY-----\n`;
  return {
    json: JSON.stringify({
      type: "service_account",
      project_id: "sprout-test",
      client_email: "fcm@sprout-test.iam.gserviceaccount.com",
      private_key: pem,
    }),
    publicKey: keyPair.publicKey,
  };
}

function base64UrlDecode(s: string): Uint8Array {
  const padded = s.replace(/-/g, "+").replace(/_/g, "/") +
    "===".slice((s.length + 3) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

interface Call {
  url: string;
  init?: RequestInit;
}

/** OAuth2 端點回固定 access token；messages:send 由 sendResponder 決定。 */
function makeFetch(
  calls: Call[],
  sendResponder: (call: Call) => Response = () =>
    new Response("{}", { status: 200 }),
  accessToken = "access-token-1",
): typeof fetch {
  return ((url: string | URL, init?: RequestInit) => {
    const call = { url: String(url), init };
    calls.push(call);
    if (call.url === "https://oauth2.googleapis.com/token") {
      return Promise.resolve(
        new Response(JSON.stringify({ access_token: accessToken }), {
          status: 200,
        }),
      );
    }
    return Promise.resolve(sendResponder(call));
  }) as unknown as typeof fetch;
}

const tokenCalls = (calls: Call[]) =>
  calls.filter((c) => c.url === "https://oauth2.googleapis.com/token");
const sendCalls = (calls: Call[]) =>
  calls.filter((c) => c.url.includes("fcm.googleapis.com"));

function errorResponse(
  status: number,
  errStatus: string,
  message: string,
  errorCode?: string,
): Response {
  return new Response(
    JSON.stringify({
      error: {
        code: status,
        message,
        status: errStatus,
        details: errorCode
          ? [{
            "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError",
            errorCode,
          }]
          : [],
      },
    }),
    { status },
  );
}

Deno.test("buildRealFcmProvider：service account 缺、非 JSON、缺欄位 → 建構時 fail loud", () => {
  const f = makeFetch([]);
  assertThrows(() =>
    buildRealFcmProvider({ serviceAccountJson: undefined, fetch: f })
  );
  assertThrows(() =>
    buildRealFcmProvider({ serviceAccountJson: "", fetch: f })
  );
  assertThrows(() =>
    buildRealFcmProvider({ serviceAccountJson: "not json", fetch: f })
  );
  assertThrows(() =>
    buildRealFcmProvider({
      serviceAccountJson: JSON.stringify({ project_id: "p" }),
      fetch: f,
    })
  );
});

Deno.test("OAuth2 assertion 是合法 RS256 JWT——header/claims 正確、簽章可用對應公鑰驗證", async () => {
  const { json, publicKey } = await makeTestServiceAccount();
  const calls: Call[] = [];
  const provider = buildRealFcmProvider({
    serviceAccountJson: json,
    fetch: makeFetch(calls),
  });
  const before = Math.floor(Date.now() / 1000);
  assertEquals(await provider.send("tok", "標題", "內文"), { ok: true });

  const form = new URLSearchParams(tokenCalls(calls)[0].init?.body as string);
  assertEquals(
    form.get("grant_type"),
    "urn:ietf:params:oauth:grant-type:jwt-bearer",
  );
  const [h, p, s] = form.get("assertion")!.split(".");
  const header = JSON.parse(new TextDecoder().decode(base64UrlDecode(h)));
  const claims = JSON.parse(new TextDecoder().decode(base64UrlDecode(p)));
  assertEquals(header.alg, "RS256");
  assertEquals(claims.iss, "fcm@sprout-test.iam.gserviceaccount.com");
  assertEquals(
    claims.scope,
    "https://www.googleapis.com/auth/firebase.messaging",
  );
  assertEquals(claims.aud, "https://oauth2.googleapis.com/token");
  assert(claims.iat >= before);
  assertEquals(claims.exp, claims.iat + 3600);
  const verified = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    publicKey,
    base64UrlDecode(s) as unknown as BufferSource,
    new TextEncoder().encode(`${h}.${p}`) as unknown as BufferSource,
  );
  assertEquals(verified, true, "JWT 簽章必須能用對應的公鑰驗證通過");
});

Deno.test("send：打 projects/<project_id>/messages:send，帶 Bearer access token 與 token／title／body", async () => {
  const { json } = await makeTestServiceAccount();
  const calls: Call[] = [];
  const provider = buildRealFcmProvider({
    serviceAccountJson: json,
    fetch: makeFetch(calls),
  });
  await provider.send("device-tok", "萌芽日記", "媽媽新增了一則日記");
  const send = sendCalls(calls)[0];
  assertEquals(
    send.url,
    "https://fcm.googleapis.com/v1/projects/sprout-test/messages:send",
  );
  const headers = send.init?.headers as Record<string, string>;
  assertEquals(headers.authorization, "Bearer access-token-1");
  const body = JSON.parse(send.init?.body as string);
  assertEquals(body.message.token, "device-tok");
  assertEquals(body.message.notification, {
    title: "萌芽日記",
    body: "媽媽新增了一則日記",
  });
  assert(send.init?.signal, "應帶 AbortSignal.timeout");
});

Deno.test("access token 快取：50 分鐘內多次 send（含併發）只換一次；超過 50 分鐘才重換", async () => {
  const { json } = await makeTestServiceAccount();
  const calls: Call[] = [];
  let nowMs = 1_000_000;
  const provider = buildRealFcmProvider({
    serviceAccountJson: json,
    fetch: makeFetch(calls),
    now: () => nowMs,
  });
  await Promise.all([
    provider.send("a", "t", "b"),
    provider.send("b", "t", "b"),
    provider.send("c", "t", "b"),
  ]);
  nowMs += 49 * 60 * 1000;
  await provider.send("d", "t", "b");
  assertEquals(tokenCalls(calls).length, 1, "50 分鐘內只該換一次 token");
  assertEquals(sendCalls(calls).length, 4);
  nowMs += 2 * 60 * 1000; // 累計 51 分鐘
  await provider.send("e", "t", "b");
  assertEquals(tokenCalls(calls).length, 2, "超過 50 分鐘應重換");
});

Deno.test("404 + errorCode UNREGISTERED → invalidToken:true（對齊 APNs 410 契約）", async () => {
  const { json } = await makeTestServiceAccount();
  const provider = buildRealFcmProvider({
    serviceAccountJson: json,
    fetch: makeFetch(
      [],
      () =>
        errorResponse(
          404,
          "NOT_FOUND",
          "Requested entity was not found.",
          "UNREGISTERED",
        ),
    ),
  });
  const outcome = await provider.send("dead", "t", "b");
  assertEquals(outcome.ok, false);
  assert(!outcome.ok && outcome.invalidToken, "UNREGISTERED 應判為失效 token");
});

Deno.test("400 INVALID_ARGUMENT 且訊息指明 registration token → invalidToken:true", async () => {
  const { json } = await makeTestServiceAccount();
  const provider = buildRealFcmProvider({
    serviceAccountJson: json,
    fetch: makeFetch(
      [],
      () =>
        errorResponse(
          400,
          "INVALID_ARGUMENT",
          "The registration token is not a valid FCM registration token",
          "INVALID_ARGUMENT",
        ),
    ),
  });
  const outcome = await provider.send("bad", "t", "b");
  assert(!outcome.ok && outcome.invalidToken);
});

Deno.test("不該誤刪 token：404 無 UNREGISTERED（例如 project_id 設錯）、400 但不是 token 問題、500、非 JSON 回應 → invalidToken:false", async () => {
  const { json } = await makeTestServiceAccount();
  const cases: Array<[string, () => Response]> = [
    [
      "404 無 UNREGISTERED",
      () => errorResponse(404, "NOT_FOUND", "Requested entity was not found."),
    ],
    [
      "400 payload 問題",
      () =>
        errorResponse(
          400,
          "INVALID_ARGUMENT",
          "Invalid JSON payload received.",
          "INVALID_ARGUMENT",
        ),
    ],
    ["500", () => errorResponse(500, "INTERNAL", "boom")],
    ["非 JSON 404", () => new Response("<html>", { status: 404 })],
  ];
  for (const [name, responder] of cases) {
    const provider = buildRealFcmProvider({
      serviceAccountJson: json,
      fetch: makeFetch([], responder),
    });
    const outcome = await provider.send("tok", "t", "b");
    assert(!outcome.ok && !outcome.invalidToken, `${name} 不該判為失效 token`);
  }
});

Deno.test("401：強制重換 access token 並重試一次；重試成功 → ok", async () => {
  const { json } = await makeTestServiceAccount();
  const calls: Call[] = [];
  let sendCount = 0;
  const provider = buildRealFcmProvider({
    serviceAccountJson: json,
    fetch: makeFetch(calls, () => {
      sendCount++;
      return sendCount === 1
        ? errorResponse(401, "UNAUTHENTICATED", "expired")
        : new Response("{}", { status: 200 });
    }),
  });
  assertEquals(await provider.send("tok", "t", "b"), { ok: true });
  assertEquals(tokenCalls(calls).length, 2, "401 後應強制重換一次");
  assertEquals(sendCalls(calls).length, 2, "只重試一次");
});

Deno.test("OAuth2 token 交換失敗 → failed（非失效 token），且失敗不被快取、下一次 send 會重試交換", async () => {
  const { json } = await makeTestServiceAccount();
  let tokenAttempts = 0;
  const fetchImpl = ((url: string | URL) => {
    if (String(url) === "https://oauth2.googleapis.com/token") {
      tokenAttempts++;
      return Promise.resolve(
        tokenAttempts === 1
          ? new Response("{}", { status: 500 })
          : new Response(JSON.stringify({ access_token: "ok" }), {
            status: 200,
          }),
      );
    }
    return Promise.resolve(new Response("{}", { status: 200 }));
  }) as unknown as typeof fetch;
  const provider = buildRealFcmProvider({
    serviceAccountJson: json,
    fetch: fetchImpl,
  });
  const first = await provider.send("tok", "t", "b");
  assert(!first.ok && !first.invalidToken);
  assertEquals(await provider.send("tok", "t", "b"), { ok: true });
  assertEquals(tokenAttempts, 2);
});
