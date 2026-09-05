// LS-196 — 三支 service-only Edge Function（purge-storage／push-dispatch／
// delete-account 的 admin client）共用的金鑰解析與鑑權 helper。
//
// 背景（LS-153 i4 煙測，comment 0535eab8）：正式站 `supabase secrets list` 回報的
// `SUPABASE_SERVICE_ROLE_KEY` sha256 digest 不等於 CLI／Management API 回報的
// legacy service_role JWT——專案已建新式 `sb_secret_` default key，EF 執行期注入
// 的 `SUPABASE_SERVICE_ROLE_KEY` 從來就不是那把 legacy JWT。`purge-storage` 原本
// 「bearer !== SUPABASE_SERVICE_ROLE_KEY」的守門在正式站因此對任何呼叫者都是
// 401。官方遷移指引（docs「Migrating to publishable and secret API keys」
// §Database Webhooks and pg_net／§Step 4）：service 端呼叫改送
// `apikey: sb_secret_…`，EF 讀 `JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS'))
// ['default']` 比對；`Authorization: Bearer` 不再是新式 key 該放的位置。
//
// 這裡的兩支函式都是純函式（env／headers 以參數注入，不直接讀 `Deno.env`）——
// 方便 Deno 單元測試不需要 `--allow-env` 也能覆蓋各種環境組合，也讓
// index.ts／handler.ts 保有「production 用 Deno.env.get() 組出這個物件、測試用
// 假物件」的既有慣例（同 delete-account／push-dispatch 的 Deps 注入模式）。

/**
 * 兩支相關環境變數的最小介面——只取這支模組需要的兩個 key，不是整個
 * `Deno.Env`，方便測試直接建構純物件。
 */
export interface SecretKeyEnv {
  /** 新式 key（JSON 字串，例如 `'{"default":"sb_secret_..."}'`，可能在金鑰輪替
   * 期間有多把並存）。本機舊版 CLI／尚未遷移的環境可能沒有這個變數。 */
  SUPABASE_SECRET_KEYS?: string;
  /** legacy service_role JWT。過渡期仍要接受，直到所有呼叫端（pg_cron 標頭、
   * 外部排程）都已改用新式 key 為止。 */
  SUPABASE_SERVICE_ROLE_KEY?: string;
}

// 常數時間字串比對（沿用 push-dispatch/handler.ts 既有的 LS-172 R2 i4 寫法）：
// 不論兩個字串是否等長、哪個位置先出現差異，都逐位元組跑完整輪比較才判斷，
// 耗時只跟兩個字串的最大長度有關——避免用 `!==` 的逐字元短路比較被拿來做
// timing attack 猜金鑰。
function timingSafeEqual(a: string, b: string): boolean {
  const bytesA = new TextEncoder().encode(a);
  const bytesB = new TextEncoder().encode(b);
  const len = Math.max(bytesA.length, bytesB.length, 1);
  let diff = bytesA.length === bytesB.length ? 0 : 1;
  for (let i = 0; i < len; i++) {
    const byteA = i < bytesA.length ? bytesA[i] : 0;
    const byteB = i < bytesB.length ? bytesB[i] : 0;
    diff |= byteA ^ byteB;
  }
  return diff === 0;
}

/**
 * 解析 `SUPABASE_SECRET_KEYS`（JSON 物件字串）。JSON 壞掉、不是物件、或是陣列
 * 一律回傳 `undefined`——fail closed：呼叫端把這當成「新式 key 不可用」，不會
 * 讓一個解析錯誤意外被當成「有值就放行」。
 */
function parseSecretKeys(raw: string | undefined): Record<string, unknown> | undefined {
  if (!raw) return undefined;
  try {
    const parsed = JSON.parse(raw);
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      return undefined;
    }
    return parsed as Record<string, unknown>;
  } catch {
    return undefined;
  }
}

function stringValues(obj: Record<string, unknown> | undefined): string[] {
  if (!obj) return [];
  return Object.values(obj).filter(
    (v): v is string => typeof v === "string" && v.length > 0,
  );
}

/**
 * 解析出可以用來建立 admin client 的 secret key：優先 `SUPABASE_SECRET_KEYS`
 * 的 `"default"` 值，缺少（未設定、JSON 壞掉、或沒有 `default` 這個 key，例如
 * 本機舊版 CLI 只提供 legacy 變數）時退回 `SUPABASE_SERVICE_ROLE_KEY`。兩者皆
 * 沒有 → `undefined`，呼叫端據此 fail loud（部署設定缺失，不是「當作沒有事件
 * 可處理」悄悄放行）。
 */
export function resolveSecretKey(env: SecretKeyEnv): string | undefined {
  const parsed = parseSecretKeys(env.SUPABASE_SECRET_KEYS);
  const fromNew = parsed?.default;
  if (typeof fromNew === "string" && fromNew.length > 0) return fromNew;
  return env.SUPABASE_SERVICE_ROLE_KEY;
}

/**
 * 判斷這次呼叫是否持有合法的 service 憑證：
 *   - `apikey` header 等於 `SUPABASE_SECRET_KEYS` 底下任一把值（不只
 *     `"default"`——金鑰輪替期間新舊兩把新式 key 可能並存，任一把都該放行）；
 *     或
 *   - （過渡，直到所有呼叫端都已改用新式 key 為止）`Authorization: Bearer`
 *     等於 `SUPABASE_SERVICE_ROLE_KEY` 本身——不是「JWT 合法即可」，anon key
 *     也是合法 JWT，這裡要的是「呼叫者持有 service 憑證」這件更窄的事。
 * 新式 key 一律放在 `apikey` header，**不**接受放在 `Authorization: Bearer`
 * （官方遷移指引：新式 key 不是 JWT，不該塞進原本給 JWT 用的欄位）。
 *
 * `SUPABASE_SECRET_KEYS` JSON 壞掉時 fail closed：解析不到任何值，`apikey`
 * 比對一律不通過，只剩 legacy bearer 這條路徑還可能放行——不會讓一個解析錯誤
 * 意外變成「什麼都放行」。
 */
export function isAuthorizedServiceCall(
  headers: Headers,
  env: SecretKeyEnv,
): boolean {
  const apikey = headers.get("apikey") ?? "";
  if (apikey) {
    const candidates = stringValues(parseSecretKeys(env.SUPABASE_SECRET_KEYS));
    for (const candidate of candidates) {
      if (timingSafeEqual(apikey, candidate)) return true;
    }
  }

  const authHeader = headers.get("Authorization") ?? "";
  const bearer = authHeader.startsWith("Bearer ")
    ? authHeader.slice("Bearer ".length)
    : "";
  if (bearer && env.SUPABASE_SERVICE_ROLE_KEY) {
    if (timingSafeEqual(bearer, env.SUPABASE_SERVICE_ROLE_KEY)) return true;
  }

  return false;
}
