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
#include "fs/dev.h"
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

#define IEXA_MAX_SESSIONS 4

struct iexa_session {
    int id;
    bool active;
    bool exited;
    int pid;
    int pgid;
    struct tty *tty;
    char *buffer;
    size_t buffer_length;
    size_t buffer_capacity;
    pthread_mutex_t lock;
};

static struct iexa_session sessions[IEXA_MAX_SESSIONS];
static pthread_mutex_t sessions_lock = PTHREAD_MUTEX_INITIALIZER;
static int next_session_id = 1;

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
    if (contains_case_insensitive(command, " ping ") ||
        contains_case_insensitive(command, "\nping ") ||
        contains_case_insensitive(command, "/ping ") ||
        contains_case_insensitive(command, " busybox ping ")) {
        return 20;
    }
    if (contains_case_insensitive(command, "nslookup ") ||
        contains_case_insensitive(command, "\nnslookup ") ||
        contains_case_insensitive(command, " busybox nslookup ") ||
        contains_case_insensitive(command, " dig ") ||
        contains_case_insensitive(command, "\ndig ") ||
        contains_case_insensitive(command, " drill ") ||
        contains_case_insensitive(command, "\ndrill ") ||
        contains_case_insensitive(command, " host ") ||
        contains_case_insensitive(command, "\nhost ")) {
        return 60;
    }
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

static void session_append_locked(struct iexa_session *session, const void *bytes, size_t length) {
    if (session == NULL || length == 0) {
        return;
    }
    if (session->buffer_length + length + 1 > session->buffer_capacity) {
        size_t next_capacity = session->buffer_capacity == 0 ? 4096 : session->buffer_capacity;
        while (next_capacity < session->buffer_length + length + 1) {
            next_capacity *= 2;
        }
        char *next = realloc(session->buffer, next_capacity);
        if (next == NULL) {
            return;
        }
        session->buffer = next;
        session->buffer_capacity = next_capacity;
    }
    memcpy(session->buffer + session->buffer_length, bytes, length);
    session->buffer_length += length;
    session->buffer[session->buffer_length] = '\0';
}

static struct iexa_session *session_for_tty_locked(struct tty *tty) {
    for (int i = 0; i < IEXA_MAX_SESSIONS; i++) {
        if (sessions[i].active && sessions[i].tty == tty) {
            return &sessions[i];
        }
    }
    return NULL;
}

static struct iexa_session *session_for_id_locked(int session_id) {
    if (session_id <= 0) {
        return NULL;
    }
    for (int i = 0; i < IEXA_MAX_SESSIONS; i++) {
        if (sessions[i].active && sessions[i].id == session_id) {
            return &sessions[i];
        }
    }
    return NULL;
}

static bool has_active_sessions_locked(void) {
    for (int i = 0; i < IEXA_MAX_SESSIONS; i++) {
        if (sessions[i].active) {
            return true;
        }
    }
    return false;
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

static int session_tty_init(struct tty *tty) {
    tty->winsize.col = 120;
    tty->winsize.row = 40;
    return 0;
}

static int session_tty_open(struct tty *tty) {
    (void) tty;
    return 0;
}

static int session_tty_close(struct tty *tty) {
    (void) tty;
    return 0;
}

static int session_tty_write(struct tty *tty, const void *buf, size_t len, bool blocking) {
    (void) blocking;
    pthread_mutex_lock(&sessions_lock);
    struct iexa_session *session = session_for_tty_locked(tty);
    if (session != NULL) {
        pthread_mutex_lock(&session->lock);
        session_append_locked(session, buf, len);
        pthread_mutex_unlock(&session->lock);
    }
    pthread_mutex_unlock(&sessions_lock);
    return (int) len;
}

static void session_tty_cleanup(struct tty *tty) {
    (void) tty;
}

static struct tty_driver_ops session_tty_ops = {
    .init = session_tty_init,
    .open = session_tty_open,
    .close = session_tty_close,
    .write = session_tty_write,
    .cleanup = session_tty_cleanup,
};

static struct tty_driver iexa_session_tty_driver = {.ops = &session_tty_ops};

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

static bool fakefs_has_exact_path(sqlite3 *db, const char *path) {
    if (db == NULL || path == NULL) {
        return false;
    }

    const char *sql = "select count(*) from paths where cast(path as text) = ?1;";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &statement, NULL) != SQLITE_OK) {
        return false;
    }

    sqlite3_bind_text(statement, 1, path, -1, SQLITE_TRANSIENT);
    bool found = false;
    if (sqlite3_step(statement) == SQLITE_ROW) {
        found = sqlite3_column_int(statement, 0) > 0;
    }
    sqlite3_finalize(statement);
    return found;
}

