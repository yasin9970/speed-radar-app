import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:flutter_tts/flutter_tts.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Allow both Landscape & Portrait
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
    DeviceOrientation.portraitUp,
  ]);

  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint("Camera error: $e");
  }
  runApp(TurfBeastRadarApp());
}

class TurfBeastRadarApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: TurfLandscapeScreen(),
    );
  }
}

class BowlerStats {
  String name;
  int balls = 0;
  int noBalls = 0;
  double topSpeed = 0.0;
  double totalSpeed = 0.0;

  BowlerStats({required this.name});
  double get avgSpeed => balls == 0 ? 0.0 : totalSpeed / balls;
}

class DeliveryRecord {
  final String ballTag;
  final String bowler;
  final double speed;
  final bool isNoBall;
  final double durationMs;

  DeliveryRecord({
    required this.ballTag,
    required this.bowler,
    required this.speed,
    required this.isNoBall,
    required this.durationMs,
  });
}

class TurfLandscapeScreen extends StatefulWidget {
  @override
  _TurfLandscapeScreenState createState() => _TurfLandscapeScreenState();
}

class _TurfLandscapeScreenState extends State<TurfLandscapeScreen> {
  CameraController? _controller;
  final FlutterTts _tts = FlutterTts();

  // Turf Match Settings
  double pitchLength = 13.5;
  double speedLimit = 85.0;
  bool isNightMode = false;
  bool isBowlerOnLeft = true;
  bool isDetecting = false;

  // Draggable Calibration Lines
  double releaseLineX = 0.20;
  double creaseLineX = 0.80;

  // Radar Processing State
  double currentSpeed = 0.0;
  double matchTopSpeed = 0.0;
  bool isNoBall = false;
  int? _startMicroseconds;
  List<int>? _prevYPlane;
  bool _coolingDown = false;

  // Bowlers & Scorecard
  List<BowlerStats> bowlers = [
    BowlerStats(name: "Bowler 1"),
    BowlerStats(name: "Bowler 2"),
  ];
  int activeBowlerIndex = 0;
  int legalBallsCount = 0;
  List<DeliveryRecord> history = [];
  DeliveryRecord? lastDelivery;

  @override
  void initState() {
    super.initState();
    _initTTS();
    _initCamera();
  }

  void _initTTS() async {
    await _tts.setLanguage("en-US");
    await _tts.setSpeechRate(0.70);
    await _tts.setPitch(1.0);
  }

