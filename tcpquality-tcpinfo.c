#define _GNU_SOURCE

#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/tcp.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef TCP_INFO
#define TCP_INFO 11
#endif

#define TCPQUALITY_MAX_TRACKED 32

typedef int (*tcpquality_connect_fn)(int, const struct sockaddr *, socklen_t);
typedef int (*tcpquality_close_fn)(int);

struct tcpquality_tracked_socket {
  int fd;
  int active;
};

static tcpquality_connect_fn tcpquality_real_connect;
static tcpquality_close_fn tcpquality_real_close;
static pthread_mutex_t tcpquality_lock = PTHREAD_MUTEX_INITIALIZER;
static struct tcpquality_tracked_socket tcpquality_sockets[TCPQUALITY_MAX_TRACKED];
static char tcpquality_target[INET6_ADDRSTRLEN];
static int tcpquality_target_family;
static const char *tcpquality_output;

static void tcpquality_resolve_symbols(void) {
  if (tcpquality_real_connect == NULL) {
    tcpquality_real_connect = (tcpquality_connect_fn)dlsym(RTLD_NEXT, "connect");
  }
  if (tcpquality_real_close == NULL) {
    tcpquality_real_close = (tcpquality_close_fn)dlsym(RTLD_NEXT, "close");
  }
}

static void tcpquality_init_config(void) {
  const char *target = getenv("TCPQUALITY_TCP_INFO_TARGET");
  const char *output = getenv("TCPQUALITY_TCP_INFO_FILE");
  struct in_addr target4;
  struct in6_addr target6;

  tcpquality_resolve_symbols();
  tcpquality_output = output;
  tcpquality_target_family = 0;
  tcpquality_target[0] = '\0';
  if (target == NULL || output == NULL || *target == '\0' || *output == '\0') {
    return;
  }
  if (inet_pton(AF_INET, target, &target4) == 1) {
    tcpquality_target_family = AF_INET;
  } else if (inet_pton(AF_INET6, target, &target6) == 1) {
    tcpquality_target_family = AF_INET6;
  } else {
    return;
  }
  strncpy(tcpquality_target, target, sizeof(tcpquality_target) - 1);
  tcpquality_target[sizeof(tcpquality_target) - 1] = '\0';
}

__attribute__((constructor)) static void tcpquality_constructor(void) {
  tcpquality_init_config();
}

static int tcpquality_is_target(const struct sockaddr *address, socklen_t address_len) {
  char address_text[INET6_ADDRSTRLEN];
  const void *address_bytes;
  int family;
  uint16_t port;

  if (address == NULL || tcpquality_target_family == 0 ||
      address_len < sizeof(sa_family_t)) {
    return 0;
  }
  family = address->sa_family;
  if (family == AF_INET && address_len >= sizeof(struct sockaddr_in) &&
      tcpquality_target_family == AF_INET) {
    const struct sockaddr_in *address4 = (const struct sockaddr_in *)address;
    address_bytes = &address4->sin_addr;
    port = ntohs(address4->sin_port);
  } else if (family == AF_INET6 && address_len >= sizeof(struct sockaddr_in6) &&
             tcpquality_target_family == AF_INET6) {
    const struct sockaddr_in6 *address6 = (const struct sockaddr_in6 *)address;
    address_bytes = &address6->sin6_addr;
    port = ntohs(address6->sin6_port);
  } else {
    return 0;
  }
  if (port != 443 || inet_ntop(family, address_bytes, address_text, sizeof(address_text)) == NULL) {
    return 0;
  }
  return strcmp(address_text, tcpquality_target) == 0;
}

static void tcpquality_mark_socket(int fd) {
  int free_slot = -1;
  int index;

  pthread_mutex_lock(&tcpquality_lock);
  for (index = 0; index < TCPQUALITY_MAX_TRACKED; index++) {
    if (tcpquality_sockets[index].active && tcpquality_sockets[index].fd == fd) {
      pthread_mutex_unlock(&tcpquality_lock);
      return;
    }
    if (!tcpquality_sockets[index].active && free_slot < 0) {
      free_slot = index;
    }
  }
  if (free_slot >= 0) {
    tcpquality_sockets[free_slot].fd = fd;
    tcpquality_sockets[free_slot].active = 1;
  }
  pthread_mutex_unlock(&tcpquality_lock);
}

static int tcpquality_unmark_socket(int fd) {
  int found = 0;
  int index;

  pthread_mutex_lock(&tcpquality_lock);
  for (index = 0; index < TCPQUALITY_MAX_TRACKED; index++) {
    if (tcpquality_sockets[index].active && tcpquality_sockets[index].fd == fd) {
      tcpquality_sockets[index].active = 0;
      found = 1;
      break;
    }
  }
  pthread_mutex_unlock(&tcpquality_lock);
  return found;
}

static void tcpquality_write_snapshot(int fd) {
  struct tcp_info info;
  socklen_t info_length = sizeof(info);
  char line[256];
  int line_length;
  int output_fd;

  if (tcpquality_output == NULL || *tcpquality_output == '\0' ||
      getsockopt(fd, IPPROTO_TCP, TCP_INFO, &info, &info_length) != 0) {
    return;
  }
  line_length = snprintf(line, sizeof(line), "%u|%u|%u|%llu\n",
                         (unsigned int)info.tcpi_total_retrans,
                         (unsigned int)info.tcpi_data_segs_out,
                         (unsigned int)info.tcpi_segs_out,
                         (unsigned long long)info.tcpi_bytes_retrans);
  if (line_length <= 0 || (size_t)line_length >= sizeof(line)) {
    return;
  }
  output_fd = (int)syscall(SYS_openat, AT_FDCWD, tcpquality_output,
                            O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
  if (output_fd < 0) {
    return;
  }
  (void)syscall(SYS_write, output_fd, line, (size_t)line_length);
  (void)syscall(SYS_close, output_fd);
}

int connect(int fd, const struct sockaddr *address, socklen_t address_len) {
  int result;
  int saved_errno;

  tcpquality_resolve_symbols();
  if (tcpquality_real_connect == NULL) {
    errno = ENOSYS;
    return -1;
  }
  result = tcpquality_real_connect(fd, address, address_len);
  saved_errno = errno;
  if (tcpquality_is_target(address, address_len) &&
      (result == 0 || saved_errno == EINPROGRESS || saved_errno == EALREADY ||
       saved_errno == EISCONN)) {
    tcpquality_mark_socket(fd);
  }
  errno = saved_errno;
  return result;
}

int close(int fd) {
  int tracked;

  tcpquality_resolve_symbols();
  tracked = tcpquality_unmark_socket(fd);
  if (tracked) {
    tcpquality_write_snapshot(fd);
  }
  if (tcpquality_real_close == NULL) {
    errno = ENOSYS;
    return -1;
  }
  return tcpquality_real_close(fd);
}

__attribute__((destructor)) static void tcpquality_destructor(void) {
  int descriptors[TCPQUALITY_MAX_TRACKED];
  int count = 0;
  int index;

  pthread_mutex_lock(&tcpquality_lock);
  for (index = 0; index < TCPQUALITY_MAX_TRACKED; index++) {
    if (tcpquality_sockets[index].active) {
      descriptors[count++] = tcpquality_sockets[index].fd;
      tcpquality_sockets[index].active = 0;
    }
  }
  pthread_mutex_unlock(&tcpquality_lock);
  for (index = 0; index < count; index++) {
    tcpquality_write_snapshot(descriptors[index]);
  }
}
