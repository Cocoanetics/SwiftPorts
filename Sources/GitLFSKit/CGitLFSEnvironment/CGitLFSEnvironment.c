#include "CGitLFSEnvironment.h"

#if defined(_WIN32)
#include <stdlib.h>
#else
extern char **environ;
#endif

char **swiftports_lfs_environ(void) {
#if defined(_WIN32)
    return *__p__environ();
#else
    return environ;
#endif
}
