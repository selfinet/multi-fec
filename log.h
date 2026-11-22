
#ifndef _LOG_MYLOG_H_
#define _LOG_MYLOG_H_

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <getopt.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>

#include <set>

using namespace std;

#define RED "\x1B[31m"
#define GRN "\x1B[32m"
#define YEL "\x1B[33m"
#define BLU "\x1B[34m"
#define MAG "\x1B[35m"
#define CYN "\x1B[36m"
#define WHT "\x1B[37m"
#define RESET "\x1B[0m"

const int log_never = 0;
const int log_fatal = 1;
const int log_error = 2;
const int log_warn = 3;
const int log_info = 4;
const int log_debug = 5;
const int log_trace = 6;
const int log_end = 7;

const char log_text[][20] = {"NEVER", "FATAL", "ERROR", "WARN", "INFO", "DEBUG", "TRACE", ""};
const char log_color[][20] = {RED, RED, RED, YEL, GRN, MAG, ""};

extern int log_level;
extern int log_worker_id;   /* mmulti-fec: worker number in log lines, -1 = none */
extern int enable_log_position;
extern int enable_log_color;

#ifdef MY_DEBUG
#define mylog(__first_argu__dummy_abcde__, ...) printf(__VA_ARGS__)

#else
/* 레벨을 호출 전에 확인한다 — 걸러지는 로그의 인자(get_str() 주소 문자열 등)를 패킷마다 만들지 않게 (2026-11-18 J1900 서버 perf: printf+log0 ~4 %).
 * 인자에 부작용이 있는 호출은 없다(전수 확인). MF_LOG_EAGER 로 빌드하면 예전처럼 항상 평가. */
#ifdef MF_LOG_EAGER
#define mylog(...) log0(__FILE__, __FUNCTION__, __LINE__, __VA_ARGS__)
#else
#define mylog(lvl_, ...) do { if ((lvl_) <= log_level) log0(__FILE__, __FUNCTION__, __LINE__, (lvl_), __VA_ARGS__); } while (0)
#endif
#endif

//#define mylog(__first_argu__dummy_abcde__,...) {;}

void log0(const char* file, const char* function, int line, int level, const char* str, ...);

void log_bare(int level, const char* str, ...);

#endif
