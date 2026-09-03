// LS-151 — delete-account 的核心邏輯（可測試部分）。
//
// 拆成 handler.ts（純邏輯＋依賴注入）＋index.ts（Deno.serve 進入點＋真正的
// supabase-js client 建構）兩個檔案：index.ts 頂層若直接呼叫 Deno.serve()，
// index.test.ts 只是 import 它就會嘗試綁定一個 HTTP listener（`deno test` 預設
// 不給 --allow-net，會直接因權限被拒），單元測試必須 import 一個不含
// Deno.serve() 副作用的模組——這裡就是那個模組。
//
// 呼叫順序契約（docs/API.md §10 Edge Functions／§4 delete_my_account 已明文）：
// client 呼叫 delete_my_account() RPC 成功後立即呼叫本端點，中間不得有其他操作。
// 本端點的職責：
//   1. 驗證呼叫者 JWT（authenticated），換回 uid。
//   2. 以 service_role 檢查 profiles.deletion_requested_at is not null——這是
//      刻意的守門：不是每個登入使用者都能直接打這支端點刪掉自己的帳號，必須先
//      走過 delete_my_account() RPC 的資料面安全檢查（唯一 owner 須先轉移等）。
//   3. Apple／Google token 撤銷（best-effort，見 revokeAppleToken／
//      revokeGoogleToken）——絕不能因為撤銷失敗或缺 env 而擋下刪除，帳號刪除是
//      強制性動作，第三方撤銷是附加的盡力而為。
//   4. 呼叫 GoTrue admin API 刪除 auth.users（profiles 隨 on delete cascade 消失）。
//
// 冪等語意：見 handleRequest 內對 deleteAuthUser 回傳值的處理與
// docs/API.md §10「冪等語意」段落。

export interface CallerUser {
  id: string;
}

// identity_data 的形狀由各 OAuth provider 決定，這裡只當成一個 string-keyed 的
// 袋子——本專案目前沒有在登入流程保存 provider 的 refresh/access token（見
// docs/API.md §10「已知限制」），findProviderToken() 因此在現有資料下幾乎必定
// 找不到值，但程式碼路徑本身要能被測試（之後補了保存 token 的登入流程，這裡
// 不需要再改）。
export interface Identity {
  provider: string;
  identity_data?: Record<string, unknown>;
}

export interface DeletionRequestedStatus {
  /** profiles 列是否存在。不存在時一律視為「未通過守門」，見上方檔頭第 2 步。 */
  found: boolean;
  /** deletion_requested_at 是否非 NULL。 */
  requested: boolean;
}

export interface DeleteAuthUserResult {
  ok: boolean;
  /** GoTrue 回報「使用者不存在」——視為已達成目的（冪等），不是失敗。 */
  notFound: boolean;
  error?: string;
}

export interface RevokeAttempt {
  attempted: boolean;
  ok?: boolean;
  reason: string;
}

export interface Deps {
  /** 驗證 Authorization header 帶的 JWT，換回呼叫者。null＝JWT 缺失／無效／使用者已不存在。 */
  getCallerUser(authHeader: string | null): Promise<CallerUser | null>;
  /** service_role 讀 profiles.deletion_requested_at。 */
  getDeletionRequestedAt(uid: string): Promise<DeletionRequestedStatus>;
  /** 呼叫者名下的 OAuth identities（admin.getUserById 回傳的 identities 陣列）。 */
  getIdentities(uid: string): Promise<Identity[]>;
  /** GoTrue admin deleteUser。 */
  deleteAuthUser(uid: string): Promise<DeleteAuthUserResult>;
  /** 注入點：Apple／Google revoke 呼叫用的 fetch（單元測試用 stub 取代）。 */
  fetchImpl: typeof fetch;
  /** Sign in with Apple 的 client 憑證，缺一即跳過 Apple 撤銷（見票文）。 */
  appleClientId: string | undefined;
  appleClientSecret: string | undefined;
}

// 找 provider 存下來的 token——常見欄位名稱都試一輪（各 OAuth provider／不同時期
// 的 Supabase identity_data 形狀沒有統一慣例，寧可多試幾個欄位名，也不要因為
// 猜錯欄位名而把「其實有 token」誤判成「沒有 token」）。
const TOKEN_FIELD_CANDIDATES = [
  "provider_token",
  "provider_refresh_token",
  "refresh_token",
  "access_token",
] as const;

