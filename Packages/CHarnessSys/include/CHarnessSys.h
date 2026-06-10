#ifndef C_HARNESS_SYS_H
#define C_HARNESS_SYS_H

#include <stddef.h>

// Declarations only — no system headers here. The implementations (in shim.c) need feature macros
// (_XOPEN_SOURCE for posix_openpt, a hand-rolled ucred for SO_PEERCRED) and the system includes that
// come with them; keeping those out of the module's umbrella header avoids leaking a conflicting
// `fd_set` definition into the Swift `CHarnessSys` module (it clashed with `CDispatch`'s).
//
// These wrap C facilities Swift can't call portably: the variadic `ioctl`/`open`/`fcntl` (unavailable
// to Swift on Linux), `SO_PEERCRED`/`struct ucred` (gated behind _GNU_SOURCE), and the `posix_openpt`
// family (gated behind _XOPEN_SOURCE).

int harness_pty_set_winsize(int fd, unsigned short rows, unsigned short cols);
int harness_pty_get_winsize(int fd, unsigned short *rows, unsigned short *cols);
int harness_pty_make_controlling(int fd);
int harness_open_rdwr(const char *path);
int harness_set_nonblocking(int fd);

// Peer UID of a connected AF_UNIX stream socket (getpeereid on Darwin, SO_PEERCRED on Linux), or -1.
long harness_peer_uid(int fd);

// Open a PTY master (O_RDWR|O_NOCTTY), grant + unlock it, and write the slave device path into
// `slave_path` (a caller buffer of `slave_len` bytes). Returns the master fd, or -1 on failure.
int harness_open_pty_master(char *slave_path, size_t slave_len);

// Close all file descriptors >= lowfd.  On Linux 5.9+ this uses the close_range(2) syscall
// (atomic, faster than a loop across sysconf(_SC_OPEN_MAX) fds).  On older Linux it falls
// back to a close(2) loop.  On Darwin/macOS this function is a no-op — callers on that
// platform use forkpty(3) which never needs post-fork fd cleanup (the master is the only
// inherited fd; all others are O_CLOEXEC'd in the daemon).
//
// POST-FORK SAFETY: this function must be async-signal-safe.  All code paths use only
// syscall(2), close(2), getdtablesize(2), or a simple integer loop — no malloc, no stdio.
void harness_close_fds_from(int lowfd);

#endif /* C_HARNESS_SYS_H */
