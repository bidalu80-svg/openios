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

static bool append_env_entry(char *buffer, size_t buffer_size, size_t *offset, const char *entry) {
    if (buffer == NULL || offset == NULL || entry == NULL) {
        return false;
    }
    size_t length = strlen(entry) + 1;
    if (*offset + length + 1 > buffer_size) {
        return false;
    }
    memcpy(buffer + *offset, entry, length);
    *offset += length;
    buffer[*offset] = '\0';
    return true;
}

#if IEXA_LOCAL_ALPINE_ISH

#include <arpa/inet.h>
#include <ctype.h>
#include <netdb.h>
#include <pthread.h>
#include <resolv.h>
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
#include "kernel/signal.h"
#include "kernel/task.h"
#include "misc.h"
#include "fs/path.h"
#include "fs/devices.h"
#include "fs/fd.h"
#include "fs/fake.h"
#include "fs/real.h"
#include "fs/sock.h"
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
static int capture_pgid = 0;

static bool contains_case_insensitive(const char *value, const char *needle) {
    if (value == NULL || needle == NULL || needle[0] == '\0') {
        return false;
    }

    size_t needle_length = strlen(needle);
    for (const char *cursor = value; *cursor != '\0'; cursor++) {
        size_t index = 0;
        while (index < needle_length &&
               cursor[index] != '\0' &&
               tolower((unsigned char) cursor[index]) == tolower((unsigned char) needle[index])) {
            index++;
        }
        if (index == needle_length) {
            return true;
        }
    }
    return false;
}

// This is only a timeout policy. It is not a command allowlist: commands are
// still passed through to /bin/sh -c below.
static int timeout_seconds_for_command(const char *command) {
    if (contains_case_insensitive(command, "apk add") ||
        contains_case_insensitive(command, "apk upgrade") ||
        contains_case_insensitive(command, "apk fix")) {
        return 900;
    }
    if (contains_case_insensitive(command, "apk update") ||
        contains_case_insensitive(command, "curl ") ||
        contains_case_insensitive(command, "wget ")) {
        return 300;
    }
    return 300;
}

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
    capture_pgid = 0;
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

