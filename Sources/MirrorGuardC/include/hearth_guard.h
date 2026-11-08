#pragma once

/* Runs body(context). Returns 1 on success, 0 if the body hit SIGSEGV/SIGBUS. */
int hearth_guard_call(void (*body)(void *), void *context);
