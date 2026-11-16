# Project Stack Scanner

CLI на PowerShell для **инвентаризации технологий** в исходниках проекта (локальная папка или git URL). Подходит для фиксации стека в резюме, портфолио и учёте навыков.

Утилита **не собирает и не запускает** проект: ищет маркеры в конфигурации, извлекает версии, считает score и собирает capabilities.

## Требования

- Windows 10+
- PowerShell 5.1 или PowerShell 7+
- `git` в `PATH` (только для клонирования удалённых репозиториев)

## Установка / запуск

```powershell
.\project-stack.ps1 -Repository "C:\Projects\my-app" -OutputFormat all
Get-Help .\project-stack.ps1 -Full
```

> `Test-ProjectStack.ps1` — совместимый shim → `project-stack.ps1`.

## Быстрый старт

```powershell
# Полный отчёт
.\project-stack.ps1 -Repository "C:\Projects\my-app" -OutputFormat all

# Только high + resume
.\project-stack.ps1 -Repository "C:\Projects\my-app" -MinConfidence high -OutputFormat resume

# GitHub shorthand
.\project-stack.ps1 owner/repo -OutputFormat all
```

Отчёты: `./project-stack-YYYYMMDD-HHmmss/`.

## CLI-параметры

| Параметр | Описание |
|---|---|
| `-Repository` (`-Path`, `-Repo`) | Локальный путь, HTTPS/SSH URL или `owner/repo` |
| `-Recurse` | Рекурсивный поиск (по умолчанию `$true`; `-Recurse:$false`) |
| `-MinConfidence` | `low` / `medium` (default) / `high` |
| `-MinScore` | Отбросить находки со score ниже порога (0–100) |
| `-CollapseImplied` | Скрывать implied-технологии из resume stack (default `$true`) |
| `-MarkersPath` | Путь к `markers.json` (default `config/markers.json`) |
| `-OutputFormat` (`-Format`) | `markdown`, `csv`, `json`, `resume`, `all` |
| `-OutputDirectory` (`-o`) | Каталог отчётов |
| `-Subdirectories` | Ограничить сканирование подпапками |
| `-ExtraKeywords` | Дополнительные пакеты/ключевые слова |
| `-ExcludeDirectories` | Каталоги, пропускаемые при рекурсии |
| `-TargetDirectory` / `-ReuseExisting` | Клон remote |
| `-ShowHidden` | Включать скрытые файлы |

Коды выхода: `0` ok, `1` error, `2` nothing found.

## Возможности

- Версии из `requirements*.txt`, `package.json`, `pyproject.toml`, Docker `FROM`
- Рекурсивный поиск маркеров и точный package match
- Resume Summary / `resume.md`
- Каталог маркеров в `config/markers.json` (расширяется без правки кода)
- Score `0–100` и confidence на его основе
- Capabilities проекта (`RAG`, `Agents`, `API`, `Multi-service`, …)
- Иерархия `implies` / `uses` / `Relation` (например Next.js → React, Node.js)
- `-CollapseImplied` для компактного CV-стека
- Расширенный набор: .NET/Java/PHP/Ruby, Prisma/Drizzle/SQLAlchemy, Celery/Kafka, LangGraph, Hugging Face, LiteLLM, OpenTelemetry, npm/yarn/pnpm/Poetry

## Отчёты

| Файл | Когда | Содержимое |
|---|---|---|
| `technologies.csv` | всегда | таблица + score/relation |
| `README.md` | `markdown` / `all` | inventory + resume + capabilities |
| `resume.md` | `resume` / `all` | формулировки для CV |
| `technologies.json` | `json` / `resume` / `all` | JSON + Summary + Capabilities |

### Score / Confidence

| Score | Confidence |
|---|---|
| ≥ 75 | high |
| ≥ 45 | medium |
| < 45 | low |

Сигналы: file/directory marker, package match, pinned version, несколько evidence.

## Структура

```
.
├── project-stack.ps1
├── Test-ProjectStack.ps1
├── config/
│   └── markers.json
├── README.md
├── LICENSE
└── .gitignore
```

## Ограничения

- Инвентаризация маркеров, не proof of expertise и не runtime-проверка
- Версии — из файлов, не из `python --version` / `node --version`
- Приватные репозитории требуют заранее настроенный git auth

## Лицензия

MIT — см. [LICENSE](LICENSE).
