/*
 * sts-backup-launcher
 *
 * A launchd job that runs a shell script is, to macOS privacy protection,
 * just /bin/bash. Granting a launchd job access to a removable volume
 * therefore means granting it to /bin/bash - and so to every shell script
 * that ever runs on the machine.
 *
 * This exists so the grant has somewhere narrower to land. launchd starts
 * this binary; this binary starts bash as a child. TCC attributes a child
 * to the responsible process that spawned it, so the permission is held by
 * this one ad-hoc-signed binary rather than by the system shell.
 *
 * It does nothing else: no arguments are taken from the environment, the
 * script path is fixed at compile time, and the child's exit status is
 * propagated unchanged so launchd still sees the real exit code.
 */

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
