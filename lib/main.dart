import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const String googleApiKey = 'API_key';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: MapScreen(),
    );
  }
}

enum TravelMode { drive, twoWheeler }

class Place {
  final String name;
  final String address;
  final LatLng location;
  final String? phoneNumber;
  final String? website;
  final Map<String, String>? openingHours;
  final double? rating;
  final int? priceLevel;
  final List<String>? types;

  Place({
    required this.name,
    required this.address,
    required this.location,
    this.phoneNumber,
    this.website,
    this.openingHours,
    this.rating,
    this.priceLevel,
    this.types,
  });
}

class RouteOption {
  final List<LatLng> points;
  final String summary;
  final int distanceMeters;
  final int durationSeconds;
  final List<dynamic>? trafficIntervals;
  final String? trafficStatus;
  final int slowCount;
  final int jamCount;

  RouteOption({
    required this.points,
    required this.summary,
    required this.distanceMeters,
    required this.durationSeconds,
    this.trafficIntervals,
    this.trafficStatus,
    required this.slowCount,
    required this.jamCount,
  });
}

class NavigationScreen extends StatefulWidget {
  final LatLng initialPosition;
  final Set<Polyline> routePolylines;
  final LatLng? destination;
  final String routeSummary;

  const NavigationScreen({
    super.key, 
    required this.initialPosition,
    required this.routePolylines,
    this.destination,
    required this.routeSummary,
  });

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  late GoogleMapController _mapController;
  LatLng _currentPosition = const LatLng(0, 0);
  StreamSubscription<Position>? _positionStream;
  bool _isFollowing = true;
  double? _currentBearing;
  Position? _previousPosition;
  BitmapDescriptor? _navigationArrowIcon;
  Marker? _userLocationMarker;
  Set<Marker> _destinationMarkers = {};

@override
void initState() {
  super.initState();
  _loadCustomMarker();
  _currentPosition = widget.initialPosition;
  _startLocationUpdates();
  
  WakelockPlus.enable();
  
  if (widget.destination != null) {
    _addDestinationMarker(widget.destination!);
  }
}

@override
void dispose() {
  WakelockPlus.disable();
  _positionStream?.cancel();
  _mapController.dispose();
  super.dispose();
}

  Future<void> _loadCustomMarker() async {
    _navigationArrowIcon = await BitmapDescriptor.fromAssetImage(
      const ImageConfiguration(),
      'assets/navigation_arrow.png',
    );
  }

  void _updateUserLocationMarker(LatLng position, double? bearing) {
    setState(() {
      _userLocationMarker = Marker(
        markerId: const MarkerId('user_location'),
        position: position,
        rotation: bearing ?? 0,
        icon: _navigationArrowIcon ?? BitmapDescriptor.defaultMarker,
        anchor: const Offset(0.5, 0.5),
        flat: true,
      );
    });
  }

