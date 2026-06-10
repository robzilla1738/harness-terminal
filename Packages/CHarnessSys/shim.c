// Feature macros must precede the system includes:
//  - _XOPEN_SOURCE 600 exposes posix_openpt/grantpt/unlockpt/ptsname and yields the XPG4.2 `fd_set`
//    layout (matching CDispatch) rather than the _GNU_SOURCE one that conflicted.
//  - We deliberately do NOT define _GNU_SOURCE (it changes `fd_set` and `struct ucred`); the peer-uid
//    path declares its own ucred-shaped struct instead.
#define _XOPEN_SOURCE 600
#define _DEFAULT_SOURCE

#include "CHarnessSys.h"

#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <termios.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

int harness_pty_set_winsize(int fd, unsigned short rows, unsigned short cols) {
    struct winsize ws;
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    return ioctl(fd, TIOCSWINSZ, &ws);
}

int harness_pty_get_winsize(int fd, unsigned short *rows, unsigned short *cols) {
    struct winsize ws;
    int r = ioctl(fd, TIOCGWINSZ, &ws);
    if (r == 0) {
        if (rows) *rows = ws.ws_row;
        if (cols) *cols = ws.ws_col;
    }
    return r;
}

int harness_pty_make_controlling(int fd) {
#ifdef TIOCSCTTY
    return ioctl(fd, TIOCSCTTY, 0);
#else
    (void)fd;
    return -1;
#endif
}

int harness_open_rdwr(const char *path) {
    return open(path, O_RDWR);
}

int harness_set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

long harness_peer_uid(int fd) {
#if defined(__APPLE__)
    uid_t uid = 0;
    gid_t gid = 0;
    if (getpeereid(fd, &uid, &gid) != 0) return -1;
    return (long)uid;
#elif defined(SO_PEERCRED)
    // Kernel `struct ucred` layout {pid, uid, gid} — declared here so we don't need _GNU_SOURCE.
    struct harness_ucred { pid_t pid; uid_t uid; gid_t gid; } cred;
    socklen_t len = sizeof(cred);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) != 0) return -1;
    return (long)cred.uid;
#else
    (void)fd;
    return -1;
#endif
}

int harness_open_pty_master(char *slave_path, size_t slave_len) {
    // Guard on the actual target platform, not on _XOPEN_SOURCE. The original guard
    // `defined(__APPLE__) || defined(_XOPEN_SOURCE)` was always true because this file
    // defines _XOPEN_SOURCE 600 at the top — making the #else branch permanently dead
    // code that would silently return -1 if the define ever moved. Use the real platform
    // macros instead, and make an unsupported platform a hard #error so it fails loudly
    // at compile time rather than silently producing broken PTYs at runtime.
#if defined(__APPLE__) || defined(__linux__)
    int master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0) return -1;
    if (grantpt(master) != 0 || unlockpt(master) != 0) {
        close(master);
        return -1;
    }
    const char *name = ptsname(master);
    if (!name) {
        close(master);
        return -1;
    }
    if (slave_path && slave_len > 0) {
        strncpy(slave_path, name, slave_len - 1);
        slave_path[slave_len - 1] = '\0';
    }
    return master;
#else
#error "unsupported platform for harness_open_pty_master"
#endif
}

// POST-FORK SAFETY: only async-signal-safe operations are used below (syscall, close,
// getdtablesize, integer arithmetic). No malloc, no stdio, no C++ — safe to call between
// fork(2) and execve(2) in the child.
void harness_close_fds_from(int lowfd) {
#if defined(__linux__)
    // close_range(2) was added in Linux 5.9. Use it when available (SYS_close_range is
    // defined at build time iff the kernel headers are new enough to declare the syscall
    // number). ~0U is the CLOSE_RANGE_UNSHARE flag's "all fds" sentinel for the `max_fd`
    // argument; flags=0 means plain close (not CLOSE_RANGE_UNSHARE / CLOSE_RANGE_CLOEXEC).
    // On a kernel that knows the syscall number but doesn't actually support it (shouldn't
    // happen in practice — the number and the implementation landed together), the syscall
    // returns ENOSYS and we fall through to the loop.
#ifdef SYS_close_range
    if (syscall(SYS_close_range, (unsigned int)lowfd, ~0U, 0U) == 0) {
        return; // success: all fds >= lowfd are now closed
    }
    // ENOSYS or any other error: fall through to the loop below.
#endif /* SYS_close_range */

    // Fallback: iterate from lowfd to getdtablesize(). Slower than close_range (O(N) where
    // N = table size, typically 1024 or 4096) but correct on kernels without the syscall.
    int limit = getdtablesize();
    for (int fd = lowfd; fd < limit; fd++) {
        close(fd);
    }
#else
    // On Darwin, forkpty(3) is used (not this Linux path), and the daemon marks its own
    // fds O_CLOEXEC, so there are no inherited descriptors to close in the child. This
    // function is provided as a no-op for Darwin to satisfy the linker (the header declares
    // it unconditionally so the Swift caller can use it without a #if canImport(Glibc)).
    (void)lowfd;
#endif
}