static bool fakefs_has_path(sqlite3 *db, const char *path) {
    if (db == NULL || path == NULL || path[0] == '\0') {
        return false;
    }

    if (fakefs_has_exact_path(db, path)) {
        return true;
    }

    while (path[0] == '/') {
        path++;
    }
    if (path[0] == '\0') {
        return false;
    }

    bool found = fakefs_has_exact_path(db, path);
    if (found) {
        return true;
    }

    size_t path_length = strlen(path);
    if (path_length == 0 || path_length >= 4094) {
        return false;
    }

    char alternate[4096];
    if (path[path_length - 1] == '/') {
        memcpy(alternate, path, path_length);
        alternate[path_length - 1] = '\0';
    } else {
        memcpy(alternate, path, path_length);
        alternate[path_length] = '/';
        alternate[path_length + 1] = '\0';
    }

    if (fakefs_has_exact_path(db, alternate)) {
        return true;
    }

    if (alternate[0] != '/') {
        char absolute[4096];
        int written = snprintf(absolute, sizeof(absolute), "/%s", alternate);
        if (written > 0 && (size_t) written < sizeof(absolute)) {
            return fakefs_has_exact_path(db, absolute);
        }
    }
    return false;
}

int32_t iexa_local_alpine_fakefs_contains_paths(const char *fakefs_path, const char *required_paths) {
    if (fakefs_path == NULL || fakefs_path[0] == '\0') {
        return 0;
    }

    char metadata_path[4096];
    int written = snprintf(metadata_path, sizeof(metadata_path), "%s/meta.db", fakefs_path);
    if (written <= 0 || (size_t) written >= sizeof(metadata_path)) {
        return 0;
    }

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(metadata_path, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        if (db != NULL) {
            sqlite3_close(db);
        }
        return 0;
    }

    bool ok = true;
    if (required_paths != NULL && required_paths[0] != '\0') {
        char *copy = strdup(required_paths);
        if (copy == NULL) {
            sqlite3_close(db);
            return 0;
        }

        char *cursor = copy;
        while (cursor != NULL && *cursor != '\0') {
            char *line_end = strchr(cursor, '\n');
            if (line_end != NULL) {
                *line_end = '\0';
            }

            if (cursor[0] != '\0' && !fakefs_has_path(db, cursor)) {
                ok = false;
                break;
            }

            cursor = line_end != NULL ? line_end + 1 : NULL;
        }
        free(copy);
    }

    sqlite3_close(db);
    return ok ? 1 : 0;
}

static void session_exit_hook(struct task *task, int code) {
    (void) code;
    capture_exit_hook(task, code);

    pthread_mutex_lock(&sessions_lock);
    for (int i = 0; i < IEXA_MAX_SESSIONS; i++) {
        if (sessions[i].active && sessions[i].pid == task->pid) {
            pthread_mutex_lock(&sessions[i].lock);
            sessions[i].exited = true;
            session_append_locked(&sessions[i], "\r\n[process exited]\r\n", strlen("\r\n[process exited]\r\n"));
            pthread_mutex_unlock(&sessions[i].lock);
            break;
        }
    }
    pthread_mutex_unlock(&sessions_lock);
}

