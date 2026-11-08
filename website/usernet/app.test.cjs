'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, 'app.js'), 'utf8');

async function render(manifests) {
  const links = Object.fromEntries(['android', 'windows', 'linux', 'macos-arm64', 'macos-amd64'].map(name => [name, {
    textContent: '', classList: { remove() {} }, removeAttribute() {},
  }]));
  const document = { getElementById: name => links[name] };
  const fetch = async url => {
    const platform = url.split('/')[2];
    const manifest = manifests[platform];
    return { ok: manifest != null, json: async () => manifest };
  };
  vm.runInNewContext(source, { document, fetch, URL });
  await new Promise(resolve => setImmediate(resolve));
  return links;
}

test('exposes the validated Android APK from a release manifest', async () => {
  const links = await render({ android: {
    version: '0.5.9',
    build: 2026110502,
    apkUrl: 'https://www.userlay.com/usernet-updates/android/usernet.apk',
  }});
  assert.equal(links.android.href, 'https://www.userlay.com/usernet-updates/android/usernet.apk');
  assert.equal(links.android.textContent, 'Скачать 0.5.9');
  assert.equal(links.windows.textContent, 'Пока недоступно');
});

test('does not advertise an older Android build as the current app', async () => {
  const links = await render({ android: {
    version: '0.5.6',
    build: 2026102907,
    apkUrl: 'https://www.userlay.com/usernet-updates/android/usernet.apk',
  } });
  assert.equal(links.android.href, undefined);
  assert.equal(links.android.textContent, 'Пока недоступно');
});

test('exposes a Windows installer only when a valid release exists', async () => {
  const links = await render({ windows: {
    version: '0.5.9',
    installerUrl: 'https://www.userlay.com/usernet-updates/windows/usernet.exe',
  } });
  assert.equal(links.windows.href, 'https://www.userlay.com/usernet-updates/windows/usernet.exe');
  assert.equal(links.windows.textContent, 'Скачать 0.5.9');
  assert.equal(links.android.textContent, 'Пока недоступно');
});

test('exposes the Linux DEB only when a valid release exists', async () => {
  const links = await render({ linux: {
    version: '0.5.11',
    build: 2026110803,
    debUrl: 'https://www.userlay.com/usernet-updates/linux/usernet-amd64.deb',
  } });
  assert.equal(links.linux.href, 'https://www.userlay.com/usernet-updates/linux/usernet-amd64.deb');
  assert.equal(links.linux.textContent, 'Скачать 0.5.11');
  assert.equal(links.android.textContent, 'Пока недоступно');
});

test('exposes architecture-specific macOS disk images only when valid', async () => {
  const links = await render({ macos: {
    version: '0.5.12',
    build: 2026110805,
    dmgArm64Url: 'https://updates.userlay.com/macos/UserNet-macos-arm64.dmg',
    dmgAmd64Url: 'https://updates.userlay.com/macos/UserNet-macos-amd64.dmg',
  } });
  assert.equal(links['macos-arm64'].href, 'https://updates.userlay.com/macos/UserNet-macos-arm64.dmg');
  assert.equal(links['macos-amd64'].href, 'https://updates.userlay.com/macos/UserNet-macos-amd64.dmg');
  assert.equal(links['macos-arm64'].textContent, 'Скачать Apple Silicon · 0.5.12');
  assert.equal(links.android.textContent, 'Пока недоступно');
});

test('rejects macOS downloads outside the trusted update origin', async () => {
  const links = await render({ macos: {
    version: '0.5.12',
    build: 2026110805,
    dmgArm64Url: 'https://evil.example/UserNet-macos-arm64.dmg',
    dmgAmd64Url: 'https://evil.example/UserNet-macos-amd64.dmg',
  } });
  assert.equal(links['macos-arm64'].href, undefined);
  assert.equal(links['macos-arm64'].textContent, 'Пока недоступно');
});

test('never offers source archives or links outside the release path', async () => {
  for (const apkUrl of [
    'https://www.userlay.com/usernet-updates/android/source.zip',
    'https://evil.example/android/usernet.apk',
    'https://www.userlay.com/other/android/usernet.apk',
    'https://www.userlay.com:8443/usernet-updates/android/usernet.apk',
  ]) {
    const links = await render({ android: { version: '1', build: 2026110502, apkUrl } });
    assert.equal(links.android.href, undefined);
    assert.equal(links.android.textContent, 'Пока недоступно');
  }
});