export function findProviderToken(
  identities: Identity[],
  provider: string,
): string | undefined {
  const identity = identities.find((i) => i.provider === provider);
  if (!identity?.identity_data) return undefined;
  for (const field of TOKEN_FIELD_CANDIDATES) {
    const value = identity.identity_data[field];
    if (typeof value === "string" && value.length > 0) return value;
  }
  return undefined;
}

export async function revokeAppleToken(
  deps: Deps,
  identities: Identity[],
): Promise<RevokeAttempt> {
  if (!deps.appleClientId || !deps.appleClientSecret) {
    return {
      attempted: false,
      reason: "缺 APPLE_CLIENT_ID／APPLE_CLIENT_SECRET，略過",
    };
  }
  const token = findProviderToken(identities, "apple");
  if (!token) {
    return {
      attempted: false,
      reason: "找不到已存的 Apple provider token，略過",
    };
  }
  try {
    const res = await deps.fetchImpl("https://appleid.apple.com/auth/revoke", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: deps.appleClientId,
        client_secret: deps.appleClientSecret,
        token,
      }),
    });
    return {
      attempted: true,
      ok: res.ok,
      reason: res.ok
        ? "Apple revoke 成功"
        : `Apple revoke 回應非 2xx（${res.status}）`,
    };
  } catch (err) {
    return {
      attempted: true,
      ok: false,
      reason: `Apple revoke 呼叫失敗：${String(err)}`,
    };
  }
}

export async function revokeGoogleToken(
  deps: Deps,
  identities: Identity[],
): Promise<RevokeAttempt> {
  const token = findProviderToken(identities, "google");
  if (!token) {
    return {
      attempted: false,
      reason: "找不到已存的 Google provider token，略過",
    };
  }
  try {
    const res = await deps.fetchImpl(
      `https://oauth2.googleapis.com/revoke?token=${encodeURIComponent(token)}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
      },
    );
    return {
      attempted: true,
      ok: res.ok,
      reason: res.ok
        ? "Google revoke 成功"
        : `Google revoke 回應非 2xx（${res.status}）`,
    };
  } catch (err) {
    return {
      attempted: true,
      ok: false,
      reason: `Google revoke 呼叫失敗：${String(err)}`,
    };
  }
}

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
  const authHeader = req.headers.get("Authorization");
  const user = await deps.getCallerUser(authHeader);
  if (!user) {
    // 涵蓋：沒帶 Authorization、JWT 無效／過期、或使用者已被刪除（冪等重複呼叫，
    // 見 docs/API.md §10「冪等語意」）——三種情況呼叫端都該視為「這個帳號目前
    // 沒有有效登入」，不是伺服器錯誤。
    return jsonResponse(401, {
      error: "無法驗證呼叫者身分（JWT 無效，或使用者已不存在）",
    });
  }

  const status = await deps.getDeletionRequestedAt(user.id);
  if (!status.found || !status.requested) {
    // fail loud：不區分「profiles 列不存在」與「存在但 deletion_requested_at 是
    // NULL」的錯誤文案，兩者都是同一個結論——呼叫者沒有走過 delete_my_account()
    // RPC 的守門，不放行。這是刻意的安全邊界，不是遺漏（票文「不得讓未走 RPC 的
    // 人直接刪」）。
    return jsonResponse(400, {
      error: "尚未呼叫 delete_my_account() RPC 標記刪除請求，無法直接刪除帳號",
    });
  }

  const identities = await deps.getIdentities(user.id);
  const appleRevoke = await revokeAppleToken(deps, identities);
  const googleRevoke = await revokeGoogleToken(deps, identities);

  const deleteResult = await deps.deleteAuthUser(user.id);
  if (!deleteResult.ok && !deleteResult.notFound) {
    return jsonResponse(500, {
      error: deleteResult.error ?? "刪除 auth.users 失敗",
    });
  }

  return jsonResponse(200, {
    deleted: true,
    alreadyDeleted: deleteResult.notFound,
    revocations: { apple: appleRevoke, google: googleRevoke },
  });
}
