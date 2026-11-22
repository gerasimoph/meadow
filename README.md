# Meadow

Простой, лёгкий и быстрый нативный Markdown-редактор заметок для macOS.

- Заметки — обычные `.md` файлы в папке; боковая панель показывает папку как есть.
- Живой предпросмотр: разметка (`#`, `**`, `[]()`, `|`) скрыта и появляется только в блоке под курсором.
- Задачи `- [ ]` рисуются кружками и переключаются кликом; таблицы выравниваются по колонкам; подсветка кода.
- Автосохранение, подхват изменений файлов извне, Quick Look для `.md` в Finder.
- Swift + AppKit (TextKit 1), без WebView; парсер — `cmark-gfm`.

## Сборка и установка

Нужны Xcode и [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
./scripts/install.sh        # Release-сборка в /Applications/Meadow.app
```

Разработка:

```sh
xcodegen generate && open Meadow.xcodeproj
cd Packages/MeadowKit && swift test
```

Чтобы открывать `.md` двойным кликом: Finder → «Свойства» файла → «Открывать в программе» → Meadow → «Изменить всё».

## Устройство

- `Packages/MeadowKit` — движок редактора:
  - `MarkdownAnalysis.swift` — разбор через `cmark-gfm` в строки, спаны и листовые блоки (UTF-16 смещения, обход известных ошибок позиций cmark);
  - `MarkdownStyler.swift` — атрибуты текста по разбору; инкрементально, только изменённые блоки;
  - `MarkdownLayoutManager.swift` — скрытие маркеров через глифы, кружки задач, выравнивание таблиц, фоны кода, цитаты;
  - `MarkdownTextView.swift` (+`Editing`) — редактор: проявление разметки под курсором, клики по задачам, списки по Enter/Tab.
- `App/` — окно, боковая панель, автосохранение, FSEvents, настройки.
- `QuickLook/` — расширение предпросмотра.

## Лицензия

MIT, см. [LICENSE](LICENSE).