static void write_file_in_fakefs(const char *path, const char *contents) {
    struct fd *fd = generic_open(path, O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0666);
    if (IS_ERR(fd)) {
        return;
    }
    fd->ops->write(fd, contents, strlen(contents));
    fd_close(fd);
}

static void ensure_runtime_base_directories(void) {
    generic_mkdirat(AT_PWD, "/dev", 0755);
    generic_mkdirat(AT_PWD, "/dev/pts", 0755);
    generic_mkdirat(AT_PWD, "/proc", 0555);
    generic_mkdirat(AT_PWD, "/tmp", 01777);
    generic_mkdirat(AT_PWD, "/mnt", 0755);
    generic_mkdirat(AT_PWD, "/mnt/iexa", 0755);
}

static void create_runtime_device_nodes(void) {
    generic_mknodat(AT_PWD, "/dev/tty1", S_IFCHR | 0666, dev_make(TTY_CONSOLE_MAJOR, 1));
    generic_mknodat(AT_PWD, "/dev/tty2", S_IFCHR | 0666, dev_make(TTY_CONSOLE_MAJOR, 2));
    generic_mknodat(AT_PWD, "/dev/tty3", S_IFCHR | 0666, dev_make(TTY_CONSOLE_MAJOR, 3));
    generic_mknodat(AT_PWD, "/dev/tty4", S_IFCHR | 0666, dev_make(TTY_CONSOLE_MAJOR, 4));
    generic_mknodat(AT_PWD, "/dev/tty5", S_IFCHR | 0666, dev_make(TTY_CONSOLE_MAJOR, 5));
    generic_mknodat(AT_PWD, "/dev/tty6", S_IFCHR | 0666, dev_make(TTY_CONSOLE_MAJOR, 6));
    generic_mknodat(AT_PWD, "/dev/tty7", S_IFCHR | 0666, dev_make(TTY_CONSOLE_MAJOR, 7));

    generic_mknodat(AT_PWD, "/dev/tty", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR));
    generic_mknodat(AT_PWD, "/dev/console", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR));
    generic_mknodat(AT_PWD, "/dev/ptmx", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR));

    generic_mknodat(AT_PWD, "/dev/null", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_NULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/zero", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_ZERO_MINOR));
    generic_mknodat(AT_PWD, "/dev/full", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_FULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/random", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_RANDOM_MINOR));
    generic_mknodat(AT_PWD, "/dev/urandom", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_URANDOM_MINOR));
}

static int create_stdio_from_tty_device(int major, int minor) {
    struct fd *fd = adhoc_fd_create(NULL);
    if (fd == NULL) {
        return _ENOMEM;
    }
    fd->stat.rdev = dev_make(major, minor);
    fd->stat.mode = S_IFCHR | 0666;
    fd->flags = O_RDWR_;

    int err = dev_open(major, minor, DEV_CHAR, fd);
    if (err < 0) {
        fd_close(fd);
        return err;
    }

    fd->refcount = 0;
    current->files->files[0] = fd_retain(fd);
    current->files->files[1] = fd_retain(fd);
    current->files->files[2] = fd_retain(fd);
    return 0;
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

static bool valid_mount_name(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return false;
    }
    if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) {
        return false;
    }
    for (const char *p = name; *p != '\0'; p++) {
        char c = *p;
        if (!((c >= 'A' && c <= 'Z') ||
              (c >= 'a' && c <= 'z') ||
              (c >= '0' && c <= '9') ||
              c == '.' || c == '_' || c == '-')) {
            return false;
        }
    }
    return true;
}

