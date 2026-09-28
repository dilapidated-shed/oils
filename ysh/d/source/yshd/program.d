module yshd.program;

import std.format : format;
import std.string : strip;

import yshd.command : Mutation, VarDecl, executeMutation, executeVarDecl;
import yshd.expr : AssignmentScope, evaluate;
import yshd.func_proc : FunctionParameter, FunctionReturn, YshFunction;
import yshd.lexer : Lexer, Token, TokenKind;
import yshd.state : Memory;
import yshd.value : Value, YshError, toBool;

private class IfCommand {
    string conditionSource;
    string thenSource;
    string elseSource;
    IfCommand elseIf;
    bool hasElse;
}

/// First command-language parser layer for the D translation.
///
/// Oils already has a split between command parsing and YSH expression
/// parsing. This parser recognizes translated declaration, mutation,
/// function, return, and conditional command forms, while expression text is
/// handed to the expression parser. Unsupported command forms fail closed.
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
            switch (current_.kind) {
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
            case TokenKind.funcKeyword:
                parseFunction(mem);
                break;
            case TokenKind.returnKeyword:
                parseReturn(mem);
                break;
            case TokenKind.ifKeyword:
                parseIf(mem);
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

    private void parseFunction(Memory mem) {
        advance(); // func
        if (current_.kind != TokenKind.name) {
            throw new YshError(format("expected function name at byte %s", current_.offset));
        }
        auto name = current_.text;
        advance();
        require(TokenKind.leftParen, "(");
        FunctionParameter[] parameters;
        bool sawDefault;

        if (current_.kind != TokenKind.rightParen) {
            while (true) {
                if (current_.kind != TokenKind.name) {
                    throw new YshError(format("expected parameter name at byte %s", current_.offset));
                }
                auto parameterName = current_.text;
                advance();
                string defaultSource;

                if (current_.kind == TokenKind.equal) {
                    sawDefault = true;
                    advance();
                    defaultSource = collectParameterDefault();
                    if (defaultSource.length == 0) {
                        throw new YshError("expected parameter default expression");
                    }
                } else if (sawDefault) {
                    throw new YshError("required parameter follows a default parameter");
                }
                parameters ~= FunctionParameter(parameterName, defaultSource);

                if (current_.kind != TokenKind.comma) {
                    break;
                }
                advance();
                if (current_.kind == TokenKind.rightParen) {
                    break;
                }
            }
        }
        require(TokenKind.rightParen, ")");
        require(TokenKind.leftBrace, "{");

        auto bodyStart = current_.offset;
        int braceDepth = 1;
        while (current_.kind != TokenKind.eof && braceDepth != 0) {
            if (current_.kind == TokenKind.leftBrace) {
                ++braceDepth;
            } else if (current_.kind == TokenKind.rightBrace) {
                --braceDepth;
                if (braceDepth == 0) {
                    break;
                }
            }
            advance();
        }
        if (braceDepth != 0) {
            throw new YshError("unterminated function body");
        }
        auto bodyEnd = current_.offset;
        auto body = source_[bodyStart .. bodyEnd];
        advance(); // closing brace

        auto userFunction = new YshFunction(name, parameters, body, mem);
        mem.declareLocal(name, Value.callable(userFunction));
    }

    private string collectParameterDefault() {
        auto start = current_.offset;
        auto end = start;
        int depth;
        while (current_.kind != TokenKind.eof) {
            if (depth == 0 && (current_.kind == TokenKind.comma ||
                    current_.kind == TokenKind.rightParen)) {
                end = current_.offset;
                break;
            }
            end = current_.offset + current_.text.length;
            adjustDepth(depth, current_.kind);
            advance();
        }
        return strip(source_[start .. end]);
    }

    private void parseReturn(Memory mem) {
        advance(); // return
        if (mem.currentFrame.enclosed is null) {
            throw new YshError("return is only valid inside a function");
        }
        if (isEndStatement(current_.kind)) {
            throw new YshError("return requires a value expression");
        }
        throw new FunctionReturn(evaluate(collectRhs(), mem));
    }

    private void parseIf(Memory mem) {
        auto command = parseIfCommand();
        while (command !is null) {
            if (toBool(evaluate(command.conditionSource, mem))) {
                executeProgram(command.thenSource, mem);
                return;
            }
            if (command.elseIf !is null) {
                command = command.elseIf;
                continue;
            }
            if (command.hasElse) {
                executeProgram(command.elseSource, mem);
            }
            return;
        }
    }

    private IfCommand parseIfCommand() {
        require(TokenKind.ifKeyword, "if");
        auto command = new IfCommand();
        command.conditionSource = collectParenthesizedExpression();
        command.thenSource = collectBlock();

        // `else` may follow the closing brace on the same or next line.
        skipEndStatements();
        if (current_.kind == TokenKind.elseKeyword) {
            advance();
            command.hasElse = true;
            if (current_.kind == TokenKind.ifKeyword) {
                command.elseIf = parseIfCommand();
            } else {
                command.elseSource = collectBlock();
            }
        }
        return command;
    }

    private string collectParenthesizedExpression() {
        require(TokenKind.leftParen, "(");
        auto start = current_.offset;
        auto end = start;
        int depth;

        while (current_.kind != TokenKind.eof) {
            if (depth == 0 && current_.kind == TokenKind.rightParen) {
                end = current_.offset;
                advance();
                auto expression = strip(source_[start .. end]);
                if (expression.length == 0) {
                    throw new YshError("if condition cannot be empty");
                }
                return expression;
            }
            end = current_.offset + current_.text.length;
            adjustDepth(depth, current_.kind);
            advance();
        }
        throw new YshError("unterminated if condition");
    }

    private string collectBlock() {
        require(TokenKind.leftBrace, "{");
        auto start = current_.offset;
        int depth = 1;
        while (current_.kind != TokenKind.eof && depth != 0) {
            if (current_.kind == TokenKind.leftBrace) {
                ++depth;
            } else if (current_.kind == TokenKind.rightBrace) {
                --depth;
                if (depth == 0) {
                    auto body = source_[start .. current_.offset];
                    advance();
                    return body;
                }
            }
            advance();
        }
        throw new YshError("unterminated command block");
    }

    private void require(TokenKind kind, string spelling) {
        if (current_.kind != kind) {
            throw new YshError(format("expected '%s' at byte %s", spelling, current_.offset));
        }
        advance();
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

    executeProgram(
        "var captured = 40\n" ~
        "var default_value = 2\n" ~
        "func add(amount, extra = default_value) {\n" ~
        "  var result = captured + amount + extra\n" ~
        "  return (result)\n" ~
        "}\n" ~
        "var answer = add(0)\n" ~
        "setvar default_value = 99\n" ~
        "var explicit_answer = add(1, 3)\n",
        mem);
    assert(repr(mem.get("answer")) == "42");
    assert(repr(mem.get("explicit_answer")) == "44");

    executeProgram(
        "func classify(number) {\n" ~
        "  if (number < 0) {\n" ~
        "    return (-1)\n" ~
        "  } else if (number === 0) {\n" ~
        "    return (0)\n" ~
        "  } else {\n" ~
        "    return (1)\n" ~
        "  }\n" ~
        "}\n" ~
        "var negative = classify(-2)\n" ~
        "var zero = classify(0)\n" ~
        "var positive = classify(3)\n",
        mem);
    assert(repr(mem.get("negative")) == "-1");
    assert(repr(mem.get("zero")) == "0");
    assert(repr(mem.get("positive")) == "1");

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
