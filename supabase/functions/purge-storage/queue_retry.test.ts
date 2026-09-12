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
//   - 連續 4 次（timeout 類）失敗 → 回傳 error 非 null、attempts=4（1 次首次
//     嘗試＋3 次重試，見 queue_retry.ts 檔頭 R2／m1 說明；index.ts 收到 error
//     非 null 就會照既有邏輯回 500）。
//   - 4xx／SQL 語法類錯誤（不在允許清單內）第一次就放棄，不重試，attempts=1。
//   - mutation 對照組：拿掉重試（maxAttempts=1）之後，「第 1 次 timeout、第 2
//     次成功」這組會轉紅——見檔尾說明與 handoff 附的實際跑法／斷言原文。
//
// LS-242（來源 LS-96 池項 cc85f81b）新增三組（見檔尾「整次 invocation 共用
// 預算」區塊）：
//   - 連續暫時性錯誤下，跨多個 readQueueWithRetry() 呼叫（模擬 index.ts 迴圈
//     的多個批次）共用同一個 RetryBudget 物件時，總退避等待不會超過建立時
//     設定的預算上限——即使某一批單獨來看還沒用完自己的 QUEUE_READ_MAX_ATTEMPTS，
//     也會因為預算不夠而提早放棄。
//   - 預算用盡時 classifyQueueReadFailure() 回傳 200／partial:true（不是既有
//     的 500），而非預算耗盡（永久性錯誤或其他原因）維持 500。
//   - 帶了 budget 參數但完全不需要重試的正常路徑，attempts／budget 消耗量都
//     不受影響（budget 沒有被使用到就不該被消耗）。

import { assertEquals } from "jsr:@std/assert@1";
import {
  classifyQueueReadFailure,
  createRetryBudget,
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

  assertEquals(result, {
    data: ["row-1"],
    error: null,
    attempts: 2,
    budgetExhausted: false,
  });
  assertEquals(
    calls,
    2,
    "應該只呼叫兩次 selectBatch（第 2 次就成功，不會有第 3 次）",
  );
  assertEquals(
    sleepLog,
    [1000],
    "只退避一次，時長是 QUEUE_READ_BACKOFF_MS[0]（1000ms）",
  );
});

