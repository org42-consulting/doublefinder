#ifndef DF_PTY_H
#define DF_PTY_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

// Spawns `executable` on the slave side of a new pty.
// On success: returns child pid, writes master fd to *master_fd.
// On error:   returns -1, sets errno.
// argv and envp must be NULL-terminated. argv[0] is the program name.
pid_t df_spawn_pty(int *master_fd,
                   const char *executable,
                   char *const argv[],
                   char *const envp[]);

#ifdef __cplusplus
}
#endif

#endif
