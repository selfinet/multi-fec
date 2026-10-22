# mf_bench — multi-fec 핫패스 벤치마크 (정적 바이너리, 다른 장비에 그대로 복사해 실행)
ROOT = ../..
mf_bench: mf_bench.cpp $(ROOT)/lib/rs.cpp $(ROOT)/lib/fec.cpp $(ROOT)/obfs.cpp
	$(CXX) -std=c++11 -O2 -Wall -static -I$(ROOT) -o $@ $^
	strip $@
clean:
	rm -f mf_bench
# A 방식 시제품: lib/fec.cpp 사본의 addmul1 만 SSSE3 로 (MF_NO_SIMD=1 로 끄면 기존 경로)
mf_bench_simd: mf_bench.cpp $(ROOT)/lib/rs.cpp fec_simd.cpp $(ROOT)/obfs.cpp
	$(CXX) -std=c++11 -O2 -Wall -static -I$(ROOT) -I$(ROOT)/lib -o $@ $^
	strip $@
