module yshd.program;

import std.algorithm : sort, endsWith;
import std.conv : to;
import std.file : FileException, chdir, read;
import std.exception : ErrnoException;
import std.format : format;
import std.stdio : File;
import std.string : indexOf, join, split, strip, startsWith;

import yshd.command : Mutation, VarDecl, executeMutation, executeVarDecl;
import yshd.command_lookup : BuiltinKind, builtinKind, hasProcedure,
    resolveCommand, executablePaths, printResolution;
import yshd.arith : ShellArithmetic, shellArithmeticEnd, parseShellArithmetic,
    parseShellArithmeticFor, parseShellArithmeticSlice, evaluateShellArithmetic, evaluateShellIndex;
import yshd.expr : AssignmentScope, ParseError, evaluate, validateExpression,
    validateAssignmentTarget, parseTypedArguments, expressionAtomEnd, ParsedArguments;
import yshd.func_proc : FunctionParameter, FunctionReturn, ProcReturn, YshFunction, YshProc, ProcSignature;
import yshd.io_ysh : WriteEncoding, encodeDataValue, renderEcho,
    renderWrite, spliceArray, DataEncodeError, dataOptions;
import yshd.pretty : prettyValue, prettyCell, asdlValue, terminalWidth;
import yshd.lexer : Lexer, Token, TokenKind, HereDocument;
import yshd.process : runExternal, runPipeline, runSourcePipeline, runSourceJob, captureSourceOutput;
import yshd.state : Memory, ReturnMode, Frame;
import yshd.options : ShellOptions;
import yshd.trace : TraceScope;
import yshd.var_check : VariableChecker, DefinitionKind;
import yshd.eval_scope : EvalOptions, withEvalBindings;
import yshd.dirs : setDirectory, popDirectory, physicalDirectory, runDirectoryBuiltin;
import yshd.pattern : ScalarWord, matchesShellPattern;
import yshd.eggex : Eggex, parseEggex, EreError;
import yshd.value : Value, ValueKind, YshDict, UsageError, FatalRuntimeError,
    StructuredError, YshError, YshTypeError, kindName, stringify, toBool, exactlyEqual;

private class IfCommand {
    bool legacySyntax;
    string conditionSource;
    bool expressionCondition;
    string thenSource;
    string elseSource;
    IfCommand elseIf;
    bool hasElse;
}

private struct ShellFunctionDefinition {
    string name;
    string body;
    size_t endOffset;
    HereDocument[] pendingDocuments;
}

private HereDocument[] shiftedDocuments(HereDocument[] documents, size_t offset) {
    auto shifted = documents.dup;
    foreach (ref document; shifted) {
        document.operatorOffset += offset;
        document.wordEnd += offset;
        document.bodyStart += offset;
        document.endOffset += offset;
    }
    return shifted;
}

private struct ForCommand {
    string[] names;
    string[] wordSources;
    string iterableSource;
    string bodySource;
    bool expressionIterable;
    bool implicitArguments;
    bool legacySyntax;
    ShellArithmetic arithmeticInit, arithmeticCondition, arithmeticStep;
}

private struct WhileCommand {
    string conditionSource;
    string bodySource;
    bool expressionCondition;
    bool negated;
}

private bool completeCommandWord(string source, Token token) {
    auto end = token.offset + token.text.length;
    return end == source.length || " \t\r\n;|&()<>{}".indexOf(source[end]) >= 0;
}

class YshCommand {
    string source;
    Frame captured;
    Frame moduleFrame;
    bool attributeScope;
    bool multiline;
    this(string source, Memory mem, bool attributeScope = false, bool multiline = false) {
        this.source = source;
        this.attributeScope = attributeScope;
        this.multiline = multiline;
        captured = mem.currentFrame;
        moduleFrame = mem.globalFrame;
    }
    int eval(Memory mem) {
        evalValue(mem);
        return mem.lastStatus;
    }
    Value evalValue(Memory mem, EvalOptions options = EvalOptions.init) {
        auto previousGlobal = mem.setActiveGlobalFrame(moduleFrame);
        Frame frame;
        if (options.inCapturedFrame) { frame = captured; mem.pushFrame(frame); }
        else frame = mem.pushEnclosed(captured);
        scope (exit) { mem.popFrame(); mem.setActiveGlobalFrame(previousGlobal); }
        withEvalBindings(mem, options, () { evalInCurrentFrame(mem); return Value.nullValue(); });
        if (!options.toDict) return Value.nullValue();
        auto dictionary = new YshDict();
        foreach (name, cell; frame.cells) if (!name.endsWith("_")) dictionary.set(name, cell.value);
        return Value.dictRef(dictionary);
    }
    int evalInCurrentFrame(Memory mem) {
        executeProgram(source, mem, attributeScope, multiline);
        return mem.lastStatus;
    }
}

private enum ConditionKind { word, unary, binary, negate, conjunction, disjunction }

/// Retained shell conditions are command ASTs. Their words stay unevaluated
/// until the selected logical operand runs, including substitutions.
private class ShellCondition {
    ConditionKind kind;
    string operation;
    string firstWord;
    string secondWord;
    ShellCondition first;
    ShellCondition second;
    this(ConditionKind kind) { this.kind = kind; }

    bool eval(Memory mem) {
        final switch (kind) {
        case ConditionKind.negate: return !first.eval(mem);
        case ConditionKind.conjunction: return first.eval(mem) && second.eval(mem);
        case ConditionKind.disjunction: return first.eval(mem) || second.eval(mem);
        case ConditionKind.word: return conditionWord(firstWord, mem).text().length != 0;
        case ConditionKind.unary:
            auto value = conditionWord(firstWord, mem).text();
            if (operation == "-n") return value.length != 0;
            if (operation == "-z") return value.length == 0;
            if (operation == "-v") return mem.getCell(value) !is null || mem.get("ENV").dictValue.contains(value);
            if (operation == "-o") return mem.options.get(value);
            if (operation == "-t") {
                import core.sys.posix.unistd : isatty;
                try { return isatty(to!int(value)) != 0; } catch (Exception error) { return false; }
            }
            import std.file : exists, isFile, isDir, isSymlink, getSize;
            import core.sys.posix.unistd : access, R_OK, W_OK, X_OK;
            try {
                switch (operation) {
                case "-e": case "-a": return exists(value);
                case "-f": return isFile(value);
                case "-d": return isDir(value);
                case "-L": case "-h": return isSymlink(value);
                case "-s": return getSize(value) != 0;
                case "-r": case "-w": case "-x":
                    import std.string : toStringz;
                    return access(value.toStringz(), operation == "-r" ? R_OK : operation == "-w" ? W_OK : X_OK) == 0;
                default: throw new UsageError("Untranslated file condition " ~ operation);
                }
            } catch (FileException error) { return false; }
        case ConditionKind.binary:
            auto left = conditionWord(firstWord, mem).text();
            auto right = conditionWord(secondWord, mem, operation == "=~");
            if (operation == "=~") {
                import yshd.eggex : searchEre;
                mem.regexMatch = searchEre(right.erePattern(), 0, left);
                return mem.regexMatch !is null;
            }
            if (operation == "=" || operation == "==" || operation == "!=")
                return matchesShellPattern(right, left, mem.options.get("nocasematch")) == (operation != "!=");
            auto text = right.text();
            if (operation == "<") return left < text;
            if (operation == ">") return left > text;
            auto a = evaluateShellArithmetic(left, mem);
            auto b = evaluateShellArithmetic(text, mem);
            switch (operation) {
            case "-eq": return a == b;
            case "-ne": return a != b;
            case "-lt": return a < b;
            case "-le": return a <= b;
            case "-gt": return a > b;
            case "-ge": return a >= b;
            default: throw new UsageError("Untranslated shell condition " ~ operation);
            }
        }
    }
}

private ScalarWord conditionWord(string source, Memory mem, bool regex = false) {
    auto parser = new ProgramParser(source, false, ReturnMode.shell, true, mem.options);
    auto result = parser.readScalarWord(mem, true, regex);
    if (parser.current_.kind != TokenKind.eof) throw new ParseError("Unexpected conditional word input");
    return result;
}

private enum CasePatternKind { words, expressions, eggex, otherwise }
private enum CaseTerminator { stop, fallThrough, retest }
private struct CaseArm {
    CasePatternKind kind;
    string[] patterns;
    Eggex regex;
    string body;
    CaseTerminator terminator;
}

/// Operator discovery treats a parsed case as one compound command. Its
/// pattern parentheses, pipes and bracket expressions are not shell grouping
/// or pipeline operators. Reuse the structural parser rather than balancing
/// case syntax with a second, approximate grammar.
private class CommandScanner {
    private string source;
    private Lexer lexer;
    private ReturnMode returnMode;
    private bool commandStart = true;
    private bool bracketCommand;
    private bool continuation;
    private ShellOptions options;
    private bool multiline;
    this(string source, ReturnMode returnMode, ShellOptions options = null, bool multiline = false) {
        this.source = source;
        this.returnMode = returnMode;
        this.options = options;
        this.multiline = multiline;
        lexer = new Lexer(source, true, 0, true, options);
        lexer.multiline = multiline;
    }
    HereDocument[size_t] documents() { return lexer.hereDocuments; }
    Token next() {
        Token token;
        do { token = lexer.next(); }
        while (continuation && token.kind == TokenKind.newline);
        continuation = token.kind == TokenKind.pipe || token.kind == TokenKind.andIf || token.kind == TokenKind.orIf;
        if (commandStart) bracketCommand = token.kind == TokenKind.name && token.text == "test" ||
            token.kind == TokenKind.leftBracket && !(token.offset + 1 < source.length && source[token.offset + 1] == '[');
        // In test/[ argv, square brackets are ordinary word bytes rather
        // than command-language grouping. Runtime arity checks own the ].
        if (token.wordBracket || (bracketCommand && (token.kind == TokenKind.leftBracket || token.kind == TokenKind.rightBracket))) {
            commandStart = false;
            return Token(TokenKind.name, token.text, token.offset);
        }
        if (token.kind == TokenKind.dollar && token.offset + 2 < source.length &&
                source[token.offset + 1 .. token.offset + 3] == "((") {
            if (options !is null && options.get("no_parse_sh_arith"))
                throw new ParseError("Shell arithmetic substitutions are disabled (no_parse_sh_arith)");
            auto end = shellArithmeticEnd(source, token.offset + 1);
            parseShellArithmetic(source[token.offset + 3 .. end - 2], options);
            lexer = new Lexer(source, true, end, true, options);
            lexer.multiline = multiline;
            commandStart = false;
            return Token(TokenKind.name, source[token.offset .. end], token.offset);
        }
        // Shell arithmetic is one command. Its operators must not be exposed
        // to the enclosing pipeline/and-or scanner.
        if (commandStart && token.kind == TokenKind.leftParen &&
                token.offset + 1 < source.length && source[token.offset + 1] == '(') {
            auto parser = new ProgramParser(source[token.offset .. $], true, returnMode, false, options, null, false, multiline);
            parser.parseSubshell(null);
            auto end = token.offset + parser.current_.offset;
            lexer = new Lexer(source, true, end, true, options);
            lexer.multiline = multiline;
            commandStart = false;
            return Token(TokenKind.name, source[token.offset .. end], token.offset);
        }
        if (commandStart && token.kind == TokenKind.name) {
            auto parser = new ProgramParser(source[token.offset .. $], true, returnMode, false, options, null, false, multiline);
            ShellFunctionDefinition definition;
            if (parser.scanShellFunction(definition)) {
                auto end = token.offset + definition.endOffset;
                lexer = new Lexer(source, true, end, true, options,
                    shiftedDocuments(definition.pendingDocuments, token.offset));
                lexer.multiline = multiline;
                commandStart = false;
                return Token(TokenKind.name, source[token.offset .. end], token.offset);
            }
        }
        if (commandStart && (token.kind == TokenKind.forKeyword || token.kind == TokenKind.whileKeyword ||
                (token.kind == TokenKind.name && token.text == "until" && completeCommandWord(source, token)))) {
            auto parser = new ProgramParser(source[token.offset .. $], true, returnMode, false, options, null, false, multiline);
            if (token.kind == TokenKind.forKeyword) parser.parseForCommand();
            else parser.parseWhileCommand();
            auto end = token.offset + parser.lastCompoundEnd_;
            lexer = new Lexer(source, true, end, true, options);
            lexer.multiline = multiline;
            commandStart = false;
            return Token(TokenKind.name, source[token.offset .. end], token.offset);
        }
        if (commandStart && token.kind == TokenKind.ifKeyword) {
            auto parser = new ProgramParser(source[token.offset .. $], true, returnMode, false, options, null, false, multiline);
            parser.parseIfCommand();
            auto end = token.offset + parser.lastCompoundEnd_;
            lexer = new Lexer(source, true, end, true, options);
            lexer.multiline = multiline;
            commandStart = false;
            return Token(TokenKind.name, source[token.offset .. end], token.offset);
        }
        if (commandStart && token.kind == TokenKind.leftBracket && lexer.peek().kind == TokenKind.leftBracket &&
                lexer.peek().offset == token.offset + 1) {
            auto parser = new ProgramParser(source[token.offset .. $], true, returnMode, false, options, null, false, multiline);
            parser.parseDoubleBracket(null);
            auto end = token.offset + parser.current_.offset;
            lexer = new Lexer(source, true, end, true, options);
            lexer.multiline = multiline;
            commandStart = false;
            return Token(TokenKind.name, source[token.offset .. end], token.offset);
        }
        if (commandStart && token.kind == TokenKind.caseKeyword) {
            auto parser = new ProgramParser(source[token.offset .. $], true, returnMode, false, options, null, false, multiline);
            parser.parseCase(null);
            auto end = token.offset + parser.current_.offset;
            lexer = new Lexer(source, true, end, true, options);
            lexer.multiline = multiline;
            commandStart = false;
            return Token(TokenKind.caseKeyword, source[token.offset .. end], token.offset);
        }
        commandStart = token.kind == TokenKind.newline || token.kind == TokenKind.semicolon ||
            token.kind == TokenKind.leftBrace || token.kind == TokenKind.pipe ||
            token.kind == TokenKind.andIf || token.kind == TokenKind.orIf ||
            (!bracketCommand && token.kind == TokenKind.bang);
        return token;
    }
}

class ShellExit : Exception {
    int status;

    this(int status) {
        super("YSH exit");
        this.status = status;
    }
}

/// Automatic failure propagation is catchable by try. An explicit exit still
/// terminates the shell even inside try, as in the reference error model.
class Errexit : ShellExit {
    string diagnostic;
    this(int status, string diagnostic = "") { super(status); this.diagnostic = diagnostic; }
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
    private size_t parsedCommands_;
    private bool parsedSimple_;
    private size_t simpleOffset_;

    // trap -p prints source only for command.Simple in the reference. Other
    // command variants retain its explicit '<unknown>' display marker.
    string commandSourceCode() {
        if (parsedCommands_ != 1 || !parsedSimple_) return "<unknown>";
        auto begin = simpleOffset_;
        while (begin && source_[begin - 1] != '\n') --begin;
        auto end = simpleOffset_;
        while (end < source_.length && source_[end] != '\n') ++end;
        if (end < source_.length) ++end;
        return source_[begin .. end];
    }
    private bool allowProcessReplacement_;
    private bool redirectStatusChecked_;
    private string source_;
    private Lexer lexer_;
    private Token current_;
    private Memory activeMemory_;
    private string[string] visibleAliases_;
    private bool syntaxOnly_;
    private ReturnMode returnMode_;
    private bool executedCommand_;
    private ShellOptions parserOptions_;
    private bool lastWordTriple_;
    private bool lastWordStatic_;
    private bool attributeScope_;
    private bool multiline_;
    private size_t lastBlockEnd_;
    private size_t lastCompoundEnd_;
    private VariableChecker variableChecker_;

    this(string source, bool syntaxOnly = false, ReturnMode returnMode = ReturnMode.shell, bool wordsOnly = false,
            ShellOptions options = null, VariableChecker variableChecker = null, bool attributeScope = false, bool multiline = false) {
        source_ = source;
        returnMode_ = returnMode;
        syntaxOnly_ = syntaxOnly;
        attributeScope_ = attributeScope;
        multiline_ = multiline;
        parserOptions_ = options;
        variableChecker_ = variableChecker is null ? new VariableChecker() : variableChecker;
        lexer_ = new Lexer(source, true, 0, !wordsOnly, options);
        lexer_.multiline = multiline_;
        current_ = lexer_.next();
    }

    /// Syntax checking shares the structural and word parsers with execution,
    /// but has no Memory, streams, variable lookup or evaluator invocation.
    /// Builtin arguments are words: their runtime arity/option checks do not
    /// run under -n. Bodies and substitutions are checked unconditionally.
    void parse() {
        assert(syntaxOnly_);
        skipEndStatements();
        while (current_.kind != TokenKind.eof) {
            ++parsedCommands_;
            parsedSimple_ = false;
            simpleOffset_ = current_.offset;
            if (tryMultiline(null) || tryExecuteAsync(null) || tryExecuteAndOr(null) || tryExecuteTopLevelPipeline(null)) {
                skipEndStatements();
                continue;
            }
            if (tryParseShellFunction(null) || tryExecuteTopLevelRedirect(null)) {
                skipEndStatements();
                continue;
            }
            if (tryBareDeclaration(null) || tryRetainedAssignment(null)) { skipEndStatements(); continue; }
            switch (current_.kind) {
            case TokenKind.leftBrace: parseProgram(collectBlock()); break;
            case TokenKind.leftParen: parseSubshell(null); break;
            case TokenKind.leftBracket: parseDoubleBracket(null); break;
            case TokenKind.varKeyword: parseDeclaration(null, false); break;
            case TokenKind.constKeyword: parseDeclaration(null, true); break;
            case TokenKind.setvarKeyword: parseMutation(null, AssignmentScope.local); break;
            case TokenKind.setglobalKeyword: parseMutation(null, AssignmentScope.global); break;
            case TokenKind.funcKeyword: parseFunction(null); break;
            case TokenKind.procKeyword: parseProc(null); break;
            case TokenKind.ifKeyword: parseIf(null); break;
            case TokenKind.whileKeyword: parseWhile(null); break;
            case TokenKind.forKeyword: parseFor(null); break;
            case TokenKind.caseKeyword: parseCase(null); break;
            case TokenKind.equal:
                advance();
                validateExpression(collectRhs());
                break;
            case TokenKind.returnKeyword:
                parseReturn(null);
                break;
            case TokenKind.bang:
                advance();
                if (isEndStatement(current_.kind)) throw new YshError("expected command after '!'");
                parseProgram(collectRhs(false));
                break;
            case TokenKind.name:
                if (!completeCommandWord(source_, current_)) { parseCommandWords(); break; }
                if (current_.text == "until") {
                    parseWhile(null);
                } else if (current_.text == "declare" || current_.text == "typeset" || current_.text == "local") {
                    parseShellDeclare(null);
                } else if (current_.text == "typed") {
                    advance();
                    if (current_.kind != TokenKind.procKeyword) throw new ParseError("Expected proc after typed");
                    parseProc(null);
                } else if (current_.text == "try") {
                    advance();
                    parseBlockArgument(collectBlock(), false);
                } else if (current_.text == "call") {
                    advance();
                    validateExpression(collectRhs());
                } else if (current_.text == "assert") {
                    advance();
                    validateExpression(current_.kind == TokenKind.leftBracket
                        ? collectBracketedExpression("assert") : collectRhs());
                } else if (current_.text == "shopt") {
                    parsedSimple_ = true;
                    parseShopt(null);
                } else {
                    parseCommandWords();
                }
                break;
            case TokenKind.trueKeyword:
            case TokenKind.falseKeyword:
            case TokenKind.breakKeyword:
            case TokenKind.continueKeyword:
            case TokenKind.colon:
            case TokenKind.stringValue:
            case TokenKind.doubleQuoted:
            case TokenKind.dollar:
            case TokenKind.slash:
                parseCommandWords();
                break;
            default:
                if (isCommandWordToken(current_.kind)) { parseCommandWords(); break; }
                throw new YshError(format("unexpected command token '%s' at byte %s",
                    current_.text, current_.offset));
            }
            skipEndStatements();
        }
    }

    private void parseCommandWords() {
        parsedSimple_ = current_.kind != TokenKind.breakKeyword && current_.kind != TokenKind.continueKeyword &&
            !(current_.kind == TokenKind.name && current_.text == "exit" && completeCommandWord(source_, current_));
        bool hasTyped;
        bool firstWord = true;
        bool attributeBlock;
        while (!isEndStatement(current_.kind)) {
            if (atTypedArguments()) {
                if (hasTyped) throw new ParseError("Unexpected second typed argument list");
                hasTyped = true;
                parseCommandArguments();
            } else if (current_.kind == TokenKind.leftBrace) {
                parseBlockArgument(collectBlock(), attributeBlock);
                if (!isEndStatement(current_.kind)) throw new ParseError("Unexpected words after block argument");
                break;
            } else {
                if (hasTyped) throw new ParseError("Unexpected words after typed arguments");
                auto parts = readCommandWord(null);
                if (firstWord) {
                    attributeBlock = lastWordStatic_ && parts.length == 1 && attributeCommandName(parts[0]);
                    firstWord = false;
                }
            }
        }
    }

    private void parseProgram(string source) {
        .parseProgram(source, returnMode_, parserOptions_, variableChecker_, attributeScope_, multiline_);
    }

    private void parseBlockArgument(string source, bool attributeScope) {
        .parseProgram(source, returnMode_, parserOptions_, variableChecker_, attributeScope, multiline_);
    }

    private void executeProgram(string source, Memory mem) {
        .executeProgram(source, mem, attributeScope_, multiline_);
    }

    private static bool attributeCommandName(string name) {
        if (!name.length || name[0] < 'A' || name[0] > 'Z') return false;
        foreach (character; name) if (character >= 'a' && character <= 'z') return true;
        return false;
    }

    private void validateExpression(string source) { .validateExpression(source, parserOptions_); }
    private auto parseTypedArguments(string source, bool validateNested = false) {
        return .parseTypedArguments(source, validateNested, parserOptions_);
    }

    private bool atTypedArguments() {
        return current_.kind == TokenKind.leftParen ||
            (current_.kind == TokenKind.leftBracket && (parserOptions_ is null || parserOptions_.get("parse_bracket")));
    }

    private auto parseCommandArguments() {
        if (current_.kind == TokenKind.leftParen)
            return parseTypedArguments("(" ~ collectParenthesizedExpression(true) ~ ")", true);
        return parseTypedArguments("[" ~ collectBracketedExpression("lazy argument list", true) ~ "]", true);
    }

