/* 管線的正典順序，寫成一支可以重跑的腳本（第 3 輪新增）。
   第 2 輪這個順序只存在於人的腦袋裡，所以每次手跑都可能少一步 ——
   而少哪一步會長成哪一種假綠燈，是這一輪一路踩出來的：

     ① build    產出 34 張板 ＋ canvas.json ＋ _root.json（結構指紋＋內容指紋）
     ② measure  在真瀏覽器裡量。開跑前三方對帳（server 的 _root.json、本地磁碟、
                 瀏覽器真的 fetch 到的原文），不一致就 exit 1（R9 第二版）
     ③ shot     截圖，並把截圖的一致性寫回 measured.json
     ④ build    **再一次** —— 這一次才把量到的數字印上板（G21 的 ls-measured 鏈）
     ⑤ verify   下判斷

   ④ 是必要的：板上印的實測句必須出自現行的 measured.json。也因為有 ④，
   內容指紋在 measure 之後必然變一次 —— 所以 G21b 用的是**結構**指紋，
   內容指紋由 ② 當場對帳（理由印在 verify 的 G21c 上）。
   Run: node run.mjs [--no-shot] */
import { execFileSync } from 'node:child_process';

const noShot = process.argv.includes('--no-shot');
const steps = [['build.mjs'], ['measure.mjs'], ...(noShot ? [] : [['_shot.mjs']]), ['build.mjs'], ['verify.mjs']];
for (const [step] of steps) {
  console.log(`\n──────── ${step} ────────`);
  try {
    process.stdout.write(execFileSync(process.execPath, [new URL(step, import.meta.url).pathname], { encoding: 'utf8', maxBuffer: 1 << 26 }));
  } catch (e) {
    process.stdout.write(e.stdout || '');
    process.stderr.write(e.stderr || '');
    console.error(`\n管線停在 ${step}（exit ${e.status}）`);
    process.exit(e.status || 1);
  }
}
