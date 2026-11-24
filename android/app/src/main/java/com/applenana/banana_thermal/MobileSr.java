package com.applenana.banana_thermal;

import android.content.res.AssetManager;
import android.os.Handler;
import android.os.Looper;
import com.applenana.thermal.sr.SrEngine;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;
import java.util.*;
import java.util.concurrent.*;

/** The compiled GPU model, its buffers and every invocation share one thread. */
final class MobileSr {
    private final MethodChannel channel;
    private final SrEngine engine;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());

    MobileSr(AssetManager assets, BinaryMessenger messenger) {
        engine = new SrEngine(assets);
        channel = new MethodChannel(messenger, "banana_thermal/mobile_sr");
        channel.setMethodCallHandler((call, reply) -> {
            if (!call.method.equals("infer")) { reply.notImplemented(); return; }
            float[] x = call.argument("input");
            String prefer = call.argument("prefer");
            if (x == null || x.length != 120 * 90 ||
                    !("gpu".equals(prefer) || "cpu".equals(prefer))) {
                reply.error("input", "需要 120×90 热像和有效的处理器选项", null); return;
            }
            worker.execute(() -> {
                try {
                    Map<String,Object> response = engine.infer(x, prefer);
                    main.post(() -> reply.success(response));
                } catch (Exception | LinkageError e) {
                    engine.release();
                    main.post(() -> reply.error("inference", e.toString(), null));
                }
            });
        });
    }

    void close() {
        channel.setMethodCallHandler(null);
        worker.execute(engine::release);
        worker.shutdown();
    }
}