    void execute(Memory mem) {
        assert(!syntaxOnly_);
        activeMemory_ = mem;
        allowProcessReplacement_ = mem.canReplaceProcess;
        auto previousReplacement = mem.canReplaceProcess;
        mem.canReplaceProcess = false;
        scope (exit) mem.canReplaceProcess = previousReplacement;
        // Command aliases expand while parsing, not while invoking arbitrary
        // argument words. Definitions following a semicolon become visible
        // only on the next source line, as in the inherited alias tests.
        visibleAliases_ = mem.aliases.dup;
        skipEndStatements();

        while (current_.kind != TokenKind.eof) {
            mem.traps.runPending(mem);
            mem.setSourcePosition(source_, current_.offset);
            if (mem.options.get("noexec")) {
                parseProgram(source_[current_.offset .. $]);
                return;
            }
            executedCommand_ = true;
            if (tryMultiline(mem)) { skipEndStatements(); continue; }
            if (tryExecuteAsync(mem)) { skipEndStatements(); continue; }
            if (tryExecuteAndOr(mem)) {
                // Each eligible command owns its errexit decision. A failed
                // nonfinal operand and a negated final operand stay exempt.
                skipEndStatements();
                continue;
            }
            if (tryExecuteTopLevelPipeline(mem)) {
                checkErrexit(mem);
                skipEndStatements();
                continue;
            }
            if (tryParseShellFunction(mem)) { skipEndStatements(); continue; }
            if (tryExecuteTopLevelRedirect(mem)) {
                if (!redirectStatusChecked_) checkErrexit(mem);
                skipEndStatements();
                continue;
            }
            if (tryExpandCommandAlias(mem)) {
                skipEndStatements();
                continue;
            }
            bool leafStatus = current_.kind != TokenKind.leftBrace && current_.kind != TokenKind.ifKeyword &&
                current_.kind != TokenKind.forKeyword && current_.kind != TokenKind.whileKeyword &&
                current_.kind != TokenKind.caseKeyword && current_.kind != TokenKind.funcKeyword && current_.kind != TokenKind.procKeyword &&
                !(current_.kind == TokenKind.name && current_.text == "until");
            if (leafStatus) mem.traps.runDebug(mem);
            if (tryBareDeclaration(mem) || tryRetainedAssignment(mem)) { checkErrexit(mem); skipEndStatements(); continue; }

            switch (current_.kind) {
            case TokenKind.leftParen:
                parseSubshell(mem);
                break;
            case TokenKind.leftBrace:
                auto body = collectBlock();
                parseProgram(body);
                executeProgram(body, mem);
                break;
            case TokenKind.leftBracket: parseDoubleBracket(mem); break;
            case TokenKind.varKeyword:
                parseDeclaration(mem, false);
                mem.lastStatus = 0;
                break;
            case TokenKind.constKeyword:
                parseDeclaration(mem, true);
                mem.lastStatus = 0;
                break;
            case TokenKind.setvarKeyword:
                parseMutation(mem, AssignmentScope.local);
                mem.lastStatus = 0;
                break;
            case TokenKind.setglobalKeyword:
                parseMutation(mem, AssignmentScope.global);
                mem.lastStatus = 0;
                break;
            case TokenKind.funcKeyword:
                parseFunction(mem);
                mem.lastStatus = 0;
                break;
            case TokenKind.procKeyword:
                parseProc(mem);
                mem.lastStatus = 0;
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
            case TokenKind.caseKeyword:
                parseCase(mem);
                break;
            case TokenKind.breakKeyword:
                parseLoopControl(mem, true);
                break;
            case TokenKind.continueKeyword:
                parseLoopControl(mem, false);
                break;
            case TokenKind.trueKeyword:
            case TokenKind.falseKeyword:
            case TokenKind.colon:
                parseCommandInvocation(mem);
                break;
            case TokenKind.equal:
                parseExpressionDisplay(mem);
                break;
            case TokenKind.name:
                if (!completeCommandWord(source_, current_)) { parseCommandInvocation(mem); break; }
                if (current_.text == "until") { parseWhile(mem); break; }
                if (current_.text == "declare" || current_.text == "typeset" || current_.text == "local") {
                    parseShellDeclare(mem);
                    break;
                }
                if (current_.text == "typed") {
                    advance();
                    if (current_.kind != TokenKind.procKeyword) throw new ParseError("Expected proc after typed");
                    parseProc(mem);
                    break;
                }
                if (current_.text == "try") {
                    parseTry(mem);
                    break;
                }
                if (current_.text == "error") {
                    parseErrorBuiltin(mem);
                    break;
                }
                if (current_.text == "failed") {
                    advance();
                    if (!isEndStatement(current_.kind)) {
                        consumeStatement();
                        mem.lastStatus = 2;
                    } else {
                        auto code = mem.get("_error").dictValue.find("code");
                        mem.lastStatus = code !is null && code.integerValue != 0 ? 0 : 1;
                    }
                    break;
                }
                if (current_.text == "assert") {
                    parseAssert(mem);
                    break;
                }
                if (current_.text == "json" || current_.text == "json8") {
                    parseJson(mem);
                    break;
                }
                if (current_.text == "pp") {
                    parsePrettyPrint(mem);
                    break;
                }
                if (current_.text == "call") {
                    parseCall(mem);
                    break;
                }
                parseCommandInvocation(mem);
                break;
            case TokenKind.bang:
                parseNegatedCommand(mem);
                // Negation is exempt even when ! true returns nonzero.
                skipEndStatements();
                continue;
            case TokenKind.stringValue:
            case TokenKind.doubleQuoted:
            case TokenKind.dollar:
            case TokenKind.slash:
                parseCommandInvocation(mem);
                break;
            default:
                if (isCommandWordToken(current_.kind)) { parseCommandInvocation(mem); break; }
                throw new YshError(format(
                    "D YSH command parser has not translated command beginning with '%s' at byte %s",
                    current_.text, current_.offset));
            }

            if (leafStatus) {
                checkErrexit(mem);
            }
            skipEndStatements();
        }
    }

    private static void checkErrexit(Memory mem) {
        auto status = mem.lastStatus;
        mem.traps.runErr(mem);
        if (mem.errexit && mem.errexitSuppression == 0 && mem.lastStatus != 0) {
            throw new Errexit(status);
        }
    }

    private void parseSet(Memory mem) {
        advance();
        string[] words;
        while (!isEndStatement(current_.kind)) words ~= readCommandWord(mem);
        runSet(words, mem);
    }

    private void runSet(string[] words, Memory mem) {
        // Unsupported options must fail rather than pretend to be enabled.
        for (size_t index; index < words.length; ++index) {
            auto word = words[index];
            if (word == "--") {
                mem.shellArguments = words[index + 1 .. $].dup;
                mem.lastStatus = 0;
                return;
            }
            if (word.length < 2 || (word[0] != '-' && word[0] != '+')) {
                mem.shellArguments = words[index .. $].dup;
                mem.lastStatus = 0;
                return;
            }
            auto enabled = word[0] == '-';
            foreach (flagIndex, flag; word[1 .. $]) {
                switch (flag) {
                case 'e': mem.errexit = enabled; break;
                case 'u': mem.nounset = enabled; break;
                case 'n': mem.options.setOld("noexec", enabled); break;
                case 'E': mem.options.setOld("errtrace", enabled); break;
                case 'x': mem.options.setOld("xtrace", enabled); break;
                case 'o':
                    if (flagIndex + 2 != word.length || index + 1 >= words.length) {
                        throw new YshError("set -o/+o requires a supported option name");
                    }
                    ++index;
                    switch (words[index]) {
                    case "errexit": mem.errexit = enabled; break;
                    case "nounset": mem.nounset = enabled; break;
                    case "pipefail": mem.pipefail = enabled; break;
                    case "errtrace": mem.options.setOld("errtrace", enabled); break;
                    case "xtrace": mem.options.setOld("xtrace", enabled); break;
                    default: throw new YshError("untranslated set option: " ~ words[index]);
                    }
                    break;
                default: throw new YshError("untranslated set flag: " ~ flag);
                }
            }
        }
        mem.lastStatus = 0;
    }

    private void parseNegatedCommand(Memory mem) {
        advance();
        auto command = collectRhs(false);
        if (command.length == 0) throw new YshError("! requires a command");
        ++mem.errexitSuppression;
        scope (exit) --mem.errexitSuppression;
        executeProgram(command, mem);
        mem.lastStatus = mem.lastStatus == 0 ? 1 : 0;
    }

    /// Expand a command-position, unquoted alias using the same D parser
    /// that executes ordinary source. Do not expand argument words or typed
    /// declaration names. Cycles are bounded by the active alias stack.
    ///
    /// This is a first alias slice. The more general upstream trailing-space
    /// and compound-language alias expansion remains untranslated.
    private bool tryExpandCommandAlias(Memory mem) {
        if (!mem.options.get("expand_aliases")) return false;
        if (current_.kind != TokenKind.name) {
            return false;
        }
        auto wordEnd = current_.offset;
        while (wordEnd < source_.length && " \t\r\n;|&()<>{}".indexOf(source_[wordEnd]) < 0) {
            if ("'\"\\$`".indexOf(source_[wordEnd]) >= 0) return false;
            ++wordEnd;
        }
        auto aliasName = source_[current_.offset .. wordEnd];
        auto value = aliasName in visibleAliases_;
        if (value is null) {
            return false;
        }

        foreach (active; mem.aliasExpansionStack) {
            if (active == aliasName) {
                return false;
            }
        }

        auto statementStart = current_.offset;
        auto scanner = new CommandScanner(source_[statementStart .. $], returnMode_, parserOptions_, multiline_);
        size_t statementEnd = source_.length;
        int depth;
        while (true) {
            auto token = scanner.next();
            if (token.kind == TokenKind.eof) {
                break;
            }
            if (depth == 0 &&
                    (token.kind == TokenKind.newline ||
                     token.kind == TokenKind.semicolon)) {
                statementEnd = statementStart + token.offset;
                break;
            }
            adjustDepth(depth, token);
        }

        // Preserve the original, *unexpanded* argument source. In particular,
        // single quotes and later variable reads must not be evaluated twice.
        auto expandedSource = *value ~
            source_[statementStart + aliasName.length .. statementEnd];
        mem.aliasExpansionStack ~= aliasName;
        scope (exit) {
            mem.aliasExpansionStack.length =
                mem.aliasExpansionStack.length - 1;
        }
        executeProgram(expandedSource, mem);

        while (current_.kind != TokenKind.eof &&
                current_.offset < statementEnd) {
            advance();
        }
        return true;
    }


    /// ParseAndOr enters the reference word parser's ... mode for one command
    /// list. Keep the raw source and pass its lexical mode with deferred bodies.
    private bool tryMultiline(Memory mem) {
        if (current_.kind != TokenKind.ellipsis || !completeCommandWord(source_, current_)) return false;
        auto start = current_.offset + current_.text.length;
        auto scanner = new CommandScanner(source_[start .. $], returnMode_, parserOptions_, true);
        int depth;
        size_t end;
        bool content;
        while (true) {
            auto token = scanner.next();
            if (token.kind == TokenKind.eof || (depth == 0 && token.kind == TokenKind.semicolon)) {
                if (depth) throw new ParseError("Unterminated multiline command");
                end = token.offset;
                break;
            }
            content = true;
            adjustDepth(depth, token);
        }
        if (!content) throw new ParseError("Expected a command after ...");
        auto fragment = source_[start .. start + end];
        .parseProgram(fragment, returnMode_, parserOptions_, variableChecker_, attributeScope_, true);
        if (!syntaxOnly_) .executeProgram(fragment, mem, attributeScope_, true);
        moveTo(start + end);
        return true;
    }

    private bool tryExecuteAndOr(Memory mem) {
        if (!pipelineStatementStart(current_.kind) && current_.kind != TokenKind.bang &&
                current_.kind != TokenKind.ifKeyword) return false;
        auto start = current_.offset;
        auto scanner = new CommandScanner(source_[start .. $], returnMode_, parserOptions_, multiline_);
        Token[] operators;
        int depth;
        size_t end;
        while (true) {
            auto token = scanner.next();
            if (token.kind == TokenKind.eof) {
                if (depth != 0) throw new YshError("unterminated command delimiter");
                end = token.offset;
                break;
            }
            if (depth == 0 && isEndStatement(token.kind)) {
                end = token.offset;
                break;
            }
            if (depth == 0 && (token.kind == TokenKind.andIf || token.kind == TokenKind.orIf))
                operators ~= token;
            adjustDepth(depth, token);
        }
        if (operators.length == 0) return false;
        string[] clauses;
        size_t begin;
        foreach (op; operators) {
            clauses ~= commandFragment(start, begin, op.offset, scanner);
            begin = op.offset + op.text.length;
        }
        clauses ~= commandFragment(start, begin, end, scanner);
        foreach (clause; clauses) {
            if (clause.length == 0) throw new YshError("expected command in &&/|| list");
            parseProgram(clause);
        }
        if (!syntaxOnly_) {
            foreach (index, clause; clauses) {
                if (index > 0) {
                    auto previous = operators[index - 1].kind;
                    if (previous == TokenKind.andIf && mem.lastStatus != 0) continue;
                    if (previous == TokenKind.orIf && mem.lastStatus == 0) continue;
                }
                bool suppress = index + 1 < clauses.length;
                if (suppress) ++mem.errexitSuppression;
                scope (exit) { if (suppress) --mem.errexitSuppression; }
                executeProgram(clause, mem);
            }
        }
        consumeStatement();
        return true;
    }

    private bool tryExecuteAsync(Memory mem) {
        if (!pipelineStatementStart(current_.kind) && current_.kind != TokenKind.bang) return false;
        auto start = current_.offset;
        auto scanner = new CommandScanner(source_[start .. $], returnMode_, parserOptions_, multiline_);
        int depth;
        size_t[] separators;
        bool compoundList = current_.kind == TokenKind.bang;
        while (true) {
            auto token = scanner.next();
            if (token.kind == TokenKind.eof || (depth == 0 &&
                    (token.kind == TokenKind.newline || token.kind == TokenKind.semicolon))) return false;
            if (depth == 0 && token.kind == TokenKind.amp) {
                // In <&n and >&n, ampersand belongs to the redirection, not
                // the command-list grammar. Adjacency is significant.
                if (token.offset && (source_[start + token.offset - 1] == '<' ||
                        source_[start + token.offset - 1] == '>')) continue;
                if (parserOptions_ !is null && parserOptions_.get("no_parse_osh"))
                    throw new ParseError("Use the 'fork' builtin instead of &");
                string[] stages;
                size_t begin;
                if (!compoundList) foreach (offset; separators) {
                    stages ~= commandFragment(start, begin, offset, scanner);
                    begin = offset + 1;
                }
                stages ~= commandFragment(start, begin, token.offset, scanner);
                foreach (stage; stages) {
                    if (!stage.length) throw new ParseError("background job needs a command");
                    parseProgram(stage);
                }
                if (!syntaxOnly_) mem.lastStatus = runSourceJob(stages, mem,
                    (string stage, Memory child) { executeProgram(stage, child); return child.lastStatus; }, true);
                moveTo(start + token.offset + 1);
                return true;
            }
            if (depth == 0 && token.kind == TokenKind.pipe) separators ~= token.offset;
            if (depth == 0 && (token.kind == TokenKind.andIf || token.kind == TokenKind.orIf)) compoundList = true;
            adjustDepth(depth, token);
        }
    }

    private void parseSubshell(Memory mem) {
        if (current_.offset + 1 < source_.length && source_[current_.offset + 1] == '(') {
            if (parserOptions_ !is null && parserOptions_.get("no_parse_dparen"))
                throw new ParseError("Shell arithmetic commands are disabled (no_parse_dparen)");
            auto start = current_.offset;
            auto end = shellArithmeticEnd(source_, start);
            auto arithmetic = parseShellArithmetic(source_[start + 2 .. end - 2], parserOptions_);
            moveTo(end);
            if (!syntaxOnly_) {
                mem.trace.sourceCode(source_[start .. end], mem);
                mem.lastStatus = arithmetic.evaluate(mem) != 0 ? 0 : 1;
            }
            return;
        }
        if (parserOptions_ !is null && parserOptions_.get("no_parse_osh"))
            throw new ParseError("Use the 'forkwait' builtin instead of a subshell");
        size_t end;
        auto body = collectParenthesizedCommand("subshell", end);
        if (!body.strip().length) throw new ParseError("subshell needs a command");
        parseProgram(body);
        if (syntaxOnly_) return;
        mem.lastStatus = runSourceJob([body], mem,
            (string stage, Memory child) { executeProgram(stage, child); return child.lastStatus; }, false);
    }

    private bool pipelineStatementStart(TokenKind kind) const {
        return kind == TokenKind.name || kind == TokenKind.leftParen || kind == TokenKind.leftBracket || kind == TokenKind.leftBrace || kind == TokenKind.ifKeyword ||
            kind == TokenKind.integer || kind == TokenKind.floating || kind == TokenKind.percent || kind == TokenKind.ellipsis ||
            kind == TokenKind.greater || kind == TokenKind.less || kind == TokenKind.shiftRight ||
            kind == TokenKind.shiftLeft || kind == TokenKind.tripleLess ||
            kind == TokenKind.trueKeyword || kind == TokenKind.falseKeyword ||
            kind == TokenKind.colon ||
            kind == TokenKind.stringValue || kind == TokenKind.doubleQuoted ||
            kind == TokenKind.dollar || kind == TokenKind.slash ||
            kind == TokenKind.caseKeyword ||
            kind == TokenKind.whileKeyword ||
            kind == TokenKind.forKeyword;
    }

    private string commandFragment(size_t sourceStart, size_t begin, size_t end, CommandScanner scanner) {
        auto fragment = strip(source_[sourceStart + begin .. sourceStart + end]);
        auto offsets = scanner.documents().keys;
        sort(offsets);
        bool appended;
        foreach (offset; offsets) {
            if (offset < begin || offset >= end) continue;
            auto document = scanner.documents()[offset];
            if (!appended) { fragment ~= '\n'; appended = true; }
            fragment ~= source_[sourceStart + document.bodyStart .. sourceStart + document.endOffset];
        }
        return fragment;
    }

    private bool tryExecuteTopLevelPipeline(Memory mem) {
        if (!pipelineStatementStart(current_.kind)) {
            return false;
        }

        auto statementStart = current_.offset;
        auto scanner = new CommandScanner(source_[statementStart .. $], returnMode_, parserOptions_, multiline_);
        int depth;
        size_t[] separators;
        size_t statementEnd = source_.length - statementStart;

        while (true) {
            auto token = scanner.next();
            if (token.kind == TokenKind.eof) {
                statementEnd = token.offset;
                break;
            }
            if (depth == 0 &&
                    (token.kind == TokenKind.newline ||
                     token.kind == TokenKind.semicolon)) {
                statementEnd = token.offset;
                break;
            }
            if (depth == 0 && token.kind == TokenKind.pipe) {
                separators ~= token.offset;
                continue;
            }
            adjustDepth(depth, token);
        }

        if (separators.length == 0) {
            return false;
        }

        string[] stages;
        size_t begin;
        foreach (separator; separators) {
            auto stage = commandFragment(statementStart, begin, separator, scanner);
            if (stage.length == 0) {
                throw new YshError("pipeline has an empty stage");
            }
            stages ~= stage;
            begin = separator + 1;
        }
        auto last = commandFragment(statementStart, begin, statementEnd, scanner);
        if (last.length == 0) {
            throw new YshError("pipeline has an empty final stage");
        }
        stages ~= last;

        if (syntaxOnly_) {
            foreach (stage; stages) parseProgram(stage);
            consumeStatement();
            return true;
        }

        mem.lastStatus = runSourcePipeline(stages, mem,
            (string stage, Memory stageMemory) {
                executeProgram(stage, stageMemory);
                return stageMemory.lastStatus;
            });

        consumeStatement();
        return true;
    }

    private bool redirectableStatementStart(TokenKind kind) const {
        return kind == TokenKind.name || kind == TokenKind.leftParen || kind == TokenKind.leftBracket || kind == TokenKind.leftBrace ||
            kind == TokenKind.integer || kind == TokenKind.floating || kind == TokenKind.percent || kind == TokenKind.ellipsis ||
            kind == TokenKind.greater || kind == TokenKind.less || kind == TokenKind.shiftRight ||
            kind == TokenKind.shiftLeft || kind == TokenKind.tripleLess ||
            kind == TokenKind.trueKeyword || kind == TokenKind.falseKeyword ||
            kind == TokenKind.colon ||
            kind == TokenKind.stringValue || kind == TokenKind.doubleQuoted ||
            kind == TokenKind.dollar || kind == TokenKind.slash ||
            kind == TokenKind.caseKeyword ||
            kind == TokenKind.ifKeyword ||
            kind == TokenKind.whileKeyword ||
            kind == TokenKind.forKeyword;
    }

    private string decodeRedirectPath(string raw, Memory mem) {
        auto pathParser = new ProgramParser(raw, false, ReturnMode.shell, false, parserOptions_);
        auto parts = pathParser.readCommandWord(mem);
        if (parts.length != 1 || pathParser.current_.kind != TokenKind.eof) {
            throw new YshError("redirect path must expand to exactly one word");
        }
        return parts[0];
    }

