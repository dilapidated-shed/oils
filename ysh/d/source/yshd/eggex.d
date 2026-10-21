module yshd.eggex;

import std.conv : to;
import std.algorithm : sort;
import std.string : indexOf, toStringz;
import std.utf : byDchar;
import std.range : walkLength;
import yshd.expr : ParseError, resolveCaptureConversion;
import yshd.lexer : Lexer, Token, TokenKind;
import yshd.options : ShellOptions;
import yshd.libc_patterns : regex_t, regmatch_t, regcomp, regexec, regfree,
    regerror, REG_EXTENDED, REG_ICASE, REG_NEWLINE, REG_NOTBOL, reg_errcode_t;
import yshd.state : Memory, RegexMatch;
import yshd.value : Value, ValueKind, YshError, YshTypeError, FatalRuntimeError, YshRegex;

private enum NodeKind { literal, primitive, sequence, alternate, repeat, group, splice, charClass }

class EreError : YshError {
    this(string message) { super(message, 2); }
}

private class Node {
    NodeKind kind;
    string text;
    Node[] children;
    string name;
    string conversion;
    bool negated;
    bool bound;
    bool characterLiteral;
    bool unicodeCharacter;
    Value delegate(Value) conversionFunction;
    this(NodeKind kind, string text = "", Node[] children = null) {
        this.kind = kind;
        this.text = text;
        this.children = children;
    }
}

private string posixClass(string name) {
    switch (name) {
    case "alnum": case "alpha": case "blank": case "cntrl": case "digit":
    case "graph": case "lower": case "print": case "punct": case "space":
    case "upper": case "xdigit": return "[:" ~ name ~ ":]";
    case "d": return "[:digit:]";
    case "w": case "word": return "[:alpha:][:digit:]_";
    case "s": return "[:space:]";
    default: return "";
    }
}

/// The regex grammar builds an AST without looking up splices or compiling an
/// ERE. Lowering is deferred until an arm is reached, like expression patterns.
class Eggex : YshRegex {
    private Node root;
    private int flags;
    private string canonicalFlags;
    private bool ereDialect = true;
    private bool frozen;
    private bool lowered;
    private string cachedEre;
    private RegexMatch captures;
    size_t endOffset;

    private this(Node root, int flags, size_t endOffset, string canonicalFlags = "", bool ereDialect = true) {
        this.root = root;
        this.flags = flags;
        this.endOffset = endOffset;
        this.canonicalFlags = canonicalFlags;
        this.ereDialect = ereDialect;
    }

    /// EvalEggex snapshots splices and conversion functions at evaluation,
    /// while ERE lowering remains lazy. Rebinding a splice cannot alter it.
    Eggex bind(Memory mem) {
        if (frozen) return this;
        auto result = new Eggex(bindNode(root, mem, false), flags, endOffset, canonicalFlags, ereDialect);
        result.frozen = true;
        return result;
    }

    private Node bindNode(Node node, Memory mem, bool characterClass) {
        if (node.kind == NodeKind.splice) {
            auto value = mem.get(node.text);
            if (value.kind == ValueKind.stringValue) {
                if (characterClass) foreach (ubyte ch; cast(const(ubyte)[])value.stringValue)
                    if (ch >= 128) throw new FatalRuntimeError("Use an unquoted character literal for non-ASCII bytes");
                return new Node(NodeKind.literal, value.stringValue);
            }
            if (!characterClass && value.kind == ValueKind.eggexValue) {
                auto splice = cast(Eggex)value.regexValue;
                if (splice is null) throw new YshTypeError("Eggex splice requires Eggex or Str");
                if (splice.ereDialect != ereDialect || splice.canonicalFlags != canonicalFlags)
                    throw new FatalRuntimeError("Spliced Eggex has different flags");
                return splice.root;
            }
            throw new YshTypeError(characterClass ? "Character class splice requires Str" : "Eggex splice requires Eggex or Str");
        }
        auto result = new Node(node.kind, node.text);
        result.name = node.name;
        result.conversion = node.conversion;
        result.negated = node.negated;
        result.bound = true;
        result.characterLiteral = node.characterLiteral;
        result.unicodeCharacter = node.unicodeCharacter;
        if (characterClass && node.kind == NodeKind.literal && !node.characterLiteral)
            foreach (ubyte ch; cast(const(ubyte)[])node.text)
                if (ch >= 128) throw new FatalRuntimeError("Use an unquoted character literal for non-ASCII bytes");
        if (node.conversion.length) result.conversionFunction = resolveCaptureConversion(node.conversion, mem);
        foreach (child; node.children) result.children ~= bindNode(child, mem, node.kind == NodeKind.charClass);
        return result;
    }

