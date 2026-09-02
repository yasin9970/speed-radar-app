import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter_tts/flutter_tts.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    print("Camera error: $e");
  }
  runApp(SpeedRadarApp());
}

class SpeedRadarApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: AutoRadarScreen(),
    );
  }
}

class AutoRadarScreen extends StatefulWidget {
  @override
  _AutoRadarScreenState createState() => _AutoRadarScreenState();
}

class _AutoRadarScreenState extends State<AutoRadarScreen> {
  CameraController? _controller;
  final FlutterTts _tts = FlutterTts();

  double speedLimit = 100.0;
  double calculatedSpeed = 0.0;
  bool isNoBall = false;
  bool isDetecting = false;

  int? _startMicroseconds;
  final double pitchDistance = 20.12; // Standard Cricket Pitch in Meters
  List<int>? _prevYPlane;

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
      if (isDetecting) {
        _processFrame(image);
      }
    });

    setState(() {});
  }

  void _processFrame(CameraImage image) {
    // Luminance plane (Y plane) processing
    final yBytes = image.planes[0].bytes;
    int width = image.width;
    int height = image.height;

    if (_prevYPlane == null || _prevYPlane!.length != yBytes.length) {
      _prevYPlane = List<int>.from(yBytes);
      return;
    }

    // Line 1: 25% screen width (Release Point)
    // Line 2: 75% screen width (Crease/Stumps)
    int col1 = (width * 0.25).toInt();
    int col2 = (width * 0.75).toInt();

    int motionLine1 = 0;
    int motionLine2 = 0;

    // Pixel difference sampling along the trigger lines
    for (int row = 0; row < height; row += 8) {
      int idx1 = row * width + col1;
      int idx2 = row * width + col2;

      if ((yBytes[idx1] - _prevYPlane![idx1]).abs() > 40) motionLine1++;
      if ((yBytes[idx2] - _prevYPlane![idx2]).abs() > 40) motionLine2++;
    }

    _prevYPlane = List<int>.from(yBytes);

    int now = DateTime.now().microsecondsSinceEpoch;

    // Trigger 1: Ball hits Line 1 (Bowler release)
    if (motionLine1 > 10 && _startMicroseconds == null) {
      _startMicroseconds = now;
    }

    // Trigger 2: Ball hits Line 2 (Crease)
    if (motionLine2 > 10 && _startMicroseconds != null) {
      int delta = now - _startMicroseconds!;
      double seconds = delta / 1000000.0;

      // Realistic cricket ball duration filter (0.3s to 2.0s)
      if (seconds >= 0.25 && seconds <= 2.2) {
        double speed = (pitchDistance / seconds) * 3.6;
        _onSpeedCaptured(speed);
      }
      _startMicroseconds = null;
    }

    // Auto-reset if ball missed line 2
    if (_startMicroseconds != null && (now - _startMicroseconds!) > 2500000) {
      _startMicroseconds = null;
    }
  }

  void _onSpeedCaptured(double speed) async {
    bool over = speed > speedLimit;
    setState(() {
      calculatedSpeed = speed;
      isNoBall = over;
    });

    if (over) {
      await _tts.speak("Warning! No Ball! Speed ${speed.toInt()}");
    } else {
      await _tts.speak("${speed.toInt()} km/h");
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

    return Scaffold(
      backgroundColor: isNoBall ? Colors.red.shade900 : Colors.black,
      body: Stack(
        children: [
          // 1. Live Camera Preview
          Center(child: CameraPreview(_controller!)),

          // 2. Calibrated Trigger Lines (Tripwire)
          Align(
            alignment: Alignment(-0.5, 0), // 25% width
            child: Container(
              width: 3,
              color: Colors.cyanAccent.withOpacity(0.8),
              child: Center(
                child: RotatedBox(
                  quarterTurns: 3,
                  child: Text("RELEASE LINE", style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment(0.5, 0), // 75% width
            child: Container(
              width: 3,
              color: Colors.amberAccent.withOpacity(0.8),
              child: Center(
                child: RotatedBox(
                  quarterTurns: 3,
                  child: Text("CREASE LINE", style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold)),
                ),
              ),
            ),
          ),

          // 3. Top HUD: Speed & Alert
          SafeArea(
            child: Column(
              children: [
                Container(
                  margin: EdgeInsets.all(12),
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.75),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("LIMIT: ${speedLimit.toInt()} KM/H", style: TextStyle(fontWeight: FontWeight.bold)),
                          SizedBox(
                            width: 140,
                            child: Slider(
                              value: speedLimit,
                              min: 40,
                              max: 160,
                              divisions: 24,
                              onChanged: (v) => setState(() => speedLimit = v),
                            ),
                          ),
                        ],
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            "${calculatedSpeed.toStringAsFixed(1)}",
                            style: TextStyle(
                              fontSize: 36,
                              fontWeight: FontWeight.bold,
                              color: isNoBall ? Colors.redAccent : Colors.greenAccent,
                            ),
                          ),
                          Text("KM/H", style: TextStyle(fontSize: 12, color: Colors.white70)),
                        ],
                      ),
                    ],
                  ),
                ),
                if (isNoBall)
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                    color: Colors.red,
                    child: Text(
                      "⚠️ NO BALL!",
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),

          // 4. Bottom Control Button
          Positioned(
            bottom: 24,
            left: 20,
            right: 20,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: isDetecting ? Colors.redAccent : Colors.green,
                padding: EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () {
                setState(() {
                  isDetecting = !isDetecting;
                  _startMicroseconds = null;
                });
              },
              child: Text(
                isDetecting ? "STOP RADAR" : "START AUTO DETECTION",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
