module yshd.help_resources_test;

version (unittest) {

import std.conv : to;
import std.digest.sha : sha256Of;
import std.exception : assertThrown;
import std.file : getcwd, mkdirRecurse, rmdirRecurse, chdir, tempDir, write;
import std.path : buildPath;
import std.process : environment;
import std.zip : ArchiveMember, CompressionMethod, ZipArchive;
import core.sys.posix.unistd : getpid;

import yshd.help_data : canonicalHelpResources, canonicalTopicMetadata,
    helpMetadataEntries, helpResourceCount, helpVersionSha256,
    minimalTopicMetadata, sourceVersionBytes;
import yshd.help_resources : EmbeddedResourceLoader, FileResourceLoader,
    ResourceError, ResourceLoader, ZipResourceLoader, defaultResourceLoader;
import yshd.value : InterpreterFailure;

private string digest(string bytes) {
    string result;
    foreach (value; sha256Of(bytes)) {
        result ~= "0123456789abcdef"[value >> 4];
        result ~= "0123456789abcdef"[value & 15];
    }
    return result;
}

unittest {
    assert(sourceVersionBytes == import("oils-version.txt"));
    assert(digest(sourceVersionBytes) == helpVersionSha256);
    assert(canonicalTopicMetadata().length == helpMetadataEntries);
    assert(canonicalHelpResources.length == helpResourceCount);
    assert(minimalTopicMetadata().length == 0);
    auto loader = new EmbeddedResourceLoader();
    assert(loader.get("oils-version.txt") == sourceVersionBytes);
    foreach (resource; canonicalHelpResources) {
        assert(loader.get(resource.path) == resource.contents);
        assert(digest(resource.contents) == resource.sha256);
    }
    foreach (topic, chapter; canonicalTopicMetadata())
        if (chapter.ptr is null) assert(loader.get("_devbuild/help/" ~ topic).length > 0);
    assertThrown!ResourceError(loader.get("_devbuild/help/../gen/help_meta.py"));
    assertThrown!ResourceError(loader.get("_devbuild/help/help\0ignored"));
    auto minimal = new EmbeddedResourceLoader(false);
    assert(minimal.get("oils-version.txt") == sourceVersionBytes);
    assertThrown!ResourceError(minimal.get("_devbuild/help/help"));
}

unittest {
    auto work = buildPath(tempDir(), "ysh-d-help-resources-" ~ to!string(getpid()));
    mkdirRecurse(buildPath(work, "first", "root", "_devbuild", "help"));
    mkdirRecurse(buildPath(work, "second", "root", "_devbuild", "help"));
    scope (exit) rmdirRecurse(work);
    write(buildPath(work, "first", "root", "oils-version.txt"), "first\r\nignored");
    write(buildPath(work, "first", "root", "_devbuild", "help", "topic"), "one\0byte\xff");
    write(buildPath(work, "second", "root", "_devbuild", "help", "topic"), "second");
    write(buildPath(work, "first", "root", "empty"), "");
    auto previous = getcwd();
    scope (exit) chdir(previous);
    chdir(buildPath(work, "first"));
    auto loader = new FileResourceLoader("root");
    assert(loader.get("oils-version.txt") == "first\r\nignored");
    assert(loader.get("_devbuild/help/topic") == "one\0byte\xff");
    assert(loader.get("empty") == "");
    assert(loader.get("_devbuild/help/../../oils-version.txt") == "first\r\nignored");
    assertThrown!ResourceError(loader.get("missing"));
    assertThrown!InterpreterFailure(loader.get("empty\0ignored"));
    chdir(buildPath(work, "second"));
    assert(loader.get("_devbuild/help/topic") == "second");
}

unittest {
    auto work = buildPath(tempDir(), "ysh-d-help-zip-" ~ to!string(getpid()));
    mkdirRecurse(work);
    scope (exit) rmdirRecurse(work);
    auto archive = new ZipArchive();
    foreach (index, bytes; ["zip-version\nignored", "stored\0\xff", "deflated\n", ""]) {
        auto member = new ArchiveMember();
        member.name = ["oils-version.txt", "_devbuild/help/stored", "_devbuild/help/deflated", "_devbuild/help/empty"][index];
        member.expandedData = cast(ubyte[])bytes.dup;
        member.compressionMethod = index == 2 ? CompressionMethod.deflate : CompressionMethod.none;
        archive.addMember(member);
    }
    auto archiveBytes = cast(string)archive.build();
    auto path = buildPath(work, "bundle");
    write(path, "arbitrary executable prefix\0" ~ archiveBytes);
    auto loader = new ZipResourceLoader(path);
    assert(loader.get("oils-version.txt") == "zip-version\nignored");
    assert(loader.get("_devbuild/help/stored") == "stored\0\xff");
    assert(loader.get("_devbuild/help/deflated") == "deflated\n");
    assert(loader.get("_devbuild/help/empty") == "");
    assertThrown!ResourceError(loader.get("missing"));
    assertThrown!InterpreterFailure(loader.get("_devbuild/help/stored\0ignored"));
    archive.comment = "comment";
    write(buildPath(work, "commented"), archive.build());
    assertThrown!InterpreterFailure(new ZipResourceLoader(buildPath(work, "commented")));

    auto savedRoot = environment.get("_OVM_RESOURCE_ROOT");
    auto savedBundle = environment.get("_OVM_IS_BUNDLE");
    auto savedPath = environment.get("_OVM_PATH");
    bool hadRoot = "_OVM_RESOURCE_ROOT" in environment;
    bool hadBundle = "_OVM_IS_BUNDLE" in environment;
    bool hadPath = "_OVM_PATH" in environment;
    scope (exit) {
        if (hadRoot) environment["_OVM_RESOURCE_ROOT"] = savedRoot; else environment.remove("_OVM_RESOURCE_ROOT");
        if (hadBundle) environment["_OVM_IS_BUNDLE"] = savedBundle; else environment.remove("_OVM_IS_BUNDLE");
        if (hadPath) environment["_OVM_PATH"] = savedPath; else environment.remove("_OVM_PATH");
    }
    environment["_OVM_IS_BUNDLE"] = "1";
    environment["_OVM_PATH"] = path;
    environment["_OVM_RESOURCE_ROOT"] = buildPath(work, "missing");
    ResourceLoader selected = defaultResourceLoader("unused native executable");
    assert(selected.get("oils-version.txt") == "zip-version\nignored");
    assert(!("_OVM_IS_BUNDLE" in environment) && !("_OVM_PATH" in environment));
    assertThrown!ResourceError(defaultResourceLoader("unused").get("oils-version.txt"));
    environment["_OVM_RESOURCE_ROOT"] = "";
    assert(defaultResourceLoader("unused").get("oils-version.txt") == sourceVersionBytes);
}

}
