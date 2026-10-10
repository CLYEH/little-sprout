# 一起長大・柔粉社群視覺提案

**LS-455** · 來源：[GitHub issue #597](https://github.com/CLYEH/little-sprout/issues/597) · 設計日期：2026-10-09 · 交付日期：2026-10-10（Asia/Taipei）。

本包為十二屏手機視覺提案與獨立品牌 skill，供方向評估。初始七屏方向獲使用者認可，新增五屏為延伸提案。此交付不代表正式產品設計替換或實作完成。

## 交付內容

- `littlesprout-soft-social.pen`：獨立、可編輯的 Pencil 原生稿，與來源原稿位元組一致。
- `exports/`：十二張 780×1688（2x）原生匯出預覽，每張嚴格小於 400,000 bytes（400 KB）；較大的圖使用 PNG 調色盤壓縮，沒有縮小尺寸。
- `assets/`：原生稿引用的十個必要素材；相對路徑保留在此提案目錄。素材來源類型見索引，PNG 同樣小於 400,000 bytes。
- `skill/`：完整、獨立的品牌 skill，包含入口、agent 設定、兩份規範與兩張內附參考；不安裝或替換現有 skill。
- `SCREEN-MANIFEST.json`：畫面、原生節點、匯出檔與素材來源類型索引。
- `.gitattributes`：固定本包文字換行為 LF，並將原生稿與圖片視為二進位，讓跨平台 checkout 的 SHA256 一致。

以 Pencil 開啟原生稿時，請保留 assets/ 相對位置。字型為 Noto Sans TC，未隨包附帶。PNG 是靜態預覽；ImageGen 只提供部分畫面內素材，並非十二屏的原生 UI 稿。

## 畫面索引

| 畫面 | 原生節點 | 預覽 | Bytes |
| --- | --- | --- | ---: |
| 家庭動態 | `rsm56` | [exports/01-home.png](exports/01-home.png) | 206,836 |
| 回憶詳情 | `M7qpWP` | [exports/02-memory.png](exports/02-memory.png) | 224,025 |
| 相簿 | `WavOD` | [exports/03-albums.png](exports/03-albums.png) | 290,900 |
| 寶貝成長 | `ftrBE` | [exports/04-child.png](exports/04-child.png) | 190,974 |
| 飲食小記 | `e347tY` | [exports/05-food.png](exports/05-food.png) | 175,122 |
| 家庭 | `CxGiV` | [exports/06-family.png](exports/06-family.png) | 197,921 |
| 加入照片 | `LefzY` | [exports/07-composer.png](exports/07-composer.png) | 214,398 |
| 相簿內頁 | `m8Dfo` | [exports/08-album-detail.png](exports/08-album-detail.png) | 311,699 |
| 通知 | `Y506Lc` | [exports/09-notifications.png](exports/09-notifications.png) | 236,276 |
| 回憶搜尋 | `MZghz` | [exports/10-search.png](exports/10-search.png) | 381,506 |
| 邀請家人 | `g5YJ4r` | [exports/11-invite.png](exports/11-invite.png) | 157,666 |
| 相簿尚無照片 | `Qr7b0` | [exports/12-album-empty.png](exports/12-album-empty.png) | 115,583 |

## SHA256

以下列出本 README 以外每個交付檔案的 SHA256。README 不自列雜湊，以避免自我參照；可用 Git 提交版本確認本檔。

| 相對路徑 | SHA256 |
| --- | --- |
| `.gitattributes` | `41d1d6b8931ca0534a187b19f57585d644616540ddc344cb1d0661a449524827` |
| `assets/app-icon.png` | `356a7f56136abe8068c7c2d21a3dc73d6287e5faea88ec8186e79361d7d77a37` |
| `assets/child-leaf.jpg` | `f57ac0bbdab129a61dd51a99eb8c0444c531075cfd1705d6b651524645b8cf7f` |
| `assets/child.jpg` | `768dc67cfcb193a6fe344af6dabab781153c000926b871847917e38bfeebf127` |
| `assets/dad.jpg` | `2e5538256f84012de3f3f21f92682a29f10e620bc982f2ef0ec9ce71fcc19fd4` |
| `assets/family-moment.jpg` | `b603e388bdd7638b2a17c6cb9cfb1ac236e1394b2fe6c3bb06220af37a3a3754` |
| `assets/family-picnic.jpg` | `18d2601ab4bc6e4bbd737ff916aae6ca8368ecbdc6bba612577cbc405e2184ff` |
| `assets/grandma.jpg` | `2e4faf9cb95ca983c64d907a951998d67a9e55d1699e2f906f0a41c8b965ee5d` |
| `assets/mandarin-sticker.png` | `e25b803b978c20bf9e7f61ca30882aa766fdc06c2e8f97db049afa82b5bbef0b` |
| `assets/mom.jpg` | `dbef7acf304bd38e436824f3c0469724659da3d9c245879edff9f15e0774ccf4` |
| `assets/wordmark.png` | `f17e92c5ffe215356ff5a8d54ad25f842efa11d4c49fbc6ced1707be3c38195b` |
| `exports/01-home.png` | `18b6fd6fa4ac9b460c1bd2ce1c12beec7cd0bcbbe363c75ab2fefaea69ed0377` |
| `exports/02-memory.png` | `797ba5b676cc09f4b9ae95d7efd66e5e640feb611efe130d6c9dcd7a24b6ffc1` |
| `exports/03-albums.png` | `e38e6fe1a0f2de889c7a0b6b813a56959390f096a058fa154b7e0cd11acce87d` |
| `exports/04-child.png` | `0a8369f1117f7b07b40956104417c0aa37e9a1282ef6632d450785ed0db67da2` |
| `exports/05-food.png` | `ba03edf3a5ffef16fe4ff89c4f0bef733a223fddc8e98a3e0229ea2c71fe4011` |
| `exports/06-family.png` | `435a0ac51d550b40b23aafa3520994fbb6ad5363d192f837c3aaae0b6bf6b662` |
| `exports/07-composer.png` | `5566cca4168fb5ead1a72f003f12b34815dc4a7cbae30e08b06f57e3cb7223a3` |
| `exports/08-album-detail.png` | `3f08f40bfaeb2793c3e5003f5db9ea6a6097b4f54b57eb4013ab33d518efb910` |
| `exports/09-notifications.png` | `ab107dc8a15bb0b49be8f2b76075f96cbe6989cf2c6ba8f33465eb89d07e6826` |
| `exports/10-search.png` | `a5cf6570a52c0bc64cadecabcd2fea6c4eab46802295d5deb59ed6b1e68115bd` |
| `exports/11-invite.png` | `96ff463ca3f6d881630beb3367c3e6abebf75d13e079ce3b4c41434ae90794eb` |
| `exports/12-album-empty.png` | `807f6696b4135bf5aef6720cbae603df28b395f464709ab83c3709f64bf45722` |
| `littlesprout-soft-social.pen` | `d1fb5fe4ea4a22fb5e86f5ecce0a8bd24439330e393df09438ca351ecba41d9a` |
| `SCREEN-MANIFEST.json` | `dca8353bccad69bc1d1e2f8436b825d6ca6845a95f6568c83357812a71ce7e12` |
| `skill/agents/openai.yaml` | `ab452d2f8df8e0ec0342dd7beeef04bf4a33b3c3cb0091eec15348b250a26fa3` |
| `skill/references/baseline.md` | `b5208d9136068d815efd8f8e3e0dd4d8e0187c3b54870f6fa6974aa00c44a095` |
| `skill/references/images/growth.png` | `0a8369f1117f7b07b40956104417c0aa37e9a1282ef6632d450785ed0db67da2` |
| `skill/references/images/home.png` | `18b6fd6fa4ac9b460c1bd2ce1c12beec7cd0bcbbe363c75ab2fefaea69ed0377` |
| `skill/references/visual-system.md` | `3902d2565485113a6986fde314573a804157c26714dee254409822b062281e30` |
| `skill/SKILL.md` | `9b4a627dc735bf3f26209a6751d1002ef0ef8dd0800ae23eb099850f13a2e760` |
