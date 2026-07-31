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

.PHONY: all static static-strip clean git_version test-rnlc-unit asan FORCE

all: $(NAME)

# RNLC(--mode 2) 결정적 유닛 테스트 (인코드 → 드롭 → 디코드 복구 검증)
# rnlc.o 의 실제 의존 객체만 링크 (mf_*/main 의 전역은 불필요)
RNLC_TEST_OBJS = rnlc.o common.o fec_manager.o log.o my_ev.o \
                 lib/fec.o lib/rs.o crc32/Crc32.o
test-rnlc-unit: $(RNLC_TEST_OBJS)
	$(CXX) $(CXXFLAGS) -o test_rnlc_unit test_rnlc_unit.cpp $(RNLC_TEST_OBJS) -lrt -lpthread
	./test_rnlc_unit

# ASAN/UBSAN 빌드: 메모리 오류·미정의 동작 검출용 (배포용 아님)
# 사용: make asan → ./multi-fec-asan  (테스트 스크립트에 BIN=./multi-fec-asan)
asan:
	$(MAKE) clean
	$(MAKE) $(NAME) \
	    CFLAGS="-std=c11 -Wall -O1 -g -fsanitize=address,undefined -I. -isystem libev" \
	    CXXFLAGS="-std=c++11 -Wall -O1 -g -fsanitize=address,undefined -I. -isystem libev" \
	    LDFLAGS="-fsanitize=address,undefined"
	mv $(NAME) $(NAME)-asan
	@echo "ASAN/UBSAN binary: $(NAME)-asan"

# 정적 빌드: glibc 의존성 없는 독립 실행 바이너리
static: $(OBJS)
	$(CXX) $(CXXFLAGS) -static -o $(NAME)-static $(OBJS) -lrt -lpthread
	@echo "Static binary: $(NAME)-static ($$(du -sh $(NAME)-static | cut -f1))"

# 정적 빌드 + strip: 배포용 (디버그 심볼 제거)
static-strip: static
	strip $(NAME)-static -o $(NAME)-dist
	@echo "Stripped static binary: $(NAME)-dist ($$(du -sh $(NAME)-dist | cut -f1))"

$(NAME): $(OBJS)
	$(CXX) $(CXXFLAGS) $(LDFLAGS) -o $@ $(OBJS) -lrt -lpthread

# git_version.h 는 실제 파일 타깃이어야 한다.
# 이전에는 phony 타깃 git_version 이 이 파일을 만들고 all: git_version $(NAME) 순서에만
# 의존했는데, -j 빌드에서 make 는 두 선행조건을 동시에 진행하므로 main.o 가 헤더보다
# 먼저 시작해 "git_version.h 를 만들 규칙이 없습니다"로 실패했다(make clean && make -j 재현).
# FORCE 로 매 빌드 재생성하는 동작은 그대로 유지한다(빌드 시각을 기록하므로).
git_version.h: FORCE
	@{ \
	  GITDESC="$$(git describe --tags --dirty --always 2>/dev/null)"; \
	  [ -n "$$GITDESC" ] || GITDESC="unknown"; \
	  printf 'const char *gitversion = "%s";\n' "$$GITDESC"; \
	  printf 'const char *build_date = "%s";\n' "$$(date '+%Y-%m-%d %H:%M:%S %Z')"; \
	} > $@

# 기존 문서·스크립트가 쓰는 `make git_version` 호출을 계속 지원하기 위한 별칭
git_version: git_version.h

FORCE:

main.o: git_version.h

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c -o $@ $<

clean:
	rm -f $(NAME) $(NAME)-static $(NAME)-dist $(OBJS) test_rnlc_unit git_version.h
