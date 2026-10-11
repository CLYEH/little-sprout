// LS-473（Android 前置 A5）— 真正打 FCM HTTP v1 的 provider：service account JSON →
// RS256 JWT → OAuth2 access token（`https://oauth2.googleapis.com/token`）→
// `POST https://fcm.googleapis.com/v1/projects/<project_id>/messages:send`。
//
// 與 apns.ts 同型的測試策略：`fcm.test.ts` 全用注入的 fake `fetch`，不打真正的 Google；
// JWT 簽章用測試產生的 RSA 金鑰對現場驗證。
//
// 一個 secret（docs/API.md §10 push-dispatch 段已明文）：`FCM_SERVICE_ACCOUNT`——
// service account JSON 的**整份字串**（含 `client_email`／`private_key`／`project_id`）。
//
// 與 apns.ts 的差異（刻意）：
//   - 失效 token 的判定比 APNs 窄：FCM 的 404 也可能是 project_id 設錯（整個專案的送出都 404），
//     若只看狀態碼就會把全部 token 刪光——所以 404 必須在 error.details 看到
//     `errorCode: "UNREGISTERED"` 才算失效；400 INVALID_ARGUMENT 也可能是 payload 本身有問題，
//     只在 message 指明是 registration token 時才算失效（其餘一律 failed，只記 log）。
//   - 每次 fetch 帶 `AbortSignal.timeout`（apns.ts 沒有；本檔不回頭改 APNs 行為）。

import type { ApnsOutcome, PushProvider } from "./handler.ts";

export interface FcmServiceAccount {
  client_email: string;
  private_key: string;
  project_id: string;
  /** 服務帳戶 JSON 內的 token_uri；缺時用 Google 預設。 */
  token_uri?: string;
}

export interface FcmOptions {
  /** `FCM_SERVICE_ACCOUNT` 環境變數的整份 JSON 字串。 */
  serviceAccountJson: string | undefined;
  fetch: typeof fetch;
  /** 注入時鐘（epoch 毫秒），測試用；預設 Date.now。 */
  now?: () => number;
}

const DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token";
const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const ACCESS_TOKEN_MAX_AGE_MS = 50 * 60 * 1000; // Google access token 效期 1 小時，50 分鐘重換
const FETCH_TIMEOUT_MS = 10_000;

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(
    /=+$/,
    "",
  );
}

function pemToPkcs8(pem: string): Uint8Array {
  const base64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

async function signServiceAccountJwt(
  sa: FcmServiceAccount,
  audience: string,
  nowMs: number,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToPkcs8(sa.private_key) as unknown as BufferSource,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const iat = Math.floor(nowMs / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const payload = {
    iss: sa.client_email,
    scope: FCM_SCOPE,
    aud: audience,
    iat,
    exp: iat + 3600,
  };
  const encoder = new TextEncoder();
  const signingInput =
    `${base64UrlEncode(encoder.encode(JSON.stringify(header)))}.` +
    `${base64UrlEncode(encoder.encode(JSON.stringify(payload)))}`;
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    encoder.encode(signingInput),
  );
  return `${signingInput}.${base64UrlEncode(new Uint8Array(signature))}`;
}

function parseServiceAccount(json: string | undefined): FcmServiceAccount {
  if (!json) {
    throw new Error("FCM_SERVICE_ACCOUNT 未設定，fail loud 不送");
  }
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(json);
  } catch {
    throw new Error("FCM_SERVICE_ACCOUNT 不是合法 JSON");
  }
  const { client_email, private_key, project_id, token_uri } = parsed;
  if (
    typeof client_email !== "string" || typeof private_key !== "string" ||
    typeof project_id !== "string" || !client_email || !private_key ||
    !project_id
  ) {
    throw new Error(
      "FCM_SERVICE_ACCOUNT 缺 client_email／private_key／project_id，fail loud 不送",
    );
  }
  return {
    client_email,
    private_key,
    project_id,
    token_uri: typeof token_uri === "string" ? token_uri : undefined,
  };
}

