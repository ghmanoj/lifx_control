#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>
#include <unistd.h>
#include <stdio.h>
#include <signal.h>
#include <sys/wait.h>
#include <spawn.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif
extern char **environ;
