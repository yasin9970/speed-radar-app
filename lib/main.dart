import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:flutter_tts/flutter_tts.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint("Camera error: $e");
  }
  runApp(TurfUltimateRadarApp());
}

class TurfUltimateRadarApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: UltimateRadarScreen(),
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

class UltimateRadarScreen extends StatefulWidget {
  @override
  _UltimateRadarScreenState createState() => _UltimateRadarScreenState();
}

class _UltimateRadarScreenState extends State<UltimateRadarScreen> {
  CameraController? _controller;
  final FlutterTts _tts = FlutterTts();

  // Match Configuration
  double pitchLength = 13.5; // Meters
  double speedLimit = 85.0; // km/h
  bool isNightMode = false;
  bool isBowlerOnLeft = true;
  bool isDetecting = false;

  // Draggable Screen Positions
  double releaseLineX = 0.25;
  double creaseLineX = 0.75;

  // Radar State
  double currentSpeed = 0.0;
  double matchTopSpeed = 0.0;
  bool isNoBall = false;
  int? _startMicroseconds;
  List<int>? _prevYPlane;
  bool _coolingDown = false;

  // Bowlers & Match Stats
  List<BowlerStats> bowlers = [
    BowlerStats(name: "Bowler 1"),
    BowlerStats(name: "Bowler 2"),
    BowlerStats(name: "Bowler 3"),
  ];
  int activeBowlerIndex = 0;
  int legalBallsCount = 0;
  List<DeliveryRecord> history = [];
  DeliveryRecord? lastDelivery;

  @override
  void initState() {
    super.initState();
    _initTTS();
    _initFlagshipCamera();
  }

  void _initTTS() async {
    await _tts.setLanguage("en-US");
    await _tts.setSpeechRate(0.70);
    await _tts.setPitch(1.0);
  }

