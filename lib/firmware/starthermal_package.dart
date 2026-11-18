import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

import 'firmware_update.dart';

const starThermalMaximumImage = 3141632;
const _signingKey =
    'AAAAC3NzaC1lZDI1NTE5AAAAIK+iFI4sRbB3MlQae/+vXUUwslxg6vKPM1vKj95ZfCUL';

/// Verify OpenSSH SSHSIG using the application's pinned release key.
/// The allowed-signers file supplied alongside a download is never trusted.
Future<Map<String, String>> verifyStarThermalChecksums(
  Uint8List checksums,
  String armoredSignature,
  String tag, {
  String trustedKey = _signingKey,
}) async {
  if (checksums.length > 16384 ||
      armoredSignature.length > 4096 ||
      !tag.startsWith('StarThermal-') ||
      firmwareReleaseVersion(tag) == null) {
    throw const FormatException('星像签名文件或版本无效');
  }
  final armor = RegExp(
    r'^-----BEGIN SSH SIGNATURE-----\s+([A-Za-z0-9+/=\s]+)-----END SSH SIGNATURE-----\s*$',
  ).firstMatch(armoredSignature);
  if (armor == null) throw const FormatException('星像签名格式无效');
  final reader = _SshReader(
    base64Decode(armor.group(1)!.replaceAll(RegExp(r'\s'), '')),
  );
  if (ascii.decode(reader.take(6)) != 'SSHSIG' || reader.uint32() != 1) {
    throw const FormatException('不支持的星像签名版本');
  }
  final keyBlob = reader.string();
  if (!_equal(keyBlob, base64Decode(trustedKey))) {
    throw const FormatException('星像签名公钥不匹配');
  }
  final namespace = reader.string(),
      reserved = reader.string(),
      algorithm = reader.string();
  final hashName = ascii.decode(algorithm);
  if (ascii.decode(namespace) != 'file' ||
      reserved.isNotEmpty ||
      (hashName != 'sha512' && hashName != 'sha256')) {
    throw const FormatException('星像签名参数无效');
  }
  final signature = _SshReader(reader.string());
  reader.requireEnd();
  if (ascii.decode(signature.string()) != 'ssh-ed25519') {
    throw const FormatException('星像签名算法无效');
  }
  final rawSignature = signature.string();
  signature.requireEnd();
  final publicKey = _SshReader(keyBlob);
  publicKey.string();
  final rawKey = publicKey.string();
  publicKey.requireEnd();
  final digest = (hashName == 'sha512' ? hashes.sha512 : hashes.sha256)
      .convert(checksums)
      .bytes;
  final signed = BytesBuilder()..add(ascii.encode('SSHSIG'));
  for (final field in [namespace, reserved, algorithm, digest]) {
    final size = ByteData(4)..setUint32(0, field.length);
    signed
      ..add(size.buffer.asUint8List())
      ..add(field);
  }
  if (rawSignature.length != 64 ||
      !await Ed25519().verify(
        signed.takeBytes(),
        signature: Signature(
          rawSignature,
          publicKey: SimplePublicKey(rawKey, type: KeyPairType.ed25519),
        ),
      )) {
    throw const FormatException('星像固件签名校验失败');
  }
  final result = <String, String>{};
  for (final line in const LineSplitter().convert(utf8.decode(checksums))) {
    if (line.isEmpty) continue;
    final match = RegExp(
      r'^([0-9a-f]{64})  \./([A-Za-z0-9._-]+)$',
    ).firstMatch(line);
    if (match == null || result.containsKey(match.group(2))) {
      throw const FormatException('星像校验清单无效');
    }
    result[match.group(2)!] = match.group(1)!;
  }
  final expected = {
    '$tag.bin',
    '$tag.uf2',
    'manifest.json',
    'starthermal-allowed-signers',
  };
  if (result.length != expected.length ||
      !result.keys.toSet().containsAll(expected)) {
    throw const FormatException('星像签名附件集合不匹配');
  }
  return result;
}

FirmwareArtifact parseStarThermalManifest(
  String source, {
  required String tag,
}) {
  final json = jsonDecode(source);
  if (json is! Map ||
      json['schema_version'] != 3 ||
      json['product_id'] != 'starthermal' ||
      json['device_model'] != 'StarThermal' ||
      !tag.startsWith('StarThermal-v') ||
      firmwareReleaseVersion(tag) == null ||
      json['firmware_tag'] != tag ||
      json['firmware_version'] != tag.substring(13) ||
      json['builder'] is! Map ||
      json['builder']['workflow_repository'] !=
          '$firmwareRepositoryOwner/$firmwareRepositoryName') {
    throw const FormatException('星像 manifest 产品或版本不匹配');
  }
  final artifacts = json['artifacts'];
  if (artifacts is! List || artifacts.length != 2) {
    throw const FormatException('星像 manifest 附件集合无效');
  }
  Map? binary;
  final formats = <String>{};
  for (final item in artifacts) {
    if (item is! Map) throw const FormatException('星像附件无效');
    final format = item['format'];
    final size = item['size'];
    if ((format != 'bin' && format != 'uf2') ||
        !formats.add(format as String) ||
        item['file'] != '$tag.$format' ||
        item['hardware_id'] != 'starthermal-rp2040-8m' ||
        item['flash_bytes'] != 8388608 ||
        item['max_firmware_bytes'] != starThermalMaximumImage ||
        item['role'] != (format == 'bin' ? 'ota' : 'recovery') ||
        item['transfer_protocol'] !=
            (format == 'bin' ? 'serial-ota-v1' : 'rp2040-uf2') ||
        size is! int ||
        size < 256 ||
        size >
            (format == 'bin'
                ? starThermalMaximumImage
                : starThermalMaximumImage * 2) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(item['sha256']?.toString() ?? '')) {
      throw const FormatException('星像附件硬件、分区或传输协议不匹配');
    }
    if (format == 'bin') binary = item;
  }
  final b = binary!;
  return FirmwareArtifact(
    file: b['file'] as String,
    size: b['size'] as int,
    sha256: b['sha256'] as String,
    environment: 'starthermal-rp2040-8m',
    hardwareProfile: FirmwareHardwareProfile.starthermal,
    flashBytes: 8388608,
    filesystemBytes: null,
    cpuHz: null,
    stabilityProfile: null,
  );
}

void validateStarThermalImage(Uint8List image, String tag) {
  if (image.length < 256 ||
      image.length > starThermalMaximumImage ||
      !tag.startsWith('StarThermal-') ||
      firmwareReleaseVersion(tag) == null ||
      !RegExp(
        '${RegExp.escape('STARTHERMAL-FIRMWARE:${tag.substring(12)}')}[\x00"]',
      ).hasMatch(latin1.decode(image))) {
    throw const FormatException('星像固件内部版本标识或大小不匹配');
  }
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _SshReader {
  _SshReader(this.data);
  final Uint8List data;
  int offset = 0;
  Uint8List take(int count) {
    if (count < 0 || count > data.length - offset) {
      throw const FormatException('签名数据不完整');
    }
    final result = Uint8List.sublistView(data, offset, offset + count);
    offset += count;
    return result;
  }

  int uint32() => ByteData.sublistView(take(4)).getUint32(0);
  Uint8List string() => take(uint32());
  void requireEnd() {
    if (offset != data.length) throw const FormatException('签名含额外数据');
  }
}
