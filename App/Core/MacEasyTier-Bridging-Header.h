#ifndef MacEasyTier_Bridging_Header_h
#define MacEasyTier_Bridging_Header_h

/// 进程常驻内存（RSS），用于首页统计。
unsigned long long easytier_process_rss(int pid);
unsigned long long easytier_current_rss(void);
unsigned long long easytier_process_footprint(int pid);
unsigned long long easytier_current_footprint(void);

#endif
