#include "LocalAlpineNativeRuntimeABI.h"

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

static char *iexa_dup_output(const char *message) {
    if (message == NULL) {
        message = "";
    }
    size_t length = strlen(message);
    char *buffer = malloc(length + 1);
    if (buffer == NULL) {
        return NULL;
    }
    memcpy(buffer, message, length + 1);
    return buffer;
}

#if IEXA_LOCAL_ALPINE_ISH

#include <pthread.h>
#include <sqlite3.h>
#include <stdio.h>
#include <unistd.h>

#include "kernel/init.h"
#include "kernel/calls.h"
#include "kernel/fs.h"
#include "kernel/task.h"
#include "misc.h"
#include "fs/devices.h"
#include "fs/fd.h"
#include "fs/fake.h"
#include "fs/real.h"
#include "fs/tty.h"
#include "tools/fakefs.h"

static pthread_mutex_t runtime_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t capture_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t capture_done = PTHREAD_COND_INITIALIZER;
static bool runtime_booted = false;
static char *capture_buffer = NULL;
static size_t capture_length = 0;
static size_t capture_capacity = 0;
static bool capture_finished = false;
static int capture_exit_code = 126;
static int capture_pid = 0;

static void capture_reset(void) {
    free(capture_buffer);
    capture_buffer = NULL;
    capture_length = 0;
    capture_capacity = 0;
    capture_finished = false;
    capture_exit_code = 126;
    capture_pid = 0;
}

static void capture_append(const void *bytes, size_t length) {
    if (length == 0) {
        return;
    }
    pthread_mutex_lock(&capture_lock);
    if (capture_length + length + 1 > capture_capacity) {
        size_t next_capacity = capture_capacity == 0 ? 4096 : capture_capacity;
        while (next_capacity < capture_length + length + 1) {
            next_capacity *= 2;
        }
        char *next = realloc(capture_buffer, next_capacity);
        if (next == NULL) {
            pthread_mutex_unlock(&capture_lock);
            return;
        }
        capture_buffer = next;
        capture_capacity = next_capacity;
    }
    memcpy(capture_buffer + capture_length, bytes, length);
    capture_length += length;
    capture_buffer[capture_length] = '\0';
    pthread_mutex_unlock(&capture_lock);
}

static int headless_tty_init(struct tty *tty) {
    tty->winsize.col = 120;
    tty->winsize.row = 40;
    return 0;
}

static int headless_tty_write(struct tty *tty, const void *buf, size_t len, bool blocking) {
    (void) tty;
    (void) blocking;
    capture_append(buf, len);
    return (int) len;
}

static void headless_tty_cleanup(struct tty *tty) {
    (void) tty;
}

static struct tty_driver_ops headless_tty_ops = {
    .init = headless_tty_init,
    .write = headless_tty_write,
    .cleanup = headless_tty_cleanup,
};

DEFINE_TTY_DRIVER(iexa_headless_tty_driver, &headless_tty_ops, TTY_CONSOLE_MAJOR, 1);

static void capture_exit_hook(struct task *task, int code) {
    if (task->pid != capture_pid) {
        return;
    }
    pthread_mutex_lock(&capture_lock);
    capture_exit_code = code >> 8;
    capture_finished = true;
    pthread_cond_signal(&capture_done);
    pthread_mutex_unlock(&capture_lock);
}

static bool import_root_if_needed(const char *root_archive_path, const char *workspace_path, char **error_out) {
    char root_path[4096];
    snprintf(root_path, sizeof(root_path), "%s/rootfs", workspace_path);
    if (access(root_path, F_OK) == 0) {
        return true;
    }

    struct fakefsify_error fs_error;
    memset(&fs_error, 0, sizeof(fs_error));
    if (!fakefs_import(root_archive_path, root_path, &fs_error, (struct progress) {0})) {
        char message[1024];
        snprintf(
            message,
            sizeof(message),
            "fakefs_import failed at line %d: %s",
            fs_error.line,
            fs_error.message != NULL ? fs_error.message : "unknown error"
        );
        free(fs_error.message);
        *error_out = iexa_dup_output(message);
        return false;
    }
    return true;
}

