# API (127.0.0.1:8787, bearer token on all but /health)

```
GET  /health                        {ok, version, db_ok, sse_subscribers}
GET  /tasks?status_filter=&limit=   POST /tasks {title|raw, due_at, priority, recurrence, tags}
PATCH /tasks/{id}                   POST /tasks/{id}/complete|snooze|drop|ack|reopen
GET  /due                           tasks firing now, each with nag_line + level
GET  /stats                         streaks, points, level, achievements, points_by_day
GET  /events                        SSE: task.created, task.changed, habit.changed
GET  /habits[?presence…]            POST /habits {name|raw|daily…}  PATCH /habits/{id}
POST /habits/{id}/done|fired        POST /habits/seed
POST /nag-lines {level, lines[]}    GET /nag-lines/depth
POST /parse {raw}                   GET /m (mobile page)
```

Errors are always `{"error":{"code","message"}}`. Datetimes are ISO-8601 with
an explicit offset; naive datetimes are rejected with 400. `raw` accepts
natural language everywhere: times ("friday 6pm"), tags (#home), priority
words ("urgent"), recurrence ("every month 5th"), and the `habit:` prefix.
