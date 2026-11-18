# Lua RGW table benchmark: runs on 2026-11-17

Baseline vs candidate, run with `lua-bench/run_all.sh`.

| | tree | branch | RGW table implementation |
|---|---|---|---|
| **baseline** | `~/code/ceph` | `wip-lua-bench` (`main` + a Prometheus commit) | `main`: `std::unordered_map` + one `std::mutex`; `pairs()` iterates without a lock |
| **candidate** | `~/code/ceph-tbb` | `wip-lua-tbb` (uncommitted changes) | 256 shards, each a plain `std::map` (not a TBB container) guarded by a `tbb::spin_rw_mutex`, plus a `tbb::spin_mutex` on each entry; stateless `pairs()`. TBB is used only for the locks |

**Settings for both runs:**
- runner defaults: `RESTART_EACH=1`, `DURATION=60s`, `CONCURRENT=100`, `GAP=30`, `SCRIPT_SETTLE=10`;
- `warp mixed --obj.size=1` against `localhost:8000`;
- each run used a fresh `vstart -n -d` cluster (1 MON, 1 OSD, 1 RGW);
- both trees are **Debug** builds.

## Run 1: `20261117-220119` (all scripts; stopped at script 3)

Started 22:02. Scripts ran in alphabetical order; each script ran on the baseline, then the candidate.

| # | script | tree | warp start | end | total obj/s | GET p50 / p99 (ms) | result |
|---|---|---|---|---|---|---|---|
| 1 | bucket_stats | baseline | 22:02:13 | 22:03:34 | 2,365 | 48.6 / 344.4 | ok |
| 2 | bucket_stats | candidate | 22:04:49 | 22:06:31 | 1,782 | 49.3 / 419.0 | ok |
| 3 | hot_increment | baseline | 22:08:23 | 22:09:44 | 1,924 | 48.5 / 344.3 | ok |
| 4 | hot_increment | candidate | 22:10:57 | 22:12:20 | 1,878 | 50.7 / 389.4 | ok |
| 5 | iter_invariant | baseline | 22:13:20 | 22:13:43 | — | — | **radosgw crashed** |
| — | iter_invariant | candidate | — | — | — | — | not run |
| — | large_values, per_request_keys, prune_ttl, read_mostly, scan_readonly, scan_with_writers | both | — | — | — | — | not run |

**The crash (run 5):**
- Baseline radosgw segfaulted 16 s into `iter_invariant` (`Caught signal (Segmentation fault)` at 22:13:36).
- Backtrace: `luaL_tolstring` → the `__tostring` closure in `create_iterator_metadata<std::unordered_map<...>>` → `lua_pushlstring`.
- Cause: on `main`, `pairs(RGW)` keeps a raw C++ iterator and walks the map without a lock. `tostring(k)` reads through that iterator after other requests' inserts and erases have freed or moved the entry.
- This is the data race the script was written to expose.
- The runner then stopped completely, because `set -e` exited on warp's error. That has since been fixed: crashes are now recorded and the run continues.

## Run 2: `20261117-221713` (`SET=safe`: scripts that never call `pairs(RGW)`)

Started 22:17. These scripts never iterate the table, so they can't hit the race above.

| # | script | tree | warp start | end | total obj/s | GET p50 / p99 (ms) | errors |
|---|---|---|---|---|---|---|---|
| 1 | bucket_stats | baseline | 22:17:58 | 22:19:19 | 2,415 | 55.4 / 340.9 | 0 |
| 2 | bucket_stats | candidate | 22:20:39 | 22:22:26 | 1,943 | 125.4 / 676.3 | 0 |
| 3 | hot_increment | baseline | 22:24:18 | 22:25:41 | 2,089 | 48.2 / 238.8 | 0 |
| 4 | hot_increment | candidate | 22:26:55 | 22:28:16 | 2,242 | 50.2 / 273.0 | 0 |
| 5 | large_values | baseline | 22:29:30 | 22:30:52 | 2,251 | 52.9 / 273.3 | 0 |
| 6 | large_values | candidate | 22:32:06 | 22:33:30 | 2,495 | 50.2 / 179.0 | 0 |
| 7 | per_request_keys | baseline | 22:34:44 | 22:36:06 | 2,118 | 52.6 / 340.3 | 0 |
| 8 | per_request_keys | candidate | 22:37:20 | 22:38:40 | 2,077 | 50.3 / 263.5 | 0 |
| 9 | read_mostly | baseline | 22:39:54 | 22:41:18 | 2,190 | 52.8 / 260.4 | 0 |
| 10 | read_mostly | candidate | 22:42:33 | 22:44:01 | 2,007 | 53.3 / 285.0 | 0 |

