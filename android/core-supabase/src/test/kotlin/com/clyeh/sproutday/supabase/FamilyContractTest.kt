package com.clyeh.sproutday.supabase

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.UUID

/**
 * 契約測試（LS-479）：對本機 Supabase 容器逐支驗證 docs/API.md §4 的 RPC 與 §5 的錯誤碼。
 * 情境對照 iOS 的同情境 SQL 測試：建家庭 → 產邀請 → 第二帳號加入 → 核准；外加各錯誤碼分支。
 * 容器沒設定／非本機時整批略過（見 [ContractEnv]）。
 */
class FamilyContractTest {
    private lateinit var config: SupabaseConfig

    @Before
    fun requireLocalContainer() {
        config = ContractEnv.requireLocalConfig()
    }

    private fun tomorrow(): Instant = Instant.now().plus(1, ChronoUnit.DAYS)

    @Test
    fun emailOtpSignInCreatesProfileAndSignOutClearsSession() =
        runBlocking<Unit> {
            val user = TestUsers.signIn(config, "otp")
            val profile = user.account.fetchMyProfile()
            assertEquals("profile.id 應等於 auth uid（trigger 自動建立）", user.id, profile.id)
            assertTrue("display_name 由 trigger 推導，不得為空", profile.displayName.isNotBlank())

            val renamed = user.account.updateDisplayName("測試媽媽")
            assertEquals("測試媽媽", renamed.displayName)

            user.auth.signOut()
            assertEquals(AuthState.SignedOut, user.auth.authState.first { it !is AuthState.SignedIn })
            assertNull("登出後不得殘留 uid", user.auth.currentUserId())
        }

    @Test
    fun wrongOtpCodeIsTypedAuthError() =
        runBlocking<Unit> {
            val email = "ls479-wrongotp-${UUID.randomUUID().toString().take(8)}@example.test"
            val auth = AuthRepository(SupabaseClientFactory.createInMemory(config))
            auth.sendEmailOtp(email)
            val error = expectError<BackendError.Auth> { auth.verifyEmailOtp(email, "000000") }
            assertEquals("GoTrue 的 error_code 字面值（AuthErrorCode.value，非 enum 名）", "otp_expired", error.code)
            assertNull("驗證失敗不得留下 session", auth.currentUserId())
        }

    @Test
    fun createFamilyInviteJoinApproveFlow() =
        runBlocking<Unit> {
            val owner = TestUsers.signIn(config, "owner")
            val member = TestUsers.signIn(config, "member")

            val family = owner.family.createFamily("契約測試家庭")
            assertEquals(owner.id, family.createdBy)
            assertTrue("新家庭預設需核准", family.requireApproval)
            assertEquals(listOf(family.id), owner.family.fetchMyFamilies().map { it.id })

            val members = owner.family.listMembers(family.id)
            assertEquals(
                "建立者由 trigger 自動成為唯一 owner",
                listOf(owner.id to FamilyRole.Owner),
                members.map {
                    it.userId to
                        it.role
                },
            )

            val invite = owner.join.createInvite(family.id, FamilyRole.Member, tomorrow(), maxUses = 3)
            assertEquals("邀請碼為 6 碼（LS-90）", 6, invite.code.length)
            assertEquals(FamilyRole.Member, invite.role)
            assertEquals(0, invite.usedCount)

            // 第二帳號用小寫＋連字號輸入：伺服器端會正規化
            val typed =
                invite.code
                    .lowercase()
                    .chunked(3)
                    .joinToString("-")
            val pending = member.join.requestJoin(typed) as JoinOutcome.Pending
            assertEquals(family.id, pending.familyId)

            val mine = member.join.myJoinRequest()
            assertNotNull(mine)
            assertEquals("pending", mine?.status)
            assertEquals(pending.requestId, mine?.requestId)

            val queue = owner.join.listJoinRequests()
            val queued = queue.single { it.requestId == pending.requestId }
            assertEquals(member.id, queued.applicantId)
            assertEquals(FamilyRole.Member, queued.role)

            assertEquals("未核准前，申請人還不是成員", 1, owner.family.listMembers(family.id).size)

            owner.join.approveJoin(pending.requestId)

            val after = owner.family.listMembers(family.id)
            assertEquals(listOf(FamilyRole.Owner, FamilyRole.Member), after.map { it.role })
            assertEquals(setOf(owner.id, member.id), after.map { it.userId }.toSet())
            assertEquals("核准後申請人看得到該家庭", listOf(family.id), member.family.fetchMyFamilies().map { it.id })
            assertEquals("approved", member.join.myJoinRequest()?.status)
            assertTrue("owner 的待審佇列清空", owner.join.listJoinRequests().none { it.requestId == pending.requestId })
        }

