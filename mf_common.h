#pragma once
/*
 * mf_common.h — multi-fec 공유 타입 및 전역 변수
 */
#include "common.h"
#include "obfs.h"
#include <vector>
#include <stdint.h>

/* session_id: 클라이언트가 시작 시 생성하는 8바이트 랜덤 식별자.
 * 모든 클라이언트→서버 FEC 패킷에 앞에 붙여 서버가 경로(POP) 무관하게
 * 동일 클라이언트를 식별하게 한다. */
#define SESSION_ID_LEN 8
extern uint8_t g_session_id[SESSION_ID_LEN];

/* --path local_ip:remote_ip:port 파싱 결과 */
struct PathSpec {
    address_t local;   /* 로컬 인터페이스 IP (포트=0 → OS 자동 선택) */
    address_t remote;  /* 원격 IP:port */
};

/*
 * 멀티패스 동작 모드
 *   MULTIPATH_FAILOVER           : 우선순위 순 Active-Standby. 최상위 경로만 사용.
 *   MULTIPATH_DUPLICATE          : 모든 경로에 동일 패킷 전송. 최고 가용성.
 *   MULTIPATH_AGGREGATE          : 경로별 다른 패킷 분배 (가중 라운드로빈).
 *                                  전체 대역폭 합산. tx.rate 비례 가중치.
 *   MULTIPATH_AGGREGATE_DUPLICATE: 집계 + 중복. 각 패킷을 dup_factor개 경로에 전송.
 *                                  대역폭 집계 + 경로 이중화 혼합.
 */
enum multipath_mode_t {
    MULTIPATH_FAILOVER            = 0,
    MULTIPATH_DUPLICATE           = 1,
    MULTIPATH_AGGREGATE           = 2,
    MULTIPATH_AGGREGATE_DUPLICATE = 3,
};

/*
 * 릴레이 키별 upstream 라우팅 테이블 엔트리.
 * --route "keystring ip:port" 옵션으로 등록.
 * g_routes가 비어 있으면 기존 --upstream 단일 모드로 동작.
 */
struct route_entry_t {
    char            key_str[1000];
    address_t       upstream_addr;
    struct obfs_ctx obfs;          /* key_str로 초기화된 HMAC 컨텍스트 */
};

/* main.cpp에서 정의, 다른 모듈에서 extern으로 참조 */
extern std::vector<PathSpec>      g_paths;          /* 클라이언트 --path 목록 */
extern address_t                  g_wg_addr;        /* 서버 --wg WireGuard 업스트림 주소 */
extern multipath_mode_t           g_multipath_mode; /* 멀티패스 동작 모드 */
extern unsigned                   g_dup_factor;     /* aggregate-duplicate 경로 중복 수 */
extern std::vector<route_entry_t> g_routes;         /* 릴레이 키별 upstream 라우팅 테이블 */
