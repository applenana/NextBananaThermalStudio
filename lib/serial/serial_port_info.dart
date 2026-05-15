/// 串口设备信息. 桌面端 (libserialport) 与 Android (usb_serial) 共用.
library;

class SerialPortInfo {
  /// 桌面端: COM 名 (Windows) / `/dev/tty*` (Linux/macOS).
  /// Android: USB device id 字符串 (`/dev/bus/usb/xxx/yyy`).
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
