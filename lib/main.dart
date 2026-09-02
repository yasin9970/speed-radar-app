import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';

void main() {
  runApp(SpeedRadarApp());
}

class SpeedRadarApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: SpeedRadarScreen(),
    );
  }
}

class SpeedRadarScreen extends StatefulWidget {
  @override
  _SpeedRadarScreenState createState() => _SpeedRadarScreenState();
}

class _SpeedRadarScreenState extends State<SpeedRadarScreen> {
  final FlutterTts flutterTts = FlutterTts();
  
  double speedLimit = 100.0; // Default speed limit
  double currentSpeed = 0.0;
  bool isNoBall = false;

  // Pitch timing variables
  final Stopwatch _stopwatch = Stopwatch();
  final double pitchDistanceInMeters = 20.12; // Standard Cricket Pitch

  @override
  void initState() {
    super.initState();
    _initVoiceEngine();
  }

  void _initVoiceEngine() async {
    await flutterTts.setLanguage("en-US");
    await flutterTts.setSpeechRate(0.65); // Ultra fast response
    await flutterTts.setPitch(1.1);
  }

  void _onBallReleased() {
    _stopwatch.reset();
    _stopwatch.start();
    setState(() {
      isNoBall = false;
    });
  }

  void _onBallReachedCrease() async {
    if (!_stopwatch.isRunning) return;
    _stopwatch.stop();

    double timeInSeconds = _stopwatch.elapsedMilliseconds / 1000.0;
    if (timeInSeconds <= 0.1) return; // False trigger ignore

    // Speed (km/h) = (Distance / Time) * 3.6
    double calculatedSpeed = (pitchDistanceInMeters / timeInSeconds) * 3.6;

    bool overLimit = calculatedSpeed > speedLimit;

    setState(() {
      currentSpeed = calculatedSpeed;
      isNoBall = overLimit;
    });

    if (overLimit) {
      await flutterTts.speak("Warning! No Ball! Speed ${calculatedSpeed.toInt()}");
    } else {
      await flutterTts.speak("${calculatedSpeed.toInt()} km/h");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: isNoBall ? Colors.red.shade900 : Colors.black,
      appBar: AppBar(
        title: Text("Cricket Speed Radar"),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            // 1. SPEED LIMIT SLIDER
            Container(
              margin: EdgeInsets.all(16),
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey.shade900,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white24),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text("SPEED LIMIT:", style: TextStyle(fontWeight: FontWeight.bold)),
                      Text(
                        "${speedLimit.toInt()} KM/H",
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.amberAccent),
                      ),
                    ],
                  ),
                  Slider(
                    value: speedLimit,
                    min: 40.0,
                    max: 160.0,
                    divisions: 24,
                    activeColor: Colors.amberAccent,
                    onChanged: (val) => setState(() => speedLimit = val),
                  ),
                ],
              ),
            ),

            // 2. SPEED DISPLAY & NO-BALL ALERT
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (isNoBall)
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                      margin: EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        "⚠️ NO BALL!",
                        style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: Colors.white),
                      ),
                    ),
                  Text(
                    currentSpeed.toStringAsFixed(1),
                    style: TextStyle(
                      fontSize: 88,
                      fontWeight: FontWeight.w900,
                      color: isNoBall ? Colors.yellowAccent : Colors.greenAccent,
                    ),
                  ),
                  Text(
                    "KM/H",
                    style: TextStyle(fontSize: 24, color: Colors.white60, letterSpacing: 2),
                  ),
                ],
              ),
            ),

            // 3. FAST TRIGGER BUTTONS
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 80,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue.shade700,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: _onBallReleased,
                        child: Text("1. RELEASE\n(Bowler)", textAlign: TextAlign.center, style: TextStyle(fontSize: 16)),
                      ),
                    ),
                  ),
                  SizedBox(width: 16),
                  Expanded(
                    child: SizedBox(
                      height: 80,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange.shade800,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: _onBallReachedCrease,
                        child: Text("2. CREASE\n(Impact)", textAlign: TextAlign.center, style: TextStyle(fontSize: 16)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
