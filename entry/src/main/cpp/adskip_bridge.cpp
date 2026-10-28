#include <napi/native_api.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <thread>
#include <atomic>
#include <string>
#include <vector>

static std::atomic<bool> g_bridgeStarted{false};
static std::atomic<bool> g_daemonEnabled{true};
static std::atomic<bool> g_daemonRunning{false};
static std::atomic<int> g_lastSkipCount{0};
static std::atomic<int> g_lastPid{0};
static std::atomic<long long> g_lastHeartbeatMs{0};
static std::atomic<long long> g_bridgeStartMs{0};
static std::atomic<bool> g_pendingReset{false};
static int g_lastLoggedSkipCount = 0;
static bool g_readyLogged = false;

static const char *kFilesDir = "/data/storage/el2/base/haps/entry/files";
static const char *kStatusFile = "/data/storage/el2/base/haps/entry/files/adskip_status.json";
static const char *kControlFile = "/data/storage/el2/base/haps/entry/files/adskip_control.txt";
static const char *kSkipLogFile = "/data/storage/el2/base/haps/entry/files/adskip_skip.log";

static long long now_epoch_ms() {
    struct timeval tv{};
    gettimeofday(&tv, nullptr);
    return (long long)tv.tv_sec * 1000LL + (long long)(tv.tv_usec / 1000);
}

static std::string now_time_str() {
    struct timeval tv{};
    gettimeofday(&tv, nullptr);
    struct tm tm_info{};
    localtime_r(&tv.tv_sec, &tm_info);
    char buf[32];
    snprintf(buf, sizeof(buf), "%02d:%02d:%02d.%03d",
             tm_info.tm_hour, tm_info.tm_min, tm_info.tm_sec, (int)(tv.tv_usec / 1000));
    return std::string(buf);
}

static void write_file_str(const char *path, const std::string &content, bool append) {
    int flags = O_CREAT | O_WRONLY | (append ? O_APPEND : O_TRUNC);
    int fd = open(path, flags, 0666);
    if (fd >= 0) {
        write(fd, content.data(), content.size());
        close(fd);
    }
}

static std::string read_file_str(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return "";
    }
    char buf[512];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) {
        return "";
    }
    buf[n] = '\0';
    return std::string(buf, n);
}

static void sync_status_from_disk() {
    std::string st = read_file_str(kStatusFile);
    if (st.empty()) {
        return;
    }
    if (st.find("\"running\":true") != std::string::npos) {
        g_daemonRunning.store(true);
    } else if (st.find("\"running\":false") != std::string::npos) {
        g_daemonRunning.store(false);
    }
    size_t scPos = st.find("\"skippedCount\":");
    if (scPos != std::string::npos) {
        int savedCount = atoi(st.c_str() + scPos + 15);
        if (savedCount > g_lastSkipCount.load()) {
            g_lastSkipCount.store(savedCount);
            g_lastLoggedSkipCount = savedCount;
        }
    }
    size_t pidPos = st.find("\"pid\":");
    if (pidPos != std::string::npos) {
        int savedPid = atoi(st.c_str() + pidPos + 6);
        if (savedPid > 0) {
            g_lastPid.store(savedPid);
        }
    }
}

static void write_status_json() {
    sync_status_from_disk();
    std::string runningStr = g_daemonRunning.load() ? "true" : "false";
    std::string enabledStr = g_daemonEnabled.load() ? "true" : "false";
    std::string json = "{\"running\":" + runningStr +
                       ",\"enabled\":" + enabledStr +
                       ",\"skippedCount\":" + std::to_string(g_lastSkipCount.load()) +
                       ",\"pid\":" + std::to_string(g_lastPid.load()) + "}";
    write_file_str(kStatusFile, json, false);
}

