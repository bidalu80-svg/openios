#ifndef LocalAlpineNativeRuntimeABI_h
#define LocalAlpineNativeRuntimeABI_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t iexa_local_alpine_runtime_available(void);

int32_t iexa_local_alpine_interrupt(void);

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
