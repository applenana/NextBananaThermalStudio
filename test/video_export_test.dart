import 'dart:typed_data';

import 'package:banana_thermal/render/render_params.dart';
import 'package:banana_thermal/render/render_pipeline.dart';
import 'package:banana_thermal/render/video_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'StarThermal export preserves preview colours at display resolution',
    () {
      final temperatures = Float32List.fromList(
        List.generate(
          120 * 90,
          (i) => (i % 120 < 60 ? 25.0 : 40.0) + (i ~/ 120) / 90,
        ),
      );
      final preview = renderPipeline(
        thermalFrame: temperatures,
        srcW: 120,
        srcH: 90,
        params: const RenderParams(upsampleScale: 2, bilateralEnabled: false),
      );
      final rgba = Uint8List(preview.width * preview.height * 4);
      for (var i = 0; i < preview.width * preview.height; i++) {
        rgba.setRange(i * 4, i * 4 + 3, preview.rgb, i * 3);
        rgba[i * 4 + 3] = 255;
      }
      final original = Uint8List.fromList(rgba);
      final scale = thermalVideoDisplayScale(preview.width, preview.height);
      final output = scaleVideoRgba(rgba, preview.width, preview.height, scale);
      final width = preview.width * scale;
      final height = preview.height * scale;
      expect((width, height), (960, 720));
      // Every output pixel must match the nearest preview pixel, with no
      // second smoothing pass or palette changes before encoding.
      var mismatches = 0;
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final source = ((y ~/ scale) * preview.width + x ~/ scale) * 4;
          final target = (y * width + x) * 4;
          for (var c = 0; c < 4; c++) {
            if (output[target + c] != rgba[source + c]) mismatches++;
          }
        }
      }
      expect(mismatches, 0);
      expect(rgba, original);
    },
  );

  test(
    'display sizing preserves aspect and never downsamples large frames',
    () {
      for (final (w, h) in [
        (120, 90),
        (240, 180),
        (256, 192),
        (180, 240),
        (32, 32),
      ]) {
        final scale = thermalVideoDisplayScale(w, h);
        expect(w * scale, greaterThanOrEqualTo(720));
        expect(h * scale, greaterThanOrEqualTo(720));
        expect(w * scale / (h * scale), w / h);
      }
      expect(thermalVideoDisplayScale(1920, 1080), 1);
      expect(thermalVideoDisplayScale(3840, 2160), 1);
      expect(() => thermalVideoDisplayScale(0, 90), throwsArgumentError);
      expect(() => scaleVideoRgba(Uint8List(3), 1, 1, 2), throwsArgumentError);
    },
  );

  test(
    'encoding uses constant desktop quality and bounded hardware bitrate',
    () {
      final args = videoExportFfmpegArgs(
        width: 960,
        height: 720,
        fps: 30,
        outputPath: 'video.mp4',
      );
      expect(args[args.indexOf('-crf') + 1], '18');
      expect(args, isNot(contains('-b:v')));
      expect(
        args[args.indexOf('-pix_fmt', args.indexOf('-c:v')) + 1],
        'yuv420p',
      );
      expect(videoExportBitrate(960, 720, 30), greaterThanOrEqualTo(4000000));
      expect(videoExportBitrate(3840, 2160, 60), 20000000);
    },
  );
}
