#define _POSIX_C_SOURCE 200809L
#include "../executable_path.h"
#include <unistd.h>

bool executable_path(char *path, size_t capacity)
{
    ssize_t n = readlink("/proc/self/exe", path, capacity);
    if (n < 0 || (size_t)n >= capacity)
        return false;
    path[n] = '\0';
    return true;
}
