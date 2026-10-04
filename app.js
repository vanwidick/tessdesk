/* TessDesk mobile v4.3 (PWA). Design by Van.
   Everything (name, Tessie token, vehicle, rates) is stored in localStorage on this device only. */
(function () {
  'use strict';
  var CFG = window.TD_CONFIG || {};
  var VARIANT = CFG.variant || 'main';
  var P = CFG.storagePrefix || 'td:';
  var VERSION = 'v4.3.10';
  var VERSION_DATE = 'Oct 3, 2026';
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
    'It uses your Tessie API token to <b>read vehicle data</b> (location, battery, charging, tires, lock and climate state) and, only when you press a control, to <b>send commands</b> (lock/unlock, windows, climate, heat, defrost, seat heat, charging, charge limit and amps).',
    'Your token and settings are stored <b>only on this phone</b> (browser local storage) and the token is sent <b>only to api.tessie.com</b>.',
    'Reminders use your own calendar or email app (and, on the desktop, your own email account or carrier gateway). Nothing goes to the TessDesk author.',
    'Alexa announcements (optional, Settings \u2192 Connected apps): if you set up Voice Monkey and agree, the <b>text of each announcement</b> is sent to Voice Monkey and Amazon so your Echo can speak it.',
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
             socStart: c.starting_battery, socEnd: c.ending_battery, segs: [[+c.started_at, +c.ended_at, added]],
             home: c.saved_location || c.location || null, fast: !!(c.is_supercharger || c.is_fast_charger || (c.max_charger_power > 25)),
             paid: (c.is_supercharger || c.is_fast_charger || (c.max_charger_power > 25)) && c.cost > 0 ? +c.cost : null };
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
  // v4.3.3: a Tessie session that ended just before the live one is the SAME kWh only if the live counter carried it.
  // When the counter reset (re-plugged / restarted), the earlier session is its own energy and is kept.
  function dupOfLive(c, lv) { return overlaps(c, lv) && !(lv.ownOnly && c.end <= lv.start + 90); }

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
    var q = 'wait_for_completion=' + (query && query.wait_for_completion !== undefined ? query.wait_for_completion : 'true'); Object.keys(query || {}).forEach(function (k) { if (k === 'wait_for_completion') return; q += '&' + k + '=' + encodeURIComponent(query[k]); });
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
  var busy = false, lastErr = null, timer = null, drivesErr = null;

  function trackLive(cfg, st) {
    var cs = st.charge_state || {}, t = nowSec();
    var charging = cs.charging_state === 'Charging';
    var added = cs.charge_energy_added != null ? +cs.charge_energy_added : 0;
    if (charging) {
      var cont = live && !live.done && added >= live.lastAdded - 0.05 && (t - live.lastAt) < 14 * 3600;
      // v4.3.3: the car's charge_energy_added keeps running across a pause on the same plug-in and resets on a new plug-in.
      // Resumed with the counter still running = same session (only new kWh added), however long the pause (up to 12 h).
      if (!cont && live && live.done && added >= live.lastAdded - 0.05 && added > 0 && (t - live.lastAt) < 12 * 3600) cont = true;
      if (!cont) {
        var pw = chargerKw(cs) || 0, est = t;
        if (pw > 0.3) est = t - Math.round(wallOf(cfg, added) / pw * 3600);
        var lastEnd = 0; (cache.charges || []).forEach(function (c) { if (c.ended_at && c.ended_at > lastEnd) lastEnd = c.ended_at; });
        // v4.3.3: first seen mid-charge right after a Tessie-recorded part: did the counter carry that part (same plug-in) or reset?
        var prevC = null; (cache.charges || []).forEach(function (c) { if (c.ended_at === lastEnd) prevC = c; });
        var reset = true;
        if (prevC && added > 0.3 && t - lastEnd < 3600) {
          var pk = +prevC.energy_added || 0, since = Math.max(0, t - lastEnd) / 3600 * (pw || 0);
          if (pk >= 0.1 && added >= pk - 0.15 && Math.abs(added - (pk + since)) < Math.abs(added - since)) reset = false;
        } else if (prevC && added > 0.3 && pw > 0.3 && (+prevC.energy_added || 0) >= 0.3 && est < lastEnd - 600) reset = false; // counter older than the gap
        est = Math.max(est, lastEnd + 60, t - 20 * 3600); if (est > t - 60) est = t - 60;
        var pack = cs.energy_remaining && cs.battery_level ? cs.energy_remaining / (cs.battery_level / 100) : 75;
        live = { start: est, socStart: Math.max(0, Math.round(cs.battery_level - added / pack * 100)), lastAdded: added, lastAt: t,
                 segs: added > 0 ? [[est, t, added]] : [], done: false, addedAtStart: added, ownOnly: reset, prevEnd: lastEnd || null };
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
    return { src: 'live', start: live.start, end: live.lastAt, added: live.lastAdded, segs: live.segs, socStart: live.socStart, done: live.done, ownOnly: live.ownOnly !== false, addedAtStart: live.addedAtStart };
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
      var needDrives = force || !cache.drives || (t - (cache.drivesAt || 0)) > CHARGES_EVERY_S;
      var pd = !needDrives ? null : api('/' + cfg.vin + '/drives?from=' + (t - 30 * 86400) + '&to=' + t + '&distance_format=mi&format=json&limit=10')
        .then(function (r) { cache.drives = (r && r.results) || []; cache.drivesAt = t; drivesErr = null; }, function (e) { drivesErr = String(e.message || e); cache.drivesAt = t - CHARGES_EVERY_S + 300; });
      if (!needCharges) return pd;
      return api('/' + cfg.vin + '/charges?from=' + (t - 31 * 86400) + '&to=' + t + '&distance_format=mi&format=json')
        .then(function (r) { cache.charges = (r && r.results) || []; cache.chargesAt = t; return pd; });
    }).then(function () {
      lastErr = null; trackLive(cfg, cache.state); save('cache', cache);
    }).catch(function (e) { lastErr = e; }).then(function () { busy = false; setSpin(false); try { render(); } catch (e) { console.error(e); } if (getCfg() && consentOk()) scheduleNext(nextDelay() * 1000); });
  }

  // ---------- v4.3.2: LAST CHARGE = the whole 11 PM -> 11 AM home window ----------
  // Every home session in one overnight window is ONE charge (unplug 30 min, plug back in: same charge). Each part keeps
  // its own per-minute pricing, so kWh after 6 AM are priced at the day rate.
  function winStartOf(cfg, sec) {
    var sh = cfg.rates.onStart != null ? cfg.rates.onStart : 23, c = ct(sec);
    if (c.h >= sh) return ctEpoch(c.y, c.mo, c.d, sh);
    if (c.h < 11) { var b = ct(sec - 13 * 3600); return ctEpoch(b.y, b.mo, b.d, sh); }
    return null;
  }
  function homeWindow(cfg, sessions) {
    var cnt = {}, best = null;
    sessions.forEach(function (s) { if (s.home && !s.fast) { cnt[s.home] = (cnt[s.home] || 0) + 1; if (!best || cnt[s.home] > cnt[best]) best = s.home; } });
    var items = [];
    sessions.forEach(function (s) {
      if (s.fast || (s.home && best && s.home !== best)) return;
      var w = winStartOf(cfg, s.start); if (w == null) w = winStartOf(cfg, s.end);
      if (w != null) items.push({ w: w, s: s });
    });
    if (!items.length) return null;
    var wl = Math.max.apply(null, items.map(function (i) { return i.w; }));
    var parts = items.filter(function (i) { return i.w === wl; }).map(function (i) { return i.s; }).sort(function (a, b) { return a.start - b.start; });
    var cost = 0, k = 0, wall = 0, a6 = 0, a6c = 0, offEnd = wl + ((24 - (cfg.rates.onStart != null ? cfg.rates.onStart : 23)) + (cfg.rates.onEnd != null ? cfg.rates.onEnd : 6)) * 3600;
    parts.forEach(function (s) { var r = sessionCost(cfg, s); cost += r.cost; k += (s.added || 0); wall += r.wall; var q = sessionCost(cfg, s, offEnd, wl + 12 * 3600); a6 += q.kwh; a6c += q.cost; });
    var first = parts[0], last = parts[parts.length - 1];
    return { src: 'window', start: first.start, end: last.end, added: k, socStart: first.socStart, socEnd: last.socEnd, parts: parts, sessions: parts.length,
      windowStart: wl, home: best, kwhAfter6: a6, costAfter6: a6c, cost: { cost: cost, kwh: k, wall: wall } };
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
      var dup = charges.some(function (c) { return dupOfLive(c, lv); });
      if (!dup || (charging && !lv.done)) {
        sessions = charges.filter(function (c) { return !dupOfLive(c, lv); }); sessions.unshift(lv);
      }
    }
    // hero
    var hero;
    if (lv && cs.fast_charger_present && charging) lv.fast = true;
    var agg = homeWindow(cfg, sessions);
    if (charging && lv && !lv.done) { hero = lv; if (agg && agg.parts.indexOf(lv) >= 0 && agg.parts.length > 1) hero = agg; }
    else {
      hero = sessions.filter(function (s) { return (s.added || 0) >= 0.1; })[0] || sessions[0] || null;
      if (agg && (!hero || agg.parts.indexOf(hero) >= 0 || hero.start <= agg.end)) hero = agg;
    }
    var hc = hero ? (hero.src === 'window' ? hero.cost : sessionCost(cfg, hero)) : null;

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
    // v4.3.10 shared rule (same as the desktop): whole charges that STARTED in the period; a Supercharger counts what Tessie says was paid.
    // (Before, the phone counted only the minutes inside the 7 / 30 days and the desktop counted whole charges, so a charge that
    // crossed the cut-off made the two differ by a few cents.)
    function rolling(from) {
      var cost = 0, k = 0, n = 0;
      sessions.forEach(function (s) { if (s.start < from) return; cost += s.paid > 0 ? s.paid : sessionCost(cfg, s).cost; k += (s.added || 0); n++; });
      return { cost: cost, kwh: k, n: n };
    }
    var d7 = rolling(t - 7 * 86400), d30 = rolling(t - 30 * 86400);

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
      limitMin: cs.charge_limit_soc_min != null ? cs.charge_limit_soc_min : 50, limitMax: cs.charge_limit_soc_max != null ? cs.charge_limit_soc_max : 100,
      chargingState: cs.charging_state || '', ampsReq: cs.charge_current_request, ampsMax: cs.charge_current_request_max, ampsNow: cs.charger_actual_current,
      seats: { fl: cl.seat_heater_left, fr: cl.seat_heater_right, rl: cl.seat_heater_rear_left, rc: cl.seat_heater_rear_center, rr: cl.seat_heater_rear_right },
      rearSeats: (st.vehicle_config || {}).rear_seat_heaters,
      wheelOn: cl.steering_wheel_heater != null ? (!!cl.steering_wheel_heater || cl.steering_wheel_heat_level > 0) : null,
      defrostOn: (cl.defrost_mode != null || cl.is_front_defroster_on != null) ? (cl.defrost_mode > 0 || !!cl.is_front_defroster_on) : null,
      cop: cl.cabin_overheat_protection || null, copFanOnly: !!cl.supports_fan_only_cabin_overheat_protection, copAllowed: cl.allow_cabin_overheat_protection,
      windows: { fd: vs.fd_window, fp: vs.fp_window, rd: vs.rd_window, rp: vs.rp_window },
      trunkOpen: vs.rt != null ? +vs.rt !== 0 : null, sentry: vs.sentry_mode != null ? !!vs.sentry_mode : null };
    return {
      charging: charging, state: st, cs: cs, hero: hero, heroCost: hc, win: agg,
      kw: charging ? chargerKw(cs) : null, toFull: charging ? fmtMins(cs.minutes_to_full_charge) : null,
      night: night, nightLabel: label, nightStart: w0, d7: d7, d30: d30,
      soc: soc, limit: limit, socStart: socStart, range: range, rangeKind: rangeKind, car: car,
      tires: { fl: tire('fl', recF), fr: tire('fr', recF), rl: tire('rl', recR), rr: tire('rr', recR), recF: recF, recR: recR, asOf: vs.timestamp ? Math.floor(vs.timestamp / 1000) : (cs.timestamp ? Math.floor(cs.timestamp / 1000) : null) },
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
  // v4.3.2 whole-window glow: red = not plugged in, solid green = plugged in (complete / limit reached / stopped), slow green pulse = charging
  function glowState() {
    if (window.__glowForce) return window.__glowForce;
    var s = cache && cache.state, cs = s && s.charge_state;
    var st = cs ? ctlVal('chargingState', cs.charging_state) : null;
    if (st === 'Charging' || st === 'Starting') return 'pulse';
    if (st && st !== 'Disconnected') return 'green';
    return 'red';
  }
  function applyTheme() {
    var tessie = true, g = glowState(), red = g === 'red';
    document.body.classList.toggle('tessie', tessie);
    document.body.classList.toggle('idle', tessie && red);
    document.body.classList.toggle('glow-red', g === 'red'); document.body.classList.toggle('glow-green', g === 'green'); document.body.classList.toggle('glow-pulse', g === 'pulse');
    var m = document.querySelector('meta[name=theme-color]');
    if (m) m.setAttribute('content', tessie ? (!red ? '#081426' : '#170a0d') : '#0b0b0b');
  }
  function setSpin(on) { var b = document.getElementById('btnRefresh'); if (b) b.classList.toggle('spin', on); }
  var screen = 'main';

  function footer() {
    return '<div class="foot"><div class="dbv">DESIGN BY <span>VAN</span></div><div class="dbv-bar"></div>' +
      '<div class="foot-links"><a class="ver" href="' + CHANGELOG_URL + '" title="What\u2019s new">' + VERSION + ' \u00b7 ' + VERSION_DATE + (VARIANT === 'test' ? ' \u00b7 TEST' : '') + '</a>' +
      '<span class="dot">\u00b7</span><a class="ver about" href="' + PRIVACY_URL + '" title="About TessDesk, privacy and permissions">About / Privacy</a>' +
      '<span class="dot">\u00b7</span><a class="ver share" href="#" id="shareLink" title="Share the TessDesk link (never your token)">Share</a></div></div>';
  }
  // ---------- v4.3.7: SHARE (links only; the app that opens does the sending, never TessDesk) ----------
  var SHARE = { phone: 'https://vanwidick.github.io/tessdesk/', download: 'https://vanwidick.github.io/tessdesk/download.html',
    subject: 'TessDesk: live Tesla charging cost' };
  function shareText() { return 'TessDesk shows what your Tesla\u2019s charging costs, live (it works with your Tessie account).\nPhone: ' + SHARE.phone + '\nWindows: ' + SHARE.download; }
  var shareLog = [];
  function shareOpen(kind, url) { shareLog.push({ kind: kind, url: url }); if (window.__tdNoOpen) return; location.href = url; }
  function shareCopy() {
    var done = function (ok) { shareMsg(ok ? 'Link copied' : 'Could not copy'); };
    try { navigator.clipboard.writeText(SHARE.phone).then(function () { done(true); }, function () { done(false); }); } catch (e) { done(false); }
    shareLog.push({ kind: 'copy', url: SHARE.phone });
  }
  function shareMsg(t) { var m = document.getElementById('shMsg'); if (m) m.textContent = t; }
  function showShare() {
    var d = document.createElement('div'); d.className = 'modal';
    d.innerHTML = '<div class="mbox share-box" role="dialog" aria-modal="true"><div class="mq">Share TessDesk</div>' +
      '<div class="msub">Only the TessDesk links are shared, never your token. Nothing is sent until you press send in the app that opens.</div>' +
      '<div class="share-grid">' + (navigator.share ? '<button class="btn" id="shNative">Share\u2026</button>' : '') +
      '<button class="btn ghost" id="shMessenger">Messenger</button><button class="btn ghost" id="shText">Text</button>' +
      '<button class="btn ghost" id="shEmail">Email</button><button class="btn ghost" id="shCopy">Copy link</button></div>' +
      '<div class="msub" id="shMsg"></div><div class="mbtns"><button class="btn ghost" id="shClose">Close</button></div></div>';
    document.body.appendChild(d);
    var close = function () { if (d.parentNode) d.parentNode.removeChild(d); };
    var q = function (id) { return d.querySelector('#' + id); };
    if (q('shNative')) q('shNative').onclick = function () { shareLog.push({ kind: 'native', url: SHARE.phone }); if (window.__tdNoOpen) return; navigator.share({ title: 'TessDesk', text: shareText(), url: SHARE.phone }).then(close, function () {}); };
    q('shMessenger').onclick = function () { shareOpen('messenger', 'fb-messenger://share/?link=' + encodeURIComponent(SHARE.phone)); };
    q('shText').onclick = function () { shareOpen('text', 'sms:?&body=' + encodeURIComponent(shareText())); };
    q('shEmail').onclick = function () { shareOpen('email', 'mailto:?subject=' + encodeURIComponent(SHARE.subject) + '&body=' + encodeURIComponent(shareText())); };
    q('shCopy').onclick = shareCopy;
    q('shClose').onclick = close; d.onclick = function (e) { if (e.target === d) close(); };
  }
  document.addEventListener('click', function (e) { var t = e.target; if (t && t.id === 'shareLink') { e.preventDefault(); showShare(); } });
  // ---------- v4.3.3: new-version check (version.json on this site; no data is sent) ----------
  var upd = { latest: null, checkedAt: 0, info: null };
  function verGt(a, b) { a = String(a || '').replace(/^v/, '').split('.'); b = String(b || '').replace(/^v/, '').split('.'); for (var i = 0; i < Math.max(a.length, b.length); i++) { var x = +a[i] || 0, y = +b[i] || 0; if (x !== y) return x > y; } return false; }
  function checkUpdate(force) {
    if (VARIANT === 'test' && !force) return;
    if (!force && Date.now() - upd.checkedAt < 6 * 3600 * 1000) return;
    upd.checkedAt = Date.now();
    fetch('version.json?t=' + Date.now(), { cache: 'no-store' }).then(function (r) { return r.ok ? r.json() : null; }).then(function (j) {
      if (!j) return; var v = (j.phone && j.phone.version) || j.version; upd.info = j;
      var was = upd.latest; upd.latest = verGt(v, VERSION) ? String(v).replace(/^v/, '') : null;
      if (was !== upd.latest) render();
    }).catch(function () {});
  }
  function updBanner() { return upd.latest ? '<button class="upd-banner" id="btnUpdApp" type="button"><b>New version, tap to refresh</b><small>v' + esc(upd.latest) + ' is out \u00b7 you have ' + esc(VERSION) + '</small></button>' : ''; }
  function applyUpdate() {
    window.__tdUpdTapped = (window.__tdUpdTapped || 0) + 1;
    var el = document.getElementById('btnUpdApp'); if (el) el.querySelector('b').textContent = 'Refreshing\u2026';
    var done = function () { var u = location.href.split('#')[0].replace(/[?&]v=\d+/, ''); location.replace(u + (u.indexOf('?') >= 0 ? '&' : '?') + 'v=' + Date.now()); };
    var p = (window.caches ? caches.keys().then(function (ks) { return Promise.all(ks.filter(function (k) { return k.indexOf('tessdesk-v') === 0; }).map(function (k) { return caches.delete(k); })); }) : Promise.resolve())
      .then(function () { return navigator.serviceWorker && navigator.serviceWorker.getRegistration ? navigator.serviceWorker.getRegistration().then(function (r) { return r && r.update(); }) : null; })
      .catch(function () {});
    Promise.race([p, new Promise(function (r) { setTimeout(r, 4000); })]).then(done);
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
    else if (v) note = '<span class="note upd" id="updAge" data-t="' + v.updated + '">' + updText(v.updated) + '</span>';
    else note = '<span class="note">Loading\u2026</span>';

    var h = '<div class="wrap">' + testBanner() + updBanner() +
      '<div class="hdr"><div class="brand">TESSDESK</div><div class="who">' + layoutChip() + 'Logged in as <b>' + esc(cfg.name) + '</b></div></div>' +
      '<div class="toolbar">' + note + '<div class="tools">' + camChip() + alexaChip() + '<button class="icon-btn" id="btnRefresh" aria-label="Refresh">' + ICON_REFRESH +
      '</button><button class="icon-btn" id="btnSettings" aria-label="Settings">' + ICON_GEAR + '</button></div></div>' +
      (camOn() ? '<div id="camSlot"></div>' : '');  // v4.3.9: camera panel sits at the top, above the charging amount

    if (!v) { h += '<div class="hero"><div class="money red">$--.--</div><div class="sub">Waiting for Tessie\u2026</div></div>' + footer() + '</div>'; $app.innerHTML = h; bind(); return; }

    var col = (v.charging || glowState() !== 'red') ? 'green' : 'red';
    var hc = v.heroCost, hero = v.hero;
    var rate = hc ? cents(hc.cost, hc.wall) : null;
    var meta = '';
    if (hero) {
      meta = kwh(hero.added) + ' added \u00b7 ' + kwh(hc.wall) + ' from wall';
      if (!v.charging) meta += '<br>' + esc(dayLabel(hero.start)) + ' ' + clock(hero.start) + ' \u2192 ' + (sameDay(hero.start, hero.end) ? '' : esc(dayLabel(hero.end)) + ' ') + clock(hero.end);
    }
    h += '<div class="hero"><span class="badge' + (v.charging ? ' on' : '') + '">' + (v.charging ? '\u25cf CHARGING' : esc((v.cs.charging_state || 'IDLE').toUpperCase())) + '</span>' +
      '<div class="money ' + col + '">' + (hc ? money(hc.cost) : '$--.--') + '</div>' +
      '<div class="sub">' + (v.charging ? 'This charge' : 'Last charge') + (hero && hero.src === 'window' && hero.sessions > 1 ? ' \u00b7 ' + hero.sessions + ' sessions since ' + clock(hero.start) : '') + (rate ? ' \u00b7 ' + rate : '') + '</div>' +
      '<div class="meta">' + meta + '</div></div>';
    // v4.3: RATE STATUS (peak/day pill + Stop, off-peak pill, or a neutral line)
    h += peakBanner(rateStatus(v, cfg));
    // v4.2: money rows right under the hero, compact
    var nightSub = v.nightLabel === 'Tonight' ? 'since ' + clock(v.nightStart) : dayLabel(v.nightStart) + ', 11 PM \u2013 11 AM';
    h += '<div class="card rows compact">' +
      row(v.nightLabel, nightSub, v.night, true) + sessionsBlock(cfg, v.win) + row('Last 7 days', null, v.d7) + row('Last 30 days', null, v.d30) + totBtn() + '</div>';

    // battery: big % + range, 0-100% bar (ball = now, tick = where this charge started), draggable LIMIT handle
    var a = v.socStart, b = ctlVal('limit', v.limit), s = v.soc;
    if (a == null) a = s; if (s != null && a > s) a = s;
    var perPct = (v.range > 0 && s > 0) ? v.range / s : null;
    lastBatt = { perPct: perPct, limit: b, min: v.car.limitMin, max: v.car.limitMax };
    var stTxt = v.charging ? 'CHARGING \u2192 ' + b + '%' : friendlyState(v.cs.charging_state).toUpperCase();
    h += '<div class="card batt"><div class="batt-hd"><h3>Battery</h3><span class="bstate' + (v.charging ? ' on' : '') + '">' + esc(stTxt) + '</span></div>' +
      '<div class="batt-main"><div class="batt-left">' +
      '<div class="batt-top" id="battTop"><span class="pct">' + (s != null ? s + '%' : '--') + '</span>' +
      (v.range > 0 ? '<span class="rng"><b>' + Math.round(v.range) + ' mi</b><small>' + esc(v.rangeKind) + '</small></span>' : '') + '</div>' +
      '<div class="batt-drag hidden" id="battDrag"><small>SET LIMIT</small><span id="dragVal"></span></div>' +
      '<div class="bar" id="limBar"><div class="track"></div>' +
      '<div class="fill base ' + col + '-bg" style="width:' + (a || 0) + '%"></div>' +
      '<div class="fill add ' + col + '-bg" style="left:' + (a || 0) + '%;width:' + Math.max(0, (s || 0) - (a || 0)) + '%"></div>' +
      '<div class="tick" style="left:' + (a || 0) + '%"></div>' +
      '<div class="ball ' + col + '-bg' + (v.charging ? ' pulse' : '') + '" style="left:' + (s || 0) + '%">' + (s != null ? s : '') + '</div>' +
      (b != null ? '<div class="limmark" style="left:' + b + '%"></div>' : '') + '</div>' +
      '<div class="fl-labels"><div><small>FROM</small><span class="mi">' + miles(perPct, a) + '</span><b>' + (a != null ? a + '%' : '--') + '</b></div>' +
      '<div class="r"><small>LIMIT</small><span class="mi" id="limMi">' + miles(perPct, b) + '</span><b id="limPct">' + (b != null ? b + '%' : '--') + '</b></div></div>' +
      '</div>' + vSlider(b, col, v.car, perPct) + '</div>' +
      ampsAndCharge(v.car, col) + '</div>';

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
    var rec = v.tires.recF == null ? '' : (v.tires.recR != null && Math.abs(v.tires.recR - v.tires.recF) >= 0.5 ? 'Recommended ' + Math.round(v.tires.recF) + ' PSI front \u00b7 ' + Math.round(v.tires.recR) + ' PSI rear' : 'Recommended ' + Math.round(v.tires.recF) + ' PSI (all four)');
    h += controlsCard(v.car);
    // v4.3.2: HEATED SEATS above the tires
    h += seatsCard(v.car);
    var remOk = !!(cfg.consent && cfg.consent.reminders);
    h += '<div class="card tires"><div class="sec-hd"><h3>Tires</h3>' + (v.tires.asOf ? '<span class="pill">Updated ' + clock(v.tires.asOf) + ' \u00b7 ' + monDay(v.tires.asOf) + '</span>' : '') + '</div>' +
      (rec ? '<div class="recline">' + rec + '</div>' : '') + tireSvg(v.tires) +
      '<button class="cbtn remind" id="bRemind"' + (remOk ? '' : ' disabled') + '><b>REMIND ME TO GET AIR</b><small>' + (remOk ? 'calendar alert, text, email or Alexa' : 'reminders are off (Settings)') + '</small></button>' +
      '<button class="linkbtn" id="bRemSetup" type="button">Setup: how reminders reach you</button></div>';
    // v4.3.3: DRIVES after the tires
    h += drivesCard(cfg);

    h += footer() + '</div>';
    $app.innerHTML = h; bind(); fitCompact();
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
      '<div class="ctl-row2 three">' +
      '<button class="cbtn big' + lockCls + '" id="cLock"' + dis + '>' + (locked === false ? ICON_UNLOCK : ICON_LOCK) + '<span><b>' + lockTxt + '</b><small>' + lockSub + '</small></span></button>' +
      '<div class="cbtn flash' + (flash.running ? ' running' : '') + '" id="cFlashBox"><b>FLASH LIGHTS</b><div class="fl-row">' +
      '<input id="cFlashN" type="number" inputmode="numeric" min="1" max="20" step="1" value="' + flash.n + '" aria-label="How many flashes (1-20)"' + (flash.running || dis ? ' disabled' : '') + '>' +
      '<input id="cFlashP" class="fl-p" type="number" inputmode="decimal" min="1" max="30" step="0.5" value="' + flash.pause.toFixed(1) + '" aria-label="Pause between flashes, seconds (1-30)" title="Pause between flashes, seconds (1-30, 0.5 s steps). Under 3 s each flash is sent without waiting for the car."' + (flash.running || dis ? ' disabled' : '') + '>' +
      '<button class="fl-go" id="cFlash"' + (flash.running ? '' : dis) + '>' + (flash.running ? 'STOP' : 'FLASH') + '</button></div>' +
      '<small>' + (flash.running ? 'Flashing ' + Math.max(1, flash.done) + ' of ' + flash.total + (flashGap() !== null ? ' \u00b7 ~' + flashGap().toFixed(1) + 's apart' : '') : 'flashes \u00b7 pause s') + '</small></div>' +
      '<button class="cbtn big' + (clim ? ' on' : '') + '" id="cClim"' + dis + '>' + ICON_SNOW + '<span><b>' + (clim ? (heatOn(car) ? 'CLIMATE ON' : 'A/C ON') : 'A/C OFF') + '</b><small>' + ins + (clim ? 'tap off' : 'tap on') + '</small></span></button></div>' +
      (flashStats() ? '<div class="fl-stats" id="cFlashStats" title="Flash lights: response time of each flash request (sent until Tessie answered), average, and the measured gap between successful flashes">' + flashStats() + '</div>' : '') +
      climateRow(car, dis) +
      '<div class="ctl-row3">' +
      '<button class="cbtn' + (win ? ' state' : '') + '" id="cVent"' + dis + '><b>VENT</b><small>' + (win ? 'VENTED / OPEN' : 'WINDOWS') + '</small></button>' +
      '<button class="cbtn' + (win === false ? ' state' : '') + '" id="cClose"' + dis + '><b>CLOSE</b><small>' + (win === false ? 'ALL CLOSED' : 'WINDOWS') + '</small></button>' +
      '<div class="temp"><button class="cbtn sq" id="cTdn" aria-label="Cooler"' + dis + '>\u2212</button>' +
      '<div class="tv"><b>' + fmtTemp(tC, car.units) + '</b><small>' + (pendTemp != null ? 'NEW SET TEMP' : 'SET TEMP') + '</small></div>' +
      '<button class="cbtn sq" id="cTup" aria-label="Warmer"' + dis + '>+</button></div></div>' +
      trunkSentryRow(car, dis) +
      '<div class="ann-row"><button class="cbtn ann" id="cAnnounce"><b>🔊 ANNOUNCE ON ALEXA</b><small>' + (annReady() ? 'full status rundown · ' + esc(targetsLabel(annTargets('rundown'))) : 'set up Alexa (Connected apps)') + '</small></button>' +
      '<button class="cbtn gear" id="cAnnSetup" aria-label="Announce on Alexa setup" title="Setup: what the rundown includes">' + ICON_GEAR + '<small>SETUP</small></button></div>' +
      '<div class="ctl-msg ' + ctlMsg.kind + '">' + (ctlMsg.kind === 'busy' ? '<span class="spin"></span>' : '') + '<span>' + esc(!cmdOk ? 'Commands are off: you did not allow TessDesk to send vehicle commands (Settings \u2192 Permissions).' : (ctlMsg.text || (dry ? 'Dry run: buttons are simulated, nothing is sent' : 'Ready'))) + '</span></div></div>';
    return r;
  }
  // ---------- v4.3.3 OPEN TRUNK (rear only, no frunk) + SENTRY MODE ----------
  function trunkSentryRow(car, dis) {
    var tr = ctlVal('trunkOpen', car.trunkOpen), se = ctlVal('sentry', car.sentry);
    return '<div class="ctl-row2 ts">' +
      '<button class="cbtn' + (tr ? ' warn' : '') + '" id="cTrunk"' + dis + '><b>' + (tr ? 'TRUNK OPEN' : 'OPEN TRUNK') + '</b><small>' + (tr == null ? 'state unknown' : (tr ? 'tap to close' : 'rear · closed')) + '</small></button>' +
      '<button class="cbtn' + (se ? ' state' : '') + '" id="cSentry"' + dis + '><b>SENTRY MODE</b><small>' + (se == null ? 'state unknown' : (se ? 'ON · tap to turn off' : 'OFF · tap to turn on')) + '</small></button></div>';
  }
  function onTrunk() {
    var c = curCar(); if (!c) return; var open = !!ctlVal('trunkOpen', c.trunkOpen);
    if (open) confirmBox('Are you sure?', 'Close trunk', 'Close the rear trunk? Make sure nothing and no one is in the way.').then(function (ok) { if (ok) runCmd('activate_rear_trunk', {}, 'Closing the trunk…', 'Trunk closing', function () { setOv('trunkOpen', false); }, 'Your Tesla trunk is closing.'); else { ctlMsg = { kind: 'idle', text: 'Trunk left open' }; render(); } });
    else confirmBox('Are you sure?', 'Open trunk', 'Open the rear trunk?').then(function (ok) { if (ok) runCmd('activate_rear_trunk', {}, 'Opening the trunk…', 'Trunk open', function () { setOv('trunkOpen', true); }, 'Your Tesla trunk is open.'); else { ctlMsg = { kind: 'idle', text: 'Trunk not opened' }; render(); } });
  }
  function onSentry() {
    var c = curCar(); if (!c) return; var on = !!ctlVal('sentry', c.sentry);
    if (on) confirmBox('Turn Sentry Mode OFF?', 'Turn off', 'The car stops watching and recording its surroundings.').then(function (ok) { if (ok) runCmd('disable_sentry', {}, 'Turning Sentry Mode off…', 'Sentry Mode off', function () { setOv('sentry', false); }, 'Sentry Mode is now off.'); else { ctlMsg = { kind: 'idle', text: 'Sentry Mode stays on' }; render(); } });
    else confirmBox('Turn Sentry Mode ON?', 'Turn on', 'The car watches and records its surroundings (uses some battery).').then(function (ok) { if (ok) runCmd('enable_sentry', {}, 'Turning Sentry Mode on…', 'Sentry Mode on', function () { setOv('sentry', true); }, 'Sentry Mode is now on.'); else { ctlMsg = { kind: 'idle', text: 'Sentry Mode stays off' }; render(); } });
  }

  // ---------- v4.3.3 DRIVES: recent drives + location history (Tessie /drives, read-only) ----------
  function placeName(saved, addr) {
    if (saved) return String(saved);
    if (!addr) return 'Unknown place';
    var p = String(addr).split(',').map(function (x) { return x.trim(); }).filter(Boolean);
    return p.length >= 2 && /^\d+\s/.test(p[0]) ? p[0] + ', ' + p[1] : p[0];
  }
  function ll(a, b) { return (+a).toFixed(6) + ',' + (+b).toFixed(6); }
  function drivesList(cfg) {
    var off = (cfg.rates.overnight || 0) + (cfg.rates.fca || 0);
    return (cache.drives || []).filter(function (d) { return d && d.started_at && +(d.odometer_distance || 0) >= 0.1; }).sort(function (a, b) { return b.started_at - a.started_at; }).slice(0, 10).map(function (d) {
      var s = +d.started_at, e = +(d.ended_at || d.started_at), k = +(d.energy_used || 0);
      return { start: s, end: e, mins: Math.round((e - s) / 60), from: placeName(d.starting_saved_location, d.starting_location), to: placeName(d.ending_saved_location, d.ending_location),
        mi: +(d.odometer_distance || 0), kwh: k, cost: k / cfg.eff * off,
        map: d.starting_latitude != null && d.ending_latitude != null ? 'https://www.google.com/maps/dir/?api=1&origin=' + ll(d.starting_latitude, d.starting_longitude) + '&destination=' + ll(d.ending_latitude, d.ending_longitude) + '&travelmode=driving' : null,
        toLat: d.ending_latitude, toLon: d.ending_longitude, fromLat: d.starting_latitude, fromLon: d.starting_longitude };
    });
  }
  function locHistory(ds) {
    var out = [], prev = null;
    ds.forEach(function (d) { if (d.to === prev) return; prev = d.to; out.push({ place: d.to, at: d.end, url: d.toLat != null ? 'https://www.google.com/maps/search/?api=1&query=' + ll(d.toLat, d.toLon) : null }); });
    return out;
  }
  function historyMap(ds) {
    var pts = [], r = ds.filter(function (d) { return d.toLat != null; }).slice().reverse();
    if (!r.length) return null;
    pts.push(ll(r[0].fromLat, r[0].fromLon));
    r.forEach(function (d) { var p = ll(d.toLat, d.toLon); if (pts[pts.length - 1] !== p) pts.push(p); });
    return 'https://www.google.com/maps/dir/' + pts.slice(-10).join('/');
  }
  function durTxt(m) { return m >= 60 ? Math.floor(m / 60) + ' h ' + (m % 60) + ' min' : m + ' min'; }
  function drivesCard(cfg) {
    var ds = drivesList(cfg), show = ds.slice(0, 5), hist = locHistory(ds).slice(0, 6), hm = historyMap(ds);
    var h = '<div class="card drives"><div class="sec-hd"><h3>Drives</h3>' + (cache.drivesAt && ds.length ? '<span class="pill">Updated ' + clock(cache.drivesAt) + '</span>' : '') + '</div>';
    if (!ds.length) return h + '<div class="dnote">' + (drivesErr ? 'Drives unavailable right now' : 'No drives in the last 30 days yet') + '</div></div>';
    h += '<div class="dnote">Last ' + show.length + ' drives · cost = energy used at the home off-peak rate (estimate) · tap a drive for its map</div>';
    show.forEach(function (d) {
      var tag = d.map ? 'a' : 'div';
      h += '<' + tag + ' class="drive"' + (d.map ? ' href="' + esc(d.map) + '" target="_blank" rel="noopener"' : '') + '>' +
        '<div class="dtop"><span class="dwhen">' + esc(dayLabel(d.start)) + ' · ' + clock(d.start) + '</span><b class="dcost">' + money(d.cost) + ' est</b></div>' +
        '<div class="droute">' + esc(d.from) + ' <span>→</span> ' + esc(d.to) + '</div>' +
        '<div class="dmeta">' + d.mi.toFixed(1) + ' mi · ' + d.kwh.toFixed(1) + ' kWh · ' + durTxt(d.mins) + (d.map ? ' · <u>MAP ›</u>' : '') + '</div></' + tag + '>';
    });
    h += '<div class="hist-hd"><h4>Location history</h4>' + (hm ? '<a class="cbtn mapbtn" id="cHistMap" href="' + esc(hm) + '" target="_blank" rel="noopener"><b>OPEN MAP ›</b></a>' : '') + '</div><ul class="hist">';
    hist.forEach(function (x) { h += '<li>' + (x.url ? '<a href="' + esc(x.url) + '" target="_blank" rel="noopener">' : '<span>') + '<span class="hp">• ' + esc(x.place) + '</span><span class="ht">' + esc(dayLabel(x.at)) + ' ' + clock(x.at) + '</span>' + (x.url ? '</a>' : '</span>') + '</li>'; });
    return h + '</ul></div>';
  }

  // ---------- v4.3.2 FLASH LIGHTS: 1-20 flashes, asks first, Stop ends early ----------
  // v4.3.5: pause 1-30 s (0.5 s steps, localStorage flashPause, default 2.5). Next flash at (previous send + pause), never while the
  // previous request is still in flight. Under 3 s: wait_for_completion=false (fire and go). Stats: response time last/avg + measured gap.
  function clampFlash(v) { v = parseInt(v, 10); if (!(v >= 1)) v = 1; if (v > 20) v = 20; return v; }
  function clampPause(v) { v = parseFloat(String(v).replace(',', '.')); if (!(v >= 1)) v = 1; if (v > 30) v = 30; return Math.round(v * 2) / 2; }
  var flash = { n: clampFlash(load('flashCount', 5)), running: false, done: 0, total: 0, timer: null, pause: clampPause(load('flashPause', 1)), noWait: false, pendingAt: null, nextAt: 0, sends: [], rtts: [] };
  function setPause(v) { flash.pause = clampPause(v); save('flashPause', flash.pause); return flash.pause; }
  function flashGap() { var s = flash.sends; return s.length < 2 ? null : (s[s.length - 1] - s[0]) / 1000 / (s.length - 1); }
  function flashStats() {
    var r = flash.rtts; if (!r.length) return '';
    var avg = r.reduce(function (a, b) { return a + b; }, 0) / r.length, g = flashGap();
    return 'Last ' + r[r.length - 1].toFixed(1) + 's \u00b7 avg ' + avg.toFixed(1) + 's' + (g !== null ? ' \u00b7 gap ' + g.toFixed(1) + 's' : '');
  }
  function onFlash() {
    if (flash.running) { stopFlash(true); return; }
    if (ctlBusy || !cmdAllowed()) return;
    var el = document.getElementById('cFlashN'); var n = clampFlash(el ? el.value : flash.n); flash.n = n; save('flashCount', n);
    var pe = document.getElementById('cFlashP'); var p = setPause(pe ? pe.value : flash.pause);
    confirmBox('Flash the lights ' + n + ' time' + (n === 1 ? '' : 's') + '?', 'Flash', n + ' flash' + (n === 1 ? '' : 'es') + ', about ' + p + ' seconds apart. Tap Stop to end early.').then(function (ok) {
      if (!ok) { ctlMsg = { kind: 'idle', text: 'Flash lights cancelled' }; render(); return; }
      flash.running = true; flash.done = 0; flash.total = n; flash.noWait = p < 3; flash.pendingAt = null; flash.nextAt = 0; flash.sends = []; flash.rtts = []; flashStep();
    });
  }
  function flashStep() {
    clearTimeout(flash.timer);
    if (!flash.running) return;
    if (ctlBusy) { flash.timer = setTimeout(flashStep, 50); return; }          // previous request still in flight: never send on top of it
    if (flash.done >= flash.total) { stopFlash(false); return; }               // v4.3.5: only after the last request has answered
    var now = Date.now();
    if (now < flash.nextAt) { flash.timer = setTimeout(flashStep, Math.min(50, flash.nextAt - now)); return; }
    var i = flash.done + 1; flash.done = i;
    flash.pendingAt = now; flash.nextAt = now + flash.pause * 1000;
    runCmd('flash', flash.noWait ? { wait_for_completion: 'false' } : {}, 'Flashing ' + i + ' of ' + flash.total + '\u2026', 'Flashed ' + i + ' of ' + flash.total,
      function () { if (flash.pendingAt !== null) { flash.rtts.push((Date.now() - flash.pendingAt) / 1000); flash.sends.push(flash.pendingAt); flash.pendingAt = null; } }, null);
    flash.timer = setTimeout(flashStep, 50);
  }
  function stopFlash(early) {
    clearTimeout(flash.timer); var was = flash.running; flash.running = false;
    if (was && early && !ctlBusy) ctlMsg = { kind: 'idle', text: 'Flash lights stopped after ' + flash.done + ' of ' + flash.total };
    if (was && !early && !ctlBusy) ctlMsg = { kind: 'ok', text: '\u2713 Flashed the lights ' + flash.done + ' time' + (flash.done === 1 ? '' : 's') + (flashGap() !== null ? ' \u00b7 ~' + flashGap().toFixed(1) + 's apart' : '') + (load('dryRun', false) ? ' (dry run, not sent)' : '') };
    render();
  }
  function confirmBox(msg, yes, sub) {
    return new Promise(function (res) {
      var d = document.createElement('div'); d.className = 'modal';
      d.innerHTML = '<div class="mbox" role="dialog" aria-modal="true"><div class="mq">' + esc(msg) + '</div>' + (sub ? '<div class="msub">' + esc(sub) + '</div>' : '') + '<div class="mbtns"><button class="btn ghost" id="mNo">Cancel</button><button class="btn" id="mYes">' + esc(yes || 'Yes') + '</button></div></div>';
      document.body.appendChild(d);
      function done(v) { d.remove(); res(v); }
      d.querySelector('#mNo').onclick = function () { done(false); }; d.querySelector('#mYes').onclick = function () { done(true); };
      d.onclick = function (e) { if (e.target === d) done(false); };
    });
  }
  // ann: what Alexa says after success (announced only after the result is known); next: follow-up step (Heat).
  function runCmd(name, query, busyTxt, okTxt, onOk, ann, next) {
    if (ctlBusy || !cmdAllowed()) return;
    ctlBusy = true; ctlMsg = { kind: 'busy', text: busyTxt + (load('dryRun', false) ? ' (dry run)' : '') }; render();
    var okd = false, why = '';
    command(name, query).then(function (j) {
      okd = true; if (onOk) onOk();
      ctlMsg = { kind: 'ok', text: '\u2713 ' + okTxt + ' \u00b7 ' + clock(nowSec()) + (j && j.dryRun ? ' (dry run, not sent)' : '') };
      if (!(j && j.dryRun)) setTimeout(function () { refresh(true); }, 6000);
    }, function (e) { why = String(e.message || e); ctlMsg = { kind: 'err', text: '\u2715 ' + name + ' failed: ' + why.slice(0, 90) }; if (name === 'flash') { flash.running = false; clearTimeout(flash.timer); } })
      .then(function () {
        ctlBusy = false; if (name === 'set_temperatures') pendTemp = null;
        if (okd) liveInfo.lastCmd = nowSec();
        if (okd && next) { render(); next(); return; }
        if (alexaOn() && name !== 'flash') announce(okd ? (ann || defaultSpeech(name, query, okTxt)) : failSpeech(name, why), okd ? 'action' : 'action-failed');
        render();
      });
  }
  function onLock() {
    var c = curCar(); if (!c) return; var locked = ctlVal('locked', c.locked);
    if (locked) confirmBox('Unlock your Tesla?', 'Unlock').then(function (ok) { if (ok) runCmd('unlock', {}, 'Unlocking\u2026', 'Unlocked', function () { setOv('locked', false); }, 'Your Tesla is now unlocked.'); else { ctlMsg = { kind: 'idle', text: 'Unlock cancelled' }; render(); } });
    else runCmd('lock', {}, 'Locking\u2026', 'Locked', function () { setOv('locked', true); }, 'Your Tesla is now locked.');
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
    var lbl = limitLabel(p); pendLimit = p; render();
    confirmBox('Set to ' + p + '%?', 'Confirm', 'Charge limit ' + lbl + (p > 90 ? ' · above 90%: best only before a long trip' : (p === 80 ? ' · Daily' : ''))).then(function (ok) {
      pendLimit = null;
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
  // v4.3.5: SESSIONS of the current / last 11 PM -> 11 AM window, one line each ('1) 11:00\u201311:30 PM \u00b7 3.1 kWh \u00b7 $0.21').
  // Same parts and per-minute pricing as the main $ (homeWindow), so the lines add up to it.
  function timeRange(a, b) {
    var x = clock(a), y = clock(b), m = /\s?([AP]M)$/i, xs = (x.match(m) || [])[1], ys = (y.match(m) || [])[1];
    return (xs && xs === ys ? x.replace(m, '') : x) + '\u2013' + y;
  }
  function windowSessions(cfg, win) {
    if (!win || !win.parts || !win.parts.length) return null;
    var lines = [], sum = 0, lv = liveSession();
    win.parts.forEach(function (p, i) {
      var r = sessionCost(cfg, p); sum += r.cost;
      var live = !!(lv && p === lv && !lv.done);
      lines.push((i + 1) + ') ' + timeRange(p.start, p.end) + ' \u00b7 ' + (p.added || 0).toFixed(1) + ' kWh \u00b7 ' + money(r.cost) + (live ? ' \u00b7 live' : ''));
    });
    return { lines: lines, sum: sum, total: win.cost.cost, header: 'Sessions \u00b7 ' + dayLabel(win.windowStart) + ' 11 PM \u2192 11 AM' };
  }
  function sessionsBlock(cfg, win) {
    var w = windowSessions(cfg, win); if (!w) return '';
    return '<div class="sess" id="sessList"><small>' + esc(w.header) + '</small>' + w.lines.map(function (l) { return '<div>' + esc(l) + '</div>'; }).join('') + '</div>';
  }
  function row(l, sub, t, hl) {
    return '<div class="row' + (hl ? ' hl' : '') + '"><div class="l">' + esc(l) + (sub ? '<small>' + esc(sub) + '</small>' : '') + '</div>' +
      '<div class="r"><small>' + kwh(t.kwh) + '</small><b>' + money(t.cost) + '</b></div></div>';
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

  // ---------- v4.2: charging start/stop + amps slider ----------
  function ampsBounds(car) { var hi = car && car.ampsMax > 0 ? +car.ampsMax : 48, lo = 5; if (hi < lo) lo = 1; return [lo, hi]; }
  function chgState(car) { return ctlVal('chargingState', car ? car.chargingState : null) || ''; }
  var lastAmps = null, draggingAmps = false;
  function ampsAndCharge(car, col) {
    var b = ampsBounds(car), a = ctlVal('amps', car.ampsReq), cs = chgState(car), chg = cs === 'Charging', plugged = !!cs && cs !== 'Disconnected';
    var cmdOk = cmdAllowed(), dis = (ctlBusy || !cmdOk) ? ' disabled' : '';
    lastAmps = { min: b[0], max: b[1], cur: a };
    var f = a != null && b[1] > b[0] ? Math.max(0, Math.min(1, (a - b[0]) / (b[1] - b[0]))) * 100 : 0;
    var note = chg && car.ampsNow != null ? 'drawing ' + Math.round(car.ampsNow) + ' A now' : (car.ampsMax ? 'charger allows up to ' + car.ampsMax + ' A' : '');
    var stopSub = ({ Charging: 'TAP TO STOP', Complete: 'COMPLETE', Stopped: 'STOPPED', NoPower: 'NO POWER', Starting: 'STARTING\u2026', Disconnected: 'NOT PLUGGED IN' })[cs] || (cs ? cs.toUpperCase() : 'STATE UNKNOWN');
    return '<div class="amps-hd"><h4>Charging amps</h4><span>' + esc(note) + '</span></div>' +
      '<div class="batt-drag hidden" id="ampsDrag"><small>SET AMPS</small><span id="ampsDragVal"></span></div>' +
      '<div class="bar amps" id="ampsBar"><div class="track"></div><div class="fill ' + col + '-bg" id="ampsFill" style="left:0;width:' + f + '%"></div>' +
      (a != null ? '<div class="thumb" id="ampsThumb" role="slider" aria-label="Charging amps" aria-valuemin="' + b[0] + '" aria-valuemax="' + b[1] + '" aria-valuenow="' + a + '" style="left:' + f + '%"><i></i><i></i></div>' : '') + '</div>' +
      '<div class="amps-lb"><small>' + b[0] + ' A</small><b id="ampsVal">' + (a != null ? a + ' A' : '-- A') + '</b><small>' + b[1] + ' A max</small></div>' +
      '<div class="chg-row"><button class="cbtn' + (chg ? ' state' : '') + '" id="cChgStart"' + ((dis || chg || !plugged) ? ' disabled' : '') + '><b>START CHARGING</b><small>' + (chg ? 'CHARGING NOW' : (plugged ? 'TAP TO START' : 'NOT PLUGGED IN')) + '</small></button>' +
      '<button class="cbtn' + (plugged && !chg ? ' soft' : '') + '" id="cChgStop"' + ((dis || !chg) ? ' disabled' : '') + '><b>STOP CHARGING</b><small>' + esc(stopSub) + '</small></button></div>';
  }
  function onChgStart() { var c = curCar(); if (!c || chgState(c) === 'Charging') return; runCmd('start_charging', {}, 'Starting charging\u2026', 'Charging started', function () { setOv('chargingState', 'Charging'); }, 'Your Tesla is now charging.'); }
  function onChgStop() {
    var c = curCar(); if (!c || chgState(c) !== 'Charging') return;
    confirmBox('Stop charging now?', 'Stop').then(function (ok) { if (ok) runCmd('stop_charging', {}, 'Stopping charging\u2026', 'Charging stopped', function () { setOv('chargingState', 'Stopped'); }, 'Charging stopped.'); else { ctlMsg = { kind: 'idle', text: 'Still charging' }; render(); } });
  }
  function requestAmps(a) {
    if (!lastAmps) return;
    a = Math.max(lastAmps.min, Math.min(lastAmps.max, Math.round(a)));
    if (a === lastAmps.cur) { ctlMsg = { kind: 'idle', text: 'Charging amps stay ' + a + ' A' }; render(); return; }
    confirmBox('Set charging current to ' + a + ' A?', 'Set ' + a + ' A').then(function (ok) {
      if (!ok) { ctlMsg = { kind: 'idle', text: 'Charging amps unchanged' }; render(); return; }
      runCmd('set_charging_amps', { amps: a }, 'Setting charging current ' + a + ' A\u2026', 'Charging current ' + a + ' A', function () { setOv('amps', a); }, 'Charging current set to ' + a + ' amps.');
    });
  }
  function bindAmps() {
    var bar = document.getElementById('ampsBar'), th = document.getElementById('ampsThumb'); if (!bar || !th || !lastAmps) return;
    var cur = null;
    function ampsAt(x) { var r = bar.getBoundingClientRect(); var f = (x - r.left) / r.width; return Math.max(lastAmps.min, Math.min(lastAmps.max, Math.round(lastAmps.min + f * (lastAmps.max - lastAmps.min)))); }
    function show(a) {
      cur = a; var f = lastAmps.max > lastAmps.min ? (a - lastAmps.min) / (lastAmps.max - lastAmps.min) * 100 : 0;
      th.style.left = f + '%'; document.getElementById('ampsFill').style.width = f + '%'; th.setAttribute('aria-valuenow', a);
      document.getElementById('ampsDragVal').textContent = a + ' A'; document.getElementById('ampsVal').textContent = a + ' A';
      document.getElementById('battTop').classList.add('hidden'); document.getElementById('ampsDrag').classList.remove('hidden');
    }
    bar.addEventListener('pointerdown', function (e) { if (ctlBusy || !cmdAllowed()) return; dragging = true; draggingAmps = true; th.classList.add('drag'); try { bar.setPointerCapture(e.pointerId); } catch (x) {} show(ampsAt(e.clientX)); e.preventDefault(); });
    bar.addEventListener('pointermove', function (e) { if (draggingAmps) show(ampsAt(e.clientX)); });
    function end(commit) { if (!draggingAmps) return; draggingAmps = false; dragging = false; th.classList.remove('drag'); if (commit && cur != null) requestAmps(cur); else render(); }
    bar.addEventListener('pointerup', function () { end(true); }); bar.addEventListener('pointercancel', function () { end(false); });
  }

  // ---------- v4.2: heat, defrost, cabin overheat protection ----------
  // Heat: Tesla has no separate heater command, so HEAT = climate on with a warm set temperature (82 F, or cfg.heatTempF).
  function heatC(car) { var cfg = getCfg() || {}, f = cfg.heatTempF || 82, c = Math.round((f - 32) * 5 / 9 * 10) / 10; return Math.min(car && car.maxC != null ? car.maxC : 28, c); }
  function heatOn(car) { var on = ctlVal('climateOn', car.climateOn), t = pendTemp != null ? pendTemp : ctlVal('tempC', car.tempC); return !!on && t != null && t >= heatC(car) - 0.3; }
  function climateRow(car, dis) {
    var h = heatOn(car), d = ctlVal('defrost', car.defrostOn), m = ctlVal('cop', car.cop);
    var copSub = ({ On: 'PROTECT: ON', FanOnly: 'PROTECT: FAN ONLY', Off: 'PROTECT: OFF' })[m] || 'state unknown';
    var copDis = dis || (car.copAllowed === false ? ' disabled' : '');
    return '<div class="ctl-row3b">' +
      '<button class="cbtn' + (h ? ' heat' : '') + '" id="cHeat"' + dis + '><b>\u2668 ' + (h ? 'HEAT ON' : 'HEAT') + '</b><small>' + (h ? 'climate on \u00b7 ' + fmtTemp(ctlVal('tempC', car.tempC), car.units) : 'climate on at ' + fmtTemp(heatC(car), car.units)) + '</small></button>' +
      '<button class="cbtn' + (d ? ' state' : '') + '" id="cDefrost"' + dis + '><b>DEFROST</b><small>' + (d == null ? 'state unknown' : (d ? 'MAX \u00b7 ON' : 'MAX \u00b7 OFF')) + '</small></button>' +
      '<button class="cbtn' + (m === 'On' || m === 'FanOnly' ? ' state' : '') + '" id="cCop"' + copDis + '><b>OVERHEAT</b><small>' + (car.copAllowed === false ? 'not available' : copSub) + '</small></button></div>';
  }
  function onHeat() {
    var c = curCar(); if (!c) return;
    if (heatOn(c)) { runCmd('stop_climate', {}, 'Turning heat (climate) off\u2026', 'Heat off (climate off)', function () { setOv('climateOn', false); }, 'Heat is off. Climate is now off.'); return; }
    var hc = heatC(c), txt = fmtTemp(hc, c.units);
    runCmd('set_temperatures', { temperature: hc.toFixed(1) }, 'Heat: setting ' + txt + '\u2026', 'Set ' + txt, function () { setOv('tempC', hc); }, null, function () {
      runCmd('start_climate', {}, 'Heat: turning climate on\u2026', 'Heat on: climate on at ' + txt, function () { setOv('climateOn', true); }, 'Heat is on. Climate set to ' + spokenTemp(hc, c.units) + '.');
    });
  }
  function onDefrost() {
    var c = curCar(); if (!c) return;
    if (ctlVal('defrost', c.defrostOn)) runCmd('stop_max_defrost', {}, 'Turning defrost off\u2026', 'Defrost off', function () { setOv('defrost', false); }, 'Defrost is now off.');
    else runCmd('start_max_defrost', {}, 'Turning max defrost on\u2026', 'Max defrost on', function () { setOv('defrost', true); setOv('climateOn', true); }, 'Max defrost is now on.');
  }
  function onCop() {
    var c = curCar(); if (!c) return; var m = ctlVal('cop', c.cop);
    var next = m === 'On' ? (c.copFanOnly ? 'FanOnly' : 'Off') : (m === 'FanOnly' ? 'Off' : 'On');
    var lbl = next === 'On' ? 'on' : (next === 'FanOnly' ? 'fan only' : 'off');
    runCmd('set_cabin_overheat_protection', { on: next !== 'Off', fan_only: next === 'FanOnly' }, 'Cabin overheat protection \u2192 ' + lbl + '\u2026', 'Cabin overheat protection ' + lbl,
      function () { setOv('cop', next); }, 'Cabin overheat protection is now ' + (next === 'FanOnly' ? 'set to fan only' : lbl) + '.');
  }

  // ---------- v4.2: HEATED SEATS (top-down, like the tires). Tap cycles off -> 1 -> 2 -> 3, sent 1.2 s after the last tap ----------
  var SEAT_API = { fl: 'front_left', fr: 'front_right', rl: 'rear_left', rc: 'rear_center', rr: 'rear_right' };
  var SEAT_NAME = { fl: 'Driver seat', fr: 'Passenger seat', rl: 'Rear left seat', rc: 'Rear center seat', rr: 'Rear right seat' };
  var seatPend = {}, seatTimer = null;
  function seatLevel(car, k) { if (seatPend[k] != null) return seatPend[k]; return ctlVal('seat_' + k, car.seats[k]); }
  function seatsCard(car) {
    var cmdOk = cmdAllowed(), dis = ctlBusy || !cmdOk;
    var rear = (car.seats.rl != null || car.seats.rr != null) && car.rearSeats !== 0;
    function seat(k, x, y, w, hgt, big) {
      var l = seatLevel(car, k); if (l == null || (k.charAt(0) === 'r' && !rear)) return '';
      var bars = '', bw = big ? 8 : 6, hs = big ? [8, 13, 18] : [6, 9, 12], gap = big ? 4 : 3, tot = bw * 3 + gap * 2, x0 = x + (w - tot) / 2, yb = y + hgt - 7;
      for (var i = 0; i < 3; i++) bars += '<rect class="hb' + (i < l ? ' l' + l : '') + '" x="' + (x0 + i * (bw + gap)) + '" y="' + (yb - hs[i]) + '" width="' + bw + '" height="' + hs[i] + '" rx="1.5"/>';
      return '<g class="seat' + (l > 0 ? ' l' + l : '') + (seatPend[k] != null ? ' pend' : '') + (dis ? ' dis' : '') + '" data-seat="' + k + '" role="button" aria-label="' + SEAT_NAME[k] + ' heat ' + l + '">' +
        '<rect class="sb" x="' + x + '" y="' + y + '" width="' + w + '" height="' + hgt + '" rx="9"/>' +
        '<text class="sn" x="' + (x + w / 2) + '" y="' + (y + (big ? 21 : 17)) + '" text-anchor="middle">' + (l > 0 ? l : 'OFF') + '</text>' + bars + '</g>';
    }
    function side(k, x, y, anchor, cap) {
      var l = seatLevel(car, k); if (l == null || (k.charAt(0) === 'r' && !rear)) return '';
      return '<text class="slv' + (l > 0 ? ' l' + l : '') + '" x="' + x + '" y="' + y + '" text-anchor="' + anchor + '">' + (l > 0 ? 'HEAT ' + l : 'OFF') + (seatPend[k] != null ? ' \u2026' : '') + '</text>' +
        '<text class="unit" x="' + x + '" y="' + (y + 15) + '" text-anchor="' + anchor + '">' + cap + '</text>';
    }
    var w = ctlVal('wheel', car.wheelOn);
    var wheel = w == null ? '' : '<g class="seat wheel' + (w ? ' l3' : '') + (dis ? ' dis' : '') + '" id="sWheel" role="button" aria-label="Steering wheel heat">' +
      '<circle class="sb" cx="134" cy="52" r="14"/><circle class="wr" cx="134" cy="52" r="7"/></g>' +
      '<text class="slv' + (w ? ' l3' : '') + '" x="96" y="50" text-anchor="end">' + (w ? 'HEAT ON' : 'OFF') + '</text><text class="unit" x="96" y="64" text-anchor="end">WHEEL</text>';
    return '<div class="card seats"><div class="sec-hd"><h3>Heated seats</h3><span class="asof sm">' + (cmdOk ? 'tap a seat: off \u2192 1 \u2192 2 \u2192 3' : 'commands are off') + '</span></div>' +
      '<svg viewBox="0 0 320 210" role="img" aria-label="Heated seats">' +
      '<path class="body" d="M160 6 C 200 6 212 20 212 48 L 214 110 L 212 180 C 212 200 196 206 160 206 C 124 206 108 200 108 180 L 106 110 L 108 48 C 108 20 120 6 160 6 Z"/>' +
      '<path class="glass" d="M124 30 C 140 22 180 22 196 30 L 192 38 C 176 34 144 34 128 38 Z"/>' +
      wheel + seat('fl', 118, 74, 38, 50, true) + seat('fr', 164, 74, 38, 50, true) +
      seat('rl', 118, 142, 26, 42, false) + seat('rc', 147, 142, 26, 42, false) + seat('rr', 176, 142, 26, 42, false) +
      side('fl', 96, 98, 'end', 'DRIVER') + side('fr', 224, 98, 'start', 'PASSENGER') + side('rl', 96, 164, 'end', 'REAR LEFT') + side('rr', 224, 164, 'start', 'REAR RIGHT') + '</svg></div>';
  }
  function onSeat(k) {
    var c = curCar(); if (!c || ctlBusy || !cmdAllowed()) return;
    var l = seatLevel(c, k); if (l == null) return;
    var n = (+l + 1) % 4; seatPend[k] = n;
    ctlMsg = { kind: 'idle', text: SEAT_NAME[k] + ' \u2192 ' + (n ? 'level ' + n : 'off') + ' \u00b7 sending in a moment\u2026' }; render();
    clearTimeout(seatTimer); seatTimer = setTimeout(sendSeats, 1200);
  }
  function sendSeats() {
    seatTimer = null;
    var ks = Object.keys(seatPend); if (!ks.length) return;
    if (ctlBusy) { seatTimer = setTimeout(sendSeats, 400); return; }
    var k = ks[0], n = seatPend[k]; delete seatPend[k];
    var c = curCar(), live = c ? ctlVal('seat_' + k, c.seats[k]) : null;
    var more = function () { if (Object.keys(seatPend).length) seatTimer = setTimeout(sendSeats, 300); };
    if (live != null && +live === n) { ctlMsg = { kind: 'idle', text: SEAT_NAME[k] + ' heat unchanged' }; render(); more(); return; }
    var lv = n ? 'level ' + n : 'off';
    runCmd('set_seat_heat', { seat: SEAT_API[k], level: n }, SEAT_NAME[k] + ' heat ' + lv + '\u2026', SEAT_NAME[k] + ' heat ' + lv, function () { setOv('seat_' + k, n); },
      n ? SEAT_NAME[k] + ' heat set to level ' + n + '.' : SEAT_NAME[k] + ' heat is now off.', Object.keys(seatPend).length ? sendSeats : null);
  }
  function onWheel() {
    var c = curCar(); if (!c) return;
    if (ctlVal('wheel', c.wheelOn)) runCmd('stop_steering_wheel_heater', {}, 'Turning wheel heat off\u2026', 'Steering wheel heat off', function () { setOv('wheel', false); }, 'Steering wheel heat is now off.');
    else runCmd('start_steering_wheel_heater', {}, 'Turning wheel heat on\u2026', 'Steering wheel heat on', function () { setOv('wheel', true); }, 'Steering wheel heat is now on.');
  }

  // ---------- v4.2: Alexa announcements via Voice Monkey (POST https://api-v3.voicemonkey.io/announce {token, device, speech}) ----------
  var VM_API = 'https://api-v3.voicemonkey.io', annLog = [];
  function annCfg() { var c = getCfg() || {}; return c.announce || {}; }
  function annConsent() { var c = getCfg() || {}; return !!(c.consent && c.consent.announcements); }
  function annReady() { var a = annCfg(); return annConsent() && !!a.token && !!a.device; }
  function alexaOn() { return !!load('alexa', false); }
  function setAlexa(on) { save('alexa', !!on); if (on && !annReady()) ctlMsg = { kind: 'idle', text: 'Alexa is on, but Voice Monkey is not set up yet: Settings \u2192 Connected apps.' }; render(); }
  function alexaChip() {
    return '<button class="alexa' + (alexaOn() ? ' on' : '') + '" id="btnAlexa" aria-pressed="' + alexaOn() + '" title="Announce control results on Alexa (Voice Monkey)"><span>ALEXA</span><i></i></button>' +
      '<button class="icon-btn" id="btnSched" aria-label="Alexa schedule and Connected apps"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg></button>';
  }
  function spokenTemp(c, units) { return c == null ? 'unknown' : (units === 'C' ? (Math.round(c * 2) / 2) + ' degrees' : Math.round(c * 9 / 5 + 32) + ' degrees'); }
  var CMD_SPOKEN = { lock: 'lock your Tesla', unlock: 'unlock your Tesla', vent_windows: 'vent the windows', close_windows: 'close the windows', start_climate: 'turn on climate', stop_climate: 'turn off climate',
    set_temperatures: 'set the cabin temperature', start_max_defrost: 'turn on defrost', stop_max_defrost: 'turn off defrost', set_cabin_overheat_protection: 'change cabin overheat protection',
    set_seat_heat: 'change the seat heat', start_steering_wheel_heater: 'turn on the steering wheel heat', stop_steering_wheel_heater: 'turn off the steering wheel heat',
    start_charging: 'start charging', stop_charging: 'stop charging', set_charge_limit: 'set the charge limit', set_charging_amps: 'set the charging current' };
  function defaultSpeech(name, q, okTxt) {
    var c = curCar() || {};
    switch (name) {
      case 'vent_windows': return 'Your Tesla windows are now vented.';
      case 'close_windows': return 'Your Tesla windows are now closed.';
      case 'start_climate': return 'Climate is now on.';
      case 'stop_climate': return 'Climate is now off.';
      case 'set_temperatures': return 'Climate set to ' + spokenTemp(+q.temperature, c.units) + '.';
      case 'set_charge_limit': return 'Charge limit set to ' + q.percent + ' percent.';
      default: return 'Done: ' + okTxt + '.';
    }
  }
  function failSpeech(name, why) { return 'TessDesk could not ' + (CMD_SPOKEN[name] || name.replace(/_/g, ' ')) + '. The command failed' + (/token/.test(why) ? ' because the Tessie token was rejected' : (/no response|timeout|offline/.test(why) ? ' because the car did not respond' : '')) + '.'; }
  // v4.3 ALL ECHOS: announcements go to every Voice Monkey speaker by default (Voice Monkey has no groups: one /announce per speaker).
  // Reminders keep using the one saved device (announce.device).
  function vmSpeakers() { return load('vmSpeakers', []) || []; }
  function spkCfg() { var a = annCfg(); return a.speakers || { all: true, ids: [] }; }
  function annTargets(why) {
    var a = annCfg(); if (why === 'reminder') return a.device ? [a.device] : [];
    var sc = spkCfg(), list = vmSpeakers().map(function (d) { return d.id; });
    var t = sc.all !== false ? list : (sc.ids || []).filter(function (id) { return !list.length || list.indexOf(id) >= 0; });
    if (!t.length && a.device) t = [a.device];
    return t;
  }
  function targetsLabel(t) { var sc = spkCfg(), sp = vmSpeakers(); return sc.all !== false && sp.length ? 'All Echos (' + t.length + ')' : t.map(function (id) { var h = sp.filter(function (x) { return x.id === id; })[0]; return h ? h.name : id; }).join(', '); }
  function refreshSpeakers() {
    var tok = annCfg().token; if (!tok) return Promise.reject(new Error('no Voice Monkey token'));
    return fetch(VM_API + '/devices', { headers: { Authorization: 'Bearer ' + tok } }).then(function (r) { if (!r.ok) throw new Error(r.status === 401 ? 'token not valid (401)' : 'HTTP ' + r.status); return r.json(); })
      .then(function (j) { var sp = (j.data || []).filter(function (d) { return d.capability === 'speakers'; }).map(function (d) { return { id: String(d.id), name: String(d.name || d.id) }; }); save('vmSpeakers', sp); return sp; });
  }
  // v4.3.1: Voice Monkey API v3 lists speakers (GET /devices) but cannot create them, so Add speaker opens the Voice Monkey Speakers page.
  var VM_SPEAKERS_URL = 'https://app.voicemonkey.io/speakers', VM_ADD_DOC = 'https://voicemonkey.io/docs/getting-started/add-device.html';
  function testSpeaker(id, m) {
    // Test this speaker: one short line on ONE speaker, only when tapped. Dry run = log only.
    var sp = vmSpeakers().filter(function (x) { return x.id === id; })[0], name = sp ? sp.name : id, a = annCfg();
    var txt = 'This is a TessDesk test on ' + name + '. Tesla announcements will play here.';
    var rec = { at: new Date().toISOString(), why: 'speaker-test', text: txt, device: id, dryRun: !!load('dryRun', false), sent: false, result: '' };
    annLog.push(rec); if (annLog.length > 40) annLog.shift();
    if (rec.dryRun) { rec.result = 'DRY RUN: test not sent'; m.textContent = 'Dry run: would say \u201c' + txt + '\u201d on ' + name + ' only. Nothing was sent.'; return rec; }
    if (!annConsent()) { rec.result = 'skipped: disclosure'; m.textContent = 'Accept the Alexa disclosure in Settings \u203a Connected apps first.'; return rec; }
    if (!a.token) { rec.result = 'skipped: no token'; m.textContent = 'Save your Voice Monkey token in Settings \u203a Connected apps first.'; return rec; }
    rec.sent = true; rec.result = 'sending'; m.textContent = 'Testing ' + name + '\u2026';
    vmPost(id, txt).then(function (r) { rec.result = r.ok ? 'test sent' : 'test failed: HTTP ' + r.status; m.textContent = r.ok ? '\u2713 Test sent to ' + name + '. Quiet? Check its Alexa Routine (Add speaker, step 2).' : '\u2715 Test failed: HTTP ' + r.status; },
      function () { rec.result = 'test failed: network'; m.textContent = '\u2715 Test failed: network'; });
    return rec;
  }
  function vmPost(dev, text) { var a = annCfg(); return fetch(VM_API + '/announce', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token: a.token, device: dev, speech: text }) }); }
  function announce(text, why, force) {
    var a = annCfg(), tg = annTargets(why), rec = { at: new Date().toISOString(), why: why || 'action', text: text, device: tg.join(','), dryRun: !!load('dryRun', false), sent: false, result: '' };
    if (!force && !alexaOn()) rec.result = 'skipped: Alexa toggle off';
    else if (!annConsent()) rec.result = 'skipped: announcement disclosure not accepted';
    else if (!a.token || !a.device) rec.result = 'skipped: Voice Monkey not set up';
    else if (rec.dryRun) rec.result = 'DRY RUN: not sent to Voice Monkey';
    else {
      rec.sent = true; rec.result = 'sending';
      var okN = 0, chain = Promise.resolve();
      tg.forEach(function (dev) { chain = chain.then(function () { return vmPost(dev, text).then(function (r) { if (r.ok) okN++; }, function () {}); }); });
      chain.then(function () { rec.result = okN === tg.length ? 'announced' : (okN ? 'announced on ' + okN + ' of ' + tg.length : 'failed'); });
    }
    annLog.push(rec); if (annLog.length > 40) annLog.shift();
    return rec;
  }

  // ---------- v4.2: Settings > Connected apps (Tessie, Voice Monkey, Alexa) + scheduled announcements ----------
  var ANN_TYPES = [['cost', 'Charging cost', 'last night\u2019s or tonight\u2019s cost and kWh'], ['tires', 'Tire pressure', 'all four, flags low or high'], ['status', 'Vehicle status', 'battery, range, charging, locks, windows, climate']];
  var DAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  function timeRow(t) {
    t = t || { time: '07:30', days: DAYS }; var hh = +t.time.split(':')[0], mm = +t.time.split(':')[1];
    var ho = ''; for (var i = 1; i <= 12; i++) ho += '<option' + (((hh % 12) || 12) === i ? ' selected' : '') + '>' + i + '</option>';
    var mo = ''; for (var j = 0; j < 60; j += 5) mo += '<option' + (j === Math.round(mm / 5) * 5 % 60 ? ' selected' : '') + '>' + ('0' + j).slice(-2) + '</option>';
    return '<div class="trow"><select class="th">' + ho + '</select><select class="tm">' + mo + '</select><select class="ta"><option' + (hh < 12 ? ' selected' : '') + '>AM</option><option' + (hh >= 12 ? ' selected' : '') + '>PM</option></select>' +
      '<div class="days">' + DAYS.map(function (d) { return '<label><input type="checkbox" value="' + d + '"' + ((t.days || []).indexOf(d) >= 0 ? ' checked' : '') + '>' + d.slice(0, 2) + '</label>'; }).join('') + '</div><button type="button" class="btn ghost rm">Remove</button></div>';
  }
  function connectedApps(cfg) {
    var a = cfg.announce || {}, sch = a.schedules || {};
    var tok = cfg.token ? 'token saved on this phone' : 'no token yet';
    return '<div class="sect" id="apps">Connected apps</div>' +
      '<div class="appc"><div class="apph"><b>Tessie</b><span>' + tok + (cfg.vin ? ' \u00b7 VIN \u2026' + esc(cfg.vin.slice(-6)) : '') + '</span></div>' +
      '<button class="btn ghost" id="aTessie" type="button">Check</button><div class="msg" id="mTessie"></div></div>' +
      '<div class="appc"><div class="apph"><b>Voice Monkey</b><span>Alexa announcements</span></div>' +
      '<div class="field"><label for="aTok">API token</label><input type="password" id="aTok" autocomplete="off" autocapitalize="off" spellcheck="false" value="' + esc(a.token || '') + '" placeholder="From app.voicemonkey.io/tokens"><div class="help">Stored only in this browser on this phone, sent only to api-v3.voicemonkey.io.</div></div>' +
      '<div class="field"><label for="aDev">Default speaker device ID (reminders; rundowns use Announce Setup \u2192 Speakers)</label><input type="text" id="aDev" autocapitalize="off" spellcheck="false" value="' + esc(a.device || '') + '" placeholder="e.g. echo-living-room-xxxxx"></div>' +
      '<label class="check"><input type="checkbox" id="aDisc"' + (cfg.consent && cfg.consent.announcements ? ' checked' : '') + '> I understand: the text of each announcement (for example charging cost, tire pressures, battery, lock and window state) is sent to Voice Monkey and Amazon (Alexa) so my Echo can speak it.</label>' +
      '<div class="inline"><button class="btn ghost" id="aCheck" type="button">Check</button><button class="btn ghost" id="aTest" type="button">Send test announcement</button></div><div class="msg" id="mVm"></div></div>' +
      '<div class="appc"><div class="apph"><b>Alexa</b><span>setup</span></div><div class="help">Voice Monkey speaks through your Echo. In the Alexa app enable the <b>Voice Monkey</b> skill and link your Amazon account, then create a <b>Speaker</b> device and an API token in the Voice Monkey dashboard.</div>' +
      '<div class="hl"><a class="hbtn" href="https://voicemonkey.io" target="_blank" rel="noopener">Sign up for Voice Monkey</a></div>' +
      '<div class="hl"><a class="hbtn" href="https://www.amazon.com/dp/B08C6Z4C3R" target="_blank" rel="noopener">Enable the Alexa skill</a></div>' +
      '<div class="hl"><a class="hbtn" href="https://app.voicemonkey.io" target="_blank" rel="noopener">Voice Monkey dashboard</a></div>' +
      '<div class="hl"><a class="hbtn" href="https://app.voicemonkey.io/tokens" target="_blank" rel="noopener">API tokens</a></div></div>' +
      '<div class="sect">Scheduled announcements</div>' +
      '<div class="pcnote"><b>These run from the PC app.</b> A web app can\u2019t run on a schedule, so the phone never announces on its own. Set the same schedule in the TessDesk desktop widget (clock button next to ALEXA); the PC uses Windows scheduled tasks. The phone still announces your control actions while the ALEXA switch is on.</div>' +
      ANN_TYPES.map(function (t) {
        var s = sch[t[0]] || {}, times = (s.times && s.times.length) ? s.times : [{ time: t[0] === 'cost' ? '07:00' : (t[0] === 'tires' ? '07:30' : '18:00'), days: DAYS }];
        return '<div class="sched" data-type="' + t[0] + '"><label class="check"><input type="checkbox" class="son"' + (s.enabled ? ' checked' : '') + '> <span><b>' + t[1] + '</b> \u00b7 ' + t[2] + '</span></label>' +
          '<div class="times">' + times.map(timeRow).join('') + '</div><button type="button" class="btn ghost add">+ Add time</button></div>';
      }).join('');
  }
  function bindConnectedApps() {
    var el = function (id) { return document.getElementById(id); }; if (!el('aTok')) return;
    Array.prototype.forEach.call(document.querySelectorAll('.sched'), function (sc) {
      sc.querySelector('.add').onclick = function () { sc.querySelector('.times').insertAdjacentHTML('beforeend', timeRow()); bindRm(); };
    });
    function bindRm() { Array.prototype.forEach.call(document.querySelectorAll('.trow .rm'), function (b) { b.onclick = function () { b.parentNode.remove(); }; }); }
    bindRm();
    el('aTessie').onclick = function () {
      var c = getCfg() || {}, m = el('mTessie'); if (!c.token || !c.vin) { m.className = 'msg err'; m.textContent = 'Save your token and vehicle first.'; return; }
      m.className = 'msg'; m.textContent = 'Checking (cached data, car not woken)\u2026';
      api('/' + c.vin + '/state?use_cache=true').then(function (s) { m.className = 'msg ok'; m.textContent = 'OK: ' + (s.display_name || 'Tesla') + ' \u00b7 ' + ((s.charge_state || {}).battery_level) + '%'; },
        function (e) { m.className = 'msg err'; m.textContent = e.auth ? 'Token rejected' : 'Could not reach Tessie: ' + e.message; });
    };
    el('aCheck').onclick = function () {
      var tok = el('aTok').value.trim(), dev = el('aDev').value.trim(), m = el('mVm');
      if (!tok) { m.className = 'msg err'; m.textContent = 'Paste your Voice Monkey API token first.'; return; }
      if (load('dryRun', false)) { m.className = 'msg ok'; m.textContent = 'Dry run: check skipped (nothing sent).'; return; }
      m.className = 'msg'; m.textContent = 'Checking\u2026';
      fetch(VM_API + '/devices', { headers: { Authorization: 'Bearer ' + tok } }).then(function (r) { if (!r.ok) throw new Error(r.status === 401 ? 'token not valid (401)' : 'HTTP ' + r.status); return r.json(); }).then(function (j) {
        var sp = (j.data || []).filter(function (d) { return d.capability === 'speakers'; }); save('vmSpeakers', sp.map(function (d) { return { id: String(d.id), name: String(d.name || d.id) }; })); var hit = sp.filter(function (d) { return d.id === dev || d.name === dev; })[0];
        m.className = 'msg ' + (hit ? 'ok' : 'err'); m.textContent = hit ? 'OK: speaker \u201c' + hit.name + '\u201d found' : 'Token valid. Speakers: ' + sp.map(function (d) { return d.id; }).join(', ') + (dev ? ' (\u201c' + dev + '\u201d not found)' : '');
      }).catch(function (e) { m.className = 'msg err'; m.textContent = 'Check failed: ' + e.message; });
    };
    el('aTest').onclick = function () {
      var m = el('mVm'); if (!el('aDisc').checked) { m.className = 'msg err'; m.textContent = 'Tick the disclosure box first.'; return; }
      var tok = el('aTok').value.trim(), dev = el('aDev').value.trim(); if (!tok || !dev) { m.className = 'msg err'; m.textContent = 'Enter the token and the speaker device first.'; return; }
      var txt = 'This is a TessDesk test announcement. Alexa announcements are working.';
      if (load('dryRun', false)) { annLog.push({ at: new Date().toISOString(), why: 'test', text: txt, device: dev, dryRun: true, sent: false, result: 'DRY RUN: not sent' }); m.className = 'msg ok'; m.textContent = 'Dry run: would announce \u201c' + txt + '\u201d on ' + dev; return; }
      m.className = 'msg'; m.textContent = 'Sending\u2026';
      fetch(VM_API + '/announce', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token: tok, device: dev, speech: txt }) })
        .then(function (r) { m.className = 'msg ' + (r.ok ? 'ok' : 'err'); m.textContent = r.ok ? 'Sent. You should hear it on ' + dev + ' now.' : 'Failed: HTTP ' + r.status; }, function () { m.className = 'msg err'; m.textContent = 'Failed: network'; });
    };
  }
  function readAnnounceForm(prev) {
    var el = function (id) { return document.getElementById(id); }; if (!el('aTok')) return prev || {};
    var sch = {};
    Array.prototype.forEach.call(document.querySelectorAll('.sched'), function (sc) {
      sch[sc.getAttribute('data-type')] = { enabled: sc.querySelector('.son').checked, times: Array.prototype.map.call(sc.querySelectorAll('.trow'), function (r) {
        var h = (+r.querySelector('.th').value) % 12 + (r.querySelector('.ta').value === 'PM' ? 12 : 0);
        return { time: ('0' + h).slice(-2) + ':' + r.querySelector('.tm').value, days: Array.prototype.filter.call(r.querySelectorAll('.days input'), function (x) { return x.checked; }).map(function (x) { return x.value; }) };
      }) };
    });
    return { token: el('aTok').value.trim(), device: el('aDev').value.trim(), schedules: sch, schedulesRunOn: 'pc', speakers: (prev && prev.speakers) || { all: true, ids: [] } };
  }

  // ---------- v4.2: FULL / COMPACT ----------
  // Compact: same sections and controls, smaller type, tighter padding, smaller drawings, then zoomed (down to 45%, only on very short screens) to fit the screen height.
  var curZoom = 1;
  function layoutMode() { return load('layout', 'full') === 'compact' ? 'compact' : 'full'; }
  function setLayout(m) { save('layout', m); render(); }
  function layoutChip() { var c = layoutMode() === 'compact'; return '<button class="laychip' + (c ? ' on' : '') + '" id="btnLayout" title="Full: normal size, scrolls. Compact: fits the screen.">' + (c ? 'COMPACT' : 'FULL') + '</button>'; }
  // v4.2.1: COMPACT is ~38 CSS px (~10 mm) narrower on screen too. v4.2's compact was min(screen, 480 * zoom) wide (276 px on a
  // 390x844 phone). Now: min(480 * zoom - 38, 238 px), never below a 360 px layout (so nothing
  // inside gets cramped) and never wider than screen - 38.
  // The zoom shrinks everything inside .wrap, so the width is set in layout px (visual / zoom). A narrower layout can wrap a
  // little taller, so the zoom is refined a few times until the page fits the screen height.
  var TRIM = 38, ZMIN = 0.45, CMAX = 238, CLAYOUT_MIN = 360;
  function fitCompact() {
    var w = document.querySelector('.wrap'); if (!w) return;
    document.body.classList.toggle('compact', layoutMode() === 'compact');
    w.style.zoom = ''; w.style.width = ''; curZoom = 1;
    if (layoutMode() !== 'compact' || screen !== 'main') return;
    var vw = document.documentElement.clientWidth || window.innerWidth, vh = window.innerHeight, z = 1;
    function apply(zz) { w.style.zoom = zz === 1 ? '' : zz; w.style.width = Math.min(vw - TRIM, Math.max(CLAYOUT_MIN * zz, Math.min(480 * zz - TRIM, CMAX))) / zz + 'px'; }
    for (var i = 0; i < 6; i++) {
      apply(z);
      var need = w.getBoundingClientRect().height / z;            // layout height at this width
      var nz = Math.max(ZMIN, Math.min(1, Math.floor(vh / need * 1000) / 1000));
      if (nz >= z && w.getBoundingClientRect().height <= vh) break; // fits
      z = nz < z ? nz : Math.max(ZMIN, z - 0.005);
      if (z === ZMIN) { apply(z); break; }
    }
    curZoom = z;
  }
  window.addEventListener('resize', function () { if (layoutMode() === 'compact') fitCompact(); });
  function monDay(t) { return new Date(t * 1000).toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: 'America/Chicago' }); }

  // ---------- v4.2: reminder setup (how reminders reach you) ----------
  var REM_CH = [
    ['calendar', 'Phone calendar alert', 'Works here. Adds a calendar event with an alert at the time you pick (.ics for Apple / any calendar, or Google Calendar). Your phone gives the notification.', true],
    ['text', 'Text message', 'On the phone: opens a text to your number, ready to send now (a web app can\u2019t send texts later). Scheduled texts come from the PC app through your carrier\u2019s email-to-text gateway. Honest note: AT&T shut its gateway down in June 2025, T-Mobile\u2019s is unreliable, Verizon\u2019s works until March 2027.', true],
    ['email', 'Email', 'On the phone: opens an email draft (sent when you tap Send). Scheduled email comes from the PC app through your own email account.', true],
    ['alexa', 'Alexa announcement', 'Your Echo speaks it through Voice Monkey (Settings \u2192 Connected apps). The phone can announce right now; scheduled announcements come from the PC app.', true],
    ['toast', 'Windows notification', 'PC app only: pops up on your Windows PC at the time you pick (set it in the desktop widget).', false]
  ];
  function remCh(c) { return (remCfg().channels || []).indexOf(c) >= 0; }
  function remCfg() { var c = getCfg() || {}; return c.remind || { channels: ['calendar'], phone: '' }; }
  function openRemSetup() {
    var rc = remCfg(), d = document.createElement('div'); d.className = 'modal';
    function close() { d.remove(); }
    d.innerHTML = '<div class="mbox rem" role="dialog" aria-modal="true"><div class="mq">How reminders reach you</div>' +
      REM_CH.map(function (c) {
        var ok = c[3] && (c[0] !== 'alexa' || annReady());
        return '<label class="check remch"><input type="checkbox" data-ch="' + c[0] + '"' + ((rc.channels || []).indexOf(c[0]) >= 0 && ok ? ' checked' : '') + (ok ? '' : ' disabled') + '><span><b>' + c[1] + '</b>' +
          (c[0] === 'alexa' && !annReady() ? ' <em>not set up</em>' : '') + '<small>' + c[2] + '</small></span></label>';
      }).join('') +
      '<div class="field"><label for="rPhone">Your mobile number (for the text option)</label><input type="text" id="rPhone" inputmode="tel" value="' + esc(rc.phone || '') + '" placeholder="555-555-0100"></div>' +
      '<div class="rn"><b>Tessie app / car screen:</b> not possible. Tessie\u2019s API can\u2019t send a notification to the Tessie app or a message to the car\u2019s screen (its \u201cshare\u201d command only sends an address or video link to the car\u2019s navigation). For Tessie\u2019s own alerts: Tessie app \u2192 Notifications (the bell, top right) \u2192 turn on <b>Low tire pressure</b>.</div>' +
      '<div class="mbtns"><button class="btn ghost" id="rsNo">Cancel</button><button class="btn" id="rsSave">Save</button></div></div>';
    d.querySelector('#rsNo').onclick = close;
    d.querySelector('#rsSave').onclick = function () {
      var c = getCfg(); c.remind = { channels: Array.prototype.filter.call(d.querySelectorAll('[data-ch]'), function (x) { return x.checked; }).map(function (x) { return x.getAttribute('data-ch'); }), phone: d.querySelector('#rPhone').value.trim() };
      save('cfg', c); close(); render();
    };
    d.onclick = function (e) { if (e.target === d) close(); };
    document.body.appendChild(d);
  }
  function smsUrl(rep) {
    var ph = (remCfg().phone || '').replace(/[^\d+]/g, ''), ios = /iPhone|iPad|iPod/.test(navigator.userAgent);
    return 'sms:' + ph + (ios ? '&' : '?') + 'body=' + encodeURIComponent('TessDesk: get air. ' + rep.lines.join(', ') + (rep.rec ? ' ' + rep.rec : ''));
  }

  function bind() {
    var r = document.getElementById('btnRefresh'); if (r) r.onclick = function () { refresh(true); };
    var s = document.getElementById('btnSettings'); if (s) s.onclick = function () { screen = 'settings'; render(); window.scrollTo(0, 0); };
    var on = function (id, f) { var el = document.getElementById(id); if (el) el.onclick = f; };
    on('cFlash', onFlash);
    var fP = document.getElementById('cFlashP'); if (fP) { fP.onchange = function () { fP.value = setPause(fP.value).toFixed(1); }; }
    var fN = document.getElementById('cFlashN'); if (fN) { fN.oninput = function () { if (fN.value !== '') flash.n = clampFlash(fN.value); }; fN.onchange = function () { fN.value = flash.n = clampFlash(fN.value); save('flashCount', flash.n); }; }
    on('btnUpdApp', applyUpdate);
    on('cTrunk', onTrunk); on('cSentry', onSentry);
    on('cLock', onLock); on('cVent', onVent); on('cClose', onClose); on('cClim', onClim);
    on('cTdn', function () { onTemp(-1); }); on('cTup', function () { onTemp(1); });
    on('bRemind', openReminder); on('bRemSetup', openRemSetup); on('btnLayout', function () { setLayout(layoutMode() === 'compact' ? 'full' : 'compact'); });
    on('cChgStart', onChgStart); on('cChgStop', onChgStop); on('cHeat', onHeat); on('cDefrost', onDefrost); on('cCop', onCop); on('sWheel', onWheel);
    on('btnCam', function () { camSetOn(!camOn()); }); camMount(); on('btnTot', totOpen);
    on('btnAlexa', function () { setAlexa(!alexaOn()); }); on('btnSched', function () { screen = 'settings'; render(); var e = document.getElementById('apps'); if (e) e.scrollIntoView(); });
    Array.prototype.forEach.call(document.querySelectorAll('[data-seat]'), function (g) { g.onclick = function () { if (!g.classList.contains('dis')) onSeat(g.getAttribute('data-seat')); }; });
    bindVSlider(); bindAmps();
    on('cAnnounce', onAnnounce); on('cAnnSetup', openAnnSetup); on('pkStop', onChgStop);
    on('pkHide', function () { var p = peakState(compute(getCfg()), getCfg()); if (p) save('peakHide', p.key); render(); }); on('pkShow', function () { save('peakHide', ''); render(); });
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
      readVehicleData: true, sendCommands: !!el('pCmd').checked, reminders: !!el('pRem').checked, announcements: !!(prev && prev.announcements), via: 'phone' };
  }
  // existing users (set up before v4.1): notice first, no Tessie calls until they agree
  function renderConsent() {
    var cfg = getCfg();
    $app.innerHTML = '<div class="wrap form">' + testBanner() + '<div class="hdr"><div class="brand">TESSDESK</div></div>' +
      '<h1>Before we connect</h1><p class="lead">TessDesk asks for your OK before it reads your car again.</p>' + noticeHtml() +
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
        (remCh('text') ? '<a class="btn ghost" id="rS" href="' + smsUrl(rep) + '">Text message (send now)</a><div class="rn">Opens Messages with the text ready' + (remCfg().phone ? ' to ' + esc(remCfg().phone) : '') + '. It goes out when you tap Send; it is <b>not</b> scheduled.</div>' : '') +
        (remCh('alexa') && annReady() ? '<button class="btn ghost" id="rA">Announce on Alexa</button><div class="rn" id="rAm">Your Echo (' + esc(annCfg().device) + ') says it now. Scheduled announcements come from the PC app.</div>' : '') +
        '<a class="btn ghost" id="rM" href="' + mailtoUrl(rep) + '">Email draft</a>' +
        '<div class="rn">Opens your mail app with a draft' + ((getCfg() || {}).remindEmail ? ' to ' + esc(getCfg().remindEmail) : '') + '. It goes out when you tap Send (now). It is <b>not</b> scheduled.</div>' +
        '<div class="rn muted">The TessDesk web app can\u2019t send anything by itself in the background. These options hand the reminder to your calendar, messages or mail app. The desktop widget can email, text, announce on Alexa or show a Windows notification at the time you pick.</div>' +
        '<div class="mbtns"><button class="btn ghost" id="rBack">Back</button><button class="btn ghost" id="rDone">Done</button></div></div>';
      d.querySelector('#rBack').onclick = step1; d.querySelector('#rDone').onclick = close;
      var ra = d.querySelector('#rA'); if (ra) ra.onclick = function () { var r = announce('Reminder: get air in your tires. ' + rep.lines.join(', ') + '.', 'reminder', true); d.querySelector('#rAm').textContent = r.result === 'sending' ? 'Sent to Voice Monkey.' : r.result; };
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
      connectedApps(cfg) +
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
      var nc = getCfg(); nc.announce = readAnnounceForm(cfg.announce); if (nc.consent) nc.consent.announcements = !!el('aDisc').checked; save('cfg', nc);
      save('dryRun', el('fDry').checked);
      if (VARIANT === 'test') save('resetOnLaunch', el('fReset').checked);
      if (changedCar) { cache = { state: null, charges: null, stateAt: 0, chargesAt: 0 }; live = null; save('cache', cache); save('live', null); }
      screen = 'main'; render(); refresh(true); startTimer();
    };
    bindConnectedApps();
    if (!first) {
      el('bCancel').onclick = function () { screen = 'main'; render(); };
      el('bLogout').onclick = function () {
        if (!confirm('Log out and erase your token and settings from this phone?')) return;
        clearAll(); cache = { state: null, charges: null, stateAt: 0, chargesAt: 0 }; live = null; screen = 'main'; stopTimer(); render();
      };
    }
  }

  // ---------- v4.3: OFF-PEAK CHARGING WARNING ----------
  // PSO RSEV is cheap only 11 PM - 6 AM CT. Charging (or starting) outside that window, at home (when a home location is set in
  // cfg.home {lat, lon, radiusM}) or otherwise on any AC charger (Superchargers / DC fast are skipped) -> banner + one-tap Stop.
  function hourLabel(h) { h = ((h % 24) + 24) % 24; return (h % 12 || 12) + ' ' + (h < 12 ? 'AM' : 'PM'); }
  function distM(a, b, c, d) { var R = 6371000, r = Math.PI / 180, x = (d - b) * r * Math.cos((a + c) / 2 * r), y = (c - a) * r; return Math.sqrt(x * x + y * y) * R; }
  // v4.3 RATE STATUS (PSO RSEV from Settings > Electricity rates): off-peak onStart-onEnd, summer weekday peak, day rate otherwise.
  function tdNow() { return window.__tdNow || nowSec(); }
  function rateKind(r, c) { var on0 = r.onStart != null ? r.onStart : 23, on1 = r.onEnd != null ? r.onEnd : 6, pk = r.peak || {}; if (inHours(c.h, on0, on1)) return 'offpeak'; var e = energyRate(r, c); return (pk.enabled && Math.abs(e - pk.rate) < 1e-9) ? 'peak' : 'day'; }
  function nextKind(r, t, want) { var k0 = rateKind(r, ct(t)), c0 = ct(t), x = t - c0.mi * 60 + 3600; for (var i = 0; i < 96; i++, x += 3600) { var k = rateKind(r, ct(x)); if ((want && k === want) || (!want && k !== k0)) return { at: x, kind: k }; } return null; }
  function c1(x) { return (Math.round(x * 1000) / 10).toFixed(1) + '\u00a2/kWh'; }
  function leftTxt(m) { m = Math.max(0, Math.round(m)); return m >= 60 ? Math.floor(m / 60) + 'h ' + ('0' + (m % 60)).slice(-2) + 'm' : m + 'm'; }
  function rateStatus(v, cfg) {
    if (!cfg) return null;
    var r = cfg.rates || PRESETS.pso, t = tdNow(), c = ct(t), k = rateKind(r, c), e = energyRate(r, c), fca = r.fca || 0, pk = r.peak || {};
    var on0 = r.onStart != null ? r.onStart : 23, on1 = r.onEnd != null ? r.onEnd : 6;
    var o = { mode: 'idle', kind: k, label: k === 'offpeak' ? 'Off-peak' : k === 'peak' ? 'Peak' : 'Day rate', red: k === 'peak', rate: e, allIn: e + fca, off: r.overnight, offAllIn: r.overnight + fca,
      start: hourLabel(on0), end: hourLabel(on1), untilOff: null, next: nextKind(r, t, ''), extra: null, reason: 'not charging', key: '', now: t };
    if (k !== 'offpeak') { var no = nextKind(r, t, 'offpeak'); if (no) o.untilOff = (no.at - t) / 60; }
    if (!v) return o;
    var cs = v.cs || {}, st = chgState(v.car);
    if (st !== 'Charging' && st !== 'Starting') return o;
    var ft = String(cs.fast_charger_type || '');
    if (cs.fast_charger_present || /supercharg|ccs|chademo|\bdc\b|combo/i.test(ft)) { o.reason = 'DC fast charging'; return o; }
    var home = cfg.home, ds = (v.state && v.state.drive_state) || {};
    if (home && home.lat != null && home.lon != null && ds.latitude != null && ds.longitude != null) {
      o.atHome = distM(+home.lat, +home.lon, +ds.latitude, +ds.longitude) <= (home.radiusM || 250);
      if (!o.atHome) { o.reason = 'away from home'; return o; }
    }
    o.key = (live && !live.done && live.start) ? 's' + live.start : 'd' + c.y + '-' + c.mo + '-' + c.d + '-' + (cs.charge_energy_added > 0 ? 'x' : c.h);
    if (k === 'offpeak') { o.mode = 'charging-offpeak'; o.reason = 'charging off-peak'; return o; }
    o.mode = 'charging-high'; o.reason = k === 'peak' ? 'summer weekday peak' : 'day rate';
    var add = +cs.charge_energy_added || 0, rem = (cs.charger_power > 0 && cs.minutes_to_full_charge > 0) ? cs.charger_power * cs.minutes_to_full_charge / 60 : 0;
    if (add + rem > 0) o.extra = (add + rem) / (cfg.eff || 0.9) * (o.allIn - o.offAllIn);
    return o;
  }
  // old name kept for the rundown / hooks: non-null only while charging at the day or peak rate
  function peakState(v, cfg) { var o = rateStatus(v, cfg); return o && o.mode === 'charging-high' ? o : null; }
  function peakBanner(rs) {
    if (!rs) return '';
    var cmdOk = cmdAllowed();
    if (rs.mode === 'charging-high') {
      var col = rs.red ? 'red' : 'amber', hidden = load('peakHide', '') === rs.key;
      var txt = (rs.red ? 'PEAK RATE' : 'DAY RATE') + ' \u00b7 charging costs more \u00b7 off-peak starts ' + rs.start + (rs.untilOff != null ? ' (in ' + leftTxt(rs.untilOff) + ')' : '');
      if (hidden) return '<button class="peak-mini ' + col + '" id="pkShow">\u26a0 ' + esc(txt) + '</button>';
      return '<div class="peak ' + col + '" id="peakBanner" role="alert"><div class="pk-top"><span class="pk-ic">\u26a0</span><div class="pk-t"><b>' + esc(txt) + '</b>' +
        '<small>Now ' + c1(rs.rate) + ' (' + (Math.round(rs.allIn * 1000) / 10).toFixed(1) + '\u00a2 all-in) vs ' + c1(rs.off) + ' off-peak' + (rs.atHome ? ' \u00b7 at home' : '') + '</small>' +
        (rs.extra != null ? '<small class="pk-extra">\u2248 +' + money(rs.extra) + ' extra this session vs charging off-peak</small>' : '') + '</div>' +
        '<button class="pk-x" id="pkHide" aria-label="Fold to one line for this charge">\u00d7</button></div>' +
        '<div class="pk-row"><button class="pk-stop" id="pkStop"' + (cmdOk && !ctlBusy ? '' : ' disabled') + '>\u25a0 Stop charging</button>' +
        '<div class="pk-tip"><b>Tip:</b> in the car set <b>Charging \u2192 Scheduled Charging</b> to start at <b>' + rs.start + '</b>, so it waits for off-peak by itself.</div></div></div>';
    }
    if (rs.mode === 'charging-offpeak')
      return '<div class="rate-pill green" id="rateStatus"><span class="rp-ic">\u2713</span><b>OFF-PEAK \u00b7 ' + c1(rs.off) + ' \u00b7 <span class="nw">cheapest rate until ' + String(rs.end).replace(' ', '\u00a0') + '</span></b><small>' + (Math.round(rs.offAllIn * 1000) / 10).toFixed(1) + '\u00a2/kWh all-in with the fuel adjustment</small></div>';
    var t = rs.kind === 'offpeak' ? 'Off-peak now \u00b7 ' + c1(rs.rate) + ' \u00b7 ends ' + rs.end + (rs.next ? ' (in ' + leftTxt((rs.next.at - rs.now) / 60) + ')' : '')
                                  : rs.label + ' now \u00b7 ' + c1(rs.rate) + ' \u00b7 off-peak in ' + (rs.untilOff != null ? leftTxt(rs.untilOff) : '?');
    if (rs.reason === 'DC fast charging' || rs.reason === 'away from home') t += ' \u00b7 ' + rs.reason;
    return '<div class="rate-line" id="rateStatus">\u23f1 ' + esc(t) + '</div>';
  }
  function sayCents(x) { return (Math.round(x * 1000) / 10).toString() + ' cents a kilowatt hour'; }
  function sayRate(rs) {
    if (!rs) return '';
    if (rs.kind === 'offpeak') return 'Rate: off-peak, ' + sayCents(rs.rate) + ', the cheapest, until ' + rs.end + '.';
    var x = 'Rate: ' + (rs.kind === 'peak' ? 'peak' : 'day') + ', ' + sayCents(rs.rate) + ', off-peak at ' + rs.start + (rs.untilOff != null ? ', in ' + sayDur(rs.untilOff) : '');
    if (rs.mode === 'charging-high' && rs.extra != null) x += '. About ' + sayMoney(rs.extra) + ' extra versus off-peak';
    return x + '.';
  }
  function sayDur(m) { m = Math.round(m); var h = Math.floor(m / 60), mm = m % 60; return m < 60 ? m + ' minute' + (m === 1 ? '' : 's') : h + ' hour' + (h === 1 ? '' : 's') + (mm ? ' ' + mm + ' minute' + (mm === 1 ? '' : 's') : ''); }

  // ---------- v4.3: VERTICAL CHARGE-LIMIT SLIDER (50-100 %, Daily 80 % tick, 90 % tick; % on the thumb) ----------
  var pendLimit = null;
  function vsF(p, lo, hi) { return hi > lo ? Math.max(0, Math.min(100, (p - lo) / (hi - lo) * 100)) : 0; }
  function vSlider(b, col, car, perPct) {
    var lo = car.limitMin != null ? car.limitMin : 50, hi = car.limitMax != null ? car.limitMax : 100, dis = (ctlBusy || !cmdAllowed());
    var shown = pendLimit != null ? pendLimit : b, f = shown != null ? vsF(shown, lo, hi) : 0;
    function tick(p, cls, lbl) { if (p < lo || p > hi) return ''; return '<div class="vs-tick ' + cls + '" style="bottom:' + vsF(p, lo, hi) + '%"><span>' + lbl + '</span></div>'; }
    return '<div class="vs' + (dis ? ' dis' : '') + (pendLimit != null ? ' pend' : '') + '" id="vs" role="slider" tabindex="0" aria-orientation="vertical" aria-label="Charge limit" aria-valuemin="' + lo + '" aria-valuemax="' + hi + '" aria-valuenow="' + shown + '" title="Drag up / down (or mouse wheel) to set the charge limit">' +
      '<div class="vs-rail" id="vsRail"><div class="vs-track"></div><div class="vs-fill ' + col + '-bg" id="vsFill" style="height:' + f + '%"></div>' +
      tick(hi, 'end', hi) + tick(90, 'p90', '90') + tick(80, 'daily', '80<em>DAILY</em>') + tick(lo, 'end', lo) +
      '<div class="vs-thumb" id="vsThumb" style="bottom:' + f + '%"><b id="vsPct">' + (shown != null ? shown + '%' : '--') + '</b><small id="vsMi">' + (perPct && shown != null ? Math.round(perPct * shown) + ' mi' : 'LIMIT') + '</small></div></div></div>';
  }
  function bindVSlider() {
    var vs = document.getElementById('vs'), rail = document.getElementById('vsRail'); if (!vs || !rail || !lastBatt) return;
    var lo = lastBatt.min != null ? lastBatt.min : 50, hi = lastBatt.max != null ? lastBatt.max : 100, cur = null, wheelT = null, mode = null;
    function off() { return ctlBusy || !cmdAllowed(); }
    function pctAt(y) { var r = rail.getBoundingClientRect(); var p = Math.round(hi - (y - r.top) / r.height * (hi - lo)); return Math.max(lo, Math.min(hi, p)); }
    function show(p) {
      cur = p; var f = vsF(p, lo, hi), mi = lastBatt.perPct ? Math.round(lastBatt.perPct * p) + ' mi' : '';
      document.getElementById('vsThumb').style.bottom = f + '%'; document.getElementById('vsFill').style.height = f + '%';
      document.getElementById('vsPct').textContent = p + '%'; document.getElementById('vsMi').textContent = mi || 'LIMIT'; vs.setAttribute('aria-valuenow', p);
      var dv = document.getElementById('dragVal'); if (dv) dv.textContent = limitLabel(p);
      var lp = document.getElementById('limPct'); if (lp) lp.textContent = p + '%';
      var lm = document.getElementById('limMi'); if (lm) lm.textContent = mi || '\u00a0';
      var bt = document.getElementById('battTop'), bd = document.getElementById('battDrag'); if (bt) bt.classList.add('hidden'); if (bd) bd.classList.remove('hidden');
    }
    function begin(m) { dragging = true; mode = m; vs.classList.add('drag'); if (cur == null) cur = lastBatt.limit != null ? lastBatt.limit : 80; }
    function end(commit) { if (!dragging || !mode) return; dragging = false; mode = null; vs.classList.remove('drag'); if (commit && cur != null && cur !== lastBatt.limit) requestLimit(cur); else { cur = null; render(); } }
    rail.addEventListener('pointerdown', function (e) { if (off()) return; begin('ptr'); try { rail.setPointerCapture(e.pointerId); } catch (x) {} show(pctAt(e.clientY)); e.preventDefault(); });
    rail.addEventListener('pointermove', function (e) { if (mode === 'ptr') show(pctAt(e.clientY)); });
    rail.addEventListener('pointerup', function () { if (mode === 'ptr') end(true); });
    rail.addEventListener('pointercancel', function () { if (mode === 'ptr') end(false); });
    function step(d) { if (off()) return; if (!mode) begin('step'); show(Math.max(lo, Math.min(hi, cur + d))); clearTimeout(wheelT); wheelT = setTimeout(function () { end(true); }, 900); }
    vs.addEventListener('wheel', function (e) { if (off()) return; e.preventDefault(); step(e.deltaY < 0 ? 1 : -1); }, { passive: false });
    vs.addEventListener('keydown', function (e) {
      var k = e.key, d = k === 'ArrowUp' || k === 'ArrowRight' ? 1 : (k === 'ArrowDown' || k === 'ArrowLeft' ? -1 : (k === 'PageUp' ? 5 : (k === 'PageDown' ? -5 : 0)));
      if (d) { e.preventDefault(); step(d); } else if (k === 'Enter' && mode === 'step') { clearTimeout(wheelT); end(true); }
    });
  }

  // ---------- v4.3: ANNOUNCE ON ALEXA: one push, full status rundown (Voice Monkey, 1 or 2 announcements, < ~45 s) ----------
  var RUN_ITEMS = [['battery', 'Battery and range'], ['limit', 'Charge limit'], ['rate', 'Charge rate (kW and amps)'], ['tofull', 'Time to full'],
    ['cost', 'Tonight\u2019s cost (and last charge)'], ['climate', 'Climate and seats'], ['lock', 'Door lock'], ['windows', 'Windows'], ['tires', 'Tires (all four)'], ['warnings', 'Warnings']];
  var WPS = 2.6;   // spoken words per second (Alexa announcement voice)
  function runItems() { var s = load('annItems', null) || {}; var o = {}; RUN_ITEMS.forEach(function (it) { o[it[0]] = s[it[0]] !== false; }); return o; }
  function sayMoney(v) { if (v == null || isNaN(v)) return 'unknown'; var c = Math.round(v * 100), d = Math.floor(c / 100), ce = c % 100;
    return (d ? d + (d === 1 ? ' dollar' : ' dollars') : '') + (d && ce ? ' and ' : '') + (ce || !d ? ce + (ce === 1 ? ' cent' : ' cents') : ''); }
  function sayMins(m) { m = Math.round(m); var h = Math.floor(m / 60), mm = m % 60; return (h ? h + (h === 1 ? ' hour' : ' hours') : '') + (h && mm ? ' ' : '') + (mm || !h ? mm + (mm === 1 ? ' minute' : ' minutes') : ''); }
  function sayAge(t) { var a = Math.max(0, nowSec() - t); return a < 90 ? 'just now' : (a < 3600 ? Math.round(a / 60) + ' minutes ago' : (a < 7200 ? 'about an hour ago' : 'about ' + Math.round(a / 3600) + ' hours ago')); }
  function buildRundown(only) {
    var cfg = getCfg(); var v = cfg && compute(cfg); if (!v) return null;
    var it = only || runItems(), car = v.car, cs = v.cs, out = [], st = chgState(car), chg = st === 'Charging';
    var lim = ctlVal('limit', v.limit), per = (v.range > 0 && v.soc > 0) ? v.range / v.soc : null;
    if (it.battery && v.soc != null) out.push('Your Tesla is at ' + v.soc + ' percent' + (v.range > 0 ? ', ' + Math.round(v.range) + ' miles of range' : '') + '.');
    if (it.limit && lim != null) out.push('Charge limit ' + lim + ' percent' + (per ? ', about ' + Math.round(per * lim) + ' miles' : '') + '.');
    if (it.rate) {
      if (chg) { var kw = chargerKw(cs), am = car.ampsNow != null ? Math.round(car.ampsNow) : ctlVal('amps', car.ampsReq);
        out.push('Charging at ' + (kw != null ? (Math.round(kw * 10) / 10) + ' kilowatts' : 'an unknown rate') + (am != null ? ', ' + am + ' amps' : '') + (cs.fast_charger_present ? ' on a fast charger' : '') + '.'); }
      else out.push(({ Complete: 'Charging is complete.', Stopped: 'Plugged in, charging stopped.', Disconnected: 'Not plugged in.', NoPower: 'Plugged in, but there is no power.', Starting: 'Charging is starting.' })[st] || 'Not charging.');
    }
    if (it.tofull && chg && cs.minutes_to_full_charge > 0) out.push('Full in ' + sayMins(cs.minutes_to_full_charge) + ', around ' + clock(nowSec() + cs.minutes_to_full_charge * 60) + '.');
    if (it.cost) {
      var nl = v.nightLabel === 'Tonight' ? 'Tonight so far' : 'Last night';
      out.push(nl + ', ' + sayMoney(v.night.cost) + '.' + (v.hero && v.heroCost ? (chg ? ' This charge, ' : ' Last charge, ') + sayMoney(v.heroCost.cost) + '.' : ''));
      out.push(sayRate(rateStatus(v, cfg)));
    }
    if (it.climate) {
      var clim = ctlVal('climateOn', car.climateOn), cl = (v.state && v.state.climate_state) || {}, bits = [];
      var tIn = car.insideC != null ? spokenTemp(car.insideC, car.units) : null, tOut = cl.outside_temp != null ? spokenTemp(cl.outside_temp, car.units) : null;
      var s = 'Climate ' + (clim ? (heatOn(car) ? 'on, heating' : 'on') : 'off') + (tIn ? ', inside ' + tIn : '') + (tOut ? ', outside ' + tOut : '') + '.';
      if (ctlVal('defrost', car.defrostOn)) bits.push('defrost on');
      var cop = ctlVal('cop', car.cop); if (cop) bits.push('overheat protection ' + (cop === 'FanOnly' ? 'fan only' : cop.toLowerCase()));
      var seats = [], names = { fl: 'driver', fr: 'passenger', rl: 'rear left', rc: 'rear center', rr: 'rear right' };
      Object.keys(names).forEach(function (k) { var l = seatLevel(car, k); if (l > 0) seats.push(names[k] + ' ' + l); });
      bits.push(seats.length ? 'seat heat ' + seats.join(', ') : 'seat heat off');
      if (ctlVal('wheel', car.wheelOn)) bits.push('wheel heat on');
      out.push(s + ' ' + bits.join(', ').replace(/^./, function (x) { return x.toUpperCase(); }) + '.');
    }
    if (it.lock) { var lk = ctlVal('locked', car.locked); out.push(lk == null ? 'Lock state unknown.' : (lk ? 'Doors locked.' : 'Doors are unlocked.')); }
    if (it.windows) {
      var W = car.windows || {}, WN = { fd: 'driver front', fp: 'passenger front', rd: 'driver rear', rp: 'passenger rear' }, open = [];
      var known = Object.keys(WN).filter(function (k) { return W[k] != null; });
      known.forEach(function (k) { if (+W[k] !== 0) open.push(WN[k]); });
      var ov = ctlVal('windowsOpen', car.windowsOpen);
      if (!known.length) out.push(ov == null ? 'Window state unknown.' : (ov ? 'Windows vented.' : 'All windows up.'));
      else if (ov === false || !open.length) out.push('All windows up.');
      else if (open.length === 4) out.push('All four windows are down or vented.');
      else out.push(open.join(' and ') + ' window' + (open.length > 1 ? 's' : '') + ' down or vented, the rest up.');
    }
    var T = v.tires, TN = { fl: 'front left', fr: 'front right', rl: 'rear left', rr: 'rear right' };
    if (it.tires && T) {
      var ps = ['fl', 'fr', 'rl', 'rr'].map(function (k) { return T[k].psi == null ? null : Math.round(T[k].psi); });
      var rec = T.recF != null ? Math.round(T.recF) : 42, recR = T.recR != null ? Math.round(T.recR) : rec;
      if (ps.every(function (p) { return p == null; })) out.push('Tire pressures unknown.');
      else out.push('Tires: ' + ['fl', 'fr', 'rl', 'rr'].map(function (k, i) { return TN[k] + ' ' + (ps[i] == null ? 'unknown' : ps[i]); }).join(', ') + ' PSI, recommended ' + (recR !== rec ? rec + ' front and ' + recR + ' rear' : rec) + '.');
    }
    if (it.warnings) {
      var w = [], pk = peakState(v, cfg);
      if (pk && !it.cost) w.push('charging at the ' + (pk.red ? 'peak' : 'day') + ' rate, off-peak starts at ' + pk.start);
      if (T) ['fl', 'fr', 'rl', 'rr'].forEach(function (k) { var f = T[k].flag || ''; if (/-(low|high)$/.test(f)) w.push(TN[k] + ' tire ' + (/high$/.test(f) ? 'high' : 'low')); });
      if (lim != null && lim > 90) w.push('charge limit above 90 percent');
      out.push(w.length ? 'Warning' + (w.length > 1 ? 's' : '') + ': ' + w.join('; ') + '.' : 'No warnings.');
    }
    if (v.updated) out.push('Updated ' + sayAge(v.updated) + '.');
    if (out.length <= 1) return { parts: [], words: 0, seconds: 0, text: '' };
    out[0] = 'TessDesk status. ' + out[0];
    var words = out.join(' ').split(/\s+/).length, parts = [out.join(' ')];
    if (words / WPS > 22) {   // two announcements, split near the middle at a sentence boundary
      var acc = 0, half = words / 2, i = 0;
      for (; i < out.length - 1; i++) { acc += out[i].split(/\s+/).length; if (acc >= half) break; }
      parts = [out.slice(0, i + 1).join(' '), out.slice(i + 1).join(' ')];
    }
    return { parts: parts, words: words, seconds: Math.round(words / WPS), text: parts.join(' ') };
  }
  function tdToast(msg, kind) {
    var t = document.getElementById('tdToast'); if (!t) { t = document.createElement('div'); t.id = 'tdToast'; document.body.appendChild(t); }
    t.className = 'td-toast show ' + (kind || ''); t.textContent = msg; clearTimeout(tdToast.t); tdToast.t = setTimeout(function () { t.className = 'td-toast'; }, 4200);
  }
  function openConnectedApps() { screen = 'settings'; render(); setTimeout(function () { var e = document.getElementById('apps'); if (e) e.scrollIntoView(); }, 50); }
  function onAnnounce() {
    if (!annConsent() || !annCfg().token || !annCfg().device) { tdToast(!annConsent() ? 'Accept the Alexa disclosure first (Connected apps).' : 'Set up Voice Monkey first (Connected apps).', 'err'); openConnectedApps(); return; }
    var r = buildRundown(); if (!r || !r.parts.length) { tdToast('Nothing to announce yet (no car data, or every item is off in Setup).', 'err'); return; }
    confirmBox('Announce full status?', 'Announce', r.parts.length + ' announcement' + (r.parts.length > 1 ? 's' : '') + ' \u00b7 about ' + r.seconds + ' s on ' + targetsLabel(annTargets('rundown'))).then(function (ok) {
      if (!ok) return; sendRundown(r);
    });
  }
  function sendRundown(r) {
    var a = annCfg(), dry = !!load('dryRun', false), results = [], tg = annTargets('rundown');
    function one(i) {
      if (i >= r.parts.length) return Promise.resolve();
      var txt = r.parts[i], rec = { at: new Date().toISOString(), why: 'rundown ' + (i + 1) + '/' + r.parts.length, text: txt, device: tg.join(','), dryRun: dry, sent: false, result: '' };
      annLog.push(rec); if (annLog.length > 40) annLog.shift();
      if (dry) { rec.result = 'DRY RUN: not sent to Voice Monkey'; results.push(true); return one(i + 1); }
      rec.sent = true; rec.result = 'sending'; var okN = 0, chain = Promise.resolve();
      tg.forEach(function (dev) { chain = chain.then(function () { return vmPost(dev, txt).then(function (res) { if (res.ok) okN++; }, function () {}); }); });
      return chain.then(function () { rec.result = okN === tg.length ? 'announced' : (okN ? 'announced on ' + okN + ' of ' + tg.length : 'failed'); results.push(okN > 0); })
        .then(function () { if (i + 1 < r.parts.length && results[i]) return new Promise(function (ok) { setTimeout(ok, Math.round(txt.split(/\s+/).length / WPS * 1000) + 1500); }).then(function () { return one(i + 1); }); });
    }
    tdToast(dry ? 'Dry run: building the announcement\u2026' : 'Announcing on ' + targetsLabel(tg) + '\u2026');
    one(0).then(function () {
      var ok = results.length === r.parts.length && results.every(Boolean);
      tdToast(dry ? '\u2713 Dry run: ' + r.parts.length + ' announcement' + (r.parts.length > 1 ? 's' : '') + ' logged, nothing sent' : (ok ? '\u2713 Announced on ' + targetsLabel(tg) : '\u2715 Announcement failed (' + (annLog[annLog.length - 1] || {}).result + ')'), ok ? 'ok' : 'err');
    });
  }
  function openAnnSetup() {
    var d = document.createElement('div'); d.className = 'modal'; var cur = runItems();
    d.innerHTML = '<div class="mbox rem annset" role="dialog" aria-modal="true"><div class="mq">Announce on Alexa: Setup</div>' +
      '<div class="rl">One push of <b>Announce on Alexa</b> speaks a full status rundown on your Echo. Pick what it includes:</div>' +
      '<div class="ann-items">' + RUN_ITEMS.map(function (x) { return '<label class="check"><input type="checkbox" data-it="' + x[0] + '"' + (cur[x[0]] ? ' checked' : '') + '> ' + esc(x[1]) + '</label>'; }).join('') + '</div>' +
      '<div class="inline3"><button class="btn ghost" id="asAll">All on</button><button class="btn ghost" id="asNone">All off</button><button class="btn ghost" id="asPrev">Preview</button></div>' +
      '<div class="ann-prev" id="asOut">Preview shows the exact spoken text. Nothing is announced.</div>' +
      '<div class="sect">Speakers (Echos)</div><label class="check"><input type="checkbox" id="asEcAll"' + (spkCfg().all !== false ? ' checked' : '') + '> <span><b id="asAllLbl">All Echos</b> <small class="muted">every Voice Monkey speaker</small></span></label>' +
      '<details class="spk-dd" id="asDd"><summary><span id="asDdTxt"></span></summary><div class="spk-list" id="asSpk"></div><div class="rn">Tick = this Echo announces. Test plays one short line on that Echo only, and only when you tap it.</div></details>' +
      '<div class="inline2"><button class="btn" id="asAdd" type="button">+ Add speaker</button><button class="btn ghost" id="asSpkRef" type="button">\u27f3 Refresh list</button></div><div class="rn" id="asSpkMsg"></div>' +
      '<div class="spk-add" id="asAddBox" hidden><b>Add a speaker (another Echo)</b><div class="rn">Voice Monkey lets apps list speakers but not create them, so the new speaker is made on the Voice Monkey page and linked to the Echo with one Alexa Routine.</div>' +
      '<label class="lbl" for="asAddName">Name</label><input id="asAddName" maxlength="40" placeholder="e.g. Kitchen Echo" autocomplete="off">' +
      '<a class="btn" id="asOpen" href="' + VM_SPEAKERS_URL + '" target="_blank" rel="noopener">Open Voice Monkey \u00b7 Add New Speaker</a>' +
      '<ol class="spk-steps" id="asSteps"></ol>' +
      '<div class="inline3"><button class="btn" id="asRef2" type="button">\u27f3 Refresh list</button><a class="btn ghost" href="' + VM_ADD_DOC + '" target="_blank" rel="noopener">Guide</a><button class="btn ghost" id="asAddX" type="button">Close</button></div><div class="rn" id="asAddMsg"></div></div>' +
      '<div class="mbtns"><button class="btn ghost" id="asNo">Cancel</button><button class="btn" id="asSave">Save</button></div></div>';
    document.body.appendChild(d);
    var sel = {}, newIds = [], sc0 = spkCfg(); (sc0.ids || []).forEach(function (id) { sel[id] = true; });
    function q(x) { return d.querySelector(x); }
    function allOn() { return q('#asEcAll').checked; }
    function spkHtml() {
      var all = allOn(), sp = vmSpeakers();
      if (!sp.length) return '<div class="rn">No speaker list yet. Tap Refresh list (reads your Voice Monkey speakers, announces nothing). Until then: ' + esc(annCfg().device || 'no device') + '.</div>';
      return sp.map(function (x) { var nw = newIds.indexOf(x.id) >= 0; return '<div class="spk-row"><label class="check"><input type="checkbox" data-spk="' + esc(x.id) + '"' + (all || sel[x.id] ? ' checked' : '') + (all ? ' disabled' : '') + '> <span>' + esc(x.name) + (nw ? ' <em class="spk-new">NEW</em>' : '') + '<small class="muted">' + esc(x.id) + '</small></span></label><button class="btn ghost spk-test" type="button" data-test="' + esc(x.id) + '">\u25b6 Test</button></div>'; }).join('');
    }
    function summary() {
      var sp = vmSpeakers(), all = allOn(); if (!sp.length) return 'No speakers listed yet';
      var on = sp.filter(function (x) { return all || sel[x.id]; }); if (!on.length) return 'No speaker ticked (0 of ' + sp.length + ')';
      return on.map(function (x) { return x.name; }).join(', ') + ' (' + on.length + ' of ' + sp.length + ')';
    }
    function head() { q('#asAllLbl').textContent = 'All Echos (' + vmSpeakers().length + ')'; q('#asDdTxt').textContent = summary(); }
    function drawSpk() { q('#asSpk').innerHTML = spkHtml(); head(); }
    function steps() { var n = q('#asAddName').value.trim(), nm = n ? '\u201c' + esc(n) + '\u201d' : 'your new speaker';
      q('#asSteps').innerHTML = '<li><b>Voice Monkey:</b> Add New Speaker, paste ' + nm + ', then Create Speaker (sign in if asked).</li>' +
        '<li><b>Alexa app</b> (the one step only you can do): More \u203a Routines \u203a + \u203a When this happens \u203a Smart Home \u203a Alexa Voice Monkey v3 \u203a VM Speakers \u203a ' + nm + '. Add action \u203a Skills \u203a Voice Monkey (or Custom: \u201copen Voice Monkey\u201d). From: pick that Echo. Save.</li>' +
        '<li><b>Back here:</b> Refresh list. The new speaker shows up ticked. Tap its Test, then Save.</li>'; }
    drawSpk(); steps();
    q('#asEcAll').onchange = drawSpk;
    q('#asSpk').onchange = function (e) { var t = e.target; if (t && t.hasAttribute('data-spk')) { sel[t.getAttribute('data-spk')] = t.checked; head(); } };
    q('#asSpk').onclick = function (e) { var t = e.target.closest ? e.target.closest('[data-test]') : null; if (t) { e.preventDefault(); testSpeaker(t.getAttribute('data-test'), q('#asSpkMsg')); } };
    q('#asAdd').onclick = function () { var b = q('#asAddBox'); b.hidden = !b.hidden; if (!b.hidden) { q('#asAddName').focus(); b.scrollIntoView({ block: 'nearest' }); } };
    q('#asAddX').onclick = function () { q('#asAddBox').hidden = true; };
    q('#asAddName').oninput = function () { var v = this.value.replace(/[^A-Za-z0-9 ]/g, ''); if (v !== this.value) this.value = v; steps(); };
    q('#asOpen').onclick = function () { var n = q('#asAddName').value.trim(), m = q('#asAddMsg'); window.TessDesk && (window.TessDesk.lastOpen = { url: VM_SPEAKERS_URL, name: n });
      if (n && navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(n).then(function () { m.textContent = '\u201c' + n + '\u201d copied: paste it into the Voice Monkey name box.'; }, function () {});
      m.textContent = 'Opening Voice Monkey Speakers\u2026' + (n ? ' Name: ' + n : ''); };
    function doRefresh(fromAdd) { var m = q('#asSpkMsg'), m2 = q('#asAddMsg'), old = vmSpeakers().map(function (x) { return x.id; }); m.textContent = 'Reading your Voice Monkey speakers\u2026';
      refreshSpeakers().then(function (sp) {
        var nw = sp.filter(function (x) { return old.indexOf(x.id) < 0; }); nw.forEach(function (x) { sel[x.id] = true; if (newIds.indexOf(x.id) < 0) newIds.push(x.id); });
        var t = sp.length + ' speaker' + (sp.length === 1 ? '' : 's') + ' found' + (nw.length ? ' \u00b7 NEW: ' + nw.map(function (x) { return x.name; }).join(', ') + ' (ticked). Tap Test, then Save.' : (fromAdd ? ' \u00b7 nothing new yet. Finish Create Speaker in Voice Monkey, then Refresh list again.' : '.'));
        m.textContent = t; m2.textContent = t; drawSpk(); if (nw.length) q('#asDd').open = true;
      }, function (e) { m.textContent = 'Could not list speakers: ' + e.message; m2.textContent = m.textContent; }); }
    q('#asSpkRef').onclick = function () { doRefresh(false); }; q('#asRef2').onclick = function () { doRefresh(true); };
    function pick() { var o = {}; Array.prototype.forEach.call(d.querySelectorAll('[data-it]'), function (x) { o[x.getAttribute('data-it')] = x.checked; }); return o; }
    function all(v) { Array.prototype.forEach.call(d.querySelectorAll('[data-it]'), function (x) { x.checked = v; }); }
    d.querySelector('#asAll').onclick = function () { all(true); }; d.querySelector('#asNone').onclick = function () { all(false); };
    d.querySelector('#asPrev').onclick = function () {
      var r = buildRundown(pick()), o = d.querySelector('#asOut');
      if (!r || !r.parts.length) { o.textContent = 'Nothing to say (no car data, or every item is off).'; return; }
      o.innerHTML = r.parts.map(function (p, i) { return (r.parts.length > 1 ? '<b>Announcement ' + (i + 1) + ' of ' + r.parts.length + '</b><br>' : '') + esc(p); }).join('<br><br>') +
        '<div class="ann-meta">' + r.words + ' words \u00b7 about ' + r.seconds + ' s of speech</div>';
    };
    d.querySelector('#asNo').onclick = function () { d.remove(); };
    d.querySelector('#asSave').onclick = function () { save('annItems', pick());
      var c = getCfg(), a = c.announce || {}; a.speakers = { all: d.querySelector('#asEcAll').checked, ids: vmSpeakers().filter(function (x) { return sel[x.id]; }).map(function (x) { return x.id; }) };
      c.announce = a; save('cfg', c); d.remove(); try { if (cache.state) render(); } catch (e) {} tdToast('\u2713 Announce Setup saved \u00b7 ' + targetsLabel(annTargets('action'))); };
    d.onclick = function (e) { if (e.target === d) d.remove(); };
  }

  // ---------- refresh loop + pull to refresh ----------
  // v4.2 adaptive refresh, cached data only (never wakes the car), and only while the app is visible:
  // 10 s car active (charging / driving / climate / a control used in the last 3 min), 15 s car awake,
  // 60 s -> 120 s -> 300 s car asleep / offline, errors back off 30 s -> 300 s.
  var liveInfo = { interval: 15, reason: 'start', errors: 0, asleepRuns: 0, lastCmd: 0, polls: 0 };
  function nextDelay() {
    var st = cache.state, L = liveInfo;
    if (lastErr) { L.errors++; L.interval = lastErr.auth ? 600 : Math.min(300, 30 * Math.pow(2, L.errors - 1)); L.reason = lastErr.auth ? 'token rejected' : 'error backoff'; return L.interval; }
    L.errors = 0;
    if (!st) { L.interval = 15; L.reason = 'no data yet'; return 15; }
    var cs = st.charge_state || {}, ds = st.drive_state || {}, cl = st.climate_state || {};
    var active = cs.charging_state === 'Charging' || cs.charging_state === 'Starting' || ['D', 'R', 'N'].indexOf(ds.shift_state) >= 0 || !!cl.is_climate_on || (nowSec() - L.lastCmd) < 180;
    if (active) { L.asleepRuns = 0; L.interval = 10; L.reason = cs.charging_state === 'Charging' ? 'charging' : 'car active'; }
    else if (st.state && st.state !== 'online') { L.asleepRuns++; L.interval = L.asleepRuns > 6 ? 300 : (L.asleepRuns > 3 ? 120 : 60); L.reason = 'car ' + st.state; }
    else { L.asleepRuns = 0; L.interval = 15; L.reason = 'car awake'; }
    return L.interval;
  }
  function scheduleNext(ms) { if (timer) clearTimeout(timer); timer = setTimeout(function () { timer = null; if (document.visibilityState === 'visible' && getCfg() && consentOk()) { liveInfo.polls++; refresh(false); } else scheduleNext(15000); }, ms); }
  function startTimer() { stopTimer(); scheduleNext(nextDelay() * 1000); }
  function stopTimer() { if (timer) clearTimeout(timer); timer = null; }
  function updText(t) {
    var a = Math.max(0, nowSec() - t), st = cache.state || {};
    var age = a < 60 ? a + 's ago' : (a < 3600 ? Math.floor(a / 60) + 'm ago' : Math.floor(a / 3600) + 'h ago');
    return (st.state && st.state !== 'online' ? 'Car ' + esc(st.state) + ' \u00b7 ' : '<i class="dot' + (a <= 30 ? ' on' : '') + '"></i>') + 'Updated ' + age;
  }
  setInterval(function () { var e = document.getElementById('updAge'); if (e) e.innerHTML = updText(+e.getAttribute('data-t')); }, 1000);
  document.addEventListener('visibilitychange', function () { if (document.visibilityState === 'visible') checkUpdate(false); });
  document.addEventListener('visibilitychange', function () { if (document.visibilityState === 'visible' && getCfg() && screen === 'main' && nowSec() - cache.stateAt > 10) refresh(false); });
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
  // v4.3.3 test hooks (read-only; selfTest restores the live session it borrows)
  window.TessDesk433u = { check: function () { checkUpdate(true); }, state: function () { return upd; }, taps: function () { return window.__tdUpdTapped || 0; } };
  window.TessDesk433 = { drives: function () { var c = getCfg(); return c ? drivesList(c) : []; }, live: function () { return live; },
    selfTest: function () {
      var cfg = getCfg(), keepLive = live, keepCh = cache.charges, t = nowSec(), res = [];
      function cs(added, kw) { return { charge_state: { charging_state: 'Charging', charge_energy_added: added, charger_power: kw, battery_level: 70 } }; }
      function chk(name, got, want) { res.push(name + ' -> ' + JSON.stringify(got) + ' (expect ' + JSON.stringify(want) + ') ' + (JSON.stringify(got) === JSON.stringify(want) ? 'PASS' : 'FAIL')); }
      try {
        cache.charges = [];
        live = { start: t - 7200, socStart: 60, lastAdded: 3.0, lastAt: t - 2700, segs: [[t - 7200, t - 2700, 3.0]], done: true };
        trackLive(cfg, cs(3.4, 7.2));
        chk('counter kept running after a 45-min pause: same session, total kWh', [live.start === t - 7200, Math.round(live.segs.reduce(function (a, g) { return a + g[2]; }, 0) * 100) / 100], [true, 3.4]);
        live = { start: t - 7200, socStart: 60, lastAdded: 3.0, lastAt: t - 120, segs: [[t - 7200, t - 120, 3.0]], done: true };
        trackLive(cfg, cs(0.2, 7.2));
        chk('counter reset (re-plugged): new session with its own kWh only', [live.start > t - 7200, live.lastAdded], [true, 0.2]);
        var prev = { started_at: t - 2400, ended_at: t - 600, energy_added: 2.0 };
        cache.charges = [prev]; live = null; trackLive(cfg, cs(3.2, 7.2));
        var lv = liveSession(), c = fromCharge(prev);
        chk('joined 10 min after a 2.0 kWh part, counter 3.2 (carried): earlier part dropped', [lv.ownOnly, dupOfLive(c, lv)], [false, true]);
        cache.charges = [prev]; live = null; trackLive(cfg, cs(1.2, 7.2)); lv = liveSession();
        chk('joined 10 min after a 2.0 kWh part, counter 1.2 (reset): earlier part kept', [lv.ownOnly, dupOfLive(c, lv)], [true, false]);
        var p2 = { started_at: t - 9000, ended_at: t - 7200, energy_added: 2.0 };
        cache.charges = [p2]; live = null; trackLive(cfg, cs(12.0, 4.0)); lv = liveSession();
        chk('joined 2 h after a 2.0 kWh part, counter 12.0 at 4 kW (older than the gap = carried): earlier part dropped', [lv.ownOnly, dupOfLive(fromCharge(p2), lv)], [false, true]);
        cache.charges = [p2]; live = null; trackLive(cfg, cs(6.0, 4.0)); lv = liveSession();
        chk('joined 2 h after a 2.0 kWh part, counter 6.0 at 4 kW (fits the gap = reset): earlier part kept', [lv.ownOnly, dupOfLive(fromCharge(p2), lv)], [true, false]);
        var tn = { started_at: t - 300 - 224, ended_at: t - 300, energy_added: 0.16 };
        cache.charges = [tn]; live = null; trackLive(cfg, cs(0.2, 7.0)); lv = liveSession();
        chk('tonight: 0.16 kWh part, restarted 9 s later, counter 0.2: earlier part kept (no double count, no loss)', [lv.ownOnly, dupOfLive(fromCharge(tn), lv)], [true, false]);
      } catch (e) { res.push('ERROR ' + e.message); }
      live = keepLive; cache.charges = keepCh; save('live', live); render();
      return res;
    } };
  // ---------- v4.3.9: CAMERAS (not live: frames looped from saved Sentry / Dashcam clips picked on this phone) ----------
  // Tesla / Tessie give no live camera feed. Pick the clip files (TeslaCam ...-front.mp4, -back.mp4, -left_repeater.mp4, ...)
  // and TessDesk pulls 16 stills per camera with a <video> + <canvas>, loops them, and lets you capture or save.
  var CAM_KEYS = ['front', 'back', 'left_repeater', 'right_repeater', 'left_pillar', 'right_pillar'];
  var CAM_NAMES = { front: 'Front', back: 'Rear', left_repeater: 'Left repeater', right_repeater: 'Right repeater', left_pillar: 'Left pillar', right_pillar: 'Right pillar' };
  var CAM_TABS = [['front', 'Front'], ['back', 'Rear'], ['left_repeater', 'Left rep.'], ['right_repeater', 'Right rep.'], ['grid', '4-up']];
  var CAM_MAIL = 'vanwidick@gmail.com', CAM_FRAMES = 16;
  var cam = { el: null, files: {}, frames: {}, n: 0, idx: 0, playing: true, timer: null, job: null, tab: load('camTab', 'grid'), label: '', when: null,
    msg: '', fs: null, fsLayout: load('camFsLayout', 'one'), log: [] };
  function camOn() { return !!load('camOn', false); }
  function camFps() { var f = +load('camFps', 4); return f === 2 || f === 8 ? f : 4; }
  function camChip() {
    return '<button class="alexa camchip' + (camOn() ? ' on' : '') + '" id="btnCam" aria-pressed="' + camOn() + '" title="Camera panel On / Off (frames from your saved clips, not live)">' +
      '<svg viewBox="0 0 24 24"><path d="M4 8h3l2-2h6l2 2h3v11H4z"/><circle cx="12" cy="13" r="3.5"/></svg><i></i></button>';
  }
  function camSetOn(on) {
    save('camOn', !!on);
    if (!on) { camStop(); camStopPlay(); cam.frames = {}; cam.files = {}; cam.n = 0; cam.idx = 0; cam.msg = ''; camCloseFs(); }
    render();
    if (on) camPlay();
  }
  function camKeyOf(name, i) {
    var n = String(name || '').toLowerCase();
    for (var k = CAM_KEYS.length - 1; k >= 0; k--) { if (n.indexOf(CAM_KEYS[k]) >= 0) return CAM_KEYS[k]; }
    if (/(^|[-_])rear([-_.]|$)/.test(n)) return 'back';
    return CAM_KEYS[i] || null;
  }
  function camWhenOf(name) {
    var m = /(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})/.exec(String(name || ''));
    return m ? new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]) : null;
  }
  function camStamp(t) {
    var p = function (x) { return (x < 10 ? '0' : '') + x; };
    return t.getFullYear() + '-' + p(t.getMonth() + 1) + '-' + p(t.getDate()) + ' ' + p(t.getHours()) + ':' + p(t.getMinutes()) + ':' + p(t.getSeconds());
  }
  function camHave() { return CAM_KEYS.filter(function (k) { return cam.frames[k] && cam.frames[k].length; }); }
  function camPick() {
    var inp = document.createElement('input'); inp.type = 'file'; inp.accept = 'video/*,.mp4'; inp.multiple = true;
    inp.onchange = function () { camUseFiles(Array.prototype.slice.call(inp.files || [])); };
    inp.click();
  }
  function camUseFiles(list) {
    var vids = list.filter(function (f) { return /\.mp4$|\.mov$|\.m4v$/i.test(f.name) || /^video\//.test(f.type || ''); });
    if (!vids.length) { cam.msg = 'No video files picked. Pick the clip files from your TeslaCam folder.'; camPaint(); return; }
    camStop(); cam.files = {}; cam.frames = {}; cam.n = 0; cam.idx = 0;
    vids.sort(function (a, b) { return a.name < b.name ? -1 : 1; });
    // keep the newest clip per camera (Sentry events are often several 1-minute files)
    vids.forEach(function (f, i) { var k = camKeyOf(f.name, i); if (k) cam.files[k] = f; });
    var any = cam.files.front || cam.files[Object.keys(cam.files)[0]];
    cam.when = camWhenOf(any && any.name) || (any && any.lastModified ? new Date(any.lastModified) : null);
    var sentry = list.some(function (f) { return /sentry/i.test((f.webkitRelativePath || '') + f.name); });
    cam.label = (sentry ? 'SENTRY EVENT' : 'SAVED CLIP') + (cam.when ? ' \u00b7 ' + esc(dayLabel(cam.when / 1000)) + ', ' + clock(cam.when / 1000) : '');
    cam.msg = ''; camLoad();
  }
  // frame extraction: one camera at a time, progress counts, Stop cancels
  function camLoad() {
    var keys = CAM_KEYS.filter(function (k) { return cam.files[k]; });
    var job = { cancel: false, done: 0, total: keys.length * CAM_FRAMES, t0: Date.now() };
    cam.job = job; camPaint();
    var W = 640, ki = 0;
    function nextCam() {
      if (job.cancel) return finish(true);
      if (ki >= keys.length) return finish(false);
      var k = keys[ki++], f = cam.files[k], url = URL.createObjectURL(f);
      var v = document.createElement('video'); v.muted = true; v.playsInline = true; v.preload = 'auto'; v.src = url;
      var out = [], i = 0, dur = 0, cv = document.createElement('canvas'), done = false;
      function end() { if (done) return; done = true; URL.revokeObjectURL(url); v.removeAttribute('src'); try { v.load(); } catch (e) {} if (out.length) cam.frames[k] = out; nextCam(); }
      function seekNext() {
        if (job.cancel || i >= CAM_FRAMES) return end();
        // 16 stills spread over the clip (skip the very first and last 0.2 s)
        var t = Math.min(Math.max(0.2, dur - 0.2), 0.2 + (Math.max(0, dur - 0.4)) * (i / (CAM_FRAMES - 1)));
        v.currentTime = t;
      }
      v.onloadedmetadata = function () {
        dur = isFinite(v.duration) ? v.duration : 0;
        var w = v.videoWidth || 1280, h = v.videoHeight || 960, s = Math.min(1, W / w);
        cv.width = Math.round(w * s); cv.height = Math.round(h * s); seekNext();
      };
      v.onseeked = function () {
        try {
          cv.getContext('2d').drawImage(v, 0, 0, cv.width, cv.height);
          var at = cam.when ? new Date(+cam.when + v.currentTime * 1000) : null;
          out.push({ src: cv.toDataURL('image/jpeg', 0.82), at: at, t: v.currentTime });
        } catch (e) {}
        i++; job.done++; if (!cam.n || out.length > cam.n) cam.n = Math.max(cam.n, out.length);
        if (!cam.frames[k] || cam.frames[k] !== out) cam.frames[k] = out;
        camPaint(); seekNext();
      };
      v.onerror = function () { job.done += CAM_FRAMES - i; cam.msg = 'Could not read ' + f.name + ' (skipped).'; end(); };
    }
    function finish(stopped) {
      cam.job = null;
      cam.n = 0; camHave().forEach(function (k) { cam.n = Math.max(cam.n, cam.frames[k].length); });
      if (stopped) cam.msg = 'Stopped at ' + job.done + ' / ' + job.total + ' frames \u00b7 showing what loaded.';
      else if (!camHave().length) cam.msg = cam.msg || 'No frames could be read from these files.';
      cam.log.push({ ev: stopped ? 'stopped' : 'loaded', done: job.done, total: job.total, ms: Date.now() - job.t0 });
      if (cam.idx >= cam.n) cam.idx = 0;
      camPaint(); camPlay();
    }
    nextCam();
  }
  function camStop() { if (cam.job) cam.job.cancel = true; }
  function camStopPlay() { if (cam.timer) { clearInterval(cam.timer); cam.timer = null; } }
  function camPlay() {
    camStopPlay();
    if (!camOn() || !cam.playing) return;
    cam.timer = setInterval(function () {
      if (!cam.n || document.visibilityState !== 'visible') return;
      cam.idx = (cam.idx + 1) % cam.n; camPaintFrames();
    }, Math.round(1000 / camFps()));
  }
  function camFrame(k) { var a = cam.frames[k]; if (!a || !a.length) return null; return a[Math.min(cam.idx, a.length - 1)]; }
  var CAM_ICON = '<svg viewBox="0 0 24 24"><path d="M4 8h3l2-2h6l2 2h3v11H4z"/><circle cx="12" cy="13" r="3.5"/></svg>';
  function camTileHtml(k, big) {
    var f = camFrame(k);
    return '<div class="cam-tile' + (big ? ' big' : '') + '" data-k="' + k + '">' + (f ? '<img alt="" data-k="' + k + '" src="' + f.src + '">' : '<div class="cam-none">No ' + esc(CAM_NAMES[k]) + ' clip</div>') +
      '<span class="lbl">' + esc(CAM_NAMES[k].toUpperCase()) + '</span>' + (f && f.at ? '<span class="ts" data-ts="' + k + '">' + camStamp(f.at) + '</span>' : '') +
      (f ? '<button class="cap" type="button" data-cap="' + k + '" title="Capture this camera and email it">' + CAM_ICON + 'Capture</button>' : '') + '</div>';
  }
  function camViewKeys() {
    if (cam.tab !== 'grid') return [cam.tab];
    var four = ['front', 'back', 'left_repeater', 'right_repeater'];
    return four.some(function (k) { return cam.frames[k]; }) ? four : camHave().slice(0, 4);
  }
  function camCountTxt() { return (cam.n ? (cam.idx + 1) + ' / ' + cam.n : '0 / 0') + ' \u00b7 ' + camFps() + ' fps'; }
  function camPaint() {
    if (!cam.el) return;
    var have = camHave(), j = cam.job, h = '';
    h += '<div class="cam-h"><h3>Cameras</h3><span class="cam-pill">NOT LIVE \u00b7 FROM SAVED CLIPS</span><button class="icon-btn sm" type="button" data-cam="opts" aria-label="Camera options">' + ICON_GEAR + '</button></div>';
    h += '<div class="cam-tabs">' + CAM_TABS.map(function (t) { return '<button type="button" data-tab="' + t[0] + '"' + (cam.tab === t[0] ? ' class="on"' : '') + '>' + t[1] + '</button>'; }).join('') + '</div>';
    if (cam.label) h += '<div class="cam-ev"><span class="ev">\u25cf ' + cam.label + '</span><span class="src">Phone \u00b7 picked clips</span></div>';
    if (cam.opts) {
      h += '<div class="cam-opts"><div class="row"><span>Speed</span>' + [2, 4, 8].map(function (f) { return '<button type="button" data-fps="' + f + '"' + (camFps() === f ? ' class="on"' : '') + '>' + f + ' fps</button>'; }).join('') + '</div>' +
        '<div class="row"><span>Full screen</span><select id="camFsSel">' + camFsOptions() + '</select></div>' +
        '<div class="row"><span>Clips</span><button type="button" data-cam="pick">Pick other clips</button></div>' +
        '<small>TessDesk cannot see your cameras live (Tesla and Tessie do not offer that). It loops stills from Sentry / Dashcam clips you pick. Captures go to ' + CAM_MAIL + ' through your share sheet or mail app.</small></div>';
    }
    if (!have.length && !j) {
      h += '<div class="cam-empty"><b>Pick saved Sentry or Dashcam clips</b><small>From the TeslaCam folder (Files app or a Wi-Fi USB drive): SentryClips or SavedClips, pick the -front, -back, -left_repeater and -right_repeater .mp4 files of one event.</small>' +
        '<button class="cam-go" type="button" data-cam="pick">' + CAM_ICON + 'Pick clips</button></div>';
    } else {
      var keys = camViewKeys();
      h += '<div class="cam-view ' + (cam.tab === 'grid' ? 'grid' : 'single') + '">' + keys.map(function (k) { return camTileHtml(k, false); }).join('') + '</div>';
    }
    if (j) h += '<div class="cam-busy"><span>Loading frames ' + j.done + ' / ' + j.total + '</span><button type="button" data-cam="stop">Stop</button></div>';
    if (cam.save) h += '<div class="cam-busy"><span>Saving clip ' + cam.save.done + ' / ' + cam.save.total + '</span><button type="button" data-cam="stopsave">Stop</button></div>';
    if (have.length) {
      h += '<div class="cam-ctl"><button type="button" class="pp' + (cam.playing ? ' on' : '') + '" data-cam="play" aria-label="Play / pause">' + (cam.playing ? '<b>II</b>' : '<svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg>') + '</button>' +
        '<input type="range" id="camSl" min="0" max="' + Math.max(0, cam.n - 1) + '" value="' + cam.idx + '"><span class="cnt" id="camCnt">' + camCountTxt() + '</span>' +
        '<button type="button" data-cam="save" title="Save this Sentry clip" aria-label="Save clip"><svg viewBox="0 0 24 24"><path d="M12 4v11M7 10l5 5 5-5M5 20h14"/></svg></button>' +
        '<button type="button" class="fsb" data-cam="fs" aria-label="Full screen">\u2922<span> Full screen</span></button></div>';
    }
    if (cam.msg) h += '<div class="cam-msg">' + esc(cam.msg) + '</div>';
    cam.el.innerHTML = h;
    var sl = cam.el.querySelector('#camSl');
    if (sl) sl.oninput = function () { cam.idx = +sl.value; cam.playing = false; camStopPlay(); camPaintFrames(); var b = cam.el.querySelector('[data-cam=play]'); if (b) { b.classList.remove('on'); b.innerHTML = '<svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg>'; } };
    var fsSel = cam.el.querySelector('#camFsSel'); if (fsSel) fsSel.onchange = function () { cam.fsLayout = fsSel.value; save('camFsLayout', cam.fsLayout); };
  }
  function camPaintFrames() {
    [cam.el, cam.fs].forEach(function (root) {
      if (!root) return;
      Array.prototype.forEach.call(root.querySelectorAll('img[data-k]'), function (im) { var f = camFrame(im.getAttribute('data-k')); if (f && im.src !== f.src) im.src = f.src; });
      Array.prototype.forEach.call(root.querySelectorAll('[data-ts]'), function (s) { var f = camFrame(s.getAttribute('data-ts')); if (f && f.at) s.textContent = camStamp(f.at); });
      var sl = root.querySelector('#camSl, #camFsSl'); if (sl) { sl.max = Math.max(0, cam.n - 1); sl.value = cam.idx; }
      var c = root.querySelector('#camCnt, #camFsCnt'); if (c) c.textContent = camCountTxt();
    });
  }
  function camMount() {
    var slot = document.getElementById('camSlot');
    if (!slot) return;
    if (!cam.el) {
      cam.el = document.createElement('div'); cam.el.className = 'card cam'; cam.el.id = 'camCard';
      cam.el.addEventListener('click', camClick);
      camPaint();
    }
    slot.appendChild(cam.el);
    if (!cam.timer && cam.playing) camPlay();
  }
  function camClick(e) {
    var b = e.target.closest ? e.target.closest('button') : null; if (!b) return;
    var t = b.getAttribute('data-tab'), a = b.getAttribute('data-cam'), cp = b.getAttribute('data-cap'), fp = b.getAttribute('data-fps');
    if (t) { cam.tab = t; save('camTab', t); camPaint(); return; }
    if (cp) { camCapture(cp); return; }
    if (fp) { save('camFps', +fp); camPaint(); camPlay(); camFsPaint(); return; }
    if (a === 'pick') camPick();
    else if (a === 'stop') camStop();
    else if (a === 'opts') { cam.opts = !cam.opts; camPaint(); }
    else if (a === 'play') { cam.playing = !cam.playing; if (cam.playing) camPlay(); else camStopPlay(); camPaint(); camFsPaint(); }
    else if (a === 'save') camSaveClip();
    else if (a === 'stopsave') { if (cam.save) cam.save.cancel = true; }
    else if (a === 'fs') camOpenFs();
    else if (a === 'fsclose') camCloseFs();
  }
  function camToast(txt) {
    var t = document.getElementById('camToast');
    if (!t) { t = document.createElement('div'); t.id = 'camToast'; t.className = 'cam-toast'; document.body.appendChild(t); }
    t.innerHTML = txt; t.classList.add('show'); clearTimeout(camToast.h);
    camToast.h = setTimeout(function () { t.classList.remove('show'); }, 4200);
  }
  function camFileStamp(d) { return camStamp(d || new Date()).replace(' ', '-').replace(/:/g, ''); }
  function camShareOrSave(files, title, text, mail) {
    // 1) the phone share sheet (pick Mail / Gmail, the image is attached)  2) download + open a mailto draft
    var canFiles = false;
    try { canFiles = !!(navigator.canShare && navigator.share && navigator.canShare({ files: files })); } catch (e) {}
    if (window.__camDry) { cam.log.push({ ev: 'share', files: files.map(function (f) { return f.name + ':' + f.size; }), via: canFiles ? 'share' : 'download+mailto', mail: mail || '' }); return Promise.resolve(canFiles ? 'share' : 'download'); }
    if (canFiles) return navigator.share({ files: files, title: title, text: text }).then(function () { return 'share'; }, function (e) { return e && e.name === 'AbortError' ? 'cancel' : dl(); });
    return Promise.resolve(dl());
    function dl() {
      files.forEach(function (f) { var u = URL.createObjectURL(f), a = document.createElement('a'); a.href = u; a.download = f.name; document.body.appendChild(a); a.click(); a.remove(); setTimeout(function () { URL.revokeObjectURL(u); }, 60000); });
      if (mail) setTimeout(function () { location.href = mail; }, 600);
      return 'download';
    }
  }
  function camCapture(k) {
    var f = camFrame(k); if (!f) return;
    var im = new Image();
    im.onload = function () {
      var bar = Math.max(28, Math.round(im.height * 0.06)), cv = document.createElement('canvas');
      cv.width = im.width; cv.height = im.height + bar;
      var g = cv.getContext('2d'); g.drawImage(im, 0, 0);
      g.fillStyle = '#111'; g.fillRect(0, im.height, cv.width, bar);
      g.fillStyle = '#fff'; g.font = '600 ' + Math.round(bar * 0.48) + 'px system-ui, sans-serif'; g.textBaseline = 'middle';
      var cap = 'TessDesk \u00b7 ' + CAM_NAMES[k] + (f.at ? ' \u00b7 ' + camStamp(f.at) : '') + ' \u00b7 from a saved clip, not live';
      g.fillText(cap, Math.round(bar * 0.4), im.height + bar / 2);
      cv.toBlob(function (blob) {
        var name = 'TessDesk-' + CAM_NAMES[k].replace(/ /g, '') + '-' + camFileStamp(f.at) + '.png';
        var file = new File([blob], name, { type: 'image/png' });
        var subj = 'TessDesk capture: ' + CAM_NAMES[k] + (f.at ? ' ' + camStamp(f.at) : '');
        var body = 'TessDesk capture from a saved clip (not live).\nCamera: ' + CAM_NAMES[k] + (f.at ? '\nTime: ' + camStamp(f.at) : '') + '\nThe image ' + name + ' is in your Downloads; attach it to this email.';
        var mail = 'mailto:' + CAM_MAIL + '?subject=' + encodeURIComponent(subj) + '&body=' + encodeURIComponent(body);
        cam.last = { name: name, size: blob.size, w: cv.width, h: cv.height, cam: k };
        camShareOrSave([file], subj, 'For ' + CAM_MAIL + ': ' + cap, mail).then(function (via) {
          cam.last.via = via;
          camToast('<b>' + CAM_ICON + ' Captured ' + esc(CAM_NAMES[k]) + '</b><small>' + (via === 'share' ? 'Share sheet opened, pick Mail to send to ' + CAM_MAIL : via === 'cancel' ? 'Share cancelled' : 'Saved ' + esc(name) + ', email draft to ' + CAM_MAIL + ' opened') + '</small>');
        });
      }, 'image/png');
    };
    im.src = f.src;
  }
  function camSaveClip() {
    if (cam.save) return;
    var keys = cam.tab === 'grid' ? CAM_KEYS.filter(function (k) { return cam.files[k]; }) : [cam.tab].filter(function (k) { return cam.files[k]; });
    if (!keys.length) { cam.msg = 'No clip file for this camera.'; camPaint(); return; }
    var files = keys.map(function (k) { return cam.files[k]; });
    cam.save = { done: 0, total: files.length, cancel: false }; camPaint();
    var canFiles = false; try { canFiles = !!(navigator.canShare && navigator.canShare({ files: files })); } catch (e) {}
    if (canFiles || window.__camDry) {
      camShareOrSave(files, 'TessDesk Sentry clip', cam.label.replace(/<[^>]+>/g, ''), '').then(function (via) { cam.save.done = files.length; camSaveDone(via); });
      return;
    }
    var i = 0;
    (function step() {
      if (cam.save.cancel) return camSaveDone('stopped');
      if (i >= files.length) return camSaveDone('download');
      var f = files[i++], u = URL.createObjectURL(f), a = document.createElement('a'); a.href = u; a.download = f.name; document.body.appendChild(a); a.click(); a.remove();
      setTimeout(function () { URL.revokeObjectURL(u); }, 60000);
      cam.save.done = i; camPaint(); setTimeout(step, 700);
    })();
  }
  function camSaveDone(via) {
    var s = cam.save; cam.save = null;
    cam.msg = via === 'stopped' ? 'Stopped, saved ' + s.done + ' of ' + s.total + ' clip files.' : via === 'cancel' ? 'Save cancelled.' : 'Clip ready: ' + s.done + ' of ' + s.total + ' files ' + (via === 'share' ? 'sent to the share sheet.' : 'saved to Downloads.');
    cam.log.push({ ev: 'save', via: via, done: s.done, total: s.total }); camPaint();
  }
  // full screen: the app hides underneath; layout dropdown; Esc or X closes
  function camFsOptions() {
    return [['one', 'One screen: Front large'], ['grid', 'One screen: grid'], ['two', 'Two monitors (desktop app only)']].map(function (o) {
      return '<option value="' + o[0] + '"' + (cam.fsLayout === o[0] ? ' selected' : '') + (o[0] === 'two' ? ' disabled' : '') + '>' + o[1] + '</option>';
    }).join('');
  }
  function camOpenFs() {
    if (cam.fs) return;
    cam.fs = document.createElement('div'); cam.fs.className = 'cam-fs'; cam.fs.id = 'camFs';
    cam.fs.addEventListener('click', camClick);
    document.body.appendChild(cam.fs); document.body.classList.add('cam-fs-open');
    camFsPaint();
    document.addEventListener('keydown', camFsKey);
    try { if (cam.fs.requestFullscreen && !window.__camDry) cam.fs.requestFullscreen().catch(function () {}); } catch (e) {}
    cam.log.push({ ev: 'fs-open', layout: cam.fsLayout });
  }
  function camFsKey(e) { if (e.key === 'Escape') camCloseFs(); }
  function camCloseFs() {
    if (!cam.fs) return;
    document.removeEventListener('keydown', camFsKey);
    try { if (document.fullscreenElement) document.exitFullscreen(); } catch (e) {}
    cam.fs.remove(); cam.fs = null; document.body.classList.remove('cam-fs-open');
    cam.log.push({ ev: 'fs-close' });
  }
  function camFsPaint() {
    if (!cam.fs) return;
    var lay = cam.fsLayout === 'grid' ? 'grid' : 'one', have = camHave();
    var main = have.indexOf('front') >= 0 ? 'front' : have[0], others = have.filter(function (k) { return k !== main; });
    var body = lay === 'one' ? '<div class="fs-main">' + (main ? camTileHtml(main, true) : '') + '</div><div class="fs-row">' + others.map(function (k) { return camTileHtml(k, false); }).join('') + '</div>'
      : '<div class="fs-grid n' + Math.min(6, Math.max(1, have.length)) + '">' + have.map(function (k) { return camTileHtml(k, false); }).join('') + '</div>';
    cam.fs.innerHTML = '<div class="fs-top"><b class="brand">TESSDESK</b><span class="ev">\u25cf ' + (cam.label || 'SAVED CLIP') + '</span>' +
      '<select id="camFsLay" aria-label="Layout">' + camFsOptions() + '</select><span class="cam-pill">NOT LIVE \u00b7 FROM SAVED CLIPS</span><span class="esc">Esc to close</span>' +
      '<button type="button" class="fs-x" data-cam="fsclose" aria-label="Close full screen">\u2715</button></div>' +
      '<div class="fs-body ' + lay + '">' + body + '</div>' +
      '<div class="fs-bot"><button type="button" class="pp' + (cam.playing ? ' on' : '') + '" data-cam="play">' + (cam.playing ? '<b>II</b>' : '<svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg>') + '</button>' +
      [2, 4, 8].map(function (f) { return '<button type="button" data-fps="' + f + '"' + (camFps() === f ? ' class="on"' : '') + '>' + f + ' fps</button>'; }).join('') +
      '<input type="range" id="camFsSl" min="0" max="' + Math.max(0, cam.n - 1) + '" value="' + cam.idx + '"><span class="cnt" id="camFsCnt">' + camCountTxt() + '</span>' +
      '<span class="dbv">DESIGN BY <span>VAN</span><small>' + VERSION + ' \u00b7 ' + VERSION_DATE + '</small></span></div>';
    var sel = cam.fs.querySelector('#camFsLay'); sel.onchange = function () { cam.fsLayout = sel.value; save('camFsLayout', cam.fsLayout); camFsPaint(); };
    var sl = cam.fs.querySelector('#camFsSl'); sl.oninput = function () { cam.idx = +sl.value; cam.playing = false; camStopPlay(); camPaintFrames(); };
  }
  document.addEventListener('visibilitychange', function () { if (document.visibilityState === 'visible' && camOn() && cam.playing && !cam.timer) camPlay(); });
  window.TessDesk439 = { cam: function () { return { on: camOn(), n: cam.n, idx: cam.idx, have: camHave(), frames: camHave().map(function (k) { return k + ':' + cam.frames[k].length; }), tab: cam.tab, fps: camFps(),
    busy: cam.job ? { done: cam.job.done, total: cam.job.total } : null, saving: cam.save ? { done: cam.save.done, total: cam.save.total } : null, fs: !!cam.fs, fsLayout: cam.fsLayout, last: cam.last || null, msg: cam.msg, label: cam.label, log: cam.log }; },
    useFiles: camUseFiles, stop: camStop, capture: camCapture, openFs: camOpenFs, closeFs: camCloseFs, setOn: camSetOn };

  // ---------- v4.3.10: TOTALS pop-up (running totals for this week / month / year + month by month) ----------
  // SHARED TOTALS RULE (the desktop uses the exact same rule, so both show the same numbers):
  //  * Charges come from Tessie's charge history, one month at a time, cached on this phone (localStorage 'totals').
  //    The charge in progress is added from the live tracker until Tessie lists it.
  //  * Home = saved location '3515 W 41st Pl'. Home cost = wall kWh (energy_used, else kWh added / efficiency) spread
  //    evenly over the charging minutes, each minute at its all-in PSO rate (energy + FCA; 6.2323 c/kWh 11 PM to 6 AM).
  //  * Away: a Supercharger / fast charge uses the amount Tessie reports (what was paid); other away charges are priced
  //    like home (estimate). Listed separately and included in the grand total.
  //  * A charge belongs to the night it started in (11 PM to 11 AM = the date the night began). Weeks run Monday to Sunday.
  //  * Nights = different home charging nights. Avg c/kWh = home cost / home wall kWh.
  //  * Last 7 / 30 days: every charge that STARTED in the last 7 / 30 days, counted whole, home + away (paid).
  var TOT_HOME = '3515 W 41st Pl';
  var tot = { months: load('totals', {}), job: null, open: {}, status: '', el: null, rowsKey: '', rows: [], view: null, log: [] };
  function totBusy() { return !!tot.job; }
  function dkey(y, mo, d) { var t = new Date(Date.UTC(y, mo - 1, d)); return t.getUTCFullYear() + '-' + ('0' + (t.getUTCMonth() + 1)).slice(-2) + '-' + ('0' + t.getUTCDate()).slice(-2); }
  function totNight(sec) { var c = ct(sec), sh = 23; return inHours(c.h, sh, 11) && c.h < sh ? dkey(c.y, c.mo, c.d - 1) : dkey(c.y, c.mo, c.d); }
  function totMonthKeys(t) { var c = ct(t), out = []; for (var m = 1; m <= c.mo; m++) out.push(c.y + '-' + ('0' + m).slice(-2)); return out; }
  function totRange(key) { var y = +key.slice(0, 4), m = +key.slice(5, 7); return [ctEpoch(y, m, 1, 0), m === 12 ? ctEpoch(y + 1, 1, 1, 0) : ctEpoch(y, m + 1, 1, 0)]; }
  function totHomeLoc(loc) { return !!loc && String(loc).trim().toLowerCase().indexOf(TOT_HOME.toLowerCase()) === 0; }
  function totLoad(all) {
    var cfg = getCfg(); if (totBusy() || !cfg || !consentOk()) return false;
    var t = nowSec(), need = [];
    totMonthKeys(t).forEach(function (k) {
      var r = totRange(k), c = tot.months[k], go = !!all || !c;
      if (!go && t < r[1]) go = (t - c.at) > 600;                 // this month: again after 10 min
      if (!go && t >= r[1] && c.at < r[1] + 2 * 86400) go = true; // a closed month: once more 2 days after it ended
      if (go) need.push({ key: k, from: r[0], to: Math.min(r[1], t) });
    });
    if (!need.length) return false;
    var job = tot.job = { done: 0, total: need.length, cancel: false, ok: 0, bad: [], t0: Date.now(), all: !!all };
    totPaint();
    var i = 0;
    (function next() {
      if (tot.stopAt && job.done >= tot.stopAt) { tot.stopAt = 0; job.cancel = true; }
      if (job.cancel || i >= need.length) return finish();
      var it = need[i++];
      api('/' + cfg.vin + '/charges?from=' + it.from + '&to=' + it.to + '&distance_format=mi&format=json').then(function (r) {
        var rows = ((r && r.results) || []).filter(function (c) { return c && c.started_at && c.ended_at; }).map(function (c) {
          return { id: c.id, s: +c.started_at, e: +c.ended_at, add: c.energy_added, used: c.energy_used, cost: c.cost, sc: !!c.is_supercharger, fc: !!c.is_fast_charger, kw: c.max_charger_power, loc: c.saved_location || c.location || '' };
        });
        tot.months[it.key] = { at: nowSec(), rows: rows }; job.ok++;
      }, function () { job.bad.push(it.key); }).then(function () { job.done++; totPaint(); next(); });
    })();
    function finish() {
      tot.job = null; tot.rowsKey = '';
      if (job.ok) { tot.loadedAt = nowSec(); try { save('totals', tot.months); save('totalsAt', tot.loadedAt); } catch (e) {} }
      tot.status = job.cancel ? 'Stopped at ' + job.ok + ' / ' + job.total + ' months, showing what is saved' : job.bad.length ? 'Could not load ' + job.bad.length + ' month(s), showing what is saved' : '';
      tot.log.push({ ev: job.cancel ? 'stopped' : 'loaded', ok: job.ok, total: job.total, bad: job.bad, ms: Date.now() - job.t0 });
      totPaint(); var b = document.getElementById('totSum'); if (b) b.textContent = totBtnSum();
    }
    return true;
  }
  tot.loadedAt = load('totalsAt', 0);
  function totRows(cfg) {
    var t = nowSec(), lv = null; try { lv = liveSession(); } catch (e) {}
    var charging = !!(cache.state && cache.state.charge_state && cache.state.charge_state.charging_state === 'Charging');
    var live = lv && lv.segs && lv.segs.length && charging && !lv.done ? lv : null;
    var key = tot.loadedAt + '|' + Object.keys(tot.months).length + '|' + (live ? live.start + ':' + live.added : '-');
    if (key === tot.rowsKey) return tot.rows;
    var seen = {}, rows = [];
    Object.keys(tot.months).sort().forEach(function (k) {
      (tot.months[k].rows || []).forEach(function (c) {
        var id = c.id != null ? String(c.id) : String(c.s); if (seen[id]) return; seen[id] = 1;
        if (c.s > t) return;
        var add = +(c.add || 0), used = +(c.used || 0), wall = used > 0 ? used : add / cfg.eff;
        var fast = !!(c.sc || c.fc || (c.kw > 25)), home = totHomeLoc(c.loc) && !fast;
        var paid = !home && fast && c.cost > 0 ? +c.cost : null;
        rows.push({ s: c.s, e: c.e, add: add, wall: wall, cost: paid != null ? paid : priceSpan(cfg.rates, c.s, c.e, wall).cost, home: home, fast: fast, paid: paid != null, day: totNight(c.s), loc: c.loc, live: false });
      });
    });
    if (live && !rows.some(function (r) { return r.s < live.end + 300 && live.start < r.e + 300; })) {
      var sc = sessionCost(cfg, live);
      rows.push({ s: live.start, e: live.end, add: live.added || 0, wall: sc.wall, cost: sc.cost, home: !live.fast, fast: !!live.fast, paid: false, day: totNight(live.start), loc: 'live', live: true });
    }
    rows.sort(function (a, b) { return a.s - b.s; });
    tot.rowsKey = key; tot.rows = rows; return rows;
  }
  function totAgg(rows) {
    var hk = 0, hc = 0, hw = 0, n = {}, an = 0, ak = 0, ac = 0;
    rows.forEach(function (r) { if (r.home) { hk += r.add; hc += r.cost; hw += r.wall; n[r.day] = 1; } else { an++; ak += r.add; ac += r.cost; } });
    var r2 = function (x) { return Math.round(x * 100) / 100; }, r1 = function (x) { return Math.round(x * 10) / 10; };
    return { kwh: r1(hk), cost: r2(hc), nights: Object.keys(n).length, cpk: hw > 0 ? r1(100 * hc / hw) : null, awayN: an, awayKwh: r1(ak), awayCost: r2(ac), grand: r2(hc + ac) };
  }
  function totView() {
    var cfg = getCfg(); if (!cfg) return null;
    var rows = totRows(cfg), t = nowSec(), c = ct(t), today = dkey(c.y, c.mo, c.d);
    var dow = new Date(Date.UTC(c.y, c.mo - 1, c.d)).getUTCDay(), wk0 = dkey(c.y, c.mo, c.d - (dow + 6) % 7), wk1 = dkey(c.y, c.mo, c.d - (dow + 6) % 7 + 6);
    var mo0 = dkey(c.y, c.mo, 1), yr0 = dkey(c.y, 1, 1);
    var inR = function (a, z) { return rows.filter(function (r) { return r.day >= a && r.day <= z; }); };
    var months = [];
    for (var m = 1; m <= c.mo; m++) {
      var k = c.y + '-' + ('0' + m).slice(-2), mr = rows.filter(function (r) { return r.day.slice(0, 7) === k; });
      months.push({ key: k, m: m, current: m === c.mo, agg: totAgg(mr), rows: mr, cached: !!tot.months[k] });
    }
    return { y: c.y, mo: c.mo, today: today, weekStart: wk0, weekEnd: wk1, week: totAgg(inR(wk0, today)), month: totAgg(inR(mo0, today)), year: totAgg(inR(yr0, today)), months: months, count: rows.length };
  }
  var MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  function totFmtDay(k, wd) { var p = k.split('-'), d = new Date(Date.UTC(+p[0], +p[1] - 1, +p[2])); return (wd ? ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][d.getUTCDay()] + ' ' : '') + MONTHS[+p[1] - 1].slice(0, 3) + ' ' + (+p[2]); }
  function totKwh(v) { return v >= 1000 ? Math.round(v).toLocaleString('en-US') + ' kWh' : (Math.round(v * 10) / 10).toFixed(1) + ' kWh'; }
  function totCents(v) { return v == null ? '--' : v.toFixed(1) + '\u00a2'; }
  function totBtnSum() { var v = Object.keys(tot.months).length ? totView() : null; return v ? MONTHS[v.mo - 1].slice(0, 3) + ' ' + money(v.month.grand) + ' \u00b7 ' + v.y + ' ' + money(v.year.grand) : ''; }
  function totBtn() {
    return '<button class="tot-btn" id="btnTot" type="button" title="Charging totals: this week, this month, this year"><i>$</i><b>TOTALS</b><span>week \u00b7 month \u00b7 year</span><em id="totSum">' + esc(totBtnSum()) + '</em><s>\u203a</s></button>';
  }
  function totPeriod(lbl, sub, a) {
    return '<div class="tot-p"><div class="k">' + lbl + '</div><div class="s">' + esc(sub) + '</div><div class="v">' + money(a.cost) + '</div>' +
      '<div class="m">' + totKwh(a.kwh) + '</div><div class="m">' + a.nights + ' night' + (a.nights === 1 ? '' : 's') + '</div><div class="m">avg ' + totCents(a.cpk) + '/kWh</div>' +
      (a.awayN ? '<div class="aw">+ ' + money(a.awayCost) + ' away</div><div class="gt">Total ' + money(a.grand) + '</div>' : '') + '</div>';
  }
  function totNights(rows) {
    var by = {}, h = '';
    rows.forEach(function (r) { if (!r.home) return; var g = by[r.day] = by[r.day] || { n: 0, k: 0, c: 0, live: false }; g.n++; g.k += r.add; g.c += r.cost; if (r.live) g.live = true; });
    Object.keys(by).sort().forEach(function (d) { var g = by[d]; h += '<div class="tn"><span>' + totFmtDay(d, true) + (g.n > 1 ? ' \u00b7 ' + g.n + ' charges' : '') + (g.live ? ' \u00b7 live' : '') + '</span><em>' + totKwh(g.k) + '</em><b>' + money(g.c) + '</b></div>'; });
    rows.filter(function (r) { return !r.home; }).forEach(function (r) {
      h += '<div class="tn aw"><span>' + totFmtDay(totNight(r.s), true) + ' \u00b7 ' + (r.fast ? 'Supercharger' : 'Away') + ' \u00b7 ' + esc(String(r.loc || '').split(',')[0].slice(0, 22)) + '</span><em>' + totKwh(r.add) + '</em><b>' + money(r.cost) + (r.paid ? ' paid' : ' est.') + '</b></div>';
    });
    return '<div class="tnl">' + (h || '<div class="tn"><span>No charges this month</span></div>') + '</div>';
  }
  function totStatus() {
    if (tot.job) return '<span class="busy">Loading charge history ' + tot.job.done + ' / ' + tot.job.total + ' months</span><button type="button" class="tot-stop" data-tot="stop">Stop</button>';
    return '<span' + (tot.status ? ' class="busy"' : '') + '>' + esc(tot.status || (tot.loadedAt ? 'Updated ' + dayLabel(tot.loadedAt) + ' ' + clock(tot.loadedAt) + ' \u00b7 ' + (tot.view ? tot.view.count : 0) + ' charges from Tessie' : 'Not loaded yet')) + '</span>';
  }
  function totPaint() {
    if (!tot.el) return;
    var st = tot.el.querySelector('.tot-st');
    var v = tot.view = totView(); if (!v) return;
    var h = '<div class="tot-box" role="dialog" aria-label="Charging totals"><div class="tot-h"><b>Charging totals</b><button type="button" class="tot-rf" data-tot="refresh"' + (tot.job ? ' disabled' : '') + '>\u21bb Refresh</button><button type="button" class="tot-x" data-tot="close" aria-label="Close">\u2715</button></div>' +
      '<div class="tot-st">' + totStatus() + '</div><div class="tot-sc">' +
      '<div class="tot-ps">' + totPeriod('THIS WEEK', totFmtDay(v.weekStart) + ' to ' + totFmtDay(v.weekEnd), v.week) + totPeriod('THIS MONTH', MONTHS[v.mo - 1] + ' so far', v.month) + totPeriod('THIS YEAR', v.y + ' so far', v.year) + '</div>' +
      '<div class="tot-note">Home at ' + esc(TOT_HOME) + ' \u00b7 what you paid at the all-in PSO rate</div>' +
      '<div class="tot-mh"><b>MONTH BY MONTH</b><span>kWh</span><span>Cost</span><span>Nights</span><i></i></div>';
    v.months.slice().reverse().forEach(function (m) {
      var a = m.agg, empty = a.kwh <= 0 && !a.awayN, open = !!tot.open[m.key];
      h += '<button type="button" class="tot-m' + (m.current ? ' cur' : '') + (empty ? ' empty' : '') + '" data-month="' + m.key + '"' + (empty ? ' disabled' : '') + '><b>' + MONTHS[m.m - 1] + (m.current ? ' so far' : '') + '</b>' +
        (empty ? '<span class="na">' + (m.cached ? 'no charges' : 'not loaded') + '</span>' : '<span>' + totKwh(a.kwh) + '</span><span class="c">' + money(a.grand) + '</span><span>' + a.nights + '</span><i>' + (open ? '\u25b4' : '\u25be') + '</i>') + '</button>';
      if (open && !empty) h += (a.awayN ? '<div class="tot-aw">Home ' + money(a.cost) + ' + away ' + money(a.awayCost) + ' (' + a.awayN + ')</div>' : '') + totNights(m.rows);
    });
    var y = v.year;
    h += '<div class="tot-yr">' + v.y + ' total: ' + totKwh(y.kwh) + ' at home, ' + money(y.cost) + (y.awayN ? ' + ' + money(y.awayCost) + ' away = ' + money(y.grand) : '') + '</div>' +
      '<div class="tot-rule">Home = ' + esc(TOT_HOME) + '. Home cost is priced by the minute at the all-in PSO rate (energy + fuel charge): 6.23\u00a2/kWh from 11 PM to 6 AM, the day rate at other hours. Supercharger and away charges use the amount Tessie reports as paid. A charge counts on the night it started (weeks run Monday to Sunday). The desktop app uses the same rule.</div></div>' +
      '<div class="foot tot-foot"><div class="dbv">DESIGN BY <span>VAN</span></div><div class="ver">' + VERSION + ' \u00b7 ' + VERSION_DATE + '</div></div></div>';
    var sc = tot.el.querySelector('.tot-sc'), top = sc ? sc.scrollTop : 0;
    tot.el.innerHTML = h;
    var sc2 = tot.el.querySelector('.tot-sc'); if (sc2) sc2.scrollTop = top;
  }
  function totOpen() {
    var t0 = performance.now();
    if (!tot.el) {
      tot.el = document.createElement('div'); tot.el.className = 'tot-pop'; tot.el.id = 'totPop';
      tot.el.addEventListener('click', function (e) {
        if (e.target === tot.el) return totClose();
        var b = e.target.closest ? e.target.closest('button') : null; if (!b) return;
        var a = b.getAttribute('data-tot'), m = b.getAttribute('data-month');
        if (m) { tot.open[m] = !tot.open[m]; totPaint(); }
        else if (a === 'close') totClose();
        else if (a === 'stop') { if (tot.job) tot.job.cancel = true; }
        else if (a === 'refresh') { tot.status = ''; totLoad(true); }
      });
    }
    document.body.appendChild(tot.el); document.body.classList.add('tot-open');
    totPaint(); tot.openMs = Math.round(performance.now() - t0);
    document.addEventListener('keydown', totKey);
    totLoad(false);
  }
  function totKey(e) { if (e.key === 'Escape') totClose(); }
  function totClose() { if (tot.job) tot.job.cancel = true; document.removeEventListener('keydown', totKey); if (tot.el && tot.el.parentNode) tot.el.parentNode.removeChild(tot.el); document.body.classList.remove('tot-open'); }
  window.TessDesk4310 = { view: function () { return totView(); }, open: totOpen, close: totClose, load: totLoad, busy: function () { return tot.job ? { done: tot.job.done, total: tot.job.total } : null; },
    status: function () { return tot.status; }, log: function () { return tot.log; }, openMs: function () { return tot.openMs; }, isOpen: function () { return !!(tot.el && tot.el.parentNode); },
    clear: function () { tot.months = {}; tot.loadedAt = 0; tot.rowsKey = ''; save('totals', {}); save('totalsAt', 0); }, stopAfter: function (n) { tot.stopAt = n; } };

  window.TessDesk437 = { share: function () { return shareLog; }, open: showShare };
  window.TessDesk435 = { sessions: function () { var c = getCfg(); var v = c && compute(c); return v ? windowSessions(c, v.win) : null; } };
  window.TessDesk432 = { glow: glowState, flash: function () { return flash; }, setGlow: function (g) { window.__glowForce = g || null; render(); }, lastWindow: function () { var c = getCfg(); var v = c && compute(c); return v && v.hero && v.hero.src === 'window' ? { cost: v.heroCost, sessions: v.hero.sessions, start: v.hero.start, end: v.hero.end, added: v.hero.added, kwhAfter6: v.hero.kwhAfter6, costAfter6: v.hero.costAfter6, home: v.hero.home } : null; } };
  window.TessDesk = { cmdLog: cmdLog, annLog: function () { return annLog; }, lastError: function () { return lastErr ? String(lastErr.message || lastErr) : null; }, live: function () { return liveInfo; }, layout: function () { return { mode: layoutMode(), zoom: curZoom }; }, seatPend: function () { return seatPend; }, tireFlag: tireFlag, buildIcs: buildIcs, priceSpan: function (t0, t1, wall) { var c = getCfg(); return priceSpan(c ? c.rates : PRESETS.pso, t0, t1, wall); }, PRESETS: PRESETS, ctEpoch: ctEpoch, refresh: refresh, rundown: function (o) { return buildRundown(o); }, peak: function () { var c = getCfg(); return c ? peakState(compute(c), c) : null; }, rate: function () { var c = getCfg(); return c ? rateStatus(compute(c), c) : null; }, version: VERSION };

  render();
  if (getCfg()) { refresh(false); startTimer(); }
  setTimeout(function () { checkUpdate(false); }, 3000);
  setInterval(function () { if (document.visibilityState === 'visible') checkUpdate(false); }, 30 * 60 * 1000);
})();
