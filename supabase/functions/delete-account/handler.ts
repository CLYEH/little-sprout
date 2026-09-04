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
// 本端點的職責（R3 訂正順序，merge-review R2 N5）：
//   1. 驗證呼叫者 JWT（authenticated），換回 uid。
//   2. 以 service_role 檢查 profiles.deletion_requested_at is not null——這是
//      刻意的守門：不是每個登入使用者都能直接打這支端點刪掉自己的帳號，必須先
//      走過 delete_my_account() RPC 的資料面安全檢查（唯一 owner 須先轉移等）。
//   3. 以 service_role 呼叫 finalize_account_deletion(uid) 重跑一次資料面清理
//      （第一道防線，見 docs/API.md §10）。失敗就 fail loud（不繼續往下走）——
//      排在撤銷**之前**：撤銷是不可逆動作，finalize 卻可能因暫時性競態失敗
//      （N1，40P01），不該讓不可逆的撤銷搶在可能失敗的步驟之前執行。
//   4. Apple／Google token 撤銷（best-effort，見 revokeAppleToken／
//      revokeGoogleToken）——絕不能因為撤銷失敗或缺 env 而擋下刪除，帳號刪除是
//      強制性動作，第三方撤銷是附加的盡力而為。
//   5. 呼叫 GoTrue admin API 刪除 auth.users（profiles 隨 on delete cascade 消失）。
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

export interface FinalizeAccountDeletionResult {
  ok: boolean;
  error?: string;
  /**
   * R3（merge-review R2 N1）：true＝這是已知的暫時性競態（例如同家庭併發成員
   * 異動撞見的 40P01 死鎖，Postgres 自動偵測、單邊回滾、無資料損毀，重試必定
   * 收斂）——handleRequest 據此回 503（可安全重試），不是泛用的 500。
   */
  retryable?: boolean;
}