  void _initCamera() async {
    if (cameras.isEmpty) return;
    _controller = CameraController(
      cameras[0],
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await _controller!.initialize();
    if (!mounted) return;

    _controller!.startImageStream((CameraImage image) {
      if (isDetecting && !_coolingDown) {
        _processHighSpeedFrame(image);
      }
    });

    setState(() {});
  }

  void _processHighSpeedFrame(CameraImage image) {
    final yBytes = image.planes[0].bytes;
    int width = image.width;
    int height = image.height;

    if (_prevYPlane == null || _prevYPlane!.length != yBytes.length) {
      _prevYPlane = List<int>.from(yBytes);
      return;
    }

    double bX = isBowlerOnLeft ? releaseLineX : creaseLineX;
    double cX = isBowlerOnLeft ? creaseLineX : releaseLineX;

    int colBowler = (width * bX).toInt().clamp(0, width - 1);
    int colCrease = (width * cX).toInt().clamp(0, width - 1);

    int motionBowler = 0;
    int motionCrease = 0;
    int threshold = isNightMode ? 52 : 38;

    int startY = (height * 0.20).toInt();
    int endY = (height * 0.75).toInt();

    for (int row = startY; row < endY; row += 3) {
      int idxB = row * width + colBowler;
      int idxC = row * width + colCrease;

      if ((yBytes[idxB] - _prevYPlane![idxB]).abs() > threshold) motionBowler++;
      if ((yBytes[idxC] - _prevYPlane![idxC]).abs() > threshold) motionCrease++;
    }

    _prevYPlane = List<int>.from(yBytes);
    int now = DateTime.now().microsecondsSinceEpoch;

    // Standing release snap filter
    if (motionBowler >= 8 && motionBowler <= 45 && _startMicroseconds == null) {
      _startMicroseconds = now;
    }

    // Crease arrival trigger
    if (motionCrease >= 8 && motionCrease <= 50 && _startMicroseconds != null) {
      int delta = now - _startMicroseconds!;
      double seconds = delta / 1000000.0;

      if (seconds >= 0.16 && seconds <= 1.35) {
        double speed = (pitchLength / seconds) * 3.6;
        _registerDelivery(speed, seconds * 1000.0);
      }
      _startMicroseconds = null;
    }

    if (_startMicroseconds != null && (now - _startMicroseconds!) > 1500000) {
      _startMicroseconds = null;
    }
  }

  void _triggerTorchStrobe() async {
    try {
      for (int i = 0; i < 4; i++) {
        await _controller?.setFlashMode(FlashMode.torch);
        await Future.delayed(Duration(milliseconds: 90));
        await _controller?.setFlashMode(FlashMode.off);
        await Future.delayed(Duration(milliseconds: 90));
      }
    } catch (_) {}
  }

  void _registerDelivery(double speed, double durationMs) async {
    _coolingDown = true;
    bool over = speed > speedLimit;

    if (!over) legalBallsCount++;
    int overNum = legalBallsCount ~/ 6;
    int ballNum = legalBallsCount % 6;
    String tag = over ? "NB" : "$overNum.$ballNum";

    if (speed > matchTopSpeed) matchTopSpeed = speed;

    BowlerStats cur = bowlers[activeBowlerIndex];
    cur.balls++;
    cur.totalSpeed += speed;
    if (speed > cur.topSpeed) cur.topSpeed = speed;
    if (over) cur.noBalls++;

    final record = DeliveryRecord(
      ballTag: tag,
      bowler: cur.name,
      speed: speed,
      isNoBall: over,
      durationMs: durationMs,
    );

    setState(() {
      currentSpeed = speed;
      isNoBall = over;
      lastDelivery = record;
      history.insert(0, record);
      if (history.length > 25) history.removeLast();
    });

    if (over) {
      HapticFeedback.heavyImpact();
      _triggerTorchStrobe();
      await _tts.speak("Siren! No Ball! ${speed.toInt()}");
    } else {
      await _tts.speak("${speed.toInt()}");
    }

    await Future.delayed(Duration(milliseconds: 2400));
    if (mounted) {
      setState(() {
        isNoBall = false;
        _coolingDown = false;
      });
    }
  }

  void _showDrsModal() {
    if (lastDelivery == null) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey.shade900,
        title: Text("⚡ DRS Ball Analysis"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Bowler: ${lastDelivery!.bowler} (${lastDelivery!.ballTag})"),
            Text("Speed: ${lastDelivery!.speed.toStringAsFixed(1)} KM/H", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: lastDelivery!.isNoBall ? Colors.redAccent : Colors.greenAccent)),
            Text("Transit Time: ${lastDelivery!.durationMs.toStringAsFixed(0)} ms"),
            Text("Turf Length: ${pitchLength.toStringAsFixed(1)} m | Limit: ${speedLimit.toInt()} km/h"),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text("OK"))],
      ),
    );
  }

  void _showSummaryModal() {
    String summary = "🏏 TURF MATCH REPORT 🏏\nTop Speed: ${matchTopSpeed.toStringAsFixed(1)} km/h\n";
    for (var b in bowlers) {
      if (b.balls > 0) {
        summary += "${b.name}: ${b.balls}b | Avg ${b.avgSpeed.toStringAsFixed(0)} | Max ${b.topSpeed.toStringAsFixed(0)} (NB:${b.noBalls})\n";
      }
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey.shade900,
        title: Text("Match Summary"),
        content: Text(summary),
        actions: [
          ElevatedButton(
            child: Text("WhatsApp Copy"),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: summary));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Copied!")));
            },
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text("CLOSE")),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    double screenWidth = MediaQuery.of(context).size.width;
    double screenHeight = MediaQuery.of(context).size.height;
    bool isLandscape = screenWidth > screenHeight;

    return Scaffold(
      backgroundColor: isNoBall ? Colors.red.shade950 : Colors.black,
      body: Stack(
        children: [
          // Fullscreen Camera Feed
          SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _controller!.value.previewSize?.height ?? screenWidth,
                height: _controller!.value.previewSize?.width ?? screenHeight,
                child: CameraPreview(_controller!),
              ),
            ),
          ),

          // Cyan Calibration Line with Drag Handle
          Positioned(
            left: screenWidth * releaseLineX - 30,
            top: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragUpdate: (d) {
                setState(() {
                  releaseLineX = (releaseLineX + d.delta.dx / screenWidth).clamp(0.05, 0.95);
                });
              },
              child: Container(
                width: 60,
                color: Colors.transparent,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(width: 3, color: isBowlerOnLeft ? Colors.cyanAccent : Colors.amberAccent),
                    Positioned(
                      bottom: 80,
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: Colors.black88, borderRadius: BorderRadius.circular(4), border: Border.all(color: Colors.cyanAccent)),
                        child: Text(isBowlerOnLeft ? "RELEASE" : "CREASE", style: TextStyle(color: Colors.cyanAccent, fontSize: 9, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Yellow/Amber Calibration Line with Drag Handle
          Positioned(
            left: screenWidth * creaseLineX - 30,
            top: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragUpdate: (d) {
                setState(() {
                  creaseLineX = (creaseLineX + d.delta.dx / screenWidth).clamp(0.05, 0.95);
                });
              },
              child: Container(
                width: 60,
                color: Colors.transparent,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(width: 3, color: isBowlerOnLeft ? Colors.amberAccent : Colors.cyanAccent),
                    Positioned(
                      bottom: 80,
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: Colors.black88, borderRadius: BorderRadius.circular(4), border: Border.all(color: Colors.amberAccent)),
                        child: Text(isBowlerOnLeft ? "CREASE" : "RELEASE", style: TextStyle(color: Colors.amberAccent, fontSize: 9, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Right Edge: Slim Ball History Log
          Positioned(
            top: isLandscape ? 8 : 110,
            right: 6,
            bottom: isLandscape ? 10 : 80,
            width: 75,
            child: Container(
              padding: EdgeInsets.symmetric(vertical: 4, horizontal: 2),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.65),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white24),
              ),
              child: Column(
                children: [
                  Text("LOG", style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.grey.shade400)),
                  Divider(color: Colors.white24, height: 4),
                  Expanded(
                    child: history.isEmpty
                        ? Center(child: Text("Ready", style: TextStyle(fontSize: 9, color: Colors.white38)))
                        : ListView.builder(
                            itemCount: history.length,
                            itemBuilder: (ctx, i) {
                              final itm = history[i];
                              return Container(
                                margin: EdgeInsets.only(bottom: 3),
                                padding: EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  color: itm.isNoBall ? Colors.red.withOpacity(0.35) : Colors.black45,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: itm.isNoBall ? Colors.redAccent : Colors.greenAccent.withOpacity(0.4)),
                                ),
                                child: Column(
                                  children: [
                                    Text(itm.ballTag, style: TextStyle(fontSize: 8, color: itm.isNoBall ? Colors.redAccent : Colors.white60)),
                                    Text("${itm.speed.toStringAsFixed(0)}", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: itm.isNoBall ? Colors.redAccent : Colors.greenAccent)),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),

          // Top Header HUD Bar
          SafeArea(
            child: Container(
              margin: EdgeInsets.only(left: 6, top: 4, right: 86),
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.80),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  // Bowler Picker
                  DropdownButton<int>(
                    value: activeBowlerIndex,
                    dropdownColor: Colors.grey.shade900,
                    underline: SizedBox(),
                    items: List.generate(
                      bowlers.length,
                      (i) => DropdownMenuItem(value: i, child: Text(bowlers[i].name, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
                    ),
                    onChanged: (v) => setState(() => activeBowlerIndex = v ?? 0),
                  ),
                  SizedBox(width: 8),

                  // Turf Length & Speed Limit
                  Expanded(
                    child: Row(
                      children: [
                        Text("${pitchLength.toStringAsFixed(1)}m", style: TextStyle(fontSize: 10, color: Colors.cyanAccent)),
                        Expanded(
                          child: Slider(
                            value: pitchLength,
                            min: 10.0,
                            max: 18.0,
                            activeColor: Colors.cyanAccent,
                            onChanged: (v) => setState(() => pitchLength = v),
                          ),
                        ),
                        Text("${speedLimit.toInt()}k", style: TextStyle(fontSize: 10, color: Colors.orangeAccent)),
                        Expanded(
                          child: Slider(
                            value: speedLimit,
                            min: 50.0,
                            max: 130.0,
                            activeColor: Colors.orangeAccent,
                            onChanged: (v) => setState(() => speedLimit = v),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Quick Buttons
                  IconButton(
                    icon: Icon(isNightMode ? Icons.nightlight_round : Icons.wb_sunny, size: 16, color: isNightMode ? Colors.indigoAccent : Colors.amberAccent),
                    onPressed: () => setState(() => isNightMode = !isNightMode),
                  ),
                  IconButton(
                    icon: Icon(Icons.swap_horiz, size: 16, color: Colors.white70),
                    onPressed: () => setState(() => isBowlerOnLeft = !isBowlerOnLeft),
                  ),
                  if (lastDelivery != null)
                    IconButton(
                      icon: Icon(Icons.slow_motion_video, size: 16, color: Colors.purpleAccent),
                      onPressed: _showDrsModal,
                    ),
                  IconButton(
                    icon: Icon(Icons.analytics, size: 16, color: Colors.tealAccent),
                    onPressed: _showSummaryModal,
                  ),
                ],
              ),
            ),
          ),

          // Speed Alert Overlay
          if (currentSpeed > 0)
            Align(
              alignment: Alignment.center,
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                decoration: BoxDecoration(
                  color: isNoBall ? Colors.red : Colors.black.withOpacity(0.85),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: isNoBall ? Colors.white : Colors.greenAccent, width: 2),
                ),
                child: Text(
                  isNoBall ? "🚨 NO BALL! ${currentSpeed.toStringAsFixed(1)} KM/H" : "${currentSpeed.toStringAsFixed(1)} KM/H",
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: isNoBall ? Colors.white : Colors.greenAccent),
                ),
              ),
            ),

          // Bottom Radar Start/Pause Button
          Positioned(
            bottom: 12,
            left: 16,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: isDetecting ? Colors.redAccent : Colors.green.shade600,
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: Icon(isDetecting ? Icons.pause : Icons.play_arrow, size: 18),
              label: Text(
                isDetecting ? "PAUSE RADAR" : "START RADAR",
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
              onPressed: () {
                setState(() {
                  isDetecting = !isDetecting;
                  _startMicroseconds = null;
                });
              },
            ),
          ),
        ],
      ),
    );
  }
}
