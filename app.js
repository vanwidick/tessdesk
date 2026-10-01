/* TessDesk mobile v4.2.1 (PWA). Design by Van.
   Everything (name, Tessie token, vehicle, rates) is stored in localStorage on this device only. */
(function () {
  'use strict';
  var CFG = window.TD_CONFIG || {};
  var VARIANT = CFG.variant || 'main';
  var P = CFG.storagePrefix || 'td:';
  var VERSION = 'v4.2.1';
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
    }).catch(function (e) { lastErr = e; }).then(function () { busy = false; setSpin(false); try { render(); } catch (e) { console.error(e); } if (getCfg() && consentOk()) scheduleNext(nextDelay() * 1000); });
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
      limitMin: cs.charge_limit_soc_min != null ? cs.charge_limit_soc_min : 50, limitMax: cs.charge_limit_soc_max != null ? cs.charge_limit_soc_max : 100,
      chargingState: cs.charging_state || '', ampsReq: cs.charge_current_request, ampsMax: cs.charge_current_request_max, ampsNow: cs.charger_actual_current,
      seats: { fl: cl.seat_heater_left, fr: cl.seat_heater_right, rl: cl.seat_heater_rear_left, rc: cl.seat_heater_rear_center, rr: cl.seat_heater_rear_right },
      rearSeats: (st.vehicle_config || {}).rear_seat_heaters,
      wheelOn: cl.steering_wheel_heater != null ? (!!cl.steering_wheel_heater || cl.steering_wheel_heat_level > 0) : null,
      defrostOn: (cl.defrost_mode != null || cl.is_front_defroster_on != null) ? (cl.defrost_mode > 0 || !!cl.is_front_defroster_on) : null,
      cop: cl.cabin_overheat_protection || null, copFanOnly: !!cl.supports_fan_only_cabin_overheat_protection, copAllowed: cl.allow_cabin_overheat_protection,
      windows: { fd: vs.fd_window, fp: vs.fp_window, rd: vs.rd_window, rp: vs.rp_window } };
    return {
      charging: charging, state: st, cs: cs, hero: hero, heroCost: hc,
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
    else if (v) note = '<span class="note upd" id="updAge" data-t="' + v.updated + '">' + updText(v.updated) + '</span>';
    else note = '<span class="note">Loading\u2026</span>';

    var h = '<div class="wrap">' + testBanner() +
      '<div class="hdr"><div class="brand">TESSDESK</div><div class="who">' + layoutChip() + 'Logged in as <b>' + esc(cfg.name) + '</b></div></div>' +
      '<div class="toolbar">' + note + '<div class="tools">' + alexaChip() + '<button class="icon-btn" id="btnRefresh" aria-label="Refresh">' + ICON_REFRESH +
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
    // v4.2: money rows right under the hero, compact
    var nightSub = v.nightLabel === 'Tonight' ? 'since ' + clock(v.nightStart) : dayLabel(v.nightStart) + ', 11 PM \u2013 11 AM';
    h += '<div class="card rows compact">' +
      row(v.nightLabel, nightSub, v.night, true) + row('Last 7 days', null, v.d7) + row('Last 30 days', null, v.d30) + '</div>';

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
      '<div class="r"><small>LIMIT</small><span class="mi" id="limMi">' + miles(perPct, b) + '</span><b id="limPct">' + (b != null ? b + '%' : '--') + '</b></div></div>' +
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
    var remOk = !!(cfg.consent && cfg.consent.reminders);
    h += '<div class="card tires"><div class="sec-hd"><h3>Tires</h3>' + (v.tires.asOf ? '<span class="pill">Updated ' + clock(v.tires.asOf) + ' \u00b7 ' + monDay(v.tires.asOf) + '</span>' : '') + '</div>' +
      (rec ? '<div class="recline">' + rec + '</div>' : '') + tireSvg(v.tires) +
      '<button class="cbtn remind" id="bRemind"' + (remOk ? '' : ' disabled') + '><b>REMIND ME TO GET AIR</b><small>' + (remOk ? 'calendar alert, text, email or Alexa' : 'reminders are off (Settings)') + '</small></button>' +
      '<button class="linkbtn" id="bRemSetup" type="button">Setup: how reminders reach you</button></div>';

    // v4.2 HEATED SEATS (drawn like the tires)
    h += seatsCard(v.car);

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
      '<div class="ctl-row2">' +
      '<button class="cbtn big' + lockCls + '" id="cLock"' + dis + '>' + (locked === false ? ICON_UNLOCK : ICON_LOCK) + '<span><b>' + lockTxt + '</b><small>' + lockSub + '</small></span></button>' +
      '<button class="cbtn big' + (clim ? ' on' : '') + '" id="cClim"' + dis + '>' + ICON_SNOW + '<span><b>' + (clim ? (heatOn(car) ? 'CLIMATE ON' : 'A/C ON') : 'A/C OFF') + '</b><small>' + ins + (clim ? 'tap off' : 'tap on') + '</small></span></button></div>' +
      climateRow(car, dis) +
      '<div class="ctl-row3">' +
      '<button class="cbtn' + (win ? ' state' : '') + '" id="cVent"' + dis + '><b>VENT</b><small>' + (win ? 'VENTED / OPEN' : 'WINDOWS') + '</small></button>' +
      '<button class="cbtn' + (win === false ? ' state' : '') + '" id="cClose"' + dis + '><b>CLOSE</b><small>' + (win === false ? 'ALL CLOSED' : 'WINDOWS') + '</small></button>' +
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
  // ann: what Alexa says after success (announced only after the result is known); next: follow-up step (Heat).
  function runCmd(name, query, busyTxt, okTxt, onOk, ann, next) {
    if (ctlBusy || !cmdAllowed()) return;
    ctlBusy = true; ctlMsg = { kind: 'busy', text: busyTxt + (load('dryRun', false) ? ' (dry run)' : '') }; render();
    var okd = false, why = '';
    command(name, query).then(function (j) {
      okd = true; if (onOk) onOk();
      ctlMsg = { kind: 'ok', text: '\u2713 ' + okTxt + ' \u00b7 ' + clock(nowSec()) + (j && j.dryRun ? ' (dry run, not sent)' : '') };
      if (!(j && j.dryRun)) setTimeout(function () { refresh(true); }, 6000);
    }, function (e) { why = String(e.message || e); ctlMsg = { kind: 'err', text: '\u2715 ' + name + ' failed: ' + why.slice(0, 90) }; })
      .then(function () {
        ctlBusy = false; if (name === 'set_temperatures') pendTemp = null;
        if (okd) liveInfo.lastCmd = nowSec();
        if (okd && next) { render(); next(); return; }
        if (alexaOn()) announce(okd ? (ann || defaultSpeech(name, query, okTxt)) : failSpeech(name, why), okd ? 'action' : 'action-failed');
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
  function announce(text, why, force) {
    var a = annCfg(), rec = { at: new Date().toISOString(), why: why || 'action', text: text, device: a.device || '', dryRun: !!load('dryRun', false), sent: false, result: '' };
    if (!force && !alexaOn()) rec.result = 'skipped: Alexa toggle off';
    else if (!annConsent()) rec.result = 'skipped: announcement disclosure not accepted';
    else if (!a.token || !a.device) rec.result = 'skipped: Voice Monkey not set up';
    else if (rec.dryRun) rec.result = 'DRY RUN: not sent to Voice Monkey';
    else {
      rec.sent = true; rec.result = 'sending';
      fetch(VM_API + '/announce', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token: a.token, device: a.device, speech: text }) })
        .then(function (r) { rec.result = r.ok ? 'announced' : 'failed: HTTP ' + r.status; }, function () { rec.result = 'failed: network'; });
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
      '<div class="field"><label for="aDev">Speaker device ID</label><input type="text" id="aDev" autocapitalize="off" spellcheck="false" value="' + esc(a.device || '') + '" placeholder="e.g. echo-living-room-xxxxx"></div>' +
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
        var sp = (j.data || []).filter(function (d) { return d.capability === 'speakers'; }), hit = sp.filter(function (d) { return d.id === dev || d.name === dev; })[0];
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
    return { token: el('aTok').value.trim(), device: el('aDev').value.trim(), schedules: sch, schedulesRunOn: 'pc' };
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
    on('cLock', onLock); on('cVent', onVent); on('cClose', onClose); on('cClim', onClim);
    on('cTdn', function () { onTemp(-1); }); on('cTup', function () { onTemp(1); });
    on('bRemind', openReminder); on('bRemSetup', openRemSetup); on('btnLayout', function () { setLayout(layoutMode() === 'compact' ? 'full' : 'compact'); });
    on('cChgStart', onChgStart); on('cChgStop', onChgStop); on('cHeat', onHeat); on('cDefrost', onDefrost); on('cCop', onCop); on('sWheel', onWheel);
    on('btnAlexa', function () { setAlexa(!alexaOn()); }); on('btnSched', function () { screen = 'settings'; render(); var e = document.getElementById('apps'); if (e) e.scrollIntoView(); });
    Array.prototype.forEach.call(document.querySelectorAll('[data-seat]'), function (g) { g.onclick = function () { if (!g.classList.contains('dis')) onSeat(g.getAttribute('data-seat')); }; });
    bindSlider(); bindAmps();
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
        (remCh('alexa') && annReady() ? '<button class="btn ghost" id="rA">Announce on Alexa now</button><div class="rn" id="rAm">Your Echo (' + esc(annCfg().device) + ') says it now. Scheduled announcements come from the PC app.</div>' : '') +
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
  window.TessDesk = { cmdLog: cmdLog, annLog: function () { return annLog; }, lastError: function () { return lastErr ? String(lastErr.message || lastErr) : null; }, live: function () { return liveInfo; }, layout: function () { return { mode: layoutMode(), zoom: curZoom }; }, seatPend: function () { return seatPend; }, tireFlag: tireFlag, buildIcs: buildIcs, priceSpan: function (t0, t1, wall) { var c = getCfg(); return priceSpan(c ? c.rates : PRESETS.pso, t0, t1, wall); }, PRESETS: PRESETS, ctEpoch: ctEpoch, refresh: refresh };

  render();
  if (getCfg()) { refresh(false); startTimer(); }
})();
