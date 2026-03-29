/*
 * launcher.c — compiled entry point for AudioTranscribe.app
 *
 * macOS LaunchServices requires a Mach-O binary as CFBundleExecutable;
 * a shell script won't launch from Finder or `open`.
 *
 * This binary resolves paths relative to its own location, sets up the
 * Python environment, and spawns the embedded Python as a child process.
 * The parent stays alive so macOS keeps the LaunchServices/window-server
 * session that allows rumps to create a status-bar item.
 *
 * Build:
 *   clang -Wall -o AudioTranscribe packaging/launcher.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <libgen.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>

#define PATH_MAX_LEN 4096

/* Forward signals to child so Quit / SIGTERM propagate cleanly */
static pid_t g_child_pid = 0;

static void forward_signal(int sig)
{
    if (g_child_pid > 0)
        kill(g_child_pid, sig);
}

int main(int argc, char *argv[])
{
    /* Resolve the real path of this binary */
    char exec_path[PATH_MAX_LEN];
    uint32_t exec_path_size = sizeof(exec_path);
    if (_NSGetExecutablePath(exec_path, &exec_path_size) != 0) {
        fprintf(stderr, "AudioTranscribe: failed to resolve executable path\n");
        return 1;
    }

    /* MacOS/  (dirname of this binary) */
    char macos_dir[PATH_MAX_LEN];
    strncpy(macos_dir, exec_path, sizeof(macos_dir));
    dirname_r(macos_dir, macos_dir);

    /* Contents/ */
    char contents_dir[PATH_MAX_LEN];
    snprintf(contents_dir, sizeof(contents_dir), "%s/..", macos_dir);

    /* Contents/Resources/ */
    char resources_dir[PATH_MAX_LEN];
    snprintf(resources_dir, sizeof(resources_dir), "%s/Resources", contents_dir);

    /* Embedded Python framework */
    char python_fw[PATH_MAX_LEN];
    snprintf(python_fw, sizeof(python_fw),
             "%s/python/Python.framework/Versions/3.11", resources_dir);

    /* Python binary */
    char python_bin[PATH_MAX_LEN];
    snprintf(python_bin, sizeof(python_bin), "%s/bin/python3", python_fw);

    /* App source root */
    char app_root[PATH_MAX_LEN];
    snprintf(app_root, sizeof(app_root), "%s/app", resources_dir);

    /* Entry point */
    char main_py[PATH_MAX_LEN];
    snprintf(main_py, sizeof(main_py), "%s/service/main.py", app_root);

    /* Set environment */
    setenv("PYTHONHOME",              python_fw,  1);
    setenv("PYTHONPATH",              app_root,   1);
    setenv("PYTHONDONTWRITEBYTECODE", "1",        1);

    /* Include Homebrew so ffmpeg (required by mlx_whisper) is found */
    char path_env[PATH_MAX_LEN * 2];
    snprintf(path_env, sizeof(path_env),
             "%s/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
             python_fw);
    setenv("PATH", path_env, 1);

    /* Fork — child runs Python, parent waits.
     * Keeping the parent alive preserves the LaunchServices session
     * so the child process can create NSStatusBar items (menu bar icon). */
    pid_t pid = fork();
    if (pid < 0) {
        perror("AudioTranscribe: fork failed");
        return 1;
    }

    if (pid == 0) {
        /* Child: exec Python */
        char *new_argv[] = { python_bin, main_py, NULL };
        execv(python_bin, new_argv);
        perror("AudioTranscribe: execv failed");
        _exit(1);
    }

    /* Parent: forward signals to child, then wait */
    g_child_pid = pid;
    signal(SIGTERM, forward_signal);
    signal(SIGINT,  forward_signal);
    signal(SIGHUP,  forward_signal);

    int status = 0;
    waitpid(pid, &status, 0);

    if (WIFEXITED(status))
        return WEXITSTATUS(status);
    return 1;
}
