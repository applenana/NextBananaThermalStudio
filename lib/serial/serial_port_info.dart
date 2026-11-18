/// 串口设备信息. 桌面端 (libserialport) 与 Android (usb_serial) 共用.
library;

import '../starthermal/protocol.dart' show publicStarThermalText;

class SerialPortInfo {
  /// 桌面端: COM 名 (Windows) / `/dev/tty*` (Linux/macOS).
  /// Android: USB device id 字符串 (`/dev/bus/usb/xxx/yyy`).
  final String name;
  final String _description;
  final String? _manufacturer;
  final String? _productName;
  String get description => publicStarThermalText(_description);
  String? get manufacturer =>
      _manufacturer == null ? null : publicStarThermalText(_manufacturer);
  String? get productName =>
      _productName == null ? null : publicStarThermalText(_productName);
  final int? vendorId;
  final int? productId;

  const SerialPortInfo({
    required this.name,
    required String description,
    String? manufacturer,
    String? productName,
    this.vendorId,
    this.productId,
  }) : _description = description,
       _manufacturer = manufacturer,
       _productName = productName;

  @override
  String toString() =>
      '$name ($description${manufacturer != null ? ', $manufacturer' : ''})';
}
