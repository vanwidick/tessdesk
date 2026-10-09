/* TessDesk LEAVING SOON v4.3.21 (phone). Design by Van. v4.3.19: 'Start after' (0-120 min, default 0) waits before the sequence begins;
   Stop during it just cancels (nothing to undo); the same timestamp catch-up and 30-minute late limit apply to that step.
   Shared by the main phone app (TESLA CONTROLS) and the standalone Leaving Soon page (leaving/). Same behavior as desktop v4.3.16:
   confirm -> read the start state (Tessie GET /{vin}/state?use_cache=true, never wakes the car; fallback = last TessDesk refresh)
   -> start_climate -> wait 'Windows after' -> close_windows -> wait 'Unlock after' -> unlock. Waits 0-30 min (default 3, 0 = right away),
   saved in localStorage <prefix>leaveMins (shared by both pages on one origin).
   Stop cancels the rest and undoes the steps already done, newest first: lock if it was locked (unknown -> lock), vent_windows if a window
   was open, stop_climate if climate was off. Each undo step is announced ('Undoing n of m').
   Web pages cannot run while the phone is locked, so the run lives in localStorage <prefix>leave with real timestamps: the countdown
   resumes and catches up when the page comes back; a step that came due meanwhile runs then (and says how late). A step more than
   30 minutes overdue is NOT run (never unlock the car hours later); the run is marked expired and UNDO is offered.
   Alexa (Voice Monkey, one speaker: announce.leavingSoonDevice / announce.device / echo-living-room-4hqjv), Leaving Soon only, fewer sends
   than the desktop: the start line rides on the climate announcement, the cancel line on the first undo announcement.
   429 from Voice Monkey (THROTTLED / MONTHLY_QUOTA_EXCEEDED) pauses Leaving Soon announcements until the time Voice Monkey gives.
   Dry run (<prefix>dryRun): nothing goes to the car or Voice Monkey. Token and settings stay in this browser's localStorage. */