    override string asEre() {
        assert(frozen);
        if (!lowered) {
            captures = new RegexMatch();
            cachedEre = lower(root, null, captures);
            lowered = true;
        }
        return cachedEre;
    }

    override RegexMatch search(string subject, long position = 0, bool leftMatch = false, bool useNotBol = true) {
        auto ere = asEre();
        return searchEre(ere, flags, subject, position, leftMatch, captures, useNotBol);
    }

    bool matches(Value subject, Memory mem) {
        if (subject.kind != ValueKind.stringValue)
            throw new YshTypeError("LHS of regex match must be a Str");
        mem.regexMatch = bind(mem).search(subject.stringValue);
        return mem.regexMatch !is null;
    }
}

RegexMatch searchEre(string ere, int flags, string subject, long position = 0,
        bool leftMatch = false, RegexMatch captures = null, bool useNotBol = true) {
    if (ere.indexOf('\0') >= 0 || subject.indexOf('\0') >= 0)
        throw new YshError("POSIX regex matching cannot contain NUL bytes");
    if (position < 0) throw new YshError("Regex search position cannot be negative");
    if (position > subject.length) return null;
    if (leftMatch) ere = "^(" ~ ere ~ ")";
    regex_t compiled;
    auto result = regcomp(&compiled, ere.toStringz(), REG_EXTENDED | flags);
    if (result != 0) regexError(result, &compiled);
    scope (exit) regfree(&compiled);
    auto matches = new regmatch_t[compiled.re_nsub + 1];
    result = regexec(&compiled, subject[position .. $].toStringz(), matches.length, matches.ptr,
        leftMatch || position == 0 || !useNotBol ? 0 : REG_NOTBOL);
    if (result == reg_errcode_t._REG_NOMATCH) return null;
    if (result != 0) regexError(result, &compiled);
    auto state = new RegexMatch();
    state.subject = subject;
    if (captures !is null) {
        state.names = captures.names;
        state.conversions = captures.conversions;
    }
    foreach (match; matches[leftMatch ? 1 : 0 .. $]) {
        state.starts ~= match.rm_so == -1 ? -1 : cast(ptrdiff_t)position + match.rm_so;
        state.ends ~= match.rm_eo == -1 ? -1 : cast(ptrdiff_t)position + match.rm_eo;
    }
    return state;
}

private void regexError(int code, regex_t* compiled) {
    auto message = new char[regerror(code, compiled, null, 0)];
    regerror(code, compiled, message.ptr, message.length);
    throw new EreError("Invalid ERE: " ~ message[0 .. $ - 1].idup);
}

private string literalEre(string text) {
    string result;
    foreach (char ch; text) {
        if (".^$*+?{}[]\\|()".indexOf(ch) >= 0) result ~= '\\';
        result ~= ch;
    }
    return result;
}

private void checkClassCharacter(Node term) {
    foreach (ubyte ch; cast(const(ubyte)[])term.text) {
        if (ch == 0) throw new FatalRuntimeError("ERE can't express char code 0");
        if (ch >= 128 && !term.unicodeCharacter) throw new FatalRuntimeError("ERE can't express high bytes");
    }
}

