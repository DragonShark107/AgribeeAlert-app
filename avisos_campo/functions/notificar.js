// Lógica compartida para enviar un aviso SOLO a los usuarios afectados.
//
// Por qué: antes se mandaba un mensaje silencioso a todos los móviles y cada
// uno decidía si estaba cerca. En iPhone, Apple retrasa o descarta esos
// mensajes silenciosos (y no los entrega si el usuario cerró la app), así que
// los avisos no llegaban. Ahora el servidor calcula quién está cerca y envía
// una notificación normal y visible, que Android e iOS muestran siempre.
//
// La usan tanto servidor_avisos.js como la Cloud Function (index.js).
// No hace `require` de firebase-admin: recibe `db` y `messaging` ya creados.

const RADIO_PARCELA_POR_DEFECTO_KM = 2.0;
// Si la última ubicación conocida del usuario es más antigua que esto,
// no se usa (puede estar en otro sitio). Las parcelas siempre cuentan.
const MAX_ANTIGUEDAD_UBICACION_MS = 12 * 60 * 60 * 1000;

function distanciaMetros(lat1, lng1, lat2, lng2) {
  const R = 6371000;
  const rad = (g) => (g * Math.PI) / 180;
  const dLat = rad(lat2 - lat1);
  const dLng = rad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

const esNumero = (v) => typeof v === "number" && Number.isFinite(v);

/**
 * Devuelve un Map uid -> motivo ("cerca de tu posición" / "cerca de tu parcela X")
 * con los usuarios afectados por el aviso.
 */
async function calcularDestinatarios(db, aviso) {
  const lat = aviso.latitud;
  const lng = aviso.longitud;
  const radioKm = esNumero(aviso.radioKm) ? aviso.radioKm : 1.0;
  const afectados = new Map();

  // 1. Parcelas / colmenas: radio del aviso + radio de alerta de la parcela.
  const parcelas = await db.collection("mis_parcelas").get();
  parcelas.forEach((doc) => {
    const p = doc.data();
    if (!p.userId || !esNumero(p.latitud) || !esNumero(p.longitud)) return;
    if (afectados.has(p.userId)) return;
    const pRadio = esNumero(p.radioAvisoKm) ? p.radioAvisoKm : RADIO_PARCELA_POR_DEFECTO_KM;
    if (distanciaMetros(p.latitud, p.longitud, lat, lng) <= (radioKm + pRadio) * 1000) {
      afectados.set(p.userId, `cerca de tu parcela "${p.nombre || "sin nombre"}"`);
    }
  });

  // 2. Última ubicación conocida del usuario (la guarda la app al abrirse).
  const ahora = Date.now();
  const usuarios = await db.collection("usuarios").get();
  usuarios.forEach((doc) => {
    if (afectados.has(doc.id)) return;
    const u = doc.data();
    if (!esNumero(u.latitud) || !esNumero(u.longitud)) return;
    const cuando = u.ubicacionActualizada?.toMillis?.() ?? 0;
    if (ahora - cuando > MAX_ANTIGUEDAD_UBICACION_MS) return;
    if (distanciaMetros(u.latitud, u.longitud, lat, lng) <= radioKm * 1000) {
      afectados.set(doc.id, "cerca de tu posición");
    }
  });

  if (aviso.creatorUid) afectados.delete(aviso.creatorUid);
  return afectados;
}

/**
 * Envía el aviso `avisoId` (datos `aviso`) a los usuarios afectados.
 * `FieldValue` es el de firebase-admin/firestore (se pasa para no depender
 * de dónde estén instalados los node_modules).
 * Devuelve { usuarios, enviados, fallidos }.
 */
async function notificarAviso({ db, messaging, FieldValue, avisoId, aviso }) {
  if (!esNumero(aviso.latitud) || !esNumero(aviso.longitud)) {
    return { usuarios: 0, enviados: 0, fallidos: 0 };
  }

  const afectados = await calcularDestinatarios(db, aviso);
  if (afectados.size === 0) return { usuarios: 0, enviados: 0, fallidos: 0 };

  const titulo = "⚡ ALERTA FITOSANITARIA";
  const base = `Tratamiento de ${aviso.tipo || "fitosanitario"} en ${aviso.localidad || "tu zona"}`;

  // Un mensaje por dispositivo (cada usuario puede tener varios móviles).
  const mensajes = [];
  const origen = []; // [uid, token] de cada mensaje, para limpiar tokens caducados
  const usuariosDocs = await Promise.all(
    [...afectados.keys()].map((uid) => db.collection("usuarios").doc(uid).get())
  );
  for (const docUsuario of usuariosDocs) {
    const tokens = docUsuario.exists ? docUsuario.data().fcmTokens || [] : [];
    const motivo = afectados.get(docUsuario.id);
    for (const token of tokens) {
      mensajes.push({
        token,
        notification: { title: titulo, body: `${base}, ${motivo}.` },
        data: {
          avisoId: String(avisoId),
          lat: String(aviso.latitud),
          lng: String(aviso.longitud),
        },
        android: {
          priority: "high",
          // Mismo tag = si llega dos veces, la segunda sustituye a la primera.
          notification: { channelId: "avisos_campo_channel", tag: String(avisoId) },
        },
        apns: {
          headers: { "apns-priority": "10", "apns-collapse-id": String(avisoId).slice(0, 64) },
          payload: { aps: { sound: "default" } },
        },
      });
      origen.push([docUsuario.id, token]);
    }
  }
  if (mensajes.length === 0) return { usuarios: afectados.size, enviados: 0, fallidos: 0 };

  let enviados = 0;
  let fallidos = 0;
  const caducados = [];
  // sendEach admite como máximo 500 mensajes por llamada.
  for (let i = 0; i < mensajes.length; i += 500) {
    const lote = mensajes.slice(i, i + 500);
    const res = await messaging.sendEach(lote);
    res.responses.forEach((r, j) => {
      if (r.success) return enviados++;
      fallidos++;
      const code = r.error?.code || "";
      if (code === "messaging/registration-token-not-registered" || code === "messaging/invalid-registration-token") {
        caducados.push(origen[i + j]);
      }
    });
  }

  // Quitar tokens de móviles que ya no existen (app desinstalada, etc.).
  await Promise.all(
    caducados.map(([uid, token]) =>
      db.collection("usuarios").doc(uid).update({
        fcmTokens: FieldValue.arrayRemove(token),
      }).catch(() => {})
    )
  );

  return { usuarios: afectados.size, enviados, fallidos };
}

module.exports = { notificarAviso, calcularDestinatarios, distanciaMetros };
