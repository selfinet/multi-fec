NAME = multi-fec
CC   = gcc
CXX  = g++

CFLAGS   = -std=c11   -Wall -O2 -I. -isystem libev
CXXFLAGS = -std=c++11 -Wall -O2 -I. -isystem libev
LDFLAGS  =

SRCS_C   = mud_lite.c

SRCS_CXX = main.cpp obfs.cpp port_hopper.cpp mf_client.cpp mf_server.cpp mf_relay.cpp \
           log.cpp misc.cpp my_ev.cpp common.cpp \
           fec_manager.cpp rnlc.cpp packet.cpp connection.cpp fd_manager.cpp delay_manager.cpp \
           lib/fec.cpp lib/rs.cpp crc32/Crc32.cpp

OBJS = $(SRCS_C:.c=.o) $(SRCS_CXX:.cpp=.o)

.PHONY: all static static-strip clean git_version test-rnlc-unit

all: git_version $(NAME)

# RNLC(--mode 2) 결정적 유닛 테스트 (인코드 → 드롭 → 디코드 복구 검증)
# rnlc.o 의 실제 의존 객체만 링크 (mf_*/main 의 전역은 불필요)
RNLC_TEST_OBJS = rnlc.o common.o fec_manager.o log.o my_ev.o \
                 lib/fec.o lib/rs.o crc32/Crc32.o
test-rnlc-unit: $(RNLC_TEST_OBJS)
	$(CXX) $(CXXFLAGS) -o test_rnlc_unit test_rnlc_unit.cpp $(RNLC_TEST_OBJS) -lrt -lpthread
	./test_rnlc_unit

# 정적 빌드: glibc 의존성 없는 독립 실행 바이너리
static: git_version $(OBJS)
	$(CXX) $(CXXFLAGS) -static -o $(NAME)-static $(OBJS) -lrt -lpthread
	@echo "Static binary: $(NAME)-static ($$(du -sh $(NAME)-static | cut -f1))"

# 정적 빌드 + strip: 배포용 (디버그 심볼 제거)
static-strip: static
	strip $(NAME)-static -o $(NAME)-dist
	@echo "Stripped static binary: $(NAME)-dist ($$(du -sh $(NAME)-dist | cut -f1))"

$(NAME): $(OBJS)
	$(CXX) $(CXXFLAGS) $(LDFLAGS) -o $@ $(OBJS) -lrt -lpthread

git_version:
	@{ \
	  GITDESC="$$(git describe --tags --dirty --always 2>/dev/null)"; \
	  [ -n "$$GITDESC" ] || GITDESC="unknown"; \
	  printf 'const char *gitversion = "%s";\n' "$$GITDESC"; \
	  printf 'const char *build_date = "%s";\n' "$$(date '+%Y-%m-%d %H:%M:%S %Z')"; \
	} > git_version.h

main.o: git_version.h

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c -o $@ $<

clean:
	rm -f $(NAME) $(NAME)-static $(NAME)-dist $(OBJS) test_rnlc_unit git_version.h
