#include <os/log.h>
#include <stdint.h>

void rota_os_log_emit(const char *subsystem, const char *category, uint8_t kind, const char *message) {
    if (!subsystem || !category || !message) {
        return;
    }
    os_log_t log = os_log_create(subsystem, category);
    os_log_type_t log_type = OS_LOG_TYPE_INFO;
    switch (kind) {
        case 1: log_type = OS_LOG_TYPE_DEFAULT; break;
        case 2: log_type = OS_LOG_TYPE_ERROR; break;
        default: log_type = OS_LOG_TYPE_INFO; break;
    }
    os_log_with_type(log, log_type, "%{public}s", message);
}