static void ensure_shared_permissions() {
    chmod(kFilesDir, 0777);

    const char *files[] = {
        "/data/storage/el2/base/haps/entry/files/vpn_dns_trace.log",
        kSkipLogFile,
        kStatusFile,
        kControlFile,
        "/data/storage/el2/base/haps/entry/files/adskip_daemon.sh"
    };
    for (int i = 0; i < 5; ++i) {
        int fd = open(files[i], O_CREAT | O_RDWR, 0666);
        if (fd >= 0) {
            close(fd);
        }
        chmod(files[i], i == 4 ? 0777 : 0666);
    }

    std::string ctrl = read_file_str(kControlFile);
    if (ctrl.find("PAUSED") != std::string::npos || ctrl.find("DISABLED") != std::string::npos) {
        g_daemonEnabled.store(false);
    } else {
        g_daemonEnabled.store(true);
        if (ctrl.empty()) {
            write_file_str(kControlFile, "ENABLED\n", false);
        }
    }

    sync_status_from_disk();
}

static std::vector<std::string> split_pipe(const std::string &s) {
    std::vector<std::string> out;
    size_t start = 0;
    while (true) {
        size_t pos = s.find('|', start);
        if (pos == std::string::npos) {
            out.push_back(s.substr(start));
            break;
        }
        out.push_back(s.substr(start, pos - start));
        start = pos + 1;
    }
    return out;
}

static void bridge_server_loop() {
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        return;
    }
    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(18688);
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");

    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(server_fd);
        return;
    }
    if (listen(server_fd, 8) < 0) {
        close(server_fd);
        return;
    }

    while (true) {
        struct sockaddr_in client_addr{};
        socklen_t client_len = sizeof(client_addr);
        int client_fd = accept(server_fd, (struct sockaddr *)&client_addr, &client_len);
        if (client_fd < 0) {
            continue;
        }

        const char *greet = "220 OK\r\n";
        send(client_fd, greet, strlen(greet), 0);

        char buf[1024];
        std::string payload;
        for (int step = 0; step < 8; ++step) {
            memset(buf, 0, sizeof(buf));
            ssize_t n = recv(client_fd, buf, sizeof(buf) - 1, 0);
            if (n <= 0) {
                break;
            }
            std::string cmd(buf, n);
            if (cmd.rfind("USER", 0) == 0) {
                const char *r = "331 OK\r\n";
                send(client_fd, r, strlen(r), 0);
            } else if (cmd.rfind("PASS", 0) == 0) {
                const char *r = "230 OK\r\n";
                send(client_fd, r, strlen(r), 0);
            } else if (cmd.rfind("PASV", 0) == 0) {
                const char *r = "227 Entering Passive Mode (127,0,0,1,72,240)\r\n";
                send(client_fd, r, strlen(r), 0);
            } else if (cmd.rfind("DELE ", 0) == 0 || cmd.rfind("RETR ", 0) == 0) {
                payload = cmd.substr(5);
                while (!payload.empty() && (payload.back() == '\r' || payload.back() == '\n')) {
                    payload.pop_back();
                }
                if (g_daemonEnabled.load()) {
                    if (g_pendingReset.exchange(false)) {
                        const char *r = "250 RESET\r\n";
                        send(client_fd, r, strlen(r), 0);
                    } else {
                        const char *r = "250 ENABLED\r\n";
                        send(client_fd, r, strlen(r), 0);
                    }
                } else {
                    const char *r = "550 PAUSED\r\n";
                    send(client_fd, r, strlen(r), 0);
                    break;
                }
            } else if (cmd.rfind("QUIT", 0) == 0) {
                const char *r = "221 OK\r\n";
                send(client_fd, r, strlen(r), 0);
                break;
            } else {
                const char *r = "200 OK\r\n";
                send(client_fd, r, strlen(r), 0);
            }
        }
        close(client_fd);

        if (!payload.empty()) {
            g_lastHeartbeatMs.store(now_epoch_ms());
            std::vector<std::string> parts = split_pipe(payload);
            if (parts.size() >= 4 && (parts[0] == "STATUS" || parts[0] == "READY")) {
                g_daemonRunning.store(true);
                int curCount = atoi(parts[2].c_str());
                int curPid = atoi(parts[3].c_str());
                if (curCount > g_lastSkipCount.load()) {
                    g_lastSkipCount.store(curCount);
                }
                if (curPid > 0) {
                    g_lastPid.store(curPid);
                }
                write_status_json();

                if (!g_readyLogged) {
                    g_readyLogged = true;
                    std::string logLine = now_time_str() + " [SKIP-SVC] 🚀 开屏广告自动跳过守护服务已就绪 (PID=" +
                                          parts[3] + ")\n";
                    write_file_str(kSkipLogFile, logLine, true);
                }

                if (parts.size() >= 8 && curCount > g_lastLoggedSkipCount && !parts[5].empty()) {
                    g_lastLoggedSkipCount = curCount;
                    std::string logLine = parts[4] + " [SKIP] ⚡ 成功自动跳过开屏广告! 应用=" + parts[5] +
                                          " | 触控坐标=(" + parts[6] + ") | 区域=" + parts[7] + "\n";
                    write_file_str(kSkipLogFile, logLine, true);
                }
            } else if (parts.size() >= 7 && parts[0] == "SKIP") {
                g_daemonRunning.store(true);
                int curCount = atoi(parts[2].c_str());
                int curPid = atoi(parts[3].c_str());
                if (curCount > g_lastSkipCount.load()) {
                    g_lastSkipCount.store(curCount);
                }
                if (curPid > 0) {
                    g_lastPid.store(curPid);
                }
                write_status_json();

                if (curCount > g_lastLoggedSkipCount) {
                    g_lastLoggedSkipCount = curCount;
                }
                std::string logLine = now_time_str() + " [SKIP] ⚡ 成功自动跳过开屏广告! 应用=" + parts[4] +
                                      " | 触控坐标=(" + parts[5] + ") | 区域=" + parts[6] + "\n";
                write_file_str(kSkipLogFile, logLine, true);
            }
        }
    }
}

