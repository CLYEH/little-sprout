#!/bin/bash
# android-env-check.sh 的自測（LS-477）。CI rules job 跑。
# 本機沒有真 JDK／Android SDK，所以「已安裝」路徑一律靠夾具：假 java（印指定版本字串）＋假 SDK 目錄結構；
# PATH 只放最小工具集的 symlink（ubuntu runner 的 /usr/bin/java 會污染「未安裝」案例）。
# 負控（mutation）：把 JDK major 比對拿掉 → 版本不符案例必須翻成通過（證明該案例釘住該判斷）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="${root}/scripts/gates/android-env-check.sh"
fail=0
source "${root}/scripts/gates/lib/selftest-helpers.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ---- 最小 PATH：只有腳本會用到的工具 ----
minbin="$work/minbin"; mkdir -p "$minbin"
for t in bash sed tr cut head dirname git; do
  p=$(command -v "$t") || { echo "✗ 測試環境缺 $t" >&2; exit 1; }
  ln -s "$p" "$minbin/$t"
done

# ---- 夾具 repo（只要釘住檔）----
mkrepo() {  # $1=目錄
  mkdir -p "$1"
  printf '17\n' > "$1/.jdk-version"; printf '36\n' > "$1/.android-api"; printf '8.14.5\n' > "$1/.gradle-version"
}
fake_java() {  # $1=bin 目錄 $2=版本字串（印在 stderr，同真 java）
  mkdir -p "$1"
  printf '#!/bin/bash\necho "openjdk version \\"%s\\" 2025-01-21" >&2\necho "OpenJDK Runtime Environment" >&2\n' "$2" > "$1/java"
  chmod +x "$1/java"
}
fake_sdk() {  # $1=SDK 根 $2=api（空＝不建 platform）$3=1 則建 emulator
  mkdir -p "$1/platform-tools"; : > "$1/platform-tools/adb"; chmod +x "$1/platform-tools/adb"
  [ -n "$2" ] && mkdir -p "$1/platforms/android-$2"
  if [ "${3:-0}" = 1 ]; then mkdir -p "$1/emulator"; : > "$1/emulator/emulator"; chmod +x "$1/emulator/emulator"; fi
}
run() {  # run <env 賦值…> -- <腳本參數…>；以 env -i 隔離，PATH 只含 minbin
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  out=$(env -i PATH="$minbin" HOME="$work" "${envs[@]}" "$minbin/bash" "$checker" "$@" 2>&1); rc=$?
}

R="$work/repo"; mkrepo "$R"

# ① 全部沒裝 → exit 3，點名 JDK 與 SDK（⚠ 略過路徑，本機真實狀況）
run -- --repo "$R"
expect_exit 3 "$rc" "① 未安裝：exit 3"
expect_has "$out" "找不到可用的 JDK" "① 未安裝：點名 JDK"
expect_has "$out" "找不到 Android SDK" "① 未安裝：點名 SDK"

# ② JDK 17 ＋ SDK（platform-tools＋android-36）齊 → exit 0（emulator 沒裝也過：資訊性）
fake_java "$work/jdk17/bin" "17.0.10"; fake_sdk "$work/sdk" 36 0
run JAVA_HOME="$work/jdk17" ANDROID_HOME="$work/sdk" -- --repo "$R"
expect_exit 0 "$rc" "② 齊（無 emulator）：exit 0"
expect_has "$out" "emulator：未安裝（unit test 不需要）" "② 齊：emulator 資訊性"

# ③ --require-emulator 但沒裝 → exit 3；裝了 → exit 0
run JAVA_HOME="$work/jdk17" ANDROID_HOME="$work/sdk" -- --repo "$R" --require-emulator
expect_exit 3 "$rc" "③a --require-emulator 無 emulator：exit 3"
expect_has "$out" "找不到 emulator" "③a 點名 emulator"
fake_sdk "$work/sdk2" 36 1
run JAVA_HOME="$work/jdk17" ANDROID_SDK_ROOT="$work/sdk2" -- --repo "$R" --require-emulator
expect_exit 0 "$rc" "③b --require-emulator 有 emulator（ANDROID_SDK_ROOT 路徑）：exit 0"

# ④ JDK 版本不符（21 ≠ 17）→ exit 3 點名版本
fake_java "$work/jdk21/bin" "21.0.2"
run JAVA_HOME="$work/jdk21" ANDROID_HOME="$work/sdk" -- --repo "$R"
expect_exit 3 "$rc" "④ JDK 21 ≠ 釘住 17：exit 3"
expect_has "$out" "JDK major 21 ≠ .jdk-version 釘住的 17" "④ 點名版本差"

