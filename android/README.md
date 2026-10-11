# android/ — Sprout Day（Android）

Gradle（Kotlin DSL）專案：`:app`（`com.clyeh.sproutday`，Compose＋Material 3）與 `:core-supabase`（supabase-kt client 建構）。
本資料夾是 LS-474（Android 前置 A1）的骨架；功能（Auth／RPC／畫面）在後續票。

## 單一來源釘住檔（repo 根）

| 檔案 | 值 | 誰讀 |
| --- | --- | --- |
| `.jdk-version` | `17` | CI `actions/setup-java`（`java-version-file`）、`android/build.gradle.kts` |
| `.android-api` | `36` | `compileSdk`／`targetSdk`（`android/build.gradle.kts` 讀、各模組取用） |
| `.gradle-version` | `8.14.5` | 人／CI 對帳；**必須與** `android/gradle/wrapper/gradle-wrapper.properties` 的 `distributionUrl` 同版 |

升級任何一個：改釘住檔＋對應設定（wrapper properties／`gradle/libs.versions.toml`）同一個 PR。

## 本機安裝（macOS）

1. JDK 17：`brew install --cask temurin@17`，確認 `java -version` 為 17.x。
2. Android Studio（含 Android SDK）：SDK Manager 裝 **Android 36** 平台與 build-tools。
3. `cp android/local.properties.example android/local.properties`，填 `sdk.dir`、`SUPABASE_URL`、`SUPABASE_ANON_KEY`
   （`local.properties` 已 gitignore；URL／key 的取得同 iOS 的 `Secrets.xcconfig`）。
4. 版本號（可選）：`bash scripts/ops/release-version.sh` 會寫 `android/version.properties`（`VERSION_NAME`／`VERSION_CODE`，
   gitignored）；沒跑時 Gradle 退回 `0.0.0`／`1`。
5. 驗證：
   ```bash
   cd android
   ./gradlew ktlintCheck detekt                                   # = CI android-lint
   ./gradlew :app:testDebugUnitTest :core-supabase:testDebugUnitTest   # = CI android-unit
   ```

### AVD 命名

Emulator 一律 `LS-<票號>-Pixel8`（例：`LS-480-Pixel8`），與 iOS 專屬模擬器 `<票號>-iPhone17Pro` 同理：一票一台、用完關、結案刪。
`bash scripts/gates/detect-emulator.sh` 依票號找／建／開（system image 讀 `.android-api`，缺就印 `sdkmanager "…"` 指令、不自動下載）並印
`emulator: <name> <serial> API <ver>（pinned <ver>）`；用完 `bash scripts/gates/detect-emulator.sh --stop`；結案 `bash scripts/ops/cleanup-merged.sh --apply LS-<n>`
連 AVD 一起刪。操作某台 emulator 的整段指令包進 `bash scripts/ops/emulator-lock.sh --serial <serial> -- <命令>`。
hook `emu-all-guard.sh` 擋 `adb kill-server`、無 `-s` 的 `adb emu kill`、刪非本票的 AVD。connected test 在後續票（LS-478）。

## 本機沒裝 JDK／Android SDK 時

- 不能跑 `./gradlew`，所以 ktlint／detekt／unit test 只有 CI 的 `android-lint`／`android-unit` job 會跑；
  push gate（`scripts/gates/push-gate.sh`）的 Android 段（LS-477）偵測到本機環境不齊（`scripts/gates/android-env-check.sh` exit 3）會印
  `⚠⚠⚠ Android 段略過：以 CI 為準` 並**不擋 push**——handoff 須註明這次 Android 段沒在本機跑；`android/**` 變更同時跳過 SwiftLint／xcodegen／xcodebuild。
  裝齊（JDK 對 `.jdk-version`、SDK 有 platform-tools 與 `.android-api` 的 platform）後，push gate 會自動跑
  `./gradlew ktlintCheck detekt :app:testDebugUnitTest :core-supabase:testDebugUnitTest`。
- 純 bash 能驗的部分本機仍會跑：`bash scripts/ops/release-version.test.sh`（含 `android/version.properties` 案）、`tracked-ignored-check`、`scan-secrets`。

## Gradle wrapper

- `gradle/wrapper/gradle-wrapper.jar` 進 repo，來源：GitHub `gradle/gradle` tag `v8.14.5` 的 `gradle/wrapper/gradle-wrapper.jar`
  （https://raw.githubusercontent.com/gradle/gradle/v8.14.5/gradle/wrapper/gradle-wrapper.jar）。
- sha256：`7d3a4ac4de1c32b59bc6a4eb8ecb8e612ccd0cf1ae1e99f66902da64df296172`，
  與 Gradle 官方公布值一致（https://services.gradle.org/distributions/gradle-8.14.5-wrapper.jar.sha256）。
- `gradlew`／`gradlew.bat` 取自同一 tag；`distributionSha256Sum` 為官方 `gradle-8.14.5-bin.zip` 的校驗值。
- 更新：換 tag 重取三檔、重算 sha256 與官方值比對，並同步 `.gradle-version`。

## 版本選擇（2026-10 時點）

AGP 8.13.2（刻意不上 9.x，DSL／內建 Kotlin 變動大）、Gradle 8.14.5、Kotlin 2.3.21（supabase-kt 3.8.0 以 Kotlin 2.4 編譯，
Kotlin 編譯器可讀高一個 minor 的 metadata，所以 Kotlin 不能停在 2.2）、Compose BOM 2026.06.01（BOM 2026.08+ 的 foundation 1.12 要 compileSdk 37，AGP 8.13 建議上限 36）、activity-compose 1.12.4、supabase-kt BOM 3.8.0、
ktor 3.5.1（與 supabase-kt 同版）、detekt 1.23.8（見下）、ktlint-gradle 14.2.0。
全部集中在 `gradle/libs.versions.toml`。

detekt 1.23.x 以 Kotlin 2.0.21 編譯，專案 Kotlin 更新時它會拒跑；`android/build.gradle.kts` 把 detekt 自己的 configuration
釘在 Kotlin 2.0.21（官方 FAQ 做法，專案編譯不受影響）。detekt 2.x 轉正後再移除這段。

`.android-api` 為 36：票文原寫 35，但 supabase-kt 3.8.0 的傳遞依賴 `androidx.browser:browser:1.10.0` 要 compileSdk 36 以上
（CI 的 `checkDebugAarMetadata` 實測擋下），compileSdk 與 targetSdk 共用此值。上架 Google Play 前仍要依當時的 target API 要求確認（另票）。