    private bool tryExecuteTopLevelRedirect(Memory mem) {
        redirectStatusChecked_ = false;
        if (!redirectableStatementStart(current_.kind)) {
            return false;
        }

        auto statementStart = current_.offset;
        auto scanner = new CommandScanner(source_[statementStart .. $], returnMode_, parserOptions_, multiline_);
        int depth;
        size_t statementEnd = source_.length - statementStart;
        Token[] tokens;
        bool compound = current_.kind == TokenKind.ifKeyword || current_.kind == TokenKind.caseKeyword;
        bool suffixReady = compound;
        while (true) {
            auto token = scanner.next();
            if (token.kind == TokenKind.eof) {
                statementEnd = token.offset;
                break;
            }
            if (depth == 0 &&
                    (token.kind == TokenKind.newline ||
                     token.kind == TokenKind.semicolon)) {
                statementEnd = token.offset;
                break;
            }

            if (depth == 0 && compound &&
                    (token.kind == TokenKind.elseKeyword || token.kind == TokenKind.elifKeyword))
                suffixReady = false;
            if (depth == 0 && (!compound || suffixReady)) tokens ~= token;
            adjustDepth(depth, token);
            if (compound && depth == 0 && token.kind == TokenKind.rightBrace) suffixReady = true;
        }
        struct Redirection {
            int descriptor;
            TokenKind kind;
            bool duplicate;
            string operand;
            bool hereDocument;
            bool expandHereDocument;
            bool omitHereStringNewline;
        }
        Redirection[] redirects;
        string commandSource;
        size_t copiedThrough;
        foreach (index, token; tokens) {
            if (token.offset < copiedThrough) continue;
            auto kind = token.kind;
            if (kind != TokenKind.greater && kind != TokenKind.shiftRight &&
                    kind != TokenKind.less && kind != TokenKind.tripleLess && kind != TokenKind.shiftLeft) continue;
            auto begin = token.offset;
            int descriptor = kind == TokenKind.less || kind == TokenKind.tripleLess || kind == TokenKind.shiftLeft ? 0 : 1;
            if (index > 0 && tokens[index - 1].kind == TokenKind.integer &&
                    tokens[index - 1].offset + tokens[index - 1].text.length == begin) {
                begin = tokens[index - 1].offset;
                descriptor = to!int(tokens[index - 1].text);
            }
            if (!syntaxOnly_ && (descriptor < 0 || descriptor > 2))
                throw new YshError("only descriptors 0, 1 and 2 are translated");
            if (kind == TokenKind.shiftLeft) {
                auto document = token.offset in scanner.documents();
                if (document is null) throw new ParseError("expected here document");
                commandSource ~= source_[statementStart + copiedThrough .. statementStart + begin] ~ " ";
                copiedThrough = document.wordEnd;
                if (syntaxOnly_ && !document.quoted) evaluateDoubleQuoted(document.body, null, true);
                redirects ~= Redirection(descriptor, kind, false, document.body, true, !document.quoted);
                continue;
            }
            auto operandStart = token.offset + token.text.length;
            // Keep the following source available to the command lexer: its
            // lookahead may encounter a later here-document on this header.
            auto operandParser = new ProgramParser(source_[statementStart + operandStart .. $], syntaxOnly_, returnMode_, false, parserOptions_, null, false, multiline_);
            bool duplicate = operandParser.current_.kind == TokenKind.amp;
            if (duplicate) operandParser.advance();
            auto parts = operandParser.readCommandWord(mem);
            if (parts.length != 1) throw new YshError("redirect requires exactly one operand");
            commandSource ~= source_[statementStart + copiedThrough .. statementStart + begin] ~ " ";
            copiedThrough = operandStart + operandParser.current_.offset;
            redirects ~= Redirection(descriptor, kind, duplicate, parts[0], false, false,
                kind == TokenKind.tripleLess && operandParser.lastWordTriple_);
        }
        if (redirects.length == 0) return false;
        commandSource ~= source_[statementStart + copiedThrough .. statementStart + statementEnd];

        if (syntaxOnly_) {
            if (strip(commandSource).length) parseProgram(commandSource);
            consumeStatement();
            return true;
        }

        File[] opened;
        auto previousInput = mem.inputFile;
        auto previousOutput = mem.outputFile;
        auto previousError = mem.errorFile;
        scope (exit) {
            mem.inputFile = previousInput;
            mem.outputFile = previousOutput;
            mem.errorFile = previousError;
            foreach (ref file; opened) file.close();
        }
        foreach (redirect; redirects) {
            File selected;
            if (redirect.duplicate) {
                // Snapshot the selected stream now, preserving left-to-right
                // behavior of >file 2>&1 versus 2>&1 >file.
                switch (redirect.operand) {
                case "0": selected = mem.inputFile; break;
                case "1": selected = mem.outputFile; break;
                case "2": selected = mem.errorFile; break;
                default: throw new YshError("untranslated descriptor duplication");
                }
            } else {
                if (redirect.kind == TokenKind.tripleLess || redirect.hereDocument) {
                    selected = File.tmpfile();
                    selected.write(redirect.expandHereDocument ? evaluateDoubleQuoted(redirect.operand, mem, true) : redirect.operand);
                    if (!redirect.hereDocument && !redirect.omitHereStringNewline) selected.write("\n");
                    selected.flush();
                    selected.rewind();
                } else {
                    try {
                        selected = File(redirect.operand, redirect.kind == TokenKind.less
                            ? "r" : redirect.kind == TokenKind.shiftRight ? "a" : "w");
                    } catch (ErrnoException error) {
                        mem.errorFile.writeln("ysh-d: ", error.msg);
                        mem.lastStatus = 1;
                        consumeStatement();
                        return true;
                    }
                }
                opened ~= selected;
            }
            switch (redirect.descriptor) {
            case 0: mem.inputFile = selected; break;
            case 1: mem.outputFile = selected; break;
            case 2: mem.errorFile = selected; break;
            default: assert(0);
            }
        }
        if (strip(commandSource).length) {
            mem.registerDerivedSource(commandSource, source_, statementStart);
            executeProgram(commandSource, mem);
            redirectStatusChecked_ = true;
        }
        else mem.lastStatus = 0;
        mem.outputFile.flush();
        mem.errorFile.flush();

        consumeStatement();
        return true;
    }

    private void consumeStatement() {
        auto start = current_.offset;
        auto scanner = new CommandScanner(source_[start .. $], returnMode_, parserOptions_, multiline_);
        int depth;
        size_t end;
        while (true) {
            auto token = scanner.next();
            if (token.kind == TokenKind.eof || (depth == 0 && isEndStatement(token.kind))) {
                end = start + token.offset;
                break;
            }
            adjustDepth(depth, token);
        }
        if (scanner.documents().length == 0) moveTo(end);
        else while (current_.kind != TokenKind.eof && current_.offset < end) advance();
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
            variableChecker_.declare(current_.text, readOnly);
            advance();

            if (current_.kind == TokenKind.colon) advance();
            if (current_.kind == TokenKind.name) parseTypeExpression();

            if (current_.kind != TokenKind.comma) {
                break;
            }
            advance();
        }

        if (current_.kind == TokenKind.equal) {
            advance();
            auto rhs = collectRhs();
            if (syntaxOnly_) {
                validateExpression(rhs);
                return;
            }
            executeVarDecl(VarDecl(names, readOnly, true, rhs), mem);
            return;
        }

        if (isEndStatement(current_.kind)) {
            if (syntaxOnly_) return;
            executeVarDecl(VarDecl(names, readOnly, false, ""), mem);
            return;
        }

