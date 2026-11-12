// MacEasyTierHelper: 常驻 root 的 launchd 守护进程，负责启动/停止 TUN 模式的 easytier-core。
//
// 取代旧方案（每次启动都经 Authorization Services 弹窗 + 每个网络一个 helper）：
//   - 只需一次管理员授权安装；之后 App 通过 Unix socket 发命令，启动/停止无需密码。
//   - 单进程管理多个 core；STOP 在 core 真正退出后才应答，App 无需轮询。
//   - App 退出/崩溃（owner pid 消失）时自动结束对应 core。
//   - 守护进程退出（launchctl bootout / 关机）时结束所有 core。
//
// 用法（由 launchd 拉起）：
//   MacEasyTierHelper --socket <path> --core <easytier-core> --uid <allowed uid> --tag <build tag>
//
// 协议：一行一个请求，字段以 TAB 分隔（路径可能含空格），请求/应答均以 '\n' 结束。
//   PING                                              -> OK\t<proto>\t<tag>
//   START\t<id>\t<rpc-port>\t<owner-pid>\t<level>\t<compression|->\t<config>\t<log>
//                                                     -> OK\t<pid> | ERR\t<message>
//   STOP\t<id>                                        -> OK | ERR\t<message>   （core 退出后才应答）
//   STOPALL                                           -> OK
//   STATUS                                            -> OK\t<proto>\t<tag> 后接若干行，以 END 结束
//                                                        CORE\t<id>\t<pid>\t<footprint>\t<started>
//                                                        EXIT\t<id>\t<status>\t<time>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define PROTOCOL_VERSION 2
#define MAX_CORES 16
#define MAX_EXITS 16
#define MAX_ID 48
#define MAX_PATH_LEN 1024
#define MAX_REQUEST 4096
#define STOP_GRACE_MS 1500
#define STOP_KILL_WAIT_MS 1500

typedef struct {
    int used;
    char id[MAX_ID];
    pid_t pid;
    pid_t owner;
    time_t started;
    int stopping;
    long long stop_deadline_ms;
    int killed;
    int waiter_fds[4];
    int waiter_count;
} core_t;

typedef struct {
    int used;
    char id[MAX_ID];
    int status;
    time_t when;
} exit_t;

static core_t g_cores[MAX_CORES];
static exit_t g_exits[MAX_EXITS];
static const char *g_socket_path = NULL;
static const char *g_core_path = NULL;
static const char *g_tag = "dev";
static uid_t g_allowed_uid = 0;
static volatile sig_atomic_t g_quit = 0;
static int g_wake_pipe[2] = {-1, -1};

static void logf_(const char *format, ...) {
    va_list args;
    va_start(args, format);
    time_t now = time(NULL);
    char stamp[32];
    struct tm tm_value;
    localtime_r(&now, &tm_value);
    strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &tm_value);
    fprintf(stderr, "%s helper: ", stamp);
    vfprintf(stderr, format, args);
    fputc('\n', stderr);
    fflush(stderr);
    va_end(args);
}

static long long now_ms(void) {
    struct timeval value;
    gettimeofday(&value, NULL);
    return (long long)value.tv_sec * 1000 + value.tv_usec / 1000;
}

static void on_signal(int number) {
    if (number == SIGTERM || number == SIGINT) {
        g_quit = 1;
    }
    if (g_wake_pipe[1] >= 0) {
        char byte = 1;
        (void)!write(g_wake_pipe[1], &byte, 1);
    }
}

static void set_cloexec(int fd) {
    fcntl(fd, F_SETFD, fcntl(fd, F_GETFD, 0) | FD_CLOEXEC);
}

static void set_nonblock(int fd) {
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
}

static void reply(int fd, const char *format, ...) {
    char buffer[MAX_REQUEST];
    va_list args;
    va_start(args, format);
    int length = vsnprintf(buffer, sizeof(buffer) - 1, format, args);
    va_end(args);
    if (length < 0) {
        return;
    }
    if (length > (int)sizeof(buffer) - 2) {
        length = (int)sizeof(buffer) - 2;
    }
    buffer[length++] = '\n';
    ssize_t offset = 0;
    while (offset < length) {
        ssize_t written = write(fd, buffer + offset, (size_t)(length - offset));
        if (written < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN) {
                usleep(1000);
                continue;
            }
            return;
        }
        offset += written;
    }
}

