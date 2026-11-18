import 'dart:convert';
import 'dart:typed_data';
import 'protocol.dart';

/// Reproduces the firmware's automatic nearest-FPA knot + 0.5 C hysteresis.
/// The stream has no curve index: this choice belongs to the acquired snapshot,
/// not to a separately observed per-frame device selection.
class LiveCurveSelection {
  int? _previous;
  String? _collection;
  ({int index, Uint8List curve, Map<String, dynamic> context}) select(
    Map<String, dynamic> snapshot,
  ) {
    final metadata = (snapshot['curves'] as Map).cast<String, dynamic>();
    final blob = base64Decode(snapshot['curves_binary'] as String);
    final device = snapshot['device'] as Map;
    final crc = device['curvesCrc32'] as String;
    validateCurves(metadata, blob, crc);
    final collection = '${device['thermalModuleSerialNumber']}:$crc';
    if (_collection != collection) _previous = null;
    _collection = collection;
    final nodes = metadata['nodes'] as List;
    final settings = (snapshot['settings'] as Map).cast<String, dynamic>();
    final fpa = snapshot['parameters']['fpa_centi_c'] as int;
    final manual = settings['temperature_curve_selection'] as int;
    int index;
    if (manual > 0 && manual <= nodes.length) {
      index = manual - 1;
      _previous = null;
    } else {
      int distance(int i) => (fpa - (nodes[i]['knot_centi_c'] as int)).abs();
      index = 0;
      for (var i = 1; i < nodes.length; i++) {
        if (distance(i) < distance(index)) index = i;
      }
      final previous = _previous;
      if (previous != null &&
          previous < nodes.length &&
          nodes[previous]['near_valid'] == true &&
          distance(index) + 50 >= distance(previous)) {
        index = previous;
      }
      _previous = index;
    }
    final far =
        settings['distance_mode'] == 'far' && nodes[index]['far_valid'] == true;
    if (nodes[index][far ? 'far_valid' : 'near_valid'] != true) {
      throw const FormatException('当前曲线不可用');
    }
    final offset = index * 2400 + (far ? 1200 : 0);
    return (
      index: index,
      curve: Uint8List.fromList(blob.sublist(offset, offset + 1200)),
      context: {
        ...snapshot,
        'settings': {...settings, 'distance_mode': far ? 'far' : 'near'},
      },
    );
  }
}
