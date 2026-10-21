/// Diagnostic runner for unchanged upstream spec cases. Unknown assertion
/// encodings fail qualification explicitly; no fixture is simplified and no
/// expected failure is counted as a pass. This supplements test/sh_spec.py.
module spec_runner;

import std.algorithm : startsWith, endsWith;
import std.conv : to;
import std.file : mkdirRecurse, read, readText, write;
import std.json : parseJSON;
import std.path : absolutePath, baseName, buildPath, dirName;
import std.process : Config, environment, spawnProcess, wait;
import std.format : format;
import std.digest.sha : sha256Of;
import std.digest : toHexString;
import std.stdio : File, stderr, writeln;
import std.string : indexOf, replace, splitLines, strip, stripRight;

struct SpecCase {
    string title;
    size_t line;
    string code;
    string output;
    string errors;
    int status;
    bool checkErrors;
    string unsupported;
}

SpecCase[] readCases(string source) {
    SpecCase[] result;
    SpecCase current;
    bool active;
    bool assertions;
    bool hasCode;
    string block;
    bool qualifiedBlock;
    foreach (lineIndex, line; source.splitLines()) {
        if (line.startsWith("#### ")) {
            if (active) result ~= current;
            current = SpecCase.init;
            current.title = line[5 .. $];
            current.line = lineIndex + 1;
            active = true;
            assertions = false;
            hasCode = false;
            block = "";
            continue;
        }
        if (!active) continue;
        if (block.length && !line.startsWith("## ")) {
            if (!qualifiedBlock) {
                if (block == "STDOUT") current.output ~= line ~ "\n";
                else current.errors ~= line ~ "\n";
            }
            continue;
        }
        if (line.startsWith("## ")) {
            block = "";
            auto directive = line[3 .. $];
            if (directive == "END") continue;
            auto colon = directive.indexOf(':');
            if (colon < 0) {
                current.unsupported ~= "unrecognized directive; ";
                continue;
            }
            if (hasCode) assertions = true;
            auto key = directive[0 .. colon];
            auto value = strip(directive[colon + 1 .. $]);
            qualifiedBlock = key.startsWith("OK ") || key.startsWith("BUG ") || key.startsWith("N-I ");
            if (qualifiedBlock) {
                // Base expectations define correct behavior. Shell-specific
                // allowances never turn a D failure into a pass.
                if (key.endsWith("STDOUT")) block = "STDOUT";
                if (key.endsWith("STDERR")) block = "STDERR";
                continue;
            }
            try { switch (key) {
            case "STDOUT": block = key; current.output = ""; break;
            case "STDERR": block = key; current.errors = ""; current.checkErrors = true; break;
            case "stdout": current.output = value ~ "\n"; break;
            case "stderr": current.errors = value ~ "\n"; current.checkErrors = true; break;
            case "stdout-json": current.output = parseJSON(value).str; break;
            case "stderr-json": current.errors = parseJSON(value).str; current.checkErrors = true; break;
            case "stdout-repr": current.output = decodeRepr(value); break;
            case "stderr-repr": current.errors = decodeRepr(value); current.checkErrors = true; break;
            case "status": current.status = to!int(value); break;
            case "code": current.unsupported ~= "code metadata; "; break;
            default: current.unsupported ~= key ~ "; "; break;
            } } catch (Exception error) {
                current.unsupported ~= key ~ ": " ~ error.msg ~ "; ";
            }
            continue;
        }
        if (!assertions) {
            current.code ~= line ~ "\n";
            if (strip(line).length && !strip(line).startsWith("#")) hasCode = true;
        }
    }
    if (active) result ~= current;
    return result;
}

private string decodeRepr(string literal) {
    if (literal.startsWith("b") || literal.startsWith("u")) literal = literal[1 .. $];
    if (literal.length < 2 || (literal[0] != '\'' && literal[0] != '"') || literal[$ - 1] != literal[0])
        throw new Exception("invalid repr assertion");
    string result;
    size_t index = 1;
    while (index + 1 < literal.length) {
        char ch = literal[index++];
        if (ch != '\\') { result ~= ch; continue; }
        if (index + 1 >= literal.length) throw new Exception("truncated repr escape");
        ch = literal[index++];
        switch (ch) {
        case 'n': result ~= '\n'; break;
        case 'r': result ~= '\r'; break;
        case 't': result ~= '\t'; break;
        case 'a': result ~= cast(char)7; break;
        case 'b': result ~= cast(char)8; break;
        case 'f': result ~= cast(char)12; break;
        case 'v': result ~= cast(char)11; break;
        case '\\': case '\'': case '"': result ~= ch; break;
        case 'x':
            if (index + 2 >= literal.length) throw new Exception("truncated hex assertion");
            result ~= cast(char)to!uint(literal[index .. index + 2], 16);
            index += 2;
            break;
        default:
            if (ch >= '0' && ch <= '7') {
                uint byteValue = ch - '0';
                size_t count = 1;
                while (count < 3 && index + 1 < literal.length && literal[index] >= '0' && literal[index] <= '7') {
                    byteValue = byteValue * 8 + literal[index++] - '0';
                    ++count;
                }
                result ~= cast(char)byteValue;
            } else {
                throw new Exception("unsupported repr escape");
            }
            break;
        }
    }
    return result;
}

