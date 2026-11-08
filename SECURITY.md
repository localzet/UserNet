# Политика безопасности / Security policy

## Поддерживаемые версии

Проверки безопасности выполняются для последней опубликованной версии и текущей ветки `main`. Исправления по возможности включаются в ближайший релиз.

## Как сообщить об уязвимости

Не создавайте публичный Issue для уязвимости. Отправьте приватное сообщение владельцу проекта через [GitHub profile](https://github.com/localzet) или используйте [Private vulnerability reporting](https://github.com/localzet/UserNet/security/advisories/new), если эта функция доступна в репозитории.

В сообщении укажите затронутую версию/коммит, платформу, краткое влияние и безопасный способ воспроизведения. Не прикладывайте действующие токены, ссылки подписок, персональные данные или эксплойт, который затрагивает чужую инфраструктуру.

Мы подтвердим получение и согласуем дальнейшую координацию. Пожалуйста, дайте время подготовить исправление до публичного раскрытия. Если в отчёт случайно попал секрет, сразу отзовите/замените его и сообщите об этом отдельно.

## Публичные диагностики

Перед публикацией удалите из логов URL подписки, `Authorization`/cookie, IP и имена приватных серверов, идентификатор устройства, платёжные сведения и локальные пути. Не загружайте резервную копию приложения или профиля.

---

## English

Please do not open a public issue for a vulnerability. Contact the maintainer through the [GitHub profile](https://github.com/localzet) or use [GitHub private vulnerability reporting](https://github.com/localzet/UserNet/security/advisories/new) when enabled. Include the affected version/commit, platform, impact, and a safe reproduction. Never include active tokens, subscription URLs, personal data, or an exploit against third-party infrastructure. Allow time for coordinated remediation before public disclosure. Revoke exposed credentials immediately.

