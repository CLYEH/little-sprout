package com.clyeh.sproutday.debug

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.clyeh.sproutday.supabase.AuthState

/**
 * 除錯用登入面板（LS-479）：純文字按鈕，只為手動驗證資料層——不是產品畫面、不對 .pen、不進 tap-target 登記。
 */
@Composable
fun DebugAuthPanel(viewModel: DebugAuthViewModel) {
    val ui by viewModel.state.collectAsStateWithLifecycle()
    Column(
        modifier =
            Modifier
                .fillMaxSize()
                .safeDrawingPadding()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("Sprout Day — 除錯登入面板", style = MaterialTheme.typography.titleMedium)
        Text(authLine(ui.auth), modifier = Modifier.testTag("auth-state"))
        SignInSection(viewModel, enabled = !ui.busy)
        FamilySection(viewModel, ui, enabled = !ui.busy)
        Text("紀錄", style = MaterialTheme.typography.titleSmall)
        ui.log.forEach { Text(it, style = MaterialTheme.typography.bodySmall) }
    }
}

@Composable
private fun SignInSection(
    viewModel: DebugAuthViewModel,
    enabled: Boolean,
) {
    val context = LocalContext.current
    var email by rememberSaveable { mutableStateOf("") }
    var code by rememberSaveable { mutableStateOf("") }
    DebugField("Email", email, "email-field") { email = it }
    DebugButton("寄 Email OTP", enabled, "send-otp") { viewModel.sendOtp(email) }
    DebugField("6 碼 OTP", code, "otp-field") { code = it }
    DebugButton("驗證 OTP", enabled, "verify-otp") { viewModel.verifyOtp(email, code) }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        DebugButton("Google", enabled, "google") { viewModel.signInWithGoogle(context) }
        DebugButton("Apple", enabled, "apple") { viewModel.signInWithApple() }
        DebugButton("登出", enabled, "sign-out") { viewModel.signOut() }
    }
}

@Composable
private fun FamilySection(
    viewModel: DebugAuthViewModel,
    ui: DebugUiState,
    enabled: Boolean,
) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        DebugButton("建家庭", enabled, "create-family") { viewModel.createFamily() }
        DebugButton("列成員", enabled, "list-members") { viewModel.listMembers() }
    }
    ui.family?.let { Text("家庭：${it.name}") }
    ui.members.forEach { Text("  ${it.role.name} ${it.displayName}（${it.userId.take(UID_PREVIEW)}…）") }
}

@Composable
private fun DebugButton(
    text: String,
    enabled: Boolean,
    tag: String,
    onClick: () -> Unit,
) {
    Button(onClick = onClick, enabled = enabled, modifier = Modifier.testTag(tag)) { Text(text) }
}

@Composable
private fun DebugField(
    label: String,
    value: String,
    tag: String,
    onValueChange: (String) -> Unit,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        singleLine = true,
        modifier = Modifier.fillMaxWidth().testTag(tag),
    )
}

private const val UID_PREVIEW = 8

private fun authLine(state: AuthState): String =
    when (state) {
        AuthState.Initializing -> "狀態：載入 session 中…"
        AuthState.SignedOut -> "狀態：未登入"
        is AuthState.SignedIn -> "uid：${state.userId}\nemail：${state.email ?: "-"}"
        AuthState.RefreshFailed -> "狀態：session 重新整理失敗（離線？），保留本機 session"
    }