static void apply_external_mounts(const char *mounts_configuration) {
    if (mounts_configuration == NULL || mounts_configuration[0] == '\0') {
        return;
    }

    struct task *init = pid_get_task(1);
    if (init != NULL) {
        current = init;
    }

    generic_mkdirat(AT_PWD, "/mnt/iexa/mounts", 0755);

    const char *cursor = mounts_configuration;
    int mounted_count = 0;
    while (*cursor != '\0' && mounted_count < 10) {
        const char *line_end = strchr(cursor, '\n');
        size_t line_length = line_end != NULL ? (size_t) (line_end - cursor) : strlen(cursor);
        if (line_length > 0 && line_length < 8192) {
            char line[8192];
            memcpy(line, cursor, line_length);
            line[line_length] = '\0';

            char *first_tab = strchr(line, '\t');
            if (first_tab != NULL) {
                *first_tab = '\0';
                char *mode = first_tab + 1;
                char *second_tab = strchr(mode, '\t');
                if (second_tab != NULL) {
                    (void) mode;
                    *second_tab = '\0';
                    char *source_path = second_tab + 1;
                    if (valid_mount_name(line) && source_path[0] == '/') {
                        char target_path[4096];
                        int written = snprintf(
                            target_path,
                            sizeof(target_path),
                            "/mnt/iexa/mounts/%s",
                            line
                        );
                        if (written > 0 && (size_t) written < sizeof(target_path)) {
                            generic_mkdirat(AT_PWD, target_path, 0755);
                            do_mount(&realfs, source_path, target_path, "", 0);
                            mounted_count++;
                        }
                    }
                }
            }
        }

        if (line_end == NULL) {
            break;
        }
        cursor = line_end + 1;
    }
}

