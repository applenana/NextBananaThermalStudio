/// 串口服务: 跨平台串口扫描 / 打开 / 关闭 / 收发.
///
/// - 桌面 (Windows/macOS/Linux): 基于 flutter_libserialport (FFI 直连 libserialport.so/.dll);
/// - Android: 基于 usb_serial (USB Host API, CDC-ACM/CH34x/FTDI/CP210x).
///
/// 公开 API 与单文件早期版本完全一致, app_state / UI 无需改动. 平台分发
/// 在每个方法入口处通过 `Platform.isAndroid` 短路, 桌面字节级行为 0 变化.
///
/// 用法:
/// ```dart
/// final svc = SerialService();
/// final ports = await SerialService.listPortsAsync();
/// await svc.open(ports.first.name, baud: 1000000);
/// svc.bytesStream.listen((data) => parser.feed(data));
/// svc.writeString('GetSysInfo\n');
/// ```
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';

import 'android_serial_impl.dart';
import 'serial_port_info.dart';
import 'windows_rx_buffer.dart';
import 'desktop_serial_reader.dart';
import 'identity_handshake.dart';

export 'serial_port_info.dart';

class SerialService {
  SerialService() {
    if (Platform.isAndroid) {
      _android = AndroidSerialImpl();
      // 透传 Android 后端字节流到外层 controller, 让监听方无差别拿到数据.
      _android!.bytesStream.listen(
        _byteCtrl.add,
        onError: (e) => _byteCtrl.addError(e),
      );
    }
  }

  AndroidSerialImpl? _android;

  SerialPort? _port;
  DesktopSerialReader? _reader;
  StreamSubscription<Uint8List>? _sub;
  final StreamController<Uint8List> _byteCtrl =
      StreamController<Uint8List>.broadcast();

  /// 字节流: 桌面来自 DesktopSerialReader, Android 来自 usb_serial inputStream.
  Stream<Uint8List> get bytesStream => _byteCtrl.stream;

  bool get isOpen => Platform.isAndroid
      ? (_android?.isOpen ?? false)
      : (_port?.isOpen ?? false);
  String? get currentPortName =>
      Platform.isAndroid ? _android?.currentPortName : _port?.name;

  /// 枚举系统所有可用串口. 桌面同步实现; **Android 上请改用 [listPortsAsync]**.
  /// 在 Android 调用本同步方法会返回空列表 (USB host 枚举必须 await).
  static List<SerialPortInfo> listPorts() {
    if (Platform.isAndroid) return const <SerialPortInfo>[];
    final result = <SerialPortInfo>[];
    for (final name in SerialPort.availablePorts) {
      SerialPort? p;
      try {
        p = SerialPort(name);
        result.add(
          SerialPortInfo(
            name: name,
            description: _safeAscii(p.description),
            manufacturer: _safeAscii(p.manufacturer),
            productName: _safeAscii(p.productName),
            vendorId: p.vendorId,
            productId: p.productId,
          ),
        );
      } catch (_) {
        result.add(SerialPortInfo(name: name, description: ''));
      } finally {
        // 必须显式 dispose, 否则 GC finalizer 跨线程释放 native handle
        // 会与后续打开的 reader 线程竞态, 在 Debug CRT 下触发 heap assert.
        try {
          p?.dispose();
        } catch (_) {}
      }
    }
    return result;
  }

  /// 异步枚举. 桌面包装同步 [listPorts]; Android 走 usb_serial.
  static Future<List<SerialPortInfo>> listPortsAsync() async {
    if (Platform.isAndroid) return AndroidSerialImpl.listPortsAsync();
    return listPorts();
  }

  /// Windows libserialport 返回的描述是 ANSI/GBK 编码,
  /// Dart 按 UTF-8 解码会乱码. 这里只保留可打印 ASCII,
  /// 非 ASCII 字节跳过. COM 编号本身是 ASCII, 不受影响.
  static String _safeAscii(String? s) {
    if (s == null || s.isEmpty) return '';
    final sb = StringBuffer();
    var dropped = false;
    for (final r in s.runes) {
      if (r == 0x09 || (r >= 0x20 && r < 0x7F)) {
        sb.writeCharCode(r);
      } else {
        dropped = true;
      }
    }
    final out = sb.toString().trim();
    return out.isEmpty && dropped ? '?' : out;
  }

