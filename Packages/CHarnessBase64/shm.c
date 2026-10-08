// POSIX shared memory for Kitty graphics `t=s`. `shm_open` is variadic, which Swift can't call.
#include "CHarnessBase64.h"

#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

intptr_t harness_shm_take(const char *name, intptr_t offset, intptr_t size, intptr_t limit, uint8_t **out) {
    *out = NULL;
    if (name == NULL || offset < 0 || size < 0) return -1;
    int fd = shm_open(name, O_RDONLY, 0);
    if (fd < 0) return -1;
    struct stat st;
    intptr_t result = -1;
    if (fstat(fd, &st) == 0 && st.st_size > offset) {
        intptr_t available = (intptr_t)st.st_size - offset;
        intptr_t count = size > 0 && size < available ? size : available;
        if (count <= limit) {
            void *mapped = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
            if (mapped != MAP_FAILED) {
                uint8_t *copy = malloc(count > 0 ? (size_t)count : 1);
                if (copy != NULL) {
                    memcpy(copy, (uint8_t *)mapped + offset, (size_t)count);
                    *out = copy;
                    result = count;
                }
                munmap(mapped, (size_t)st.st_size);
            }
        }
    }
    close(fd);
    // The protocol hands the object over: the terminal removes it once read.
    shm_unlink(name);
    return result;
}

int harness_shm_put(const char *name, const uint8_t *bytes, intptr_t count) {
    int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd < 0) return -1;
    int ok = ftruncate(fd, (off_t)count) == 0;
    if (ok && count > 0) {
        void *mapped = mmap(NULL, (size_t)count, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        ok = mapped != MAP_FAILED;
        if (ok) {
            memcpy(mapped, bytes, (size_t)count);
            munmap(mapped, (size_t)count);
        }
    }
    close(fd);
    if (!ok) shm_unlink(name);
    return ok ? 0 : -1;
}
