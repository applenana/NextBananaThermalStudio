/// 串口服务: 跨平台串口扫描 / 打开 / 关闭 / 收发. 基于 flutter_libserialport.
///
/// 用法:
/// ```dart
/// final svc = SerialService();
/// final ports = SerialService.listPorts();
/// await svc.open(ports.first.name, baud: 1000000);
/// svc.bytesStream.listen((data) => parser.feed(data));
/// svc.writeString('GetSysInfo\n');
/// ```
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';

class SerialPortInfo {
  final String name;
  final String description;
  final String? manufacturer;
  final String? productName;
  final int? vendorId;
  final int? productId;

  const SerialPortInfo({
    required this.name,
    required this.description,
    this.manufacturer,
    this.productName,
    this.vendorId,
    this.productId,
  });

  @override
  String toString() =>
      '$name ($description${manufacturer != null ? ', $manufacturer' : ''})';
}

class SerialService {
  SerialPort? _port;
  SerialPortReader? _reader;
  StreamSubscription<Uint8List>? _sub;
  final StreamController<Uint8List> _byteCtrl =
      StreamController<Uint8List>.broadcast();

  /// 字节流: 来自 SerialPortReader, 转发给上层 FrameParser.
  Stream<Uint8List> get bytesStream => _byteCtrl.stream;

  bool get isOpen => _port?.isOpen ?? false;
  String? get currentPortName => _port?.name;

  /// 枚举系统所有可用串口.
  static List<SerialPortInfo> listPorts() {
    final result = <SerialPortInfo>[];
    for (final name in SerialPort.availablePorts) {
      SerialPort? p;
      try {
        p = SerialPort(name);
        result.add(SerialPortInfo(
          name: name,
          description: _safeAscii(p.description),
          manufacturer: _safeAscii(p.manufacturer),
          productName: _safeAscii(p.productName),
          vendorId: p.vendorId,
          productId: p.productId,
        ));
      } catch (_) {
        result.add(SerialPortInfo(name: name, description: ''));
      } finally {
        // 必须显式 dispose, 否则 GC finalizer 跨线程释放 native handle
        // 会与后续打开的 reader 线程竞态, 在 Debug CRT 下触发 heap assert.
        try { p?.dispose(); } catch (_) {}
      }
    }
    return result;
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

  /// 打开串口. 失败抛 [SerialPortError].
  Future<void> open(String name, {int baud = 115200}) async {
    await close();
    final p = SerialPort(name);
    if (!p.openReadWrite()) {
      throw SerialPortError('无法打开串口 $name');
    }
    final cfg = SerialPortConfig()
      ..baudRate = baud
      ..bits = 8
      ..stopBits = 1
      ..parity = SerialPortParity.none
      ..setFlowControl(SerialPortFlowControl.none);
    p.config = cfg;
    // 不调 cfg.dispose(): flutter_libserialport 在 Windows 上手动 dispose 后
    // GC finalizer 会二次释放同一 native handle, 造成闪退. 交给 GC.

    _port = p;
    _reader = SerialPortReader(p);
    _sub = _reader!.stream.listen(
      _byteCtrl.add,
      onError: (e) => _byteCtrl.addError(e),
    );
  }

  Future<void> close() async {
    // 顺序: 取消上层 sub → 关 reader (停下 native 读线程) → 关 port.
    // 重点: 不调 port.dispose() / reader.dispose(),
    // flutter_libserialport 0.4.0 Windows 下手动 dispose 会和 finalizer 双释放闪退.
    try { await _sub?.cancel(); } catch (_) {}
    _sub = null;
    try { _reader?.close(); } catch (_) {}
    _reader = null;
    final p = _port;
    _port = null;
    if (p != null) {
      try { if (p.isOpen) p.close(); } catch (_) {}
    }
  }

  /// 写字符串 (UTF-8, 不附加换行; 调用方负责加 \n).
  int writeString(String s) {
    final port = _port;
    if (port == null || !port.isOpen) return 0;
    final bytes = Uint8List.fromList(s.codeUnits);
    return port.write(bytes, timeout: 200);
  }

  /// 写原始字节.
  int writeBytes(List<int> bytes) {
    final port = _port;
    if (port == null || !port.isOpen) return 0;
    return port.write(
        bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
        timeout: 200);
  }

  Future<void> dispose() async {
    await close();
    await _byteCtrl.close();
  }
}
