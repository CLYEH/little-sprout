package com.clyeh.sproutday

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.File

class VersionPropertiesTest {
    @Test
    fun parsesNameAndCode() {
        val parsed = VersionProperties.parse("VERSION_NAME=1.2.3\nVERSION_CODE=42\n")
        assertEquals(VersionProperties("1.2.3", 42), parsed)
    }

    @Test
    fun missingFileFallsBackTo000And1() {
        assertEquals(VersionProperties("0.0.0", 1), VersionProperties.parse(null))
    }

    @Test
    fun malformedCodeFailsLoudly() {
        assertThrows(IllegalArgumentException::class.java) {
            VersionProperties.parse("VERSION_NAME=1.0.0\nVERSION_CODE=abc\n")
        }
    }

    @Test
    fun missingNameFailsLoudly() {
        assertThrows(IllegalArgumentException::class.java) {
            VersionProperties.parse("VERSION_CODE=3\n")
        }
    }

    /** 建置接線：BuildConfig（來自 app/build.gradle.kts）必須等於同一份 version.properties 的解析結果。 */
    @Test
    fun buildConfigMatchesVersionPropertiesFile() {
        // 單元測試的工作目錄是模組目錄 android/app；version.properties 在 android/。
        val file = File("../version.properties")
        val expected = VersionProperties.parse(if (file.exists()) file.readText() else null)
        assertEquals(expected, VersionProperties(BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE))
    }
}