// MARK: - Validation

static int valid_id(const char *value) {
    size_t length = strlen(value);
    if (length == 0 || length >= MAX_ID) return 0;
    for (size_t i = 0; i < length; i++) {
        if (!isalnum((unsigned char)value[i]) && value[i] != '-') return 0;
    }
    return 1;
}

static int valid_token(const char *value) {
    size_t length = strlen(value);
    if (length == 0 || length > 16) return 0;
    for (size_t i = 0; i < length; i++) {
        if (!isalnum((unsigned char)value[i])) return 0;
    }
    return 1;
}

static int safe_path(const char *path) {
    if (path[0] != '/' || strlen(path) >= MAX_PATH_LEN) return 0;
    if (strstr(path, "/../") != NULL || strstr(path, "/./") != NULL) return 0;
    size_t length = strlen(path);
    if (length >= 3 && strcmp(path + length - 3, "/..") == 0) return 0;
    return 1;
}

// 配置文件必须是调用者自己的普通文件（非符号链接，且别人不可写），防止借 root 读取任意文件。
static int check_config(const char *path, char *error, size_t error_size) {
    struct stat info;
    if (!safe_path(path) || lstat(path, &info) != 0) {
        snprintf(error, error_size, "config not found");
        return 0;
    }
    if (!S_ISREG(info.st_mode) || info.st_uid != g_allowed_uid || (info.st_mode & (S_IWGRP | S_IWOTH))) {
        snprintf(error, error_size, "config rejected (owner/mode)");
        return 0;
    }
    return 1;
}

static int open_log(const char *path, char *error, size_t error_size) {
    if (!safe_path(path)) {
        snprintf(error, error_size, "bad log path");
        return -1;
    }
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0600);
    if (fd < 0) {
        snprintf(error, error_size, "cannot open log: %s", strerror(errno));
        return -1;
    }
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode)) {
        close(fd);
        snprintf(error, error_size, "bad log file");
        return -1;
    }
    (void)!fchown(fd, g_allowed_uid, (gid_t)-1);
    return fd;
}

// MARK: - Core table

static core_t *find_core(const char *id) {
    for (int i = 0; i < MAX_CORES; i++) {
        if (g_cores[i].used && strcmp(g_cores[i].id, id) == 0) return &g_cores[i];
    }
    return NULL;
}

static core_t *find_core_by_pid(pid_t pid) {
    for (int i = 0; i < MAX_CORES; i++) {
        if (g_cores[i].used && g_cores[i].pid == pid) return &g_cores[i];
    }
    return NULL;
}

static void record_exit(const core_t *core, int status) {
    int slot = 0;
    time_t oldest = 0;
    for (int i = 0; i < MAX_EXITS; i++) {
        if (!g_exits[i].used) {
            slot = i;
            oldest = 0;
            break;
        }
        if (oldest == 0 || g_exits[i].when < oldest) {
            oldest = g_exits[i].when;
            slot = i;
        }
    }
    g_exits[slot].used = 1;
    snprintf(g_exits[slot].id, sizeof(g_exits[slot].id), "%s", core->id);
    g_exits[slot].status = WIFEXITED(status) ? WEXITSTATUS(status) : -WTERMSIG(status);
    g_exits[slot].when = time(NULL);
}

static void finish_core(core_t *core, int status) {
    logf_("core %s (pid %d) exited status=%d", core->id, (int)core->pid, status);
    if (!core->stopping) {
        record_exit(core, status);
    }
    for (int i = 0; i < core->waiter_count; i++) {
        reply(core->waiter_fds[i], "OK");
        close(core->waiter_fds[i]);
    }
    memset(core, 0, sizeof(*core));
}

static void reap_children(void) {
    for (;;) {
        int status = 0;
        pid_t pid = waitpid(-1, &status, WNOHANG);
        if (pid <= 0) return;
        core_t *core = find_core_by_pid(pid);
        if (core != NULL) finish_core(core, status);
    }
}

static void begin_stop(core_t *core) {
    if (core->stopping) return;
    core->stopping = 1;
    core->stop_deadline_ms = now_ms() + STOP_GRACE_MS;
    kill(core->pid, SIGTERM);
}

