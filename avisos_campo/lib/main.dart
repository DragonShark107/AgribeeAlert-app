import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
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

/// Clave de Stadia Maps, leída de claves.json al compilar (ese archivo no se sube a GitHub).
const String kStadiaApiKey = String.fromEnvironment('STADIA_API_KEY');

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

const AndroidNotificationChannel canalNotificaciones = AndroidNotificationChannel(
  'avisos_campo_channel',
  'Avisos de Fumigación',
  description: 'Notificaciones sobre tratamientos fitosanitarios y zonas de alerta',
  importance: Importance.max,
);

final ValueNotifier<LatLng?> ubicacionNotificacionSeleccionada = ValueNotifier<LatLng?>(null);

// Los avisos ahora los filtra el SERVIDOR (functions/notificar.js) y llegan
// como notificación normal y visible solo a quien está cerca. Android e iOS
// la muestran por sí solos con la app en segundo plano o cerrada, así que este
// handler no tiene que hacer nada, pero debe existir para Android.
// (Antes se mandaba un mensaje silencioso a todos y cada móvil decidía; en
// iPhone esos mensajes se retrasan o se pierden.)
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // En web (vista previa en navegador) no hay notificaciones push ni locales:
  // solo se configuran en Android/iOS.
  if (!kIsWeb) await _configurarNotificacionesNativas();

  runApp(const AgribeeAlertApp());

  // Se pide DESPUÉS de dibujar la app: antes se esperaba la respuesta al
  // diálogo de permisos y la pantalla se quedaba en negro hasta contestar.
  _pedirPermisoNotificaciones();
}

Future<void> _pedirPermisoNotificaciones() async {
  try {
    await FirebaseMessaging.instance.requestPermission(alert: true, badge: true, sound: true);
    // El tema común ya no se usa: el servidor envía a cada dispositivo afectado.
    // Se da de baja para que las versiones antiguas del servidor no avisen a todos.
    if (!kIsWeb) await FirebaseMessaging.instance.unsubscribeFromTopic('avisos_generales');
  } catch (e) {
    debugPrint('No se pudo configurar FCM: $e');
  }
}

Future<void> _configurarNotificacionesNativas() async {
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  const AndroidInitializationSettings configuracionAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings configuracionInicial = InitializationSettings(
    android: configuracionAndroid,
    iOS: DarwinInitializationSettings(),
  );

  await flutterLocalNotificationsPlugin.initialize(
    settings: configuracionInicial,
    onDidReceiveNotificationResponse: (NotificationResponse response) {
      _centrarMapaDesdePayload(response.payload);
    },
  );

  // Si la app estaba cerrada y se abrió pulsando una notificación local,
  // onDidReceiveNotificationResponse no se dispara: hay que leerlo aquí.
  try {
    final detallesLanzamiento = await flutterLocalNotificationsPlugin.getNotificationAppLaunchDetails();
    if (detallesLanzamiento?.didNotificationLaunchApp ?? false) {
      _centrarMapaDesdePayload(detallesLanzamiento!.notificationResponse?.payload);
    }
  } catch (_) {}

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(canalNotificaciones);

  // iOS: mostrar el aviso como banner también con la app abierta.
  await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
    alert: true,
    badge: true,
    sound: true,
  );

  // Android: con la app abierta, FCM no muestra la notificación; se muestra en local.
  FirebaseMessaging.onMessage.listen(_mostrarAvisoEnPrimerPlano);

  // Pulsar la notificación push (app en segundo plano o cerrada) centra el mapa en el aviso.
  FirebaseMessaging.onMessageOpenedApp.listen(_centrarMapaDesdeMensaje);
  try {
    final mensajeInicial = await FirebaseMessaging.instance.getInitialMessage();
    if (mensajeInicial != null) _centrarMapaDesdeMensaje(mensajeInicial);
  } catch (_) {}
}

void _mostrarAvisoEnPrimerPlano(RemoteMessage message) {
  // En iOS ya lo muestra el sistema (setForegroundNotificationPresentationOptions).
  if (defaultTargetPlatform != TargetPlatform.android) return;
  final notification = message.notification;
  if (notification == null) return;

  final lat = double.tryParse(message.data['lat'] ?? '');
  final lng = double.tryParse(message.data['lng'] ?? '');
  flutterLocalNotificationsPlugin.show(
    id: (message.data['avisoId'] ?? message.messageId ?? notification.hashCode.toString()).hashCode,
    title: notification.title,
    body: notification.body,
    payload: lat != null && lng != null ? json.encode({'lat': lat, 'lng': lng}) : null,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        canalNotificaciones.id,
        canalNotificaciones.name,
        channelDescription: canalNotificaciones.description,
        icon: '@mipmap/ic_launcher',
        importance: Importance.max,
        priority: Priority.high,
      ),
    ),
  );
}

void _centrarMapaDesdeMensaje(RemoteMessage message) {
  final lat = double.tryParse(message.data['lat'] ?? '');
  final lng = double.tryParse(message.data['lng'] ?? '');
  if (lat != null && lng != null) {
    ubicacionNotificacionSeleccionada.value = LatLng(lat, lng);
  }
}

class AgribeeAlertApp extends StatelessWidget {
  const AgribeeAlertApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
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
          registrarDispositivo(kUserIdActual);
          // La key fuerza un estado nuevo si cambia el usuario (logout + login con otra cuenta).
          return MapaAvisosScreen(key: ValueKey(kUserIdActual));
        }
        return const LoginScreen();
      },
    ),
  );
}

void _centrarMapaDesdePayload(String? payload) {
  if (payload == null || payload.isEmpty) return;
  try {
    final data = json.decode(payload);
    ubicacionNotificacionSeleccionada.value = LatLng(
      (data['lat'] as num).toDouble(),
      (data['lng'] as num).toDouble(),
    );
  } catch (_) {}
}

// ---------------------------------------------------------------------------
// Registro del dispositivo para que el servidor sepa a quién avisar.
// Se guarda en usuarios/{uid}: los tokens FCM de sus móviles y su última
// ubicación conocida. Las parcelas ya están en mis_parcelas.
// ---------------------------------------------------------------------------

StreamSubscription<String>? _suscripcionToken;
String? _uidRegistrado;