    @Test
    fun inviteErrorCodesMapToSealedErrors() =
        runBlocking<Unit> {
            val owner = TestUsers.signIn(config, "inv-owner")
            val alice = TestUsers.signIn(config, "alice")
            val bob = TestUsers.signIn(config, "bob")
            val carol = TestUsers.signIn(config, "carol")
            val family = owner.family.createFamily("邀請錯誤碼家庭")

            expectError<BackendError.InviteNotFound> { alice.join.requestJoin("ZZZZZZ") } // LS010
            expectError<BackendError.PermissionDenied> {
                // 42501：非 owner 產碼
                alice.join.createInvite(family.id, FamilyRole.Member, tomorrow(), 1)
            }
            expectError<BackendError.InviteParamsInvalid> {
                // LS017：max_uses 超界
                owner.join.createInvite(family.id, FamilyRole.Member, tomorrow(), 0)
            }
            expectError<BackendError.InviteParamsInvalid> {
                // LS017：到期日超過 30 天
                owner.join.createInvite(family.id, FamilyRole.Member, Instant.now().plus(31, ChronoUnit.DAYS), 1)
            }

            // max_uses=2：申請成立就消耗次數（拒絕／撤回不退還），所以 alice 重複申請先撞 LS014、第三人才撞 LS012
            val invite = owner.join.createInvite(family.id, FamilyRole.Member, tomorrow(), maxUses = 2)
            val pending = alice.join.requestJoin(invite.code) as JoinOutcome.Pending
            expectError<BackendError.JoinRequestAlreadyPending> { alice.join.requestJoin(invite.code) } // LS014
            bob.join.requestJoin(invite.code)
            expectError<BackendError.InviteExhausted> { carol.join.requestJoin(invite.code) } // LS012

            alice.join.withdrawJoin(pending.requestId)
            expectError<BackendError.JoinRequestNotFound> { alice.join.withdrawJoin(pending.requestId) } // LS015
            expectError<BackendError.JoinRequestNotFound> { owner.join.approveJoin(pending.requestId) } // LS015
            expectError<BackendError.JoinRequestNotFound> { owner.join.rejectJoin(pending.requestId) } // LS015
            assertEquals("withdrawn", alice.join.myJoinRequest()?.status)
        }

    @Test
    fun alreadyMemberAndRejectFlow() =
        runBlocking<Unit> {
            val owner = TestUsers.signIn(config, "rj-owner")
            val member = TestUsers.signIn(config, "rj-member")
            val family = owner.family.createFamily("加入拒絕家庭")
            val invite = owner.join.createInvite(family.id, FamilyRole.Viewer, tomorrow(), maxUses = 5)

            val first = member.join.requestJoin(invite.code) as JoinOutcome.Pending
            owner.join.rejectJoin(first.requestId)
            assertEquals("rejected", member.join.myJoinRequest()?.status)
            assertEquals("拒絕不寫 family_members", 1, owner.family.listMembers(family.id).size)

            val second = member.join.requestJoin(invite.code) as JoinOutcome.Pending
            owner.join.approveJoin(second.requestId)
            assertEquals(
                FamilyRole.Viewer,
                owner.family
                    .listMembers(family.id)
                    .last()
                    .role,
            )
            expectError<BackendError.AlreadyMember> { member.join.requestJoin(invite.code) } // LS013
        }

    @Test
    fun onlyOwnerCanEditFamilyAndZeroRowUpdateIsExplicit() =
        runBlocking<Unit> {
            val owner = TestUsers.signIn(config, "ed-owner")
            val member = TestUsers.signIn(config, "ed-member")
            val family = owner.family.createFamily("改名前")
            val invite = owner.join.createInvite(family.id, FamilyRole.Member, tomorrow(), 1)
            owner.join.approveJoin((member.join.requestJoin(invite.code) as JoinOutcome.Pending).requestId)

            owner.family.updateFamilyName(family.id, "改名後")
            owner.family.setRequireApproval(family.id, false)
            val updated = owner.family.fetchMyFamilies().single()
            assertEquals("改名後", updated.name)
            assertFalse(updated.requireApproval)

            // RLS USING 過濾：非 owner 的 UPDATE 不丟錯、匹配 0 列（API.md §2）——client 必須轉成明確錯誤
            expectError<BackendError.NoRowsAffected> { member.family.updateFamilyName(family.id, "亂改") }
            assertEquals(
                "改名後",
                owner.family
                    .fetchMyFamilies()
                    .single()
                    .name,
            )
        }

    @Test
    fun soleOwnerCannotLeaveOrDeleteAccountWhileOthersRemain() =
        runBlocking<Unit> {
            val owner = TestUsers.signIn(config, "lv-owner")
            val member = TestUsers.signIn(config, "lv-member")
            val family = owner.family.createFamily("轉移 owner 家庭")
            val invite = owner.join.createInvite(family.id, FamilyRole.Member, tomorrow(), 1)
            owner.join.approveJoin((member.join.requestJoin(invite.code) as JoinOutcome.Pending).requestId)

            // LS057：唯一 owner 退出，DETAIL 帶 {"family_id","family_name"}
            val leave =
                expectError<BackendError.MustTransferOwnership> { owner.family.removeMember(family.id, owner.id) }
            assertEquals("LS057", leave.code)
            assertEquals(listOf(family.id), leave.families.map { it.familyId })
            assertEquals("轉移 owner 家庭", leave.families.single().familyName)

            // LS050：刪帳號被擋，DETAIL 帶待轉移家庭陣列；沒有任何資料被改動
            val outcome = owner.account.deleteMyAccount()
            assertTrue(outcome is DeleteAccountOutcome.MustTransferOwnership)
            assertEquals(
                listOf(family.id),
                (outcome as DeleteAccountOutcome.MustTransferOwnership).families.map { it.familyId },
            )
            assertEquals("被擋下後家庭成員不變", 2, owner.family.listMembers(family.id).size)

            // 一般成員可自行退出
            member.family.removeMember(family.id, member.id)
            assertEquals(1, owner.family.listMembers(family.id).size)
        }
}
