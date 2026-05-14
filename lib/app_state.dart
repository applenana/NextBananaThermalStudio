/// 应用级状态: 串口连接 / 设备激活 / 热像数据 / 显示参数. 用 ChangeNotifier
/// 暴露给 UI, 由 provider 注入.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'filters/kalman.dart';
import 'fusion/fusion.dart';
import 'protocol/frame_parser.dart';
import 'render/render_params.dart';
import 'serial/serial_service.dart';

enum ConnectionStatus { disconnected, scanning, connecting, connected }

class LogEntry {
  final DateTime time;
  final String level; // info / warn / err / tx / rx
  final String text;
  const LogEntry(this.time, this.level, this.text);
}

class AppState extends ChangeNotifier {
  final SerialService _serial = SerialService();
  late final FrameParser _parser;

  StreamSubscription<Uint8List>? _byteSub;
  Timer? _thermalHeartbeat;
  Timer? _visibleHeartbeat;
  /// 掩插检测: 周期查看 native port 是否还开着. libserialport
  /// 在 Windows 上设备拔出后不会立刻在读流上报错, 必须主动轮询.
  Timer? _portWatchdog;
  /// 自动重连计时器.
  Timer? _reconnectTimer;
  /// 是否为用户主动断开 (点击断开按钮). 为 true 时不启动重连.
  bool _userDisconnect = false;
  /// 上次成功连接的端口 / 波特率, 用于重连优先尝试同一个端口.
  String? _lastPort;
  int _lastBaud = 115200;

  // ---------------- 连接 ----------------
  ConnectionStatus status = ConnectionStatus.disconnected;
  String? currentPort;
  String? deviceSerial;
  bool isActivated = false;
  Map<String, dynamic>? deviceInfo;
  /// 激活时间 (设备 GetSysInfo 返回的 ActivateTime, 字符串原样保留).
  String? activateTime;
  /// 保修截止时间 (设备 GetSysInfo 返回的 WarrantyTime).
  String? warrantyTime;

  // ---------------- 推流 ----------------
  bool thermalStreamEnabled = false;
  bool visibleStreamEnabled = false;

  // ---------------- 数据 ----------------
  double tMax = 0, tMin = 0, tAvg = 0;
  Float32List? thermalFrame; // 24x32 (已中心镜像后的温度场)
  Uint16List? visibleFrame; // 原始 RGB565 (未旋转, 仅供调试/导出使用)

  /// 可见光 RGB888 (顺时针旋转 90° 后), 长度 = visibleWidth * visibleHeight * 3.
  Uint8List? visibleRgb888;

  /// 旋转后的可见光宽 / 高 (原始宽高互换).
  int visibleWidth = 0;
  int visibleHeight = 0;

  // 温度历史 (画曲线)
  static const int maxHistory = 100;
  final List<double> historyMax = [];
  final List<double> historyMin = [];
  final List<double> historyAvg = [];

  // 滤波
  final KalmanFilter1D _kMax = KalmanFilter1D();
  final KalmanFilter1D _kMin = KalmanFilter1D();
  final KalmanFilter1D _kAvg = KalmanFilter1D();
  final KalmanFilter2D _kPix = KalmanFilter2D();
  bool kalmanScalarEnabled = true;
  bool kalmanPixelEnabled = false;

  // 平均温度异常剔除: 维护最近 7 帧, 若新值偏离中位数 > 阈值则替换为上次合法值.
  final List<double> _avgRecent = [];
  double? _lastValidAvg;
  /// 偏离中位数超过此值 (°C) 视为异常.
  double avgOutlierThreshold = 8.0;

  // ---------------- 显示 ----------------
  /// 统一的渲染参数 (插值+双边滤波+调色盘+融合). 实时画面与图片下载 Tab 共用同一份.
  RenderParams renderParams = const RenderParams();

  // ---------------- 日志 ----------------
  final List<LogEntry> logs = [];
  static const int maxLogs = 500;

  // ---------------- 串口缓冲 (供命令行回显) ----------------
  final BytesBuilder _textBuf = BytesBuilder(copy: false);

  AppState() {
    _parser = FrameParser(
      onThermal: _onThermalFrame,
      onVisible: _onVisibleFrame,
      onPassthrough: _onPassthrough,
    );
  }

