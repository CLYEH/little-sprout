// LS-222 — orphan_scan.ts 的 Deno 單元測試。全部用注入的 fake OrphanScanDeps，
// 不連線到任何真正的 Supabase 專案（同 delete-account/handler.test.ts、
// push-dispatch/handler.test.ts 既有慣例）。
//
// 跑法：`deno test supabase/functions/purge-storage/`（不需要 --allow-net，這裡
// 每一個依賴都是 fake，不會真的發出網路請求）。
//
// 重點覆蓋（收口 LS-213 R2 merge-review comment 0e4c0eed 的 N2／N3）：
//   - N3：形狀不合規的落差樣本（票文點名的 `_thumb.png`）計入 dropped，不會被
//     送進 enqueueOrphans，也不會靜默消失。
//   - N2：游標在每個家庭前綴掃完後就寫回一次（不是整趟掃描結束才寫一次）；
//     候選預算用完時仍然寫回已完整處理的那個家庭，下次從那裡續掃。
//
// LS-223（收口 LS-222 merge-review comment f64a788e 的 F1／F2）：
//   - F2：候選預算（considered）不被形狀不合規的路徑吃掉——classify 之後才扣掉
//     invalidPaths.length。
//   - F1：不合規路徑改為計數（invalidCount）＋前 5 筆樣本（invalidSample），
//     不再無上限把整組路徑 join 進 warning 字串。

import { assertEquals } from "jsr:@std/assert@1";
import {
  type OrphanScanDeps,
  scanFamilyOrphans,
  scanOrphanStorageObjects,
  type StorageEntry,
} from "./orphan_scan.ts";

const CUTOFF_MS = Date.parse("2026-09-05T00:00:00Z");
const PAST_GRACE = "2026-09-01T00:00:00Z"; // 早於 CUTOFF_MS，算過寬限期的候選。
const WITHIN_GRACE = "2026-09-05T12:00:00Z"; // 晚於 CUTOFF_MS，還在寬限期內。

function unreachable(label: string): () => Promise<never> {
  return () => {
    throw new Error(`不該被呼叫：${label}`);
  };
}

// ---------------------------------------------------------------------------
// scanFamilyOrphans
// ---------------------------------------------------------------------------

Deno.test("scanFamilyOrphans：形狀不合規的落差樣本（_thumb.png）計入 dropped，不會混進 enqueueOrphans 的路徑清單", async () => {
  const familyId = "fam-1";
  const orphanPath =
    `${familyId}/2026/07/aaaaaaaa-0000-4000-8000-000000000001.jpg`;
  // LS-213 R2 merge-review N3 的具體案例：SQL private.is_media_object_path() 只
  // 認縮圖 .jpg，這個 .png 縮圖形狀完全不合規。
  const badThumbPath =
    `${familyId}/2026/07/aaaaaaaa-0000-4000-8000-000000000002_thumb.png`;

  const enqueueCalls: { familyId: string; paths: string[] }[] = [];
  const deps: OrphanScanDeps = {
    listPaged: (path) => {
      if (path === familyId) {
        return Promise.resolve([{ id: null, name: "2026" }]);
      }
      if (path === `${familyId}/2026`) {
        return Promise.resolve([{ id: null, name: "07" }]);
      }
      if (path === `${familyId}/2026/07`) {
        return Promise.resolve(
          [
            {
              id: "f1",
              name: "aaaaaaaa-0000-4000-8000-000000000001.jpg",
              created_at: PAST_GRACE,
            },
            {
              id: "f2",
              name: "aaaaaaaa-0000-4000-8000-000000000002_thumb.png",
              created_at: PAST_GRACE,
            },
          ] satisfies StorageEntry[],
        );
      }
      return Promise.resolve([]);
    },
    classifyPaths: (paths) => {
      assertEquals([...paths].sort(), [orphanPath, badThumbPath].sort());
      return Promise.resolve({
        ok: true,
        result: { orphanPaths: [orphanPath], invalidPaths: [badThumbPath] },
      });
    },
    enqueueOrphans: (fid, paths) => {
      enqueueCalls.push({ familyId: fid, paths });
      return Promise.resolve({
        ok: true,
        result: { enqueued: paths.length, dropped: 0 },
      });
    },
    readCursor: () => Promise.resolve(null),
    writeCursor: () => Promise.resolve(),
  };

  const warnings: string[] = [];
  const result = await scanFamilyOrphans(deps, familyId, CUTOFF_MS, warnings);

  assertEquals(result, {
    considered: 1,
    enqueued: 1,
    dropped: 1,
    invalidCount: 1,
    invalidSample: [badThumbPath],
  });
  assertEquals(enqueueCalls, [{ familyId, paths: [orphanPath] }]);
  assertEquals(
    warnings.some((w) => w.includes(badThumbPath)),
    true,
    "形狀不合規的路徑應該出現在 warnings 裡，不能靜默消失（N3 要修的正是這個）",
  );
});

