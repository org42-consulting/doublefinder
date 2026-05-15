#include "df_pty.h"

#include <util.h>      // forkpty
#include <unistd.h>    // execve, _exit
#include <errno.h>

pid_t df_spawn_pty(int *master_fd,
                   const char *executable,
                   char *const argv[],
                   char *const envp[]) {
    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, NULL);
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
        // child — execute and never return
        execve(executable, argv, envp);
        _exit(127); // exec failed
    }
    *master_fd = master;
    return pid;
}
