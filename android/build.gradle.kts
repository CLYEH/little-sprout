plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.detekt) apply false
    alias(libs.plugins.ktlint) apply false
    alias(libs.plugins.ksp) apply false
    alias(libs.plugins.google.services) apply false
}

// 釘住檔在 repo 根（單一來源，shell／CI／Gradle 共讀）；android/ 是 Gradle 根，所以往上一層。
val repoRoot: File = rootDir.parentFile
fun pinned(name: String): String = repoRoot.resolve(name).readText().trim()

extra["androidApi"] = pinned(".android-api").toInt()
extra["jdkVersion"] = pinned(".jdk-version").toInt()

subprojects {
    apply(plugin = "io.gitlab.arturbosch.detekt")
    apply(plugin = "org.jlleitschuh.gradle.ktlint")

    configure<io.gitlab.arturbosch.detekt.extensions.DetektExtension> {
        buildUponDefaultConfig = true
        config.setFrom(rootProject.file("config/detekt/detekt.yml"))
        // 預設只掃 src/main 與 src/test；app 的除錯面板在 src/debug、release 根畫面在 src/release，要一起掃
        source.setFrom(files(listOf("main", "debug", "release", "test").map { "src/$it/kotlin" }))
    }

    // detekt 1.23.x 以 Kotlin 2.0.21 編譯；專案 Kotlin 較新時它會因版本不符拒跑，官方 FAQ 的做法是把 detekt
    // 自己的設定檔釘在它編譯用的 Kotlin 版本，不影響專案本身的 Kotlin。
    configurations.matching { it.name == "detekt" }.configureEach {
        resolutionStrategy.eachDependency {
            if (requested.group == "org.jetbrains.kotlin") useVersion("2.0.21")
        }
    }
}
