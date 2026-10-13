#ifndef ROTA_PTY_H
#define ROTA_PTY_H
#include <sys/types.h>
pid_t rota_pty_spawn(const char *executable, char *const argv[], char *const envp[],
                     const char *directory, int *master, int *error);
#endif
