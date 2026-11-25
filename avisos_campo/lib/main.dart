import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'firebase_options.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'dart:io';
import 'package:csv/csv.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

late String kUserIdActual;

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

const AndroidNotificationChannel canalNotificaciones = AndroidNotificationChannel(
  'avisos_campo_channel',
  'Avisos de Fumigación',
  description: 'Notificaciones sobre tratamientos fitosanitarios y zonas de alerta',
  importance: Importance.max,
);

final ValueNotifier<LatLng?> ubicacionNotificacionSeleccionada = ValueNotifier<LatLng?>(null);

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  final data = message.data;
  if (data.isEmpty) return;

  // 1. Evitar auto-notificarte si tú creaste el aviso
  final currentUser = FirebaseAuth.instance.currentUser;
  if (currentUser != null && data['creatorUid'] == currentUser.uid) return;

  final double avisoLat = double.tryParse(data['lat']?.toString() ?? '0') ?? 0;
  final double avisoLng = double.tryParse(data['lng']?.toString() ?? '0') ?? 0;
  final double avisoRadioKm = double.tryParse(data['radioKm']?.toString() ?? '1') ?? 1.0;

  bool debeNotificar = false;
  String motivoAviso = '';

  // 2. Comprobar si estás dentro del radio por GPS
  try {
    if (await Geolocator.isLocationServiceEnabled()) {
      Position? pos = await Geolocator.getLastKnownPosition();
      if (pos != null) {
        double dist = Geolocator.distanceBetween(pos.latitude, pos.longitude, avisoLat, avisoLng);
        if (dist <= avisoRadioKm * 1000) {
          debeNotificar = true;
          motivoAviso = 'cerca de tu posición';
        }
      }
    }
  } catch (_) {}

  // 3. Comprobar si intersecta alguna de tus parcelas
  if (!debeNotificar && currentUser != null) {
    try {
      final parcelas = await FirebaseFirestore.instance
          .collection('mis_parcelas')
          .where('userId', isEqualTo: currentUser.uid)
          .get();

      for (var doc in parcelas.docs) {
        final p = doc.data();
        final double pLat = (p['latitud'] as num).toDouble();
        final double pLng = (p['longitud'] as num).toDouble();
        final double pRadioKm = (p['radioAvisoKm'] as num?)?.toDouble() ?? 2.0;

        final dist = Geolocator.distanceBetween(pLat, pLng, avisoLat, avisoLng);
        if (dist <= (avisoRadioKm + pRadioKm) * 1000) {
          debeNotificar = true;
          motivoAviso = 'cerca de tu parcela "${p['nombre']}"';
          break;
        }
      }
    } catch (_) {}
  }

  // 4. Lanzar la notificación local con parámetros nombrados
  if (debeNotificar) {
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );

    await plugin.show(
      id: message.messageId?.hashCode ?? DateTime.now().millisecond,
      title: data['title'] ?? '⚡ ALERTA FITOSANITARIA',
      body: '${data['body'] ?? ''} $motivoAviso',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          canalNotificaciones.id,
          canalNotificaciones.name,
          importance: Importance.max,
          priority: Priority.high,
        ),
      ),
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  const AndroidInitializationSettings configuracionAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings configuracionInicial = InitializationSettings(android: configuracionAndroid);

  await flutterLocalNotificationsPlugin.initialize(
    settings: configuracionInicial,
    onDidReceiveNotificationResponse: (NotificationResponse response) {
      final payload = response.payload;
      if (payload != null && payload.isNotEmpty) {
        try {
          final data = json.decode(payload);
          ubicacionNotificacionSeleccionada.value = LatLng(
            (data['lat'] as num).toDouble(),
            (data['lng'] as num).toDouble(),
          );
        } catch (_) {}
      }
    },
  );

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(canalNotificaciones);

  await FirebaseMessaging.instance.requestPermission(alert: true, badge: true, sound: true);
  await FirebaseMessaging.instance.subscribeToTopic('avisos_generales');

  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Agribee Alert',
    themeMode: ThemeMode.system,
    theme: ThemeData(brightness: Brightness.light, colorScheme: const ColorScheme.light(primary: Color(0xFF2E7D32))),
    darkTheme: ThemeData(brightness: Brightness.dark, scaffoldBackgroundColor: const Color(0xFF0B0F14), colorScheme: const ColorScheme.dark(primary: Color(0xFF00E676))),
    home: StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
        if (snapshot.hasData && snapshot.data != null) {
          kUserIdActual = snapshot.data!.uid;
          iniciarEscuchaAvisos(userIdActual: kUserIdActual);
          return const MapaAvisosScreen();
        }
        return const LoginScreen();
      },
    ),
  ));
}

final Set<String> _avisosProcesados = {};

void iniciarEscuchaAvisos({required String userIdActual}) {
  FirebaseFirestore.instance
      .collection('avisos')
      .snapshots()
      .listen((snapshot) async {
    final parcelasSnapshot = await FirebaseFirestore.instance
        .collection('mis_parcelas')
        .where('userId', isEqualTo: userIdActual)
        .get();

    Position? posicionActual;
    try {
      if (await Geolocator.isLocationServiceEnabled()) {
        posicionActual = await Geolocator.getLastKnownPosition() ??
            await Geolocator.getCurrentPosition(
                timeLimit: const Duration(seconds: 4));
      }
    } catch (_) {}

    for (var change in snapshot.docChanges) {
      if (change.type == DocumentChangeType.added) {
        if (_avisosProcesados.contains(change.doc.id)) continue;
        _avisosProcesados.add(change.doc.id);

        final data = change.doc.data();
        if (data == null) continue;

        if (data['creatorUid'] == userIdActual) continue;

        final fecha = (data['fecha'] as Timestamp?)?.toDate();
        if (fecha != null && DateTime.now().difference(fecha).inMinutes > 2) continue;

        final double avisoLat = (data['latitud'] as num).toDouble();
        final double avisoLng = (data['longitud'] as num).toDouble();
        final double avisoRadioKm = (data['radioKm'] as num?)?.toDouble() ?? 1.0;

        bool debeNotificar = false;
        String motivoAviso = '';

        if (posicionActual != null) {
          double distUsuario = Geolocator.distanceBetween(
            posicionActual.latitude,
            posicionActual.longitude,
            avisoLat,
            avisoLng,
          );
          if (distUsuario <= (avisoRadioKm * 1000)) {
            debeNotificar = true;
            motivoAviso = 'cerca de tu posición actual';
          }
        }

        if (!debeNotificar) {
          for (var doc in parcelasSnapshot.docs) {
            final pData = doc.data();
            final double pLat = (pData['latitud'] as num).toDouble();
            final double pLng = (pData['longitud'] as num).toDouble();
            final double pRadioKm = (pData['radioAvisoKm'] as num?)?.toDouble() ?? 2.0;

            final double distParcela = Geolocator.distanceBetween(pLat, pLng, avisoLat, avisoLng);

            if (distParcela <= ((avisoRadioKm + pRadioKm) * 1000)) {
              debeNotificar = true;
              motivoAviso = 'cerca de tu parcela "${pData['nombre']}"';
              break;
            }
          }
        }

        if (debeNotificar) {
          final String payload = json.encode({
            'lat': avisoLat,
            'lng': avisoLng,
          });

          await flutterLocalNotificationsPlugin.show(
            id: change.doc.id.hashCode,
            title: '⚡ ALERTA FITOSANITARIA',
            body: 'Tratamiento de ${data['cultivo'] ?? 'fitosanitario'} $motivoAviso.',
            payload: payload,
            notificationDetails: NotificationDetails(
              android: AndroidNotificationDetails(
                canalNotificaciones.id,
                canalNotificaciones.name,
                importance: Importance.max,
                priority: Priority.high,
              ),
            ),
          );
        }
      }
    }
  });
}

class MapaAvisosScreen extends StatefulWidget {
  const MapaAvisosScreen({super.key});

  @override
  State<MapaAvisosScreen> createState() => _MapaAvisosScreenState();
}

class _MapaAvisosScreenState extends State<MapaAvisosScreen> {

  final MapController _mapController = MapController();
  LatLng _posicionSeleccionada = const LatLng(38.0, -1.2);
  LatLng? _miUbicacionReal;
  double _radioKm = 4.0;
  bool _cargandoUbicacion = true;

  bool _esModoAgricultor = false;
  int _tipoMapa = 0; // 0: Dark Cyber, 1: Satélite HD, 2: OpenStreetMap
  String _filtroTipo = 'Todos';
  bool _soloActivos = true;

  bool _mostrandoBuscador = false;
  final TextEditingController _searchController = TextEditingController();
  bool _buscando = false;
  Timer? _relojRefresco;

  int _avisosActivosTotal = 0;
  bool _dentroDeZonaRiesgo = false;

  final List<String> _tiposFiltro = [
    'Todos',
    'Insecticida',
    'Fungicida',
    'Herbicida',
    'Tratamiento Ecológico',
    'Acaricida',
  ];

