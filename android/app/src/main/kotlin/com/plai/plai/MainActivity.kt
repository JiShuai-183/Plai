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
    /// ⚠️ 「自启动」在 Android 上**没有任何标准 API**：只能反射 MIUI 私有 AppOps
    /// op，而隐藏 API 反射常常被系统拦截。**因此本方法在结构上很可能只返回
    /// `"unknown"`** —— 这是刻意的降级，不是 bug。三态语义严格如下：
    ///
    /// - `"allowed"`：可信 op 明确返回 `MODE_ALLOWED`。
    /// - `"denied"`：可信 op 明确返回 `MODE_IGNORED`。
    ///   —— `denied` **只可能来自语义明确的可信 op**，别无来源。
    /// - `"unknown"`：其余**一切**情况（拿不到字段 / 反射被隐藏 API 策略拦 /
    ///   查询抛异常 / `MODE_DEFAULT` / `MODE_ERRORED`）。
    ///
    /// 三条反直觉但必要的决定，改动前务必读懂：
    ///
    /// 1. **`MODE_ERRORED`（2）不算 `denied`**。它的语义是「这次查询本身有问题」
    ///    （op 不存在 / 无权限 / 查询出错），**不是「用户关闭了」**。真正的
    ///    「用户关闭」只有 `MODE_IGNORED`（1）。早期实现把 `MODE_ERRORED` 也当
    ///    `denied`，于是「用一个未经验证的 op 值去查 → 系统回 MODE_ERRORED →
    ///    判为未开启」，正是真机上「明明开了却报未开启」的假 negative 来源。
    ///
    /// 2. **删掉了社区流传的字面量候选（10008 / 10021）**。它们是**猜的** op，
    ///    语义未经证实；用未知 op 得到的任何 mode 都没有解释力，且真机已证明
    ///    会产生假 `denied`（用户看到 App 说没开、实际开了，直接摧毁信任）。
    ///    **宁可不检测（unknown），也不给错答案。**
    ///
    /// 3. **可信组尽力找，找不到就认**。`trustedBackgroundStartOps()` 同时试
    ///    `getField` 与 `getDeclaredField`（后者配 `setAccessible(true)`）——后者
    ///    能碰隐藏字段，但 Android 隐藏 API 黑名单仍可能拦截。拦住了就老实返回
    ///    `unknown`，**绝不放宽判断去凑一个答案**。
    private fun checkAutoStart(): String {
        return try {
            val appOps = getSystemService(Context.APP_OPS_SERVICE) as? AppOpsManager
                ?: return "unknown"
            var trustedAllowed = false
            var trustedDenied = false

            for (op in trustedBackgroundStartOps()) {
                val mode = queryOpMode(appOps, op) ?: continue
                when (mode) {
                    AppOpsManager.MODE_ALLOWED -> trustedAllowed = true
                    AppOpsManager.MODE_IGNORED -> trustedDenied = true
                    // MODE_DEFAULT / MODE_ERRORED / 其它：语义不明或查询出错，
                    // 跳过 —— 不据此下任何结论（见上方注释 1）。
                    else -> {
                    }
                }
            }

            when {
                trustedAllowed -> "allowed"
                trustedDenied -> "denied"
                else -> "unknown"
            }
        } catch (_: Throwable) {
            "unknown"
        }
    }

    /// 可信候选：反射字段名（语义明确，才可产生 allowed / denied）。
    ///
    /// 先试公有 `getField`，再试 `getDeclaredField`（可命中隐藏字段，需
    /// `setAccessible(true)`）。Android 的隐藏 API 策略可能让两者都抛异常 ——
    /// 那就返回空列表，调用方据此降级为 `unknown`。
    private fun trustedBackgroundStartOps(): List<Int> {
        val candidates = mutableListOf<Int>()
        for (name in arrayOf("OP_BACKGROUND_START_ACTIVITY", "OP_AUTO_START")) {
            try {
                candidates.add(AppOpsManager::class.java.getField(name).getInt(null))
                continue
            } catch (_: Throwable) {
                // 公有字段取不到，试隐藏字段。
            }
            try {
                val field = AppOpsManager::class.java.getDeclaredField(name)
                field.isAccessible = true
                candidates.add(field.getInt(null))
            } catch (_: Throwable) {
                // 本 ROM 无该字段或隐藏 API 被拦，试下一个名字。
            }
        }
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