private string cell(string value) {
    string result;
    foreach (ubyte ch; cast(const(ubyte)[])value) {
        switch (ch) {
        case '\\': result ~= "\\\\"; break;
        case '\t': result ~= "\\t"; break;
        case '\n': result ~= "\\n"; break;
        case '\r': result ~= "\\r"; break;
        default:
            if (ch < 32 || ch >= 127) result ~= format("\\x%02x", ch);
            else result ~= cast(char)ch;
            break;
        }
    }
    return result;
}

int main(string[] args) {
    if (args.length < 4) {
        stderr.writeln("usage: spec-runner ABSOLUTE-YSH-D OUTPUT-DIRECTORY SPEC-FILE...");
        return 2;
    }
    auto binary = absolutePath(args[1]);
    auto outputDirectory = absolutePath(args[2]);
    mkdirRecurse(outputDirectory);
    auto results = File(buildPath(outputDirectory, "cases.tsv"), "w");
    auto summaries = File(buildPath(outputDirectory, "suites.tsv"), "w");
    summaries.writeln("spec\tpassed\tfailed\tunsupported-assertions\tfixture-sha256");
    results.writeln("spec\tline\tresult\texpected-status\tactual-status\ttitle\tdiagnostic");
    size_t passed, failed, unsupported;
    foreach (argument; args[3 .. $]) {
        auto path = absolutePath(argument);
        auto previousPassed = passed, previousFailed = failed, previousUnsupported = unsupported;
        auto root = dirName(dirName(path));
        foreach (caseIndex, test; readCases(readText(path))) {
            if (test.unsupported.length) {
                ++unsupported;
                results.writeln(baseName(path), "\t", test.line, "\tUNSUPPORTED_ASSERTION\t",
                    test.status, "\t-\t", cell(test.title), "\t", cell(test.unsupported));
                continue;
            }
            auto directory = buildPath(outputDirectory, baseName(path), to!string(caseIndex));
            mkdirRecurse(directory);
            auto sourcePath = buildPath(directory, "case.ysh");
            write(sourcePath, test.code);
            auto input = File(sourcePath, "r");
            auto outputPath = buildPath(directory, "stdout.txt");
            auto errorPath = buildPath(directory, "stderr.txt");
            auto output = File(outputPath, "w");
            auto errors = File(errorPath, "w");
            auto childEnv = environment.toAA();
            childEnv["SH"] = binary;
            childEnv["REPO_ROOT"] = root;
            childEnv["LIB_YSH"] = buildPath(root, "stdlib", "ysh");
            childEnv["PATH"] = buildPath(root, "spec", "bin") ~ ":" ~ environment.get("PATH", "");
            childEnv["TMP"] = directory;
            childEnv["LC_ALL"] = "C.UTF-8";
            auto child = spawnProcess(["/usr/bin/timeout", "--kill-after=1", "3", binary],
                input, output, errors, childEnv,
                Config.retainStdin | Config.retainStdout | Config.retainStderr, directory);
            auto status = wait(child);
            output.close();
            errors.close();
            auto actualOutput = cast(string)read(outputPath);
            auto actualErrors = cast(string)read(errorPath);
            bool success = status == test.status && actualOutput == test.output &&
                (!test.checkErrors || actualErrors == test.errors);
            if (success) ++passed;
            else ++failed;
            results.writeln(baseName(path), "\t", test.line, "\t", success ? "PASS" : "FAIL",
                "\t", test.status, "\t", status, "\t", cell(test.title), "\t", cell(actualErrors));
            results.flush();
        }
        summaries.writeln(baseName(path), "\t", passed - previousPassed, "\t", failed - previousFailed,
            "\t", unsupported - previousUnsupported, "\t", sha256Of(read(path)).toHexString());
        summaries.flush();
    }
    writeln("passed=", passed, " failed=", failed, " unsupported-assertions=", unsupported);
    return failed == 0 && unsupported == 0 ? 0 : 1;
}

unittest {
    auto cases = readCases("#### one\necho x\n## STDOUT:\nx\n## END\n\n" ~
        "#### two\nfalse\n## status: 1\n## stdout-json: \"\"\n");
    assert(cases.length == 2);
    assert(cases[0].code == "echo x\n");
    assert(cases[0].output == "x\n");
    assert(cases[1].status == 1);
    assert(cases[1].output == "");
    assert(cell("\xff\t\n") == "\\xff\\t\\n");
    assert(decodeRepr(`'\xff\n\000'`) == "\xff\n\0");
    auto pre = readCases("#### metadata first\n## status: 2\necho x\n## stdout: x\n");
    assert(pre[0].code == "echo x\n");
}
