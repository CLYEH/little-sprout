# 萌芽日記 Little Sprout — EULA 附加條款

| 項目 | 內容 |
|---|---|
| 版本 | v0.1（草稿，尚未生效） |
| 生效日期 | [[EFFECTIVE_DATE]] |
| 用途 | 貼入 App Store Connect「App 資訊 → 授權合約（License Agreement）」的自訂 EULA 欄位 |

## 這份文件怎麼用（非合約內容）

Apple 的做法是二選一：**不填**自訂 EULA 時套用 Apple 標準 EULA（App Store 頁面不顯示授權合約連結）；**填了**自訂 EULA 就整份取代標準 EULA，且自訂內容不得牴觸 Apple 的「開發者 EULA 最低條款」（Instructions for Minimum Terms）。PLAN §9-B 的「Apple 標準 EULA 加附一段」在 App Store Connect 上沒有「附加」欄位，因此本文件寫成一份**自成一體的自訂 EULA**：以引用方式納入 Apple 標準 EULA 全文（即保留 Apple 全部條款），再加上本 App 特有的零容忍與家庭私密條款。這樣無論使用者從哪個入口看到，條款一致。

- 欄位只接受純文字，HTML 標籤會被移除，只保留換行。下方 `BEGIN PASTE`／`END PASTE` 之間的文字即為貼入內容，請勿貼入本節說明。
- 若使用者最終決定**不用**自訂 EULA（只用 Apple 標準 EULA），零容忍條款仍由《使用條款》第 6 節承載——歡迎頁「登入即表示你同意《使用條款》」即為同意入口，Guideline 1.2 亦可滿足；差別只在 App Store 產品頁是否顯示授權合約連結。取捨見 `docs/legal/README.md`。
- 來源：
  - Apple「Provide a custom license agreement」：https://developer.apple.com/help/app-store-connect/manage-app-information/provide-a-custom-license-agreement/
  - Apple 標準 EULA：https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
  - Apple 開發者 EULA 最低條款：https://www.apple.com/legal/internet-services/itunes/appstore/dev/minterms/

---

<!-- BEGIN PASTE -->
萌芽日記 Little Sprout 使用者授權合約

生效日期：[[EFFECTIVE_DATE]]　版本：v0.1

一、與 Apple 標準 EULA 的關係
1. 本 App 由 [[OPERATOR_NAME]]（下稱「授權人」）提供。您對本 App 的使用，適用 Apple 公司之「授權應用程式使用者授權合約」（Licensed Application End User License Agreement，網址 https://www.apple.com/legal/internet-services/itunes/dev/stdeula/ ，下稱「Apple 標準 EULA」）之全部條款，該等條款以引用方式納入本合約；另適用下列附加條款。
2. 本合約是您與授權人之間的合約，Apple 並非本合約當事人。Apple 對本 App 不負任何維護或支援義務。您與授權人確認 Apple 及其子公司為本合約之第三方受益人，於您接受本合約後，Apple 有權以第三方受益人身分對您執行本合約。
3. 附加條款與 Apple 標準 EULA 有牴觸時，就 Apple 與 App Store 相關事項以 Apple 標準 EULA 為準；其餘以附加條款、授權人之《使用條款》及《隱私權政策》為準。

二、對冒犯性內容零容忍
1. 本 App 允許使用者上傳照片、影片、日記與留言，並在其所屬的私密家庭內分享。授權人對辱罵、騷擾、霸凌、威脅、仇恨言論、色情、涉及兒童或少年之性剝削內容，以及其他違法或侵權內容，採取零容忍政策。
2. 您同意不上傳、發佈或傳播上述內容，並同意授權人得在不事先通知的情況下移除任何此類內容、限制或終止您的帳號，並於必要時保留紀錄向主管機關或司法機關通報。
3. 任何使用者皆可在 App 內檢舉內容，或寄信至 [[SUPPORT_EMAIL]] 檢舉。授權人承諾於收到檢舉後 24 小時內採取行動，包括移除內容及對違規者停權。使用者亦可在 App 內封鎖其他成員；家庭 Owner 可移除其家庭內的任何內容與成員。

三、家庭私密空間與兒童內容
1. 本 App 之內容以「家庭」為隔離單位，僅家庭成員可見。您同意只把邀請碼交給您信任的人，不在公開場合張貼，並在邀請碼外流時立即撤銷。
2. 您僅得為您有權拍攝並分享其影像的人（包括孩子）上傳內容；就未成年人，您須為其家長或監護人，或已取得其家長或監護人之同意。
3. 您加入他人家庭後所見之內容（包括孩子的姓名、生日與影像），僅得在該家庭內依成員合理期待之方式使用，不得未經該家庭 Owner 同意轉貼、公開或提供予家庭以外之人。

四、帳號與資料
1. 您可隨時於 App 內刪除帳號；您的個人資料與內容之處理方式，依授權人之《隱私權政策》（[[SUPPORT_URL]]/privacy）。
2. 本 App 並非備份服務，請自行保留照片與影片之原始檔案。

五、其他
1. 您對本 App 的使用亦受授權人之《使用條款》（[[SUPPORT_URL]]/terms）拘束；該條款就服務內容、家庭與角色、使用者內容授權、禁止行為、免責與責任限制、準據法與管轄有更完整之約定。
2. 本合約以中華民國法律為準據法。
3. 授權人聯絡方式：[[OPERATOR_NAME]]，電子郵件 [[SUPPORT_EMAIL]]，支援網頁 [[SUPPORT_URL]]。
<!-- END PASTE -->
