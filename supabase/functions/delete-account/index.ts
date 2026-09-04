// LS-151 — Edge Function delete-account：以 service_role 完成 LS-143
// delete_my_account() RPC 標記之後、真正的 auth.users 刪除。
//
// 這是 repo 第一支 Edge Function 部署單元（與 LS-153 的 supabase/functions/
// purge-storage 同批落地）。核心邏輯（含依賴注入介面）在 handler.ts——這個檔案
// 只負責「用 Deno 環境變數與 supabase-js 建構真正的依賴」＋掛上 Deno.serve()，
// 保持 handler.ts 可以被 Deno 單元測試直接 import 而不需要啟動 HTTP listener
// （見 handler.ts 檔頭與 index.test.ts）。
//
// 契約細節（呼叫順序、鑑權、錯誤碼、Apple／Google 撤銷、部署指令）見
// docs/API.md §10「Edge Functions」。

import { createClient } from "npm:@supabase/supabase-js@2.114";
import { type Deps, handleRequest, type Identity } from "./handler.ts";

// SUPABASE_URL／SUPABASE_ANON_KEY／SUPABASE_SERVICE_ROLE_KEY 由 Supabase 平台在
// 每個 Edge Function 執行環境自動注入（部署後）；本機 `supabase functions serve`
// 也會從 .env 或平台預設值提供同名變數。APPLE_CLIENT_ID／APPLE_CLIENT_SECRET
// 需要另外用 `supabase secrets set` 設定，缺 env 時 revokeAppleToken() 會跳過
// （不擋刪除，見票文）。
//
// fail loud：這三個是平台自動注入的變數，缺任何一個代表部署設定本身有問題，
// 不是「當作沒有請求可處理」悄悄放行（同 purge-storage 既有先例）。放在模組層級
// （不是等第一個請求進來才檢查）：isolate 冷啟動就會直接失敗，比藏在
// buildProdDeps() 裡、每個請求都重新算一次還快看到問題。
const supabaseUrl = Deno.env.get("SUPABASE_URL");
const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

if (!supabaseUrl || !anonKey || !serviceRoleKey) {
  throw new Error(
    "SUPABASE_URL／SUPABASE_ANON_KEY／SUPABASE_SERVICE_ROLE_KEY 未設定",
  );
}

// minor-3（merge-review R1）：client 提到模組層級，只建立一次（不是每個請求都
// 在 buildProdDeps() 裡重建兩個 client）；帶 persistSession/autoRefreshToken:
// false——這兩個 client 是伺服器端一次性使用的 service/anon client，不是瀏覽器
// session client，不需要（也不該）啟動自動刷新 token 的計時器。PLAUSIBLE：
// 未實測 supabase-js v2.114 在 Deno 無 window 環境下是否真的會啟動這個計時器，
// 但關閉這兩個選項本身無害，是 server 端建議設定，不需要等實測結果才做。
const clientOptions = {
  auth: { persistSession: false, autoRefreshToken: false },
};
const anonClient = createClient(supabaseUrl, anonKey, clientOptions);
const adminClient = createClient(supabaseUrl, serviceRoleKey, clientOptions);

function buildProdDeps(): Deps {
  return {
    async getCallerUser(authHeader) {
      const bearer = authHeader?.startsWith("Bearer ")
        ? authHeader.slice("Bearer ".length)
        : null;
      if (!bearer) return null;
      // 明確傳入 token（不是靠 client 內部的 session/local storage）——這支端點
      // 每個請求都是全新建立的 client，沒有既有 session 可用，見 docs/API.md
      // §10「鑑權」段落。
      const { data, error } = await anonClient.auth.getUser(bearer);
      if (error || !data.user) return null;
      return { id: data.user.id };
    },

    async getDeletionRequestedAt(uid) {
      const { data, error } = await adminClient
        .from("profiles")
        .select("deletion_requested_at")
        .eq("id", uid)
        .maybeSingle();
      if (error || !data) return { found: false, requested: false };
      return { found: true, requested: data.deletion_requested_at !== null };
    },

    async getIdentities(uid) {
      const { data, error } = await adminClient.auth.admin.getUserById(uid);
      if (error || !data.user) return [];
      return (data.user.identities ?? []) as Identity[];
    },

    // R2（merge-review R1 B1／M1，第一道防線）：service_role 呼叫
    // public.finalize_account_deletion(p_user uuid)——只授權 service_role 執行
    // 的 SECURITY DEFINER 函式，見 20260903115014_delete_account_edge_support.sql。
    async finalizeAccountDeletion(uid) {
      const { error } = await adminClient.rpc("finalize_account_deletion", {
        p_user: uid,
      });
      if (error) return { ok: false, error: error.message };
      return { ok: true };
    },

    async deleteAuthUser(uid) {
      const { error } = await adminClient.auth.admin.deleteUser(uid);
      if (!error) return { ok: true, notFound: false };
      // GoTrue 對「使用者不存在」的 admin deleteUser 回應是 404——視為冪等成功
      // （重複呼叫的情境，見 docs/API.md §10「冪等語意」），不是失敗。
      const notFound = error.status === 404 ||
        /not.?found/i.test(error.message ?? "");
      return {
        ok: false,
        notFound,
        error: notFound ? undefined : error.message,
      };
    },

    fetchImpl: fetch,
    appleClientId: Deno.env.get("APPLE_CLIENT_ID"),
    appleClientSecret: Deno.env.get("APPLE_CLIENT_SECRET"),
  };
}

Deno.serve((req) => handleRequest(req, buildProdDeps()));
