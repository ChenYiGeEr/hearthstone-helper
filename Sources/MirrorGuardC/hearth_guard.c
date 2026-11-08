#include "hearth_guard.h"

#include <setjmp.h>
#include <signal.h>
#include <stdlib.h>

static sigjmp_buf hearth_jump;
static volatile sig_atomic_t hearth_armed;

static void hearth_fault(int signal_number) {
    if (hearth_armed) {
        siglongjmp(hearth_jump, 1);
    }
    signal(signal_number, SIG_DFL);
    raise(signal_number);
}

int hearth_guard_call(void (*body)(void *), void *context) {
    static int installed = 0;
    if (!installed) {
        signal(SIGSEGV, hearth_fault);
        signal(SIGBUS, hearth_fault);
        installed = 1;
    }
    hearth_armed = 1;
    if (sigsetjmp(hearth_jump, 1) != 0) {
        hearth_armed = 0;
        return 0;
    }
    body(context);
    hearth_armed = 0;
    return 1;
}
