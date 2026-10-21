module yshd.var_check;

import yshd.expr : ParseError;

enum DefinitionKind { shellFunction, procedure, functionValue }

/// osh/cmd_parse.py:VarChecker checks each definition in source order. It
/// deliberately does no global analysis and does not infer lexical mutations.
class VariableChecker {
    private struct Scope {
        DefinitionKind kind;
        bool[string] names;
    }
    private Scope[] scopes;

    void enter(DefinitionKind kind) {
        if (scopes.length && ((scopes[0].kind == DefinitionKind.shellFunction) !=
                (kind == DefinitionKind.shellFunction)))
            throw new ParseError("Cannot mix nested shell function and proc/func definitions");
        scopes ~= Scope(kind);
    }

    void leave() { assert(scopes.length); --scopes.length; }

    void declare(string name, bool readOnly = false) {
        if (!scopes.length) return;
        if (readOnly) {
            if (scopes[$ - 1].kind != DefinitionKind.shellFunction)
                throw new ParseError("const cannot be inside proc or func; use var");
            return;
        }
        if (name in scopes[$ - 1].names) throw new ParseError("Variable was already declared: " ~ name);
        scopes[$ - 1].names[name] = true;
    }

    void mutate(string name) {
        if (scopes.length && name.length && name !in scopes[$ - 1].names)
            throw new ParseError("setvar could not find matching var " ~ name ~ " (OILS-ERR-10)");
    }
}
