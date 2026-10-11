package com.clyeh.sproutday.supabase

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.auth

/** 目前登入者的 uid；沒有 session 就 [BackendError.NotSignedIn]（資料層方法在送請求前先 fail loud）。 */
internal fun SupabaseClient.requireUserId(): String = auth.currentUserOrNull()?.id ?: throw BackendError.NotSignedIn()
