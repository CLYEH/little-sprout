#!/bin/bash
# android-env-check.sh — Android 本機環境是否齊到能跑 `./gradlew ktlintCheck detekt :app:testDebugUnitTest …`（LS-477）
#
# 供 push-gate.sh 的 Android 段呼叫。對照 iOS 的 `.xcode-version`／`.ios-runtime` 對齊，但極性不同：iOS 工具鏈
# 缺了就紅（開發機一定有 Xcode）；Android 工具鏈使用者還沒裝是常態，所以這裡**不裝＝⚠ 略過、不擋 push**
# （fail-open 到 CI 的 android-lint／android-unit，LS-477 票文），由呼叫端印醒目 ⚠ 並在 handoff 註明。
#
# 檢查（單一來源＝repo 根釘住檔，與 CI／Gradle 同讀）：
#   1. JDK：`$JAVA_HOME/bin/java` 優先、否則 PATH 的 `java`，`-version` 解析出的 major 必須等於 `.jdk-version`
#      （macOS 的 /usr/bin/java 是「找不到 Java Runtime」的 stub，-version 無版本字串＝視為未安裝）
#   2. Android SDK：android_sdk_root（$ANDROID_HOME／$ANDROID_SDK_ROOT／android/local.properties 的 sdk.dir）
#      下有 `platform-tools/`（含 adb）與 `platforms/android-<.android-api>/`
#   3. emulator：資訊性（印有／沒有），只有帶 `--require-emulator`（detect-emulator.sh 用）才算必要——跑 unit test
#      不需要 emulator，本機有 SDK 沒裝 emulator 不該連 ktlint／detekt／unit 一起跳過。票文原把 emulator 列為
#      必備項，這裡刻意拆開（見 PR 說明）。
#
# 釘住檔（`.jdk-version`／`.android-api`）缺檔＝fail loud（exit 1），不當成「未安裝」——那是 repo 壞了，不是本機環境。
#
# 用法：android-env-check.sh [--require-emulator] [--repo <path>]
# exit：0＝齊；3＝本機未安裝／版本不符（stdout 印逐項原因，呼叫端轉成 ⚠）；1＝釘住檔缺／壞；2＝參數錯
# 自測：scripts/gates/android-env-check.test.sh（假 java／假 SDK 目錄；本機沒有真 JDK／SDK 時「已安裝」路徑只能靠夾具）
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/android-tools.sh
source "$here/lib/android-tools.sh"

need_emulator=0
repo=
while [ $# -gt 0 ]; do
  case "$1" in
    --require-emulator) need_emulator=1; shift ;;
    --repo) repo=${2:-}; [ -n "$repo" ] || { echo "✗ android-env-check：--repo 缺值" >&2; exit 2; }; shift 2 ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "✗ android-env-check：未知參數「$1」。用法：android-env-check.sh [--require-emulator] [--repo <path>]" >&2; exit 2 ;;
  esac
done
[ -n "$repo" ] || repo=$(git -C "$here" rev-parse --show-toplevel 2>/dev/null) || repo=
[ -n "$repo" ] && [ -d "$repo" ] || { echo "✗ android-env-check：找不到 repo 根（請給 --repo）" >&2; exit 2; }

for f in .jdk-version .android-api .gradle-version; do
  if [ ! -f "$repo/$f" ]; then
    echo "✗ android-env-check：缺釘住檔 ${f}（CI 的 android-lint／android-unit 會紅；LS-474 單一來源）" >&2
    exit 1
  fi
done
jdk_pin=$(tr -d '[:space:]' < "$repo/.jdk-version")
api_pin=$(tr -d '[:space:]' < "$repo/.android-api")
case "$jdk_pin" in ''|*[!0-9]*) echo "✗ android-env-check：.jdk-version 須為整數 major（得到「${jdk_pin}」）" >&2; exit 1 ;; esac
case "$api_pin" in ''|*[!0-9]*) echo "✗ android-env-check：.android-api 須為整數（得到「${api_pin}」）" >&2; exit 1 ;; esac

problems=
add_problem() { problems="${problems}  - $1"$'\n'; }

# ---- 1. JDK ----
java_bin=
if [ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/java" ]; then java_bin="${JAVA_HOME}/bin/java"
else java_bin=$(command -v java 2>/dev/null) || java_bin=; fi
jdk_major=
if [ -n "$java_bin" ]; then
  # `java -version` 印在 stderr：`openjdk version "17.0.10" …`／`java version "1.8.0_x"`（舊式 1.x → major 取第二段）
  jv=$("$java_bin" -version 2>&1 | sed -n 's/.*version "\([0-9][0-9._]*\).*/\1/p' | head -1) || jv=
  if [ -n "$jv" ]; then
    case "$jv" in 1.*) jdk_major=$(printf '%s' "$jv" | cut -d. -f2) ;; *) jdk_major=$(printf '%s' "$jv" | cut -d. -f1 | cut -d_ -f1) ;; esac
  fi
fi
if [ -z "$jdk_major" ]; then
  add_problem "找不到可用的 JDK（JAVA_HOME／PATH 的 java 都跑不出版本字串）——需要 JDK ${jdk_pin}（brew install --cask temurin@${jdk_pin}）"
elif [ "$jdk_major" != "$jdk_pin" ]; then
  add_problem "JDK major ${jdk_major} ≠ .jdk-version 釘住的 ${jdk_pin}（${java_bin}）——CI 用 ${jdk_pin}，本機版本不同可能行為不一致"
fi

# ---- 2. Android SDK ----
sdk=$(android_sdk_root "$repo")
if [ -z "$sdk" ]; then
  add_problem "找不到 Android SDK（ANDROID_HOME／ANDROID_SDK_ROOT 未設或目錄不存在，android/local.properties 也沒有有效的 sdk.dir）"
else
  [ -d "$sdk/platform-tools" ] || add_problem "SDK ${sdk} 缺 platform-tools/"
  [ -d "$sdk/platforms/android-${api_pin}" ] || add_problem "SDK ${sdk} 缺 platforms/android-${api_pin}（.android-api 釘住 ${api_pin}；SDK Manager 裝 Android ${api_pin} 平台）"
fi

# ---- 3. emulator（資訊性，--require-emulator 才必要）----
emu_bin=$(android_tool emulator "$repo")
if [ -z "$emu_bin" ] && [ "$need_emulator" -eq 1 ]; then
  add_problem "找不到 emulator（SDK 的 emulator/emulator 或 PATH）——SDK Manager 裝 Android Emulator"
fi

if [ -n "$problems" ]; then
  echo "⚠ android-env：本機 Android 環境不齊："
  printf '%s' "$problems"
  exit 3
fi
echo "✓ android-env：JDK ${jdk_major}（${java_bin}）、SDK ${sdk}（platform-tools、platforms/android-${api_pin}）齊；emulator：${emu_bin:-未安裝（unit test 不需要）}"
exit 0
