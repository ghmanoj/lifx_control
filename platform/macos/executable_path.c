#include "../executable_path.h"
#include <mach-o/dyld.h>

bool executable_path(char *path, size_t capacity)
{
    uint32_t size = (uint32_t)capacity;
    return _NSGetExecutablePath(path, &size) == 0;
}
