size ?= 1000000
nprocs ?= 1 2 4 8
uname := $(shell uname)
ifeq ($(uname),Darwin)
	format := macho64
	perf := time
endif
ifeq ($(UNAME),Linux)
	format := elf64
	perf := perf stat
endif

.PHONY: perf_test integrity_check clean

perf_execs := $(foreach n,$(nprocs),concurrency-noprint-x$(n))
perf_test: $(perf_execs)
	for x in $(perf_execs) ; do $(perf) ./$$x ; done

out_files := $(foreach n,$(nprocs),out-$(n))
integrity_check: $(out_files)
	diff -q -s --from-file=$< $(filter-out $<,$^)

clean:
	rm -f concurrency-* out-*

out-%: concurrency-print-x%
	./$< >$@

concurrency-%: concurrency-%.o
	ld -lc $^ -o $@

concurrency-print-x%.o: concurrency.asm
	nasm -f $(format) -DSIZE=$(size) -DNPROCS=$* $^ -o $@

concurrency-noprint-x%.o: concurrency.asm
	nasm -f $(format) -DNOPRINT -DSIZE=$(size) -DNPROCS=$* $^ -o $@