Deno.test("scanFamilyOrphans：enqueueOrphans 自己防禦性重驗丟棄的筆數，會累加進總 dropped（不會被 classify 階段的結果蓋掉）", async () => {
  const familyId = "fam-2";
  const pathA = `${familyId}/2026/07/bbbbbbbb-0000-4000-8000-000000000001.jpg`;
  const pathB = `${familyId}/2026/07/bbbbbbbb-0000-4000-8000-000000000002.jpg`;

  const deps: OrphanScanDeps = {
    listPaged: (path) => {
      if (path === familyId) {
        return Promise.resolve([{ id: null, name: "2026" }]);
      }
      if (path === `${familyId}/2026`) {
        return Promise.resolve([{ id: null, name: "07" }]);
      }
      if (path === `${familyId}/2026/07`) {
        return Promise.resolve(
          [
            {
              id: "f1",
              name: "bbbbbbbb-0000-4000-8000-000000000001.jpg",
              created_at: PAST_GRACE,
            },
            {
              id: "f2",
              name: "bbbbbbbb-0000-4000-8000-000000000002.jpg",
              created_at: PAST_GRACE,
            },
          ] satisfies StorageEntry[],
        );
      }
      return Promise.resolve([]);
    },
    // classify 階段：兩條都合法形狀、都是真孤兒（invalidPaths 空）。
    classifyPaths: () =>
      Promise.resolve({
        ok: true,
        result: { orphanPaths: [pathA, pathB], invalidPaths: [] },
      }),
    // enqueue 階段：模擬防禦性重驗自己又丟了一筆（例如前綴比對邊界案例）。
    enqueueOrphans: () =>
      Promise.resolve({ ok: true, result: { enqueued: 1, dropped: 1 } }),
    readCursor: () => Promise.resolve(null),
    writeCursor: () => Promise.resolve(),
  };

  const result = await scanFamilyOrphans(deps, familyId, CUTOFF_MS, []);

  assertEquals(result, {
    considered: 2,
    enqueued: 1,
    dropped: 1,
    invalidCount: 0,
    invalidSample: [],
  });
});

Deno.test("scanFamilyOrphans：還在寬限期內的物件不計入候選，不會呼叫 classifyPaths／enqueueOrphans", async () => {
  const familyId = "fam-3";
  const deps: OrphanScanDeps = {
    listPaged: (path) => {
      if (path === familyId) {
        return Promise.resolve([{ id: null, name: "2026" }]);
      }
      if (path === `${familyId}/2026`) {
        return Promise.resolve([{ id: null, name: "07" }]);
      }
      if (path === `${familyId}/2026/07`) {
        return Promise.resolve(
          [
            { id: "f1", name: "recent.jpg", created_at: WITHIN_GRACE },
          ] satisfies StorageEntry[],
        );
      }
      return Promise.resolve([]);
    },
    classifyPaths: unreachable("沒有過寬限期的候選"),
    enqueueOrphans: unreachable("沒有過寬限期的候選"),
    readCursor: () => Promise.resolve(null),
    writeCursor: () => Promise.resolve(),
  };

  const result = await scanFamilyOrphans(deps, familyId, CUTOFF_MS, []);
  assertEquals(result, {
    considered: 0,
    enqueued: 0,
    dropped: 0,
    invalidCount: 0,
    invalidSample: [],
  });
});

