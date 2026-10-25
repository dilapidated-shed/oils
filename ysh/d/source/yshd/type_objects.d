module yshd.type_objects;

import std.string : indexOf, join;
import yshd.value : Value, ValueKind, YshDict, YshObject, YshTypeError;

/// builtin/method_type.py:Index__ owns one cache for the shell's type objects.
/// A parameterized type is an ordinary Obj, without new type enforcement.
class YshTypeIndexFunction {
    private Value[string] instances;

    private Value* stringProperty(Value object, string name) {
        if (object.kind != ValueKind.objectValue)
            throw new YshTypeError("Type parameter should be Obj");
        auto property = object.objectValue.properties.find(name);
        return property !is null && property.kind == ValueKind.stringValue ? property : null;
    }

    Value invoke(Value[] arguments, YshDict named) {
        if (arguments.length != 2 || (named !is null && named.length))
            throw new YshTypeError("Type index expects an Obj and parameters");
        auto nameValue = stringProperty(arguments[0], "name");
        if (nameValue is null) throw new YshTypeError("Broken type Obj name invariant");
        auto name = nameValue.stringValue;
        if (name.indexOf(',') >= 0 || name.indexOf('[') >= 0 || name.indexOf(']') >= 0)
            throw new YshTypeError("Broken type Obj name invariant");
        Value[] parameters;
        if (arguments[1].kind == ValueKind.objectValue) parameters = [arguments[1]];
        else if (arguments[1].kind == ValueKind.list) parameters = arguments[1].listValue.items;
        else throw new YshTypeError("Type index expected Obj or List");
        auto expected = name == "List" ? 1 : name == "Dict" ? 2 : 0;
        if (parameters.length != expected)
            throw new YshTypeError("Wrong number of type parameters");
        string[] names;
        foreach (parameter; parameters) {
            auto property = stringProperty(parameter, "unique_id");
            if (property is null) {
                property = stringProperty(parameter, "name");
                if (property is null || property.stringValue.indexOf(',') >= 0 ||
                        property.stringValue.indexOf('[') >= 0 || property.stringValue.indexOf(']') >= 0)
                    throw new YshTypeError("Broken type parameter name invariant");
            }
            names ~= property.stringValue;
        }
        auto identity = name ~ "[" ~ names.join(",") ~ "]";
        if (auto existing = identity in instances) return *existing;
        auto properties = new YshDict();
        properties.set("unique_id", Value.str(identity));
        auto result = Value.object(new YshObject(null, properties));
        instances[identity] = result;
        return result;
    }
}

unittest {
    import std.stdio : File;
    import yshd.expr : evaluate;
    import yshd.program : executeProgram;
    import yshd.state : Memory;
    import yshd.value : sameIdentity, YshError;
    auto mem = new Memory(File.tmpfile(), File.tmpfile());
    auto nested = evaluate("Dict[Str,List[Int]]", mem);
    assert(sameIdentity(nested, evaluate("Dict[Str,List[Int]]", mem)));
    assert(!sameIdentity(nested, evaluate("Dict[Str,List[Int]]", new Memory())));
    assert(!sameIdentity(evaluate("List[Int]", mem), evaluate("List[Str]", mem)));
    foreach (source; ["Bool[Str]", "List[Int, Str]", "Dict[Int]", "List[3]",
            "List[Object(null, {})]"]) {
        bool rejected;
        try { evaluate(source, mem); }
        catch (YshError error) { rejected = error.status == 3; }
        assert(rejected, source);
    }
    executeProgram(`
        func next(self, index) { return (self.offset + index) }
        var prototype = Object(null, {__index__: next})
        var indexed = Object(prototype, {offset: 40})
        var answer = indexed[2]
    `, mem);
    assert(mem.get("answer").integerValue == 42);
    bool rejected;
    try { evaluate("next === next", mem); }
    catch (YshError error) { rejected = error.status == 3; }
    assert(rejected);
}
