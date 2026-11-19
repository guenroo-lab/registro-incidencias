// Service worker del Registro de dispositivos.
// Solo guarda la propia web (para abrirla sin cobertura) y las tipografías. NUNCA toca las llamadas al servidor
// (POST a la función de borde): esas van siempre a la red, y la propia web decide qué hacer si no hay cobertura.
// Para forzar que todos recarguen la web, cambia VERSION.
var VERSION = 'rd-v1';
var SHELL = 'rd-shell-' + VERSION;
var FUENTES = 'rd-fuentes-' + VERSION;
var ARCHIVOS = ['./', 'manifest.webmanifest', 'icono-192.png', 'icono-512.png', 'icono-180.png'];

self.addEventListener('install', function (ev) {
  ev.waitUntil(caches.open(SHELL).then(function (c) {
    return Promise.all(ARCHIVOS.map(function (a) { return c.add(a).catch(function () {}); }));
  }).then(function () { return self.skipWaiting(); }));
});

self.addEventListener('activate', function (ev) {
  ev.waitUntil(caches.keys().then(function (claves) {
    return Promise.all(claves.filter(function (k) { return k !== SHELL && k !== FUENTES; }).map(function (k) { return caches.delete(k); }));
  }).then(function () { return self.clients.claim(); }));
});

function conTiempo(promesa, ms) {
  return new Promise(function (ok, mal) {
    var t = setTimeout(function () { mal(new Error('tiempo')); }, ms);
    promesa.then(function (r) { clearTimeout(t); ok(r); }, function (e) { clearTimeout(t); mal(e); });
  });
}

self.addEventListener('fetch', function (ev) {
  var req = ev.request;
  if (req.method !== 'GET') return;                       // las acciones (POST) no pasan por aquí
  var url = new URL(req.url);

  // tipografías de Google: se sirven de la copia y se renuevan en segundo plano
  if (url.hostname === 'fonts.googleapis.com' || url.hostname === 'fonts.gstatic.com') {
    ev.respondWith(caches.open(FUENTES).then(function (c) {
      return c.match(req).then(function (hit) {
        var red = fetch(req).then(function (r) { if (r && (r.ok || r.type === 'opaque')) c.put(req, r.clone()); return r; }).catch(function () { return hit; });
        return hit || red;
      });
    }));
    return;
  }

  if (url.origin !== self.location.origin) return;

  // la web y sus archivos: primero la red (así llegan las novedades) y, si no hay cobertura, la copia guardada
  ev.respondWith(conTiempo(fetch(req), req.mode === 'navigate' ? 4000 : 6000).then(function (r) {
    if (r && r.ok) {
      // sin la parte «?k=…»: la clave de acceso no debe quedar escrita en el nombre de lo guardado
      var llave = req.mode === 'navigate' ? new Request(url.origin + url.pathname) : req;
      var copia = r.clone(); caches.open(SHELL).then(function (c) { c.put(llave, copia); });
    }
    return r;
  }).catch(function () {
    return caches.open(SHELL).then(function (c) {
      return c.match(req, { ignoreSearch: true }).then(function (hit) {
        return hit || (req.mode === 'navigate' ? c.match('./', { ignoreSearch: true }) : undefined) || Response.error();
      });
    });
  }));
});
