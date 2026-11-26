import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Sin esto, flutter_local_notifications no muestra las alertas en iOS
    // mientras la app está abierta (y no se recibe el toque en la notificación).
    UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
    // Registro en APNs para que Firebase Messaging obtenga el token del dispositivo.
    application.registerForRemoteNotifications()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
