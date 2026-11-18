#define _GNU_SOURCE
#include <dlfcn.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* Pause the announcing thread while Poly/ML's signal thread cancels the
   batch. Returning immediately would race registration on the old client. */
ssize_t write(int fd, const void *buffer, size_t count)
{
    static ssize_t (*real_write)(int, const void *, size_t);
    static int interrupted;
    const char prefix[] = "holbuild: remote batch ";
    if (!real_write)
        real_write = dlsym(RTLD_NEXT, "write");
    ssize_t result = real_write(fd, buffer, count);
    if (fd == STDERR_FILENO && !interrupted &&
        memmem(buffer, count, prefix, sizeof(prefix) - 1)) {
        interrupted = 1;
        unsetenv("LD_PRELOAD");
        kill(getpid(), SIGTERM);
        struct timespec delay = {.tv_nsec = 100000000};
        nanosleep(&delay, NULL);
    }
    return result;
}
