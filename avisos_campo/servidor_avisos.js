// Servidor local de avisos (alternativa a la Cloud Function de functions/index.js).
// Usa solo UNA de las dos opciones: si están las dos en marcha, cada aviso llega dos veces.
const { initializeApp, cert } = require("firebase-admin/app");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { notificarAviso, notificarSolicitud } = require("./functions/notificar");
const serviceAccount = require("./serviceAccountKey.json");

initializeApp({ credential: cert(serviceAccount) });
const db = getFirestore();
const messaging = getMessaging();

// `node servidor_avisos.js --prueba`: avisa también a quien publica el aviso.
// Los demás usuarios afectados lo siguen recibiendo igual.
const modoPrueba = process.argv.includes("--prueba");

console.log("🟢 Servidor activo (filtrado por distancia en el servidor)...");
if (modoPrueba) console.log("🧪 MODO DE PRUEBA: quien publica un aviso también recibe la notificación.");

db.collection("avisos").onSnapshot((snapshot) => {
  snapshot.docChanges().forEach(async (change) => {
    if (change.type !== "added") return;

    const data = change.doc.data();
    const fechaDoc = data.fecha ? data.fecha.toDate() : new Date();
    // Al arrancar, onSnapshot devuelve todos los avisos antiguos: solo se envían los recientes.
    if ((Date.now() - fechaDoc.getTime()) / 1000 > 60) return;

    // En modo de prueba se espera un poco para dar tiempo a salir de la app y ver
    // la notificación push del sistema (con la app abierta la muestra la propia app).
    if (modoPrueba) {
      console.log("⏳ Sal a la pantalla de inicio del móvil: envío en 15 segundos...");
      await new Promise((resolve) => setTimeout(resolve, 15000));
    }

    try {
      const r = await notificarAviso({ db, messaging, FieldValue, avisoId: change.doc.id, aviso: data, incluirCreador: modoPrueba });
      console.log(`📲 Aviso ${change.doc.id}: ${r.usuarios} usuarios afectados, ${r.enviados} enviados, ${r.fallidos} fallidos.`);
      if (modoPrueba && r.destinos) console.log(`🔎 Enviado a los móviles: ${r.destinos.join(", ")}`);
    } catch (error) {
      console.error("❌ Error al enviar:", error);
    }
  });
});

// Solicitudes de verificación: avisa al administrador de las nuevas y al usuario
// cuando se aprueba, rechaza o retira la suya. Se recuerda el estado anterior de
// cada solicitud para notificar solo los cambios (no las ya existentes al arrancar).
const estadoSolicitudes = new Map();
let primeraCarga = true;

db.collection("solicitudes").onSnapshot((snapshot) => {
  snapshot.docChanges().forEach(async (change) => {
    const uid = change.doc.id;
    const despues = change.type === "removed" ? undefined : change.doc.data();
    const antes = estadoSolicitudes.get(uid);
    if (despues) estadoSolicitudes.set(uid, despues);
    else estadoSolicitudes.delete(uid);
    if (primeraCarga) return;

    try {
      const r = await notificarSolicitud({ db, messaging, FieldValue, uid, antes, despues });
      if (r) console.log(`🐝 Solicitud de ${despues?.email} -> ${despues?.estado}: ${r.enviados} notificaciones enviadas.`);
    } catch (error) {
      console.error("❌ Error notificando solicitud:", error);
    }
  });
  primeraCarga = false;
});