Not run: `iter_invariant`, `prune_ttl`, `scan_readonly` and `scan_with_writers`. These call `pairs(RGW)`, so they were excluded by `SET=safe`.

No crashes. The surviving radosgw logs (from `read_mostly`, the last run in each tree) show 0 Lua errors.

## What the numbers mean

**Columns:**
- **total obj/s** is aggregate throughput: all S3 operations warp completed, divided by the run time.
- **GET p50 / p99** is per-request latency, end to end: HTTP, auth, RADOS and the OSD, logging, and the Lua script.
- Neither column isolates the Lua script's own time.

**Baseline → candidate, total obj/s:**

| script | run 1 | run 2 |
|---|---|---|
| bucket_stats | −24.6% | −19.5% |
| hot_increment | −2.4% | +7.4% |
| large_values | — | +10.8% |
| per_request_keys | — | −1.9% |
| read_mostly | — | −8.3% |

**Most of these differences are noise from the setup, not the table:**
- **Every script lands at about the same throughput** (1,800–2,500 obj/s), whether it does about 9 or about 500 table operations per request.
- **Throughput sometimes collapsed.** In some 1-second windows it dropped to 48–613 obj/s.
- **`hot_increment` changed direction** between run 1 and run 2.
- **Debug logging dominated the run.** The `-d` flag sets `debug_rgw=20`. The candidate's radosgw log for one 60 s run was 2.85 GB, 21.8 million lines. Logging plus Debug builds cost far more per request than the table operations do.

**The one result that repeated: `bucket_stats` was slower on the candidate in both runs (−25%, −20%).**
- In a real gateway, `Request.Bucket.Name` is always `my-bucket`, so every request updates the same ~8 keys. That makes it a hot-key workload.
- That differs from the offline benchmark, where the script picks from 1,000 random buckets.
- **Possible cause:** with 100 concurrent requests on a Debug build, the candidate's spinning locks (`tbb::spin_rw_mutex` and the entry `spin_mutex`) may waste CPU where `main`'s `std::mutex` puts waiting threads to sleep.
- This is a hypothesis to test, not a conclusion. Check it with Release builds, logging off, and repeated runs.

## Lua script time per request (radosgw metrics, run 2)

Both trees export `rgw_lua_duration_seconds`, a Prometheus histogram.
- **What it times:** `rgw_process.cc` wraps exactly the `rgw::lua::request::execute(...)` call for the prerequest script with `steady_clock` (identical code in both trees). That's the script's own time per request, without the rest of the S3 request.
- **Bucket edges:** 1, 2.5, 5, 10, 25 … ms, so anything under 1 ms shows up as about 1 ms.

The p95 values below are read by eye from the dashboard (`runs.png`):

| script | baseline p95 | candidate p95 | |
|---|---|---|---|
| bucket_stats | ≤1 ms | ≤1 ms | under the histogram's resolution for both |
| hot_increment | ~1.5–1.7 ms | ≤1 ms | candidate faster |
| large_values | ~1.8–2.0 ms | ≤1 ms | candidate faster |
| per_request_keys | ~7.5–8.2 ms | ≤1 ms | **candidate at least 7× faster** |
| read_mostly | ~4.6–5.0 ms | ~2.5–2.9 ms | candidate ~1.8× faster |

**This is the real per-request difference, and the candidate wins every pair where it can be measured.**
- The baseline's single global `std::mutex` makes concurrent requests queue for each table access.
- The ranking matches how many table operations each script does and how much `main`'s one mutex serializes them: `per_request_keys` does ~420 operations on keys no other request touches, so on the candidate those requests never wait for each other.

**Why warp throughput didn't show it:**
- **The Lua time is a small part of each request.** A few milliseconds of Lua is small next to the tens to hundreds of milliseconds each S3 request spends in the Debug-built RGW and RADOS paths with debug logging on.
- **The cluster caps throughput** at about 2–2.9K completions per second in every run.

**`bucket_stats`:** its Lua time is under 1 ms in both trees, so its ~20% lower warp throughput on the candidate isn't explained by slower script execution, at least at p95. It's more likely noise or something outside the script, and needs repeated runs to tell.

## To get a meaningful comparison next time

1. Build both trees as `RelWithDebInfo` (or `Release`).
2. Start the clusters without `-d` (or set `debug_rgw = 1`, `debug_ms = 0`).
3. Add a no-script control run for each tree, so a script's cost is the drop from "no script" to "script".
4. Repeat each baseline/candidate pair at least 3 times and compare medians.
5. Measure the Lua script's own time inside radosgw, for example with a timer around `rgw::lua::request::execute` reported as a perf counter.
6. Run the scripts that call `pairs(RGW)` separately. They check correctness: whether `main` crashes, and whether the candidate's iteration stays correct.
