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

> `ProjectStack.ps1` — совместимый shim → `project-stack.ps1`.

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

### Как считается Score

Score — сумма сигналов по находке (макс. 100), затем при необходимости поднимается до floor из каталога. По итоговому score выставляется `confidence`.

#### Базовые баллы

| Сигнал | Баллы | Когда |
|---|---|---|
| File / directory marker | +50 | найден конфиг или папка (`Dockerfile`, `tsconfig.json`, `.github/workflows/` …) |
| Package match | +35 | пакет найден в зависимостях (`requirements.txt`, `package.json`, …) |
| Version | +15 | удалось извлечь версию |
| Несколько evidence | +10 | в Evidence ≥ 2 частей (через `;`) |

#### Floor из `markers.json`

Исходный `confidence` маркера в каталоге задаёт минимум, если технология реально обнаружена (есть file / directory / package):

| Catalog confidence | Floor |
|---|---|
| high | 75 |
| medium | 50 |
| low / иное | 25 |

Если сырой score ниже floor — он поднимается до floor. Так явный маркер (например Docker) не уезжает в `medium` только из‑за отсутствия версии.

#### Score → Confidence

| Score | Confidence |
|---|---|
| ≥ 75 | high |
| ≥ 45 | medium |
| < 45 | low |

#### Примеры

- **FastAPI** в `requirements.txt` + версия `0.135.0` → package 35 + version 15 = 50, catalog `high` → floor **75** → **high**
- **Docker** по compose/Dockerfile + version из `FROM` → file 50 + version 15 + multi-evidence 10 = **75** → **high**
- **Express** только как package + version → 35 + 15 = 50, catalog `medium` → floor **50** → **medium**

Фильтры `-MinConfidence` и `-MinScore` отсекают находки уже после этого расчёта.

## Структура

```
.
├── project-stack.ps1
├── ProjectStack.ps1
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
