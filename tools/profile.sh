#!/bin/sh
# Where Zit's time goes, without perf: sample every thread's stack with
# eu-stack and count the frames on top.
#
#   tools/profile.sh [repository] [samples] [settle seconds]
#
# Builds an unstripped Zit into .zig-cache/profile (symbols, or the stacks are
# addresses). Yama's ptrace_scope=1 lets only a parent trace a process, and
# eu-stack is not Zit's parent: a two-line preload library has Zit allow any
# tracer instead. Config and cache are throwaway; CACHE keeps a cache, as in
# tools/measure.sh.
set -eu
repo=${1:-.}
samples=${2:-150}
settle=${3:-15}
out=.zig-cache/profile
mkdir -p "$out"

zig build -Dstrip=false -p "$out" >/dev/null
printf '#include <sys/prctl.h>\n__attribute__((constructor)) static void allow(void) { prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY, 0, 0, 0); }\n' >"$out/allow.c"
zig cc -shared -fPIC -o "$out/allow.so" "$out/allow.c"

tmp=$(mktemp -d)
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
LD_PRELOAD=$PWD/$out/allow.so XDG_CONFIG_HOME=$tmp/config XDG_CACHE_HOME=${CACHE:-$tmp/cache} "$out/bin/zit" "$repo" >/dev/null 2>&1 &
pid=$!
sleep "$settle"

: >"$tmp/stacks"
i=0
while [ $i -lt "$samples" ]; do
    eu-stack -p "$pid" >>"$tmp/stacks" 2>/dev/null || true
    sleep 0.05
    i=$((i + 1))
done

# Each thread's top frame, then every frame anywhere on a stack: the first
# says who is busy, the second what they are busy inside.
echo "top of stack, per thread (a thread parked in a wait is idle):"
awk '/^TID/ {tid = $2; getline; sub(/^#[0-9]+ +0x[0-9a-f]+ /, ""); sub(/ - .*/, ""); n[tid " " $0]++} END {for (k in n) print n[k], k}' "$tmp/stacks" | sort -rn | head -15
echo
echo "on any stack:"
awk '/^#/ {sub(/^#[0-9]+ +0x[0-9a-f]+ /, ""); sub(/ - .*/, ""); print}' "$tmp/stacks" | sort | uniq -c | sort -rn | head -40
