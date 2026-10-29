#!/bin/sh
# Zit's footprint, measured rather than supposed: run it on a repository with a
# throwaway config and cache, let it settle, then read the kernel's numbers.
#
#   tools/measure.sh [binary] [repository] [idle seconds]
#
# RSS is what the kernel charges the process, shared pages included; the
# memory Zit itself is responsible for is Private_Dirty, from smaps_rollup.
# Idle CPU is the process's ticks over the idle window. Run it a few times and
# keep the lowest: the window opens on the desktop, and anything that happens
# to it there — a mouse crossing it — only ever adds. Fails when a number
# is over the ceilings in docs/PERF.md (override with MAX_RSS_MB, MAX_PEAK_MB,
# MAX_DIRTY_MB, MAX_IDLE_CPU — the last in percent). CACHE names a cache folder to keep
# between runs: a fresh one has every author's picture still to fetch, which
# is start-up work, not idling. SETTLE is how long start-up gets, 40 s by
# default: the first background fetch goes 20 s after a repository opens.
set -eu
bin=${1:-zig-out/bin/zit}
repo=${2:-.}
idle=${3:-20}
settle=${SETTLE:-40}
max_rss=${MAX_RSS_MB:-64}
max_peak=${MAX_PEAK_MB:-96}
max_dirty=${MAX_DIRTY_MB:-40}
max_cpu=${MAX_IDLE_CPU:-0.5}

tmp=$(mktemp -d)
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
XDG_CONFIG_HOME=$tmp/config XDG_CACHE_HOME=${CACHE:-$tmp/cache} "$bin" "$repo" >/dev/null 2>&1 &
pid=$!
sleep "$settle"
kill -0 "$pid" 2>/dev/null || { echo "zit exited during start-up" >&2; exit 1; }

ticks() { sed 's/.*) //' "/proc/$pid/stat" | awk '{print $12 + $13}'; }
# Every thread's context switches: how often the process wakes at all — the
# number "idle" should hold at zero, and one a desktop's noise moves less than
# CPU time (a mouse crossing the window costs frames, not many wake-ups).
switches() { cat /proc/"$pid"/task/*/status 2>/dev/null | awk '/ctxt_switches/ {n += $2} END {print n}'; }
kb() { awk -v k="$1:" '$1 == k {print $2}' "$2"; }

t0=$(ticks)
s0=$(switches)
sleep "$idle"
t1=$(ticks)
s1=$(switches)
hz=$(getconf CLK_TCK)

rss=$(kb VmRSS "/proc/$pid/status")
hwm=$(kb VmHWM "/proc/$pid/status")
dirty=$(kb Private_Dirty "/proc/$pid/smaps_rollup")
cpu=$(awk -v d=$((t1 - t0)) -v hz="$hz" -v s="$idle" 'BEGIN {printf "%.2f", d / hz / s * 100}')

printf 'repository     %s (%s commits)\n' "$repo" "$(git -C "$repo" rev-list --all --count 2>/dev/null || echo ?)"
printf 'RSS            %d MB   (ceiling %d)\n' $((rss / 1024)) "$max_rss"
printf 'peak RSS       %d MB   (ceiling %d)\n' $((hwm / 1024)) "$max_peak"
printf 'Private_Dirty  %d MB   (ceiling %d)\n' $((dirty / 1024)) "$max_dirty"
printf 'idle CPU       %s %%   over %ss, %d ticks (ceiling %s)\n' "$cpu" "$idle" $((t1 - t0)) "$max_cpu"
printf 'wake-ups       %s /s\n' "$(awk -v d=$((s1 - s0)) -v s="$idle" 'BEGIN {printf "%.1f", d / s}')"

fail=0
[ $((rss / 1024)) -le "$max_rss" ] || { echo "over: RSS"; fail=1; }
[ $((hwm / 1024)) -le "$max_peak" ] || { echo "over: peak RSS"; fail=1; }
[ $((dirty / 1024)) -le "$max_dirty" ] || { echo "over: Private_Dirty"; fail=1; }
awk -v c="$cpu" -v m="$max_cpu" 'BEGIN {exit !(c <= m)}' || { echo "over: idle CPU"; fail=1; }
exit $fail
