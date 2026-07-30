import 'dart:convert';

import 'package:banana_thermal/update/app_update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppVersion', () {
    test('解析 v 前缀、构建号并比较多位版本', () {
      final current = AppVersion.tryParse('0.3.50+123')!;
      final newer = AppVersion.tryParse('v0.3.60')!;
      final equivalent = AppVersion.tryParse('0.3.50.0')!;

      expect(newer.compareTo(current), greaterThan(0));
      expect(current.compareTo(equivalent), 0);
    });

    test('正式版高于预发布版并遵循数字标识符顺序', () {
      final stable = AppVersion.tryParse('v1.0.0')!;
      final rc2 = AppVersion.tryParse('1.0.0-rc.2')!;
      final rc10 = AppVersion.tryParse('1.0.0-rc.10')!;

      expect(stable.compareTo(rc10), greaterThan(0));
      expect(rc10.compareTo(rc2), greaterThan(0));
    });

    test('拒绝无法安全比较的标签', () {
      expect(AppVersion.tryParse('latest'), isNull);
      expect(AppVersion.tryParse('v1.x.0'), isNull);
      expect(AppVersion.tryParse(''), isNull);
    });
  });

  group('AppRelease', () {
    final release = AppRelease.fromJsonString(
      jsonEncode({
        'tag_name': 'v0.3.50',
        'name': 'BananaThermal v0.3.50',
        'html_url':
            'https://github.com/applenana/NextBananaThermalStudio/releases/tag/v0.3.50',
        'body': '更新说明',
        'published_at': '2026-07-30T12:19:56Z',
        'assets': [
          {
            'name': 'BananaThermal-android-arm64-v8a.apk',
            'browser_download_url': 'https://example.com/arm64.apk',
            'content_type': 'application/vnd.android.package-archive',
            'size': 10,
          },
          {
            'name': 'BananaThermal-android.apk',
            'browser_download_url': 'https://example.com/universal.apk',
            'content_type': 'application/vnd.android.package-archive',
            'size': 20,
            'digest': 'sha256:abc',
          },
          {
            'name': 'BananaThermal-windows-x64-setup.exe',
            'browser_download_url': 'https://example.com/windows-setup.exe',
            'content_type': 'application/vnd.microsoft.portable-executable',
            'size': 25,
          },
          {
            'name': 'BananaThermal-windows-x64.zip',
            'browser_download_url': 'https://example.com/windows.zip',
            'content_type': 'application/zip',
            'size': 30,
          },
        ],
      }),
    );

    test('解析发布信息与摘要', () {
      expect(release.tagName, 'v0.3.50');
      expect(release.publishedAt, DateTime.utc(2026, 7, 30, 12, 19, 56));
      expect(release.assets, hasLength(4));
      expect(release.assets[1].digest, 'sha256:abc');
    });

    test('Android 优先选择 universal APK', () {
      expect(
        release.assetFor(AppUpdatePlatform.android)?.name,
        'BananaThermal-android.apk',
      );
    });

    test('Windows 优先选择安装版，其他平台安全回退', () {
      expect(
        release.assetFor(AppUpdatePlatform.windows)?.name,
        'BananaThermal-windows-x64-setup.exe',
      );
      expect(release.assetFor(AppUpdatePlatform.unsupported), isNull);
    });

    test('拒绝缺少有效版本或页面地址的响应', () {
      expect(
        () => AppRelease.fromJson(const {
          'tag_name': 'not-a-version',
          'html_url': 'https://example.com',
        }),
        throwsFormatException,
      );
    });
  });
}