static int boot_runtime(
    const char *root_archive_path,
    const char *workspace_path,
    const char *mounts_configuration,
    char **error_out
) {
    if (runtime_booted) {
        apply_external_mounts(mounts_configuration);
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

    ensure_runtime_base_directories();
    create_runtime_device_nodes();
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
    do_mount(&realfs, shared_path, "/mnt/iexa", "", 0);
    generic_mkdirat(AT_PWD, "/mnt/iexa/mounts", 0755);
    apply_external_mounts(mounts_configuration);

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

int32_t iexa_local_alpine_session_start(
    const char *cwd,
    const char *root_archive_path,
    const char *workspace_path,
    const char *mounts_configuration,
    const char *time_zone
) {
    pthread_mutex_lock(&runtime_lock);

    if (workspace_path == NULL || workspace_path[0] == '\0') {
        pthread_mutex_unlock(&runtime_lock);
        return -1;
    }
    ensure_directory(workspace_path);

    char *error = NULL;
    int err = boot_runtime(root_archive_path, workspace_path, mounts_configuration, &error);
    if (err < 0) {
        free(error);
        pthread_mutex_unlock(&runtime_lock);
        return -2;
    }

    configure_dns();

    pthread_mutex_lock(&sessions_lock);
    struct iexa_session *session = NULL;
    for (int i = 0; i < IEXA_MAX_SESSIONS; i++) {
        if (!sessions[i].active) {
            session = &sessions[i];
            memset(session, 0, sizeof(*session));
            session->id = next_session_id++;
            if (next_session_id <= 0) {
                next_session_id = 1;
            }
            session->active = true;
            pthread_mutex_init(&session->lock, NULL);
            break;
        }
    }
    pthread_mutex_unlock(&sessions_lock);

    if (session == NULL) {
        pthread_mutex_unlock(&runtime_lock);
        return -3;
    }

    err = become_new_init_child();
    if (err < 0) {
        pthread_mutex_lock(&sessions_lock);
        session->active = false;
        pthread_mutex_unlock(&sessions_lock);
        pthread_mutex_destroy(&session->lock);
        pthread_mutex_unlock(&runtime_lock);
        return -4;
    }

    if (cwd != NULL && cwd[0] != '\0') {
        struct fd *pwd = generic_open(cwd, O_RDONLY_ | O_DIRECTORY_, 0);
        if (!IS_ERR(pwd)) {
            fs_chdir(current->fs, pwd);
        }
    }

    struct tty *tty = pty_open_fake(&iexa_session_tty_driver);
    if (IS_ERR(tty)) {
        pthread_mutex_lock(&sessions_lock);
        session->active = false;
        pthread_mutex_unlock(&sessions_lock);
        pthread_mutex_destroy(&session->lock);
        pthread_mutex_unlock(&runtime_lock);
        return -5;
    }

    pthread_mutex_lock(&sessions_lock);
    session->tty = tty;
    pthread_mutex_unlock(&sessions_lock);

    err = create_stdio_from_tty_device(TTY_PSEUDO_SLAVE_MAJOR, tty->num);
    if (err < 0) {
        pthread_mutex_lock(&sessions_lock);
        session->active = false;
        session->tty = NULL;
        pthread_mutex_unlock(&sessions_lock);
        tty_release(tty);
        pthread_mutex_destroy(&session->lock);
        pthread_mutex_unlock(&runtime_lock);
        return -6;
    }
    tty_release(tty);

    const char *shell = "/bin/sh";
    char argv[64];
    snprintf(argv, sizeof(argv), "%s%c-i%c%c", shell, '\0', '\0', '\0');
    char envp[2048];
    envp[0] = '\0';
    size_t envp_offset = 0;
    append_env_entry(envp, sizeof(envp), &envp_offset, "TERM=dumb");
    append_env_entry(envp, sizeof(envp), &envp_offset, "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
    append_env_entry(envp, sizeof(envp), &envp_offset, "HOME=/root");
    append_env_entry(envp, sizeof(envp), &envp_offset, "USER=root");
    append_env_entry(envp, sizeof(envp), &envp_offset, "PS1=");
    append_env_entry(envp, sizeof(envp), &envp_offset, "ENV=/etc/profile");
    append_env_entry(envp, sizeof(envp), &envp_offset, "BROWSER=/usr/local/bin/iexa-open");
    append_env_entry(envp, sizeof(envp), &envp_offset, "LANG=C.UTF-8");
    append_env_entry(envp, sizeof(envp), &envp_offset, "LC_ALL=C.UTF-8");
    append_env_entry(envp, sizeof(envp), &envp_offset, "NO_COLOR=1");
    append_env_entry(envp, sizeof(envp), &envp_offset, "PAGER=less");
    append_env_entry(envp, sizeof(envp), &envp_offset, "PYTHONDONTWRITEBYTECODE=1");
    append_env_entry(envp, sizeof(envp), &envp_offset, "GOMAXPROCS=2");
    append_env_entry(envp, sizeof(envp), &envp_offset, "UV_LINK_MODE=symlink");
    if (time_zone != NULL && time_zone[0] != '\0') {
        char tz_env[128];
        snprintf(tz_env, sizeof(tz_env), "TZ=%s", time_zone);
        append_env_entry(envp, sizeof(envp), &envp_offset, tz_env);
    }

    err = do_execve(shell, 2, argv, envp);
    if (err < 0) {
        pthread_mutex_lock(&sessions_lock);
        session->active = false;
        session->tty = NULL;
        pthread_mutex_unlock(&sessions_lock);
        pthread_mutex_destroy(&session->lock);
        pthread_mutex_unlock(&runtime_lock);
        return -7;
    }

    pthread_mutex_lock(&sessions_lock);
    session->pid = current->pid;
    session->pgid = current->group != NULL ? (int) current->group->pgid : current->pid;
    pthread_mutex_unlock(&sessions_lock);

    exit_hook = session_exit_hook;
    int session_id = session->id;
    task_start(current);
    pthread_mutex_unlock(&runtime_lock);
    return session_id;
}

int32_t iexa_local_alpine_session_write(int32_t session_id, const char *input) {
    if (input == NULL) {
        return 0;
    }

    pthread_mutex_lock(&sessions_lock);
    struct iexa_session *session = session_for_id_locked(session_id);
    struct tty *tty = session != NULL ? session->tty : NULL;
    bool ok = session != NULL && session->active && !session->exited && tty != NULL;
    pthread_mutex_unlock(&sessions_lock);

    if (!ok) {
        return 0;
    }
    ssize_t written = tty_input(tty, input, strlen(input), false);
    return written >= 0 ? 1 : 0;
}

char *iexa_local_alpine_session_read(int32_t session_id) {
    pthread_mutex_lock(&sessions_lock);
    struct iexa_session *session = session_for_id_locked(session_id);
    if (session == NULL) {
        pthread_mutex_unlock(&sessions_lock);
        return iexa_dup_output("");
    }
    pthread_mutex_lock(&session->lock);
    pthread_mutex_unlock(&sessions_lock);

    char *output = iexa_dup_output(session->buffer != NULL ? session->buffer : "");
    free(session->buffer);
    session->buffer = NULL;
    session->buffer_length = 0;
    session->buffer_capacity = 0;
    pthread_mutex_unlock(&session->lock);
    return output != NULL ? output : iexa_dup_output("");
}

int32_t iexa_local_alpine_session_resize(int32_t session_id, int32_t columns, int32_t rows) {
    if (columns <= 0 || rows <= 0) {
        return 0;
    }
    pthread_mutex_lock(&sessions_lock);
    struct iexa_session *session = session_for_id_locked(session_id);
    struct tty *tty = session != NULL ? session->tty : NULL;
    pthread_mutex_unlock(&sessions_lock);
    if (tty == NULL) {
        return 0;
    }
    lock(&tty->lock);
    tty_set_winsize(tty, (struct winsize_) {.col = (word_t) columns, .row = (word_t) rows});
    unlock(&tty->lock);
    return 1;
}

int32_t iexa_local_alpine_session_interrupt(int32_t session_id) {
    pthread_mutex_lock(&sessions_lock);
    struct iexa_session *session = session_for_id_locked(session_id);
    int pgid = session != NULL ? session->pgid : 0;
    int pid = session != NULL ? session->pid : 0;
    pthread_mutex_unlock(&sessions_lock);

    if (pgid > 0) {
        return send_group_signal((dword_t) pgid, SIGINT_, SIGINFO_NIL) == 0 ? 1 : 0;
    }
    if (pid > 0) {
        lock(&pids_lock);
        struct task *task = pid_get_task((dword_t) pid);
        if (task != NULL) {
            send_signal(task, SIGINT_, SIGINFO_NIL);
        }
        unlock(&pids_lock);
        return task != NULL ? 1 : 0;
    }
    return 0;
}

int32_t iexa_local_alpine_session_close(int32_t session_id) {
    pthread_mutex_lock(&sessions_lock);
    struct iexa_session *session = session_for_id_locked(session_id);
    if (session == NULL) {
        pthread_mutex_unlock(&sessions_lock);
        return 0;
    }
    int pgid = session->pgid;
    int pid = session->pid;
    struct tty *tty = session->tty;
    pthread_mutex_lock(&session->lock);
    free(session->buffer);
    session->buffer = NULL;
    session->buffer_length = 0;
    session->buffer_capacity = 0;
    session->active = false;
    session->tty = NULL;
    pthread_mutex_unlock(&session->lock);
    bool any_sessions = has_active_sessions_locked();
    pthread_mutex_unlock(&sessions_lock);

    if (tty != NULL) {
        lock(&tty->lock);
        tty_hangup(tty);
        unlock(&tty->lock);
    }
    if (pgid > 0) {
        send_group_signal((dword_t) pgid, SIGHUP_, SIGINFO_NIL);
    } else if (pid > 0) {
        lock(&pids_lock);
        struct task *task = pid_get_task((dword_t) pid);
        if (task != NULL) {
            send_signal(task, SIGHUP_, SIGINFO_NIL);
        }
        unlock(&pids_lock);
    }
    if (!any_sessions && capture_finished) {
        exit_hook = NULL;
    }
    pthread_mutex_destroy(&session->lock);
    return 1;
}

char *iexa_local_alpine_execute(
    const char *command,
    const char *cwd,
    const char *root_archive_path,
    const char *workspace_path,
    const char *mounts_configuration,
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
    int err = boot_runtime(root_archive_path, workspace_path, mounts_configuration, &error);
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
    exit_hook = session_exit_hook;
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
    char envp[2048];
    envp[0] = '\0';
    size_t envp_offset = 0;
    append_env_entry(envp, sizeof(envp), &envp_offset, "TERM=xterm-256color");
    append_env_entry(envp, sizeof(envp), &envp_offset, "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
    append_env_entry(envp, sizeof(envp), &envp_offset, "HOME=/root");
    append_env_entry(envp, sizeof(envp), &envp_offset, "USER=root");
    append_env_entry(envp, sizeof(envp), &envp_offset, "ENV=/etc/profile");
    append_env_entry(envp, sizeof(envp), &envp_offset, "BROWSER=/usr/local/bin/iexa-open");
    append_env_entry(envp, sizeof(envp), &envp_offset, "LANG=C.UTF-8");
    append_env_entry(envp, sizeof(envp), &envp_offset, "LC_ALL=C.UTF-8");
    append_env_entry(envp, sizeof(envp), &envp_offset, "NO_COLOR=1");
    append_env_entry(envp, sizeof(envp), &envp_offset, "PAGER=less");
    append_env_entry(envp, sizeof(envp), &envp_offset, "PYTHONDONTWRITEBYTECODE=1");
    append_env_entry(envp, sizeof(envp), &envp_offset, "GOMAXPROCS=2");
    append_env_entry(envp, sizeof(envp), &envp_offset, "UV_LINK_MODE=symlink");
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
            int timed_out_pgid = capture_pgid;
            int timed_out_pid = capture_pid;
            char message[96];
            snprintf(message, sizeof(message), "Local Alpine command timed out after %d seconds\n", timeout_seconds);
            capture_append_locked(message, strlen(message));
            capture_finished = true;
            pthread_mutex_unlock(&capture_lock);
            if (timed_out_pgid > 0) {
                send_group_signal((dword_t) timed_out_pgid, SIGKILL_, SIGINFO_NIL);
            } else if (timed_out_pid > 0) {
                lock(&pids_lock);
                struct task *task = pid_get_task((dword_t) timed_out_pid);
                if (task != NULL) {
                    send_signal(task, SIGKILL_, SIGINFO_NIL);
                }
                unlock(&pids_lock);
            }
            pthread_mutex_lock(&capture_lock);
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
    pthread_mutex_lock(&sessions_lock);
    bool any_sessions = has_active_sessions_locked();
    pthread_mutex_unlock(&sessions_lock);
    exit_hook = any_sessions ? session_exit_hook : NULL;
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

int32_t iexa_local_alpine_fakefs_contains_paths(const char *fakefs_path, const char *required_paths) {
    (void) fakefs_path;
    (void) required_paths;
    return 0;
}

int32_t iexa_local_alpine_session_start(
    const char *cwd,
    const char *root_archive_path,
    const char *workspace_path,
    const char *mounts_configuration,
    const char *time_zone
) {
    (void) cwd;
    (void) root_archive_path;
    (void) workspace_path;
    (void) mounts_configuration;
    (void) time_zone;
    return -1;
}

int32_t iexa_local_alpine_session_write(int32_t session_id, const char *input) {
    (void) session_id;
    (void) input;
    return 0;
}

char *iexa_local_alpine_session_read(int32_t session_id) {
    (void) session_id;
    return iexa_dup_output("");
}

int32_t iexa_local_alpine_session_resize(int32_t session_id, int32_t columns, int32_t rows) {
    (void) session_id;
    (void) columns;
    (void) rows;
    return 0;
}

int32_t iexa_local_alpine_session_interrupt(int32_t session_id) {
    (void) session_id;
    return 0;
}

int32_t iexa_local_alpine_session_close(int32_t session_id) {
    (void) session_id;
    return 0;
}

char *iexa_local_alpine_execute(
    const char *command,
    const char *cwd,
    const char *root_archive_path,
    const char *workspace_path,
    const char *mounts_configuration,
    const char *time_zone,
    int32_t *exit_code
) {
    (void) command;
    (void) cwd;
    (void) root_archive_path;
    (void) workspace_path;
    (void) mounts_configuration;
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