private string lower(Node node, Memory mem, RegexMatch state) {
    final switch (node.kind) {
    case NodeKind.literal: return literalEre(node.text);
    case NodeKind.primitive: return node.text;
    case NodeKind.sequence:
    case NodeKind.alternate:
        string result;
        foreach (index, child; node.children) {
            if (index && node.kind == NodeKind.alternate) result ~= "|";
            result ~= lower(child, mem, state);
        }
        return result;
    case NodeKind.repeat:
        auto child = node.children[0];
        if (child.kind == NodeKind.literal && child.text.length > 1)
            throw new FatalRuntimeError("POSIX ERE repetition of a string needs () around it");
        if (child.kind == NodeKind.splice) {
            auto value = mem.get(child.text);
            if (value.kind == ValueKind.stringValue && value.stringValue.length > 1)
                throw new YshError("POSIX ERE repetition of a string needs () around it");
        }
        return lower(child, mem, state) ~ node.text;
    case NodeKind.group:
        state.names ~= node.name;
        state.conversions ~= node.bound ? node.conversionFunction : node.conversion.length
            ? resolveCaptureConversion(node.conversion, mem) : null;
        return "(" ~ lower(node.children[0], mem, state) ~ ")";
    case NodeKind.splice:
        auto value = mem.get(node.text);
        if (value.kind != ValueKind.stringValue)
            throw new YshTypeError("Eggex splice requires Str (Eggex values are not translated yet)");
        return literalEre(value.stringValue);
    case NodeKind.charClass:
        string ordinary;
        bool rightBracket, backslash, caret, hyphen;
        foreach (term; node.children) {
            if (term.kind == NodeKind.primitive) {
                if (term.negated) throw new FatalRuntimeError("Classes cannot be negated within an ERE character class");
                ordinary ~= term.text;
            } else if (term.kind == NodeKind.sequence) {
                foreach (endpoint; term.children) {
                    checkClassCharacter(endpoint);
                    if (endpoint.text.indexOf(']') >= 0 || endpoint.text.indexOf('\\') >= 0 ||
                            endpoint.text.indexOf('^') >= 0 || endpoint.text.indexOf('-') >= 0)
                        throw new YshError("Special character cannot be an ERE range endpoint");
                }
                ordinary ~= term.children[0].text ~ "-" ~ term.children[1].text;
            } else {
                checkClassCharacter(term);
                auto text = term.text;
                if (term.kind == NodeKind.splice) {
                    auto value = mem.get(text);
                    if (value.kind != ValueKind.stringValue)
                        throw new YshTypeError("Character class splice requires Str");
                    text = value.stringValue;
                }
                foreach (char ch; text) {
                    switch (ch) {
                    case ']': rightBracket = true; break;
                    case '\\': backslash = true; break;
                    case '^': caret = true; break;
                    case '-': hyphen = true; break;
                    default: ordinary ~= ch; break;
                    }
                }
            }
        }
        return "[" ~ (node.negated ? "^" : "") ~ (rightBracket ? "]" : "") ~ ordinary ~
            (backslash ? "\\\\" : "") ~ (caret ? "^" : "") ~ (hyphen ? "-" : "") ~ "]";
    }
}

private class EggexParser {
    private Lexer lexer;
    private Token token;
    private string source;
    this(string source, ShellOptions options = null) { this.source = source; lexer = new Lexer(source, false, 0, true, options); advance(); }
    private void advance() { token = lexer.next(); }
    private void require(TokenKind kind) {
        if (token.kind != kind) throw new ParseError("Expected Eggex delimiter at byte " ~ to!string(token.offset));
        advance();
    }
    private bool isName() { return token.kind == TokenKind.name; }
    private string name() {
        if (!isName()) throw new ParseError("Expected name in Eggex");
        auto result = token.text;
        advance();
        return result;
    }

    private string decimalCount() {
        if (token.kind != TokenKind.integer) return "";
        auto result = token.text;
        foreach (char ch; result)
            if (ch < '0' || ch > '9') throw new ParseError("Eggex repeat count must be decimal digits");
        advance();
        return result;
    }