__attribute__((constructor))
static void on_load_bridge() {
    ensure_shared_permissions();
    if (!g_bridgeStarted.exchange(true)) {
        g_bridgeStartMs.store(now_epoch_ms());
        std::thread(bridge_server_loop).detach();
    }
}

static napi_value InitBridge(napi_env env, napi_callback_info info) {
    ensure_shared_permissions();
    if (!g_bridgeStarted.exchange(true)) {
        g_bridgeStartMs.store(now_epoch_ms());
        std::thread(bridge_server_loop).detach();
    }
    napi_value result;
    napi_get_boolean(env, true, &result);
    return result;
}

static napi_value SetDaemonEnabled(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    bool enabled = true;
    if (argc >= 1 && args[0] != nullptr) {
        napi_get_value_bool(env, args[0], &enabled);
    }

    g_daemonEnabled.store(enabled);
    if (enabled) {
        g_pendingReset.store(true);
        std::string ctrlContent = "ENABLED:" + std::to_string(now_epoch_ms()) + "\n";
        write_file_str(kControlFile, ctrlContent, false);
    } else {
        g_pendingReset.store(false);
        write_file_str(kControlFile, "PAUSED\n", false);
    }
    chmod(kControlFile, 0666);
    write_status_json();
    chmod(kStatusFile, 0666);

    napi_value result;
    napi_get_boolean(env, enabled, &result);
    return result;
}

static napi_value GetDaemonEnabled(napi_env env, napi_callback_info info) {
    sync_status_from_disk();
    napi_value result;
    napi_get_boolean(env, g_daemonEnabled.load(), &result);
    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    ensure_shared_permissions();
    if (!g_bridgeStarted.exchange(true)) {
        g_bridgeStartMs.store(now_epoch_ms());
        std::thread(bridge_server_loop).detach();
    }
    napi_property_descriptor desc[] = {
        {"initBridge", nullptr, InitBridge, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setDaemonEnabled", nullptr, SetDaemonEnabled, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getDaemonEnabled", nullptr, GetDaemonEnabled, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "adskip_bridge",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterAdSkipBridgeModule(void) {
    napi_module_register(&demoModule);
}