Deno.test("readQueueWithRetry：連續 4 次都是 ETIMEDOUT → error 非 null、attempts=4，退避序列 1000ms→2000ms→4000ms 全部用到（R2 修正 m1：三格退避表不再有取不到的死值）", async () => {
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

  assertEquals(result.error, {
    message: "讀取失敗：connect ETIMEDOUT（第 4 次）",
  });
  assertEquals(result.data, null);
  assertEquals(result.attempts, 4);
  assertEquals(
    result.budgetExhausted,
    false,
    "沒有傳入 budget（未定義）——放棄重試是因為用完自己的 QUEUE_READ_MAX_ATTEMPTS，不是預算問題（LS-242）",
  );
  assertEquals(calls, 4, "達到 MAX_ATTEMPTS(4) 後不再繼續呼叫 selectBatch");
  assertEquals(
    sleepLog,
    [
      QUEUE_READ_BACKOFF_MS[0],
      QUEUE_READ_BACKOFF_MS[1],
      QUEUE_READ_BACKOFF_MS[2],
    ],
    "在第 1→2、2→3、3→4 次之間各退避一次（最後一次失敗後不再退避），序列是 1000ms→2000ms→4000ms，三格退避表全部用到",
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
    budgetExhausted: false,
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

  assertEquals(result, {
    data: [],
    error: null,
    attempts: 1,
    budgetExhausted: false,
  });
});

// ---------------------------------------------------------------------------
// isTransientQueueReadError —— 允許清單的正負樣本
// ---------------------------------------------------------------------------

Deno.test("isTransientQueueReadError：暫時性錯誤關鍵字（timeout／5xx／網路錯誤／Deno 原生 fetch 錯誤措辭）判定為 true", () => {
  const transientSamples = [
    "讀取 purge_storage_queue 失敗：Gateway Timeout",
    "connect ETIMEDOUT 10.0.0.1:443",
    "read ECONNRESET",
    "TypeError: fetch failed",
    "network error occurred",
    "upstream connect error: 502 Bad Gateway",
    "503 Service Unavailable",
    "statement timeout",
    // R2（merge-review R1 comment da96a7d0，i1）：Deno 原生 fetch 失敗的實際措辭，
    // 不是 Node/undici 的「fetch failed」／「network error」。
    "error sending request for url (https://xxx.supabase.co/rest/v1/purge_storage_queue): client error (Connect)",
    "connection closed before message completed",
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
    'relation "purge_storage_queue" does not exist',
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
// LS-242 —— 整次 invocation 共用的重試等待預算（RetryBudget）
// ---------------------------------------------------------------------------

Deno.test("readQueueWithRetry：兩個模擬 index.ts 不同批次的呼叫共用同一個 RetryBudget → 第 2 批的重試會被第 1 批已消耗的預算限縮，累計退避不超過建立時的預算上限（LS-242：修前每批各自獨立套用 7 秒上限，20 批相乘可逼近 140 秒）", async () => {
  const budget = createRetryBudget(3000);

  // 第 1 批（模擬 index.ts 迴圈的第 1 次 readQueueWithRetry() 呼叫）：第 1 次
  // 暫時性失敗、第 2 次成功——消耗 1 次退避（1000ms）。
  let callsA = 0;
  const selectBatchA = (): Promise<QueueSelectResult<string[]>> => {
    callsA++;
    if (callsA === 1) {
      return Promise.resolve({
        data: null,
        error: { message: "Gateway Timeout" },
      });
    }
    return Promise.resolve({ data: ["batch-a-row"], error: null });
  };
  const sleepLogA: number[] = [];
  const resultA = await readQueueWithRetry(
    selectBatchA,
    fakeSleep(sleepLogA),
    budget,
  );

  assertEquals(resultA, {
    data: ["batch-a-row"],
    error: null,
    attempts: 2,
    budgetExhausted: false,
  });
  assertEquals(sleepLogA, [1000]);
  assertEquals(
    budget.remainingMs,
    2000,
    "第 1 批消耗 1000ms，共用預算剩 3000-1000=2000ms",
  );

  // 第 2 批：用同一個 budget 物件，持續遇到暫時性錯誤（永遠不成功）。若這一批
  // 有自己獨立的 7 秒上限（LS-242 之前的行為），會照樣退避 1000→2000→4000
  // 共 3 次；但共用預算只剩 2000ms——退避完第 1 次（1000ms，剩 1000ms）之後，
  // 第 2 次原本要等 2000ms，剩下的 1000ms 不夠，直接放棄，不再等待。
  let callsB = 0;
  const selectBatchB = (): Promise<QueueSelectResult<string[]>> => {
    callsB++;
    return Promise.resolve({
      data: null,
      error: { message: `Gateway Timeout（第 ${callsB} 次）` },
    });
  };
  const sleepLogB: number[] = [];
  const resultB = await readQueueWithRetry(
    selectBatchB,
    fakeSleep(sleepLogB),
    budget,
  );

  assertEquals(resultB.data, null);
  assertEquals(resultB.error, { message: "Gateway Timeout（第 2 次）" });
  assertEquals(
    resultB.attempts,
    2,
    "只嘗試 2 次就放棄——第 2 次失敗後本該退避 2000ms，但共用預算只剩 1000ms",
  );
  assertEquals(
    resultB.budgetExhausted,
    true,
    "第 2 批是因為共用預算用盡而放棄，不是自己的 QUEUE_READ_MAX_ATTEMPTS 用盡（那要到 attempts=4）",
  );
  assertEquals(
    sleepLogB,
    [1000],
    "只退避一次（用掉最後 1000ms 預算），第 2 次退避前預算不夠、不會真的呼叫 sleep",
  );
  assertEquals(
    budget.remainingMs,
    1000,
    "累計退避 1000(A)+1000(B)=2000ms，未超過建立時的 3000ms 預算上限；剩餘 1000ms 因為不夠付第 2 批第 2 次退避（2000ms）而保留未消耗",
  );

  const totalSlept = sleepLogA.reduce((a, b) => a + b, 0) +
    sleepLogB.reduce((a, b) => a + b, 0);
  assertEquals(
    totalSlept <= 3000,
    true,
    `兩批合計實際退避 ${totalSlept}ms 不應超過共用預算 3000ms（若無 LS-242 修法，第 2 批單獨可退避到 1000+2000+4000=7000ms，遠超此上限）`,
  );
});

Deno.test("classifyQueueReadFailure：budgetExhausted=true → status 200、partial=true（不是既有的 500，讓 index.ts 停止處理後續批次但不當成硬失敗，見 LS-242）", () => {
  assertEquals(
    classifyQueueReadFailure({ budgetExhausted: true }),
    { status: 200, partial: true },
  );
});

Deno.test("classifyQueueReadFailure：budgetExhausted=false（永久性錯誤，或單一批次自己的 QUEUE_READ_MAX_ATTEMPTS 用盡但預算還夠，與預算無關）→ status 500、partial=false（既有行為不變）", () => {
  assertEquals(
    classifyQueueReadFailure({ budgetExhausted: false }),
    { status: 500, partial: false },
  );
});

Deno.test("readQueueWithRetry：帶 budget 但完全不需要重試（一次就成功）→ attempts=1、budgetExhausted=false，且完全不消耗 budget（LS-242：新增的預算參數不影響既有『不需要重試』的正常路徑）", async () => {
  const budget = createRetryBudget(500); // 刻意給一個很小的預算，證明「用不到」時完全不受影響
  const selectBatch = (): Promise<QueueSelectResult<string[]>> =>
    Promise.resolve({ data: ["row-1"], error: null });

  const result = await readQueueWithRetry(
    selectBatch,
    unreachableSleep(),
    budget,
  );

  assertEquals(result, {
    data: ["row-1"],
    error: null,
    attempts: 1,
    budgetExhausted: false,
  });
  assertEquals(budget.remainingMs, 500, "沒有重試就沒有消耗任何預算");
});

Deno.test("readQueueWithRetry：帶 budget 但遇到永久性錯誤（不在允許清單內）→ 第一次就放棄，attempts=1、budgetExhausted=false，budget 不受影響（永久性錯誤與預算無關，index.ts 仍應回 500，見 classifyQueueReadFailure）", async () => {
  const budget = createRetryBudget(500);
  const selectBatch = (): Promise<QueueSelectResult<string[]>> =>
    Promise.resolve({
      data: null,
      error: { message: "permission denied for table purge_storage_queue" },
    });

  const result = await readQueueWithRetry(
    selectBatch,
    unreachableSleep(),
    budget,
  );

  assertEquals(result, {
    data: null,
    error: { message: "permission denied for table purge_storage_queue" },
    attempts: 1,
    budgetExhausted: false,
  });
  assertEquals(budget.remainingMs, 500);
});

// ---------------------------------------------------------------------------
// Mutation 對照組（LS-209 handoff 規約：改了什麼一行 → 哪條測試紅 → 斷言訊息
// 原文，見票 handoff）。這個測試檔本身不執行 mutation——mutation 驗證是「暫時
// 把 readQueueWithRetry 的重試迴圈拿掉（maxAttempts 固定傳 1），跑一次上面
// 「第 1 次 Gateway Timeout、第 2 次成功」那組」，證明拿掉重試後這組真的會轉
// 紅，不是恆真斷言。實際跑法與轉紅後的斷言訊息原文記在票 handoff（PR 不含這段
// mutation 本身的程式碼變更，只有驗證過程留痕）。
//
// LS-242 mutation 對照組：暫時把 `if (budget.remainingMs < wait)` 這個判斷式
// 拿掉（budget 完全不生效，行為退回 LS-242 之前——每批各自獨立套用
// QUEUE_READ_MAX_ATTEMPTS／QUEUE_READ_BACKOFF_MS，不受共用預算限制），跑一次
// 上面「兩個模擬 index.ts 不同批次的呼叫共用同一個 RetryBudget」那組，證明
// 拿掉判斷式後第 2 批會退回自己完整跑滿 3 次重試（attempts 變成 4、
// budgetExhausted 恆為 false、sleepLogB 變成 [1000, 2000, 4000]），不是恆真
// 斷言。實際跑法與轉紅後的斷言訊息原文記在票 handoff。
