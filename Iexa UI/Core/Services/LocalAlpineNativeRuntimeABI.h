#ifndef LocalAlpineNativeRuntimeABI_h
#define LocalAlpineNativeRuntimeABI_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t iexa_local_alpine_runtime_available(void);

int32_t iexa_local_alpine_interrupt(void);

int32_t iexa_local_alpine_session_start(
    const char *cwd,
    const char *root_archive_path,
    const char *workspace_path,
    const char *time_zone
);

int32_t iexa_local_alpine_session_write(
    int32_t session_id,
    const char *input
);

char *iexa_local_alpine_session_read(
    int32_t session_id
);

int32_t iexa_local_alpine_session_resize(
    int32_t session_id,
    int32_t columns,
    int32_t rows
);

int32_t iexa_local_alpine_session_interrupt(
    int32_t session_id
);

int32_t iexa_local_alpine_session_close(
    int32_t session_id
);

char *iexa_local_alpine_execute(
    const char *command,
    const char *cwd,
    const char *root_archive_path,
    const char *workspace_path,
    const char *time_zone,
    int32_t *exit_code
);

void iexa_local_alpine_free(char *buffer);

#ifdef __cplusplus
}
#endif

#endif
