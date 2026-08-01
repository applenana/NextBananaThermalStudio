import 'dart:convert';

import 'package:banana_thermal/update/app_update.dart';
import 'package:banana_thermal/update/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const digestA =
      'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const digestB =
      'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const digestC =
      'sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

  group('AppVersion', () {
    test('四段发布标签覆盖平台的三段内部版本', () {
      expect(
        resolveInstalledAppVersion('0.5.2', compiledReleaseVersion: '0.5.2.1'),
        '0.5.2.1',
      );
      expect(resolveInstalledAppVersion('0.5.2'), '0.5.2');
    });

    test('解析 v 前缀、构建号并比较多位版本', () {
      final current = AppVersion.tryParse('0.3.50+123')!;
      final newer = AppVersion.tryParse('v0.3.60')!;
      final equivalent = AppVersion.tryParse('0.3.50.0')!;

      expect(newer.compareTo(current), greaterThan(0));
      expect(current.compareTo(equivalent), 0);
      expect(
        AppVersion.tryParse(
          'v0.5.2.1',
        )!.compareTo(AppVersion.tryParse('0.5.2')!),
        1,
      );
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
    final releaseJson = <String, dynamic>{
      'tag_name': 'v0.3.50',
      'name': 'BananaThermal v0.3.50',
      'html_url':
          'https://github.com/applenana/NextBananaThermalStudio/releases/tag/v0.3.50',
      'body': '更新说明',
      'published_at': '2026-07-30T12:19:56Z',
      'assets': [
        {
          'name': 'BananaThermal-android-arm64-v8a.apk',
          'browser_download_url':
              'https://github.com/applenana/NextBananaThermalStudio/releases/download/v0.3.50/BananaThermal-android-arm64-v8a.apk',
          'content_type': 'application/vnd.android.package-archive',
          'size': 10,
        },
        {
          'name': 'BananaThermal-android.apk',
          'browser_download_url':
              'https://github.com/applenana/NextBananaThermalStudio/releases/download/v0.3.50/BananaThermal-android.apk',
          'content_type': 'application/vnd.android.package-archive',
          'size': 20,
          'digest': digestA,
        },
        {
          'name': 'BananaThermal-windows-x64-setup.exe',
          'browser_download_url':
              'https://github.com/applenana/NextBananaThermalStudio/releases/download/v0.3.50/BananaThermal-windows-x64-setup.exe',
          'content_type': 'application/vnd.microsoft.portable-executable',
          'size': 25,
          'digest': digestB,
        },
        {
          'name': 'BananaThermal-windows-x64.zip',
          'browser_download_url':
              'https://github.com/applenana/NextBananaThermalStudio/releases/download/v0.3.50/BananaThermal-windows-x64.zip',
          'content_type': 'application/zip',
          'size': 30,
          'digest': digestC,
        },
      ],
    };
    final release = AppRelease.fromJsonString(jsonEncode(releaseJson));

    test('解析发布信息与摘要', () {
      expect(release.tagName, 'v0.3.50');
      expect(release.publishedAt, DateTime.utc(2026, 7, 30, 12, 19, 56));
      expect(release.assets, hasLength(4));
      expect(release.assets[1].sha256, digestA.substring('sha256:'.length));
      expect(release.assets.first.canInstallSafely, isFalse);
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
      expect(
        () => AppReleaseAsset.fromJson(const {
          'name': 'BananaThermal-android.apk',
          'browser_download_url': 'https://example.com/update.apk',
        }),
        throwsFormatException,
      );
      expect(
        () => AppRelease.fromJson(const {
          'tag_name': 'v9.9.9',
          'html_url':
              'https://github.com/applenana/NextBananaThermalStudio/releases/tag/v0.3.50',
        }),
        throwsFormatException,
      );
    });

    test('镜像共识忽略说明和资产顺序，但拒绝摘要差异', () {
      final sameJson =
          jsonDecode(jsonEncode(releaseJson)) as Map<String, dynamic>;
      sameJson['body'] = '镜像缓存中的旧说明';
      sameJson['assets'] = (sameJson['assets'] as List).reversed.toList();
      final same = AppRelease.fromJson(sameJson);
      expect(release.hasSameVerificationIdentity(same), isTrue);

      final changedJson =
          jsonDecode(jsonEncode(releaseJson)) as Map<String, dynamic>;
      final changedAssets = changedJson['assets'] as List<dynamic>;
      (changedAssets[1] as Map<String, dynamic>)['digest'] = digestB;
      final changed = AppRelease.fromJson(changedJson);
      expect(release.hasSameVerificationIdentity(changed), isFalse);

      final consensus = selectAppReleaseConsensus({
        '镜像 A': release,
        '镜像 B': same,
        '被篡改的镜像': changed,
      });
      expect(
        consensus?.release.verificationIdentity,
        release.verificationIdentity,
      );
      expect(consensus?.sourceLabels, ['镜像 A', '镜像 B']);
      expect(consensus?.isCrossVerified, isTrue);
      expect(selectAppReleaseConsensus({'唯一镜像': release}), isNull);

      final single = selectAppReleaseConsensus({
        '唯一镜像': release,
      }, allowSingleSourceFallback: true);
      expect(single?.sourceLabels, ['唯一镜像']);
      expect(single?.isCrossVerified, isFalse);

      expect(
        selectAppReleaseConsensus({
          '镜像 A': release,
          '冲突镜像': changed,
        }, allowSingleSourceFallback: true),
        isNull,
      );

      expect(
        selectAppReleaseConsensus({
          '镜像 A1': release,
          '镜像 A2': same,
          '镜像 B1': changed,
          '镜像 B2': changed,
        }, allowSingleSourceFallback: true),
        isNull,
      );
    });
  });

  group('GitHub mirror URL', () {
    test('只为 HTTPS 官方地址生成代理 URL', () {
      final official = Uri.parse(
        'https://api.github.com/repos/applenana/NextBananaThermalStudio/releases/latest',
      );
      expect(
        githubProxyUri(Uri.parse('https://gh-proxy.com/'), official).toString(),
        'https://gh-proxy.com/https://api.github.com/repos/applenana/NextBananaThermalStudio/releases/latest',
      );
      expect(
        () => githubProxyUri(Uri.parse('http://mirror.example'), official),
        throwsFormatException,
      );
    });
  });
}
