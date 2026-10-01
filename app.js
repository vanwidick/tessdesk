/* TessDesk mobile v4.0 (PWA). Design by Van.
   Everything (name, Tessie token, vehicle, rates) is stored in localStorage on this device only. */
(function () {
  'use strict';
  var CFG = window.TD_CONFIG || {};
  var VARIANT = CFG.variant || 'main';
  var P = CFG.storagePrefix || 'td:';
  var VERSION = 'v4.0';
  var VERSION_DATE = 'Oct 1, 2026';
  var TZ = 'America/Chicago';
  var DEFAULT_API = 'https://api.tessie.com';
  var REFRESH_MS = 60000, CHARGES_EVERY_S = 15 * 60, HTTP_TIMEOUT_MS = 15000;
  var BAR_TO_PSI = 14.5038;

  var PRESETS = {
    pso: { preset: 'pso', label: 'PSO Oklahoma RSEV', overnight: 0.030451, onStart: 23, onEnd: 6,
           daySummer: 0.084497, dayWinter: 0.061045, fca: 0.031872,
           peak: { enabled: true, rate: 0.248475, start: 14, end: 19, weekdaysOnly: true, summerOnly: true } }
  };

  // ---------- storage ----------
  function load(k, d) { try { var v = localStorage.getItem(P + k); return v ? JSON.parse(v) : d; } catch (e) { return d; } }
  function save(k, v) { try { localStorage.setItem(P + k, JSON.stringify(v)); } catch (e) {} }
  function clearAll() { Object.keys(localStorage).forEach(function (k) { if (k.indexOf(P) === 0) localStorage.removeItem(k); }); }
  function getCfg() { return load('cfg', null); }

  // ---------- time (America/Chicago) ----------
  var partsFmt = new Intl.DateTimeFormat('en-US', { timeZone: TZ, hourCycle: 'h23', year: 'numeric', month: 'numeric',
    day: 'numeric', hour: 'numeric', minute: 'numeric', weekday: 'short' });
  var DOW = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
  function ct(sec) {
    var o = {};
    partsFmt.formatToParts(new Date(sec * 1000)).forEach(function (p) { o[p.type] = p.value; });
    var h = +o.hour; if (h === 24) h = 0;
    return { y: +o.year, mo: +o.month, d: +o.day, h: h, mi: +o.minute, dow: DOW[o.weekday] };
  }
  function offsetMin(sec) { var c = ct(sec); return Math.round((Date.UTC(c.y, c.mo - 1, c.d, c.h, c.mi) / 1000 - Math.floor(sec / 60) * 60) / 60); }
  function ctEpoch(y, mo, d, h) { // Central wall-clock -> epoch seconds
    var guess = Date.UTC(y, mo - 1, d, h, 0) / 1000;
    var e = guess - offsetMin(guess) * 60; return guess - offsetMin(e) * 60;
  }
  function nowSec() { return Math.floor(Date.now() / 1000); }
  var clockFmt = new Intl.DateTimeFormat('en-US', { timeZone: TZ, hour: 'numeric', minute: '2-digit' });
  var dayFmt = new Intl.DateTimeFormat('en-US', { timeZone: TZ, weekday: 'short', month: 'short', day: 'numeric' });
  function clock(sec) { return clockFmt.format(new Date(sec * 1000)); }
  function dayLabel(sec) { return dayFmt.format(new Date(sec * 1000)); }
  function sameDay(a, b) { var x = ct(a), y = ct(b); return x.y === y.y && x.mo === y.mo && x.d === y.d; }
  function fmtMins(m) {
    if (m == null || !(m > 0)) return null; m = Math.round(m);
    return m >= 60 ? Math.floor(m / 60) + 'h ' + ('0' + (m % 60)).slice(-2) + 'm' : m + ' min';
  }

  // ---------- pricing ----------
  function inHours(h, a, b) { return a === b ? false : (a < b ? (h >= a && h < b) : (h >= a || h < b)); }
  function energyRate(r, c) {
    if (inHours(c.h, r.onStart, r.onEnd)) return r.overnight;
    var summer = c.mo >= 6 && c.mo <= 10;
    var pk = r.peak || {};
    if (pk.enabled && (!pk.summerOnly || summer) && (!pk.weekdaysOnly || (c.dow >= 1 && c.dow <= 5)) && inHours(c.h, pk.start, pk.end)) return pk.rate;
    return summer ? r.daySummer : r.dayWinter;
  }
  function allInRate(r, c) { return energyRate(r, c) + (r.fca || 0); }
  // Wall kWh spread evenly over the minutes from t0 to t1; each minute priced at its rate (like the desktop).
  // Only minutes inside [from, to) are counted. Returns cost and the counted fraction.
  function priceSpan(r, t0, t1, wall, from, to) {
    from = from == null ? -Infinity : from; to = to == null ? Infinity : to;
    var mins = Math.max(1, Math.floor((t1 - t0) / 60)), per = wall / mins, cost = 0, n = 0;
    var off0 = offsetMin(t0), fast = off0 === offsetMin(t0 + mins * 60);
    for (var i = 0; i < mins; i++) {
      var t = t0 + i * 60; if (t < from || t >= to) continue;
      var c;
      if (fast) { var d = new Date((t + off0 * 60) * 1000); c = { h: d.getUTCHours(), mo: d.getUTCMonth() + 1, dow: d.getUTCDay() }; }
      else c = ct(t);
      cost += per * allInRate(r, c); n++;
    }
    return { cost: cost, frac: n / mins };
  }
  function money(v) { if (v == null || isNaN(v)) return '--'; return '$' + (Math.round(v * 100) / 100).toFixed(2); }
  function cents(cost, wall) { if (!(wall > 0)) return null; return (Math.round(cost / wall * 1000) / 10).toFixed(1) + '\u00a2/kWh'; }
  function kwh(v) { return v == null ? '--' : (Math.round(v * 10) / 10).toFixed(1) + ' kWh'; }

  // ---------- sessions ----------
  // Normalized session: {src, start, end, added, segs:[[t0,t1,added]], socStart, socEnd}
  function fromCharge(c) {
    var added = c.energy_added != null ? +c.energy_added : null;
    return { src: 'tessie', start: +c.started_at, end: +c.ended_at, added: added, used: c.energy_used,
             socStart: c.starting_battery, socEnd: c.ending_battery, segs: [[+c.started_at, +c.ended_at, added]] };
  }
  // Same as desktop v4: a completed Tessie charge uses Tessie's measured wall kWh (energy_used) when present;
  // otherwise (and for the live charge) wall kWh = kWh added / efficiency.
  function wallOf(cfg, added, used) {
    if (used != null && +used > 0) return +used;
    if (added != null && !isNaN(added)) return added / cfg.eff;
    return 0;
  }
  function sessionCost(cfg, s, from, to) {
    var cost = 0, k = 0, wall = 0;
    s.segs.forEach(function (g) {
      var w = wallOf(cfg, g[2], s.segs.length === 1 ? s.used : null);
      var p = priceSpan(cfg.rates, g[0], Math.max(g[1], g[0] + 60), w, from, to);
      cost += p.cost; k += (g[2] || 0) * p.frac; wall += w * p.frac;
    });
    return { cost: cost, kwh: k, wall: wall };
  }
  function overlaps(a, b) { return a.start < b.end + 300 && b.start < a.end + 300; }

  // ---------- API ----------
  function api(path) {
    var cfg = getCfg() || {}; return apiWith(cfg.apiBase || DEFAULT_API, cfg.token, path);
  }
  function apiWith(base, token, path) {
    var ctl = new AbortController(); var t = setTimeout(function () { ctl.abort(); }, HTTP_TIMEOUT_MS);
    return fetch(base.replace(/\/+$/, '') + path, { headers: { Authorization: 'Bearer ' + token, Accept: 'application/json' },
      cache: 'no-store', signal: ctl.signal }).then(function (r) {
      clearTimeout(t);
      if (r.status === 401 || r.status === 403) { var e = new Error('Token rejected (' + r.status + ')'); e.auth = true; throw e; }
      if (!r.ok) throw new Error('Tessie error ' + r.status);
      return r.json();
    }, function (e) { clearTimeout(t); throw new Error(navigator.onLine === false ? 'Offline' : 'Network error'); });
  }

  // ---------- state ----------
  var cache = load('cache', { state: null, charges: null, stateAt: 0, chargesAt: 0 });
  var live = load('live', null);        // {start, socStart, lastAdded, lastAt, segs, done}
  var busy = false, lastErr = null, timer = null;

  function trackLive(cfg, st) {
    var cs = st.charge_state || {}, t = nowSec();
    var charging = cs.charging_state === 'Charging';
    var added = cs.charge_energy_added != null ? +cs.charge_energy_added : 0;
    if (charging) {
      var cont = live && !live.done && added >= live.lastAdded - 0.05 && (t - live.lastAt) < 14 * 3600;
      if (!cont && live && live.done && added >= live.lastAdded - 0.05 && added > 0 && (t - live.lastAt) < 30 * 60) cont = true; // short pause
      if (!cont) {
        var pw = chargerKw(cs) || 0, est = t;
        if (pw > 0.3) est = t - Math.round(wallOf(cfg, added) / pw * 3600);
        var lastEnd = 0; (cache.charges || []).forEach(function (c) { if (c.ended_at && c.ended_at > lastEnd) lastEnd = c.ended_at; });
        est = Math.max(est, lastEnd + 60, t - 20 * 3600); if (est > t - 60) est = t - 60;
        var pack = cs.energy_remaining && cs.battery_level ? cs.energy_remaining / (cs.battery_level / 100) : 75;
        live = { start: est, socStart: Math.max(0, Math.round(cs.battery_level - added / pack * 100)), lastAdded: added, lastAt: t,
                 segs: added > 0 ? [[est, t, added]] : [], done: false };
      } else {
        var delta = added - live.lastAdded;
        if (delta > 0.001) live.segs.push([live.lastAt, t, delta]);
        live.lastAdded = Math.max(live.lastAdded, added); live.lastAt = t; live.done = false;
        if (live.segs.length > 400) { // merge oldest pairs to stay small
          var a = live.segs.shift(), b = live.segs.shift(); live.segs.unshift([a[0], b[1], (a[2] || 0) + (b[2] || 0)]);
        }
      }
    } else if (live && !live.done) { live.done = true; }
    save('live', live);
  }
  function liveSession() {
    if (!live || !live.segs) return null;
    return { src: 'live', start: live.start, end: live.lastAt, added: live.lastAdded, segs: live.segs, socStart: live.socStart, done: live.done };
  }
  function chargerKw(cs) {
    if (!cs) return null;
    if (!cs.fast_charger_present && cs.charger_voltage > 50 && cs.charger_actual_current > 0) {
      var ph = cs.charger_phases && cs.charger_phases > 1 ? cs.charger_phases : 1;
      return cs.charger_voltage * cs.charger_actual_current * ph / 1000;
    }
    return cs.charger_power != null ? +cs.charger_power : null;
  }

  function refresh(force) {
    var cfg = getCfg(); if (!cfg || busy) return;
    busy = true; setSpin(true);
    var t = nowSec();
    api('/' + cfg.vin + '/state?use_cache=true').then(function (st) {
      var wasCharging = cache.state && cache.state.charge_state && cache.state.charge_state.charging_state === 'Charging';
      var isCharging = st.charge_state && st.charge_state.charging_state === 'Charging';
      cache.state = st; cache.stateAt = t;
      var needCharges = force || !cache.charges || (t - cache.chargesAt) > CHARGES_EVERY_S || wasCharging !== isCharging;
      if (!needCharges) return;
      return api('/' + cfg.vin + '/charges?from=' + (t - 31 * 86400) + '&to=' + t + '&distance_format=mi&format=json')
        .then(function (r) { cache.charges = (r && r.results) || []; cache.chargesAt = t; });
    }).then(function () {
      lastErr = null; trackLive(cfg, cache.state); save('cache', cache);
    }).catch(function (e) { lastErr = e; }).then(function () { busy = false; setSpin(false); render(); });
  }

  // ---------- compute view model ----------
  function compute(cfg) {
    var st = cache.state, t = nowSec();
    if (!st) return null;
    var cs = st.charge_state || {}, vs = st.vehicle_state || {};
    var charging = cs.charging_state === 'Charging';
    var charges = (cache.charges || []).filter(function (c) { return c && c.started_at && c.ended_at; }).map(fromCharge)
      .sort(function (a, b) { return b.end - a.end; });
    var lv = liveSession();
    var sessions = charges.slice();
    if (lv && lv.segs.length) {
      var dup = charges.some(function (c) { return overlaps(c, lv); });
      if (!dup || (charging && !lv.done)) {
        sessions = charges.filter(function (c) { return !overlaps(c, lv); }); sessions.unshift(lv);
      }
    }
    // hero
    var hero;
    if (charging && lv && !lv.done) hero = lv;
    else hero = sessions.filter(function (s) { return (s.added || 0) >= 0.1; })[0] || sessions[0] || null;
    var hc = hero ? sessionCost(cfg, hero) : null;

    // tonight / last night window (11 PM - 11 AM Central)
    var c = ct(t), startH = cfg.rates.onStart != null ? cfg.rates.onStart : 23, w0, w1, label;
    if (c.h >= startH || c.h < 11) {
      var base = c.h >= startH ? c : ct(t - 13 * 3600);
      w0 = ctEpoch(base.y, base.mo, base.d, startH); w1 = t + 1; label = 'Tonight';
    } else {
      var y = ct(t - 86400);
      w0 = ctEpoch(y.y, y.mo, y.d, startH); w1 = ctEpoch(c.y, c.mo, c.d, 11); label = 'Last night';
    }
    function total(from, to) {
      var cost = 0, k = 0;
      sessions.forEach(function (s) { if (s.end < from || s.start > to) return; var r = sessionCost(cfg, s, from, to); cost += r.cost; k += r.kwh; });
      return { cost: cost, kwh: k };
    }
    var night = total(w0, w1);
    var d7 = total(t - 7 * 86400, t + 1), d30 = total(t - 30 * 86400, t + 1);

    // progress
    var soc = cs.battery_level, limit = cs.charge_limit_soc;
    var socStart = hero ? (hero.socStart != null ? hero.socStart : soc) : soc;
    // tires
    function psi(v) { return v == null ? null : v * BAR_TO_PSI; }
    var recF = psi(vs.tpms_rcp_front_value), recR = psi(vs.tpms_rcp_rear_value);
    function tire(pos, rec) {
      var p = psi(vs['tpms_pressure_' + pos]);
      var low = !!(vs['tpms_soft_warning_' + pos] || vs['tpms_hard_warning_' + pos]) || (p != null && p < (rec ? rec - 3 : 38));
      return { psi: p, low: p != null && low };
    }
    return {
      charging: charging, state: st, cs: cs, hero: hero, heroCost: hc,
      kw: charging ? chargerKw(cs) : null, toFull: charging ? fmtMins(cs.minutes_to_full_charge) : null,
      night: night, nightLabel: label, nightStart: w0, d7: d7, d30: d30,
      soc: soc, limit: limit, socStart: socStart,
      tires: { fl: tire('fl', recF), fr: tire('fr', recF), rl: tire('rl', recR), rr: tire('rr', recR) },
      updated: cs.timestamp ? Math.floor(cs.timestamp / 1000) : cache.stateAt, asleep: st.state && st.state !== 'online', carState: st.state
    };
  }

  // ---------- UI ----------
  var $app = document.getElementById('app');
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (ch) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]; }); }
  var ICON_REFRESH = '<svg viewBox="0 0 24 24"><path d="M21 12a9 9 0 1 1-2.64-6.36"/><path d="M21 3v6h-6"/></svg>';
  var ICON_GEAR = '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></svg>';

  function applyTheme() { document.body.classList.toggle('tessie', !!load('tessieLook', false)); 
    var m = document.querySelector('meta[name=theme-color]'); if (m) m.setAttribute('content', load('tessieLook', false) ? '#081426' : '#0b0b0b'); }
  function setSpin(on) { var b = document.getElementById('btnRefresh'); if (b) b.classList.toggle('spin', on); }
  var screen = 'main';

  function footer() {
    return '<div class="foot"><div class="dbv">DESIGN BY <span>VAN</span></div><div class="dbv-bar"></div>' +
      '<div class="ver">' + VERSION + ' \u00b7 ' + VERSION_DATE + (VARIANT === 'test' ? ' \u00b7 TEST' : '') + '</div></div>';
  }
  function testBanner() { return VARIANT === 'test' ? '<div class="test-banner">TEST BUILD</div>' : ''; }

  function render() {
    applyTheme();
    var cfg = getCfg();
    if (!cfg) return renderForm(true);
    if (screen === 'settings') return renderForm(false);
    var v = compute(cfg);
    var note = '';
    if (lastErr) note = '<span class="note err">' + esc(lastErr.auth ? 'Token rejected, check Settings' : lastErr.message + ', retrying') + (v ? ' \u00b7 showing ' + clock(cache.stateAt) : '') + '</span>';
    else if (v) note = '<span class="note">' + (v.charging ? 'LIVE \u00b7 ' : '') + 'updated ' + clock(v.updated) + (v.asleep ? ' \u00b7 car ' + esc(v.carState) : '') + '</span>';
    else note = '<span class="note">Loading\u2026</span>';

    var h = '<div class="wrap">' + testBanner() +
      '<div class="hdr"><div class="brand">TESSDESK</div><div class="who">Logged in as <b>' + esc(cfg.name) + '</b></div></div>' +
      '<div class="toolbar">' + note + '<div class="tools"><button class="icon-btn" id="btnRefresh" aria-label="Refresh">' + ICON_REFRESH +
      '</button><button class="icon-btn" id="btnSettings" aria-label="Settings">' + ICON_GEAR + '</button></div></div>';

    if (!v) { h += '<div class="hero"><div class="money red">$--.--</div><div class="sub">Waiting for Tessie\u2026</div></div>' + footer() + '</div>'; $app.innerHTML = h; bind(); return; }

    var col = v.charging ? 'green' : 'red';
    var hc = v.heroCost, hero = v.hero;
    var rate = hc ? cents(hc.cost, hc.wall) : null;
    var meta = '';
    if (hero) {
      meta = kwh(hero.added) + ' added \u00b7 ' + kwh(hc.wall) + ' from wall';
      if (!v.charging) meta += '<br>' + esc(dayLabel(hero.start)) + ' ' + clock(hero.start) + ' \u2192 ' + (sameDay(hero.start, hero.end) ? '' : esc(dayLabel(hero.end)) + ' ') + clock(hero.end);
    }
    h += '<div class="hero"><span class="badge' + (v.charging ? ' on' : '') + '">' + (v.charging ? '\u25cf CHARGING' : esc((v.cs.charging_state || 'IDLE').toUpperCase())) + '</span>' +
      '<div class="money ' + col + '">' + (hc ? money(hc.cost) : '$--.--') + '</div>' +
      '<div class="sub">' + (v.charging ? 'This charge' : 'Last charge') + (rate ? ' \u00b7 ' + rate : '') + '</div>' +
      '<div class="meta">' + meta + '</div></div>';
    h += '<div class="toggle-row"><div class="toggle' + (load('tessieLook', false) ? ' on' : '') + '" id="tglTessie" role="switch" aria-checked="' + !!load('tessieLook', false) + '">TESSIE LOOK<span class="sw"></span></div></div>';

    // progress
    var a = v.socStart, b = v.limit, s = v.soc;
    if (a == null) a = s; if (b == null) b = 100;
    if (a > b) a = Math.min(a, s);
    var span = Math.max(1, b - a), pos = Math.max(0, Math.min(100, (s - a) / span * 100));
    h += '<div class="card"><h3>' + (v.charging ? 'Charging' : 'Battery') + '</h3><div class="prog"><div class="track"></div>' +
      '<div class="fill ' + col + '-bg" style="width:' + pos + '%"></div>' +
      '<div class="bubble ' + col + '-t" style="left:clamp(16px,' + pos + '%,calc(100% - 16px))">' + (s != null ? s + '%' : '--') + '</div>' +
      '<div class="ball ' + col + '-bg' + (v.charging ? ' pulse' : '') + '" style="left:' + pos + '%"></div></div>' +
      '<div class="prog-labels"><span>Start <b>' + (a != null ? a + '%' : '--') + '</b></span><span>Limit <b>' + (b != null ? b + '%' : '--') + '</b></span></div></div>';

    // chips
    var started = hero ? clock(hero.start) : '--';
    h += '<div class="chips">' +
      chip('POWER', v.kw != null ? (Math.round(v.kw * 10) / 10).toFixed(1) + ' kW' : '--') +
      chip('TO FULL', v.charging ? (v.toFull || '--') : (v.cs.charging_state === 'Complete' ? 'Done' : '--')) +
      chip('STARTED', started) + '</div>';

    // tires
    h += '<div class="card tires"><h3>Tire pressure</h3>' + tireSvg(v.tires) + '</div>';

    // rows
    var nightSub = v.nightLabel === 'Tonight' ? 'Since ' + clock(v.nightStart) : dayLabel(v.nightStart) + ', 11 PM \u2013 11 AM';
    h += '<div class="card rows">' +
      row(v.nightLabel, nightSub, v.night, true) + row('Last 7 days', null, v.d7) + row('Last 30 days', null, v.d30) + '</div>';
    h += footer() + '</div>';
    $app.innerHTML = h; bind();
  }
  function chip(k, val) { return '<div class="chip"><div class="k">' + k + '</div><div class="v">' + esc(val) + '</div></div>'; }
  function row(l, sub, t, hl) {
    return '<div class="row' + (hl ? ' hl' : '') + '"><div class="l">' + esc(l) + (sub ? '<small>' + esc(sub) + '</small>' : '') + '</div>' +
      '<div class="r"><b>' + money(t.cost) + '</b><small>' + kwh(t.kwh) + '</small></div></div>';
  }
  function tireSvg(T) {
    function lab(x, y, t, anchor) {
      var cls = t.low ? ' low' : '';
      return '<text class="psi' + cls + '" x="' + x + '" y="' + y + '" text-anchor="' + anchor + '">' + (t.psi == null ? '--' : Math.round(t.psi)) + '</text>' +
        '<text class="unit" x="' + x + '" y="' + (y + 15) + '" text-anchor="' + anchor + '">PSI</text>';
    }
    function tire(x, y, t) { return '<rect class="tire' + (t.low ? ' low' : '') + '" x="' + x + '" y="' + y + '" width="16" height="40" rx="5"/>'; }
    return '<svg viewBox="0 0 320 240" role="img" aria-label="Tire pressures">' +
      // leads
      '<line class="lead" x1="86" y1="64" x2="114" y2="64"/><line class="lead" x1="206" y1="64" x2="234" y2="64"/>' +
      '<line class="lead" x1="86" y1="178" x2="114" y2="178"/><line class="lead" x1="206" y1="178" x2="234" y2="178"/>' +
      tire(114, 44, T.fl) + tire(190, 44, T.fr) + tire(114, 158, T.rl) + tire(190, 158, T.rr) +
      // body (top-down, front up)
      '<path class="body" d="M160 10 C 196 10 204 22 204 50 L 206 120 L 204 200 C 204 222 192 230 160 230 C 128 230 116 222 116 200 L 114 120 L 116 50 C 116 22 124 10 160 10 Z"/>' +
      '<path class="glass" d="M128 66 C 140 56 180 56 192 66 L 188 96 C 172 92 148 92 132 96 Z"/>' +
      '<path class="glass" d="M134 104 C 150 100 170 100 186 104 L 186 168 C 170 172 150 172 134 168 Z" opacity=".55"/>' +
      '<path class="glass" d="M132 180 C 148 184 172 184 188 180 L 190 204 C 172 212 148 212 130 204 Z"/>' +
      '<text class="unit" x="160" y="26" text-anchor="middle">FRONT</text>' +
      lab(80, 64, T.fl, 'end') + lab(240, 64, T.fr, 'start') + lab(80, 178, T.rl, 'end') + lab(240, 178, T.rr, 'start') + '</svg>';
  }

  function bind() {
    var r = document.getElementById('btnRefresh'); if (r) r.onclick = function () { refresh(true); };
    var s = document.getElementById('btnSettings'); if (s) s.onclick = function () { screen = 'settings'; render(); window.scrollTo(0, 0); };
    var t = document.getElementById('tglTessie'); if (t) t.onclick = function () { save('tessieLook', !load('tessieLook', false)); render(); };
    if (busy) setSpin(true);
  }

  // ---------- setup / settings form ----------
  function hourOpts(sel) { var o = ''; for (var i = 0; i < 24; i++) { var l = (i % 12 || 12) + ' ' + (i < 12 ? 'AM' : 'PM'); o += '<option value="' + i + '"' + (i === sel ? ' selected' : '') + '>' + l + '</option>'; } return o; }
  function renderForm(first) {
    var cfg = getCfg() || { name: '', token: '', vin: '', rates: PRESETS.pso, eff: 0.9, apiBase: DEFAULT_API, resetOnLaunch: VARIANT === 'test' };
    var r = cfg.rates || PRESETS.pso, pk = r.peak || {};
    var isTestReset = VARIANT === 'test' ? (load('resetOnLaunch', true) !== false) : false;
    var h = '<div class="wrap form">' + testBanner() + '<div class="hdr"><div class="brand">TESSDESK</div>' +
      (first ? '' : '<div class="who">Logged in as <b>' + esc(cfg.name) + '</b></div>') + '</div>' +
      '<h1>' + (first ? 'Welcome' : 'Settings') + '</h1><p class="lead">' + (first ? 'Set up TessDesk for your Tesla. Everything stays on this phone.' : 'Saved on this device only.') + '</p>' +
      '<div class="field"><label for="fName">Your name</label><input type="text" id="fName" autocomplete="given-name" value="' + esc(cfg.name) + '" placeholder="Van"></div>' +
      '<div class="field"><label for="fToken">Tessie API token</label><div class="inline"><input type="password" id="fToken" autocomplete="off" autocapitalize="off" spellcheck="false" value="' + esc(cfg.token) + '" placeholder="Paste token">' +
      '<button class="btn ghost" id="bShow" type="button" style="flex:0 0 72px;margin:0">Show</button></div>' +
      '<div class="help">Tessie app \u2192 Settings \u2192 API. Copy the access token and paste it here.</div></div>' +
      '<button class="btn ghost" id="bFind" type="button">Find my vehicles</button>' +
      '<div class="field"><label for="fVin">Vehicle</label><select id="fVin">' + (cfg.vin ? '<option value="' + esc(cfg.vin) + '">' + esc((cfg.carName || 'Vehicle') + ' \u00b7 ' + cfg.vin) + '</option>' : '<option value="">Tap \u201cFind my vehicles\u201d first</option>') + '</select><div class="msg" id="mFind"></div></div>' +
      '<div class="sect">Electricity rates</div>' +
      '<div class="field"><label for="fPreset">Plan</label><select id="fPreset"><option value="pso"' + (r.preset === 'pso' ? ' selected' : '') + '>PSO Oklahoma RSEV</option><option value="custom"' + (r.preset !== 'pso' ? ' selected' : '') + '>Custom</option></select>' +
      '<div class="help" id="psoHelp">Overnight 11 PM\u20136 AM 6.2\u00a2/kWh (3.0451\u00a2 + 3.1872\u00a2 fuel adjustment). Daytime 11.6\u00a2 Jun\u2013Oct, 9.3\u00a2 Nov\u2013May. Peak Jun\u2013Oct weekdays 2\u20137 PM 28.0\u00a2.</div></div>' +
      '<div id="custom">' +
      '<div class="field"><label>Overnight $/kWh (energy)</label><input type="number" step="0.000001" id="fOn" value="' + r.overnight + '"></div>' +
      '<div class="field"><label>Overnight hours</label><div class="inline"><select id="fOnS">' + hourOpts(r.onStart) + '</select><span style="flex:0">to</span><select id="fOnE">' + hourOpts(r.onEnd) + '</select></div></div>' +
      '<div class="field"><label>Daytime $/kWh (energy)</label><input type="number" step="0.000001" id="fDay" value="' + r.daySummer + '"></div>' +
      '<div class="field"><label>Fuel / FCA adder $/kWh</label><input type="number" step="0.000001" id="fFca" value="' + r.fca + '"><div class="help">Added to every kWh.</div></div>' +
      '<label class="check"><input type="checkbox" id="fPk"' + (pk.enabled ? ' checked' : '') + '> Peak window</label>' +
      '<div id="peakBox"><div class="field"><label>Peak $/kWh (energy)</label><input type="number" step="0.000001" id="fPkR" value="' + (pk.rate || 0) + '"></div>' +
      '<div class="field"><label>Peak hours</label><div class="inline"><select id="fPkS">' + hourOpts(pk.start != null ? pk.start : 14) + '</select><span style="flex:0">to</span><select id="fPkE">' + hourOpts(pk.end != null ? pk.end : 19) + '</select></div></div>' +
      '<label class="check"><input type="checkbox" id="fPkW"' + (pk.weekdaysOnly !== false ? ' checked' : '') + '> Weekdays only</label>' +
      '<label class="check"><input type="checkbox" id="fPkM"' + (pk.summerOnly !== false ? ' checked' : '') + '> June\u2013October only</label></div></div>' +
      '<div class="field"><label for="fEff">Charging efficiency %</label><input type="number" id="fEff" min="50" max="100" step="1" value="' + Math.round((cfg.eff || 0.9) * 100) + '"><div class="help">Wall kWh = kWh added \u00f7 efficiency. Default 90%.</div></div>' +
      '<div class="sect">Display</div>' +
      '<label class="check"><input type="checkbox" id="fLook"' + (load('tessieLook', false) ? ' checked' : '') + '> Tessie look</label>' +
      (VARIANT === 'test' ? '<label class="check"><input type="checkbox" id="fReset"' + (isTestReset ? ' checked' : '') + '> Reset data on every launch</label>' : '') +
      '<details style="margin:10px 0;color:var(--muted);font-size:13px"><summary>Advanced</summary><div class="field"><label>API address</label><input type="url" id="fApi" value="' + esc(cfg.apiBase || DEFAULT_API) + '"><div class="help">Leave as https://api.tessie.com unless you set up a proxy.</div></div></details>' +
      '<div class="msg" id="mSave"></div><button class="btn" id="bSave">' + (first ? 'Start TessDesk' : 'Save') + '</button>' +
      (first ? '' : '<button class="btn ghost" id="bCancel">Back</button><button class="btn danger" id="bLogout">Log out and erase data</button>') +
      footer() + '</div>';
    $app.innerHTML = h;
    var el = function (id) { return document.getElementById(id); };
    function sync() {
      var c = el('fPreset').value === 'custom';
      el('custom').classList.toggle('hidden', !c); el('psoHelp').classList.toggle('hidden', c);
      el('peakBox').classList.toggle('hidden', !el('fPk').checked);
    }
    el('fPreset').onchange = sync; el('fPk').onchange = sync; sync();
    el('bShow').onclick = function () { var t = el('fToken'); t.type = t.type === 'password' ? 'text' : 'password'; el('bShow').textContent = t.type === 'password' ? 'Show' : 'Hide'; };
    el('bFind').onclick = function () {
      var tok = el('fToken').value.trim().replace(/^bearer\s+/i, ''), m = el('mFind');
      if (!tok) { m.className = 'msg err'; m.textContent = 'Paste your token first.'; return; }
      m.className = 'msg'; m.textContent = 'Looking up your vehicles\u2026';
      apiWith(el('fApi').value.trim() || DEFAULT_API, tok, '/vehicles?only_active=true').then(function (r) {
        var list = (r && r.results) || [];
        if (!list.length) throw new Error('No vehicles on this Tessie account');
        el('fVin').innerHTML = list.map(function (x) {
          var ls = x.last_state || {}, nm = ls.display_name || 'Tesla';
          return '<option value="' + esc(x.vin) + '" data-name="' + esc(nm) + '"' + (x.vin === cfg.vin ? ' selected' : '') + '>' + esc(nm + ' \u00b7 ' + x.vin) + '</option>';
        }).join('');
        m.className = 'msg ok'; m.textContent = 'Found ' + list.length + ' vehicle' + (list.length > 1 ? 's' : '') + '.';
      }).catch(function (e) { m.className = 'msg err'; m.textContent = e.auth ? 'Token rejected. Check it and try again.' : 'Could not reach Tessie: ' + e.message; });
    };
    el('bSave').onclick = function () {
      var m = el('mSave'), name = el('fName').value.trim(), tok = el('fToken').value.trim().replace(/^bearer\s+/i, ''), vin = el('fVin').value;
      var eff = (+el('fEff').value || 90) / 100;
      if (!name || !tok || !vin) { m.className = 'msg err'; m.textContent = !name ? 'Enter your name.' : !tok ? 'Paste your Tessie token.' : 'Pick your vehicle (tap Find my vehicles).'; return; }
      if (eff < 0.5 || eff > 1) { m.className = 'msg err'; m.textContent = 'Efficiency must be 50\u2013100%.'; return; }
      var rates;
      if (el('fPreset').value === 'pso') rates = JSON.parse(JSON.stringify(PRESETS.pso));
      else {
        var day = +el('fDay').value || 0;
        rates = { preset: 'custom', overnight: +el('fOn').value || 0, onStart: +el('fOnS').value, onEnd: +el('fOnE').value,
          daySummer: day, dayWinter: day, fca: +el('fFca').value || 0,
          peak: { enabled: el('fPk').checked, rate: +el('fPkR').value || 0, start: +el('fPkS').value, end: +el('fPkE').value,
                  weekdaysOnly: el('fPkW').checked, summerOnly: el('fPkM').checked } };
      }
      var opt = el('fVin').selectedOptions[0];
      var changedCar = vin !== cfg.vin || tok !== cfg.token;
      save('cfg', { name: name, token: tok, vin: vin, carName: (opt && opt.getAttribute('data-name')) || cfg.carName || '', rates: rates, eff: eff,
                    apiBase: (el('fApi').value.trim() || DEFAULT_API) });
      save('tessieLook', el('fLook').checked);
      if (VARIANT === 'test') save('resetOnLaunch', el('fReset').checked);
      if (changedCar) { cache = { state: null, charges: null, stateAt: 0, chargesAt: 0 }; live = null; save('cache', cache); save('live', null); }
      screen = 'main'; render(); refresh(true); startTimer();
    };
    if (!first) {
      el('bCancel').onclick = function () { screen = 'main'; render(); };
      el('bLogout').onclick = function () {
        if (!confirm('Log out and erase your token and settings from this phone?')) return;
        clearAll(); cache = { state: null, charges: null, stateAt: 0, chargesAt: 0 }; live = null; screen = 'main'; stopTimer(); render();
      };
    }
  }

  // ---------- refresh loop + pull to refresh ----------
  function startTimer() { stopTimer(); timer = setInterval(function () { if (document.visibilityState === 'visible') refresh(false); }, REFRESH_MS); }
  function stopTimer() { if (timer) clearInterval(timer); timer = null; }
  document.addEventListener('visibilitychange', function () { if (document.visibilityState === 'visible' && getCfg() && screen === 'main' && nowSec() - cache.stateAt > 30) refresh(false); });
  (function ptr() {
    var y0 = null, ind = document.createElement('div'); ind.className = 'ptr'; ind.textContent = 'Pull to refresh'; document.body.appendChild(ind);
    window.addEventListener('touchstart', function (e) { y0 = (window.scrollY <= 0 && screen === 'main' && getCfg()) ? e.touches[0].clientY : null; }, { passive: true });
    window.addEventListener('touchmove', function (e) {
      if (y0 == null) return; var dy = e.touches[0].clientY - y0;
      if (dy > 0) { ind.style.transform = 'translate(-50%,' + Math.min(dy - 60, 20) + 'px)'; ind.textContent = dy > 80 ? 'Release to refresh' : 'Pull to refresh'; }
    }, { passive: true });
    window.addEventListener('touchend', function (e) {
      if (y0 == null) return; var dy = (e.changedTouches[0] || {}).clientY - y0; y0 = null;
      ind.style.transform = 'translate(-50%,-60px)'; if (dy > 80) refresh(true);
    }, { passive: true });
  })();

  // test hooks for headless checks (no secrets)
  window.TessDesk = { priceSpan: function (t0, t1, wall) { var c = getCfg(); return priceSpan(c ? c.rates : PRESETS.pso, t0, t1, wall); }, PRESETS: PRESETS, ctEpoch: ctEpoch, refresh: refresh };

  render();
  if (getCfg()) { refresh(false); startTimer(); }
})();
