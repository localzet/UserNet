'use strict';
for (const [platform, field, extension] of [
  ['android', 'apkUrl', '.apk'],
  ['windows', 'installerUrl', '.exe'],
  ['linux', 'debUrl', '.deb'],
]) {
  const link = document.getElementById(platform);
  fetch(`/usernet-updates/${platform}/stable.json`, { cache: 'no-store' })
    .then(response => { if (!response.ok) throw new Error('unavailable'); return response.json(); })
    .then(release => {
      if (platform !== 'windows' && (!Number.isInteger(release.build) || release.build < 2026110502)) throw new Error('outdated release');
      const url = new URL(release[field]);
      const trustedPath = url.hostname === 'updates.userlay.com'
        ? `/${platform}/`
        : url.hostname === 'www.userlay.com'
          ? `/usernet-updates/${platform}/`
          : null;
      if (url.protocol !== 'https:' || url.username || url.password || url.port || !trustedPath || !url.pathname.startsWith(trustedPath) || url.search || url.hash || !url.pathname.endsWith(extension)) throw new Error('invalid release');
      link.href = url.href;
      link.textContent = `Скачать ${release.version || ''}`.trim();
      link.classList.remove('disabled');
      link.removeAttribute('aria-disabled');
    })
    .catch(() => { link.textContent = 'Пока недоступно'; });
}

for (const [arch, field] of [['arm64', 'dmgArm64Url'], ['amd64', 'dmgAmd64Url']]) {
  const link = document.getElementById(`macos-${arch}`);
  fetch('/usernet-updates/macos/stable.json', { cache: 'no-store' })
    .then(response => { if (!response.ok) throw new Error('unavailable'); return response.json(); })
    .then(release => {
      if (!Number.isInteger(release.build) || release.build < 2026110502) throw new Error('outdated release');
      const url = new URL(release[field]);
      const trustedPath = url.hostname === 'updates.userlay.com'
        ? '/macos/'
        : url.hostname === 'www.userlay.com'
          ? '/usernet-updates/macos/'
          : null;
      if (url.protocol !== 'https:' || url.username || url.password || url.port || !trustedPath || !url.pathname.startsWith(trustedPath) || url.search || url.hash || !url.pathname.endsWith('.dmg')) throw new Error('invalid release');
      link.href = url.href;
      link.textContent = `Скачать ${arch === 'arm64' ? 'Apple Silicon' : 'Intel'} · ${release.version || ''}`.trim();
      link.classList.remove('disabled');
      link.removeAttribute('aria-disabled');
    })
    .catch(() => { link.textContent = 'Пока недоступно'; });
}