static void service_stops(void) {
    long long now = now_ms();
    for (int i = 0; i < MAX_CORES; i++) {
        core_t *core = &g_cores[i];
        if (!core->used) continue;

        if (!core->stopping && core->owner > 1 && kill(core->owner, 0) != 0 && errno == ESRCH) {
            logf_("owner %d of core %s is gone, stopping", (int)core->owner, core->id);
            begin_stop(core);
        }
        if (core->stopping && !core->killed && now >= core->stop_deadline_ms) {
            kill(core->pid, SIGKILL);
            core->killed = 1;
            core->stop_deadline_ms = now + STOP_KILL_WAIT_MS;
        } else if (core->stopping && core->killed && now >= core->stop_deadline_ms) {
            // SIGKILL 之后仍未被回收（不可中断状态），放弃等待，避免阻塞 App。
            for (int w = 0; w < core->waiter_count; w++) {
                reply(core->waiter_fds[w], "ERR\tcore did not exit");
                close(core->waiter_fds[w]);
            }
            core->waiter_count = 0;
            core->stop_deadline_ms = now + 60000;
        }
    }
}

static unsigned long long footprint(pid_t pid) {
    struct rusage_info_v2 usage;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&usage) != 0) return 0;
    return usage.ri_phys_footprint;
}

// MARK: - Commands

