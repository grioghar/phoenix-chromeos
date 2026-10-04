/*
 * phoenix-statusd: local status + control endpoint for the Phoenix Health extension.
 *
 * Listens on 127.0.0.1 only. Every request must come from the Phoenix extension: Chrome sets the
 * Origin header of extension requests to chrome-extension://<id>, and web pages cannot forge it,
 * so other pages in the browser (which can also reach 127.0.0.1) are refused with 403.
 *   GET  /health    -> /run/phoenix/health.json
 *   GET  /config    -> /run/phoenix/health-config.json
 *   GET  /settings  -> control.sh get            (current Phoenix settings as JSON)
 *   POST /set       -> control.sh set KEY VALUE  (body: KEY=VALUE; both checked here and in control.sh)
 * Static, dependency-free. Build: cc -O2 -static -o phoenix-statusd statusd.c
 * Usage: phoenix-statusd PORT EXTENSION_ID
 */
#include <arpa/inet.h>
#include <ctype.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

#define CONTROL "/usr/share/phoenix/desktop/control.sh"
static char origin_ok[128];

static void reply(int c, const char *status, const char *body, size_t n) {
  char h[512];
  int k = snprintf(h, sizeof h, "HTTP/1.0 %s\r\nContent-Type: application/json\r\n"
                   "Access-Control-Allow-Origin: %s\r\nVary: Origin\r\nCache-Control: no-store\r\n"
                   "Content-Length: %zu\r\n\r\n", status, origin_ok, n);
  if (write(c, h, k) < 0 || (n && write(c, body, n) < 0)) return;
}
static void send_file(int c, const char *path, const char *fallback) {
  static char buf[65536];
  FILE *f = fopen(path, "r");
  if (!f) { reply(c, "200 OK", fallback, strlen(fallback)); return; }
  size_t n = fread(buf, 1, sizeof buf, f); fclose(f);
  reply(c, "200 OK", buf, n);
}
/* run control.sh with fixed argv (no shell interpretation of the arguments) */
static void run_control(int c, const char *a1, const char *a2, const char *a3) {
  static char buf[65536];
  int p[2]; if (pipe(p)) { reply(c, "500 Error", "{}", 2); return; }
  pid_t pid = fork();
  if (pid == 0) {
    dup2(p[1], 1); close(p[0]); close(p[1]);
    execl("/bin/sh", "sh", CONTROL, a1, a2, a3, (char *)NULL); _exit(127);
  }
  close(p[1]);
  size_t n = 0; ssize_t r;
  while (n < sizeof buf - 1 && (r = read(p[0], buf + n, sizeof buf - 1 - n)) > 0) n += r;
  close(p[0]); int st; waitpid(pid, &st, 0);
  if (WIFEXITED(st) && WEXITSTATUS(st) == 0) reply(c, "200 OK", buf, n);
  else reply(c, "400 Bad Request", n ? buf : "{\"error\":\"rejected\"}", n ? n : 20);
}
static int valid(const char *s, int allow_dot) {
  if (!*s || strlen(s) > 32) return 0;
  for (; *s; s++) if (!(islower((unsigned char)*s) || isdigit((unsigned char)*s) || *s == '_' || (allow_dot && *s == '.'))) return 0;
  return 1;
}
static const char *header(const char *req, const char *name) {
  static char v[256]; size_t ln = strlen(name);
  for (const char *p = strstr(req, "\r\n"); p; p = strstr(p + 2, "\r\n")) {
    if (!strncasecmp(p + 2, name, ln) && p[2 + ln] == ':') {
      const char *s = p + 3 + ln; while (*s == ' ') s++;
      size_t i = 0; while (s[i] && s[i] != '\r' && i < sizeof v - 1) { v[i] = s[i]; i++; } v[i] = 0; return v;
    }
  }
  return "";
}
int main(int argc, char **argv) {
  int port = argc > 1 ? atoi(argv[1]) : 8098;
  snprintf(origin_ok, sizeof origin_ok, "chrome-extension://%s", argc > 2 ? argv[2] : "none");
  signal(SIGPIPE, SIG_IGN);
  int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
  setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in a = {0};
  a.sin_family = AF_INET; a.sin_port = htons(port); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(s, (struct sockaddr *)&a, sizeof a) || listen(s, 8)) { perror("bind"); return 1; }
  for (;;) {
    int c = accept(s, NULL, NULL);
    if (c < 0) continue;
    struct timeval tv = {2, 0}; setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    char req[4096] = {0};
    ssize_t n = read(c, req, sizeof req - 1);
    if (n > 0) {
      if (strcmp(header(req, "Origin"), origin_ok)) { reply(c, "403 Forbidden", "{\"error\":\"forbidden\"}", 21); close(c); continue; }
      if (!strncmp(req, "OPTIONS ", 8)) reply(c, "204 No Content", "", 0);
      else if (!strncmp(req, "GET /health ", 12)) send_file(c, "/run/phoenix/health.json", "{\"issues\":[],\"pending\":true}");
      else if (!strncmp(req, "GET /config ", 12)) send_file(c, "/run/phoenix/health-config.json", "{\"interval\":300}");
      else if (!strncmp(req, "GET /settings ", 14)) run_control(c, "get", "", "");
      else if (!strncmp(req, "POST /set ", 10)) {
        char *body = strstr(req, "\r\n\r\n"), key[40] = "", val[40] = "";
        if (body && sscanf(body + 4, "%39[^=]=%39s", key, val) == 2 && valid(key, 0) && valid(val, 1)) run_control(c, "set", key, val);
        else reply(c, "400 Bad Request", "{\"error\":\"bad request\"}", 23);
      } else reply(c, "404 Not Found", "{}", 2);
    }
    close(c);
  }
}
