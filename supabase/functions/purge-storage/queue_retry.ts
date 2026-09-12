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
//
// LS-242（來源 LS-96 池項 cc85f81b，LS-235 merge-review R2 留下的唯一未收口項）：
// 上面這一組常數只約束「單一批次讀取」的最壞等待（1+2+4=7 秒）——但
// index.ts 的迴圈最多跑 MAX_BATCHES=20 批，每批都各自重新套用同一組上限，
// 最壞情況 20 批全部連續遇到暫時性錯誤，總等待可以逼近 20 × 7s ≈ 140 秒，
// 超過呼叫端 pg_net.http_post(... timeout_milliseconds := 60000)（見
// docs/API.md §6「pg_cron＋pg_net 呼叫範本」）。修法：新增整次 invocation
// 共用的「重試等待預算」（`RetryBudget`）——由 index.ts 在迴圈開始前建立
// 一個物件（`createRetryBudget()`），逐批傳入同一個 `readQueueWithRetry()`
// 呼叫；每次要退避之前先檢查剩餘預算夠不夠這一次的退避時長，不夠就不等待、
// 直接放棄這次讀取的剩餘重試（`budgetExhausted: true`），讓 index.ts 停止
// 處理後續批次。**這不是把單一批次的 QUEUE_READ_MAX_ATTEMPTS／
// QUEUE_READ_BACKOFF_MS 改小**（那樣會讓「只是剛好前面幾批比較不順」的正常
// 情況提早放棄重試）——是在「單一批次的重試上限」之外再疊一層「整次
// invocation 的總退避時間上限」，兩者各自獨立生效，先碰到哪個就先放棄。
// `budget` 參數刻意放在 `sleep` 之後、`maxAttempts`／`backoffMs` 之前
// （設計為選填，預設 `undefined`＝不設預算上限，行為與 LS-242 之前完全相同）
// ——這兩個既有參數目前只有測試會覆寫，`budget` 才是正式呼叫會用到的新參數，
// 放在測試用參數前面比追加在最後面更符合「常用參數在前」的可讀性。

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
  /** LS-242：這次讀取是因為整次 invocation 共用的重試預算已用盡而放棄重試
   * （不是因為到達單一批次自己的 QUEUE_READ_MAX_ATTEMPTS，也不是因為遇到
   * 非暫時性錯誤）。只有 `error` 非 null 時才可能是 true；`error` 為 null
   * （這次讀取成功）時恆為 false。 */
  budgetExhausted: boolean;
}

/** LS-242：整次 invocation 共用的重試等待預算——由呼叫端（index.ts）建立一個
 * 物件，逐批傳入同一個 `readQueueWithRetry()` 呼叫，靠物件參照在呼叫之間
 * 累計已消耗的退避時間。`remainingMs` 只會遞減，不會回補。 */
export interface RetryBudget {
  remainingMs: number;
}

/** 這次 invocation 允許的重試等待總量（毫秒）——跨所有批次累計共用，不是每批
 * 各自的上限（那是 QUEUE_READ_MAX_ATTEMPTS／QUEUE_READ_BACKOFF_MS，見上方
 * LS-242 檔頭說明）。20000ms（20 秒）留給批次本身的 I/O（SELECT／
 * storage.remove()／dequeue）與孤兒掃描約 40 秒餘裕，維持整次 invocation
 * 最壞情況仍在呼叫端 60 秒逾時之內（推算見票 handoff）。 */
export const QUEUE_READ_TOTAL_BUDGET_MS = 20_000;

/** 建立一個新的 `RetryBudget`——每次 invocation 呼叫一次（在 index.ts 的批次
 * 迴圈開始前），不要在迴圈內重複呼叫，否則預算會被重新灌滿、失去「整次
 * invocation 共用」的意義。 */
export function createRetryBudget(
  totalMs: number = QUEUE_READ_TOTAL_BUDGET_MS,
): RetryBudget {
  return { remainingMs: totalMs };
}

/** LS-242：讀取失敗時，index.ts 該回 500 還是回 200 帶 `partial: true` 的唯一
 * 判斷點——`budgetExhausted` 是這次失敗的唯一分流依據：預算用盡是「這次
 * invocation 自己設的節流上限被碰到」，不是真的服務端錯誤，不該回應成
 * 500（那會讓呼叫端／健康度巡檢誤判成一次真正的失敗，即使已處理的批次都是
 * 成功的、佇列狀態完全正常、下次 invocation 接著處理就好）；其他情況（永久性
 * 錯誤第一次就放棄、或單一批次自己的重試已經用盡但整次 invocation 的預算
 * 還夠）維持既有的 500，行為不變。抽成獨立函式而不是寫死在 index.ts 的
 * `Deno.serve()` 內：讓這條規則能被 deno test 直接單元測試，不需要另外搭建
 * index.ts 的 HTTP handler 測試治具（這個 repo 目前沒有，見 index.ts 檔頭
 * 「已知限制」）。 */
export function classifyQueueReadFailure(
  outcome: Pick<QueueReadOutcome<unknown>, "budgetExhausted">,
): { status: 200 | 500; partial: boolean } {
  if (outcome.budgetExhausted) {
    return { status: 200, partial: true };
  }
  return { status: 500, partial: false };
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
  budget?: RetryBudget,
  maxAttempts: number = QUEUE_READ_MAX_ATTEMPTS,
  backoffMs: number[] = QUEUE_READ_BACKOFF_MS,
): Promise<QueueReadOutcome<T>> {
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const { data, error } = await selectBatch();
    if (!error) {
      return { data, error: null, attempts: attempt, budgetExhausted: false };
    }

    const isFinalAttempt = attempt >= maxAttempts;
    if (isFinalAttempt || !isTransientQueueReadError(error.message)) {
      return { data: null, error, attempts: attempt, budgetExhausted: false };
    }

    const wait = backoffMs[attempt - 1] ?? backoffMs[backoffMs.length - 1];
    // LS-242：budget 未提供（呼叫端刻意不設整次 invocation 的預算上限，例如
    // 測試）時完全不檢查，行為與 LS-242 之前一致。提供時，剩餘預算不夠這一次
    // 退避就不等待、直接放棄——不消耗任何預算（沒有真的等待），讓呼叫端知道
    // 「不是這次讀取自己重試到底仍失敗」，是整次 invocation 的時間預算用盡。
    if (budget !== undefined) {
      if (budget.remainingMs < wait) {
        return { data: null, error, attempts: attempt, budgetExhausted: true };
      }
      budget.remainingMs -= wait;
    }

    await sleep(wait);
  }
  // 迴圈一定會在 attempt === maxAttempts 時 return（isFinalAttempt 恆真）——
  // 這裡純粹滿足 TypeScript 對「所有路徑都要有回傳值」的要求，正常呼叫方式
  // （maxAttempts >= 1）跑不到這裡。
  throw new Error("readQueueWithRetry：不可能執行到這裡（maxAttempts < 1？）");
}
