const { initializeApp, cert } = require("firebase-admin/app");
const { getFirestore } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const serviceAccount = require("./serviceAccountKey.json");

initializeApp({ credential: cert(serviceAccount) });
const db = getFirestore();
const messaging = getMessaging();

console.log("🟢 Servidor activo (Modo filtro geoespacial estricto)...");

db.collection("avisos").onSnapshot((snapshot) => {
  snapshot.docChanges().forEach(async (change) => {
    if (change.type === "added") {
      const data = change.doc.data();
      const fechaDoc = data.fecha ? data.fecha.toDate() : new Date();
      if ((Date.now() - fechaDoc.getTime()) / 1000 > 60) return;

      const message = {
        topic: "avisos_generales",
        // ❌ Eliminado el bloque 'notification' para que FCM no la muestre a la fuerza
        // ✅ Enviamos solo 'data' para que el filtro de distancia en Flutter decida
        data: {
          title: "⚡ ALERTA FITOSANITARIA",
          body: `Nuevo tratamiento de ${data.tipo || "Fitosanitario"} en ${data.localidad || "tu zona"}.`,
          lat: String(data.latitud || 0),
          lng: String(data.longitud || 0),
          radioKm: String(data.radioKm || 1.0),
          creatorUid: String(data.creatorUid || "")
        },
        android: { priority: "high" }
      };

      try {
        await messaging.send(message);
        console.log("📲 Datos enviados silenciosamente para evaluación local.");
      } catch (error) {
        console.error("❌ Error al enviar:", error);
      }
    }
  });
});