package com.daffaheroik.installercodex

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.ListView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.TimeUnit


class MainActivity : AppCompatActivity() {
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .build()

    private val handler = Handler(Looper.getMainLooper())

    private lateinit var summaryText: TextView
    private lateinit var availabilityText: TextView
    private lateinit var activeServerText: TextView
    private lateinit var loginStateText: TextView
    private lateinit var deviceCodeText: TextView
    private lateinit var loginUrlText: TextView
    private lateinit var serverList: ListView

    private val serverItems = mutableListOf<ServerItem>()
    private lateinit var serverAdapter: ArrayAdapter<String>

    private var selectedServerId: String? = null
    private var activeServer: ServerItem? = null
    private var latestLoginUrl: String? = null
    private val refreshInFlight = AtomicBoolean(false)
    private val overviewInFlight = AtomicBoolean(false)
    private var isForeground = false
    private var userSelectingServer = false

    private val poller = object : Runnable {
        override fun run() {
            if (isForeground && !userSelectingServer) {
                refreshServers(showToast = false)
            }
            handler.postDelayed(this, 7000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        summaryText = findViewById(R.id.summaryText)
        availabilityText = findViewById(R.id.availabilityText)
        activeServerText = findViewById(R.id.activeServerText)
        loginStateText = findViewById(R.id.loginStateText)
        deviceCodeText = findViewById(R.id.deviceCodeText)
        loginUrlText = findViewById(R.id.loginUrlText)
        serverList = findViewById(R.id.serverList)

        serverAdapter = ArrayAdapter(this, android.R.layout.simple_list_item_1, mutableListOf())
        serverList.adapter = serverAdapter
        serverList.setOnItemClickListener { _, _, position, _ ->
            val item = serverItems.getOrNull(position) ?: return@setOnItemClickListener
            userSelectingServer = true
            selectedServerId = item.serverId
            activeServer = item
            refreshOverview(showToast = true)
            handler.postDelayed({ userSelectingServer = false }, 1500)
        }

        findViewById<Button>(R.id.refreshButton).setOnClickListener {
            refreshServers(showToast = true)
        }
        findViewById<Button>(R.id.useSelectedButton).setOnClickListener {
            val chosen = serverItems.firstOrNull { it.serverId == selectedServerId }
            if (chosen == null) {
                toast("Select a server first")
            } else {
                activeServer = chosen
                refreshOverview(showToast = true)
            }
        }
        findViewById<Button>(R.id.deleteSelectedButton).setOnClickListener {
            deleteSelectedServer()
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

        refreshServers(showToast = false)
    }

    override fun onStart() {
        super.onStart()
        isForeground = true
        handler.post(poller)
    }

    override fun onStop() {
        isForeground = false
        handler.removeCallbacks(poller)
        super.onStop()
    }

    private fun refreshServers(showToast: Boolean) {
        if (!refreshInFlight.compareAndSet(false, true)) {
            return
        }

        val request = Request.Builder()
            .url(FIREBASE_SERVERS_URL)
            .get()
            .build()

        executeJson(
            request,
            onSuccess = { body ->
                val freshServers = parseServers(body)
                serverItems.clear()
                serverItems.addAll(freshServers)
                renderServerList()

                if (activeServer == null || serverItems.none { it.serverId == activeServer?.serverId }) {
                    activeServer = chooseAutoServer()
                } else {
                    activeServer = serverItems.firstOrNull { it.serverId == activeServer?.serverId } ?: chooseAutoServer()
                }

                selectedServerId = activeServer?.serverId ?: selectedServerId
                refreshOverview(showToast = showToast)
                refreshInFlight.set(false)
            },
            onFailure = {
                runOnUiThread {
                    activeServer = null
                    availabilityText.text = getString(R.string.availability_fmt, "no_server_available")
                    summaryText.text = getString(R.string.summary_fmt, "No server available")
                    activeServerText.text = getString(R.string.active_server_fmt, "-")
                    loginStateText.text = getString(R.string.login_state_fmt, "-")
                    deviceCodeText.text = getString(R.string.device_code_fmt, "-")
                    loginUrlText.text = getString(R.string.login_url_fmt, "-")
                    serverAdapter.clear()
                    latestLoginUrl = null
                }
                refreshInFlight.set(false)
            },
            toastErrors = showToast,
        )
    }

    private fun parseServers(body: JSONObject): List<ServerItem> {
        val now = System.currentTimeMillis() / 1000
        val items = mutableListOf<ServerItem>()
        val keys = body.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            val obj = body.optJSONObject(key) ?: continue
            val serverUrl = obj.optString("server_url", "").trim().trimEnd('/')
            val apiToken = obj.optString("api_token", "change-me")
            if (serverUrl.isBlank()) continue

            val updatedAt = obj.optLong("updated_at", 0L)
            val isFresh = now - updatedAt <= SERVER_STALE_SECONDS
            val status = obj.optString("status", "offline")
            items += ServerItem(
                serverId = obj.optString("server_id", key),
                serverName = obj.optString("server_name", key),
                serverUrl = serverUrl,
                apiToken = apiToken,
                status = if (isFresh) status else "offline",
                availability = obj.optString("availability", "unknown"),
                summary = obj.optString("summary", "No summary available."),
                updatedAt = updatedAt,
            )
        }
        return items.sortedWith(compareByDescending<ServerItem> { it.isUsable() }.thenByDescending { it.updatedAt })
    }

    private fun chooseAutoServer(): ServerItem? {
        return serverItems.firstOrNull { it.isUsable() } ?: serverItems.firstOrNull()
    }

    private fun renderServerList() {
        val labels = serverItems.map { item ->
            val selected = if (item.serverId == selectedServerId) " [selected]" else ""
            "${item.serverName} | ${item.status} | ${item.serverUrl}$selected"
        }
        runOnUiThread {
            serverAdapter.clear()
            serverAdapter.addAll(labels)
            serverAdapter.notifyDataSetChanged()
        }
    }

    private fun refreshOverview(showToast: Boolean) {
        if (!overviewInFlight.compareAndSet(false, true)) {
            return
        }

        val server = activeServer
        if (server == null) {
            overviewInFlight.set(false)
            runOnUiThread {
                availabilityText.text = getString(R.string.availability_fmt, "no_server_available")
                summaryText.text = getString(R.string.summary_fmt, "No server available")
                activeServerText.text = getString(R.string.active_server_fmt, "-")
            }
            return
        }

        val request = baseRequest(server, "/api/app/overview")
            .get()
            .build()

        executeJson(
            request,
            onSuccess = { body ->
                renderOverview(server, body)
                if (showToast) toast("Connected to ${server.serverName}")
                overviewInFlight.set(false)
            },
            onFailure = {
                runOnUiThread {
                    availabilityText.text = getString(R.string.availability_fmt, "offline")
                    summaryText.text = getString(R.string.summary_fmt, "Selected server is unavailable")
                    activeServerText.text = getString(R.string.active_server_fmt, server.serverName)
                    loginStateText.text = getString(R.string.login_state_fmt, "-")
                    deviceCodeText.text = getString(R.string.device_code_fmt, "-")
                    loginUrlText.text = getString(R.string.login_url_fmt, "-")
                    latestLoginUrl = null
                }
                overviewInFlight.set(false)
            },
            toastErrors = showToast,
        )
    }

    private fun renderOverview(server: ServerItem, body: JSONObject) {
        val loginState = body.optJSONObject("login_state") ?: JSONObject()
        val phase = loginState.optString("phase", "-")
        val message = body.optString("summary", "-")
        val availability = body.optString("availability", "-")
        val deviceCode = loginState.optString("device_code", "-").ifBlank { "-" }
        val loginUrl = loginState.optString("login_url", "-").ifBlank { "-" }

        latestLoginUrl = loginState.optString("login_url", null)

        runOnUiThread {
            activeServerText.text = getString(R.string.active_server_fmt, "${server.serverName} (${server.serverUrl})")
            availabilityText.text = getString(R.string.availability_fmt, availability)
            summaryText.text = getString(R.string.summary_fmt, message)
            loginStateText.text = getString(R.string.login_state_fmt, phase)
            deviceCodeText.text = getString(R.string.device_code_fmt, deviceCode)
            loginUrlText.text = getString(R.string.login_url_fmt, loginUrl)
        }
    }

    private fun startLogin() {
        val server = activeServer ?: return toast("No active server")
        val request = baseRequest(server, "/api/login/start")
            .post("{}".toRequestBody(JSON_MEDIA))
            .build()

        executeJson(request, onSuccess = {
            refreshOverview(showToast = true)
        }, toastErrors = true)
    }

    private fun logout() {
        val server = activeServer ?: return toast("No active server")
        val request = baseRequest(server, "/api/logout")
            .post("{}".toRequestBody(JSON_MEDIA))
            .build()

        executeJson(request, onSuccess = {
            refreshOverview(showToast = true)
        }, toastErrors = true)
    }

    private fun deleteSelectedServer() {
        val serverId = selectedServerId ?: return toast("Select a server first")
        val url = "$FIREBASE_DB_ROOT/$FIREBASE_SERVERS_PATH/$serverId.json"
        val request = Request.Builder()
            .url(url)
            .delete()
            .build()

        executeJson(
            request,
            onSuccess = {
                if (activeServer?.serverId == serverId) {
                    activeServer = null
                }
                selectedServerId = null
                toast("Server deleted from registry")
                refreshServers(showToast = false)
            },
            toastErrors = true,
        )
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

    private fun baseRequest(server: ServerItem, path: String): Request.Builder {
        return Request.Builder()
            .url("${server.serverUrl}$path")
            .header("X-API-Token", server.apiToken)
    }

    private fun executeJson(
        request: Request,
        onSuccess: (JSONObject) -> Unit,
        onFailure: (() -> Unit)? = null,
        toastErrors: Boolean = true,
    ) {
        client.newCall(request).enqueue(object : okhttp3.Callback {
            override fun onFailure(call: okhttp3.Call, e: IOException) {
                onFailure?.invoke()
                if (toastErrors) {
                    runOnUiThread { toast("Request failed: ${e.message}") }
                }
            }

            override fun onResponse(call: okhttp3.Call, response: okhttp3.Response) {
                response.use {
                    if (!response.isSuccessful) {
                        onFailure?.invoke()
                        if (toastErrors) {
                            runOnUiThread { toast("HTTP ${response.code}") }
                        }
                        return
                    }

                    val rawBody = response.body?.string().orEmpty().ifBlank { "{}" }.let {
                        if (it == "null") "{}" else it
                    }
                    try {
                        onSuccess(JSONObject(rawBody))
                    } catch (_: Exception) {
                        onFailure?.invoke()
                        if (toastErrors) {
                            runOnUiThread { toast("Invalid server response") }
                        }
                    }
                }
            }
        })
    }

    private fun toast(message: String) {
        runOnUiThread {
            Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
        }
    }

    data class ServerItem(
        val serverId: String,
        val serverName: String,
        val serverUrl: String,
        val apiToken: String,
        val status: String,
        val availability: String,
        val summary: String,
        val updatedAt: Long,
    ) {
        fun isUsable(): Boolean = status == "online"
    }

    companion object {
        private const val FIREBASE_DB_ROOT = "https://kebun-pintar-dce3e-default-rtdb.firebaseio.com"
        private const val FIREBASE_SERVERS_PATH = "codex_servers"
        private const val FIREBASE_SERVERS_URL = "$FIREBASE_DB_ROOT/$FIREBASE_SERVERS_PATH.json"
        private const val SERVER_STALE_SECONDS = 120L
        private val JSON_MEDIA = "application/json; charset=utf-8".toMediaType()
    }
}
