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
