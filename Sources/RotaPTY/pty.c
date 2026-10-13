#include "RotaPTY.h"
#include <util.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/wait.h>

/* Keep every operation between fork and exec in C and async-signal-safe. */
pid_t rota_pty_spawn(const char *executable, char *const argv[], char *const envp[],
                     const char *directory, int *master, int *error) {
    int slave, pipefd[2];
    struct winsize size = {.ws_row = 40, .ws_col = 120};
    if (openpty(master, &slave, NULL, NULL, &size) < 0) { *error = errno; return -1; }
    if (pipe(pipefd) < 0) { *error = errno; close(*master); close(slave); return -1; }
    fcntl(pipefd[1], F_SETFD, FD_CLOEXEC);
    int limit = getdtablesize();
    pid_t pid = fork();
    if (pid == 0) {
        close(pipefd[0]);
        close(*master);
        if (setsid() < 0 || ioctl(slave, TIOCSCTTY, 0) < 0 || chdir(directory) < 0)
            goto failed;
        if (dup2(slave, 0) < 0 || dup2(slave, 1) < 0 || dup2(slave, 2) < 0) goto failed;
        for (int fd = 3; fd < limit; fd++) if (fd != pipefd[1]) close(fd);
        execve(executable, argv, envp);
failed:;
        int failure = errno;
        (void)write(pipefd[1], &failure, sizeof(failure));
        _exit(127);
    }
    close(slave);
    close(pipefd[1]);
    if (pid < 0) { *error = errno; close(pipefd[0]); close(*master); return -1; }
    int failure = 0;
    ssize_t count;
    do { count = read(pipefd[0], &failure, sizeof(failure)); } while (count < 0 && errno == EINTR);
    close(pipefd[0]);
    if (count != 0) {
        *error = failure ? failure : EIO;
        close(*master);
        int status; while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
        return -1;
    }
    return pid;
}
