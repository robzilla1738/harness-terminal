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
#if defined(__APPLE__) || defined(_XOPEN_SOURCE)
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
    (void)slave_path;
    (void)slave_len;
    return -1;
#endif
}
