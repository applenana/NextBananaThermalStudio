package com.applenana.banana_thermal

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/**
 * RP2040 BOOTSEL flasher for Android USB Host.
 *
 * The RP2040 presents a virtual FAT16 disk. Android does not expose a public
 * file-copy API for arbitrary USB mass-storage devices, and common Android USB
 * file-system libraries only implement FAT32. This bridge therefore talks the
 * standard USB Mass Storage Bulk-Only Transport / SCSI protocol directly.
 *
 * It is intentionally restricted to the official RP2040 BOOTSEL VID/PID and
 * validates INFO_UF2.TXT plus every UF2 block before issuing the first write.
 * Device-family approval remains in Dart and is completed while the exact
 * serial device is still connected.
 */
class AndroidFirmwareFlasher(
    private val activity: MainActivity,
    flutterEngine: FlutterEngine,
) {
    companion object {
        const val CHANNEL_NAME = "com.applenana.banana_thermal/firmware_update"

        private const val RP2040_VENDOR_ID = 0x2E8A
        private const val RP2040_BOOTSEL_PRODUCT_ID = 0x0003
        private const val USB_MASS_STORAGE_CLASS = 8
        private const val SCSI_TRANSPARENT_SUBCLASS = 6
        private const val BULK_ONLY_PROTOCOL = 0x50

        private const val UF2_BLOCK_SIZE = 512
        private const val UF2_MAGIC_START0 = 0x0A324655
        private const val UF2_MAGIC_START1 = 0x9E5D5157.toInt()
        private const val UF2_MAGIC_END = 0x0AB16F30
        private const val UF2_FLAG_NOT_MAIN_FLASH = 0x00000001
        private const val UF2_FLAG_FAMILY_ID_PRESENT = 0x00002000
        private const val UF2_RP2040_FAMILY_ID = 0xE48BFF56.toInt()
        private const val RP2040_XIP_BASE = 0x10000000L
        private const val RP2040_XIP_END = 0x11000000L

        private const val DEFAULT_TIMEOUT_MS = 50_000L
        private const val PERMISSION_TIMEOUT_MS = 30_000L
        private const val IO_TIMEOUT_MS = 5_000
        private const val WRITE_SECTORS_PER_COMMAND = 32
        private const val MAX_UF2_BYTES = 64L * 1024L * 1024L
    }

    private val channel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        CHANNEL_NAME,
    )
    private val usbManager = activity.getSystemService(Context.USB_SERVICE) as UsbManager
    private val worker = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "rp2040-uf2-flasher").apply { isDaemon = true }
    }
    private val active = AtomicBoolean(false)
    private val permissionRequestCode = AtomicInteger(0x4254)

    init {
        channel.setMethodCallHandler(::handleMethodCall)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        worker.shutdownNow()
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "listBootloaderIds" -> result.success(findBootloaderCandidates().map { it.stableId })
            "inspectUsbState" -> result.success(inspectUsbState())
            "requestBootloaderPermission" -> startPermissionRequest(call, result)
            "flashUf2" -> startFlash(call, result)
            else -> result.notImplemented()
        }
    }

    private fun inspectUsbState(): Map<String, Any> {
        val candidates = findBootloaderCandidates()
        return mapOf(
            "usbHostSupported" to activity.packageManager.hasSystemFeature(
                PackageManager.FEATURE_USB_HOST,
            ),
            "bootloaders" to candidates.map {
                it.toChannelMap(usbManager.hasPermission(it.device))
            },
        )
    }

    private fun startPermissionRequest(call: MethodCall, result: MethodChannel.Result) {
        if (!active.compareAndSet(false, true)) {
            result.error("flash_busy", "已有 Android 固件操作正在进行", null)
            return
        }
        val requestedId = call.argument<String>("deviceId")
        worker.execute {
            try {
                val candidates = findBootloaderCandidates()
                val candidate = when {
                    requestedId != null -> candidates.singleOrNull { it.stableId == requestedId }
                        ?: throw FlashException(
                            "bootloader_detached",
                            "选中的 RP2040 Bootloader 已断开或设备数量发生变化",
                        )
                    candidates.size == 1 -> candidates.single()
                    candidates.isEmpty() -> throw FlashException(
                        "bootloader_missing",
                        "未检测到 RP2040 Bootloader USB 磁盘",
                    )
                    else -> throw FlashException(
                        "multiple_bootloaders",
                        "检测到多个 RP2040 Bootloader，请只保留待烧录设备",
                    )
                }
                requireUsbPermission(candidate.device)
                val fresh = findBootloaderCandidates().singleOrNull {
                    it.stableId == candidate.stableId
                } ?: throw FlashException(
                    "bootloader_detached",
                    "USB 授权完成后 RP2040 Bootloader 已断开",
                )
                if (!usbManager.hasPermission(fresh.device)) {
                    throw FlashException("usb_permission_denied", "系统没有授予 USB 磁盘访问权限")
                }
                completeSuccess(
                    result,
                    fresh.toChannelMap(usbManager.hasPermission(fresh.device)),
                )
            } catch (error: FlashException) {
                completeError(result, error.code, error.message ?: "USB 授权失败")
            } catch (error: Exception) {
                completeError(result, "usb_permission", error.message ?: "USB 授权失败")
            } finally {
                active.set(false)
            }
        }
    }

    private fun startFlash(call: MethodCall, result: MethodChannel.Result) {
        if (!active.compareAndSet(false, true)) {
            result.error("flash_busy", "已有 Android 固件烧录任务正在进行", null)
            return
        }

        val path = call.argument<String>("path")
        val expectedSha256 = call.argument<String>("expectedSha256")
        val displayName = call.argument<String>("destinationName")
        val timeoutMs = (call.argument<Number>("timeoutMs")?.toLong()
            ?: DEFAULT_TIMEOUT_MS).coerceIn(5_000L, 120_000L)
        if (path.isNullOrBlank() || expectedSha256.isNullOrBlank() || displayName.isNullOrBlank()) {
            active.set(false)
            result.error("invalid_arguments", "缺少 Android 固件烧录参数", null)
            return
        }

        worker.execute {
            try {
                val file = validatePrivateFile(path)
                val metadata = validateUf2(file, expectedSha256)
                emitProgress(0.0, "UF2 结构已校验，等待 RP2040 Bootloader…")
                val candidate = waitForSingleBootloader(timeoutMs)
                emitProgress(0.0, "检测到 RP2040 Bootloader，等待 USB 授权…")
                requireUsbPermission(candidate.device)

                val fresh = findBootloaderCandidates()
                    .firstOrNull { it.device.deviceName == candidate.device.deviceName }
                    ?: throw FlashException(
                        "bootloader_detached",
                        "USB 授权完成前 RP2040 Bootloader 已断开，请重试",
                    )
                flashValidatedUf2(fresh, file, metadata, displayName)
                completeSuccess(
                    result,
                    mapOf(
                        "deviceId" to fresh.stableId,
                        "blocks" to metadata.blockCount,
                        "bytes" to metadata.fileBytes,
                    ),
                )
            } catch (error: FlashException) {
                completeError(result, error.code, error.message ?: "Android 固件烧录失败")
            } catch (error: SecurityException) {
                completeError(result, "usb_permission", "USB 权限不足：${error.message ?: "用户未授权"}")
            } catch (error: InterruptedException) {
                Thread.currentThread().interrupt()
                completeError(result, "flash_interrupted", "Android 固件烧录已中断")
            } catch (error: Exception) {
                completeError(result, "flash_failed", error.message ?: "Android 固件烧录失败")
            } finally {
                active.set(false)
            }
        }
    }

    private fun validatePrivateFile(path: String): File {
        val file = File(path).canonicalFile
        val dataRoot = File(activity.applicationInfo.dataDir).canonicalFile
        val prefix = dataRoot.path + File.separator
        if (!file.path.startsWith(prefix) || !file.isFile) {
            throw FlashException("invalid_path", "固件文件不在应用私有目录或已经被清理")
        }
        if (!file.name.lowercase(Locale.ROOT).endsWith(".uf2")) {
            throw FlashException("invalid_file", "固件文件扩展名不是 .uf2")
        }
        return file
    }

    private fun validateUf2(file: File, expectedSha256: String): Uf2Metadata {
        val length = file.length()
        if (length <= 0 || length > MAX_UF2_BYTES || length % UF2_BLOCK_SIZE != 0L) {
            throw FlashException("invalid_uf2", "UF2 文件大小无效")
        }
        val normalizedDigest = expectedSha256.lowercase(Locale.ROOT)
        if (!normalizedDigest.matches(Regex("[0-9a-f]{64}"))) {
            throw FlashException("invalid_digest", "UF2 SHA-256 参数无效")
        }

        val blockCount = (length / UF2_BLOCK_SIZE).toInt()
        val digest = MessageDigest.getInstance("SHA-256")
        RandomAccessFile(file, "r").use { input ->
            val block = ByteArray(UF2_BLOCK_SIZE)
            for (index in 0 until blockCount) {
                input.readFully(block)
                digest.update(block)
                val view = ByteBuffer.wrap(block).order(ByteOrder.LITTLE_ENDIAN)
                if (view.getInt(0) != UF2_MAGIC_START0 ||
                    view.getInt(4) != UF2_MAGIC_START1 ||
                    view.getInt(508) != UF2_MAGIC_END
                ) {
                    throw FlashException("invalid_uf2", "UF2 第 ${index + 1} 块魔数无效")
                }
                val flags = view.getInt(8)
                val address = view.getInt(12).toLong() and 0xffffffffL
                val payloadSize = view.getInt(16)
                val blockNumber = view.getInt(20)
                val declaredBlocks = view.getInt(24)
                val familyId = view.getInt(28)
                if (payloadSize != 256 || blockNumber != index || declaredBlocks != blockCount) {
                    throw FlashException("invalid_uf2", "UF2 第 ${index + 1} 块的编号或负载长度无效")
                }
                if ((flags and UF2_FLAG_NOT_MAIN_FLASH) != 0 ||
                    (flags and UF2_FLAG_FAMILY_ID_PRESENT) == 0 ||
                    familyId != UF2_RP2040_FAMILY_ID
                ) {
                    throw FlashException("wrong_uf2_family", "UF2 不是 RP2040 固件，已拒绝烧录")
                }
                if (address < RP2040_XIP_BASE || address + payloadSize > RP2040_XIP_END) {
                    throw FlashException("invalid_uf2_address", "UF2 包含超出 RP2040 Flash 的目标地址")
                }
            }
        }
        val actualDigest = digest.digest().joinToString("") {
            "%02x".format(it.toInt() and 0xff)
        }
        if (actualDigest != normalizedDigest) {
            throw FlashException("digest_mismatch", "Android 原生层复核 UF2 SHA-256 失败")
        }
        return Uf2Metadata(length, blockCount)
    }

    private fun waitForSingleBootloader(timeoutMs: Long): BootloaderCandidate {
        val startedAt = System.nanoTime()
        val deadline = startedAt + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        val hintAt = startedAt + TimeUnit.SECONDS.toNanos(4)
        var hintSent = false
        while (System.nanoTime() < deadline) {
            val all = findBootloaderCandidates()
            if (all.size == 1) return all.single()
            if (all.size > 1) {
                throw FlashException(
                    "multiple_bootloaders",
                    "检测到多个 RP2040 Bootloader，请只保留待烧录设备",
                )
            }
            if (!hintSent && System.nanoTime() >= hintAt) {
                hintSent = true
                emitWaitingHint()
            }
            Thread.sleep(250)
        }
        throw FlashException(
            "bootloader_timeout",
            "未检测到 RP2040 Bootloader；请按住按钮 A / BOOTSEL，短按 RESET 后松开按钮 A",
        )
    }

    private fun emitWaitingHint() {
        emitProgress(
            null,
            "等待 RP2040：按住按钮 A / BOOTSEL，短按 RESET，看到授权提示后松开按钮 A",
        )
    }

    private fun findBootloaderCandidates(): List<BootloaderCandidate> {
        return usbManager.deviceList.values.mapNotNull { device ->
            if (device.vendorId != RP2040_VENDOR_ID ||
                device.productId != RP2040_BOOTSEL_PRODUCT_ID
            ) return@mapNotNull null
            val massStorageInterface = (0 until device.interfaceCount)
                .map { device.getInterface(it) }
                .firstOrNull {
                    it.interfaceClass == USB_MASS_STORAGE_CLASS &&
                        it.interfaceSubclass == SCSI_TRANSPARENT_SUBCLASS &&
                        it.interfaceProtocol == BULK_ONLY_PROTOCOL
                } ?: return@mapNotNull null
            val bulkIn = (0 until massStorageInterface.endpointCount)
                .map { massStorageInterface.getEndpoint(it) }
                .firstOrNull {
                    it.type == UsbConstants.USB_ENDPOINT_XFER_BULK &&
                        it.direction == UsbConstants.USB_DIR_IN
                } ?: return@mapNotNull null
            val bulkOut = (0 until massStorageInterface.endpointCount)
                .map { massStorageInterface.getEndpoint(it) }
                .firstOrNull {
                    it.type == UsbConstants.USB_ENDPOINT_XFER_BULK &&
                        it.direction == UsbConstants.USB_DIR_OUT
                } ?: return@mapNotNull null
            BootloaderCandidate(device, massStorageInterface, bulkIn, bulkOut)
        }
    }

    private fun requireUsbPermission(device: UsbDevice) {
        if (usbManager.hasPermission(device)) return
        val callbackLatch = CountDownLatch(1)
        val setupLatch = CountDownLatch(1)
        val outcome = AtomicInteger(-1)
        val receiverRegistered = AtomicBoolean(false)
        val setupError = AtomicReference<Throwable?>(null)
        val action = "${activity.packageName}.USB_FIRMWARE_PERMISSION.${permissionRequestCode.incrementAndGet()}"
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action != action) return
                val returned = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                }
                val sameDevice = returned?.deviceName == device.deviceName
                val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                if (sameDevice) outcome.set(if (granted) 1 else 0)
                callbackLatch.countDown()
            }
        }

        activity.runOnUiThread {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    // UsbService/SystemUI completes the PendingIntent. A NOT_EXPORTED
                    // receiver can miss broadcasts sent by highly privileged system
                    // components on some Android builds. The action is unique and the
                    // callback is still verified against hasPermission(device).
                    activity.registerReceiver(
                        receiver,
                        IntentFilter(action),
                        Context.RECEIVER_EXPORTED,
                    )
                } else {
                    @Suppress("DEPRECATION")
                    activity.registerReceiver(receiver, IntentFilter(action))
                }
                receiverRegistered.set(true)
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                val permissionIntent = PendingIntent.getBroadcast(
                    activity,
                    permissionRequestCode.get(),
                    Intent(action).setPackage(activity.packageName),
                    flags,
                )
                usbManager.requestPermission(device, permissionIntent)
            } catch (error: Throwable) {
                setupError.set(error)
            } finally {
                setupLatch.countDown()
            }
        }

        try {
            if (!setupLatch.await(5, TimeUnit.SECONDS)) {
                throw FlashException("usb_permission_setup", "无法启动 USB 系统授权")
            }
            setupError.get()?.let { throw it }

            val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(PERMISSION_TIMEOUT_MS)
            while (System.nanoTime() < deadline) {
                // hasPermission is the source of truth. Some OEM builds grant the
                // permission but lose or delay the PendingIntent callback.
                if (usbManager.hasPermission(device)) return
                if (outcome.get() == 0) {
                    throw FlashException(
                        "usb_permission_denied",
                        "用户未授权访问 RP2040 Bootloader",
                    )
                }
                callbackLatch.await(100, TimeUnit.MILLISECONDS)
            }
            throw FlashException("usb_permission_timeout", "等待 USB Bootloader 授权超时")
        } finally {
            if (receiverRegistered.get()) {
                activity.runOnUiThread {
                    try {
                        activity.unregisterReceiver(receiver)
                    } catch (_: IllegalArgumentException) {
                        // Receiver registration may have raced with Activity teardown.
                    }
                }
            }
        }
    }

    private fun flashValidatedUf2(
        candidate: BootloaderCandidate,
        file: File,
        metadata: Uf2Metadata,
        displayName: String,
    ) {
        val connection = usbManager.openDevice(candidate.device)
            ?: throw FlashException("open_bootloader", "无法打开已授权的 RP2040 Bootloader")
        var claimed = false
        try {
            claimed = connection.claimInterface(candidate.usbInterface, true)
            if (!claimed) {
                throw FlashException("claim_bootloader", "无法独占 RP2040 USB Mass Storage 接口")
            }
            val transport = MassStorageTransport(
                connection,
                candidate.usbInterface,
                candidate.bulkIn,
                candidate.bulkOut,
            )
            transport.reset()
            val layout = readAndValidateRp2040Disk(transport)
            val firstWriteLba = layout.firstDataSector + layout.sectorsPerCluster * 8L
            if (firstWriteLba + metadata.blockCount > layout.totalSectors) {
                throw FlashException("uf2_too_large", "UF2 大于 RP2040 BOOTSEL 虚拟磁盘可写空间")
            }

            emitProgress(0.0, "已验证 RPI-RP2，正在烧录 $displayName")
            RandomAccessFile(file, "r").use { input ->
                var blockIndex = 0
                while (blockIndex < metadata.blockCount) {
                    val sectors = minOf(
                        WRITE_SECTORS_PER_COMMAND,
                        metadata.blockCount - blockIndex,
                    )
                    val data = ByteArray(sectors * UF2_BLOCK_SIZE)
                    input.readFully(data)
                    val lastCommand = blockIndex + sectors == metadata.blockCount
                    transport.writeSectors(
                        firstWriteLba + blockIndex,
                        sectors,
                        data,
                        allowDisconnectAfterData = lastCommand,
                    )
                    blockIndex += sectors
                    emitProgress(
                        blockIndex.toDouble() / metadata.blockCount,
                        "正在烧录 $displayName · $blockIndex/${metadata.blockCount} 块",
                    )
                }
            }
            emitProgress(1.0, "UF2 已完整提交，正在等待设备重启…")
        } finally {
            if (claimed) {
                try {
                    connection.releaseInterface(candidate.usbInterface)
                } catch (_: Exception) {
                    // A successful UF2 transfer makes RP2040 disconnect immediately.
                }
            }
            connection.close()
        }
    }

    private fun readAndValidateRp2040Disk(transport: MassStorageTransport): Fat16Layout {
        var bootSector = transport.readSectors(0, 1)
        var volumeStart = 0L
        if (!looksLikeFatBootSector(bootSector)) {
            if (u16(bootSector, 510) != 0xAA55) {
                throw FlashException("invalid_boot_disk", "RP2040 USB 磁盘没有有效的引导扇区")
            }
            val partitionType = bootSector[446 + 4].toInt() and 0xff
            val partitionStart = u32(bootSector, 446 + 8)
            val partitionSectors = u32(bootSector, 446 + 12)
            if (partitionType !in setOf(0x04, 0x06, 0x0E) ||
                partitionStart <= 0 || partitionSectors <= 0
            ) {
                throw FlashException("invalid_boot_disk", "RP2040 USB 磁盘分区表无效")
            }
            volumeStart = partitionStart
            bootSector = transport.readSectors(volumeStart, 1)
        }
        if (!looksLikeFatBootSector(bootSector)) {
            throw FlashException("invalid_boot_disk", "RP2040 USB 磁盘不是预期的 FAT16")
        }

        val bytesPerSector = u16(bootSector, 11)
        val sectorsPerCluster = bootSector[13].toInt() and 0xff
        val reservedSectors = u16(bootSector, 14)
        val fatCount = bootSector[16].toInt() and 0xff
        val rootEntryCount = u16(bootSector, 17)
        val sectorsPerFat = u16(bootSector, 22)
        val total = u16(bootSector, 19).toLong().takeIf { it > 0 }
            ?: u32(bootSector, 32)
        if (bytesPerSector != UF2_BLOCK_SIZE || sectorsPerCluster <= 0 ||
            reservedSectors <= 0 || fatCount <= 0 || rootEntryCount <= 0 ||
            sectorsPerFat <= 0 || total <= 0
        ) {
            throw FlashException("invalid_boot_disk", "RP2040 FAT16 参数无效")
        }

        val rootSectors = ((rootEntryCount * 32L) + bytesPerSector - 1) / bytesPerSector
        val rootStart = volumeStart + reservedSectors + fatCount.toLong() * sectorsPerFat
        val firstData = rootStart + rootSectors
        val root = transport.readSectors(rootStart, rootSectors.toInt())
        var infoCluster = -1
        var infoSize = -1L
        var volumeLabel = ascii(bootSector, 43, 11).trim()
        for (offset in root.indices step 32) {
            if (offset + 32 > root.size) break
            val first = root[offset].toInt() and 0xff
            if (first == 0x00) break
            if (first == 0xE5) continue
            val attributes = root[offset + 11].toInt() and 0xff
            if (attributes == 0x0F) continue
            val name = ascii(root, offset, 11)
            if ((attributes and 0x08) != 0) volumeLabel = name.trim()
            if (name == "INFO_UF2TXT") {
                infoCluster = u16(root, offset + 26)
                infoSize = u32(root, offset + 28)
            }
        }
        if (volumeLabel != "RPI-RP2" || infoCluster < 2 || infoSize !in 1..65_536) {
            throw FlashException("wrong_bootloader", "USB 设备不是预期的 RPI-RP2 Bootloader")
        }

        val infoSectors = ((infoSize + bytesPerSector - 1) / bytesPerSector).toInt()
        if (infoSectors > sectorsPerCluster) {
            throw FlashException("invalid_info_uf2", "INFO_UF2.TXT 超出单个 FAT16 簇")
        }
        val infoLba = firstData + (infoCluster - 2L) * sectorsPerCluster
        val info = ascii(transport.readSectors(infoLba, infoSectors), 0, infoSize.toInt())
            .lowercase(Locale.ROOT)
        val validInfo = info.contains("uf2 bootloader") &&
            (info.contains("rp2040") || info.contains("raspberry pi") ||
                info.contains("board-id: rpi-rp2"))
        if (!validInfo) {
            throw FlashException("wrong_bootloader", "INFO_UF2.TXT 未确认该设备为 RP2040")
        }

        return Fat16Layout(
            firstDataSector = firstData,
            sectorsPerCluster = sectorsPerCluster,
            totalSectors = volumeStart + total,
        )
    }

    private fun looksLikeFatBootSector(bytes: ByteArray): Boolean {
        if (bytes.size < UF2_BLOCK_SIZE) return false
        val bytesPerSector = u16(bytes, 11)
        val sectorsPerCluster = bytes[13].toInt() and 0xff
        val reservedSectors = u16(bytes, 14)
        val fatCount = bytes[16].toInt() and 0xff
        val rootEntries = u16(bytes, 17)
        val sectorsPerFat = u16(bytes, 22)
        val extendedBootSignature = bytes[38].toInt() and 0xff
        val fileSystemType = ascii(bytes, 54, 8).trim()
        val jumpInstruction = bytes[0].toInt() and 0xff
        // The official RP2040 BOOTSEL VBR deliberately has no trailing 0x55AA
        // signature. Validate its FAT16 BPB and identifying fields instead of
        // applying the MBR signature rule to the partition boot sector.
        return jumpInstruction in setOf(0xE9, 0xEB) &&
            bytesPerSector == UF2_BLOCK_SIZE && sectorsPerCluster in 1..128 &&
            (sectorsPerCluster and (sectorsPerCluster - 1)) == 0 &&
            reservedSectors > 0 && fatCount > 0 && rootEntries > 0 &&
            sectorsPerFat > 0 && extendedBootSignature == 0x29 &&
            fileSystemType == "FAT16"
    }

    private fun emitProgress(progress: Double?, message: String) {
        activity.runOnUiThread {
            channel.invokeMethod(
                "onProgress",
                mapOf("progress" to progress, "message" to message),
            )
        }
    }

    private fun completeSuccess(result: MethodChannel.Result, value: Any?) {
        activity.runOnUiThread { result.success(value) }
    }

    private fun completeError(result: MethodChannel.Result, code: String, message: String) {
        activity.runOnUiThread { result.error(code, message, null) }
    }

    private fun u16(bytes: ByteArray, offset: Int): Int =
        (bytes[offset].toInt() and 0xff) or
            ((bytes[offset + 1].toInt() and 0xff) shl 8)

    private fun u32(bytes: ByteArray, offset: Int): Long =
        (bytes[offset].toLong() and 0xff) or
            ((bytes[offset + 1].toLong() and 0xff) shl 8) or
            ((bytes[offset + 2].toLong() and 0xff) shl 16) or
            ((bytes[offset + 3].toLong() and 0xff) shl 24)

    private fun ascii(bytes: ByteArray, offset: Int, length: Int): String =
        bytes.copyOfRange(offset, minOf(bytes.size, offset + length))
            .map { (it.toInt() and 0x7f).toChar() }
            .joinToString("")

    private data class BootloaderCandidate(
        val device: UsbDevice,
        val usbInterface: UsbInterface,
        val bulkIn: UsbEndpoint,
        val bulkOut: UsbEndpoint,
    ) {
        val stableId: String
            get() = "%04x:%04x:%s".format(
                Locale.ROOT,
                device.vendorId,
                device.productId,
                device.deviceName,
            )

        fun toChannelMap(hasPermission: Boolean): Map<String, Any?> = mapOf(
            "id" to stableId,
            "deviceName" to device.deviceName,
            "vendorId" to device.vendorId,
            "productId" to device.productId,
            "manufacturer" to device.manufacturerName,
            "product" to device.productName,
            "hasPermission" to hasPermission,
        )
    }

    private data class Uf2Metadata(val fileBytes: Long, val blockCount: Int)

    private data class Fat16Layout(
        val firstDataSector: Long,
        val sectorsPerCluster: Int,
        val totalSectors: Long,
    )

    private class FlashException(val code: String, message: String) : Exception(message)

    private class MassStorageTransport(
        private val connection: UsbDeviceConnection,
        private val usbInterface: UsbInterface,
        private val bulkIn: UsbEndpoint,
        private val bulkOut: UsbEndpoint,
    ) {
        companion object {
            private const val CBW_SIGNATURE = 0x43425355
            private const val CSW_SIGNATURE = 0x53425355
        }

        private var nextTag = 1

        fun reset() {
            val resetResult = connection.controlTransfer(
                0x21, // Host-to-device, class, interface.
                0xFF, // Bulk-Only Mass Storage Reset.
                0,
                usbInterface.id,
                null,
                0,
                IO_TIMEOUT_MS,
            )
            connection.controlTransfer(
                0x02, // Host-to-device, standard, endpoint.
                0x01, // CLEAR_FEATURE.
                0,
                bulkIn.address,
                null,
                0,
                IO_TIMEOUT_MS,
            )
            connection.controlTransfer(
                0x02,
                0x01,
                0,
                bulkOut.address,
                null,
                0,
                IO_TIMEOUT_MS,
            )
            if (resetResult < 0) {
                throw FlashException("usb_mass_storage_reset", "无法复位 RP2040 USB 磁盘传输状态")
            }
            nextTag = 1
            Thread.sleep(50)
        }

        fun readSectors(lba: Long, sectors: Int): ByteArray {
            if (sectors <= 0 || sectors > 0xffff) {
                throw FlashException("invalid_scsi_read", "SCSI 读取扇区数量无效")
            }
            val cdb = ByteArray(10)
            cdb[0] = 0x28
            putBigEndianU32(cdb, 2, lba)
            cdb[7] = ((sectors ushr 8) and 0xff).toByte()
            cdb[8] = (sectors and 0xff).toByte()
            return command(cdb, inputLength = sectors * UF2_BLOCK_SIZE)
                ?: throw FlashException("scsi_read_failed", "SCSI 未返回磁盘数据")
        }

        fun writeSectors(
            lba: Long,
            sectors: Int,
            data: ByteArray,
            allowDisconnectAfterData: Boolean,
        ) {
            if (sectors <= 0 || sectors > 0xffff || data.size != sectors * UF2_BLOCK_SIZE) {
                throw FlashException("invalid_scsi_write", "SCSI 写入参数无效")
            }
            val cdb = ByteArray(10)
            cdb[0] = 0x2A
            putBigEndianU32(cdb, 2, lba)
            cdb[7] = ((sectors ushr 8) and 0xff).toByte()
            cdb[8] = (sectors and 0xff).toByte()
            command(cdb, output = data, allowDisconnectAfterData = allowDisconnectAfterData)
        }

        private fun command(
            cdb: ByteArray,
            inputLength: Int = 0,
            output: ByteArray? = null,
            allowDisconnectAfterData: Boolean = false,
        ): ByteArray? {
            if (inputLength > 0 && output != null) {
                throw FlashException("invalid_scsi_command", "SCSI 命令不能同时读写")
            }
            val tag = nextTag++
            val transferLength = if (inputLength > 0) inputLength else output?.size ?: 0
            val cbw = ByteBuffer.allocate(31).order(ByteOrder.LITTLE_ENDIAN).apply {
                putInt(CBW_SIGNATURE)
                putInt(tag)
                putInt(transferLength)
                put(if (inputLength > 0) 0x80.toByte() else 0x00)
                put(0x00)
                put(cdb.size.toByte())
                put(cdb)
                while (position() < capacity()) put(0x00)
            }.array()
            writeFully(cbw, "SCSI CBW")

            val input = if (inputLength > 0) readFully(inputLength, "SCSI 数据") else null
            var outputSubmitted = false
            try {
                if (output != null) {
                    writeFully(output, "UF2 数据")
                    outputSubmitted = true
                }
                val csw = readFully(13, "SCSI CSW")
                val view = ByteBuffer.wrap(csw).order(ByteOrder.LITTLE_ENDIAN)
                val signature = view.int
                val returnedTag = view.int
                val residue = view.int
                val status = view.get().toInt() and 0xff
                if (signature != CSW_SIGNATURE || returnedTag != tag || residue != 0 || status != 0) {
                    throw FlashException(
                        "scsi_command_failed",
                        "RP2040 拒绝 SCSI 命令（status=$status, residue=$residue）",
                    )
                }
            } catch (error: FlashException) {
                if (!(allowDisconnectAfterData && outputSubmitted && error.code == "usb_read_failed")) {
                    throw error
                }
                // RP2040 reboots as soon as the final UF2 block is complete, so
                // the final CSW may disappear with the USB device.
            }
            return input
        }

        private fun writeFully(bytes: ByteArray, label: String) {
            var offset = 0
            while (offset < bytes.size) {
                val written = connection.bulkTransfer(
                    bulkOut,
                    bytes,
                    offset,
                    bytes.size - offset,
                    IO_TIMEOUT_MS,
                )
                if (written <= 0) {
                    throw FlashException("usb_write_failed", "$label 写入失败（$offset/${bytes.size}）")
                }
                offset += written
            }
        }

        private fun readFully(length: Int, label: String): ByteArray {
            val bytes = ByteArray(length)
            var offset = 0
            while (offset < length) {
                val read = connection.bulkTransfer(
                    bulkIn,
                    bytes,
                    offset,
                    length - offset,
                    IO_TIMEOUT_MS,
                )
                if (read <= 0) {
                    throw FlashException("usb_read_failed", "$label 读取失败（$offset/$length）")
                }
                offset += read
            }
            return bytes
        }

        private fun putBigEndianU32(target: ByteArray, offset: Int, value: Long) {
            if (value !in 0..0xffffffffL) {
                throw FlashException("invalid_lba", "SCSI LBA 超出范围")
            }
            target[offset] = ((value ushr 24) and 0xff).toByte()
            target[offset + 1] = ((value ushr 16) and 0xff).toByte()
            target[offset + 2] = ((value ushr 8) and 0xff).toByte()
            target[offset + 3] = (value and 0xff).toByte()
        }
    }
}
