module yshd.timing;

// core/pyos.py:Time, osh/cmd_eval.py:_DoTimeBlock, pyext/libc.c:print_time.
import core.sys.posix.sys.time : timeval, gettimeofday;
import core.sys.posix.sys.resource : rusage, getrusage, RUSAGE_SELF;
import core.sys.posix.unistd : sysconf, _SC_CLK_TCK;
import core.stdc.errno : EINVAL;
import std.exception : ErrnoException;
import std.format : format;
import std.stdio : File;
import yshd.libc_process : clock_t, tms, posixTimes = times;
import yshd.value : YshError;

struct TimingSnapshot {
    long wallMicroseconds;
    long userMicroseconds;
    long systemMicroseconds;
}

private long microseconds(timeval value) {
    return cast(long)value.tv_sec * 1_000_000 + value.tv_usec;
}

TimingSnapshot snapshotTimes() {
    timeval wall;
    rusage usage;
    if (gettimeofday(&wall, null) != 0 || getrusage(RUSAGE_SELF, &usage) != 0)
        throw new YshError("native timing snapshot failed", 1);
    return TimingSnapshot(microseconds(wall), microseconds(usage.ru_utime), microseconds(usage.ru_stime));
}

void reportTiming(TimingSnapshot before, TimingSnapshot after, File errors) {
    // The retained C printer ignores fprintf errors. A closed stderr must
    // not replace the timed command's status with a diagnostic failure.
    if (!errors.isOpen) return;
    try {
        // Keep native microseconds for accounting. Floating conversion is
        // confined to the reference's fixed three-decimal display boundary.
        errors.writef("real\t%.3f\nuser\t%.3f\nsys\t%.3f\n",
            cast(double)(after.wallMicroseconds - before.wallMicroseconds) / 1_000_000,
            cast(double)(after.userMicroseconds - before.userMicroseconds) / 1_000_000,
            cast(double)(after.systemMicroseconds - before.systemMicroseconds) / 1_000_000);
        errors.flush();
    } catch (ErrnoException error) { }
}

private string processClock(clock_t ticks, long ticksPerSecond) {
    auto wholeSeconds = ticks / ticksPerSecond;
    auto seconds = cast(double)(wholeSeconds % 60) +
        cast(double)(ticks % ticksPerSecond) / ticksPerSecond;
    // Keep absolute native counters as ticks. Floating conversion belongs
    // only to the retained PrintTimes three-decimal display boundary.
    return format("%dm%.3fs", wholeSeconds / 60, seconds);
}

void printProcessTimes(File output) {
    // builtin/misc_osh.py:Times, core/pyos.py:PrintTimes, POSIX times(2).
    // These are cumulative self and reaped-child totals, not time deltas.
    tms accounting;
    if (posixTimes(&accounting) == cast(clock_t)-1) throw new ErrnoException("times");
    auto ticksPerSecond = sysconf(_SC_CLK_TCK);
    if (ticksPerSecond <= 0) throw new ErrnoException("times: invalid clock tick rate", EINVAL);
    output.writeln(processClock(accounting.tms_utime, ticksPerSecond), " ",
        processClock(accounting.tms_stime, ticksPerSecond));
    output.writeln(processClock(accounting.tms_cutime, ticksPerSecond), " ",
        processClock(accounting.tms_cstime, ticksPerSecond));
    // The builtin boundary owns flushing and reports I/O failures as status1.
}

unittest {
    assert(processClock(6123, 100) == "1m1.230s");
    assert(processClock(5999, 100) == "0m59.990s");
    assert(processClock(12001, 100) == "2m0.010s");
    assert(processClock(1, 128) == "0m0.008s");
    assert(processClock(1, 250) == "0m0.004s");
    assert(processClock(5_999_960, 100_000) == "0m60.000s");
}

unittest {
    auto errors = File.tmpfile();
    reportTiming(TimingSnapshot(1_000_000, 200_000, 300_000),
        TimingSnapshot(2_234_567, 201_234, 302_789), errors);
    errors.rewind();
    assert(errors.readln() == "real\t1.235\n");
    assert(errors.readln() == "user\t0.001\n");
    assert(errors.readln() == "sys\t0.003\n");
    reportTiming(TimingSnapshot.init, TimingSnapshot.init, File.init);
}
