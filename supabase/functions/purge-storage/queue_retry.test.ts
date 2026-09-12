// LS-235 — queue_retry.ts 的 Deno 單元測試。全部用注入的 fake selectBatch／
// sleep，不連線到任何真正的 Supabase 專案，也不真的等待退避時間（sleep 注入
// 立即 resolve 的假實作，記錄呼叫參數供斷言）。
//
// 跑法：`deno test --allow-all supabase/functions/purge-storage/`（不需要
// --allow-net，這裡每一個依賴都是 fake，不會真的發出網路請求）。
//
// 對應票文（LS-235）驗收：
//   - 第 1 次 timeout、第 2 次成功 → 回傳 error:null、attempts=2（index.ts 收到
//     error:null 就會照既有邏輯回 200，見 index.ts 的整合）。
//   - 連續 3 次（timeout 類）失敗 → 回傳 error 非 null、attempts=3（index.ts
//     收到 error 非 null 就會照既有邏輯回 500）。
//   - 4xx／SQL 語法類錯誤（不在允許清單內）第一次就放棄，不重試，attempts=1。
//   - mutation 對照組：拿掉重試（maxAttempts=1）之後，「第 1 次 timeout、第 2
//     次成功」這組會轉紅——見檔尾說明與 handoff 附的實際跑法／斷言原文。

import { assertEquals } from "jsr:@std/assert@1";
import {
  isTransientQueueReadError,
  QUEUE_READ_BACKOFF_MS,
  type QueueSelectResult,
  readQueueWithRetry,
} from "./queue_retry.ts";

function fakeSleep(log: number[]): (ms: number) => Promise<void> {
  return (ms: number) => {
    log.push(ms);
    return Promise.resolve();
  };
}

function unreachableSleep(): (ms: number) => Promise<void> {
  return () => {
    throw new Error("不該被呼叫：這個情境不該重試（沒有退避可等）");
  };
}

Deno.test("readQueueWithRetry：第 1 次 Gateway Timeout、第 2 次成功 → error:null、attempts=2，且只退避一次 1000ms", async () => {
  let calls = 0;
  const selectBatch = (): Promise<QueueSelectResult<string[]>> => {
    calls++;
    if (calls === 1) {
      return Promise.resolve({
        data: null,
        error: { message: "讀取失敗：Gateway Timeout" },
      });
    }
    return Promise.resolve({ data: ["row-1"], error: null });
  };
  const sleepLog: number[] = [];

  const result = await readQueueWithRetry(selectBatch, fakeSleep(sleepLog));

  assertEquals(result, { data: ["row-1"], error: null, attempts: 2 });
  assertEquals(calls, 2, "應該只呼叫兩次 selectBatch（第 2 次就成功，不會有第 3 次）");
  assertEquals(sleepLog, [1000], "只退避一次，時長是 QUEUE_READ_BACKOFF_MS[0]（1000ms）");
});

Deno.test("readQueueWithRetry：連續 3 次都是 ETIMEDOUT → error 非 null、attempts=3，退避序列 1000ms→2000ms", async () => {
  let calls = 0;
  const selectBatch = (): Promise<QueueSelectResult<string[]>> => {
    calls++;
    return Promise.resolve({
      data: null,
      error: { message: `讀取失敗：connect ETIMEDOUT（第 ${calls} 次）` },
    });
  };
  const sleepLog: number[] = [];

  const result = await readQueueWithRetry(selectBatch, fakeSleep(sleepLog));

  assertEquals(result.error, { message: "讀取失敗：connect ETIMEDOUT（第 3 次）" });
  assertEquals(result.data, null);
  assertEquals(result.attempts, 3);
  assertEquals(calls, 3, "達到 MAX_ATTEMPTS(3) 後不再繼續呼叫 selectBatch");
  assertEquals(
    sleepLog,
    [QUEUE_READ_BACKOFF_MS[0], QUEUE_READ_BACKOFF_MS[1]],
    "只在第 1→2、2→3 次之間退避兩次（最後一次失敗後不再退避），序列是 1000ms→2000ms",
  );
});

