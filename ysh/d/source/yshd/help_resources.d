module yshd.help_resources;

import std.file : FileException, read;
import std.process : environment;
import std.string : indexOf;
import std.zip : ZipArchive, ZipException;

import yshd.value : InterpreterFailure;
import yshd.help_data : canonicalHelpResources, sourceVersionBytes;

/// The IOError/OSError boundary used by core/util.py:PrintEmbeddedHelp.
class ResourceError : Exception {
    this(string message) { super(message); }
}

interface ResourceLoader {
    string get(string relativePath);
}

private string resourcePath(string root, string relativePath) {
    if (relativePath.length && relativePath[0] == '/') return relativePath;
    return root.length == 0 || root[$ - 1] == '/' ? root ~ relativePath : root ~ "/" ~ relativePath;
}

class FileResourceLoader : ResourceLoader {
    private string root;
    this(string root) { this.root = root; }
    string get(string relativePath) {
        auto path = resourcePath(root, relativePath);
        if (path.indexOf('\0') >= 0)
            throw new InterpreterFailure("NUL byte in resource pathname");
        try { return cast(string)read(path); }
        catch (FileException error) { throw new ResourceError(error.msg); }
    }
}

/// The native backend has a closed resource table, as in cpp/core.cc's
/// _ResourceLoader. Both cards and version come from the original build's
/// inputs; an unknown path does not fall through to the working directory.
class EmbeddedResourceLoader : ResourceLoader {
    private bool includeHelp;

    this(bool includeHelp = true) { this.includeHelp = includeHelp; }

    string get(string relativePath) {
        if (relativePath == "oils-version.txt") return sourceVersionBytes;
        if (includeHelp) {
            foreach (resource; canonicalHelpResources)
                if (resource.path == relativePath) return resource.contents;
        }
        throw new ResourceError("Resource not found: " ~ relativePath);
    }
}

private uint littleEndian32(const(ubyte)[] bytes, size_t offset) {
    return cast(uint)bytes[offset] | (cast(uint)bytes[offset + 1] << 8) |
        (cast(uint)bytes[offset + 2] << 16) | (cast(uint)bytes[offset + 3] << 24);
}

/// Like Python 2 zipimport, an OVM archive may follow an executable prefix.
/// Its EOCD must be the final 22 bytes (zipimport does not accept comments).
class ZipResourceLoader : ResourceLoader {
    private ZipArchive archive;
    this(string path) {
        if (path.indexOf('\0') >= 0)
            throw new InterpreterFailure("NUL byte in resource archive pathname");
        ubyte[] bytes;
        try { bytes = cast(ubyte[])read(path); }
        catch (FileException error) { throw new InterpreterFailure("Cannot open resource archive: " ~ error.msg); }
        if (bytes.length < 22)
            throw new InterpreterFailure("Invalid resource ZIP archive");
        auto end = bytes.length - 22;
        if (bytes[end .. end + 4] != [0x50, 0x4b, 0x05, 0x06] || bytes[end + 20] || bytes[end + 21])
            throw new InterpreterFailure("Invalid resource ZIP end record");
        auto directorySize = littleEndian32(bytes, end + 12);
        auto directoryOffset = littleEndian32(bytes, end + 16);
        if (directorySize > end || directoryOffset > end - directorySize)
            throw new InterpreterFailure("Invalid resource ZIP directory");
        auto prefix = end - directorySize - directoryOffset;
        try { archive = new ZipArchive(bytes[prefix .. $]); }
        catch (ZipException error) { throw new InterpreterFailure("Invalid resource ZIP archive: " ~ error.msg); }
    }

    string get(string relativePath) {
        if (relativePath.indexOf('\0') >= 0)
            throw new InterpreterFailure("NUL byte in resource archive member");
        auto member = relativePath in archive.directory;
        if (member is null) throw new ResourceError("Resource not found: " ~ relativePath);
        try { return cast(string)archive.expand(*member); }
        // zipimport.get_data reports ordinary missing/bad entry I/O as IOError.
        catch (ZipException error) { throw new ResourceError(error.msg); }
    }
}

/// Capture this at shell initialization, before commands can change cwd or
/// ENV. The default matches the original native embedded backend. Explicit
/// file and OVM roots retain the Python loader compatibility route; a relative
/// file root stays relative for later Get calls, and never falls back.
ResourceLoader defaultResourceLoader(string argumentZero) {
    if (environment.get("_OVM_IS_BUNDLE") == "1") {
        auto loader = new ZipResourceLoader(environment.get("_OVM_PATH"));
        environment.remove("_OVM_IS_BUNDLE");
        environment.remove("_OVM_PATH");
        return loader;
    }
    auto root = environment.get("_OVM_RESOURCE_ROOT");
    if (root.length) return new FileResourceLoader(root);
    return new EmbeddedResourceLoader();
}
