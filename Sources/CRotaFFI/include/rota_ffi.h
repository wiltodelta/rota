#ifndef ROTA_FFI_H
#define ROTA_FFI_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RotaSchedulerHandle RotaSchedulerHandle;
typedef struct RotaControlServerHandle RotaControlServerHandle;
typedef struct RotaReaderHandle RotaReaderHandle;
typedef struct RotaJournalHandle RotaJournalHandle;

typedef enum RotaSchedulerEventKind {
    ROTA_EVENT_REVISION_CHANGED = 1,
    ROTA_EVENT_RUN_ENDED = 2,
    ROTA_EVENT_ROUTINE_PAUSED = 3,
    ROTA_EVENT_ROUTINE_ADDED = 4,
    ROTA_EVENT_SESSION_NOTIFIED = 5
} RotaSchedulerEventKind;

typedef void (*RotaEventCallback)(uintptr_t ctx, uint32_t kind, const char *payload_json);

typedef void (*RotaControlReplyFn)(uintptr_t reply_ctx, const char *response_json);
typedef void (*RotaControlRequestCallback)(
    uintptr_t ctx,
    const char *method,
    const char *params_json,
    uintptr_t reply_ctx,
    RotaControlReplyFn reply_fn
);

void rota_string_free(char *ptr);

char *rota_core_call(const char *method, const char *params_json);

RotaSchedulerHandle *rota_scheduler_create(
    const char *root_dir,
    const char *logs_dir,
    bool use_real_launcher,
    uintptr_t callback_ctx,
    RotaEventCallback callback,
    char **out_error
);

char *rota_scheduler_snapshot(const RotaSchedulerHandle *handle);

char *rota_scheduler_call(
    const RotaSchedulerHandle *handle,
    const char *method,
    const char *params_json
);

void rota_scheduler_free(RotaSchedulerHandle *handle);

RotaControlServerHandle *rota_control_server_start(
    const char *socket_path,
    uintptr_t ctx,
    RotaControlRequestCallback callback,
    char **out_error
);

void rota_control_server_free(RotaControlServerHandle *handle);

RotaReaderHandle *rota_reader_create(int64_t page_size, bool settle_writes);
char *rota_reader_read(
    RotaReaderHandle *handle,
    const char *log_path,
    bool shell,
    bool finished,
    bool earlier
);
char *rota_reader_preview(RotaReaderHandle *handle, const char *record_json);
void rota_reader_free(RotaReaderHandle *handle);

RotaJournalHandle *rota_journal_create(const char *log_path, bool resuming);
void rota_journal_record(const RotaJournalHandle *handle, const char *kind, const char *text);
void rota_journal_finish(const RotaJournalHandle *handle, const char *outcome_json);
void rota_journal_free(RotaJournalHandle *handle);

#ifdef __cplusplus
}
#endif

#endif