  void _initFlagshipCamera() async {
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
        _processFrame(image);
      }
    });

    setState(() {});
  }

  void _processFrame(CameraImage image) {
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

    // Standing Bowler Release Detection
    if (motionBowler >= 8 && motionBowler <= 45 && _startMicroseconds == null) {
      _startMicroseconds = now;
    }

    // Crease Trigger
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

  void _triggerHardwareTorchStrobe() async {
    try {
      for (int i = 0; i < 4; i++) {
        await _controller?.setFlashMode(FlashMode.torch);
        await Future.delayed(Duration(milliseconds: 100));
        await _controller?.setFlashMode(FlashMode.off);
        await Future.delayed(Duration(milliseconds: 100));
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

    BowlerStats currentBowler = bowlers[activeBowlerIndex];
    currentBowler.balls++;
    currentBowler.totalSpeed += speed;
    if (speed > currentBowler.topSpeed) currentBowler.topSpeed = speed;
    if (over) currentBowler.noBalls++;

    final record = DeliveryRecord(
      ballTag: tag,
      bowler: currentBowler.name,
      speed: speed,
      isNoBall: over,
      durationMs: durationMs,
    );

    setState(() {
      currentSpeed = speed;
      isNoBall = over;
      lastDelivery = record;
      history.insert(0, record);
      if (history.length > 30) history.removeLast();
    });

    if (over) {
      HapticFeedback.heavyImpact();
      _triggerHardwareTorchStrobe();
      await _tts.speak("Siren! Warning! No Ball! Speed ${speed.toInt()}");
    } else {
      await _tts.speak("${speed.toInt()}");
    }

    await Future.delayed(Duration(milliseconds: 2500));
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
        title: Row(
          children: [
            Icon(Icons.slow_motion_video, color: Colors.cyanAccent),
            SizedBox(width: 8),
            Text("DRS Ball Breakdown", style: TextStyle(color: Colors.white)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Bowler: ${lastDelivery!.bowler}", style: TextStyle(fontSize: 14, color: Colors.white70)),
            Divider(color: Colors.white24),
            Text("Recorded Speed: ${lastDelivery!.speed.toStringAsFixed(1)} KM/H", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: lastDelivery!.isNoBall ? Colors.redAccent : Colors.greenAccent)),
            SizedBox(height: 6),
            Text("Pitch Length: ${pitchLength.toStringAsFixed(1)} Meters", style: TextStyle(color: Colors.white70)),
            Text("Flight Transit Time: ${lastDelivery!.durationMs.toStringAsFixed(0)} ms (${(lastDelivery!.durationMs / 1000).toStringAsFixed(3)}s)", style: TextStyle(color: Colors.amberAccent)),
            Text("Speed Limit: ${speedLimit.toInt()} KM/H", style: TextStyle(color: Colors.white70)),
            SizedBox(height: 8),
            Container(
              padding: EdgeInsets.all(8),
              color: lastDelivery!.isNoBall ? Colors.red.withOpacity(0.3) : Colors.green.withOpacity(0.3),
              child: Center(
                child: Text(
                  lastDelivery!.isNoBall ? "DECISION: ⚠️ OVER-SPEED NO BALL" : "DECISION: ✔️ FAIR LEGAL DELIVERY",
                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text("CLOSE")),
        ],
      ),
    );
  }

  void _showSummaryModal() {
    String summaryText = "🏏 *TURF CRICKET MATCH RADAR REPORT* 🏏\n"
        "⚡ Highest Speed: ${matchTopSpeed.toStringAsFixed(1)} KM/H\n"
        "🎯 Total Legal Deliveries: $legalBallsCount\n\n"
        "*BOWLER PERFORMANCE:*\n";

    for (var b in bowlers) {
      if (b.balls > 0) {
        summaryText += "👤 ${b.name}: ${b.balls} balls | Avg: ${b.avgSpeed.toStringAsFixed(1)} km/h | Top: ${b.topSpeed.toStringAsFixed(0)} km/h | NB: ${b.noBalls}\n";
      }
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey.shade900,
        title: Text("🏆 Match Radar Summary"),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Top Speed: ${matchTopSpeed.toStringAsFixed(1)} KM/H", style: TextStyle(fontSize: 16, color: Colors.greenAccent, fontWeight: FontWeight.bold)),
              Text("Legal Balls: $legalBallsCount", style: TextStyle(color: Colors.white70)),
              Divider(color: Colors.white24),
              ...bowlers.where((b) => b.balls > 0).map((b) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4.0),
                    child: Text("${b.name}: ${b.balls}b, Avg: ${b.avgSpeed.toStringAsFixed(0)}km/h, Max: ${b.topSpeed.toStringAsFixed(0)}km/h (NB: ${b.noBalls})"),
                  )),
            ],
          ),
        ),
        actions: [
          ElevatedButton.icon(
            icon: Icon(Icons.share, size: 16),
            label: Text("Copy for WhatsApp"),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: summaryText));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text("Scorecard copied! Direct WhatsApp me paste karein.")),
              );
            },
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text("DONE")),
        ],
      ),
    );
  }

  void _addNewBowlerDialog() {
    TextEditingController nameCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey.shade900,
        title: Text("Add Bowler"),
        content: TextField(
          controller: nameCtrl,
          decoration: InputDecoration(hintText: "Enter bowler name"),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text("CANCEL")),
          ElevatedButton(
            onPressed: () {
              if (nameCtrl.text.trim().isNotEmpty) {
                setState(() {
                  bowlers.add(BowlerStats(name: nameCtrl.text.trim()));
                  activeBowlerIndex = bowlers.length - 1;
                });
                Navigator.pop(ctx);
              }
            },
            child: Text("ADD & SELECT"),
          ),
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

    return Scaffold(
      backgroundColor: isNoBall ? Colors.red.shade900 : Colors.black,
      body: Stack(
        children: [
          Center(child: CameraPreview(_controller!)),

          // Draggable Bowler Line
          Positioned(
            left: screenWidth * releaseLineX - 25,
            top: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragUpdate: (details) {
                setState(() {
                  releaseLineX = (releaseLineX + details.delta.dx / screenWidth).clamp(0.05, 0.95);
                });
              },
              child: Container(
                width: 50,
                child: Center(
                  child: Container(
                    width: 3,
                    color: isBowlerOnLeft ? Colors.cyanAccent : Colors.amberAccent,
                    child: Align(
                      alignment: Alignment.center,
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: Text(
                          isBowlerOnLeft ? "BOWLER RELEASE" : "BATSMAN CREASE",
                          style: TextStyle(
                            color: isBowlerOnLeft ? Colors.cyanAccent : Colors.amberAccent,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Draggable Crease Line
          Positioned(
            left: screenWidth * creaseLineX - 25,
            top: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragUpdate: (details) {
                setState(() {
                  creaseLineX = (creaseLineX + details.delta.dx / screenWidth).clamp(0.05, 0.95);
                });
              },
              child: Container(
                width: 50,
                child: Center(
                  child: Container(
                    width: 3,
                    color: isBowlerOnLeft ? Colors.amberAccent : Colors.cyanAccent,
                    child: Align(
                      alignment: Alignment.center,
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: Text(
                          isBowlerOnLeft ? "BATSMAN CREASE" : "BOWLER RELEASE",
                          style: TextStyle(
                            color: isBowlerOnLeft ? Colors.amberAccent : Colors.cyanAccent,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Right Side Ball Log
          Positioned(
            top: 155,
            right: 8,
            bottom: 85,
            width: 95,
            child: Container(
              padding: EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.75),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white24),
              ),
              child: Column(
                children: [
                  Text("BALL LOG", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey.shade300)),
                  Divider(color: Colors.white24, height: 6),
                  Expanded(
                    child: history.isEmpty
                        ? Center(child: Text("Ready...", style: TextStyle(fontSize: 10, color: Colors.white38)))
                        : ListView.builder(
                            itemCount: history.length,
                            itemBuilder: (ctx, i) {
                              final item = history[i];
                              return Container(
                                margin: EdgeInsets.only(bottom: 4),
                                padding: EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: item.isNoBall ? Colors.red.withOpacity(0.4) : Colors.black45,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: item.isNoBall ? Colors.redAccent : Colors.greenAccent.withOpacity(0.5)),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text("${item.bowler} (${item.ballTag})", style: TextStyle(fontSize: 8, color: Colors.white70)),
                                    Text("${item.speed.toStringAsFixed(1)}", style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: item.isNoBall ? Colors.redAccent : Colors.greenAccent)),
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

          // Top Configuration Panel
          SafeArea(
            child: Column(
              children: [
                Container(
                  margin: EdgeInsets.all(8),
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.85),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      // Bowler Selector + Match Summary
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          DropdownButton<int>(
                            value: activeBowlerIndex,
                            dropdownColor: Colors.grey.shade900,
                            underline: SizedBox(),
                            items: List.generate(
                              bowlers.length,
                              (idx) => DropdownMenuItem(
                                value: idx,
                                child: Text("👤 ${bowlers[idx].name}", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                              ),
                            ),
                            onChanged: (val) => setState(() => activeBowlerIndex = val ?? 0),
                          ),
                          IconButton(
                            icon: Icon(Icons.person_add, size: 18, color: Colors.cyanAccent),
                            onPressed: _addNewBowlerDialog,
                          ),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.teal.shade800, padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
                            icon: Icon(Icons.analytics, size: 14),
                            label: Text("SUMMARY", style: TextStyle(fontSize: 10)),
                            onPressed: _showSummaryModal,
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text("TURF: ${pitchLength.toStringAsFixed(1)}m", style: TextStyle(fontSize: 11, color: Colors.cyanAccent)),
                          Text("LIMIT: ${speedLimit.toInt()} km/h", style: TextStyle(fontSize: 11, color: Colors.orangeAccent)),
                          Text("TOP: ${matchTopSpeed.toStringAsFixed(0)}", style: TextStyle(fontSize: 11, color: Colors.greenAccent)),
                        ],
                      ),
                      Row(
                        children: [
                          Text("Pitch:", style: TextStyle(fontSize: 9, color: Colors.white60)),
                          Expanded(
                            child: Slider(
                              value: pitchLength,
                              min: 10.0,
                              max: 18.0,
                              divisions: 16,
                              activeColor: Colors.cyanAccent,
                              onChanged: (v) => setState(() => pitchLength = v),
                            ),
                          ),
                          Text("Limit:", style: TextStyle(fontSize: 9, color: Colors.white60)),
                          Expanded(
                            child: Slider(
                              value: speedLimit,
                              min: 50.0,
                              max: 130.0,
                              divisions: 16,
                              activeColor: Colors.orangeAccent,
                              onChanged: (v) => setState(() => speedLimit = v),
                            ),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: isNightMode ? Colors.indigo.shade900 : Colors.amber.shade700,
                              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            ),
                            icon: Icon(isNightMode ? Icons.nightlight_round : Icons.wb_sunny, size: 12),
                            label: Text(isNightMode ? "Night (LED)" : "Day Light", style: TextStyle(fontSize: 10)),
                            onPressed: () => setState(() => isNightMode = !isNightMode),
                          ),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blueGrey.shade800,
                              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            ),
                            icon: Icon(Icons.swap_horiz, size: 12),
                            label: Text(isBowlerOnLeft ? "Bowler: Left" : "Bowler: Right", style: TextStyle(fontSize: 10)),
                            onPressed: () => setState(() => isBowlerOnLeft = !isBowlerOnLeft),
                          ),
                          if (lastDelivery != null)
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple.shade700, padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2)),
                              icon: Icon(Icons.slow_motion_video, size: 12),
                              label: Text("DRS", style: TextStyle(fontSize: 10)),
                              onPressed: _showDrsModal,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),

                if (currentSpeed > 0)
                  Container(
                    margin: EdgeInsets.only(top: 2),
                    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                    decoration: BoxDecoration(
                      color: isNoBall ? Colors.red : Colors.black.withOpacity(0.85),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: isNoBall ? Colors.white : Colors.greenAccent, width: 2),
                    ),
                    child: Column(
                      children: [
                        if (isNoBall)
                          Text("🚨 SIREN: OVER-SPEED NO BALL!", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
                        Text(
                          "${currentSpeed.toStringAsFixed(1)} KM/H",
                          style: TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.bold,
                            color: isNoBall ? Colors.white : Colors.greenAccent,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          // Start Radar Button
          Positioned(
            bottom: 16,
            left: 20,
            right: 120,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: isDetecting ? Colors.redAccent : Colors.green.shade600,
                padding: EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () {
                setState(() {
                  isDetecting = !isDetecting;
                  _startMicroseconds = null;
                });
              },
              child: Text(
                isDetecting ? "PAUSE RADAR" : "START TURF RADAR",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
