#include "MacEasyTier-Bridging-Header.h"

#include <libproc.h>
#include <unistd.h>

unsigned long long easytier_process_rss(int pid) {
    struct proc_taskinfo info;
    int size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, sizeof(info));
    if (size != sizeof(info)) {
        return 0;
    }
    return (unsigned long long)info.pti_resident_size;
}

unsigned long long easytier_current_rss(void) {
    return easytier_process_rss(getpid());
}

unsigned long long easytier_process_footprint(int pid) {
    struct rusage_info_v2 info;
    int size = proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&info);
    if (size != 0) {
        return easytier_process_rss(pid);
    }
    return (unsigned long long)info.ri_phys_footprint;
}

unsigned long long easytier_current_footprint(void) {
    return easytier_process_footprint(getpid());
}
