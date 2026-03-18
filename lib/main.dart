import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';

// ----- INITIALIZATION -----

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeService();
  runApp(const MyApp());
}

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'my_foreground', 
    'Crash Detector',
    description: 'Blijft actief om vallen en routes te detecteren.',
    importance: Importance.high, 
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'my_foreground',
      initialNotificationTitle: 'Snowboard Tracker',
      initialNotificationContent: 'Monitoring actief...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  return true;
}

// ----- BACKGROUND SERVICE -----

class TrackedPoint {
  final Position position;
  final DateTime time;
  TrackedPoint(this.position, this.time);
}

String getTodaySessionId() {
  final now = DateTime.now();
  return DateFormat('yyyy-MM-dd').format(now);
}

Future<void> ensureSessionExists(SharedPreferences prefs, String sessionId) async {
  List<String> sessions = prefs.getStringList('session_ids') ?? [];
  if (!sessions.contains(sessionId)) {
    sessions.add(sessionId);
    await prefs.setStringList('session_ids', sessions);
    await prefs.setString('session_${sessionId}_name', 'Sessie ${DateFormat('dd MMM yyyy').format(DateTime.now())}');
  }
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  bool isMonitoring = true;
  
  final initPrefs = await SharedPreferences.getInstance();
  await initPrefs.reload();
  double crashThreshold = initPrefs.getDouble('crashThreshold') ?? 40.0;
  int cooldownTime = initPrefs.getInt('cooldownTime') ?? 10;
  
  service.on('updateSettings').listen((event) {
    if (event != null) {
      if (event['crashThreshold'] != null) crashThreshold = event['crashThreshold'];
      if (event['cooldownTime'] != null) cooldownTime = event['cooldownTime'];
    }
  });

  List<TrackedPoint> recentPositions = [];

  final locationSettings = const LocationSettings(
    accuracy: LocationAccuracy.best,
    distanceFilter: 2, 
  );

  StreamSubscription<Position>? posStream = Geolocator.getPositionStream(locationSettings: locationSettings).listen((Position position) async {
    final now = DateTime.now();
    recentPositions.add(TrackedPoint(position, now));
    
    recentPositions.removeWhere((p) => now.difference(p.time).inSeconds > 15);

    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    String sessionId = getTodaySessionId();
    await ensureSessionExists(prefs, sessionId);

    List<String> route = prefs.getStringList('session_${sessionId}_route') ?? [];
    route.add(jsonEncode({
      'time': now.toIso8601String(),
      'lat': position.latitude,
      'lon': position.longitude,
      'speed': (position.speed * 3.6), 
    }));
    await prefs.setStringList('session_${sessionId}_route', route);
  });

  service.on('stopService').listen((event) {
    posStream.cancel();
    service.stopSelf();
    isMonitoring = false;
  });

  userAccelerometerEventStream().listen((UserAccelerometerEvent event) async {
    if (!isMonitoring) return;
    
    double gForce = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);

    if (gForce > crashThreshold) {
      isMonitoring = false;
      
      double speed2SecAgo = 0.0;
      DateTime targetTime = DateTime.now().subtract(const Duration(seconds: 2));
      
      if (recentPositions.isNotEmpty) {
        TrackedPoint closest = recentPositions.reduce((a, b) {
          int diffA = a.time.difference(targetTime).inMilliseconds.abs();
          int diffB = b.time.difference(targetTime).inMilliseconds.abs();
          return diffA < diffB ? a : b;
        });
        speed2SecAgo = closest.position.speed * 3.6; 
      }

      await registerCrash(gForce, speed2SecAgo);
      
      Timer(Duration(seconds: cooldownTime), () {
        isMonitoring = true;
      });
    }
  });
}

Future<void> registerCrash(double gForce, double speedBefore) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload(); 
  
  String sessionId = getTodaySessionId();
  await ensureSessionExists(prefs, sessionId);

  List<String> rawCrashes = prefs.getStringList('session_${sessionId}_crashes') ?? [];
  
  Map<String, dynamic> crashData = {
    'time': DateTime.now().toIso8601String(),
    'severity': gForce,
    'speed_before': speedBefore,
    'lat': 0.0,
    'lon': 0.0,
  };

  try {
    Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    crashData['lat'] = position.latitude;
    crashData['lon'] = position.longitude;
  } catch (e) {
    print('Failed location: $e');
  }

  rawCrashes.insert(0, jsonEncode(crashData));
  await prefs.setStringList('session_${sessionId}_crashes', rawCrashes);
}

