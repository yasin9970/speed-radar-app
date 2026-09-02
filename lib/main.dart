import 'package:flutter/material.dart';
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
  runApp(TurfBeastRadarApp());
}

class TurfBeastRadarApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: TurfBeastRadarScreen(),
    );
  }
}

class TurfDelivery {
  final String ballTag;
  final double speed;
  final bool isNoBall;

  TurfDelivery({required this.ballTag, required this.speed, required this.isNoBall});
}

class TurfBeastRadarScreen extends StatefulWidget {
  @override
  _TurfBeastRadarScreenState createState() => _TurfBeastRadarScreenState();
}

class _TurfBeastRadarScreenState extends State<TurfBeastRadarScreen> {
  CameraController? _controller;
  final FlutterTts _tts = FlutterTts();

  // Match Configuration
  double pitchLength = 13.5; // Meters (10.0m to 18.0m)
  double speedLimit = 85.0; // km/h limit
  bool isNightMode = false; // Night Floodlight Anti-Flicker
  bool isBowlerOnLeft = true; // Left-to-Right vs Right-to-Left
  bool isDetecting = false;

  // Ultra-Precision Draggable Lines (Screen ratios)
  double releaseLineX = 0.25;
  double creaseLineX = 0.75;

  // High-Speed Engine State
  double currentSpeed = 0.0;
  double topSpeed = 0.0;
  bool isNoBall = false;
  int? _startMicroseconds;
  List<int>? _prevYPlane;
  bool _coolingDown = false;

  // Match History
  int legalBallsCount = 0;
  List<TurfDelivery> history = [];

  @override
  void initState() {
    super.initState();
    _initTTS();
    _initHighPerformanceCamera();
  }

  void _initTTS() async {
    await _tts.setLanguage("en-US");
    await _tts.setSpeechRate(0.70);
    await _tts.setPitch(1.0);
  }

  void _initHighPerformanceCamera() async {
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

    if (motionBowler >= 8 && motionBowler <= 45 && _startMicroseconds == null) {
      _startMicroseconds = now;
    }

    if (motionCrease >= 8 && motionCrease <= 50 && _startMicroseconds != null) {
      int delta = now - _startMicroseconds!;
      double seconds = delta / 1000000.0;

      if (seconds >= 0.16 && seconds <= 1.35) {
        double speed = (pitchLength / seconds) * 3.6;
        _registerDelivery(speed);
      }
      _startMicroseconds = null;
    }

    if (_startMicroseconds != null && (now - _startMicroseconds!) > 1500000) {
      _startMicroseconds = null;
    }
  }

  void _registerDelivery(double speed) async {
    _coolingDown = true;
    bool over = speed > speedLimit;

    if (!over) legalBallsCount++;
    int overNum = legalBallsCount ~/ 6;
    int ballNum = legalBallsCount % 6;
    String tag = over ? "NB" : "$overNum.$ballNum";

    if (speed > topSpeed) topSpeed = speed;

    final record = TurfDelivery(
      ballTag: tag,
      speed: speed,
      isNoBall: over,
    );

    setState(() {
      currentSpeed = speed;
      isNoBall = over;
      history.insert(0, record);
      if (history.length > 30) history.removeLast();
    });

    if (over) {
      await _tts.speak("Warning! No Ball! Speed ${speed.toInt()}");
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

          Positioned(
            top: 145,
            right: 8,
            bottom: 90,
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
                                    Text(item.ballTag, style: TextStyle(fontSize: 9, color: item.isNoBall ? Colors.redAccent : Colors.white70, fontWeight: FontWeight.bold)),
                                    Text("${item.speed.toStringAsFixed(1)}", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: item.isNoBall ? Colors.redAccent : Colors.greenAccent)),
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

          SafeArea(
            child: Column(
              children: [
                Container(
                  margin: EdgeInsets.all(8),
                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.85),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text("TURF: ${pitchLength.toStringAsFixed(1)}m", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.cyanAccent)),
                          Text("LIMIT: ${speedLimit.toInt()} km/h", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.orangeAccent)),
                          Text("TOP: ${topSpeed.toStringAsFixed(0)}", style: TextStyle(fontSize: 11, color: Colors.greenAccent)),
                        ],
                      ),
                      Row(
                        children: [
                          Text("Turf:", style: TextStyle(fontSize: 10, color: Colors.white60)),
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
                          Text("Limit:", style: TextStyle(fontSize: 10, color: Colors.white60)),
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
                              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            ),
                            icon: Icon(isNightMode ? Icons.nightlight_round : Icons.wb_sunny, size: 14),
                            label: Text(isNightMode ? "Night (LED)" : "Day Light", style: TextStyle(fontSize: 10)),
                            onPressed: () => setState(() => isNightMode = !isNightMode),
                          ),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blueGrey.shade800,
                              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            ),
                            icon: Icon(Icons.swap_horiz, size: 14),
                            label: Text(isBowlerOnLeft ? "Bowler: Left" : "Bowler: Right", style: TextStyle(fontSize: 10)),
                            onPressed: () => setState(() => isBowlerOnLeft = !isBowlerOnLeft),
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
                          Text("⚠️ OVER-SPEED NO BALL!", style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
                        Text(
                          "${currentSpeed.toStringAsFixed(1)} KM/H",
                          style: TextStyle(
                            fontSize: 36,
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
                isDetecting ? "PAUSE TURF RADAR" : "START TURF RADAR",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
