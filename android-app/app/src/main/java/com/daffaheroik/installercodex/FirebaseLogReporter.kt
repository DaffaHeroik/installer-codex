package com.daffaheroik.installercodex

import android.content.Context
import android.os.Build
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import java.util.concurrent.TimeUnit


object FirebaseLogReporter {
    private const val FIREBASE_DB_ROOT = "https://kebun-pintar-dce3e-default-rtdb.firebaseio.com"
    private const val LOG_PATH = "codex_app_logs"
    private val JSON_MEDIA = "application/json; charset=utf-8".toMediaType()

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()

    fun install(context: Context) {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            log(
                context = context,
                level = "fatal",
                event = "uncaught_exception",
                message = throwable.message ?: "Unknown uncaught exception",
                extra = JSONObject()
                    .put("thread", thread.name)
                    .put("stacktrace", throwable.stackTraceToString()),
            )
            Thread.sleep(1200)
            previous?.uncaughtException(thread, throwable)
        }
    }

    fun log(
        context: Context,
        level: String,
        event: String,
        message: String,
        extra: JSONObject? = null,
    ) {
        Thread {
            try {
                val payload = JSONObject()
                    .put("level", level)
                    .put("event", event)
                    .put("message", message)
                    .put("manufacturer", Build.MANUFACTURER)
                    .put("model", Build.MODEL)
                    .put("android_version", Build.VERSION.RELEASE)
                    .put("sdk_int", Build.VERSION.SDK_INT)
                    .put("app_version", BuildConfig.VERSION_NAME)
                    .put("timestamp", System.currentTimeMillis())
                    .put("timestamp_human", SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date()))
                    .put("install_id", installId(context))

                if (extra != null) {
                    payload.put("extra", extra)
                }

                val request = Request.Builder()
                    .url("$FIREBASE_DB_ROOT/$LOG_PATH.json")
                    .post(payload.toString().toRequestBody(JSON_MEDIA))
                    .build()

                client.newCall(request).execute().close()
            } catch (_: Exception) {
            }
        }.start()
    }

    private fun installId(context: Context): String {
        val prefs = context.getSharedPreferences("installer_codex", Context.MODE_PRIVATE)
        val existing = prefs.getString("install_id", null)
        if (!existing.isNullOrBlank()) return existing
        val generated = UUID.randomUUID().toString()
        prefs.edit().putString("install_id", generated).apply()
        return generated
    }
}
