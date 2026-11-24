package com.applenana.thermal.sr;

import android.content.res.AssetManager;
import com.google.ai.edge.litert.*;
import java.util.*;

/** Use exclusively from the inference thread, including release. */
public final class SrEngine {
    private final AssetManager assets;
    private CompiledModel model;
    private List<TensorBuffer> inputs, outputs;
    private boolean gpu;
    private String gpuFailure;

    public SrEngine(AssetManager assets) { this.assets = assets; }

    public Map<String,Object> infer(float[] x, String prefer) throws Exception {
        if (x == null || x.length != 120 * 90 || !("gpu".equals(prefer) || "cpu".equals(prefer)))
            throw new IllegalArgumentException("需要 120×90 热像和有效的处理器选项");
        boolean wantGpu = "gpu".equals(prefer);
        if (!wantGpu) gpuFailure = null;
        if (wantGpu && gpuFailure == null) {
            try { return run(x, true); }
            catch (Exception | LinkageError e) {
                release();
                gpuFailure = e.toString();
            }
        }
        Map<String,Object> value = run(x, false);
        value.put("fallback", gpuFailure);
        return value;
    }

    private Map<String,Object> run(float[] x, boolean useGpu) throws Exception {
        long begin = System.nanoTime();
        if (model == null || gpu != useGpu) {
            release();
            model = CompiledModel.create(assets, "tiny3x.tflite",
                new CompiledModel.Options(useGpu ? Accelerator.GPU : Accelerator.CPU));
            inputs = model.createInputBuffers();
            outputs = model.createOutputBuffers();
            gpu = useGpu;
        }
        long loaded = System.nanoTime();
        inputs.get(0).writeFloat(x);
        model.run(inputs, outputs);
        float[] y = outputs.get(0).readFloat();
        long end = System.nanoTime();
        if (y.length != 360 * 270) throw new IllegalStateException("输出尺寸错误");
        for (int j = 0; j < y.length; j++) {
            if (!Float.isFinite(y[j])) throw new IllegalStateException("输出包含无效灰度");
            y[j] = Math.max(0, Math.min(1, y[j]));
        }
        Map<String,Object> result = new HashMap<>();
        result.put("output", y);
        result.put("device", useGpu ? "gpu" : "cpu");
        result.put("modelLoadMs", (loaded - begin) / 1000000);
        result.put("modelInferenceMs", (end - loaded) / 1000000);
        return result;
    }

    public void release() {
        if (outputs != null) { for (TensorBuffer b : outputs) b.close(); outputs = null; }
        if (inputs != null) { for (TensorBuffer b : inputs) b.close(); inputs = null; }
        if (model != null) { model.close(); model = null; }
    }

}
