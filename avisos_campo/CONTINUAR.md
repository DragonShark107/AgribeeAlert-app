# Por dónde me he quedado (27 de noviembre de 2026)

## Contexto para una conversación nueva

- **Proyecto:** Agribee Alert (`avisos_campo`), Flutter + Firebase (proyecto `avisos-campo`). Debe funcionar en Android e iOS.
- **Carpeta de trabajo en el PC:** `Escritorio\AgribeeAlert-app\avisos_campo` (clon de GitHub). La antigua `Escritorio\avisos_campo` ya no se usa.
- **Cómo trabajar conmigo:** háblame en español. El emulador y `flutter run` los lanzo yo.
- **Nunca subir a GitHub:** `claves.json` ni `serviceAccountKey.json`.
- **Entorno del PC:** Flutter en `C:\Users\Usuario\flutter` (fuera del PATH para el asistente), Android Studio en `D:\Android\Android Studio`, SDK en `D:\Android\Sdk`, `JAVA_HOME` ya configurado.
- **Archivos principales:** `lib/main.dart` (app), `functions/notificar.js` (a quién se avisa), `servidor_avisos.js` (servidor local), `firestore.rules` (permisos, ya publicadas), `admin_verificaciones.js` (nombrar administradores).
- **Pruebas:** `flutter test` y `flutter analyze` (la última vez, solo 2 avisos informativos de obsolescencia).
- **Inicio de sesión:** el error `blocked` en el PC dejó de salir; la huella SHA-1 va en Google Cloud (Credenciales) y en Firebase.
- **Modo de prueba:** `node servidor_avisos.js --prueba` notifica también a quien publica el aviso, para probar con un solo dispositivo.

## Hecho

- Arreglos generales, configuración de iOS y Android, reglas de Firestore y notificaciones filtradas por distancia en el servidor.
- Verificación de apicultores y aplicadores con aprobación desde la app (sustituye al PIN).
- Mi cuenta ya es administradora y está aprobada como aplicador.
- La clave de Stadia está fuera del código (`claves.json`).

## Pendiente

1. ~~Probar las notificaciones push.~~ Probadas el 27/11 en el emulador Android con `--prueba` (espera 15 s para salir de la app).
   - Si el servidor dice `enviados` pero no llega nada, reiniciar la app y comparar la terminación del móvil (`Dispositivo registrado para avisos`) con la del servidor.
   - Falta probar con dos dispositivos y cuentas distintas (sin `--prueba`).
2. Regenerar la clave de Stadia: la antigua sigue en el historial de GitHub.
3. iOS: sin probar. Hace falta un Mac (o un servicio como Codemagic) y cuenta de desarrollador de Apple.

## Preparar el portátil (solo la primera vez)

1. Instalar Git, Flutter (en el PC uso la 3.50.1), Android Studio y Node.js.
2. Descargar el proyecto y abrir en VS Code la carpeta `avisos_campo` de dentro:

   ```
   git clone https://github.com/DragonShark107/AgribeeAlert-app.git
   ```

3. Pasar del PC **por USB** (nunca por GitHub) `claves.json` y `serviceAccountKey.json` a la carpeta `avisos_campo`.
4. En la carpeta `avisos_campo`:

   ```
   flutter pub get
   npm install
   ```

5. Si sale `JAVA_HOME is not set`: crear la variable de entorno `JAVA_HOME` apuntando a la carpeta `jbr` de Android Studio y reiniciar VS Code.
6. Si al iniciar sesión sale `Requests from this Android client application ... are blocked`: añadir la huella SHA-1 **del portátil** a la clave de Android en Google Cloud (Credenciales) y en Firebase. Cada ordenador tiene la suya. Para verla, dentro de `android`:

   ```
   .\gradlew signingReport
   ```

## Cada día

Dos terminales en la carpeta `avisos_campo`:

```
node servidor_avisos.js
```

```
flutter run --dart-define-from-file=claves.json
```

El servidor solo debe estar abierto en **un ordenador a la vez**, o las notificaciones llegarán repetidas.

## Cambiar de ordenador

Antes de empezar:

```
git pull
```

Al terminar:

```
git add -A
git commit -m "Lo que he hecho"
git push
```

En el PC de sobremesa, la carpeta antigua `Escritorio\avisos_campo` **no sirve para hacer pull ni push** (su historial es distinto). Hay que clonar el repositorio también allí y trabajar en el clon.
