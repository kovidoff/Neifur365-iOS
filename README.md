# Neifur 365 (iOS)

Неофициальный iOS-клиент для **Anime 365** и **Shikimori** на **Swift + SwiftUI**.
Порт Android-приложения [Neifur 365](https://github.com/kovidoff/Neifur365) — без рекламы, трекеров и собственного сервера.

## Сборка

Проект описывается через `project.yml` ([XcodeGen](https://github.com/yonaskolb/XcodeGen)) и автоматически собирается в **GitHub Actions** на `macos-latest`:
- прогоняются юнит-тесты (`Neifur365Tests`) на iOS Simulator;
- собирается неподписанный `Neifur365.ipa` (готов к подписи в Gbox / Feather / ESign / SideStore / Sideloadly) и загружается в артефакты запуска Actions.

## Лицензия

Исходный код распространяется по лицензии **[GNU General Public License v3.0](LICENSE)**.
