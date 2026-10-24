package com.carelink.carelink_admin

import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity is required by local_auth (biometric prompt). The "carelink/secure_screen" channel toggles
// FLAG_SECURE so clinical screens cannot be screenshotted, screen-recorded or shown in the recent-apps thumbnail.
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "carelink/secure_screen").setMethodCallHandler { call, result ->
            if (call.method == "setSecure") {
                val secure = call.argument<Boolean>("secure") ?: true
                runOnUiThread {
                    if (secure) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE) else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }
}
