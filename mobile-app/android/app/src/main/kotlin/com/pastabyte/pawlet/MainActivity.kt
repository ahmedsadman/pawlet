package com.pastabyte.pawlet

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.StandardIntegrityException
import com.google.android.play.core.integrity.StandardIntegrityManager.PrepareIntegrityTokenRequest
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenProvider
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenRequest
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity (not FlutterActivity) is required by local_auth so the
// biometric prompt can attach to a FragmentActivity.
class MainActivity : FlutterFragmentActivity() {
    private val channelName = "pawlet/security"
    private val installChannelName = "pawlet/install"
    private val integrityChannelName = "pawlet/integrity"

    // Debug-only: lets `adb` inject a fake SMS into the Dart pipeline.
    private val debugChannelName = "pawlet/debug"
    private val injectAction = "com.pastabyte.pawlet.INJECT_SMS"
    private var debugChannel: MethodChannel? = null

    // Preparing a provider warms Play's verdict cache and costs a round trip,
    // so a single cached provider is kept and replaced when the project changes
    // or a request fails.
    private var integrityProvider: StandardIntegrityTokenProvider? = null
    private var integrityProviderProject: Long? = null

    // Set by the screen-off receiver; read (and reset) by the app on resume so it
    // can re-lock only when the device was actually locked, not on app-switching.
    @Volatile
    private var screenWasOff = false

    private val screenOffReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Intent.ACTION_SCREEN_OFF) {
                screenWasOff = true
            }
        }
    }

    private val injectReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != injectAction) return
            val sender = intent.getStringExtra("sender") ?: return
            val content = intent.getStringExtra("content") ?: return
            runOnUiThread {
                debugChannel?.invokeMethod(
                    "injectSms",
                    mapOf("sender" to sender, "content" to content),
                )
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        registerReceiver(screenOffReceiver, IntentFilter(Intent.ACTION_SCREEN_OFF))
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumeScreenOff" -> {
                        val wasOff = screenWasOff
                        screenWasOff = false
                        result.success(wasOff)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, installChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installerPackage" -> result.success(installerPackage())
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, integrityChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestToken" -> {
                        val project = call.argument<String>("cloudProjectNumber")?.toLongOrNull()
                        val hash = call.argument<String>("requestHash")
                        if (project == null || hash.isNullOrEmpty()) {
                            result.error("bad_args", "cloudProjectNumber and requestHash are required", null)
                        } else {
                            requestIntegrityToken(project, hash, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        if (BuildConfig.DEBUG) {
            debugChannel = MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                debugChannelName,
            )
            registerReceiver(
                injectReceiver,
                IntentFilter(injectAction),
                Context.RECEIVER_EXPORTED,
            )
        }
    }

    // minSdk is 24, so the API 30 call has to be guarded. Below 30 the
    // deprecated getInstallerPackageName is the only option, and it reports
    // the same value for a Play install.
    @Suppress("DEPRECATION")
    private fun installerPackage(): String? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            packageManager.getInstallSourceInfo(packageName).installingPackageName
        } else {
            packageManager.getInstallerPackageName(packageName)
        }
    } catch (_: PackageManager.NameNotFoundException) {
        null
    }

    private fun requestIntegrityToken(project: Long, hash: String, result: MethodChannel.Result) {
        withIntegrityProvider(project, onError = { reportIntegrityError(it, result) }) { provider ->
            try {
                provider.request(StandardIntegrityTokenRequest.builder().setRequestHash(hash).build())
                    .addOnCompleteListener { task ->
                        if (task.isSuccessful) {
                            result.success(task.result.token())
                        } else if (task.isCanceled) {
                            result.error("cancelled", "Integrity request was cancelled", null)
                        } else {
                            // A provider can go stale (INTEGRITY_TOKEN_PROVIDER_INVALID);
                            // the next call prepares a fresh one.
                            integrityProvider = null
                            reportIntegrityError(task.exception ?: Exception("Unknown error"), result)
                        }
                    }
            } catch (e: Exception) {
                reportIntegrityError(e, result)
            }
        }
    }

    private fun withIntegrityProvider(
        project: Long,
        onError: (Exception) -> Unit,
        use: (StandardIntegrityTokenProvider) -> Unit,
    ) {
        val cached = integrityProvider
        if (cached != null && integrityProviderProject == project) {
            try {
                use(cached)
            } catch (e: Exception) {
                onError(e)
            }
            return
        }
        try {
            IntegrityManagerFactory.createStandard(applicationContext)
                .prepareIntegrityToken(
                    PrepareIntegrityTokenRequest.builder().setCloudProjectNumber(project).build(),
                )
                .addOnCompleteListener { task ->
                    if (task.isSuccessful) {
                        val provider = task.result
                        integrityProvider = provider
                        integrityProviderProject = project
                        try {
                            use(provider)
                        } catch (e: Exception) {
                            onError(e)
                        }
                    } else if (task.isCanceled) {
                        onError(Exception("Prepare cancelled"))
                    } else {
                        onError(task.exception ?: Exception("Unknown prepare error"))
                    }
                }
        } catch (e: Exception) {
            onError(e)
        }
    }

    // The numeric StandardIntegrityErrorCode crosses as the error code string;
    // the Dart side decides which ones are permanent.
    private fun reportIntegrityError(e: Exception, result: MethodChannel.Result) {
        val code = (e as? StandardIntegrityException)?.errorCode?.toString() ?: "unknown"
        result.error(code, e.message, null)
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(screenOffReceiver)
        } catch (_: IllegalArgumentException) {
            // Receiver was never registered (engine not configured); ignore.
        }
        if (BuildConfig.DEBUG) {
            try {
                unregisterReceiver(injectReceiver)
            } catch (_: IllegalArgumentException) {
                // Not registered; ignore.
            }
        }
        super.onDestroy()
    }
}
