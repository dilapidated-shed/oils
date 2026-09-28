module yshd.program;

import std.format : format;
import std.string : strip;

import yshd.command : Mutation, VarDecl, executeMutation, executeVarDecl;
import yshd.expr : AssignmentScope, evaluate;
import yshd.func_proc : FunctionParameter, FunctionReturn, YshFunction;
import yshd.lexer : Lexer, Token, TokenKind;
import yshd.state : Memory;
import yshd.value : Value, ValueKind, YshError, toBool;

private class IfCommand {
    string conditionSource;
    string thenSource;
    string elseSource;
    IfCommand elseIf;
    bool hasElse;
}

private class LoopControl : Exception {
    bool shouldBreak;

    this(bool shouldBreak) {
        super(shouldBreak ? "YSH break" : "YSH continue");
        this.shouldBreak = shouldBreak;
    }
}

/// First command-language parser layer for the D translation.
///
/// Oils already has a split between command parsing and YSH expression
/// parsing. This parser recognizes translated declaration, mutation,
/// function, return, conditional, and while-loop command forms, while
/// expression text is handed to the expression parser. Unsupported command
/// forms fail closed.
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
            case TokenKind.whileKeyword:
                parseWhile(mem);
                break;
            case TokenKind.forKeyword:
                parseFor(mem);
                break;
            case TokenKind.breakKeyword:
                parseLoopControl(mem, true);
                break;
            case TokenKind.continueKeyword:
                parseLoopControl(mem, false);
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

    private void parseWhile(Memory mem) {
        advance(); // while
        auto conditionSource = current_.kind == TokenKind.leftParen
            ? collectParenthesizedExpression()
            : collectConditionThroughBlock();
        auto bodySource = collectBlock();

        while (toBool(evaluate(conditionSource, mem))) {
            mem.enterLoop();
            scope (exit) mem.leaveLoop();
            try {
                executeProgram(bodySource, mem);
            } catch (LoopControl control) {
                if (control.shouldBreak) {
                    break;
                }
            }
        }
    }

    /// First expression-iterator form of YSH `for`. Shell word expansion,
    /// stdin, and glob iteration remain separate frontend/runtime work.
    private void parseFor(Memory mem) {
        advance(); // for
        string[] names;
        while (true) {
            if (current_.kind != TokenKind.name) {
                throw new YshError(format("expected loop variable at byte %s", current_.offset));
            }
            names ~= current_.text;
            advance();
            if (current_.kind != TokenKind.comma) {
                break;
            }
            advance();
        }
        if (names.length > 3) {
            throw new YshError("for loops support at most three loop variables");
        }
        require(TokenKind.inKeyword, "in");
        auto iterableSource = collectParenthesizedExpression();
        auto bodySource = collectBlock();
        auto iterable = evaluate(iterableSource, mem);

        mem.enterLoop();
        scope (exit) mem.leaveLoop();
        switch (iterable.kind) {
        case ValueKind.list:
            // YSH List iteration observes its changing length as the loop
            // runs, so appends extend the loop and removals shorten it.
            size_t index;
            while (index < iterable.listValue.length) {
                auto item = iterable.listValue.items[index];
                Value[] bindings;
                if (names.length == 1) {
                    bindings = [item];
                } else if (names.length == 2) {
                    bindings = [Value.integer(cast(long) index), item];
                } else {
                    throw new YshError("List for loop accepts one or two variables");
                }
                bindLoopVariables(names, bindings, mem);
                try {
                    executeProgram(bodySource, mem);
                } catch (LoopControl control) {
                    if (control.shouldBreak) {
                        break;
                    }
                }
                ++index;
            }
            break;
        case ValueKind.dict:
            // Dict iteration is over a stable key/value snapshot: mutations
            // during the body do not change which entries this loop visits.
            auto keys = iterable.dictValue.keys();
            auto values = iterable.dictValue.values();
            foreach (index, key; keys) {
                Value[] bindings;
                if (names.length == 1) {
                    bindings = [Value.str(key)];
                } else if (names.length == 2) {
                    bindings = [Value.str(key), values[index]];
                } else {
                    bindings = [Value.integer(cast(long) index), Value.str(key), values[index]];
                }
                bindLoopVariables(names, bindings, mem);
                try {
                    executeProgram(bodySource, mem);
                } catch (LoopControl control) {
                    if (control.shouldBreak) {
                        break;
                    }
                }
            }
            break;
        case ValueKind.rangeValue:
            if (names.length != 1) {
                throw new YshError("Range for loop accepts one variable");
            }
            for (auto item = iterable.rangeLower; item < iterable.rangeUpper; ++item) {
                bindLoopVariables(names, [Value.integer(item)], mem);
                try {
                    executeProgram(bodySource, mem);
                } catch (LoopControl control) {
                    if (control.shouldBreak) {
                        break;
                    }
                }
            }
            break;
        default:
            throw new YshError(format("Object of type %s is not iterable", iterable.kind));
        }
    }

    private static void bindLoopVariables(string[] names, Value[] values, Memory mem) {
        foreach (index, name; names) {
            mem.declareLocal(name, values[index]);
        }
    }

    private string collectConditionThroughBlock() {
        auto start = current_.offset;
        auto end = start;
        int depth;
        while (current_.kind != TokenKind.eof) {
            if (depth == 0 && current_.kind == TokenKind.leftBrace) {
                end = current_.offset;
                break;
            }
            if (depth == 0 && isEndStatement(current_.kind)) {
                throw new YshError("expected '{' after while condition");
            }
            end = current_.offset + current_.text.length;
            adjustDepth(depth, current_.kind);
            advance();
        }
        auto condition = strip(source_[start .. end]);
        if (condition.length == 0) {
            throw new YshError("while condition cannot be empty");
        }
        return condition;
    }

    private void parseLoopControl(Memory mem, bool shouldBreak) {
        advance();
        if (!mem.insideLoop()) {
            throw new YshError(shouldBreak
                ? "break is only valid inside a loop"
                : "continue is only valid inside a loop");
        }
        if (!isEndStatement(current_.kind)) {
            throw new YshError("break and continue arguments are not translated yet");
        }
        throw new LoopControl(shouldBreak);
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

    executeProgram(
        "func factorial(number) {\n" ~
        "  if (number <= 1) { return (1) }\n" ~
        "  return (number * factorial(number - 1))\n" ~
        "}\n" ~
        "var factorial_of_six = factorial(6)\n",
        mem);
    assert(repr(mem.get("factorial_of_six")) == "720");

    executeProgram(
        "var iteration = 0\n" ~
        "var visits = 0\n" ~
        "while (iteration < 5) {\n" ~
        "  setvar iteration = iteration + 1\n" ~
        "  if (iteration === 2) { continue }\n" ~
        "  if (iteration === 4) { break }\n" ~
        "  setvar visits = visits + 1\n" ~
        "}\n" ~
        "var once = 0\n" ~
        "while true { setvar once = once + 1; break }\n",
        mem);
    assert(repr(mem.get("iteration")) == "4");
    assert(repr(mem.get("visits")) == "2");
    assert(repr(mem.get("once")) == "1");

    executeProgram(
        "var list_total = 0\n" ~
        "for item in ([1, 2, 3]) { setvar list_total = list_total + item }\n" ~
        "var indexed = 0\n" ~
        "for index, item in ([10, 20, 30]) {\n" ~
        "  setvar indexed = indexed + index + item\n" ~
        "}\n" ~
        "var range_total = 0\n" ~
        "for item in (0 ..< 4) { setvar range_total = range_total + item }\n" ~
        "var dict_total = 0\n" ~
        "for index, key, value in ({first: 5, second: 7}) {\n" ~
        "  setvar dict_total = dict_total + index + value\n" ~
        "}\n" ~
        "var loop_skips = 0\n" ~
        "for item in ([1, 2, 3, 4]) {\n" ~
        "  if (item === 2) { continue }\n" ~
        "  if (item === 4) { break }\n" ~
        "  setvar loop_skips = loop_skips + item\n" ~
        "}\n",
        mem);
    assert(repr(mem.get("list_total")) == "6");
    assert(repr(mem.get("indexed")) == "63");
    assert(repr(mem.get("range_total")) == "6");
    assert(repr(mem.get("dict_total")) == "13");
    assert(repr(mem.get("loop_skips")) == "4");

    bool rejectedNonIterable;
    try {
        executeProgram("for item in (42) { setvar item = 1 }\n", mem);
    } catch (YshError error) {
        rejectedNonIterable = true;
    }
    assert(rejectedNonIterable);

    bool rejectedThreeVariableList;
    try {
        executeProgram("for i, item, extra in ([1, 2]) {}\n", mem);
    } catch (YshError error) {
        rejectedThreeVariableList = true;
    }
    assert(rejectedThreeVariableList);

    bool rejectedBreakOutsideLoop;
    try {
        executeProgram("break\n", mem);
    } catch (YshError error) {
        rejectedBreakOutsideLoop = true;
    }
    assert(rejectedBreakOutsideLoop);

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
