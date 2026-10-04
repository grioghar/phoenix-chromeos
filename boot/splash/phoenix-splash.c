/*
 * phoenix-splash: framebuffer boot screen for Phoenix (runs in Brunch's initramfs).
 *
 * It shows the Phoenix title, a plain-language status line, an optional progress bar and the
 * detected hardware. The kernel/Brunch text stays hidden behind it.
 *
 * Input:
 *   - Commands on a FIFO (default /run/phoenix-splash), one per line:
 *       status <text>     main status line
 *       detail <text>     add a line to the hardware/details box (max 8)
 *       clear             remove all detail lines
 *       progress <0-100>  show the progress bar (-1 hides it)
 *       pvfile <path>     follow a file written by `pv -n` (percent per line)
 *       quit              exit
 *   - The kernel log (/dev/kmsg): "brunch: ..." messages become friendly status lines.
 *
 * Usage: phoenix-splash [/dev/fb0] [fifo]
 * Build: static, e.g. `cc -O2 -static -o phoenix-splash phoenix-splash.c`
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "font8x8_basic.h"

#define MAXD 8
#define LINE 160

static struct fb_var_screeninfo vi;
static struct fb_fix_screeninfo fi;
static uint8_t *fbmem;
static uint32_t *buf;            /* back buffer, 0x00RRGGBB */
static int W, H;
static char status[LINE] = "Starting...";
static char details[MAXD][LINE];
static int ndetails, progress = -1, spin;
static FILE *pvf;

/* ------------------------------------------------------------------ drawing */
static void fill(int x, int y, int w, int h, uint32_t c) {
  for (int j = y < 0 ? 0 : y; j < y + h && j < H; j++)
    for (int i = x < 0 ? 0 : x; i < x + w && i < W; i++) buf[j * W + i] = c;
}
static uint32_t mix(uint32_t a, uint32_t b, int t, int n) { /* a..b at t/n */
  int r = ((a >> 16 & 255) * (n - t) + (b >> 16 & 255) * t) / n;
  int g = ((a >> 8 & 255) * (n - t) + (b >> 8 & 255) * t) / n;
  int bl = ((a & 255) * (n - t) + (b & 255) * t) / n;
  return (uint32_t)(r << 16 | g << 8 | bl);
}
static int text_w(const char *s, int sc) { return (int)strlen(s) * 8 * sc; }
/* text with a vertical gradient (c1 top, c2 bottom) */
static void text(int x, int y, const char *s, int sc, uint32_t c1, uint32_t c2) {
  for (; *s; s++, x += 8 * sc) {
    unsigned char ch = (unsigned char)*s;
    if (ch > 127) ch = '?';
    for (int row = 0; row < 8; row++) {
      unsigned char bits = (unsigned char)font8x8_basic[ch][row];
      uint32_t c = mix(c1, c2, row, 7);
      for (int col = 0; col < 8; col++)
        if (bits & (1 << col)) fill(x + col * sc, y + row * sc, sc, sc, c);
    }
  }
}
static void ctext(int y, const char *s, int sc, uint32_t c1, uint32_t c2) {
  text((W - text_w(s, sc)) / 2, y, s, sc, c1, c2);
}
/* simple emblem: a flame made of stacked, narrowing gradient rows */
static void emblem(int cx, int top, int size) {
  for (int j = 0; j < size; j++) {
    double f = (double)j / size;                     /* 0 at top .. 1 at bottom */
    double wing = f < 0.55 ? f / 0.55 : 1.0 - (f - 0.55) / 0.45 * 0.65;
    int half = (int)(size * 0.42 * wing * (1.0 - 0.15 * (j % (size / 6 + 1)) / (size / 6 + 1.0)));
    uint32_t c = mix(0xFFD25A, 0xE8431B, j, size);
    fill(cx - half, top + j, 2 * half, 1, c);
  }
  /* inner glow */
  for (int j = size / 3; j < size; j++) {
    double f = (double)(j - size / 3) / (size * 2 / 3);
    int half = (int)(size * 0.16 * (f < 0.6 ? f / 0.6 : 1.0 - (f - 0.6) / 0.4 * 0.7));
    fill(cx - half, top + j, 2 * half, 1, mix(0xFFF2C0, 0xFFB347, j - size / 3, size * 2 / 3));
  }
}

