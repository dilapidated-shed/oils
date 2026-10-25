module yshd.arith;

// Native translation of osh/arith_parse.py's precedence table and the shared
// scalar arithmetic evaluator in osh/sh_expr_eval.py. YSH expressions retain
// their own parser and value operations in expr.d.

import std.bigint : BigInt, toDecimalString;
import std.conv : to;
import std.string : indexOf, strip;
import yshd.expr : ParseError;
import yshd.options : ShellOptions;
import yshd.state : Memory, ReturnMode;
import yshd.value : Value, ValueKind, YshDict, YshError, FatalRuntimeError;

private bool nameStart(char ch) { return ch == '_' || ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z'; }
private bool namePart(char ch) { return nameStart(ch) || ch >= '0' && ch <= '9'; }
private bool validName(string text) {
    if (!text.length || !nameStart(text[0])) return false;
    foreach (ch; text) if (!namePart(ch)) return false;
    return true;
}

/// Return the byte after a balanced shell delimiter, without evaluating it.
/// Quotes and nested substitutions cannot terminate their surrounding input.
private size_t delimitedEnd(string source, size_t start, char close) {
    auto open = source[start];
    auto position = start + 1;
    while (position < source.length) {
        auto ch = source[position];
        if (ch == '\\') { position += position + 1 < source.length ? 2 : 1; continue; }
        if (ch == '\'' || ch == '"' || ch == '`') {
            position = quotedEnd(source, position);
            continue;
        }
        if (ch == open) { position = delimitedEnd(source, position, close); continue; }
        if (ch == close) return position + 1;
        ++position;
    }
    throw new ParseError("Unterminated arithmetic substitution delimiter");
}

private size_t quotedEnd(string source, size_t start) {
    auto quote = source[start];
    auto position = start + 1;
    while (position < source.length) {
        if (source[position] == quote) return position + 1;
        if (quote != '\'' && source[position] == '\\') {
            position += position + 1 < source.length ? 2 : 1;
            continue;
        }
        if (quote == '"' && source[position] == '$' && position + 1 < source.length) {
            auto open = source[position + 1];
            if (open == '(' || open == '{' || open == '[') {
                position = delimitedEnd(source, position + 1, open == '(' ? ')' : open == '[' ? ']' : '}');
                continue;
            }
        }
        ++position;
    }
    throw new ParseError("Unterminated quote in arithmetic");
}

/// The first opening parenthesis belongs to ((...)) or $((...)).
size_t shellArithmeticEnd(string source, size_t start) {
    assert(start + 1 < source.length && source[start .. start + 2] == "((");
    auto end = delimitedEnd(source, start + 1, ')');
    if (end >= source.length || source[end] != ')')
        throw new ParseError("Expected second ) to end shell arithmetic");
    return end + 1;
}

private struct Token {
    string text;
    size_t offset;
    bool word;
}

private class ArithmeticLexer {
    string source;
    size_t position;
    this(string source) { this.source = source; }
    Token next() {
        while (position < source.length && " \t\r\n".indexOf(source[position]) >= 0) ++position;
        auto start = position;
        if (position == source.length) return Token("", position);
        foreach (op; ["<<=", ">>=", "++", "--", "**", "<<", ">>", "<=", ">=", "==", "!=",
                "&&", "||", "+=", "-=", "*=", "/=", "%=", "&=", "^=", "|="]) {
            if (source.length - position >= op.length && source[position .. position + op.length] == op) {
                position += op.length;
                return Token(op, start);
            }
        }
        if ("()+-*/%<>=!~&^|?:,[];".indexOf(source[position]) >= 0) {
            ++position;
            return Token(source[start .. position], start);
        }
        while (position < source.length) {
            auto ch = source[position];
            if (ch == '\'' || ch == '"' || ch == '`') { position = quotedEnd(source, position); continue; }
            if (ch == '\\') { position += position + 1 < source.length ? 2 : 1; continue; }
            if (ch == '$' && position + 1 < source.length) {
                auto open = source[position + 1];
                if (open == '(' || open == '{' || open == '[') {
                    position = delimitedEnd(source, position + 1, open == '(' ? ')' : open == '[' ? ']' : '}');
                    continue;
                }
            }
            if (" \t\r\n()+-*/%<>=!~&^|?:,[];".indexOf(ch) >= 0) break;
            if (!namePart(ch) && ch != '$' && ch != '#' && ch != '@')
                throw new ParseError("Invalid byte in shell arithmetic: " ~ ch);
            ++position;
        }
        if (position == start) throw new ParseError("Invalid token in shell arithmetic");
        return Token(source[start .. position], start, true);
    }
}

private enum Kind { word, variable, unary, increment, binary, assignment, index, conditional }
private class Node {
    Kind kind;
    string text;
    Node first, second, third;
    bool postfix;
    this(Kind kind, string text, Node first = null, Node second = null, Node third = null) {
        this.kind = kind; this.text = text; this.first = first; this.second = second; this.third = third;
    }
}

private bool indexable(Node node) { return node.kind == Kind.word || node.kind == Kind.variable; }
private void requirePlace(Node node) {
    if (!indexable(node) && !(node.kind == Kind.index && indexable(node.first)))
        throw new ParseError("Left-hand side of arithmetic assignment is invalid");
}

private int bindingPower(string op) {
    switch (op) {
    case "++": case "--": case "[": return 33;
    case "**": return 29;
    case "*": case "/": case "%": return 27;
    case "+": case "-": return 25;
    case "<<": case ">>": return 23;
    case "<": case ">": case "<=": case ">=": return 21;
    case "==": case "!=": return 19;
    case "&": return 15;
    case "^": return 13;
    case "|": return 11;
    case "&&": return 9;
    case "||": return 7;
    case "?": return 5;
    case "=": case "+=": case "-=": case "*=": case "/=": case "%=":
    case "<<=": case ">>=": case "&=": case "^=": case "|=": return 3;
    case ",": return 1;
    default: return -1;
    }
}

private class ArithmeticParser {
    ArithmeticLexer lexer;
    Token token;
    ShellOptions options;
    this(string source, ShellOptions options) { lexer = new ArithmeticLexer(source); this.options = options; advance(); }
    void advance() { token = lexer.next(); }
    void require(string expected) {
        if (token.text != expected) throw new ParseError("Expected " ~ expected ~ " in shell arithmetic");
        advance();
    }
    Node parse() {
        if (!token.text.length) return new Node(Kind.word, "0");
        auto result = expression(0);
        if (token.text.length) throw new ParseError("Unexpected token in shell arithmetic: " ~ token.text);
        return result;
    }
    Node[3] forHeader() {
        Node[3] result;
        foreach (i; 0 .. 3) {
            auto delimiter = i < 2 ? ";" : "";
            result[i] = token.text == delimiter
                ? new Node(Kind.word, i == 1 ? "1" : "0") : expression(0);
            require(delimiter);
        }
        return result;
    }
    Node[2] slice() {
        Node[2] result;
        result[0] = !token.text.length || token.text == ":" ? new Node(Kind.word, "0") : expression(0);
        if (token.text == ":") {
            advance();
            result[1] = !token.text.length ? new Node(Kind.word, "0") : expression(0);
        }
        require("");
        return result;
    }
    Node expression(int minimum) {
        auto current = token;
        if (!current.text.length) throw new ParseError("Expected arithmetic operand");
        advance();
        Node left;
        if (current.word) {
            expandWord(current.text, null, options);
            left = new Node(validName(current.text) ? Kind.variable : Kind.word, current.text);
        } else if (current.text == "(") {
            left = expression(0);
            require(")");
        } else if (current.text == "+" || current.text == "-" || current.text == "!" || current.text == "~") {
            left = new Node(Kind.unary, current.text, expression(31));
        } else if (current.text == "++" || current.text == "--") {
            auto child = expression(31);
            requirePlace(child);
            left = new Node(Kind.increment, current.text, child);
        } else throw new ParseError("Invalid prefix operator in shell arithmetic: " ~ current.text);

        while (!token.word && bindingPower(token.text) > minimum) {
            auto op = token.text;
            auto power = bindingPower(op);
            advance();
            if (op == "[") {
                if (!indexable(left)) throw new ParseError("The [ operator doesn't apply to this arithmetic expression");
                auto index = expression(0);
                require("]");
                left = new Node(Kind.index, op, left, index);
            } else if (op == "++" || op == "--") {
                requirePlace(left);
                left = new Node(Kind.increment, op, left);
                left.postfix = true;
            } else if (op == "?") {
                auto selected = expression(0);
                require(":");
                left = new Node(Kind.conditional, op, left, selected, expression(power - 1));
            } else if (power == 3) {
                requirePlace(left);
                left = new Node(Kind.assignment, op, left, expression(power - 1));
            } else left = new Node(Kind.binary, op, left, expression(op == "**" ? power - 1 : power));
        }
        return left;
    }
}

/// Arithmetic words are scalar: no field splitting or pathname expansion.
/// The owning shell parser still validates/evaluates nested substitutions.
private string expandWord(string source, Memory mem, ShellOptions options) {
    import yshd.program : evaluateDoubleQuotedExpression, validateDoubleQuoted,
        evaluateCommandSubstitution, parseProgram;
    string result;
    size_t start, position;
    void expand(string text) {
        if (mem is null) validateDoubleQuoted(text, options);
        else result ~= evaluateDoubleQuotedExpression(text, mem);
    }
    while (position < source.length) {
        if (source[position] == '\\') { position += position + 1 < source.length ? 2 : 1; continue; }
        if (source[position] == '$' && position + 1 < source.length && "([{".indexOf(source[position + 1]) >= 0) {
            auto open = source[position + 1];
            position = delimitedEnd(source, position + 1, open == '(' ? ')' : open == '[' ? ']' : '}');
            continue;
        }
        if (source[position] == '\'' || source[position] == '"' || source[position] == '`') {
            expand(source[start .. position]);
            auto end = quotedEnd(source, position);
            auto content = source[position + 1 .. end - 1];
            if (source[position] == '\'') result ~= content;
            else if (source[position] == '`') {
                if (mem is null) parseProgram(content, ReturnMode.shell, options);
                else result ~= evaluateCommandSubstitution(content, mem);
            } else expand(content);
            position = end;
            start = position;
        } else ++position;
    }
    expand(source[start .. $]);
    return result;
}

private class StrictArithmetic : FatalRuntimeError {
    this(string message) { super(message); }
}

private bool parseInteger(string text, out BigInt result) {
    if (!text.length) return false;
    uint base = 10;
    size_t start;
    auto separator = text.indexOf('#');
    if (separator >= 0) {
        if (!separator || text[0] == '0' || separator + 1 == text.length) return false;
        foreach (ch; text[0 .. separator]) if (ch < '0' || ch > '9') return false;
        auto parsedBase = BigInt(text[0 .. separator]);
        if (parsedBase < 2 || parsedBase > 64) throw new StrictArithmetic("Arithmetic base must be between 2 and 64");
        base = to!uint(toDecimalString(parsedBase));
        start = separator + 1;
    } else if (text.length > 2 && text[0] == '0' && (text[1] == 'x' || text[1] == 'X')) {
        base = 16; start = 2;
    } else if (text.length > 1 && text[0] == '0') { base = 8; start = 1; }
    result = 0;
    foreach (ch; text[start .. $]) {
        uint digit;
        if (ch >= '0' && ch <= '9') digit = ch - '0';
        else if (ch >= 'a' && ch <= 'z') digit = ch - 'a' + 10;
        else if (ch >= 'A' && ch <= 'Z') digit = ch - 'A' + (separator >= 0 ? 36 : 10);
        else if (ch == '@' && separator >= 0) digit = 62;
        else if (ch == '_' && separator >= 0) digit = 63;
        else return false;
        if (digit >= base) {
            if (separator >= 0) throw new StrictArithmetic("Digit out of range for arithmetic base");
            return false;
        }
        result = result * base + digit;
    }
    if (separator < 0 && result > BigInt(long.max)) throw new FatalRuntimeError("Arithmetic integer constant is too large");
    return true;
}

private struct Reference {
    Memory mem;
    string name;
    bool indexed;
    string key;

    Value read(out bool defined) {
        auto cell = mem.getShellAssignmentCell(name);
        defined = cell !is null;
        if (!defined) {
            if (mem.nounset) throw new FatalRuntimeError("Undefined arithmetic variable " ~ name);
            return Value.nullValue();
        }
        if (!indexed) {
            if ((cell.value.kind == ValueKind.bashArrayValue || cell.value.kind == ValueKind.bashAssocValue) &&
                    !mem.options.get("strict_array")) { indexed = true; key = "0"; }
            else return cell.value;
        }
        if (cell.value.kind == ValueKind.stringValue) {
            defined = key == "0";
            return defined ? cell.value : Value.nullValue();
        }
        if (cell.value.kind != ValueKind.bashArrayValue && cell.value.kind != ValueKind.bashAssocValue)
            throw new FatalRuntimeError("Can't index this arithmetic value");
        auto entry = cell.value.shellContainer.find(key);
        defined = entry !is null;
        return defined ? *entry : Value.nullValue();
    }

    void store(BigInt number) {
        auto cell = mem.getShellAssignmentCell(name);
        if (cell !is null && cell.readOnly) throw new FatalRuntimeError("Can't assign to readonly arithmetic variable " ~ name);
        auto value = Value.str(toDecimalString(number));
        if (!indexed) { mem.setShellVar(name, value); return; }
        Value array;
        if (cell is null) array = Value.shellArray(new YshDict());
        else if (cell.value.kind == ValueKind.stringValue) {
            auto entries = new YshDict();
            entries.set("0", cell.value);
            array = Value.shellArray(entries);
        } else if (cell.value.kind == ValueKind.bashArrayValue || cell.value.kind == ValueKind.bashAssocValue) array = cell.value;
        else throw new FatalRuntimeError("Can't assign an arithmetic array element on this value");
        if (array.kind == ValueKind.bashArrayValue && BigInt(key) < 0)
            throw new FatalRuntimeError("Invalid negative arithmetic array index");
        array.shellContainer.set(key, value);
        mem.setShellVar(name, array);
    }
}

private class ArithmeticContext {
    Memory mem;
    size_t recursion;
    this(Memory mem) { this.mem = mem; }

    Value lookup(string name, out bool defined) {
        if (name == "PIPESTATUS") { defined = true; return mem.get(name); }
        if (name == "LINENO" || name == "BASHPID") { defined = true; return Value.str(mem.wordVariable(name)); }
        auto cell = mem.getCell(name);
        if (cell !is null) { defined = true; return cell.value; }
        auto environment = mem.get("ENV").dictValue.find(name);
        if (environment !is null) { defined = true; return *environment; }
        defined = false;
        if (mem.nounset) throw new FatalRuntimeError("Undefined arithmetic variable " ~ name);
        return Value.nullValue();
    }

    BigInt number(Value value, bool defined = true) {
        if (!defined) {
            if (mem.options.get("strict_arith")) throw new FatalRuntimeError("Undefined value in arithmetic context");
            return BigInt(0);
        }
        if (value.kind == ValueKind.integer) return value.integerValue;
        if (value.kind == ValueKind.bashArrayValue || value.kind == ValueKind.bashAssocValue) {
            if (mem.options.get("strict_array")) throw new FatalRuntimeError("Arithmetic array decay is disabled");
            auto entry = value.shellContainer.find("0");
            return entry is null ? number(Value.nullValue(), false) : number(*entry);
        }
        if (value.kind != ValueKind.stringValue) throw new FatalRuntimeError("Expected a value convertible to integer");
        auto text = strip(value.stringValue);
        if (!text.length) return BigInt(0);
        BigInt result;
        try { if (parseInteger(text, result)) return result; }
        catch (StrictArithmetic error) { if (mem.options.get("strict_arith")) throw error; return BigInt(0); }
        if (++recursion > 1000) throw new FatalRuntimeError("Recursive arithmetic evaluation did not terminate");
        scope (exit) --recursion;
        Node parsed;
        try { parsed = (new ArithmeticParser(text, mem.options)).parse(); }
        catch (ParseError error) { throw new FatalRuntimeError("Parse error in recursive arithmetic: " ~ error.msg); }
        if (parsed.kind == Kind.word) throw new FatalRuntimeError("Invalid integer constant: " ~ text);
        size_t[] disabled;
        if (!mem.options.get("eval_unsafe_arith")) {
            disabled = [ShellOptions.number("_allow_command_sub")];
            mem.options.push(disabled, false);
        }
        scope (exit) { if (disabled.length) mem.options.pop(disabled); }
        return eval(parsed);
    }

    string indexKey(Node index, Value array) {
        if (array.kind == ValueKind.bashAssocValue) {
            if (index.kind != Kind.word) throw new FatalRuntimeError("Assoc array keys must be quoted words or substitutions");
            return expandWord(index.text, mem, mem.options);
        }
        return normalizeIndex(eval(index), array);
    }

    Reference place(Node node) {
        auto base = node.kind == Kind.index ? node.first : node;
        auto name = base.kind == Kind.variable ? base.text : expandWord(base.text, mem, mem.options);
        if (!validName(name)) throw new FatalRuntimeError("Invalid arithmetic variable name: " ~ name);
        Reference result = Reference(mem, name);
        if (node.kind == Kind.index) {
            auto cell = mem.getShellAssignmentCell(name);
            result.indexed = true;
            result.key = indexKey(node.second, cell is null ? Value.nullValue() : cell.value);
        }
        return result;
    }

    BigInt eval(Node node) {
        final switch (node.kind) {
        case Kind.word: return number(Value.str(expandWord(node.text, mem, mem.options)));
        case Kind.variable:
            bool defined;
            auto value = lookup(node.text, defined);
            return number(value, defined);
        case Kind.index:
            Value array;
            bool defined;
            if (node.first.kind == Kind.variable) array = lookup(node.first.text, defined);
            else { array = Value.str(expandWord(node.first.text, mem, mem.options)); defined = true; }
            if (!defined) return number(Value.nullValue(), false);
            auto key = indexKey(node.second, array);
            if (array.kind == ValueKind.stringValue) {
                if (mem.options.get("strict_arith")) throw new FatalRuntimeError("Str can't be indexed in strict arithmetic");
                return key == "0" ? number(array) : number(Value.nullValue(), false);
            }
            if (array.kind != ValueKind.bashArrayValue && array.kind != ValueKind.bashAssocValue)
                throw new FatalRuntimeError("Arithmetic value can't be indexed");
            auto entry = array.shellContainer.find(key);
            return entry is null ? number(Value.nullValue(), false) : number(*entry);
        case Kind.unary:
            auto number = eval(node.first);
            if (node.text == "+") return number;
            if (node.text == "-") return -number;
            if (node.text == "!") return BigInt(number == 0 ? 1 : 0);
            return -number - 1;
        case Kind.increment:
            auto target = place(node.first);
            bool defined;
            auto prior = target.read(defined);
            auto old = number(prior, defined);
            auto updated = old + (node.text == "++" ? 1 : -1);
            target.store(updated);
            return node.postfix ? old : updated;
        case Kind.assignment:
            auto target = place(node.first);
            BigInt result;
            if (node.text == "=") result = eval(node.second);
            else {
                bool defined;
                auto prior = target.read(defined);
                auto old = number(prior, defined);
                result = binary(node.text[0 .. $ - 1], old, eval(node.second));
            }
            target.store(result);
            return result;
        case Kind.conditional: return eval(node.first) != 0 ? eval(node.second) : eval(node.third);
        case Kind.binary:
            auto left = eval(node.first);
            if (node.text == "||") return BigInt(left != 0 || eval(node.second) != 0 ? 1 : 0);
            if (node.text == "&&") return BigInt(left != 0 && eval(node.second) != 0 ? 1 : 0);
            auto right = eval(node.second);
            if (node.text == ",") return right;
            return binary(node.text, left, right);
        }
    }
}

private BigInt binary(string op, BigInt left, BigInt right) {
    switch (op) {
    case "+": return left + right;
    case "-": return left - right;
    case "*": return left * right;
    case "/": case "%":
        if (right == 0) throw new FatalRuntimeError("Divide by zero");
        return op == "/" ? left / right : left % right;
    case "**":
        if (right < 0) throw new FatalRuntimeError("Exponent can't be a negative number");
        BigInt result = 1;
        while (right != 0) {
            if (right % 2 != 0) result *= left;
            right /= 2;
            if (right != 0) left *= left;
        }
        return result;
    case "&": return left & right;
    case "|": return left | right;
    case "^": return left ^ right;
    case "<<": case ">>":
        if (right < 0 || right > BigInt(size_t.max)) throw new YshError("Invalid arithmetic shift count");
        auto count = to!size_t(toDecimalString(right));
        if (op == "<<") return left << count;
        return left < 0 ? -(((-left - 1) >> count) + 1) : left >> count;
    case "==": return BigInt(left == right ? 1 : 0);
    case "!=": return BigInt(left != right ? 1 : 0);
    case "<": return BigInt(left < right ? 1 : 0);
    case ">": return BigInt(left > right ? 1 : 0);
    case "<=": return BigInt(left <= right ? 1 : 0);
    case ">=": return BigInt(left >= right ? 1 : 0);
    default: assert(false, "Unknown translated arithmetic operator");
    }
}

/// This is the existing shell arithmetic language, not YSH's expression IR.
class ShellArithmetic {
    private Node root;
    private this(Node root) { this.root = root; }
    BigInt evaluate(Memory mem) { return (new ArithmeticContext(mem)).eval(root); }
}

ShellArithmetic parseShellArithmetic(string source, ShellOptions options = null) {
    return new ShellArithmetic((new ArithmeticParser(source, options)).parse());
}

BigInt evaluateShellArithmetic(string source, Memory mem) {
    return parseShellArithmetic(source, mem.options).evaluate(mem);
}

ShellArithmetic[3] parseShellArithmeticFor(string source, ShellOptions options = null) {
    auto nodes = (new ArithmeticParser(source, options)).forHeader();
    ShellArithmetic[3] result;
    foreach (i; 0 .. 3) result[i] = new ShellArithmetic(nodes[i]);
    return result;
}

ShellArithmetic[2] parseShellArithmeticSlice(string source, ShellOptions options = null) {
    auto nodes = (new ArithmeticParser(source, options)).slice();
    ShellArithmetic[2] result;
    foreach (i; 0 .. 2) if (nodes[i] !is null) result[i] = new ShellArithmetic(nodes[i]);
    return result;
}

private string normalizeIndex(BigInt offset, Value array) {
    if (offset < 0 && array.kind == ValueKind.bashArrayValue) {
        BigInt length = 0;
        foreach (key, unused; array.shellContainer) {
            auto candidate = BigInt(key) + 1;
            if (candidate > length) length = candidate;
        }
        offset += length;
    }
    return toDecimalString(offset);
}

string evaluateShellIndex(string source, Value array, Memory mem) {
    return normalizeIndex(evaluateShellArithmetic(source, mem), array);
}
