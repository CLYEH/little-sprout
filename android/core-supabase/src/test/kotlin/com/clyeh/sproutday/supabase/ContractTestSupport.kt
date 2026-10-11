package com.clyeh.sproutday.supabase

import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLEncoder
import java.util.UUID

/**
 * 契約測試的環境：打 android/local.properties 指向的「本機」Supabase 容器（`supabase start`，連線值取自 `supabase status -o env`）。
 * 沒設定（例如 CI 的 android-unit job）或指向非本機位址 → 整批測試以 Assume 略過（JUnit 報 skipped，不是通過）。
 * 非本機位址一律不跑：這些測試會建帳號、建家庭，絕不能對正式站執行。
 */
internal object ContractEnv {
    private val localHosts = setOf("127.0.0.1", "localhost", "10.0.2.2")

    /** Mailpit（本機信件攔截）固定在 54324；本機容器的 OTP 信不會真的寄出。 */
    private const val MAILPIT_PORT = 54324

    fun requireLocalConfig(): SupabaseConfig {
        assumeTrue(
            "契約測試需要 android/local.properties 的 SUPABASE_URL／SUPABASE_ANON_KEY 指向本機容器（略過，不算通過）",
            BuildConfig.SUPABASE_URL.isNotBlank() && BuildConfig.SUPABASE_ANON_KEY.isNotBlank(),
        )
        val host = URI(BuildConfig.SUPABASE_URL).host
        assumeTrue("SUPABASE_URL 的 host 是 $host，不是本機容器——契約測試只對本機跑", host in localHosts)
        return SupabaseConfig(BuildConfig.SUPABASE_URL, BuildConfig.SUPABASE_ANON_KEY)
    }

    fun mailpitBase(config: SupabaseConfig): String = "http://${URI(config.url).host}:$MAILPIT_PORT"
}

/** 一個已用 Email OTP 登入的測試使用者（各自獨立的 in-memory client，互不干擾）。 */
@Suppress("LongParameterList") // 測試夾具：一個使用者一組 repository
internal class TestUser(
    val email: String,
    val auth: AuthRepository,
    val family: FamilyRepository,
    val join: JoinRepository,
    val account: AccountRepository,
    val media: MediaRepository,
    val id: String,
)

internal object TestUsers {
    /** 用真實的 Email OTP 流程（sendEmailOtp → 從 Mailpit 取 6 碼 → verifyEmailOtp）建立並登入一個新使用者。 */
    suspend fun signIn(
        config: SupabaseConfig,
        label: String,
    ): TestUser {
        val email = "ls479-$label-${UUID.randomUUID().toString().take(8)}@example.test"
        val client = SupabaseClientFactory.createInMemory(config)
        val auth = AuthRepository(client)
        auth.sendEmailOtp(email)
        auth.verifyEmailOtp(email, fetchOtp(config, email))
        val state = auth.authState.first { it is AuthState.SignedIn }
        return TestUser(
            email,
            auth,
            FamilyRepository(client),
            JoinRepository(client),
            AccountRepository(client),
            MediaRepository(client),
            (state as AuthState.SignedIn).userId,
        )
    }

    /** 輪詢 Mailpit 取最新一封寄給 [email] 的信，抓內文的 6 位數字碼。 */
    suspend fun fetchOtp(
        config: SupabaseConfig,
        email: String,
    ): String {
        val base = ContractEnv.mailpitBase(config)
        val query = URLEncoder.encode("to:$email", Charsets.UTF_8)
        repeat(POLL_ATTEMPTS) {
            val messages =
                Json
                    .parseToJsonElement(
                        get("$base/api/v1/search?query=$query"),
                    ).jsonObject["messages"]
                    ?.jsonArray
            val id =
                messages
                    ?.firstOrNull()
                    ?.jsonObject
                    ?.get("ID")
                    ?.jsonPrimitive
                    ?.content
            if (id != null) {
                val text =
                    Json
                        .parseToJsonElement(
                            get("$base/api/v1/message/$id"),
                        ).jsonObject["Text"]
                        ?.jsonPrimitive
                        ?.content
                        .orEmpty()
                Regex("""\b(\d{6})\b""").find(text)?.let { return it.groupValues[1] }
            }
            delay(POLL_INTERVAL_MS)
        }
        fail("Mailpit 在 ${POLL_ATTEMPTS * POLL_INTERVAL_MS} ms 內沒收到 $email 的 OTP 信（本機容器有跑嗎？）")
        error("unreachable")
    }

    private fun get(url: String): String {
        val connection = URL(url).openConnection() as HttpURLConnection
        return try {
            connection.inputStream.bufferedReader().use { it.readText() }
        } finally {
            connection.disconnect()
        }
    }

    private const val POLL_ATTEMPTS = 40
    private const val POLL_INTERVAL_MS = 250L
}

/** 斷言 [block] 丟出 [E] 型 [BackendError]，回傳它供進一步檢查。 */
internal suspend inline fun <reified E : BackendError> expectError(block: () -> Unit): E {
    try {
        block()
    } catch (e: BackendError) {
        if (e is E) return e
        fail("預期 ${E::class.simpleName}，實際是 ${e::class.simpleName}(code=${e.code}): ${e.message}")
    }
    fail("預期丟出 ${E::class.simpleName}，但呼叫成功了")
    error("unreachable")
}