static void do_start(int client, char **fields, int count) {
    // START id port owner level compression config log
    if (count != 8) {
        reply(client, "ERR\tbad arguments");
        return;
    }
    const char *id = fields[1];
    int port = atoi(fields[2]);
    pid_t owner = (pid_t)atoi(fields[3]);
    const char *level = fields[4];
    const char *compression = fields[5];
    const char *config = fields[6];
    const char *log_path = fields[7];

    char error[160] = {0};
    if (!valid_id(id) || port < 1024 || port > 65535 || !valid_token(level) ||
        (strcmp(compression, "-") != 0 && !valid_token(compression))) {
        reply(client, "ERR\tinvalid arguments");
        return;
    }
    if (find_core(id) != NULL) {
        reply(client, "ERR\talready running");
        return;
    }
    if (!check_config(config, error, sizeof(error))) {
        reply(client, "ERR\t%s", error);
        return;
    }
    core_t *slot = NULL;
    for (int i = 0; i < MAX_CORES; i++) {
        if (!g_cores[i].used) {
            slot = &g_cores[i];
            break;
        }
    }
    if (slot == NULL) {
        reply(client, "ERR\ttoo many cores");
        return;
    }
    int log_fd = open_log(log_path, error, sizeof(error));
    if (log_fd < 0) {
        reply(client, "ERR\t%s", error);
        return;
    }

    char rpc_portal[48];
    snprintf(rpc_portal, sizeof(rpc_portal), "127.0.0.1:%d", port);
    char *argv[16];
    int argc = 0;
    argv[argc++] = (char *)g_core_path;
    argv[argc++] = "--disable-env-parsing";
    argv[argc++] = "--config-file";
    argv[argc++] = (char *)config;
    argv[argc++] = "--rpc-portal";
    argv[argc++] = rpc_portal;
    argv[argc++] = "--console-log-level";
    argv[argc++] = (char *)level;
    if (strcmp(compression, "-") != 0) {
        argv[argc++] = "--compression";
        argv[argc++] = (char *)compression;
    }
    argv[argc] = NULL;

    // 用 CLOEXEC 管道回传 exec 失败原因：exec 成功则管道被关闭，父进程读到 EOF，几乎零延迟。
    int status_pipe[2];
    if (pipe(status_pipe) != 0) {
        close(log_fd);
        reply(client, "ERR\tpipe failed");
        return;
    }
    set_cloexec(status_pipe[0]);
    set_cloexec(status_pipe[1]);

    pid_t child = fork();
    if (child < 0) {
        close(log_fd);
        close(status_pipe[0]);
        close(status_pipe[1]);
        reply(client, "ERR\tfork failed");
        return;
    }
    if (child == 0) {
        sigset_t empty;
        sigemptyset(&empty);
        sigprocmask(SIG_SETMASK, &empty, NULL);
        signal(SIGCHLD, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGPIPE, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        int null_fd = open("/dev/null", O_RDONLY);
        if (null_fd >= 0) dup2(null_fd, STDIN_FILENO);
        dup2(log_fd, STDOUT_FILENO);
        dup2(log_fd, STDERR_FILENO);
        if (chdir("/var/empty") != 0) (void)!chdir("/");
        char *envp[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=/var/root", NULL};
        execve(g_core_path, argv, envp);
        int code = errno;
        (void)!write(status_pipe[1], &code, sizeof(code));
        _exit(127);
    }

    close(log_fd);
    close(status_pipe[1]);
    int exec_errno = 0;
    ssize_t got;
    do {
        got = read(status_pipe[0], &exec_errno, sizeof(exec_errno));
    } while (got < 0 && errno == EINTR);
    close(status_pipe[0]);

    if (got > 0) {
        int status = 0;
        waitpid(child, &status, 0);
        reply(client, "ERR\tcannot exec core: %s", strerror(exec_errno));
        return;
    }

    memset(slot, 0, sizeof(*slot));
    slot->used = 1;
    snprintf(slot->id, sizeof(slot->id), "%s", id);
    slot->pid = child;
    slot->owner = owner;
    slot->started = time(NULL);
    logf_("core %s started pid=%d owner=%d", id, (int)child, (int)owner);
    reply(client, "OK\t%d", (int)child);
}

static int do_stop(int client, const char *id) {
    core_t *core = find_core(id);
    if (core == NULL) {
        reply(client, "OK");
        return 0;
    }
    if (core->waiter_count >= 4) {
        reply(client, "ERR\tbusy");
        return 0;
    }
    begin_stop(core);
    core->waiter_fds[core->waiter_count++] = client;
    return 1; // 保留连接，core 退出后再应答
}

static void do_status(int client) {
    reply(client, "OK\t%d\t%s", PROTOCOL_VERSION, g_tag);
    for (int i = 0; i < MAX_CORES; i++) {
        if (!g_cores[i].used) continue;
        reply(client, "CORE\t%s\t%d\t%llu\t%ld", g_cores[i].id, (int)g_cores[i].pid,
              footprint(g_cores[i].pid), (long)g_cores[i].started);
    }
    for (int i = 0; i < MAX_EXITS; i++) {
        if (!g_exits[i].used) continue;
        reply(client, "EXIT\t%s\t%d\t%ld", g_exits[i].id, g_exits[i].status, (long)g_exits[i].when);
        g_exits[i].used = 0;
    }
    reply(client, "END");
}

static int split_fields(char *line, char **fields, int max) {
    int count = 0;
    char *cursor = line;
    while (count < max) {
        fields[count++] = cursor;
        char *tab = strchr(cursor, '\t');
        if (tab == NULL) break;
        *tab = '\0';
        cursor = tab + 1;
    }
    return count;
}

// 返回 1 表示 client 连接被保留（等待 STOP 完成）。
static int handle_client(int client) {
    uid_t uid = (uid_t)-1;
    gid_t gid = (gid_t)-1;
    if (getpeereid(client, &uid, &gid) != 0 || (uid != g_allowed_uid && uid != 0)) {
        reply(client, "ERR\tnot authorized");
        return 0;
    }

    struct timeval timeout = {1, 0};
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    char request[MAX_REQUEST];
    size_t length = 0;
    while (length < sizeof(request) - 1) {
        ssize_t got = read(client, request + length, sizeof(request) - 1 - length);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) break;
        length += (size_t)got;
        if (memchr(request, '\n', length) != NULL) break;
    }
    request[length] = '\0';
    char *newline = strchr(request, '\n');
    if (newline != NULL) *newline = '\0';
    if (length == 0 || (newline == NULL && length >= sizeof(request) - 1)) {
        reply(client, "ERR\tbad request");
        return 0;
    }

    char *fields[10];
    int count = split_fields(request, fields, 10);
    const char *command = fields[0];

    if (strcmp(command, "PING") == 0) {
        reply(client, "OK\t%d\t%s", PROTOCOL_VERSION, g_tag);
    } else if (strcmp(command, "START") == 0) {
        do_start(client, fields, count);
    } else if (strcmp(command, "STOP") == 0 && count == 2) {
        return do_stop(client, fields[1]);
    } else if (strcmp(command, "STOPALL") == 0) {
        for (int i = 0; i < MAX_CORES; i++) {
            if (g_cores[i].used) begin_stop(&g_cores[i]);
        }
        reply(client, "OK");
    } else if (strcmp(command, "STATUS") == 0) {
        do_status(client);
    } else {
        reply(client, "ERR\tunknown command");
    }
    return 0;
}

// MARK: - Socket

static int create_socket(const char *path) {
    unlink(path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    address.sun_len = (unsigned char)sizeof(address);
    if (strlen(path) >= sizeof(address.sun_path)) {
        close(fd);
        return -1;
    }
    strncpy(address.sun_path, path, sizeof(address.sun_path) - 1);

    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        return -1;
    }
    // 访问控制在 getpeereid 里做，socket 本身允许任意本地用户 connect。
    chmod(path, 0666);
    if (listen(fd, 16) != 0) {
        close(fd);
        return -1;
    }
    set_cloexec(fd);
    set_nonblock(fd);
    return fd;
}

static void stop_all_and_wait(void) {
    for (int i = 0; i < MAX_CORES; i++) {
        if (g_cores[i].used) begin_stop(&g_cores[i]);
    }
    long long deadline = now_ms() + STOP_GRACE_MS + STOP_KILL_WAIT_MS;
    for (;;) {
        reap_children();
        service_stops();
        int alive = 0;
        for (int i = 0; i < MAX_CORES; i++) {
            if (g_cores[i].used) alive++;
        }
        if (alive == 0 || now_ms() > deadline) break;
        usleep(20 * 1000);
    }
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--socket") == 0 && i + 1 < argc) {
            g_socket_path = argv[++i];
        } else if (strcmp(argv[i], "--core") == 0 && i + 1 < argc) {
            g_core_path = argv[++i];
        } else if (strcmp(argv[i], "--uid") == 0 && i + 1 < argc) {
            g_allowed_uid = (uid_t)strtoul(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--tag") == 0 && i + 1 < argc) {
            g_tag = argv[++i];
        }
    }
    if (g_socket_path == NULL || g_core_path == NULL) {
        fprintf(stderr, "usage: MacEasyTierHelper --socket <path> --core <easytier-core> --uid <uid> --tag <tag>\n");
        return 2;
    }
    if (access(g_core_path, X_OK) != 0) {
        fprintf(stderr, "helper: core %s is not executable: %s\n", g_core_path, strerror(errno));
        return 3;
    }

    if (pipe(g_wake_pipe) != 0) return 4;
    set_cloexec(g_wake_pipe[0]);
    set_cloexec(g_wake_pipe[1]);
    set_nonblock(g_wake_pipe[0]);
    set_nonblock(g_wake_pipe[1]);

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = on_signal;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_RESTART;
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGCHLD, &action, NULL);
    signal(SIGPIPE, SIG_IGN);
    signal(SIGHUP, SIG_IGN);

    int listen_fd = create_socket(g_socket_path);
    if (listen_fd < 0) {
        fprintf(stderr, "helper: cannot create socket %s: %s\n", g_socket_path, strerror(errno));
        return 5;
    }
    logf_("ready proto=%d tag=%s uid=%d socket=%s", PROTOCOL_VERSION, g_tag, (int)g_allowed_uid, g_socket_path);

    while (!g_quit) {
        struct pollfd fds[2] = {
            {.fd = listen_fd, .events = POLLIN, .revents = 0},
            {.fd = g_wake_pipe[0], .events = POLLIN, .revents = 0},
        };
        poll(fds, 2, 250);

        if (fds[1].revents & POLLIN) {
            char drain[64];
            while (read(g_wake_pipe[0], drain, sizeof(drain)) > 0) {
            }
        }
        reap_children();

        if (fds[0].revents & POLLIN) {
            for (;;) {
                int client = accept(listen_fd, NULL, NULL);
                if (client < 0) break;
                set_cloexec(client);
                // accept 出来的 fd 在 BSD 上会继承 O_NONBLOCK，这里改回阻塞并依靠 SO_RCVTIMEO 兜底。
                fcntl(client, F_SETFL, fcntl(client, F_GETFL, 0) & ~O_NONBLOCK);
                int keep = handle_client(client);
                if (!keep) close(client);
            }
        }
        service_stops();
    }

    logf_("shutting down");
    stop_all_and_wait();
    close(listen_fd);
    unlink(g_socket_path);
    return 0;
}
