/* TessDesk service worker: offline app shell. API calls (api.tessie.com) are never cached here. */
var CACHE = 'tessdesk-v4.3.2';
var SHELL = ['./', 'index.html', 'app.js', 'style.css', 'manifest.json', 'changelog.html', 'privacy.html', 'fonts/BebasNeue-Regular.ttf',
  'icons/icon-192.png', 'icons/icon-512.png', 'icons/apple-touch-icon.png', 'icons/favicon-32.png'];
self.addEventListener('install', function (e) {
  e.waitUntil(caches.open(CACHE).then(function (c) { return c.addAll(SHELL); }).then(function () { return self.skipWaiting(); }));
});
self.addEventListener('activate', function (e) {
  e.waitUntil(caches.keys().then(function (keys) {
    return Promise.all(keys.filter(function (k) { return k.indexOf('tessdesk-v') === 0 && k !== CACHE; }).map(function (k) { return caches.delete(k); }));
  }).then(function () { return self.clients.claim(); }));
});
self.addEventListener('fetch', function (e) {
  var req = e.request, url = new URL(req.url);
  if (req.method !== 'GET' || url.origin !== self.location.origin) return;           // let Tessie API go straight to network
  var scope = new URL(self.registration.scope);
  if (url.pathname.indexOf(scope.pathname + 'test/') === 0) return;                  // never touch the TEST build
  // stale-while-revalidate: instant from cache, refresh in the background
  e.respondWith(caches.open(CACHE).then(function (c) {
    return c.match(req, { ignoreSearch: req.mode === 'navigate' }).then(function (hit) {
      var net = fetch(req).then(function (res) { if (res && res.ok) c.put(req, res.clone()); return res; })
        .catch(function () { return hit || (req.mode === 'navigate' ? c.match('index.html') : Response.error()); });
      return hit || net;
    });
  }));
});