  // ============================================================
  // 串口控制
  // ============================================================

  List<SerialPortInfo> listPorts() => SerialService.listPorts();

  /// 自动搜索热成像设备并连接.
  ///
  /// 流程: 状态置为 scanning -> 枚举端口 -> 逐个发 `GetSysInfo` 探测 ->
  /// 找到目标后用 [open] 正常打开 + 沿用现有字节回调链.
  ///
  /// 返回 true 表示连接成功. 若已连接会先断开重连. 探测期间会刷新 UI 显示
  /// "正在搜索 COMx" 进度日志.
  Future<bool> autoSearchAndConnect({int baud = 115200}) async {
    if (status == ConnectionStatus.connected) {
      await disconnect();
    }
    if (status == ConnectionStatus.scanning ||
        status == ConnectionStatus.connecting) {
      return false;
    }
    status = ConnectionStatus.scanning;
    _log('info', '开始自动搜索热成像设备...');
    notifyListeners();

    final found = await SerialService.searchTargetDevice(
      baud: baud,
      onProbe: (p) {
        _log('info', '探测 $p ...');
        notifyListeners();
      },
    );

    if (found.port == null) {
      status = ConnectionStatus.disconnected;
      _log('warn', '未发现热成像设备, 请检查 USB 连接');
      notifyListeners();
      return false;
    }

    _log('info', '发现设备 @ ${found.port}, 准备连接');
    notifyListeners();
    await connect(found.port!, baud: baud);
    // 探测阶段已经拿到 JSON, 直接消化, 不必等连接后再 GetSysInfo
    if (found.info != null) {
      _absorbDeviceInfo(found.info!);
      notifyListeners();
    }
    return status == ConnectionStatus.connected;
  }

  Future<void> connect(String portName, {int baud = 115200}) async {
    if (status == ConnectionStatus.connected) await disconnect();
    status = ConnectionStatus.connecting;
    notifyListeners();
    try {
      await _serial.open(portName, baud: baud);
      currentPort = portName;
      _lastPort = portName;
      _lastBaud = baud;
      _userDisconnect = false;
      _stopReconnectLoop();
      status = ConnectionStatus.connected;
      _byteSub = _serial.bytesStream.listen(
        _onBytes,
        onError: (e) {
          _log('err', '串口读错误: $e');
          _handleUnexpectedDisconnect();
        },
        onDone: () {
          _log('warn', '串口读流结束 (设备可能被拔出)');
          _handleUnexpectedDisconnect();
        },
        cancelOnError: false,
      );
      _startPortWatchdog();
      _log('info', '已打开 $portName @ $baud');
      // 自动探测设备
      Future.delayed(const Duration(milliseconds: 300), () {
        sendCommand('GetSysInfo');
      });
    } catch (e) {
      status = ConnectionStatus.disconnected;
      _log('err', '打开失败: $e');
    }
    notifyListeners();
  }

  Future<void> disconnect() async {
    _userDisconnect = true;
    _stopReconnectLoop();
    await _teardownConnection(reason: '已断开串口');
  }

  /// 内部: 拆除当前连接资源 (不改 _userDisconnect / 不动重连逻辑).
  Future<void> _teardownConnection({required String reason}) async {
    _stopPortWatchdog();
    _stopThermalHeartbeat();
    _stopVisibleHeartbeat();
    try { await _byteSub?.cancel(); } catch (_) {}
    _byteSub = null;
    await _serial.close();
    _parser.reset();
    status = ConnectionStatus.disconnected;
    currentPort = null;
    thermalFrame = null;
    visibleFrame = null;
    isActivated = false;
    deviceInfo = null;
    deviceSerial = null;
    activateTime = null;
    warrantyTime = null;
    _log('info', reason);
    notifyListeners();
  }

  /// 检测到非主动断开 (读错/读完/watchdog) 后调用: 释放连接并启动自动重连循环.
  void _handleUnexpectedDisconnect() {
    if (status == ConnectionStatus.disconnected) return;
    _teardownConnection(reason: '设备已断开, 准备重连');
    if (!_userDisconnect) {
      _startReconnectLoop();
    }
  }

