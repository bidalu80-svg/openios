#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

#include "debug.h"

static void default_die_handler(const char *msg) {
    fprintf(stderr, "%s\n", msg);
}

void (*die_handler)(const char *msg) = default_die_handler;

void ish_vprintk(const char *msg, va_list args) {
    vfprintf(stderr, msg, args);
}

void ish_printk(const char *msg, ...) {
    va_list args;
    va_start(args, msg);
    ish_vprintk(msg, args);
    va_end(args);
}

_Noreturn void die(const char *msg, ...) {
    char buffer[4096];
    va_list args;
    va_start(args, msg);
    vsnprintf(buffer, sizeof(buffer), msg, args);
    va_end(args);
    die_handler(buffer);
    abort();
}

int current_pid(void) {
    return -1;
}
