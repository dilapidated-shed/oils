module yshd.resources;

/// Same stdlib sources as the reference resource loader, embedded as data.
/// -Jstdlib binds the bytes to the tested source tree at build time.
bool standardLibrarySource(string path, out string source) {
    static foreach (name; [
        "osh/bash-strict.sh", "osh/byo-server.sh", "osh/no-quotes.sh",
        "osh/task-five.sh", "osh/two.sh", "ysh/args.ysh", "ysh/def.ysh",
        "ysh/list.ysh", "ysh/math.ysh", "ysh/quote.ysh", "ysh/stream.ysh",
        "ysh/table.ysh", "ysh/yblocks.ysh", "methods.ysh", "prelude.ysh",
        "draft-synch.ysh", "osh/byo-server-test.sh", "osh/no-quotes-test.sh",
        "osh/two-test.sh", "ysh/args-test.ysh", "ysh/def-test.ysh",
        "ysh/list-test.ysh", "ysh/math-test.ysh", "ysh/quote-test.ysh",
        "ysh/yblocks-test.ysh", "README.md", "TEST.sh"
    ]) {
        if (path == name) { source = import(name); return true; }
    }
    return false;
}