  // ============================================================
  // 掩插看门狗 + 重连循环
  // ============================================================

  void _startPortWatchdog() {
    _portWatchdog?.cancel();
    _portWatchdog = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      if (status != ConnectionStatus.connected) return;
      if (!_serial.isOpen) {
        _log('warn', '检测到串口已关闭 (拔出?)');
        _handleUnexpectedDisconnect();
      }
    });
  }

  void _stopPortWatchdog() {
    _portWatchdog?.cancel();
    _portWatchdog = null;
  }

  void _startReconnectLoop() {
    if (_reconnectTimer != null) return;
    _log('info', '启动自动重连 (每 3s 重试)');
    _reconnectTimer =
        Timer.periodic(const Duration(seconds: 3), (_) async {
      if (_userDisconnect) {
        _stopReconnectLoop();
        return;
      }
      if (status == ConnectionStatus.connected ||
          status == ConnectionStatus.connecting ||
          status == ConnectionStatus.scanning) {
        return;
      }
      // 优先尝试上次端口, 失败再全局扫描.
      if (_lastPort != null) {
        final ports = SerialService.listPorts().map((e) => e.name).toList();
        if (ports.contains(_lastPort)) {
          await connect(_lastPort!, baud: _lastBaud);
          if (status == ConnectionStatus.connected) {
            _stopReconnectLoop();
            return;
          }
        }
      }
      final ok = await autoSearchAndConnect(baud: _lastBaud);
      if (ok) _stopReconnectLoop();
    });
  }

  void _stopReconnectLoop() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  /// 发送一行命令 (自动加 \n, 同步回显日志).
  void sendCommand(String line) {
    if (!_serial.isOpen) {
      _log('warn', '串口未连接, 忽略: $line');
      return;
    }
    final trimmed = line.trim();
    _serial.writeString('$trimmed\n');
    _log('tx', '> $trimmed');
  }

  // ============================================================
  // 字节流处理
  // ============================================================

  void _onBytes(Uint8List data) {
    if (_photoMode) {
      _onPhotoBytes(data);
      return;
    }
    _parser.feed(data);
  }

  /// 接收 FrameParser 认为不属于帧的字节(通常为 ASCII 响应文本).
  void _onPassthrough(Uint8List data) {
    _textBuf.add(data);
    final all = _textBuf.toBytes();
    int last = 0;
    for (int i = 0; i < all.length; i++) {
      if (all[i] == 0x0A) {
        final lineBytes = all.sublist(last, i);
        last = i + 1;
        _consumeTextLine(lineBytes);
      }
    }
    _textBuf.clear();
    if (last < all.length) {
      // 保留未遇 \n 的尾部(限长防爆)
      final tail = all.sublist(last);
      if (tail.length < 4096) {
        _textBuf.add(tail);
      }
    }
  }

  void _consumeTextLine(Uint8List bytes) {
    // 帧的 magic 是 'BEGIN' / 'VBEG', 不会以独立文本行出现; 但帧里偶尔会
    // 误命中 0x0A — 容忍并显示 ASCII 可打印部分.
    final asAscii = bytes.where((b) => b == 0x09 || (b >= 0x20 && b < 0x7F))
        .toList();
    if (asAscii.isEmpty) return;
    final text = String.fromCharCodes(asAscii).trimRight();
    if (text.isEmpty) return;

    _log('rx', text);

    // 设备信息 JSON
    if (text.startsWith('{') && text.endsWith('}')) {
      try {
        final j = jsonDecode(text) as Map<String, dynamic>;
        if (j.containsKey('Activated') ||
            j.containsKey('isActivated') ||
            j.containsKey('Serial') ||
            j.containsKey('SerialNum')) {
          _absorbDeviceInfo(j);
          _log('info', '设备信息更新, 激活=$isActivated, SN=$deviceSerial');
          notifyListeners();
        }
      } catch (_) {}
    }
  }

  /// 统一吸收 GetSysInfo 返回的 JSON 字段, 兼容 Python/固件两套 key 命名.
  void _absorbDeviceInfo(Map<String, dynamic> j) {
    deviceInfo = j;
    deviceSerial =
        (j['Serial'] ?? j['SerialNum'])?.toString() ?? deviceSerial;
    final actField = j['Activated'] ?? j['isActivated'];
    isActivated = (actField == true) ||
        (actField?.toString().toLowerCase() == 'true');
    final at = j['ActivateTime']?.toString();
    if (at != null && at.isNotEmpty) activateTime = at;
    final wt = j['WarrantyTime']?.toString();
    if (wt != null && wt.isNotEmpty) warrantyTime = wt;
  }

  // ============================================================
  // 帧回调
  // ============================================================

  void _onThermalFrame(double mx, double mn, double av, Float32List frame) {
    // 异常剔除: 平均温度偶发大跳变, 用滚动中位数过滤.
    if (_avgRecent.length >= 3) {
      final sorted = List<double>.from(_avgRecent)..sort();
      final median = sorted[sorted.length >> 1];
      if ((av - median).abs() > avgOutlierThreshold) {
        av = _lastValidAvg ?? median;
      }
    }
    _avgRecent.add(av);
    if (_avgRecent.length > 7) _avgRecent.removeAt(0);
    _lastValidAvg = av;
    if (kalmanScalarEnabled) {
      mx = _kMax.update(mx);
      mn = _kMin.update(mn);
      av = _kAvg.update(av);
    }
    final pix = kalmanPixelEnabled ? _kPix.filter(frame) : frame;
    // 垂直翻转 (上下镜像): 设备热像与显示方向上下相反.
    const int tw = 32, th = 24;
    final mirrored = Float32List(tw * th);
    for (int y = 0; y < th; y++) {
      final srcOff = (th - 1 - y) * tw;
      final dstOff = y * tw;
      for (int x = 0; x < tw; x++) {
        mirrored[dstOff + x] = pix[srcOff + x];
      }
    }
    tMax = mx;
    tMin = mn;
    tAvg = av;
    thermalFrame = mirrored;
    historyMax.add(mx);
    historyMin.add(mn);
    historyAvg.add(av);
    while (historyMax.length > maxHistory) {
      historyMax.removeAt(0);
      historyMin.removeAt(0);
      historyAvg.removeAt(0);
    }
    notifyListeners();
  }

  void _onVisibleFrame(int w, int h, Uint16List frame) {
    visibleFrame = frame;
    if (visibleRgb888 == null) {
      _log('info', '可见光首帧: 原始 ${w}x$h, 旋转后 ${h}x$w');
    }
    // 顺时针旋转 90°: 新宽 = h, 新高 = w
    // 反向映射: 新(xp, yp) <- 原(x=yp, y=h-1-xp)
    final newW = h, newH = w;
    final rgb = Uint8List(newW * newH * 3);
    for (int yp = 0; yp < newH; yp++) {
      for (int xp = 0; xp < newW; xp++) {
        final srcX = yp;
        final srcY = h - 1 - xp;
        final v = frame[srcY * w + srcX];
        final r5 = (v >> 11) & 0x1F;
        final g6 = (v >> 5) & 0x3F;
        final b5 = v & 0x1F;
        final dj = (yp * newW + xp) * 3;
        rgb[dj] = (r5 << 3) | (r5 >> 2);
        rgb[dj + 1] = (g6 << 2) | (g6 >> 4);
        rgb[dj + 2] = (b5 << 3) | (b5 >> 2);
      }
    }
    visibleRgb888 = rgb;
    visibleWidth = newW;
    visibleHeight = newH;
    notifyListeners();
  }

  // ============================================================
  // 推流心跳
  // ============================================================

  void setThermalStream(bool on) {
    thermalStreamEnabled = on;
    if (on) {
      sendCommand('stream');
      _startThermalHeartbeat();
    } else {
      _stopThermalHeartbeat();
      sendCommand('streaming stoped');
    }
    notifyListeners();
  }

  void setVisibleStream(bool on) {
    visibleStreamEnabled = on;
    if (on) {
      sendCommand('vstream');
      _startVisibleHeartbeat();
      // 打开可见光时, 若融合处于关闭, 自动切换到 blend 以便用户立刻看到混合效果.
      if (renderParams.fusion.mode == FusionMode.off) {
        renderParams = renderParams.copyWith(
          fusion: FusionParams(
            mode: FusionMode.blend,
            gamma: renderParams.fusion.gamma,
            alpha: renderParams.fusion.alpha,
            edgeStrength: renderParams.fusion.edgeStrength,
            edgeThresh: renderParams.fusion.edgeThresh,
            edgeWidth: renderParams.fusion.edgeWidth,
            edgeColor: renderParams.fusion.edgeColor,
          ),
        );
      }
    } else {
      _stopVisibleHeartbeat();
      sendCommand('vstream stoped');
    }
    notifyListeners();
  }

  void _startThermalHeartbeat() {
    _stopThermalHeartbeat();
    _thermalHeartbeat = Timer.periodic(
        const Duration(milliseconds: 500), (_) => sendCommand('stream'));
  }

  void _stopThermalHeartbeat() {
    _thermalHeartbeat?.cancel();
    _thermalHeartbeat = null;
  }

  void _startVisibleHeartbeat() {
    _stopVisibleHeartbeat();
    _visibleHeartbeat = Timer.periodic(
        const Duration(milliseconds: 500), (_) => sendCommand('vstream'));
  }

  void _stopVisibleHeartbeat() {
    _visibleHeartbeat?.cancel();
    _visibleHeartbeat = null;
  }

  // ============================================================
  // 显示参数 setter
  // ============================================================

  /// 更新渲染参数 (任意字段). UI 控件调用.
  void updateRenderParams(RenderParams p) {
    renderParams = p;
    notifyListeners();
  }

  /// 当前正在下载的图片已累积字节快照. 供 UI 边收边解析展示部分画面.
  /// 未在下载或缓冲为空时返回 null.
  Uint8List? get photoPartialBytes {
    if (_photoCompleter == null) return null;
    if (_photoBuf.length == 0) return null;
    return _photoBuf.toBytes();
  }

  void setKalmanScalar(bool v) {
    kalmanScalarEnabled = v;
    if (!v) {
      _kMax.reset();
      _kMin.reset();
      _kAvg.reset();
    }
    notifyListeners();
  }

  void setKalmanPixel(bool v) {
    kalmanPixelEnabled = v;
    if (!v) _kPix.reset();
    notifyListeners();
  }

  // ============================================================
  // 日志
  // ============================================================

  /// 心跳相关流量(stream/vstream 命令及其状态回执): 默认隐藏防刷屏.
  bool hideHeartbeatLog = true;

  static const Set<String> _heartbeatTx = {
    '> stream',
    '> vstream',
    '> streaming stoped',
    '> vstream stoped',
  };
  static const Set<String> _heartbeatRx = {
    'streaming started',
    'streaming stoped',
    'vstream started',
    'vstream stoped',
    'stream started',
    'stream stoped',
  };

  bool _isHeartbeatTraffic(String level, String text) {
    final t = text.trim().toLowerCase();
    if (level == 'tx') return _heartbeatTx.contains(t);
    if (level == 'rx') return _heartbeatRx.contains(t);
    return false;
  }

  void _log(String level, String text) {
    if (hideHeartbeatLog && _isHeartbeatTraffic(level, text)) return;
    logs.add(LogEntry(DateTime.now(), level, text));
    while (logs.length > maxLogs) {
      logs.removeAt(0);
    }
    notifyListeners();
  }

  /// 一次性关闭所有推流 (进入图库 tab 时调用).
  void stopAllStreams() {
    if (thermalStreamEnabled) setThermalStream(false);
    if (visibleStreamEnabled) setVisibleStream(false);
  }

  void clearLogs() {
    logs.clear();
    notifyListeners();
  }

  // ============================================================
  // 图库: check / download 独占字节流
  // ============================================================

  bool _photoMode = false;
  bool _photoIsJson = false;
  bool _photoIsHexDump = false;
  bool _hexDumpStarted = false;
  int _photoJsonDepth = 0;
  final BytesBuilder _photoBuf = BytesBuilder();
  final BytesBuilder _photoLineBuf = BytesBuilder();
  int _photoExpected = 0;
  Completer<Uint8List>? _photoCompleter;
  void Function(int received, int total)? _photoProgress;

  void _onPhotoBytes(Uint8List data) {
    if (_photoCompleter == null) return;
    if (_photoIsJson) {
      // 累积直到大括号配对. 未见过 `{` 之前的字节(残余 stream 帧/文本提示)全部丢弃.
      for (final b in data) {
        if (_photoJsonDepth == 0 && b != 0x7B) continue;
        _photoBuf.addByte(b);
        if (b == 0x7B /* { */) {
          _photoJsonDepth++;
        } else if (b == 0x7D /* } */) {
          _photoJsonDepth--;
          if (_photoJsonDepth == 0) {
            _finishPhoto();
            return;
          }
        }
      }
      return;
    }
    if (_photoIsHexDump) {
      // 按 \n 拆行, 解析 hexdump 行: "00000000: 41 20 ... |A ...|"
      for (final b in data) {
        if (b == 0x0A) {
          final line = _photoLineBuf.toBytes();
          _photoLineBuf.clear();
          _consumeHexDumpLine(line);
          if (!_photoMode) return;
        } else if (b != 0x0D) {
          _photoLineBuf.addByte(b);
        }
      }
    }
  }

  void _consumeHexDumpLine(Uint8List lineBytes) {
    if (lineBytes.isEmpty) return;
    final text = String.fromCharCodes(
        lineBytes.where((b) => b >= 0x20 && b < 0x7F));
    if (text.isEmpty) return;
    if (text.contains('BEGIN FILE DATA')) {
      _hexDumpStarted = true;
      return;
    }
    if (text.contains('END FILE DATA')) {
      _finishPhoto();
      return;
    }
    if (!_hexDumpStarted) return;
    // 格式: "00000000: 41 20 00 00 ... |A ...|"
    final colon = text.indexOf(':');
    if (colon < 0) return;
    var hexPart = text.substring(colon + 1);
    final bar = hexPart.indexOf('|');
    if (bar >= 0) hexPart = hexPart.substring(0, bar);
    final tokens = hexPart.split(RegExp(r'\s+'));
    for (final tk in tokens) {
      if (tk.length != 2) continue;
      final v = int.tryParse(tk, radix: 16);
      if (v == null) continue;
      _photoBuf.addByte(v);
    }
    _photoProgress?.call(_photoBuf.length, _photoExpected);
  }

  void _finishPhoto() {
    final c = _photoCompleter;
    final out = _photoBuf.toBytes();
    _photoBuf.clear();
    _photoLineBuf.clear();
    _photoMode = false;
    _photoCompleter = null;
    _photoProgress = null;
    _photoIsJson = false;
    _photoIsHexDump = false;
    _hexDumpStarted = false;
    _photoJsonDepth = 0;
    _photoExpected = 0;
    c?.complete(out);
  }

  void _abortPhoto(Object error) {
    final c = _photoCompleter;
    _photoBuf.clear();
    _photoLineBuf.clear();
    _photoMode = false;
    _photoCompleter = null;
    _photoProgress = null;
    _photoIsJson = false;
    _photoIsHexDump = false;
    _hexDumpStarted = false;
    _photoJsonDepth = 0;
    _photoExpected = 0;
    c?.completeError(error);
  }

  /// 拉取片上图片列表. 发送 `check\n`, 等待 JSON 响应, 解析为 [PhotoMeta] 列表.
  Future<List<PhotoMeta>> fetchPhotoList(
      {Duration timeout = const Duration(seconds: 4)}) async {
    if (!_serial.isOpen) throw StateError('串口未连接');
    if (_photoMode) throw StateError('图库忙, 请稍候');
    // 暂停推流以减少干扰.
    final hadTherm = thermalStreamEnabled;
    final hadVis = visibleStreamEnabled;
    _stopThermalHeartbeat();
    _stopVisibleHeartbeat();
    _photoMode = true;
    _photoIsJson = true;
    _photoJsonDepth = 0;
    _photoBuf.clear();
    _photoCompleter = Completer<Uint8List>();
    _serial.writeString('check\n');
    _log('tx', '> check');
    Uint8List bytes;
    try {
      bytes = await _photoCompleter!.future.timeout(timeout, onTimeout: () {
        _abortPhoto(TimeoutException('check 超时'));
        throw TimeoutException('check 超时');
      });
    } catch (e) {
      if (hadTherm) setThermalStream(true);
      if (hadVis) setVisibleStream(true);
      rethrow;
    }
    // 提取首个 { ... } 块.
    final s = String.fromCharCodes(bytes.where((b) => b >= 0x20 || b == 0x0A));
    final i = s.indexOf('{');
    final j = s.lastIndexOf('}');
    if (i < 0 || j <= i) {
      if (hadTherm) setThermalStream(true);
      if (hadVis) setVisibleStream(true);
      throw FormatException('未收到有效 JSON');
    }
    final j2 = s.substring(i, j + 1);
    // 设备发的 JSON 可能含 inf / -inf / nan (Python 风格), Dart 的 jsonDecode 不接受.
    // 用正则把这些非法值替换为 null 后再解析.
    final sanitized = j2.replaceAllMapped(
      RegExp(r':\s*(-?inf(?:inity)?|nan)\b', caseSensitive: false),
      (_) => ': null',
    );
    final root = jsonDecode(sanitized) as Map<String, dynamic>;
    final arr = (root['photos'] as List?) ?? const [];
    final out = <PhotoMeta>[];
    for (final e in arr) {
      if (e is Map) {
        out.add(PhotoMeta.fromJson(e.cast<String, dynamic>()));
      }
    }
    _log('info', '获取图片列表: ${out.length} 张');
    if (hadTherm) setThermalStream(true);
    if (hadVis) setVisibleStream(true);
    return out;
  }

  /// 下载一张图片原始数据 (size 字节). 通过 [onProgress] 回报进度.
  Future<Uint8List> downloadPhoto(
    String filename,
    int size, {
    void Function(int received, int total)? onProgress,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!_serial.isOpen) throw StateError('串口未连接');
    if (_photoMode) throw StateError('图库忙, 请稍候');
    final hadTherm = thermalStreamEnabled;
    final hadVis = visibleStreamEnabled;
    _stopThermalHeartbeat();
    _stopVisibleHeartbeat();
    _photoMode = true;
    _photoIsJson = false;
    _photoIsHexDump = true;
    _hexDumpStarted = false;
    _photoExpected = size;
    _photoBuf.clear();
    _photoLineBuf.clear();
    _photoProgress = onProgress;
    _photoCompleter = Completer<Uint8List>();
    _serial.writeString('download $filename\n');
    _log('tx', '> download $filename');
    try {
      final bytes = await _photoCompleter!.future.timeout(timeout, onTimeout: () {
        _abortPhoto(TimeoutException('download 超时'));
        throw TimeoutException('download 超时');
      });
      _log('info', '下载完成: $filename (${bytes.length} B)');
      if (hadTherm) setThermalStream(true);
      if (hadVis) setVisibleStream(true);
      return bytes;
    } catch (e) {
      if (hadTherm) setThermalStream(true);
      if (hadVis) setVisibleStream(true);
      rethrow;
    }
  }

  // ============================================================

  @override
  Future<void> dispose() async {
    await _byteSub?.cancel();
    _stopThermalHeartbeat();
    _stopVisibleHeartbeat();
    await _serial.dispose();
    super.dispose();
  }
}

/// 片上单张图片元数据 (来自 `check` 命令返回的 JSON).
class PhotoMeta {
  final int index;
  final String filename;
  final int size;
  final String? mode;          // 'thermal' / 'dual' 等
  final String? dataFormat;    // 'HTPH-V2' / 'raw' 等
  final double? tempMax;
  final double? tempMin;

  const PhotoMeta({
    required this.index,
    required this.filename,
    required this.size,
    this.mode,
    this.dataFormat,
    this.tempMax,
    this.tempMin,
  });

  factory PhotoMeta.fromJson(Map<String, dynamic> j) => PhotoMeta(
        index: (j['index'] as num?)?.toInt() ?? -1,
        filename: j['filename']?.toString() ??
            'photo_${(j['index'] as num?)?.toInt() ?? 0}.dat',
        size: (j['size'] as num?)?.toInt() ?? 0,
        mode: j['mode']?.toString(),
        dataFormat: j['dataFormat']?.toString(),
        tempMax: (j['temperatureMax'] as num?)?.toDouble(),
        tempMin: (j['temperatureMin'] as num?)?.toDouble(),
      );
}
