module yshd.options;

import std.algorithm : sort;
import yshd.option_data : OptionSpec, optionSpecs;
import yshd.value : UsageError;

/// Option cells and scoped overlays follow core/state.py:MutableOpts. Metadata
/// is generated from frontend/option_def.py, including default-true inversion
/// in permanent option groups. A scoped group pushes the requested value.
class ShellOptions {
    private bool[] values_;
    private bool[][] overlays_;

    this(bool ysh = false) {
        values_.length = optionSpecs.length + 1;
        overlays_.length = values_.length;
        foreach (spec; optionSpecs) values_[spec.number] = spec.defaultValue;
        if (ysh) set("ysh:all", true);
    }

    static string canonicalGroup(string name) {
        if (name == "oil:all") return "ysh:all";
        if (name == "oil:upgrade") return "ysh:upgrade";
        return name;
    }

    static bool isGroup(string name) {
        name = canonicalGroup(name);
        return name == "ysh:all" || name == "ysh:upgrade" || name == "strict:all";
    }

    static size_t number(string name, bool allowUnimplemented = false) {
        foreach (spec; optionSpecs) {
            if (spec.name == name && (spec.implemented || allowUnimplemented)) return spec.number;
        }
        throw new UsageError("invalid shell option: " ~ name);
    }

    static immutable(OptionSpec)* spec(size_t number) {
        assert(number > 0 && number <= optionSpecs.length);
        return &optionSpecs[number - 1];
    }

    bool get(size_t number) const {
        auto stack = overlays_[number];
        return stack.length ? stack[$ - 1] : values_[number];
    }

    bool get(string name) const {
        return get(number(name, true));
    }

    size_t[] expand(string name) const {
        name = canonicalGroup(name);
        if (!isGroup(name)) return [number(name, get("ignore_shopt_not_impl"))];
        size_t[] result;
        foreach (spec; optionSpecs) foreach (group; spec.groups) {
            if (group == name) { result ~= spec.number; break; }
        }
        sort!((a, b) => spec(a).name < spec(b).name)(result);
        return result;
    }

    void set(string name, bool enabled) {
        if (isGroup(name)) {
            foreach (number; expand(name))
                values_[number] = spec(number).defaultValue ? !enabled : enabled;
            return;
        }
        set(number(name, get("ignore_shopt_not_impl")), enabled);
    }

    void set(size_t number, bool enabled) {
        if (spec(number).builtin.length == 0)
            throw new UsageError("shell option cannot be changed: " ~ spec(number).name);
        // POSIX defers a permanent errexit change until condition overlays end.
        if (spec(number).name == "errexit" || overlays_[number].length == 0)
            values_[number] = enabled;
        else overlays_[number][$ - 1] = enabled;
    }

    void setOld(string name, bool enabled) {
        if (isGroup(name)) { set(name, enabled); return; }
        auto index = number(name);
        if (spec(index).builtin != "set") throw new UsageError("invalid set option: " ~ name);
        set(index, enabled);
    }

    static string shortName(char flag) {
        foreach (spec; optionSpecs)
            if (spec.shortFlag.length == 1 && spec.shortFlag[0] == flag) return spec.name;
        throw new UsageError("invalid shell flag: " ~ flag);
    }

    void push(size_t[] numbers, bool enabled) {
        foreach (number; numbers) overlays_[number] ~= enabled;
    }

    size_t[] pushExpression() {
        size_t[] numbers;
        foreach (name; ["command_sub_errexit", "errexit", "pipefail",
                "inherit_errexit", "strict_errexit"]) numbers ~= number(name);
        push(numbers, true);
        return numbers;
    }

    void pop(size_t[] numbers) {
        foreach_reverse (number; numbers) {
            assert(overlays_[number].length);
            --overlays_[number].length;
        }
    }

    size_t[] visible(bool setOptions = false) const {
        size_t[] result;
        foreach (spec; optionSpecs)
            if (spec.implemented && spec.builtin == (setOptions ? "set" : "shopt"))
                result ~= spec.number;
        sort!((a, b) => spec(a).name < spec(b).name)(result);
        return result;
    }
}

unittest {
    auto options = new ShellOptions();
    assert(!options.get("errexit") && options.get("expand_aliases"));
    options.set("oil:all", true);
    assert(options.get("errexit") && options.get("command_sub_errexit"));
    assert(options.get("expand_aliases"));
    auto selected = options.expand("errexit");
    options.push(selected, false);
    options.set("errexit", true);
    assert(!options.get("errexit"));
    options.pop(selected);
    assert(options.get("errexit"));
    options.set("ysh:all", false);
    assert(!options.get("errexit"));
}
