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
  runApp(TurfRadarApp());
}

class TurfRadarApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: TurfRadarScreen(),
    );
  }
}

class TurfDelivery {
  final String overBall;
  final double speed;
  final bool isNoBall;

  TurfDelivery({required this.overBall, required this.speed, required this.isNoBall});
}

class TurfRadarScreen extends StatefulWidget {
  @override
  _TurfRadarScreenState createState() => _TurfRadarScreenState();
}

class _TurfRadarScreenState extends State<TurfRadarScreen> {
  CameraController? _controller;
  final FlutterTts _tts = FlutterTts();

  // Turf Settings
  double pitchLength = 13.5; // Standard Turf (meters)
  double speedLimit = 85.0; // Turf speed limit (km/h)
  bool isDetecting = false;

  // Draggable Tripwire Positions (0.0 to 1.0 screen ratio)
  double releaseLineX = 0.22;
  double creaseLineX = 0.78;

  // Live Radar State
  double currentSpeed = 0.0;
  double maxSpeed = 0.0;
  bool isNoBall = false;
  int? _startMicroseconds;
  List<int>? _prevYPlane;
  bool _coolingDown = false;

  // Turf Match Stats
  int totalLegalBalls = 0;
  List<TurfDelivery> history = [];

  @override
  void initState() {
    super.initState();
    _initTTS();
    _initCamera();
  }

  void _initTTS() async {
    await _tts.setLanguage("en-US");
    await _tts.setSpeechRate(0.65);
    await _tts.setPitch(1.0);
  }

  void _initCamera() async {
    if (cameras.isEmpty) return;
    _controller = CameraController(
      cameras[0],
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await _controller!.initialize();
    if (!mounted) return;

    _controller!.startImageStream((CameraImage image) {
      if (isDetecting && !_coolingDown) {
        _processTurfFrame(image);
      }
    });

    setState(() {});
  }

  void _processTurfFrame(CameraImage image) {
    final yBytes = image.planes[0].bytes;
    int width = image.width;
    int height = image.height;

    if (_prevYPlane == null || _prevYPlane!.length != yBytes.length) {
      _prevYPlane = List<int>.from(yBytes);
      return;
    }

    int col1 = (width * releaseLineX).toInt().clamp(0, width - 1);
    int col2 = (width * creaseLineX).toInt().clamp(0, width - 1);

    int motionRelease = 0;
    int motionCrease = 0;

    // Turf Height Filter: Scan only between 25% and 75% height (ignores ground/feet)
    int startY = (height * 0.25).toInt();
    int endY = (height * 0.75).toInt();

    for (int row = startY; row < endY; row += 6) {
      int idx1 = row * width + col1;
      int idx2 = row * width + col2;

      // Tennis ball optical sensitivity threshold
      if ((yBytes[idx1] - _prevYPlane![idx1]).abs() > 42) motionRelease++;
      if ((yBytes[idx2] - _prevYPlane![idx2]).abs() > 42) motionCrease++;
    }

    _prevYPlane = List<int>.from(yBytes);
    int now = DateTime.now().microsecondsSinceEpoch;

    // Trigger 1: Release Point (Small object filter: 4 to 35 pixel shift)
    if (motionRelease >= 4 && motionRelease <= 35 && _startMicroseconds == null) {
      _startMicroseconds = now;
    }

    // Trigger 2: Crease Point
    if (motionCrease >= 4 && motionCrease <= 35 && _startMicroseconds != null) {
      int delta = now - _startMicroseconds!;
      double seconds = delta / 1000000.0;

      // Realistic Turf Ball Timing (0.15s to 1.4s)
      if (seconds >= 0.15 && seconds <= 1.4) {
        double speed = (pitchLength / seconds) * 3.6;
        _handleTurfDelivery(speed);
      }
      _startMicroseconds = null;
    }

    // Auto-timeout if ball doesn't reach batsman in 1.8s
    if (_startMicroseconds != null && (now - _startMicroseconds!) > 1800000) {
      _startMicroseconds = null;
    }
  }

  void _handleTurfDelivery(double speed) async {
    _coolingDown = true;
    bool over = speed > speedLimit;

    if (!over) totalLegalBalls++;
    int overNum = totalLegalBalls ~/ 6;
    int ballNum = totalLegalBalls % 6;
    String overBallStr = over ? "NB" : "$overNum.$ballNum";

    if (speed > maxSpeed) maxSpeed = speed;

    final record = TurfDelivery(
      overBall: overBallStr,
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

    // Turf Auto-Reset for next delivery
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
          // 1. Live Camera Stream
          Center(child: CameraPreview(_controller!)),

          // 2. Draggable Release Line (Bowler Hand)
          Positioned(
            left: screenWidth * releaseLineX - 25,
            top: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragUpdate: (details) {
                setState(() {
                  releaseLineX = (releaseLineX + details.delta.dx / screenWidth).clamp(0.05, creaseLineX - 0.1);
                });
              },
              child: Container(
                width: 50,
                child: Center(
                  child: Container(
                    width: 3,
                    color: Colors.cyanAccent,
                    child: Align(
                      alignment: Alignment.center,
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: Text("DRAG RELEASE", style: TextStyle(color: Colors.cyanAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // 3. Draggable Crease Line (Batsman / Stumps)
          Positioned(
            left: screenWidth * creaseLineX - 25,
            top: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragUpdate: (details) {
                setState(() {
                  creaseLineX = (creaseLineX + details.delta.dx / screenWidth).clamp(releaseLineX + 0.1, 0.95);
                });
              },
              child: Container(
                width: 50,
                child: Center(
                  child: Container(
                    width: 3,
                    color: Colors.amberAccent,
                    child: Align(
                      alignment: Alignment.center,
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: Text("DRAG CREASE", style: TextStyle(color: Colors.amberAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // 4. Right Side: Turf Match Delivery History
          Positioned(
            top: 130,
            right: 8,
            bottom: 90,
            width: 95,
            child: Container(
              padding: EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white24),
              ),
              child: Column(
                children: [
                  Text("TURF LOG", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey.shade300)),
                  Divider(color: Colors.white24, height: 6),
                  Expanded(
                    child: history.isEmpty
                        ? Center(child: Text("No Balls", style: TextStyle(fontSize: 10, color: Colors.white38)))
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
                                    Text(item.overBall, style: TextStyle(fontSize: 9, color: item.isNoBall ? Colors.redAccent : Colors.white70, fontWeight: FontWeight.bold)),
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

          // 5. Top Controls: Turf Size & Limit Controls
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
                          Text("TURF PITCH: ${pitchLength.toStringAsFixed(1)}m", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.cyanAccent)),
                          Text("LIMIT: ${speedLimit.toInt()} km/h", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.orangeAccent)),
                          Text("MAX: ${maxSpeed.toStringAsFixed(0)}", style: TextStyle(fontSize: 12, color: Colors.greenAccent)),
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
                    ],
                  ),
                ),

                // Main Speed Banner
                if (currentSpeed > 0)
                  Container(
                    margin: EdgeInsets.only(top: 4),
                    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                    decoration: BoxDecoration(
                      color: isNoBall ? Colors.red : Colors.black.withOpacity(0.85),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: isNoBall ? Colors.white : Colors.greenAccent, width: 2),
                    ),
                    child: Column(
                      children: [
                        if (isNoBall)
                          Text("⚠️ OVER-SPEED NO BALL!", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                        Text(
                          "${currentSpeed.toStringAsFixed(1)} KM/H",
                          style: TextStyle(
                            fontSize: 38,
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

          // 6. Bottom Radar Toggle Button
          Positioned(
            bottom: 20,
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
