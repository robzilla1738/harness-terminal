#ifndef C_HARNESS_SYS_H
#define C_HARNESS_SYS_H

// `struct ucred` / `SO_PEERCRED` (Linux peer credentials) are gated behind _GNU_SOURCE, which the
// Swift Glibc module doesn't define — so the peer-uid check lives here in C rather than Swift.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <sys/ioctl.h>
#include <sys/socket.h>
#include <termios.h>
#include <fcntl.h>
#include <unistd.h>

// `ioctl` is a C variadic function, which the Swift importer marks unavailable on Linux (and is
// awkward to call portably on Darwin). These non-variadic `static inline` wrappers give the daemon
// and CLI one Swift-callable spelling for the few terminal ioctls they need, on both platforms.

static inline int harness_pty_set_winsize(int fd, unsigned short rows, unsigned short cols) {
    struct winsize ws;
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    return ioctl(fd, TIOCSWINSZ, &ws);
}

static inline int harness_pty_get_winsize(int fd, unsigned short *rows, unsigned short *cols) {
    struct winsize ws;
    int r = ioctl(fd, TIOCGWINSZ, &ws);
    if (r == 0) {
        if (rows) *rows = ws.ws_row;
        if (cols) *cols = ws.ws_col;
    }
    return r;
}

// Make `fd` (a PTY slave) the controlling terminal of the calling session. Used by the Linux PTY
// spawn path after `setsid`; `forkpty` does this implicitly on Darwin.
static inline int harness_pty_make_controlling(int fd) {
#ifdef TIOCSCTTY
    return ioctl(fd, TIOCSCTTY, 0);
#else
    (void)fd;
    return -1;
#endif
}

// `open` is also a C variadic function (the optional mode arg); wrap the read/write open the PTY
// child needs so Swift can call it portably. Async-signal-safe, so usable between fork and exec.
static inline int harness_open_rdwr(const char *path) {
    return open(path, O_RDWR);
}

// `fcntl` is variadic too; wrap the one operation we need — set O_NONBLOCK — so a slow/stuck peer
// never blocks a write on the daemon's serial queue. Returns 0 on success, -1 on error.
static inline int harness_set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

// Peer UID of a connected AF_UNIX stream socket — `getpeereid` on Darwin/BSD, `SO_PEERCRED` on
// Linux. Both read kernel-recorded credentials that can't be spoofed. Returns the uid, or -1 on
// failure. Kept in C so the Linux ucred path compiles without the Swift Glibc module exposing it.
static inline long harness_peer_uid(int fd) {
#if defined(__APPLE__)
    uid_t uid = 0;
    gid_t gid = 0;
    if (getpeereid(fd, &uid, &gid) != 0) return -1;
    return (long)uid;
#elif defined(SO_PEERCRED)
    struct ucred cred;
    socklen_t len = sizeof(cred);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) != 0) return -1;
    return (long)cred.uid;
#else
    (void)fd;
    return -1;
#endif
}

#endif /* C_HARNESS_SYS_H */
