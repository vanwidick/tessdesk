/* Leaving Soon page v4.3.26 (DESIGN BY VAN). Uses ../leave.js (same Leaving Soon logic as TESLA CONTROLS in the main app).
   Settings come from the main TessDesk app's localStorage on this site (td:cfg). If they are missing (for example an iPhone
   Home Screen app keeps its own storage), a short one-time setup asks for the Tessie token (and optional Voice Monkey token);
   it is saved only in this browser (td:leaveCfg) and sent only to api.tessie.com / api-v3.voicemonkey.io. */
(function () {
  'use strict';
  var VERSION = 'v4.3.26', VERSION_DATE = 'Oct 10, 2026', P = 'td:', L = window.TDLeave, root = document.getElementById('lp'), setup = false;
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
  function load(k, d) { try { var v = localStorage.getItem(P + k); return v ? JSON.parse(v) : d; } catch (e) { return d; } }
  function save(k, v) { try { localStorage.setItem(P + k, JSON.stringify(v)); } catch (e) {} }
  function foot() { return '<div class="lp-ft"><div class="dbv"><b>DESIGN BY <span>VAN</span></b></div><a class="ver" href="../changelog.html">Leaving Soon ' + VERSION + ' \u00b7 ' + VERSION_DATE + '</a></div>'; }
  function head() { return '<div class="lp-hd"><div class="brand">Leaving Soon</div><a href="../" id="lpFull">TessDesk \u203a</a></div>'; }
  function render() {
    if (setup || !L.hasSetup()) { renderSetup(); return; }
    root.innerHTML = head() + '<div class="lp-main">' + L.html('page') + '</div>' + foot();
    L.readCar(false);
  }
  function renderSetup() {
    var c = load('leaveCfg', null) || {}, a = c.announce || {};
    root.innerHTML = head() + '<div class="lp-setup"><h2>One-time setup</h2>' +
      '<p>No TessDesk settings found in this browser. If you use the full TessDesk app in this same browser, set it up there and come back. Otherwise enter them here. They stay on this phone only.</p>' +
      '<div class="field"><label for="sTok">Tessie API token</label><input type="password" id="sTok" autocomplete="off" autocapitalize="off" spellcheck="false" value="' + esc(c.token || '') + '" placeholder="Tessie app \u2192 Settings \u2192 API"></div>' +
      '<div class="field"><label for="sVm">Voice Monkey token (optional, for Alexa)</label><input type="password" id="sVm" autocomplete="off" autocapitalize="off" spellcheck="false" value="' + esc(a.token || '') + '" placeholder="app.voicemonkey.io/tokens"></div>' +
      '<div class="field"><label for="sDev">Echo (Voice Monkey speaker id)</label><input type="text" id="sDev" autocomplete="off" autocapitalize="off" spellcheck="false" value="' + esc(a.device || 'echo-living-room-4hqjv') + '"></div>' +
      '<label class="check"><input type="checkbox" id="sCmd"' + (c.consent && c.consent.sendCommands ? ' checked' : '') + '> Let Leaving Soon send commands to my car (climate, windows, lock / unlock). TessDesk is unofficial; commands may wake the car.</label>' +
      '<label class="check"><input type="checkbox" id="sAnn"' + (c.consent && c.consent.announcements ? ' checked' : '') + '> The text of each Leaving Soon announcement is sent to Voice Monkey and Amazon so my Echo can speak it.</label>' +
      '<button class="btn" id="sSave">Save and continue</button><div class="msg" id="sMsg"></div></div>' + foot();
    document.getElementById('sSave').onclick = function () {
      var tok = document.getElementById('sTok').value.trim(), m = document.getElementById('sMsg');
      if (!tok) { m.textContent = 'Paste your Tessie token first.'; return; }
      m.textContent = 'Checking the token\u2026';
      fetch('https://api.tessie.com/vehicles?only_active=true', { headers: { Authorization: 'Bearer ' + tok, Accept: 'application/json' }, cache: 'no-store' })
        .then(function (r) { if (r.status === 401 || r.status === 403) throw new Error('token rejected (' + r.status + ')'); if (!r.ok) throw new Error('Tessie error ' + r.status); return r.json(); })
        .then(function (j) {
          var v = (j.results || [])[0]; if (!v || !v.vin) throw new Error('no vehicle on this Tessie account');
          var vm = document.getElementById('sVm').value.trim();
          save('leaveCfg', { token: tok, vin: v.vin, apiBase: 'https://api.tessie.com', via: 'leaving', savedAt: new Date().toISOString(),
            consent: { version: '4.1', agreed: true, readVehicleData: true, sendCommands: document.getElementById('sCmd').checked, announcements: !!vm && document.getElementById('sAnn').checked, via: 'leaving' },
            announce: { token: vm, device: document.getElementById('sDev').value.trim() || 'echo-living-room-4hqjv' } });
          setup = false; render(); L.readCar(true);
        }).catch(function (e) { m.textContent = '\u2715 ' + String(e.message || e); });
    };
  }
  L.init({ ownRefresh: true });
  render();
  window.TDLeavePage = { version: VERSION, render: render, setup: function () { setup = true; render(); } };
})();
