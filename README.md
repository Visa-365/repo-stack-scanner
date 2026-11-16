# Project Stack Scanner (`Test-ProjectStack.ps1`)

PowerShell-утилита для **инвентаризации технологий** в исходниках проекта: локальная папка или удалённый Git-репозиторий. Подходит для фиксации стека в резюме, портфолио и учёте навыков.

Скрипт **не компилирует и не запускает** проект. Он ищет маркеры в конфигурационных файлах и извлекает указанные в них версии.

## Требования

- Windows 10+
- PowerShell 5.1 или PowerShell 7+
- `git` в `PATH` (нужен только для клонирования удалённых репозиториев)

## Быстрый старт

```powershell
# Локальная папка
.\Test-ProjectStack.ps1 -Repository "C:\Projects\my-app"

# Полный URL
.\Test-ProjectStack.ps1 -Repository "https://github.com/owner/repo.git"

# Короткая ссылка GitHub (owner/repo)
.\Test-ProjectStack.ps1 -Repository "owner/repo"

# SSH (нужен настроенный ключ)
.\Test-ProjectStack.ps1 -Repository "git@github.com:owner/repo.git"
```

По умолчанию отчёт сохраняется в каталог `project-stack-YYYYMMDD-HHmmss` в текущей папке.

## Параметры

| Параметр | Описание |
|---|---|
| `-Repository` | Обязательный. Локальный путь, HTTPS/SSH URL или `owner/repo` |
| `-TargetDirectory` | Куда клонировать remote-репозиторий (иначе — временная папка) |
| `-ReuseExisting` | Не клонировать заново, если целевая папка уже есть |
| `-Subdirectories` | Сканировать только указанные подпапки (удобно для монорепо) |
| `-ExtraKeywords` | Дополнительные ключевые слова для поиска в маркерах |
| `-OutputFormat` | `markdown` (по умолчанию), `csv`, `json` или `all` |
| `-OutputDirectory` | Каталог отчётов |

## Примеры

Монорепозиторий и все форматы отчёта:

```powershell
.\Test-ProjectStack.ps1 `
  -Repository "https://github.com/owner/monorepo.git" `
  -Subdirectories "apps/web", "apps/api" `
  -OutputFormat all
```

Свои маркеры (внутренний стек):

```powershell
.\Test-ProjectStack.ps1 `
  -Repository "C:\Projects\my-app" `
  -ExtraKeywords "mymonitoring", "internal-analytics"
```

## Что ищет скрипт

Обнаружение идёт по файлам и ключевым словам в маркерах (`package.json`, `pyproject.toml`, `go.mod`, `requirements.txt`, Docker/CI-манифесты и т.д.).

Категории включают, среди прочего:

- **Runtime:** Node.js, Python, Go, Rust
- **Frontend:** React, Vue, Angular, Svelte, Next.js, TypeScript, Tailwind CSS
- **Web frameworks:** FastAPI, Django, Flask, Express, NestJS
- **Databases:** PostgreSQL, MySQL, MongoDB, Redis
- **Containerization / IaC:** Docker, Kubernetes, Terraform, AWS CDK
- **CI/CD:** GitHub Actions, GitLab CI, Jenkins
- **AI / RAG / Tooling:** LangChain, LlamaIndex, ChromaDB, Pinecone, Qdrant, Weaviate, pgvector, MCP, OpenAI, Anthropic
- **Testing / quality:** Pytest, Jest, Vitest, Playwright, Cypress, ESLint, Prettier

Список маркеров задаётся в функции `Find-TechnologyMarkers` и легко расширяется без смены основной логики.

## Версии

Версии берутся из конфигурации, а не из «фактического» окружения машины:

- `package.json` → Node.js
- `pyproject.toml` / `.python-version` → Python
- `go.mod` → Go
- `Cargo.toml` → Rust
- `Dockerfile` `FROM image:tag` → Docker-образы

Приоритет: точнее — конфиг проекта, иначе — Dockerfile и аналогичные источники.

## Отчёты

В каталоге вывода:

| Файл | Содержимое |
|---|---|
| `technologies.csv` | Таблица находок (создаётся всегда) |
| `README.md` | Markdown-отчёт (при `markdown` / `all`) |
| `technologies.json` | JSON для резюме / портфолио (при `json` / `all`) |

Пример колонок: Technology, Category, Version, Version Source, Confidence, Evidence.

### Как читать Confidence

- **high** — технология явно объявлена в конфигурации; обычно можно уверенно вносить в резюме.
- **medium** — приблизительный маркер; лучше перепроверить вручную.

Рекомендация: опираться на `high`, а `medium` использовать как подсказку.

## Приватные репозитории

Скрипт сам не настраивает аутентификацию. Перед клонированием настройте один из вариантов:

- переменная окружения / credential helper (`GIT_TOKEN`, `~/.git-credentials`);
- Windows Credential Manager;
- SSH-ключ для `git@...` URL.

## Ограничения

- Это структурный поиск маркеров, а не статический анализ кода и не проверка работоспособности.
- Версии в отчёте — значения из файлов, а не результат `node --version` / `python --version`.
- Проект не запускается; Docker, БД и AI-интеграции не тестируются.

## Структура репозитория

```
.
├── Test-ProjectStack.ps1   # основная утилита
├── README.md
└── .gitignore
```

## Лицензия

MIT — см. [LICENSE](LICENSE).
