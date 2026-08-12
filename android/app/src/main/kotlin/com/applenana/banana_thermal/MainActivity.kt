package com.applenana.banana_thermal

import android.content.Intent
import android.graphics.fonts.SystemFonts
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val updateChannel = "com.applenana.banana_thermal/app_update"
    private val systemFontsChannel = "com.applenana.banana_thermal/system_fonts"
    private var firmwareFlasher: AndroidFirmwareFlasher? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        firmwareFlasher = AndroidFirmwareFlasher(this, flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updateChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "installApk") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                if (path.isNullOrBlank()) {
                    result.error("invalid_path", "更新包路径为空", null)
                    return@setMethodCallHandler
                }
                installApk(path, result)
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, systemFontsChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "listSystemFonts") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    result.success(listSystemFonts())
                } catch (error: Exception) {
                    result.error(
                        "font_enumeration_failed",
                        error.message ?: "无法读取 Android 系统字体",
                        null,
                    )
                }
            }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        firmwareFlasher?.dispose()
        firmwareFlasher = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun installApk(path: String, result: MethodChannel.Result) {
        val apk = File(path)
        if (!apk.exists() || !apk.isFile) {
            result.error("missing_apk", "更新包不存在或已被系统清理", null)
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            val settingsIntent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName")
            )
            startActivity(settingsIntent)
            result.success("permission_required")
            return
        }

        try {
            val uri = FileProvider.getUriForFile(
                this,
                "$packageName.update_files",
                apk
            )
            val installIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(installIntent)
            result.success("launched")
        } catch (error: Exception) {
            result.error("install_failed", error.message ?: "无法打开系统安装器", null)
        }
    }

    private data class SystemFontCandidate(
        val label: String,
        val file: File,
        val score: Int,
    )

    private fun listSystemFonts(): List<Map<String, String>> {
        val candidates = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            listModernSystemFonts()
        } else {
            listLegacySystemFonts()
        }
        return candidates
            .groupBy { it.label.lowercase() }
            .values
            .mapNotNull { family -> family.minByOrNull { it.score } }
            .sortedBy { it.label.lowercase() }
            .map { candidate ->
                mapOf(
                    "label" to candidate.label,
                    "path" to candidate.file.absolutePath,
                )
            }
    }

    @Suppress("NewApi")
    private fun listModernSystemFonts(): List<SystemFontCandidate> {
        return SystemFonts.getAvailableFonts().mapNotNull { font ->
            val file = font.file ?: return@mapNotNull null
            if (!isLoadableFontFile(file)) return@mapNotNull null
            val style = font.style
            val score = kotlin.math.abs(style.weight - 400) + style.slant * 1000
            SystemFontCandidate(fontDisplayName(file), file, score)
        }
    }

    private fun listLegacySystemFonts(): List<SystemFontCandidate> {
        val roots = listOf(
            File("/system/fonts"),
            File("/product/fonts"),
            File("/system/product/fonts"),
            File("/vendor/fonts"),
        )
        return roots.flatMap { root ->
            root.listFiles()?.mapNotNull { file ->
                if (!isLoadableFontFile(file)) return@mapNotNull null
                val name = file.nameWithoutExtension.lowercase()
                val score = when {
                    name.endsWith("regular") -> 0
                    name.endsWith("medium") -> 100
                    name.endsWith("light") -> 200
                    name.endsWith("bold") -> 300
                    else -> 500
                }
                SystemFontCandidate(fontDisplayName(file), file, score)
            } ?: emptyList()
        }
    }

    private fun isLoadableFontFile(file: File): Boolean {
        if (!file.isFile || !file.canRead()) return false
        return file.extension.equals("ttf", ignoreCase = true) ||
            file.extension.equals("otf", ignoreCase = true)
    }

    private fun fontDisplayName(file: File): String {
        val styleSuffix = Regex(
            "(?i)([-_ ]?(thin|extralight|ultralight|light|regular|medium|" +
                "semibold|demibold|bold|extrabold|ultrabold|black|heavy|" +
                "italic|oblique))+$",
        )
        val stripped = file.nameWithoutExtension.replace(styleSuffix, "")
        return stripped.replace('_', ' ').ifBlank { file.nameWithoutExtension }
    }
}
