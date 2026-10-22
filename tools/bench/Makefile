# mf_bench — multi-fec 핫패스 벤치마크 (정적 바이너리, 다른 장비에 그대로 복사해 실행)
ROOT = ../..
mf_bench: mf_bench.cpp $(ROOT)/lib/rs.cpp $(ROOT)/lib/fec.cpp $(ROOT)/obfs.cpp
	$(CXX) -std=c++11 -O2 -Wall -static -I$(ROOT) -o $@ $^
	strip $@
clean:
	rm -f mf_bench
