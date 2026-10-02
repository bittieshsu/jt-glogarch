#!/usr/bin/env node
// Translate backend messages with the REAL i18n.js (trSrv) for the pytest gate
// tests/test_srv_messages.py. Reads [{text, lang}] JSON on stdin, prints the
// translations as a JSON array.
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const src = fs.readFileSync(path.join(__dirname, '..', 'glogarch', 'web', 'static', 'js', 'i18n.js'), 'utf8');
let lang = 'en';
const ctx = {
    localStorage: {getItem: () => lang, setItem: () => {}},
    document: {querySelectorAll: () => [], documentElement: {}, dispatchEvent: () => {},
               addEventListener: () => {}, getElementById: () => null},
    window: {}, navigator: {language: 'en'},
    CustomEvent: function () {}, console,
};
vm.createContext(ctx);
vm.runInContext(src + '\n;this.__trSrv = trSrv;', ctx);
const cases = JSON.parse(fs.readFileSync(0, 'utf8'));
const out = cases.map(c => { lang = c.lang; return ctx.__trSrv(c.text); });
process.stdout.write(JSON.stringify(out));
