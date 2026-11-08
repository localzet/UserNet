# Участие в UserNet / Contributing

Спасибо за интерес к проекту. Здесь принимаются исправления, тесты, документация и предложения, которые подходят разным ОС и не раскрывают пользовательские или серверные данные.

## Перед началом

1. Проверьте [открытые Issues](https://github.com/localzet/UserNet/issues) и pull requests, чтобы не дублировать работу.
2. Для бага используйте форму **Bug report**, для новой возможности — **Feature request**. Сначала согласуйте крупное изменение поведения или API в Issue.
3. Не отправляйте реальные ссылки подписок, токены, клиентские профили, логи с IP/ID устройства, платёжные данные или ключи. Для уязвимостей используйте приватный порядок из [SECURITY.md](SECURITY.md).

## Разработка

- Создайте ветку от актуального `main`: `feat/<short-name>` или `fix/<short-name>`.
- Держите pull request узким; отдельно опишите влияние на Android, Windows, macOS и Linux.
- Следуйте существующей структуре Flutter/Dart, Go и Kotlin. Не добавляйте новую зависимость без необходимости.
- Комментарии в коде — короткие и на английском; пользовательские строки добавляйте через локализацию.
- Не включайте артефакты сборки, личные конфиги, `env.json`, ключи подписи и файлы профилей.

## Проверки

Для Flutter-кода:

```bash
flutter pub get
dart format --output=none --set-exit-if-changed lib test tool plugins setup.dart
flutter analyze --no-fatal-infos
flutter test
```

Для веб-страницы загрузок и Go-ядра:

```bash
node --test website/usernet/app.test.cjs
cd core && go test ./...
```

Добавьте регрессионный тест к исправлению поведения. В pull request перечислите реальные результаты проверок; если сборку или платформу проверить не удалось, укажите это прямо. Для изменений интерфейса приложите скриншоты с тестовыми данными. Не прикладывайте экраны с личной подпиской.

## Pull request

1. Обновите документацию и `CHANGELOG.md`, если меняется пользовательское поведение.
2. Убедитесь, что diff не содержит секретов, реальных адресов узлов, локальных путей или сгенерированных файлов без необходимости.
3. Заполните шаблон pull request: мотивация, решение, платформы, тесты и риски.
4. Оставьте PR в режиме draft, если контракт или UX ещё требуют обсуждения. Не объединяйте собственный PR без ревью.

## Лицензия и авторство

Внося код, вы соглашаетесь, что он будет распространяться по лицензии репозитория, GNU GPL v3.0. Сохраняйте существующие уведомления об авторстве и лицензиях сторонних компонентов; не копируйте код или медиа с несовместимыми условиями.

---

## English summary

Open a focused issue before large changes. Branch from `main` using `feat/…` or `fix/…`, add regression tests, run the relevant checks above, and report actual results in your PR. Never include real subscription URLs, tokens, customer profiles, private node addresses, payment data, signing keys, or unredacted logs. Preserve existing copyright and third-party license notices. Contributions are distributed under GPL-3.0.