static void wait_for_capture_settle_locked(void) {
    size_t previous_length = capture_length;
    int stable_intervals = 0;
    for (int attempt = 0; attempt < 5; attempt++) {
        pthread_mutex_unlock(&capture_lock);
        usleep(50000);
        pthread_mutex_lock(&capture_lock);
        if (capture_length == previous_length) {
            stable_intervals++;
            if (stable_intervals >= 2) {
                return;
            }
        } else {
            stable_intervals = 0;
            previous_length = capture_length;
        }
    }
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

static void write_file_in_fakefs(const char *path, const char *contents) {
    struct fd *fd = generic_open(path, O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0666);
    if (IS_ERR(fd)) {
        return;
    }
    fd->ops->write(fd, contents, strlen(contents));
    fd_close(fd);
}

static void configure_dns(void) {
    struct task *init = pid_get_task(1);
    if (init != NULL) {
        current = init;
    }

    char resolv_conf[2048];
    size_t used = 0;
    resolv_conf[0] = '\0';

    struct __res_state res;
    memset(&res, 0, sizeof(res));
    if (res_ninit(&res) == EXIT_SUCCESS) {
        if (res.dnsrch[0] != NULL) {
            int written = snprintf(resolv_conf + used, sizeof(resolv_conf) - used, "search");
            if (written > 0) {
                used += (size_t) written < sizeof(resolv_conf) - used ? (size_t) written : sizeof(resolv_conf) - used - 1;
            }
            for (int i = 0; res.dnsrch[i] != NULL && used < sizeof(resolv_conf) - 1; i++) {
                written = snprintf(resolv_conf + used, sizeof(resolv_conf) - used, " %s", res.dnsrch[i]);
                if (written > 0) {
                    used += (size_t) written < sizeof(resolv_conf) - used ? (size_t) written : sizeof(resolv_conf) - used - 1;
                }
            }
            if (used < sizeof(resolv_conf) - 1) {
                resolv_conf[used++] = '\n';
                resolv_conf[used] = '\0';
            }
        }

        union res_sockaddr_union servers[NI_MAXSERV];
        int servers_found = res_getservers(&res, servers, NI_MAXSERV);
        char address[NI_MAXHOST];
        for (int i = 0; i < servers_found && used < sizeof(resolv_conf) - 1; i++) {
            union res_sockaddr_union server = servers[i];
            if (server.sin.sin_len == 0) {
                continue;
            }
            if (getnameinfo((struct sockaddr *) &server.sin, server.sin.sin_len,
                            address, sizeof(address),
                            NULL, 0, NI_NUMERICHOST) != 0) {
                continue;
            }
            int written = snprintf(resolv_conf + used, sizeof(resolv_conf) - used, "nameserver %s\n", address);
            if (written > 0) {
                used += (size_t) written < sizeof(resolv_conf) - used ? (size_t) written : sizeof(resolv_conf) - used - 1;
            }
        }
    }

    if (strstr(resolv_conf, "nameserver ") == NULL) {
        snprintf(resolv_conf, sizeof(resolv_conf),
                 "nameserver 1.1.1.1\n"
                 "nameserver 8.8.8.8\n"
                 "nameserver 223.5.5.5\n");
    }

    strncat(resolv_conf, "options timeout:2 attempts:2\n",
            sizeof(resolv_conf) - strlen(resolv_conf) - 1);
    write_file_in_fakefs("/etc/resolv.conf", resolv_conf);
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
    configure_dns();

    char socket_tmp_dir[4096];
    snprintf(socket_tmp_dir, sizeof(socket_tmp_dir), "%s/sockets", workspace_path);
    ensure_directory(socket_tmp_dir);
    char socket_tmp_prefix[4096];
    snprintf(socket_tmp_prefix, sizeof(socket_tmp_prefix), "%s/ishsock", socket_tmp_dir);
    sock_tmp_prefix = strdup(socket_tmp_prefix);

    tty_drivers[TTY_CONSOLE_MAJOR] = &iexa_headless_tty_driver;
    set_console_device(TTY_CONSOLE_MAJOR, 1);

    char shared_path[4096];
    snprintf(shared_path, sizeof(shared_path), "%s/shared", workspace_path);
    ensure_directory(shared_path);
    // Many shell snippets and tools assume /tmp exists.
    generic_mkdirat(AT_PWD, "/tmp", 01777);
    generic_mkdirat(AT_PWD, "/mnt", 0755);
    generic_mkdirat(AT_PWD, "/mnt/iexa", 0755);
    do_mount(&realfs, shared_path, "/mnt/iexa", "", 0);

    runtime_booted = true;
    return 0;
}

int32_t iexa_local_alpine_runtime_available(void) {
    return 1;
}

int32_t iexa_local_alpine_interrupt(void) {
    int pgid = 0;
    int pid = 0;

    pthread_mutex_lock(&capture_lock);
    if (!capture_finished) {
        pgid = capture_pgid;
        pid = capture_pid;
    }
    pthread_mutex_unlock(&capture_lock);

    if (pgid > 0) {
        return send_group_signal((dword_t) pgid, SIGINT_, SIGINFO_NIL) == 0 ? 1 : 0;
    }

    if (pid > 0) {
        lock(&pids_lock);
        struct task *task = pid_get_task((dword_t) pid);
        if (task == NULL) {
            unlock(&pids_lock);
            return 0;
        }
        send_signal(task, SIGINT_, SIGINFO_NIL);
        unlock(&pids_lock);
        return 1;
    }

    return 0;
}

char *iexa_local_alpine_execute(
    const char *command,
    const char *cwd,
    const char *root_archive_path,
    const char *workspace_path,
    const char *time_zone,
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

    configure_dns();

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
    const char *safe_command = command != NULL ? command : "";
    char argv[8192];
    size_t argv_required = strlen(shell) + strlen("-c") + strlen(safe_command) + 4;
    if (argv_required >= sizeof(argv)) {
        if (exit_code != NULL) {
            *exit_code = 125;
        }
        exit_hook = NULL;
        pthread_mutex_unlock(&runtime_lock);
        return iexa_dup_output("Local Alpine inline command is too long; write it to a script file and execute the file instead.\n");
    }
    snprintf(argv, sizeof(argv), "%s%c-c%c%s%c%c", shell, '\0', '\0', safe_command, '\0', '\0');
    char envp[1024];
    envp[0] = '\0';
    size_t envp_offset = 0;
    append_env_entry(envp, sizeof(envp), &envp_offset, "TERM=xterm-256color");
    append_env_entry(envp, sizeof(envp), &envp_offset, "PATH=/bin:/sbin:/usr/bin:/usr/sbin");
    append_env_entry(envp, sizeof(envp), &envp_offset, "HOME=/root");
    append_env_entry(envp, sizeof(envp), &envp_offset, "USER=root");
    if (time_zone != NULL && time_zone[0] != '\0') {
        char tz_env[128];
        snprintf(tz_env, sizeof(tz_env), "TZ=%s", time_zone);
        append_env_entry(envp, sizeof(envp), &envp_offset, tz_env);
    }

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

    pthread_mutex_lock(&capture_lock);
    capture_pid = current->pid;
    capture_pgid = current->group != NULL ? (int) current->group->pgid : current->pid;
    pthread_mutex_unlock(&capture_lock);
    task_start(current);

    int timeout_seconds = timeout_seconds_for_command(command);
    pthread_mutex_lock(&capture_lock);
    while (!capture_finished) {
        struct timespec timeout;
        struct timeval now;
        gettimeofday(&now, NULL);
        timeout.tv_sec = now.tv_sec + timeout_seconds;
        timeout.tv_nsec = now.tv_usec * 1000;
        int wait_result = pthread_cond_timedwait(&capture_done, &capture_lock, &timeout);
        if (wait_result == ETIMEDOUT) {
            capture_exit_code = 124;
            char message[96];
            snprintf(message, sizeof(message), "Local Alpine command timed out after %d seconds\n", timeout_seconds);
            capture_append_locked(message, strlen(message));
            capture_finished = true;
            break;
        }
    }
    wait_for_capture_settle_locked();
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

int32_t iexa_local_alpine_interrupt(void) {
    return 0;
}

char *iexa_local_alpine_execute(
    const char *command,
    const char *cwd,
    const char *root_archive_path,
    const char *workspace_path,
    const char *time_zone,
    int32_t *exit_code
) {
    (void) command;
    (void) cwd;
    (void) root_archive_path;
    (void) workspace_path;
    (void) time_zone;
    if (exit_code != NULL) {
        *exit_code = 126;
    }
    return iexa_dup_output("Local Alpine native runtime was not compiled with IEXA_LOCAL_ALPINE_ISH=1.");
}

#endif

void iexa_local_alpine_free(char *buffer) {
    free(buffer);
}