(function () {
  'use strict';
  var CFG = window.TD_CONFIG || {}, P = CFG.storagePrefix || 'td:';
  var DEFAULT_API = 'https://api.tessie.com', VM_API = 'https://api-v3.voicemonkey.io', DEF_DEVICE = 'echo-living-room-4hqjv';
  var MAXMIN = 30, DEFMIN = 3, STARTMAX = 120, DEFSTART = 0, CMD_TIMEOUT = 90000, READ_TIMEOUT = 8000, STALE_SEND = 100000, LATE_NOTE = 3000, OWNER_STALE = 4000;
  var TAB = Math.random().toString(36).slice(2, 10);
  var STEPS = [
    { cmd: 'start_climate', doing: 'turning on climate', next: 'climate on', done: 'climate on', label: 'Climate', name: 'Climate on', what: 'turn on climate', spoken: 'Leaving Soon: climate is now on.' },
    { cmd: 'close_windows', doing: 'closing windows', next: 'close windows', done: 'windows closed', label: 'Windows', name: 'Close windows', what: 'close the windows', spoken: 'Leaving Soon: the windows are now closed.' },
    { cmd: 'unlock', doing: 'unlocking', next: 'unlock', done: 'unlocked', label: 'Unlock', name: 'Unlock', what: 'unlock your Tesla', spoken: 'Leaving Soon: your Tesla is now unlocked.' }
  ];
  var UNDO = {
    start_climate: { cmd: 'stop_climate', doing: 'turning climate back off', done: 'climate off', what: 'turn climate back off', spoken: 'climate is off again.' },
    close_windows: { cmd: 'vent_windows', doing: 'venting the windows', done: 'windows vented', what: 'vent the windows', spoken: 'the windows are vented again.' },
    unlock: { cmd: 'lock', doing: 'locking', done: 'locked', what: 'lock your Tesla', spoken: 'your Tesla is locked again.' }
  };
  var UNDO_BY = {}; Object.keys(UNDO).forEach(function (k) { UNDO_BY[UNDO[k].cmd] = UNDO[k]; });
  var opts = {}, timer = null, dueTimer = null, inflight = {}, snapping = {}, msg = '', cmdLog = [], carReadAt = 0, carBusy = false, carErr = '', ov = {};

  // ---------- storage / setup ----------
  function load(k, d) { try { var v = localStorage.getItem(P + k); return v ? JSON.parse(v) : d; } catch (e) { return d; } }
  function save(k, v) { try { if (v === null) localStorage.removeItem(P + k); else localStorage.setItem(P + k, JSON.stringify(v)); } catch (e) {} }
  function ok(c) { return !!(c && c.token && c.vin); }
  function cfg() { var c = load('cfg', null); if (ok(c)) return c; var l = load('leaveCfg', null); return ok(l) ? l : (c || l); }
  function hasSetup() { return ok(cfg()); }
  function cmdAllowed() { var c = cfg(); return !!(c && c.consent && c.consent.sendCommands); }
  function dry() { return !!load('dryRun', false); }
  function spm() { if (dry()) { var v = +load('leaveSecPerMin', 0); if (v >= 1) return Math.min(60, v); } return 60; }
  function clampMin(v) { v = parseInt(v, 10); if (isNaN(v)) return DEFMIN; return Math.max(0, Math.min(MAXMIN, v)); }
  function clampStart(v) { v = parseInt(v, 10); if (isNaN(v)) return DEFSTART; return Math.max(0, Math.min(STARTMAX, v)); }   // v4.3.19: Start after, 0-120 min (0 = start right away)
  function mins() { var m = load('leaveMins', null) || {}; return [clampMin(m.w != null ? m.w : DEFMIN), clampMin(m.u != null ? m.u : DEFMIN), clampStart(m.s != null ? m.s : DEFSTART)]; }
  function setMins(w, u, s2) { if (s2 == null) s2 = mins()[2]; save('leaveMins', { w: clampMin(w), u: clampMin(u), s: clampStart(s2) }); }
  function st() { return load('leave', null); }
  function put(L) { save('leave', L); }
  function active(L) { return !!L && (L.phase === 'pre' || L.phase === 'snap' || L.phase === 'run' || L.phase === 'stopping' || L.phase === 'undo'); }

  // ---------- text ----------
  var clockFmt = new Intl.DateTimeFormat('en-US', { timeZone: 'America/Chicago', hour: 'numeric', minute: '2-digit' });
  function clock(ms) { return clockFmt.format(new Date(ms)); }
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (ch) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]; }); }
  function summary(m) { function f(n, z, t) { return n <= 0 ? z : t.replace('{0}', n); } return f(m[2], 'start now', 'start in {0} min') + ' \u00b7 ' + f(m[0], 'windows right away', 'windows {0} min later') + ' \u00b7 ' + f(m[1], 'unlock right after', 'unlock {0} min later'); }
  function minTxt(m) { return m + ' minute' + (m === 1 ? '' : 's'); }
  function inTxt(m, now, later) { return m <= 0 ? now : later.replace('{0}', minTxt(m)); }
  function span(ms) { var s = Math.round(ms / 1000); if (s < 90) return s + ' s'; var m = Math.round(s / 60); return m < 90 ? m + ' min' : (Math.round(m / 6) / 10) + ' h'; }
  function mmss(ms) { var s = Math.max(0, Math.ceil(ms / 1000)); return Math.floor(s / 60) + ':' + ('0' + (s % 60)).slice(-2); }
  function cap(s) { return s.charAt(0).toUpperCase() + s.slice(1); }
  function note(L, t) { L.notes = (L.notes || []).concat([t]).slice(-4); }
  function dryTag() { return dry() ? ' (dry run, not sent)' : ''; }

  // ---------- Tessie ----------
  function apiBase(c) { return String(c.apiBase || DEFAULT_API).replace(/\/+$/, ''); }
  function command(name) {
    var c = cfg() || {}, path = '/' + c.vin + '/command/' + name + '?wait_for_completion=true', d = dry();
    cmdLog.push({ at: new Date().toISOString(), cmd: name, dryRun: d }); if (cmdLog.length > 40) cmdLog.shift();
    if (d) return new Promise(function (res, rej) { setTimeout(function () { if (window.__leaveFail === name) rej(new Error('simulated failure (dry run test)')); else res({ result: true, dryRun: true }); }, window.__leaveDryMs != null ? window.__leaveDryMs : 1400); });
    var ctl = new AbortController(), t = setTimeout(function () { ctl.abort(); }, CMD_TIMEOUT);
    return fetch(apiBase(c) + path, { method: 'POST', headers: { Authorization: 'Bearer ' + c.token, Accept: 'application/json' }, cache: 'no-store', signal: ctl.signal }).then(function (r) {
      clearTimeout(t);
      return r.json().catch(function () { return {}; }).then(function (j) {
        if (r.status === 401 || r.status === 403) throw new Error('token rejected (' + r.status + ')');
        if (!r.ok) throw new Error((j && (j.error || j.reason)) || ('Tessie error ' + r.status));
        if (!j || !j.result) throw new Error((j && (j.reason || j.error)) || 'car did not confirm');
        return j;
      });
    }, function () { clearTimeout(t); throw new Error(navigator.onLine === false ? 'offline' : 'no response (network / timeout)'); });
  }
  function readState() {   // cached state only: never wakes the car
    var c = cfg() || {}, ctl = new AbortController(), t = setTimeout(function () { ctl.abort(); }, READ_TIMEOUT);
    return fetch(apiBase(c) + '/' + c.vin + '/state?use_cache=true', { headers: { Authorization: 'Bearer ' + c.token, Accept: 'application/json' }, cache: 'no-store', signal: ctl.signal })
      .then(function (r) { clearTimeout(t); if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); }, function () { clearTimeout(t); throw new Error('no response'); })
      .then(function (j) { var cc = load('cache', null) || {}; cc.state = j; cc.stateAt = Math.floor(Date.now() / 1000); save('cache', cc); return j; });
  }
  function cachedState() { var cc = load('cache', null); return cc && cc.state ? { state: cc.state, at: (cc.stateAt || 0) * 1000 } : null; }
  function snapFrom(v, src) {
    var vs = (v && v.vehicle_state) || null, cl = (v && v.climate_state) || null, w = {}, known = [];
    ['fd', 'fp', 'rd', 'rp'].forEach(function (k) { var x = vs ? vs[k + '_window'] : null; w[k] = x == null ? null : +x; if (x != null) known.push(+x); });
    return { src: src, at: Date.now(), climateOn: cl && cl.is_climate_on != null ? !!cl.is_climate_on : null, windows: w,
      anyOpen: known.length ? known.some(function (x) { return x !== 0; }) : null, locked: vs && vs.locked != null ? !!vs.locked : null };
  }

  // ---------- Voice Monkey (Leaving Soon only) ----------
  function annCfg() { var c = cfg() || {}; return c.announce || {}; }
  function annDevice() { var a = annCfg(); return a.leavingSoonDevice || a.device || DEF_DEVICE; }
  function annReady() { var c = cfg() || {}, a = annCfg(); return !!(c.consent && c.consent.announcements && a.token); }
  function vmSend(token, device, text) {
    var ctl = new AbortController(), t = setTimeout(function () { ctl.abort(); }, 20000);
    return fetch(VM_API + '/announce', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token: token, device: device, speech: text }), signal: ctl.signal })
      .then(function (r) {
        clearTimeout(t);
        return r.text().then(function (b) {
          var j = null; try { j = JSON.parse(b); } catch (e) {}
          var res = { ok: r.ok && !(j && j.success === false), code: r.status, error: j && j.error ? String(j.error) : (r.ok ? '' : 'HTTP ' + r.status), body: j };
          if (r.status === 429) {
            var quota = /QUOTA/i.test(res.error), until = j && (j.periodEnd || j.lockoutUntil), u = until ? Date.parse(until) : NaN;
            if (isNaN(u)) u = Date.now() + (quota ? 3600000 : 120000);
            res.why = quota ? 'Voice Monkey monthly limit reached (resets ' + new Date(u).toLocaleDateString('en-US', { timeZone: 'America/Chicago', month: 'short', day: 'numeric' }) + ')' : 'Voice Monkey is throttling announcements until ' + clock(u);
            save('vmBlock', { until: new Date(u).toISOString(), why: res.why, code: 429, error: res.error });
          }
          return res;
        });
      }, function (e) { clearTimeout(t); return { ok: false, code: 0, error: navigator.onLine === false ? 'offline' : 'network / CORS error' }; });
  }
  function announce(L, text, tag) {
    var a = annCfg(), rec = { at: Date.now(), tag: tag, text: text, device: annDevice(), result: '' }, bl = load('vmBlock', null);
    if (!annReady()) rec.result = 'skipped: Alexa not set up (Settings \u2192 Connected apps: Voice Monkey token + disclosure)';
    else if (dry()) rec.result = 'DRY RUN: not sent';
    else if (bl && Date.parse(bl.until) > Date.now()) rec.result = 'skipped: ' + bl.why;
    else rec.result = 'sending';
    L.ann = (L.ann || []).concat([rec]).slice(-20);
    if (/^skipped/.test(rec.result) && !L.annNoted) { L.annNoted = true; note(L, 'Alexa ' + rec.result); }
    if (rec.result !== 'sending') return rec;
    L.announced = (L.announced || 0) + 1;
    var id = L.id, idx = L.ann.length - 1;
    vmSend(a.token, rec.device, text).then(function (r) {
      var M = st(); if (!M || M.id !== id || !M.ann || !M.ann[idx]) return;
      M.ann[idx].result = r.ok ? 'announced' : 'failed: ' + (r.why || (r.code ? 'HTTP ' + r.code + (r.error && r.error !== 'HTTP ' + r.code ? ' ' + r.error : '') : r.error));
      if (!r.ok) note(M, 'Alexa announcement failed (' + tag + '): ' + M.ann[idx].result.replace(/^failed: /, ''));
      put(M); paint();
    });
    return rec;
  }

  // ---------- run ----------
  function own(L) {
    var now = Date.now();
    if (!L.owner || L.owner.by === TAB || now - L.owner.at > OWNER_STALE) { L.owner = { by: TAB, at: now }; return true; }
    return false;
  }
  function confirmBox(q, yes, sub) {
    if (opts.confirm) return opts.confirm(q, yes, sub);
    return new Promise(function (res) {
      var d = document.createElement('div'); d.className = 'modal';
      d.innerHTML = '<div class="mbox" role="dialog" aria-modal="true"><div class="mq">' + esc(q) + '</div>' + (sub ? '<div class="msub">' + esc(sub) + '</div>' : '') + '<div class="mbtns"><button class="btn ghost" id="mNo">Cancel</button><button class="btn" id="mYes">' + esc(yes || 'Yes') + '</button></div></div>';
      document.body.appendChild(d);
      function done(v) { d.remove(); res(v); }
      d.querySelector('#mNo').onclick = function () { done(false); }; d.querySelector('#mYes').onclick = function () { done(true); };
      d.onclick = function (e) { if (e.target === d) done(false); };
    });
  }
  function skipLeave() { var s = load('skipConfirm', null); return !!(s && s.leave === true); }   // v4.3.18: td:skipConfirm (shared with the main app's SKIP CONFIRM row)
  function setSkipLeave(on) { var s = load('skipConfirm', null); if (!s || typeof s !== 'object') s = {}; s.leave = !!on; save('skipConfirm', s); }
  function start() {
    var L = st(); if (active(L)) return;
    if (!hasSetup()) { msg = 'Set up your Tessie token first.'; paint(); return; }
    if (!cmdAllowed()) { msg = 'Commands are off: allow vehicle commands first (Settings \u2192 Permissions).'; paint(); return; }
    readInputs(); var m = mins();
    var sub = summary(m) + '. ' + (m[2] > 0 ? 'Nothing happens for ' + minTxt(m[2]) + ' (Stop just cancels). Then c' : 'C') + 'limate turns on, ' + inTxt(m[0], 'the windows close right away', 'the windows close {0} later') + ', then ' + inTxt(m[1], 'the car unlocks right after that', 'the car unlocks {0} after that') +
      '. Each step is announced on Alexa. Stop cancels the rest and undoes the steps already done. Keep this page open during the countdown.';
    return (skipLeave() ? Promise.resolve(true) : confirmBox('Are you sure? Start Leaving Soon?', 'Start', sub)).then(function (yes) {   // v4.3.18 SKIP CONFIRM
      if (!yes) { msg = 'Leaving Soon cancelled'; paint(); return false; }
      if (active(st())) return false;
      var s = spm(), now = Date.now();
      put({ v: 1, id: now.toString(36) + TAB, phase: m[2] > 0 ? 'pre' : 'snap', mins: m, spm: s, waits: [m[2] * s * 1000, m[0] * s * 1000, m[1] * s * 1000], startedAt: now, step: 0, dueAt: now + (m[2] > 0 ? m[2] * s * 1000 : 0),
        sending: null, snapAt: 0, snap: null, done: [], undo: [], undoIdx: 0, undoDone: [], undoFailed: [], notes: [], late: [], log: [], ann: [], announced: 0,
        result: '', kind: 'busy', endedAt: 0, dry: dry(), owner: { by: TAB, at: now } });
      msg = ''; ensureTimer(); tick(); return true;
    });
  }
  function doSnap(L) {
    var id = L.id; snapping[id] = true; L.snapAt = Date.now(); put(L);
    function fin(snap) {
      delete snapping[id]; var M = st(); if (!M || M.id !== id) return;
      M.snap = snap; if (snap.src !== 'Tessie cached state') note(M, 'Start state from the ' + snap.src);
      if (M.phase === 'snap') { M.phase = 'run'; M.step = 0; M.dueAt = Date.now(); }
      put(M); tick();
    }
    var c = cfg();
    if (!ok(c)) { fin(snapFrom(null, 'unknown: no Tessie token / VIN')); return; }
    readState().then(function (j) { carReadAt = Date.now(); fin(snapFrom(j, 'Tessie cached state')); }, function (e) {
      var cs = cachedState(), why = 'cached state read failed (' + String(e.message || e) + ')';
      fin(cs ? snapFrom(cs.state, 'last TessDesk refresh (' + clock(cs.at) + '): ' + why) : snapFrom(null, 'unknown: ' + why));
    });
  }
  function send(L, cmd, kind) {
    var id = L.id; L.sending = { cmd: cmd, kind: kind, at: Date.now(), by: TAB }; put(L); inflight[id] = true; paint();
    var t0 = Date.now();
    command(cmd).then(function (j) { return { ok: true, dry: !!(j && j.dryRun) }; }, function (e) { var w = String(e.message || e); return { ok: false, why: w.length > 90 ? w.slice(0, 90) + '\u2026' : w }; }).then(function (res) {
      delete inflight[id];
      var M = st(); if (!M || M.id !== id) return;
      M.sending = null;
      M.log = (M.log || []).concat([{ at: new Date().toISOString(), cmd: cmd, kind: kind, ok: res.ok, error: res.why || '', ms: Date.now() - t0, dryRun: res.dry }]);
      try { if (opts.onCmd) opts.onCmd(cmd, res.ok, res.dry); } catch (e) {}
      if (res.ok) { var o = { start_climate: ['climateOn', true], close_windows: ['windowsOpen', false], unlock: ['locked', false], stop_climate: ['climateOn', false], vent_windows: ['windowsOpen', true], lock: ['locked', true] }[cmd]; if (o) ov[o[0]] = { v: o[1], until: Date.now() + 180000 }; if (!res.dry && opts.ownRefresh) setTimeout(function () { readCar(true); }, 6000); }
      if (kind === 'undo') completeUndo(M, cmd, res); else completeStep(M, cmd, res);
    });
  }
  function completeStep(M, cmd, res) {
    var s = STEPS[M.step];
    if (res.ok && M.done.indexOf(cmd) < 0) M.done.push(cmd);
    if (M.phase === 'stopping') { note(M, 'The ' + cmd + ' request was already sent: ' + (res.ok ? 'it went through' : 'it failed (' + res.why + ')') + '.'); planUndo(M); return; }
    if (M.phase !== 'run') { put(M); paint(); return; }
    if (!res.ok) { fail(M, s, res.why); return; }
    var txt = s.spoken;
    if (M.step === 0) txt = 'Leaving Soon: climate is now on. ' + cap(inTxt(M.mins[0], 'the windows close right away', 'the windows close in {0}')) + ', and ' + inTxt(M.mins[1], 'the car unlocks right after that', 'the car unlocks {0} after that') + '.';
    announce(M, txt, cmd);
    M.step++;
    if (M.step >= STEPS.length) { M.phase = 'done'; M.kind = 'ok'; M.endedAt = Date.now(); M.result = 'Leaving Soon done \u00b7 climate on, windows closed, unlocked \u00b7 ' + clock(M.endedAt) + dryTag(); }
    else M.dueAt = Date.now() + M.waits[M.step];
    put(M); setTimeout(tick, 0);
  }
  function fail(M, s, why) {
    var skipped = STEPS.slice(M.step + 1).map(function (x) { return x.label.toLowerCase(); });
    M.phase = 'failed'; M.kind = 'err'; M.endedAt = Date.now();
    M.result = 'Step ' + (M.step + 1) + ' of 3 failed: ' + s.cmd + ': ' + why + (skipped.length ? '. Skipped: ' + skipped.join(', ') : '');
    var reason = /token/.test(why) ? ' because the Tessie token was rejected' : (/timed out|timeout|no response|did not confirm/.test(why) ? ' because the car did not respond' : '');
    announce(M, 'Leaving Soon stopped. TessDesk could not ' + s.what + reason + '.' + (skipped.length ? ' The remaining steps will not run.' : ''), 'failed');
    put(M); paint();
  }
  function planUndo(M) {
    var sn = M.snap, plan = [], d = M.done.slice().reverse();
    d.forEach(function (c) {
      var need = false, why = '';
      if (c === 'start_climate') { if (!sn || sn.climateOn == null) why = 'climate start state unknown, left on'; else if (!sn.climateOn) need = true; else why = 'climate was already on'; }
      if (c === 'close_windows') { if (!sn || sn.anyOpen == null) why = 'window start state unknown, left closed'; else if (sn.anyOpen) need = true; else why = 'windows were already closed'; }
      if (c === 'unlock') { if (!sn || sn.locked == null || sn.locked) need = true; else why = 'it was already unlocked'; }   // unknown -> lock
      if (need) plan.push(UNDO[c].cmd); else note(M, 'Not undone: ' + why + '.');
    });
    M.undo = plan; M.undoIdx = 0; M.undoDone = []; M.undoFailed = []; M.cancelSaid = false;
    if (!plan.length) { if (M.announced) { announce(M, 'Leaving Soon is cancelled. The remaining steps will not run.', 'cancel'); M.cancelSaid = true; } finishStop(M); return; }
    M.phase = 'undo'; M.kind = 'busy'; put(M); setTimeout(tick, 0);
  }
  function completeUndo(M, cmd, res) {
    var u = UNDO_BY[cmd], first = !M.cancelSaid, pre = first ? 'Leaving Soon is cancelled. ' : 'Leaving Soon undo: '; M.undoIdx++; M.cancelSaid = true;
    if (res.ok) { M.undoDone.push(u.done); announce(M, pre + (first ? cap(u.spoken) : u.spoken), 'undo-' + cmd); }
    else {
      M.undoFailed.push(cmd + ': ' + res.why); note(M, 'Undo ' + cmd + ' failed: ' + res.why);
      var reason = /token/.test(res.why) ? ' because the Tessie token was rejected' : (/timed out|timeout|no response|did not confirm/.test(res.why) ? ' because the car did not respond' : '');
      announce(M, pre + 'Undo failed. TessDesk could not ' + u.what + reason + '.', 'undo-failed-' + cmd);
    }
    if (M.undoIdx >= M.undo.length) { finishStop(M); return; }
    put(M); setTimeout(tick, 0);
  }
  function finishStop(M) {
    var doneTxt = STEPS.filter(function (s) { return M.done.indexOf(s.cmd) >= 0; }).map(function (s) { return s.done; }), n = M.undo.length, bad = M.undoFailed.length;
    var t = (M.phase === 'expired' || M.wasExpired ? 'Leaving Soon expired' : 'Leaving Soon stopped') + ' \u00b7 ' + (doneTxt.length ? doneTxt.join(', ') + ', ' : '') + 'the rest cancelled';
    if (n) t += ' \u00b7 undid ' + M.undoDone.length + ' of ' + n + (M.undoDone.length ? ': ' + M.undoDone.join(', ') : '');
    if (bad) t += ' \u00b7 FAILED: ' + M.undoFailed.join('; ');
    M.phase = 'cancelled'; M.endedAt = Date.now(); M.kind = bad ? 'err' : 'idle';
    M.result = t + ' \u00b7 ' + clock(M.endedAt) + (n || doneTxt.length ? dryTag() : '');
    put(M); paint();
  }
  function expire(M, late) {
    var s = STEPS[M.step];
    M.phase = 'expired'; M.wasExpired = true; M.kind = 'err'; M.endedAt = Date.now();
    M.result = 'Leaving Soon expired \u00b7 ' + s.name + ' was due at ' + clock(M.dueAt) + ', but this page was closed for ' + span(late) + '. It is too late to run it, so the remaining steps are cancelled.' +
      (M.done.length ? ' Already done: ' + STEPS.filter(function (x) { return M.done.indexOf(x.cmd) >= 0; }).map(function (x) { return x.done; }).join(', ') + '. Tap UNDO to undo them.' : '');
    put(M); paint();
  }
  function stop() {
    var L = st(); if (!L) return;
    if (L.phase === 'undo' || L.phase === 'stopping') return;
    if (L.phase === 'pre') {   // v4.3.19: stopped before anything started: nothing to undo
      L.phase = 'cancelled'; L.kind = 'idle'; L.endedAt = Date.now();
      L.result = 'Leaving Soon cancelled before it started \u00b7 nothing to undo \u00b7 ' + clock(L.endedAt);
      note(L, 'Cancelled during the start-after countdown: nothing was sent.'); put(L); paint(); return; }
    if (L.phase === 'expired' && L.done.length) { L.phase = 'stopping'; planUndo(L); return; }
    if (!active(L)) { dismiss(); return; }
    L.phase = 'stopping'; L.kind = 'idle'; L.endedAt = Date.now(); own(L);
    if (L.sending) { L.result = 'Leaving Soon stopping \u00b7 waiting for the ' + L.sending.cmd + ' result\u2026'; put(L); paint(); return; }
    planUndo(L);
  }
  function dismiss() { save('leave', null); msg = ''; stopTimer(); paint(); }
  function tick() {
    var L = st();
    if (!active(L)) { stopTimer(); autoHide(L); paint(); return; }
    if (!own(L)) { paint(); return; }   // another open page (tab) is running it
    var now = Date.now(), s = L.sending;
    if (s && s.by !== TAB && !inflight[L.id] && now - s.at > STALE_SEND) {
      // the page that sent this request was closed before the answer came back
      L.sending = null;
      if (s.kind === 'step' && (L.phase === 'stopping' || now - s.at > MAXMIN * L.spm * 1000)) {
        if (L.done.indexOf(s.cmd) < 0) L.done.push(s.cmd);
        note(L, 'The ' + s.cmd + ' request sent at ' + clock(s.at) + ' never reported back (page closed); counted as done.');
        if (L.phase === 'stopping') { planUndo(L); paint(); return; }
        L.step++; if (L.step >= STEPS.length) { L.phase = 'done'; L.kind = 'ok'; L.endedAt = now; L.result = 'Leaving Soon done (last result unknown) \u00b7 ' + clock(now); put(L); paint(); return; }
        L.dueAt = s.at + L.waits[L.step];
      } else {
        note(L, 'The ' + s.cmd + ' request sent at ' + clock(s.at) + ' never reported back (page closed); sending it again.');
        put(L); send(L, s.cmd, s.kind); return;
      }
    }
    if (L.phase === 'pre') {
      if (now - L.dueAt > MAXMIN * L.spm * 1000) {   // the 30-minute late limit applies to the pre-leave step too
        L.phase = 'cancelled'; L.kind = 'err'; L.endedAt = now;
        L.result = 'Leaving Soon expired \u00b7 the start was due at ' + clock(L.dueAt) + ', but this page was closed for ' + span(now - L.dueAt) + '. It is too late to start, so nothing was sent.';
        put(L); paint(); return; }
      if (now >= L.dueAt) {
        if (now - L.dueAt > LATE_NOTE) { L.late.push({ cmd: 'start', dueAt: L.dueAt, ranAt: now }); note(L, 'The start was due at ' + clock(L.dueAt) + ' and ran at ' + clock(now) + ' (' + span(now - L.dueAt) + ' late: the page was closed or the screen was locked).'); }
        L.phase = 'snap'; put(L); doSnap(L); return; }
    }
    else if (L.phase === 'snap') { if (!snapping[L.id] && (!L.snapAt || now - L.snapAt > 15000)) { doSnap(L); return; } }
    else if (L.phase === 'run' && !L.sending && now >= L.dueAt) {
      var late = now - L.dueAt, step = STEPS[L.step];
      if (L.step > 0 && late > MAXMIN * L.spm * 1000) { expire(L, late); return; }
      if (L.step > 0 && late > LATE_NOTE) { L.late.push({ cmd: step.cmd, dueAt: L.dueAt, ranAt: now }); note(L, step.name + ' was due at ' + clock(L.dueAt) + ' and ran at ' + clock(now) + ' (' + span(late) + ' late: the page was closed or the screen was locked).'); }
      send(L, step.cmd, 'step'); return;
    } else if (L.phase === 'undo' && !L.sending) {
      if (L.undoIdx >= L.undo.length) { finishStop(L); return; }
      send(L, L.undo[L.undoIdx], 'undo'); return;
    }
    if ((L.phase === 'run' || L.phase === 'pre') && !L.sending) { clearTimeout(dueTimer); dueTimer = setTimeout(tick, Math.max(0, L.dueAt - now) + 15); }   // exact due time (the 1 s timer only repaints)
    put(L); paint();
  }
  function autoHide(L) { if (L && (L.phase === 'done' || (L.phase === 'cancelled' && L.kind !== 'err')) && Date.now() - L.endedAt > 30 * 60000) save('leave', null); }
  function ensureTimer() { if (!timer) timer = setInterval(tick, 1000); }
  function stopTimer() { if (timer) { clearInterval(timer); timer = null; } }

  // ---------- car status (standalone page) ----------
  function ovVal(k, v) { var o = ov[k]; if (o && Date.now() < o.until && String(o.v) !== String(v)) return o.v; delete ov[k]; return v; }
  function car() {
    var cs = cachedState(); if (!cs) return null;
    var vs = cs.state.vehicle_state || {}, cl = cs.state.climate_state || {}, w = ['fd_window', 'fp_window', 'rd_window', 'rp_window'].filter(function (k) { return vs[k] != null; });
    return { locked: ovVal('locked', vs.locked != null ? !!vs.locked : null), climateOn: ovVal('climateOn', cl.is_climate_on != null ? !!cl.is_climate_on : null),
      windowsOpen: ovVal('windowsOpen', w.length ? w.some(function (k) { return +vs[k] !== 0; }) : null), at: cs.at, inside: cl.inside_temp };
  }
  function readCar(force) {
    if (carBusy || !hasSetup()) return;
    var cs = cachedState(); if (!force && cs && Date.now() - cs.at < 60000) return;
    carBusy = true; paint();
    readState().then(function () { carErr = ''; carReadAt = Date.now(); }, function (e) { carErr = String(e.message || e); }).then(function () { carBusy = false; paint(); });
  }
  function carLine() {
    var c = car();
    if (!c) return '<div class="lv-car">' + (carBusy ? 'Reading car status\u2026' : (carErr ? 'Car status unavailable (' + esc(carErr) + ')' : 'Car status not read yet')) + '</div>';
    function b(v, yes, no, warn) { return v == null ? '<span>?</span>' : '<span class="' + (v === warn ? 'w' : 'g') + '">' + (v ? yes : no) + '</span>'; }
    var age = Math.max(0, Date.now() - c.at), ago = age < 90000 ? Math.round(age / 1000) + 's ago' : span(age) + ' ago';
    return '<div class="lv-car">' + b(c.locked, 'Locked', 'Unlocked', false) + ' \u00b7 ' + b(c.climateOn, 'Climate on', 'Climate off', null) + ' \u00b7 ' + b(c.windowsOpen, 'Windows open', 'Windows closed', true) +
      ' <em>' + (carBusy ? 'updating\u2026' : ago) + '</em></div>';
  }

  // ---------- UI ----------
  function stepText(L, now) {
    if (L.phase === 'pre') return 'Starting in ' + mmss(L.dueAt - now);
    if (L.phase === 'undo') { var n = L.undo.length, i = Math.min(L.undoIdx, n - 1), u = UNDO_BY[L.undo[i]]; return 'Undoing ' + (i + 1) + ' of ' + n + ' \u00b7 ' + u.doing + '\u2026'; }
    if (L.phase === 'stopping') return L.result || 'Stopping\u2026';
    if (!active(L)) return L.result;
    if (L.phase === 'snap') return 'Step 1 of 3 \u00b7 reading the start state\u2026';
    var s = STEPS[Math.min(L.step, 2)];
    if (L.sending) return 'Step ' + (L.step + 1) + ' of 3 \u00b7 ' + s.doing + '\u2026' + (dry() ? ' (dry run)' : '');
    return 'Step ' + (L.step + 1) + ' of 3 \u00b7 ' + s.next + ' in ' + mmss(L.dueAt - now);
  }
  function inner(kind) {
    var L = st(), act = active(L), m = act ? L.mins : mins(), now = Date.now(), ready = hasSetup() && cmdAllowed(), dis = act ? ' disabled' : '';
    var sub = act ? (L.phase === 'undo' || L.phase === 'stopping' ? 'stopping\u2026' : 'running \u00b7 tap STOP to cancel') :
      (!hasSetup() ? 'set up Tessie first' : (!cmdAllowed() ? 'commands are off (Permissions)' : summary(m)));
    var h = '<button class="cbtn lv-go' + (act ? ' on' : '') + '" data-lv="start" id="lvGo"' + (act || !ready ? ' disabled' : '') + '><b>LEAVING SOON</b><small>' + esc(sub) + '</small></button>';
    function pm(key, label, v, max, len) {
      return '<div class="lv-w"><span class="lv-wl">' + label + '</span><div class="lv-pm"><button class="cbtn sq" data-lv="' + key + '-" aria-label="' + label + ' minus one minute"' + dis + '>\u2212</button>' +
        '<label class="lv-v"><input id="lv' + key.toUpperCase() + '" data-lvin="' + key + '" data-lvmax="' + max + '" type="text" inputmode="numeric" pattern="[0-9]*" maxlength="' + len + '" value="' + v + '" aria-label="' + label + ', minutes (0-' + max + ')"' + dis + '><small>MIN</small></label>' +
        '<button class="cbtn sq" data-lv="' + key + '+" aria-label="' + label + ' plus one minute"' + dis + '>+</button></div></div>';
    }
    h += '<div class="lv-waits">' + pm('s', 'Start after', m[2], STARTMAX, 3) + pm('w', 'Windows after', m[0], MAXMIN, 2) + pm('u', 'Unlock after', m[1], MAXMIN, 2) + '</div>';
    if (L) {
      var pct = 0, wait = L.waits ? L.waits[Math.min(L.step, 2)] : 0;
      if (L.phase === 'pre' && L.waits && L.waits[0] > 0) pct = Math.max(0, Math.min(100, 100 - (L.dueAt - now) / L.waits[0] * 100));
      else if (L.phase === 'run' && !L.sending && wait > 0) pct = Math.max(0, Math.min(100, 100 - (L.dueAt - now) / wait * 100));
      else if (L.phase === 'run' && (L.sending || wait === 0)) pct = 100;
      else if (L.phase === 'undo') pct = L.undo.length ? L.undoIdx / L.undo.length * 100 : 100;
      else if (!act) pct = 100;
      var dots = STEPS.map(function (s, i) {
        var c = L.done.indexOf(s.cmd) >= 0 ? (L.undo && L.undoIdx > L.undo.indexOf(UNDO[s.cmd].cmd) && L.undo.indexOf(UNDO[s.cmd].cmd) >= 0 ? 'undone' : 'done') : (act && L.phase === 'run' && L.step === i ? 'cur' : (L.phase === 'failed' && L.step === i ? 'bad' : ''));
        return '<span class="lv-dot ' + c + '">' + (c === 'done' ? '\u2713 ' : (c === 'undone' ? '\u21ba ' : (c === 'bad' ? '\u2715 ' : ''))) + s.label + '</span>';
      }).join('');
      var pending = L.phase === 'undo' || L.phase === 'stopping', stopTxt = act ? (pending ? 'STOPPING\u2026' : 'STOP') : (L.phase === 'expired' && L.done.length ? 'UNDO' : 'CLOSE');
      h += '<div class="lv-run ' + (L.kind === 'err' ? 'err' : (pending || L.kind === 'idle' ? 'amber' : (L.kind === 'ok' ? 'ok' : 'busy'))) + '" id="lvRun">' +
        '<div class="lv-step" id="lvStep">' + (act && !pending ? '<span class="spin"></span>' : '') + '<span>' + esc(stepText(L, now)) + '</span></div>' +
        '<div class="lv-bar"><i style="width:' + pct.toFixed(1) + '%"></i></div><div class="lv-dots">' + dots + '</div>' +
        ((L.notes || []).length ? '<div class="lv-notes" id="lvNotes">' + L.notes.map(function (n) { return '<div' + (/fail|could not|skipped|late|expired|never/.test(n) ? ' class="bad"' : '') + '>' + esc(n) + '</div>'; }).join('') + '</div>' : '') +
        '<div class="lv-btns"><button class="cbtn lv-stop' + (act ? ' live' : '') + '" data-lv="stop" id="lvStop"' + (pending ? ' disabled' : '') + '><b>' + stopTxt + '</b></button>' +
        (L.phase === 'expired' && L.done.length ? '<button class="cbtn lv-x" data-lv="close" id="lvClose"><b>CLOSE</b></button>' : '') + '</div></div>';
    }
    h += '<div class="lv-note">' + (msg ? '<b>' + esc(msg) + '</b> \u00b7 ' : '') + 'Keep this page open during the countdown. If the screen locks, the next step runs when you come back to this page.' + (dry() ? ' <span class="dry">DRY RUN</span>' : '') + '</div>';
    if (kind === 'page') h += '<label class="lv-skip"><input type="checkbox" data-lvskip="1" id="lvSkip"' + (skipLeave() ? ' checked' : '') + '><span>Skip confirm</span><small>start with no Yes / No pop-up</small></label>';   // v4.3.18
    if (kind === 'page') h = carLine() + h;
    return h;
  }
  function html(kind) { return '<div class="lv lv-' + (kind || 'main') + '" id="lvBox" data-kind="' + (kind || 'main') + '">' + inner(kind) + '</div>'; }
  function paint() {
    var b = document.getElementById('lvBox'); if (!b) return;
    var f = document.activeElement && document.activeElement.getAttribute && document.activeElement.getAttribute('data-lvin');
    if (f) return;   // do not repaint under the user's typing
    b.innerHTML = inner(b.getAttribute('data-kind'));
    if (opts.onPaint) try { opts.onPaint(); } catch (e) {}
  }
  function readInputs() {
    var w = document.querySelector('[data-lvin="w"]'), u = document.querySelector('[data-lvin="u"]'), s2 = document.querySelector('[data-lvin="s"]'), m = mins();
    if (w || u || s2) setMins(w ? w.value : m[0], u ? u.value : m[1], s2 ? s2.value : m[2]);
  }
  function bump(key, d) { if (active(st())) return; var m = mins(); if (key === 'w') m[0] = clampMin(m[0] + d); else if (key === 'u') m[1] = clampMin(m[1] + d); else m[2] = clampStart(m[2] + d); setMins(m[0], m[1], m[2]); paint(); }
  document.addEventListener('click', function (e) {
    var t = e.target && e.target.closest ? e.target.closest('[data-lv]') : null; if (!t || t.disabled) return;
    var a = t.getAttribute('data-lv'); e.preventDefault();
    if (a === 'start') start(); else if (a === 'stop') stop(); else if (a === 'close') dismiss();
    else if (a === 'w-') bump('w', -1); else if (a === 'w+') bump('w', 1); else if (a === 'u-') bump('u', -1); else if (a === 'u+') bump('u', 1);
    else if (a === 's-') bump('s', -1); else if (a === 's+') bump('s', 1);
  });
  document.addEventListener('change', function (e) { var t = e.target; if (t && t.getAttribute && t.getAttribute('data-lvskip')) setSkipLeave(t.checked); });   // v4.3.18
  document.addEventListener('input', function (e) { var t = e.target; if (t && t.getAttribute && t.getAttribute('data-lvin')) t.value = t.value.replace(/[^0-9]/g, '').slice(0, t.getAttribute('data-lvin') === 's' ? 3 : 2); });
  document.addEventListener('change', function (e) { var t = e.target; if (t && t.getAttribute && t.getAttribute('data-lvin')) { readInputs(); t.blur(); paint(); } });
  document.addEventListener('keydown', function (e) { var t = e.target; if (t && t.getAttribute && t.getAttribute('data-lvin') && e.key === 'Enter') { readInputs(); t.blur(); paint(); } });
  function wake() { var L = st(); if (active(L)) { ensureTimer(); tick(); } else paint(); if (opts.ownRefresh && document.visibilityState === 'visible') readCar(false); }
  document.addEventListener('visibilitychange', function () { if (document.visibilityState === 'visible') wake(); });
  window.addEventListener('pageshow', wake); window.addEventListener('focus', wake);
  window.addEventListener('storage', function (e) { if (e.key === P + 'leave' || e.key === P + 'leaveMins' || e.key === P + 'cache' || e.key === P + 'skipConfirm') { if (active(st())) ensureTimer(); paint(); } });

  window.TDLeave = {
    version: 'v4.3.21', skipLeave: function () { return skipLeave(); },
    init: function (o) { opts = o || {}; if (active(st())) { ensureTimer(); setTimeout(tick, 0); } return window.TDLeave; },
    html: html, paint: paint, start: start, stop: stop, dismiss: dismiss, tick: tick, mins: mins, setMins: function (w, u, s2) { setMins(w, u, s2); paint(); }, summary: summary,
    state: st, active: function () { return active(st()); }, cmdLog: cmdLog, hasSetup: hasSetup, cmdAllowed: cmdAllowed, readCar: readCar, car: car,
    vmSend: vmSend, annDevice: annDevice, cfg: cfg, prefix: P, steps: STEPS
  };
})();
