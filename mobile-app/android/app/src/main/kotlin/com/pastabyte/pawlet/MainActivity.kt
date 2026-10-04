package com.pastabyte.pawlet

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity (not FlutterActivity) is required by local_auth so the
// biometric prompt can attach to a FragmentActivity.
class MainActivity : FlutterFragmentActivity() {
    private val channelName = "pawlet/security"
    private val installChannelName = "pawlet/install"

    // Debug-only: lets `adb` inject a fake SMS into the Dart pipeline.
    private val debugChannelName = "pawlet/debug"
    private val injectAction = "com.pastabyte.pawlet.INJECT_SMS"
    private var debugChannel: MethodChannel? = null

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
