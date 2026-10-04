/* Advertise MOVBE to KVM guests on CPUs without it (Sandy/Ivy Bridge).
 * KVM emulates MOVBE on #UD when the guest CPUID has it, so the ARCVM
 * Android image (built with MOVBE) can run; AVX is hidden so hot crypto avoids MOVBE.
 * Linked into crosvm (DT_NEEDED). */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <linux/kvm.h>
typedef int (*ioctl_fn)(int, unsigned long, ...);
static ioctl_fn real_ioctl;
__attribute__((constructor)) static void init(void) { real_ioctl = (ioctl_fn)dlsym(RTLD_NEXT, "ioctl"); }
int ioctl(int fd, unsigned long req, ...) {
  va_list ap; va_start(ap, req); void *arg = va_arg(ap, void *); va_end(ap);
  if (req == KVM_SET_CPUID2 && arg) {
    struct kvm_cpuid2 *c = arg;
    for (unsigned i = 0; i < c->nent; i++)
      if (c->entries[i].function == 1) {
        c->entries[i].ecx |= 1u << 22;                       /* MOVBE: KVM emulates it */
        /* Hide AVX (and FMA/F16C): with AVX+MOVBE, BoringSSL picks an AES-GCM path built on
         * MOVBE, and every one of those traps into KVM. Without AVX it uses plain AES-NI. */
        c->entries[i].ecx &= ~((1u << 28) | (1u << 12) | (1u << 29));
      }
  }
  if (!real_ioctl) real_ioctl = (ioctl_fn)dlsym(RTLD_NEXT, "ioctl");
  return real_ioctl(fd, req, arg);
}
