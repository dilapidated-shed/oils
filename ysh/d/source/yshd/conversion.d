module yshd.conversion;

import std.bigint : BigInt;
import std.math : abs, frexp, isFinite, ldexp;
import yshd.value : YshError;

/// builtin/func_misc.py:Int permits explicit Bool and Float conversion.
/// Arithmetic and method arguments retain their stricter conversion rules.
BigInt truncateFiniteFloatToInteger(double number) {
    if (!isFinite(number))
        throw new YshError("Can't convert nonfinite Float to Int");
    if (abs(number) < 1) return BigInt(0);

    // Extract the exact binary significand before removing fractional bits.
    // Narrowing the whole Float to long would lose finite integers outside
    // the machine-word range. Shift the magnitude so negatives truncate
    // toward zero, including numbers between -1 and zero.
    int exponent;
    auto fraction = frexp(abs(number), exponent);
    auto significand = cast(ulong)ldexp(fraction, double.mant_dig);
    auto magnitude = BigInt(significand);
    auto shift = exponent - double.mant_dig;
    if (shift >= 0) magnitude <<= shift;
    else magnitude >>= -shift;
    return number < 0 ? -magnitude : magnitude;
}

unittest {
    assert(truncateFiniteFloatToInteger(1.75) == 1);
    assert(truncateFiniteFloatToInteger(-1.75) == -1);
    assert(truncateFiniteFloatToInteger(-0.75) == 0);
    assert(truncateFiniteFloatToInteger(-0.0) == 0);
    assert(truncateFiniteFloatToInteger(double.min_normal) == 0);
    assert(truncateFiniteFloatToInteger(0x1p100) == (BigInt(1) << 100));
    assert(truncateFiniteFloatToInteger(-0x1p100) == -(BigInt(1) << 100));
    assert(truncateFiniteFloatToInteger(double.max) ==
        ((BigInt(1) << double.mant_dig) - 1) <<
        (double.max_exp - double.mant_dig));
    foreach (number; [double.nan, double.infinity, -double.infinity]) {
        bool rejected;
        try { truncateFiniteFloatToInteger(number); }
        catch (YshError error) { rejected = error.status == 3; }
        assert(rejected);
    }
}

unittest {
    import yshd.expr : evaluate;
    import yshd.state : Memory;
    import yshd.value : Value, ValueKind, YshDict, stringify, YshTypeError;
    assert(evaluate("int(true)").integerValue == 1);
    assert(evaluate("int(false)").integerValue == 0);
    assert(evaluate("int(-1.75)").integerValue == -1);
    assert(evaluate("int(-0.75)").integerValue == 0);
    foreach (source; ["true + 1", "false < true", "1 << true", "[1][0.0]",
            "float(true)", "int(NAN)", "int(INFINITY)"]) {
        bool rejected;
        try { evaluate(source); }
        catch (YshError error) { rejected = error.status == 3; }
        assert(rejected, source);
    }

    auto mem = new Memory();
    auto source = new YshDict();
    source.set("item", Value.str("before"));
    mem.declareLocal("shell_dict", Value.shellArray(source, true));
    auto converted = evaluate("dict(shell_dict)", mem);
    assert(converted.kind == ValueKind.dict);
    source.set("item", Value.str("after"));
    assert(converted.dictValue.get("item").stringValue == "before");
    converted.dictValue.set("extra", Value.str("independent"));
    assert(!source.contains("extra"));

    assert(stringify(Value.floating(double.infinity)) == "inf");
    assert(stringify(Value.floating(-double.infinity)) == "-inf");
    assert(stringify(Value.floating(double.nan)) == "nan");
}
