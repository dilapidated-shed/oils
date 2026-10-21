module yshd.program;

import std.algorithm : sort, endsWith;
import std.conv : to;
import std.file : FileException, chdir, read;
import std.format : format;
import std.stdio : File;
import std.string : indexOf, join, split, strip;

import yshd.command : Mutation, VarDecl, executeMutation, executeVarDecl;
import yshd.expr : AssignmentScope, ParseError, evaluate, validateExpression,
    validateAssignmentTarget, parseTypedArguments, expressionAtomEnd;
import yshd.func_proc : FunctionParameter, FunctionReturn, ProcReturn, YshFunction, YshProc, ProcSignature;
import yshd.io_ysh : WriteEncoding, encodeDataValue, renderEcho,
    renderWrite, spliceArray, DataEncodeError, dataOptions;
import yshd.pretty : prettyValue, prettyCell, asdlValue, terminalWidth;
import yshd.lexer : Lexer, Token, TokenKind, HereDocument;
import yshd.process : runExternal, runPipeline, runSourcePipeline, captureSourceOutput;
import yshd.state : Memory, ReturnMode, Frame;
import yshd.options : ShellOptions;
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

class YshCommand {
    string source;
    Frame captured;
    Frame moduleFrame;
    this(string source, Memory mem) {
        this.source = source;
        captured = mem.currentFrame;
        moduleFrame = mem.globalFrame;
    }
    int eval(Memory mem) {
        auto previousGlobal = mem.globalFrame;
        mem.globalFrame = moduleFrame;
        mem.pushEnclosed(captured);
        scope (exit) { mem.popFrame(); mem.globalFrame = previousGlobal; }
        executeProgram(source, mem);
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
            import std.bigint : BigInt;
            BigInt a, b;
            try { a = BigInt(left); b = BigInt(text); }
            catch (Exception error) { throw new UsageError("Shell integer condition expected integer operands"); }
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
    private ShellOptions options;
    this(string source, ReturnMode returnMode, ShellOptions options = null) {
        this.source = source;
        this.returnMode = returnMode;
        this.options = options;
        lexer = new Lexer(source, true, 0, true, options);
    }
    HereDocument[size_t] documents() { return lexer.hereDocuments; }
    Token next() {
        auto token = lexer.next();
        if (commandStart && token.kind == TokenKind.ifKeyword) {
            auto parser = new ProgramParser(source[token.offset .. $], true, returnMode, false, options);
            parser.parseIfCommand();
            auto end = token.offset + parser.lastCompoundEnd_;
            lexer = new Lexer(source, true, end, true, options);
            commandStart = false;
            return Token(TokenKind.name, source[token.offset .. end], token.offset);
        }
        if (commandStart && token.kind == TokenKind.leftBracket && lexer.peek().kind == TokenKind.leftBracket &&
                lexer.peek().offset == token.offset + 1) {
            auto parser = new ProgramParser(source[token.offset .. $], true, returnMode, false, options);
            parser.parseDoubleBracket(null);
            auto end = token.offset + parser.current_.offset;
            lexer = new Lexer(source, true, end, true, options);
            commandStart = false;
            return Token(TokenKind.name, source[token.offset .. end], token.offset);
        }
        if (commandStart && token.kind == TokenKind.caseKeyword) {
            auto parser = new ProgramParser(source[token.offset .. $], true, returnMode, false, options);
            parser.parseCase(null);
            auto end = token.offset + parser.current_.offset;
            lexer = new Lexer(source, true, end, true, options);
            commandStart = false;
            return Token(TokenKind.caseKeyword, source[token.offset .. end], token.offset);
        }
        commandStart = token.kind == TokenKind.newline || token.kind == TokenKind.semicolon ||
            token.kind == TokenKind.leftBrace || token.kind == TokenKind.pipe ||
            token.kind == TokenKind.andIf || token.kind == TokenKind.orIf ||
            token.kind == TokenKind.bang;
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
    this(int status) { super(status); }
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
    private Memory activeMemory_;
    private string[string] visibleAliases_;
    private bool syntaxOnly_;
    private ReturnMode returnMode_;
    private bool executedCommand_;
    private ShellOptions parserOptions_;
    private bool lastWordTriple_;
    private size_t lastBlockEnd_;
    private size_t lastCompoundEnd_;

    this(string source, bool syntaxOnly = false, ReturnMode returnMode = ReturnMode.shell, bool wordsOnly = false, ShellOptions options = null) {
        source_ = source;
        returnMode_ = returnMode;
        syntaxOnly_ = syntaxOnly;
        parserOptions_ = options;
        lexer_ = new Lexer(source, true, 0, !wordsOnly, options);
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
            if (tryExecuteAndOr(null) || tryExecuteTopLevelPipeline(null) ||
                    tryExecuteTopLevelRedirect(null)) {
                skipEndStatements();
                continue;
            }
            if (tryRetainedAssignment(null)) { skipEndStatements(); continue; }
            switch (current_.kind) {
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
                if (current_.text == "declare" || current_.text == "typeset" || current_.text == "local") {
                    parseShellDeclare(null);
                } else if (current_.text == "typed") {
                    advance();
                    if (current_.kind != TokenKind.procKeyword) throw new ParseError("Expected proc after typed");
                    parseProc(null);
                } else if (current_.text == "try") {
                    advance();
                    parseProgram(collectBlock());
                } else if (current_.text == "call") {
                    advance();
                    validateExpression(collectRhs());
                } else if (current_.text == "assert") {
                    advance();
                    validateExpression(current_.kind == TokenKind.leftBracket
                        ? collectBracketedExpression("assert") : collectRhs());
                } else if (current_.text == "shopt") {
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
                throw new YshError(format("unexpected command token '%s' at byte %s",
                    current_.text, current_.offset));
            }
            skipEndStatements();
        }
    }

    private void parseCommandWords() {
        bool hasTyped;
        while (!isEndStatement(current_.kind)) {
            if (current_.kind == TokenKind.leftParen) {
                if (hasTyped) throw new ParseError("Unexpected second typed argument list");
                hasTyped = true;
                parseTypedArguments("(" ~ collectParenthesizedExpression(true) ~ ")", true);
            } else if (current_.kind == TokenKind.leftBrace) {
                parseProgram(collectBlock());
                if (!isEndStatement(current_.kind)) throw new ParseError("Unexpected words after block argument");
                break;
            } else {
                if (hasTyped) throw new ParseError("Unexpected words after typed arguments");
                readCommandWord(null);
            }
        }
    }

    private void parseProgram(string source) {
        .parseProgram(source, returnMode_, parserOptions_);
    }

    private void validateExpression(string source) { .validateExpression(source, parserOptions_); }
    private auto parseTypedArguments(string source, bool validateNested = false) {
        return .parseTypedArguments(source, validateNested, parserOptions_);
    }

    void execute(Memory mem) {
        assert(!syntaxOnly_);
        activeMemory_ = mem;
        // Command aliases expand while parsing, not while invoking arbitrary
        // argument words. Definitions following a semicolon become visible
        // only on the next source line, as in the inherited alias tests.
        visibleAliases_ = mem.aliases.dup;
        skipEndStatements();

        while (current_.kind != TokenKind.eof) {
            if (mem.options.get("noexec")) {
                parseProgram(source_[current_.offset .. $]);
                return;
            }
            executedCommand_ = true;
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
            if (tryExecuteTopLevelRedirect(mem)) {
                checkErrexit(mem);
                skipEndStatements();
                continue;
            }
            if (tryExpandCommandAlias(mem)) {
                checkErrexit(mem);
                skipEndStatements();
                continue;
            }
            if (tryRetainedAssignment(mem)) { checkErrexit(mem); skipEndStatements(); continue; }

            switch (current_.kind) {
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
                advance();
                while (!isEndStatement(current_.kind)) readCommandWord(mem);
                mem.lastStatus = 0;
                break;
            case TokenKind.falseKeyword:
                advance();
                while (!isEndStatement(current_.kind)) readCommandWord(mem);
                mem.lastStatus = 1;
                break;
            case TokenKind.colon:
                parseNoOp(mem);
                break;
            case TokenKind.equal:
                parseExpressionDisplay(mem);
                break;
            case TokenKind.name:
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
                if (current_.text == "builtin") {
                    advance();
                    if (current_.text == "set") parseSet(mem);
                    else if (current_.text == "echo") parseEcho(mem);
                    else if (current_.text == "read") parseRead(mem);
                    else if (current_.text == "cd") parseCd(mem);
                    else throw new UsageError("Untranslated or unknown builtin " ~ current_.text);
                    break;
                }
                if (current_.text == "set") {
                    parseSet(mem);
                    break;
                }
                if (current_.text == "alias") {
                    parseAlias(mem);
                    break;
                }
                if (current_.text == "unalias") {
                    parseUnalias(mem);
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
                if (current_.text == "read") {
                    parseRead(mem);
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
                throw new YshError(format(
                    "D YSH command parser has not translated command beginning with '%s' at byte %s",
                    current_.text, current_.offset));
            }

            checkErrexit(mem);
            skipEndStatements();
        }
    }

    private static void checkErrexit(Memory mem) {
        if (mem.errexit && mem.errexitSuppression == 0 && mem.lastStatus != 0) {
            throw new Errexit(mem.lastStatus);
        }
    }

    private void parseSet(Memory mem) {
        advance();
        string[] words;
        while (!isEndStatement(current_.kind)) words ~= readCommandWord(mem);
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
                case 'o':
                    if (flagIndex + 2 != word.length || index + 1 >= words.length) {
                        throw new YshError("set -o/+o requires a supported option name");
                    }
                    ++index;
                    switch (words[index]) {
                    case "errexit": mem.errexit = enabled; break;
                    case "nounset": mem.nounset = enabled; break;
                    case "pipefail": mem.pipefail = enabled; break;
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
        auto value = current_.text in visibleAliases_;
        if (value is null) {
            return false;
        }

        auto aliasName = current_.text;
        foreach (active; mem.aliasExpansionStack) {
            if (active == aliasName) {
                return false;
            }
        }

        auto statementStart = current_.offset;
        auto scanner = new CommandScanner(source_[statementStart .. $], returnMode_, parserOptions_);
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
            adjustDepth(depth, token.kind);
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

    private bool tryExecuteAndOr(Memory mem) {
        if (!pipelineStatementStart(current_.kind) && current_.kind != TokenKind.bang &&
                current_.kind != TokenKind.ifKeyword) return false;
        auto start = current_.offset;
        auto scanner = new CommandScanner(source_[start .. $], returnMode_, parserOptions_);
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
            adjustDepth(depth, token.kind);
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

    private bool pipelineStatementStart(TokenKind kind) const {
        return kind == TokenKind.name || kind == TokenKind.leftBracket || kind == TokenKind.ifKeyword ||
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
        auto scanner = new CommandScanner(source_[statementStart .. $], returnMode_, parserOptions_);
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
            adjustDepth(depth, token.kind);
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
        return kind == TokenKind.name || kind == TokenKind.leftBracket ||
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
        if (!redirectableStatementStart(current_.kind)) {
            return false;
        }

        auto statementStart = current_.offset;
        auto scanner = new CommandScanner(source_[statementStart .. $], returnMode_, parserOptions_);
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
            adjustDepth(depth, token.kind);
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
            auto operandParser = new ProgramParser(source_[statementStart + operandStart .. $], syntaxOnly_, returnMode_, false, parserOptions_);
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
                    selected = File(redirect.operand, redirect.kind == TokenKind.less
                        ? "r" : redirect.kind == TokenKind.shiftRight ? "a" : "w");
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
        if (strip(commandSource).length) executeProgram(commandSource, mem);
        else mem.lastStatus = 0;
        mem.outputFile.flush();
        mem.errorFile.flush();

        consumeStatement();
        return true;
    }

    private void consumeStatement() {
        auto start = current_.offset;
        auto scanner = new CommandScanner(source_[start .. $], returnMode_, parserOptions_);
        int depth;
        size_t end;
        while (true) {
            auto token = scanner.next();
            if (token.kind == TokenKind.eof || (depth == 0 && isEndStatement(token.kind))) {
                end = start + token.offset;
                break;
            }
            adjustDepth(depth, token.kind);
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
            advance();

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

        // Type expressions belong here eventually. Fail closed rather than
        // silently accepting a declaration that has not actually been parsed.
        throw new YshError(format(
            "untranslated declaration syntax at byte %s", current_.offset));
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
            foreach (target; targets) validateAssignmentTarget(target);
            validateExpression(rhs);
            return;
        }
        executeMutation(Mutation(targets, assignmentScope, rhs, operation), mem);
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

        .parseProgram(body, ReturnMode.functionValue, parserOptions_);
        if (syntaxOnly_) return;
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
        .parseProgram(body, ReturnMode.procValue, parserOptions_);
        if (syntaxOnly_) return;
        auto userProc = new YshProc(name, body, mem, openSignature,
            wordParameters, restWordName, signature);
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
        if (!associative && !indexed) throw new UsageError("Untranslated declaration flags");
        if (current_.kind != TokenKind.name) throw new UsageError("Expected a shell array name");
        auto name = current_.text;
        if (!tryRetainedAssignment(mem, true, associative)) {
            advance();
            if (!isEndStatement(current_.kind)) throw new ParseError("Expected a shell array assignment");
            if (!syntaxOnly_) mem.setVar(name, Value.shellArray(new YshDict(), associative));
        }
        if (!syntaxOnly_) mem.lastStatus = 0;
    }

    /// Retained assignments have their own lvalues and array values. They do
    /// not turn a typed List/Dict/Eggex into a shell container.
    private bool tryRetainedAssignment(Memory mem, bool declaration = false, bool associative = false) {
        if (current_.kind != TokenKind.name) return false;
        auto start = current_.offset;
        auto name = current_.text;
        auto offset = start + name.length;
        string indexSource;
        bool indexed;
        if (offset < source_.length && source_[offset] == '[') {
            auto close = substitutionClose(source_, offset, '[', ']');
            indexSource = source_[offset + 1 .. close];
            indexed = true;
            offset = close + 1;
        }
        bool append = offset + 1 < source_.length && source_[offset .. offset + 2] == "+=";
        if (append) offset += 2;
        else if (offset < source_.length && source_[offset] == '=') ++offset;
        else return false;
        bool compound = offset < source_.length && source_[offset] == '(';
        if (!declaration && !indexed && !append && !compound) return false;
        auto cell = syntaxOnly_ ? null : mem.getCell(name);
        if (!syntaxOnly_ && append && !indexed && !compound && cell !is null &&
                (cell.value.kind == ValueKind.bashArrayValue || cell.value.kind == ValueKind.bashAssocValue))
            throw new FatalRuntimeError("Can't append a string to a shell array");
        if (cell !is null && cell.readOnly) throw new FatalRuntimeError("Can't assign to readonly shell variable " ~ name);
        if (!syntaxOnly_ && cell !is null && cell.value.kind != ValueKind.stringValue &&
                cell.value.kind != ValueKind.bashArrayValue && cell.value.kind != ValueKind.bashAssocValue)
            throw new FatalRuntimeError("Cannot use shell assignment on " ~ kindName(cell.value));
        bool isAssociative = associative || (!syntaxOnly_ && cell !is null && cell.value.kind == ValueKind.bashAssocValue);
        auto elements = new YshDict();
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
                    } else if (!syntaxOnly_) {
                        try { nextIndex = to!long(keySource); }
                        catch (Exception error) { throw new FatalRuntimeError("Untranslated shell arithmetic index"); }
                        if (nextIndex < 0) throw new FatalRuntimeError("Invalid shell array index");
                    }
                } else if (isAssociative) throw new ParseError("Associative literal requires [key]=value entries");
                if (!isAssociative) key = to!string(nextIndex++);
                string value;
                if (current_.kind != TokenKind.rightParen && !isEndStatement(current_.kind)) value = readScalarWord(mem).text();
                elements.set(key, Value.str(value));
            }
            advance(); // )
            if (!isEndStatement(current_.kind)) throw new ParseError("Unexpected words after array literal");
            if (!syntaxOnly_) mem.setVar(name, Value.shellArray(elements, isAssociative));
        } else {
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
                        auto keyParser = new ProgramParser(indexSource, false, returnMode_, true, parserOptions_);
                        key = keyParser.readScalarWord(mem).text();
                        if (!isAssociative) {
                            try { key = to!string(to!long(key)); }
                            catch (Exception error) { throw new FatalRuntimeError("Untranslated shell arithmetic index"); }
                        }
                    }
                    if (append) if (auto prior = elements.find(key)) value = prior.stringValue ~ value;
                    elements.set(key, Value.str(value));
                    mem.setVar(name, Value.shellArray(elements, isAssociative));
                } else {
                    if (append && cell !is null) value = cell.value.stringValue ~ value;
                    mem.setVar(name, Value.str(value));
                }
            }
        }
        if (!syntaxOnly_) mem.lastStatus = 0;
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
        import yshd.expr : ParsedArguments, EvaluatedArguments;
        ParsedArguments typedArguments;
        string blockSource;
        bool hasBlock;

        while (!isEndStatement(current_.kind)) {
            if (current_.kind == TokenKind.leftBrace) {
                hasBlock = true;
                blockSource = collectBlock();
                parseProgram(blockSource);
                if (!isEndStatement(current_.kind)) throw new ParseError("Unexpected words after block argument");
                break;
            }
            if (current_.kind == TokenKind.leftParen) {
                if (typedArguments !is null || pipeline.length)
                    throw new ParseError("Unexpected typed argument list");
                typedArguments = parseTypedArguments("(" ~ collectParenthesizedExpression(true) ~ ")", true);
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
                arguments.block = Value.closure(ValueKind.commandValue, new YshCommand(blockSource, mem));
            }
            return arguments;
        }

        if (pipeline.length == 0) {
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
                    executeProgram((cast(YshCommand)arguments.block.callableValue).source, mem);
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
            auto cell = mem.getCell(commandName);
            Value callable = cell is null ? Value.nullValue() : cell.value;
            bool invokableObject;
            if (callable.kind == ValueKind.objectValue && callable.objectValue.prototype !is null) {
                auto method = callable.objectValue.prototype.properties.find("__invoke__");
                if (method !is null && method.kind == ValueKind.procValue) {
                    callable = *method;
                    invokableObject = true;
                }
            }
            if (callable.kind == ValueKind.procValue) {
                auto userProc = cast(YshProc)callable.callableValue;
                if (userProc is null) {
                    throw new YshError(format(
                        "invalid proc value '%s'", commandName));
                }
                auto arguments = evalArguments();
                if (invokableObject) {
                    if (!userProc.signature.positional.length && !userProc.signature.restPositional.length)
                        throw new YshError("Using a proc as __invoke__ requires a self param");
                    arguments.positional = [cell.value] ~ arguments.positional;
                }
                userProc.invoke(argv[1 .. $], mem, arguments);
                return;
            }

            if (typedArguments !is null || hasBlock) throw new UsageError("External commands do not accept typed arguments");
            mem.lastStatus = runExternal(argv, mem);
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
            if (hasBlock) parseProgram(body);
            return;
        }
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
                    executeProgram(body, mem);
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
        if (isEndStatement(current_.kind)) {
            throw new YshError("source requires a path");
        }
        auto words = readCommandWord(mem);
        if (words.length != 1 || !isEndStatement(current_.kind)) {
            throw new YshError("source accepts exactly one path");
        }

        string source;
        try { source = cast(string)read(words[0]); }
        catch (FileException error) {
            mem.errorFile.writeln("ysh-d: ", error.msg);
            mem.lastStatus = 1;
            return;
        }
        auto savedMode = mem.returnMode;
        mem.returnMode = ReturnMode.shell;
        scope (exit) mem.returnMode = savedMode;
        try {
            executeProgram(source, mem);
        } catch (ProcReturn control) {
            mem.lastStatus = control.status;
        }
    }

