package com.clyeh.sproutday.upload

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import com.clyeh.sproutday.supabase.MediaLimits
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.max
import kotlin.math.min

/** 上傳前要知道的原圖資訊與縮圖。[thumbnail] 為 null＝縮圖產生失敗，不阻斷上傳（docs/API.md §3，三個 `thumb_*` 欄留空）。 */
class PreparedMedia(
    val width: Int,
    val height: Int,
    val thumbnail: PreparedThumbnail?,
)

class PreparedThumbnail(
    val bytes: ByteArray,
    val width: Int,
    val height: Int,
)

/** 來源檔無法解碼出尺寸（損毀、或此 API 等級不支援該格式，例如 API 28 以前的 HEIC）：重試不會變好。 */
class UnreadableMediaException(
    message: String,
) : Exception(message)

/** 阻塞式、CPU／IO 密集——呼叫端必須在 IO dispatcher 上呼叫。 */
fun interface MediaPreparer {
    fun prepare(file: File): PreparedMedia
}

/**
 * 原檔**不重新壓縮**（與 iOS 一致：`SupabaseMediaUploadService` 上傳原始位元組，單檔上限 50 MiB 由 bucket 把關）；
 * 只產生縮圖：長邊 ≤ [MediaLimits.THUMBNAIL_MAX_EDGE_PX]、JPEG 品質 [MediaLimits.THUMBNAIL_JPEG_QUALITY_PERCENT]%（docs/API.md §6）。
 * 解碼用 `inSampleSize` 降採樣，不把全尺寸點陣圖載入記憶體。
 */
class AndroidMediaPreparer : MediaPreparer {
    override fun prepare(file: File): PreparedMedia {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw UnreadableMediaException("無法解碼 ${file.name} 的尺寸")
        val orientation = readOrientation(file)
        // EXIF 方向為 5–8 時顯示尺寸的寬高對調；`media.width／height` 記顯示尺寸。
        val swapped = orientation in ORIENTATION_TRANSPOSE..ORIENTATION_ROTATE_270
        val width = if (swapped) bounds.outHeight else bounds.outWidth
        val height = if (swapped) bounds.outWidth else bounds.outHeight
        return PreparedMedia(width, height, makeThumbnail(file, bounds, orientation))
    }

    // 縮圖失敗不得阻斷原檔上傳（docs/API.md §3）；解碼器可能丟各種 RuntimeException／OOM。
    @Suppress("TooGenericExceptionCaught", "SwallowedException")
    private fun makeThumbnail(
        file: File,
        bounds: BitmapFactory.Options,
        orientation: Int,
    ): PreparedThumbnail? =
        try {
            val longEdge = max(bounds.outWidth, bounds.outHeight)
            var sample = 1
            while (longEdge / (sample * 2) >= MediaLimits.THUMBNAIL_MAX_EDGE_PX) sample *= 2
            val decoded = BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })
            decoded?.let { encode(it, orientation) }
        } catch (e: RuntimeException) {
            null
        } catch (e: OutOfMemoryError) {
            null
        }

    private fun encode(
        decoded: Bitmap,
        orientation: Int,
    ): PreparedThumbnail {
        val scale = min(1f, MediaLimits.THUMBNAIL_MAX_EDGE_PX.toFloat() / max(decoded.width, decoded.height))
        val matrix = orientationMatrix(orientation).apply { postScale(scale, scale) }
        val oriented = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
        val out = ByteArrayOutputStream()
        check(
            oriented.compress(Bitmap.CompressFormat.JPEG, MediaLimits.THUMBNAIL_JPEG_QUALITY_PERCENT, out),
        ) { "JPEG 編碼失敗" }
        val thumbnail = PreparedThumbnail(out.toByteArray(), oriented.width, oriented.height)
        if (oriented !== decoded) oriented.recycle()
        decoded.recycle()
        return thumbnail
    }

    @Suppress("SwallowedException") // 沒有／讀不到 EXIF 就當正向，不是錯誤
    private fun readOrientation(file: File): Int =
        try {
            ExifInterface(file.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        } catch (e: java.io.IOException) {
            ExifInterface.ORIENTATION_NORMAL // 沒有／讀不到 EXIF 就當正向
        }

    private fun orientationMatrix(orientation: Int): Matrix =
        Matrix().apply {
            when (orientation) {
                ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> postScale(-1f, 1f)
                ExifInterface.ORIENTATION_ROTATE_180 -> postRotate(ROTATE_180)
                ExifInterface.ORIENTATION_FLIP_VERTICAL -> postScale(1f, -1f)
                ExifInterface.ORIENTATION_TRANSPOSE -> {
                    postRotate(ROTATE_90)
                    postScale(-1f, 1f)
                }
                ExifInterface.ORIENTATION_ROTATE_90 -> postRotate(ROTATE_90)
                ExifInterface.ORIENTATION_TRANSVERSE -> {
                    postRotate(-ROTATE_90)
                    postScale(-1f, 1f)
                }
                ExifInterface.ORIENTATION_ROTATE_270 -> postRotate(-ROTATE_90)
            }
        }

    private companion object {
        const val ORIENTATION_TRANSPOSE = ExifInterface.ORIENTATION_TRANSPOSE
        const val ORIENTATION_ROTATE_270 = ExifInterface.ORIENTATION_ROTATE_270
        const val ROTATE_90 = 90f
        const val ROTATE_180 = 180f
    }
}
