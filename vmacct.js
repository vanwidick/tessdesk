/* TessDesk v1: Voice Monkey accounts (up to 3). Account 1 = Settings > Connected apps token/device (td:cfg announce) + td:vmUsage.
   Accounts 2/3 = td:vmAccts [{n, token, device, label}] + td:vmUsage2/3, td:vmBlock2/3. Each has its own 200/month (26th 7 PM CT).
   Announcements use account 1 until its month is used up, then 2, then 3. Tokens stay on this device (localStorage), like account 1. */
(function () {
  var P = (window.TD_CONFIG && window.TD_CONFIG.storagePrefix) || 'td:', LIM = 200, MAX = 3, MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  function ld(k, d) { try { var v = localStorage.getItem(P + k); return v ? JSON.parse(v) : d; } catch (e) { return d; } }
  function sv(k, v) { try { if (v == null) localStorage.removeItem(P + k); else localStorage.setItem(P + k, JSON.stringify(v)); } catch (e) {} }
  function period() {
    var o = {}; new Intl.DateTimeFormat('en-US', { timeZone: 'America/Chicago', year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', hourCycle: 'h23' }).formatToParts(new Date()).forEach(function (p) { o[p.type] = +p.value; });
    var y = o.year, m = o.month; if (o.day < 26 || (o.day === 26 && o.hour < 19)) { m--; if (m < 1) { m = 12; y--; } }
    var nm = m === 12 ? 1 : m + 1; return { key: y + '-' + (m < 10 ? '0' : '') + m + '-26', reset: MON[nm - 1] + ' 26, 7 PM CT' };
  }
  function uk(n) { return n > 1 ? 'vmUsage' + n : 'vmUsage'; }
  function bk(n) { return n > 1 ? 'vmBlock' + n : 'vmBlock'; }
  function a1() { var c = ld('cfg', null) || ld('leaveCfg', null) || {}; var a = c.announce || {}; return { n: 1, token: a.token || '', device: a.device || '', label: 'Account 1' }; }
  function extra() { return (ld('vmAccts', []) || []).filter(function (x) { return x && x.n > 1 && x.n <= MAX; }); }
  function acct(n) { if (n <= 1) return a1(); return extra().filter(function (x) { return +x.n === +n; })[0] || null; }
  function list() { return [a1()].concat(extra().sort(function (a, b) { return a.n - b.n; })); }
  function ready(n) { var a = acct(n); return !!(a && a.token && a.device); }
  function usage(n) {
    var p = period(), u = ld(uk(n), null), o = { n: n, period: p.key, count: 0, blocked: false, reason: '', resetAt: p.reset, limit: LIM };
    if (u && u.period === p.key) { o.count = +u.count || 0; o.blocked = !!u.blocked; o.reason = u.reason || ''; }
    var b = ld(bk(n), null); if (b && Date.parse(b.until) > Date.now() && /QUOTA|limit/i.test((b.why || '') + (b.error || ''))) { o.blocked = true; o.reason = o.reason || b.why; }
    if (o.count >= LIM) o.blocked = true; return o;
  }
  function active() { for (var n = 1; n <= MAX; n++) { if (ready(n) && !usage(n).blocked) return n; } return 0; }
  var T = {
    LIMIT: LIM, MAX: MAX, cur: 1, period: period, uk: uk, bk: bk, acct: acct, list: list, ready: ready, usage: usage, active: active,
    pick: function () { T.cur = Math.max(1, active()); return T.cur; },
    anyReady: function () { for (var n = 1; n <= MAX; n++) if (ready(n)) return true; return false; },
    tok: function (t1) { return T.cur > 1 ? (acct(T.cur) || {}).token : t1; },
    dev: function (d1) { return T.cur > 1 ? (acct(T.cur) || {}).device : d1; },
    targets: function (tg) { return T.cur > 1 ? [(acct(T.cur) || {}).device] : tg; },
    err: function (n) { var e = ld('vmErr' + (n > 1 ? n : ''), null); return e ? e.error + ' (' + e.at + ')' : ''; },
    setErr: function (n, msg) { sv('vmErr' + (n > 1 ? n : ''), { error: String(msg), at: new Date().toLocaleString('en-US', { timeZone: 'America/Chicago', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) + ' CT' }); },
    nextFree: function () { for (var n = 2; n <= MAX; n++) if (!acct(n)) return n; return 0; },
    save: function (n, token, device, label) {
      if (n <= 1) { var k = ld('cfg', null) ? 'cfg' : 'leaveCfg', c = ld(k, null) || {}; c.announce = c.announce || {}; if (token) c.announce.token = token; if (device) c.announce.device = device; sv(k, c); return; }
      var l = extra().filter(function (x) { return +x.n !== +n; }), o = acct(n) || {}; l.push({ n: n, token: token || o.token || '', device: device || o.device || '', label: label || 'Account ' + n }); sv('vmAccts', l);
    },
    remove: function (n) { if (n <= 1) return; sv('vmAccts', extra().filter(function (x) { return +x.n !== +n; })); },
    model: function () { var act = active(); return list().map(function (a) { var u = usage(a.n), r = ready(a.n); return { n: a.n, label: a.label, device: a.device, token: !!a.token, ready: r, count: u.count, limit: LIM, blocked: u.blocked, reason: u.reason, resetAt: u.resetAt, active: a.n === act, lastErr: T.err(a.n), status: !a.token ? 'NOT CONNECTED' : (!r ? 'NEEDS A DEVICE' : (u.blocked ? 'MONTH USED UP' : 'CONNECTED')) }; }); }
  };
  window.TDVM = T;
})();
