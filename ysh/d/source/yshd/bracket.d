module yshd.bracket;

// builtin/bracket_osh.py and osh/bool_parse.py parse the already expanded
// argv, with POSIX's 0/1/2/3/4-argument disambiguation before the general
// boolean grammar. These predicates never recursively evaluate shell code.
import std.bigint : BigInt, toDecimalString;
import std.conv : to;
import std.string : indexOf, toStringz;
import core.sys.posix.sys.stat;
import core.sys.posix.unistd : access, isatty, geteuid, getegid, R_OK, W_OK, X_OK;
import yshd.state : Memory;
import yshd.value : UsageError, YshError, ValueKind;

private bool unaryOperator(string op) {
    return op.length == 2 && op[0] == '-' && "znotvRabcdefghkLprsSuwxOGN".indexOf(op[1]) >= 0;
}

private bool binaryOperator(string op) {
    foreach (candidate; ["=", "==", "!=", "<", ">", "-eq", "-ne", "-lt", "-le", "-gt", "-ge", "-nt", "-ot", "-ef"])
        if (op == candidate) return true;
    return false;
}

private BigInt integer(string text, bool allowPlus = false) {
    size_t begin, end = text.length;
    while (begin < end && " \t\r\n\v\f".indexOf(text[begin]) >= 0) ++begin;
    while (end > begin && " \t\r\n\v\f".indexOf(text[end - 1]) >= 0) --end;
    auto number = text[begin .. end];
    if (allowPlus && number.length && number[0] == '+') number = number[1 .. $];
    if (!number.length) throw new UsageError("test: Invalid integer");
    auto digits = number[0] == '-' ? number[1 .. $] : number;
    if (!digits.length) throw new UsageError("test: Invalid integer " ~ text);
    foreach (ch; digits) if (ch < '0' || ch > '9') throw new UsageError("test: Invalid integer " ~ text);
    auto result = BigInt(number);
    if (result < BigInt(long.min) || result > BigInt(long.max)) throw new UsageError("test: Invalid integer " ~ text);
    return result;
}