DocumentReference<Map<String, dynamic>> _docUsuario(String uid) =>
    FirebaseFirestore.instance.collection('usuarios').doc(uid);

Future<void> registrarDispositivo(String uid) async {
  if (kIsWeb || _uidRegistrado == uid) return;
  _uidRegistrado = uid;

  Future<void> guardarToken(String token) => _docUsuario(uid).set({
        'fcmTokens': FieldValue.arrayUnion([token]),
        'tokenActualizado': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

  _suscripcionToken?.cancel();
  _suscripcionToken = FirebaseMessaging.instance.onTokenRefresh.listen(
    (token) => guardarToken(token).catchError((_) {}),
  );

  try {
    // En iOS, getToken falla si Apple (APNs) todavía no ha entregado su token.
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      for (var i = 0; i < 5; i++) {
        if (await FirebaseMessaging.instance.getAPNSToken() != null) break;
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) {
      await guardarToken(token);
      // Solo el final del token, para compararlo con el del servidor en modo de prueba.
      debugPrint('Dispositivo registrado para avisos: ...${token.substring(token.length - 8)}');
    } else {
      debugPrint('No se pudo registrar el dispositivo para avisos: sin token');
    }
  } catch (e) {
    debugPrint('No se pudo registrar el dispositivo para avisos: $e');
  }
}

/// Quita este móvil de la cuenta al cerrar sesión (si no, seguiría recibiendo
/// los avisos de ese usuario).
Future<void> desregistrarDispositivo() async {
  final uid = _uidRegistrado;
  _uidRegistrado = null;
  await _suscripcionToken?.cancel();
  _suscripcionToken = null;
  if (kIsWeb || uid == null) return;
  try {
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) {
      await _docUsuario(uid).update({'fcmTokens': FieldValue.arrayRemove([token])});
    }
  } catch (_) {}
}

// ---------------------------------------------------------------------------
// Verificación de profesionales (sustituye al antiguo PIN 1234).
//
// - Los vecinos entran directamente, sin verificar nada.
// - Apicultores y aplicadores envían una solicitud con su nº oficial
//   (código REGA o nº ROPO) a solicitudes/{uid}.
// - Un administrador (documento admins/{uid}) la revisa en el "Panel de
//   verificación" de la app y pulsa Aprobar o Rechazar. Al aprobar se crea
//   roles/{uid}. Las reglas de Firestore leen ese rol: solo un aplicador
//   verificado puede crear avisos, aunque alguien modifique la app.
// ---------------------------------------------------------------------------

const Map<String, String> kNombresRol = {
  'vecino': 'Vecino',
  'apicultor': 'Apicultor',
  'aplicador': 'Aplicador',
};

/// Devuelve un mensaje de error, o null si los datos son válidos.
String? validarSolicitudProfesional(String rol, String nombre, String numero) {
  if (rol == 'vecino') return null;
  if (nombre.trim().isEmpty) return 'Escribe tu nombre y apellidos.';
  final n = numero.trim();
  if (n.length < 4 || n.length > 40) {
    return rol == 'apicultor'
        ? 'Escribe el código REGA de tu explotación.'
        : 'Escribe tu nº ROPO o de carné de aplicador.';
  }
  return null;
}

Future<void> enviarSolicitudVerificacion({
  required String rol,
  required String nombre,
  required String numeroOficial,
}) {
  final usuario = FirebaseAuth.instance.currentUser!;
  // set sin merge: al repetir una solicitud rechazada se borra el motivo anterior.
  return FirebaseFirestore.instance.collection('solicitudes').doc(usuario.uid).set({
    'rol': rol,
    'nombre': nombre.trim(),
    'numeroOficial': numeroOficial.trim().toUpperCase(),
    'email': usuario.email ?? '',
    'estado': 'pendiente',
    'fecha': FieldValue.serverTimestamp(),
  });
}

/// Selector de perfil y, para profesionales, los datos que se revisarán.
class CamposSolicitudProfesional extends StatelessWidget {
  const CamposSolicitudProfesional({
    super.key,
    required this.rol,
    required this.alCambiarRol,
    required this.nombreCtrl,
    required this.numeroCtrl,
    this.incluirVecino = true,
  });

  final String rol;
  final ValueChanged<String> alCambiarRol;
  final TextEditingController nombreCtrl;
  final TextEditingController numeroCtrl;
  final bool incluirVecino;

  @override
  Widget build(BuildContext context) {
    InputDecoration deco(String label, [String? ayuda]) => InputDecoration(
          labelText: label,
          helperText: ayuda,
          helperMaxLines: 2,
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.05),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: [
            if (incluirVecino)
              const ButtonSegment(value: 'vecino', label: Text('Vecino'), icon: Icon(Icons.home_outlined)),
            const ButtonSegment(value: 'apicultor', label: Text('Apicultor'), icon: Icon(Icons.hive_outlined)),
            const ButtonSegment(value: 'aplicador', label: Text('Aplicador'), icon: Icon(Icons.agriculture_rounded)),
          ],
          selected: {rol},
          onSelectionChanged: (s) => alCambiarRol(s.first),
        ),
        if (rol != 'vecino') ...[
          const SizedBox(height: 12),
          TextField(controller: nombreCtrl, textCapitalization: TextCapitalization.words, decoration: deco('Nombre y apellidos')),
          const SizedBox(height: 12),
          TextField(
            controller: numeroCtrl,
            textCapitalization: TextCapitalization.characters,
            decoration: rol == 'apicultor'
                ? deco('Código REGA de la explotación', 'Ej.: ES300000000000')
                : deco('Nº ROPO / carné de aplicador', 'Aparece en tu carné de productos fitosanitarios'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Revisaremos tus datos. Hasta que se aprueben usarás la app en modo vecino.',
            style: TextStyle(fontSize: 12, color: Colors.white60),
          ),
        ],
      ],
    );
  }
}

