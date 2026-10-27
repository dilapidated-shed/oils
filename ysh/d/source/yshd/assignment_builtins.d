module yshd.assignment_builtins;

import yshd.state : Memory;
import yshd.value : Value, ValueKind, UsageError, YshError;
import std.string : indexOf;

private bool identifier(string name) {
    if (!name.length || name[0] >= '0' && name[0] <= '9') return false;
    foreach (ch; name) if (!(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' ||
            ch >= '0' && ch <= '9' || ch == '_')) return false;
    return true;
}

int runAssignmentBuiltin(string command, string[] words, Memory mem) {
    if (command == "export" && mem.options.get("no_exported")) {
        mem.errorFile.writeln("YSH doesn't have export; use setglobal ENV"); return 1;
    }
    bool unexport, listing, functions, variables;
    size_t index;
    for (; index < words.length; ++index) {
        auto word = words[index];
        if (word == "--") { ++index; break; }
        if (word.length < 2 || word[0] != '-') break;
        foreach (flag; word[1 .. $]) {
            if (flag == 'n' && command == "export") unexport = true;
            else if (flag == 'p' && command != "unset") listing = true;
            else if (flag == 'f' && command == "unset") functions = true;
            else if (flag == 'v' && command == "unset") variables = true;
            else throw new UsageError(command ~ ": invalid flag " ~ word);
        }
    }
    int status;
    if (command != "unset" && (listing || index == words.length)) {
        import std.algorithm : sort;
        import yshd.traps : shellQuote;
        string[] names;
        foreach (name, cell; mem.currentFrame.cells)
            if (command == "export" ? cell.exported : cell.readOnly) names ~= name;
        sort(names);
        foreach (name; names) {
            auto cell = mem.currentFrame.cells.get(name);
            if (cell.value.kind == ValueKind.stringValue)
                mem.outputFile.writeln(command, " ", name, "=", shellQuote(cell.value.stringValue));
        }
        return 0;
    }
    foreach (word; words[index .. $]) {
        if (command == "unset") {
            if (functions) { mem.builtins.shellFunctions.erase(word); continue; }
            try {
                auto bracket = word.indexOf('[');
                bool found;
                if (bracket >= 0 && word[$ - 1] == ']') {
                    auto name = word[0 .. bracket];
                    auto cell = mem.getShellAssignmentCell(name);
                    if (cell !is null) {
                        if (cell.readOnly) throw new YshError("Can't unset readonly variable " ~ name);
                        if (cell.value.kind != ValueKind.bashArrayValue && cell.value.kind != ValueKind.bashAssocValue)
                            throw new YshError("unset: expected shell array");
                        import yshd.arith : evaluateShellIndex;
                        auto key = cell.value.kind == ValueKind.bashAssocValue ? word[bracket + 1 .. $ - 1] :
                            evaluateShellIndex(word[bracket + 1 .. $ - 1], cell.value, mem);
                        cell.value.shellContainer.erase(key); found = true;
                    }
                } else {
                    if (!identifier(word)) throw new UsageError("unset: invalid variable name");
                    found = mem.unsetShellVariable(word);
                }
                if (!found && !variables) mem.builtins.shellFunctions.erase(word);
            } catch (YshError error) { mem.errorFile.writeln("unset: ", error.msg); status = 1; }
            continue;
        }
        auto equal = word.indexOf('=');
        auto name = equal < 0 ? word : word[0 .. equal];
        if (!identifier(name)) throw new UsageError(command ~ ": invalid variable name");
        if (unexport && equal >= 0) throw new UsageError("export -n does not accept a value");
        auto cell = mem.getShellAssignmentCell(name);
        if (equal >= 0) {
            mem.setShellVar(name, Value.str(word[equal + 1 .. $]));
            cell = mem.getShellAssignmentCell(name);
        } else if (cell is null && !unexport) {
            mem.setShellVar(name, Value.str(""));
            cell = mem.getShellAssignmentCell(name);
        }
        if (cell !is null) {
            if (command == "readonly") cell.readOnly = true;
            else cell.exported = !unexport;
        }
    }
    return status;
}