private bool nameStart(char ch) { return ch == '_' || ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z'; }
private bool namePart(char ch) { return nameStart(ch) || ch >= '0' && ch <= '9'; }

private bool defined(string operand, Memory mem) {
    bool invalid(string reason) {
        if (mem.options.get("strict_word_eval")) throw new UsageError("test -v: " ~ reason);
        return false;
    }
    if (!operand.length || !nameStart(operand[0])) return invalid("expected name or name[index]");
    size_t end = 1;
    while (end < operand.length && namePart(operand[end])) ++end;
    auto name = operand[0 .. end];
    auto cell = mem.getCell(name);
    if (end == operand.length) return cell !is null || mem.get("ENV").dictValue.contains(name) || name == "PIPESTATUS";
    if (operand[end] != '[' || operand[$ - 1] != ']' || end + 2 == operand.length)
        return invalid("expected name or name[index]");
    auto key = operand[end + 1 .. $ - 1];
    if (key.indexOf(']') >= 0) return invalid("expected name or name[index]");
    if (cell is null && name != "PIPESTATUS") return invalid("expected BashArray or BashAssoc");
    auto value = name == "PIPESTATUS" ? mem.get(name) : cell.value;
    if (value.kind == ValueKind.bashAssocValue) return value.shellContainer.contains(key);
    if (value.kind != ValueKind.bashArrayValue) return invalid("expected BashArray or BashAssoc");
    BigInt offset;
    try { offset = integer(key, true); }
    catch (UsageError error) { return invalid("invalid BashArray index"); }
    if (offset < 0) {
        BigInt length;
        foreach (index, unused; value.shellContainer) {
            auto next = BigInt(index) + 1;
            if (next > length) length = next;
        }
        offset += length;
        if (offset < 0) throw new UsageError("test -v: array index out of bounds");
    }
    return value.shellContainer.contains(toDecimalString(offset));
}

private bool unary(string op, string operand, Memory mem) {
    if (op == "-n") return operand.length != 0;
    if (op == "-z") return operand.length == 0;
    if (op == "--true") return operand == "true";
    if (op == "--false") return operand == "false";
    if (op == "-v") return defined(operand, mem);
    if (op == "-o") {
        try { return mem.options.get(operand); }
        catch (UsageError error) { return false; }
    }
    if (op == "-R") throw new UsageError("test: -R isn't implemented by the reference");
    if (op == "-t") {
        int descriptor;
        try { descriptor = to!int(operand); }
        catch (Exception error) { throw new UsageError("test: Invalid file descriptor " ~ operand); }
        return isatty(descriptor) != 0;
    }
    stat_t info;
    if (operand.indexOf('\0') >= 0) return false;
    auto result = op == "-L" || op == "-h" ? lstat(operand.toStringz(), &info) : stat(operand.toStringz(), &info);
    if (result != 0) return false;
    switch (op) {
    case "-e": case "-a": return true;
    case "-b": return S_ISBLK(info.st_mode);
    case "-c": return S_ISCHR(info.st_mode);
    case "-d": return S_ISDIR(info.st_mode);
    case "-f": return S_ISREG(info.st_mode);
    case "-L": case "-h": return S_ISLNK(info.st_mode);
    case "-p": return S_ISFIFO(info.st_mode);
    case "-S": return S_ISSOCK(info.st_mode);
    case "-g": return (info.st_mode & S_ISGID) != 0;
    case "-k": return (info.st_mode & S_ISVTX) != 0;
    case "-u": return (info.st_mode & S_ISUID) != 0;
    case "-s": return info.st_size != 0;
    case "-G": return info.st_gid == getegid();
    case "-O": return info.st_uid == geteuid();
    case "-r": return access(operand.toStringz(), R_OK) == 0;
    case "-w": return access(operand.toStringz(), W_OK) == 0;
    case "-x": return access(operand.toStringz(), X_OK) == 0;
    default: throw new UsageError("test: " ~ op ~ " isn't implemented by the reference");
    }
}

private bool binary(string op, string left, string right) {
    if (op == "=" || op == "==") return left == right;
    if (op == "!=") return left != right;
    if (op == "<") return left < right;
    if (op == ">") return left > right;
    if (op == "-nt" || op == "-ot" || op == "-ef") {
        stat_t a, b;
        bool hasA = left.indexOf('\0') < 0 && stat(left.toStringz(), &a) == 0;
        bool hasB = right.indexOf('\0') < 0 && stat(right.toStringz(), &b) == 0;
        if (op == "-ef") return hasA && hasB && a.st_dev == b.st_dev && a.st_ino == b.st_ino;
        auto first = hasA ? a.st_mtime : 0;
        auto second = hasB ? b.st_mtime : 0;
        return op == "-nt" ? first > second : first < second;
    }
    auto a = integer(left), b = integer(right);
    switch (op) {
    case "-eq": return a == b;
    case "-ne": return a != b;
    case "-lt": return a < b;
    case "-le": return a <= b;
    case "-gt": return a > b;
    case "-ge": return a >= b;
    default: assert(false, "Unknown test binary operator");
    }
}

private enum Kind { word, unary, binary, negate, conjunction, disjunction }
private class Node {
    Kind kind;
    string op, left, right;
    Node first, second;
    this(Kind kind, string op = "", string left = "", string right = "", Node first = null, Node second = null) {
        this.kind = kind; this.op = op; this.left = left; this.right = right; this.first = first; this.second = second;
    }
    bool eval(Memory mem) {
        final switch (kind) {
        case Kind.word: return left.length != 0;
        case Kind.unary: return unary(op, left, mem);
        case Kind.binary: return binary(op, left, right);
        case Kind.negate: return !first.eval(mem);
        case Kind.conjunction: return first.eval(mem) && second.eval(mem);
        case Kind.disjunction: return first.eval(mem) || second.eval(mem);
        }
    }
}

private Node word(string operand) { return new Node(Kind.word, "", operand); }
private Node negate(Node child) { return new Node(Kind.negate, "", "", "", child); }
private Node logical(Kind kind, Node a, Node b) { return new Node(kind, "", "", "", a, b); }

private Node two(string[] argv) {
    if (argv[0] == "!") return negate(word(argv[1]));
    auto op = argv[0];
    switch (op) {
    case "--dir": op = "-d"; break;
    case "--exists": op = "-e"; break;
    case "--file": op = "-f"; break;
    case "--symlink": op = "-L"; break;
    case "--true": case "--false": break;
    default: if (!unaryOperator(op)) throw new UsageError("test: Expected unary operator (2 args)");
    }
    return new Node(Kind.unary, op, argv[1]);
}

private Node three(string[] argv) {
    if (binaryOperator(argv[1])) return new Node(Kind.binary, argv[1], argv[0], argv[2]);
    if (argv[1] == "-a" || argv[1] == "-o")
        return logical(argv[1] == "-a" ? Kind.conjunction : Kind.disjunction, word(argv[0]), word(argv[2]));
    if (argv[0] == "!") return negate(two(argv[1 .. $]));
    if (argv[0] == "(" && argv[2] == ")") return word(argv[1]);
    throw new UsageError("test: Expected binary operator (3 args)");
}

private class Parser {
    string[] argv;
    size_t position;
    this(string[] argv) { this.argv = argv; }
    string take() {
        // _StringWordEmitter emits a String word containing '' at EOF. In
        // the general grammar this participates in WordTest/unary predicates.
        if (position == argv.length) return "";
        return argv[position++];
    }
    Node expression() {
        auto result = term();
        if (position < argv.length && argv[position] == "-o") { ++position; result = logical(Kind.disjunction, result, expression()); }
        return result;
    }
    Node term() {
        Node result;
        if (position < argv.length && argv[position] == "!") { ++position; result = negate(factor()); }
        else result = factor();
        if (position < argv.length && argv[position] == "-a") { ++position; result = logical(Kind.conjunction, result, term()); }
        return result;
    }
    Node factor() {
        auto current = take();
        if (current == "(") {
            auto result = expression();
            if (take() != ")") throw new UsageError("test: Expected )");
            return result;
        }
        if (position < argv.length && binaryOperator(argv[position])) {
            auto op = take(), right = take();
            return new Node(Kind.binary, op, current, right);
        }
        if (unaryOperator(current)) return new Node(Kind.unary, current, take());
        if (current == ")") throw new UsageError("test: Unexpected )");
        return word(current);
    }
    Node parse() {
        auto result = expression();
        if (position != argv.length) throw new UsageError("test: Unexpected trailing word");
        return result;
    }
}

int runTest(string[] argv, Memory mem) {
    try {
        auto arguments = argv[1 .. $];
        if (argv[0] == "[") {
            if (mem.options.get("simple_test_builtin")) throw new UsageError("test: invoke as test (simple_test_builtin)");
            if (!arguments.length || arguments[$ - 1] != "]") throw new UsageError("test: missing closing ]");
            arguments = arguments[0 .. $ - 1];
        }
        auto count = arguments.length;
        if (mem.options.get("simple_test_builtin") && count != 2 && count != 3)
            throw new UsageError("test: expected 2 or 3 arguments (simple_test_builtin)");
        Node root;
        switch (count) {
        case 0: return 1;
        case 1: root = word(arguments[0]); break;
        case 2: root = two(arguments); break;
        case 3: root = three(arguments); break;
        case 4:
            if (arguments[0] == "!") root = negate(three(arguments[1 .. $]));
            else if (arguments[0] == "(" && arguments[3] == ")") root = two(arguments[1 .. 3]);
            else root = (new Parser(arguments)).parse();
            break;
        default: root = (new Parser(arguments)).parse();
        }
        return root.eval(mem) ? 0 : 1;
    } catch (YshError error) {
        mem.errorFile.writeln(error.msg);
        return 2;
    }
}

unittest {
    import std.stdio : File;
    auto mem = new Memory(File.tmpfile(), File.tmpfile());
    assert(runTest(["[", "]"], mem) == 1);
    assert(runTest(["[", "]", "]"], mem) == 0);
    assert(runTest(["test", "-z"], mem) == 0);
    assert(runTest(["test", "-z", "-a"], mem) == 1);
    assert(runTest(["test", "-z", "-a", "]"], mem) == 0);
    assert(runTest(["test", "-z", "-a", "-a"], mem) == 0);
    assert(runTest(["test", "a", "=", "*"], mem) == 1);
    assert(runTest(["test", "08", "-eq", "8"], mem) == 0);
    assert(runTest(["test", "+8", "-eq", "8"], mem) == 2);
    assert(runTest(["test", "1+2", "-eq", "3"], mem) == 2);
    assert(runTest(["test", "9223372036854775808", "-gt", "0"], mem) == 2);
    assert(runTest(["test", "yes", "-o", "bad", "-eq", "3"], mem) == 0);
    assert(runTest(["test", "yes", "-o", "(", "bad"], mem) == 2);
    assert(runTest(["test", "foo", "-a", "bar", "-a"], mem) == 1);
    assert(runTest(["test", "foo", "-a", "bar", "-a", "-z"], mem) == 0);
    mem.options.set("simple_test_builtin", true);
    assert(runTest(["test", "yes"], mem) == 2);
    assert(runTest(["[", "-n", "yes", "]"], mem) == 2);
    assert(runTest(["test", "--exists", "/"], mem) == 0);
    assert(runTest(["test", "--true", "true"], mem) == 0);
    assert(runTest(["test", "--false", "TRUE"], mem) == 1);
}

unittest {
    import std.stdio : File;
    import yshd.program : executeProgram;
    auto output = File.tmpfile();
    auto mem = new Memory(output, File.tmpfile());
    executeProgram(`
        var=-f
        [ $var = -f ] && echo equal
        [ -z '' -a ! -z x ] && echo logical
        [ '(' -n x ')' ] && echo grouped
        shopt -s ysh:all
        shopt -u errexit
        [ -n x ]
        echo rejected=$?
        test --true true
        echo truth=$?
    `, mem);
    output.rewind();
    assert(output.readln() == "equal\n");
    assert(output.readln() == "logical\n");
    assert(output.readln() == "grouped\n");
    assert(output.readln() == "rejected=2\n");
    assert(output.readln() == "truth=0\n");
}