  /// 打开串口. 失败抛 [SerialPortError] (桌面) / [StateError] (Android).
  Future<void> open(String name, {int baud = 115200}) async {
    if (Platform.isAndroid) {
      return _android!.open(name, baud: baud);
    }
    await close();
    final p = SerialPort(name);
    if (!p.openReadWrite()) {
      throw SerialPortError('无法打开串口 $name');
    }
    _port = p;
    try {
      final cfg = SerialPortConfig()
        ..baudRate = baud
        ..bits = 8
        ..stopBits = 1
        ..parity = SerialPortParity.none
        ..setFlowControl(SerialPortFlowControl.none)
        // 关键: 显式拉高 DTR / RTS, 唤醒 RP2040 + TinyUSB CDC 设备的 TX.
        // 多数 TinyUSB CDC 固件在 cdc_set_control_line_state(dtr=1) 回调里
        // 才把内部 cdc_connected 置 true, 否则 tud_cdc_write 全部丢弃.
        // 这也是为什么必须先用浏览器 Web Serial (默认拉 DTR) "唤一下"才有数据.
        ..dtr = SerialPortDtr.on
        ..rts = SerialPortRts.on;
      p.config = cfg;
      // 不调 cfg.dispose(): flutter_libserialport 在 Windows 上手动 dispose 后
      // GC finalizer 会二次释放同一 native handle, 造成闪退. 交给 GC.

      configureWindowsRxBuffer(p.address);
      _reader = await DesktopSerialReader.open(p.address);
      _sub = _reader!.stream.listen(
        _byteCtrl.add,
        onError: (e) => _byteCtrl.addError(e),
      );
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<void> setBaud(int baud) async {
    if (Platform.isAndroid) return _android!.setBaud(baud);
    final port = _port;
    if (port == null || !port.isOpen) throw StateError('串口未打开');
    if (port.config.baudRate == baud) return;
    // Wait for the cooperative RX isolate to exit before reconfiguring the
    // handle: libserialport can otherwise report a negative read length from
    // the in-flight operation and terminate its reader isolate silently.
    await _sub?.cancel();
    await _reader?.close();
    final config = port.config;
    config.baudRate = baud;
    port.config = config;
    _reader = await DesktopSerialReader.open(port.address);
    _sub = _reader!.stream.listen(
      _byteCtrl.add,
      onError: (e) => _byteCtrl.addError(e),
    );
  }

  Future<void> writeAll(Uint8List bytes) async {
    if (Platform.isAndroid) return _android!.writeAll(bytes);
    var offset = 0;
    while (offset < bytes.length) {
      final n = writeBytes(Uint8List.sublistView(bytes, offset));
      if (n <= 0) throw StateError('串口写入失败');
      offset += n;
    }
  }

  Future<void> close() async {
    if (Platform.isAndroid) {
      return _android!.close();
    }
    // 顺序: 取消上层 sub → 关 reader (停下 native 读线程) → 关 port.
    // 重点: 不调 port.dispose() / reader.dispose(),
    // flutter_libserialport 0.4.0 Windows 下手动 dispose 会和 finalizer 双释放闪退.
    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    try {
      await _reader?.close();
    } catch (_) {}
    _reader = null;
    final p = _port;
    _port = null;
    if (p != null) {
      try {
        if (p.isOpen) p.close();
      } catch (_) {}
    }
  }

  /// 写字符串 (UTF-8, 不附加换行; 调用方负责加 \n).
  int writeString(String s) {
    if (Platform.isAndroid) return _android!.writeString(s);
    final port = _port;
    if (port == null || !port.isOpen) return 0;
    final bytes = Uint8List.fromList(s.codeUnits);
    return port.write(bytes, timeout: 200);
  }

  /// 写原始字节.
  int writeBytes(List<int> bytes) {
    if (Platform.isAndroid) return _android!.writeBytes(bytes);
    final port = _port;
    if (port == null || !port.isOpen) return 0;
    return port.write(
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      timeout: 200,
    );
  }

  Future<void> dispose() async {
    if (Platform.isAndroid) {
      await _android!.dispose();
      await _byteCtrl.close();
      return;
    }
    await close();
    await _byteCtrl.close();
  }

  /// 对 RP2040 Arduino USB CDC 执行标准 1200-baud touch。
  ///
  /// 支持该机制的固件会在 1200 baud 下 DTR 从 on 变为 off 时重启到 UF2
  /// Bootloader。失败只返回 false，调用方仍可等待用户通过 BOOTSEL/RESET
  /// 手动进入，不能把普通串口设备误判为已经进入烧录模式。
  static Future<bool> touch1200Bootloader(String name) async {
    if (Platform.isAndroid) {
      return AndroidSerialImpl.touch1200Bootloader(name);
    }
    SerialPort? port;
    try {
      port = SerialPort(name);
      if (!port.openReadWrite()) return false;
      final active = SerialPortConfig()
        ..baudRate = 1200
        ..bits = 8
        ..stopBits = 1
        ..parity = SerialPortParity.none
        ..setFlowControl(SerialPortFlowControl.none)
        ..dtr = SerialPortDtr.on
        ..rts = SerialPortRts.off;
      port.config = active;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final released = SerialPortConfig()
        ..baudRate = 1200
        ..bits = 8
        ..stopBits = 1
        ..parity = SerialPortParity.none
        ..setFlowControl(SerialPortFlowControl.none)
        ..dtr = SerialPortDtr.off
        ..rts = SerialPortRts.off;
      port.config = released;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        if (port?.isOpen == true) port?.close();
      } catch (_) {}
      // 与 open/close 主路径一致，不手动 dispose，避免 Windows 上 finalizer
      // 与原生句柄发生二次释放竞态。
    }
  }

  // ============================================================
  // 自动探测设备 (参考全能上位机 _probe_device)
  // ============================================================

  /// 临时打开 [name] 端口, 发 `GetSysInfo\n`, 在 [timeout] 内等设备
  /// 返回 JSON 行 (包含 `Activated`/`Serial` 等字段).
  ///
  /// 成功返回解析后的 JSON Map, 失败 / 超时返回 null.
  /// 注意: 在主 isolate 调用会因 libserialport 同步 FFI 卡 UI 线程,
  /// 批量探测请改用 [searchTargetDevice] (内部跑后台 isolate).
  static Future<Map<String, dynamic>?> probeDevice(
    String name, {
    int baud = 115200,
    Duration timeout = const Duration(milliseconds: 1800),
  }) {
    if (Platform.isAndroid) {
      return AndroidSerialImpl.probeDevice(name, baud: baud, timeout: timeout);
    }
    return _probeDeviceCore(
      name,
      baud: baud,
      timeoutMs: timeout.inMilliseconds,
    );
  }

  /// 判断端口描述是否可能是热成像 USB CDC 设备 (优先尝试).
  /// 与 Python 上位机的过滤策略一致.
  static bool _isLikelyTarget(SerialPortInfo info) {
    final d = info.description.toUpperCase();
    final m = (info.manufacturer ?? '').toUpperCase();
    final blob = '$d $m';
    return blob.contains('USB') ||
        blob.contains('CDC') ||
        blob.contains('ACM') ||
        blob.contains('SERIAL') ||
        // RP2040 默认描述 "Board CDC"
        blob.contains('BOARD');
  }

  /// 扫描全部串口并探测目标设备. 返回 `(端口名, 设备JSON)`,
  /// 没找到返回 `(null, null)`.
  ///
  /// 探测顺序: 描述含 USB/CDC/ACM/BOARD 的端口优先, 其余端口兜底.
  /// 每个端口最多耗时 [perPortTimeout].
  ///
  /// 整个扫描通过 [Isolate.spawn] 跑在后台 isolate, 避免 libserialport 的
  /// 同步 FFI (openReadWrite / close 等) 卡住 UI 线程. 进度 / 结果通过
  /// SendPort 回主线程, 失败兜底为主 isolate 串行探测.
  static Future<({String? port, Map<String, dynamic>? info})>
  searchTargetDevice({
    int baud = 115200,
    Duration perPortTimeout = const Duration(milliseconds: 1500),
    void Function(String port)? onProbe,
    Set<String>? allowedPorts,
  }) async {
    if (Platform.isAndroid) {
      return AndroidSerialImpl.searchTargetDevice(
        baud: baud,
        perPortTimeout: perPortTimeout,
        onProbe: onProbe,
        allowedPorts: allowedPorts,
      );
    }
    // 枚举仍在主 isolate, 否则跨 isolate 的 SerialPortInfo 排序逻辑要复制一份.
    final ports = listPorts()
        .where(
          (port) => allowedPorts == null || allowedPorts.contains(port.name),
        )
        .toList();
    final ordered = <String>[
      ...ports.where(_isLikelyTarget).map((e) => e.name),
      ...ports.where((p) => !_isLikelyTarget(p)).map((e) => e.name),
    ];
    if (ordered.isEmpty) return (port: null, info: null);
    final finished = _searchFinished = Completer<void>();
    _searchCancelled = false;

    final rp = ReceivePort();
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();
    final resultCompleter = Completer<Map<String, dynamic>?>();
    final foundCompleter = Completer<String?>();

    final progSub = rp.listen((msg) {
      if (msg is SendPort) {
        _currentSearchCommands = msg;
        if (_searchCancelled) msg.send(null);
      } else if (msg is String) {
        onProbe?.call(msg);
      } else if (msg is Map) {
        // 结果消息: {'port': name, 'info': Map?}
        final port = msg['port'];
        final info = msg['info'];
        if (!foundCompleter.isCompleted) {
          foundCompleter.complete(port is String ? port : null);
        }
        if (!resultCompleter.isCompleted) {
          resultCompleter.complete(
            info is Map ? info.cast<String, dynamic>() : null,
          );
        }
      }
    });
    final errSub = errorPort.listen((e) {
      // ignore: avoid_print
      print('[searchTargetDevice] isolate error: $e');
      if (!foundCompleter.isCompleted) foundCompleter.complete(null);
      if (!resultCompleter.isCompleted) resultCompleter.complete(null);
    });
    final exitSub = exitPort.listen((_) {
      if (!foundCompleter.isCompleted) foundCompleter.complete(null);
      if (!resultCompleter.isCompleted) resultCompleter.complete(null);
    });

    Isolate? isolate;
    try {
      isolate = await Isolate.spawn<_SearchArgs>(
        _searchIsolateEntry,
        _SearchArgs(
          ports: ordered,
          baud: baud,
          timeoutMs: perPortTimeout.inMilliseconds,
          sendPort: rp.sendPort,
        ),
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort,
        errorsAreFatal: false,
      );
      final foundPort = await foundCompleter.future;
      final foundInfo = await resultCompleter.future;
      if (_searchCancelled) {
        return (port: null, info: null);
      }
      return (port: foundPort, info: foundInfo);
    } catch (e) {
      // ignore: avoid_print
      print('[searchTargetDevice] spawn failed, fallback main isolate: $e');
      // 兜底: 没法用 isolate 时退回主 isolate 串行扫描, 不至于完全没功能.
      for (final name in ordered) {
        if (_searchCancelled) break;
        onProbe?.call(name);
        final info = await _probeDeviceCore(
          name,
          baud: baud,
          timeoutMs: perPortTimeout.inMilliseconds,
        );
        if (!_searchCancelled && info != null) return (port: name, info: info);
      }
      return (port: null, info: null);
    } finally {
      try {
        isolate?.kill(priority: Isolate.immediate);
      } catch (_) {}
      _currentSearchCommands = null;
      _searchCancelled = false;
      await progSub.cancel();
      await errSub.cancel();
      await exitSub.cancel();
      rp.close();
      errorPort.close();
      exitPort.close();
      _searchFinished = null;
      finished.complete();
    }
  }

  // Cooperative cancellation also waits for the reader isolate to exit.
  static SendPort? _currentSearchCommands;
  static IdentityHandshake? _activeSearchProbe;
  static Completer<void>? _searchFinished;
  static bool _searchCancelled = false;

  /// Cancel cooperatively and wait for the probe to close its native port.
  /// Killing its isolate first would skip finally and leave the port occupied.
  static Future<void> cancelSearch() async {
    if (Platform.isAndroid) return AndroidSerialImpl.cancelSearch();
    _searchCancelled = true;
    _currentSearchCommands?.send(null);
    _activeSearchProbe?.cancel();
    await _searchFinished?.future;
    if (_searchFinished == null) _searchCancelled = false;
  }

  /// probeDevice 的纯实现, 不依赖任何 isolate-bound 资源, 可在主或子 isolate 调用.
  static Future<Map<String, dynamic>?> _probeDeviceCore(
    String name, {
    required int baud,
    required int timeoutMs,
  }) async {
    final service = SerialService();
    try {
      await service.open(name, baud: baud);
      final handshake = IdentityHandshake(
        bytes: service.bytesStream,
        write: service.writeAll,
        setBaud: service.setBaud,
        perBaudTimeout: Duration(milliseconds: timeoutMs),
      );
      _activeSearchProbe = handshake;
      if (_searchCancelled) handshake.cancel();
      return (await handshake.run([baud]))?.info;
    } catch (_) {
      return null;
    } finally {
      _activeSearchProbe = null;
      await service.dispose();
    }
  }
}

// ============================================================
// 后台 isolate: 串口探测 worker
// ============================================================

class _SearchArgs {
  final List<String> ports;
  final int baud;
  final int timeoutMs;
  final SendPort sendPort;
  const _SearchArgs({
    required this.ports,
    required this.baud,
    required this.timeoutMs,
    required this.sendPort,
  });
}

Future<void> _searchIsolateEntry(_SearchArgs args) async {
  final commands = ReceivePort();
  commands.listen((_) {
    SerialService._searchCancelled = true;
    SerialService._activeSearchProbe?.cancel();
  });
  args.sendPort.send(commands.sendPort);
  try {
    for (final name in args.ports) {
      if (SerialService._searchCancelled) break;
      args.sendPort.send(name); // 进度消息: 端口名
      final info = await SerialService._probeDeviceCore(
        name,
        baud: args.baud,
        timeoutMs: args.timeoutMs,
      );
      if (!SerialService._searchCancelled && info != null) {
        args.sendPort.send({'port': name, 'info': info});
        return;
      }
    }
    args.sendPort.send({'port': null, 'info': null});
  } finally {
    commands.close();
  }
}