        throw new YshError(format(
            "untranslated declaration syntax at byte %s", current_.offset));
    }

    private bool tryBareDeclaration(Memory mem) {
        if (parserOptions_ !is null && !parserOptions_.get("parse_equals")) return false;
        if (current_.kind != TokenKind.name) return false;
        auto next = lexer_.peek();
        if (next.kind != TokenKind.equal || next.offset <= current_.offset + current_.text.length) return false;
        if (!attributeScope_) throw new ParseError("Unexpected = (Hint: use var/setvar, or quote it)");
        auto name = current_.text;
        advance();
        require(TokenKind.equal, "=");
        auto rhs = collectRhs();
        if (syntaxOnly_) validateExpression(rhs);
        else executeVarDecl(VarDecl([name], false, true, rhs), mem);
        return true;
    }

    private void parseTypeExpression() {
        if (current_.kind != TokenKind.name) throw new ParseError("Expected a declaration type");
        advance();
        if (current_.kind == TokenKind.leftBracket) parseParameterTypeArguments();
    }

    private void parseMutation(Memory mem, AssignmentScope assignmentScope) {
        advance(); // setvar / setglobal

        string[] targets;
        string operation;
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
                foreach (op; ["**", "//", "<<", ">>", "++", "+", "-", "*", "/", "%", "&", "|", "^"]) {
                    if (target.endsWith(op)) {
                        operation = op;
                        target = strip(target[0 .. $ - op.length]);
                        break;
                    }
                }
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
        if (operation.length && targets.length != 1)
            throw new ParseError("augmented mutation needs one target");
        if (syntaxOnly_) {
            foreach (target; targets) {
                auto name = validateAssignmentTarget(target, parserOptions_);
                if (assignmentScope == AssignmentScope.local) variableChecker_.mutate(name);
            }
            validateExpression(rhs);
            return;
        }
        executeMutation(Mutation(targets, assignmentScope, rhs, operation), mem);
    }

    private bool scanShellFunction(out ShellFunctionDefinition definition) {
        if (current_.kind != TokenKind.name && current_.kind != TokenKind.trueKeyword &&
                current_.kind != TokenKind.falseKeyword) return false;
        bool explicitKeyword = current_.text == "function" && completeCommandWord(source_, current_);
        if (explicitKeyword) advance();
        if (current_.kind != TokenKind.name && current_.kind != TokenKind.trueKeyword &&
                current_.kind != TokenKind.falseKeyword) {
            if (explicitKeyword) throw new ParseError("Expected a shell function name");
            return false;
        }
        auto start = current_.offset;
        auto end = start;
        while (end < source_.length && !isCommandWhitespace(source_[end]) && source_[end] != '(' && source_[end] != '{') ++end;
        auto name = source_[start .. end];
        if (!name.length || !asciiIdentifierStart(name[0])) return false;
        foreach (ch; name) if (!asciiIdentifierContinue(ch) && ch != '-') return false;
        moveTo(end);
        if (current_.kind == TokenKind.leftParen) {
            advance();
            if (current_.kind != TokenKind.rightParen) return false;
            advance();
        } else if (!explicitKeyword) return false;
        while (current_.kind == TokenKind.newline) advance();
        if (current_.kind != TokenKind.leftBrace) {
            throw new ParseError("Expected a shell function body");
        }
        auto bodyStart = current_.offset;
        auto body = collectBlock();
        auto bodyEnd = lastBlockEnd_;
        if (current_.kind == TokenKind.less || current_.kind == TokenKind.greater ||
                current_.kind == TokenKind.shiftRight || current_.kind == TokenKind.shiftLeft ||
                current_.kind == TokenKind.tripleLess) {
            auto suffixStart = current_.offset;
            auto scanner = new CommandScanner(source_[suffixStart .. $], returnMode_, parserOptions_, multiline_);
            int depth;
            size_t suffixEnd;
            while (true) {
                auto token = scanner.next();
                if (token.kind == TokenKind.eof || (!depth && (isEndStatement(token.kind) ||
                        token.kind == TokenKind.andIf || token.kind == TokenKind.orIf || token.kind == TokenKind.pipe))) {
                    suffixEnd = token.offset;
                    break;
                }
                adjustDepth(depth, token);
            }
            auto suffix = commandFragment(suffixStart, 0, suffixEnd, scanner);
            body = source_[bodyStart .. bodyEnd] ~ " " ~ suffix;
            bodyEnd = suffixStart + suffixEnd;
            auto offsets = scanner.documents().keys;
            sort(offsets);
            foreach (offset; offsets) if (offset < suffixEnd)
                definition.pendingDocuments ~= shiftedDocuments([scanner.documents()[offset]], suffixStart);
        }
        definition.name = name;
        definition.body = body;
        definition.endOffset = bodyEnd;
        return true;
    }

    private bool tryParseShellFunction(Memory mem) {
        if (current_.kind != TokenKind.name && current_.kind != TokenKind.trueKeyword &&
                current_.kind != TokenKind.falseKeyword) return false;
        auto start = current_.offset;
        auto parser = new ProgramParser(source_[start .. $], true, returnMode_, false, parserOptions_, null, false, multiline_);
        ShellFunctionDefinition definition;
        if (!parser.scanShellFunction(definition)) return false;
        variableChecker_.enter(DefinitionKind.shellFunction);
        scope (exit) variableChecker_.leave();
        .parseProgram(definition.body, ReturnMode.procValue, parserOptions_, variableChecker_, attributeScope_, multiline_);
        moveTo(start + definition.endOffset, shiftedDocuments(definition.pendingDocuments, start));
        if (!syntaxOnly_) {
            auto functionProc = new YshProc(definition.name, definition.body, mem, true, [], "", ProcSignature.init, true, attributeScope_, multiline_);
            mem.builtins.shellFunctions.set(definition.name, Value.proc(functionProc));
            mem.lastStatus = 0;
        }
        return true;
    }

    private void parseFunction(Memory mem) {
        variableChecker_.enter(DefinitionKind.functionValue);
        scope (exit) variableChecker_.leave();
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
            if (current_.kind == TokenKind.name) parseTypeExpression();
            string defaultSource;

            if (current_.kind == TokenKind.equal) {
                sawDefault = true;
                advance();
                defaultSource = collectParameterDefault();
                if (defaultSource.length == 0) {
                    throw new YshError("expected parameter default expression");
                }
                if (syntaxOnly_) validateExpression(defaultSource);
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
        if (current_.kind == TokenKind.fatArrow) { advance(); parseTypeExpression(); }
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

        foreach (parameter; parameters) variableChecker_.declare(parameter.name);
        foreach (parameter; namedParameters) variableChecker_.declare(parameter.name);
        if (restPositionalName.length) variableChecker_.declare(restPositionalName);
        if (restNamedName.length) variableChecker_.declare(restNamedName);
        .parseProgram(body, ReturnMode.functionValue, parserOptions_, variableChecker_, attributeScope_, multiline_);
        if (syntaxOnly_) return;
        auto userFunction = new YshFunction(name, parameters, body, mem,
            restPositionalName, namedParameters, restNamedName, attributeScope_, multiline_);
        mem.declareLocal(name, Value.callable(userFunction));
    }

    private void parseProc(Memory mem) {
        variableChecker_.enter(DefinitionKind.procedure);
        scope (exit) variableChecker_.leave();
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
        ProcSignature signature;

        if (current_.kind == TokenKind.leftParen) {
            openSignature = false;
            advance();
            size_t group;
            FunctionParameter[][4] parameters;
            string[4] rest;
            bool[string] names;
            while (current_.kind != TokenKind.rightParen) {
                if (current_.kind == TokenKind.semicolon) {
                    if (++group > 3) throw new ParseError("Too many proc parameter groups");
                    advance();
                    continue;
                }
                string parameterName;
                if (current_.kind == TokenKind.ellipsis) {
                    if (group == 3) throw new ParseError("Rest param isn't allowed for blocks");
                    advance();
                    if (current_.kind != TokenKind.name) throw new ParseError("Expected proc rest parameter name");
                    parameterName = current_.text;
                    rest[group] = parameterName;
                    advance();
                    if (current_.kind == TokenKind.comma) advance();
                    if (current_.kind != TokenKind.semicolon && current_.kind != TokenKind.rightParen)
                        throw new ParseError("Proc rest parameter must be last in its group");
                } else {
                    if (current_.kind != TokenKind.name) throw new ParseError("Expected proc parameter name");
                    parameterName = current_.text;
                    advance();
                    if (current_.kind == TokenKind.name) {
                        auto typeName = current_.text;
                        advance();
                        bool parameterized = current_.kind == TokenKind.leftBracket;
                        if (group == 0 && (parameterized || (typeName != "Str" && typeName != "Ref")))
                            throw new ParseError("Word params may only have type Str or Ref");
                        if (group == 3 && (parameterized || typeName != "Command"))
                            throw new ParseError("Block param must have type Command");
                        if (parameterized) parseParameterTypeArguments();
                    }
                    string defaultSource;
                    if (current_.kind == TokenKind.equal) {
                        advance();
                        defaultSource = collectParameterDefault();
                        if (!defaultSource.length) throw new ParseError("Expected proc parameter default expression");
                        validateExpression(defaultSource);
                    }
                    parameters[group] ~= FunctionParameter(parameterName, defaultSource);
                    if (group == 3 && parameters[group].length > 1)
                        throw new ParseError("Only one block param is allowed");
                    if (current_.kind == TokenKind.comma) advance();
                    else if (current_.kind != TokenKind.semicolon && current_.kind != TokenKind.rightParen)
                        throw new ParseError("Expected comma or parameter-group separator");
                }
                if (parameterName in names) throw new ParseError("Duplicate proc parameter " ~ parameterName);
                names[parameterName] = true;
            }
            require(TokenKind.rightParen, ")");
            wordParameters = parameters[0];
            restWordName = rest[0];
            signature.positional = parameters[1];
            signature.restPositional = rest[1];
            signature.named = parameters[2];
            signature.restNamed = rest[2];
            signature.hasBlock = parameters[3].length != 0;
            if (signature.hasBlock) signature.block = parameters[3][0];
        }

        auto body = collectBlock();
        foreach (parameter; wordParameters) variableChecker_.declare(parameter.name);
        foreach (parameter; signature.positional) variableChecker_.declare(parameter.name);
        foreach (parameter; signature.named) variableChecker_.declare(parameter.name);
        if (restWordName.length) variableChecker_.declare(restWordName);
        if (signature.restPositional.length) variableChecker_.declare(signature.restPositional);
        if (signature.restNamed.length) variableChecker_.declare(signature.restNamed);
        if (signature.hasBlock) variableChecker_.declare(signature.block.name);
        .parseProgram(body, ReturnMode.procValue, parserOptions_, variableChecker_, attributeScope_, multiline_);
        if (syntaxOnly_) return;
        auto userProc = new YshProc(name, body, mem, openSignature,
            wordParameters, restWordName, signature, false, attributeScope_, multiline_);
        mem.declareLocal(name, Value.proc(userProc));
    }

    private void parseParameterTypeArguments() {
        require(TokenKind.leftBracket, "[");
        while (true) {
            if (current_.kind != TokenKind.name) throw new ParseError("Expected parameter type");
            advance();
            if (current_.kind == TokenKind.leftBracket) parseParameterTypeArguments();
            if (current_.kind != TokenKind.comma) break;
            advance();
        }
        require(TokenKind.rightBracket, "]");
    }

    private struct SavedEnvBinding {
        string name;
        bool existed;
        Value value;
    }

    private void parseShellDeclare(Memory mem) {
        advance();
        bool associative, indexed;
        while (atRawWord("-A") || atRawWord("-a")) {
            if (atRawWord("-A")) { associative = true; consumeRawWord("-A"); }
            else { indexed = true; consumeRawWord("-a"); }
        }
        if (!associative && !indexed) {
            bool any;
            while (!isEndStatement(current_.kind)) {
                foreach (word; readCommandWord(mem)) {
                    string name, value;
                    if (!splitTempBinding(word, name, value)) throw new UsageError("Untranslated declaration without initializer or flags");
                    if (!syntaxOnly_) mem.declareLocal(name, Value.str(value));
                    any = true;
                }
            }
            if (!any) throw new UsageError("Declaration requires an operand");
            if (!syntaxOnly_) mem.lastStatus = 0;
            return;
        }
        if (current_.kind != TokenKind.name) throw new UsageError("Expected a shell array name");
        auto name = current_.text;
        if (!tryRetainedAssignment(mem, true, associative)) {
            advance();
            if (!isEndStatement(current_.kind)) throw new ParseError("Expected a shell array assignment");
            if (!syntaxOnly_) mem.declareLocal(name, Value.shellArray(new YshDict(), associative));
        }
        if (!syntaxOnly_) mem.lastStatus = 0;
    }

    /// Retained assignments have their own lvalues and array values. They do
    /// not turn a typed List/Dict/Eggex into a shell container.
    private bool tryRetainedAssignment(Memory mem, bool declaration = false, bool associative = false) {
        auto subEpoch = syntaxOnly_ ? 0 : mem.commandSubEpoch;
        if (current_.kind != TokenKind.name) return false;
        auto start = current_.offset;
        auto name = current_.text;
        auto offset = start + name.length;
        string indexSource;
        bool indexed;
        if (offset < source_.length && source_[offset] == '[') {
            auto close = substitutionClose(source_, offset, '[', ']');
            indexSource = source_[offset + 1 .. close];
            if (!indexSource.strip().length) throw new ParseError("Shell array index cannot be empty");
            indexed = true;
            offset = close + 1;
        }
        bool append = offset + 1 < source_.length && source_[offset .. offset + 2] == "+=";
        if (append) offset += 2;
        else if (offset < source_.length && source_[offset] == '=') ++offset;
        else return false;
        bool compound = offset < source_.length && source_[offset] == '(';
        if (!declaration && !indexed && !append && !compound) return false;
        import yshd.state : Cell;
        Cell cell;
        if (!syntaxOnly_) {
            if (declaration) {
                if (auto local = mem.currentFrame.cells.find(name)) cell = *local;
            } else cell = mem.getShellAssignmentCell(name);
        }
        if (!syntaxOnly_ && append && !indexed && !compound && cell !is null &&
                (cell.value.kind == ValueKind.bashArrayValue || cell.value.kind == ValueKind.bashAssocValue))
            throw new FatalRuntimeError("Can't append a string to a shell array");
        if (cell !is null && cell.readOnly) throw new FatalRuntimeError("Can't assign to readonly shell variable " ~ name);
        if (!syntaxOnly_ && cell !is null && cell.value.kind != ValueKind.stringValue &&
                cell.value.kind != ValueKind.bashArrayValue && cell.value.kind != ValueKind.bashAssocValue)
            throw new FatalRuntimeError("Cannot use shell assignment on " ~ kindName(cell.value));
        bool isAssociative = associative || (!syntaxOnly_ && cell !is null && cell.value.kind == ValueKind.bashAssocValue);
        auto elements = new YshDict();
        void assignRetained(Value value) {
            if (declaration) mem.declareLocal(name, value);
            else mem.setShellVar(name, value);
        }
        if (!syntaxOnly_ && append && cell !is null &&
                (cell.value.kind == ValueKind.bashArrayValue || cell.value.kind == ValueKind.bashAssocValue))
            elements = cell.value.shellContainer.shallowCopy();
        moveTo(offset);
        if (compound) {
            advance(); // (
            long nextIndex;
            if (append && !isAssociative) foreach (key, unused; elements) {
                auto index = to!long(key);
                if (index >= nextIndex) nextIndex = index + 1;
            }
            while (current_.kind != TokenKind.rightParen) {
                if (current_.kind == TokenKind.eof) throw new ParseError("Unterminated shell array literal");
                if (current_.kind == TokenKind.newline) { advance(); continue; }
                string key;
                if (current_.kind == TokenKind.leftBracket) {
                    auto keySource = collectBracketedExpression("shell array index");
                    require(TokenKind.equal, "=");
                    if (isAssociative) {
                        auto keyParser = new ProgramParser(keySource, syntaxOnly_, returnMode_, true, parserOptions_);
                        key = keyParser.readScalarWord(mem).text();
                    } else {
                        auto arithmetic = parseShellArithmetic(keySource, parserOptions_);
                        if (!syntaxOnly_) {
                            import std.bigint : toDecimalString;
                            nextIndex = to!long(toDecimalString(arithmetic.evaluate(mem)));
                            if (nextIndex < 0) throw new FatalRuntimeError("Invalid shell array index");
                        }
                    }
                } else if (isAssociative) throw new ParseError("Associative literal requires [key]=value entries");
                if (!isAssociative) key = to!string(nextIndex++);
                string value;
                if (current_.kind != TokenKind.rightParen && !isEndStatement(current_.kind)) value = readScalarWord(mem).text();
                elements.set(key, Value.str(value));
            }
            advance(); // )
            if (!isEndStatement(current_.kind)) throw new ParseError("Unexpected words after array literal");
            if (!syntaxOnly_) assignRetained(Value.shellArray(elements, isAssociative));
        } else {
            if (indexed && syntaxOnly_) parseShellArithmetic(indexSource, parserOptions_);
            string value;
            if (offset < source_.length && !isCommandWhitespace(source_[offset]) && !isEndStatement(current_.kind))
                value = readScalarWord(mem).text();
            if (!isEndStatement(current_.kind)) throw new ParseError("Unexpected words after shell assignment");
            if (!syntaxOnly_) {
                if (indexed || isAssociative || (cell !is null && cell.value.kind == ValueKind.bashArrayValue)) {
                    if (cell !is null && (cell.value.kind == ValueKind.bashArrayValue || cell.value.kind == ValueKind.bashAssocValue))
                        elements = cell.value.shellContainer;
                    else if (cell !is null && cell.value.kind == ValueKind.stringValue && !isAssociative)
                        elements.set("0", cell.value);
                    string key = "0";
                    if (indexed) {
                        if (isAssociative) {
                            auto keyParser = new ProgramParser(indexSource, false, returnMode_, true, parserOptions_);
                            key = keyParser.readScalarWord(mem).text();
                        } else key = evaluateShellIndex(indexSource, Value.shellArray(elements), mem);
                        if (!isAssociative && key.length && key[0] == '-')
                            throw new FatalRuntimeError("Invalid negative shell array index");
                    }
                    if (append) if (auto prior = elements.find(key)) value = prior.stringValue ~ value;
                    elements.set(key, Value.str(value));
                    assignRetained(Value.shellArray(elements, isAssociative));
                } else {
                    if (append && cell !is null) value = cell.value.stringValue ~ value;
                    assignRetained(Value.str(value));
                }
            }
        }
        if (!syntaxOnly_) mem.lastStatus = !declaration && mem.commandSubEpoch != subEpoch ? mem.commandSubLastStatus : 0;
        return true;
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

    private static string shellQuotedAlias(string value) {
        string quoted = "'";
        foreach (character; value) {
            if (character == '\'') {
                quoted ~= "'\\''";
            } else {
                quoted ~= character;
            }
        }
        return quoted ~ "'";
    }

    /// Translate the conventional alias/unalias builtin surface used by
    /// Grease's current spec, retaining definitions in shell parser state.
    private void parseAlias(Memory mem) {
        advance(); // alias
        string[] operands;
        while (!isEndStatement(current_.kind)) {
            operands ~= readCommandWord(mem);
        }

        runAlias(operands, mem);
    }

    private void runAlias(string[] operands, Memory mem) {

        if (operands.length == 0 ||
                (operands.length == 1 && operands[0] == "--")) {
            auto names = mem.aliases.keys;
            sort(names);
            foreach (name; names) {
                mem.outputFile.write("alias ", name, "=",
                    shellQuotedAlias(mem.aliases[name]), "\n");
            }
            mem.lastStatus = 0;
            return;
        }

        int status;
        foreach (word; operands) {
            if (word == "--") {
                continue;
            }
            auto equal = word.indexOf('=');
            if (equal >= 0) {
                if (equal == 0) {
                    mem.errorFile.write("alias: empty alias name\n");
                    status = 2;
                } else {
                    mem.aliases[word[0 .. cast(size_t)equal]] =
                        word[cast(size_t)equal + 1 .. $];
                }
                continue;
            }

            auto known = word in mem.aliases;
            if (known is null) {
                mem.errorFile.write("alias: ", word, ": not found\n");
                if (status == 0) {
                    status = 1;
                }
            } else {
                mem.outputFile.write("alias ", word, "=",
                    shellQuotedAlias(*known), "\n");
            }
        }
        mem.lastStatus = status;
    }

    private void parseUnalias(Memory mem) {
        advance(); // unalias
        string[] operands;
        while (!isEndStatement(current_.kind)) {
            operands ~= readCommandWord(mem);
        }
        runUnalias(operands, mem);
    }

    private void runUnalias(string[] operands, Memory mem) {
        if (operands.length == 0) {
            mem.errorFile.write("unalias: requires at least one name\n");
            mem.lastStatus = 2;
            return;
        }

        int status;
        bool clearAll;
        foreach (word; operands) {
            if (word == "--") {
                continue;
            }
            if (word == "-a") {
                clearAll = true;
                continue;
            }
            if (!mem.aliases.remove(word)) {
                mem.errorFile.write("unalias: ", word, ": not found\n");
                status = 1;
            }
        }
        if (clearAll) {
            mem.aliases = null;
        }
        mem.lastStatus = status;
    }

    private void parseCommandInvocation(Memory mem) {
        auto subEpoch = mem.commandSubEpoch;
        auto commandNameParts = readCommandWord(mem, true);
        while (!commandNameParts.length && !isEndStatement(current_.kind))
            commandNameParts = readCommandWord(mem, true);
        if (!commandNameParts.length) {
            mem.lastStatus = mem.commandSubEpoch != subEpoch ? mem.commandSubLastStatus : 0;
            return;
        }
        bool attributeBlock = lastWordStatic_ && commandNameParts.length == 1 && attributeCommandName(commandNameParts[0]);

        string[string] tempBindings;
        auto commandName = commandNameParts[0];
        string bindingName;
        string bindingValue;
        while (splitTempBinding(commandName, bindingName, bindingValue)) {
            tempBindings[bindingName] = bindingValue;
            if (isEndStatement(current_.kind)) {
                foreach (name, text; tempBindings) {
                    mem.setShellVar(name, Value.str(text));
                    mem.trace.assignment(name, "=", Value.str(text), mem);
                }
                mem.lastStatus = mem.commandSubEpoch != subEpoch ? mem.commandSubLastStatus : 0;
                return;
            }
            commandNameParts = readCommandWord(mem, true);
            while (!commandNameParts.length && !isEndStatement(current_.kind))
                commandNameParts = readCommandWord(mem, true);
            if (!commandNameParts.length) { mem.lastStatus = 0; return; }
            commandName = commandNameParts[0];
        }

        string[][] pipeline;
        string[] argv = commandNameParts;
        import yshd.expr : ParsedArguments, EvaluatedArguments;
        ParsedArguments typedArguments;
        string blockSource;
        bool hasBlock;

        while (!isEndStatement(current_.kind)) {
            if (current_.kind == TokenKind.leftBrace) {
                hasBlock = true;
                blockSource = collectBlock();
                parseBlockArgument(blockSource, attributeBlock);
                if (!isEndStatement(current_.kind)) throw new ParseError("Unexpected words after block argument");
                break;
            }
            if (atTypedArguments()) {
                if (typedArguments !is null || pipeline.length)
                    throw new ParseError("Unexpected typed argument list");
                typedArguments = parseCommandArguments();
                if (current_.kind == TokenKind.leftBrace) continue;
                if (!isEndStatement(current_.kind)) throw new ParseError("Unexpected words after typed arguments");
                break;
            }
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

        EvaluatedArguments evalArguments() {
            auto arguments = typedArguments is null ? EvaluatedArguments.init : typedArguments.eval(mem);
            if (hasBlock) {
                if (arguments.hasBlock) throw new FatalRuntimeError("Can't accept both block expression and block literal");
                arguments.hasBlock = true;
                arguments.block = Value.closure(ValueKind.commandValue, new YshCommand(blockSource, mem, attributeBlock, multiline_));
            }
            return arguments;
        }

        if (pipeline.length == 0) {
            mem.trace.simpleCommand(argv, mem);
            bool builtinOnly, skipProcedures, useDefaultPath;
            // Prefixes operate on this already-expanded argv. Never turn words
            // back into source or evaluate a typed argument a second time.
            while (argv.length) {
                if (!skipProcedures && builtinKind(argv[0]) != BuiltinKind.special) {
                    import yshd.func_proc : invokeProcedure;
                    if (hasProcedure(argv[0], mem) &&
                            invokeProcedure(mem.getCell(argv[0]).value, argv[1 .. $], mem, evalArguments(), argv[0])) return;
                    if (auto functionValue = mem.builtins.shellFunctions.find(argv[0])) {
                        (cast(YshProc)functionValue.callableValue).invoke(argv[1 .. $], mem, evalArguments());
                        return;
                    }
                }
                if (argv[0] == "runproc") {
                    size_t start = argv.length > 1 && argv[1] == "--" ? 2 : 1;
                    if (start == argv.length) { mem.errorFile.writeln("runproc requires a command"); mem.lastStatus = 2; return; }
                    auto name = argv[start];
                    if (!hasProcedure(name, mem)) { mem.errorFile.writeln("runproc: no invokable named ", name); mem.lastStatus = 1; return; }
                    import yshd.func_proc : invokeProcedure;
                    invokeProcedure(mem.getCell(name).value, argv[start + 1 .. $], mem, evalArguments(), name);
                    return;
                }
                if (argv[0] == "invoke") {
                    size_t start = 1;
                    bool procedures, functions, builtins, external, show;
                    for (; start < argv.length; ++start) {
                        auto word = argv[start];
                        if (word == "--") { ++start; break; }
                        if (word.length < 2 || word[0] != '-') break;
                        if (word == "--proc") procedures = true;
                        else if (word == "--sh-func") functions = true;
                        else if (word == "--builtin") builtins = true;
                        else if (word == "--extern") external = true;
                        else if (word == "--show") show = true;
                        else { mem.errorFile.writeln("invoke: invalid flag ", word); mem.lastStatus = 2; return; }
                    }
                    if (start == argv.length) { mem.errorFile.writeln("invoke requires a command"); mem.lastStatus = 2; return; }
                    if (show) {
                        if (typedArguments !is null || hasBlock) { mem.lastStatus = 2; return; }
                        runInvokeShow(argv[start .. $], mem); return;
                    }
                    if (!(procedures || functions || builtins || external)) {
                        mem.errorFile.writeln("invoke requires a lookup flag"); mem.lastStatus = 2; return;
                    }
                    auto name = argv[start];
                    if (procedures && hasProcedure(name, mem)) {
                        import yshd.func_proc : invokeProcedure;
                        invokeProcedure(mem.getCell(name).value, argv[start + 1 .. $], mem, evalArguments()); return;
                    }
                    if (functions) if (auto functionValue = mem.builtins.shellFunctions.find(name)) {
                        (cast(YshProc)functionValue.callableValue).invoke(argv[start + 1 .. $], mem, evalArguments()); return;
                    }
                    auto kind = builtinKind(name);
                    if (builtins && kind != BuiltinKind.none && kind != BuiltinKind.assignment) {
                        argv = argv[start .. $]; builtinOnly = true; skipProcedures = true; continue;
                    }
                    if (external) {
                        if (typedArguments !is null || hasBlock) { mem.lastStatus = 2; return; }
                        mem.lastStatus = runExternal(argv[start .. $], mem); return;
                    }
                    mem.errorFile.writeln("invoke: command not found: ", name); mem.lastStatus = 127; return;
                }
                if (argv[0] != "builtin" && argv[0] != "command") break;
                auto prefix = argv[0];
                size_t index = 1;
                bool query, verbose;
                if (prefix == "command") {
                    while (index < argv.length) {
                        auto word = argv[index];
                        if (word == "--") { ++index; break; }
                        if (word.length < 2 || word[0] != '-') break;
                        foreach (flag; word[1 .. $]) {
                            if (flag == 'p') useDefaultPath = true;
                            else if (flag == 'v') { query = true; verbose = false; }
                            else if (flag == 'V') { query = true; verbose = true; }
                            else { mem.errorFile.writeln("command: invalid flag ", word); mem.lastStatus = 2; return; }
                        }
                        ++index;
                    }
                    if (query) {
                        if (typedArguments !is null || hasBlock) { mem.lastStatus = 2; return; }
                        mem.lastStatus = 0;
                        foreach (name; argv[index .. $]) {
                            auto resolutions = resolveCommand(name, mem, false);
                            if (!resolutions.length) {
                                mem.errorFile.writeln(name, ": not found"); mem.lastStatus = 1;
                            } else if (verbose) printResolution(resolutions[0], mem);
                            else mem.outputFile.writeln(resolutions[0].kind == "file" ? resolutions[0].detail : name);
                        }
                        return;
                    }
                    skipProcedures = true;
                    builtinOnly = false;
                } else {
                    if (index < argv.length && argv[index] == "--") ++index;
                    else if (index < argv.length && argv[index].length > 1 && argv[index][0] == '-') {
                        mem.errorFile.writeln("builtin: invalid flag ", argv[index]); mem.lastStatus = 2; return;
                    }
                    skipProcedures = true;
                    builtinOnly = true;
                }
                argv = argv[index .. $];
                if (!argv.length) { mem.lastStatus = 0; return; }
                if (builtinOnly && (builtinKind(argv[0]) == BuiltinKind.none ||
                        builtinKind(argv[0]) == BuiltinKind.assignment)) {
                    mem.errorFile.writeln("builtin: '", argv[0], "' isn't a shell builtin"); mem.lastStatus = 1; return;
                }
            }
            commandName = argv[0];
            auto selectedBuiltin = builtinKind(commandName);
            if (selectedBuiltin != BuiltinKind.none && (selectedBuiltin != BuiltinKind.privateBuiltin || builtinOnly))
                mem.trace.builtin(argv, mem);
            try {
                auto words = argv[1 .. $];
                switch (commandName) {
                case "read": runRead(words, typedArguments, hasBlock, mem); return;
                case "export": case "readonly": case "unset":
                    if (typedArguments !is null || hasBlock) throw new UsageError(commandName ~ " does not accept typed arguments");
                    import yshd.assignment_builtins : runAssignmentBuiltin;
                    mem.lastStatus = runAssignmentBuiltin(commandName, words, mem);
                    return;
                case "printf":
                    if (typedArguments !is null || hasBlock) throw new UsageError("printf does not accept typed arguments");
                    import yshd.printf_osh : runPrintf;
                    mem.lastStatus = runPrintf(words, mem);
                    return;
                case "cat": case "rm": case "sleep":
                    if (!builtinOnly) break;
                    if (typedArguments !is null || hasBlock) throw new UsageError(commandName ~ " does not accept typed arguments");
                    import yshd.private_builtins : runPrivateBuiltin;
                    mem.lastStatus = runPrivateBuiltin(commandName, words, mem);
                    return;
                case "cd": case "chdir":
                    auto arguments = evalArguments();
                    if (arguments.positional.length || (arguments.named !is null && arguments.named.length))
                        throw new YshTypeError("cd accepts only a block typed argument");
                    if (arguments.hasBlock && arguments.block.kind != ValueKind.commandValue)
                        throw new YshTypeError("cd block should be Command");
                    auto block = arguments.hasBlock ? cast(YshCommand)arguments.block.callableValue : null;
                    runCd(words, block !is null, block is null ? "" : block.source,
                        block !is null && block.attributeScope, mem, block !is null && block.multiline);
                    return;
                case "shopt":
                    auto arguments = evalArguments();
                    if (arguments.positional.length || (arguments.named !is null && arguments.named.length))
                        throw new YshTypeError("shopt accepts only a block typed argument");
                    if (arguments.hasBlock && arguments.block.kind != ValueKind.commandValue)
                        throw new YshTypeError("shopt block should be Command");
                    auto block = arguments.hasBlock ? cast(YshCommand)arguments.block.callableValue : null;
                    runShopt(words, block !is null, block is null ? "" : block.source, mem, block !is null && block.multiline);
                    return;
                case "true": case "false": case ":": case "echo": case "write":
                case "set": case "alias": case "unalias": case "source": case ".": case "eval": case "exit": case "type":
                    if (typedArguments !is null || hasBlock) throw new UsageError(commandName ~ " does not accept typed arguments");
                    switch (commandName) {
                    case "true": case ":": mem.lastStatus = 0; break;
                    case "false": mem.lastStatus = 1; break;
                    case "echo": runEcho(words, mem); break;
                    case "write": runWrite(words, mem); break;
                    case "set": runSet(words, mem); break;
                    case "alias": runAlias(words, mem); break;
                    case "unalias": runUnalias(words, mem); break;
                    case "source": case ".": runSource(words, mem); break;
                    case "eval": runEval(words, mem); break;
                    case "type": runType(words, mem); break;
                    case "exit":
                        if (words.length > 1) throw new UsageError("exit accepts zero or one status");
                        int status = mem.lastStatus;
                        if (words.length) {
                            try { status = to!int(words[0]); }
                            catch (Exception error) { throw new UsageError("exit status must be an integer"); }
                        }
                        mem.trace.control("exit", status, mem);
                        throw new ShellExit(status);
                    default: assert(0);
                    }
                    return;
                default: break;
                }
            } catch (UsageError error) {
                mem.errorFile.writeln("ysh-d: ", error.msg); mem.lastStatus = 2; return;
            }
            if (commandName == "fork" || commandName == "forkwait" || commandName == "wait" ||
                    commandName == "jobs" || commandName == "fg" || commandName == "bg") {
                try {
                    auto arguments = evalArguments();
                    if (commandName == "fork" || commandName == "forkwait") {
                        auto words = argv[1 .. $];
                        if (words.length && words[0] == "--") words = words[1 .. $];
                        if (words.length) throw new UsageError(commandName ~ ": unexpected word argument");
                        if (!arguments.hasBlock) throw new UsageError(commandName ~ " requires a Command block");
                        if (arguments.block.kind != ValueKind.commandValue || arguments.positional.length ||
                                (arguments.named !is null && arguments.named.length))
                            throw new YshTypeError(commandName ~ " expects only a Command block");
                        auto command = cast(YshCommand)arguments.block.callableValue;
                        // RequiredBlockAsFrag discards captured frames, as cd
                        // and trap do. The OS child inherits the current frame.
                        mem.lastStatus = runSourceJob([command.source], mem,
                            (string stage, Memory child) { return command.evalInCurrentFrame(child); }, commandName == "fork");
                    } else {
                        if (arguments.hasBlock || typedArguments !is null)
                            throw new UsageError(commandName ~ " does not accept typed arguments");
                        if (commandName == "wait") {
                            auto traceScope = TraceScope(mem, "wait", argv);
                            mem.lastStatus = mem.jobs.waitBuiltin(argv[1 .. $], mem);
                        }
                        else if (commandName == "jobs") mem.lastStatus = mem.jobs.jobsBuiltin(argv[1 .. $], mem);
                        else if (commandName == "fg") mem.lastStatus = mem.jobs.foreground(argv[1 .. $], mem);
                        else throw new UsageError("bg isn't implemented"); // Same reference boundary.
                    }
                } catch (UsageError error) { mem.errorFile.writeln("ysh-d: ", error.msg); mem.lastStatus = 2; }
                return;
            }
            if (commandName == "trap") {
                try {
                    auto arguments = evalArguments();
                    if (arguments.positional.length || (arguments.named !is null && arguments.named.length))
                        throw new YshTypeError("trap expects only a block argument");
                    if (arguments.hasBlock && arguments.block.kind != ValueKind.commandValue)
                        throw new YshTypeError("trap block should be Command");
                    auto block = arguments.hasBlock ? cast(YshCommand)arguments.block.callableValue : null;
                    auto fragment = block is null ? "" : block.source;
                    mem.lastStatus = mem.traps.builtin(argv[1 .. $], arguments.hasBlock, fragment, mem,
                        block !is null && block.multiline);
                } catch (UsageError error) {
                    mem.errorFile.writeln("ysh-d: ", error.msg);
                    mem.lastStatus = 2;
                }
                return;
            }
            if (commandName == "is-main" || commandName == "source-guard" || commandName == "use") {
                try {
                    if (typedArguments !is null || hasBlock)
                        throw new UsageError(commandName ~ " does not accept typed arguments");
                    auto words = argv[1 .. $];
                    if (commandName == "is-main") mem.lastStatus = mem.isMain ? 0 : 1;
                    else if (commandName == "use") {
                        import yshd.module_ysh : useModule;
                        mem.lastStatus = useModule(words, mem);
                    } else {
                        if (words.length && words[0] == "--") words = words[1 .. $];
                        if (!words.length || words[0].length && words[0][0] == '-')
                            throw new UsageError("source-guard requires a name");
                        auto seen = words[0] in mem.sourceGuards;
                        mem.lastStatus = seen !is null && !mem.options.get("redefine_source") ? 1 : 0;
                        if (seen !is null && mem.options.get("redefine_source"))
                            mem.errorFile.writeln("(interactive) Reloading source file '", words[0], "'");
                        mem.sourceGuards[words[0]] = true;
                    }
                } catch (UsageError error) {
                    mem.errorFile.writeln("ysh-d: ", error.msg);
                    mem.lastStatus = 2;
                }
                return;
            }
            if (commandName == "shvar") {
                try {
                    auto arguments = evalArguments();
                    if (!arguments.hasBlock) throw new UsageError("shvar requires a Command block");
                    if (arguments.block.kind != ValueKind.commandValue)
                        throw new YshTypeError("shvar block should be Command");
                    if (arguments.positional.length || (arguments.named !is null && arguments.named.length))
                        throw new YshTypeError("shvar expects only a block argument");
                    size_t start = 1;
                    if (argv.length > start && argv[start] == "--") ++start;
                    else if (argv.length > start && argv[start].length > 1 && argv[start][0] == '-')
                        throw new UsageError("shvar: invalid flag " ~ argv[start]);
                    if (argv.length == start) throw new UsageError("shvar: expected name=value");
                    EvalOptions options;
                    options.variables = new YshDict();
                    foreach (word; argv[start .. $]) {
                        auto equal = word.indexOf('=');
                        if (equal < 0) throw new UsageError("shvar: expected name=value");
                        options.variables.set(word[0 .. equal], Value.str(word[equal + 1 .. $]));
                    }
                    withEvalBindings(mem, options, () {
                        (cast(YshCommand)arguments.block.callableValue).evalInCurrentFrame(mem);
                        return Value.nullValue();
                    });
                    mem.lastStatus = 0;
                } catch (UsageError error) {
                    mem.errorFile.writeln("ysh-d: ", error.msg);
                    mem.lastStatus = 2;
                }
                return;
            }
            if (commandName == "pushd" || commandName == "popd" || commandName == "dirs" || commandName == "pwd") {
                try {
                    if (typedArguments !is null || hasBlock)
                        throw new UsageError(commandName ~ " does not accept typed arguments");
                    mem.lastStatus = runDirectoryBuiltin(commandName, argv[1 .. $], mem);
                } catch (UsageError error) {
                    mem.errorFile.writeln("ysh-d: ", error.msg);
                    mem.lastStatus = 2;
                }
                return;
            }
            if (commandName == "redir" || commandName == "fopen") {
                auto arguments = evalArguments();
                if (!arguments.hasBlock) throw new UsageError(commandName ~ " requires a Command block");
                if (arguments.block.kind != ValueKind.commandValue)
                    throw new YshTypeError(commandName ~ " block should be Command");
                if (arguments.positional.length || (arguments.named !is null && arguments.named.length))
                    throw new YshTypeError(commandName ~ " expects only a block argument");
                // RunBlock evaluates the fragment in the current frame;
                // redirection setup and cleanup belong to its command owner.
                (cast(YshCommand)arguments.block.callableValue).evalInCurrentFrame(mem);
                mem.lastStatus = 0;
                return;
            }
            if (commandName == "ctx") {
                auto arguments = evalArguments();
                if (argv.length < 2) throw new UsageError("ctx expects push, set, or emit");
                auto named = arguments.named is null ? new YshDict() : arguments.named;
                switch (argv[1]) {
                case "push":
                    if (arguments.positional.length != 1 || arguments.positional[0].kind != ValueKind.dict || named.length)
                        throw new YshTypeError("ctx push expects one Dict");
                    if (!arguments.hasBlock || arguments.block.kind != ValueKind.commandValue)
                        throw new YshTypeError("ctx push requires a Command block");
                    mem.contextStack ~= arguments.positional[0].dictValue;
                    scope (exit) --mem.contextStack.length;
                    // This dynamic-context builtin evaluates a command fragment
                    // in the current frame, as pure_ysh.Ctx does.
                    (cast(YshCommand)arguments.block.callableValue).evalInCurrentFrame(mem);
                    return;
                case "set":
                    if (arguments.positional.length || arguments.hasBlock)
                        throw new YshTypeError("ctx set expects only named arguments");
                    if (!mem.contextStack.length) throw new YshError("Could not find a context. Did you forget to ctx push?");
                    foreach (key, value; named) mem.contextStack[$ - 1].set(key, value);
                    break;
                case "emit":
                    if (argv.length < 3) throw new UsageError("ctx emit requires a target field");
                    if (arguments.positional.length != 1 || named.length || arguments.hasBlock)
                        throw new YshTypeError("ctx emit expects one value");
                    if (!mem.contextStack.length) throw new YshError("Could not find a context. Did you forget to ctx push?");
                    auto context = mem.contextStack[$ - 1];
                    auto field = context.find(argv[2]);
                    if (field is null) {
                        context.set(argv[2], Value.list([]));
                        field = context.find(argv[2]);
                    }
                    if (field.kind != ValueKind.list) throw new YshTypeError("ctx emit requires a List field");
                    field.listValue.items ~= arguments.positional[0];
                    break;
                default: throw new UsageError("Unknown ctx verb " ~ argv[1]);
                }
                mem.lastStatus = 0;
                return;
            }
            if (commandName == "append") {
                auto arguments = evalArguments();
                if (arguments.positional.length != 1 ||
                        (arguments.positional[0].kind != ValueKind.list && arguments.positional[0].kind != ValueKind.bashArrayValue) ||
                        (arguments.named !is null && arguments.named.length) || arguments.hasBlock)
                    throw new YshTypeError("append expects one List");
                auto start = argv.length > 1 && argv[1] == "--" ? 2 : 1;
                auto target = arguments.positional[0];
                if (target.kind == ValueKind.list) foreach (word; argv[start .. $]) target.listValue.items ~= Value.str(word);
                else {
                    long nextIndex;
                    foreach (key, unused; target.shellContainer) {
                        auto index = to!long(key);
                        if (index >= nextIndex) nextIndex = index + 1;
                    }
                    foreach (word; argv[start .. $]) target.shellContainer.set(to!string(nextIndex++), Value.str(word));
                }
                mem.lastStatus = 0;
                return;
            }
            if (commandName == "test" || commandName == "[") {
                if (typedArguments !is null || hasBlock) throw new YshTypeError("test does not accept typed arguments");
                import yshd.bracket : runTest;
                mem.lastStatus = runTest(argv, mem);
                return;
            }

            if (typedArguments !is null || hasBlock) throw new UsageError("External commands do not accept typed arguments");
            if (builtinOnly || (selectedBuiltin != BuiltinKind.none && selectedBuiltin != BuiltinKind.privateBuiltin))
                throw new YshError("Untranslated builtin: " ~ commandName);
            mem.canReplaceProcess = allowProcessReplacement_ && atProgramEnd();
            scope (exit) mem.canReplaceProcess = false;
            mem.lastStatus = runExternal(argv, mem, useDefaultPath);
            return;
        }

        pipeline ~= argv;
        mem.lastStatus = runPipeline(pipeline, mem);
    }

    private void parseShopt(Memory mem) {
        advance(); // shopt
        string[] words;
        while (!isEndStatement(current_.kind) && current_.kind != TokenKind.leftBrace)
            words ~= readCommandWord(mem);
        bool hasBlock = current_.kind == TokenKind.leftBrace;
        auto body = hasBlock ? collectBlock() : "";
        if (syntaxOnly_) {
            if (hasBlock) parseBlockArgument(body, false);
            return;
        }
        runShopt(words, hasBlock, body, mem, multiline_);
    }

    private void runShopt(string[] words, bool hasBlock, string body, Memory mem, bool bodyMultiline = false) {
        try {
            bool setting, enabled, query, setOptions;
            size_t index;
            for (; index < words.length; ++index) {
                auto word = words[index];
                if (word == "--") { ++index; break; }
                if (word == "--set") { setting = true; enabled = true; continue; }
                if (word == "--unset") { setting = true; enabled = false; continue; }
                if (word.length < 2 || word[0] != '-') break;
                foreach (flag; word[1 .. $]) {
                    switch (flag) {
                    case 's': setting = true; enabled = true; break;
                    case 'u': setting = true; enabled = false; break;
                    case 'q': query = true; break;
                    case 'p': break;
                    case 'o': setOptions = true; break;
                    default: throw new UsageError("shopt: invalid flag " ~ word);
                    }
                }
            }
            auto names = words[index .. $];
            if (query) {
                if (hasBlock) throw new UsageError("shopt -q does not accept a block");
                mem.lastStatus = 0;
                foreach (name; names) {
                    auto number = ShellOptions.number(name, mem.options.get("ignore_shopt_not_impl"));
                    if (!mem.options.get(number)) { mem.lastStatus = 1; break; }
                }
                return;
            }
            if (setting) {
                if (hasBlock) {
                    size_t[] numbers;
                    foreach (name; names) numbers ~= mem.options.expand(name);
                    mem.options.push(numbers, enabled);
                    scope (exit) mem.options.pop(numbers);
                    .executeProgram(body, mem, false, bodyMultiline);
                } else {
                    foreach (name; names) mem.options.set(name, enabled);
                }
                mem.lastStatus = 0;
                return;
            }
            if (hasBlock) throw new UsageError("shopt requires --set or --unset with a block");
            size_t[] numbers;
            bool singleNames;
            if (names.length == 0) numbers = mem.options.visible(setOptions);
            else foreach (name; names) {
                numbers ~= mem.options.expand(name);
                if (!ShellOptions.isGroup(name)) singleNames = true;
            }
            bool anyFalse;
            foreach (number; numbers) {
                bool value = mem.options.get(number);
                anyFalse = anyFalse || !value;
                auto name = ShellOptions.spec(number).name;
                if (setOptions) mem.outputFile.writeln("set ", value ? "-o " : "+o ", name);
                else mem.outputFile.writeln("shopt -", value ? "s " : "u ", name);
            }
            mem.lastStatus = singleNames && anyFalse ? 1 : 0;
        } catch (UsageError error) {
            mem.errorFile.writeln("ysh-d: ", error.msg);
            mem.lastStatus = 2;
        }
    }

    private void parseExpressionDisplay(Memory mem) {
        advance(); // =
        auto expression = collectRhs();
        auto value = evaluate(expression, mem);
        mem.outputFile.writeln(prettyValue(value, terminalWidth(mem.outputFile.fileno())));
        mem.lastStatus = 0;
    }

    private void parseNoOp(Memory mem) {
        advance(); // :
        while (!isEndStatement(current_.kind)) readCommandWord(mem);
        mem.lastStatus = 0;
    }

    private void parseSource(Memory mem) {
        advance(); // source
        string[] words;
        while (!isEndStatement(current_.kind)) words ~= readCommandWord(mem);
        runSource(words, mem);
    }

    private void runSource(string[] words, Memory mem) {
        bool embedded;
        if (words.length && words[0] == "--builtin") { embedded = true; words = words[1 .. $]; }
        else if (words.length && words[0] == "--") words = words[1 .. $];
        if (!words.length || words[0].length && words[0][0] == '-') {
            mem.errorFile.writeln("source requires a file path");
            mem.lastStatus = 2;
            return;
        }
        auto path = words[0];
        if (path.startsWith("///")) { embedded = true; path = path[3 .. $]; }
        string source;
        if (embedded) {
            import yshd.resources : standardLibrarySource;
            if (!standardLibrarySource(path, source)) {
                mem.errorFile.writeln("source: no builtin file '", path, "'");
                mem.lastStatus = 1;
                return;
            }
        } else {
            if (path.indexOf('/') < 0) {
                import std.path : buildPath;
                import std.file : exists;
                foreach (directory; mem.getEnv("PATH").split(":")) {
                    auto candidate = buildPath(directory, path);
                    if (exists(candidate)) { path = candidate; break; }
                }
            }
            try { source = cast(string)read(path); }
            catch (FileException error) {
                mem.errorFile.writeln("ysh-d: ", error.msg);
                mem.lastStatus = 1;
                return;
            }
        }
        auto traceScope = TraceScope(mem, "source", ["source"] ~ words);
        auto savedMode = mem.returnMode;
        auto savedMain = mem.isMain;
        auto savedArguments = mem.shellArguments;
        mem.returnMode = ReturnMode.shell;
        mem.isMain = false;
        if (words.length > 1) mem.shellArguments = words[1 .. $].dup;
        mem.pushSourceDirectory(embedded ? "stdlib/" ~ path : path);
        scope (exit) {
            mem.returnMode = savedMode;
            mem.isMain = savedMain;
            mem.shellArguments = savedArguments;
            --mem.sourceDirectories.length;
        }
        try {
            .executeProgram(source, mem);
        } catch (ProcReturn control) {
            mem.lastStatus = control.status;
        }
    }

    private void parseEval(Memory mem) {
        advance(); // eval
        string[] words;
        while (!isEndStatement(current_.kind)) {
            if (current_.kind == TokenKind.leftBrace || current_.kind == TokenKind.leftParen)
                throw new UsageError("eval does not accept typed arguments or literal blocks");
            words ~= readCommandWord(mem);
        }
        runEval(words, mem);
    }

    private void runEval(string[] words, Memory mem) {
        if (mem.options.get("simple_eval_builtin") && words.length != 1) {
            mem.errorFile.writeln("ysh-d: eval requires exactly one argument");
            mem.lastStatus = 2;
            return;
        }
        auto traceScope = TraceScope(mem, "eval");
        .executeProgram(words.join(" "), mem);
    }

    private void parseExit(Memory mem) {
        advance(); // exit
        int status = mem.lastStatus;
        if (!isEndStatement(current_.kind)) {
            auto words = [readScalarWord(mem).text()];
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
        string[] words;
        while (!isEndStatement(current_.kind) && current_.kind != TokenKind.leftBrace && current_.kind != TokenKind.leftParen)
            words ~= readCommandWord(mem);
        import yshd.expr : ParsedArguments, EvaluatedArguments;
        ParsedArguments parsed;
        if (current_.kind == TokenKind.leftParen)
            parsed = parseTypedArguments("(" ~ collectParenthesizedExpression(true) ~ ")", true);
        bool literalBlock = current_.kind == TokenKind.leftBrace;
        auto body = literalBlock ? collectBlock() : "";
        bool bodyAttributeScope;
        bool bodyMultiline;
        if (literalBlock) parseBlockArgument(body, false);
        if (!isEndStatement(current_.kind)) throw new ParseError("Unexpected words after cd block");
        auto arguments = parsed is null ? EvaluatedArguments.init : parsed.eval(mem);
        if (arguments.positional.length || (arguments.named !is null && arguments.named.length))
            throw new YshTypeError("cd accepts only a block typed argument");
        if (literalBlock && arguments.hasBlock) throw new FatalRuntimeError("Can't accept both block expression and literal");
        bool hasBlock = literalBlock || arguments.hasBlock;
        if (arguments.hasBlock) {
            if (arguments.block.kind != ValueKind.commandValue) throw new YshTypeError("cd block should be Command");
            body = (cast(YshCommand)arguments.block.callableValue).source;
            bodyAttributeScope = (cast(YshCommand)arguments.block.callableValue).attributeScope;
            bodyMultiline = (cast(YshCommand)arguments.block.callableValue).multiline;
        }
        runCd(words, hasBlock, body, bodyAttributeScope, mem, bodyMultiline);
    }

    private void runCd(string[] words, bool hasBlock, string body, bool bodyAttributeScope, Memory mem, bool bodyMultiline = false) {
        bool physical;
        size_t index;
        for (; index < words.length; ++index) {
            if (words[index] == "--") { ++index; break; }
            if (words[index] == "-P") { physical = true; continue; }
            if (words[index] == "-L") { physical = false; continue; }
            break;
        }
        auto operands = words[index .. $];
        if (mem.options.get("strict_arg_parse") && operands.length > 1) throw new UsageError("cd accepts at most one path");
        if (hasBlock && !operands.length) throw new UsageError("cd requires a path when passed a block");
        auto target = operands.length ? operands[0] : mem.getEnv("HOME");
        if (!target.length && !operands.length) { mem.errorFile.writeln("cd: HOME is not set"); mem.lastStatus = 1; return; }
        if (target == "-") {
            auto old = mem.getCell("OLDPWD");
            if (old is null || old.value.kind != ValueKind.stringValue) {
                mem.errorFile.writeln("cd: OLDPWD is not set"); mem.lastStatus = 1; return;
            }
            target = old.value.stringValue;
            mem.outputFile.writeln(target);
        }
        import std.path : buildNormalizedPath, isAbsolute;
        import std.file : getcwd;
        auto previousDirectory = mem.workingDirectory;
        auto destination = isAbsolute(target) ? buildNormalizedPath(target) : buildNormalizedPath(previousDirectory, target);
        if (physical) destination = physicalDirectory(isAbsolute(target) ? target : previousDirectory ~ "/" ~ target);
        try {
            chdir(destination);
        } catch (Exception error) {
            mem.errorFile.writeln("cd: ", error.msg);
            mem.lastStatus = 1;
            return;
        }
        if (hasBlock) {
            mem.directoryStack.push(destination);
            bool restoreFailed, restored;
            void restoreDirectory() {
                if (restored) return;
                restored = true;
                restoreFailed = !popDirectory(mem, "cd");
            }
            scope (exit) restoreDirectory();
            setDirectory(mem, destination);
            .executeProgram(body, mem, bodyAttributeScope, bodyMultiline);
            // Restore before deciding the builtin's status. Nonlocal control
            // still runs the same cleanup through the scope guard.
            restoreDirectory();
            mem.lastStatus = restoreFailed ? 1 : 0;
        } else {
            setDirectory(mem, destination);
            mem.setGlobal("OLDPWD", Value.str(previousDirectory));
            mem.get("ENV").dictValue.set("OLDPWD", Value.str(previousDirectory));
            mem.directoryStack.replace(destination);
            mem.lastStatus = 0;
        }
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
        if (returnMode_ == ReturnMode.functionValue) {
            if (current_.kind != TokenKind.leftParen)
                throw new ParseError("func return requires one typed argument in parentheses");
            auto arguments = parseTypedArguments("(" ~ collectParenthesizedExpression() ~ ")", true);
            auto expression = arguments.singleExpression();
            if (!isEndStatement(current_.kind)) throw new ParseError("unexpected argument after typed return");
            if (syntaxOnly_) return;
            auto optionNumbers = mem.options.pushExpression();
            scope (exit) mem.options.pop(optionNumbers);
            throw new FunctionReturn(expression.eval(mem));
        }
        if (current_.kind == TokenKind.leftParen)
            throw new ParseError("typed return is only allowed inside func");
        string[] words;
        while (!isEndStatement(current_.kind)) words ~= readScalarWord(mem).text();
        if (words.length > 1) throw new ParseError("return accepts at most one status word");
        if (syntaxOnly_) return;
        int status = mem.lastStatus;
        if (words.length) {
            try { status = to!int(words[0]); }
            catch (Exception error) { throw new FatalRuntimeError("return status must be an integer"); }
        }
        mem.trace.control("return", status, mem);
        throw new ProcReturn(status & 255);
    }

    private void parseCase(Memory mem) {
        advance(); // case
        if (current_.kind != TokenKind.leftParen) {
            parseOldCase(mem);
            return;
        }
        string subjectSource;
        CaseArm[] arms;
        try {
            subjectSource = collectParenthesizedExpression();
            validateExpression(subjectSource);
            require(TokenKind.leftBrace, "{");
            skipCaseNewlines();
            while (current_.kind != TokenKind.rightBrace) {
                if (current_.kind == TokenKind.eof) throw new ParseError("Unterminated case statement");
                CaseArm arm;
                if (current_.kind == TokenKind.leftParen) {
                    arm.kind = CasePatternKind.expressions;
                    while (true) {
                        auto pattern = collectParenthesizedExpression();
                        if (pattern == "else") {
                            if (arm.patterns.length) throw new ParseError("(else) must be the sole pattern");
                            arm.kind = CasePatternKind.otherwise;
                        } else {
                            validateExpression(pattern);
                            arm.patterns ~= pattern;
                        }
                        skipCaseNewlines();
                        if (current_.kind != TokenKind.pipe) break;
                        if (arm.kind == CasePatternKind.otherwise) throw new ParseError("(else) cannot have alternatives");
                        advance();
                        skipCaseNewlines();
                        if (current_.kind != TokenKind.leftParen)
                            throw new ParseError("Expression case patterns must be parenthesized");
                    }
                } else if (current_.kind == TokenKind.slash) {
                    arm.kind = CasePatternKind.eggex;
                    auto start = current_.offset;
                    arm.regex = parseEggex(source_[start .. $], parserOptions_);
                    auto end = start + arm.regex.endOffset;
                    while (current_.kind != TokenKind.eof && current_.offset < end) advance();
                    skipCaseNewlines();
                } else {
                    arm.kind = CasePatternKind.words;
                    while (true) {
                        arm.patterns ~= collectPatternWord();
                        skipCaseNewlines();
                        if (current_.kind != TokenKind.pipe) break;
                        advance();
                        skipCaseNewlines();
                        if (current_.kind == TokenKind.leftParen || current_.kind == TokenKind.slash)
                            throw new ParseError("Word case patterns cannot mix with expressions or Eggex");
                    }
                }
                arm.body = collectBlock();
                // Even unreachable bodies and patterns must have valid syntax.
                parseProgram(arm.body);
                arms ~= arm;
                skipCaseNewlines();
            }
            advance(); // }
        } catch (YshError error) {
            if (error.status == 2) throw error;
            throw new ParseError(error.msg);
        }
        if (!syntaxOnly_) executeCase(evaluate(subjectSource, mem), arms, mem);
    }

    private void executeCase(Value subject, CaseArm[] arms, Memory mem) {
        int status;
        bool fallThrough;
        foreach (arm; arms) {
            bool selected = fallThrough;
            if (!fallThrough) {
                final switch (arm.kind) {
            case CasePatternKind.otherwise: selected = true; break;
            case CasePatternKind.expressions:
                foreach (pattern; arm.patterns) {
                    if (exactlyEqual(evaluate(pattern, mem), subject)) { selected = true; break; }
                }
                break;
            case CasePatternKind.words:
                if (subject.kind != ValueKind.stringValue) break;
                foreach (pattern; arm.patterns) {
                    auto parser = new ProgramParser(pattern);
                    auto word = parser.readScalarWord(mem, true);
                    if (matchesShellPattern(word, subject.stringValue, mem.options.get("nocasematch"))) {
                        selected = true;
                        break;
                    }
                }
                break;
            case CasePatternKind.eggex: selected = arm.regex.matches(subject, mem); break;
                }
            }
            if (selected) {
                executeProgram(arm.body, mem);
                status = mem.lastStatus;
                if (arm.terminator == CaseTerminator.stop) return;
            }
            fallThrough = selected && arm.terminator == CaseTerminator.fallThrough;
        }
        // Pattern substitutions may change $?. They do not replace the
        // status of the last selected action (or zero when none matched).
        mem.lastStatus = status;
    }

    private string collectPatternWord(bool pattern = true) {
        auto start = current_.offset;
        auto previousMode = syntaxOnly_;
        syntaxOnly_ = true;
        scope (exit) syntaxOnly_ = previousMode;
        readScalarWord(null, pattern);
        return source_[start .. current_.offset];
    }

    private void parseOldCase(Memory mem) {
        string subjectSource;
        CaseArm[] arms;
        try {
            subjectSource = collectPatternWord(false);
            skipCaseNewlines();
            require(TokenKind.inKeyword, "in");
            skipCaseNewlines();
            while (current_.kind != TokenKind.esacKeyword) {
                if (current_.kind == TokenKind.eof) throw new ParseError("Unterminated old case statement");
                CaseArm arm;
                arm.kind = CasePatternKind.words;
                if (current_.kind == TokenKind.leftParen) advance();
                while (true) {
                    arm.patterns ~= collectPatternWord();
                    if (current_.kind != TokenKind.pipe) break;
                    advance();
                }
                require(TokenKind.rightParen, ")");
                skipCaseNewlines();
                arm.body = collectOldCaseBody();
                parseProgram(arm.body);
                if (current_.kind == TokenKind.semicolon) {
                    auto offset = current_.offset;
                    advance();
                    if (current_.offset != offset + 1)
                        throw new ParseError("Expected ;; or ;& after old case arm");
                    if (current_.kind == TokenKind.amp) {
                        arm.terminator = CaseTerminator.fallThrough;
                        advance();
                    } else {
                        require(TokenKind.semicolon, ";;");
                        if (current_.kind == TokenKind.amp && current_.offset == offset + 2) {
                            arm.terminator = CaseTerminator.retest;
                            advance();
                        }
                    }
                } else if (current_.kind != TokenKind.esacKeyword) {
                    throw new ParseError("Expected ;; or esac after old case arm");
                }
                arms ~= arm;
                skipCaseNewlines();
            }
            advance();
        } catch (YshError error) {
            if (error.status == 2) throw error;
            throw new ParseError(error.msg);
        }
        if (!syntaxOnly_) {
            auto subject = (new ProgramParser(subjectSource)).readScalarWord(mem).text();
            executeCase(Value.str(subject), arms, mem);
        }
    }

    private string collectOldCaseBody() {
        auto start = current_.offset;
        int depth;
        bool commandStart = true;
        while (current_.kind != TokenKind.eof) {
            if (depth == 0) {
                if (commandStart && current_.kind == TokenKind.esacKeyword) break;
                if (current_.kind == TokenKind.semicolon) {
                    auto next = lexer_.peek();
                    if (next.offset == current_.offset + 1 &&
                            (next.kind == TokenKind.semicolon || next.kind == TokenKind.amp)) break;
                }
                if (commandStart && current_.kind == TokenKind.caseKeyword) {
                    // Let the structural parser consume nested case syntax;
                    // its pattern ')' is not a command grouping delimiter.
                    auto previousMode = syntaxOnly_;
                    syntaxOnly_ = true;
                    { scope (exit) syntaxOnly_ = previousMode; parseCase(null); }
                    commandStart = false;
                    continue;
                }
            }
            auto kind = current_.kind;
            adjustDepth(depth, current_);
            advance();
            commandStart = isEndStatement(kind) || kind == TokenKind.pipe ||
                kind == TokenKind.andIf || kind == TokenKind.orIf;
        }
        return source_[start .. current_.offset];
    }

    private void skipCaseNewlines() {
        while (current_.kind == TokenKind.newline) advance();
    }

    private void parseIf(Memory mem) {
        auto command = parseIfCommand();
        {
            for (auto arm = command; arm !is null; arm = arm.elseIf) {
                if (arm.expressionCondition) validateExpression(arm.conditionSource);
                else parseProgram(arm.conditionSource);
                parseProgram(arm.thenSource);
                if (arm.hasElse && arm.elseIf is null) parseProgram(arm.elseSource);
            }
        }
        if (syntaxOnly_) return;
        while (command !is null) {
            bool selected;
            if (command.expressionCondition) {
                selected = toBool(evaluate(command.conditionSource, mem));
            } else {
                ++mem.errexitSuppression;
                scope (exit) --mem.errexitSuppression;
                executeProgram(command.conditionSource, mem);
                selected = mem.lastStatus == 0;
            }
            if (selected) {
                executeProgram(command.thenSource, mem);
                return;
            }
            if (command.elseIf !is null) {
                command = command.elseIf;
                continue;
            }
            if (command.hasElse) {
                executeProgram(command.elseSource, mem);
            } else {
                mem.lastStatus = 0;
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
        command.expressionCondition = current_.kind == TokenKind.leftParen &&
            !(current_.offset + 1 < source_.length && source_[current_.offset + 1] == '(');
        if (command.expressionCondition) {
            auto conditionStart = current_.offset;
            command.conditionSource = collectParenthesizedExpression();
            if (current_.kind != TokenKind.leftBrace) {
                command.expressionCondition = false;
                command.conditionSource = source_[conditionStart .. current_.offset];
                command.conditionSource ~= collectIfCondition(command.legacySyntax);
            }
        } else command.conditionSource = collectIfCondition(command.legacySyntax);
        if (command.legacySyntax) {
            if (!atRawWord("then")) throw new ParseError("Expected then");
            consumeRawWord("then");
            command.thenSource = collectLegacyIfBody();
            if (current_.kind == TokenKind.elifKeyword) {
                command.hasElse = true;
                command.elseIf = parseIfCommand();
                if (!command.elseIf.legacySyntax) throw new ParseError("Expected retained elif/then syntax");
                return command;
            }
            if (current_.kind == TokenKind.elseKeyword) {
                advance();
                command.hasElse = true;
                command.elseSource = collectLegacyIfBody();
            }
            if (!atRawWord("fi")) throw new ParseError("Expected fi");
            lastCompoundEnd_ = current_.offset + 2;
            consumeRawWord("fi");
            return command;
        }
        command.thenSource = collectBlock();
        lastCompoundEnd_ = lastBlockEnd_;

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
                lastCompoundEnd_ = lastBlockEnd_;
            }
        }
        return command;
    }

    private void moveTo(size_t offset, HereDocument[] pendingDocuments = []) {
        lexer_ = new Lexer(source_, true, offset, true, parserOptions_, pendingDocuments);
        lexer_.multiline = multiline_;
        current_ = lexer_.next();
    }

    private string collectIfCondition(out bool legacy, string keyword = "then") {
        auto start = current_.offset;
        auto scanner = new CommandScanner(source_[start .. $], returnMode_, parserOptions_, multiline_);
        int depth;
        bool commandStart = true;
        while (true) {
            auto token = scanner.next();
            if (token.kind == TokenKind.eof) throw new ParseError("Unterminated if condition");
            if (!depth && token.kind == TokenKind.leftBrace) {
                auto result = strip(source_[start .. start + token.offset]);
                if (!result.length) throw new ParseError("Empty if condition");
                legacy = false;
                moveTo(start + token.offset);
                return result;
            }
            if (!depth && commandStart && token.kind == TokenKind.name && token.text == keyword) {
                auto result = strip(source_[start .. start + token.offset]);
                if (!result.length) throw new ParseError("Empty if condition");
                auto content = new Lexer(result, true, 0, true, parserOptions_);
                Token first;
                do { first = content.next(); } while (first.kind == TokenKind.newline || first.kind == TokenKind.semicolon);
                if (first.kind == TokenKind.eof) throw new ParseError("Empty if condition");
                legacy = true;
                moveTo(start + token.offset);
                return result;
            }
            adjustDepth(depth, token);
            commandStart = token.kind == TokenKind.newline || token.kind == TokenKind.semicolon ||
                token.kind == TokenKind.andIf || token.kind == TokenKind.orIf || token.kind == TokenKind.pipe;
        }
    }

    private string collectLegacyIfBody() {
        auto start = current_.offset;
        auto scanner = new CommandScanner(source_[start .. $], returnMode_, parserOptions_, multiline_);
        int depth;
        bool commandStart = true;
        while (true) {
            auto token = scanner.next();
            if (token.kind == TokenKind.eof) throw new ParseError("Unterminated retained if statement");
            if (!depth && commandStart && (token.kind == TokenKind.elifKeyword || token.kind == TokenKind.elseKeyword ||
                    (token.kind == TokenKind.name && token.text == "fi"))) {
                auto result = source_[start .. start + token.offset];
                auto content = new Lexer(result, true, 0, true, parserOptions_);
                Token first;
                do { first = content.next(); } while (first.kind == TokenKind.newline || first.kind == TokenKind.semicolon);
                if (first.kind == TokenKind.eof) throw new ParseError("Empty retained if body");
                moveTo(start + token.offset);
                return result;
            }
            adjustDepth(depth, token);
            commandStart = token.kind == TokenKind.newline || token.kind == TokenKind.semicolon ||
                token.kind == TokenKind.andIf || token.kind == TokenKind.orIf || token.kind == TokenKind.pipe;
        }
    }

    private bool atConditionalEnd() {
        if (current_.kind != TokenKind.rightBracket) return false;
        auto next = lexer_.peek();
        return next.kind == TokenKind.rightBracket && next.offset == current_.offset + 1;
    }

    private string collectConditionalWord(bool regex = false) {
        if (isEndStatement(current_.kind) || atConditionalEnd()) throw new ParseError("Expected conditional operand");
        auto start = current_.offset;
        readScalarWord(null, true, regex);
        return strip(source_[start .. current_.offset]);
    }

    private ShellCondition parseConditionOr() {
        auto node = parseConditionAnd();
        while (current_.kind == TokenKind.orIf) {
            advance();
            auto combined = new ShellCondition(ConditionKind.disjunction);
            combined.first = node;
            combined.second = parseConditionAnd();
            node = combined;
        }
        return node;
    }

    private ShellCondition parseConditionAnd() {
        auto node = parseConditionPrimary();
        while (current_.kind == TokenKind.andIf) {
            advance();
            auto combined = new ShellCondition(ConditionKind.conjunction);
            combined.first = node;
            combined.second = parseConditionPrimary();
            node = combined;
        }
        return node;
    }

    private ShellCondition parseConditionPrimary() {
        if (atRawWord("!")) {
            consumeRawWord("!");
            auto node = new ShellCondition(ConditionKind.negate);
            node.first = parseConditionPrimary();
            return node;
        }
        if (current_.kind == TokenKind.leftParen) {
            advance();
            auto node = parseConditionOr();
            if (current_.kind != TokenKind.rightParen) throw new ParseError("Expected ) in conditional");
            advance();
            return node;
        }
        foreach (operation; ["-n", "-z", "-v", "-o", "-t", "-e", "-a", "-f", "-d", "-L", "-h", "-s", "-r", "-w", "-x"]) {
            if (!atRawWord(operation)) continue;
            consumeRawWord(operation);
            auto node = new ShellCondition(ConditionKind.unary);
            node.operation = operation;
            node.firstWord = collectConditionalWord();
            return node;
        }
        auto word = collectConditionalWord();
        foreach (operation; ["=~", "==", "!=", "=", "<", ">", "-eq", "-ne", "-lt", "-le", "-gt", "-ge"]) {
            if (!atRawWord(operation)) continue;
            consumeRawWord(operation);
            auto node = new ShellCondition(ConditionKind.binary);
            node.operation = operation;
            node.firstWord = word;
            node.secondWord = collectConditionalWord(operation == "=~");
            return node;
        }
        auto node = new ShellCondition(ConditionKind.word);
        node.firstWord = word;
        return node;
    }

    private void parseDoubleBracket(Memory mem) {
        auto first = current_.offset;
        if (first + 1 >= source_.length || source_[first + 1] != '[') {
            if (syntaxOnly_) parseCommandWords();
            else parseCommandInvocation(mem);
            return;
        }
        advance();
        if (current_.kind != TokenKind.leftBracket || current_.offset != first + 1)
            throw new ParseError("Expected [[");
        advance();
        bool previousSyntax = syntaxOnly_;
        syntaxOnly_ = true;
        scope (exit) syntaxOnly_ = previousSyntax;
        ShellCondition condition;
        if (atConditionalEnd()) {
            condition = new ShellCondition(ConditionKind.word);
            condition.firstWord = "''";
        } else condition = parseConditionOr();
        if (!atConditionalEnd()) throw new ParseError("Expected ]] after conditional");
        auto end = current_.offset + 2;
        // ERE bracket expressions have their own grammar. Finish the command
        // lexical context instead of carrying their delimiter counts onward.
        lexer_ = new Lexer(source_, true, end, true, parserOptions_);
        lexer_.multiline = multiline_;
        current_ = lexer_.next();
        if (previousSyntax) return;
        mem.trace.sourceCode(source_[first .. end], mem);
        try { mem.lastStatus = condition.eval(mem) ? 0 : 1; }
        catch (EreError error) {
            mem.errorFile.writeln(error.msg);
            mem.lastStatus = 2;
        }
    }

    private string collectDoBody() {
        auto start = current_.offset;
        auto scanner = new CommandScanner(source_[start .. $], returnMode_, parserOptions_, multiline_);
        int depth;
        bool commandStart = true;
        while (true) {
            auto token = scanner.next();
            if (token.kind == TokenKind.eof) throw new ParseError("Unterminated do/done loop");
            if (!depth && commandStart && token.kind == TokenKind.name && token.text == "done") {
                auto body = source_[start .. start + token.offset];
                auto content = new Lexer(body, true, 0, true, parserOptions_);
                Token first;
                do { first = content.next(); } while (first.kind == TokenKind.newline || first.kind == TokenKind.semicolon);
                if (first.kind == TokenKind.eof) throw new ParseError("Empty do/done loop body");
                moveTo(start + token.offset);
                lastCompoundEnd_ = current_.offset + 4;
                consumeRawWord("done");
                return body;
            }
            adjustDepth(depth, token);
            commandStart = token.kind == TokenKind.newline || token.kind == TokenKind.semicolon ||
                token.kind == TokenKind.andIf || token.kind == TokenKind.orIf || token.kind == TokenKind.pipe;
        }
    }

    private WhileCommand parseWhileCommand() {
        WhileCommand command;
        command.negated = current_.text == "until";
        advance();
        bool legacy;
        command.expressionCondition = current_.kind == TokenKind.leftParen &&
            !(current_.offset + 1 < source_.length && source_[current_.offset + 1] == '(');
        if (command.expressionCondition) {
            auto start = current_.offset;
            command.conditionSource = collectParenthesizedExpression();
            if (current_.kind != TokenKind.leftBrace) {
                command.expressionCondition = false;
                command.conditionSource = source_[start .. current_.offset] ~ collectIfCondition(legacy, "do");
            }
        } else command.conditionSource = collectIfCondition(legacy, "do");
        if (legacy) {
            consumeRawWord("do");
            command.bodySource = collectDoBody();
        } else {
            command.bodySource = collectBlock();
            lastCompoundEnd_ = lastBlockEnd_;
        }
        return command;
    }

    private void parseWhile(Memory mem) {
        auto command = parseWhileCommand();
        auto conditionSource = command.conditionSource;
        auto bodySource = command.bodySource;
        bool expressionCondition = command.expressionCondition;
        if (expressionCondition) validateExpression(conditionSource);
        else parseProgram(conditionSource);
        parseProgram(bodySource);
        if (syntaxOnly_) return;
        int bodyStatus;
        while (true) {
            bool selected;
            if (expressionCondition) {
                selected = toBool(evaluate(conditionSource, mem));
            } else {
                ++mem.errexitSuppression;
                scope (exit) --mem.errexitSuppression;
                executeProgram(conditionSource, mem);
                selected = mem.lastStatus == 0;
            }
            if (command.negated) selected = !selected;
            if (!selected) break;
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
                    bodyStatus = 0;
                    break;
                }
            }
            bodyStatus = mem.lastStatus;
        }
        mem.lastStatus = bodyStatus;
    }

    private ForCommand parseForCommand() {
        ForCommand command;
        advance(); // for
        if (current_.kind == TokenKind.leftParen && current_.offset + 1 < source_.length &&
                source_[current_.offset + 1] == '(') {
            if (parserOptions_ !is null && parserOptions_.get("no_parse_dparen"))
                throw new ParseError("Shell arithmetic for is disabled (no_parse_dparen)");
            auto start = current_.offset;
            auto end = shellArithmeticEnd(source_, start);
            auto parts = parseShellArithmeticFor(source_[start + 2 .. end - 2], parserOptions_);
            command.arithmeticInit = parts[0];
            command.arithmeticCondition = parts[1];
            command.arithmeticStep = parts[2];
            moveTo(end);
            skipEndStatements();
            if (current_.kind == TokenKind.leftBrace) {
                command.bodySource = collectBlock();
                lastCompoundEnd_ = lastBlockEnd_;
            } else {
                if (!atRawWord("do")) throw new ParseError("Expected do or { after arithmetic for header");
                consumeRawWord("do");
                command.legacySyntax = true;
                command.bodySource = collectDoBody();
            }
            return command;
        }
        while (true) {
            if (current_.kind != TokenKind.name) {
                throw new ParseError(format("expected loop variable at byte %s", current_.offset));
            }
            command.names ~= current_.text;
            advance();
            if (current_.kind != TokenKind.comma) {
                break;
            }
            advance();
        }
        if (command.names.length > 3) {
            throw new ParseError("for loops support at most three loop variables");
        }
        if (current_.kind == TokenKind.inKeyword) advance();
        else {
            command.implicitArguments = true;
            if (!isEndStatement(current_.kind) && !atRawWord("do")) throw new ParseError("Expected in or do after loop variable");
        }
        if (current_.kind != TokenKind.leftParen) {
            if (command.names.length > 2) {
                throw new ParseError("Shell-word for loops accept at most two variables");
            }
            bool previousSyntax = syntaxOnly_;
            syntaxOnly_ = true;
            scope (exit) syntaxOnly_ = previousSyntax;
            while (!command.implicitArguments && current_.kind != TokenKind.leftBrace && !isEndStatement(current_.kind)) {
                auto begin = current_.offset;
                readCommandWord(null);
                command.wordSources ~= strip(source_[begin .. current_.offset]);
            }
            auto firstWordSource = command.wordSources.length ? command.wordSources[0] : "";
            bool bareIdentifier = firstWordSource.length && asciiIdentifierStart(firstWordSource[0]);
            foreach (ch; firstWordSource) if (!asciiIdentifierContinue(ch)) bareIdentifier = false;
            if (command.wordSources.length == 1 && bareIdentifier && parserOptions_ !is null && parserOptions_.get("no_parse_bare_word"))
                throw new ParseError("Surround this loop word with parens or quotes (no_parse_bare_word)");
        } else {
            command.expressionIterable = true;
            command.iterableSource = collectParenthesizedExpression();
        }
        if (current_.kind == TokenKind.leftBrace) {
            command.bodySource = collectBlock();
            lastCompoundEnd_ = lastBlockEnd_;
        } else {
            if (command.expressionIterable) throw new ParseError("Expression for requires a brace body");
            skipEndStatements();
            if (!atRawWord("do")) throw new ParseError("Expected do after for header");
            consumeRawWord("do");
            command.legacySyntax = true;
            command.bodySource = collectDoBody();
        }
        return command;
    }

    private void parseFor(Memory mem) {
        auto command = parseForCommand();
        auto names = command.names;
        auto bodySource = command.bodySource;
        parseProgram(bodySource);
        if (command.expressionIterable) validateExpression(command.iterableSource);
        if (syntaxOnly_) return;
        if (command.arithmeticInit !is null) {
            command.arithmeticInit.evaluate(mem);
            int bodyStatus;
            mem.enterLoop();
            scope (exit) mem.leaveLoop();
            while (command.arithmeticCondition.evaluate(mem) != 0) {
                try { executeProgram(bodySource, mem); }
                catch (LoopControl control) {
                    if (control.levels > 1) { --control.levels; throw control; }
                    if (control.shouldBreak) { bodyStatus = 0; break; }
                }
                bodyStatus = mem.lastStatus;
                command.arithmeticStep.evaluate(mem);
            }
            mem.lastStatus = bodyStatus;
            return;
        }
        if (!command.expressionIterable) {
            string[] words;
            if (command.implicitArguments) words = mem.shellArguments.dup;
            else foreach (source; command.wordSources) {
                auto parser = new ProgramParser(source, false, returnMode_, true, parserOptions_);
                words ~= parser.readCommandWord(mem);
                if (parser.current_.kind != TokenKind.eof) throw new ParseError("Unexpected for word input");
            }
            int bodyStatus;
            mem.enterLoop();
            scope (exit) mem.leaveLoop();
            foreach (index, word; words) {
                Value[] bindings = names.length == 1
                    ? [Value.str(word)]
                    : [Value.integer(cast(long) index), Value.str(word)];
                if (command.legacySyntax) foreach (offset, name; names) mem.setShellVar(name, bindings[offset]);
                else bindLoopVariables(names, bindings, mem);
                try {
                    executeProgram(bodySource, mem);
                } catch (LoopControl control) {
                if (control.levels > 1) {
                    --control.levels;
                    throw control;
                }
                    if (control.shouldBreak) {
                        bodyStatus = 0;
                        break;
                    }
                }
                bodyStatus = mem.lastStatus;
            }
            mem.lastStatus = bodyStatus;
            return;
        }

        auto iterable = evaluate(command.iterableSource, mem);
        mem.lastStatus = 0;

        mem.enterLoop();
        scope (exit) mem.leaveLoop();
        switch (iterable.kind) {
        case ValueKind.stdinValue:
            if (names.length > 2) throw new UsageError("Stdin iteration expects at most 2 loop variables");
            // Each iteration owns a stream snapshot, not the singleton value.
            // Body redirects may temporarily change Memory.inputFile.
            auto input = mem.inputFile;
            long lineIndex;
            while (true) {
                string text;
                import std.exception : ErrnoException;
                import core.stdc.errno : EINTR;
                try { text = input.readln(); }
                catch (ErrnoException error) {
                    if (error.errno == EINTR) continue;
                    throw new FatalRuntimeError("Error reading stdin: " ~ error.msg);
                }
                if (!text.length) break;
                if (text[$ - 1] == '\n') text = text[0 .. $ - 1];
                auto bindings = names.length == 1 ? [Value.str(text)] : [Value.integer(lineIndex), Value.str(text)];
                bindLoopVariables(names, bindings, mem);
                try { executeProgram(bodySource, mem); }
                catch (LoopControl control) {
                    if (control.levels > 1) { --control.levels; throw control; }
                    if (control.shouldBreak) break;
                }
                ++lineIndex;
            }
            break;
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
    private void parseJson(Memory mem) {
        auto encoding = current_.text == "json8" ? WriteEncoding.j8 : WriteEncoding.json;
        bool hasTyped;
        advance(); // json
        string[] words;
        while (!isEndStatement(current_.kind) && current_.kind != TokenKind.leftParen) {
            words ~= readCommandWord(mem);
        }
        hasTyped = current_.kind == TokenKind.leftParen;
        auto arguments = hasTyped
            ? parseTypedArguments("(" ~ collectParenthesizedExpression(true) ~ ")", true)
            : parseTypedArguments("()", true);
        if (!isEndStatement(current_.kind)) throw new ParseError("Unexpected words after JSON typed arguments");
        if (!((words.length == 1 || (words.length == 2 && words[1] == "--")) &&
                (words[0] == "write" || words[0] == "read"))) {
            mem.errorFile.writeln("json: expected read or write with no word arguments");
            mem.lastStatus = 2;
            return;
        }
        auto values = arguments.eval(mem);
        if (words[0] == "read") {
            import yshd.data_decode : decodeDataValue, DataDecodeError;
            import yshd.state : FramePlace;
            import std.exception : ErrnoException;
            Value place;
            if (hasTyped) {
                if (values.positional.length != 1 || values.named.length || values.hasBlock ||
                        values.positional[0].kind != ValueKind.placeValue)
                    throw new YshTypeError("json read expects one Place argument");
                place = values.positional[0];
            } else place = Value.place(new FramePlace(mem.currentFrame, "_reply"));
            string contents;
            try {
                while (true) {
                    auto chunk = mem.inputFile.readln();
                    if (!chunk.length) break;
                    contents ~= chunk;
                }
                auto value = decodeDataValue(contents, encoding == WriteEncoding.j8);
                place.placeValue.assign(value);
            } catch (DataDecodeError error) {
                mem.errorFile.writeln("json read: ", error.msg);
                mem.lastStatus = 1;
                return;
            } catch (ErrnoException error) {
                mem.errorFile.writeln("json read: ", error.msg);
                mem.lastStatus = 1;
                return;
            }
            mem.lastStatus = 0;
            return;
        }
        if (values.positional.length != 1 || values.hasBlock)
            throw new YshTypeError("json write expects one typed argument");
        auto options = dataOptions(values.named, 2);
        // Buffer before writing so errors never leave an incomplete document.
        try {
            auto message = encodeDataValue(values.positional[0], encoding, options.space, options.typeErrors);
            mem.outputFile.writeln(message);
        } catch (DataEncodeError error) {
            mem.errorFile.writeln("json write: ", error.msg);
            mem.lastStatus = 1;
            return;
        }
        mem.lastStatus = 0;
    }

    private void parsePrettyPrint(Memory mem) {
        advance(); // pp
        if (current_.kind != TokenKind.name) throw new UsageError("pp: expected an action");
        auto action = current_.text;
        advance();
        if (action == "frame_vars_") {
            string[] names;
            foreach (name, cell; mem.currentFrame.cells) names ~= name;
            mem.outputFile.writeln("    [frame_vars_] ", names.join(" "));
            mem.lastStatus = 0;
            return;
        }
        if (action == "cell_") {
            string[] names;
            while (!isEndStatement(current_.kind)) names ~= readCommandWord(mem);
            mem.lastStatus = 0;
            foreach (name; names) {
                if (!name.length || !asciiIdentifierStart(name[0])) throw new UsageError("pp cell_: invalid variable name");
                foreach (ch; name) if (!asciiIdentifierContinue(ch)) throw new UsageError("pp cell_: invalid variable name");
                auto cell = mem.getCell(name);
                if (cell is null) {
                    mem.errorFile.writeln("pp: Couldn't find a variable named ", name);
                    mem.lastStatus = 1;
                } else mem.outputFile.writeln(prettyCell(name, cell.value, cell.readOnly, terminalWidth(mem.outputFile.fileno())));
            }
            return;
        }
        if (action != "value" && action != "test_" && action != "asdl_") throw new UsageError("pp: invalid action " ~ action);
        auto parsed = current_.kind == TokenKind.leftParen
            ? parseTypedArguments("(" ~ collectParenthesizedExpression(true) ~ ")", true)
            : parseTypedArguments("()", true);
        if (!isEndStatement(current_.kind)) throw new UsageError("pp: unexpected word arguments");
        auto values = parsed.eval(mem);
        if (values.positional.length != 1 || values.named.length || values.hasBlock)
            throw new YshTypeError("pp expects one typed argument");
        auto value = values.positional[0];
        if (action == "value") mem.outputFile.writeln(prettyValue(value, terminalWidth(mem.outputFile.fileno())));
        else if (action == "asdl_") mem.outputFile.writeln(asdlValue(value, terminalWidth(mem.outputFile.fileno())));
        else {
            if (value.kind <= ValueKind.dict || value.kind == ValueKind.objectValue) mem.outputFile.write("(", kindName(value), ")   ");
            mem.outputFile.writeln(encodeDataValue(value, WriteEncoding.j8, -1, false, true));
        }
        mem.lastStatus = 0;
    }

    private void runRead(string[] words, ParsedArguments parsed, bool hasBlock, Memory mem) {
        import yshd.read_builtin : runReadBuiltin;
        runReadBuiltin(words, parsed, hasBlock, mem);
    }

    private void parseTry(Memory mem) {
        advance(); // try
        auto body = collectBlock();

        auto error = Value.dict();
        auto optionNumbers = mem.options.expand("errexit");
        mem.options.push(optionNumbers, true);
        scope (exit) mem.options.pop(optionNumbers);
        auto savedSuppression = mem.errexitSuppression;
        mem.errexitSuppression = 0;
        scope (exit) mem.errexitSuppression = savedSuppression;
        try {
            .executeProgram(body, mem, false, multiline_);
            error.dictValue.set("code", Value.integer(0));
        } catch (Errexit caught) {
            error.dictValue.set("code", Value.integer(caught.status));
        } catch (StructuredError caught) {
            error = Value.dictRef(caught.properties);
        } catch (YshError caught) {
            // Syntax errors aren't runtime exceptions and aren't catchable.
            if (caught.status != 3) throw caught;
            error.dictValue.set("code", Value.integer(3));
        }
        mem.setGlobal("_error", error);
        mem.setGlobal("_status", error.dictValue.get("code"));
        mem.lastStatus = 0;
    }

    private void parseErrorBuiltin(Memory mem) {
        advance();
        string[] words;
        while (!isEndStatement(current_.kind) && current_.kind != TokenKind.leftParen)
            words ~= readCommandWord(mem);
        auto properties = new YshDict();
        int code = 10;
        if (current_.kind == TokenKind.leftParen) {
            auto parsed = parseTypedArguments("(" ~ collectParenthesizedExpression() ~ ")");
            // The reference checks the required word message before any typed
            // argument is evaluated, including an otherwise invalid code.
            if (words.length == 0) {
                mem.errorFile.writeln("ysh-d: error requires a message");
                mem.lastStatus = 2;
                return;
            }
            auto arguments = parsed.eval(mem);
            if (arguments.positional.length || arguments.hasBlock)
                throw new YshError("error accepts only named typed arguments");
            properties = arguments.named;
            auto codeValue = properties.find("code");
            if (codeValue !is null) {
                if (codeValue.kind != ValueKind.integer) throw new YshError("error code must be Int");
                code = to!int(codeValue.integerValue);
                properties.erase("code");
            }
        }
        if (words.length == 0 || code == 0) {
            mem.errorFile.writeln("ysh-d: error requires a message and a nonzero code");
            mem.lastStatus = 2;
            return;
        }
        throw new StructuredError(code, words[0], properties);
    }

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
        mem.lastStatus = 0;
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
        mem.lastStatus = 0;
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

    private void runWrite(string[] words, Memory mem) {
        string separator = "\n", ending = "\n";
        bool noNewline, jsonEncoding, j8Encoding;
        string[] arguments;
        bool flags = true;
        for (size_t index; index < words.length; ++index) {
            auto word = words[index];
            if (flags && word == "--") { flags = false; continue; }
            if (flags && (word == "--sep" || word == "--end")) {
                if (++index == words.length) throw new UsageError(word ~ " requires an argument");
                if (word == "--sep") separator = words[index];
                else ending = words[index];
            } else if (flags && word == "--json") jsonEncoding = true;
            else if (flags && word == "--j8") j8Encoding = true;
            else if (flags && word == "-n") noNewline = true;
            else if (flags && word.length > 1 && word[0] == '-') throw new UsageError("write: invalid flag " ~ word);
            else { flags = false; arguments ~= word; }
        }
        if (noNewline) ending = "";
        auto encoding = jsonEncoding ? WriteEncoding.json : (j8Encoding ? WriteEncoding.j8 : WriteEncoding.plain);
        mem.outputFile.write(renderWrite(arguments, separator, ending, encoding));
        mem.lastStatus = 0;
    }

    private void runEcho(string[] words, Memory mem) {
        bool noNewline, interpretEscapes;
        size_t index;
        for (; index < words.length; ++index) {
            auto word = words[index];
            if (word.length < 2 || word[0] != '-') break;
            bool valid = true;
            foreach (flag; word[1 .. $]) if (flag != 'e' && flag != 'n') valid = false;
            if (!valid) break;
            foreach (flag; word[1 .. $]) {
                if (flag == 'n') noNewline = true;
                else interpretEscapes = true;
            }
        }
        mem.outputFile.write(renderEcho(words[index .. $], noNewline, interpretEscapes));
        mem.lastStatus = 0;
    }

    private void runType(string[] words, Memory mem) {
        bool all, pathOnly, forcePath, shortKind, skipFunctions;
        size_t index;
        for (; index < words.length; ++index) {
            auto word = words[index];
            if (word == "--") { ++index; break; }
            if (word.length < 2 || word[0] != '-') break;
            foreach (flag; word[1 .. $]) {
                switch (flag) {
                case 'a': all = true; break;
                case 'p': pathOnly = true; break;
                case 'P': forcePath = true; break;
                case 't': shortKind = true; break;
                case 'f': skipFunctions = true; break;
                default: throw new UsageError("type: invalid flag " ~ word);
                }
            }
        }
        mem.lastStatus = 0;
        foreach (name; words[index .. $]) {
            if (forcePath) {
                auto paths = executablePaths(name, mem.getEnv("PATH"), all);
                foreach (path; paths) mem.outputFile.writeln(path);
                if (!paths.length) mem.lastStatus = 1;
                continue;
            }
            auto resolutions = resolveCommand(name, mem, all, !skipFunctions);
            if (!resolutions.length) {
                if (!shortKind) mem.errorFile.writeln(name, ": not found");
                mem.lastStatus = 1;
                continue;
            }
            foreach (resolution; all ? resolutions : resolutions[0 .. 1]) {
                if (shortKind) mem.outputFile.writeln(resolution.kind);
                else if (pathOnly) { if (resolution.kind == "file") mem.outputFile.writeln(resolution.detail); }
                else {
                    printResolution(resolution, mem);
                    if (resolution.kind == "function") {
                        auto functionValue = mem.builtins.shellFunctions.get(name);
                        auto functionBody = (cast(YshProc)functionValue.callableValue).bodySource;
                        mem.outputFile.writeln(name, " () \n{\n", functionBody, "\n}");
                    }
                }
            }
        }
    }

    private void runInvokeShow(string[] names, Memory mem) {
        import yshd.command_lookup : CommandResolution;
        import yshd.pretty : encodeYshString;
        string tableWord(string word) {
            bool bare = word.length != 0;
            foreach (ch; word) if (!asciiIdentifierContinue(ch) && "-./".indexOf(ch) < 0) bare = false;
            return bare ? word : encodeYshString(word);
        }
        mem.outputFile.write(format("%-8s%-12s%-12s%s\n", "#.qtt8", "name", "kind", "detail"));
        foreach (name; names) {
            auto resolutions = resolveCommand(name, mem, true, true, true);
            if (!resolutions.length) resolutions ~= CommandResolution(name, "-", "-");
            foreach (resolution; resolutions) {
                auto kind = resolution.kind == "function" ? "sh-func" : resolution.kind == "file" ? "extern" : resolution.kind;
                mem.outputFile.write(format("%-8s%-12s%-12s%s\n", "", tableWord(name), kind,
                    resolution.detail.length ? tableWord(resolution.detail) : "-"));
            }
        }
        mem.lastStatus = 0;
    }

    private string[] readCommandWord(Memory mem, bool assignmentPosition = false) {
        lastWordTriple_ = false;
        lastWordStatic_ = true;
        if (current_.kind == TokenKind.doubleQuoted && current_.text == "$@") {
            lastWordStatic_ = false;
            advance();
            return syntaxOnly_ ? [] : mem.shellArguments.dup;
        }
        if (current_.kind == TokenKind.doubleQuoted && current_.text.length > 6 &&
                current_.text[0 .. 2] == "${" && current_.text[$ - 4 .. $] == "[@]}" &&
                current_.text != "${BASH_REMATCH[@]}") {
            lastWordStatic_ = false;
            auto name = current_.text[2 .. $ - 4];
            advance();
            if (syntaxOnly_) return [];
            auto value = mem.get(name);
            if (value.kind != ValueKind.bashArrayValue && value.kind != ValueKind.bashAssocValue)
                throw new YshTypeError("Shell array expansion expects BashArray or BashAssoc");
            import yshd.value : shellArrayValues;
            return shellArrayValues(value);
        }
        if (current_.kind == TokenKind.doubleQuoted && current_.text == "${BASH_REMATCH[@]}") {
            lastWordStatic_ = false;
            advance();
            if (syntaxOnly_) return [""];
            string[] result;
            auto match = mem.regexMatch;
            if (match !is null) foreach (index, start; match.starts)
                result ~= start < 0 ? "" : match.subject[start .. match.ends[index]];
            return result;
        }
        if (current_.kind == TokenKind.at) {
            lastWordStatic_ = false;
            return parseArraySplice(mem);
        }
        bool assignment;
        if (assignmentPosition && current_.kind == TokenKind.name) {
            auto end = current_.offset;
            while (end < source_.length && asciiIdentifierContinue(source_[end])) ++end;
            assignment = end < source_.length && source_[end] == '=';
        }
        auto word = readScalarWord(mem);
        if (syntaxOnly_ || assignment) return [word.text()];
        import yshd.pattern : expandShellWord;
        return expandShellWord(word, mem, lastWordStatic_);
    }

    private ScalarWord readScalarWord(Memory mem, bool pattern = false, bool regex = false) {
        auto end = current_.offset;
        ScalarWord result;
        bool consumed;
        size_t parts;
        bool tripleQuoted;
        while (true) {
            // The lexer removes a backslash-newline, including in a word.
            while (end + 1 < source_.length && source_[end .. end + 2] == "\\\n") end += 2;
            bool patternToken = pattern && (current_.kind == TokenKind.star ||
                current_.kind == TokenKind.starStar || current_.kind == TokenKind.leftBracket ||
                current_.kind == TokenKind.rightBracket || current_.kind == TokenKind.caret ||
                current_.kind == TokenKind.bang || current_.kind == TokenKind.percent ||
                current_.kind == TokenKind.tilde);
            if (current_.offset != end || !(isCommandWordToken(current_.kind) || patternToken ||
                    (regex && !isEndStatement(current_.kind)))) break;
            ++parts;
            if ((current_.kind == TokenKind.stringValue || current_.kind == TokenKind.doubleQuoted) &&
                    lexer_.offset - current_.offset >= 6) {
                auto raw = source_[current_.offset .. lexer_.offset];
                if (raw[0 .. 3] == "'''" || raw[0 .. 3] == "\"\"\"" ||
                        (raw.length >= 7 && raw[1 .. 4] == "'''")) tripleQuoted = true;
            }
            if (current_.kind == TokenKind.charValue) {
                result.append(current_.text, true);
                end = lexer_.offset;
                consumed = true;
                advance();
            } else if (current_.kind == TokenKind.stringValue) {
                result.append(current_.text, true);
                end = lexer_.offset;
                consumed = true;
                advance();
            } else if (current_.kind == TokenKind.doubleQuoted) {
                result.append(evaluateDoubleQuoted(current_.text, mem), true);
                end = lexer_.offset;
                consumed = true;
                advance();
            } else if (current_.kind == TokenKind.dollar) {
                lastWordStatic_ = false;
                auto start = current_.offset;
                size_t substitutionEnd;
                auto text = parseScalarSubstitution(mem, substitutionEnd);
                bool quoted = start + 1 < source_.length && (source_[start + 1] == '"' || source_[start + 1] == '[');
                if (quoted && substitutionEnd - start >= 7 && source_[start + 1 .. start + 4] == "\"\"\"")
                    tripleQuoted = true;
                result.append(text, quoted, !quoted);
                end = substitutionEnd;
                consumed = true;
            } else {
                end += literalTokenLength(current_);
                result.append(source_[current_.offset .. end], false);
                consumed = true;
                advance();
            }
        }
        if (!consumed) {
            throw new YshError(format("untranslated command word '%s' at byte %s",
                current_.text, current_.offset));
        }
        if (tripleQuoted && parts > 1) throw new ParseError("Unexpected parts after triple quoted string");
        lastWordTriple_ = tripleQuoted;
        return result;
    }

    private size_t characterEscapeEnd(size_t start) const {
        if (start + 1 >= source_.length || source_[start] != '\\') {
            throw new YshError("invalid character escape span");
        }

        auto escape = source_[start + 1];
        if (escape == 'y' || escape == 'x') {
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

    private string evaluateDoubleQuoted(string content, Memory mem, bool hereDocument = false) {
        string result;
        size_t position;
        while (position < content.length) {
            auto ch = content[position];
            if (ch == '\\' && position + 1 < content.length) {
                auto next = content[position + 1];
                if (next == '\n') { position += 2; continue; }
                if (next == '$' || next == '`' || (!hereDocument && next == '"') || next == '\\') {
                    result ~= next;
                    position += 2;
                    continue;
                }
                result ~= ch;
                ++position;
                continue;
            }

            if (ch == '$' && position + 1 < content.length &&
                    (asciiIdentifierStart(content[position + 1]) || "{[(0123456789?@!$#*-".indexOf(content[position + 1]) >= 0))
                lastWordStatic_ = false;

            if (ch == '$' && position + 1 < content.length &&
                    content[position + 1] == '{') {
                auto close = substitutionClose(content, position + 1, '{', '}');
                result ~= evaluateBracedParameter(content[position + 2 .. close], mem, true);
                position = close + 1;
                continue;
            }

            if (ch == '$' && position + 1 < content.length &&
                    content[position + 1] == '[') {
                auto close = substitutionClose(content, position + 1, '[', ']');
                auto expression = content[position + 2 .. close];
                if (parserOptions_ !is null && !parserOptions_.get("parse_ysh_expr_sub"))
                    result ~= arithmeticSubstitution(expression, mem);
                else if (syntaxOnly_) validateExpression(expression);
                else result ~= stringify(evaluate(expression, mem));
                position = close + 1;
                continue;
            }

            if (ch == '$' && position + 1 < content.length &&
                    content[position + 1] == '(') {
                if (position + 2 < content.length && content[position + 2] == '(') {
                    auto end = shellArithmeticEnd(content, position + 1);
                    result ~= arithmeticSubstitution(content[position + 3 .. end - 2], mem);
                    position = end;
                    continue;
                }
                auto close = substitutionClose(content, position + 1, '(', ')');
                auto command = content[position + 2 .. close];
                auto output = captureCommandOutput(command, mem);
                while (output.length != 0 && output[$ - 1] == '\n') {
                    output = output[0 .. $ - 1];
                }
                result ~= output;
                position = close + 1;
                continue;
            }

            if (ch == '$' && position + 1 < content.length &&
                    "0123456789?!@#$*-".indexOf(content[position + 1]) >= 0) {
                if (!syntaxOnly_) result ~= mem.simpleShellVariable(content[position + 1], true);
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
                if (!syntaxOnly_) result ~= mem.wordVariable(content[nameStart .. nameEnd]);
                position = nameEnd;
                continue;
            }

            result ~= ch;
            ++position;
        }
        return result;
    }

    private string evaluateBracedParameter(string parameter, Memory mem, bool quoted = false) {
        import std.path : CaseSensitive, globMatch;
        import std.utf : toUTF32;
        if (parameter.length && parameter[0] == '#') {
            auto operand = parameter[1 .. $];
            bool arrayLength = operand.length >= 3 && operand[$ - 3 .. $] == "[@]";
            auto name = arrayLength ? operand[0 .. $ - 3] : operand;
            if (syntaxOnly_) return "";
            auto value = mem.get(name);
            if (value.kind == ValueKind.bashArrayValue || value.kind == ValueKind.bashAssocValue) {
                if (arrayLength) return to!string(value.shellContainer.length);
                return to!string(toUTF32(mem.wordVariable(name)).length);
            }
            if (arrayLength || value.kind != ValueKind.stringValue) throw new YshTypeError("Shell length expects Str or shell array");
            return to!string(toUTF32(value.stringValue).length);
        }
        size_t nameEnd;
        while (nameEnd < parameter.length && asciiIdentifierContinue(parameter[nameEnd])) ++nameEnd;
        bool positional = nameEnd && parameter[0] >= '0' && parameter[0] <= '9';
        if (nameEnd == 0 || (!positional && !asciiIdentifierStart(parameter[0])))
            throw new YshError("unsupported braced parameter");
        auto name = parameter[0 .. nameEnd];
        // Slice separators belong to the arithmetic grammar: the colon in a
        // nested ?: expression cannot split the offset from the length.
        bool arraySlice = nameEnd + 3 < parameter.length &&
            (parameter[nameEnd .. nameEnd + 3] == "[@]" || parameter[nameEnd .. nameEnd + 3] == "[*]") &&
            parameter[nameEnd + 3] == ':';
        auto sliceOffset = nameEnd + (arraySlice ? 3 : 0);
        if (sliceOffset < parameter.length && parameter[sliceOffset] == ':' &&
                (sliceOffset + 1 == parameter.length || "-+=?".indexOf(parameter[sliceOffset + 1]) < 0)) {
            if (parserOptions_ !is null && parserOptions_.get("no_parse_sh_arith"))
                throw new ParseError("Shell arithmetic slices are disabled (no_parse_sh_arith)");
            auto parts = parseShellArithmeticSlice(parameter[sliceOffset + 1 .. $], parserOptions_);
            if (syntaxOnly_) return "";
            import std.bigint : BigInt, toDecimalString;
            auto begin = parts[0].evaluate(mem);
            bool hasLength = parts[1] !is null;
            auto count = hasLength ? parts[1].evaluate(mem) : BigInt(0);
            if (arraySlice) {
                auto value = mem.get(name);
                if (value.kind != ValueKind.bashArrayValue) throw new FatalRuntimeError("Array slice expects BashArray");
                if (hasLength && count < 0) throw new FatalRuntimeError("Array slice can't have negative length");
                BigInt length;
                foreach (key, unused; value.shellContainer) {
                    auto next = BigInt(key) + 1;
                    if (next > length) length = next;
                }
                if (begin < 0) begin += length;
                auto keys = value.shellContainer.keys;
                sort!((a, b) => BigInt(a) < BigInt(b))(keys);
                string[] words;
                foreach (key; keys) if (BigInt(key) >= begin && (!hasLength || BigInt(words.length) < count))
                    words ~= value.shellContainer.find(key).stringValue;
                return words.join(" ");
            }
            auto chars = toUTF32(mem.wordVariable(name));
            auto length = BigInt(chars.length);
            if (begin < 0) begin += length;
            if (begin < 0) begin = 0;
            if (begin > length) begin = length;
            auto end = hasLength ? (count < 0 ? length + count : begin + count) : length;
            if (end < begin) end = begin;
            if (end > length) end = length;
            import std.utf : toUTF8;
            return toUTF8(chars[to!size_t(toDecimalString(begin)) .. to!size_t(toDecimalString(end))]);
        }
        if (nameEnd < parameter.length && parameter[nameEnd] == '[') {
            auto close = substitutionClose(parameter, nameEnd, '[', ']');
            if (close + 1 != parameter.length) throw new YshError("Untranslated shell array parameter operation");
            auto key = parameter[nameEnd + 1 .. close];
            if (!key.length) throw new ParseError("Shell array index cannot be empty");
            if (syntaxOnly_) {
                if (key != "@" && key != "*") arithmeticSubstitution(key, null);
                return "";
            }
            auto cell = mem.getCell(name);
            if (cell is null && name != "PIPESTATUS") {
                if (mem.nounset) throw new FatalRuntimeError("Undefined shell array " ~ name);
                return "";
            }
            auto value = mem.get(name);
            if (value.kind != ValueKind.bashArrayValue && value.kind != ValueKind.bashAssocValue)
                throw new YshTypeError("Shell indexed expansion expects BashArray or BashAssoc");
            if (key == "@" || key == "*") {
                import yshd.value : shellArrayValues;
                return shellArrayValues(value).join(" ");
            }
            if (value.kind == ValueKind.bashArrayValue) {
                key = evaluateShellIndex(key, value, mem);
            } else {
                auto indexParser = new ProgramParser(key, false, returnMode_, true, parserOptions_);
                key = indexParser.readScalarWord(mem).text();
            }
            if (auto found = value.shellContainer.find(key)) return found.stringValue;
            if (mem.nounset) throw new FatalRuntimeError("Undefined shell array element");
            return "";
        }
        size_t positionalIndex;
        if (positional) {
            foreach (ch; name) if (ch < '0' || ch > '9') throw new ParseError("Invalid positional parameter");
            try { positionalIndex = to!size_t(name); } catch (Exception error) { throw new ParseError("Positional index is too large"); }
        }
        bool positionalDefined = !syntaxOnly_ && (positionalIndex == 0 || positionalIndex <= mem.shellArguments.length);
        string parameterValue() {
            if (syntaxOnly_) return "";
            if (!positional) return mem.wordVariable(name);
            return positionalIndex == 0 ? mem.argumentZero : mem.shellArgument(positionalIndex);
        }
        if (nameEnd == parameter.length) return parameterValue();
        char operation = parameter[nameEnd];
        bool colon = operation == ':';
        auto operatorOffset = nameEnd + (colon ? 1 : 0);
        if (operatorOffset < parameter.length &&
                (parameter[operatorOffset] == '-' || parameter[operatorOffset] == '+' ||
                 parameter[operatorOffset] == '=' || parameter[operatorOffset] == '?')) {
            operation = parameter[operatorOffset];
            auto word = parameter[operatorOffset + 1 .. $];
            auto wordParser = new ProgramParser(word, syntaxOnly_, returnMode_, false, parserOptions_, null, false, multiline_);
            if (syntaxOnly_) {
                // Syntax is checked even when the default would be unused,
                // while nested commands and assignments remain unevaluated.
                if (quoted) {
                    evaluateDoubleQuoted(word, null);
                } else if (word.length) {
                    wordParser.readCommandWord(null);
                    if (wordParser.current_.kind != TokenKind.eof)
                        throw new YshError("parameter default requires one translated word");
                }
                return "";
            }
            auto cell = mem.getCell(name);
            auto environmentValue = mem.get("ENV").dictValue.find(name);
            bool defined = positional ? positionalDefined : cell !is null || environmentValue !is null;
            auto existing = defined ? parameterValue() : "";
            bool useDefault = !defined || (colon && existing.length == 0);
            if (operation == '+') useDefault = !useDefault;
            if (!useDefault) return operation == '+' ? "" : existing;
            string replacement;
            if (quoted) replacement = evaluateDoubleQuoted(word, mem);
            else if (word.length) {
                auto parts = wordParser.readCommandWord(mem);
                if (parts.length != 1 || wordParser.current_.kind != TokenKind.eof)
                    throw new YshError("parameter default requires one translated word");
                replacement = parts[0];
            }
            if (operation == '?') throw new YshError(replacement.length ? replacement : name ~ " is unset");
            if (operation == '=') {
                if (positional) throw new FatalRuntimeError("Cannot assign to a positional parameter");
                mem.setVar(name, Value.str(replacement));
            }
            return replacement;
        }
        auto value = parameterValue();
        if (operation != '%' && operation != '#')
            throw new YshError("untranslated parameter operation");
        auto patternStart = nameEnd + 1;
        bool longest = patternStart < parameter.length && parameter[patternStart] == operation;
        if (longest) ++patternStart;
        auto pattern = parameter[patternStart .. $];
        // Phobos globMatch's brace alternatives are not shell parameter syntax.
        if (pattern.indexOf('{') >= 0 || pattern.indexOf('}') >= 0)
            throw new YshError("brace patterns are not translated");
        string result = value;
        foreach (count; 0 .. value.length + 1) {
            auto cut = longest ? value.length - count : count;
            auto position = operation == '%' ? value.length - cut : cut;
            if (position < value.length && (cast(ubyte)value[position] & 0xc0) == 0x80) continue;
            auto candidate = operation == '%' ? value[position .. $] : value[0 .. position];
            if (globMatch!(CaseSensitive.yes)(toUTF32(candidate), toUTF32(pattern))) {
                result = operation == '%' ? value[0 .. position] : value[position .. $];
                break;
            }
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
            kind == TokenKind.leftBracket || kind == TokenKind.rightBracket ||
            kind == TokenKind.plusPlus ||
            kind == TokenKind.slashSlash || kind == TokenKind.bang ||
            kind == TokenKind.comma ||
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
            if (syntaxOnly_) {
                validateExpression(expression);
                return [""];
            }
            return spliceArray(evaluate(expression, mem));
        }
        if (current_.kind != TokenKind.name) {
            throw new YshError("@ splice expects a variable name or [expression]");
        }
        auto value = Value.nullValue();
        if (!syntaxOnly_) {
            auto cell = mem.getCell(current_.text);
            if (cell is null) throw new YshError("Undefined splice variable '" ~ current_.text ~ "'");
            value = cell.value;
        }
        advance();
        if (syntaxOnly_) return [""];
        return spliceArray(value);
    }

    private string parseScalarSubstitution(Memory mem, ref size_t endOffset) {
        auto dollarOffset = current_.offset;
        // Variable names remain identifiers even when they are command
        // keywords, for example $var and $for in test operands.
        if (dollarOffset + 1 < source_.length && asciiIdentifierStart(source_[dollarOffset + 1])) {
            endOffset = dollarOffset + 2;
            while (endOffset < source_.length && asciiIdentifierContinue(source_[endOffset])) ++endOffset;
            auto name = source_[dollarOffset + 1 .. endOffset];
            auto value = syntaxOnly_ ? "" : mem.wordVariable(name);
            moveTo(endOffset);
            return value;
        }
        if (dollarOffset + 2 < source_.length && source_[dollarOffset + 1 .. dollarOffset + 3] == "((") {
            endOffset = shellArithmeticEnd(source_, dollarOffset + 1);
            auto result = arithmeticSubstitution(source_[dollarOffset + 3 .. endOffset - 2], mem);
            moveTo(endOffset);
            return result;
        }
        if (dollarOffset + 1 < source_.length &&
                "0123456789?!@#$*-".indexOf(source_[dollarOffset + 1]) >= 0) {
            auto name = source_[dollarOffset + 1];
            endOffset = dollarOffset + 2;
            moveTo(endOffset);
            return syntaxOnly_ ? "" : mem.simpleShellVariable(name);
        }
        advance();
        if (current_.offset != dollarOffset + 1) {
            throw new YshError("$ substitution must follow '$' without whitespace");
        }
        if (current_.kind == TokenKind.doubleQuoted) {
            auto result = evaluateDoubleQuoted(current_.text, mem);
            endOffset = lexer_.offset;
            advance();
            return result;
        }
        if (current_.kind == TokenKind.leftParen) {
            auto command = collectParenthesizedCommand("$ command substitution",
                endOffset);
            auto output = captureCommandOutput(command, mem);
            while (output.length != 0 && output[$ - 1] == '\n') {
                output = output[0 .. $ - 1];
            }
            return output;
        }
        if (current_.kind == TokenKind.leftBrace) {
            auto close = substitutionClose(source_, dollarOffset + 1, '{', '}');
            auto result = evaluateBracedParameter(source_[dollarOffset + 2 .. close], mem);
            endOffset = close + 1;
            while (current_.kind != TokenKind.eof && current_.offset < endOffset) advance();
            return result;
        }
        if (current_.kind == TokenKind.leftBracket) {
            auto expression = collectBracketedExpression("$ expression", endOffset);
            if (parserOptions_ !is null && !parserOptions_.get("parse_ysh_expr_sub"))
                return arithmeticSubstitution(expression, mem);
            if (syntaxOnly_) {
                validateExpression(expression);
                return "";
            }
            return stringify(evaluate(expression, mem));
        }
        if (current_.kind != TokenKind.name) {
            throw new YshError("$ substitution expects a variable name or [expression]");
        }
        auto value = syntaxOnly_ ? "" : mem.wordVariable(current_.text);
        endOffset = current_.offset + current_.text.length;
        advance();
        return value;
    }

    private string arithmeticSubstitution(string source, Memory mem) {
        if (parserOptions_ !is null && parserOptions_.get("no_parse_sh_arith"))
            throw new ParseError("Shell arithmetic substitutions are disabled (no_parse_sh_arith)");
        auto arithmetic = parseShellArithmetic(source, parserOptions_);
        if (syntaxOnly_) return "";
        import std.bigint : toDecimalString;
        return toDecimalString(arithmetic.evaluate(mem));
    }

    private string captureCommandOutput(string command, Memory mem) {
        if (syntaxOnly_) {
            // Command substitution has its own CommandParser / VarChecker.
            .parseProgram(command, ReturnMode.shell, parserOptions_);
            return "";
        }
        if (!mem.options.get("_allow_command_sub"))
            throw new FatalRuntimeError("Command substitution is disabled in recursive arithmetic (eval_unsafe_arith)");
        auto result = captureSourceOutput(command, mem,
            (string source, Memory childMemory) {
                .executeProgram(source, childMemory);
                return childMemory.lastStatus;
            });
        if (mem.options.get("command_sub_errexit") && mem.commandSubLastStatus != 0)
            throw new Errexit(mem.commandSubLastStatus,
                "Command Sub exited with status " ~ to!string(mem.commandSubLastStatus));
        return result;
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
            adjustDepth(depth, current_);
            advance();
        }
        throw new YshError("unterminated " ~ description);
    }

    private string collectBracketedExpression(string description, bool allowEmpty = false) {
        size_t ignored;
        return collectBracketedExpression(description, ignored, allowEmpty);
    }

    private string collectBracketedExpression(string description, ref size_t endOffset, bool allowEmpty = false) {
        require(TokenKind.leftBracket, "[");
        auto start = current_.offset;
        int depth;
        bool atomExpected = true;
        while (current_.kind != TokenKind.eof) {
            if (consumeDelimitedAtom(atomExpected)) continue;
            if (depth == 0 && current_.kind == TokenKind.rightBracket) {
                auto expression = strip(source_[start .. current_.offset]);
                endOffset = current_.offset + current_.text.length;
                advance();
                if (expression.length == 0 && !allowEmpty) {
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
        case TokenKind.caseKeyword:
        case TokenKind.esacKeyword:
        case TokenKind.breakKeyword:
        case TokenKind.continueKeyword:
        case TokenKind.minus:
        case TokenKind.plus:
        case TokenKind.dot:
        case TokenKind.ellipsis:
        case TokenKind.colon:
        case TokenKind.slash:
        case TokenKind.percent:
        case TokenKind.caret:
        case TokenKind.star:
        case TokenKind.starStar:
        case TokenKind.leftBracket:
        case TokenKind.rightBracket:
        case TokenKind.tilde:
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

    private void parseLoopControl(Memory mem, bool shouldBreak) {
        advance();
        string[] words;
        while (!isEndStatement(current_.kind)) words ~= readScalarWord(mem).text();
        if (words.length > 1) throw new FatalRuntimeError("break and continue expect at most one integer");
        size_t levels = 1;
        if (words.length) {
            long value;
            try { value = to!long(words[0]); }
            catch (Exception error) { throw new FatalRuntimeError("break/continue expected an integer"); }
            if (value < 1) throw new FatalRuntimeError("break/continue level must be at least 1");
            levels = cast(size_t)value;
        }
        if (!mem.insideLoop()) {
            auto message = shouldBreak
                ? "break is only valid inside a loop"
                : "continue is only valid inside a loop";
            if (mem.options.get("strict_control_flow")) throw new FatalRuntimeError(message);
            mem.errorFile.writeln("warning: ", message);
            mem.lastStatus = 0;
            return;
        }
        mem.lastStatus = 0;
        mem.trace.control(shouldBreak ? "break" : "continue", levels, mem);
        throw new LoopControl(shouldBreak, levels);
    }

    private string collectParenthesizedExpression(bool allowEmpty = false) {
        require(TokenKind.leftParen, "(");
        auto start = current_.offset;
        auto end = start;
        int depth;
        bool atomExpected = true;

        while (current_.kind != TokenKind.eof) {
            if (consumeDelimitedAtom(atomExpected)) continue;
            if (depth == 0 && current_.kind == TokenKind.rightParen) {
                end = current_.offset;
                advance();
                auto expression = strip(source_[start .. end]);
                if (expression.length == 0 && !allowEmpty) {
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
                    lastBlockEnd_ = current_.offset + 1;
                    advance();
                    return body;
                }
            }
            advance();
        }
        throw new ParseError("unterminated command block");
    }

    private void require(TokenKind kind, string spelling) {
        if (current_.kind != kind) {
            throw new ParseError(format("expected '%s' at byte %s", spelling, current_.offset));
        }
        advance();
    }

    /// Collect one YSH testlist through the end of the command. Top-level
    /// commas become a List expression, matching the semantic shape consumed by
    /// _DoVarDecl/_DoMutation after upstream expr_to_ast conversion.
    private string collectRhs(bool expressionTuple = true) {
        if (isEndStatement(current_.kind)) {
            throw new YshError("expected expression on right side of '='");
        }

        size_t start = current_.offset;
        size_t end = source_.length;
        int depth;
        size_t topLevelCommas;
        bool atomExpected = true;

        while (current_.kind != TokenKind.eof) {
            if (consumeDelimitedAtom(atomExpected)) continue;
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

        if (expressionTuple && topLevelCommas != 0) {
            rhs = "[" ~ rhs ~ "]";
        }
        return rhs;
    }

    private bool consumeDelimitedAtom(ref bool atomExpected) {
        if (atomExpected && (current_.kind == TokenKind.slash ||
                (current_.kind == TokenKind.colon && lexer_.peek().kind == TokenKind.pipe))) {
            auto end = current_.offset + expressionAtomEnd(source_[current_.offset .. $], parserOptions_);
            while (current_.kind != TokenKind.eof && current_.offset < end) advance();
            atomExpected = false;
            return true;
        }
        switch (current_.kind) {
        case TokenKind.name: case TokenKind.integer: case TokenKind.floating:
        case TokenKind.stringValue: case TokenKind.doubleQuoted: case TokenKind.charValue:
        case TokenKind.trueKeyword: case TokenKind.falseKeyword: case TokenKind.nullKeyword:
        case TokenKind.rightParen: case TokenKind.rightBracket: case TokenKind.rightBrace:
            atomExpected = false;
            break;
        default: atomExpected = true; break;
        }
        return false;
    }

    private static void adjustDepth(ref int depth, Token token) {
        if (!token.wordBracket) adjustDepth(depth, token.kind);
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
            if (current_.kind == TokenKind.newline &&
                    activeMemory_ !is null) {
                visibleAliases_ = activeMemory_.aliases.dup;
            }
            advance();
        }
    }

    private static bool isEndStatement(TokenKind kind) {
        return kind == TokenKind.newline ||
            kind == TokenKind.semicolon ||
            kind == TokenKind.eof;
    }

    private bool atProgramEnd() {
        auto remaining = new Lexer(source_, true, current_.offset, true, parserOptions_);
        remaining.multiline = multiline_;
        auto token = remaining.next();
        while (token.kind == TokenKind.newline || token.kind == TokenKind.semicolon) token = remaining.next();
        return token.kind == TokenKind.eof;
    }

    private void advance() {
        current_ = lexer_.next();
    }
}

// Expressions and command words share interpolation and escape semantics.
string evaluateDoubleQuotedExpression(string content, Memory mem) {
    return (new ProgramParser("", false, ReturnMode.shell, false, mem.options)).evaluateDoubleQuoted(content, mem);
}

string evaluateCommandSubstitution(string command, Memory mem) {
    auto output = (new ProgramParser("")).captureCommandOutput(command, mem);
    while (output.length != 0 && output[$ - 1] == '\n') output = output[0 .. $ - 1];
    return output;
}

void executeProgram(string source, Memory mem, bool attributeScope = false, bool multiline = false) {
    mem.registerSource(source);
    auto parser = new ProgramParser(source, false, mem.returnMode, false, mem.options, null, attributeScope, multiline);
    parser.execute(mem);
    // Batch and command-list evaluation return zero for an empty program.
    // Do this afterward so a first command's $? still sees its caller's status.
    if (!parser.executedCommand_) mem.lastStatus = 0;
}

void executeProcedureBody(string source, Memory mem, bool attributeScope = false, bool multiline = false) {
    try { executeProgram(source, mem, attributeScope, multiline); }
    catch (LoopControl control) { throw new FatalRuntimeError("Unexpected break or continue across a procedure call"); }
}

/// Parse with no interpreter state. No command or expression is evaluated.
void parseProgram(string source, ReturnMode returnMode = ReturnMode.shell, ShellOptions options = null,
        VariableChecker variableChecker = null, bool attributeScope = false, bool multiline = false) {
    try {
        (new ProgramParser(source, true, returnMode, false, options, variableChecker, attributeScope, multiline)).parse();
    } catch (ParseError error) {
        throw error;
    } catch (YshError error) {
        // Structural parsers do not execute code. Their diagnostics are parse
        // failures even when invoked by source, a function definition, or
        // dynamic noexec rather than the CLI's -n path.
        throw new ParseError(error.msg);
    }
}

void validateDoubleQuoted(string content, ShellOptions options = null) {
    (new ProgramParser("", true, ReturnMode.shell, false, options)).evaluateDoubleQuoted(content, null);
}

string[] evaluateShellWords(string source, Memory mem) {
    auto parser = new ProgramParser(source, false, ReturnMode.shell, true, mem.options);
    string[] words;
    while (parser.current_.kind != TokenKind.eof) {
        if (parser.current_.kind == TokenKind.newline) { parser.advance(); continue; }
        if (parser.current_.kind == TokenKind.newline) parser.advance();
        else words ~= parser.readCommandWord(mem);
    }
    return words;
}

void validateShellWords(string source, ShellOptions options = null) {
    auto parser = new ProgramParser(source, true, ReturnMode.shell, true, options);
    while (parser.current_.kind != TokenKind.eof) {
        if (parser.current_.kind == TokenKind.newline) { parser.advance(); continue; }
        if (parser.current_.kind == TokenKind.newline) parser.advance();
        else parser.readCommandWord(null);
    }
}

unittest {
    // core/state.py keeps script identity separate from the mutable ARGV
    // cell; both quoted and unquoted $0 preserve the complete script name.
    auto output = File.tmpfile();
    auto errors = File.tmpfile();
    auto mem = new Memory(output, errors);
    mem.initializeArguments("directory/script with spaces.grease", ["one word", "two"]);
    executeProgram("echo $0; echo \"$0\"; write @ARGV", mem);
    output.rewind();
    assert(output.readln() == "directory/script with spaces.grease\n");
    assert(output.readln() == "directory/script with spaces.grease\n");
    assert(output.readln() == "one word\n");
    assert(output.readln() == "two\n");
    assert(output.readln().length == 0);
    executeProgram("call ARGV->append('later')", mem);
    assert(mem.argumentZero == "directory/script with spaces.grease");
    assert(mem.get("ARGV").listValue.length == 3);
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
        "func store(value) { setglobal called = value; return (null) }\n" ~
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
        "  setglobal proc_value = first ++ ':' ++ rest[1]\n" ~
        "}\n" ~
        "capture alpha beta gamma\n" ~
        "var open_proc_value = ''\n" ~
        "proc open_capture { setglobal open_proc_value = ARGV[1] }\n" ~
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
    executeProgram("break\n", mem); // OSH defaults warn and return zero.
    assert(mem.lastStatus == 0);
    mem.options.set("strict_control_flow", true);
    try {
        executeProgram("break\n", mem);
    } catch (YshError error) {
        rejectedBreakOutsideLoop = true;
    }
    assert(rejectedBreakOutsideLoop);
    mem.options.set("strict_control_flow", false);

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

unittest {
    auto mem = new Memory();
    // $[dict[...]] is a YSH substitution, not the OSH arithmetic synonym.
    mem.options.set("parse_ysh_expr_sub", true);
    executeProgram(`var key = 'value'; var d = {key: 42}; var quoted = "key=$key $[d["key"]]";`, mem);
    assert(mem.get("quoted").stringValue == "key=value 42");
}

unittest {
    // Grease spec/grease-alias.test.sh: selected unquoted command names
    // expand, unalias removes the definition, missing aliases return status 1.
    auto output = File.tmpfile();
    auto errors = File.tmpfile();
    auto mem = new Memory(output, errors);
    bool stopped;
    try {
        executeProgram(
            "shopt -s ysh:all\n" ~
            "alias ll='echo alias-ok'\n" ~
            "ll\n" ~
            "unalias ll\n" ~
            "alias ll\n", mem);
    } catch (Errexit error) { stopped = error.status == 1; }
    assert(stopped);
    output.rewind();
    assert(output.readln() == "alias-ok\n");
    assert(output.readln().length == 0);
    assert(mem.lastStatus == 1);
    assert(("ll" in mem.aliases) is null);
}

unittest {
    // The source line is parsed before alias definitions on that line are
    // visible. An alias can override a builtin on later lines, but recursion
    // within the replacement is suppressed.
    auto output = File.tmpfile();
    auto errors = File.tmpfile();
    auto mem = new Memory(output, errors);
    executeProgram(
        "alias echo='echo marked'; echo same-line\n" ~
        "echo next-line\n" ~
        "unalias echo\n" ~
        "echo restored\n", mem);
    output.rewind();
    assert(output.readln() == "same-line\n");
    assert(output.readln() == "marked next-line\n");
    assert(output.readln() == "restored\n");
    assert(output.readln().length == 0);
}

unittest {
    // Alias expansion occurs at command position, not in ordinary arguments.
    auto output = File.tmpfile();
    auto errors = File.tmpfile();
    auto mem = new Memory(output, errors);
    executeProgram(
        "alias greet='echo expanded'\n" ~
        "echo greet\n" ~
        "greet literal\n" ~
        "unalias -a\n", mem);
    output.rewind();
    assert(output.readln() == "greet\n");
    assert(output.readln() == "expanded literal\n");
    assert(mem.aliases.length == 0);
}
