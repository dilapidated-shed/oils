module yshd.program;

import std.format : format;
import std.string : strip;

import yshd.command : Mutation, VarDecl, executeMutation, executeVarDecl;
import yshd.expr : AssignmentScope;
import yshd.lexer : Lexer, Token, TokenKind;
import yshd.state : Memory;
import yshd.value : YshError;

/// First command-language parser layer for the D translation.
///
/// Oils already has a split between command parsing and YSH expression
/// parsing. This parser recognizes the translated VarDecl/Mutation command
/// forms, while RHS expression text is handed to the expression parser. As the
/// rest of command.Command moves to D, this module becomes the command parser
/// entry point rather than growing a separate mini-language.
class ProgramParser {
    private string source_;
    private Lexer lexer_;
    private Token current_;

    this(string source) {
        source_ = source;
        lexer_ = new Lexer(source, true);
        current_ = lexer_.next();
    }

    void execute(Memory mem) {
        skipEndStatements();

        while (current_.kind != TokenKind.eof) {
            final switch (current_.kind) {
            case TokenKind.varKeyword:
                parseDeclaration(mem, false);
                break;
            case TokenKind.constKeyword:
                parseDeclaration(mem, true);
                break;
            case TokenKind.setvarKeyword:
                parseMutation(mem, AssignmentScope.local);
                break;
            case TokenKind.setglobalKeyword:
                parseMutation(mem, AssignmentScope.global);
                break;
            default:
                throw new YshError(format(
                    "D YSH command parser has not translated command beginning with '%s' at byte %s",
                    current_.text, current_.offset));
            }

            skipEndStatements();
        }
    }

    private void parseDeclaration(Memory mem, bool readOnly) {
        advance(); // var / const

        string[] names;
        while (true) {
            if (current_.kind != TokenKind.name) {
                throw new YshError(format(
                    "expected variable name at byte %s", current_.offset));
            }
            names ~= current_.text;
            advance();

            if (current_.kind != TokenKind.comma) {
                break;
            }
            advance();
        }

        if (current_.kind == TokenKind.equal) {
            advance();
            auto rhs = collectRhs();
            executeVarDecl(VarDecl(names, readOnly, true, rhs), mem);
            return;
        }

        if (isEndStatement(current_.kind)) {
            executeVarDecl(VarDecl(names, readOnly, false, ""), mem);
            return;
        }

        // Type expressions belong here eventually. Fail closed rather than
        // silently accepting a declaration that has not actually been parsed.
        throw new YshError(format(
            "untranslated declaration syntax at byte %s", current_.offset));
    }

    private void parseMutation(Memory mem, AssignmentScope assignmentScope) {
        advance(); // setvar / setglobal

        string[] targets;
        size_t targetStart = current_.offset;
        int depth;

        while (true) {
            if (current_.kind == TokenKind.eof ||
                    current_.kind == TokenKind.newline ||
                    current_.kind == TokenKind.semicolon) {
                throw new YshError("expected '=' in mutation");
            }

            if (depth == 0 && current_.kind == TokenKind.equal) {
                auto target = strip(source_[targetStart .. current_.offset]);
                if (target.length == 0) {
                    throw new YshError("empty assignment target");
                }
                targets ~= target;
                advance();
                break;
            }

            if (depth == 0 && current_.kind == TokenKind.comma) {
                auto target = strip(source_[targetStart .. current_.offset]);
                if (target.length == 0) {
                    throw new YshError("empty assignment target");
                }
                targets ~= target;
                advance();
                targetStart = current_.offset;
                continue;
            }

            adjustDepth(depth, current_.kind);
            advance();
        }

        auto rhs = collectRhs();
        executeMutation(Mutation(targets, assignmentScope, rhs), mem);
    }

    /// Collect one YSH testlist through the end of the command. Top-level
    /// commas become a List expression, matching the semantic shape consumed by
    /// _DoVarDecl/_DoMutation after upstream expr_to_ast conversion.
    private string collectRhs() {
        if (isEndStatement(current_.kind)) {
            throw new YshError("expected expression on right side of '='");
        }

        size_t start = current_.offset;
        size_t end = source_.length;
        int depth;
        size_t topLevelCommas;

        while (current_.kind != TokenKind.eof) {
            if (depth == 0 && isEndStatement(current_.kind)) {
                end = current_.offset;
                break;
            }

            if (depth == 0 && current_.kind == TokenKind.comma) {
                ++topLevelCommas;
            }

            adjustDepth(depth, current_.kind);
            advance();
        }

        auto rhs = strip(source_[start .. end]);
        if (rhs.length == 0) {
            throw new YshError("expected expression on right side of '='");
        }

        if (topLevelCommas != 0) {
            rhs = "[" ~ rhs ~ "]";
        }
        return rhs;
    }

    private static void adjustDepth(ref int depth, TokenKind kind) {
        switch (kind) {
        case TokenKind.leftParen:
        case TokenKind.leftBracket:
        case TokenKind.leftBrace:
            ++depth;
            break;
        case TokenKind.rightParen:
        case TokenKind.rightBracket:
        case TokenKind.rightBrace:
            --depth;
            if (depth < 0) {
                throw new YshError("unbalanced delimiter");
            }
            break;
        default:
            break;
        }
    }

    private void skipEndStatements() {
        while (current_.kind == TokenKind.newline ||
                current_.kind == TokenKind.semicolon) {
            advance();
        }
    }

    private static bool isEndStatement(TokenKind kind) {
        return kind == TokenKind.newline ||
            kind == TokenKind.semicolon ||
            kind == TokenKind.eof;
    }

    private void advance() {
        current_ = lexer_.next();
    }
}

void executeProgram(string source, Memory mem) {
    auto parser = new ProgramParser(source);
    parser.execute(mem);
}

unittest {
    import yshd.expr : evaluate;
    import yshd.value : repr;

    auto mem = new Memory();

    executeProgram(
        "var x = 1\n" ~
        "setvar x = 42\n" ~
        "var a, b\n" ~
        "var left, right = 3, 4\n" ~
        "setvar left, right = right, left\n",
        mem);

    assert(repr(mem.get("x")) == "42");
    assert(repr(mem.get("a")) == "null");
    assert(repr(mem.get("b")) == "null");
    assert(repr(mem.get("left")) == "4");
    assert(repr(mem.get("right")) == "3");

    executeProgram(
        "var items = [1, 2, 3]\n" ~
        "setvar items[0], items[1] = items[1], items[0]\n" ~
        "var record = {int: 42}\n" ~
        "setvar items[0], record.int = record.int, items[0]\n",
        mem);

    assert(repr(mem.get("items")) == "[42, 1, 3]");
    assert(repr(evaluate("record.int", mem)) == "2");

    executeProgram("const fixed = 'value'\n", mem);
    bool rejected;
    try {
        executeProgram("setvar fixed = 'changed'\n", mem);
    } catch (YshError error) {
        rejected = true;
    }
    assert(rejected);

    // Comments terminate at the newline in command mode.
    executeProgram("var commented = 9 # note\nsetvar commented = 10\n", mem);
    assert(repr(mem.get("commented")) == "10");
}
