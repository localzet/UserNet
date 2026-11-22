// SPDX-FileCopyrightText: 2026 Ivan Zorin <creator@localzet.com>
// SPDX-License-Identifier: GPL-3.0-or-later

package com.follow.clashx.plugins

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import com.follow.clashx.common.Components
import org.json.JSONObject
import java.io.BufferedWriter
import java.io.File
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URI
import java.net.URL
import java.util.concurrent.TimeUnit
import java.util.IdentityHashMap
import java.util.UUID

private const val USERNET_CHANNEL = "${Components.PACKAGE_NAME}/usernet_transport"

internal fun createUserNetMethodChannel(
    messenger: BinaryMessenger,
    handler: MethodChannel.MethodCallHandler,
): MethodChannel {
    val taskQueue = messenger.makeBackgroundTaskQueue(
        BinaryMessenger.TaskQueueOptions().setIsSerial(true),
    )
    return MethodChannel(
        messenger,
        USERNET_CHANNEL,
        StandardMethodCodec.INSTANCE,
        taskQueue,
    ).also { it.setMethodCallHandler(handler) }
}

data object UserNetPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private val operationLock = Any()
    private val channels = IdentityHashMap<BinaryMessenger, MethodChannel>()
    private var context: Context? = null
    private var process: Process? = null
    private var writer: BufferedWriter? = null
    private var readerThread: Thread? = null
    private data class Launch(
        val platform: String, val joinLink: String, val socksPort: Int,
        val serviceUserId: String?, val serviceCredential: String?,
        val workPlatform: String, val egressId: String,
    )
    private data class StopResources(
        val writer: BufferedWriter?,
        val process: Process?,
        val reader: Thread?,
    )
    private var recoveryLaunch: Launch? = null
    private var networkManager: ConnectivityManager? = null
    private var physicalNetwork: Network? = null
    private val networkTransition = UserNetNetworkTransition<Network>()
    private var pendingNetworkRestart: Runnable? = null
    private var pendingRelayRestart: Runnable? = null
    private val relayRecoveryPolicy = UserNetRelayRecoveryPolicy()
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) ||
                !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                mainHandler.post { refreshPhysicalNetwork() }
                return
            }
            mainHandler.post {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    handlePhysicalNetwork(network)
                } else {
                    refreshPhysicalNetwork()
                }
            }
        }
        override fun onLost(network: Network) {
            mainHandler.post {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    if (physicalNetwork == network) handlePhysicalNetwork(null)
                } else {
                    refreshPhysicalNetwork(excluded = network)
                }
            }
        }
    }

    @Volatile private var generation = 0L
    private var verificationTicket = 0L
    private var activeStage = "transport"
    private var controlState = "idle"
    private var transportState = "idle"
    private var controlCarrier = ""
    private var transportCarrier = ""
    @Volatile private var lastStatus = "STOPPED"
    private val mainHandler = Handler(Looper.getMainLooper())

    @Synchronized
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        if (networkManager == null) {
            val manager = binding.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            networkManager = manager
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                manager.registerBestMatchingNetworkCallback(request, networkCallback, mainHandler)
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.registerNetworkCallback(request, networkCallback, mainHandler)
            } else {
                manager.registerNetworkCallback(request, networkCallback)
            }
        }
        channels[binding.binaryMessenger] = createUserNetMethodChannel(
            binding.binaryMessenger,
            this,
        )
    }

    private fun selectPhysicalNetwork(excluded: Network? = null): Network? {
        val (manager, current) = synchronized(this) { networkManager to physicalNetwork }
        manager ?: return null
        val eligible = manager.allNetworks.filter { network ->
            if (network == excluded) return@filter false
            val capabilities = manager.getNetworkCapabilities(network)
            capabilities != null &&
                capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) &&
                capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return current?.takeIf { it in eligible }
        }
        return selectLegacyPhysicalNetwork(eligible, manager.activeNetwork, current) { network ->
            val caps = manager.getNetworkCapabilities(network)
            when {
                caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true -> 0
                caps?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true -> 1
                caps?.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH) == true -> 3
                caps?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true -> 4
                else -> 20
            }
        }
    }

    private fun refreshPhysicalNetwork(excluded: Network? = null) {
        handlePhysicalNetwork(selectPhysicalNetwork(excluded))
    }

    @Synchronized
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channels.remove(binding.binaryMessenger)?.setMethodCallHandler(null)
        if (!shouldKeepNetworkObserver(channels.size, recoveryLaunch != null)) {
            releaseNetworkObserver()
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> runCatching {
                val link = requireNotNull(call.argument<String>("joinLink"))
                val platform = call.argument<String>("platform") ?: "wbstream"
                val port = call.argument<Int>("socksPort") ?: 17890
                start(
                    platform = platform,
                    joinLink = link,
                    socksPort = port,
                    serviceUserId = call.argument("serviceUserId"),
                    serviceCredential = call.argument("serviceCredential"),
                    workPlatform = call.argument<String>("workPlatform") ?: "telemost",
                    egressId = call.argument<String>("egressId") ?: "auto",
                )
            }.onSuccess { result.success(null) }
                .onFailure { result.error("USERNET_START", it.message, null) }
            "stop" -> {
                stop()
                result.success(null)
            }
            "isRunning" -> result.success(process?.isAlive == true)
            "getStatus" -> result.success(lastStatus)
            "getConnectionState" -> result.success(synchronized(this) {
                mapOf("status" to lastStatus, "controlState" to controlState,
                    "transportState" to transportState, "controlCarrier" to controlCarrier,
                    "transportCarrier" to transportCarrier)
            })
            "probe" -> probe(result)
            "request" -> request(call, result)
            else -> result.notImplemented()
        }
    }

    @Synchronized
    private fun handlePhysicalNetwork(network: Network?) {
        if (physicalNetwork == network) return
        val recoveryRequested = recoveryLaunch != null
        val relayReady = isRelayReadyForNetworkChange()
        val update = networkTransition.update(network, recoveryRequested, relayReady)
        physicalNetwork = network
        pendingNetworkRestart?.let(mainHandler::removeCallbacks)
        pendingNetworkRestart = null
        if (!update.changed) return
        pendingRelayRestart?.let(mainHandler::removeCallbacks)
        pendingRelayRestart = null
        Log.i("UserNet", if (network == null) "network: unavailable" else "network: changed")
        val expectedGeneration = generation
        val request = synchronized(this) {
            recoveryLaunch ?: return
        }
        if (!update.shouldAnnounceReconnect) return
        emit("status", "RECONNECTING", expectedGeneration)
        if (!update.shouldRestart) return
        lateinit var restart: Runnable
        restart = Runnable {
            Thread {
                synchronized(operationLock) {
                    val isCurrent = synchronized(this) {
                        val current = shouldRunScheduledNetworkRestart(
                            recoveryRequestIsCurrent = recoveryLaunch === request,
                            networkUpdateIsCurrent = networkTransition.isCurrent(update.revision, network),
                            restartIsCurrent = pendingNetworkRestart === restart,
                        )
                        if (current && pendingNetworkRestart === restart) {
                            pendingNetworkRestart = null
                        }
                        current
                    }
                    if (!isCurrent || selectPhysicalNetwork() != network) return@synchronized

                    stopLocked(resetState = false)
                    val targetNetwork = synchronized(this) {
                        if (recoveryLaunch !== request) {
                            null
                        } else {
                            pendingNetworkRestart?.let(mainHandler::removeCallbacks)
                            pendingNetworkRestart = null
                            physicalNetwork
                        }
                    }
                    if (targetNetwork == null || selectPhysicalNetwork() != targetNetwork) {
                        return@synchronized
                    }
                    emit("status", "RECONNECTING")
                    runCatching {
                        startLocked(
                            platform = request.platform,
                            joinLink = request.joinLink,
                            socksPort = request.socksPort,
                            serviceUserId = request.serviceUserId,
                            serviceCredential = request.serviceCredential,
                            workPlatform = request.workPlatform,
                            egressId = request.egressId,
                            stopExisting = false,
                        )
                    }.onFailure { emit("status", "ERROR:NETWORK_RECOVERY") }
                }
            }.apply { name = "UserNet-network-recovery"; isDaemon = true; start() }
        }
        pendingNetworkRestart = restart
        mainHandler.postDelayed(restart, 750)
    }

    @Synchronized
    private fun isRelayReadyForNetworkChange(): Boolean = isUserNetRelayReady(
        processRunning = process?.isAlive == true,
        activeStage = activeStage,
        controlState = controlState,
        transportState = transportState,
    )

    private fun probe(result: MethodChannel.Result) {
        Thread {
            val reachable = runCatching {
                val connection = URL("https://api.userlay.com/app/v1/plans")
                    .openConnection() as HttpURLConnection
                try {
                    connection.requestMethod = "GET"
                    connection.connectTimeout = 3_000
                    connection.readTimeout = 3_000
                    connection.instanceFollowRedirects = false
                    val status = connection.responseCode
                    if (status !in 200..299 && status != 401 && status != 403) {
                        false
                    } else {
                        val stream = if (status in 200..299) connection.inputStream else connection.errorStream
                        val body = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
                        val trimmed = body.trim()
                        if (trimmed.startsWith("{")) {
                            JSONObject(trimmed)
                            true
                        } else if (trimmed.startsWith("[")) {
                            org.json.JSONArray(trimmed)
                            true
                        } else {
                            false
                        }
                    }
                } finally {
                    connection.disconnect()
                }
            }.getOrDefault(false)
            mainHandler.post { result.success(reachable) }
        }.apply {
            name = "UserNet-direct-probe"
            isDaemon = true
            start()
        }
    }

    private fun request(call: MethodCall, result: MethodChannel.Result) {
        val method = call.argument<String>("method") ?: "GET"
        val rawUrl = call.argument<String>("url").orEmpty()
        val headers = call.argument<Map<String, String>>("headers").orEmpty()
        val body = call.argument<String>("body")
        val port = call.argument<Int>("socksPort") ?: 17890
        Thread {
            runCatching {
                require(process?.isAlive == true) { "UserNet carrier is not running" }
                require(method == "GET" || method == "POST") { "Unsupported HTTP method" }
                require(port in 1..65535) { "Invalid SOCKS port" }
                val uri = URI(rawUrl)
                require(
                    uri.scheme == "https" &&
                        uri.host.equals("api.userlay.com", true) &&
                        (uri.port == -1 || uri.port == 443)
                ) {
                    "Only the UserNet API endpoint is allowed"
                }
                val proxy = Proxy(
                    Proxy.Type.SOCKS,
                    InetSocketAddress("127.0.0.1", port),
                )
                val connection = URL(rawUrl).openConnection(proxy) as HttpURLConnection
                try {
                    connection.requestMethod = method
                    connection.connectTimeout = 8_000
                    connection.readTimeout = 12_000
                    connection.instanceFollowRedirects = false
                    headers.forEach(connection::setRequestProperty)
                    if (body != null) {
                        connection.doOutput = true
                        connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                    }
                    val statusCode = connection.responseCode
                    val stream = if (statusCode in 200..399) connection.inputStream else connection.errorStream
                    val responseBody = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
                    mapOf("statusCode" to statusCode, "body" to responseBody)
                } finally {
                    connection.disconnect()
                }
            }.onSuccess { response ->
                mainHandler.post { result.success(response) }
            }.onFailure { error ->
                mainHandler.post { result.error("USERNET_REQUEST", error.message, null) }
            }
        }.apply {
            name = "UserNet-api-request"
            isDaemon = true
            start()
        }
    }

    private fun start(
        platform: String,
        joinLink: String,
        socksPort: Int,
        serviceUserId: String? = null,
        serviceCredential: String? = null,
        workPlatform: String = "telemost",
        egressId: String = "auto",
        preserveRecoveryBudget: Boolean = false,
    ): Unit {
        synchronized(operationLock) {
            startLocked(
                platform = platform,
                joinLink = joinLink,
                socksPort = socksPort,
                serviceUserId = serviceUserId,
                serviceCredential = serviceCredential,
                workPlatform = workPlatform,
                egressId = egressId,
                preserveRecoveryBudget = preserveRecoveryBudget,
            )
        }
    }

    private fun startLocked(
        platform: String,
        joinLink: String,
        socksPort: Int,
        serviceUserId: String? = null,
        serviceCredential: String? = null,
        workPlatform: String = "telemost",
        egressId: String = "auto",
        preserveRecoveryBudget: Boolean = false,
        stopExisting: Boolean = true,
        abortIfNetworkRestartPending: Boolean = false,
    ) {
        require(platform in setOf("wbstream", "telemost", "vk")) { "Unsupported carrier: $platform" }
        require(workPlatform in setOf("wbstream", "telemost", "vk")) { "Unsupported work carrier: $workPlatform" }
        require(joinLink.isNotBlank()) { "joinLink is required" }
        require(socksPort in 1..65535) { "Invalid SOCKS port" }
        val serviceMode = !serviceUserId.isNullOrBlank()
        if (serviceMode) {
            require(!serviceCredential.isNullOrBlank()) { "serviceCredential is required" }
        }
        val request = Launch(platform, joinLink, socksPort, serviceUserId, serviceCredential, workPlatform, egressId)
        if (!preserveRecoveryBudget) synchronized(this) { relayRecoveryPolicy.reset() }
        if (stopExisting && !stopLocked(
                resetState = false,
                replacementLaunch = request,
                abortIfNetworkRestartPending = abortIfNetworkRestartPending,
            )
        ) {
            return
        }
        synchronized(this) {
            recoveryLaunch = request
            activeStage = if (serviceMode) "control" else "transport"
            controlState = if (serviceMode) "connecting" else "idle"
            transportState = if (serviceMode) "idle" else "connecting"
            controlCarrier = if (serviceMode) platform else ""
            transportCarrier = if (serviceMode) workPlatform else platform
        }
        emit("status", "STARTING")
        launchLocked(
            platform = platform,
            joinLink = joinLink,
            socksPort = socksPort,
            serviceUserId = serviceUserId,
            serviceCredential = serviceCredential,
            workPlatform = workPlatform,
            egressId = egressId,
        )
    }

    private fun launchLocked(
        platform: String,
        joinLink: String,
        socksPort: Int,
        serviceUserId: String? = null,
        serviceCredential: String? = null,
        workPlatform: String = "telemost",
        egressId: String = "auto",
    ) {
        val appContext = synchronized(this) {
            checkNotNull(context) { "UserNet plugin is not attached" }
        }
        val relay = File(appContext.applicationInfo.nativeLibraryDir, "libusernetrelay.so")
        check(relay.isFile) { "UserNet relay binary is missing" }
        val args = mutableListOf(
            relay.absolutePath,
            "--mode", "$platform-headless-joiner",
            "--socks-host", "127.0.0.1",
            "--socks-port", socksPort.toString(),
        )
        val serviceMode = !serviceUserId.isNullOrBlank()
        if (serviceMode) {
            args += listOf(
                "--service-control",
                "--service-user-id", serviceUserId,
                "--service-credential", serviceCredential.orEmpty(),
                "--service-work-platform", workPlatform,
                "--service-request-id", UUID.randomUUID().toString(),
                "--service-tunnel-mode", "video",
                "--egress-id", egressId,
            )
        }
        val builder = ProcessBuilder(args).redirectErrorStream(true)
        // Go runs as a Linux executable and needs Android's system CA directories.
        builder.environment()["SSL_CERT_DIR"] =
            "/apex/com.android.conscrypt/cacerts:/system/etc/security/cacerts"
        val proc = builder.start()
        val outputWriter = BufferedWriter(OutputStreamWriter(proc.outputStream))
        val currentGeneration = synchronized(this) {
            process = proc
            writer = outputWriter
            ++generation
        }
        val outputThread = Thread {
            var readFailure: Throwable? = null
            runCatching {
                proc.inputStream.bufferedReader().use { input ->
                    while (true) {
                        val line = input.readLine() ?: break
                        if (currentGeneration != generation) return@Thread
                        when {
                            line == "STATUS:READY" -> {
                                markRelayStable(currentGeneration)
                                sendJoin(platform, joinLink, currentGeneration)
                            }
                            line.startsWith("RESOLVE:") -> resolve(line.removePrefix("RESOLVE:"), currentGeneration)
                            line.startsWith("SERVICE_SESSION_READY:") -> {
                                val session = JSONObject(line.removePrefix("SERVICE_SESSION_READY:"))
                                val workLink = session.getString("joinLink")
                                emit("status", "WORK_SESSION_READY", currentGeneration)
                                if (currentGeneration == generation) {
                                    synchronized(operationLock) {
                                        val canHandoff = synchronized(this) {
                                            currentGeneration == generation && process === proc
                                        }
                                        if (canHandoff) {
                                            stopLocked(resetState = false)
                                            synchronized(this) {
                                                activeStage = "transport"
                                                transportState = "connecting"
                                            }
                                            emit("status", "TRANSPORT_STARTING")
                                            launchLocked(platform = workPlatform, joinLink = workLink, socksPort = socksPort)
                                        }
                                    }
                                }
                                return@Thread
                            }
                            line == "STATUS:TUNNEL_CONNECTED" && serviceMode -> emit("status", "CONTROL_CONNECTED", currentGeneration)
                            line == "STATUS:TUNNEL_CONNECTED" -> verifyTransport(socksPort, currentGeneration)
                            line.startsWith("STATUS:") -> emit("status", line.removePrefix("STATUS:"), currentGeneration)
                            else -> {
                                Log.d("UserNetRelay", line)
                                emit("log", line, currentGeneration)
                            }
                        }
                    }
                }
            }.onFailure { error ->
                readFailure = error
            }
            handleRelayExit(proc, currentGeneration, readFailure)
        }.also {
            it.name = "UserNet-relay-output"
        }
        synchronized(this) { readerThread = outputThread }
        outputThread.start()
    }

    private fun handleRelayExit(
        exitedProcess: Process,
        expectedGeneration: Long,
        readFailure: Throwable?,
    ) {
        val isCurrent = synchronized(this) {
            expectedGeneration == generation && process === exitedProcess
        }
        if (readFailure != null && isCurrent) {
            Log.e("UserNet", "relay output failed", readFailure)
        }

        val shouldRetry = synchronized(this) {
            shouldRetryUnexpectedRelayExit(
                generationIsCurrent = expectedGeneration == generation,
                processIsCurrent = process === exitedProcess,
                recoveryRequested = recoveryLaunch != null,
                terminalError = lastStatus.startsWith("ERROR:"),
                physicalNetworkAvailable = physicalNetwork != null,
                networkRestartPending = pendingNetworkRestart != null,
            )
        }
        if (shouldRetry) {
            if (exitedProcess.isAlive) exitedProcess.destroy()
            scheduleRelayRestart(exitedProcess, expectedGeneration)
            return
        }

        val waitingForNetwork = synchronized(this) {
            expectedGeneration == generation && process === exitedProcess &&
                    recoveryLaunch != null && !lastStatus.startsWith("ERROR:")
        }
        if (waitingForNetwork) {
            emit("status", "RECONNECTING", expectedGeneration)
        } else if (isCurrent && !lastStatus.startsWith("ERROR:")) {
            emit("status", "STOPPED", expectedGeneration)
        }
    }

    private fun scheduleRelayRestart(exitedProcess: Process, expectedGeneration: Long) {
        var retryExhausted = false
        synchronized(this) {
            if (!shouldRetryUnexpectedRelayExit(
                    generationIsCurrent = expectedGeneration == generation,
                    processIsCurrent = process === exitedProcess,
                    recoveryRequested = recoveryLaunch != null,
                    terminalError = lastStatus.startsWith("ERROR:"),
                    physicalNetworkAvailable = physicalNetwork != null,
                    networkRestartPending = pendingNetworkRestart != null,
                )
            ) {
                return
            }

            val request = recoveryLaunch ?: return
            val network = physicalNetwork ?: return
            val delayMillis = relayRecoveryPolicy.nextDelayMillis(SystemClock.elapsedRealtime())
            if (delayMillis == null) {
                retryExhausted = true
            } else {
                lateinit var restart: Runnable
                restart = Runnable {
                    Thread {
                        runRelayRestartIfCurrent(
                            lock = this,
                            operationLock = operationLock,
                            isCurrent = {
                                shouldRunScheduledRelayRestart(
                                    generationIsCurrent = expectedGeneration == generation,
                                    processIsCurrent = process === exitedProcess,
                                    recoveryRequested = recoveryLaunch === request,
                                    restartIsCurrent = pendingRelayRestart === restart,
                                    terminalError = lastStatus.startsWith("ERROR:"),
                                    physicalNetworkAvailable = physicalNetwork != null,
                                    networkIsCurrent = physicalNetwork == network,
                                    networkRestartPending = pendingNetworkRestart != null,
                                )
                            },
                            restart = {
                                synchronized(this) { pendingRelayRestart = null }
                                runCatching {
                                    startLocked(
                                        platform = request.platform,
                                        joinLink = request.joinLink,
                                        socksPort = request.socksPort,
                                        serviceUserId = request.serviceUserId,
                                        serviceCredential = request.serviceCredential,
                                        workPlatform = request.workPlatform,
                                        egressId = request.egressId,
                                        preserveRecoveryBudget = true,
                                        abortIfNetworkRestartPending = true,
                                    )
                                }.onFailure { error ->
                                    Log.e("UserNet", "relay restart failed", error)
                                    emit("status", "ERROR:RELAY_RESTART", generation)
                                }
                            },
                        )
                    }.apply {
                        name = "UserNet-relay-restart"
                        isDaemon = true
                        start()
                    }
                }
                pendingRelayRestart = restart
                mainHandler.postDelayed(restart, delayMillis)
            }
        }

        if (retryExhausted) {
            emit("status", "ERROR:RELAY_EXIT", expectedGeneration)
        } else {
            emit("status", "RECONNECTING", expectedGeneration)
        }
    }

    private fun emit(method: String, value: String, expectedGeneration: Long? = null) {
        val emissionGeneration = synchronized(this) {
            if (expectedGeneration != null && expectedGeneration != generation) return
            if (method == "status") updateStatus(value, generation)
            generation
        }
        mainHandler.post {
            val activeChannels = synchronized(this) {
                if (emissionGeneration != generation) return@post
                channels.values.toList()
            }
            activeChannels.forEach { it.invokeMethod(method, value) }
        }
    }

    @Synchronized
    private fun updateStatus(value: String, expectedGeneration: Long) {
        when {
            value == "CONTROL_CONNECTED" -> {
                controlState = "connected"
                markRelayStable(expectedGeneration)
            }
            value == "WORK_SESSION_READY" -> {
                controlState = "complete"
                transportState = "connecting"
            }
            value == "TUNNEL_CONNECTED" -> {
                transportState = "connected"
                markRelayStable(expectedGeneration)
            }
            value == "TRANSPORT_VERIFYING" -> transportState = "connecting"
            value == "TUNNEL_LOST" || value == "RECONNECTING" || value == "CONNECTING" -> {
                verificationTicket++
                if (activeStage == "control") controlState = "connecting" else transportState = "connecting"
            }
            value.startsWith("ERROR:") -> {
                if (activeStage == "control") controlState = "failed" else transportState = "failed"
            }
            value == "STOPPED" -> {
                if (activeStage == "control" && controlState != "complete") controlState = "idle"
                transportState = "idle"
            }
        }
        lastStatus = value
        Log.i("UserNet", "status: $value")
    }

    private fun markRelayStable(expectedGeneration: Long) {
        synchronized(this) {
            if (!markRelayReadyIfCurrent(
                    relayRecoveryPolicy,
                    expectedGeneration,
                    generation,
                    SystemClock.elapsedRealtime(),
                )
            ) return
            pendingRelayRestart?.let(mainHandler::removeCallbacks)
            pendingRelayRestart = null
        }
    }

    private fun verifyTransport(port: Int, expectedGeneration: Long) {
        val ticket = synchronized(this) {
            if (expectedGeneration != generation) return
            verificationTicket++
            emit("status", "TRANSPORT_VERIFYING", expectedGeneration)
            verificationTicket
        }
        Thread {
            repeat(3) {
                if (expectedGeneration != generation || process?.isAlive != true) return@Thread
                val connected = runCatching {
                    val proxy = Proxy(Proxy.Type.SOCKS, InetSocketAddress("127.0.0.1", port))
                    val connection = URL("https://api.userlay.com/app/v1/account")
                        .openConnection(proxy) as HttpURLConnection
                    try {
                        connection.connectTimeout = 3_000
                        connection.readTimeout = 5_000
                        connection.instanceFollowRedirects = false
                        connection.setRequestProperty("Accept", "application/json")
                        val code = connection.responseCode
                        val stream = if (code in 200..299) connection.inputStream else connection.errorStream
                        val body = stream?.bufferedReader()?.use { it.readText() }.orEmpty()
                        if (code !in 200..299 && code != 401 && code != 403) {
                            Log.w("UserNet", "transport verification: HTTP $code")
                        }
                        (code in 200..299 || code == 401 || code == 403) &&
                            runCatching { JSONObject(body) }.isSuccess
                    } finally {
                        connection.disconnect()
                    }
                }.getOrDefault(false)
                synchronized(this) {
                    if (expectedGeneration != generation || ticket != verificationTicket || process?.isAlive != true) return@Thread
                    if (connected) {
                        emit("status", "TUNNEL_CONNECTED", expectedGeneration)
                        return@Thread
                    }
                }
                Thread.sleep(500)
            }
            synchronized(this) {
                if (expectedGeneration == generation && ticket == verificationTicket && process?.isAlive == true) {
                    emit("status", "ERROR:TRANSPORT_UNREACHABLE", expectedGeneration)
                }
            }
        }.apply {
            name = "UserNet-transport-verification"
            isDaemon = true
            start()
        }
    }

    private fun sendJoin(platform: String, link: String, expectedGeneration: Long) {
        val publicLink = link.substringBefore('#')
        val roomId = when {
            publicLink.startsWith("wbstream://") -> publicLink.removePrefix("wbstream://").trim('/')
            else -> publicLink.substringAfterLast('/').trim('/')
        }
        val payload = JSONObject().apply {
            if (platform == "wbstream") put("roomId", roomId) else put("joinLink", publicLink)
            link.substringAfter("#key=", "").takeIf { it.isNotBlank() }?.let {
                put("tunnelKey", it.substringBefore('&'))
            }
            put("displayName", "UserNet")
            put("tunnelMode", "video")
            put("vp8Fps", 24)
			put("vp8Batch", 30)
			put("dualTrack", false)
			put("reliable", platform == "telemost")
		}
        writeLine("${if (platform == "vk") "AUTH" else "JOIN"}:$payload", expectedGeneration)
    }

    private fun resolve(hostname: String, expectedGeneration: Long) {
        val addresses = resolveOnPhysicalNetwork(
            selectNetwork = { selectPhysicalNetwork() },
            lookup = { network -> network.getAllByName(hostname).toList() },
        )
        val selected = addresses.firstOrNull { it is Inet4Address } ?: addresses.firstOrNull()
        writeLine(selected?.hostAddress.orEmpty(), expectedGeneration)
    }

    @Synchronized
    private fun writeLine(value: String, expectedGeneration: Long) {
        if (expectedGeneration != generation) return
        runCatching {
            writer?.write(value)
            writer?.newLine()
            writer?.flush()
        }.onFailure { Log.e("UserNet", "relay stdin failed", it) }
    }

    private fun stop(resetState: Boolean = true): Unit {
        synchronized(operationLock) {
            stopLocked(resetState)
        }
    }

    private fun stopLocked(
        resetState: Boolean = true,
        replacementLaunch: Launch? = null,
        abortIfNetworkRestartPending: Boolean = false,
    ): Boolean {
        val resources = runUnlessNetworkRestartPending(
            lock = this,
            networkRestartPending = { abortIfNetworkRestartPending && pendingNetworkRestart != null },
        ) {
            generation++
            pendingNetworkRestart?.let(mainHandler::removeCallbacks)
            pendingNetworkRestart = null
            pendingRelayRestart?.let(mainHandler::removeCallbacks)
            pendingRelayRestart = null
            if (resetState) {
                recoveryLaunch = null
                relayRecoveryPolicy.reset()
                controlState = "idle"
                transportState = "idle"
                controlCarrier = ""
                transportCarrier = ""
            } else if (replacementLaunch != null) {
                recoveryLaunch = replacementLaunch
            }
            val writerToClose = writer
            val processToStop = process
            val readerToInterrupt = readerThread
            writer = null
            process = null
            readerThread = null
            if (!shouldKeepNetworkObserver(channels.size, recoveryLaunch != null)) {
                unregisterNetworkObserver(takeNetworkObserverLocked())
            }
            StopResources(writerToClose, processToStop, readerToInterrupt)
        } ?: return false

        if (resetState) emit("status", "STOPPED")
        runCatching {
            resources.writer?.write("STOP")
            resources.writer?.newLine()
            resources.writer?.flush()
        }
        runCatching { resources.writer?.close() }
        if (resources.process != null && !resources.process.waitFor(2_000, TimeUnit.MILLISECONDS)) {
            resources.process.destroy()
        }
        if (resources.process != null && resources.process.isAlive &&
            !resources.process.waitFor(500, TimeUnit.MILLISECONDS)
        ) {
            resources.process.destroyForcibly()
        }
        resources.reader?.interrupt()
        return true
    }

    private fun releaseNetworkObserver() {
        synchronized(this) {
            unregisterNetworkObserver(takeNetworkObserverLocked())
        }
    }

    private fun takeNetworkObserverLocked(): ConnectivityManager? {
        pendingNetworkRestart?.let(mainHandler::removeCallbacks)
        pendingNetworkRestart = null
        pendingRelayRestart?.let(mainHandler::removeCallbacks)
        pendingRelayRestart = null
        val manager = networkManager
        networkManager = null
        physicalNetwork = null
        networkTransition.reset()
        return manager
    }

    private fun unregisterNetworkObserver(manager: ConnectivityManager?) {
        manager?.let {
            runCatching { it.unregisterNetworkCallback(networkCallback) }
                .onFailure { Log.w("UserNet", "network observer release failed") }
        }
    }
}