# ⑤ 舊式版本字串 1.8 → major 8 ≠ 17
fake_java "$work/jdk8/bin" "1.8.0_392"
run JAVA_HOME="$work/jdk8" ANDROID_HOME="$work/sdk" -- --repo "$R"
expect_has "$out" "JDK major 8 ≠" "⑤ 1.8.x 解析成 major 8"

# ⑥ JDK 從 PATH 找（不設 JAVA_HOME）
fake_java "$work/pathjdk" "17.0.9"
run PATH="$work/pathjdk:$minbin" ANDROID_HOME="$work/sdk" -- --repo "$R"
expect_exit 0 "$rc" "⑥ java 在 PATH 上（無 JAVA_HOME）：exit 0"

# ⑦ SDK 缺 platform（只有 android-35，釘住 36）→ exit 3 點名
rm -rf "$work/sdk35"; fake_sdk "$work/sdk35" 35 0
run JAVA_HOME="$work/jdk17" ANDROID_HOME="$work/sdk35" -- --repo "$R"
expect_exit 3 "$rc" "⑦ 缺 platforms/android-36：exit 3"
expect_has "$out" "缺 platforms/android-36" "⑦ 點名缺的 platform"

# ⑧ SDK 缺 platform-tools
mkdir -p "$work/sdknopt/platforms/android-36"
run JAVA_HOME="$work/jdk17" ANDROID_HOME="$work/sdknopt" -- --repo "$R"
expect_has "$out" "缺 platform-tools/" "⑧ 缺 platform-tools"

# ⑨ SDK 由 android/local.properties 的 sdk.dir 提供（README 要使用者填的位置）
mkdir -p "$R/android"; printf 'sdk.dir=%s\n' "$work/sdk" > "$R/android/local.properties"
run JAVA_HOME="$work/jdk17" -- --repo "$R"
expect_exit 0 "$rc" "⑨ sdk.dir（local.properties）：exit 0"
rm -f "$R/android/local.properties"

# ⑩ 釘住檔缺 → exit 1（repo 壞了，不是環境未安裝）
R2="$work/repo2"; mkrepo "$R2"; rm "$R2/.android-api"
run JAVA_HOME="$work/jdk17" ANDROID_HOME="$work/sdk" -- --repo "$R2"
expect_exit 1 "$rc" "⑩ 缺 .android-api：exit 1"
expect_has "$out" "缺釘住檔 .android-api" "⑩ 點名缺的檔"

# ⑪ 釘住檔內容非整數 → exit 1
R3="$work/repo3"; mkrepo "$R3"; printf 'abc\n' > "$R3/.jdk-version"
run JAVA_HOME="$work/jdk17" ANDROID_HOME="$work/sdk" -- --repo "$R3"
expect_exit 1 "$rc" "⑪ .jdk-version 非整數：exit 1"

# ⑫ 參數錯
run -- --bogus
expect_exit 2 "$rc" "⑫ 未知參數：exit 2"

# ⑬ 真 repo 的釘住檔可讀（單一來源仍在）
run -- --repo "$root"
if [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; then echo "✓ ⑬ 真 repo 釘住檔可解析（exit ${rc}）"; else echo "✗ ⑬ 真 repo 釘住檔解析失敗（exit ${rc}）：${out}" >&2; fail=1; fi

# ---- mutation：拿掉 JDK major 比對 → ④ 必翻成通過 ----
mut="$work/mut"; mkdir -p "$mut/lib"
anchor='elif [ "$jdk_major" != "$jdk_pin" ]; then'
if ! grep -qF "$anchor" "$checker"; then
  echo "✗ mutation 錨點不在 android-env-check.sh：${anchor}" >&2; fail=1
else
  sed "s/\[ \"\$jdk_major\" != \"\$jdk_pin\" \]/false/" "$checker" > "$mut/android-env-check.sh"
  cp "${root}/scripts/gates/lib/android-tools.sh" "$mut/lib/android-tools.sh"
  out=$(env -i PATH="$minbin" HOME="$work" JAVA_HOME="$work/jdk21" ANDROID_HOME="$work/sdk" "$minbin/bash" "$mut/android-env-check.sh" --repo "$R" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then echo "✓ mutation：拿掉 JDK major 比對後 ④ 的 JDK 21 翻成通過（④ 確由該判斷造成）"
  else echo "✗ mutation：拿掉 JDK major 比對後仍 exit ${rc}（④ 沒釘住該判斷）：${out}" >&2; fail=1; fi
fi

if [ "$fail" -eq 0 ] && [ "${selftest_helpers_fail:-0}" -eq 0 ]; then echo "✓ android-env-check 自測通過"; exit 0; fi
exit 1