    private void parseEval(Memory mem) {
        advance(); // eval
        string[] words;
        while (!isEndStatement(current_.kind)) {
            words ~= readCommandWord(mem);
        }
        if (mem.options.get("simple_eval_builtin") && words.length != 1) {
            mem.errorFile.writeln("ysh-d: eval requires exactly one argument");
            mem.lastStatus = 2;
            return;
        }
        executeProgram(words.join(" "), mem);
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
        while (!isEndStatement(current_.kind)) words ~= readCommandWord(mem);
        if (words.length > 1) throw new ParseError("return accepts at most one status word");
        if (syntaxOnly_) return;
        int status = mem.lastStatus;
        if (words.length) {
            try { status = to!int(words[0]); }
            catch (Exception error) { throw new FatalRuntimeError("return status must be an integer"); }
        }
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
            adjustDepth(depth, kind);
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
        command.expressionCondition = current_.kind == TokenKind.leftParen;
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

    private void moveTo(size_t offset) {
        lexer_ = new Lexer(source_, true, offset, true, parserOptions_);
        current_ = lexer_.next();
    }

    private string collectIfCondition(out bool legacy) {
        auto start = current_.offset;
        auto scanner = new CommandScanner(source_[start .. $], returnMode_, parserOptions_);
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
            if (!depth && commandStart && token.kind == TokenKind.name && token.text == "then") {
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
            adjustDepth(depth, token.kind);
            commandStart = token.kind == TokenKind.newline || token.kind == TokenKind.semicolon ||
                token.kind == TokenKind.andIf || token.kind == TokenKind.orIf || token.kind == TokenKind.pipe;
        }
    }

    private string collectLegacyIfBody() {
        auto start = current_.offset;
        auto scanner = new CommandScanner(source_[start .. $], returnMode_, parserOptions_);
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
            adjustDepth(depth, token.kind);
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
        current_ = lexer_.next();
        if (previousSyntax) return;
        try { mem.lastStatus = condition.eval(mem) ? 0 : 1; }
        catch (EreError error) {
            mem.errorFile.writeln(error.msg);
            mem.lastStatus = 2;
        }
    }

    private void parseWhile(Memory mem) {
        advance(); // while
        bool expressionCondition = current_.kind == TokenKind.leftParen;
        auto conditionSource = expressionCondition
            ? collectParenthesizedExpression()
            : collectConditionThroughBlock();
        auto bodySource = collectBlock();

        if (syntaxOnly_) {
            if (expressionCondition) validateExpression(conditionSource);
            else parseProgram(conditionSource);
            parseProgram(bodySource);
            return;
        }
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
            throw new ParseError("for loops support at most three loop variables");
        }
        require(TokenKind.inKeyword, "in");
        if (current_.kind != TokenKind.leftParen) {
            if (names.length > 2) {
                throw new ParseError("Shell-word for loops accept at most two variables");
            }
            string[] words;
            size_t argumentWordCount;
            string firstWordSource;
            while (current_.kind != TokenKind.leftBrace) {
                if (isEndStatement(current_.kind)) {
                    throw new YshError("expected '{' after for-loop words");
                }
                auto begin = current_.offset;
                words ~= readCommandWord(mem);
                if (!argumentWordCount++) firstWordSource = strip(source_[begin .. current_.offset]);
            }
            bool bareIdentifier = firstWordSource.length && asciiIdentifierStart(firstWordSource[0]);
            foreach (ch; firstWordSource) if (!asciiIdentifierContinue(ch)) bareIdentifier = false;
            if (argumentWordCount == 1 && bareIdentifier && parserOptions_ !is null && parserOptions_.get("no_parse_bare_word"))
                throw new ParseError("Surround this loop word with parens or quotes (no_parse_bare_word)");
            auto bodySource = collectBlock();
            if (syntaxOnly_) {
                parseProgram(bodySource);
                return;
            }
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
        if (syntaxOnly_) {
            validateExpression(iterableSource);
            parseProgram(bodySource);
            return;
        }
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

    private void parseRead(Memory mem) {
        advance(); // read
        bool all;
        bool line;

        while (!isEndStatement(current_.kind) && current_.kind != TokenKind.leftParen) {
            if (atRawWord("--all")) {
                consumeRawWord("--all");
                all = true;
                continue;
            }
            if (atRawWord("--line")) {
                consumeRawWord("--line");
                line = true;
                continue;
            }
            throw new UsageError("read currently supports --all or --line");
        }

        if (all && line) {
            throw new YshError("read accepts only one of --all and --line");
        }

        import yshd.state : FramePlace;
        Value place = Value.place(new FramePlace(mem.currentFrame, "_reply"));
        if (current_.kind == TokenKind.leftParen) {
            auto values = parseTypedArguments("(" ~ collectParenthesizedExpression(true) ~ ")", true).eval(mem);
            if (values.positional.length != 1 || values.named.length || values.hasBlock ||
                    values.positional[0].kind != ValueKind.placeValue)
                throw new YshTypeError("read expects one Place argument");
            place = values.positional[0];
        }
        if (!isEndStatement(current_.kind)) throw new UsageError("read: unexpected word arguments");

        string result;
        bool endOfInput;
        if (all) {
            while (true) {
                auto chunk = mem.inputFile.readln();
                if (chunk.length == 0) {
                    break;
                }
                result ~= chunk;
            }
        } else {
            result = mem.inputFile.readln();
            endOfInput = !result.length;
            if (result.length != 0 && result[$ - 1] == '\n') {
                result = result[0 .. $ - 1];
                if (result.length != 0 && result[$ - 1] == '\r') {
                    result = result[0 .. $ - 1];
                }
            }
        }

        place.placeValue.assign(Value.str(result));
        mem.lastStatus = endOfInput && !all ? 1 : 0;
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
            executeProgram(body, mem);
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

    private string[] readCommandWord(Memory mem) {
        lastWordTriple_ = false;
        if (current_.kind == TokenKind.doubleQuoted && current_.text == "$@") {
            advance();
            return syntaxOnly_ ? [] : mem.shellArguments.dup;
        }
        if (current_.kind == TokenKind.doubleQuoted && current_.text.length > 6 &&
                current_.text[0 .. 2] == "${" && current_.text[$ - 4 .. $] == "[@]}" &&
                current_.text != "${BASH_REMATCH[@]}") {
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
            advance();
            if (syntaxOnly_) return [""];
            string[] result;
            auto match = mem.regexMatch;
            if (match !is null) foreach (index, start; match.starts)
                result ~= start < 0 ? "" : match.subject[start .. match.ends[index]];
            return result;
        }
        if (current_.kind == TokenKind.at) {
            return parseArraySplice(mem);
        }
        return [readScalarWord(mem).text()];
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
                auto start = current_.offset;
                size_t substitutionEnd;
                auto text = parseScalarSubstitution(mem, substitutionEnd);
                bool quoted = start + 1 < source_.length && source_[start + 1] == '"';
                if (quoted && substitutionEnd - start >= 7 && source_[start + 1 .. start + 4] == "\"\"\"")
                    tripleQuoted = true;
                result.append(text, quoted);
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
                if (syntaxOnly_) validateExpression(expression);
                else result ~= stringify(evaluate(expression, mem));
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
                if (!syntaxOnly_) result ~= to!string(mem.lastStatus);
                position += 2;
                continue;
            }

            if (ch == '$' && position + 1 < content.length &&
                    content[position + 1] == '0') {
                if (!syntaxOnly_) result ~= mem.argumentZero;
                position += 2;
                continue;
            }

            if (ch == '$' && position + 1 < content.length &&
                    content[position + 1] >= '1' && content[position + 1] <= '9') {
                if (!syntaxOnly_) result ~= mem.shellArgument(content[position + 1] - '0');
                position += 2;
                continue;
            }

            if (ch == '$' && position + 1 < content.length && content[position + 1] == '@') {
                if (!syntaxOnly_) result ~= mem.shellArguments.join(" ");
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
        if (nameEnd < parameter.length && parameter[nameEnd] == '[') {
            auto close = substitutionClose(parameter, nameEnd, '[', ']');
            if (close + 1 != parameter.length) throw new YshError("Untranslated shell array parameter operation");
            if (syntaxOnly_) return "";
            auto value = mem.get(name);
            if (value.kind != ValueKind.bashArrayValue && value.kind != ValueKind.bashAssocValue)
                throw new YshTypeError("Shell indexed expansion expects BashArray or BashAssoc");
            auto key = parameter[nameEnd + 1 .. close];
            if (key == "@" || key == "*") {
                import yshd.value : shellArrayValues;
                return shellArrayValues(value).join(" ");
            }
            auto indexParser = new ProgramParser(key, false, returnMode_, true, parserOptions_);
            key = indexParser.readScalarWord(mem).text();
            if (value.kind == ValueKind.bashArrayValue) {
                try { key = to!string(to!long(key)); }
                catch (Exception error) { throw new FatalRuntimeError("Untranslated shell arithmetic index"); }
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
            auto wordParser = new ProgramParser(word, syntaxOnly_, returnMode_, false, parserOptions_);
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
            while (output.length != 0 &&
                    (output[$ - 1] == '\n' || output[$ - 1] == '\r')) {
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
            if (syntaxOnly_) {
                validateExpression(expression);
                return "";
            }
            return stringify(evaluate(expression, mem));
        }
        if (current_.kind == TokenKind.question) {
            endOffset = current_.offset + 1;
            advance();
            return syntaxOnly_ ? "" : to!string(mem.lastStatus);
        }
        if (current_.kind == TokenKind.integer) {
            auto number = current_.text;
            endOffset = current_.offset + number.length;
            advance();
            return syntaxOnly_ ? "" : (number[0] == '0' ? mem.argumentZero : mem.shellArgument(number[0] - '0')) ~ number[1 .. $];
        }
        if (current_.kind != TokenKind.name) {
            throw new YshError("$ substitution expects a variable name or [expression]");
        }
        auto value = syntaxOnly_ ? "" : mem.wordVariable(current_.text);
        endOffset = current_.offset + current_.text.length;
        advance();
        return value;
    }

    private string captureCommandOutput(string command, Memory mem) {
        if (syntaxOnly_) {
            parseProgram(command);
            return "";
        }
        auto result = captureSourceOutput(command, mem,
            (string source, Memory childMemory) {
                executeProgram(source, childMemory);
                return childMemory.lastStatus;
            });
        if (mem.options.get("command_sub_errexit") && mem.lastStatus != 0)
            throw new Errexit(mem.lastStatus);
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
        bool atomExpected = true;
        while (current_.kind != TokenKind.eof) {
            if (consumeDelimitedAtom(atomExpected)) continue;
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
        case TokenKind.caseKeyword:
        case TokenKind.esacKeyword:
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

void executeProgram(string source, Memory mem) {
    auto parser = new ProgramParser(source, false, mem.returnMode, false, mem.options);
    parser.execute(mem);
    // Batch and command-list evaluation return zero for an empty program.
    // Do this afterward so a first command's $? still sees its caller's status.
    if (!parser.executedCommand_) mem.lastStatus = 0;
}

/// Parse with no interpreter state. No command or expression is evaluated.
void parseProgram(string source, ReturnMode returnMode = ReturnMode.shell, ShellOptions options = null) {
    try {
        (new ProgramParser(source, true, returnMode, false, options)).parse();
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

unittest {
    auto mem = new Memory();
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