  Future<void> _applyMinimalStyle() async {
    int retries = 0;
    const maxRetries = 3;
    
    while (retries < maxRetries) {
      try {
        final style = await rootBundle.loadString('assets/minimal_map_style.json');
        await _mapController?.setMapStyle(style);
        break;
      } catch (e) {
        retries++;
        if (retries >= maxRetries) {
          debugPrint('Failed to apply map style after $maxRetries attempts');
        }
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  Future<void> _startLocationUpdates() async {
    final status = await Permission.locationWhenInUse.status;
    if (!status.isGranted) {
      await Permission.locationWhenInUse.request();
      if (!mounted) return;
    }

    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 3,
        timeLimit: Duration(seconds: 30),
      ),
    ).listen((newPosition) async {
      if (!mounted) return;

      try {
        final newLatLng = LatLng(newPosition.latitude, newPosition.longitude);
        double? newBearing;

        if (_previousPosition != null) {
          newBearing = Geolocator.bearingBetween(
            _previousPosition!.latitude,
            _previousPosition!.longitude,
            newPosition.latitude,
            newPosition.longitude,
          );
        }

        final effectiveBearing = newPosition.heading ?? newBearing ?? _currentBearing ?? 0;

        setState(() {
          _previousPosition = newPosition;
          _currentPosition = newLatLng;
          _currentBearing = effectiveBearing;
          
          _userLocationMarker = Marker(
            markerId: const MarkerId('user_location'),
            position: newLatLng,
            rotation: effectiveBearing,
            icon: _navigationArrowIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
            anchor: const Offset(0.5, 0.5),
            flat: true,
            zIndex: 2,
            consumeTapEvents: false,
          );
        });

        if (_isFollowing) {
          await _updateCameraPosition();
        }
      } catch (e) {
        debugPrint('Position update error: $e');
      }
    });
  }

Future<void> _updateCameraPosition() async {
  if (_mapController == null || _currentBearing == null) return;

  // 1. Calculate position offset (keeps pointer lower on screen)
  final latOffset = 0.002;
  final offsetPosition = LatLng(
    _currentPosition.latitude - latOffset,
    _currentPosition.longitude,
  );

  // 2. Get current zoom level to maintain consistency
  final zoom = await _mapController!.getZoomLevel();

  // 3. Apply camera update with proper bearing
  await _mapController!.animateCamera(
    CameraUpdate.newCameraPosition(
      CameraPosition(
        target: offsetPosition,
        zoom: zoom, // Maintain current zoom
        bearing: _currentBearing!, // Critical: Use actual bearing
        tilt: 45,
      ),
    ),
  );
}

  void _addDestinationMarker(LatLng destination) {
    setState(() {
      _destinationMarkers = {
        Marker(
          markerId: const MarkerId('destination'),
          position: destination,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        )
      };
    });
  }

    @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Container(),
        actions: [
          IconButton(
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(Icons.close, color: Colors.white),
            ),
            onPressed: () {
              Navigator.pop(context);
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: _currentPosition,
              zoom: 17,
              bearing: _currentBearing ?? 0,
              tilt: 45,
            ),
            onMapCreated: (controller) async {
              _mapController = controller;
              _loadCustomMarker();
              await controller.setMapStyle(null);
              final style = await rootBundle.loadString('assets/minimal_map_style.json');
              await controller.setMapStyle(style);
            },
            myLocationEnabled: false,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            compassEnabled: true,
            trafficEnabled: true,
            buildingsEnabled: false,
            rotateGesturesEnabled: false,
            tiltGesturesEnabled: false,
            mapToolbarEnabled: false,
            indoorViewEnabled: false,
            markers: {
              if (_userLocationMarker != null) _userLocationMarker!,
              ..._destinationMarkers,
            },
            polylines: widget.routePolylines,
            onCameraMove: (position) {
              if (_userLocationMarker != null) {
                _updateUserLocationMarker(
                  _userLocationMarker!.position,
                  position.bearing,
                );
              }
            },
          ),
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 20,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Text(
                widget.routeSummary,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  GoogleMapController? _mapController;
  LatLng _currentPosition = const LatLng(19.0760, 72.8777);
  bool _trafficEnabled = true;
  final TextEditingController _searchController = TextEditingController();
  List<dynamic> _placeSuggestions = [];
  Marker? _selectedMarker;
  Timer? _debounce;
  bool _isLoading = false;
  Set<Polyline> _polylines = {};
  LatLng? _destination;
  String _trafficStatus = 'No traffic data';
  List<RouteOption> _routeOptions = [];
  int _selectedRouteIndex = 0;
  String _selectedPlaceName = '';
  bool _showDetailsSheet = false;
  Timer? _trafficUpdateTimer;
  DateTime _lastUpdate = DateTime.now();
  bool _showUpdateIndicator = false;
  double _lastKnownSpeed = 0.0;
  Set<Polygon> _dashedBoundaries = {};
  final double _boundaryRadius = 1000;
  Set<Marker> _placeMarkers = {};
  Place? _selectedPlace;
  bool _showCancelButton = false;
  bool _isFetchingPlaceDetails = false;
  bool _showDirectionsSheet = false;
  LatLng? _startPoint;
  LatLng? _endPoint;
  final TextEditingController _startPointController = TextEditingController();
  final TextEditingController _endPointController = TextEditingController();
  List<Map<String, dynamic>> _recentDestinations = [];
  final FocusNode _searchFocusNode = FocusNode();
  final FocusNode _startPointFocusNode = FocusNode();
  final FocusNode _endPointFocusNode = FocusNode();
  StreamSubscription<Position>? _positionStream;
  bool _userInteractedWithMap = false;
  bool _myLocationEnabled = true;
  bool _showRouteSummary = false;
  String _startDisplayName = '';
  String _endDisplayName = '';
  LatLng? _homeLocation;
  LatLng? _workLocation;
  String _homeAddress = "Set Home Location";
  String _workAddress = "Set Work Location";
  final TextEditingController _homeSearchController = TextEditingController();
  final TextEditingController _workSearchController = TextEditingController();
  List<Map<String, dynamic>> _recentSearches = [];
  bool _showRecentSearches = false;
  final TextEditingController _searchHistoryController = TextEditingController();
  String? _lastTappedSuggestionId;
  String? _lastTappedRecentSearchId;
  String? _lastTappedRecentDestinationId;
  Timer? _tapFeedbackTimer;
  TravelMode _currentTravelMode = TravelMode.drive;
  bool _showNavigationButton = false;

  @override
  void dispose() {
    _trafficUpdateTimer?.cancel();
    _debounce?.cancel();
    _positionStream?.cancel();
    _searchController.dispose();
    _startPointController.dispose();
    _endPointController.dispose();
    _homeSearchController.dispose();
    _workSearchController.dispose();
    _searchFocusNode.dispose();
    _startPointFocusNode.dispose();
    _endPointFocusNode.dispose();
    _mapController?.dispose();
    _tapFeedbackTimer?.cancel();
    super.dispose();
  }

  List<LatLng> _decodePolyline(String encoded) {
    return PolylinePoints().decodePolyline(encoded)
        .map((p) => LatLng(p.latitude, p.longitude))
        .toList();
  }

  (String, int, int) _calculateTrafficMetrics(List<dynamic> intervals) {
    int slowCount = 0;
    int jamCount = 0;
    List<dynamic> trafficIntervals = [];
    
    if (intervals.isNotEmpty) {
      trafficIntervals = List<dynamic>.from(intervals);
      for (final interval in trafficIntervals) {
        final speed = interval['speed'] as String?;
        if (speed == 'SLOW' || speed == 'slow') slowCount++;
        if (speed == 'TRAFFIC_JAM' || speed == 'traffic_jam') jamCount++;
      }
    }

    final trafficStatus = _getTrafficStatus(trafficIntervals, slowCount, jamCount);
    return (trafficStatus, slowCount, jamCount);
  }

  String _formatDistance(int meters) {
  if (meters < 1000) {
    return '${meters}m';
  }
  return '${(meters / 1000).toStringAsFixed(1)} km';
}

String _formatETA(int seconds) {
  final now = DateTime.now();
  final eta = now.add(Duration(seconds: seconds));
  return '${eta.hour}:${eta.minute.toString().padLeft(2, '0')}';
}

  void _swapFieldsOnly() {
    if (_startPoint == null || _endPoint == null) return;

    final tempText = _startPointController.text;
    _startPointController.text = _endPointController.text;
    _endPointController.text = tempText;

    final tempPoint = _startPoint;
    _startPoint = _endPoint;
    _endPoint = tempPoint;

    final tempName = _startDisplayName;
    _startDisplayName = _endDisplayName;
    _endDisplayName = tempName;
  }

  void _processDriveRoutes(List<dynamic> routes) {
    _processRoutes(
      routes: routes,
      modeName: "Car",
    );
  }

  void _processTwoWheelerRoutes(List<dynamic> routes) {
    _processRoutes(
      routes: routes,
      modeName: "Bike",
    );
  }

  void _processRoutes({
    required List<dynamic> routes,
    required String modeName,
  }) {
    try {
      if (routes.isEmpty) return;

      routes.sort((a, b) => _parseDuration(a['duration']).compareTo(_parseDuration(b['duration'])));

      final List<RouteOption> options = [];
      
      for (int i = 0; i < routes.length; i++) {
        final route = routes[i];
        final polyline = route['polyline']['encodedPolyline'] as String? ?? '';
        final points = _decodePolyline(polyline);

        debugPrint('Route ${i + 1} traffic data: ${route['travelAdvisory']?['speedReadingIntervals']}');

        int slowCount = 0;
        int jamCount = 0;
        List<dynamic> trafficIntervals = [];
        
        if (route['travelAdvisory']?['speedReadingIntervals'] != null) {
          trafficIntervals = List<dynamic>.from(route['travelAdvisory']['speedReadingIntervals']);
          
          for (final interval in trafficIntervals) {
            final speed = interval['speed'] as String?;
            if (speed == 'SLOW' || speed == 'slow') slowCount++;
            if (speed == 'TRAFFIC_JAM' || speed == 'traffic_jam') jamCount++;
          }
        }

        final trafficStatus = _getTrafficStatus(trafficIntervals, slowCount, jamCount);

        options.add(RouteOption(
          points: points,
          summary: "Route ${i + 1} - $modeName",
          distanceMeters: route['distanceMeters'] as int? ?? 0,
          durationSeconds: _parseDuration(route['duration']),
          trafficIntervals: trafficIntervals,
          trafficStatus: trafficStatus,
          slowCount: slowCount,
          jamCount: jamCount,
        ));

        debugPrint('Created route with ${points.length} points and ${trafficIntervals.length} traffic intervals');
      }

      setState(() {
        _routeOptions = options;
        if (_routeOptions.isNotEmpty) {
          _selectedRouteIndex = 0;
          _updateRouteStatus(_routeOptions[0]);
          _displayAllRoutes();
        }
      });
    } catch (e) {
      debugPrint('Error processing routes: $e');
      if (routes.isNotEmpty) {
        final route = routes.first;
        final polyline = route['polyline']['encodedPolyline'] as String? ?? '';
        final points = _decodePolyline(polyline);
        
        setState(() {
          _routeOptions = [
            RouteOption(
              points: points,
              summary: "Route 1 - $modeName",
              distanceMeters: route['distanceMeters'] as int? ?? 0,
              durationSeconds: _parseDuration(route['duration']),
              trafficIntervals: [],
              trafficStatus: 'No traffic data',
              slowCount: 0,
              jamCount: 0,
            )
          ];
          _selectedRouteIndex = 0;
        });
      }
    }
  }

  String _getTrafficStatus(List<dynamic> intervals, int slowCount, int jamCount) {
    if (intervals.isEmpty) return 'No traffic data';
    
    double totalDistance = 0;
    double slowDistance = 0;
    double jamDistance = 0;
    double visualWeight = 0;

    for (final interval in intervals) {
      final distance = (interval['endPolylinePointIndex'] ?? 0) - 
                     (interval['startPolylinePointIndex'] ?? 0);
      totalDistance += distance;
      
      final speed = interval['speed'] as String?;
      if (speed == 'SLOW' || speed == 'slow') {
        slowDistance += distance;
        visualWeight += distance * 1.5;
      } else if (speed == 'TRAFFIC_JAM' || speed == 'traffic_jam') {
        jamDistance += distance;
        visualWeight += distance * 2;
      }
    }
    
    if (totalDistance == 0) return 'No traffic data';
    
    final slowPercent = (slowDistance / totalDistance * 100).round();
    final jamPercent = (jamDistance / totalDistance * 100).round();
    final visualPercent = (visualWeight / totalDistance * 100).round();

    if (visualPercent > 25) {
      return 'Heavy Traffic (${visualPercent}% congested)\n'
             'Slow: $slowCount  | Jams: $jamCount';
    } else if (visualPercent > 15) {
      return 'Moderate Traffic (${visualPercent}% congested)\n'
             'Slow: $slowCount  | Jams: $jamCount';
    } else if (visualPercent > 5 || (slowCount + jamCount) > 3) {
      return 'Light Traffic\n'
             'Slow: $slowCount | Jams: $jamCount';
    }
    
    return 'No traffic\n'
           'Slow: $slowCount | Jams: $jamCount';
  }

  int _parseDuration(String duration) {
    try {
      if (duration.endsWith('s')) {
        return int.parse(duration.substring(0, duration.length - 1));
      }
      return 0;
    } catch (e) {
      debugPrint('Error parsing duration: $e');
      return 0;
    }
  }

  String _formatTimeAgo(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);
    
    if (difference.inMinutes < 1) return "Just now";
    if (difference.inHours < 1) return "${difference.inMinutes} min ago";
    if (difference.inDays < 1) return "${difference.inHours} hr ago";
    if (difference.inDays < 7) return "${difference.inDays} days ago";
    return "${difference.inDays ~/ 7} weeks ago";
  }

  Future<void> _loadRecentSearches() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString('recentSearches');
    
    if (jsonString != null) {
      setState(() {
        _recentSearches = List<Map<String, dynamic>>.from(json.decode(jsonString));
      });
    }
  }

