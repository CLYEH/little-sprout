// LS-196 — _shared/keys.ts 的 Deno 單元測試。純函式，env／headers 全部是注入的
// 假值，不連線任何真正的 Supabase 專案，不需要 --allow-env／--allow-net。
//
// 跑法：`deno test supabase/functions/_shared/`

import { assertEquals } from "jsr:@std/assert@1";
import { isAuthorizedServiceCall, resolveSecretKey } from "./keys.ts";

const NEW_DEFAULT = "test-new-key-default-abc123";
const NEW_PREVIOUS = "test-new-key-previous-xyz789";
const LEGACY = "legacy-service-role-jwt";

function secretKeysJson(obj: Record<string, string>): string {
  return JSON.stringify(obj);
}

function headers(init: Record<string, string> = {}): Headers {
  return new Headers(init);
}

// ---------------------------------------------------------------------------
// resolveSecretKey
// ---------------------------------------------------------------------------

Deno.test("resolveSecretKey：只有 legacy → 回傳 legacy", () => {
  const key = resolveSecretKey({ SUPABASE_SERVICE_ROLE_KEY: LEGACY });
  assertEquals(key, LEGACY);
});

Deno.test("resolveSecretKey：只有新式（僅 default）→ 回傳 default 值", () => {
  const key = resolveSecretKey({
    SUPABASE_SECRET_KEYS: secretKeysJson({ default: NEW_DEFAULT }),
  });
  assertEquals(key, NEW_DEFAULT);
});

Deno.test("resolveSecretKey：兩者皆有 → 優先回傳新式 default，不是 legacy", () => {
  const key = resolveSecretKey({
    SUPABASE_SECRET_KEYS: secretKeysJson({ default: NEW_DEFAULT }),
    SUPABASE_SERVICE_ROLE_KEY: LEGACY,
  });
  assertEquals(key, NEW_DEFAULT);
});

Deno.test("resolveSecretKey：兩者皆無 → undefined（呼叫端 fail loud）", () => {
  const key = resolveSecretKey({});
  assertEquals(key, undefined);
});

Deno.test("resolveSecretKey：SUPABASE_SECRET_KEYS 有值但沒有 default 這個 key、有 legacy → 退回 legacy", () => {
  const key = resolveSecretKey({
    SUPABASE_SECRET_KEYS: secretKeysJson({ previous: NEW_PREVIOUS }),
    SUPABASE_SERVICE_ROLE_KEY: LEGACY,
  });
  assertEquals(key, LEGACY);
});

Deno.test("resolveSecretKey：SUPABASE_SECRET_KEYS JSON 壞掉、有 legacy → 退回 legacy（fail closed 不代表整個解析都不能用既有 legacy 值）", () => {
  const key = resolveSecretKey({
    SUPABASE_SECRET_KEYS: "{not valid json",
    SUPABASE_SERVICE_ROLE_KEY: LEGACY,
  });
  assertEquals(key, LEGACY);
});

Deno.test("resolveSecretKey：SUPABASE_SECRET_KEYS JSON 壞掉、無 legacy → undefined", () => {
  const key = resolveSecretKey({ SUPABASE_SECRET_KEYS: "{not valid json" });
  assertEquals(key, undefined);
});

Deno.test("resolveSecretKey：SUPABASE_SECRET_KEYS 是陣列（不是物件）→ 視為不可用，退回 legacy", () => {
  const key = resolveSecretKey({
    SUPABASE_SECRET_KEYS: JSON.stringify(["a", "b"]),
    SUPABASE_SERVICE_ROLE_KEY: LEGACY,
  });
  assertEquals(key, LEGACY);
});

// ---------------------------------------------------------------------------
// isAuthorizedServiceCall
// ---------------------------------------------------------------------------

Deno.test("isAuthorizedServiceCall：apikey 等於 default → true", () => {
  const env = {
    SUPABASE_SECRET_KEYS: secretKeysJson({ default: NEW_DEFAULT }),
  };
  const ok = isAuthorizedServiceCall(headers({ apikey: NEW_DEFAULT }), env);
  assertEquals(ok, true);
});

Deno.test("isAuthorizedServiceCall：apikey 等於輪替中的 previous（不是 default）→ true（任一 SUPABASE_SECRET_KEYS 值皆可）", () => {
  const env = {
    SUPABASE_SECRET_KEYS: secretKeysJson({
      default: NEW_DEFAULT,
      previous: NEW_PREVIOUS,
    }),
  };
  const ok = isAuthorizedServiceCall(headers({ apikey: NEW_PREVIOUS }), env);
  assertEquals(ok, true);
});

Deno.test("isAuthorizedServiceCall：apikey 錯誤值 → false", () => {
  const env = {
    SUPABASE_SECRET_KEYS: secretKeysJson({ default: NEW_DEFAULT }),
  };
  const ok = isAuthorizedServiceCall(headers({ apikey: "wrong-key" }), env);
  assertEquals(ok, false);
});

