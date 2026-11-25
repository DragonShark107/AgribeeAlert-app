# Reglas básicas de Flutter
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class plugins.flutter.io.**  { *; }

# Reglas para Firebase (evita que se borren clases necesarias en release)
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**

# Reglas para ignorar advertencias de Play Core
-dontwarn com.google.android.play.core.**