/// Guarda la última ubicación conocida para que el servidor pueda avisar
/// también por cercanía a la posición (no solo a las parcelas).
void guardarUbicacionUsuario(LatLng posicion) {
  if (kIsWeb) return;
  _docUsuario(kUserIdActual).set({
    'latitud': posicion.latitude,
    'longitud': posicion.longitude,
    'ubicacionActualizada': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true)).catchError((_) {});
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

  // Rol verificado por un administrador (documento roles/{uid}).
  // 'vecino' hasta que se apruebe una solicitud. La app no puede cambiarlo.
  String _rolVerificado = 'vecino';
  // Un profesional verificado puede pasar a ver la app como vecino.
  bool _modoProfesional = true;
  bool _esAdmin = false;
  Map<String, dynamic>? _solicitud;
  final List<StreamSubscription> _suscripcionesCuenta = [];

  bool get _modoPro => _modoProfesional && _rolVerificado != 'vecino';
  bool get _puedeEmitir => _modoProfesional && _rolVerificado == 'aplicador';
  int _tipoMapa = 0; // 0: Dark Cyber, 1: Satélite HD, 2: OpenStreetMap
  String _filtroTipo = 'Todos';
  bool _soloActivos = true;

  bool _mostrandoBuscador = false;
  final TextEditingController _searchController = TextEditingController();
  bool _buscando = false;
  Timer? _relojRefresco;
  StreamSubscription<Position>? _suscripcionPosicion;

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

    ubicacionNotificacionSeleccionada.addListener(_onNotificacionPulsada);

    // Refresco periódico para actualizar visualmente los avisos caducados
    _relojRefresco = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });

    _cargarRol();
  }

  Future<void> _cargarRol() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _modoProfesional = prefs.getBool('modo_profesional_$kUserIdActual') ?? true);

    final db = FirebaseFirestore.instance;
    bool primeraLectura = true;
    // Rol verificado: cambia en directo cuando un administrador lo aprueba o retira.
    _suscripcionesCuenta.add(db.collection('roles').doc(kUserIdActual).snapshots().listen((doc) {
      final rol = doc.data()?['rol'];
      final nuevoRol = (rol == 'apicultor' || rol == 'aplicador') ? rol as String : 'vecino';
      if (!mounted) return;
      final antes = _rolVerificado;
      setState(() => _rolVerificado = nuevoRol);
      if (!primeraLectura && antes == 'vecino' && nuevoRol != 'vecino') {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: const Color(0xFF2E7D32),
          content: Text('Cuenta verificada como ${kNombresRol[nuevoRol]}.'),
        ));
      }
      primeraLectura = false;
    }, onError: (_) {}));

    _suscripcionesCuenta.add(db.collection('admins').doc(kUserIdActual).snapshots().listen((doc) {
      if (mounted) setState(() => _esAdmin = doc.exists);
    }, onError: (_) {}));

    _suscripcionesCuenta.add(db.collection('solicitudes').doc(kUserIdActual).snapshots().listen((doc) {
      if (mounted) setState(() => _solicitud = doc.data());
    }, onError: (_) {}));
  }

  Future<void> _cambiarModoProfesional(bool activo) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('modo_profesional_$kUserIdActual', activo);
    if (mounted) setState(() => _modoProfesional = activo);
  }

  void _mostrarDialogoSolicitud() {
    final estado = _solicitud?['estado'];
    if (estado == 'pendiente') {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF131A20),
          title: const Text('Verificación pendiente', style: TextStyle(color: Colors.white)),
          content: Text(
            'Tu solicitud como ${kNombresRol[_solicitud?['rol']] ?? 'profesional'} '
            '(nº ${_solicitud?['numeroOficial'] ?? ''}) está pendiente de revisión. '
            'Mientras tanto puedes usar la app en modo vecino.',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Entendido'))],
        ),
      );
      return;
    }

    final nombreCtrl = TextEditingController(text: _solicitud?['nombre'] as String? ?? '');
    final numeroCtrl = TextEditingController();
    String rol = 'apicultor';
    bool enviando = false;
    final motivo = (_solicitud?['motivo'] ?? '').toString();
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF131A20),
          title: const Text('Verificar cuenta profesional', style: TextStyle(color: Colors.white)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (estado == 'rechazada' || estado == 'retirada')
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      'Tu solicitud anterior fue ${estado == 'rechazada' ? 'rechazada' : 'retirada'}'
                      '${motivo.isNotEmpty ? ': $motivo' : '.'}',
                      style: const TextStyle(color: Colors.orangeAccent, fontSize: 13),
                    ),
                  ),
                CamposSolicitudProfesional(
                  rol: rol,
                  incluirVecino: false,
                  alCambiarRol: (r) => setDialogState(() => rol = r),
                  nombreCtrl: nombreCtrl,
                  numeroCtrl: numeroCtrl,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar', style: TextStyle(color: Colors.white54))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E676)),
              onPressed: enviando
                  ? null
                  : () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final error = validarSolicitudProfesional(rol, nombreCtrl.text, numeroCtrl.text);
                      if (error != null) {
                        messenger.showSnackBar(SnackBar(content: Text(error), backgroundColor: Colors.redAccent));
                        return;
                      }
                      setDialogState(() => enviando = true);
                      try {
                        await enviarSolicitudVerificacion(rol: rol, nombre: nombreCtrl.text, numeroOficial: numeroCtrl.text);
                        if (ctx.mounted) Navigator.pop(ctx);
                        messenger.showSnackBar(const SnackBar(content: Text('Solicitud enviada. Te avisaremos al revisarla.')));
                      } catch (e) {
                        if (ctx.mounted) setDialogState(() => enviando = false);
                        messenger.showSnackBar(SnackBar(content: Text('No se pudo enviar: $e'), backgroundColor: Colors.redAccent));
                      }
                    },
              child: const Text('Enviar solicitud', style: TextStyle(color: Colors.black)),
            ),
          ],
        ),
      ),
    );
  }

  void _onNotificacionPulsada() {
    final destino = ubicacionNotificacionSeleccionada.value;
    if (destino == null) return;
    // Mientras se carga la ubicación el mapa aún no existe y mover el
    // MapController lanzaría una excepción: se aplica al terminar la carga.
    if (_cargandoUbicacion || !mounted) return;
    try {
      _mapController.move(destino, 14.5);
      ubicacionNotificacionSeleccionada.value = null;
    } catch (_) {}
  }

  // Mientras la app está abierta, sigue la posición (cada 500 m de movimiento)
  // para que el mapa y el servidor tengan la ubicación al día.
  void _seguirUbicacion() {
    _suscripcionPosicion?.cancel();
    _suscripcionPosicion = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(distanceFilter: 500),
    ).listen((posicion) {
      final nueva = LatLng(posicion.latitude, posicion.longitude);
      guardarUbicacionUsuario(nueva);
      if (mounted) setState(() => _miUbicacionReal = nueva);
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _suscripcionPosicion?.cancel();
    for (final s in _suscripcionesCuenta) {
      s.cancel();
    }
    _relojRefresco?.cancel();
    ubicacionNotificacionSeleccionada.removeListener(_onNotificacionPulsada);
    _searchController.dispose();
    super.dispose();
  }

  void _terminarCargaUbicacion() {
    if (!mounted) return;
    setState(() => _cargandoUbicacion = false);
    // Si se pulsó una notificación mientras cargaba, centrar ahora que el mapa existe.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onNotificacionPulsada());
  }

  // Antes: si el GPS fallaba o tardaba, la pantalla se quedaba en el spinner
  // para siempre. Ahora hay límite de tiempo y siempre se muestra el mapa.
  Future<void> _obtenerUbicacionActual() async {
    try {
      bool servicioHabilitado = await Geolocator.isLocationServiceEnabled();
      if (!servicioHabilitado) return;

      LocationPermission permiso = await Geolocator.checkPermission();
      if (permiso == LocationPermission.denied) {
        permiso = await Geolocator.requestPermission();
      }
      if (permiso == LocationPermission.denied || permiso == LocationPermission.deniedForever) return;

      Position? posicion;
      try {
        posicion = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(timeLimit: Duration(seconds: 10)),
        );
      } catch (_) {
        posicion = await Geolocator.getLastKnownPosition();
      }
      if (posicion == null || !mounted) return;

      // El mapa todavía no se ha construido: initialCenter usará esta posición,
      // así que no hace falta (ni se puede) llamar a _mapController.move aquí.
      _miUbicacionReal = LatLng(posicion.latitude, posicion.longitude);
      _posicionSeleccionada = _miUbicacionReal!;
      guardarUbicacionUsuario(_miUbicacionReal!);
      _seguirUbicacion();
    } catch (e) {
      debugPrint('Error obteniendo ubicación: $e');
    } finally {
      _terminarCargaUbicacion();
    }
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
      }).timeout(const Duration(seconds: 8));

      if (respuesta.statusCode == 200) {
        final List datos = json.decode(respuesta.body);
        if (!mounted) return;
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
            color: const Color(0xFF10171D).withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(radius),
            border: border ??
                Border.all(
                  color: Colors.white.withValues(alpha: 0.08),
                  width: 1.2,
                ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
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
              border: Border.all(color: const Color(0xFF00E5FF).withValues(alpha: 0.3)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00E5FF).withValues(alpha: 0.12),
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
                                  : Colors.white.withValues(alpha: 0.05),
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
                                  : Colors.white.withValues(alpha: 0.05),
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
                      labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.04),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                  initialValue: tipoParcela,
                  dropdownColor: const Color(0xFF131A20),
                  style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Uso de la tierra',
                      labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.04),
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
                        final nombre = nombreController.text.trim();
                        if (nombre.isEmpty) return;
                        // Se toma el ScaffoldMessenger de la pantalla, no del modal:
                        // el contexto del modal deja de existir tras el pop.
                        final messenger = ScaffoldMessenger.of(this.context);
                        Navigator.pop(modalCtx);

                        // Sin await: sin conexión, Firestore guarda en local al instante
                        // pero el Future no se completa hasta sincronizar con el servidor.
                        final Future<void> escritura = esEdicion
                            ? FirebaseFirestore.instance
                                .collection('mis_parcelas')
                                .doc(idDocExistente)
                                .update({
                                'nombre': nombre,
                                'tipo': tipoParcela,
                                'radioAvisoKm': radioParcela,
                              })
                            : FirebaseFirestore.instance.collection('mis_parcelas').add({
                                'userId': kUserIdActual,
                                'nombre': nombre,
                                'tipo': tipoParcela,
                                'latitud': coordenadasElegidas.latitude,
                                'longitud': coordenadasElegidas.longitude,
                                'radioAvisoKm': radioParcela,
                                'fechaRegistro': FieldValue.serverTimestamp(),
                              });
                        escritura.then((_) {}, onError: (Object e) {
                          messenger.showSnackBar(
                            SnackBar(content: Text('Error guardando la parcela: $e'), backgroundColor: Colors.redAccent),
                          );
                        });

                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(
                              esEdicion
                                  ? 'Parcela actualizada correctamente'
                                  : 'Parcela "$nombre" asegurada',
                            ),
                            backgroundColor: const Color(0xFF00B0FF),
                          ),
                        );
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
          border: Border.all(color: const Color(0xFF00E5FF).withValues(alpha: 0.2)),
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
                style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.5)),
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
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
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
                      final pLat = (p['latitud'] as num?)?.toDouble() ?? 0;
                      final pLng = (p['longitud'] as num?)?.toDouble() ?? 0;
                      final pRadio = (p['radioAvisoKm'] as num?)?.toDouble() ?? 2.5;
                      final punto = LatLng(pLat, pLng);

                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.03),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: const Color(0xFF00E5FF).withValues(alpha: 0.12),
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
                                    style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 12),
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
      // Con timeout: sin cobertura, esta llamada bloqueaba el guardado del aviso.
      final respuesta = await http.get(url, headers: {
        'User-Agent': 'AvisosCampoApp/2026.1',
      }).timeout(const Duration(seconds: 5));

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
              border: Border.all(color: const Color(0xFF00E676).withValues(alpha: 0.3)),
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
                            color: const Color(0xFF00E676).withValues(alpha: 0.12),
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
                          color: Colors.orangeAccent.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.55)),
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
                          color: const Color(0xFF00E676).withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFF00E676).withValues(alpha: 0.25)),
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
                          color: Colors.white.withValues(alpha: 0.04),
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
                          color: Colors.blueAccent.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.55)),
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
                      initialValue: tipoSeleccionado,
                      dropdownColor: const Color(0xFF131A20),
                      decoration: InputDecoration(
                        labelText: 'Compuesto aplicado',
                        labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.04),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'Insecticida', child: Text('🧪 Insecticida', style: TextStyle(color: Colors.white))),
                        DropdownMenuItem(value: 'Fungicida', child: Text('🍄 Fungicida', style: TextStyle(color: Colors.white))),
                        DropdownMenuItem(value: 'Herbicida', child: Text('🌿 Herbicida', style: TextStyle(color: Colors.white))),
                        DropdownMenuItem(value: 'Tratamiento Ecológico', child: Text('🍃 Tratamiento Ecológico', style: TextStyle(color: Colors.white))),
                        DropdownMenuItem(value: 'Acaricida', child: Text('🔬 Acaricida', style: TextStyle(color: Colors.white))),
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
                        labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.04),
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
                        labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.04),
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
                                punto: puntoEmision,
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
    required LatLng punto,
    required String tipo,
    required String cultivo,
    required int duracionHoras,
    required String observaciones,
    double? vientoKmH,
  }) async {
    final DateTime ahora = DateTime.now();
    final DateTime expiraEn = ahora.add(Duration(hours: duracionHoras));
    final double radioKm = _radioKm;

    // 1. Comprobar si hay internet
    bool hayConexion = true;
    try {
      final List<ConnectivityResult> connectivityResult = await (Connectivity().checkConnectivity());
      if (connectivityResult.contains(ConnectivityResult.none)) hayConexion = false;
    } catch (_) {}

    try {
      // Sin conexión no tiene sentido esperar a Nominatim.
      final localidad = hayConexion
          ? await obtenerNombreMunicipio(punto.latitude, punto.longitude)
          : 'Ubicación en campo';

      // 2. Guardar en Firestore. Se usa el punto capturado al abrir el formulario
      // (antes se leía _posicionSeleccionada al guardar, que podía haber cambiado).
      // Sin await: sin conexión el Future no se completa hasta sincronizar, y el
      // usuario se quedaba sin confirmación. Firestore lo guarda en local al instante.
      final escritura = FirebaseFirestore.instance.collection('avisos').add({
        'creatorUid': kUserIdActual,
        'latitud': punto.latitude,
        'longitud': punto.longitude,
        'localidad': localidad,
        'radioKm': radioKm,
        'tipo': tipo,
        'cultivo': cultivo,
        'duracionHoras': duracionHoras,
        'observaciones': observaciones,
        'vientoKmH': vientoKmH,
        'fecha': FieldValue.serverTimestamp(),
        'expiraEn': Timestamp.fromDate(expiraEn),
      });
      if (hayConexion) {
        await escritura;
      } else {
        escritura.ignore();
      }

      // 3. El push lo envía el servidor (servidor_avisos.js o la Cloud Function)
      // al detectar el documento nuevo. Aquí había una llamada a la API antigua
      // de FCM (fcm/send), que Google dio de baja en 2024 y que además exigía
      // meter la clave del servidor dentro de la app.

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
              border: Border.all(color: const Color(0xFF00E5FF).withValues(alpha: 0.25)),
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

                    final lat = (data['latitud'] as num?)?.toDouble();
                    final lng = (data['longitud'] as num?)?.toDouble();
                    if (lat == null || lng == null) return false;
                    if (_miUbicacionReal == null) return true;

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
                          separatorBuilder: (_, _) =>
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
    final radioKm = (data['radioKm'] as num?)?.toDouble() ?? 1.0;
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
                ? Colors.redAccent.withValues(alpha: 0.5)
                : (activo ? const Color(0xFF00E676).withValues(alpha: 0.3) : Colors.white12),
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
                          ? Colors.redAccent.withValues(alpha: 0.2)
                          : (activo ? const Color(0xFF00E676).withValues(alpha: 0.15) : Colors.white10),
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
                  if (_puedeEmitir && data['creatorUid'] == kUserIdActual)
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.white54),
                      onPressed: () async {
                        final confirmar = await _confirmarBorrado(
                          'Eliminar Tratamiento', 
                          '¿Estás seguro de que deseas cancelar este aviso y retirarlo del mapa?'
                        );
                        if (confirmar) {
                          if (context.mounted) Navigator.pop(context);
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
                Text('📝 $observaciones', style: TextStyle(fontStyle: FontStyle.italic, color: Colors.white.withValues(alpha: 0.75))),
              ],
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: enPeligro ? Colors.redAccent.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: enPeligro ? Colors.redAccent.withValues(alpha: 0.4) : Colors.white10,
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
      // La clave de Stadia ya no está en el código (se subiría a GitHub):
      // se pasa al compilar con --dart-define-from-file=claves.json.
      // Sin clave se usa el mapa oscuro de CARTO, que no la necesita.
      tileUrl = kStadiaApiKey.isNotEmpty
          ? 'https://tiles.stadiamaps.com/tiles/alidade_smooth_dark/{z}/{x}/{y}.png?api_key=$kStadiaApiKey'
          : 'https://a.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png';
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
                        if (_puedeEmitir) setState(() => _posicionSeleccionada = point);
                      },
                      onLongPress: (tapPosition, point) => _mostrarDialogoParcela(coordenadas: point),
                    ),
                    children: [
                      if (_tipoMapa == 3)
                        TileLayer(
                          // https: Android bloquea por defecto el tráfico http sin cifrar.
                          wmsOptions: WMSTileLayerOptions(
                            baseUrl: 'https://ovc.catastro.meh.es/Cartografia/WMS/ServidorWMS.aspx?',
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
                                  final pLat = (pData['latitud'] as num?)?.toDouble();
                                  final pLng = (pData['longitud'] as num?)?.toDouble();
                                  if (pLat == null || pLng == null) continue;
                                  final pRadio = (pData['radioAvisoKm'] as num?)?.toDouble() ?? 2.5;
                                  final puntoP = LatLng(pLat, pLng);

                                  circulosGuardados.add(CircleMarker(
                                    point: puntoP,
                                    color: const Color(0xFF00E5FF).withValues(alpha: 0.12),
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
                                          boxShadow: [BoxShadow(color: const Color(0xFF00E5FF).withValues(alpha: 0.6), blurRadius: 10)],
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

                                  // Un solo documento sin coordenadas tumbaba todo el mapa.
                                  final latN = (data['latitud'] as num?)?.toDouble();
                                  final lngN = (data['longitud'] as num?)?.toDouble();
                                  if (latN == null || lngN == null) continue;
                                  final double lat = latN;
                                  final double lng = lngN;
                                  final radioKm = (data['radioKm'] as num?)?.toDouble() ?? 1.0;
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
                                      // Mismo criterio que las notificaciones: radio del aviso + radio
                                      // de la parcela (antes había un 3 km fijo que no cuadraba).
                                      final pRadioKm = (p['radioAvisoKm'] as num?)?.toDouble() ?? 2.0;
                                      if (Geolocator.distanceBetween(pLat, pLng, lat, lng) <= (radioKm + pRadioKm) * 1000) {
                                        afectaMisParcelas = true;
                                        break;
                                      }
                                    }
                                  }

                                  final Color colorPerimetro = afectaMisParcelas ? Colors.redAccent : (activo ? Colors.redAccent : Colors.white30);

                                  circulosGuardados.add(CircleMarker(
                                    point: puntoAviso, color: colorPerimetro.withValues(alpha: activo ? 0.16 : 0.05),
                                    borderColor: colorPerimetro, borderStrokeWidth: activo ? 2.0 : 1.0,
                                    useRadiusInMeter: true, radius: radioKm * 1000,
                                  ));

                                  marcadoresGuardados.add(Marker(
                                    point: puntoAviso, width: 44, height: 44,
                                    child: GestureDetector(
                                      onTap: () => _mostrarDetallesAviso(idDoc: doc.id, data: data, puntoAviso: puntoAviso, activo: activo),
                                      child: Container(
                                        decoration: BoxDecoration(color: colorPerimetro.withValues(alpha: 0.18), shape: BoxShape.circle),
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
                                      if (_puedeEmitir)
                                        CircleMarker(
                                          point: _posicionSeleccionada, color: const Color(0xFF00E676).withValues(alpha: 0.2),
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
                                          child: IgnorePointer(child: Container(decoration: BoxDecoration(color: const Color(0xFF00E5FF), shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3), boxShadow: [BoxShadow(color: const Color(0xFF00E5FF).withValues(alpha: 0.8), blurRadius: 10)]))),
                                        ),
                                      if (_puedeEmitir)
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
                                Container(width: 8, height: 8, decoration: BoxDecoration(color: _modoPro ? const Color(0xFF00E676) : const Color(0xFF00E5FF), shape: BoxShape.circle)),
                                const SizedBox(width: 8),
                                Flexible(child: Text(_modoPro ? kNombresRol[_rolVerificado]!.toUpperCase() : 'VECINO', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.1, color: Colors.white))),
                                // Distintivo de cuenta profesional verificada por el administrador.
                                if (_modoPro) ...[
                                  const SizedBox(width: 4),
                                  const Tooltip(message: 'Cuenta verificada', child: Icon(Icons.verified_rounded, size: 15, color: Color(0xFF00E676))),
                                ],
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(10)),
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
                          icon: Icon(_modoPro ? Icons.person_outline : Icons.agriculture_rounded, size: 22, color: Colors.white),
                          color: const Color(0xFF131A20),
                          tooltip: 'Opciones de Cuenta',
                          offset: const Offset(0, 40),
                          onSelected: (val) async {
                            if (val == 'cambiar_rol') {
                              if (_rolVerificado != 'vecino') {
                                // Profesional verificado: alterna entre su modo y el de vecino.
                                await _cambiarModoProfesional(!_modoProfesional);
                              } else {
                                // Sin verificar: enviar (o consultar) la solicitud.
                                _mostrarDialogoSolicitud();
                              }
                            } else if (val == 'panel_admin') {
                              Navigator.push(context, MaterialPageRoute(builder: (_) => const PanelVerificacionScreen()));
                            } else if (val == 'logout') {
                              // Cerrar Sesión
                              await desregistrarDispositivo();
                              await FirebaseAuth.instance.signOut();
                            }
                          },
                          itemBuilder: (context) => [
                            PopupMenuItem<String>(
                              value: 'cambiar_rol',
                              child: Row(
                                children: [
                                  Icon(_modoPro ? Icons.person_outline : Icons.verified_user_outlined, size: 18, color: Colors.white),
                                  const SizedBox(width: 10),
                                  Text(
                                    _rolVerificado != 'vecino'
                                        ? (_modoProfesional ? 'Cambiar a Vecino' : 'Modo ${kNombresRol[_rolVerificado]}')
                                        : (_solicitud?['estado'] == 'pendiente' ? 'Verificación pendiente' : 'Soy apicultor / aplicador'),
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                ],
                              ),
                            ),
                            if (_esAdmin)
                              const PopupMenuItem<String>(
                                value: 'panel_admin',
                                child: Row(
                                  children: [
                                    Icon(Icons.admin_panel_settings_outlined, size: 18, color: Color(0xFF00E676)),
                                    SizedBox(width: 10),
                                    Text('Panel de verificación', style: TextStyle(color: Colors.white)),
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
                      radius: 14, border: Border.all(color: Colors.redAccent.withValues(alpha: 0.6)), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      child: const Row(
                        children: [
                          Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 22),
                          SizedBox(width: 10),
                          Expanded(child: Text('GEO-ALERTA: Tu posición actual intersecta un radio de tratamiento.', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 12))),
                        ],
                      ),
                    ),
                  ),

                if (_modoPro)
                  Positioned(
                    left: 14, bottom: _puedeEmitir ? 200 : 32,
                    child: InkWell(
                      onTap: _mostrarMenuParcelas, borderRadius: BorderRadius.circular(20),
                      child: _glassContainer(
                        radius: 20, border: Border.all(color: const Color(0xFF00E5FF).withValues(alpha: 0.4)), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.shield_outlined, color: Color(0xFF00E5FF), size: 20), SizedBox(width: 8), Text('Mis Parcelas', style: TextStyle(color: Color(0xFF00E5FF), fontWeight: FontWeight.bold, fontSize: 13))]),
                      ),
                    ),
                  ),

                Positioned(
                  right: 14, bottom: _puedeEmitir ? 210 : 32,
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

                if (_puedeEmitir)
                  Positioned(
                    bottom: 20, left: 14, right: 14,
                    child: SafeArea(
                      top: false,
                      child: _glassContainer(
                        radius: 24, border: Border.all(color: const Color(0xFF00E676).withValues(alpha: 0.4)), padding: const EdgeInsets.all(16),
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
              border: Border.all(color: const Color(0xFF00E676).withValues(alpha: 0.4)),
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
                              child: Text('Cuaderno de Explotación', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
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
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No hay datos para exportar')));
        }
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al generar PDF: $e')));
      }
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

      // Mismo orden que el cuaderno y el PDF (más reciente primero).
      final docs = snapshot.docs.toList()
        ..sort((a, b) {
          final aFecha = (a.data()['fecha'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
          final bFecha = (b.data()['fecha'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
          return bFecha.compareTo(aFecha);
        });

      for (var doc in docs) {
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
      // API actual de share_plus (Share.shareXFiles está obsoleta desde la v11).
      await SharePlus.instance.share(ShareParams(
        files: [XFile(rutaArchivo)],
        text: 'Adjunto registro histórico de tratamientos fitosanitarios.',
      ));

    } catch (e) {
      debugPrint('Error CSV: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al generar Excel: $e')));
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Panel de verificación (solo administradores): aprobar o rechazar a
// apicultores y aplicadores con un botón, sin usar la terminal.
// ---------------------------------------------------------------------------

class PanelVerificacionScreen extends StatelessWidget {
  const PanelVerificacionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final db = FirebaseFirestore.instance;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: const Color(0xFF0B0F14),
        appBar: AppBar(
          backgroundColor: const Color(0xFF131A20),
          foregroundColor: Colors.white,
          title: const Text('Panel de verificación'),
          bottom: const TabBar(
            labelColor: Color(0xFF00E676),
            unselectedLabelColor: Colors.white54,
            indicatorColor: Color(0xFF00E676),
            tabs: [Tab(text: 'Pendientes'), Tab(text: 'Verificados')],
          ),
        ),
        body: TabBarView(
          children: [
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: db.collection('solicitudes').where('estado', isEqualTo: 'pendiente').snapshots(),
              builder: (context, snap) {
                if (snap.hasError) return _mensaje('No se pudieron cargar las solicitudes.\n${snap.error}');
                if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: Color(0xFF00E676)));
                final docs = [...snap.data!.docs]..sort((a, b) {
                    final fa = a.data()['fecha'], fb = b.data()['fecha'];
                    return (fa is Timestamp && fb is Timestamp) ? fa.compareTo(fb) : 0;
                  });
                if (docs.isEmpty) return _mensaje('No hay solicitudes pendientes. 🎉');
                return ListView(padding: const EdgeInsets.all(12), children: docs.map((d) => _TarjetaSolicitud(doc: d)).toList());
              },
            ),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: db.collection('roles').snapshots(),
              builder: (context, snap) {
                if (snap.hasError) return _mensaje('No se pudieron cargar los verificados.\n${snap.error}');
                if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: Color(0xFF00E676)));
                final docs = snap.data!.docs;
                if (docs.isEmpty) return _mensaje('Todavía no hay cuentas verificadas.');
                return ListView(
                  padding: const EdgeInsets.all(12),
                  children: docs.map((d) {
                    final r = d.data();
                    return Card(
                      color: const Color(0xFF131A20),
                      child: ListTile(
                        leading: Icon(r['rol'] == 'apicultor' ? Icons.hive_outlined : Icons.agriculture_rounded, color: const Color(0xFF00E676)),
                        title: Text(r['nombre']?.toString() ?? r['email']?.toString() ?? d.id, style: const TextStyle(color: Colors.white)),
                        subtitle: Text('${kNombresRol[r['rol']] ?? r['rol']} • ${r['numeroOficial'] ?? ''}\n${r['email'] ?? ''}', style: const TextStyle(color: Colors.white60)),
                        isThreeLine: true,
                        trailing: TextButton(
                          onPressed: () => _retirar(context, d.id, r),
                          child: const Text('Retirar', style: TextStyle(color: Colors.redAccent)),
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  static Widget _mensaje(String texto) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(texto, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60)),
        ),
      );

  static Future<void> _retirar(BuildContext context, String uid, Map<String, dynamic> r) async {
    final motivo = await pedirMotivo(context, 'Retirar verificación a ${r['nombre'] ?? r['email'] ?? ''}');
    if (motivo == null || !context.mounted) return;
    final db = FirebaseFirestore.instance;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await db.collection('roles').doc(uid).delete();
      await db.collection('solicitudes').doc(uid).update({
        'estado': 'retirada',
        'motivo': motivo,
        'fechaRevision': FieldValue.serverTimestamp(),
      }).catchError((_) {}); // Puede no existir si se verificó desde la terminal.
      messenger.showSnackBar(const SnackBar(content: Text('Verificación retirada.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.redAccent));
    }
  }
}

/// Pide un motivo (opcional). Devuelve null si se cancela.
Future<String?> pedirMotivo(BuildContext context, String titulo) {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF131A20),
      title: Text(titulo, style: const TextStyle(color: Colors.white, fontSize: 17)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: ctrl,
            maxLength: 300,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(labelText: 'Motivo (lo verá el usuario)', labelStyle: TextStyle(color: Colors.white54)),
          ),
          Wrap(
            spacing: 6,
            children: ['El número no existe', 'Los datos no coinciden', 'Falta el justificante']
                .map((m) => ActionChip(label: Text(m, style: const TextStyle(fontSize: 12)), onPressed: () => ctrl.text = m))
                .toList(),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar', style: TextStyle(color: Colors.white54))),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          child: const Text('Confirmar', style: TextStyle(color: Colors.white)),
        ),
      ],
    ),
  );
}

class _TarjetaSolicitud extends StatefulWidget {
  const _TarjetaSolicitud({required this.doc});
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;

  @override
  State<_TarjetaSolicitud> createState() => _TarjetaSolicitudState();
}

class _TarjetaSolicitudState extends State<_TarjetaSolicitud> {
  bool _trabajando = false;

  Map<String, dynamic> get _s => widget.doc.data();

  Future<void> _aprobar() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _trabajando = true);
    final db = FirebaseFirestore.instance;
    // Las dos escrituras van juntas: o se aprueban las dos o ninguna.
    final lote = db.batch()
      ..set(db.collection('roles').doc(widget.doc.id), {
        'rol': _s['rol'],
        'nombre': _s['nombre'],
        'email': _s['email'],
        'numeroOficial': _s['numeroOficial'],
        'aprobadoPor': FirebaseAuth.instance.currentUser?.uid,
        'fecha': FieldValue.serverTimestamp(),
      })
      ..update(widget.doc.reference, {
        'estado': 'aprobada',
        'motivo': '',
        'fechaRevision': FieldValue.serverTimestamp(),
      });
    try {
      await lote.commit();
      messenger.showSnackBar(SnackBar(content: Text('${_s['nombre']} verificado como ${kNombresRol[_s['rol']]}.')));
    } catch (e) {
      if (mounted) setState(() => _trabajando = false);
      messenger.showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.redAccent));
    }
  }

  Future<void> _rechazar() async {
    final motivo = await pedirMotivo(context, 'Rechazar a ${_s['nombre']}');
    if (motivo == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _trabajando = true);
    try {
      await widget.doc.reference.update({
        'estado': 'rechazada',
        'motivo': motivo,
        'fechaRevision': FieldValue.serverTimestamp(),
      });
      messenger.showSnackBar(const SnackBar(content: Text('Solicitud rechazada.')));
    } catch (e) {
      if (mounted) setState(() => _trabajando = false);
      messenger.showSnackBar(SnackBar(content: Text('Error: $e'), backgroundColor: Colors.redAccent));
    }
  }

  @override
  Widget build(BuildContext context) {
    final esApicultor = _s['rol'] == 'apicultor';
    String dos(int n) => n.toString().padLeft(2, '0');
    final f = _s['fecha'] is Timestamp ? (_s['fecha'] as Timestamp).toDate() : null;
    final fecha = f == null ? '' : '${dos(f.day)}/${dos(f.month)}/${f.year} ${dos(f.hour)}:${dos(f.minute)}';
    final numero = _s['numeroOficial']?.toString() ?? '';
    return Card(
      color: const Color(0xFF131A20),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(esApicultor ? Icons.hive_outlined : Icons.agriculture_rounded, color: const Color(0xFF00E676)),
              const SizedBox(width: 8),
              Expanded(child: Text(_s['nombre']?.toString() ?? '', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16))),
              Text(kNombresRol[_s['rol']] ?? '', style: const TextStyle(color: Color(0xFF00E676), fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 6),
            Text(_s['email']?.toString() ?? '', style: const TextStyle(color: Colors.white70)),
            Row(children: [
              Expanded(child: Text('${esApicultor ? 'REGA' : 'ROPO'}: $numero', style: const TextStyle(color: Colors.white, fontFamily: 'monospace'))),
              IconButton(
                tooltip: 'Copiar número',
                icon: const Icon(Icons.copy_rounded, size: 18, color: Colors.white54),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: numero));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Número copiado'), duration: Duration(seconds: 1)));
                },
              ),
            ]),
            Text(
              esApicultor
                  ? 'Comprueba el código REGA con el justificante de su explotación.'
                  : 'Comprueba el nº ROPO en el buscador del Ministerio de Agricultura (ROPO).',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
            if (fecha.isNotEmpty) Text('Solicitado: $fecha', style: const TextStyle(color: Colors.white38, fontSize: 12)),
            const SizedBox(height: 10),
            _trabajando
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF00E676)))
                : Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent, side: const BorderSide(color: Colors.redAccent)),
                        onPressed: _rechazar,
                        child: const Text('Rechazar'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E676), foregroundColor: Colors.black),
                        onPressed: _aprobar,
                        child: const Text('Aprobar', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ]),
          ],
        ),
      ),
    );
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
  final _nombreCtrl = TextEditingController();
  final _numeroCtrl = TextEditingController();
  bool _cargando = false;
  bool _esRegistro = false;
  String _rol = 'vecino';

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _nombreCtrl.dispose();
    _numeroCtrl.dispose();
    super.dispose();
  }

  Future<void> _autenticar() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_esRegistro) {
      final error = validarSolicitudProfesional(_rol, _nombreCtrl.text, _numeroCtrl.text);
      if (error != null) {
        messenger.showSnackBar(SnackBar(content: Text(error), backgroundColor: Colors.redAccent));
        return;
      }
    }
    setState(() => _cargando = true);
    try {
      if (_esRegistro) {
        await FirebaseAuth.instance.createUserWithEmailAndPassword(
            email: _emailCtrl.text.trim(), password: _passCtrl.text.trim());
        // Los vecinos entran sin más; los profesionales dejan su solicitud.
        if (_rol != 'vecino') {
          try {
            await enviarSolicitudVerificacion(rol: _rol, nombre: _nombreCtrl.text, numeroOficial: _numeroCtrl.text);
            messenger.showSnackBar(const SnackBar(content: Text('Cuenta creada. Tu solicitud de verificación está pendiente.')));
          } catch (_) {
            messenger.showSnackBar(const SnackBar(content: Text('Cuenta creada, pero no se pudo enviar la solicitud. Repítela desde el menú de cuenta.')));
          }
        }
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
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.agriculture_rounded, size: 80, color: Color(0xFF00E676)),
              const SizedBox(height: 24),
              TextField(
                controller: _emailCtrl,
                decoration: InputDecoration(labelText: 'Correo Electrónico', filled: true, fillColor: Colors.white.withValues(alpha: 0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passCtrl, obscureText: true,
                decoration: InputDecoration(labelText: 'Contraseña', filled: true, fillColor: Colors.white.withValues(alpha: 0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
              ),
              if (_esRegistro) ...[
                const SizedBox(height: 20),
                const Align(alignment: Alignment.centerLeft, child: Text('¿Cómo vas a usar la app?', style: TextStyle(fontWeight: FontWeight.bold))),
                const SizedBox(height: 8),
                CamposSolicitudProfesional(
                  rol: _rol,
                  alCambiarRol: (r) => setState(() => _rol = r),
                  nombreCtrl: _nombreCtrl,
                  numeroCtrl: _numeroCtrl,
                ),
              ],
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