// ----- APP ENTRY -----

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SnowFall',
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.deepOrange,
        scaffoldBackgroundColor: const Color(0xff121212),
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.orange, brightness: Brightness.dark),
      ),
      home: const DashboardScreen(),
    );
  }
}

// ----- SCREENS -----

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _isTracking = false;
  String _activityType = 'snowboard';
  List<String> _sessionIds = [];
  Map<String, String> _sessionNames = {};
  int _todayCrashes = 0;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadData();
    _checkServiceStatus();
    
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (_isTracking) _loadData();
    });
  }
  
  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkServiceStatus() async {
    final service = FlutterBackgroundService();
    bool isRunning = await service.isRunning();
    if (mounted) {
      setState(() {
        _isTracking = isRunning;
      });
    }
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); 
    
    String activityType = prefs.getString('activityType') ?? 'snowboard';
    List<String> sessions = prefs.getStringList('session_ids') ?? [];
    
    // Reverse to show newest first
    sessions = sessions.reversed.toList();
    
    Map<String, String> names = {};
    for (String id in sessions) {
      names[id] = prefs.getString('session_${id}_name') ?? 'Sessie $id';
    }

    // Check today's crashes if exists
    String todayId = getTodaySessionId();
    int todayCrashes = 0;
    if (sessions.contains(todayId)) {
        List<String> crashes = prefs.getStringList('session_${todayId}_crashes') ?? [];
        todayCrashes = crashes.length;
    }

    if (mounted) {
      setState(() {
        _activityType = activityType;
        _sessionIds = sessions;
        _sessionNames = names;
        _todayCrashes = todayCrashes;
      });
    }
  }

  Future<void> _toggleTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Locatie is uitgeschakeld.')));
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) return;

    final service = FlutterBackgroundService();
    bool isRunning = await service.isRunning();

    if (isRunning) {
      service.invoke('stopService');
      setState(() { _isTracking = false; });
    } else {
      // Ensure session exists immediately when clicking start
      final prefs = await SharedPreferences.getInstance();
      await ensureSessionExists(prefs, getTodaySessionId());
      await service.startService();
      setState(() { _isTracking = true; });
      _loadData();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SnowFall Tracker'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())).then((_) {
                 _loadData();
              });
            },
            tooltip: 'Instellingen',
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
            child: Column(
              children: [
                Icon(_activityType == 'ski' ? Icons.downhill_skiing : Icons.snowboarding, size: 80, color: Colors.orange),
                const SizedBox(height: 20),
                Text(
                  'Vallen vandaag: $_todayCrashes',
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 30),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isTracking ? Colors.red.shade700 : Colors.green.shade700,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(60),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))
                  ),
                  onPressed: _toggleTracking,
                  child: Text(
                    _isTracking ? 'STOP TRACKING' : 'START TRACKING',
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                )
              ],
            ),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.all(8.0),
            child: Text('Mijn Sessies', style: TextStyle(fontSize: 16, color: Colors.grey, fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: _sessionIds.isEmpty
                ? const Center(child: Text('Nog geen sessies gelogd.'))
                : ListView.builder(
                    itemCount: _sessionIds.length,
                    itemBuilder: (context, index) {
                      String sid = _sessionIds[index];
                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        child: ListTile(
                          onTap: () {
                            Navigator.push(context, MaterialPageRoute(builder: (_) => SessionDetailScreen(sessionId: sid))).then((_) => _loadData());
                          },
                          leading: const CircleAvatar(
                            backgroundColor: Colors.blueAccent,
                            child: Icon(Icons.calendar_month, color: Colors.white),
                          ),
                          title: Text(_sessionNames[sid] ?? sid),
                          subtitle: Text(sid),
                          trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                        ),
                      );
                    },
                  ),
          )
        ],
      ),
    );
  }
}