Deno.test("scanFamilyOrphans：avatars 子資料夾整個跳過，不會被當成 year 資料夾遞迴列出", async () => {
  const familyId = "fam-4";
  let avatarsListed = false;
  const deps: OrphanScanDeps = {
    listPaged: (path) => {
      if (path === familyId) {
        return Promise.resolve(
          [
            { id: null, name: "avatars" },
            { id: null, name: "2026" },
          ] satisfies StorageEntry[],
        );
      }
      if (path === `${familyId}/avatars`) {
        avatarsListed = true;
        return Promise.resolve(
          [
            { id: "x", name: "child.jpg", created_at: PAST_GRACE },
          ] satisfies StorageEntry[],
        );
      }
      if (path === `${familyId}/2026`) return Promise.resolve([]);
      return Promise.resolve([]);
    },
    classifyPaths: unreachable("沒有候選路徑"),
    enqueueOrphans: unreachable("沒有候選路徑"),
    readCursor: () => Promise.resolve(null),
    writeCursor: () => Promise.resolve(),
  };

  const result = await scanFamilyOrphans(deps, familyId, CUTOFF_MS, []);
  assertEquals(result, {
    considered: 0,
    enqueued: 0,
    dropped: 0,
    invalidCount: 0,
    invalidSample: [],
  });
  assertEquals(avatarsListed, false, "avatars 資料夾不該被遞迴列出");
});

// ---------------------------------------------------------------------------
// scanOrphanStorageObjects — N2：游標分段寫回
// ---------------------------------------------------------------------------

/** 建一個「家庭 → 檔案清單」的假 Storage 樹；沒有檔案的家庭直接回空陣列，不建
 * year/month 層（scanFamilyOrphans 收到空陣列就結束，不會再往下 list）。 */
function buildFamilyTree(
  families: Record<string, { name: string; createdAt: string }[]>,
): Record<string, StorageEntry[]> {
  const tree: Record<string, StorageEntry[]> = {};
  const familyIds = Object.keys(families);
  tree[""] = familyIds.map((id) => ({ id: null, name: id }));
  for (const familyId of familyIds) {
    const files = families[familyId];
    if (files.length === 0) {
      tree[familyId] = [];
      continue;
    }
    tree[familyId] = [{ id: null, name: "2026" }];
    tree[`${familyId}/2026`] = [{ id: null, name: "07" }];
    tree[`${familyId}/2026/07`] = files.map((f) => ({
      id: `id-${f.name}`,
      name: f.name,
      created_at: f.createdAt,
    }));
  }
  return tree;
}

function makeDeps(
  tree: Record<string, StorageEntry[]>,
  overrides: Partial<OrphanScanDeps> = {},
): { deps: OrphanScanDeps; writeCursorCalls: (string | null)[] } {
  const writeCursorCalls: (string | null)[] = [];
  const deps: OrphanScanDeps = {
    listPaged: (path) => Promise.resolve(tree[path] ?? []),
    classifyPaths: () =>
      Promise.resolve({
        ok: true,
        result: { orphanPaths: [], invalidPaths: [] },
      }),
    enqueueOrphans: () =>
      Promise.resolve({ ok: true, result: { enqueued: 0, dropped: 0 } }),
    readCursor: () => Promise.resolve(null),
    writeCursor: (lastFamilyId) => {
      writeCursorCalls.push(lastFamilyId);
      return Promise.resolve();
    },
    ...overrides,
  };
  return { deps, writeCursorCalls };
}

