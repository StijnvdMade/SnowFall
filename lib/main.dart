import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:convert';

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
      initialNotificationTitle: 'Crash & Route Tracker',
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

class TrackedPoint {
  final Position position;
  final DateTime time;
  TrackedPoint(this.position, this.time);
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  bool isMonitoring = true;
  double crashThreshold = 40.0; // +- 4G krachten
  
  List<TrackedPoint> recentPositions = [];
  Timer? routeSaveTimer;

  // Start Locatie Stream voor Route & Snelheid
  final locationSettings = const LocationSettings(
    accuracy: LocationAccuracy.best,
    distanceFilter: 2, // Check elke 2 meter
  );

  StreamSubscription<Position>? posStream = Geolocator.getPositionStream(locationSettings: locationSettings).listen((Position position) async {
    final now = DateTime.now();
    recentPositions.add(TrackedPoint(position, now));
    
    // Voorkom een te volle lijst: bewaar maximaal de laatste 15 seconden aan data in RAM
    recentPositions.removeWhere((p) => now.difference(p.time).inSeconds > 15);

    // Sla de coördinaten op in de route (1x per beurt om schijf niet te spammen)
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    List<String> route = prefs.getStringList('route_history') ?? [];
    route.add(jsonEncode({
      'lat': position.latitude,
      'lon': position.longitude,
      'speed': (position.speed * 3.6), // in km/h
    }));
    await prefs.setStringList('route_history', route);
  });

  service.on('stopService').listen((event) {
    posStream.cancel();
    routeSaveTimer?.cancel();
    service.stopSelf();
    isMonitoring = false;
  });

  // Luister naar accelerometer voor crashes
  userAccelerometerEventStream().listen((UserAccelerometerEvent event) async {
    if (!isMonitoring) return;
    
    double gForce = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);

    if (gForce > crashThreshold) {
      isMonitoring = false;
      
      // Zoek de snelheid van 2 seconden geleden
      double speed2SecAgo = 0.0;
      DateTime targetTime = DateTime.now().subtract(const Duration(seconds: 2));
      
      if (recentPositions.isNotEmpty) {
        // Vind het punt dat het dichtst in de buurt kwam van de doeltijd (-2s)
        TrackedPoint closest = recentPositions.reduce((a, b) {
          int diffA = a.time.difference(targetTime).inMilliseconds.abs();
          int diffB = b.time.difference(targetTime).inMilliseconds.abs();
          return diffA < diffB ? a : b;
        });
        speed2SecAgo = closest.position.speed * 3.6; // convert m/s to km/h
      }

      await registerCrash(gForce, speed2SecAgo);
      
      // Cooldown timer
      Timer(const Duration(seconds: 10), () {
        isMonitoring = true;
      });
    }
  });
}

