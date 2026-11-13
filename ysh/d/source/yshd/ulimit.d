module yshd.ulimit;

// builtin/process_osh.py:Ulimit and frontend/flag_def.py:ULIMIT_SPEC.
// Resource identities and ABI widths come from the target's POSIX headers.
import core.sys.posix.sys.resource : rlimit, rlim_t, RLIM_INFINITY,
    RLIMIT_CORE, RLIMIT_DATA, RLIMIT_FSIZE, RLIMIT_NOFILE, RLIMIT_STACK,
    RLIMIT_CPU, RLIMIT_AS, getrlimit, setrlimit;
import core.stdc.errno : errno;
import core.stdc.string : strerror;
import std.bigint : BigInt, toDecimalString;
import std.conv : to;
import std.format : format;
import std.string : startsWith, strip;
import yshd.state : Memory;
import yshd.value : UsageError;

private struct Resource {
    char flag;
    int identifier;
    uint factor;
    string description;
}

private immutable Resource[7] resources = [
    Resource('c', RLIMIT_CORE, 512, "core dump size"),
    Resource('d', RLIMIT_DATA, 1024, "data segment size"),
    Resource('f', RLIMIT_FSIZE, 512, "file size"),
    Resource('n', RLIMIT_NOFILE, 1, "file descriptors"),
    Resource('s', RLIMIT_STACK, 1024, "stack size"),
    Resource('t', RLIMIT_CPU, 1, "CPU seconds"),
    Resource('v', RLIMIT_AS, 1024, "address space size")
];

private string limitString(rlim_t limit, uint factor) {
    return limit == RLIM_INFINITY ? "unlimited" : to!string(limit / factor);
}

private rlim_t parseLimit(string word, uint factor) {
    if (word == "unlimited") return cast(rlim_t)RLIM_INFINITY;
    // LooksLikeInteger admits only ASCII space/tab/CR/LF and an optional '-'.
    auto number = strip(word, " \t\r\n");
    auto start = number.length && number[0] == '-' ? 1 : 0;
    if (start == number.length) throw new UsageError("ulimit: expected a number or 'unlimited'");
    foreach (character; number[start .. $])
        if (character < '0' || character > '9')
            throw new UsageError("ulimit: expected a number or 'unlimited'");
    auto value = BigInt(number);
    if (value < BigInt(long.min) || value > BigInt(long.max))
        throw new UsageError("ulimit: integer too big");
    if (value < 0) throw new UsageError("ulimit: doesn't accept negative numbers");
    // The retained mops input and multiply boundary is signed 64-bit even
    // though Linux rlim_t is unsigned. Check before narrowing or multiplying.
    auto scaled = value * factor;
    if (scaled > BigInt(long.max) || scaled > BigInt(rlim_t.max))
        throw new UsageError("ulimit: detected integer overflow");
    return to!rlim_t(toDecimalString(scaled));
}

private int resourceError(Memory mem) {
    auto message = to!string(strerror(errno));
    mem.errorFile.writeln("oils: ulimit error: ", message);
    return 1;
}

int runUlimit(string[] words, Memory mem) {
    bool hard, soft, all;
    bool[7] selected;
    size_t index;
    for (; index < words.length; ++index) {
        auto word = words[index];
        if (word == "--") { ++index; break; }
        // The reference's zero-arity long flag ignores an attached value.
        if (word == "--all" || word.startsWith("--all=")) { all = true; continue; }
        if (word.length < 2 || word[0] != '-') break;
        foreach (flag; word[1 .. $]) {
            if (flag == 'H') hard = true;
            else if (flag == 'S') soft = true;
            else if (flag == 'a') all = true;
            else {
                bool found;
                foreach (resourceIndex, resource; resources) if (resource.flag == flag) {
                    selected[resourceIndex] = true; found = true; break;
                }
                if (!found) throw new UsageError("ulimit: invalid flag " ~ word);
            }
        }
    }
    size_t count, resourceIndex = 2; // -f is the default.
    foreach (candidate, enabled; selected) if (enabled) { ++count; resourceIndex = candidate; }
    if (count > 1) throw new UsageError("ulimit: can only handle one resource at a time");
    if (all) {
        if (count) throw new UsageError("ulimit: doesn't accept resource flags with -a");
        if (index != words.length) throw new UsageError("ulimit: got extra arg with -a");
        mem.outputFile.writeln(format("%5s %15s %15s %7s  %s", "FLAG", "SOFT", "HARD", "FACTOR", "DESC"));
        foreach (resource; resources) {
            rlimit limits;
            if (getrlimit(resource.identifier, &limits) < 0) return resourceError(mem);
            mem.outputFile.writeln(format("%5s %15s %15s %7s  %s", "-" ~ resource.flag,
                limitString(limits.rlim_cur, resource.factor), limitString(limits.rlim_max, resource.factor),
                to!string(resource.factor), resource.description));
        }
        return 0;
    }
    auto resource = resources[resourceIndex];
    // Validate operands before querying or changing kernel state.
    bool setting = index < words.length;
    rlim_t requested;
    if (setting) {
        requested = parseLimit(words[index++], resource.factor);
        if (index != words.length) throw new UsageError("ulimit: got extra arg");
    }
    rlimit limits;
    if (getrlimit(resource.identifier, &limits) < 0) return resourceError(mem);
    if (!setting) {
        mem.outputFile.writeln(limitString(hard ? limits.rlim_max : limits.rlim_cur, resource.factor));
        return 0;
    }
    if (soft || !hard) limits.rlim_cur = requested;
    if (hard || !soft) limits.rlim_max = requested;
    if (setrlimit(resource.identifier, &limits) < 0) return resourceError(mem);
    return 0;
}

unittest {
    assert(parseLimit("0", 512) == 0);
    assert(parseLimit(" -0 \t", 512) == 0);
    assert(parseLimit("00064", 1) == 64);
    static if (rlim_t.sizeof >= 8) {
        assert(parseLimit("4294967296", 512) == 2199023255552UL);
        assert(parseLimit("9007199254740992", 512) == 4611686018427387904UL);
    }
    assert(parseLimit("unlimited", 1) == RLIM_INFINITY);
    foreach (bad; ["", "-1", "+1", "1_0", "0x10", "1.5", "unlimited ", "\v1",
            "9223372036854775808", "-9223372036854775809", "18014398509481984", "4611686018427387905"]) {
        bool rejected;
        try { parseLimit(bad, 512); }
        catch (UsageError error) { rejected = true; }
        assert(rejected, bad);
    }
}
