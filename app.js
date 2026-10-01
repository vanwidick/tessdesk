/* TessDesk mobile v4.1 (PWA). Design by Van.
   Everything (name, Tessie token, vehicle, rates) is stored in localStorage on this device only. */
(function () {
  'use strict';
  var CFG = window.TD_CONFIG || {};
  var VARIANT = CFG.variant || 'main';
  var P = CFG.storagePrefix || 'td:';
  var VERSION = 'v4.1';
  var VERSION_DATE = 'Oct 1, 2026';
  var TZ = 'America/Chicago';
  var DEFAULT_API = 'https://api.tessie.com';
  var REFRESH_MS = 60000, CHARGES_EVERY_S = 15 * 60, HTTP_TIMEOUT_MS = 15000, CMD_TIMEOUT_MS = 90000;
  var CHANGELOG_URL = VARIANT === 'test' ? '../changelog.html' : 'changelog.html';
  var BAR_TO_PSI = 14.5038;
  var PRIVACY_URL = VARIANT === 'test' ? '../privacy.html' : 'privacy.html';
  // tire thresholds (same defaults as the desktop config.json "tires" block)
  var TIRE = { yellowPct: 5, redPct: 10, maxPsiNoRec: 48, minPsiNoRec: 38 };
  var CONSENT_VERSION = '4.1';
  var HELP_LINKS = [
    ['Sign up for Tessie', 'https://www.tessie.com', 'No Tessie account? Tessie is a paid service that connects to your Tesla.'],
    ['Get your API token', 'https://dash.tessie.com/settings/api', 'After signing up: Tessie app \u2192 Settings \u2192 API (or this page).'],
    ['Create a Gmail account', 'https://accounts.google.com/signup', 'No Gmail? Free. Handy for reminder emails.'],
    ['2-Step Verification', 'https://myaccount.google.com/signinoptions/two-step-verification', 'Google needs it before you can make an App Password.'],
    ['Gmail App Password', 'https://myaccount.google.com/apppasswords', 'For desktop TessDesk reminders (16-letter password).'],
    ['How App Passwords work', 'https://support.google.com/accounts/answer/185833', 'Google help article.']
  ];
  var NOTICE = [
    'TessDesk is an <b>unofficial</b> app. It is not made by, affiliated with, or endorsed by Tesla or Tessie.',
    'It uses your Tessie API token to <b>read vehicle data</b> (location, battery, charging, tires, lock and climate state) and, only when you press a control, to <b>send commands</b> (lock/unlock, windows, climate, charge limit).',
    'Your token and settings are stored <b>only on this phone</b> (browser local storage) and the token is sent <b>only to api.tessie.com</b>.',
    'Reminders use your own calendar or email app (and, on the desktop, your own email account or carrier gateway). Nothing goes to the TessDesk author.',
    'Costs shown are <b>estimates</b> based on the rates you enter.',
    'Commands can <b>wake the car</b> and use a little battery. Use the controls only when it is safe and legal.',
    'No warranty. You use TessDesk at your own risk. Tessie\u2019s Terms of Service apply.',
    'To revoke access: delete the API token in the Tessie app (Settings \u2192 API). To remove TessDesk: Settings \u2192 Log out and erase data, then remove the home-screen icon.'
  ];

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

  // Vehicle command (TESLA CONTROLS): POST /{vin}/command/<name>?wait_for_completion=true. May wake the car (the user pressed a button).
  // Dry run (Settings > Advanced, and the headless tests) never touches the network.
  function command(name, query) {
    var cfg = getCfg() || {};
    var q = 'wait_for_completion=true'; Object.keys(query || {}).forEach(function (k) { q += '&' + k + '=' + encodeURIComponent(query[k]); });
    var path = '/' + cfg.vin + '/command/' + name + '?' + q;
    cmdLog.push({ at: new Date().toISOString(), cmd: name, path: path, dryRun: !!load('dryRun', false) });
    if (cmdLog.length > 20) cmdLog.shift();
    if (load('dryRun', false)) return new Promise(function (res) { setTimeout(function () { res({ result: true, dryRun: true }); }, 1400); });
    var ctl = new AbortController(); var t = setTimeout(function () { ctl.abort(); }, CMD_TIMEOUT_MS);
    return fetch((cfg.apiBase || DEFAULT_API).replace(/\/+$/, '') + path, { method: 'POST', headers: { Authorization: 'Bearer ' + cfg.token, Accept: 'application/json' },
      cache: 'no-store', signal: ctl.signal }).then(function (r) {
      clearTimeout(t);
      return r.json().catch(function () { return {}; }).then(function (j) {
        if (r.status === 401 || r.status === 403) throw new Error('token rejected (' + r.status + ')');
        if (!r.ok) throw new Error((j && (j.error || j.reason)) || ('Tessie error ' + r.status));
        if (!j || !j.result) throw new Error((j && (j.reason || j.error)) || 'car did not confirm');
        return j;
      });
    }, function () { clearTimeout(t); throw new Error(navigator.onLine === false ? 'offline' : 'no response (network / timeout)'); });
  }
  var cmdLog = [];

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
    if (!consentOk()) return;   // no Tessie calls until the notice is accepted
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
    // range as the car displays it (gui_range_display: Rated -> battery_range, Ideal -> ideal_battery_range)
    var gs = st.gui_settings || {}, cl = st.climate_state || {};
    var range = cs.battery_range, rangeKind = 'RATED RANGE';
    if (gs.gui_range_display === 'Ideal' && cs.ideal_battery_range > 0) { range = cs.ideal_battery_range; rangeKind = 'IDEAL RANGE'; }
    if (!(range > 0) && cs.est_battery_range > 0) { range = cs.est_battery_range; rangeKind = 'EST. RANGE'; }
    // tires: green / yellow / red from the car's TPMS warnings and recommended pressures (see tireFlag)
    function psi(v) { return v == null ? null : v * BAR_TO_PSI; }
    var recF = psi(vs.tpms_rcp_front_value), recR = psi(vs.tpms_rcp_rear_value);
    function tire(pos, rec) {
      var p = psi(vs['tpms_pressure_' + pos]);
      return { psi: p, flag: tireFlag(p, vs['tpms_soft_warning_' + pos], vs['tpms_hard_warning_' + pos], rec) };
    }
    var wins = ['fd_window', 'fp_window', 'rd_window', 'rp_window'].filter(function (k) { return vs[k] != null; });
    var car = { locked: vs.locked, windowsOpen: wins.length ? wins.some(function (k) { return +vs[k] !== 0; }) : null,
      climateOn: cl.is_climate_on, tempC: cl.driver_temp_setting, insideC: cl.inside_temp,
      minC: cl.min_avail_temp != null ? cl.min_avail_temp : 15, maxC: cl.max_avail_temp != null ? cl.max_avail_temp : 28,
      units: gs.gui_temperature_units === 'C' ? 'C' : 'F',
      limitMin: cs.charge_limit_soc_min != null ? cs.charge_limit_soc_min : 50, limitMax: cs.charge_limit_soc_max != null ? cs.charge_limit_soc_max : 100 };
    return {
      charging: charging, state: st, cs: cs, hero: hero, heroCost: hc,
      kw: charging ? chargerKw(cs) : null, toFull: charging ? fmtMins(cs.minutes_to_full_charge) : null,
      night: night, nightLabel: label, nightStart: w0, d7: d7, d30: d30,
      soc: soc, limit: limit, socStart: socStart, range: range, rangeKind: rangeKind, car: car,
      tires: { fl: tire('fl', recF), fr: tire('fr', recF), rl: tire('rl', recR), rr: tire('rr', recR), recF: recF, recR: recR },
      updated: cs.timestamp ? Math.floor(cs.timestamp / 1000) : cache.stateAt, asleep: st.state && st.state !== 'online', carState: st.state
    };
  }

  // GREEN = good. YELLOW = a little out (car's soft TPMS warning, or 5-10% from the recommended cold pressure).
  // RED = really out (car's hard TPMS warning, or > 10% off) and it flashes. Returns 'green' | 'yellow-low' | 'red-high' | 'none' ...
  function tireFlag(p, soft, hard, rec) {
    if (p == null) return 'none';
    var level = 'green', dir = '';
    if (rec != null && rec > 0) {
      var dev = (p - rec) / rec * 100;
      if (Math.abs(dev) > TIRE.redPct) level = 'red'; else if (Math.abs(dev) > TIRE.yellowPct) level = 'yellow';
      if (level !== 'green') dir = dev < 0 ? 'low' : 'high';
    } else {
      if (p > TIRE.maxPsiNoRec) { level = 'red'; dir = 'high'; } else if (p < TIRE.minPsiNoRec) { level = 'red'; dir = 'low'; }
      else if (p > TIRE.maxPsiNoRec - 2) { level = 'yellow'; dir = 'high'; } else if (p < TIRE.minPsiNoRec + 2) { level = 'yellow'; dir = 'low'; }
    }
    if (hard) { level = 'red'; if (!dir) dir = 'low'; }
    else if (soft) { if (level === 'green') level = 'yellow'; if (!dir) dir = 'low'; }
    return dir ? level + '-' + dir : level;
  }

  // ---------- UI ----------
  var $app = document.getElementById('app');
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (ch) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]; }); }
  var ICON_REFRESH = '<svg viewBox="0 0 24 24"><path d="M21 12a9 9 0 1 1-2.64-6.36"/><path d="M21 3v6h-6"/></svg>';
  var ICON_GEAR = '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></svg>';

  // v4.1: the Tessie look is always on: green palette while charging, red-tinted when not.
  function isCharging() { var s = cache && cache.state; return !!(s && s.charge_state && s.charge_state.charging_state === 'Charging'); }
  function applyTheme() {
    var tessie = true, chg = isCharging();
    document.body.classList.toggle('tessie', tessie);
    document.body.classList.toggle('idle', tessie && !chg);
    var m = document.querySelector('meta[name=theme-color]');
    if (m) m.setAttribute('content', tessie ? (chg ? '#081426' : '#170a0d') : '#0b0b0b');
  }
  function setSpin(on) { var b = document.getElementById('btnRefresh'); if (b) b.classList.toggle('spin', on); }
  var screen = 'main';

  function footer() {
    return '<div class="foot"><div class="dbv">DESIGN BY <span>VAN</span></div><div class="dbv-bar"></div>' +
      '<div class="foot-links"><a class="ver" href="' + CHANGELOG_URL + '" title="What\u2019s new">' + VERSION + ' \u00b7 ' + VERSION_DATE + (VARIANT === 'test' ? ' \u00b7 TEST' : '') + '</a>' +
      '<span class="dot">\u00b7</span><a class="ver about" href="' + PRIVACY_URL + '" title="About TessDesk, privacy and permissions">About / Privacy</a></div></div>';
  }
  function testBanner() { return VARIANT === 'test' ? '<div class="test-banner">TEST BUILD</div>' : ''; }

  function render() {
    if (dragging) return;
    applyTheme();
    var cfg = getCfg();
    if (!cfg) return renderForm(true);
    if (screen === 'settings') return renderForm(false);
    if (!consentOk()) return renderConsent();
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
    h += '<div class="gap"></div>';

    // battery: big % + range, 0-100% bar (ball = now, tick = where this charge started), draggable LIMIT handle
    var a = v.socStart, b = ctlVal('limit', v.limit), s = v.soc;
    if (a == null) a = s; if (s != null && a > s) a = s;
    var perPct = (v.range > 0 && s > 0) ? v.range / s : null;
    lastBatt = { perPct: perPct, limit: b, min: v.car.limitMin, max: v.car.limitMax };
    var stTxt = v.charging ? 'CHARGING \u2192 ' + b + '%' : friendlyState(v.cs.charging_state).toUpperCase();
    h += '<div class="card batt"><div class="batt-hd"><h3>Battery</h3><span class="bstate' + (v.charging ? ' on' : '') + '">' + esc(stTxt) + '</span></div>' +
      '<div class="batt-top" id="battTop"><span class="pct">' + (s != null ? s + '%' : '--') + '</span>' +
      (v.range > 0 ? '<span class="rng"><b>' + Math.round(v.range) + ' mi</b><small>' + esc(v.rangeKind) + '</small></span>' : '') + '</div>' +
      '<div class="batt-drag hidden" id="battDrag"><small>SET LIMIT</small><span id="dragVal"></span></div>' +
      '<div class="bar" id="limBar"><div class="track"></div>' +
      '<div class="fill base ' + col + '-bg" style="width:' + (a || 0) + '%"></div>' +
      '<div class="fill add ' + col + '-bg" style="left:' + (a || 0) + '%;width:' + Math.max(0, (s || 0) - (a || 0)) + '%"></div>' +
      '<div class="tick" style="left:' + (a || 0) + '%"></div>' +
      '<div class="ball ' + col + '-bg' + (v.charging ? ' pulse' : '') + '" style="left:' + (s || 0) + '%">' + (s != null ? s : '') + '</div>' +
      '<div class="thumb" id="limThumb" role="slider" aria-label="Charge limit" aria-valuemin="' + v.car.limitMin + '" aria-valuemax="' + v.car.limitMax + '" aria-valuenow="' + b + '" style="left:' + b + '%"><i></i><i></i></div></div>' +
      '<div class="fl-labels"><div><small>FROM</small><span class="mi">' + miles(perPct, a) + '</span><b>' + (a != null ? a + '%' : '--') + '</b></div>' +
      '<div class="r"><small>LIMIT</small><span class="mi" id="limMi">' + miles(perPct, b) + '</span><b id="limPct">' + (b != null ? b + '%' : '--') + '</b></div></div></div>';

    // chips
    var started = hero ? clock(hero.start) : '--';
    if (v.charging) {
      var vSub = v.cs.fast_charger_present ? 'DC fast charging' : (v.cs.charger_voltage > 50 && v.cs.charger_actual_current > 0 ?
        Math.round(v.cs.charger_voltage) + ' V \u00b7 ' + Math.round(v.cs.charger_actual_current) + ' A' + (v.cs.charger_phases > 1 ? ' \u00b7 ' + v.cs.charger_phases + '-phase' : '') : '');
      var done = v.cs.minutes_to_full_charge > 0 ? 'done ~' + clock(nowSec() + v.cs.minutes_to_full_charge * 60) : '';
      h += '<div class="chips">' +
        chip('CHARGING AT', v.cs.charger_power != null ? v.cs.charger_power + ' kW' : '--', vSub) +
        chip('TO FULL', v.toFull || (v.cs.minutes_to_full_charge === 0 ? 'Done' : '--'), done) +
        chip('STARTED', started, hero ? dayLabel(hero.start) : '') + '</div>';
    } else {
      h += '<div class="chips">' +
        chip('POWER', 'Not charging', friendlyState(v.cs.charging_state), 'soft') +
        chip('TO FULL', v.cs.charging_state === 'Complete' ? 'Done' : '--', v.cs.charging_state === 'Complete' ? 'at limit' : '') +
        chip('ENDED', hero ? clock(hero.end) : '--', hero ? dayLabel(hero.end) : '') + '</div>';
    }

    // tires
    var rec = v.tires.recF != null ? ' \u00b7 rec ' + Math.round(v.tires.recF) + (v.tires.recR != null && Math.abs(v.tires.recR - v.tires.recF) >= 0.5 ? '/' + Math.round(v.tires.recR) : '') + ' PSI' : '';
    var remOk = !!(cfg.consent && cfg.consent.reminders);
    h += '<div class="card tires"><h3>Tire pressure' + rec + '</h3>' + tireSvg(v.tires) +
      '<button class="cbtn remind" id="bRemind"' + (remOk ? '' : ' disabled') + '><b>REMIND ME TO GET AIR</b><small>' + (remOk ? 'calendar alert or email draft' : 'reminders are off (Settings)') + '</small></button></div>';

    // TESLA CONTROLS (under tires)
    h += controlsCard(v.car);

    // rows
    var nightSub = v.nightLabel === 'Tonight' ? 'Since ' + clock(v.nightStart) : dayLabel(v.nightStart) + ', 11 PM \u2013 11 AM';
    h += '<div class="card rows">' +
      row(v.nightLabel, nightSub, v.night, true) + row('Last 7 days', null, v.d7) + row('Last 30 days', null, v.d30) + '</div>';
    h += footer() + '</div>';
    $app.innerHTML = h; bind();
  }
  function chip(k, val, sub, cls) { return '<div class="chip"><div class="k">' + k + '</div><div class="v' + (cls ? ' ' + cls : '') + '">' + esc(val) + '</div><div class="s">' + esc(sub || '\u00a0') + '</div></div>'; }
  function friendlyState(s) { return ({ Complete: 'Charge complete', Stopped: 'Charging stopped', Disconnected: 'Unplugged', NoPower: 'No power', Starting: 'Starting\u2026' })[s] || s || 'Idle'; }
  function miles(perPct, pct) { return perPct && pct != null ? Math.round(perPct * pct) + ' mi' : '\u00a0'; }

  // ---------- TESLA CONTROLS ----------
  var ctlBusy = false, ctlMsg = { kind: 'idle', text: '' }, ctlOv = {}, pendTemp = null, tempTimer = null, lastBatt = null, dragging = false;
  function ctlVal(k, live) {
    var o = ctlOv[k];
    if (o && Date.now() < o.until && !(live != null && String(live) === String(o.v))) return o.v;
    delete ctlOv[k]; return live;
  }
  function setOv(k, v) { ctlOv[k] = { v: v, until: Date.now() + 180000 }; }
  function fmtTemp(c, units) { if (c == null) return '--'; return units === 'C' ? (Math.round(c * 2) / 2).toFixed(1) + '\u00b0C' : Math.round(c * 9 / 5 + 32) + '\u00b0F'; }
  function curCar() { var cfg = getCfg(); var v = cfg && compute(cfg); return v ? v.car : null; }
  function controlsCard(car) {
    var locked = ctlVal('locked', car.locked), win = ctlVal('windowsOpen', car.windowsOpen), clim = ctlVal('climateOn', car.climateOn);
    var cmdOk = cmdAllowed();
    var tC = pendTemp != null ? pendTemp : ctlVal('tempC', car.tempC), dis = (ctlBusy || !cmdOk) ? ' disabled' : '';
    var dry = load('dryRun', false);
    var lockCls = locked === false ? ' warn' : '', lockTxt = locked == null ? 'LOCK' : (locked ? 'LOCKED' : 'UNLOCKED');
    var lockSub = locked == null ? 'state unknown' : (locked ? 'tap to unlock' : 'tap to lock');
    var ins = car.insideC != null ? 'inside ' + fmtTemp(car.insideC, car.units) + ' \u00b7 ' : '';
    var ICON_LOCK = '<svg viewBox="0 0 24 24"><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>';
    var ICON_UNLOCK = '<svg viewBox="0 0 24 24"><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 7.6-1.7"/></svg>';
    var ICON_SNOW = '<svg viewBox="0 0 24 24"><path d="M12 2v20M4.9 6.5l14.2 11M4.9 17.5l14.2-11M9 4l3 2 3-2M9 20l3-2 3 2"/></svg>';
    var r = '<div class="card ctl' + (cmdOk ? '' : ' off') + '"><div class="ctl-hd"><h3>Tesla controls</h3>' + (!cmdOk ? '<span class="dry">OFF</span>' : (dry ? '<span class="dry">DRY RUN</span>' : '')) + '</div>' +
      '<div class="ctl-row2">' +
      '<button class="cbtn big' + lockCls + '" id="cLock"' + dis + '>' + (locked === false ? ICON_UNLOCK : ICON_LOCK) + '<span><b>' + lockTxt + '</b><small>' + lockSub + '</small></span></button>' +
      '<button class="cbtn big' + (clim ? ' on' : '') + '" id="cClim"' + dis + '>' + ICON_SNOW + '<span><b>' + (clim ? 'A/C ON' : 'A/C OFF') + '</b><small>' + ins + (clim ? 'tap off' : 'tap on') + '</small></span></button></div>' +
      '<div class="ctl-row3">' +
      '<button class="cbtn' + (win ? ' warn' : '') + '" id="cVent"' + dis + '><b>VENT</b><small>' + (win ? 'OPEN NOW' : 'WINDOWS') + '</small></button>' +
      '<button class="cbtn" id="cClose"' + dis + '><b>CLOSE</b><small>' + (win === false ? 'ALL CLOSED' : 'WINDOWS') + '</small></button>' +
      '<div class="temp"><button class="cbtn sq" id="cTdn" aria-label="Cooler"' + dis + '>\u2212</button>' +
      '<div class="tv"><b>' + fmtTemp(tC, car.units) + '</b><small>' + (pendTemp != null ? 'NEW SET TEMP' : 'SET TEMP') + '</small></div>' +
      '<button class="cbtn sq" id="cTup" aria-label="Warmer"' + dis + '>+</button></div></div>' +
      '<div class="ctl-msg ' + ctlMsg.kind + '">' + (ctlMsg.kind === 'busy' ? '<span class="spin"></span>' : '') + '<span>' + esc(!cmdOk ? 'Commands are off: you did not allow TessDesk to send vehicle commands (Settings \u2192 Permissions).' : (ctlMsg.text || (dry ? 'Dry run: buttons are simulated, nothing is sent' : 'Ready'))) + '</span></div></div>';
    return r;
  }
  function confirmBox(msg, yes) {
    return new Promise(function (res) {
      var d = document.createElement('div'); d.className = 'modal';
      d.innerHTML = '<div class="mbox" role="dialog" aria-modal="true"><div class="mq">' + esc(msg) + '</div><div class="mbtns"><button class="btn ghost" id="mNo">Cancel</button><button class="btn" id="mYes">' + esc(yes || 'Yes') + '</button></div></div>';
      document.body.appendChild(d);
      function done(v) { d.remove(); res(v); }
      d.querySelector('#mNo').onclick = function () { done(false); }; d.querySelector('#mYes').onclick = function () { done(true); };
      d.onclick = function (e) { if (e.target === d) done(false); };
    });
  }
  function runCmd(name, query, busyTxt, okTxt, onOk) {
    if (ctlBusy || !cmdAllowed()) return;
    ctlBusy = true; ctlMsg = { kind: 'busy', text: busyTxt + (load('dryRun', false) ? ' (dry run)' : '') }; render();
    command(name, query).then(function (j) {
      if (onOk) onOk();
      ctlMsg = { kind: 'ok', text: '\u2713 ' + okTxt + ' \u00b7 ' + clock(nowSec()) + (j && j.dryRun ? ' (dry run, not sent)' : '') };
      if (!(j && j.dryRun)) setTimeout(function () { refresh(true); }, 6000);
    }, function (e) { ctlMsg = { kind: 'err', text: '\u2715 ' + name + ' failed: ' + String(e.message || e).slice(0, 90) }; })
      .then(function () { ctlBusy = false; if (name === 'set_temperatures') pendTemp = null; render(); });
  }
  function onLock() {
    var c = curCar(); if (!c) return; var locked = ctlVal('locked', c.locked);
    if (locked) confirmBox('Unlock your Tesla?', 'Unlock').then(function (ok) { if (ok) runCmd('unlock', {}, 'Unlocking\u2026', 'Unlocked', function () { setOv('locked', false); }); else { ctlMsg = { kind: 'idle', text: 'Unlock cancelled' }; render(); } });
    else runCmd('lock', {}, 'Locking\u2026', 'Locked', function () { setOv('locked', true); });
  }
  function onVent() { confirmBox('Vent the windows on your Tesla?', 'Vent').then(function (ok) { if (ok) runCmd('vent_windows', {}, 'Venting windows\u2026', 'Windows vented', function () { setOv('windowsOpen', true); }); else { ctlMsg = { kind: 'idle', text: 'Vent cancelled' }; render(); } }); }
  function onClose() { runCmd('close_windows', {}, 'Closing windows\u2026', 'Windows closed', function () { setOv('windowsOpen', false); }); }
  function onClim() {
    var c = curCar(); if (!c) return;
    if (ctlVal('climateOn', c.climateOn)) runCmd('stop_climate', {}, 'Turning climate off\u2026', 'Climate off', function () { setOv('climateOn', false); });
    else runCmd('start_climate', {}, 'Turning climate on\u2026', 'Climate on', function () { setOv('climateOn', true); });
  }
  function onTemp(dir) {
    var c = curCar(); if (!c) return;
    var t = pendTemp != null ? pendTemp : ctlVal('tempC', c.tempC); if (t == null) t = 20;
    var n = c.units === 'C' ? Math.round((t + 0.5 * dir) * 2) / 2 : Math.round(((Math.round(t * 9 / 5 + 32) + dir) - 32) * 5 / 9 * 10) / 10;
    n = Math.max(c.minC, Math.min(c.maxC, n)); pendTemp = n;
    ctlMsg = { kind: 'idle', text: 'Set to ' + fmtTemp(n, c.units) + ' \u00b7 sending in a moment\u2026' }; render();
    clearTimeout(tempTimer);
    tempTimer = setTimeout(function () { tempTimer = null; var txt = fmtTemp(n, c.units);
      runCmd('set_temperatures', { temperature: n.toFixed(1) }, 'Setting ' + txt + '\u2026', 'Temperature ' + txt, function () { setOv('tempC', n); }); }, 1500);
  }
  function limitLabel(p) { var mi = lastBatt && lastBatt.perPct ? ' / ' + Math.round(lastBatt.perPct * p) + ' mi' : ''; return p + '%' + mi; }
  function requestLimit(p) {
    if (!lastBatt) return;
    p = Math.max(lastBatt.min, Math.min(lastBatt.max, Math.round(p)));
    if (p === lastBatt.limit) { ctlMsg = { kind: 'idle', text: 'Charge limit stays ' + limitLabel(p) }; render(); return; }
    var lbl = limitLabel(p);
    confirmBox('Set charge limit to ' + p + '%?', 'Set ' + p + '%').then(function (ok) {
      if (!ok) { ctlMsg = { kind: 'idle', text: 'Charge limit unchanged' }; render(); return; }
      runCmd('set_charge_limit', { percent: p }, 'Setting charge limit ' + lbl + '\u2026', 'Charge limit ' + lbl, function () { setOv('limit', p); });
    });
  }
  function bindSlider() {
    var bar = document.getElementById('limBar'), th = document.getElementById('limThumb'); if (!bar || !th || !lastBatt) return;
    var cur = null;
    function pctAt(x) { var r = bar.getBoundingClientRect(); var p = Math.round((x - r.left) / r.width * 100); return Math.max(lastBatt.min, Math.min(lastBatt.max, p)); }
    function show(p) {
      cur = p; th.style.left = p + '%'; th.setAttribute('aria-valuenow', p);
      document.getElementById('dragVal').textContent = limitLabel(p);
      document.getElementById('limPct').textContent = p + '%';
      document.getElementById('limMi').textContent = lastBatt.perPct ? Math.round(lastBatt.perPct * p) + ' mi' : '';
      document.getElementById('battTop').classList.add('hidden'); document.getElementById('battDrag').classList.remove('hidden');
    }
    bar.addEventListener('pointerdown', function (e) {
      if (ctlBusy || !cmdAllowed()) return; dragging = true; th.classList.add('drag');
      try { bar.setPointerCapture(e.pointerId); } catch (x) {}
      show(pctAt(e.clientX)); e.preventDefault();
    });
    bar.addEventListener('pointermove', function (e) { if (dragging) show(pctAt(e.clientX)); });
    function end(commit) { if (!dragging) return; dragging = false; th.classList.remove('drag'); if (commit && cur != null) requestLimit(cur); else render(); }
    bar.addEventListener('pointerup', function () { end(true); });
    bar.addEventListener('pointercancel', function () { end(false); });
  }
  function row(l, sub, t, hl) {
    return '<div class="row' + (hl ? ' hl' : '') + '"><div class="l">' + esc(l) + (sub ? '<small>' + esc(sub) + '</small>' : '') + '</div>' +
      '<div class="r"><b>' + money(t.cost) + '</b><small>' + kwh(t.kwh) + '</small></div></div>';
  }
  function tireSvg(T) {
    function parts(t) { var f = t.flag || 'none', lv = f.split('-')[0], dir = f.split('-')[1] || ''; return { lv: lv, dir: dir, cls: lv === 'red' ? ' r pulse' : (lv === 'yellow' ? ' y' : (lv === 'green' ? ' g' : '')) }; }
    function lab(x, y, t, anchor) {
      var q = parts(t), bad = q.dir !== '', word = q.dir === 'high' ? 'HIGH' : 'LOW';
      var num = (t.psi == null ? '--' : (Math.round(t.psi * 10) / 10).toFixed(1));
      var txt = anchor === 'end' ? (bad ? '<tspan class="warn">' + word + '</tspan><tspan dx="5">' + num + '</tspan>' : num) : num + (bad ? '<tspan class="warn" dx="5">' + word + '</tspan>' : '');
      return '<text class="psi' + q.cls + '" x="' + x + '" y="' + y + '" text-anchor="' + anchor + '">' + txt + '</text>' +
        '<text class="unit" x="' + x + '" y="' + (y + 15) + '" text-anchor="' + anchor + '">PSI</text>';
    }
    function tire(x, y, t) { return '<rect class="tire' + parts(t).cls + '" x="' + x + '" y="' + y + '" width="16" height="40" rx="5"/>'; }
    return '<svg viewBox="0 0 320 240" role="img" aria-label="Tire pressures">' +
      // leads
      '<line class="lead" x1="86" y1="64" x2="108" y2="64"/><line class="lead" x1="212" y1="64" x2="234" y2="64"/>' +
      '<line class="lead" x1="86" y1="178" x2="108" y2="178"/><line class="lead" x1="212" y1="178" x2="234" y2="178"/>' +
      // body (top-down, front up)
      '<path class="body" d="M160 10 C 196 10 204 22 204 50 L 206 120 L 204 200 C 204 222 192 230 160 230 C 128 230 116 222 116 200 L 114 120 L 116 50 C 116 22 124 10 160 10 Z"/>' +
      '<path class="glass" d="M128 66 C 140 56 180 56 192 66 L 188 96 C 172 92 148 92 132 96 Z"/>' +
      '<path class="glass" d="M134 104 C 150 100 170 100 186 104 L 186 168 C 170 172 150 172 134 168 Z" opacity=".55"/>' +
      '<path class="glass" d="M132 180 C 148 184 172 184 188 180 L 190 204 C 172 212 148 212 130 204 Z"/>' +
      '<text class="unit" x="160" y="26" text-anchor="middle">FRONT</text>' +
      tire(108, 44, T.fl) + tire(196, 44, T.fr) + tire(108, 158, T.rl) + tire(196, 158, T.rr) +
      lab(80, 64, T.fl, 'end') + lab(240, 64, T.fr, 'start') + lab(80, 178, T.rl, 'end') + lab(240, 178, T.rr, 'start') + '</svg>';
  }

  function bind() {
    var r = document.getElementById('btnRefresh'); if (r) r.onclick = function () { refresh(true); };
    var s = document.getElementById('btnSettings'); if (s) s.onclick = function () { screen = 'settings'; render(); window.scrollTo(0, 0); };
    var on = function (id, f) { var el = document.getElementById(id); if (el) el.onclick = f; };
    on('cLock', onLock); on('cVent', onVent); on('cClose', onClose); on('cClim', onClim);
    on('cTdn', function () { onTemp(-1); }); on('cTup', function () { onTemp(1); });
    on('bRemind', openReminder);
    bindSlider();
    if (busy) setSpin(true);
  }


  // ---------- notice, permissions, getting started ----------
  function consentOk() { var c = getCfg(); return !!(c && c.consent && c.consent.agreed && c.consent.readVehicleData); }
  function cmdAllowed() { var c = getCfg(); return !!(c && c.consent && c.consent.sendCommands); }
  function noticeHtml() { return '<div class="notice"><ul>' + NOTICE.map(function (t) { return '<li>' + t + '</li>'; }).join('') + '</ul>' +
    '<a class="lnk" href="' + PRIVACY_URL + '">Full privacy &amp; disclosures page</a></div>'; }
  function helpPanel(open) {
    return '<details class="help-panel"' + (open ? ' open' : '') + '><summary>Getting started \u00b7 Don\u2019t have these yet?</summary>' +
      HELP_LINKS.map(function (l) { return '<div class="hl"><a class="hbtn" href="' + l[1] + '" target="_blank" rel="noopener">' + esc(l[0]) + '</a><span>' + esc(l[2]) + '</span></div>'; }).join('') + '</details>';
  }
  function permBoxes(c, first) {
    c = c || {};
    return (first ? '<label class="check agree"><input type="checkbox" id="pAgree"> <b>I have read this notice and I agree</b></label>' : '') +
      '<label class="check"><input type="checkbox" id="pRead" checked disabled> Allow TessDesk to read vehicle data from Tessie (required)</label>' +
      '<label class="check"><input type="checkbox" id="pCmd"' + (c.sendCommands !== false ? ' checked' : '') + '> Allow TessDesk to send vehicle commands (optional; off = controls disabled)</label>' +
      '<label class="check"><input type="checkbox" id="pRem"' + (c.reminders !== false ? ' checked' : '') + '> Allow reminders by calendar/email (optional)</label>';
  }
  function readConsent(prev) {
    var el = function (id) { return document.getElementById(id); };
    return { version: CONSENT_VERSION, agreed: true, agreedAt: (prev && prev.agreedAt) || new Date().toISOString(), updatedAt: new Date().toISOString(),
      readVehicleData: true, sendCommands: !!el('pCmd').checked, reminders: !!el('pRem').checked, via: 'phone' };
  }
  // existing users (set up before v4.1): notice first, no Tessie calls until they agree
  function renderConsent() {
    var cfg = getCfg();
    $app.innerHTML = '<div class="wrap form">' + testBanner() + '<div class="hdr"><div class="brand">TESSDESK</div></div>' +
      '<h1>Before we connect</h1><p class="lead">TessDesk v4.1 asks for your OK before it reads your car again.</p>' + noticeHtml() +
      permBoxes(cfg.consent, true) + helpPanel(false) + '<div class="msg" id="mC"></div><button class="btn" id="bAgree" disabled>Continue</button>' + footer() + '</div>';
    var a = document.getElementById('pAgree'), b = document.getElementById('bAgree');
    a.onchange = function () { b.disabled = !a.checked; };
    b.onclick = function () { if (!a.checked) return; cfg.consent = readConsent(null); save('cfg', cfg); render(); refresh(true); startTimer(); };
  }

  // ---------- "Remind me to get air" (phone: calendar alert or email draft; the page can't send anything in the background) ----------
  function tireReport() {
    var cfg = getCfg(), v = cfg && compute(cfg); if (!v) return null;
    var names = { fl: 'Front left', fr: 'Front right', rl: 'Rear left', rr: 'Rear right' }, lines = [], low = [];
    ['fl', 'fr', 'rl', 'rr'].forEach(function (k) {
      var t = v.tires[k]; if (!t || t.psi == null) return;
      var f = t.flag || 'green', lv = f.split('-')[0], dir = f.split('-')[1];
      var line = names[k] + ' (' + k.toUpperCase() + '): ' + t.psi.toFixed(1) + ' PSI' + (dir ? ' \u00b7 ' + (lv === 'red' ? 'really ' : 'a little ') + dir.toUpperCase() : '');
      lines.push(line); if (dir) low.push(k.toUpperCase() + ' ' + t.psi.toFixed(1) + ' PSI');
    });
    var rec = v.tires.recF != null ? 'Recommended: ' + Math.round(v.tires.recF) + ' PSI front / ' + Math.round(v.tires.recR != null ? v.tires.recR : v.tires.recF) + ' PSI rear (cold).' : '';
    return { low: low, lines: lines, rec: rec, title: low.length ? 'Get air: ' + low.join(', ') : 'Check tire pressure (TessDesk)' };
  }
  function icsStamp(d) { return d.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, ''); }
  function icsEsc(t) { return String(t).replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\n/g, '\\n'); }
  function buildIcs(due, rep) {
    var body = 'Reminder from TessDesk: get air in your tires.\n' + rep.lines.join('\n') + '\n' + rep.rec;
    var end = new Date(due.getTime() + 15 * 60000);
    return ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//TessDesk//Tire reminder 4.1//EN', 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH', 'BEGIN:VEVENT',
      'UID:tessdesk-' + Date.now() + '@vanwidick.github.io', 'DTSTAMP:' + icsStamp(new Date()), 'DTSTART:' + icsStamp(due), 'DTEND:' + icsStamp(end),
      'SUMMARY:' + icsEsc(rep.title), 'DESCRIPTION:' + icsEsc(body),
      'BEGIN:VALARM', 'ACTION:DISPLAY', 'DESCRIPTION:' + icsEsc(rep.title), 'TRIGGER:PT0M', 'END:VALARM', 'END:VEVENT', 'END:VCALENDAR'].join('\r\n');
  }
  function gcalUrl(due, rep) {
    var end = new Date(due.getTime() + 15 * 60000);
    return 'https://calendar.google.com/calendar/render?action=TEMPLATE&text=' + encodeURIComponent(rep.title) + '&dates=' + icsStamp(due) + '/' + icsStamp(end) +
      '&details=' + encodeURIComponent('Reminder from TessDesk: get air in your tires.\n' + rep.lines.join('\n') + '\n' + rep.rec);
  }
  function mailtoUrl(rep) {
    var cfg = getCfg() || {};
    return 'mailto:' + encodeURIComponent(cfg.remindEmail || '') + '?subject=' + encodeURIComponent('TessDesk: ' + rep.title) +
      '&body=' + encodeURIComponent('Reminder from TessDesk: get air in your tires.\n\n' + rep.lines.join('\n') + '\n' + rep.rec + '\n');
  }
  function openReminder() {
    var rep = tireReport(); if (!rep) return;
    var d = document.createElement('div'); d.className = 'modal';
    function close() { d.remove(); }
    function step1() {
      d.innerHTML = '<div class="mbox rem" role="dialog" aria-modal="true"><div class="mq">Remind me to get air in\u2026</div>' +
        '<div class="rl">' + rep.lines.map(esc).join('<br>') + '</div>' +
        '<div class="hrs">' + [1, 2, 4, 8].map(function (x) { return '<button class="btn ghost h" data-h="' + x + '">' + x + ' hr' + (x > 1 ? 's' : '') + '</button>'; }).join('') + '</div>' +
        '<div class="inline cust"><input type="number" id="rCust" min="0.25" max="168" step="0.25" value="3" aria-label="Custom hours"><button class="btn ghost" id="rSet">Set custom hours</button></div>' +
        '<div class="mbtns"><button class="btn ghost" id="rNo">Cancel</button></div></div>';
      Array.prototype.forEach.call(d.querySelectorAll('.h'), function (b) { b.onclick = function () { step2(+b.getAttribute('data-h')); }; });
      d.querySelector('#rSet').onclick = function () { var x = +d.querySelector('#rCust').value; if (x > 0 && x <= 168) step2(x); };
      d.querySelector('#rNo').onclick = close;
    }
    function step2(hrs) {
      var due = new Date(Date.now() + Math.round(hrs * 60) * 60000), when = clock(Math.floor(due.getTime() / 1000));
      var ics = buildIcs(due, rep), ios = /iPhone|iPad|iPod/.test(navigator.userAgent);
      var href = 'data:text/calendar;charset=utf-8,' + encodeURIComponent(ics);
      d.innerHTML = '<div class="mbox rem" role="dialog" aria-modal="true"><div class="mq">Reminder at ' + esc(when) + '</div>' +
        '<a class="btn" id="rIcs" href="' + href + '"' + (ios ? '' : ' download="tessdesk-tire-reminder.ics"') + '>Add phone reminder</a>' +
        '<div class="rn">Adds a 15-minute calendar event at ' + esc(when) + ' with an alert at that time. Your phone\u2019s Calendar app gives the notification, even while you drive. ' + (ios ? 'iPhone: tap \u201cAdd to Calendar\u201d on the next screen.' : 'Android: open the downloaded file with your calendar app.') + '</div>' +
        '<a class="btn ghost" id="rG" href="' + gcalUrl(due, rep) + '" target="_blank" rel="noopener">Google Calendar</a>' +
        '<div class="rn">Opens Google Calendar with the event filled in. Tap Save. The alert uses your Google Calendar\u2019s default notification (you can change it on the event).</div>' +
        '<a class="btn ghost" id="rM" href="' + mailtoUrl(rep) + '">Email draft</a>' +
        '<div class="rn">Opens your mail app with a draft' + ((getCfg() || {}).remindEmail ? ' to ' + esc(getCfg().remindEmail) : '') + '. It goes out when you tap Send (now). It is <b>not</b> scheduled.</div>' +
        '<div class="rn muted">The TessDesk web app can\u2019t send anything by itself in the background. These options hand the reminder to your calendar or mail app. The desktop widget can email or text you at the time you pick.</div>' +
        '<div class="mbtns"><button class="btn ghost" id="rBack">Back</button><button class="btn ghost" id="rDone">Done</button></div></div>';
      d.querySelector('#rBack').onclick = step1; d.querySelector('#rDone').onclick = close;
      window.TessDesk.lastReminder = { hours: hrs, due: due.toISOString(), ics: ics, gcal: gcalUrl(due, rep), mailto: mailtoUrl(rep) };
    }
    d.onclick = function (e) { if (e.target === d) close(); };
    document.body.appendChild(d); step1();
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
      (first ? '<div class="sect">Notice &amp; permissions</div>' + noticeHtml() + permBoxes(null, true) : '') +
      '<div class="field"><label for="fName">Your name</label><input type="text" id="fName" autocomplete="given-name" value="' + esc(cfg.name) + '" placeholder="Van"></div>' +
      '<div class="field"><label for="fToken">Tessie API token</label><div class="inline"><input type="password" id="fToken" autocomplete="off" autocapitalize="off" spellcheck="false" value="' + esc(cfg.token) + '" placeholder="Paste token">' +
      '<button class="btn ghost" id="bShow" type="button" style="flex:0 0 72px;margin:0">Show</button></div>' +
      '<div class="help">Tessie app \u2192 Settings \u2192 API. Copy the access token and paste it here. It stays on this phone and is sent only to api.tessie.com.</div>' + helpPanel(first) + '</div>' +
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
      '<div class="sect">Reminders</div>' +
      '<div class="field"><label for="fRemEmail">Email for reminder drafts (optional)</label><input type="email" id="fRemEmail" autocomplete="email" value="' + esc(cfg.remindEmail || '') + '" placeholder="you@gmail.com"><div class="help">Used as the To: address in the \u201cEmail draft\u201d option. Calendar alerts need nothing here.</div></div>' +
      (first ? '' : '<div class="sect">Permissions</div>' + permBoxes(cfg.consent, false) +
        '<div class="help">You agreed to the notice ' + esc(cfg.consent && cfg.consent.agreedAt ? new Date(cfg.consent.agreedAt).toLocaleString() : '') + '.</div><details class="help-panel"><summary>Review the notice</summary>' + noticeHtml() + '</details>') +
      (VARIANT === 'test' ? '<label class="check"><input type="checkbox" id="fReset"' + (isTestReset ? ' checked' : '') + '> Reset data on every launch</label>' : '') +
      '<details style="margin:10px 0;color:var(--muted);font-size:13px"><summary>Advanced</summary><div class="field"><label>API address</label><input type="url" id="fApi" value="' + esc(cfg.apiBase || DEFAULT_API) + '"><div class="help">Leave as https://api.tessie.com unless you set up a proxy.</div></div>' +
      '<label class="check"><input type="checkbox" id="fDry"' + (load('dryRun', false) ? ' checked' : '') + '> Dry run Tesla controls (simulate, send nothing)</label></details>' +
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
      if (first && !el('pAgree').checked) { m.className = 'msg err'; m.textContent = 'Please read the notice and check \u201cI agree\u201d.'; return; }
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
                    apiBase: (el('fApi').value.trim() || DEFAULT_API), remindEmail: el('fRemEmail').value.trim(), consent: readConsent(cfg.consent) });
      save('dryRun', el('fDry').checked);
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
  window.TessDesk = { cmdLog: cmdLog, tireFlag: tireFlag, buildIcs: buildIcs, priceSpan: function (t0, t1, wall) { var c = getCfg(); return priceSpan(c ? c.rates : PRESETS.pso, t0, t1, wall); }, PRESETS: PRESETS, ctEpoch: ctEpoch, refresh: refresh };

  render();
  if (getCfg()) { refresh(false); startTimer(); }
})();
