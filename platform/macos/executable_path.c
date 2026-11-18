#include "../executable_path.h"
#include <libproc.h>
#include <unistd.h>

bool executable_path(char *path, size_t capacity)
{
    // Ask the kernel for the running image, independent of its launch symlink.
    if (capacity > PROC_PIDPATHINFO_MAXSIZE)
        capacity = PROC_PIDPATHINFO_MAXSIZE;
    return proc_pidpath(getpid(), path, (uint32_t)capacity) > 0;
}