class SessionDetailScreen extends StatefulWidget {
  final String sessionId;
  const SessionDetailScreen({super.key, required this.sessionId});

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  String _sessionName = '';
  List<LatLng> _routePoints = [];
  List<Map<String, dynamic>> _crashes = [];
  double _maxSpeed = 0.0;
  double _totalDistanceKm = 0.0;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSessionData();
  }

  Future<void> _loadSessionData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    
    setState(() {
      _sessionName = prefs.getString('session_${widget.sessionId}_name') ?? widget.sessionId;
    });

    List<String> rawRoute = prefs.getStringList('session_${widget.sessionId}_route') ?? [];
    List<LatLng> points = [];
    double tempMaxSpeed = 0.0;
    
    for (String r in rawRoute) {
      Map<String, dynamic> data = jsonDecode(r);
      points.add(LatLng(data['lat'], data['lon']));
      double spd = (data['speed'] ?? 0.0).toDouble();
      if (spd > tempMaxSpeed) tempMaxSpeed = spd;
    }

    double dist = 0.0;
    if (points.length > 1) {
      final distanceCalc = const Distance();
      for (int i = 0; i < points.length - 1; i++) {
        dist += distanceCalc.as(LengthUnit.Meter, points[i], points[i + 1]);
      }
    }

    List<String> rawCrashes = prefs.getStringList('session_${widget.sessionId}_crashes') ?? [];
    List<Map<String, dynamic>> crs = [];
    for (String c in rawCrashes) {
       var mapped = jsonDecode(c) as Map<String, dynamic>;
       crs.add(mapped);
       double spdb = (mapped['speed_before'] ?? 0.0).toDouble();
       if (spdb > tempMaxSpeed) tempMaxSpeed = spdb;
    }

    setState(() {
      _routePoints = points;
      _crashes = crs;
      _maxSpeed = tempMaxSpeed;
      _totalDistanceKm = dist / 1000.0;
      _isLoading = false;
    });
  }

  Future<void> _renameSession() async {
    TextEditingController ctrl = TextEditingController(text: _sessionName);
    String? newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hernoem Sessie'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(hintText: "Bijv: Dag 1 Val Thorens"),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuleren')),
          TextButton(onPressed: () => Navigator.pop(context, ctrl.text), child: const Text('Opslaan')),
        ],
      )
    );

    if (newName != null && newName.trim().isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('session_${widget.sessionId}_name', newName.trim());
      setState(() {
        _sessionName = newName.trim();
      });
    }
  }

  Future<void> _deleteSession() async {
    bool? conf = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sessie Verwijderen'),
        content: const Text('Weet je zeker dat je deze hele dag wil verwijderen?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Nee')),
          TextButton(
             onPressed: () => Navigator.pop(context, true), 
             child: const Text('Ja, Verwijder', style: TextStyle(color: Colors.red))
          ),
        ],
      )
    );

    if (conf == true) {
      final prefs = await SharedPreferences.getInstance();
      List<String> sessions = prefs.getStringList('session_ids') ?? [];
      sessions.remove(widget.sessionId);
      await prefs.setStringList('session_ids', sessions);
      
      await prefs.remove('session_${widget.sessionId}_name');
      await prefs.remove('session_${widget.sessionId}_route');
      await prefs.remove('session_${widget.sessionId}_crashes');
      
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    LatLng centerMap = _routePoints.isNotEmpty 
        ? _routePoints[(_routePoints.length / 2).floor()] 
        : const LatLng(52.3676, 4.9041);
        
    // Calculate bounding box so map zooms to fit the entire route
    LatLngBounds? routeBounds;
    if (_routePoints.length > 1) {
      final lats = _routePoints.map((p) => p.latitude).toList();
      final lngs = _routePoints.map((p) => p.longitude).toList();
      double minLat = lats.reduce(min);
      double maxLat = lats.reduce(max);
      double minLng = lngs.reduce(min);
      double maxLng = lngs.reduce(max);
      
      if (minLat == maxLat) { minLat -= 0.005; maxLat += 0.005; }
      if (minLng == maxLng) { minLng -= 0.005; maxLng += 0.005; }
      
      routeBounds = LatLngBounds(
        LatLng(minLat, minLng),
        LatLng(maxLat, maxLng),
      );
    }
        
    List<Marker> mapMarkers = [];
    for (int i = 0; i < _crashes.length; i++) {
       var c = _crashes[i];
       if (c['lat'] != 0.0 && c['lon'] != 0.0) {
         mapMarkers.add(
           Marker(
             point: LatLng(c['lat'], c['lon']),
             width: 40,
             height: 40,
             child: const Icon(Icons.warning_rounded, color: Colors.red, size: 30),
           )
         );
       }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_sessionName),
        actions: [
          IconButton(icon: const Icon(Icons.edit), onPressed: _renameSession, tooltip: 'Hernoem'),
          IconButton(icon: const Icon(Icons.delete), onPressed: _deleteSession, tooltip: 'Verwijder'),
        ],
      ),
      body: _isLoading ? const Center(child: CircularProgressIndicator()) : Column(
        children: [
          Container(
             color: Colors.grey.shade900,
             padding: const EdgeInsets.all(16),
             child: Row(
               mainAxisAlignment: MainAxisAlignment.spaceAround,
               children: [
                  _StatBox(title: 'Vallen', value: '${_crashes.length}', icon: Icons.sick),
                  _StatBox(title: 'Max Snelheid', value: _maxSpeed.toStringAsFixed(1), unit: 'km/h', icon: Icons.speed),
                  _StatBox(title: 'Afstand', value: _totalDistanceKm.toStringAsFixed(2), unit: 'km', icon: Icons.route),
               ],
             ),
          ),
          Expanded(
            flex: 2,
            child: Stack(
              children: [
                FlutterMap(
                  options: MapOptions(
                    initialCenter: centerMap,
                    initialZoom: 13.0,
                    initialCameraFit: routeBounds != null 
                        ? CameraFit.bounds(
                            bounds: routeBounds,
                            padding: const EdgeInsets.all(32.0),
                          )
                        : null,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.example.crashdetector',
                    ),
                    PolylineLayer(
                      polylines: [
                        if (_routePoints.isNotEmpty)
                          Polyline(
                            points: _routePoints,
                            strokeWidth: 5.0,
                            color: Colors.blueAccent,
                          ),
                      ],
                    ),
                    MarkerLayer(
                      markers: mapMarkers,
                    ),
                  ],
                ),
                if (_routePoints.isEmpty) 
                   Container(
                     color: Colors.black54,
                     child: const Center(child: Text('Geen GPS route gevonden voor deze sessie', style: TextStyle(color: Colors.white))),
                   )
              ],
            )
          ),
          const Padding(
            padding: EdgeInsets.all(8.0),
            child: Text('Geregistreerde Vallen', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          Expanded(
            flex: 1,
            child: _crashes.isEmpty 
               ? const Center(child: Text('Geen vallen geregistreerd in deze sessie!'))
               : ListView.builder(
                 itemCount: _crashes.length,
                 itemBuilder: (context, i) {
                    final crash = _crashes[i];
                    final date = DateTime.parse(crash['time']);
                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: ListTile(
                        leading: const CircleAvatar(backgroundColor: Colors.redAccent, child: Icon(Icons.warning_amber_rounded, color: Colors.white)),
                        title: Text('Val #${_crashes.length - i}'),
                        subtitle: Text('${date.hour}:${date.minute.toString().padLeft(2,'0')} | Impact: ${crash['severity'].toStringAsFixed(1)} m/s² | Snelheid ervóór: ${(crash['speed_before'] ?? 0.0).toStringAsFixed(1)} km/h'),
                      ),
                    );
                 }
               )
          )
        ],
      ),
    );
  }
}