/** FCM v1 錯誤本文 → 是否為「這支 token 不會再收到通知」。見檔頭差異說明。 */
function isInvalidTokenResponse(status: number, body: unknown): boolean {
  const error = (body as { error?: Record<string, unknown> } | null)?.error;
  if (!error) return false;
  const details = Array.isArray(error.details) ? error.details : [];
  const errorCodes = details.map((d) =>
    (d as { errorCode?: unknown })?.errorCode
  );
  if (status === 404) return errorCodes.includes("UNREGISTERED");
  if (status === 400) {
    return error.status === "INVALID_ARGUMENT" &&
      typeof error.message === "string" &&
      /registration token/i.test(error.message);
  }
  return false;
}

/**
 * 建構真正打 FCM 的 provider。**service account 缺或格式不對立即丟例外（fail loud，不送）**
 * ——index.ts 在冷啟動時呼叫並接住例外，記 console.error 後讓 fcm 路徑缺席
 * （handler 把 android 收件者計 failed，不影響 APNs）。
 */
export function buildRealFcmProvider(options: FcmOptions): PushProvider {
  const sa = parseServiceAccount(options.serviceAccountJson);
  const fetchImpl = options.fetch;
  const now = options.now ?? (() => Date.now());
  const tokenUri = sa.token_uri ?? DEFAULT_TOKEN_URI;
  const sendUrl =
    `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`;

  // access token 快取：存 Promise，同一時間多個 send() 併發也只換一次；換失敗要清掉，
  // 否則被拒絕的 Promise 會讓之後每次 send 都失敗到快取過期。
  let cached: { promise: Promise<string>; atMs: number } | null = null;
  function getAccessToken(forceRefresh = false): Promise<string> {
    const nowMs = now();
    if (
      !forceRefresh && cached && nowMs - cached.atMs < ACCESS_TOKEN_MAX_AGE_MS
    ) {
      return cached.promise;
    }
    const promise = (async () => {
      const assertion = await signServiceAccountJwt(sa, tokenUri, nowMs);
      const res = await fetchImpl(tokenUri, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
          assertion,
        }).toString(),
        signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
      });
      if (!res.ok) {
        throw new Error(`OAuth2 token 交換失敗 HTTP ${res.status}`);
      }
      const parsed = await res.json();
      if (typeof parsed?.access_token !== "string" || !parsed.access_token) {
        throw new Error("OAuth2 token 回應缺 access_token");
      }
      return parsed.access_token as string;
    })();
    const entry = { promise, atMs: nowMs };
    cached = entry;
    promise.catch(() => {
      if (cached === entry) cached = null;
    });
    return promise;
  }

  async function attempt(
    accessToken: string,
    token: string,
    title: string,
    body: string,
  ): Promise<{ ok: boolean; status: number; json: unknown }> {
    const res = await fetchImpl(sendUrl, {
      method: "POST",
      headers: {
        "authorization": `Bearer ${accessToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        message: {
          token,
          notification: { title, body },
          android: { priority: "HIGH" },
        },
      }),
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    if (res.ok) return { ok: true, status: res.status, json: null };
    let json: unknown = null;
    try {
      json = await res.json();
    } catch {
      // 非 JSON 回應：json 留 null，不影響失敗分類（只是不會被判成失效 token）。
    }
    return { ok: false, status: res.status, json };
  }

  return {
    async send(
      token: string,
      title: string,
      body: string,
    ): Promise<ApnsOutcome> {
      let result: { ok: boolean; status: number; json: unknown };
      try {
        result = await attempt(await getAccessToken(), token, title, body);
        // 401：access token 被提前作廢——強制重換一次並重試一次（同 apns.ts 403 路徑）。
        if (!result.ok && result.status === 401) {
          result = await attempt(
            await getAccessToken(true),
            token,
            title,
            body,
          );
        }
      } catch (err) {
        // token 交換失敗／逾時／網路錯：不是這支 token 的問題，回 failed（handler 計數＋log）。
        return { ok: false, invalidToken: false, error: `FCM ${String(err)}` };
      }
      if (result.ok) return { ok: true };
      const error = (result.json as { error?: { status?: unknown } } | null)
        ?.error;
      return {
        ok: false,
        invalidToken: isInvalidTokenResponse(result.status, result.json),
        error: `FCM ${result.status}${
          typeof error?.status === "string" ? " " + error.status : ""
        }`,
      };
    },
  };
}
