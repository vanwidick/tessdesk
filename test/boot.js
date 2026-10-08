/* TessDesk TEST launcher.
   Every launch (once per app session): unregister the TEST service worker, delete TEST caches,
   optionally wipe TEST data, then reload from the network, so it behaves like a fresh install of the newest build. */
(function () {
  'use strict';
  var P = 'tdtest:', FLAG = 'tdtest:fresh';
  var here = new URL('./', location.href).href;           // .../test/
  function loadApp() {
    var v = Date.now();                                   // bypass HTTP cache for code
    var css = document.createElement('link'); css.rel = 'stylesheet'; css.href = '../style.css?v=' + v; document.head.appendChild(css);
    document.body.className = 'tessie idle';   // v4.1: Tessie look is always on
    document.getElementById('app').innerHTML = '';
    var lv = document.createElement('script'); lv.src = '../leave.js?v=' + v;   // v4.3.16: Leaving Soon module first
    lv.onload = lv.onerror = function () { var s = document.createElement('script'); s.src = '../app.js?v=' + v; document.body.appendChild(s); };
    document.body.appendChild(lv);
    // A pass-through SW keeps the TEST app installable; it never caches anything.
    if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js?v=' + v, { scope: './' }).catch(function () {});
  }
  function freshStart() {
    var reset = true;
    try { var r = localStorage.getItem(P + 'resetOnLaunch'); if (r !== null) reset = JSON.parse(r) !== false; } catch (e) {}
    if (reset) Object.keys(localStorage).forEach(function (k) { if (k.indexOf(P) === 0 && k !== P + 'resetOnLaunch') localStorage.removeItem(k); });
    var jobs = [];
    if ('serviceWorker' in navigator) jobs.push(navigator.serviceWorker.getRegistrations().then(function (regs) {
      return Promise.all(regs.filter(function (g) { return g.scope.indexOf(here) === 0; }).map(function (g) { return g.unregister(); }));
    }));
    if (window.caches) jobs.push(caches.keys().then(function (keys) {
      return Promise.all(keys.filter(function (k) { return k.indexOf('tessdesk-test') === 0; }).map(function (k) { return caches.delete(k); }));
    }));
    // refresh the HTTP cache for the page itself
    jobs.push(fetch(location.href.split('#')[0], { cache: 'reload' }).catch(function () {}));
    jobs.push(fetch('boot.js', { cache: 'reload' }).catch(function () {}));
    Promise.all(jobs).catch(function () {}).then(function () {
      sessionStorage.setItem(FLAG, String(Date.now()));
      location.reload();
    });
  }
  var go = function () {
    if (!sessionStorage.getItem(FLAG)) freshStart(); else loadApp();
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', go); else go();
})();
