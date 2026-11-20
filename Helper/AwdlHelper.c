// Blue Bloom AWDL helper: keeps the macOS peer-to-peer Wi-Fi interface (awdl0) down while Blue Bloom
// is actively streaming, and restores it as soon as streaming pauses, stops, or the client disconnects.
//
// Why this exists: on Macs with shared Wi-Fi/Bluetooth radios (notably Apple N1), macOS AWDL discovery
// hops onto 2.4 GHz (channel 6) even when Wi-Fi is on 5 GHz, starving third-party Classic A2DP streams
// for 1.5-2.6 s. Because SIOCSIFFLAGS on awdl0 requires root, this small LaunchDaemon performs only
// that single operation on awdl0, driven by a crash-safe Unix stream socket.

#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <net/route.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#define kHelperVersion "1"
#define kSocketPath "/var/run/app.bluebloom.awdl-helper.sock"
#define kInterfaceName "awdl0"
#define kMaxClients 8
#define kActivePollTimeoutMs 500

typedef struct {
    int fd;
    bool suppressing;
} ClientSlot;

static volatile sig_atomic_t gRunning = 1;

static void HandleSignal(int sig) {
    (void)sig;
    gRunning = 0;
}

// Brings awdl0 up or down using SIOCGIFFLAGS / SIOCSIFFLAGS. Returns true on success or if already in state.
static bool SetAwdlUp(int ioctlFD, bool up) {
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strlcpy(ifr.ifr_name, kInterfaceName, sizeof(ifr.ifr_name));
    if (ioctl(ioctlFD, SIOCGIFFLAGS, &ifr) < 0) return false;
    bool isUp = (ifr.ifr_flags & IFF_UP) != 0;
    if (isUp == up) return true;
    if (up) {
        ifr.ifr_flags |= IFF_UP;
    } else {
        ifr.ifr_flags &= ~IFF_UP;
    }
    return ioctl(ioctlFD, SIOCSIFFLAGS, &ifr) == 0;
}

static int OpenListenSocket(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(addr.sun_path)) {
        close(fd);
        return -1;
    }
    strlcpy(addr.sun_path, path, sizeof(addr.sun_path));
    unlink(path);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    // Non-root GUI/CLI clients connect to send 1-byte '0'/'1'/'?' commands; this daemon only toggles awdl0.
    chmod(path, 0666);
    if (listen(fd, kMaxClients) < 0) {
        unlink(path);
        close(fd);
        return -1;
    }
    return fd;
}

static int OpenRouteSocket(void) {
    int fd = socket(PF_ROUTE, SOCK_RAW, 0);
    if (fd < 0) return -1;
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    return fd;
}

// Drain queued kernel routing messages and return true if awdl0 was reported IFF_UP.
static bool DrainRouteEventsSawAwdlUp(int routeFD) {
    uint8_t buf[4096];
    bool sawUp = false;
    unsigned int awdlIndex = if_nametoindex(kInterfaceName);
    for (;;) {
        ssize_t n = read(routeFD, buf, sizeof(buf));
        if (n <= 0) break;
        size_t offset = 0;
        while (offset + sizeof(struct rt_msghdr) <= (size_t)n) {
            const struct rt_msghdr *rtm = (const struct rt_msghdr *)(buf + offset);
            if (rtm->rtm_msglen == 0 || offset + rtm->rtm_msglen > (size_t)n) break;
            if (rtm->rtm_type == RTM_IFINFO && rtm->rtm_msglen >= sizeof(struct if_msghdr)) {
                const struct if_msghdr *ifm = (const struct if_msghdr *)rtm;
                if (awdlIndex == 0) awdlIndex = if_nametoindex(kInterfaceName);
                if (awdlIndex != 0 && ifm->ifm_index == awdlIndex && (ifm->ifm_flags & IFF_UP)) {
                    sawUp = true;
                }
            }
            offset += rtm->rtm_msglen;
        }
    }
    return sawUp;
}

static int CountSuppressors(const ClientSlot *clients) {
    int count = 0;
    for (int i = 0; i < kMaxClients; i++) {
        if (clients[i].fd >= 0 && clients[i].suppressing) count++;
    }
    return count;
}

static void CloseClient(ClientSlot *slot) {
    if (slot->fd >= 0) close(slot->fd);
    slot->fd = -1;
    slot->suppressing = false;
}

static void SendReply(int fd, const char *reply) {
    size_t len = strlen(reply);
    ssize_t unused = write(fd, reply, len);
    (void)unused;
}

