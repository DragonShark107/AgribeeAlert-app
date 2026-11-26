// Servidor local de avisos (alternativa a la Cloud Function de functions/index.js).
// Usa solo UNA de las dos opciones: si están las dos en marcha, cada aviso llega dos veces.
const { initializeApp, cert } = require("firebase-admin/app");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { notificarAviso } = require("./functions/notificar");
const serviceAccount = require("./serviceAccountKey.json");

initializeApp({ credential: cert(serviceAccount) });
const db = getFirestore();
const messaging = getMessaging();

console.log("🟢 Servidor activo (filtrado por distancia en el servidor)...");

db.collection("avisos").onSnapshot((snapshot) => {
  snapshot.docChanges().forEach(async (change) => {
    if (change.type !== "added") return;

    const data = change.doc.data();
    const fechaDoc = data.fecha ? data.fecha.toDate() : new Date();
    // Al arrancar, onSnapshot devuelve todos los avisos antiguos: solo se envían los recientes.
    if ((Date.now() - fechaDoc.getTime()) / 1000 > 60) return;

    try {
      const r = await notificarAviso({ db, messaging, FieldValue, avisoId: change.doc.id, aviso: data });
      console.log(`📲 Aviso ${change.doc.id}: ${r.usuarios} usuarios afectados, ${r.enviados} enviados, ${r.fallidos} fallidos.`);
    } catch (error) {
      console.error("❌ Error al enviar:", error);
    }
  });
});
