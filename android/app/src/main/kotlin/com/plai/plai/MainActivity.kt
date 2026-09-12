package com.plai.plai

import android.app.AppOpsManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.os.Process
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "plai/app_update")
            .setMethodCallHandler { call, result ->
                if (call.method != "installApk") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                val apk = path?.let(::File)
                if (apk == null || !apk.isFile || !apk.name.endsWith(".apk", ignoreCase = true)) {
                    result.error("invalid_apk", "更新包不可用。", null)
                    return@setMethodCallHandler
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                    !packageManager.canRequestPackageInstalls()
                ) {
                    startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:$packageName"),
                        ),
                    )
                    result.success("permissionRequired")
                    return@setMethodCallHandler
                }
                val uri = FileProvider.getUriForFile(
                    this,
                    "$packageName.fileprovider",
                    apk,
                )
                startActivity(
                    Intent(Intent.ACTION_VIEW)
                        .setDataAndType(uri, "application/vnd.android.package-archive")
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                result.success("installerOpened")
            }

        // 「提醒保护」页的检测与跳转通道（plai-notify 拥有）。单通道四方法，
        // 与上面 plai/app_update 同风格（inline 注册 + 方法守卫）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "plai/keep_alive")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getManufacturer" -> result.success(Build.MANUFACTURER ?: "")
                    "checkBatteryOptimization" -> result.success(isIgnoringBatteryOptimizations())
                    "checkAutoStart" -> result.success(checkAutoStart())
                    "openSettings" -> {
                        val target = call.argument<String>("target") ?: "appDetails"
                        result.success(if (openSettings(target)) "opened" else "failed")
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// 电池优化是否已豁免（`PowerManager.isIgnoringBatteryOptimizations` 是标准
    /// API，结果准确）。查询失败时按「未豁免」处理，引导用户去设置看一眼。
    private fun isIgnoringBatteryOptimizations(): Boolean {
        return try {
            val power = getSystemService(Context.POWER_SERVICE) as? PowerManager
            power?.isIgnoringBatteryOptimizations(packageName) ?: false
        } catch (_: Throwable) {
            false
        }
    }

    /// 自动启动是否已开启。返回 `"allowed"` / `"denied"` / `"unknown"`。
    ///
    /// ⚠️ 「自启动」在 Android 上没有标准 API：社区做法是反射 MIUI 私有 AppOps
    /// op，而候选值（字段 `OP_BACKGROUND_START_ACTIVITY`、字面量 10008 / 10021）
    /// 互不一致、随 MIUI 版本漂移，且部分版本的隐藏 API 反射会被系统拦截。
    /// 因此这里只在**能确定**时才给结论：
    /// - 任一候选 op 明确返回 `MODE_ALLOWED` → `"allowed"`；
    /// - 全部候选都查得到且无一 allowed、但有明确 `MODE_IGNORED` / `MODE_ERRORED`
    ///   → `"denied"`；
    /// - 其余（查询失败、反射被拦、`MODE_DEFAULT` 等语义不明）→ `"unknown"`。
    ///
    /// **绝不放宽判断去凑一个答案**：误报「已开启」比不检测更糟 —— 用户以为
    /// 搞定了，提醒照样不响。
    private fun checkAutoStart(): String {
        return try {
            val appOps = getSystemService(Context.APP_OPS_SERVICE) as? AppOpsManager
                ?: return "unknown"
            var sawAllowed = false
            var sawDenied = false
            var sawQueryable = false
            for (op in backgroundStartOpCandidates()) {
                val mode = queryOpMode(appOps, op) ?: continue
                sawQueryable = true
                when (mode) {
                    AppOpsManager.MODE_ALLOWED -> sawAllowed = true
                    AppOpsManager.MODE_IGNORED, AppOpsManager.MODE_ERRORED -> sawDenied = true
                }
            }
            when {
                sawAllowed -> "allowed"
                sawQueryable && sawDenied -> "denied"
                else -> "unknown"
            }
        } catch (_: Throwable) {
            "unknown"
        }
    }

    /// 「后台启动」AppOps op 的候选值：先试反射字段名，再退常见字面量。
    private fun backgroundStartOpCandidates(): List<Int> {
        val candidates = mutableListOf<Int>()
        for (name in arrayOf("OP_BACKGROUND_START_ACTIVITY", "OP_AUTO_START")) {
            try {
                candidates.add(AppOpsManager::class.java.getField(name).getInt(null))
            } catch (_: Throwable) {
                // 本 ROM 无该字段，试下一个。
            }
        }
        // 社区常见的 MIUI 私有 op 字面量（互不一致，可能都不对）。
        candidates.add(10008)
        candidates.add(10021)
        return candidates
    }

    /// 用反射调用 `checkOpNoThrow(int, int, String)` 查询 op 当前模式。
    ///
    /// 取不到（方法不存在 / 隐藏 API 反射被拦 / 不是 Int）返回 null。
    private fun queryOpMode(appOps: AppOpsManager, op: Int): Int? {
        val uid = Process.myUid()
        for (name in arrayOf("checkOpNoThrow", "unsafeCheckOpNoThrow")) {
            try {
                val method = AppOpsManager::class.java.getMethod(
                    name,
                    Integer.TYPE,
                    Integer.TYPE,
                    String::class.java,
                )
                val value = method.invoke(appOps, op, uid, packageName)
                if (value is Int) return value
            } catch (_: Throwable) {
                // 方法签名在本 ROM 不存在，试下一个。
            }
        }
        return null
    }

    /// 按 target 打开对应系统设置页；任何异常都不许崩，失败返回 false。
    private fun openSettings(target: String): Boolean {
        var intent: Intent? = when (target) {
            "notification" -> Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            "exactAlarm" -> Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                .setData(Uri.parse("package:$packageName"))
            "battery" -> Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                .setData(Uri.parse("package:$packageName"))
            "autostart" -> resolveAutoStartIntent()
            else -> null
        }
        // 未识别 target / 本机无自启动入口 → 应用详情页（总有落点）。
        if (intent == null) intent = appDetailsIntent()
        return try {
            startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (_: Throwable) {
            // 电池优化直弹授权框在部分 ROM 会被拒；回退到电池优化列表页。
            if (target == "battery") {
                try {
                    startActivity(
                        Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    return true
                } catch (_: Throwable) {
                    // 落到下面的 false。
                }
            }
            false
        }
    }

    private fun appDetailsIntent(): Intent =
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            .setData(Uri.parse("package:$packageName"))

    /// 逐个尝试厂商自启动管理页；本机都没有则回 null（调用方回退应用详情页）。
    ///
    /// Android 11+ 需在 Manifest 的 `<queries>` 声明这些包名，否则 `resolveActivity`
    /// 恒为 null、跳转全盘失效。
    private fun resolveAutoStartIntent(): Intent? {
        val candidates = listOf(
            // 小米 / 红米
            ComponentName(
                "com.miui.securitycenter",
                "com.miui.permcenter.autostart.AutoStartManagementActivity",
            ),
            // 华为
            ComponentName(
                "com.huawei.systemmanager",
                "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            ),
            // 荣耀
            ComponentName(
                "com.hihonor.systemmanager",
                "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            ),
            // OPPO / 一加 / realme
            ComponentName(
                "com.coloros.safecenter",
                "com.coloros.safecenter.permission.startup.StartupAppListActivity",
            ),
            ComponentName(
                "com.oppo.safe",
                "com.oppo.safe.permission.startup.StartupAppListActivity",
            ),
            // vivo / iQOO
            ComponentName(
                "com.vivo.permissionmanager",
                "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
            ),
        )
        for (component in candidates) {
            val intent = Intent().setComponent(component)
            if (intent.resolveActivity(packageManager) != null) return intent
        }
        return null
    }
}