    Eggex parse() {
        require(TokenKind.slash);
        auto root = regex();
        int flags;
        string[] names;
        bool ereDialect = true;
        if (token.kind == TokenKind.semicolon) {
            advance();
            while (isName()) {
                auto flag = name();
                names ~= flag;
            }
            if (token.kind == TokenKind.semicolon) {
                advance();
                auto dialect = name();
                ereDialect = dialect == "ERE";
                // The reference accepts the preference syntactically; libc
                // still lowers to ERE. It is not a different matching engine.
            }
        }
        string canonicalFlags;
        if (ereDialect) {
            foreach (flag; names) {
                if (flag == "i" || flag == "reg_icase") { flags |= REG_ICASE; canonicalFlags ~= 'i'; }
                else if (flag == "reg_newline") { flags |= REG_NEWLINE; canonicalFlags ~= 'n'; }
                else throw new ParseError("Invalid regex flag " ~ flag);
            }
            auto normalized = cast(ubyte[])canonicalFlags.dup;
            sort(normalized);
            canonicalFlags = cast(string)normalized.idup;
        }
        if (token.kind != TokenKind.slash) throw new ParseError("Expected closing / in Eggex");
        return new Eggex(root, flags, token.offset + 1, canonicalFlags, ereDialect);
    }

    private bool atomStart() {
        return token.kind == TokenKind.stringValue || token.kind == TokenKind.charValue ||
            token.kind == TokenKind.name || token.kind == TokenKind.percent ||
            token.kind == TokenKind.dot || token.kind == TokenKind.caret ||
            token.kind == TokenKind.dollar || token.kind == TokenKind.at ||
            token.kind == TokenKind.bang || token.kind == TokenKind.leftParen ||
            token.kind == TokenKind.leftBracket || token.kind == TokenKind.less;
    }

    private Node regex() {
        Node[] alternatives;
        alternatives ~= sequence();
        while (token.kind == TokenKind.pipe || token.kind == TokenKind.orKeyword) {
            advance();
            if (!atomStart()) throw new ParseError("Expected alternative in Eggex");
            alternatives ~= sequence();
        }
        return alternatives.length == 1 ? alternatives[0] : new Node(NodeKind.alternate, "", alternatives);
    }

    private Node sequence() {
        Node[] nodes;
        while (atomStart()) {
            // 'as' ends a capture's regex before its optional name.
            if (token.kind == TokenKind.name && token.text == "as") break;
            auto node = atom();
            if (token.kind == TokenKind.plus || token.kind == TokenKind.star ||
                    token.kind == TokenKind.question) {
                auto operation = token.text;
                advance();
                node = new Node(NodeKind.repeat, operation, [node]);
            } else if (token.kind == TokenKind.leftBrace) {
                advance();
                string lowerBound, upperBound;
                lowerBound = decimalCount();
                bool comma = token.kind == TokenKind.comma;
                if (comma) {
                    advance();
                    upperBound = decimalCount();
                }
                if (lowerBound.length == 0 && upperBound.length == 0)
                    throw new ParseError("Expected repeat count in Eggex");
                require(TokenKind.rightBrace);
                node = new Node(NodeKind.repeat, "{" ~ lowerBound ~
                    (comma ? "," ~ upperBound : "") ~ "}", [node]);
            }
            nodes ~= node;
        }
        return nodes.length == 1 ? nodes[0] : new Node(NodeKind.sequence, "", nodes);
    }

