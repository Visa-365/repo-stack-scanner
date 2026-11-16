# Project Stack Scanner

CLI на PowerShell для **инвентаризации технологий** в исходниках проекта (локальная папка или git URL). Подходит для фиксации стека в резюме, портфолио и учёте навыков.

Утилита **не собирает и не запускает** проект: ищет маркеры в конфигурации и извлекает объявленные версии.

## Требования

- Windows 10+
- PowerShell 5.1 или PowerShell 7+
- `git` в `PATH` (только для клонирования удалённых репозиториев)

## Установка / запуск

Клонируйте репозиторий и вызывайте CLI из корня:

```powershell
.\project-stack.ps1 -Repository "C:\Projects\my-app" -Recurse -OutputFormat all
```

Справка:

```powershell
Get-Help .\project-stack.ps1 -Full
```

> `Test-ProjectStack.ps1` — совместимый shim, который просто вызывает `project-stack.ps1`.

## Быстрый старт

```powershell
# Локальная папка + рекурсивный поиск Dockerfile/requirements
.\project-stack.ps1 -Repository "C:\Projects\my-app" -Recurse

# Только high-confidence + resume-отчёт
.\project-stack.ps1 -Repository "C:\Projects\my-app" -Recurse -MinConfidence high -OutputFormat resume

# GitHub shorthand
.\project-stack.ps1 owner/repo -Recurse -OutputFormat all

# SSH
.\project-stack.ps1 -Repository "git@github.com:owner/repo.git" -Recurse
```

Отчёты по умолчанию: `./project-stack-YYYYMMDD-HHmmss/`.

## CLI-параметры

| Параметр | Описание |
|---|---|
| `-Repository` (`-Path`, `-Repo`) | Локальный путь, HTTPS/SSH URL или `owner/repo` |
| `-Recurse` | Рекурсивный поиск маркеров (по умолчанию `$true`; отключить: `-Recurse:`$false`) |
| `-MinConfidence` | `medium` (по умолчанию) или `high` |
| `-OutputFormat` (`-Format`) | `markdown`, `csv`, `json`, `resume`, `all` |
| `-OutputDirectory` (`-o`) | Каталог отчётов |
| `-Subdirectories` | Ограничить сканирование подпапками (монорепо) |
| `-ExtraKeywords` | Дополнительные пакеты/ключевые слова |
| `-ExcludeDirectories` | Имена каталогов, пропускаемые при `-Recurse` |
| `-TargetDirectory` | Куда клонировать remote |
| `-ReuseExisting` | Не клонировать повторно, если папка уже есть |
| `-ShowHidden` | Включать скрытые файлы при рекурсии |

Коды выхода: `0` — успех, `1` — ошибка, `2` — ничего не найдено.

## Примеры

Монорепозиторий:

```powershell
.\project-stack.ps1 `
  -Repository "https://github.com/owner/monorepo.git" `
  -Subdirectories "apps/web", "apps/api" `
  -Recurse `
  -OutputFormat all
```

Только уверенные технологии для CV:

```powershell
.\project-stack.ps1 -Repository "C:\Projects\my-app" -Recurse `
  -MinConfidence high -OutputFormat resume
```

## Что делает P0-улучшения

- Версии из `requirements*.txt`, `package.json` (deps/engines), `pyproject.toml`
- Рекурсивный поиск `Dockerfile` / compose / dependency-файлов (`-Recurse`)
- Более точный match пакетов (не грубый substring)
- Resume Summary в Markdown + отдельный `resume.md`
- Фильтр `-MinConfidence`

## Отчёты

| Файл | Когда | Содержимое |
|---|---|---|
| `technologies.csv` | всегда | таблица находок |
| `README.md` | `markdown` / `all` | inventory + resume summary |
| `resume.md` | `resume` / `all` | готовые формулировки для CV |
| `technologies.json` | `json` / `resume` / `all` | JSON + Summary |

### Confidence

- **high** — явный маркер/пакет; обычно можно в резюме
- **medium** — эвристика; лучше перепроверить

## Ограничения

- Это инвентаризация маркеров, не proof of expertise и не runtime-проверка
- Версии — из файлов, не из `python --version` / `node --version`
- Приватные репозитории требуют заранее настроенный git auth

## Структура

```
.
├── project-stack.ps1       # CLI entrypoint
├── Test-ProjectStack.ps1   # compatibility shim
├── README.md
├── LICENSE
└── .gitignore
```

## Лицензия

MIT — см. [LICENSE](LICENSE).
