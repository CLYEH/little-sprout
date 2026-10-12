package com.clyeh.sproutday.supabase

import io.github.jan.supabase.postgrest.from
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import java.util.UUID

/**
 * 契約測試（LS-497）：對本機 Supabase 容器驗證 docs/API.md §4 `register_device_token`——註冊後 `device_tokens` 有一列
 * `platform='android'`；同 token 重註冊列數不變（token 是 PK，RPC 先刪再插）；換 token 是新增一列、舊列不會被清掉
 * （沒有反註冊路徑）；另一個帳號註冊同一個 token 會接手（舊帳號的列消失，不會留下跨帳號推播）。
 * 容器沒設定／非本機時整批略過（見 [ContractEnv]）。
 */
class PushContractTest {
    private lateinit var config: SupabaseConfig

    @Before
    fun requireLocalContainer() {
        config = ContractEnv.requireLocalConfig()
    }

    @Test
    fun registerDeviceTokenAgainstLocalContainer() =
        runBlocking<Unit> {
            val a = TestUsers.signIn(config, "pusha")
            val b = TestUsers.signIn(config, "pushb")
            val tokenA = "fake-token-A-${UUID.randomUUID()}"
            val tokenB = "fake-token-B-${UUID.randomUUID()}"

            PushRepository(a.client).registerDeviceToken(tokenA)
            val first = a.rows()
            assertEquals("註冊後本人只有一列", 1, first.size)
            assertEquals(tokenA, first.single().token)
            assertEquals("platform 必為 android", "android", first.single().platform)
            assertEquals(a.id, first.single().userId)

            PushRepository(a.client).registerDeviceToken(tokenA)
            assertEquals("同 token 重註冊不重複", listOf(tokenA), a.rows().map { it.token })

            PushRepository(a.client).registerDeviceToken(tokenB)
            assertEquals("換 token 是新增一列、舊列保留", setOf(tokenA, tokenB), a.rows().map { it.token }.toSet())
            assertEquals("兩列都是 android", setOf("android"), a.rows().map { it.platform }.toSet())

            PushRepository(b.client).registerDeviceToken(tokenA)
            assertEquals("B 接手 tokenA：B 看得到", listOf(tokenA), b.rows().map { it.token })
            assertEquals("B 接手 tokenA：A 的 tokenA 列被刪、只剩 tokenB", listOf(tokenB), a.rows().map { it.token })
        }

    /** 本人可讀自己的 `device_tokens` 列（RLS `user_id = auth.uid()`）；token 在每次執行都是新的，不受其他測試影響。 */
    private suspend fun TestUser.rows(): List<DeviceTokenRow> =
        client.from("device_tokens").select().decodeList<DeviceTokenRow>()

    @Serializable
    private data class DeviceTokenRow(
        val token: String,
        @SerialName("user_id") val userId: String,
        val platform: String,
    )
}