export interface Deps {
  /** 驗證 Authorization header 帶的 JWT，換回呼叫者。null＝JWT 缺失／無效／使用者已不存在。 */
  getCallerUser(authHeader: string | null): Promise<CallerUser | null>;
  /** service_role 讀 profiles.deletion_requested_at。 */
  getDeletionRequestedAt(uid: string): Promise<DeletionRequestedStatus>;
  /** 呼叫者名下的 OAuth identities（admin.getUserById 回傳的 identities 陣列）。 */
  getIdentities(uid: string): Promise<Identity[]>;
  /**
   * R2（merge-review R1 B1／M1，第一道防線）：刪除 auth.users 前以 service_role
   * 呼叫 public.finalize_account_deletion(uid)，重跑一次資料面清理——不依賴過渡期
   * 擋寫（LS051）完全沒有漏洞，保證呼叫者被真正刪除前一定沒有任何一列
   * family_members，見 docs/API.md §10。
   */
  finalizeAccountDeletion(uid: string): Promise<FinalizeAccountDeletionResult>;
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
    // M2（merge-review R1）：Deno 的 fetch 預設沒有逾時上限，appleid.apple.com
    // 若被黑洞（TCP 建立後不回應）會讓 await 永遠不返回，deleteAuthUser() 因此
    // 永遠不會被呼叫——直接違反上面檔頭「絕不能因為撤銷失敗或缺 env 而擋下刪除」
    // 的承諾。AbortSignal.timeout() 逾時會讓 fetch reject（TimeoutError），落進
    // 下面既有的 catch，跟其他 fetch 失敗一視同仁地當成 best-effort 失敗，不需要
    // 額外的錯誤處理分支。
    const res = await deps.fetchImpl("https://appleid.apple.com/auth/revoke", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: deps.appleClientId,
        client_secret: deps.appleClientSecret,
        token,
      }),
      signal: AbortSignal.timeout(5000),
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
    // M2：同 revokeAppleToken——逾時落進下面既有的 catch，不擋刪除。
    const res = await deps.fetchImpl(
      `https://oauth2.googleapis.com/revoke?token=${encodeURIComponent(token)}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        signal: AbortSignal.timeout(5000),
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
  // minor-1（merge-review R1）：docs/API.md §10 寫的路徑是「POST …/delete-account」，
  // 但這支端點本來對任何 method 一視同仁地執行刪除——GET 具破壞性、且與文件不符。
  if (req.method !== "POST") {
    return jsonResponse(405, { error: "只接受 POST" });
  }

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

  // R2（merge-review R1 B1／M1，第一道防線）：刪除 auth.users 前先以 service_role
  // 重跑一次資料面清理——不論過渡期擋寫（LS051）有沒有漏洞，這一步都保證呼叫者
  // 被真正刪除前一定沒有任何一列 family_members，讓下面的 deleteAuthUser 不會撞見
  // LS001。失敗就 fail loud（不繼續往下走撤銷／刪除）：finalize_account_deletion
  // 在正常情況下近乎是 no-op（迴圈跑過 0 個家庭），會失敗代表資料面本身有問題，
  // 樂觀地繼續刪 auth.users 只會讓問題更難排查。
  //
  // N5（merge-review R2）：排在 Apple／Google 撤銷**之前**——撤銷是不可逆的第三方
  // 動作，finalize 卻可能失敗（N1 的 40P01 窗口），若撤銷排在 finalize 之前，
  // finalize 失敗時授權已經撤銷但帳號還在，使用者要重新登入卻拿不回撤銷掉的
  // 授權。目前零實際影響（本專案未保存 provider token，撤銷分支必定 skip），但
  // 一旦「保存 provider token」的後續票落地就會是真的問題，這裡先把順序訂對。
  const cleanupResult = await deps.finalizeAccountDeletion(user.id);
  if (!cleanupResult.ok) {
    console.log(
      `delete-account: finalizeAccountDeletion user=${user.id} result=failed`,
    );
    // N2（merge-review R2）：原始錯誤（可能含其他家庭的 UUID、內部 SQL 片段）只
    // 進 console.error，不進回應 body——這是隱私優先產品，HTTP 回應不該外洩資料庫
    // 內部訊息。body 一律固定文案，呼叫端只需要 stage 分流。
    console.error(
      `delete-account: finalizeAccountDeletion error user=${user.id}: ${cleanupResult.error}`,
    );
    if (cleanupResult.retryable) {
      // N1（merge-review R2）：已知的暫時性競態（40P01，見 index.ts
      // finalizeAccountDeletion 的重試邏輯與已重試一次仍失敗的情況）——503 告訴
      // 呼叫端這是可安全重試的暫時狀態，不是 500 的泛用失敗。
      return jsonResponse(503, {
        error: "deletion_temporarily_unavailable",
        stage: "finalize",
      });
    }
    return jsonResponse(500, { error: "deletion_failed", stage: "finalize" });
  }

  const identities = await deps.getIdentities(user.id);
  // minor-2（merge-review R1）：Apple／Google 兩支撤銷互相獨立，串行 await 白白
  // 多等一趟 RTT——改 Promise.all 平行送出。
  const [appleRevoke, googleRevoke] = await Promise.all([
    revokeAppleToken(deps, identities),
    revokeGoogleToken(deps, identities),
  ]);
  // minor-4（merge-review R1）：撤銷結果之前完全沒有任何伺服器端稽核痕跡（EF 全檔
  // 零 console.*）——LS-132 隱私政策 §8 的撤銷承諾之後要舉證會沒有東西可舉。只記
  // user id 與結果碼，不含 token／key／email。
  console.log(
    `delete-account: revocations user=${user.id} apple=${
      appleRevoke.attempted ? (appleRevoke.ok ? "ok" : "failed") : "skipped"
    } google=${
      googleRevoke.attempted ? (googleRevoke.ok ? "ok" : "failed") : "skipped"
    }`,
  );

  const deleteResult = await deps.deleteAuthUser(user.id);
  console.log(
    `delete-account: deleteAuthUser user=${user.id} result=${
      deleteResult.ok
        ? "ok"
        : deleteResult.notFound
        ? "already_deleted"
        : "failed"
    }`,
  );
  if (!deleteResult.ok && !deleteResult.notFound) {
    // N2：同上，原始錯誤只進 console.error，body 固定文案。
    console.error(
      `delete-account: deleteAuthUser error user=${user.id}: ${deleteResult.error}`,
    );
    return jsonResponse(500, {
      error: "deletion_failed",
      stage: "auth_delete",
    });
  }

  return jsonResponse(200, {
    deleted: true,
    alreadyDeleted: deleteResult.notFound,
    revocations: { apple: appleRevoke, google: googleRevoke },
  });
}