Deno.test("scanOrphanStorageObjects：游標在每個家庭前綴掃完後就寫回一次，不是整趟掃描結束才寫一次（N2）", async () => {
  const tree = buildFamilyTree({ a: [], b: [], c: [] });
  const { deps, writeCursorCalls } = makeDeps(tree);

  const result = await scanOrphanStorageObjects(deps, CUTOFF_MS, 500, []);

  // N2 的核心斷言：3 個家庭前綴，游標應該被寫回 3 次（依序 a → b → null），
  // 不是舊行為那樣只在迴圈外寫一次（那樣這裡只會看到 1 筆）。
  assertEquals(writeCursorCalls, ["a", "b", null]);
  assertEquals(result, {
    enqueued: 0,
    dropped: 0,
    scanCompleted: true,
    cursor: null,
    invalidCount: 0,
    invalidSample: [],
  });
});

Deno.test("scanOrphanStorageObjects：候選預算用完時停在已完整處理的家庭，游標仍然被寫回那個家庭（不是 null、不是完全沒寫）", async () => {
  const tree = buildFamilyTree({
    a: [
      { name: "1.jpg", createdAt: PAST_GRACE },
      { name: "2.jpg", createdAt: PAST_GRACE },
      { name: "3.jpg", createdAt: PAST_GRACE },
    ],
    b: [],
    c: [],
  });
  const { deps, writeCursorCalls } = makeDeps(tree, {
    classifyPaths: (paths) =>
      Promise.resolve({
        ok: true,
        result: { orphanPaths: paths, invalidPaths: [] },
      }),
    enqueueOrphans: (_familyId, paths) =>
      Promise.resolve({
        ok: true,
        result: { enqueued: paths.length, dropped: 0 },
      }),
  });

  // batchSize=2：家庭 a 貢獻 3 個候選，超過預算，round-robin 應該停在 a，
  // 不再繼續掃 b／c。
  const result = await scanOrphanStorageObjects(deps, CUTOFF_MS, 2, []);

  assertEquals(
    writeCursorCalls,
    ["a"],
    "只完整處理了家庭 a，游標只該被寫回一次、值是 a",
  );
  assertEquals(result, {
    enqueued: 3,
    dropped: 0,
    scanCompleted: false,
    cursor: "a",
    invalidCount: 0,
    invalidSample: [],
  });
});

Deno.test("scanOrphanStorageObjects：round-robin 從游標之後的家庭開始（resume），繞完一整圈游標歸零", async () => {
  const tree = buildFamilyTree({ a: [], b: [], c: [] });
  const visitedOrder: string[] = [];
  const { deps, writeCursorCalls } = makeDeps(tree, {
    readCursor: () => Promise.resolve("b"),
    listPaged: (path) => {
      if (path === "a" || path === "b" || path === "c") visitedOrder.push(path);
      return Promise.resolve(tree[path] ?? []);
    },
  });

  const result = await scanOrphanStorageObjects(deps, CUTOFF_MS, 500, []);

  // resumeAfter="b" → 第一個 > "b" 的家庭是 "c"，round-robin 順序 c → a → b。
  assertEquals(visitedOrder, ["c", "a", "b"]);
  assertEquals(writeCursorCalls, ["c", "a", null]);
  assertEquals(result.scanCompleted, true);
  assertEquals(result.cursor, null);
});

// ---------------------------------------------------------------------------
// LS-223 —— F2：候選預算不被形狀不合規的路徑吃掉／F1：不合規路徑改計數＋樣本
// ---------------------------------------------------------------------------

