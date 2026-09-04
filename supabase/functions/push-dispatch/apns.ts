// LS-172 — 真正打 APNs 的 ApnsProvider 實作：token-based auth（ES256 JWT）＋
// HTTP/2（Deno 的 fetch 對 HTTPS 端點自動協商 h2，不需要額外套件——APNs 的
// HTTP/1.1 端點已於 2021 年除役，只接受 HTTP/2）。
//
// 這個檔案刻意不參與 handler.ts 的依賴注入測試——`runDispatch`／`handleRequest`
// 只透過 `ApnsProvider` 介面（`StubApnsProvider`）測試派送邏輯（見
// `handler.test.ts`），這裡的 `apns.test.ts` 只測「JWT 是否簽得對」「缺 secrets
// 是否 fail loud」「410／BadDeviceToken 是否正確判定為失效 token」，一律用注入的
// fake `fetch`，不打真正的 Apple 伺服器。
//
// 五個 secrets（`docs/API.md` §10 push-dispatch 段已明文，需以
// `supabase secrets set` 設定）：`APNS_TEAM_ID`／`APNS_KEY_ID`／`APNS_P8`
// （.p8 私鑰全文，PEM 格式，含 BEGIN/END 行）／`APNS_BUNDLE_ID`／`APNS_ENV`
// （`"production"` 或其他值皆視為 sandbox——sandbox 是本機／TestFlight 開發期
// 的預設，正式站部署時才需要明確設成 `"production"`）。

import type { ApnsOutcome, ApnsProvider } from "./handler.ts";

export interface ApnsSecrets {
  teamId: string | undefined;
  keyId: string | undefined;
  /** PEM 格式的 .p8 私鑰全文（含 BEGIN/END 行）。 */
  p8: string | undefined;
  bundleId: string | undefined;
  /** `"production"` | 其他（視為 sandbox）。 */
  env: string | undefined;
}

const PRODUCTION_HOST = "https://api.push.apple.com";
const SANDBOX_HOST = "https://api.sandbox.push.apple.com";

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

async function signApnsJwt(
  secrets: { teamId: string; keyId: string; p8: string },
): Promise<string> {
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToPkcs8(secrets.p8) as unknown as BufferSource,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const header = { alg: "ES256", kid: secrets.keyId };
  const payload = { iss: secrets.teamId, iat: Math.floor(Date.now() / 1000) };
  const encoder = new TextEncoder();
  const signingInput =
    `${base64UrlEncode(encoder.encode(JSON.stringify(header)))}.` +
    `${base64UrlEncode(encoder.encode(JSON.stringify(payload)))}`;
  // Web Crypto 的 ECDSA sign() 回傳的就是 JOSE/JWA 要求的 raw r||s 格式
  // （不是 OpenSSL 預設的 DER/ASN.1），不需要額外轉換。
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    encoder.encode(signingInput),
  );
  return `${signingInput}.${base64UrlEncode(new Uint8Array(signature))}`;
}

/**
 * 建構真正打 APNs 的 provider。**缺任一 secret 立即丟出例外（fail loud，不送）**
 * ——呼叫端（index.ts 的 buildProdDeps）在模組層級呼叫這支函式，缺 secrets 時
 * 整個 isolate 冷啟動就失敗，不會等到收到請求才發現、更不會悄悄降級成「不送」。
 */
export function buildRealApnsProvider(
  secrets: ApnsSecrets,
  fetchImpl: typeof fetch,
): ApnsProvider {
  const { teamId, keyId, p8, bundleId, env } = secrets;
  if (!teamId || !keyId || !p8 || !bundleId || !env) {
    throw new Error(
      "APNS_TEAM_ID／APNS_KEY_ID／APNS_P8／APNS_BUNDLE_ID／APNS_ENV 未設定齊全，fail loud 不送",
    );
  }
  const host = env === "production" ? PRODUCTION_HOST : SANDBOX_HOST;
  // 上面的 narrowing（string | undefined → string）不會穿過下面 getJwt 這個巢狀
  // function 的邊界（TypeScript 對 function 宣告的閉包不保證延續外層的窄化）——
  // 這裡緊接著建一個型別已經是 string（不是 string | undefined）的新物件，
  // getJwt 內部直接吃這個已經確定的型別，不需要依賴窄化穿透閉包。
  const signingSecrets: { teamId: string; keyId: string; p8: string } = {
    teamId,
    keyId,
    p8,
  };

  // Apple 建議同一把 JWT 在效期內（最長 1 小時）重複使用，不必每次呼叫都重簽——
  // 這裡 lazy 簽一次、快取在 provider 實例上，同一次 invocation 內的多個 send()
  // 呼叫共用同一把 token；下一次 invocation 是全新的 provider 實例，天然過期，
  // 不需要額外的過期判斷邏輯。
  let cachedJwt: Promise<string> | null = null;
  function getJwt(): Promise<string> {
    if (!cachedJwt) cachedJwt = signApnsJwt(signingSecrets);
    return cachedJwt;
  }

  return {
    async send(
      token: string,
      title: string,
      body: string,
    ): Promise<ApnsOutcome> {
      const jwt = await getJwt();
      const res = await fetchImpl(`${host}/3/device/${token}`, {
        method: "POST",
        headers: {
          "authorization": `bearer ${jwt}`,
          "apns-topic": bundleId,
          "apns-push-type": "alert",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          aps: { alert: { title, body }, sound: "default" },
        }),
      });
      if (res.ok) return { ok: true };

      let reason = "";
      try {
        const parsed = await res.json();
        reason = typeof parsed?.reason === "string" ? parsed.reason : "";
      } catch {
        // 回應不是合法 JSON：reason 留空，不影響下面的失效判斷（410 本身就夠）。
      }
      // 票文明定：410 Unregistered／400 BadDeviceToken 才視為失效 token。其他
      // 錯誤（例如 BadTopic、TopicDisallowed、ExpiredProviderToken）只記 log、
      // 不刪 token、不重試——那些是設定或憑證問題，不是「這支裝置不會再收到通知」。
      const invalidToken = res.status === 410 ||
        (res.status === 400 && reason === "BadDeviceToken");
      return {
        ok: false,
        invalidToken,
        error: `APNs ${res.status}${reason ? " " + reason : ""}`,
      };
    },
  };
}