    private Node atom() {
        auto kind = token.kind;
        auto text = token.text;
        advance();
        if (kind == TokenKind.stringValue || kind == TokenKind.charValue)
            return new Node(NodeKind.literal, text);
        if (kind == TokenKind.dot || kind == TokenKind.caret || kind == TokenKind.dollar)
            return new Node(NodeKind.primitive, text);
        if (kind == TokenKind.percent) {
            auto symbol = name();
            if (symbol != "start" && symbol != "end") throw new ParseError("Invalid Eggex symbol");
            return new Node(NodeKind.primitive, symbol == "start" ? "^" : "$");
        }
        if (kind == TokenKind.at) return new Node(NodeKind.splice, name());
        if (kind == TokenKind.name) {
            if (text == "dot") return new Node(NodeKind.primitive, ".");
            auto cls = posixClass(text);
            if (cls.length) return new Node(NodeKind.primitive, "[" ~ cls ~ "]");
            if (text[0] >= 'A' && text[0] <= 'Z') return new Node(NodeKind.splice, text);
            throw new ParseError("Not an Eggex character class: " ~ text);
        }
        if (kind == TokenKind.leftParen) {
            auto child = regex();
            require(TokenKind.rightParen);
            return new Node(NodeKind.group, "", [child]);
        }
        if (kind == TokenKind.less) {
            if (name() != "capture") throw new ParseError("Expected capture in Eggex");
            auto group = new Node(NodeKind.group, "", [regex()]);
            if (isName() && token.text == "as") { advance(); group.name = name(); }
            if (token.kind == TokenKind.colon) { advance(); group.conversion = name(); }
            require(TokenKind.greater);
            return group;
        }
        if (kind == TokenKind.leftBracket) return charClass(false);
        if (kind == TokenKind.bang) {
            if (token.kind == TokenKind.leftBracket) { advance(); return charClass(true); }
            auto cls = posixClass(name());
            if (cls.length == 0) throw new ParseError("Cannot negate this Eggex symbol");
            return new Node(NodeKind.primitive, "[^" ~ cls ~ "]");
        }
        throw new ParseError("Invalid Eggex atom");
    }

    private Node charClass(bool negated) {
        auto result = new Node(NodeKind.charClass);
        result.negated = negated;
        while (token.kind != TokenKind.rightBracket) {
            if (token.kind == TokenKind.at) {
                advance();
                result.children ~= new Node(NodeKind.splice, name());
                continue;
            }
            bool negate = token.kind == TokenKind.bang;
            if (negate) advance();
            auto kind = token.kind;
            auto text = token.text;
            auto tokenOffset = token.offset;
            if (kind != TokenKind.name && kind != TokenKind.integer &&
                    kind != TokenKind.stringValue && kind != TokenKind.charValue)
                throw new ParseError("Invalid Eggex character class term");
            advance();
            auto cls = kind == TokenKind.name && text.length > 1 ? posixClass(text) : "";
            if (cls.length) {
                auto term = new Node(NodeKind.primitive, cls);
                term.negated = negate;
                result.children ~= term;
                continue;
            }
            if (negate) throw new ParseError("Cannot negate a character");
            if (kind == TokenKind.integer && text.length != 1)
                throw new ParseError("Character class digit should be one digit");
            if (kind == TokenKind.name && text.length != 1)
                throw new ParseError("Not an Eggex character class: " ~ text);
            auto term = new Node(NodeKind.literal, text);
            term.characterLiteral = kind == TokenKind.charValue;
            term.unicodeCharacter = term.characterLiteral && source[tokenOffset .. tokenOffset + 2] == "\\u";
            if (token.kind == TokenKind.minus) {
                if (text.byDchar.walkLength != 1) throw new ParseError("Range endpoint must be one character");
                advance();
                auto end = token;
                if ((end.kind != TokenKind.name && end.kind != TokenKind.integer &&
                        end.kind != TokenKind.stringValue && end.kind != TokenKind.charValue) ||
                        end.text.byDchar.walkLength != 1)
                    throw new ParseError("Range endpoint must be one character");
                advance();
                auto endTerm = new Node(NodeKind.literal, end.text);
                endTerm.characterLiteral = end.kind == TokenKind.charValue;
                endTerm.unicodeCharacter = endTerm.characterLiteral && source[end.offset .. end.offset + 2] == "\\u";
                term = new Node(NodeKind.sequence, "", [term, endTerm]);
            }
            result.children ~= term;
        }
        if (!result.children.length) throw new ParseError("Empty Eggex character class");
        advance();
        return result;
    }
}

Eggex parseEggex(string source, ShellOptions options = null) { return (new EggexParser(source, options)).parse(); }