int main(int argc, char **argv) {
    const char *socketPath = kSocketPath;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--version") == 0) {
            printf("%s\n", kHelperVersion);
            return 0;
        }
        if (strcmp(argv[i], "--socket") == 0 && i + 1 < argc) {
            socketPath = argv[++i];
        }
    }

    signal(SIGPIPE, SIG_IGN);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = HandleSignal;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    int ioctlFD = socket(AF_INET, SOCK_DGRAM, 0);
    if (ioctlFD < 0) return 1;

    int listenFD = OpenListenSocket(socketPath);
    if (listenFD < 0) {
        close(ioctlFD);
        return 2;
    }

    int routeFD = OpenRouteSocket();

    ClientSlot clients[kMaxClients];
    for (int i = 0; i < kMaxClients; i++) {
        clients[i].fd = -1;
        clients[i].suppressing = false;
    }

    int activeSuppressors = 0;

    while (gRunning) {
        struct pollfd fds[2 + kMaxClients];
        int mapSlot[2 + kMaxClients];
        nfds_t nfds = 0;

        fds[nfds].fd = listenFD;
        fds[nfds].events = POLLIN;
        fds[nfds].revents = 0;
        mapSlot[nfds++] = -1;

        int routeIdx = -1;
        if (routeFD >= 0) {
            routeIdx = (int)nfds;
            fds[nfds].fd = routeFD;
            fds[nfds].events = POLLIN;
            fds[nfds].revents = 0;
            mapSlot[nfds++] = -2;
        }

        for (int i = 0; i < kMaxClients; i++) {
            if (clients[i].fd < 0) continue;
            fds[nfds].fd = clients[i].fd;
            fds[nfds].events = POLLIN;
            fds[nfds].revents = 0;
            mapSlot[nfds++] = i;
        }

        int timeout = activeSuppressors > 0 ? kActivePollTimeoutMs : -1;
        int ready = poll(fds, nfds, timeout);
        if (ready < 0) {
            if (errno == EINTR) continue;
            break;
        }

        // Periodic safety check while active in case a routing event was dropped or awdl0 reappeared after wake
        if (ready == 0) {
            if (activeSuppressors > 0) SetAwdlUp(ioctlFD, false);
            continue;
        }

        // Accept new client connections
        if (fds[0].revents & POLLIN) {
            for (;;) {
                int cfd = accept(listenFD, NULL, NULL);
                if (cfd < 0) break;
                int flags = fcntl(cfd, F_GETFL, 0);
                if (flags >= 0) fcntl(cfd, F_SETFL, flags | O_NONBLOCK);
                int slot = -1;
                for (int i = 0; i < kMaxClients; i++) {
                    if (clients[i].fd < 0) {
                        slot = i;
                        break;
                    }
                }
                if (slot < 0) {
                    close(cfd);
                } else {
                    clients[slot].fd = cfd;
                    clients[slot].suppressing = false;
                }
            }
        }

        // Kernel interface state change notifications
        if (routeIdx >= 0 && (fds[routeIdx].revents & POLLIN)) {
            if (DrainRouteEventsSawAwdlUp(routeFD) && activeSuppressors > 0) {
                SetAwdlUp(ioctlFD, false);
            }
        }

        // Client commands and disconnect detection (EOF / HUP / ERR immediately releases suppression)
        for (nfds_t k = 0; k < nfds; k++) {
            int slot = mapSlot[k];
            if (slot < 0) continue;
            if (!(fds[k].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL))) continue;

            uint8_t buf[64];
            ssize_t n = read(clients[slot].fd, buf, sizeof(buf));
            if (n <= 0) {
                if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) continue;
                CloseClient(&clients[slot]);
                continue;
            }
            for (ssize_t i = 0; i < n; i++) {
                if (buf[i] == '1') {
                    clients[slot].suppressing = true;
                    SendReply(clients[slot].fd, "1\n");
                } else if (buf[i] == '0') {
                    clients[slot].suppressing = false;
                    SendReply(clients[slot].fd, "0\n");
                } else if (buf[i] == '?') {
                    SendReply(clients[slot].fd, "v" kHelperVersion "\n");
                }
            }
        }

        int nextSuppressors = CountSuppressors(clients);
        if (activeSuppressors == 0 && nextSuppressors > 0) {
            SetAwdlUp(ioctlFD, false);
        } else if (activeSuppressors > 0 && nextSuppressors == 0) {
            SetAwdlUp(ioctlFD, true);
        }
        activeSuppressors = nextSuppressors;
    }

    // Always restore awdl0 if we were suppressing it when stopped/uninstalled
    if (activeSuppressors > 0) SetAwdlUp(ioctlFD, true);
    for (int i = 0; i < kMaxClients; i++) CloseClient(&clients[i]);
    if (routeFD >= 0) close(routeFD);
    close(listenFD);
    unlink(socketPath);
    close(ioctlFD);
    return 0;
}
