#include <errno.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static int become_root(void) {
    if (setgid(0) != 0 || setuid(0) != 0) {
        fprintf(stderr, "Could not switch to root privileges: %s\n", strerror(errno));
        return 77;
    }

    return 0;
}

static int run_command(char *const arguments[]) {
    char *const environment[] = {
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
        NULL
    };

    pid_t pid = 0;
    int spawn_result = posix_spawn(&pid, arguments[0], NULL, NULL, arguments, environment);
    if (spawn_result != 0) {
        fprintf(stderr, "Could not run command: %s\n", strerror(spawn_result));
        return 78;
    }

    int status = 0;
    if (waitpid(pid, &status, 0) == -1) {
        fprintf(stderr, "Could not wait for pmset: %s\n", strerror(errno));
        return 79;
    }

    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }

    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }

    return 80;
}

static int run_pmset_disablesleep(const char *value) {
    int root_result = become_root();
    if (root_result != 0) {
        return root_result;
    }

    char *const arguments[] = {
        "/usr/bin/pmset",
        "-a",
        "disablesleep",
        (char *)value,
        NULL
    };

    return run_command(arguments);
}

static int run_pmset_display_sleep_now(void) {
    int root_result = become_root();
    if (root_result != 0) {
        return root_result;
    }

    char *const arguments[] = {
        "/usr/bin/pmset",
        "displaysleepnow",
        NULL
    };

    return run_command(arguments);
}

int main(int argc, char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s enable|disable|display-sleep\n", argv[0]);
        return 64;
    }

    if (strcmp(argv[1], "enable") == 0) {
        return run_pmset_disablesleep("1");
    }

    if (strcmp(argv[1], "disable") == 0) {
        return run_pmset_disablesleep("0");
    }

    if (strcmp(argv[1], "display-sleep") == 0) {
        return run_pmset_display_sleep_now();
    }

    fprintf(stderr, "Invalid command. Use enable, disable, or display-sleep.\n");
    return 64;
}