class _StatBox extends StatelessWidget {
  final String title;
  final String value;
  final String unit;
  final IconData icon;

  const _StatBox({required this.title, required this.value, this.unit = '', required this.icon});

  @override
  Widget build(BuildContext context) {
     return Column(
       children: [
         Icon(icon, color: Colors.orange),
         const SizedBox(height: 4),
         Text(title, style: const TextStyle(color: Colors.grey, fontSize: 12)),
         RichText(
           text: TextSpan(
             children: [
               TextSpan(text: value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
               if (unit.isNotEmpty) TextSpan(text: ' $unit', style: const TextStyle(fontSize: 12, color: Colors.white70)),
             ]
           )
         )
       ],
     );
  }
}

// ----- SETTINGS -----

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  double _crashThreshold = 40.0;
  int _cooldown = 10;
  String _activityType = 'snowboard';
  String _preset = 'oneplus11';

  final Map<String, Map<String, dynamic>> _presetValues = {
    'general': {'name': 'Algemeen', 'threshold': 40.0, 'cooldown': 10},
    'oneplus11': {'name': 'OnePlus 11', 'threshold': 40.0, 'cooldown': 10},
    'nothing': {'name': 'Nothing Phone', 'threshold': 35.0, 'cooldown': 10},
    'iphone': {'name': 'iPhone', 'threshold': 30.0, 'cooldown': 10},
    'custom': {'name': 'Handmatig Aangepast', 'threshold': null, 'cooldown': null},
  };

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _crashThreshold = prefs.getDouble('crashThreshold') ?? 40.0;
      _cooldown = prefs.getInt('cooldownTime') ?? 10;
      _activityType = prefs.getString('activityType') ?? 'snowboard';
      _preset = prefs.getString('devicePreset') ?? 'oneplus11';
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('crashThreshold', _crashThreshold);
    await prefs.setInt('cooldownTime', _cooldown);
    await prefs.setString('activityType', _activityType);
    await prefs.setString('devicePreset', _preset);
    
