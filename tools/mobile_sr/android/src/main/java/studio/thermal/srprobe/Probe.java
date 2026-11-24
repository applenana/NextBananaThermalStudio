package studio.thermal.srprobe;

import android.app.Activity;
import android.graphics.Bitmap;
import android.graphics.Typeface;
import android.graphics.drawable.BitmapDrawable;
import android.os.Bundle;
import android.os.Build;
import android.util.Log;
import android.view.View;
import android.widget.*;
import com.google.ai.edge.litert.*;
import java.io.*;
import java.nio.*;
import java.util.*;

public final class Probe extends Activity {
    private LinearLayout page;
    private TextView output, status, resultTitle;
    private ImageView source, resultView;
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    private TextView label(String value, int size, boolean bold) {
        TextView v = new TextView(this);
        v.setText(value);
        v.setTextSize(size);
        v.setTextColor(bold ? 0xfff5f5f2 : 0xffcdd3cf);
        if (bold) v.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        v.setPadding(0, dp(6), 0, dp(4));
        page.addView(v);
        return v;
    }
    private ImageView preview(String description) {
        ImageView v = new ImageView(this);
        v.setScaleType(ImageView.ScaleType.FIT_CENTER);
        v.setBackgroundColor(0xff070908);
        v.setContentDescription(description);
        page.addView(v, -1, dp(184));
        return v;
    }
    private Bitmap bitmap(float[] values, int width, int height) {
        int[] pixels = new int[values.length];
        for (int j = 0; j < pixels.length; j++) {
            int gray = Math.round(255 * Math.min(1f, Math.max(0f, values[j])));
            pixels[j] = 0xff000000 | gray * 0x010101;
        }
        return Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888);
    }
    private void show(ImageView view, Bitmap image) {
        BitmapDrawable drawable = new BitmapDrawable(getResources(), image);
        drawable.setFilterBitmap(false);
        view.setImageDrawable(drawable);
    }
    private void report(String text) {
        Log.i("ThermalSR", text);
        runOnUiThread(() -> output.append(text + "\n"));
    }
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setBackgroundColor(0xff171b19);
        scroll.setOnApplyWindowInsetsListener((v, insets) -> {
            v.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(),
                insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            return insets;
        });
        page = new LinearLayout(this);
        page.setOrientation(LinearLayout.VERTICAL);
        page.setPadding(dp(16), dp(8), dp(16), dp(16));
        scroll.addView(page);
        setContentView(scroll);
        label("热像超分对照", 22, true);
        status = label("正在读取内置样本…", 14, false);
        label("原图 · 120 × 90", 16, true);
        source = preview("内置热像原图");
        resultTitle = label("3 倍超分 · 360 × 270", 16, true);
        resultView = preview("手机模型输出");
        label("单帧耗时", 16, true);
        output = label(Build.MODEL + " / API " + Build.VERSION.SDK_INT + "\n", 14, false);
        new Thread(() -> {
            try {
                float[] x = load("input.f32", 90 * 120);
                Bitmap inputImage = bitmap(x, 120, 90);
                runOnUiThread(() -> show(source, inputImage));
                float[] ref = load("reference.f32", 270 * 360);
                int successes = 0;
                for (Accelerator mode : new Accelerator[]{Accelerator.CPU, Accelerator.GPU}) {
                    runOnUiThread(() -> status.setText("内置样本 · 正在测试 " + mode + "…"));
                    try {
                        Bitmap resultImage = bitmap(measure(mode, x, ref), 360, 270);
                        runOnUiThread(() -> {
                            show(resultView, resultImage);
                            resultTitle.setText("3 倍超分 · 360 × 270 · " + mode + " 请求");
                        });
                        successes++;
                    }
                    catch (Exception | LinkageError e) { report(mode + ": " + e); }
                }
                String outcome = successes == 2 ? "CPU、GPU 测试完成" :
                    successes == 1 ? "一项测试失败，已保留成功结果" : "推理失败，详见下方记录";
                runOnUiThread(() -> status.setText("内置样本 · " + outcome));
            } catch (Exception e) {
                runOnUiThread(() -> status.setText("读取样本失败：" + e.getMessage()));
                report(e.toString());
            }
        }, "sr-probe").start();
    }
    private float[] load(String name, int count) throws IOException {
        byte[] bytes = new byte[count * 4];
        try (DataInputStream in = new DataInputStream(getAssets().open(name))) {
            in.readFully(bytes);
            if (in.read() != -1) throw new IOException("Invalid length: " + name);
        }
        float[] dst = new float[count];
        ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().get(dst);
        return dst;
    }
    private float[] measure(Accelerator mode, float[] x, float[] ref) throws Exception {
        long start = System.nanoTime();
        try (CompiledModel model = CompiledModel.create(getAssets(), "tiny3x.tflite",
                new CompiledModel.Options(mode))) {
            List<TensorBuffer> ins = model.createInputBuffers();
            List<TensorBuffer> outs = model.createOutputBuffers();
            try {
                double initMs = (System.nanoTime() - start) / 1e6;
                double[] times = new double[100];
                double max = 0;
                float[] result = null;
                for (int i = -10; i < times.length; i++) {
                    long t = System.nanoTime();
                    ins.get(0).writeFloat(x);
                    model.run(ins, outs);
                    result = outs.get(0).readFloat();
                    if (i >= 0) times[i] = (System.nanoTime() - t) / 1e6;
                    if (result.length != ref.length) throw new IOException("Output size mismatch");
                    for (int j = 0; j < ref.length; j++) {
                        if (!Float.isFinite(result[j])) throw new IOException("Non-finite output");
                        max = Math.max(max, Math.abs(result[j] - ref[j]));
                    }
                }
                Arrays.sort(times);
                report(String.format(Locale.ROOT,
                    "%s requested: init %.1f ms, P50 %.2f ms, P95 %.2f ms, max |error| %.6f",
                    mode, initMs, (times[49]+times[50])/2, times[94], max));
                return result;
            } finally {
                for (TensorBuffer b : outs) b.close();
                for (TensorBuffer b : ins) b.close();
            }
        }
    }
}
