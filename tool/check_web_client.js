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
assert(ice.iceServers.length === 3, 'stun plus two relays');
assert(ice.iceServers[1].username === 'user', 'turn username');

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

assert(L.esc('<b>"') === '&lt;b&gt;&quot;', 'escape');
assert(L.sanitiseFileName('../a b.png') === 'a_b.png', 'file name');

const html = fs.readFileSync(htmlPath, 'utf8');
assert(html.includes('logic.js') && html.includes('app.js'), 'scripts linked');
assert(html.includes('id="call-layer"'), 'call layer present');
assert(!html.includes('service_role'), 'no service role in the page');

vm.runInContext(fs.readFileSync(appPath, 'utf8'), context, { filename: appPath });
console.log('web client checks ok');
