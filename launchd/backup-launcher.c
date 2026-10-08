/* sts-backup-launcher: launchd starts this, it runs the backup script and passes its exit status through. */
/* Exists so the disk-access grant lands on this binary, not on /bin/bash (TCC credits the spawning process). */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>
#include <spawn.h>

#ifndef STS_SCRIPT
#error "STS_SCRIPT must be defined at compile time"
#endif

extern char **environ;

int main(void)
{
    char *argv[] = { "/bin/bash", STS_SCRIPT, "backup", NULL };
    pid_t pid;
    int rc, status;

    rc = posix_spawn(&pid, "/bin/bash", NULL, NULL, argv, environ);
    if (rc != 0) {
        fprintf(stderr, "sts-backup-launcher: cannot spawn /bin/bash: %d\n", rc);
        return 127;
    }

    if (waitpid(pid, &status, 0) < 0) {
        perror("sts-backup-launcher: waitpid");
        return 127;
    }

    if (WIFEXITED(status))   return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 1;
}