Deno.test("scanOrphanStorageObjects：候選預算不被形狀不合規的路徑吃掉（F2：considered 在 classify 之後才扣掉 invalidPaths）", async () => {
  const validName = "valid.jpg";
  const invalidNames = [
    "bad1_thumb.png",
    "bad2_thumb.png",
    "bad3_thumb.png",
    "bad4_thumb.png",
  ];
  const tree = buildFamilyTree({
    a: [
      { name: validName, createdAt: PAST_GRACE },
      ...invalidNames.map((name) => ({ name, createdAt: PAST_GRACE })),
    ],
    b: [],
    c: [],
  });
  const validPath = `a/2026/07/${validName}`;
  const invalidPaths = invalidNames.map((name) => `a/2026/07/${name}`);

  const { deps, writeCursorCalls } = makeDeps(tree, {
    classifyPaths: (paths) => {
      if (paths.includes(validPath)) {
        return Promise.resolve({
          ok: true,
          result: { orphanPaths: [validPath], invalidPaths },
        });
      }
      return Promise.resolve({
        ok: true,
        result: { orphanPaths: [], invalidPaths: [] },
      });
    },
    enqueueOrphans: (_familyId, paths) =>
      Promise.resolve({
        ok: true,
        result: { enqueued: paths.length, dropped: 0 },
      }),
  });

  // batchSize=2：家庭 a 有 5 個過寬限期候選（1 合規＋4 不合規）。修法前
  // considered 在 classify 之前就定值＝5，>= batchSize(2) 會讓 round-robin
  // 在處理完 a 之後就停下、不再繼續掃 b／c。修法後 considered 只計「過寬限期
  // 且形狀合規」的候選（=1），應該可以繼續繞完整圈。
  const result = await scanOrphanStorageObjects(deps, CUTOFF_MS, 2, []);

  assertEquals(
    writeCursorCalls,
    ["a", "b", null],
    "considered 不該把 4 個形狀不合規的路徑算進候選預算，應該能繼續繞完 b／c",
  );
  assertEquals(result.scanCompleted, true);
  assertEquals(result.cursor, null);
  assertEquals(result.enqueued, 1);
  assertEquals(result.invalidCount, 4);
});

Deno.test("scanFamilyOrphans：不合規路徑數量超過 5 筆時，只回報前 5 筆樣本，計數仍是真實筆數（F1：計數＋樣本回報，不再無上限 join 整份清單）", async () => {
  const familyId = "fam-5";
  const invalidNames = Array.from({ length: 7 }, (_, i) => `bad-${i}.png`);
  const invalidPaths = invalidNames.map((name) =>
    `${familyId}/2026/07/${name}`
  );

  const deps: OrphanScanDeps = {
    listPaged: (path) => {
      if (path === familyId) {
        return Promise.resolve([{ id: null, name: "2026" }]);
      }
      if (path === `${familyId}/2026`) {
        return Promise.resolve([{ id: null, name: "07" }]);
      }
      if (path === `${familyId}/2026/07`) {
        return Promise.resolve(
          invalidNames.map((name, i) => ({
            id: `f${i}`,
            name,
            created_at: PAST_GRACE,
          })) satisfies StorageEntry[],
        );
      }
      return Promise.resolve([]);
    },
    classifyPaths: () =>
      Promise.resolve({ ok: true, result: { orphanPaths: [], invalidPaths } }),
    enqueueOrphans: unreachable("orphanPaths 是空的，不該呼叫 enqueueOrphans"),
    readCursor: () => Promise.resolve(null),
    writeCursor: () => Promise.resolve(),
  };

  const warnings: string[] = [];
  const result = await scanFamilyOrphans(deps, familyId, CUTOFF_MS, warnings);

  assertEquals(
    result.invalidCount,
    7,
    "計數必須是真實筆數，不能被樣本上限蓋掉",
  );
  assertEquals(result.invalidSample, invalidPaths.slice(0, 5), "樣本最多 5 筆");
  assertEquals(result.considered, 0, "7 筆全部不合規，扣掉後合規候選為 0");
  assertEquals(
    warnings.some((w) => w.includes(invalidPaths[6])),
    false,
    "warning 不該把第 6 筆之後的路徑塞進字串（F1 修法：計數＋樣本，不是無上限 join）",
  );
  assertEquals(
    warnings.some((w) => w.includes("7 個路徑形狀不合規")),
    true,
    "warning 仍要保留真實計數",
  );
});