Future<void> registerCrash(double gForce, double speedBefore) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload(); 
  List<String> rawCrashes = prefs.getStringList('crash_history') ?? [];
  
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
  await prefs.setStringList('crash_history', rawCrashes);
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Crash Detector',
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.deepOrange,
        scaffoldBackgroundColor: const Color(0xff121212),
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.orange, brightness: Brightness.dark),
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _isTracking = false;
  List<Map<String, dynamic>> _crashes = [];
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadCrashes();
    _checkServiceStatus();
    
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (_isTracking) _loadCrashes();
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
    setState(() {
      _isTracking = isRunning;
    });
  }

  Future<void> _loadCrashes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); 
    List<String> rawCrashes = prefs.getStringList('crash_history') ?? [];
    setState(() {
      _crashes = rawCrashes.map((e) => jsonDecode(e) as Map<String, dynamic>).toList();
    });
  }
  
  Future<void> _clearEverything() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('crash_history');
    await prefs.remove('route_history');
    _loadCrashes();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Alle data verwijderd.')));
  }

  Future<void> _toggleTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

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
      await service.startService();
      setState(() { _isTracking = true; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Snowboard Tracker'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_forever),
            onPressed: _clearEverything,
            tooltip: 'Wis Sessie',
          ),
          IconButton(
            icon: const Icon(Icons.map),
            onPressed: () {
              Navigator.push(context, MaterialPageRoute(builder: (_) => const MapScreen()));
            },
            tooltip: 'Bekijk Totale Route',
          )
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
            child: Column(
              children: [
                const Icon(Icons.downhill_skiing, size: 80, color: Colors.orange),
                const SizedBox(height: 20),
                Text(
                  'Totale vallen: ${_crashes.length}',
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
            child: Text('Recente Vallen (Klik om te zien op kaart)', style: TextStyle(fontSize: 16, color: Colors.grey)),
          ),
          Expanded(
            child: _crashes.isEmpty
                ? const Center(child: Text('Goed bezig, nog niet gevallen!'))
                : ListView.builder(
                    itemCount: _crashes.length,
                    itemBuilder: (context, index) {
                      final crash = _crashes[index];
                      final date = DateTime.parse(crash['time']);
                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        child: ListTile(
                          onTap: () {
                            Navigator.push(context, MaterialPageRoute(builder: (_) => MapScreen(
                              focusLat: crash['lat'], 
                              focusLon: crash['lon']
                            )));
                          },
                          leading: const CircleAvatar(
                            backgroundColor: Colors.redAccent,
                            child: Icon(Icons.warning_amber_rounded, color: Colors.white),
                          ),
                          title: Text('Val #${_crashes.length - index}'),
                          subtitle: Text('Tijdstip: ${date.hour}:${date.minute.toString().padLeft(2, '0')}\n'
                                       'Impact: ${crash['severity'].toStringAsFixed(1)} m/s²\n'
                                       'Snelheid voor val: ${(crash['speed_before'] ?? 0.0).toStringAsFixed(1)} km/h'),
                          isThreeLine: true,
                          trailing: const Icon(Icons.map, color: Colors.orangeAccent),
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

class MapScreen extends StatefulWidget {
  final double? focusLat;
  final double? focusLon;

  const MapScreen({Key? key, this.focusLat, this.focusLon}) : super(key: key);

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  GoogleMapController? mapController;
  Set<Polyline> _polylines = {};
  Set<Marker> _markers = {};
  LatLng _center = const LatLng(52.3676, 4.9041); // Default A'dam

  @override
  void initState() {
    super.initState();
    if (widget.focusLat != null && widget.focusLat != 0.0) {
      _center = LatLng(widget.focusLat!, widget.focusLon!);
    }
    _loadMapData();
  }

  Future<void> _loadMapData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    
    // Laad Route Data
    List<String> rawRoute = prefs.getStringList('route_history') ?? [];
    List<LatLng> routePoints = [];
    for (String r in rawRoute) {
      Map<String, dynamic> pointData = jsonDecode(r);
      routePoints.add(LatLng(pointData['lat'], pointData['lon']));
    }

    if (routePoints.isNotEmpty && widget.focusLat == null) {
      _center = routePoints.last; // centreer op laatste punt indien geen crash is gekozen
    }

    // Laad Crashes Data voor de markers
    List<String> rawCrashes = prefs.getStringList('crash_history') ?? [];
    Set<Marker> crashMarkers = {};
    for (int i = 0; i < rawCrashes.length; i++) {
        Map<String, dynamic> c = jsonDecode(rawCrashes[i]);
        if (c['lat'] != 0.0 && c['lon'] != 0.0) {
          crashMarkers.add(
            Marker(
              markerId: MarkerId('crash_$i'),
              position: LatLng(c['lat'], c['lon']),
              infoWindow: InfoWindow(
                title: 'Val ${rawCrashes.length - i}',
                snippet: '${(c['speed_before'] ?? 0.0).toStringAsFixed(1)} km/h voor impact'
              ),
              icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
            )
          );
        }
    }

    setState(() {
      _polylines.add(
        Polyline(
          polylineId: const PolylineId('snowboard_route'),
          points: routePoints,
          color: Colors.blueAccent,
          width: 5,
        )
      );
      _markers = crashMarkers;
    });

    if (mapController != null) {
      mapController!.animateCamera(CameraUpdate.newLatLngZoom(_center, 15.0));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Route & Crashes')),
      body: GoogleMap(
        onMapCreated: (GoogleMapController controller) {
          mapController = controller;
        },
        initialCameraPosition: CameraPosition(
          target: _center,
          zoom: 15.0,
        ),
        polylines: _polylines,
        markers: _markers,
        myLocationEnabled: true,
      ),
    );
  }
}
