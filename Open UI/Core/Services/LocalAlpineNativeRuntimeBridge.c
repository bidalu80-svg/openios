#include "LocalAlpineNativeRuntimeABI.h"

#include <stdbool.h>
#include <errno.h>
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
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#ifndef ISH_INTERNAL
#define ISH_INTERNAL 1
#endif

#include "kernel/init.h"
#include "kernel/calls.h"
#include "kernel/fs.h"
#include "kernel/task.h"
#include "misc.h"
#include "fs/path.h"
#include "fs/devices.h"
#include "fs/fd.h"
#include "fs/fake.h"
#include "fs/real.h"
#include "fs/tty.h"

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

static int ensure_directory(const char *path) {
    if (mkdir(path, 0777) == 0) {
        return 0;
    }
    if (errno == EEXIST) {
        return 0;
    }
    return -1;
}

static bool ends_with(const char *value, const char *suffix) {
    if (value == NULL || suffix == NULL) {
        return false;
    }
    size_t value_length = strlen(value);
    size_t suffix_length = strlen(suffix);
    if (suffix_length > value_length) {
        return false;
    }
    return strcmp(value + value_length - suffix_length, suffix) == 0;
}

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

static void capture_append_locked(const void *bytes, size_t length) {
    if (length == 0) {
        return;
    }
    if (capture_length + length + 1 > capture_capacity) {
        size_t next_capacity = capture_capacity == 0 ? 4096 : capture_capacity;
        while (next_capacity < capture_length + length + 1) {
            next_capacity *= 2;
        }
        char *next = realloc(capture_buffer, next_capacity);
        if (next == NULL) {
            return;
        }
        capture_buffer = next;
        capture_capacity = next_capacity;
    }
    memcpy(capture_buffer + capture_length, bytes, length);
    capture_length += length;
    capture_buffer[capture_length] = '\0';
}

static int headless_tty_init(struct tty *tty) {
    tty->winsize.col = 120;
    tty->winsize.row = 40;
    tty->termios.lflags &= ~(ICANON_ | ECHO_ | ECHOE_ | ECHOK_ | ECHOCTL_ | ECHOKE_);
    tty->termios.cc[VMIN_] = 1;
    tty->termios.cc[VTIME_] = 0;
    return 0;
}

static int headless_tty_open(struct tty *tty) {
    (void) tty;
    return 0;
}

static int headless_tty_close(struct tty *tty) {
    (void) tty;
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
    .open = headless_tty_open,
    .close = headless_tty_close,
    .write = headless_tty_write,
    .cleanup = headless_tty_cleanup,
};

DEFINE_TTY_DRIVER(iexa_headless_tty_driver, &headless_tty_ops, TTY_CONSOLE_MAJOR, 64);

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

static bool resolve_root_data_path(const char *root_archive_path, char *root_data_path, size_t root_data_path_size, char **error_out) {
    if (root_archive_path == NULL || root_archive_path[0] == '\0') {
        *error_out = iexa_dup_output("Local Alpine root archive path is empty");
        return false;
    }

    if (ends_with(root_archive_path, ".fakefs")) {
        char data_path[4096];
        snprintf(data_path, sizeof(data_path), "%s/data", root_archive_path);
        if (access(data_path, F_OK) != 0) {
            *error_out = iexa_dup_output("Bundled Local Alpine fakefs is missing its data directory");
            return false;
        }
        snprintf(root_data_path, root_data_path_size, "%s", data_path);
        return true;
    }

    if (ends_with(root_archive_path, ".fakefs.tar.gz")) {
        *error_out = iexa_dup_output("Local Alpine native runtime requires a bundled .fakefs directory, not a compressed fakefs archive.");
        return false;
    }

    *error_out = iexa_dup_output("Local Alpine fakefs is missing. The CI build must convert iexa-alpine-rootfs.tar.gz into iexa-alpine-rootfs.fakefs.");
    return false;
}

