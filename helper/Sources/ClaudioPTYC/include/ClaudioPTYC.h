#ifndef CLAUDIO_PTY_C_H
#define CLAUDIO_PTY_C_H
#include <termios.h>
#include <sys/ioctl.h>
#include <sys/types.h>

// Child setup stays entirely in C: no Swift/Foundation work occurs between fork and exec.
pid_t claudio_pty_spawn(const char *path, char *const argv[],
                       const struct termios *attributes, const struct winsize *size,
                       int *master);
int claudio_pty_install_handlers(void);
void claudio_pty_restore_handlers(void);
int claudio_pty_take_signal(void);
int claudio_pty_input_caught_up(int fd);
// 0 running, 1 exited (code includes 128+signal), 2 stopped, -1 error.
int claudio_pty_wait(pid_t child, int *code);
#endif
