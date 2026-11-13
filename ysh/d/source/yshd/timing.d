module yshd.timing;

// core/pyos.py:Time, osh/cmd_eval.py:_DoTimeBlock, pyext/libc.c:print_time.
import core.sys.posix.sys.time : timeval, gettimeofday;
import core.sys.posix.sys.resource : rusage, getrusage, RUSAGE_SELF;
import std.exception : ErrnoException;
import std.stdio : File;
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
