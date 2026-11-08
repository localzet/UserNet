# Страница загрузки UserNet

Статические файлы не требуют серверного исполнения. Размещайте их на том же
домене, где доступны `/usernet-updates/{android,windows,linux,macos}/stable.json`.
Отсутствующая или ошибочная публикация
отображается как недоступная платформа. Ссылки проверяются по HTTPS, хосту,
каталогу и расширению; архивы исходного кода не предлагаются для установки.

Проверка: `node --test website/usernet/app.test.cjs`.

# UserNet download page

These static files are intended for an origin serving the release manifests at
`/usernet-updates/{android,windows,linux,macos}/stable.json`. A missing or invalid manifest
leaves that platform unavailable. Run `node --test website/usernet/app.test.cjs`
from the repository root to check the link validation.

macOS releases use separate `dmgArm64Url` and `dmgAmd64Url` fields. They are
unsigned and require users to approve the app in macOS Privacy & Security on
first launch; do not describe them as notarized or silently auto-installable.
