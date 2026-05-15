/// Android USB Host 串口实现, 基于 [usb_serial] 包.
///
/// 接口与 [SerialService] 公开 API 保持一致 (open / close / writeBytes /
/// writeString / bytesStream / isOpen / currentPortName / listPorts /
/// probeDevice / searchTargetDevice).
///
/// 设计原则:
/// - 仅在 [Platform.isAndroid] 路径被实例化 / 调用, 桌面代码不受影响;
/// - 显式 setDTR(true)/setRTS(true), 与 Windows 端 v0.2.3 修复对齐, 唤醒
///   RP2040 + TinyUSB CDC 固件的 TX (cdc_set_control_line_state 回调).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:usb_serial/usb_serial.dart';

import 'serial_port_info.dart';

class AndroidSerialImpl {
  UsbPort? _port;
  StreamSubscription<Uint8List>? _sub;
  String? _portName;
  final StreamController<Uint8List> _byteCtrl =
      StreamController<Uint8List>.broadcast();

  Stream<Uint8List> get bytesStream => _byteCtrl.stream;
  bool get isOpen => _port != null;
  String? get currentPortName => _portName;

  /// 枚举所有 USB CDC / UART 桥接设备. 返回的 `name` 字段是设备 id 字符串
  /// (deviceName, 形如 `/dev/bus/usb/001/002`), 用于 [open] 时回查.
  static Future<List<SerialPortInfo>> listPortsAsync() async {
    final devices = await UsbSerial.listDevices();
    return devices.map((d) {
      final vidHex = d.vid?.toRadixString(16).padLeft(4, '0').toUpperCase();
      final pidHex = d.pid?.toRadixString(16).padLeft(4, '0').toUpperCase();
      final desc = StringBuffer();
      if (d.productName != null && d.productName!.isNotEmpty) {
        desc.write(d.productName);
      }
      if (vidHex != null && pidHex != null) {
        if (desc.isNotEmpty) desc.write(' ');
        desc.write('[$vidHex:$pidHex]');
      }
      return SerialPortInfo(
        name: d.deviceName,
        description: desc.toString(),
        manufacturer: d.manufacturerName,
        productName: d.productName,
        vendorId: d.vid,
        productId: d.pid,
      );
    }).toList(growable: false);
  }

  Future<void> open(String name, {int baud = 115200}) async {
    await close();
    final devices = await UsbSerial.listDevices();
    final device = devices.firstWhere(
      (d) => d.deviceName == name,
      orElse: () => throw StateError('USB 设备未连接: $name'),
    );
    final port = await device.create();
    if (port == null) throw StateError('无法创建 USB 串口: $name');
    final ok = await port.open();
    if (!ok) throw StateError('无法打开 USB 串口: $name');
    await port.setPortParameters(
        baud, UsbPort.DATABITS_8, UsbPort.STOPBITS_1, UsbPort.PARITY_NONE);
    // 与桌面端一致: 显式拉高 DTR / RTS, 唤醒 TinyUSB CDC 设备 TX.
    await port.setDTR(true);
    await port.setRTS(true);
    _port = port;
    _portName = name;
    _sub = port.inputStream?.listen(
      _byteCtrl.add,
      onError: (e) => _byteCtrl.addError(e),
    );
  }

  Future<void> close() async {
    try { await _sub?.cancel(); } catch (_) {}
    _sub = null;
    final p = _port;
    _port = null;
    _portName = null;
    if (p != null) {
      try { await p.close(); } catch (_) {}
    }
  }

  int writeBytes(List<int> bytes) {
    final port = _port;
    if (port == null) return 0;
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    // usb_serial 的 write 是异步的, 这里 fire-and-forget 与 libserialport
    // 的同步 write 语义对齐 (返回长度即"已提交"长度).
    unawaited(port.write(data));
    return data.length;
  }

  int writeString(String s) =>
      writeBytes(Uint8List.fromList(s.codeUnits));

  Future<void> dispose() async {
    await close();
    await _byteCtrl.close();
  }

  // ============================================================
  // 探测设备 (与桌面端 _probeDeviceCore 行为对齐)
  // ============================================================

  static Future<Map<String, dynamic>?> probeDevice(
    String name, {
    int baud = 115200,
    Duration timeout = const Duration(milliseconds: 1800),
  }) async {
    final devices = await UsbSerial.listDevices();
    final device = devices.firstWhere(
      (d) => d.deviceName == name,
      orElse: () => throw StateError('USB 设备未连接: $name'),
    );
    UsbPort? port;
    StreamSubscription<Uint8List>? sub;
    final completer = Completer<Map<String, dynamic>?>();
    final buf = BytesBuilder(copy: false);
    try {
      port = await device.create();
      if (port == null) return null;
      if (!await port.open()) return null;
      await port.setPortParameters(baud, UsbPort.DATABITS_8,
          UsbPort.STOPBITS_1, UsbPort.PARITY_NONE);
      await port.setDTR(true);
      await port.setRTS(true);
      sub = port.inputStream?.listen((data) {
        if (completer.isCompleted) return;
        buf.add(data);
        final all = buf.toBytes();
        int last = 0;
        for (int i = 0; i < all.length; i++) {
          if (all[i] != 0x0A) continue;
          final raw = all.sublist(last, i);
          last = i + 1;
          final ascii = raw
              .where((b) => b == 0x09 || (b >= 0x20 && b < 0x7F))
              .toList(growable: false);
          final line = String.fromCharCodes(ascii).trim();
          if (line.startsWith('{') && line.endsWith('}')) {
            try {
              final j = jsonDecode(line);
              if (j is Map<String, dynamic> &&
                  (j.containsKey('Activated') ||
                      j.containsKey('Serial') ||
                      j.containsKey('SerialNum') ||
                      j.containsKey('isActivated'))) {
                if (!completer.isCompleted) completer.complete(j);
                return;
              }
            } catch (_) {}
          }
        }
        if (last > 0 && last < all.length) {
          final tail = all.sublist(last);
          buf.clear();
          buf.add(tail);
        } else if (last >= all.length) {
          buf.clear();
        }
      }, onError: (_) {
        if (!completer.isCompleted) completer.complete(null);
      });

      await Future<void>.delayed(const Duration(milliseconds: 150));
      await port.write(Uint8List.fromList('GetSysInfo\n'.codeUnits));

      return await completer.future.timeout(timeout, onTimeout: () => null);
    } catch (_) {
      return null;
    } finally {
      try { await sub?.cancel(); } catch (_) {}
      try { await port?.close(); } catch (_) {}
    }
  }

  static Future<({String? port, Map<String, dynamic>? info})>
      searchTargetDevice({
    int baud = 115200,
    Duration perPortTimeout = const Duration(milliseconds: 1500),
    void Function(String port)? onProbe,
  }) async {
    final ports = await listPortsAsync();
    for (final info in ports) {
      onProbe?.call(info.name);
      final res = await probeDevice(info.name,
          baud: baud, timeout: perPortTimeout);
      if (res != null) return (port: info.name, info: res);
    }
    return (port: null, info: null);
  }
}