    final service = FlutterBackgroundService();
    if (await service.isRunning()) {
      service.invoke('updateSettings', {
        'crashThreshold': _crashThreshold,
        'cooldownTime': _cooldown,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Instellingen'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: ListView(
          children: [
            const Text('Apparaat Preset', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Kies een instelling gebaseerd op de telefoon die gebruikt wordt, aangezien sensoren verschillen per model.', style: TextStyle(color: Colors.grey)),
            DropdownButton<String>(
              isExpanded: true,
              value: _preset,
              items: _presetValues.entries.map((entry) {
                return DropdownMenuItem<String>(
                  value: entry.key,
                  child: Text(entry.value['name']),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null && value != 'custom') {
                  setState(() {
                    _preset = value;
                    _crashThreshold = _presetValues[value]!['threshold'];
                    _cooldown = _presetValues[value]!['cooldown'];
                  });
                  _saveSettings();
                }
              },
            ),
            const Divider(height: 32),
            const Text('Val Gevoeligheid (m/s²)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Huidige drempelwaarde: ${_crashThreshold.toStringAsFixed(1)} m/s²\n(Lager = gevoeliger, Hoger = minder gevoelig)', style: const TextStyle(color: Colors.grey)),
            Slider(
              value: _crashThreshold,
              min: 10.0,
              max: 100.0,
              divisions: 90,
              label: _crashThreshold.toStringAsFixed(1),
              onChanged: (value) {
                setState(() {
                  _crashThreshold = value;
                  _preset = 'custom';
                });
              },
              onChangeEnd: (value) {
                _saveSettings();
              },
            ),
            const Divider(height: 32),
            const Text('Cooldown Tijd (seconden)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Tijd wachten na een val: $_cooldown seconden', style: const TextStyle(color: Colors.grey)),
            Slider(
              value: _cooldown.toDouble(),
              min: 2.0,
              max: 60.0,
              divisions: 58,
              label: _cooldown.toString(),
              onChanged: (value) {
                setState(() {
                  _cooldown = value.toInt();
                  _preset = 'custom';
                });
              },
              onChangeEnd: (value) {
                _saveSettings();
              },
            ),
            const Divider(height: 32),
            const Text('Icoon Weergave', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: RadioListTile<String>(
                    title: const Text('Snowboard'),
                    value: 'snowboard',
                    groupValue: _activityType,
                    onChanged: (value) {
                      setState(() { _activityType = value!; });
                      _saveSettings();
                    },
                  ),
                ),
                Expanded(
                  child: RadioListTile<String>(
                    title: const Text('Ski'),
                    value: 'ski',
                    groupValue: _activityType,
                    onChanged: (value) {
                      setState(() { _activityType = value!; });
                      _saveSettings();
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
