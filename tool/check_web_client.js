#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.join(__dirname, '..');
const logicPath = path.join(root, 'webapp', 'logic.js');
const appPath = path.join(root, 'webapp', 'app.js');
const htmlPath = path.join(root, 'webapp', 'index.html');

const context = { console, atob, btoa, URL, URLSearchParams };
vm.createContext(context);
vm.runInContext(fs.readFileSync(logicPath, 'utf8'), context);
const L = context.MailChatLogic;
if (!L) {
  console.error('MailChatLogic missing');
  process.exit(1);
}

function assert(cond, message) {
  if (!cond) {
    console.error('FAIL', message);
    process.exit(1);
  }
}

assert(L.usernameError('ab') !== '', 'short username');
assert(L.usernameError('ada') === '', 'ok username');
assert(L.usernameError('Ada') !== '', 'uppercase username');
assert(L.passwordError('short') !== '', 'short password');
assert(L.passwordError('Secret12') === '', 'ok password');

const turns = L.parseTurnUrls(
  'stun:stun.l.google.com:19302, https://global.relay.metered.ca:443?transport=tcp, turn:global.relay.metered.ca:80'
);
assert(turns.length === 2, 'turn parse count ' + turns.join('|'));
assert(turns[0].indexOf('turns:') === 0, 'https rewritten');
assert(turns[1].indexOf('turn:') === 0, 'turn kept');

const ice = L.buildIceServers('stun:stun.l.google.com:19302', turns.join(','), 'user', 'secret');
assert(ice.forceRelay === true, 'relay policy');
assert(ice.iceServers.length === 6, 'stun plus two relays plus public ' + ice.iceServers.length);
assert(ice.iceServers[1].username === 'user', 'turn username');
const bare = L.buildIceServers('stun:stun.l.google.com:19302', '', '', '');
assert(bare.iceServers.length === 4, 'public relay without pasted TURN');
assert(bare.iceServers[3].urls.indexOf('transport=tcp') > 0, 'public tcp relay');

const link = L.parseAuthLink(
  'https://example.com/Mailchat/webapp/index.html#access_token=abc&refresh_token=def&type=signup'
);
assert(link && link.kind === 'session' && link.access === 'abc', 'session link');
const recovery = L.parseAuthLink('https://example.com/app#access_token=abc&type=recovery');
assert(recovery.kind === 'recovery', 'recovery link');
const bad = L.parseAuthLink('https://example.com/app?error_description=expired');
assert(bad.kind === 'error' && bad.error === 'expired', 'error link');
const hashToken = L.parseAuthLink('https://example.com/app?token_hash=xyz&type=signup');
assert(hashToken.kind === 'token' && hashToken.tokenHash === 'xyz', 'token hash');

assert(L.receiptStatus([]) === 'sent', 'no receipts');
assert(L.receiptStatus([{ delivered_at: 't' }]) === 'delivered', 'delivered');
assert(L.receiptStatus([{ delivered_at: 't', read_at: 't' }]) === 'read', 'read wins');

const header = Buffer.from(JSON.stringify({ role: 'service_role' })).toString('base64url');
assert(L.jwtRole('aaa.' + header + '.sig') === 'service_role', 'service role');
const anon = Buffer.from(JSON.stringify({ role: 'anon' })).toString('base64url');
assert(L.jwtRole('aaa.' + anon + '.sig') === 'anon', 'anon role');

var now = Date.parse('2026-10-27T12:00:00Z');
assert(L.ringIsFresh('2026-10-27T11:59:40Z', now), 'fresh ring');
assert(!L.ringIsFresh('2026-10-27T11:00:00Z', now), 'old ring');
assert(L.ringShouldClear('2026-10-27T11:00:00Z', true, now), 'clear old incoming');
assert(!L.ringShouldClear('2026-10-27T11:59:00Z', false, now), 'keep a live outgoing ring');
assert(L.sdpForPhone('v=0\r\na=extmap-allow-mixed\r\n').indexOf('extmap-allow-mixed') === -1, 'sdp line dropped');

assert(L.esc('<b>"') === '&lt;b&gt;&quot;', 'escape');
assert(L.sanitiseFileName('../a b.png') === 'a_b.png', 'file name');

const html = fs.readFileSync(htmlPath, 'utf8');
assert(html.includes('logic.js') && html.includes('app.js'), 'scripts linked');
assert(html.includes('id="call-layer"'), 'call layer present');
assert(!html.includes('service_role'), 'no service role in the page');

const app = fs.readFileSync(appPath, 'utf8');
assert(L.friendlyError({ code: '42501', message: 'new row violates row-level security policy for table "calls"' }, '', 403).indexOf('0010_call_write.sql') > 0, 'call rls hint');
assert(L.rpcMissing('Could not find the function public.place_call in the schema cache'), 'missing rpc');
assert(!L.rpcMissing('new row violates row-level security policy for table "calls"'), 'rls is not a missing rpc');
assert(app.includes("iceTransportPolicy: 'all'"), 'policy all');
assert(app.includes('/rest/v1/rpc/place_call'), 'place_call');
assert(app.includes('/rest/v1/rpc/set_call_status'), 'set_call_status');
assert(!app.includes("iceTransportPolicy: ice.forceRelay"), 'no relay-only policy');
assert(app.includes('on_conflict=message_id,recipient_id'), 'receipt upsert');
vm.runInContext(app, context, { filename: appPath });
console.log('web client checks ok');
