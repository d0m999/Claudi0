#include "ClaudioPTYC.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

static const int handled[] = { SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGWINCH, SIGCONT, SIGTSTP };
static struct sigaction previous[sizeof(handled) / sizeof(handled[0])];
static struct sigaction previous_pipe;
static _Atomic(unsigned int) signals_pending;
static sigset_t previous_mask;
static int installed;
static volatile sig_atomic_t command_group;

int claudio_pty_input_caught_up(int fd) {
    int unread = 0;
    return ioctl(fd, FIONREAD, &unread) == 0 && unread == 0;
}

static void forward_command_signal(int signal_number) {
    if (command_group > 0) kill(-(pid_t)command_group, signal_number);
}

static void command_supervisor(const char *path, char *const argv[]) {
    // Keep a same-session parent outside the command's process group. Without this tiny
    // supervisor the command group is orphaned and POSIX silently ignores Ctrl-Z/SIGTSTP.
    struct sigaction ignored = {0};
    ignored.sa_handler = SIG_IGN;
    sigemptyset(&ignored.sa_mask);
    sigaction(SIGTTOU, &ignored, NULL);
    const int forwarded[] = { SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGTSTP, SIGCONT };
    sigset_t blocked, old_mask;
    sigemptyset(&blocked);
    for (size_t i = 0; i < sizeof(forwarded) / sizeof(forwarded[0]); i++) sigaddset(&blocked, forwarded[i]);
    sigprocmask(SIG_BLOCK, &blocked, &old_mask);
    pid_t command = fork();
    if (command < 0) _exit(127);
    if (command == 0) {
        setpgid(0, 0);
        tcsetpgrp(STDIN_FILENO, getpid());
        struct sigaction normal = {0};
        normal.sa_handler = SIG_DFL;
        sigemptyset(&normal.sa_mask);
        sigaction(SIGTTOU, &normal, NULL);
        sigprocmask(SIG_SETMASK, &old_mask, NULL);
        execv(path, argv);
        const char failure[] = "Claudio PTY: command could not start.\n";
        write(STDERR_FILENO, failure, sizeof(failure) - 1);
        _exit(127);
    }
    command_group = command;
    setpgid(command, command);
    tcsetpgrp(STDIN_FILENO, command);
    struct sigaction forward = {0};
    forward.sa_handler = forward_command_signal;
    sigemptyset(&forward.sa_mask);
    for (size_t i = 0; i < sizeof(forwarded) / sizeof(forwarded[0]); i++) {
        sigaddset(&forward.sa_mask, forwarded[i]);
    }
    for (size_t i = 0; i < sizeof(forwarded) / sizeof(forwarded[0]); i++) {
        sigaction(forwarded[i], &forward, NULL);
    }
    sigprocmask(SIG_SETMASK, &old_mask, NULL);
    while (1) {
        int status = 0;
        pid_t result = waitpid(command, &status, WUNTRACED);
        if (result < 0) { if (errno == EINTR) continue; _exit(127); }
        if (WIFSTOPPED(status)) {
            kill(getpid(), SIGSTOP);
            kill(-command, SIGCONT);
        } else if (WIFEXITED(status)) {
            _exit(WEXITSTATUS(status));
        } else if (WIFSIGNALED(status)) {
            _exit(128 + WTERMSIG(status));
        }
    }
}

static void note_signal(int signal_number) {
    atomic_fetch_or_explicit(&signals_pending, 1u << signal_number, memory_order_relaxed);
}

pid_t claudio_pty_spawn(const char *path, char *const argv[],
                       const struct termios *attributes, const struct winsize *size,
                       int *master) {
    pid_t child = forkpty(master, NULL, (struct termios *)attributes, (struct winsize *)size);
    if (child == 0) {
        struct sigaction action = {0};
        action.sa_handler = SIG_DFL;
        sigemptyset(&action.sa_mask);
        for (int i = 1; i < NSIG; i++) {
            if (i != SIGKILL && i != SIGSTOP) sigaction(i, &action, NULL);
        }
        sigset_t empty;
        sigemptyset(&empty);
        sigprocmask(SIG_SETMASK, &empty, NULL);
        command_supervisor(path, argv);
    }
    if (child > 0) fcntl(*master, F_SETFD, FD_CLOEXEC);
    return child;
}

int claudio_pty_install_handlers(void) {
    if (installed) { errno = EBUSY; return -1; }
    struct sigaction action = {0};
    action.sa_handler = note_signal;
    sigemptyset(&action.sa_mask);
    for (size_t i = 0; i < sizeof(handled) / sizeof(handled[0]); i++) sigaddset(&action.sa_mask, handled[i]);
    size_t i = 0;
    for (; i < sizeof(handled) / sizeof(handled[0]); i++) {
        if (sigaction(handled[i], &action, &previous[i]) != 0) break;
    }
    if (i != sizeof(handled) / sizeof(handled[0])) {
        while (i > 0) { i--; sigaction(handled[i], &previous[i], NULL); }
        return -1;
    }
    action.sa_handler = SIG_IGN;
    if (sigaction(SIGPIPE, &action, &previous_pipe) != 0) {
        for (size_t j = 0; j < i; j++) sigaction(handled[j], &previous[j], NULL);
        return -1;
    }
    atomic_store_explicit(&signals_pending, 0, memory_order_relaxed);
    // AsyncParsableCommand may call us on a libdispatch worker with signals blocked.
    // The PTY loop must be a delivery thread; restore its original mask on return.
    pthread_sigmask(SIG_UNBLOCK, &action.sa_mask, &previous_mask);
    installed = 1;
    return 0;
}

void claudio_pty_restore_handlers(void) {
    if (!installed) return;
    for (size_t i = 0; i < sizeof(handled) / sizeof(handled[0]); i++) sigaction(handled[i], &previous[i], NULL);
    sigaction(SIGPIPE, &previous_pipe, NULL);
    pthread_sigmask(SIG_SETMASK, &previous_mask, NULL);
    installed = 0;
}

int claudio_pty_take_signal(void) {
    sigset_t set, old;
    sigemptyset(&set);
    for (size_t i = 0; i < sizeof(handled) / sizeof(handled[0]); i++) sigaddset(&set, handled[i]);
    sigprocmask(SIG_BLOCK, &set, &old);
    int result = 0;
    for (size_t i = 0; i < sizeof(handled) / sizeof(handled[0]); i++) {
        unsigned int bit = 1u << handled[i];
        if (atomic_load_explicit(&signals_pending, memory_order_relaxed) & bit) {
            atomic_fetch_and_explicit(&signals_pending, ~bit, memory_order_relaxed);
            result = handled[i]; break;
        }
    }
    sigprocmask(SIG_SETMASK, &old, NULL);
    return result;
}

int claudio_pty_wait(pid_t child, int *code) {
    int status = 0;
    pid_t result = waitpid(child, &status, WNOHANG | WUNTRACED);
    if (result == 0 || (result < 0 && errno == EINTR)) return 0;
    if (result < 0) return -1;
    if (WIFSTOPPED(status)) { *code = WSTOPSIG(status); return 2; }
    if (WIFEXITED(status)) { *code = WEXITSTATUS(status); return 1; }
    if (WIFSIGNALED(status)) { *code = 128 + WTERMSIG(status); return 1; }
    return 0;
}