  Future<void> _saveRecentSearches() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('recentSearches', json.encode(_recentSearches));
  }

  void _addToRecentSearches(String query, {String? placeId}) {
    _recentSearches.removeWhere((search) => search['query'] == query);
    setState(() {
      _recentSearches.insert(0, {
        'query': query,
        'placeId': placeId,
        'time': DateTime.now().toIso8601String(),
      });
      if (_recentSearches.length > 5) {
        _recentSearches.removeLast();
      }
    });
    _saveRecentSearches();
  }

  void _clearRecentSearches() {
    setState(() {
      _recentSearches.clear();
    });
    _saveRecentSearches();
  }

  void _removeRecentSearch(int index) {
    setState(() {
      _recentSearches.removeAt(index);
    });
    _saveRecentSearches();
  }

  void _handleTapFeedback(String type, String id) {
    setState(() {
      if (type == 'suggestion') {
        _lastTappedSuggestionId = id;
      } else if (type == 'recentSearch') {
        _lastTappedRecentSearchId = id;
      } else if (type == 'recentDestination') {
        _lastTappedRecentDestinationId = id;
      }
    });

    _tapFeedbackTimer?.cancel();
    _tapFeedbackTimer = Timer(const Duration(milliseconds: 300), () {
      setState(() {
        _lastTappedSuggestionId = null;
        _lastTappedRecentSearchId = null;
        _lastTappedRecentDestinationId = null;
      });
    });
  }

  Future<void> _saveHomeWorkLocations() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('home_lat', _homeLocation?.latitude ?? 0);
    await prefs.setDouble('home_lng', _homeLocation?.longitude ?? 0);
    await prefs.setString('home_address', _homeAddress);
    
    await prefs.setDouble('work_lat', _workLocation?.latitude ?? 0);
    await prefs.setDouble('work_lng', _workLocation?.longitude ?? 0);
    await prefs.setString('work_address', _workAddress);
  }

  Future<void> _loadHomeWorkLocations() async {
    final prefs = await SharedPreferences.getInstance();
    final homeLat = prefs.getDouble('home_lat');
    final homeLng = prefs.getDouble('home_lng');
    final workLat = prefs.getDouble('work_lat');
    final workLng = prefs.getDouble('work_lng');

    if (mounted) {
      setState(() {
        if (homeLat != null && homeLng != null) {
          _homeLocation = LatLng(homeLat, homeLng);
          _homeAddress = prefs.getString('home_address') ?? "Set Home Location";
        }
        if (workLat != null && workLng != null) {
          _workLocation = LatLng(workLat, workLng);
          _workAddress = prefs.getString('work_address') ?? "Set Work Location";
        }
      });
    }
  }

  void _updateDestinationMarker(LatLng position, String title) {
    setState(() {
      _placeMarkers.removeWhere((marker) => marker.markerId.value == 'selected_destination');
      _placeMarkers.add(
        Marker(
          markerId: const MarkerId('selected_destination'),
          position: position,
          infoWindow: InfoWindow(title: title),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        )
      );
    });
  }

  Future<void> _loadRecentDestinations() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString('recentDestinations');
    
    if (jsonString != null) {
      final List<dynamic> jsonList = json.decode(jsonString);
      setState(() {
        _recentDestinations = jsonList.map((item) => {
          'name': item['name'],
          'address': item['address'],
          'location': LatLng(item['location']['latitude'], item['location']['longitude']),
          'time': item['time'],
        }).toList();
      });
    }
  }

  Future<void> _saveRecentDestinations() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = _recentDestinations.map((dest) => {
      'name': dest['name'],
      'address': dest['address'],
      'location': {
        'latitude': dest['location'].latitude,
        'longitude': dest['location'].longitude,
      },
      'time': dest['time'],
    }).toList();
    
    await prefs.setString('recentDestinations', json.encode(jsonList));
  }

  void _showPlaceDetails(Place place) {
    setState(() {
      _placeMarkers.clear();
      _dashedBoundaries.clear();
      _selectedMarker = null;
      _showRouteSummary = false;
    });

    setState(() {
      _selectedPlace = place;
      _showDetailsSheet = true;
      _placeMarkers = {
        Marker(
          markerId: MarkerId(place.name),
          position: place.location,
          infoWindow: InfoWindow(title: place.name),
        )
      };
      _isFetchingPlaceDetails = false;
    });

    if (_isAreaPlace(place.types)) {
      _mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(place.location, 14),
      );
      _addDashedCircleBoundary(place.location);
    } else {
      _mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(place.location, 17),
      );
    }
  }

  double _calculateSearchRadius(double zoom) {
    if (zoom < 8) return 5000.0;
    if (zoom < 10) return 1000.0;
    if (zoom < 12) return 500.0;
    if (zoom < 14) return 200.0;
    if (zoom < 16) return 50.0;
    return 20.0;
  }

  Future<Map<String, dynamic>> _fetchPlaceDetailsById(String placeId) async {
    try {
      final response = await http.get(
        Uri.parse('https://places.googleapis.com/v1/places/$placeId'),
        headers: {
          'X-Goog-Api-Key': googleApiKey,
          'X-Goog-FieldMask': 'location,displayName.text,formattedAddress',
        },
      );

      final data = json.decode(response.body);
      return {
        'name': data['displayName']['text'],
        'address': data['formattedAddress'] ?? 'No address available',
        'location': LatLng(
          data['location']['latitude'],
          data['location']['longitude'],
        ),
      };
    } catch (e) {
      debugPrint('Error fetching place details by ID: $e');
      return {
        'name': 'Error',
        'address': 'Could not load details',
        'location': _currentPosition,
      };
    }
  }

  Future<Place?> _findNearestPlace(LatLng point, double radius) async {
    try {
      final response = await http.post(
        Uri.parse('https://places.googleapis.com/v1/places:searchNearby'),
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': googleApiKey,
          'X-Goog-FieldMask': 'places.displayName,places.formattedAddress,'
                             'places.location,places.nationalPhoneNumber,'
                             'places.websiteUri,places.regularOpeningHours,'
                             'places.rating,places.priceLevel,places.types',
        },
        body: json.encode({
          'maxResultCount': 1,
          'rankPreference': 'POPULARITY',
          'locationRestriction': {
            'circle': {
              'center': {
                'latitude': point.latitude,
                'longitude': point.longitude,
              },
              'radius': radius
            }
          }
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final places = data['places'] as List;
        
        if (places.isNotEmpty) {
          final place = places.first;
          final location = place['location'];
          final latLng = LatLng(location['latitude'], location['longitude']);
          
          Map<String, String>? openingHoursMap;
          if (place['regularOpeningHours']?['weekdayDescriptions'] != null) {
            openingHoursMap = {};
            final days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
            final descriptions = place['regularOpeningHours']['weekdayDescriptions'] as List;
            for (int i = 0; i < days.length && i < descriptions.length; i++) {
              openingHoursMap[days[i]] = descriptions[i].replaceAll('${days[i]}: ', '');
            }
          }
          
          return Place(
            name: place['displayName']['text'],
            address: place['formattedAddress'] ?? 'No address available',
            location: latLng,
            phoneNumber: place['nationalPhoneNumber'],
            website: place['websiteUri'],
            openingHours: openingHoursMap,
            rating: place['rating']?.toDouble(),
            priceLevel: place['priceLevel'],
            types: place['types']?.cast<String>(),
          );
        }
      }
      return null;
    } catch (e) {
      debugPrint('Error finding nearest place: $e');
      return null;
    }
  }

  Future<String> _reverseGeocode(LatLng position) async {
    try {
      final response = await http.get(
        Uri.parse('https://maps.googleapis.com/maps/api/geocode/json?'
                 'latlng=${position.latitude},${position.longitude}'
                 '&key=$googleApiKey'),
      );
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['results'].isNotEmpty) {
          return data['results'][0]['formatted_address'];
        }
      }
      return '${position.latitude}, ${position.longitude}';
    } catch (e) {
      debugPrint('Reverse geocoding error: $e');
      return '${position.latitude}, ${position.longitude}';
    }
  }

  void _showGenericLocation(String address) {
    setState(() {
      _selectedPlace = Place(
        name: 'Location',
        address: address,
        location: _currentPosition,
      );
      _showDetailsSheet = true;
      _isFetchingPlaceDetails = false;
    });
  }

  Future<void> _setHomeLocation(LatLng location, String address) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('home_lat', location.latitude);
    await prefs.setDouble('home_lng', location.longitude);
    await prefs.setString('home_address', address);
    
    if (mounted) {
      setState(() {
        _homeLocation = location;
        _homeAddress = address;
      });
    }
  }

  Future<void> _setWorkLocation(LatLng location, String address) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('work_lat', location.latitude);
    await prefs.setDouble('work_lng', location.longitude);
    await prefs.setString('work_address', address);
    
    if (mounted) {
      setState(() {
        _workLocation = location;
        _workAddress = address;
      });
    }
  }

  void _clearRoutes() {
    setState(() {
      _polylines.clear();
      _routeOptions.clear();
      _selectedRouteIndex = 0;
      _trafficStatus = 'No traffic data';
      _showCancelButton = false;
      _destination = null;
      _selectedMarker = null;
      _dashedBoundaries.clear();
      _showRouteSummary = false;
      _placeMarkers.clear();
      _showNavigationButton = false;
    });
  }

  void _clearSearch() {
    setState(() {
      _searchController.clear();
      _placeSuggestions.clear();
      _polylines.clear();
      _selectedMarker = null;
      _destination = null;
      _routeOptions.clear();
      _trafficUpdateTimer?.cancel();
      _dashedBoundaries.clear();
      _placeMarkers.clear();
      _selectedPlace = null;
      _showDetailsSheet = false;
      _showCancelButton = false;
    });
  }

  bool _isAreaPlace(List<String>? types) {
    if (types == null) return false;
    final areaTypes = [
      'locality',
      'sublocality',
      'neighborhood',
      'administrative_area_level_1',
      'administrative_area_level_2',
      'postal_code',
      'country'
    ];
    return types.any((type) => areaTypes.contains(type));
  }

  void _addDashedCircleBoundary(LatLng center) {
    const int totalSegments = 60;
    const int visibleSegments = 24;
    final List<LatLng> points = [];
    
    for (int i = 0; i < totalSegments; i++) {
      if (i % (totalSegments ~/ visibleSegments) == 0) {
        final angle = 2 * pi * i / totalSegments;
        final x = center.latitude + (_boundaryRadius / 111320) * cos(angle);
        final y = center.longitude + (_boundaryRadius / (111320 * cos(center.latitude * pi / 180))) * sin(angle);
        points.add(LatLng(x, y));
      }
    }

    setState(() {
      _dashedBoundaries = {
        Polygon(
          polygonId: const PolygonId('dashed_boundary'),
          points: points,
          strokeWidth: 3,
          strokeColor: Colors.red,
          fillColor: Colors.transparent,
          geodesic: true,
        )
      };
    });
  }

  Future<void> _fetchPlaceDetails(LatLng position) async {
    setState(() => _isFetchingPlaceDetails = true);
    try {
      final zoom = await _mapController?.getZoomLevel() ?? 12.0;
      final radius = _calculateSearchRadius(zoom);

      final response = await http.post(
        Uri.parse('https://places.googleapis.com/v1/places:searchNearby'),
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': googleApiKey,
          'X-Goog-FieldMask': 'places.displayName,places.formattedAddress,'
                             'places.location,places.nationalPhoneNumber,'
                             'places.websiteUri,places.regularOpeningHours,'
                             'places.rating,places.priceLevel,places.types',
        },
        body: json.encode({
          'maxResultCount': 1,
          'rankPreference': 'POPULARITY',
          'locationRestriction': {
            'circle': {
              'center': {
                'latitude': position.latitude,
                'longitude': position.longitude,
              },
              'radius': radius
            }
          }
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final places = data['places'] as List;
        
        if (places.isNotEmpty) {
          final place = places.first;
          _showPlaceDetails(Place(
            name: place['displayName']['text'],
            address: place['formattedAddress'] ?? 'No address available',
            location: LatLng(
              place['location']['latitude'],
              place['location']['longitude'],
            ),
            phoneNumber: place['nationalPhoneNumber'],
            website: place['websiteUri'],
            openingHours: place['regularOpeningHours']?['weekdayDescriptions'] != null
                ? Map.fromIterables(
                    ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'],
                    (place['regularOpeningHours']['weekdayDescriptions'] as List)
                        .map((d) => d.toString().replaceAll(RegExp(r'^[^:]+: '), ''))
                        .toList()
                  )
                : null,
            rating: place['rating']?.toDouble(),
            priceLevel: place['priceLevel'],
            types: place['types']?.cast<String>(),
          ));
        }
      }
    } catch (e) {
      debugPrint('Error fetching place details: $e');
      setState(() {
        _selectedPlace = Place(
          name: 'Error',
          address: 'Could not load place details',
          location: position,
        );
        _isFetchingPlaceDetails = false;
      });
    }
  }

  Future<void> _checkLocationPermission() async {
    final status = await Permission.locationWhenInUse.status;
    if (!status.isGranted) {
      await Permission.locationWhenInUse.request();
    }
  }

  Future<void> _enableLocationUpdates() async {
    final position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
    
    setState(() {
      _currentPosition = LatLng(position.latitude, position.longitude);
    });
    
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((newPosition) {
      if (mounted) {
        setState(() {
          _currentPosition = LatLng(newPosition.latitude, newPosition.longitude);
        });
        _handlePositionUpdate(newPosition);
      }
    });
  }

  Future<void> _fetchSuggestions(String input) async {
    setState(() => _isLoading = true);
    final String url = 'https://places.googleapis.com/v1/places:autocomplete';
    try {
      final response = await http.post(
        Uri.parse(url),
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': googleApiKey,
          'X-Goog-FieldMask': 'suggestions.placePrediction',
        },
        body: json.encode({
          'input': input,
          'locationBias': {
            'circle': {
              'center': {
                'latitude': _currentPosition.latitude,
                'longitude': _currentPosition.longitude,
              },
              'radius': 50000.0, 
            },
          },
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _placeSuggestions = (data['suggestions'] as List?)?.map((suggestion) {
            return {
              'displayName': suggestion['placePrediction']['text']['text'],
              'placeId': suggestion['placePrediction']['placeId'],
            };
          }).toList() ?? [];
        });
      } else {
        debugPrint('Places API error: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      debugPrint('Error fetching suggestions: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _goToPlace(String placeId) async {
    FocusScope.of(context).unfocus();
    _searchFocusNode.unfocus();
    
    setState(() {
      _isLoading = true;
      _polylines.clear();
      _routeOptions.clear();
      _selectedRouteIndex = 0;
      _trafficUpdateTimer?.cancel();
      _dashedBoundaries.clear();
      _placeMarkers.clear();
      _placeSuggestions.clear();
      _searchController.clear();
      _startPointController.clear();
      _endPointController.clear();
      _startPoint = null;
      _endPoint = null;
      _startDisplayName = '';
      _endDisplayName = '';
    });

    try {
      final response = await http.get(
        Uri.parse('https://places.googleapis.com/v1/places/$placeId'),
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': googleApiKey,
          'X-Goog-FieldMask': 'location,displayName,formattedAddress,'
                             'nationalPhoneNumber,websiteUri,regularOpeningHours,'
                             'rating,priceLevel,types',
        },
      );
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final location = data['location'];
        final displayName = data['displayName']['text'];
        _addToRecentSearches(displayName, placeId: placeId);
        final types = data['types']?.cast<String>();
        
        final LatLng latLng = LatLng(
          location['latitude'], 
          location['longitude']
        );
        Map<String, String>? openingHoursMap;
        if (data['regularOpeningHours']?['weekdayDescriptions'] != null) {
          openingHoursMap = {};
          final days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
          final descriptions = data['regularOpeningHours']['weekdayDescriptions'] as List;
          for (int i = 0; i < days.length && i < descriptions.length; i++) {
            openingHoursMap[days[i]] = descriptions[i].replaceAll('${days[i]}: ', '');
          }
        }
        
        final placeObj = Place(
          name: displayName,
          address: data['formattedAddress'] ?? 'No address available',
          location: latLng,
          phoneNumber: data['nationalPhoneNumber'],
          website: data['websiteUri'],
          openingHours: openingHoursMap,
          rating: data['rating']?.toDouble(),
          priceLevel: data['priceLevel'],
          types: types,
        );

        if (mounted) {
          setState(() {
            _destination = latLng;
            _selectedPlaceName = displayName;
            _selectedPlace = placeObj;
            _showDetailsSheet = true;
            _showRouteSummary = true;
            _endDisplayName = displayName;
            _endPointController.text = displayName;
            _endPoint = latLng;
            _startDisplayName = 'Current Location';
            _startPointController.text = 'Current Location';
            _startPoint = _currentPosition;
            _placeMarkers = {
              Marker(
                markerId: const MarkerId("selected_place"),
                position: latLng,
                infoWindow: InfoWindow(title: displayName),
              )
            };
          });
        }

        if (_isAreaPlace(types)) {
          _mapController?.animateCamera(
            CameraUpdate.newLatLngZoom(latLng, 14),
          );
          _addDashedCircleBoundary(latLng);
        } else {
          _mapController?.animateCamera(
            CameraUpdate.newLatLngZoom(latLng, 17),
          );
        }
      }
    } catch (e) {
      debugPrint('Error getting place details: $e');
      if (mounted) {
        setState(() {
          _selectedPlace = Place(
            name: 'Error',
            address: 'Could not load place details',
            location: _currentPosition,
          );
          _showDetailsSheet = true;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _startTrafficUpdates() {
    _trafficUpdateTimer?.cancel();
    _trafficUpdateTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      if (_destination != null && _shouldUpdateTraffic()) {
        _triggerTrafficUpdate();
      }
    });
  }

  bool _shouldUpdateTraffic() {
    final timeElapsed = DateTime.now().difference(_lastUpdate);
    final isCongested = _trafficStatus.contains('Jam') || 
                       _trafficStatus.contains('Slow') ||
                       _lastKnownSpeed < 20;
    
    return isCongested 
        ? timeElapsed > const Duration(minutes: 1)
        : timeElapsed > const Duration(minutes: 5);
  }

  void _triggerTrafficUpdate() {
    setState(() => _showUpdateIndicator = true);
    _getRoute(_currentPosition, _destination!);
    _lastUpdate = DateTime.now();
  }

  void _handlePositionUpdate(Position newPosition) {
    final distanceMoved = Geolocator.distanceBetween(
      _currentPosition.latitude,
      _currentPosition.longitude,
      newPosition.latitude,
      newPosition.longitude,
    );

    final timeElapsed = newPosition.timestamp?.difference(
      _lastUpdate
    ) ?? const Duration(seconds: 1);
    
    _lastKnownSpeed = distanceMoved / timeElapsed.inSeconds * 3.6;

    if (distanceMoved > 500 || _shouldUpdateTraffic()) {
      if (_destination != null) {
        _triggerTrafficUpdate();
      }
    }
  }

  void _updateRouteStatus(RouteOption route) {
    final now = DateTime.now();
    final eta = now.add(Duration(seconds: route.durationSeconds));
    
    setState(() {
      _trafficStatus = '${route.summary}\n'
          'Distance: ${(route.distanceMeters / 1000).toStringAsFixed(1)} km\n'
          'Duration: ${_formatDuration(route.durationSeconds)}\n'
          'ETA: ${_formatDayPrefix(eta)} ${_formatAMPM(eta)}\n'
          '${route.trafficStatus}';
    });
  }

  String _formatDayPrefix(DateTime eta) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    final etaDate = DateTime(eta.year, eta.month, eta.day);

    if (etaDate.isAtSameMomentAs(today)) return 'Today';
    if (etaDate.isAtSameMomentAs(tomorrow)) return 'Tomorrow';
    return '${eta.month}/${eta.day}';
  }

  String _formatAMPM(DateTime time) {
    final hour = time.hour % 12;
    final ampm = time.hour < 12 ? 'AM' : 'PM';
    return '${hour == 0 ? 12 : hour}:${time.minute.toString().padLeft(2, '0')} $ampm';
  }

  String _formatDuration(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (hours > 0) {
      return '${hours}h ${minutes}m';
    }
    return '${minutes}m';
  }

  void _zoomToFitRoute(RouteOption route) {
    if (_mapController == null || route.points.isEmpty) return;
    
    final startPoint = _startPoint ?? _currentPosition;
    final endPoint = _endPoint ?? _destination;
    
    if (endPoint == null) return;
    
    final bounds = _boundsFromLatLngList([
      startPoint,
      endPoint,
      ...route.points
    ]);
    
    _mapController?.animateCamera(
      CameraUpdate.newLatLngBounds(bounds, 100),
    );
  }

  LatLngBounds _boundsFromLatLngList(List<LatLng> list) {
    double? x0, x1, y0, y1;
    for (LatLng latLng in list) {
      if (x0 == null) {
        x0 = x1 = latLng.latitude;
        y0 = y1 = latLng.longitude;
      } else {
        if (latLng.latitude > x1!) x1 = latLng.latitude;
        if (latLng.latitude < x0) x0 = latLng.latitude;
        if (latLng.longitude > y1!) y1 = latLng.longitude;
        if (latLng.longitude < y0!) y0 = latLng.longitude;
      }
    }
    return LatLngBounds(
      northeast: LatLng(x1!, y1!),
      southwest: LatLng(x0!, y0!),
    );
  }

void _displayAllRoutes() {
  Set<Polyline> newPolylines = {};
  
  for (int i = 0; i < _routeOptions.length; i++) {
    final route = _routeOptions[i];
    final isSelected = i == _selectedRouteIndex;

    newPolylines.add(Polyline(
      polylineId: PolylineId('route_${i}_visual'),
      points: route.points,
      color: isSelected ? Colors.blue[800]! : Colors.blue[300]!,
      width: isSelected ? 7 : 5,
      zIndex: isSelected ? 3 : 1,
    ));

    if (route.trafficIntervals != null) {
      for (final interval in route.trafficIntervals!) {
        final start = interval['startPolylinePointIndex'] ?? 0;
        final end = min(
          interval['endPolylinePointIndex'] ?? route.points.length,
          route.points.length
        );
        
        if (start >= end) continue;
        
        final speed = interval['speed'] as String?;
        if (speed != null) {
          newPolylines.add(Polyline(
            polylineId: PolylineId('route_${i}_traffic_${speed}_$start'),
            points: route.points.sublist(start, end),
            color: _getTrafficColor(speed, isSelected),
            width: isSelected ? 7 : 5,
            zIndex: isSelected ? 4 : 2,
          ));
        }
      }
    }

    newPolylines.add(Polyline(
      polylineId: PolylineId('route_${i}_tap'),
      points: route.points,
      color: Colors.transparent,
      width: 30,
      zIndex: 100,
      consumeTapEvents: true,
      onTap: () {
        HapticFeedback.lightImpact();
        setState(() {
          _selectedRouteIndex = i;
          _updateRouteStatus(route);
        });
        _displayAllRoutes();
        _zoomToFitRoute(route);
      },
    ));
  }

  setState(() {
    _polylines = newPolylines;
    _showNavigationButton = _routeOptions.isNotEmpty; // Control navigation button visibility
    if (_routeOptions.isNotEmpty) {
      _showRouteSummary = true; // Ensure route summary is shown when routes exist
    }
  });
}

  Color _getTrafficColor(String speed, bool isSelected) {
    switch (speed.toUpperCase()) {
      case 'SLOW': 
        return Colors.orange;
      case 'TRAFFIC_JAM': 
        return Colors.red;
      case 'NORMAL':
      default:
        return isSelected ? Colors.blue[800]! : Colors.blue[300]!;
    }
  }

  @override
  void initState() {
    super.initState();
    _searchFocusNode.addListener(() {
      if (!_searchFocusNode.hasFocus) {
        setState(() {
          _showRecentSearches = false;
        });
      }
    });
    _checkPermissionAndLocate();
    _loadRecentDestinations();
    _loadRecentSearches();
    _loadHomeWorkLocations();
  } 

  Future<void> _checkPermissionAndLocate() async {
    try {
      final status = await Permission.locationWhenInUse.status;
      if (!status.isGranted) {
        final requestedStatus = await Permission.locationWhenInUse.request();
        if (!requestedStatus.isGranted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Location permission not granted')),
            );
          }
          return;
        }
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(const Duration(seconds: 10));
      
      if (!mounted) return;
      
      setState(() {
        _currentPosition = LatLng(position.latitude, position.longitude);
      });

      await _mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(_currentPosition, 15),
      );

      _positionStream?.cancel();
      _positionStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
          timeLimit: Duration(seconds: 30),
        ),
      ).listen((newPosition) {
        if (!mounted) return;
        
        setState(() {
          _currentPosition = LatLng(newPosition.latitude, newPosition.longitude);
        });
        
        if (!_userInteractedWithMap) {
          _mapController?.animateCamera(
            CameraUpdate.newLatLng(_currentPosition),
          );
        }
        
        _handlePositionUpdate(newPosition);
      });

    } catch (e) {
      debugPrint('Location error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not get location: ${e.toString()}')),
        );
      }
    }
  }

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      if (query.isNotEmpty) {
        _clearAllRouteData();
        _fetchSuggestions(query);
      } else {
        setState(() {
          _placeSuggestions.clear();
          _dashedBoundaries.clear();
          _placeMarkers.clear();
          _selectedPlace = null;
          _showDetailsSheet = false;
        });
      }
    });
  }

  Future<void> _getRoute(LatLng origin, LatLng destination) async {
    setState(() {
      _isLoading = true;
      _polylines.clear();
      _routeOptions.clear();
      _selectedRouteIndex = 0;
      _trafficStatus = 'Loading route options...';
      _showCancelButton = false;
      _destination = destination;
    });

    try {
      final response = await http.post(
        Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes'),
        headers: {
          'X-Goog-Api-Key': googleApiKey,
          'Content-Type': 'application/json',
          'X-Goog-FieldMask': _currentTravelMode == TravelMode.twoWheeler
              ? 'routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline,routes.travelAdvisory.speedReadingIntervals,routes.routeLabels'
              : 'routes.polyline,routes.travelAdvisory,routes.distanceMeters,routes.duration,routes.routeLabels',
        },
        body: json.encode({
          "origin": {"location": {"latLng": {
            "latitude": origin.latitude,
            "longitude": origin.longitude
          }}},
          "destination": {"location": {"latLng": {
            "latitude": destination.latitude,
            "longitude": destination.longitude
          }}},
          "travelMode": _currentTravelMode == TravelMode.twoWheeler ? "TWO_WHEELER" : "DRIVE",
          "routingPreference": _currentTravelMode == TravelMode.drive 
              ? "TRAFFIC_AWARE_OPTIMAL"
              : "TRAFFIC_AWARE",
          "polylineEncoding": "ENCODED_POLYLINE",
          "computeAlternativeRoutes": true,
          if (_currentTravelMode == TravelMode.drive) ...{
            "departureTime": DateTime.now().add(const Duration(minutes: 5)).toUtc().toIso8601String(),
            "extraComputations": ["TRAFFIC_ON_POLYLINE"],
            "routeModifiers": {
              "avoidTolls": false,
              "avoidHighways": false,
              "avoidFerries": true
            },
          },
          if (_currentTravelMode == TravelMode.twoWheeler) ...{
            "extraComputations": ["TRAFFIC_ON_POLYLINE"],
            "routeModifiers": {
              "avoidHighways": false,
              "avoidFerries": true
            },
          },
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (_currentTravelMode == TravelMode.twoWheeler) {
          _processTwoWheelerRoutes(data['routes'] as List);
        } else {
          _processDriveRoutes(data['routes'] as List);
        }

        if (_routeOptions.isNotEmpty) {
          _updateRouteStatus(_routeOptions[_selectedRouteIndex]);
          _displayAllRoutes();
          _zoomToFitRoute(_routeOptions[_selectedRouteIndex]);
        }
      }
    } catch (e) {
      setState(() => _trafficStatus = 'Error: ${e.toString()}');
    } finally {
      setState(() {
        _isLoading = false;
        _showUpdateIndicator = false;
      });
    }
  }

  void _swapStartAndDestination() async {
    if (_startPoint == null || _endPoint == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select valid start and destination points')),
      );
      return;
    }

    final originalStartName = _startDisplayName;
    final originalEndName = _endDisplayName;
    final originalStartPoint = _startPoint;
    final originalEndPoint = _endPoint;

    setState(() {
      _isLoading = true;
      _polylines.clear();
      _routeOptions.clear();
      _selectedRouteIndex = 0;
      _showCancelButton = false;
      _trafficStatus = 'Calculating new route...';
      _startDisplayName = originalEndName;
      _endDisplayName = originalStartName;
      _startPointController.text = _startDisplayName;
      _endPointController.text = _endDisplayName;
      _startPoint = originalEndPoint;
      _endPoint = originalStartPoint;
    });

    try {
      await _getRoute(originalEndPoint!, originalStartPoint!);
      
    } catch (e) {
      debugPrint('Error swapping route: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update route: ${e.toString()}')),
        );
        
        setState(() {
          _startDisplayName = originalStartName;
          _endDisplayName = originalEndName;
          _startPointController.text = originalStartName;
          _endPointController.text = originalEndName;
          _startPoint = originalStartPoint;
          _endPoint = originalEndPoint;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
    
    HapticFeedback.lightImpact();
  }

  void _toggleDirectionsSheet() {
    if (_showRecentSearches) {
      setState(() {
        _showRecentSearches = false;
      });
    }
    setState(() {
      _showDirectionsSheet = !_showDirectionsSheet;
      if (_showDirectionsSheet) {
        _placeMarkers.clear();
        _startPoint = _currentPosition;
        _reverseGeocode(_currentPosition).then((address) {
          _startPointController.text = address;
        });

        if (_recentDestinations.isNotEmpty) {
          final recent = _recentDestinations.first;
          _endPointController.text = recent['name'];
          _endPoint = recent['location'];
        } else {
          _endPointController.clear();
        }
      }
    });
  }

  void _clearAllRouteData() {
    setState(() {
      _polylines.clear();
      _routeOptions.clear();
      _selectedRouteIndex = 0;
      _startPoint = null;
      _endPoint = null;
      _startPointController.clear();
      _endPointController.clear();
      _showCancelButton = false;
      _trafficStatus = 'No route data';
      _placeMarkers.clear();
    });
  }

  void _hideRecentSearches() {
    if (_showRecentSearches) {
      setState(() {
        _showRecentSearches = false;
      });
    }
  }

  void _toggleTravelMode() {
    setState(() {
      _currentTravelMode = _currentTravelMode == TravelMode.drive 
          ? TravelMode.twoWheeler 
          : TravelMode.drive;
    });
    
    if (_startPoint != null && _endPoint != null) {
      _getRoute(_startPoint!, _endPoint!);
    }
  }

  void _addToRecentDestinations(String name, String address, LatLng location) {
    setState(() {
      _recentDestinations.insert(0, {
        'name': name,
        'address': address,
        'location': location,
        'time': _formatTimeAgo(DateTime.now()),
      });
      
      if (_recentDestinations.length > 5) {
        _recentDestinations.removeLast();
      }
    });
    
    _saveRecentDestinations();
  }

  Future<void> _showLocationEditDialog(BuildContext context, {required bool isHome}) async {
    final controller = isHome ? _homeSearchController : _workSearchController;
    controller.text = isHome ? _homeAddress : _workAddress;

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("Edit ${isHome ? 'Home' : 'Work'} Location"),
        content: TextField(
          controller: controller,
          readOnly: true,
          decoration: InputDecoration(
            hintText: "Search location",
            suffixIcon: IconButton(
              icon: const Icon(Icons.search),
              onPressed: () async {
                final result = await showSearch(
                  context: context,
                  delegate: PlaceSearchDelegate(currentPosition: _currentPosition),
                );
                if (result != null) {
                  final place = await _fetchPlaceDetailsById(result['placeId']);
                  setState(() {
                    if (isHome) {
                      _homeLocation = place['location'];
                      _homeAddress = place['name'];
                    } else {
                      _workLocation = place['location'];
                      _workAddress = place['name'];
                    }
                  });
                  Navigator.pop(context);
                }
              },
            ),
          ),
          onTap: () async {
            final result = await showSearch(
              context: context,
              delegate: PlaceSearchDelegate(currentPosition: _currentPosition),
            );
            if (result != null) {
              final place = await _fetchPlaceDetailsById(result['placeId']);
              if (isHome) {
                await _setHomeLocation(place['location'], place['name']);
              } else {
                await _setWorkLocation(place['location'], place['name']);
              }
              Navigator.pop(context);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
        ],
      ),
    );
  }

  double _getBottomPadding(BuildContext context, {bool includeExtra = true, bool forSheet = false}) {
    if (forSheet) return 0;
    
    final mediaQuery = MediaQuery.of(context);
    final bottomPadding = mediaQuery.viewPadding.bottom;
    return bottomPadding > 0 ? bottomPadding + (includeExtra ? 16 : 0) : (includeExtra ? 16 : 0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        toolbarHeight: 0,
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: _currentPosition,
              zoom: 15.5,
            ),
            onMapCreated: (controller) async {
              _mapController = controller;
              await _checkLocationPermission();
              _enableLocationUpdates();
              if (mounted) {
                setState(() => _userInteractedWithMap = false);
              }
            },
            onTap: (latLng) async {
              _hideRecentSearches();
              setState(() {
                _selectedMarker = null;
                _dashedBoundaries.clear();
                _placeMarkers.clear();
                _selectedPlace = null;
                _showDetailsSheet = false;
                _isFetchingPlaceDetails = true;
                _userInteractedWithMap = true;
              });
              
              final zoom = await _mapController?.getZoomLevel() ?? 12.0;
              final radius = _calculateSearchRadius(zoom);
              
              final place = await _findNearestPlace(latLng, radius);
              
              if (place != null) {
                _showPlaceDetails(place);
              } else {
                final address = await _reverseGeocode(latLng);
                _showGenericLocation(address);
              }
            },
            myLocationEnabled: _myLocationEnabled,
            myLocationButtonEnabled: false,
            trafficEnabled: _trafficEnabled,
            zoomControlsEnabled: false,
            zoomGesturesEnabled: true,
            scrollGesturesEnabled: true,
            rotateGesturesEnabled: true,
            tiltGesturesEnabled: true,
            markers: {
              if (_selectedMarker != null) _selectedMarker!,
              ..._placeMarkers,
            },
            polylines: _polylines,
            polygons: _dashedBoundaries,
            onCameraMoveStarted: () {
              _hideRecentSearches();
              if (mounted) {
                setState(() => _userInteractedWithMap = true);
              }
            },
          ),

          if (_isFetchingPlaceDetails)
            Positioned(
              top: MediaQuery.of(context).size.height / 2 - 20,
              left: MediaQuery.of(context).size.width / 2 - 20,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.8),
                  borderRadius: BorderRadius.circular(40),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black12,
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    ),  
                  ],
                ),
                child: const SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                  ),
                ),
              ),
            ),

          if (_showUpdateIndicator)
            Positioned(
              top: 50,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black12,
                      blurRadius: 4,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(Colors.blue),
                      ),
                    ),
                    SizedBox(width: 8),
                    Text('Updating traffic...', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ),

          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 16,
            right: 16,
            child: Column(
              children: [
                Material(
                  elevation: 2,
                  borderRadius: BorderRadius.circular(8),
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    onChanged: _onSearchChanged,
                    onTap: () {
                      if (!_searchFocusNode.hasFocus) {
                        _searchFocusNode.requestFocus();
                      }
                      setState(() {
                        _showRecentSearches = _searchController.text.isEmpty;
                      });
                    },
                    decoration: InputDecoration(
                      hintText: "Search places...",
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: _clearSearch,
                            )
                          : null,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    GestureDetector(
                      onTap: () {
                        setState(() => _trafficEnabled = !_trafficEnabled);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.1),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _trafficEnabled ? Icons.traffic : Icons.traffic_outlined,
                              size: 18,
                              color: Colors.blue,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _trafficEnabled ? "Hide Traffic" : "Show Traffic",
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.blue,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    GestureDetector(
                      onTap: _toggleTravelMode,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.1),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _currentTravelMode == TravelMode.twoWheeler 
                                  ? Icons.directions_car
                                  : Icons.motorcycle,
                              size: 18,
                              color: Colors.blue,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _currentTravelMode == TravelMode.twoWheeler 
                                  ? "Car" 
                                  : "Two-Wheeler",
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.blue,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    GestureDetector(
                      onTap: _polylines.isNotEmpty && _startPoint != null && _endPoint != null
                          ? () {
                              final start = _startPoint ?? _currentPosition;
                              final end = _endPoint ?? _destination;
                              if (start != null && end != null) {
                                _getRoute(start, end);
                              }
                            }
                          : null,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.1),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.refresh,
                              size: 18,
                              color: _polylines.isNotEmpty && _startPoint != null && _endPoint != null 
                                  ? Colors.blue 
                                  : Colors.grey,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              "Refresh",
                              style: TextStyle(
                                fontSize: 12,
                                color: _polylines.isNotEmpty && _startPoint != null && _endPoint != null
                                    ? Colors.blue
                                    : Colors.grey,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                if (_isLoading)
                  const Padding(
                    padding: EdgeInsets.all(8.0),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (_placeSuggestions.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 5),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: const [
                        BoxShadow(
                          blurRadius: 4,
                          color: Colors.black26,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _placeSuggestions.length,
                      itemBuilder: (context, index) {
                        final suggestion = _placeSuggestions[index];
                        return InkWell(
                          onTap: () {
                            HapticFeedback.lightImpact();
                            _handleTapFeedback('suggestion', suggestion['placeId']);
                            _goToPlace(suggestion['placeId']);
                          },
                          splashColor: Colors.grey[300],
                          highlightColor: Colors.grey[200],
                          child: Container(
                            color: _lastTappedSuggestionId == suggestion['placeId'] 
                                ? Colors.grey[300] 
                                : Colors.transparent,
                            child: ListTile(
                              title: Text(suggestion['displayName']),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),

          if (_showRecentSearches && _searchController.text.isEmpty)
            Positioned(
              top: MediaQuery.of(context).padding.top + 70,
              left: 16,
              right: 16,
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              "Recent Places",
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                            TextButton(
                              onPressed: _clearRecentSearches,
                              child: const Text(
                                "Clear all",
                                style: TextStyle(
                                  color: Colors.blue,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_recentSearches.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            "No recent searches",
                            style: TextStyle(color: Colors.grey),
                          ),
                        )
                      else
                        ListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _recentSearches.length,
                          itemBuilder: (context, index) {
                          final search = _recentSearches[index];
                          final uniqueId = '${search['query']}_${search['placeId'] ?? ''}';
                          return Material(
                            color: _lastTappedRecentSearchId == uniqueId
                                ? Colors.grey[300]
                                : Colors.transparent,
                            child: ListTile(
                              dense: true,
                              leading: const Icon(Icons.history, size: 20),
                              title: Text(search['query']),
                              trailing: IconButton(
                                icon: const Icon(Icons.close, size: 16),
                                onPressed: () => _removeRecentSearch(index),
                              ),
                              onTap: () {
                                _handleTapFeedback('recentSearch', uniqueId);
                                if (search['placeId'] != null) {
                                  _goToPlace(search['placeId']);
                                  setState(() {
                                    _searchController.text = search['query'];
                                    _showRecentSearches = false;
                                  });
                                } else {
                                  setState(() {
                                    _searchController.text = search['query'];
                                    _showRecentSearches = false;
                                  });
                                  _onSearchChanged(search['query']);
                                }
                              },
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),

          if (_showRouteSummary && _polylines.isNotEmpty)
            Positioned(
              top: MediaQuery.of(context).padding.top + 180,
              right: 16,
              width: MediaQuery.of(context).size.width * 0.4,
              child: Material(
                elevation: 2,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'From: $_startDisplayName',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[700],
                                height: 1.4,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'To: $_endDisplayName',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[700],
                                fontWeight: FontWeight.bold,
                                height: 1.4,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: Icon(Icons.swap_vert, 
                          size: 18, 
                          color: Colors.blue,
                        ),
                        onPressed: () {
                          _swapStartAndDestination();
                          _zoomToFitRoute(_routeOptions[_selectedRouteIndex]);
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),

          if (_polylines.isNotEmpty)
            Positioned(
              top: 165,
              right: 16,
              child: AnimatedOpacity(
                opacity: _polylines.isNotEmpty ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: FloatingActionButton(
                  heroTag: 'cancel_routes',
                  mini: true,
                  backgroundColor: Colors.red,
                  onPressed: _clearRoutes,
                  child: const Icon(Icons.close, color: Colors.white),
                ),
              ),
            ),    

          Positioned(
  bottom: _getBottomPadding(context),
  right: 16,
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      FloatingActionButton(
        heroTag: 'recenter',
        mini: true,
        onPressed: () async {
          try {
            if (mounted) {
              setState(() {
                _userInteractedWithMap = false;
                _myLocationEnabled = true;
              });
            }

            final position = await Geolocator.getCurrentPosition(
              desiredAccuracy: LocationAccuracy.high,
            ).timeout(const Duration(seconds: 5));

            if (!mounted) return;

            final newPos = LatLng(position.latitude, position.longitude);
            
            setState(() {
              _currentPosition = newPos;
            });

            await _mapController?.animateCamera(
              CameraUpdate.newLatLngZoom(newPos, 15.5),
            );

            if (_positionStream == null || _positionStream!.isPaused) {
              _checkPermissionAndLocate();
            }

          } catch (e) {
            debugPrint('Recenter error: $e');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Could not refresh location')),
              );
            }
          }
        },
        child: const Icon(Icons.my_location),
        backgroundColor: Colors.deepPurple[100],
      ),
       if (_showNavigationButton)
  Column(
    children: [
      const SizedBox(height: 12),
      FloatingActionButton.extended(
        heroTag: 'enter_navigation',
        backgroundColor: Colors.blue,
        onPressed: () async {
          if (_routeOptions.isNotEmpty) {
            await WakelockPlus.enable();
            final selectedRoute = _routeOptions[_selectedRouteIndex];
            final summary = '${selectedRoute.summary}\n'
                'Distance: ${_formatDistance(selectedRoute.distanceMeters)}\n'
                'ETA: ${_formatETA(selectedRoute.durationSeconds)}';
              if (!mounted) return;
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => NavigationScreen(
                  initialPosition: _currentPosition,
                  routePolylines: _polylines,
                  destination: _endPoint,
                  routeSummary: summary,
                ),
              ),
            );
          }
        },
        icon: const Icon(Icons.navigation, color: Colors.white),
        label: const Text("Navigate", style: TextStyle(color: Colors.white)),
      ),
    ],
  ),
      const SizedBox(height: 12),
      FloatingActionButton(
        heroTag: 'directions',
        mini: true,
        onPressed: _toggleDirectionsSheet,
        child: const Icon(Icons.directions),
        backgroundColor: Colors.deepPurple[100],
      ),
      const SizedBox(height: 12),
      FloatingActionButton.extended(
        heroTag: 'report',
        onPressed: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Jam reported!")),
          );
        },
        icon: const Icon(Icons.report_problem),
        label: const Text("Report Jam"),
        backgroundColor: Colors.deepPurple[100],
      ),
    ],
  ),
),

          Positioned(
            bottom: _getBottomPadding(context),
            left: 20,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.9),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _trafficStatus,
                style: const TextStyle(
                  fontSize: 14, 
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                ),
              ),
            ),
          ),

          if (_selectedPlace != null && _showDetailsSheet)
            NotificationListener<DraggableScrollableNotification>(
              onNotification: (notification) {
                if (notification.extent <= 0.2) {
                  Future.delayed(const Duration(milliseconds: 100), () {
                    if (mounted) {
                      setState(() {
                        _showDetailsSheet = false;
                        _placeMarkers.clear();
                        _dashedBoundaries.clear();
                        _selectedMarker = null;
                      });
                    }
                  });
                }
                return true;
              },
              child: DraggableScrollableSheet(
                initialChildSize: 0.25,
                minChildSize: 0.2,
                maxChildSize: 0.7,
                snap: true,
                snapSizes: const [0.25, 0.7],
                builder: (context, scrollController) {
                  final place = _selectedPlace!;
                  return Container(
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                    ),
                    child: Column(
                      children: [
                        GestureDetector(
                          onVerticalDragEnd: (details) {
                            if (details.primaryVelocity! > 1000) {
                              setState(() {
                                _showDetailsSheet = false;
                              });
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.only(top: 12, bottom: 8),
                            child: Center(
                              child: Container(
                                width: 60,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: Colors.grey[400],
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: SingleChildScrollView(
                            controller: scrollController,
                            child: Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          place.name,
                                          style: const TextStyle(
                                            fontSize: 22,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      if (place.rating != null)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8, 
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.blue[50],
                                            borderRadius: BorderRadius.circular(20),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const Icon(Icons.star, color: Colors.amber, size: 18),
                                              const SizedBox(width: 4),
                                              Text(
                                                place.rating.toString(),
                                                style: const TextStyle(fontWeight: FontWeight.bold),
                                              ),
                                            ],
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                  child: Text(
                                    place.address,
                                    style: TextStyle(
                                      color: Colors.grey[600],
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                                const Divider(height: 24, thickness: 1),
                                if (place.openingHours != null) ...[
                                  const Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 16),
                                    child: Text(
                                      'Opening Hours',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  ...place.openingHours!.entries.map(
                                    (entry) => Padding(
                                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                                      child: Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          SizedBox(
                                            width: 80,
                                            child: Text(
                                              entry.key,
                                              style: const TextStyle(fontWeight: FontWeight.w500),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(child: Text(entry.value)),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const Divider(height: 24, thickness: 1),
                                ],
                                if (place.phoneNumber != null || place.website != null) ...[
                                  const Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 16),
                                    child: Text(
                                      'Contact Information',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  if (place.phoneNumber != null)
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                                      child: Row(
                                        children: [
                                          const Icon(Icons.phone, size: 20, color: Colors.blue),
                                          const SizedBox(width: 8),
                                          Text(place.phoneNumber!),
                                        ],
                                      ),
                                    ),
                                  if (place.website != null)
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                                      child: Row(
                                        children: [
                                          const Icon(Icons.language, size: 20, color: Colors.blue),
                                          const SizedBox(width: 8),
                                          GestureDetector(
                                            onTap: () => launchUrl(Uri.parse(place.website!)),
                                            child: const Text(
                                              'Visit Website',
                                              style: TextStyle(
                                                color: Colors.blue,
                                                decoration: TextDecoration.underline,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  const SizedBox(height: 16),
                                ],
                              ],
                            ),
                          ),
                        ),
                        Container(
                          padding: EdgeInsets.only(
                            bottom: _getBottomPadding(context, includeExtra: false) + 10,
                            left: 16,
                            right: 16,
                            top: 16,
                          ),
                          decoration: BoxDecoration(
                            border: Border(top: BorderSide(color: Colors.grey[200]!)),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: ElevatedButton.icon(
                                  icon: const Icon(Icons.directions, size: 20),
                                  label: const Text('Directions'),
                                  onPressed: () async {
                                    final startAddress = await _reverseGeocode(_currentPosition);
                                    setState(() {
                                      _destination = place.location;
                                      _selectedPlaceName = place.name;
                                      _selectedPlace = null;
                                      _showDetailsSheet = false;
                                      _showRouteSummary = true;
                                      _startPointController.text = 'Current Location';
                                      _endPointController.text = place.name;
                                      _endPoint = place.location;
                                      _showNavigationButton = true;
                                    });
                                    _getRoute(_currentPosition, place.location);
                                  },
                                  style: ElevatedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                ),  
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: ElevatedButton.icon(
                                  icon: const Icon(Icons.call, size: 20),
                                  label: const Text('Call'),
                                  onPressed: place.phoneNumber != null
                                      ? () => launchUrl(Uri.parse('tel:${place.phoneNumber}'))
                                      : null,
                                  style: ElevatedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),

          if (_showDirectionsSheet)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                height: MediaQuery.of(context).size.height * 0.7,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                ),
                child: Stack(
                  children: [
                    Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.only(top: 40, bottom: 12),
                          child: Center(
                            child: Container(
                              width: 60,
                              height: 4,
                              decoration: BoxDecoration(
                                color: Colors.grey[400],
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ),
                        
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: TextField(
                            controller: _startPointController,
                            focusNode: _startPointFocusNode,
                            decoration: InputDecoration(
                              hintText: "Your location",
                              prefixIcon: const Icon(Icons.my_location),
                              suffixIcon: IconButton(
                                icon: const Icon(Icons.search),
                                onPressed: () async {
                                  _startPointFocusNode.unfocus();
                                  final result = await showSearch(
                                    context: context,
                                    delegate: PlaceSearchDelegate(currentPosition: _currentPosition),
                                  );
                                  if (result != null) {
                                    final place = await _fetchPlaceDetailsById(result['placeId']);
                                    if (mounted) {
                                      setState(() {
                                        _startPointController.text = place['name'];
                                        _startPoint = place['location'];
                                      });
                                    }
                                  }
                                },
                              ),
                            ),
                            onTap: () async {
                              _startPointFocusNode.unfocus();
                              final result = await showSearch(
                                context: context,
                                delegate: PlaceSearchDelegate(currentPosition: _currentPosition),
                              );
                              if (result != null) {
                                final place = await _fetchPlaceDetailsById(result['placeId']);
                                if (mounted) {
                                  setState(() {
                                    _startPointController.text = place['name'];
                                    _startPoint = place['location'];
                                  });
                                }
                              }
                            },
                          ),
                        ),
                        
                        Center(
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.grey[200],
                              shape: BoxShape.circle,
                            ),
                            child: IconButton(
                              icon: const Icon(Icons.swap_vert, size: 24, color: Colors.blue),
                              onPressed: _swapFieldsOnly,
                            ),
                          ),
                        ),
                        
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: TextField(
                            controller: _endPointController,
                            focusNode: _startPointFocusNode,
                            decoration: const InputDecoration(
                              hintText: "Choose destination",
                              prefixIcon: Icon(Icons.place),
                            ),
                            onTap: () async {
                              _startPointFocusNode.unfocus();
                              final result = await showSearch(
                                context: context,
                                delegate: PlaceSearchDelegate(currentPosition: _currentPosition),
                              );
                              if (result != null) {
                                final place = await _fetchPlaceDetailsById(result['placeId']);
                                setState(() {
                                  _endPointController.text = place['name'];
                                  _endPoint = place['location'];
                                  _endDisplayName = place['name'];
                                });
                                _updateDestinationMarker(place['location'], place['name']);
                              }
                            },
                          ),
                        ),
                        
                        const Divider(height: 1),
                        
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text("Saved", style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16)),
                          ),
                        ),
                        
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            children: [
                              Expanded(
                                child: Card(
                                  child: ListTile(
                                    leading: const Icon(Icons.home, size: 24),
                                    title: const Text("Home", style: TextStyle(fontSize: 14)),
                                    subtitle: Text(
                                      _homeAddress.length > 15 
                                          ? "${_homeAddress.substring(0, 15)}..." 
                                          : _homeAddress,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                                    trailing: IconButton(
                                      icon: const Icon(Icons.edit, size: 18, color: Colors.grey),
                                      onPressed: () => _showLocationEditDialog(context, isHome: true),
                                    ),
                                    onTap: () {
                                      if (_homeLocation != null) {
                                        _endPointController.text = "Home";
                                        _endPoint = _homeLocation;
                                      }
                                    },
                                  ),
                                ),
                              ),
                              
                              const SizedBox(width: 8),
                              
                              Expanded(
                                child: Card(
                                  child: ListTile(
                                    leading: const Icon(Icons.work, size: 24),
                                    title: const Text("Work", style: TextStyle(fontSize: 14)),
                                    subtitle: Text(
                                      _workAddress.length > 15 
                                          ? "${_workAddress.substring(0, 15)}..." 
                                          : _workAddress,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                                    trailing: IconButton(
                                      icon: const Icon(Icons.edit, size: 18, color: Colors.grey),
                                      onPressed: () => _showLocationEditDialog(context, isHome: false),
                                    ),
                                    onTap: () {
                                      if (_workLocation != null) {
                                        _endPointController.text = "Work";
                                        _endPoint = _workLocation;
                                      }
                                    },
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text("Recent destinations", style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16)),
                          ),
                        ),
                        
                        Expanded(
                          child: ListView.builder(
                            itemCount: _recentDestinations.length,
                            itemBuilder: (context, index) {
                              final dest = _recentDestinations[index];
                              final uniqueId = '${dest['name']}_${dest['location'].latitude}_${dest['location'].longitude}';
                              return Dismissible(
                                key: Key(dest['name']),
                                background: Container(
                                  color: Colors.red,
                                  alignment: Alignment.centerRight,
                                  child: const Padding(
                                    padding: EdgeInsets.only(right: 20),
                                    child: Icon(Icons.delete, color: Colors.white),
                                  ),
                                ),
                                direction: DismissDirection.endToStart,
                                confirmDismiss: (direction) async {
                                  return await showDialog(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: const Text("Confirm Delete"),
                                      content: Text("Remove ${dest['name']} from recent places?"),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(ctx, false),
                                          child: const Text("Cancel"),
                                        ),
                                        TextButton(
                                          onPressed: () => Navigator.pop(ctx, true),
                                          child: const Text("Delete", style: TextStyle(color: Colors.red)),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                                onDismissed: (direction) {
                                  setState(() {
                                    _recentDestinations.removeAt(index);
                                  });
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text("${dest['name']} removed")),
                                  );
                                },
                                child: Material(
                                  color: _lastTappedRecentDestinationId == uniqueId
                                      ? Colors.grey[300]
                                      : Colors.transparent,
                                  child: ListTile(
                                    leading: const Icon(Icons.history),
                                    title: Text(dest['name']),
                                    subtitle: Text(dest['address']),
                                    onTap: () {
                                      _handleTapFeedback('recentDestination', uniqueId);
                                      final location = dest['location'] as LatLng;
                                      final name = dest['name'] as String;
                                      
                                      setState(() {
                                        _endPointController.text = name;
                                        _endPoint = location;
                                        _endDisplayName = name;
                                      });
                                      
                                      _updateDestinationMarker(location, name);
                                    },
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        
                        Padding(
                          padding: EdgeInsets.only(
                            bottom: _getBottomPadding(context, includeExtra: true),
                            left: 16,
                            right: 16,
                            top: 16,
                          ),
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              minimumSize: const Size(double.infinity, 50),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            onPressed: () async {
                              if (_endPoint != null) {
                                _updateDestinationMarker(_endPoint!, _endPointController.text);
                                _toggleDirectionsSheet();
                                setState(() => _showRouteSummary = true);
                                
                                final start = _startPoint ?? _currentPosition;
                                await _getRoute(start, _endPoint!);
                                
                                if (_routeOptions.isNotEmpty) {
                                  _zoomToFitRoute(_routeOptions[_selectedRouteIndex]);
                                }
                                
                                final address = await _reverseGeocode(_endPoint!);
                                _addToRecentDestinations(
                                  _endPointController.text,
                                  address,
                                  _endPoint!,
                                );
                              }
                            },
                            child: const Text("DIRECTIONS"),
                          ),
                        ),
                      ],
                    ),
                    
                    Positioned(
                      top: 12,
                      right: 12,
                      child: IconButton(
                        icon: const Icon(Icons.close, size: 26, color: Colors.red),
                        onPressed: _toggleDirectionsSheet,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class PlaceSearchDelegate extends SearchDelegate {
  final LatLng currentPosition;
  
  PlaceSearchDelegate({required this.currentPosition});
  
  @override
  List<Widget> buildActions(BuildContext context) {
    return [
      IconButton(
        icon: const Icon(Icons.clear),
        onPressed: () {
          query = '';
        },
      ),
    ];
  }
  
  @override
  Widget buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      onPressed: () {
        close(context, null);
      },
    );
  }
  
  @override
  Widget buildResults(BuildContext context) {
    return Container();
  }
  
  @override
  Widget buildSuggestions(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _fetchPlaceSuggestions(query),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListView.builder(
          itemCount: snapshot.data!.length,
          itemBuilder: (context, index) {
            final place = snapshot.data![index];
            return ListTile(
              title: Text(place['description']),
              onTap: () {
                close(context, place);
              },
            );
          },
        );
      },
    );
  }
  
  Future<List<Map<String, dynamic>>> _fetchPlaceSuggestions(String input) async {
    try {
      final response = await http.post(
        Uri.parse('https://places.googleapis.com/v1/places:autocomplete'),
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': googleApiKey,
          'X-Goog-FieldMask': 'suggestions.placePrediction',
        },
        body: json.encode({
          'input': input,
          'locationBias': {
            'circle': {
              'center': {
                'latitude': currentPosition.latitude,
                'longitude': currentPosition.longitude,
              },
              'radius': 50000.0, 
            },
          },
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return (data['suggestions'] as List).map((suggestion) {
          return {
            'description': suggestion['placePrediction']['text']['text'],
            'placeId': suggestion['placePrediction']['placeId'],
            'geometry': {
              'location': {
                'lat': currentPosition.latitude,
                'lng': currentPosition.longitude,
              }
            }
          };
        }).toList();
      }
      return [];
    } catch (e) {
      debugPrint('Error fetching place suggestions: $e');
      return [];
    }
  }
}
