// LS-235 —— purge-storage 讀取 public.purge_storage_queue 這一步的重試／退避
// 包裝（來源 LS-96 池項 fa8c91fc：09-11 一次 Gateway Timeout 訊息即讓整輪
// invocation 直接回 500，即使佇列本身完全正常、下一次呼叫多半就會成功）。
//
// 範圍：只包這一個 SELECT 步驟——迴圈裡其他動作（storage.remove()／
// markFailed()／dequeue／孤兒掃描）各自已有自己的失敗處理（見 index.ts 檔頭
// R2／R3／R4 說明），不在本票範圍內（票文「不做」）。
//
// race 安全性：這裡重試的是一次唯讀 SELECT，沒有任何寫入副作用——重試造成的
// 頂多是「多發一次一模一樣的查詢、丟棄前面失敗那次的（無）結果」，被實際處理
// 的仍是讀取成功那一次拿到的同一批列；真正的刪除／dequeue 動作在讀取成功
// *之後* 才執行一次，跟這裡重試了幾次無關，不會讓同一批佇列項被處理兩次。
//
// 只重試「暫時性錯誤」（timeout／5xx／網路錯誤／訊息含 Gateway Timeout、
// ETIMEDOUT、fetch failed 等字樣）——採**允許清單**而非黑名單：4xx／SQL 語法類
// 錯誤（例如欄位不存在、權限不足）不會出現在允許清單裡，第一次就回傳、不重試，
// 避免對「重試也沒用」的永久性錯誤白白多等 7 秒（1+2+4）才失敗。
//
// R2（merge-review R1 comment da96a7d0，m1）：R1 版本 QUEUE_READ_MAX_ATTEMPTS=3
// 其實是「總嘗試次數」（含首次），只會重試 2 次（attempt 1→2、2→3 各退避一次，
// attempt 3 失敗就直接放棄），退避表第三格 4000 永遠取不到——跟票文「最多重試
// 3 次、退避 1s→2s→4s」的字面（3 次「重試」＝首次之外再 3 次＝總嘗試 4 次）
// 對不上。改成 QUEUE_READ_MAX_ATTEMPTS=4（1 次首次嘗試＋最多 3 次重試），
// QUEUE_READ_BACKOFF_MS 改由 (QUEUE_READ_MAX_ATTEMPTS - 1) 動態產生退避表長度，
// 不再是寫死的字面陣列——避免未來只改其中一個常數、另一個沒跟著改，又出現同一種
// 「退避表有值但永遠用不到」的死值。

/** 讀取一次 purge_storage_queue 的最小回傳形狀——刻意不依賴 index.ts 的
 * QueueRow／PostgrestError 型別，維持這個模組跟真正的 supabase-js 完全解耦
 * （同 orphan_scan.ts 的既有慣例），真正的實作（wiring 到 supabase-js）由
 * index.ts 提供。 */
export interface QueueSelectResult<T> {
  data: T | null;
  error: { message: string } | null;
}

export interface QueueReadOutcome<T> {
  data: T | null;
  error: { message: string } | null;
  /** 這一次讀取總共嘗試的次數（成功或最終放棄都算，最小值 1）。 */
  attempts: number;
}

const TRANSIENT_ERROR_PATTERNS: RegExp[] = [
  /gateway timeout/i,
  /\btimed?[\s-]?out\b/i,
  /etimedout/i,
  /econnreset/i,
  /fetch failed/i,
  /network error/i,
  /bad gateway/i,
  /service unavailable/i,
  /\b50[0234]\b/, // 500／502／503／504
  // R2（merge-review R1 comment da96a7d0，i1，PLAUSIBLE）：以上多是 Node／undici
  // 的 fetch 錯誤措辭；Deno（Edge Function 執行環境）的原生 fetch 失敗訊息形狀
  // 不同，常見「error sending request for url (…): client error (Connect) …」
  // 或「connection closed before message completed」，兩者都不含上面任何關鍵字
  // ——會被誤判成永久性錯誤、第一次就放棄，正好是這票想接住的那類故障。
  /error sending request/i,
  /connection closed/i,
];

/** 判斷這則錯誤訊息是否屬於暫時性錯誤（值得重試）。允許清單設計：不在清單內
 * 一律視為永久性失敗（4xx／SQL 語法錯誤等），第一次就放棄，不做無意義的重試。 */
export function isTransientQueueReadError(message: string): boolean {
  return TRANSIENT_ERROR_PATTERNS.some((pattern) => pattern.test(message));
}

// 1 次首次嘗試＋最多 3 次重試＝總嘗試上限 4 次（R2 修正，見上方檔頭 m1 說明）。
export const QUEUE_READ_MAX_ATTEMPTS = 4;
// 由 QUEUE_READ_MAX_ATTEMPTS 動態產生（長度＝MAX_ATTEMPTS-1，即重試次數）——
// 1000ms 為基準、每次退避時間翻倍（1000, 2000, 4000, …），不是寫死的字面陣列，
// 避免以後只改 QUEUE_READ_MAX_ATTEMPTS 卻忘記同步退避表長度，又出現「表裡有
// 值但迴圈永遠取不到」的死值（R2 merge-review R1 m1）。
export const QUEUE_READ_BACKOFF_MS: number[] = Array.from(
  { length: QUEUE_READ_MAX_ATTEMPTS - 1 },
  (_, i) => 1000 * 2 ** i,
);

/**
 * 對讀取 purge_storage_queue 這一步做重試／退避。`sleep` 由呼叫端注入——正式
 * 呼叫用真正的 `setTimeout` 封裝，測試用立即 resolve 的假 sleep，不會真的等待
 * （見 queue_retry.test.ts）。
 */
export async function readQueueWithRetry<T>(
  selectBatch: () => Promise<QueueSelectResult<T>>,
  sleep: (ms: number) => Promise<void>,
  maxAttempts: number = QUEUE_READ_MAX_ATTEMPTS,
  backoffMs: number[] = QUEUE_READ_BACKOFF_MS,
): Promise<QueueReadOutcome<T>> {
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const { data, error } = await selectBatch();
    if (!error) {
      return { data, error: null, attempts: attempt };
    }

    const isFinalAttempt = attempt >= maxAttempts;
    if (isFinalAttempt || !isTransientQueueReadError(error.message)) {
      return { data: null, error, attempts: attempt };
    }

    await sleep(backoffMs[attempt - 1] ?? backoffMs[backoffMs.length - 1]);
  }
  // 迴圈一定會在 attempt === maxAttempts 時 return（isFinalAttempt 恆真）——
  // 這裡純粹滿足 TypeScript 對「所有路徑都要有回傳值」的要求，正常呼叫方式
  // （maxAttempts >= 1）跑不到這裡。
  throw new Error("readQueueWithRetry：不可能執行到這裡（maxAttempts < 1？）");
}
