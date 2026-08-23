/* 管線的正典順序，寫成一支可以重跑的腳本（第 3 輪新增）。
   第 2 輪這個順序只存在於人的腦袋裡，所以每次手跑都可能少一步 ——
   而少哪一步會長成哪一種假綠燈，是這一輪一路踩出來的：

     ① build     產出 35 張板 ＋ canvas.json ＋ _root.json（結構指紋＋內容指紋）
     ② measure   在真瀏覽器裡量。開跑前三方對帳（server 的 _root.json、本地磁碟、
                  瀏覽器真的 fetch 到的原文），不一致就 exit 1（R9 第二版）
     ③ build     **再一次** —— 這一次才把量到的數字印上板（G21 的 ls-measured 鏈）
     ④ shot      截圖。**排在第二次 build 之後**（第 5 輪 D4-08 對調）——
                  第 4 輪它排在 ③ 之前，所以 PNG 永遠是「印上實測數字之前」的那一版：
                  人真的會看的東西與 gate 驗的東西不同版，而且 PNG 上一條 gate 都沒有。
                  現在 shot 把每張板的原文雜湊寫進 shots.json，G17 逐張比對。
     ⑤ selftest  負面對照（第 5 輪 D4-07③）：對內嵌的壞樣本跑同一份 gate 程式，
                  **沒有轉紅就 exit 1**。沒有這一步，「全綠」只證明沒有人破壞，
                  不證明 gate 還有牙。它把結果寫進 selftest.json，MG3 驗它與現行 gate 程式同版。
     ⑥ verify    下判斷（含三條 meta-gate：母體宣告／豁免登記／負面對照）

   ③ 是必要的：板上印的實測句必須出自現行的 measured.json。也因為有 ③，
   內容指紋在 measure 之後必然變一次 —— 所以 G21b 用的是**結構**指紋，
   內容指紋由 ② 當場對帳（理由印在 verify 的 G21c 上）。
   而 ls-measured 戳記本身**排除 measured.json 的 root 欄位**（第 5 輪 D4-09）：
   不排除的話「戳記→內容→contentFp→戳記」會自我餵食，跑兩次得到兩份不同的產物。
   Run: node run.mjs [--no-shot] [--no-selftest] */
import { execFileSync } from 'node:child_process';

const noShot = process.argv.includes('--no-shot');
const noSelf = process.argv.includes('--no-selftest');
const steps = [['build.mjs'], ['measure.mjs'], ['build.mjs'],
  ...(noShot ? [] : [['_shot.mjs']]), ...(noSelf ? [] : [['selftest.mjs']]), ['verify.mjs']];
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