Deno.test("readQueueWithRetry：4xx 類錯誤（權限不足）第一次就放棄，不重試——attempts=1，且完全不呼叫 sleep", async () => {
  let calls = 0;
  const selectBatch = (): Promise<QueueSelectResult<string[]>> => {
    calls++;
    return Promise.resolve({
      data: null,
      error: { message: "permission denied for table purge_storage_queue" },
    });
  };

  const result = await readQueueWithRetry(selectBatch, unreachableSleep());

  assertEquals(result, {
    data: null,
    error: { message: "permission denied for table purge_storage_queue" },
    attempts: 1,
  });
  assertEquals(calls, 1, "永久性錯誤（不在允許清單內）不該重試");
});

Deno.test("readQueueWithRetry：SQL 語法類錯誤（欄位不存在）第一次就放棄，不重試", async () => {
  const selectBatch = (): Promise<QueueSelectResult<string[]>> =>
    Promise.resolve({
      data: null,
      error: { message: 'column "bogus_column" does not exist' },
    });

  const result = await readQueueWithRetry(selectBatch, unreachableSleep());

  assertEquals(result.attempts, 1);
  assertEquals(result.error?.message, 'column "bogus_column" does not exist');
});

Deno.test("readQueueWithRetry：成功且不需要重試 → attempts=1，完全不呼叫 sleep", async () => {
  const selectBatch = (): Promise<QueueSelectResult<string[]>> =>
    Promise.resolve({ data: [], error: null });

  const result = await readQueueWithRetry(selectBatch, unreachableSleep());

  assertEquals(result, { data: [], error: null, attempts: 1 });
});

// ---------------------------------------------------------------------------
// isTransientQueueReadError —— 允許清單的正負樣本
// ---------------------------------------------------------------------------

Deno.test("isTransientQueueReadError：暫時性錯誤關鍵字（timeout／5xx／網路錯誤）判定為 true", () => {
  const transientSamples = [
    "讀取 purge_storage_queue 失敗：Gateway Timeout",
    "connect ETIMEDOUT 10.0.0.1:443",
    "read ECONNRESET",
    "TypeError: fetch failed",
    "network error occurred",
    "upstream connect error: 502 Bad Gateway",
    "503 Service Unavailable",
    "statement timeout",
  ];
  for (const message of transientSamples) {
    assertEquals(
      isTransientQueueReadError(message),
      true,
      `「${message}」應判定為暫時性錯誤`,
    );
  }
});

Deno.test("isTransientQueueReadError：永久性錯誤（4xx／SQL 語法／權限）判定為 false（允許清單設計，不在清單內一律不重試）", () => {
  const permanentSamples = [
    "permission denied for table purge_storage_queue",
    'column "bogus_column" does not exist',
    "JWT expired",
    "invalid input syntax for type uuid",
    "relation \"purge_storage_queue\" does not exist",
    "PGRST116: The result contains 0 rows",
  ];
  for (const message of permanentSamples) {
    assertEquals(
      isTransientQueueReadError(message),
      false,
      `「${message}」不該被判定為暫時性錯誤（允許清單以外一律不重試）`,
    );
  }
});

// ---------------------------------------------------------------------------
// Mutation 對照組（LS-209 handoff 規約：改了什麼一行 → 哪條測試紅 → 斷言訊息
// 原文，見票 handoff）。這個測試檔本身不執行 mutation——mutation 驗證是「暫時
// 把 readQueueWithRetry 的重試迴圈拿掉（maxAttempts 固定傳 1），跑一次上面
// 「第 1 次 Gateway Timeout、第 2 次成功」那組」，證明拿掉重試後這組真的會轉
// 紅，不是恆真斷言。實際跑法與轉紅後的斷言訊息原文記在票 handoff（PR 不含這段
// mutation 本身的程式碼變更，只有驗證過程留痕）。
