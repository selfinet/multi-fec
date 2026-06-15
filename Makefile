NAME = multi-fec
CC   = gcc
CXX  = g++

CFLAGS   = -std=c11   -Wall -O2 -I. -isystem libev
CXXFLAGS = -std=c++11 -Wall -O2 -I. -isystem libev
LDFLAGS  =

SRCS_C   = mud_lite.c

SRCS_CXX = main.cpp obfs.cpp port_hopper.cpp mf_client.cpp mf_server.cpp mf_relay.cpp \
           log.cpp misc.cpp my_ev.cpp common.cpp \
           fec_manager.cpp packet.cpp connection.cpp fd_manager.cpp delay_manager.cpp \
           lib/fec.cpp lib/rs.cpp crc32/Crc32.cpp

OBJS = $(SRCS_C:.c=.o) $(SRCS_CXX:.cpp=.o)

.PHONY: all static static-strip clean git_version

all: git_version $(NAME)

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
	  echo 'const char *gitversion = "local-build";'; \
	  echo "const char *build_date = \"$$(date '+%Y-%m-%d %H:%M:%S %Z')\";"; \
	} > git_version.h

main.o: git_version.h

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c -o $@ $<

clean:
	rm -f $(NAME) $(NAME)-static $(NAME)-dist $(OBJS) git_version.h
