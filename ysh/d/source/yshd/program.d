module yshd.program;

import std.conv : to;
import std.file : chdir, readText;
import std.format : format;
import std.stdio : File;
import std.string : indexOf, join, split, strip;

import yshd.command : Mutation, VarDecl, executeMutation, executeVarDecl;
import yshd.expr : AssignmentScope, evaluate;
import yshd.func_proc : FunctionParameter, FunctionReturn, YshFunction, YshProc;
import yshd.io_ysh : WriteEncoding, renderEcho, renderWrite, spliceArray;
import yshd.lexer : Lexer, Token, TokenKind;
import yshd.process : runExternal, runPipeline;
import yshd.state : Memory;
import yshd.value : Value, ValueKind, YshError, stringify, toBool;

private class IfCommand {
    string conditionSource;
    string thenSource;
    string elseSource;
    IfCommand elseIf;
    bool hasElse;
}

class ShellExit : Exception {
    int status;

    this(int status) {
        super("YSH exit");
        this.status = status;
    }
}

private class LoopControl : Exception {
    bool shouldBreak;
    size_t levels;

    this(bool shouldBreak, size_t levels = 1) {
        super(shouldBreak ? "YSH break" : "YSH continue");
        this.shouldBreak = shouldBreak;
        this.levels = levels;
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
            case TokenKind.procKeyword:
                parseProc(mem);
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
            case TokenKind.trueKeyword:
                advance();
                if (!isEndStatement(current_.kind)) {
                    throw new YshError("true does not accept arguments");
                }
                mem.lastStatus = 0;
                break;
            case TokenKind.falseKeyword:
                advance();
                if (!isEndStatement(current_.kind)) {
                    throw new YshError("false does not accept arguments");
                }
                mem.lastStatus = 1;
                break;
            case TokenKind.colon:
                parseNoOp(mem);
                break;
            case TokenKind.name:
                if (current_.text == "assert") {
                    parseAssert(mem);
                    break;
                }
                if (current_.text == "write") {
                    parseWrite(mem);
                    break;
                }
                if (current_.text == "echo") {
                    parseEcho(mem);
                    break;
                }
                if (current_.text == "call") {
                    parseCall(mem);
                    break;
                }
                if (current_.text == "shopt") {
                    parseShopt(mem);
                    break;
                }
                if (current_.text == "cd") {
                    parseCd(mem);
                    break;
                }
                if (current_.text == "source") {
                    parseSource(mem);
                    break;
                }
                if (current_.text == "eval") {
                    parseEval(mem);
                    break;
                }
                if (current_.text == "exit") {
                    parseExit(mem);
                    break;
                }
                parseCommandInvocation(mem);
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
        FunctionParameter[] namedParameters;
        string restPositionalName;
        string restNamedName;
        bool namedGroup;
        bool sawDefault;

        while (current_.kind != TokenKind.rightParen) {
            if (current_.kind == TokenKind.semicolon) {
                if (namedGroup) {
                    throw new YshError("function signature has more than one named-parameter separator");
                }
                namedGroup = true;
                sawDefault = false;
                advance();
                continue;
            }

            if (current_.kind == TokenKind.ellipsis) {
                advance();
                if (current_.kind != TokenKind.name) {
                    throw new YshError(format(
                        "expected rest parameter name at byte %s", current_.offset));
                }
                auto restName = current_.text;
                advance();

                if (namedGroup) {
                    if (restNamedName.length != 0) {
                        throw new YshError("function has more than one named rest parameter");
                    }
                    restNamedName = restName;
                } else {
                    if (restPositionalName.length != 0) {
                        throw new YshError("function has more than one positional rest parameter");
                    }
                    restPositionalName = restName;
                }

                if (current_.kind == TokenKind.comma) {
                    advance();
                    if (current_.kind != TokenKind.semicolon &&
                            current_.kind != TokenKind.rightParen) {
                        throw new YshError(
                            "rest parameter must be last in its parameter group");
                    }
                } else if (current_.kind != TokenKind.semicolon &&
                        current_.kind != TokenKind.rightParen) {
                    throw new YshError(
                        "rest parameter must be last in its parameter group");
                }
                continue;
            }

            if (current_.kind != TokenKind.name) {
                throw new YshError(format(
                    "expected parameter name at byte %s", current_.offset));
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

            if (namedGroup) {
                namedParameters ~= FunctionParameter(parameterName, defaultSource);
            } else {
                parameters ~= FunctionParameter(parameterName, defaultSource);
            }

            if (current_.kind == TokenKind.comma) {
                advance();
                continue;
            }
            if (current_.kind != TokenKind.semicolon &&
                    current_.kind != TokenKind.rightParen) {
                throw new YshError(format(
                    "untranslated function parameter syntax at byte %s",
                    current_.offset));
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

        auto userFunction = new YshFunction(name, parameters, body, mem,
            restPositionalName, namedParameters, restNamedName);
        mem.declareLocal(name, Value.callable(userFunction));
    }

    private void parseProc(Memory mem) {
        advance(); // proc

        if (current_.kind == TokenKind.eof ||
                current_.kind == TokenKind.newline ||
                current_.kind == TokenKind.leftBrace ||
                current_.kind == TokenKind.leftParen) {
            throw new YshError(format(
                "expected proc name at byte %s", current_.offset));
        }

        auto nameStart = current_.offset;
        auto nameEnd = nameStart;
        while (nameEnd < source_.length &&
                !isCommandWhitespace(source_[nameEnd]) &&
                source_[nameEnd] != '(' && source_[nameEnd] != '{') {
            ++nameEnd;
        }
        auto name = source_[nameStart .. nameEnd];
        while (current_.kind != TokenKind.eof && current_.offset < nameEnd) {
            advance();
        }

        bool openSignature = true;
        FunctionParameter[] wordParameters;
        string restWordName;
        bool sawDefault;

        if (current_.kind == TokenKind.leftParen) {
            openSignature = false;
            advance();

            while (current_.kind != TokenKind.rightParen) {
                if (current_.kind == TokenKind.semicolon) {
                    throw new YshError(
                        "typed/named/block proc parameter groups are not translated yet");
                }

                if (current_.kind == TokenKind.ellipsis) {
                    advance();
                    if (current_.kind != TokenKind.name) {
                        throw new YshError(format(
                            "expected proc rest parameter name at byte %s",
                            current_.offset));
                    }
                    restWordName = current_.text;
                    advance();
                    if (current_.kind == TokenKind.comma) {
                        advance();
                    }
                    if (current_.kind != TokenKind.rightParen) {
                        throw new YshError(
                            "proc rest parameter must be last in its word parameter group");
                    }
                    break;
                }

                if (current_.kind != TokenKind.name) {
                    throw new YshError(format(
                        "expected proc word parameter at byte %s",
                        current_.offset));
                }

                auto parameterName = current_.text;
                advance();
                string defaultSource;
                if (current_.kind == TokenKind.equal) {
                    sawDefault = true;
                    advance();
                    defaultSource = collectParameterDefault();
                    if (defaultSource.length == 0) {
                        throw new YshError(
                            "expected proc parameter default expression");
                    }
                } else if (sawDefault) {
                    throw new YshError(
                        "required parameter follows a default parameter");
                }

                wordParameters ~= FunctionParameter(
                    parameterName, defaultSource);

                if (current_.kind == TokenKind.comma) {
                    advance();
                    continue;
                }
                if (current_.kind != TokenKind.rightParen) {
                    throw new YshError(format(
                        "untranslated proc parameter syntax at byte %s",
                        current_.offset));
                }
            }

            require(TokenKind.rightParen, ")");
        }

        auto body = collectBlock();
        auto userProc = new YshProc(name, body, mem, openSignature,
            wordParameters, restWordName);
        mem.declareLocal(name, Value.proc(userProc));
    }

    private struct SavedEnvBinding {
        string name;
        bool existed;
        Value value;
    }

    private static bool splitTempBinding(string word,
            out string name, out string value) {
        auto equal = word.indexOf('=');
        if (equal <= 0) {
            return false;
        }

        name = word[0 .. cast(size_t)equal];
        if (!asciiIdentifierStart(name[0])) {
            return false;
        }
        foreach (c; name[1 .. $]) {
            if (!asciiIdentifierContinue(c)) {
                return false;
            }
        }

        value = word[cast(size_t)equal + 1 .. $];
        return true;
    }

    private static SavedEnvBinding[] applyTempBindings(
            string[string] bindings, Memory mem) {
        SavedEnvBinding[] saved;
        auto envValue = mem.get("ENV");
        if (envValue.kind != ValueKind.dict) {
            throw new YshError("ENV must be a Dict");
        }

        foreach (name, text; bindings) {
            auto old = envValue.dictValue.find(name);
            if (old is null) {
                saved ~= SavedEnvBinding(name, false, Value.nullValue());
            } else {
                saved ~= SavedEnvBinding(name, true, *old);
            }
            envValue.dictValue.set(name, Value.str(text));
        }
        return saved;
    }

    private static void restoreTempBindings(
            SavedEnvBinding[] saved, Memory mem) {
        auto envValue = mem.get("ENV");
        if (envValue.kind != ValueKind.dict) {
            throw new YshError("ENV must be a Dict");
        }
        foreach_reverse (entry; saved) {
            if (entry.existed) {
                envValue.dictValue.set(entry.name, entry.value);
            } else {
                envValue.dictValue.erase(entry.name);
            }
        }
    }

    private void parseCommandInvocation(Memory mem) {
        auto commandNameParts = readCommandWord(mem);
        if (commandNameParts.length != 1) {
            throw new YshError("command name cannot be a list splice");
        }

        string[string] tempBindings;
        auto commandName = commandNameParts[0];
        string bindingName;
        string bindingValue;
        while (splitTempBinding(commandName, bindingName, bindingValue)) {
            tempBindings[bindingName] = bindingValue;
            if (isEndStatement(current_.kind)) {
                foreach (name, text; tempBindings) {
                    mem.setVar(name, Value.str(text));
                }
                mem.lastStatus = 0;
                return;
            }
            commandNameParts = readCommandWord(mem);
            if (commandNameParts.length != 1) {
                throw new YshError("command name cannot be a list splice");
            }
            commandName = commandNameParts[0];
        }

        string[][] pipeline;
        string[] argv = [commandName];

        while (!isEndStatement(current_.kind)) {
            if (current_.kind == TokenKind.pipe) {
                pipeline ~= argv;
                argv = [];
                advance();
                if (isEndStatement(current_.kind) ||
                        current_.kind == TokenKind.pipe) {
                    throw new YshError("expected command after '|'");
                }
                auto nextName = readCommandWord(mem);
                if (nextName.length != 1) {
                    throw new YshError(
                        "pipeline command name cannot be a list splice");
                }
                argv ~= nextName[0];
                continue;
            }
            argv ~= readCommandWord(mem);
        }

        auto saved = applyTempBindings(tempBindings, mem);
        scope (exit) restoreTempBindings(saved, mem);

        if (pipeline.length == 0) {
            auto cell = mem.getCell(commandName);
            if (cell !is null && cell.value.kind == ValueKind.procValue) {
                auto userProc = cast(YshProc)cell.value.callableValue;
                if (userProc is null) {
                    throw new YshError(format(
                        "invalid proc value '%s'", commandName));
                }
                userProc.invoke(argv[1 .. $], mem);
                mem.lastStatus = 0;
                return;
            }

            mem.lastStatus = runExternal(argv, mem);
            return;
        }

        pipeline ~= argv;
        mem.lastStatus = runPipeline(pipeline, mem);
    }

    /// Accept the option-setting forms that gate YSH syntax in the upstream
    /// spec suite.  The translated parser already speaks YSH directly, so
    /// these settings do not need to switch parser modes here.
    private void parseShopt(Memory mem) {
        advance(); // shopt
        while (!isEndStatement(current_.kind)) {
            readCommandWord(mem);
        }
        mem.lastStatus = 0;
    }

    private void parseNoOp(Memory mem) {
        advance(); // :
        if (!isEndStatement(current_.kind)) {
            throw new YshError(": does not accept arguments");
        }
        mem.lastStatus = 0;
    }

    private void parseSource(Memory mem) {
        advance(); // source
        if (isEndStatement(current_.kind)) {
            throw new YshError("source requires a path");
        }
        auto words = readCommandWord(mem);
        if (words.length != 1 || !isEndStatement(current_.kind)) {
            throw new YshError("source accepts exactly one path");
        }

        try {
            executeProgram(readText(words[0]), mem);
        } catch (YshError error) {
            throw error;
        } catch (Exception error) {
            throw new YshError(format("source %s: %s", words[0], error.msg));
        }
        mem.lastStatus = 0;
    }

    private void parseEval(Memory mem) {
        advance(); // eval
        string[] words;
        while (!isEndStatement(current_.kind)) {
            words ~= readCommandWord(mem);
        }
        executeProgram(words.join(" "), mem);
        mem.lastStatus = 0;
    }

    private void parseExit(Memory mem) {
        advance(); // exit
        int status = mem.lastStatus;
        if (!isEndStatement(current_.kind)) {
            auto words = readCommandWord(mem);
            if (words.length != 1 || !isEndStatement(current_.kind)) {
                throw new YshError("exit accepts zero or one status");
            }
            try {
                status = to!int(words[0]);
            } catch (Exception error) {
                throw new YshError("exit status must be an integer");
            }
        }
        throw new ShellExit(status);
    }

    private void parseCd(Memory mem) {
        advance(); // cd

        string target;
        if (isEndStatement(current_.kind)) {
            target = mem.getEnv("HOME");
            if (target.length == 0) {
                throw new YshError("cd: HOME is not set");
            }
        } else {
            auto words = readCommandWord(mem);
            if (words.length != 1 || !isEndStatement(current_.kind)) {
                throw new YshError("cd accepts zero or one path");
            }
            target = words[0];
        }

        try {
            chdir(target);
        } catch (Exception error) {
            throw new YshError(format("cd: %s", error.msg));
        }
        mem.lastStatus = 0;
    }

    private string collectParameterDefault() {
        auto start = current_.offset;
        auto end = start;
        int depth;
        while (current_.kind != TokenKind.eof) {
            if (depth == 0 && (current_.kind == TokenKind.comma ||
                    current_.kind == TokenKind.semicolon ||
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
        if (current_.kind != TokenKind.ifKeyword &&
                current_.kind != TokenKind.elifKeyword) {
            throw new YshError(format(
                "expected 'if' or 'elif' at byte %s", current_.offset));
        }
        advance();
        auto command = new IfCommand();
        command.conditionSource = collectParenthesizedExpression();
        command.thenSource = collectBlock();

        // `else` may follow the closing brace on the same or next line.
        skipEndStatements();
        if (current_.kind == TokenKind.elifKeyword) {
            command.hasElse = true;
            command.elseIf = parseIfCommand();
        } else if (current_.kind == TokenKind.elseKeyword) {
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
                if (control.levels > 1) {
                    --control.levels;
                    throw control;
                }
                if (control.shouldBreak) {
                    break;
                }
            }
        }
    }

    /// First expression-iterator and literal shell-word forms of YSH `for`.
    /// Full shell expansion, stdin, and glob iteration remain separate work.
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
        if (current_.kind != TokenKind.leftParen) {
            if (names.length > 2) {
                throw new YshError("Shell-word for loops accept at most two variables");
            }
            string[] words;
            while (current_.kind != TokenKind.leftBrace) {
                if (isEndStatement(current_.kind)) {
                    throw new YshError("expected '{' after for-loop words");
                }
                words ~= readCommandWord(mem);
            }
            auto bodySource = collectBlock();
            mem.enterLoop();
            scope (exit) mem.leaveLoop();
            foreach (index, word; words) {
                Value[] bindings = names.length == 1
                    ? [Value.str(word)]
                    : [Value.integer(cast(long) index), Value.str(word)];
                bindLoopVariables(names, bindings, mem);
                try {
                    executeProgram(bodySource, mem);
                } catch (LoopControl control) {
                if (control.levels > 1) {
                    --control.levels;
                    throw control;
                }
                    if (control.shouldBreak) {
                        break;
                    }
                }
            }
            return;
        }

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
                if (control.levels > 1) {
                    --control.levels;
                    throw control;
                }
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
                if (control.levels > 1) {
                    --control.levels;
                    throw control;
                }
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
                if (control.levels > 1) {
                    --control.levels;
                    throw control;
                }
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

    /// YSH `call f(...)` evaluates a function-call expression for its
    /// side effects and discards the returned value.
    private void parseAssert(Memory mem) {
        advance(); // assert
        if (isEndStatement(current_.kind)) {
            throw new YshError("assert requires an expression");
        }

        string expression;
        if (current_.kind == TokenKind.leftBracket) {
            expression = collectBracketedExpression("assert");
        } else {
            expression = collectRhs();
        }

        if (!toBool(evaluate(expression, mem))) {
            throw new YshError("assertion failed");
        }
        mem.lastStatus = 0;
    }

    private void parseCall(Memory mem) {
        advance(); // call
        if (isEndStatement(current_.kind)) {
            throw new YshError("call requires a function-call expression");
        }
        evaluate(collectRhs(), mem);
    }

    /// Translate builtin/io_ysh.py:Write for the already-translated word
    /// forms. JSON/J8 string encoding follows data_lang/j8.py.
    private void parseWrite(Memory mem) {
        advance(); // write
        string separator = "\n";
        string ending = "\n";
        bool noNewline;
        bool jsonEncoding;
        bool j8Encoding;
        bool options = true;
        string[] arguments;

        while (!isEndStatement(current_.kind)) {
            if (options && atRawWord("--sep")) {
                consumeRawWord("--sep");
                separator = readLiteralWord("--sep requires a separator word");
            } else if (options && atRawWord("--end")) {
                consumeRawWord("--end");
                ending = readLiteralWord("--end requires an ending word");
            } else if (options && atRawWord("--json")) {
                consumeRawWord("--json");
                jsonEncoding = true;
            } else if (options && atRawWord("--j8")) {
                consumeRawWord("--j8");
                j8Encoding = true;
            } else if (options && atRawWord("-n")) {
                consumeRawWord("-n");
                noNewline = true;
            } else if (options && atRawWord("--")) {
                consumeRawWord("--");
                options = false;
            } else if (options && current_.kind == TokenKind.minus) {
                throw new YshError(format(
                    "invalid write option beginning at byte %s", current_.offset));
            } else {
                arguments ~= readCommandWord(mem);
            }
        }

        if (noNewline) {
            ending = "";
        }

        // builtin/io_ysh.py tests json before j8 when both flags are present.
        auto encoding = jsonEncoding
            ? WriteEncoding.json
            : (j8Encoding ? WriteEncoding.j8 : WriteEncoding.plain);
        mem.outputFile.write(renderWrite(arguments, separator, ending, encoding));
    }

    /// Translate builtin/io_osh.py:Echo for the command-word forms currently
    /// handled by the D word evaluator. ParseLikeEcho accepts any leading
    /// combination of -e and -n; the first non-flag word ends flag parsing.
    private void parseEcho(Memory mem) {
        advance(); // echo
        bool noNewline;
        bool interpretEscapes;
        string[] arguments;
        bool parsingFlags = true;

        while (!isEndStatement(current_.kind)) {
            if (parsingFlags &&
                    consumeEchoFlags(noNewline, interpretEscapes)) {
                continue;
            }
            parsingFlags = false;
            arguments ~= readCommandWord(mem);
        }
        mem.outputFile.write(renderEcho(arguments, noNewline, interpretEscapes));
    }

    private bool consumeEchoFlags(ref bool noNewline,
            ref bool interpretEscapes) {
        if (current_.kind != TokenKind.minus) {
            return false;
        }

        auto start = current_.offset;
        auto end = start;
        while (end < source_.length && !isCommandWhitespace(source_[end])) {
            ++end;
        }

        auto word = source_[start .. end];
        if (word.length < 2 || word[0] != '-') {
            return false;
        }

        foreach (flag; word[1 .. $]) {
            if (flag != 'e' && flag != 'n') {
                return false;
            }
        }

        foreach (flag; word[1 .. $]) {
            if (flag == 'e') {
                interpretEscapes = true;
            } else {
                noNewline = true;
            }
        }
        consumeRawWord(word);
        return true;
    }

    private string[] readCommandWord(Memory mem) {
        if (current_.kind == TokenKind.at) {
            return parseArraySplice(mem);
        }

        auto end = current_.offset;
        string result;
        bool consumed;
        while (current_.offset == end && isCommandWordToken(current_.kind)) {
            if (current_.kind == TokenKind.charValue) {
                result ~= current_.text;
                end = characterEscapeEnd(current_.offset);
                consumed = true;
                advance();
            } else if (current_.kind == TokenKind.stringValue) {
                result ~= current_.text;
                end = quotedTokenEnd(current_.offset, '\'');
                consumed = true;
                advance();
            } else if (current_.kind == TokenKind.doubleQuoted) {
                result ~= evaluateDoubleQuoted(current_.text, mem);
                end = quotedTokenEnd(current_.offset, '"');
                consumed = true;
                advance();
            } else if (current_.kind == TokenKind.dollar) {
                size_t substitutionEnd;
                result ~= parseScalarSubstitution(mem, substitutionEnd);
                end = substitutionEnd;
                consumed = true;
            } else {
                end += literalTokenLength(current_);
                result ~= source_[current_.offset .. end];
                consumed = true;
                advance();
            }
        }
        if (!consumed) {
            throw new YshError("command argument is not a translated word form");
        }
        return [result];
    }

    private size_t characterEscapeEnd(size_t start) const {
        if (start + 1 >= source_.length || source_[start] != '\\') {
            throw new YshError("invalid character escape span");
        }

        auto escape = source_[start + 1];
        if (escape == 'y') {
            return start + 4;
        }
        if (escape == 'u' && start + 2 < source_.length &&
                source_[start + 2] == '{') {
            auto position = start + 3;
            while (position < source_.length && source_[position] != '}') {
                ++position;
            }
            if (position >= source_.length) {
                throw new YshError("unterminated \\u{...} escape");
            }
            return position + 1;
        }
        return start + 2;
    }

    private size_t quotedTokenEnd(size_t start, char quote) const {
        auto position = start;
        bool backslashEscapes = quote == '"';

        // J8-style r'', u'', and b'' tokens include their one-byte prefix in
        // Token.offset. Triple-quoted forms use the complete ''' delimiter.
        if (position < source_.length && source_[position] != quote) {
            backslashEscapes = source_[position] != 'r';
            if (quote == '\'' && position + 3 < source_.length &&
                    source_[position + 1 .. position + 4] == "'''") {
                position += 4;
                while (position + 2 < source_.length) {
                    if (source_[position .. position + 3] == "'''") {
                        return position + 3;
                    }
                    ++position;
                }
                throw new YshError("unterminated triple-quoted command word");
            }
            ++position;
        }
        ++position; // opening quote

        while (position < source_.length) {
            if (backslashEscapes && source_[position] == '\\') {
                position += 2;
                continue;
            }
            if (source_[position] == quote) {
                return position + 1;
            }
            ++position;
        }
        throw new YshError("unterminated quoted command word");
    }

    private static size_t substitutionClose(string content,
            size_t openOffset, char open, char close) {
        int depth = 1;
        auto position = openOffset + 1;
        while (position < content.length) {
            auto ch = content[position];
            if (ch == '\\') {
                position += position + 1 < content.length ? 2 : 1;
                continue;
            }
            if (ch == '\'' || ch == '"') {
                auto quote = ch;
                ++position;
                while (position < content.length) {
                    if (content[position] == '\\') {
                        position += position + 1 < content.length ? 2 : 1;
                        continue;
                    }
                    if (content[position] == quote) {
                        ++position;
                        break;
                    }
                    ++position;
                }
                continue;
            }
            if (ch == open) {
                ++depth;
            } else if (ch == close) {
                --depth;
                if (depth == 0) {
                    return position;
                }
            }
            ++position;
        }
        throw new YshError("unterminated substitution in double-quoted word");
    }

    private string evaluateDoubleQuoted(string content, Memory mem) {
        string result;
        size_t position;
        while (position < content.length) {
            auto ch = content[position];
            if (ch == '\\' && position + 1 < content.length) {
                auto next = content[position + 1];
                if (next == '$' || next == '`' || next == '"' || next == '\\') {
                    result ~= next;
                    position += 2;
                    continue;
                }
                result ~= ch;
                ++position;
                continue;
            }

            if (ch == '$' && position + 1 < content.length &&
                    content[position + 1] == '[') {
                auto close = substitutionClose(content, position + 1, '[', ']');
                auto expression = content[position + 2 .. close];
                result ~= stringify(evaluate(expression, mem));
                position = close + 1;
                continue;
            }

            if (ch == '$' && position + 1 < content.length &&
                    content[position + 1] == '(') {
                auto close = substitutionClose(content, position + 1, '(', ')');
                auto command = content[position + 2 .. close];
                auto output = captureCommandOutput(command, mem);
                while (output.length != 0 &&
                        (output[$ - 1] == '\n' || output[$ - 1] == '\r')) {
                    output = output[0 .. $ - 1];
                }
                result ~= output;
                position = close + 1;
                continue;
            }

            if (ch == '$' && position + 1 < content.length &&
                    content[position + 1] == '?') {
                result ~= to!string(mem.lastStatus);
                position += 2;
                continue;
            }

            if (ch == '$' && position + 1 < content.length &&
                    asciiIdentifierStart(content[position + 1])) {
                auto nameStart = position + 1;
                auto nameEnd = nameStart + 1;
                while (nameEnd < content.length &&
                        asciiIdentifierContinue(content[nameEnd])) {
                    ++nameEnd;
                }
                result ~= stringify(mem.get(content[nameStart .. nameEnd]));
                position = nameEnd;
                continue;
            }

            result ~= ch;
            ++position;
        }
        return result;
    }

    private static bool asciiIdentifierStart(char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
    }

    private static bool asciiIdentifierContinue(char c) {
        return asciiIdentifierStart(c) || (c >= '0' && c <= '9');
    }

    private static bool isCommandWordToken(TokenKind kind) {
        return isLiteralWordToken(kind) || kind == TokenKind.equal ||
            kind == TokenKind.stringValue || kind == TokenKind.doubleQuoted ||
            kind == TokenKind.charValue || kind == TokenKind.dollar ||
            kind == TokenKind.question;
    }

    private string[] parseArraySplice(Memory mem) {
        auto atOffset = current_.offset;
        advance();
        if (current_.offset != atOffset + 1) {
            throw new YshError("@ splice expression must follow '@' without whitespace");
        }
        if (current_.kind == TokenKind.leftParen) {
            size_t commandEnd;
            auto command = collectParenthesizedCommand("@ command substitution",
                commandEnd);
            return splitCommandOutput(captureCommandOutput(command, mem));
        }
        if (current_.kind == TokenKind.leftBracket) {
            auto expression = collectBracketedExpression("@ splice");
            return spliceArray(evaluate(expression, mem));
        }
        if (current_.kind != TokenKind.name) {
            throw new YshError("@ splice expects a variable name or [expression]");
        }
        auto value = mem.get(current_.text);
        advance();
        return spliceArray(value);
    }

    private string parseScalarSubstitution(Memory mem, ref size_t endOffset) {
        auto dollarOffset = current_.offset;
        advance();
        if (current_.offset != dollarOffset + 1) {
            throw new YshError("$ substitution must follow '$' without whitespace");
        }
        if (current_.kind == TokenKind.leftParen) {
            auto command = collectParenthesizedCommand("$ command substitution",
                endOffset);
            auto output = captureCommandOutput(command, mem);
            while (output.length != 0 &&
                    (output[$ - 1] == '\n' || output[$ - 1] == '\r')) {
                output = output[0 .. $ - 1];
            }
            return output;
        }
        if (current_.kind == TokenKind.leftBracket) {
            auto expression = collectBracketedExpression("$ expression", endOffset);
            return stringify(evaluate(expression, mem));
        }
        if (current_.kind == TokenKind.question) {
            endOffset = current_.offset + 1;
            advance();
            return to!string(mem.lastStatus);
        }
        if (current_.kind != TokenKind.name) {
            throw new YshError("$ substitution expects a variable name or [expression]");
        }
        auto value = mem.get(current_.text);
        endOffset = current_.offset + current_.text.length;
        advance();
        return stringify(value);
    }

    private string captureCommandOutput(string command, Memory mem) {
        auto capture = File.tmpfile();
        auto previous = mem.outputFile;
        mem.outputFile = capture;
        scope (exit) mem.outputFile = previous;

        executeProgram(command, mem);
        capture.flush();
        capture.rewind();

        string output;
        while (true) {
            auto line = capture.readln();
            if (line.length == 0) {
                break;
            }
            output ~= line;
        }
        return output;
    }

    private static string[] splitCommandOutput(string output) {
        string[] result;
        foreach (line; output.split("\n")) {
            auto word = strip(line);
            if (word.length != 0) {
                result ~= word;
            }
        }
        return result;
    }

    private string collectParenthesizedCommand(string description,
            ref size_t endOffset) {
        require(TokenKind.leftParen, "(");
        auto start = current_.offset;
        int depth;

        while (current_.kind != TokenKind.eof) {
            if (depth == 0 && current_.kind == TokenKind.rightParen) {
                auto command = source_[start .. current_.offset];
                endOffset = current_.offset + 1;
                advance();
                return command;
            }
            adjustDepth(depth, current_.kind);
            advance();
        }
        throw new YshError("unterminated " ~ description);
    }

    private string collectBracketedExpression(string description) {
        size_t ignored;
        return collectBracketedExpression(description, ignored);
    }

    private string collectBracketedExpression(string description, ref size_t endOffset) {
        require(TokenKind.leftBracket, "[");
        auto start = current_.offset;
        int depth;
        while (current_.kind != TokenKind.eof) {
            if (depth == 0 && current_.kind == TokenKind.rightBracket) {
                auto expression = strip(source_[start .. current_.offset]);
                endOffset = current_.offset + current_.text.length;
                advance();
                if (expression.length == 0) {
                    throw new YshError(description ~ " cannot be empty");
                }
                return expression;
            }
            adjustDepth(depth, current_.kind);
            advance();
        }
        throw new YshError("unterminated " ~ description);
    }

    private string readLiteralWord(string errorMessage) {
        if (current_.kind == TokenKind.stringValue) {
            auto value = current_.text;
            advance();
            return value;
        }
        if (current_.kind == TokenKind.doubleQuoted) {
            auto value = current_.text;
            advance();
            return value;
        }

        if (!isLiteralWordToken(current_.kind)) {
            throw new YshError(errorMessage);
        }

        auto start = current_.offset;
        auto end = start;
        while (isLiteralWordToken(current_.kind) && current_.offset == end) {
            end += literalTokenLength(current_);
            advance();
        }
        return source_[start .. end];
    }

    private bool atRawWord(string spelling) const {
        if (current_.offset + spelling.length > source_.length ||
                source_[current_.offset .. current_.offset + spelling.length] != spelling) {
            return false;
        }
        auto end = current_.offset + spelling.length;
        return end == source_.length || isCommandWhitespace(source_[end]);
    }

    private void consumeRawWord(string spelling) {
        auto end = current_.offset + spelling.length;
        while (current_.kind != TokenKind.eof && current_.offset < end) {
            advance();
        }
        if (current_.offset < end) {
            throw new YshError(format("malformed '%s' write option", spelling));
        }
    }

    private static bool isCommandWhitespace(char c) {
        return c == ' ' || c == '\t' || c == '\n' || c == ';';
    }

    private static bool isLiteralWordToken(TokenKind kind) {
        switch (kind) {
        case TokenKind.name:
        case TokenKind.integer:
        case TokenKind.floating:
        case TokenKind.nullKeyword:
        case TokenKind.trueKeyword:
        case TokenKind.falseKeyword:
        case TokenKind.andKeyword:
        case TokenKind.orKeyword:
        case TokenKind.notKeyword:
        case TokenKind.inKeyword:
        case TokenKind.ifKeyword:
        case TokenKind.elifKeyword:
        case TokenKind.elseKeyword:
        case TokenKind.varKeyword:
        case TokenKind.constKeyword:
        case TokenKind.setvarKeyword:
        case TokenKind.setglobalKeyword:
        case TokenKind.funcKeyword:
        case TokenKind.procKeyword:
        case TokenKind.returnKeyword:
        case TokenKind.whileKeyword:
        case TokenKind.forKeyword:
        case TokenKind.breakKeyword:
        case TokenKind.continueKeyword:
        case TokenKind.minus:
        case TokenKind.plus:
        case TokenKind.dot:
        case TokenKind.colon:
        case TokenKind.slash:
            return true;
        default:
            return false;
        }
    }

    private static size_t literalTokenLength(Token token) {
        switch (token.kind) {
        case TokenKind.minus:
        case TokenKind.plus:
        case TokenKind.dot:
        case TokenKind.colon:
        case TokenKind.slash:
        case TokenKind.equal:
        case TokenKind.question:
            return 1;
        default:
            return token.text.length;
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

        size_t levels = 1;
        if (current_.kind == TokenKind.integer) {
            levels = 0;
            foreach (digit; current_.text) {
                if (digit == '_') {
                    continue;
                }
                auto value = cast(size_t)(digit - '0');
                if (levels > (size_t.max - value) / 10) {
                    throw new YshError("break/continue level is too large");
                }
                levels = levels * 10 + value;
            }
            if (levels == 0) {
                throw new YshError("break/continue level must be at least 1");
            }
            advance();
        }

        if (!isEndStatement(current_.kind)) {
            throw new YshError("break and continue accept at most one integer argument");
        }
        throw new LoopControl(shouldBreak, levels);
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
        "var called = 0\n" ~
        "func store(value) { setvar called = value; return (null) }\n" ~
        "call store(7)\n",
        mem);
    assert(repr(mem.get("called")) == "7");

    executeProgram(
        "func rest_pick(first, ...rest) { return (rest[1]) }\n" ~
        "var rest_answer = rest_pick(0, 10, 20)\n" ~
        "var positional_values = [1, 2, 3]\n" ~
        "func second(...args) { return (args[1]) }\n" ~
        "var spread_answer = second(...positional_values)\n" ~
        "func named_add(; x = 3, y = 4) { return (x + y) }\n" ~
        "var named_answer = named_add(y = 10)\n" ~
        "func named_rest(; ...other) { return (other.z) }\n" ~
        "var named_values = {z: 9}\n" ~
        "var named_spread_answer = named_rest(; ...named_values)\n",
        mem);
    assert(repr(mem.get("rest_answer")) == "20");
    assert(repr(mem.get("spread_answer")) == "2");
    assert(repr(mem.get("named_answer")) == "13");
    assert(repr(mem.get("named_spread_answer")) == "9");

    executeProgram(
        "var proc_value = ''\n" ~
        "proc capture(first, ...rest) {\n" ~
        "  setvar proc_value = first ++ ':' ++ rest[1]\n" ~
        "}\n" ~
        "capture alpha beta gamma\n" ~
        "var open_proc_value = ''\n" ~
        "proc open_capture { setvar open_proc_value = ARGV[1] }\n" ~
        "open_capture red green blue\n",
        mem);
    assert(repr(mem.get("proc_value")) == "\"alpha:gamma\"");
    assert(repr(mem.get("open_proc_value")) == "\"green\"");

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
        "var elif_value = 0\n" ~
        "if (false) { setvar elif_value = 1 } " ~
        "elif (true) { setvar elif_value = 2 } " ~
        "else { setvar elif_value = 3 }\n",
        mem);
    assert(repr(mem.get("elif_value")) == "2");

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
        "var break_visits = 0\n" ~
        "for i in (0 ..< 3) {\n" ~
        "  for j in (0 ..< 3) {\n" ~
        "    setvar break_visits = break_visits + 1\n" ~
        "    if (j === 1) { break 2 }\n" ~
        "  }\n" ~
        "  setvar break_visits = break_visits + 100\n" ~
        "}\n" ~
        "var continue_visits = 0\n" ~
        "for i in (0 ..< 3) {\n" ~
        "  for j in (0 ..< 3) {\n" ~
        "    if (j === 1) { continue 2 }\n" ~
        "    setvar continue_visits = continue_visits + 1\n" ~
        "  }\n" ~
        "  setvar continue_visits = continue_visits + 100\n" ~
        "}\n",
        mem);
    assert(repr(mem.get("break_visits")) == "2");
    assert(repr(mem.get("continue_visits")) == "3");

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

    executeProgram(
        "var word_index_total = 0\n" ~
        "var final_word = ''\n" ~
        "for index, word in red green blue {\n" ~
        "  setvar word_index_total = word_index_total + index\n" ~
        "  setvar final_word = word\n" ~
        "}\n",
        mem);
    assert(repr(mem.get("word_index_total")) == "3");
    assert(repr(mem.get("final_word")) == "\"blue\"");

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
