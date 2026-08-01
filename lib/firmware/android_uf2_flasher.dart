import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

typedef AndroidUf2Progress = void Function(double? progress, String message);

class AndroidFirmwareException implements Exception {
  const AndroidFirmwareException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class AndroidBootloaderDevice {
  const AndroidBootloaderDevice({
    required this.id,
    required this.deviceName,
    required this.vendorId,
    required this.productId,
    required this.hasPermission,
    this.manufacturer,
    this.product,
  });

  final String id;
  final String deviceName;
  final int vendorId;
  final int productId;
  final bool hasPermission;
  final String? manufacturer;
  final String? product;

  factory AndroidBootloaderDevice.fromMap(Map<Object?, Object?> map) {
    return AndroidBootloaderDevice(
      id: map['id']?.toString() ?? '',
      deviceName: map['deviceName']?.toString() ?? '',
      vendorId: (map['vendorId'] as num?)?.toInt() ?? 0,
      productId: (map['productId'] as num?)?.toInt() ?? 0,
      hasPermission: map['hasPermission'] == true,
      manufacturer: map['manufacturer']?.toString(),
      product: map['product']?.toString(),
    );
  }
}

class AndroidFirmwareUsbState {
  const AndroidFirmwareUsbState({
    required this.usbHostSupported,
    required this.bootloaders,
  });

  final bool usbHostSupported;
  final List<AndroidBootloaderDevice> bootloaders;

  AndroidBootloaderDevice? get singleBootloader =>
      bootloaders.length == 1 ? bootloaders.single : null;

  factory AndroidFirmwareUsbState.fromMap(Map<Object?, Object?> map) {
    final rawBootloaders = map['bootloaders'];
    return AndroidFirmwareUsbState(
      usbHostSupported: map['usbHostSupported'] == true,
      bootloaders: rawBootloaders is List
          ? rawBootloaders
                .whereType<Map>()
                .map(
                  (item) => AndroidBootloaderDevice.fromMap(
                    Map<Object?, Object?>.from(item),
                  ),
                )
                .where((item) => item.id.isNotEmpty)
                .toList(growable: false)
          : const <AndroidBootloaderDevice>[],
    );
  }
}

/// Narrow MethodChannel bridge for the Android RP2040 BOOTSEL writer.
///
/// Device-family selection, release verification, download trust and post-flash
/// version verification remain in [FirmwareUpdateService]. The native side only
/// receives an already verified app-private UF2 and writes it to a newly attached
/// official RP2040 BOOTSEL device after a second system USB permission grant.
class AndroidUf2Flasher {
  AndroidUf2Flasher._();

  static const MethodChannel _channel = MethodChannel(
    'com.applenana.banana_thermal/firmware_update',
  );

  static AndroidUf2Progress? _progress;
  static bool _handlerInstalled = false;

  static Future<Set<String>> listBootloaderIds() async {
    if (!Platform.isAndroid) return const <String>{};
    final state = await inspectUsbState();
    return state.bootloaders.map((item) => item.id).toSet();
  }

  static Future<AndroidFirmwareUsbState> inspectUsbState() async {
    if (!Platform.isAndroid) {
      return const AndroidFirmwareUsbState(
        usbHostSupported: false,
        bootloaders: <AndroidBootloaderDevice>[],
      );
    }
    try {
      final raw = await _channel.invokeMethod<Object?>('inspectUsbState');
      if (raw is! Map) {
        throw const AndroidFirmwareException(
          'invalid_usb_state',
          'Android 原生层返回了无效的 USB 状态',
        );
      }
      return AndroidFirmwareUsbState.fromMap(Map<Object?, Object?>.from(raw));
    } on PlatformException catch (error) {
      throw AndroidFirmwareException(
        error.code,
        error.message ?? '无法读取 Android USB 设备状态',
      );
    }
  }

  static Future<AndroidBootloaderDevice> requestPermission(
    AndroidBootloaderDevice device,
  ) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('Android USB 授权只能在 Android 上调用');
    }
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'requestBootloaderPermission',
        {'deviceId': device.id},
      );
      if (raw is! Map) {
        throw const AndroidFirmwareException(
          'invalid_usb_device',
          'Android 原生层没有返回已授权的 USB 设备',
        );
      }
      return AndroidBootloaderDevice.fromMap(Map<Object?, Object?>.from(raw));
    } on PlatformException catch (error) {
      throw AndroidFirmwareException(
        error.code,
        error.message ?? 'USB Bootloader 授权失败',
      );
    }
  }

  static Future<void> flashUf2({
    required File firmware,
    required String expectedSha256,
    required String destinationName,
    required Duration timeout,
    required AndroidUf2Progress onProgress,
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('Android UF2 烧录桥只能在 Android 上调用');
    }
    _installHandler();
    if (_progress != null) throw StateError('已有 Android UF2 烧录任务正在进行');
    _progress = onProgress;
    try {
      await _channel.invokeMethod<Map<Object?, Object?>>('flashUf2', {
        'path': firmware.path,
        'expectedSha256': expectedSha256,
        'destinationName': destinationName,
        'timeoutMs': timeout.inMilliseconds,
      });
    } on PlatformException catch (error) {
      throw AndroidFirmwareException(
        error.code,
        error.message ?? 'Android USB 固件烧录失败',
      );
    } finally {
      _progress = null;
    }
  }

  static void _installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onProgress') return;
      final args = call.arguments;
      if (args is! Map) return;
      final rawProgress = args['progress'];
      final message = args['message']?.toString();
      if (message == null || message.isEmpty) return;
      _progress?.call(
        rawProgress is num ? rawProgress.toDouble().clamp(0, 1) : null,
        message,
      );
    });
  }
}