Deno.test("isAuthorizedServiceCall：apikey 為正確 key 的前綴（不是完整值）→ false（釘住常數時間比對是精確相等，不是 startsWith——merge-review R1 F1／M4：只用『跟正解無關的字串』當負樣本殺不掉把比對誤改成 candidate.startsWith(apikey) 的退化）", () => {
  const env = {
    SUPABASE_SECRET_KEYS: secretKeysJson({ default: NEW_DEFAULT }),
  };
  const ok = isAuthorizedServiceCall(
    headers({ apikey: NEW_DEFAULT.slice(0, 8) }),
    env,
  );
  assertEquals(ok, false);
});

Deno.test("isAuthorizedServiceCall：apikey 缺失、無 legacy bearer → false", () => {
  const env = {
    SUPABASE_SECRET_KEYS: secretKeysJson({ default: NEW_DEFAULT }),
  };
  const ok = isAuthorizedServiceCall(headers(), env);
  assertEquals(ok, false);
});

Deno.test("isAuthorizedServiceCall：legacy bearer 對（過渡）→ true", () => {
  const env = { SUPABASE_SERVICE_ROLE_KEY: LEGACY };
  const ok = isAuthorizedServiceCall(
    headers({ Authorization: `Bearer ${LEGACY}` }),
    env,
  );
  assertEquals(ok, true);
});

Deno.test("isAuthorizedServiceCall：legacy bearer 錯 → false", () => {
  const env = { SUPABASE_SERVICE_ROLE_KEY: LEGACY };
  const ok = isAuthorizedServiceCall(
    headers({ Authorization: "Bearer wrong-token" }),
    env,
  );
  assertEquals(ok, false);
});

Deno.test("isAuthorizedServiceCall：legacy bearer 為正確 token 的前綴（不是完整值）→ false（同上，merge-review R1 F1／M3：殺掉把比對誤改成 expected.startsWith(bearer) 的退化）", () => {
  const env = { SUPABASE_SERVICE_ROLE_KEY: LEGACY };
  const ok = isAuthorizedServiceCall(
    headers({ Authorization: `Bearer ${LEGACY.slice(0, 6)}` }),
    env,
  );
  assertEquals(ok, false);
});

Deno.test("isAuthorizedServiceCall：SUPABASE_SECRET_KEYS 含空字串候選值（輪替期常見，例如 previous 剛清空）、未帶 apikey header → false（merge-review R1 F1／M1：v.length>0 過濾與 if(apikey) 短路兩道防線缺一都不能讓『完全不帶 apikey』被空字串候選比對放行）", () => {
  const env = {
    SUPABASE_SECRET_KEYS: secretKeysJson({
      default: "sb_secret_x",
      previous: "",
    }),
  };
  const ok = isAuthorizedServiceCall(headers(), env);
  assertEquals(ok, false);
});

Deno.test("isAuthorizedServiceCall：新式 key 放進 Authorization: Bearer（不是 apikey）→ false（新式 key 不接受這個位置）", () => {
  const env = {
    SUPABASE_SECRET_KEYS: secretKeysJson({ default: NEW_DEFAULT }),
  };
  const ok = isAuthorizedServiceCall(
    headers({ Authorization: `Bearer ${NEW_DEFAULT}` }),
    env,
  );
  assertEquals(ok, false);
});

Deno.test("isAuthorizedServiceCall：兩者皆設定，只帶合法 legacy bearer（不帶 apikey）→ true（過渡期兩條路徑並存）", () => {
  const env = {
    SUPABASE_SECRET_KEYS: secretKeysJson({ default: NEW_DEFAULT }),
    SUPABASE_SERVICE_ROLE_KEY: LEGACY,
  };
  const ok = isAuthorizedServiceCall(
    headers({ Authorization: `Bearer ${LEGACY}` }),
    env,
  );
  assertEquals(ok, true);
});

Deno.test("isAuthorizedServiceCall：兩者皆未設定 → false（不論帶什麼 header 都不放行）", () => {
  const ok = isAuthorizedServiceCall(
    headers({ apikey: "anything", Authorization: "Bearer anything" }),
    {},
  );
  assertEquals(ok, false);
});

Deno.test("isAuthorizedServiceCall：SUPABASE_SECRET_KEYS JSON 壞掉、帶 apikey、無 legacy → false（fail closed，不放行）", () => {
  const env = { SUPABASE_SECRET_KEYS: "{not valid json" };
  const ok = isAuthorizedServiceCall(headers({ apikey: NEW_DEFAULT }), env);
  assertEquals(ok, false);
});

Deno.test("isAuthorizedServiceCall：SUPABASE_SECRET_KEYS JSON 壞掉，但 legacy bearer 對 → true（壞掉的新式設定不影響既有 legacy 過渡路徑）", () => {
  const env = {
    SUPABASE_SECRET_KEYS: "{not valid json",
    SUPABASE_SERVICE_ROLE_KEY: LEGACY,
  };
  const ok = isAuthorizedServiceCall(
    headers({ Authorization: `Bearer ${LEGACY}` }),
    env,
  );
  assertEquals(ok, true);
});