static int boot_runtime(const char *root_archive_path, const char *workspace_path, char **error_out) {
    if (runtime_booted) {
        return 0;
    }

    char root_data_path[4096];
    if (!resolve_root_data_path(root_archive_path, root_data_path, sizeof(root_data_path), error_out)) {
        return -1;
    }

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
    current->thread = pthread_self();

    create_some_device_nodes();
    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);
    tty_drivers[TTY_CONSOLE_MAJOR] = &iexa_headless_tty_driver;
    set_console_device(TTY_CONSOLE_MAJOR, 1);

    char shared_path[4096];
    snprintf(shared_path, sizeof(shared_path), "%s/shared", workspace_path);
    ensure_directory(shared_path);
    generic_mkdirat(AT_PWD, "/mnt", 0755);
    generic_mkdirat(AT_PWD, "/mnt/iexa", 0755);
    do_mount(&realfs, shared_path, "/mnt/iexa", "", 0);

    runtime_booted = true;
    return 0;
}

int32_t iexa_local_alpine_runtime_available(void) {
    return 1;
}

char *iexa_local_alpine_execute(
    const char *command,
    const char *cwd,
    const char *root_archive_path,
    const char *workspace_path,
    int32_t *exit_code
) {
    pthread_mutex_lock(&runtime_lock);

    if (workspace_path == NULL || workspace_path[0] == '\0') {
        if (exit_code != NULL) {
            *exit_code = 127;
        }
        pthread_mutex_unlock(&runtime_lock);
        return iexa_dup_output("Local Alpine workspace path is empty");
    }
    ensure_directory(workspace_path);

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
        struct fd *pwd = generic_open(cwd, O_RDONLY_ | O_DIRECTORY_, 0);
        if (!IS_ERR(pwd)) {
            fs_chdir(current->fs, pwd);
        }
    }

    capture_reset();
    exit_hook = capture_exit_hook;
    set_console_device(TTY_CONSOLE_MAJOR, 1);
    err = create_stdio("/dev/tty1", TTY_CONSOLE_MAJOR, 1);
    if (err < 0) {
        if (exit_code != NULL) {
            *exit_code = 127;
        }
        exit_hook = NULL;
        pthread_mutex_unlock(&runtime_lock);
        char message[128];
        snprintf(message, sizeof(message), "create_stdio failed: %d", err);
        return iexa_dup_output(message);
    }

    const char *shell = "/bin/sh";
    char argv[8192];
    snprintf(argv, sizeof(argv), "%s%c-c%c%s%c%c", shell, '\0', '\0', command != NULL ? command : "", '\0', '\0');
    const char *envp = "TERM=xterm-256color\0PATH=/bin:/sbin:/usr/bin:/usr/sbin\0HOME=/root\0USER=root\0";

    err = do_execve(shell, 3, argv, envp);
    if (err < 0) {
        if (exit_code != NULL) {
            *exit_code = 127;
        }
        exit_hook = NULL;
        pthread_mutex_unlock(&runtime_lock);
        char message[256];
        snprintf(message, sizeof(message), "do_execve failed for %s: %d", shell, err);
        return iexa_dup_output(message);
    }

    capture_pid = current->pid;
    task_start(current);

    pthread_mutex_lock(&capture_lock);
    while (!capture_finished) {
        struct timespec timeout;
        struct timeval now;
        gettimeofday(&now, NULL);
        timeout.tv_sec = now.tv_sec + 30;
        timeout.tv_nsec = now.tv_usec * 1000;
        int wait_result = pthread_cond_timedwait(&capture_done, &capture_lock, &timeout);
        if (wait_result == ETIMEDOUT) {
            capture_exit_code = 124;
            const char *message = "Local Alpine command timed out after 30 seconds\n";
            capture_append_locked(message, strlen(message));
            capture_finished = true;
            break;
        }
    }
    if (capture_buffer == NULL || capture_length == 0) {
        char message[256];
        snprintf(message, sizeof(message), "Local Alpine command exited without output. pid=%d shell=%s cwd=%s", capture_pid, shell, cwd != NULL ? cwd : "");
        capture_append_locked(message, strlen(message));
    }
    char *output = iexa_dup_output(capture_buffer != NULL ? capture_buffer : "");
    int completed_exit_code = capture_exit_code;
    pthread_mutex_unlock(&capture_lock);

    if (exit_code != NULL) {
        *exit_code = completed_exit_code;
    }
    exit_hook = NULL;
    pthread_mutex_unlock(&runtime_lock);
    return output != NULL ? output : iexa_dup_output("");
}

#else

int32_t iexa_local_alpine_runtime_available(void) {
    return 0;
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
