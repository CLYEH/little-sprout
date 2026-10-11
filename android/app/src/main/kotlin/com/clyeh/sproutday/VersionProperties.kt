package com.clyeh.sproutday

import java.util.Properties

/**
 * `android/version.properties`（scripts/ops/release-version.sh 產生）的解析規則。
 * app/build.gradle.kts 讀同一份檔、同一組 fallback；[VersionPropertiesTest] 驗建置出的 BuildConfig 與這裡一致。
 */
data class VersionProperties(val name: String, val code: Int) {
    companion object {
        val FALLBACK = VersionProperties(name = "0.0.0", code = 1)

        /** 檔案不存在（[text] 為 null）→ fallback；有檔但欄位缺或 VERSION_CODE 不是整數 → 丟例外（fail loud）。 */
        fun parse(text: String?): VersionProperties {
            if (text == null) return FALLBACK
            val props = Properties().apply { load(text.reader()) }
            val name = requireNotNull(props.getProperty("VERSION_NAME")) { "version.properties 缺 VERSION_NAME" }
            val code = requireNotNull(props.getProperty("VERSION_CODE")?.toIntOrNull()) {
                "version.properties 的 VERSION_CODE 缺漏或不是整數"
            }
            return VersionProperties(name, code)
        }
    }
}