static void render(void) {
  int sc = H >= 1000 ? 3 : 2;                        /* body text scale */
  int tsc = H / 100 < 4 ? 4 : H / 100;               /* title scale */
  fill(0, 0, W, H, 0x0E1116);
  int y = H / 7;
  int es = H / 6;
  emblem(W / 2, y, es);
  y += es + H / 30;
  ctext(y, "PHOENIX", tsc, 0xFFC04D, 0xE8431B);
  y += 8 * tsc + H / 60;
  ctext(y, "ChromeOS for every PC", sc, 0x9AA4B2, 0x9AA4B2);
  y += 8 * sc + H / 14;

  /* status with spinner */
  static const char *sp[] = {"   ", ".  ", ".. ", "..."};
  char st[LINE + 4];
  snprintf(st, sizeof st, "%s%s", status, progress < 0 ? sp[spin % 4] : "");
  ctext(y, st, sc, 0xE6EAF0, 0xE6EAF0);
  y += 8 * sc + H / 40;

  /* progress bar */
  int bw = W / 2, bh = 8 * sc / 2 + 4, bx = (W - bw) / 2;
  if (progress >= 0) {
    fill(bx, y, bw, bh, 0x2A303A);
    int pw = bw * (progress > 100 ? 100 : progress) / 100;
    for (int i = 0; i < pw; i++) fill(bx + i, y, 1, bh, mix(0xFFC04D, 0xE8431B, i, bw));
    char pct[8]; snprintf(pct, sizeof pct, "%d%%", progress);
    text(bx + bw + 8 * sc, y + (bh - 8 * sc) / 2, pct, sc, 0x9AA4B2, 0x9AA4B2);
  }
  y += bh + H / 18;

  /* details box (detected hardware etc.) */
  if (ndetails) {
    /* size the box to the longest line; shrink the text, then truncate, to fit 92% of the width */
    int maxw = W * 92 / 100, longest = 0, dsc = sc;
    for (int i = 0; i < ndetails; i++) if ((int)strlen(details[i]) > longest) longest = (int)strlen(details[i]);
    while (dsc > 1 && longest * 8 * dsc + 40 > maxw) dsc--;
    int fitc = (maxw - 40) / (8 * dsc);
    int lh = 8 * dsc + 6, bxw = (longest < fitc ? longest : fitc) * 8 * dsc + 40, bxx = (W - bxw) / 2;
    fill(bxx, y, bxw, ndetails * lh + 20, 0x161B22);
    fill(bxx, y, 3, ndetails * lh + 20, 0xE8431B);
    for (int i = 0; i < ndetails; i++) {
      char l[LINE]; snprintf(l, sizeof l, "%s", details[i]);
      if ((int)strlen(l) > fitc && fitc > 3) { l[fitc - 3] = '.'; l[fitc - 2] = '.'; l[fitc - 1] = '.'; l[fitc] = 0; }
      text(bxx + 20, y + 10 + i * lh, l, dsc, 0xB8C0CC, 0xB8C0CC);
    }
  }
}

static void blit(void) {
  int bpp = vi.bits_per_pixel / 8;
  for (int j = 0; j < H; j++) {
    uint8_t *row = fbmem + (size_t)(j + vi.yoffset) * fi.line_length + (size_t)vi.xoffset * bpp;
    for (int i = 0; i < W; i++) {
      uint32_t c = buf[j * W + i];
      uint32_t r = c >> 16 & 255, g = c >> 8 & 255, b = c & 255;
      uint32_t px = (r >> (8 - vi.red.length)) << vi.red.offset |
                    (g >> (8 - vi.green.length)) << vi.green.offset |
                    (b >> (8 - vi.blue.length)) << vi.blue.offset;
      memcpy(row + i * bpp, &px, bpp);
    }
  }
}

/* ------------------------------------------------------------------ input */
static void trim(char *s) { size_t n = strlen(s); while (n && (s[n - 1] == '\n' || s[n - 1] == '\r')) s[--n] = 0; }
static void set_status(const char *s) { snprintf(status, sizeof status, "%s", s); }

static int command(char *l) {
  trim(l);
  if (!strncmp(l, "status ", 7)) set_status(l + 7);
  else if (!strncmp(l, "detail ", 7)) { if (ndetails < MAXD) snprintf(details[ndetails++], LINE, "%s", l + 7); }
  else if (!strcmp(l, "clear")) ndetails = 0;
  else if (!strncmp(l, "progress ", 9)) progress = atoi(l + 9);
  else if (!strncmp(l, "pvfile ", 7)) { if (pvf) fclose(pvf); pvf = fopen(l + 7, "r"); progress = 0; }
  else if (!strcmp(l, "quit")) return 1;
  return 0;
}

