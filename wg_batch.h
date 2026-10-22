/*
 * wg_batch — WireGuard 쪽 송신 묶음 (v1.5 후보, 2026-10-22)
 *
 * FEC 디코드 출력은 패킷마다 delay_send() → my_send() → sendto() 였다. 15 Mbps 에서 server 초당 ~1,550회,
 * client ~700회의 시스템 호출이 여기서 났다(test-results/2026-10-22-strace). 지연(-j)·임의 손실(--random-drop)을
 * 쓰지 않을 때만 여기 모았다가 sendmmsg 로 내보낸다 — 이벤트 루프가 잠들기 직전(ev_prepare)과 묶음이 찼을 때.
 * 같은 소켓이 이어지는 구간마다 한 번에 보내므로 소켓별 순서는 그대로다. upstream(packet.cpp·delay_manager) 무수정.
 */
#ifndef WG_BATCH_H
#define WG_BATCH_H
#include "common.h"

/* delay_send() 대신 부른다. 묶을 수 없는 경우(지연·임의 손실·지원 안 하는 dest)는 delay_send() 로 넘긴다. */
int wg_batch_send(my_time_t delay, const dest_t &dest, char *data, int len);
/* 모인 것을 보낸다. ev_prepare 콜백에서 부른다. 반환: 보낸 패킷 수 */
int wg_batch_flush();
#endif
