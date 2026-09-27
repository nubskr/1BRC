# Build and run 

```
zig build -Doptimize=ReleaseFast
time ./zig-out/bin/_1brc
```

# Performance

Ran on Intel Core Ultra 9 285H

```
1brc master ❯ hyperfine --warmup 2 --runs 5 './zig-out/bin/_1brc'
Benchmark 1: ./zig-out/bin/1brc
  Time (mean ± σ):     486.5 ms ±   6.6 ms    [User: 3896.8 ms, System: 508.5 ms]
  Range (min … max):   480.8 ms … 494.8 ms    5 runs

```