/* map Brunch's kernel-log messages to friendly status lines */
static void kmsg_line(char *l) {
  char *m = strstr(l, "brunch: ");
  if (!m) return;
  m += 8; trim(m);
  if (strstr(m, "Scanning device")) set_status("Looking for ChromeOS");
  else if (strstr(m, "ChromeOS found")) set_status("Found ChromeOS");
  else if (strstr(m, "update detected")) set_status("Installing the ChromeOS update");
  else if (strstr(m, "new install detected")) set_status("Preparing ChromeOS for first use (this happens once)");
  else if (strstr(m, "framework change detected")) set_status("Applying new settings");
  else if (strstr(m, "rebuilding ChromeOS rootfs, it might")) set_status("Rebuilding the system (a few minutes)");
  else if (strstr(m, "rebuilding ChromeOS rootfs not necessary")) set_status("Starting ChromeOS");
  else if (strstr(m, "/patches/")) {                   /* ".../patches/61-touchpad.sh success" */
    char name[64] = ""; const char *p = strstr(m, "/patches/") + 9;
    while (*p && *p != '-' && *p != ' ') p++;          /* skip number */
    if (*p == '-') p++;
    int n = 0; while (*p && *p != '.' && *p != ' ' && n < 60) name[n++] = *p == '_' ? ' ' : *p, p++;
    name[n] = 0;
    if (progress < 0 || progress >= 100) progress = -1;
    char s[LINE]; snprintf(s, sizeof s, "Applying hardware support: %s", name); set_status(s);
  }
  else if (strstr(m, "corrupt by an unfinished update")) set_status("Waiting for the update to finish downloading");
}

/* test mode: phoenix-splash --ppm WxH out.ppm < commands  (renders one frame to an image) */
static int ppm(const char *size, const char *out) {
  if (sscanf(size, "%dx%d", &W, &H) != 2) return 1;
  buf = malloc((size_t)W * H * 4);
  char line[512];
  while (fgets(line, sizeof line, stdin)) { if (!strncmp(line, "kmsg ", 5)) kmsg_line(line + 5); else command(line); }
  render();
  FILE *f = fopen(out, "wb"); if (!f) return 1;
  fprintf(f, "P6\n%d %d\n255\n", W, H);
  for (int i = 0; i < W * H; i++) { uint32_t c = buf[i]; fputc(c >> 16 & 255, f); fputc(c >> 8 & 255, f); fputc(c & 255, f); }
  return fclose(f);
}

int main(int argc, char **argv) {
  if (argc == 4 && !strcmp(argv[1], "--ppm")) return ppm(argv[2], argv[3]);
  const char *fbdev = argc > 1 ? argv[1] : "/dev/fb0";
  const char *fifo = argc > 2 ? argv[2] : "/run/phoenix-splash";
  signal(SIGPIPE, SIG_IGN);
  int fb = open(fbdev, O_RDWR);
  if (fb < 0 || ioctl(fb, FBIOGET_VSCREENINFO, &vi) || ioctl(fb, FBIOGET_FSCREENINFO, &fi)) { perror(fbdev); return 1; }
  if (vi.bits_per_pixel != 16 && vi.bits_per_pixel != 24 && vi.bits_per_pixel != 32) { fprintf(stderr, "unsupported bpp %u\n", vi.bits_per_pixel); return 1; }
  W = (int)vi.xres; H = (int)vi.yres;
  fbmem = mmap(NULL, fi.smem_len, PROT_READ | PROT_WRITE, MAP_SHARED, fb, 0);
  buf = malloc((size_t)W * H * 4);
  if (fbmem == MAP_FAILED || !buf) { perror("mmap"); return 1; }

  mkdir("/run", 0755);
  unlink(fifo); mkfifo(fifo, 0666);
  int ff = open(fifo, O_RDWR | O_NONBLOCK);            /* RDWR: never sees EOF */
  int km = open("/dev/kmsg", O_RDONLY | O_NONBLOCK);
  if (km >= 0) lseek(km, 0, SEEK_END);                  /* only new messages */
  FILE *fin = ff >= 0 ? fdopen(ff, "r") : NULL;
  char line[512];

  for (int dirty = 1;; ) {
    if (dirty) { render(); blit(); dirty = 0; }
    struct pollfd p[2] = {{ff, POLLIN, 0}, {km, POLLIN, 0}};
    poll(p, 2, 250);
    if (fin && (p[0].revents & POLLIN)) {
      while (fgets(line, sizeof line, fin)) { if (command(line)) return 0; dirty = 1; }
      clearerr(fin);
    }
    if (km >= 0 && (p[1].revents & POLLIN)) {
      ssize_t n;
      while ((n = read(km, line, sizeof line - 1)) > 0) { line[n] = 0; kmsg_line(line); dirty = 1; }
    }
    if (pvf) {                                           /* `pv -n` writes one percentage per line */
      while (fgets(line, sizeof line, pvf)) { int v = atoi(line); if (v != progress) { progress = v; dirty = 1; } }
      clearerr(pvf);
    }
    spin++; dirty = 1;                                   /* animate the status dots */
  }
}