static int boot_runtime(const char *root_archive_path, const char *workspace_path, char **error_out) {
    if (runtime_booted) {
        return 0;
    }

    if (!import_root_if_needed(root_archive_path, workspace_path, error_out)) {
        return -1;
    }

    char root_data_path[4096];
    snprintf(root_data_path, sizeof(root_data_path), "%s/rootfs/data", workspace_path);

    int err = mount_root(&fakefs, root_data_path);
    if (err < 0) {
        *error_out = iexa_dup_output("mount_root failed");
        return err;
    }

    err = become_first_process();
    if (err < 0) {
        *error_out = iexa_dup_output("become_first_process failed");
        return err;
    }

    create_some_device_nodes();
    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);
    tty_drivers[TTY_CONSOLE_MAJOR] = &iexa_headless_tty_driver;

    runtime_booted = true;
    return 0;
}

bool iexa_local_alpine_runtime_available(void) {
    return true;
}

char *iexa_local_alpine_execute(
    const char *command,
    const char *cwd,
    const char *root_archive_path,
    const char *workspace_path,
    int32_t *exit_code
) {
    pthread_mutex_lock(&runtime_lock);

    char *error = NULL;
    int err = boot_runtime(root_archive_path, workspace_path, &error);
    if (err < 0) {
        if (exit_code != NULL) {
            *exit_code = 127;
        }
        pthread_mutex_unlock(&runtime_lock);
        return error != NULL ? error : iexa_dup_output("Local Alpine boot failed");
    }

    err = become_new_init_child();
    if (err < 0) {
        if (exit_code != NULL) {
            *exit_code = 127;
        }
        pthread_mutex_unlock(&runtime_lock);
        return iexa_dup_output("become_new_init_child failed");
    }

    if (cwd != NULL && cwd[0] != '\0') {
        struct fd *pwd = generic_open(cwd, O_RDONLY_, 0);
        if (!IS_ERR(pwd)) {
            fs_chdir(current->fs, pwd);
        }
    }

    capture_reset();
    exit_hook = capture_exit_hook;
    err = create_stdio("/dev/tty1", TTY_CONSOLE_MAJOR, 1);
    if (err < 0) {
        if (exit_code != NULL) {
            *exit_code = 127;
        }
        pthread_mutex_unlock(&runtime_lock);
        return iexa_dup_output("create_stdio failed");
    }

    const char *shell = "/bin/sh";
    char argv[8192];
    snprintf(argv, sizeof(argv), "%s%c-lc%c%s%c", shell, '\0', '\0', command != NULL ? command : "", '\0');
    const char *envp = "TERM=xterm-256color\0PATH=/bin:/sbin:/usr/bin:/usr/sbin\0";

    err = do_execve(shell, 3, argv, envp);
    if (err < 0) {
        if (exit_code != NULL) {
            *exit_code = 127;
        }
        pthread_mutex_unlock(&runtime_lock);
        return iexa_dup_output("do_execve failed");
    }

    capture_pid = current->pid;
    task_start(current);

    pthread_mutex_lock(&capture_lock);
    while (!capture_finished) {
        pthread_cond_wait(&capture_done, &capture_lock);
    }
    char *output = iexa_dup_output(capture_buffer != NULL ? capture_buffer : "");
    int completed_exit_code = capture_exit_code;
    pthread_mutex_unlock(&capture_lock);

    if (exit_code != NULL) {
        *exit_code = completed_exit_code;
    }
    pthread_mutex_unlock(&runtime_lock);
    return output != NULL ? output : iexa_dup_output("");
}

#else

bool iexa_local_alpine_runtime_available(void) {
    return false;
}

char *iexa_local_alpine_execute(
    const char *command,
    const char *cwd,
    const char *root_archive_path,
    const char *workspace_path,
    int32_t *exit_code
) {
    (void) command;
    (void) cwd;
    (void) root_archive_path;
    (void) workspace_path;
    if (exit_code != NULL) {
        *exit_code = 126;
    }
    return iexa_dup_output("Local Alpine native runtime was not compiled with IEXA_LOCAL_ALPINE_ISH=1.");
}

#endif

void iexa_local_alpine_free(char *buffer) {
    free(buffer);
}
