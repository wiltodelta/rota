## 2026-11-22T19:10:00Z - авторизованное чтение GitHub API в harness_review.py

id: github-releases-auth-resolved
cue: `harness_review.py collect` запрашивает `codex-release` (`api.github.com/repos/openai/codex/releases/latest`).
lesson: Не требуется ручной обход через `gh api` при штатном сборе: `scripts/harness_review.py` сам передаёт токен GitHub и получает ответ 200; возвращаться к ручной проверке только если авторизованный запрос вернёт ошибку.
evidence: При сборе `2026-11-22T19:07Z` запрос `GET https://api.github.com/repos/openai/codex/releases/latest` прошёл с `authenticated=True` и `status=200`, а тест `test_github_api_source_is_read_with_the_token_and_never_logs_it` в `scripts/tests/test_harness_review.py` подтверждён.
confidence: high, подтверждено тестом и успешным живым сбором.
supersedes: github-releases-unauth-403

## 2026-11-15T19:18:00Z - лимит GitHub API у codex-release

id: github-releases-unauth-403
cue: `harness_review.py collect` помечает `codex-release` (`api.github.com/repos/openai/codex/releases/latest`) как `unavailable` с `HTTPError` 403.
lesson: Оставить `codex-release` вне `accept --reviewed`, чтобы `progress.json` сохранил честный статус `unavailable` и счётчик `failures`, но прочитать `gh api repos/openai/codex/releases/latest` в режиме чтения для проверки протокольных изменений текущего выпуска в самом обзоре.
evidence: При сборе `2026-11-15T19:08Z` неавторизованный `urlopen` получил HTTP 403 rate limit от `api.github.com`, тогда как `gh api repos/openai/codex/releases/latest` вернул карточку актуального выпуска `rust-v0.169.0`.
confidence: low, первое наблюдение лимита на этом источнике.
needs: code scripts/harness_review.py - использовать авторизованный GitHub-клиент или токен окружения при чтении `api.github.com/repos/*/releases/latest`.

## 2026-11-01, America/Los_Angeles - область поиска ACP

cue: Запрос Context7 явно называет ACP v1, но результаты ссылаются на `/protocol/v2/` и `/rfds/`.
lesson: Проверять версию в URL каждого результата и читать опубликованный v1 напрямую до оценки изменения адаптера. Указание v1 в запросе не ограничивает выдачу этой версией.
evidence: Запрос о resource links и permission cancellation вернул v2 schema/content и RFD subagents; соответствующий v1 прочитан по https://agentclientprotocol.com/protocol/v1/tool-calls и https://agentclientprotocol.com/protocol/v1/content.
confidence: low, одно наблюдение для явно версионного запроса; предыдущий обзор отдельно отмечал смешивание с RFD.

## 2026-10-31T01:10:00Z - первый обзор

cue: Context7 возвращает совпадения ACP из `docs/rfds/` рядом с действующим протоколом.
lesson: Сверять вывод с опубликованным ACP v1, а RFD считать проектом, пока нативный контракт используемого агента не подтвердит соответствующую возможность.
evidence: Запрос о tool content и permission cancellation вернул RFD subagents/request-cancellation/mcp-over-acp; опубликованные контракты находятся на https://agentclientprotocol.com/protocol/v1/tool-calls и https://agentclientprotocol.com/protocol/v1/content.
confidence: low, одно наблюдение выдачи Context7; различие расположений документов проверено непосредственно.
