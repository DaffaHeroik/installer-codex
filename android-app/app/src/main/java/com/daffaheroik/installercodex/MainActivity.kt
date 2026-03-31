package com.daffaheroik.installercodex

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit


class MainActivity : AppCompatActivity() {
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .build()

    private val handler = Handler(Looper.getMainLooper())
    private val prefs by lazy { getSharedPreferences("installer_codex", Context.MODE_PRIVATE) }

    private lateinit var serverUrlInput: EditText
    private lateinit var apiTokenInput: EditText
    private lateinit var summaryText: TextView
    private lateinit var availabilityText: TextView
    private lateinit var loginStateText: TextView
    private lateinit var deviceCodeText: TextView
    private lateinit var loginUrlText: TextView

    private var latestLoginUrl: String? = null

    private val poller = object : Runnable {
        override fun run() {
            refreshOverview(showToast = false)
            handler.postDelayed(this, 5000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        serverUrlInput = findViewById(R.id.serverUrlInput)
        apiTokenInput = findViewById(R.id.apiTokenInput)
        summaryText = findViewById(R.id.summaryText)
        availabilityText = findViewById(R.id.availabilityText)
        loginStateText = findViewById(R.id.loginStateText)
        deviceCodeText = findViewById(R.id.deviceCodeText)
        loginUrlText = findViewById(R.id.loginUrlText)

        serverUrlInput.setText(prefs.getString("server_url", "http://YOUR_VPS_IP:8787"))
        apiTokenInput.setText(prefs.getString("api_token", "change-me"))

        findViewById<Button>(R.id.saveButton).setOnClickListener {
            saveConfig()
        }
        findViewById<Button>(R.id.refreshButton).setOnClickListener {
            refreshOverview(showToast = true)
        }
        findViewById<Button>(R.id.startLoginButton).setOnClickListener {
            startLogin()
        }
        findViewById<Button>(R.id.openBrowserButton).setOnClickListener {
            openLoginUrl()
        }
        findViewById<Button>(R.id.copyCodeButton).setOnClickListener {
            copyDeviceCode()
        }
        findViewById<Button>(R.id.logoutButton).setOnClickListener {
            logout()
        }

        refreshOverview(showToast = false)
    }

    override fun onStart() {
        super.onStart()
        handler.post(poller)
    }

    override fun onStop() {
        handler.removeCallbacks(poller)
        super.onStop()
    }

    private fun saveConfig() {
        prefs.edit()
            .putString("server_url", serverUrlInput.text.toString().trim().trimEnd('/'))
            .putString("api_token", apiTokenInput.text.toString().trim())
            .apply()
        toast("Config saved")
        refreshOverview(showToast = false)
    }

    private fun startLogin() {
        val request = baseRequest("/api/login/start")
            .post("{}".toRequestBody(JSON_MEDIA))
            .build()

        executeJson(request, onSuccess = {
            refreshOverview(showToast = true)
        })
    }

    private fun logout() {
        val request = baseRequest("/api/logout")
            .post("{}".toRequestBody(JSON_MEDIA))
            .build()

        executeJson(request, onSuccess = {
            refreshOverview(showToast = true)
        })
    }

    private fun refreshOverview(showToast: Boolean) {
        val request = baseRequest("/api/app/overview")
            .get()
            .build()

        executeJson(
            request,
            onSuccess = { body ->
                renderOverview(body)
                if (showToast) toast("Status updated")
            },
            onFailure = {
                runOnUiThread {
                    availabilityText.text = getString(R.string.availability_fmt, "no_server_available")
                    summaryText.text = getString(R.string.summary_fmt, "No server available")
                    loginStateText.text = getString(R.string.login_state_fmt, "-")
                    deviceCodeText.text = getString(R.string.device_code_fmt, "-")
                    loginUrlText.text = getString(R.string.login_url_fmt, "-")
                    latestLoginUrl = null
                }
            },
        )
    }

    private fun renderOverview(body: JSONObject) {
        val loginState = body.optJSONObject("login_state") ?: JSONObject()
        val phase = loginState.optString("phase", "-")
        val message = body.optString("summary", "-")
        val availability = body.optString("availability", "-")
        val deviceCode = loginState.optString("device_code", "-").ifBlank { "-" }
        val loginUrl = loginState.optString("login_url", "-").ifBlank { "-" }

        latestLoginUrl = loginState.optString("login_url", null)

        runOnUiThread {
            availabilityText.text = getString(R.string.availability_fmt, availability)
            summaryText.text = getString(R.string.summary_fmt, message)
            loginStateText.text = getString(R.string.login_state_fmt, phase)
            deviceCodeText.text = getString(R.string.device_code_fmt, deviceCode)
            loginUrlText.text = getString(R.string.login_url_fmt, loginUrl)
        }
    }

    private fun openLoginUrl() {
        val url = latestLoginUrl
        if (url.isNullOrBlank()) {
            toast("No login URL yet")
            return
        }
        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
    }

    private fun copyDeviceCode() {
        val rawText = deviceCodeText.text.toString()
        val code = rawText.substringAfter(": ").trim()
        if (code == "-" || code.isBlank()) {
            toast("No device code yet")
            return
        }
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("Codex device code", code))
        toast("Device code copied")
    }

    private fun baseRequest(path: String): Request.Builder {
        val serverUrl = serverUrlInput.text.toString().trim().trimEnd('/')
        val apiToken = apiTokenInput.text.toString().trim()
        return Request.Builder()
            .url("$serverUrl$path")
            .header("X-API-Token", apiToken)
    }

    private fun executeJson(
        request: Request,
        onSuccess: (JSONObject) -> Unit,
        onFailure: (() -> Unit)? = null,
    ) {
        client.newCall(request).enqueue(object : okhttp3.Callback {
            override fun onFailure(call: okhttp3.Call, e: IOException) {
                onFailure?.invoke()
                runOnUiThread { toast("Request failed: ${e.message}") }
            }

            override fun onResponse(call: okhttp3.Call, response: okhttp3.Response) {
                response.use {
                    if (!response.isSuccessful) {
                        onFailure?.invoke()
                        runOnUiThread { toast("HTTP ${response.code}") }
                        return
                    }

                    val rawBody = response.body?.string().orEmpty()
                    onSuccess(JSONObject(rawBody))
                }
            }
        })
    }

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    companion object {
        private val JSON_MEDIA = "application/json; charset=utf-8".toMediaType()
    }
}