  @override
  void initState() {
    super.initState();

    // Detectar la hora del dispositivo para establecer el estilo de mapa inicial
    final int horaActual = DateTime.now().hour;
    if (horaActual >= 7 && horaActual < 20) {
      _tipoMapa = 2; // De día (7:00 a 19:59): OpenStreetMap (claro)
    } else {
      _tipoMapa = 0; // De noche (20:00 a 6:59): Dark Cyber (oscuro)
    }

    _obtenerUbicacionActual();
    _configurarEscuchaMensajesPush();
    ubicacionNotificacionSeleccionada.addListener(_onNotificacionPulsada);

    // Refresco periódico para actualizar visualmente los avisos caducados
    _relojRefresco = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });

    SharedPreferences.getInstance().then((prefs) {
      if (!prefs.containsKey('es_aplicador')) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _pedirPinInicial());
      } else {
        setState(() {
          _esModoAgricultor = prefs.getBool('es_aplicador') ?? false;
        });
      }
    });
    
  }

  void _pedirPinInicial() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final TextEditingController pinController = TextEditingController();
        return AlertDialog(
          backgroundColor: const Color(0xFF131A20),
          title: const Text('Configuración de Perfil', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Si eres técnico aplicador, introduce tu PIN. Si eres un vecino, continúa directamente.', style: TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 12),
              TextField(
                controller: pinController, keyboardType: TextInputType.number, obscureText: true, style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(labelText: 'Nº Carné / PIN', labelStyle: TextStyle(color: Colors.white54)),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool('es_aplicador', false);
                setState(() => _esModoAgricultor = false);
                Navigator.pop(ctx);
              },
              child: const Text('No soy técnico (Modo Vecino)', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E676)),
              onPressed: () async {
                if (pinController.text == '1234') {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool('es_aplicador', true);
                  setState(() => _esModoAgricultor = true);
                  Navigator.pop(ctx);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN incorrecto'), backgroundColor: Colors.redAccent));
                }
              },
              child: const Text('Acceso Técnico', style: TextStyle(color: Colors.black)),
            ),
          ],
        );
      },
    );
  }

  void _onNotificacionPulsada() {
    final destino = ubicacionNotificacionSeleccionada.value;
    if (destino != null) {
      _mapController.move(destino, 14.5);
      ubicacionNotificacionSeleccionada.value = null;
    }
  }

  void _configurarEscuchaMensajesPush() {
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      RemoteNotification? notification = message.notification;
      AndroidNotification? android = message.notification?.android;

      if (notification != null && android != null) {
        flutterLocalNotificationsPlugin.show(
          id: notification.hashCode,
          title: notification.title,
          body: notification.body,
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              canalNotificaciones.id,
              canalNotificaciones.name,
              channelDescription: canalNotificaciones.description,
              icon: android.smallIcon ?? '@mipmap/ic_launcher',
              importance: Importance.max,
              priority: Priority.high,
            ),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _relojRefresco?.cancel();
    ubicacionNotificacionSeleccionada.removeListener(_onNotificacionPulsada);
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _obtenerUbicacionActual() async {
    bool servicioHabilitado = await Geolocator.isLocationServiceEnabled();
    if (!servicioHabilitado) {
      setState(() => _cargandoUbicacion = false);
      return;
    }

    LocationPermission permiso = await Geolocator.checkPermission();
    if (permiso == LocationPermission.denied) {
      permiso = await Geolocator.requestPermission();
      if (permiso == LocationPermission.denied) {
        setState(() => _cargandoUbicacion = false);
        return;
      }
    }

    if (permiso == LocationPermission.deniedForever) {
      setState(() => _cargandoUbicacion = false);
      return;
    }

    Position posicion = await Geolocator.getCurrentPosition();
    setState(() {
      _miUbicacionReal = LatLng(posicion.latitude, posicion.longitude);
      _posicionSeleccionada = _miUbicacionReal!;
      _cargandoUbicacion = false;
    });
    _mapController.move(_posicionSeleccionada, 12.0);
  }

  void _zoomIn() {
    final zoomActual = _mapController.camera.zoom;
    if (zoomActual < 18.0) {
      _mapController.move(_mapController.camera.center, zoomActual + 1.0);
    }
  }

  void _zoomOut() {
    final zoomActual = _mapController.camera.zoom;
    if (zoomActual > 3.0) {
      _mapController.move(_mapController.camera.center, zoomActual - 1.0);
    }
  }

  Future<void> _buscarLugar(String consulta) async {
    if (consulta.trim().isEmpty) return;
    setState(() => _buscando = true);

    try {
      final url = Uri.parse(
        'https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(consulta)}&format=json&limit=1',
      );
      final respuesta = await http.get(url, headers: {
        'User-Agent': 'AvisosCampoApp/2026.1',
      });

      if (respuesta.statusCode == 200) {
        final List datos = json.decode(respuesta.body);
        if (datos.isNotEmpty) {
          final double lat = double.parse(datos[0]['lat']);
          final double lon = double.parse(datos[0]['lon']);
          final nuevoPunto = LatLng(lat, lon);

          setState(() {
            _posicionSeleccionada = nuevoPunto;
            _mostrandoBuscador = false;
          });
          _mapController.move(nuevoPunto, 13.5);
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('No se encontró la localización.')),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error en búsqueda: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _buscando = false);
    }
  }

  Future<bool> _confirmarBorrado(String titulo, String mensaje) async {
    return await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF131A20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(titulo, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Text(mensaje, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    ) ?? false;
  }

  // Cuadro Glassmorphic reutilizable
  Widget _glassContainer({
    required Widget child,
    EdgeInsetsGeometry? padding,
    double radius = 18,
    Border? border,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: padding ?? const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF10171D).withOpacity(0.72),
            borderRadius: BorderRadius.circular(radius),
            border: border ??
                Border.all(
                  color: Colors.white.withOpacity(0.08),
                  width: 1.2,
                ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.35),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }

  // Formulario para crear o editar parcelas
  // Formulario para crear o editar parcelas
  void _mostrarDialogoParcela({
    required LatLng coordenadas,
    String? idDocExistente,
    String? nombreInicial,
    String? tipoInicial,
    double? radioInicial,
  }) {
    final TextEditingController nombreController =
        TextEditingController(text: nombreInicial ?? '');
    double radioParcela = radioInicial ?? 2.5;
    String tipoParcela = tipoInicial ?? 'Parcela agrícola';
    final esEdicion = idDocExistente != null;
    
    // Variable para guardar la ubicación final decidida
    LatLng coordenadasElegidas = coordenadas;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (modalCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return _glassContainer(
              radius: 28,
              padding: EdgeInsets.only(
                left: 22,
                right: 22,
                top: 22,
                bottom: MediaQuery.of(context).viewInsets.bottom + 22,
              ),
              border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.3)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00E5FF).withOpacity(0.12),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.fence, color: Color(0xFF00E5FF), size: 22),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        esEdicion ? 'Configurar Parcela' : 'Proteger Nueva Zona',
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // BOTONES DE SELECCIÓN DE ORIGEN (Solo visibles al crear una nueva)
                  if (!esEdicion) ...[
                    const Text('Origen de las coordenadas:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: coordenadasElegidas == coordenadas 
                                  ? const Color(0xFF00E5FF) 
                                  : Colors.white.withOpacity(0.05),
                              foregroundColor: coordenadasElegidas == coordenadas 
                                  ? Colors.black : Colors.white70,
                              elevation: 0,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            icon: const Icon(Icons.location_on, size: 18),
                            label: const Text('Marcador'),
                            onPressed: () {
                              setDialogState(() => coordenadasElegidas = coordenadas);
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: coordenadasElegidas == _miUbicacionReal 
                                  ? const Color(0xFF00E676) 
                                  : Colors.white.withOpacity(0.05),
                              foregroundColor: coordenadasElegidas == _miUbicacionReal 
                                  ? Colors.black : Colors.white70,
                              elevation: 0,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            icon: const Icon(Icons.my_location, size: 18),
                            label: const Text('Mi GPS'),
                            onPressed: () {
                              if (_miUbicacionReal != null) {
                                setDialogState(() => coordenadasElegidas = _miUbicacionReal!);
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Ubicación GPS no disponible aún')),
                                );
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                  ],

                  TextField(
                    controller: nombreController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Nombre / Finca (ej. Cítricos Alguazas)',
                      labelStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.04),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                  value: tipoParcela,
                  dropdownColor: const Color(0xFF131A20),
                  style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Uso de la tierra',
                      labelStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.04),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    items: const [
                        DropdownMenuItem(value: 'Parcela agrícola', child: Text('🌱 Parcela Agrícola', style: TextStyle(color: Colors.white))),
                        DropdownMenuItem(value: 'Apiario / Colmenas', child: Text('🐝 Apiario / Colmenas', style: TextStyle(color: Colors.white))),
                        DropdownMenuItem(value: 'Vivienda rural', child: Text('🏡 Vivienda Rural', style: TextStyle(color: Colors.white))),
                        DropdownMenuItem(value: 'Explotación Ganadera', child: Text('🐄 Explotación Ganadera', style: TextStyle(color: Colors.white))),
                    ],
                    onChanged: (val) {
                      if (val != null) setDialogState(() => tipoParcela = val);
                    },
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Radio de Alerta Geoespacial:', style: TextStyle(fontSize: 13, color: Colors.white70)),
                      Text(
                        '${radioParcela.toStringAsFixed(1)} km',
                        style: const TextStyle(
                          color: Color(0xFF00E5FF),
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    value: radioParcela,
                    min: 0.5,
                    max: 15.0,
                    divisions: 29,
                    activeColor: const Color(0xFF00E5FF),
                    inactiveColor: Colors.white12,
                    onChanged: (val) => setDialogState(() => radioParcela = val),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00E5FF),
                        foregroundColor: const Color(0xFF051319),
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: () async {
                        if (nombreController.text.trim().isEmpty) return;
                        Navigator.pop(modalCtx);

                        if (esEdicion) {
                          await FirebaseFirestore.instance
                              .collection('mis_parcelas')
                              .doc(idDocExistente)
                              .update({
                            'nombre': nombreController.text.trim(),
                            'tipo': tipoParcela,
                            'radioAvisoKm': radioParcela,
                          });
                        } else {
                          await FirebaseFirestore.instance.collection('mis_parcelas').add({
                            'userId': kUserIdActual,
                            'nombre': nombreController.text.trim(),
                            'tipo': tipoParcela,
                            'latitud': coordenadasElegidas.latitude, 
                            'longitud': coordenadasElegidas.longitude, 
                            'radioAvisoKm': radioParcela,
                            'fechaRegistro': FieldValue.serverTimestamp(),
                          });
                        }

                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                esEdicion
                                    ? 'Parcela actualizada correctamente'
                                    : 'Parcela "${nombreController.text.trim()}" asegurada',
                              ),
                              backgroundColor: const Color(0xFF00B0FF),
                            ),
                          );
                        }
                      },
                      child: Text(
                        esEdicion ? 'Actualizar Configuración' : 'Confirmar y Proteger',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _mostrarMenuParcelas() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return _glassContainer(
          radius: 28,
          padding: const EdgeInsets.all(22.0),
          border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.2)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Expanded(
                    child: Row(
                      children: [
                        Icon(Icons.shield_outlined, color: Color(0xFF00E5FF), size: 24),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Zonas Protegidas',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00E5FF),
                      foregroundColor: const Color(0xFF06141B),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
                    ),
                    icon: const Icon(Icons.add_location_alt_outlined, size: 16),
                    label: const Text('Añadir', style: TextStyle(fontWeight: FontWeight.bold)),
                    onPressed: () {
                      Navigator.pop(context);
                      _mostrarDialogoParcela(coordenadas: _posicionSeleccionada);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Tus parcelas y colmenas reciben alerta de radio temprano en tiempo real.',
                style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.5)),
              ),
              const Divider(height: 24, color: Colors.white10),
              StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('mis_parcelas')
                    .where('userId', isEqualTo: kUserIdActual)
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: Padding(
                      padding: EdgeInsets.all(20.0),
                      child: CircularProgressIndicator(),
                    ));
                  }
                  if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24.0),
                      child: Center(
                        child: Text(
                          'No hay parcelas registradas. Añade una con el botón superior.',
                          style: TextStyle(color: Colors.white.withOpacity(0.5)),
                        ),
                      ),
                    );
                  }

                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: snapshot.data!.docs.length,
                    itemBuilder: (context, index) {
                      final doc = snapshot.data!.docs[index];
                      final p = doc.data() as Map<String, dynamic>;
                      final pLat = (p['latitud'] as num).toDouble();
                      final pLng = (p['longitud'] as num).toDouble();
                      final pRadio = (p['radioAvisoKm'] as num?)?.toDouble() ?? 2.5;
                      final punto = LatLng(pLat, pLng);

                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.03),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.white.withOpacity(0.05)),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: const Color(0xFF00E5FF).withOpacity(0.12),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(Icons.fence, color: Color(0xFF00E5FF), size: 20),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(p['nombre'] ?? 'Sin nombre', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.white)),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${p['tipo'] ?? 'Parcela'} • Radio: $pRadio km',
                                    style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.center_focus_strong, color: Color(0xFF00E5FF)),
                              tooltip: 'Ver en mapa',
                              onPressed: () {
                                Navigator.pop(context);
                                _mapController.move(punto, 14.0);
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.tune_rounded, color: Colors.white70),
                              tooltip: 'Editar',
                              onPressed: () {
                                Navigator.pop(context);
                                _mostrarDialogoParcela(
                                  coordenadas: punto,
                                  idDocExistente: doc.id,
                                  nombreInicial: p['nombre'],
                                  tipoInicial: p['tipo'],
                                  radioInicial: pRadio,
                                );
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                              tooltip: 'Eliminar',
                              onPressed: () async {
                                final confirmar = await _confirmarBorrado(
                                  'Eliminar Parcela', 
                                  '¿Estás seguro de que deseas dejar de proteger "${p['nombre']}"?'
                                );
                                if (confirmar) {
                                  await FirebaseFirestore.instance.collection('mis_parcelas').doc(doc.id).delete();
                                }
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<Map<String, dynamic>?> _obtenerDatosClima(LatLng punto) async {
    try {
      final url = Uri.parse(
        'https://api.open-meteo.com/v1/forecast?latitude=${punto.latitude}&longitude=${punto.longitude}&current=wind_speed_10m&hourly=precipitation_probability&forecast_hours=6',
      );
      final res = await http.get(url).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final viento = data['current']?['wind_speed_10m'];
        final probs = data['hourly']?['precipitation_probability'] as List<dynamic>?;
        double maxProb = 0;
        if (probs != null) {
          for (var p in probs) {
            if ((p as num) > maxProb) maxProb = p.toDouble();
          }
        }
        return {
          'viento': viento != null ? (viento as num).toDouble() : null, 
          'probLluvia': maxProb
        };
      }
    } catch (_) {}
    return null;
  }

  Future<String> obtenerNombreMunicipio(double lat, double lng) async {
    try {
      final url = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?lat=$lat&lon=$lng&format=json',
      );
      final respuesta = await http.get(url, headers: {
        'User-Agent': 'AvisosCampoApp/2026.1',
      });

      if (respuesta.statusCode == 200) {
        final datos = json.decode(respuesta.body) as Map<String, dynamic>;
        final address = datos['address'] as Map<String, dynamic>?;
        if (address != null) {
          final localidad = address['town'] ??
              address['village'] ??
              address['city'] ??
              address['municipality'] ??
              address['county'] ??
              '';
          final provincia = address['state'] ?? address['province'] ?? '';

          if (localidad.toString().isNotEmpty && provincia.toString().isNotEmpty) {
            return '$localidad, $provincia';
          }
          if (localidad.toString().isNotEmpty) return localidad.toString();
          if (provincia.toString().isNotEmpty) return provincia.toString();
        }
      }
    } catch (_) {}
    return 'Ubicación en campo';
  }

  Future<void> _mostrarFormularioAviso() async {
    final puntoEmision = _posicionSeleccionada;

    if (mounted) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(
          child: CircularProgressIndicator(color: Color(0xFF00E676)),
        ),
      );
    }

    final clima = await _obtenerDatosClima(puntoEmision);

    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    if (!mounted) return;

    final double? vientoKmH = clima?['viento'];
    final double? probLluvia = clima?['probLluvia'];

    final bool vientoExcesivo = vientoKmH != null && vientoKmH > 15.0;
    final bool lluviaAlta = probLluvia != null && probLluvia > 40.0;

    String tipoSeleccionado = 'Insecticida';
    int duracionHoras = 12;
    final TextEditingController cultivoController = TextEditingController();
    final TextEditingController observacionesController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return _glassContainer(
              radius: 28,
              border: Border.all(color: const Color(0xFF00E676).withOpacity(0.3)),
              padding: EdgeInsets.only(
                left: 22,
                right: 22,
                top: 22,
                bottom: MediaQuery.of(context).viewInsets.bottom + 22,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF00E676).withOpacity(0.12),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.sensors, color: Color(0xFF00E676), size: 24),
                        ),
                        const SizedBox(width: 12),
                        const Text(
                          'Emitir Aviso Fitosanitario',
                          style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                      ],
                    ),
                    const Divider(height: 24, color: Colors.white10),

                    if (vientoExcesivo) ...[
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: 14),
                        padding: const EdgeInsets.all(13),
                        decoration: BoxDecoration(
                          color: Colors.orangeAccent.withOpacity(0.14),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.orangeAccent.withOpacity(0.55)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '⚠️ Viento: ${vientoKmH.toStringAsFixed(1)} km/h. Riesgo de deriva. Revisa las condiciones antes de aplicar el tratamiento.',
                                style: const TextStyle(
                                  color: Colors.orangeAccent,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ] else if (vientoKmH != null) ...[
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: 14),
                        padding: const EdgeInsets.all(11),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00E676).withOpacity(0.08),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFF00E676).withOpacity(0.25)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.air_rounded, color: Color(0xFF00E676), size: 20),
                            const SizedBox(width: 10),
                            Text(
                              'Viento actual: ${vientoKmH.toStringAsFixed(1)} km/h',
                              style: const TextStyle(color: Color(0xFF00E676), fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ] else ...[
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: 14),
                        padding: const EdgeInsets.all(11),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.04),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.air_rounded, color: Colors.white54, size: 20),
                            SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Viento actual: datos no disponibles',
                                style: TextStyle(color: Colors.white60),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    if (lluviaAlta) ...[
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: 14),
                        padding: const EdgeInsets.all(13),
                        decoration: BoxDecoration(
                          color: Colors.blueAccent.withOpacity(0.14),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.blueAccent.withOpacity(0.55)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.water_drop_rounded, color: Colors.blueAccent),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '🌧️ Riesgo de lluvia: ${probLluvia.toStringAsFixed(0)}% en las próximas 6h. El tratamiento podría lavarse y perder efectividad.',
                                style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.w600, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    DropdownButtonFormField<String>(
                      value: tipoSeleccionado,
                      dropdownColor: const Color(0xFF131A20),
                      decoration: InputDecoration(
                        labelText: 'Compuesto aplicado',
                        labelStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.04),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'Insecticida', child: Text('🧪 Insecticida', style: const TextStyle(color: Colors.white))),
                        DropdownMenuItem(value: 'Fungicida', child: Text('🍄 Fungicida', style: const TextStyle(color: Colors.white))),
                        DropdownMenuItem(value: 'Herbicida', child: Text('🌿 Herbicida', style: const TextStyle(color: Colors.white))),
                        DropdownMenuItem(value: 'Tratamiento Ecológico', child: Text('🍃 Tratamiento Ecológico', style: const TextStyle(color: Colors.white))),
                        DropdownMenuItem(value: 'Acaricida', child: Text('🔬 Acaricida', style: const TextStyle(color: Colors.white))),
                      ],
                      onChanged: (val) {
                        if (val != null) setModalState(() => tipoSeleccionado = val);
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: cultivoController,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Cultivo / Sector (ej. Cítricos, Olivar, Huerta)',
                        labelStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.04),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Plazo de Seguridad:', style: TextStyle(color: Colors.white70)),
                        Text(
                          '$duracionHoras h',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF00E676),
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: duracionHoras.toDouble(),
                      min: 1,
                      max: 48,
                      divisions: 47,
                      activeColor: const Color(0xFF00E676),
                      inactiveColor: Colors.white12,
                      onChanged: (val) => setModalState(() => duracionHoras = val.toInt()),
                    ),
                    TextField(
                      controller: observacionesController,
                      maxLines: 2,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Observaciones (ej. Atención colmenas, viento en calma)',
                        labelStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.04),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                   // 1. Mensaje de advertencia dinámico (solo aparece si hay viento y es herbicida)
                    if (vientoExcesivo && tipoSeleccionado == 'Herbicida')
                      const Padding(
                        padding: EdgeInsets.only(bottom: 10),
                        child: Text(
                          '⛔ Emisión bloqueada: El viento supera los 15 km/h. La aplicación de herbicidas está prohibida por alto riesgo de deriva.',
                          style: TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ),
                      
                    // 2. El botón de publicar actualizado
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00E676),
                          foregroundColor: const Color(0xFF051C11),
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          // Si está deshabilitado, lo ponemos gris oscuro
                          disabledBackgroundColor: Colors.white10,
                          disabledForegroundColor: Colors.white30,
                        ),
                        icon: const Icon(Icons.broadcast_on_personal_rounded),
                        label: const Text('Publicar Alerta al Entorno', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                        // 3. La condición que bloquea el botón (null significa deshabilitado en Flutter)
                        onPressed: (vientoExcesivo && tipoSeleccionado == 'Herbicida') 
                          ? null 
                          : () async {
                              Navigator.pop(context);
                              await _guardarAvisoEnFirebase(
                                tipo: tipoSeleccionado,
                                cultivo: cultivoController.text.trim().isEmpty
                                    ? 'No especificado'
                                    : cultivoController.text.trim(),
                                duracionHoras: duracionHoras,
                                observaciones: observacionesController.text.trim(),
                                vientoKmH: vientoKmH,
                              );
                            },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _guardarAvisoEnFirebase({
    required String tipo,
    required String cultivo,
    required int duracionHoras,
    required String observaciones,
    double? vientoKmH,
  }) async {
    final DateTime ahora = DateTime.now();
    final DateTime expiraEn = ahora.add(Duration(hours: duracionHoras));

    // 1. Comprobar si hay internet
    bool hayConexion = true;
    try {
      final List<ConnectivityResult> connectivityResult = await (Connectivity().checkConnectivity());
      if (connectivityResult.contains(ConnectivityResult.none)) hayConexion = false;
    } catch (_) {}

    try {
      final localidad = await obtenerNombreMunicipio(
        _posicionSeleccionada.latitude,
        _posicionSeleccionada.longitude,
      );

      // 2. Guardar en Firestore (Esto funciona SIEMPRE, con red o sin red gracias al caché local)
      await FirebaseFirestore.instance.collection('avisos').add({
        'creatorUid': kUserIdActual,
        'latitud': _posicionSeleccionada.latitude,
        'longitud': _posicionSeleccionada.longitude,
        'localidad': localidad,
        'radioKm': _radioKm,
        'tipo': tipo,
        'cultivo': cultivo,
        'duracionHoras': duracionHoras,
        'observaciones': observaciones,
        'vientoKmH': vientoKmH,
        'fecha': FieldValue.serverTimestamp(),
        'expiraEn': Timestamp.fromDate(expiraEn),
      });

      // 3. Mandar la notificación Push SOLO si hay red
      if (hayConexion) {
        try {
          await http.post(
            Uri.parse('https://fcm.googleapis.com/fcm/send'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'key=TU_CLAVE_DEL_SERVIDOR_FIREBASE' // Mantén la tuya
            },
            body: json.encode({
              'to': '/topics/avisos_generales',
              // Solo bloque data
              'data': {
                'title': '⚡ ALERTA FITOSANITARIA',
                'body': 'Nuevo tratamiento de $tipo en $localidad.',
                'lat': _posicionSeleccionada.latitude.toString(),
                'lng': _posicionSeleccionada.longitude.toString(),
                'radioKm': _radioKm.toString(),
                'creatorUid': kUserIdActual,
              },
            }),
          );
        } catch (_) {}
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(hayConexion 
              ? 'Aviso emitido satelitalmente con éxito' 
              : 'Guardado en Modo Offline. Se subirá a la nube automáticamente al recuperar conexión.'),
            backgroundColor: hayConexion ? const Color(0xFF00E676) : Colors.orangeAccent,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error crítico: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  void _mostrarFeedAvisos() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (modalContext) {
        return DraggableScrollableSheet(
          initialChildSize: 0.60,
          minChildSize: 0.40,
          maxChildSize: 0.90,
          expand: false,
          builder: (context, scrollController) {
            return _glassContainer(
              radius: 28,
              padding: const EdgeInsets.all(16),
              border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.25)),
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance.collection('avisos').snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: CircularProgressIndicator(color: Color(0xFF00E676)),
                    );
                  }

                  const double radioMaximoMetros = 50000; // Límite de 50 km
                  final docs = snapshot.data?.docs.where((doc) {
                    final data = doc.data() as Map<String, dynamic>;
                    final Timestamp? expiraEn = data['expiraEn'] as Timestamp?;
                    final bool vigente = expiraEn == null ||
                        expiraEn.toDate().isAfter(DateTime.now());
                    if (!vigente) return false;
                    if (_miUbicacionReal == null) return true;

                    final lat = (data['latitud'] as num?)?.toDouble();
                    final lng = (data['longitud'] as num?)?.toDouble();
                    if (lat == null || lng == null) return false;

                    final distancia = Geolocator.distanceBetween(
                      _miUbicacionReal!.latitude,
                      _miUbicacionReal!.longitude,
                      lat,
                      lng,
                    );
                    return distancia <= radioMaximoMetros;
                  }).toList() ?? [];

                  if (docs.isEmpty) {
                    return const Center(
                      child: Text(
                        'No hay alertas activas en el entorno',
                        style: TextStyle(color: Colors.white70),
                      ),
                    );
                  }

                  if (_miUbicacionReal != null) {
                    docs.sort((a, b) {
                      final aData = a.data() as Map<String, dynamic>;
                      final bData = b.data() as Map<String, dynamic>;
                      final aLat = (aData['latitud'] as num).toDouble();
                      final aLng = (aData['longitud'] as num).toDouble();
                      final bLat = (bData['latitud'] as num).toDouble();
                      final bLng = (bData['longitud'] as num).toDouble();

                      final aDist = Geolocator.distanceBetween(
                        _miUbicacionReal!.latitude,
                        _miUbicacionReal!.longitude,
                        aLat,
                        aLng,
                      );
                      final bDist = Geolocator.distanceBetween(
                        _miUbicacionReal!.latitude,
                        _miUbicacionReal!.longitude,
                        bLat,
                        bLng,
                      );
                      return aDist.compareTo(bDist);
                    });
                  }

                  return Column(
                    children: [
                      Container(
                        width: 42,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                      Row(
                        children: [
                          const Icon(Icons.notifications_active_outlined, color: Color(0xFF00E5FF)),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'Avisos activos cercanos',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                            ),
                          ),
                          Text(
                            '${docs.length}',
                            style: const TextStyle(
                              color: Color(0xFF00E676),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: ListView.separated(
                          controller: scrollController,
                          itemCount: docs.length,
                          separatorBuilder: (_, __) =>
                              const Divider(color: Colors.white10, height: 1),
                          itemBuilder: (context, index) {
                            final doc = docs[index];
                            final data = doc.data() as Map<String, dynamic>;
                            final lat = (data['latitud'] as num).toDouble();
                            final lng = (data['longitud'] as num).toDouble();
                            final punto = LatLng(lat, lng);

                            double? distKm;
                            if (_miUbicacionReal != null) {
                              distKm = Geolocator.distanceBetween(
                                    _miUbicacionReal!.latitude,
                                    _miUbicacionReal!.longitude,
                                    lat,
                                    lng,
                                  ) /
                                  1000;
                            }

                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(vertical: 5),
                              leading: const CircleAvatar(
                                backgroundColor: Colors.redAccent,
                                child: Icon(Icons.warning_amber_rounded, color: Colors.white),
                              ),
                              title: Text('${data['cultivo'] ?? 'Cultivo no especificado'}', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                              subtitle: Text(
                                '${data['tipo'] ?? 'Fumigación'} • ${data['localidad'] ?? 'Ubicación en campo'} • ${distKm != null ? '${distKm.toStringAsFixed(1)} km' : 'Distancia N/D'}',
                                style: const TextStyle(color: Colors.white70),
                              ),
                              trailing: const Icon(Icons.gps_fixed, color: Color(0xFF00E5FF), size: 18),
                              onTap: () {
                                Navigator.pop(modalContext);
                                _mapController.move(punto, 14.0);
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
            );
          },
        );
      },
    );
  }

  void _mostrarDetallesAviso({
    required String idDoc,
    required Map<String, dynamic> data,
    required LatLng puntoAviso,
    required bool activo,
  }) {
    final radioKm = (data['radioKm'] as num).toDouble();
    final tipo = data['tipo'] ?? 'Fumigación';
    final cultivo = data['cultivo'] ?? 'No especificado';
    final duracionHoras = data['duracionHoras'] ?? 24;
    final observaciones = data['observaciones'] ?? '';

    final Timestamp? fechaInicioTimestamp = data['fecha'] as Timestamp?;
    final Timestamp? expiraEnTimestamp = data['expiraEn'] as Timestamp?;

    String horaInicioStr = 'No registrada';
    if (fechaInicioTimestamp != null) {
      final inicio = fechaInicioTimestamp.toDate().toLocal();
      final diff = DateTime.now().difference(inicio);
      if (diff.inMinutes < 60) {
        horaInicioStr = 'Hace ${diff.inMinutes}m';
      } else if (diff.inHours < 24) {
        horaInicioStr = 'Hace ${diff.inHours}h';
      } else {
        horaInicioStr = '${inicio.day}/${inicio.month} ${inicio.hour}:${inicio.minute.toString().padLeft(2, '0')}';
      }
    }

    String tiempoRestanteStr = 'Tratamiento completado';
    if (expiraEnTimestamp != null && activo) {
      final diff = expiraEnTimestamp.toDate().difference(DateTime.now());
      tiempoRestanteStr = '${diff.inHours}h ${diff.inMinutes.remainder(60)}m restantes';
    }

    double? distanciaKm;
    bool enPeligro = false;

    if (_miUbicacionReal != null) {
      double distMetros = Geolocator.distanceBetween(
        _miUbicacionReal!.latitude,
        _miUbicacionReal!.longitude,
        puntoAviso.latitude,
        puntoAviso.longitude,
      );
      distanciaKm = distMetros / 1000.0;
      enPeligro = activo && distMetros <= (radioKm * 1000);
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return _glassContainer(
          radius: 28,
          border: Border.all(
            color: enPeligro
                ? Colors.redAccent.withOpacity(0.5)
                : (activo ? const Color(0xFF00E676).withOpacity(0.3) : Colors.white12),
          ),
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: enPeligro
                          ? Colors.redAccent.withOpacity(0.2)
                          : (activo ? const Color(0xFF00E676).withOpacity(0.15) : Colors.white10),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      enPeligro
                          ? Icons.warning_rounded
                          : (activo ? Icons.sensors : Icons.check_circle_outline),
                      color: enPeligro
                          ? Colors.redAccent
                          : (activo ? const Color(0xFF00E676) : Colors.white54),
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tipo, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                        Text(
                          activo ? 'ACTIVO • $tiempoRestanteStr' : 'FINALIZADO',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: activo ? const Color(0xFF00E676) : Colors.white54,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_esModoAgricultor && data['creatorUid'] == kUserIdActual)
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.white54),
                      onPressed: () async {
                        final confirmar = await _confirmarBorrado(
                          'Eliminar Tratamiento', 
                          '¿Estás seguro de que deseas cancelar este aviso y retirarlo del mapa?'
                        );
                        if (confirmar) {
                          Navigator.pop(context);
                          await FirebaseFirestore.instance.collection('avisos').doc(idDoc).delete();
                        }
                      },
                    ),
                ],
              ),
              const Divider(height: 24, color: Colors.white10),
              Text('🌾 Cultivo / Sector: $cultivo', style: const TextStyle(color: Colors.white)),
              const SizedBox(height: 6),
              Text('⏱️ Emisión: $horaInicioStr • Duración total: $duracionHoras h', style: const TextStyle(color: Colors.white)),
              const SizedBox(height: 6),
              Text('📡 Radio de alcance: ${radioKm.toStringAsFixed(1)} km', style: const TextStyle(color: Colors.white)),
              if (distanciaKm != null) ...[
                const SizedBox(height: 6),
                Text('📍 Distancia a ti: ${distanciaKm.toStringAsFixed(2)} km', style: const TextStyle(color: Colors.white)),
              ],
              if (observaciones.toString().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('📝 $observaciones', style: TextStyle(fontStyle: FontStyle.italic, color: Colors.white.withOpacity(0.75))),
              ],
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: enPeligro ? Colors.redAccent.withOpacity(0.15) : Colors.white.withOpacity(0.04),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: enPeligro ? Colors.redAccent.withOpacity(0.4) : Colors.white10,
                  ),
                ),
                child: Text(
                  enPeligro
                      ? '⚠️ ATENCIÓN: Te encuentras dentro del perímetro de este tratamiento activo.'
                      : (activo ? '✅ Tu ubicación está fuera de este radio.' : 'ℹ️ Este tratamiento ha finalizado su plazo de seguridad.'),
                  style: TextStyle(
                    color: enPeligro ? Colors.redAccent : Colors.white70,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    String tileUrl = '';
    if (_tipoMapa == 0) {
      tileUrl = 'https://tiles.stadiamaps.com/tiles/alidade_smooth_dark/{z}/{x}/{y}.png?api_key=60a076e8-a8da-4805-ad4b-0da89dffd67a';
    } else if (_tipoMapa == 1) {
      tileUrl = 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
    } else if (_tipoMapa == 2) {
      tileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
    }

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: _cargandoUbicacion
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF00E676)))
          : Stack(
              children: [
                // 1. EL MAPA BASE ESTÁTICO (Nunca se repinta con la base de datos)
                RepaintBoundary(
                  child: FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: _posicionSeleccionada,
                      initialZoom: 11.5,
                      onTap: (tapPosition, point) {
                        if (_esModoAgricultor) setState(() => _posicionSeleccionada = point);
                      },
                      onLongPress: (tapPosition, point) => _mostrarDialogoParcela(coordenadas: point),
                    ),
                    children: [
                      if (_tipoMapa == 3)
                        TileLayer(
                          wmsOptions: WMSTileLayerOptions(
                            baseUrl: 'http://ovc.catastro.meh.es/Cartografia/WMS/ServidorWMS.aspx?',
                            layers: const ['Catastro'],
                            transparent: true,
                            format: 'image/png',
                          ),
                          userAgentPackageName: 'com.example.avisos_campo',
                        )
                      else
                        TileLayer(
                          urlTemplate: tileUrl,
                          userAgentPackageName: 'com.example.avisos_campo',
                        ),
                      
                      // Mantener capa de nombres para satélite y añadirla al Catastro
                      if (_tipoMapa == 1 || _tipoMapa == 3)
                        TileLayer(
                          urlTemplate: 'https://services.arcgisonline.com/arcgis/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
                          userAgentPackageName: 'com.example.avisos_campo',
                        ),

                      // 2. CAPA DINÁMICA (El StreamBuilder baja al nivel de los dibujos)
                      StreamBuilder<QuerySnapshot>(
                        stream: FirebaseFirestore.instance.collection('avisos').snapshots(),
                        builder: (context, snapshotAvisos) {
                          return StreamBuilder<QuerySnapshot>(
                            stream: FirebaseFirestore.instance.collection('mis_parcelas').where('userId', isEqualTo: kUserIdActual).snapshots(),
                            builder: (context, snapshotParcelas) {
                              List<CircleMarker> circulosGuardados = [];
                              List<Marker> marcadoresGuardados = [];
                              bool calculoRiesgo = false;
                              int calculoActivos = 0;

                              if (snapshotParcelas.hasData) {
                                for (var doc in snapshotParcelas.data!.docs) {
                                  final pData = doc.data() as Map<String, dynamic>;
                                  final pLat = (pData['latitud'] as num).toDouble();
                                  final pLng = (pData['longitud'] as num).toDouble();
                                  final pRadio = (pData['radioAvisoKm'] as num?)?.toDouble() ?? 2.5;
                                  final puntoP = LatLng(pLat, pLng);

                                  circulosGuardados.add(CircleMarker(
                                    point: puntoP,
                                    color: const Color(0xFF00E5FF).withOpacity(0.12),
                                    borderColor: const Color(0xFF00E5FF),
                                    borderStrokeWidth: 1.5,
                                    useRadiusInMeter: true,
                                    radius: pRadio * 1000,
                                  ));

                                  marcadoresGuardados.add(Marker(
                                    point: puntoP,
                                    width: 38,
                                    height: 38,
                                    child: Tooltip(
                                      message: 'Zona: ${pData['nombre']}',
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF00E5FF),
                                          shape: BoxShape.circle,
                                          boxShadow: [BoxShadow(color: const Color(0xFF00E5FF).withOpacity(0.6), blurRadius: 10)],
                                        ),
                                        child: const Icon(Icons.fence, color: Color(0xFF06141B), size: 20),
                                      ),
                                    ),
                                  ));
                                }
                              }

                              if (snapshotAvisos.hasData) {
                                for (var doc in snapshotAvisos.data!.docs) {
                                  final data = doc.data() as Map<String, dynamic>;
                                  final Timestamp? expiraEn = data['expiraEn'] as Timestamp?;
                                  final bool activo = expiraEn == null || expiraEn.toDate().isAfter(DateTime.now());

                                  if (_soloActivos && !activo) continue;
                                  if (activo) calculoActivos++;

                                  final tipo = data['tipo'] ?? 'Fumigación';
                                  if (_filtroTipo != 'Todos' && tipo != _filtroTipo) continue;

                                  final lat = (data['latitud'] as num).toDouble();
                                  final lng = (data['longitud'] as num).toDouble();
                                  final radioKm = (data['radioKm'] as num).toDouble();
                                  final puntoAviso = LatLng(lat, lng);

                                  if (activo && _miUbicacionReal != null) {
                                    if (Geolocator.distanceBetween(_miUbicacionReal!.latitude, _miUbicacionReal!.longitude, lat, lng) <= radioKm * 1000) calculoRiesgo = true;
                                  }

                                  bool afectaMisParcelas = false;
                                  if (activo && snapshotParcelas.hasData) {
                                    for (final parcelaDoc in snapshotParcelas.data!.docs) {
                                      final p = parcelaDoc.data() as Map<String, dynamic>;
                                      final pLat = (p['latitud'] as num?)?.toDouble();
                                      final pLng = (p['longitud'] as num?)?.toDouble();
                                      if (pLat == null || pLng == null) continue;
                                      if (Geolocator.distanceBetween(pLat, pLng, lat, lng) <= 3000) {
                                        afectaMisParcelas = true;
                                        break;
                                      }
                                    }
                                  }

                                  final Color colorPerimetro = afectaMisParcelas ? Colors.redAccent : (activo ? Colors.redAccent : Colors.white30);

                                  circulosGuardados.add(CircleMarker(
                                    point: puntoAviso, color: colorPerimetro.withOpacity(activo ? 0.16 : 0.05),
                                    borderColor: colorPerimetro, borderStrokeWidth: activo ? 2.0 : 1.0,
                                    useRadiusInMeter: true, radius: radioKm * 1000,
                                  ));

                                  marcadoresGuardados.add(Marker(
                                    point: puntoAviso, width: 44, height: 44,
                                    child: GestureDetector(
                                      onTap: () => _mostrarDetallesAviso(idDoc: doc.id, data: data, puntoAviso: puntoAviso, activo: activo),
                                      child: Container(
                                        decoration: BoxDecoration(color: colorPerimetro.withOpacity(0.18), shape: BoxShape.circle),
                                        child: Icon(activo ? Icons.sensors : Icons.check_circle_outline, color: colorPerimetro, size: 28),
                                      ),
                                    ),
                                  ));
                                }
                              }

                              // Sincronización en segundo plano con el HUD
                              if (calculoActivos != _avisosActivosTotal || calculoRiesgo != _dentroDeZonaRiesgo) {
                                Future.microtask(() {
                                  if (mounted) {
                                    setState(() {
                                      _avisosActivosTotal = calculoActivos;
                                      _dentroDeZonaRiesgo = calculoRiesgo;
                                    });
                                  }
                                });
                              }

                              // Devolvemos solo las capas gráficas sobre el mapa
                              return Stack(
                                children: [
                                  CircleLayer(
                                    circles: [
                                      ...circulosGuardados,
                                      if (_esModoAgricultor)
                                        CircleMarker(
                                          point: _posicionSeleccionada, color: const Color(0xFF00E676).withOpacity(0.2),
                                          borderColor: const Color(0xFF00E676), borderStrokeWidth: 2,
                                          useRadiusInMeter: true, radius: _radioKm * 1000,
                                        ),
                                    ],
                                  ),
                                  MarkerLayer(
                                    markers: [
                                      if (_miUbicacionReal != null)
                                        Marker(
                                          point: _miUbicacionReal!, width: 24, height: 24,
                                          child: IgnorePointer(child: Container(decoration: BoxDecoration(color: const Color(0xFF00E5FF), shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3), boxShadow: [BoxShadow(color: const Color(0xFF00E5FF).withOpacity(0.8), blurRadius: 10)]))),
                                        ),
                                      if (_esModoAgricultor)
                                        Marker(
                                          point: _posicionSeleccionada, width: 44, height: 44,
                                          child: const IgnorePointer(child: Icon(Icons.location_on, color: Color(0xFF00E676), size: 44)),
                                        ),
                                      ...marcadoresGuardados,
                                    ],
                                  ),
                                ],
                              );
                            },
                          );
                        },
                      ),
                    ],
                  ),
                ),

                // 3. EL HUD FLOTANTE (Ahora es independiente y se alimenta de las variables)
                if (_buscando)
                  const Center(child: CircularProgressIndicator(color: Color(0xFF00E676))),

                Positioned(
                  top: 48, left: 14, right: 14,
                  child: _glassContainer(
                    radius: 20, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    child: Row(
                      children: [
                        if (_mostrandoBuscador)
                          Expanded(
                            child: TextField(
                              controller: _searchController, autofocus: true,
                              style: const TextStyle(color: Colors.white),
                              decoration: const InputDecoration(hintText: 'Buscar término, localidad o paraje...', hintStyle: TextStyle(color: Colors.white54, fontSize: 13), border: InputBorder.none),
                              onSubmitted: _buscarLugar,
                            ),
                          )
                        else
                          Expanded(
                            child: Row(
                              children: [
                                Container(width: 8, height: 8, decoration: BoxDecoration(color: _esModoAgricultor ? const Color(0xFF00E676) : const Color(0xFF00E5FF), shape: BoxShape.circle)),
                                const SizedBox(width: 8),
                                Flexible(child: Text(_esModoAgricultor ? 'APLICADOR' : 'VECINO', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.1, color: Colors.white))),
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(color: Colors.white.withOpacity(0.08), borderRadius: BorderRadius.circular(10)),
                                  child: Text('$_avisosActivosTotal', style: const TextStyle(fontSize: 11, color: Color(0xFF00E676), fontWeight: FontWeight.bold)), // <-- AQUI USA LA NUEVA VARIABLE
                                ),
                              ],
                            ),
                          ),
                        IconButton(
                          icon: Icon(_mostrandoBuscador ? Icons.close : Icons.search_rounded, size: 22, color: Colors.white),
                          onPressed: () {
                            setState(() {
                              _mostrandoBuscador = !_mostrandoBuscador;
                              if (!_mostrandoBuscador) _searchController.clear();
                            });
                          },
                        ),
                        PopupMenuButton<String>(
                          icon: Icon(_esModoAgricultor ? Icons.person_outline : Icons.agriculture_rounded, size: 22, color: Colors.white),
                          color: const Color(0xFF131A20),
                          tooltip: 'Opciones de Cuenta',
                          offset: const Offset(0, 40),
                          onSelected: (val) async {
                            if (val == 'cambiar_rol') {
                              if (_esModoAgricultor) {
                                // De Aplicador a Vecino (sin contraseña)
                                final prefs = await SharedPreferences.getInstance();
                                await prefs.setBool('es_aplicador', false);
                                setState(() => _esModoAgricultor = false);
                              } else {
                                // De Vecino a Aplicador (Pide PIN)
                                showDialog(
                                  context: context,
                                  builder: (ctx) {
                                    final TextEditingController pinController = TextEditingController();
                                    return AlertDialog(
                                      backgroundColor: const Color(0xFF131A20),
                                      title: const Text('Acceso Técnico', style: TextStyle(color: Colors.white)),
                                      content: TextField(
                                        controller: pinController, keyboardType: TextInputType.number, obscureText: true, style: const TextStyle(color: Colors.white),
                                        decoration: const InputDecoration(labelText: 'Nº Carné / PIN', labelStyle: TextStyle(color: Colors.white54)),
                                      ),
                                      actions: [
                                        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar', style: TextStyle(color: Colors.white54))),
                                        ElevatedButton(
                                          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E676)),
                                          onPressed: () async {
                                            if (pinController.text == '1234') {
                                              final prefs = await SharedPreferences.getInstance();
                                              await prefs.setBool('es_aplicador', true);
                                              setState(() => _esModoAgricultor = true);
                                              Navigator.pop(ctx);
                                            } else {
                                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN incorrecto'), backgroundColor: Colors.redAccent));
                                            }
                                          },
                                          child: const Text('Verificar', style: TextStyle(color: Colors.black)),
                                        ),
                                      ],
                                    );
                                  },
                                );
                              }
                            } else if (val == 'logout') {
                              // Cerrar Sesión
                              final prefs = await SharedPreferences.getInstance();
                              await prefs.remove('es_aplicador');
                              await FirebaseAuth.instance.signOut();
                            }
                          },
                          itemBuilder: (context) => [
                            PopupMenuItem<String>(
                              value: 'cambiar_rol',
                              child: Row(
                                children: [
                                  Icon(_esModoAgricultor ? Icons.person_outline : Icons.agriculture_rounded, size: 18, color: Colors.white),
                                  const SizedBox(width: 10),
                                  Text(_esModoAgricultor ? 'Cambiar a Vecino' : 'Acceso Técnico', style: const TextStyle(color: Colors.white)),
                                ],
                              ),
                            ),
                            const PopupMenuItem<String>(
                              value: 'logout',
                              child: Row(
                                children: [
                                  Icon(Icons.logout_rounded, size: 18, color: Colors.redAccent),
                                  SizedBox(width: 10),
                                  Text('Cerrar Sesión', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                                ],
                              ),
                            ),
                          ],
                        ),
                        PopupMenuButton<String>(
                        icon: const Icon(Icons.filter_list_rounded, size: 22, color: Colors.white),
                        color: const Color(0xFF131A20),
                        onSelected: (val) => setState(() => _filtroTipo = val),
                        itemBuilder: (context) => _tiposFiltro.map((t) {
                            return PopupMenuItem<String>(
                              value: t,
                              child: Row(
                                children: [
                                  Icon(_filtroTipo == t ? Icons.check_circle : Icons.circle_outlined, size: 16, color: const Color(0xFF00E676)),
                                  const SizedBox(width: 8),
                                 Text(t, style: const TextStyle(fontSize: 13, color: Colors.white)),
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),
                ),

                if (_dentroDeZonaRiesgo) // <-- AQUI USA LA NUEVA VARIABLE
                  Positioned(
                    top: 115, left: 14, right: 14,
                    child: _glassContainer(
                      radius: 14, border: Border.all(color: Colors.redAccent.withOpacity(0.6)), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      child: const Row(
                        children: [
                          Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 22),
                          SizedBox(width: 10),
                          Expanded(child: Text('GEO-ALERTA: Tu posición actual intersecta un radio de tratamiento.', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 12))),
                        ],
                      ),
                    ),
                  ),

                if (_esModoAgricultor)
                  Positioned(
                    left: 14, bottom: 200,
                    child: InkWell(
                      onTap: _mostrarMenuParcelas, borderRadius: BorderRadius.circular(20),
                      child: _glassContainer(
                        radius: 20, border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.4)), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.shield_outlined, color: Color(0xFF00E5FF), size: 20), SizedBox(width: 8), Text('Mis Parcelas', style: TextStyle(color: Color(0xFF00E5FF), fontWeight: FontWeight.bold, fontSize: 13))]),
                      ),
                    ),
                  ),

                Positioned(
                  right: 14, bottom: _esModoAgricultor ? 210 : 32,
                  child: Column(
                    children: [
                     _glassContainer(
  radius: 14,
  padding: EdgeInsets.zero,
  child: Semantics(
    label: 'Acercar mapa',
    button: true,
    child: IconButton(
      icon: const Icon(Icons.add_rounded, color: Colors.white),
      onPressed: _zoomIn,
    ),
  ),
),
const SizedBox(height: 6),
_glassContainer(
  radius: 14,
  padding: EdgeInsets.zero,
  child: Semantics(
    label: 'Alejar mapa',
    button: true,
    child: IconButton(
      icon: const Icon(Icons.remove_rounded, color: Colors.white),
      onPressed: _zoomOut,
    ),
  ),
),
                      const SizedBox(height: 10),
                      _glassContainer(radius: 14, padding: EdgeInsets.zero, child: IconButton(tooltip: 'Alternar estilo de mapa', icon: Icon(_tipoMapa == 0 ? Icons.dark_mode_outlined : (_tipoMapa == 1 ? Icons.satellite_alt_rounded : (_tipoMapa == 2 ? Icons.map_outlined : Icons.grid_on_rounded)), color: Colors.white), onPressed: () { setState(() => _tipoMapa = (_tipoMapa + 1) % 4); })),
                      const SizedBox(height: 6),
                      _glassContainer(
                        radius: 14, padding: EdgeInsets.zero,
                        child: IconButton(
                          tooltip: _soloActivos ? 'Ver todos los avisos' : 'Ver solo activos',
                          icon: Icon(_soloActivos ? Icons.visibility_rounded : Icons.history_rounded, color: _soloActivos ? const Color(0xFF00E676) : Colors.white54),
                          onPressed: () {
                            setState(() => _soloActivos = !_soloActivos);
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(duration: const Duration(seconds: 1), content: Text(_soloActivos ? 'Filtrando: Solo alertas activas' : 'Filtrando: Mostrando histórico completo')));
                          },
                        ),
                      ),
                      const SizedBox(height: 6),
                      _glassContainer(radius: 14, padding: EdgeInsets.zero, child: IconButton(tooltip: 'Avisos cercanos', icon: const Icon(Icons.notifications_active_outlined, color: Color(0xFF00E5FF)), onPressed: _mostrarFeedAvisos)),
                      const SizedBox(height: 6),
                      _glassContainer(radius: 14, padding: EdgeInsets.zero, child: IconButton(tooltip: 'Mi Cuaderno de Explotación', icon: const Icon(Icons.menu_book_rounded, color: Color(0xFF00E676)), onPressed: _mostrarHistorialYCuaderno)),
                      if (_miUbicacionReal != null) ...[
                        const SizedBox(height: 6),
                        _glassContainer(radius: 14, padding: EdgeInsets.zero, child: IconButton(icon: const Icon(Icons.my_location_rounded, color: Color(0xFF00E5FF)), onPressed: () => _mapController.move(_miUbicacionReal!, 13.0))),
                      ],
                    ],
                  ),
                ),

                if (_esModoAgricultor)
                  Positioned(
                    bottom: 20, left: 14, right: 14,
                    child: SafeArea(
                      top: false,
                      child: _glassContainer(
                        radius: 24, border: Border.all(color: const Color(0xFF00E676).withOpacity(0.4)), padding: const EdgeInsets.all(16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [const Text('Perímetro de Tratamiento:', style: TextStyle(fontSize: 13, color: Colors.white70)), Text('${_radioKm.toStringAsFixed(1)} km', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF00E676)))],
                            ),
                            Slider(value: _radioKm, min: 0.5, max: 30.0, divisions: 59, activeColor: const Color(0xFF00E676), inactiveColor: Colors.white12, onChanged: (val) => setState(() => _radioKm = val)),
                            SizedBox(
                              width: double.infinity, height: 48,
                              child: ElevatedButton.icon(
                                onPressed: _mostrarFormularioAviso, 
                                icon: const Icon(Icons.broadcast_on_home_rounded, size: 20), 
                                label: const Text('Emitir Tratamiento', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E676), foregroundColor: Colors.white, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
          ),
    );
  }
  void _mostrarHistorialYCuaderno() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (modalContext) {
        return DraggableScrollableSheet(
          initialChildSize: 0.70, maxChildSize: 0.90, minChildSize: 0.50,
          builder: (context, scrollController) {
            return _glassContainer(
              radius: 28, padding: const EdgeInsets.all(16),
              border: Border.all(color: const Color(0xFF00E676).withOpacity(0.4)),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Expanded(
                        child: Row(
                          children: [
                            Icon(Icons.menu_book_rounded, color: Color(0xFF00E676)),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text('Cuaderno de Explotación', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                                overflow: TextOverflow.ellipsis, // Añade puntos suspensivos si no cabe
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00E676), 
                              foregroundColor: Colors.black,
                              minimumSize: const Size(140, 36),
                            ),
                            icon: const Icon(Icons.picture_as_pdf_rounded, size: 18),
                            label: const Text('Generar PDF'),
                            onPressed: () => _exportarPDFPrivado(),
                          ),
                          const SizedBox(height: 8),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00E5FF), 
                              foregroundColor: Colors.black,
                              minimumSize: const Size(140, 36),
                            ),
                            icon: const Icon(Icons.table_chart_rounded, size: 18),
                            label: const Text('Exportar Excel'),
                            onPressed: () => _exportarCSV(), // Aquí llamamos a tu nueva función
                          ),
                        ],
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white10, height: 24),
                  Expanded(
                    child: StreamBuilder<QuerySnapshot>(
                      stream: FirebaseFirestore.instance.collection('avisos')
                          .where('creatorUid', isEqualTo: kUserIdActual)
                          .snapshots(), // Eliminado el orderBy de Firebase
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
                        
                        if (snapshot.hasError) {
                          return Center(child: Text('Error: ${snapshot.error}', style: const TextStyle(color: Colors.redAccent)));
                        }

                        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                          return const Center(child: Text('Aún no has registrado ningún tratamiento.', style: TextStyle(color: Colors.white70)));
                        }

                        // Ordenación local en Dart (más reciente primero)
                        final docs = snapshot.data!.docs.toList();
                        docs.sort((a, b) {
                          final aData = a.data() as Map<String, dynamic>;
                          final bData = b.data() as Map<String, dynamic>;
                          final aFecha = (aData['fecha'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
                          final bFecha = (bData['fecha'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
                          return bFecha.compareTo(aFecha);
                        });

                        return ListView.builder(
                          controller: scrollController,
                          itemCount: docs.length,
                          itemBuilder: (context, index) {
                            final doc = docs[index];
                            final data = doc.data() as Map<String, dynamic>;
                            final fecha = (data['fecha'] as Timestamp?)?.toDate();
                            final fechaStr = fecha != null ? '${fecha.day}/${fecha.month}/${fecha.year}' : 'Fecha N/D';
                            return ListTile(
                              leading: const Icon(Icons.grass_rounded, color: Colors.white54),
                              title: Text('${data['tipo']} en ${data['cultivo']}', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                              subtitle: Text('$fechaStr • ${data['localidad'] ?? 'Ubicación en campo'}', style: const TextStyle(color: Colors.white70)),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                                onPressed: () async {
                                  if (await _confirmarBorrado('Eliminar Registro', '¿Seguro que quieres borrar este tratamiento histórico de tu cuaderno?')) {
                                    await FirebaseFirestore.instance.collection('avisos').doc(doc.id).delete();
                                  }
                                },
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _exportarPDFPrivado() async {
    try {
      final snapshot = await FirebaseFirestore.instance.collection('avisos')
          .where('creatorUid', isEqualTo: kUserIdActual).get(); // Eliminado el orderBy

      if (snapshot.docs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No hay datos para exportar')));
        return;
      }

      // Ordenación local en Dart
      final docs = snapshot.docs.toList();
      docs.sort((a, b) {
        final aData = a.data();
        final bData = b.data();
        final aFecha = (aData['fecha'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bFecha = (bData['fecha'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bFecha.compareTo(aFecha);
      });

      final pdf = pw.Document();
      pdf.addPage(
        pw.Page(
          build: (pw.Context context) {
            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('Cuaderno de Explotación Agrícola', style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold)),
                pw.SizedBox(height: 5),
                pw.Text('Documento privado de registro de tratamientos fitosanitarios.', style: const pw.TextStyle(fontSize: 12)),
                pw.SizedBox(height: 20),
                pw.TableHelper.fromTextArray(
                  context: context,
                  cellAlignment: pw.Alignment.centerLeft,
                  headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
                  data: <List<String>>[
                    <String>['Fecha', 'Cultivo', 'Tratamiento', 'Localidad'],
                    // Usar la lista 'docs' ya ordenada en lugar de 'snapshot.docs'
                    ...docs.map((doc) {
                      final d = doc.data();
                      final fecha = (d['fecha'] as Timestamp?)?.toDate();
                      final fStr = fecha != null ? '${fecha.day}/${fecha.month}/${fecha.year}' : '';
                      return [fStr, d['cultivo']?.toString() ?? '', d['tipo']?.toString() ?? '', d['localidad']?.toString() ?? ''];
                    })
                  ],
                ),
              ],
            );
          },
        ),
      );

      await Printing.layoutPdf(
        onLayout: (PdfPageFormat format) async => pdf.save(),
        name: 'Cuaderno_Explotacion.pdf',
      );
    } catch (e) {
      debugPrint('Error generando PDF: $e');
    }
  }

  Future<void> _exportarCSV() async {
    try {
      final snapshot = await FirebaseFirestore.instance.collection('avisos')
          .where('creatorUid', isEqualTo: kUserIdActual).get();

      if (snapshot.docs.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No hay datos para exportar')));
        }
        return;
      }

      List<List<dynamic>> filas = [
        ['Fecha', 'Cultivo', 'Tratamiento', 'Localidad', 'Viento (km/h)', 'Observaciones']
      ];

      for (var doc in snapshot.docs) {
        final d = doc.data();
        final fecha = (d['fecha'] as Timestamp?)?.toDate();
        filas.add([
          fecha != null ? '${fecha.day}/${fecha.month}/${fecha.year}' : 'N/D',
          d['cultivo'] ?? '',
          d['tipo'] ?? '',
          d['localidad'] ?? '',
          d['vientoKmH'] ?? 'N/D',
          d['observaciones'] ?? ''
        ]);
      }

      // 1. Generar la estructura de datos CSV
      String csvData = const ListToCsvConverter().convert(filas);

      // 2. Obtener la ruta temporal oculta del dispositivo
      final directorio = await getTemporaryDirectory();
      final rutaArchivo = '${directorio.path}/Cuaderno_Explotacion.csv';
      final archivo = File(rutaArchivo);

      // 3. Escribir los datos físicamente en el archivo
      await archivo.writeAsString(csvData);

      // 4. Desplegar el menú nativo de Android/iOS para compartir el documento
      await Share.shareXFiles([XFile(rutaArchivo)], text: 'Adjunto registro histórico de tratamientos fitosanitarios.');

    } catch (e) {
      debugPrint('Error CSV: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al generar Excel: $e')));
      }
    }
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _cargando = false;
  bool _esRegistro = false;

  Future<void> _autenticar() async {
    setState(() => _cargando = true);
    try {
      if (_esRegistro) {
        await FirebaseAuth.instance.createUserWithEmailAndPassword(
            email: _emailCtrl.text.trim(), password: _passCtrl.text.trim());
      } else {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
            email: _emailCtrl.text.trim(), password: _passCtrl.text.trim());
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: ${e.message}'), backgroundColor: Colors.redAccent));
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.agriculture_rounded, size: 80, color: Color(0xFF00E676)),
              const SizedBox(height: 24),
              TextField(
                controller: _emailCtrl,
                decoration: InputDecoration(labelText: 'Correo Electrónico', filled: true, fillColor: Colors.white.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passCtrl, obscureText: true,
                decoration: InputDecoration(labelText: 'Contraseña', filled: true, fillColor: Colors.white.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
              ),
              const SizedBox(height: 24),
              _cargando
                  ? const CircularProgressIndicator(color: Color(0xFF00E676))
                  : ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E676), foregroundColor: Colors.black, minimumSize: const Size(double.infinity, 50)),
                      onPressed: _autenticar,
                      child: Text(_esRegistro ? 'Registrarse' : 'Iniciar Sesión', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    ),
              TextButton(
                onPressed: () => setState(() => _esRegistro = !_esRegistro),
                child: Text(_esRegistro ? 'Ya tengo cuenta. Iniciar Sesión' : 'No tengo cuenta. Registrarse', style: const TextStyle(color: Color(0xFF00E5FF))),
              ),
            ],
          ),
        ),
      ),
    );
  }
}