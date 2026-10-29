//! Colour for the code in a diff, one line at a time.
//!
//! ponytail: a lexer, not a parser — keywords, strings, numbers, comments and
//! capitalised names, with one keyword list shared by the C-family languages.
//! A line knows nothing of the one before it, so the inside of a block comment
//! is only recognised by its leading `*`. Tree-sitter per language is the
//! upgrade if this ever reads wrong often enough to matter.

const std = @import("std");

pub const Kind = enum { plain, keyword, string, number, comment, type_name };

pub const Token = struct { start: usize, end: usize, kind: Kind };

pub const Lang = enum {
    /// Not code, or not one we know: drawn plain.
    none,
    /// `//` and `/* */` comments: TS, JS, Zig, Go, C, Java, C#, Swift…
    c_like,
    /// As `c_like`, where `'a` is a lifetime rather than a string.
    rust,
    /// `#` comments: Python, shell, Ruby, YAML, TOML.
    hash,
};

pub fn langOf(path: []const u8) Lang {
    const ext = std.fs.path.extension(path);
    const c_like = [_][]const u8{ ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".vue", ".svelte", ".zig", ".go", ".c", ".h", ".cc", ".cpp", ".hpp", ".java", ".kt", ".cs", ".swift", ".php", ".dart", ".scala", ".css", ".scss", ".json", ".jsonc" };
    const hash = [_][]const u8{ ".py", ".sh", ".bash", ".zsh", ".fish", ".rb", ".yml", ".yaml", ".toml", ".pl", ".r", ".nix" };
    for (c_like) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return .c_like;
    if (std.ascii.eqlIgnoreCase(ext, ".rs")) return .rust;
    for (hash) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return .hash;
    const base = std.fs.path.basename(path);
    if (std.mem.eql(u8, base, "Dockerfile") or std.mem.eql(u8, base, "Makefile")) return .hash;
    return .none;
}

const keywords = [_][]const u8{
    "abstract",   "and",      "as",     "async",     "await",      "break",     "case",      "catch", "chan",
    "class",      "comptime", "const",  "continue",  "def",        "default",   "defer",     "del",   "do",
    "elif",       "else",     "enum",   "errdefer",  "export",     "extends",   "extern",    "false", "final",
    "finally",    "fn",       "for",    "from",      "func",       "function",  "go",        "if",    "impl",
    "implements", "import",   "in",     "inline",    "instanceof", "interface", "is",        "keyof", "lambda",
    "let",        "loop",     "match",  "mod",       "mut",        "namespace", "new",       "nil",   "None",
    "not",        "null",     "of",     "or",        "orelse",     "override",  "package",   "pass",  "private",
    "protected",  "pub",      "public", "raise",     "readonly",   "return",    "satisfies", "self",  "static",
    "struct",     "super",    "switch", "this",      "throw",      "trait",     "true",      "True",  "False",
    "try",        "type",     "typeof", "undefined", "union",      "unsafe",    "use",       "var",   "void",
    "where",      "while",    "with",   "yield",
};

fn isKeyword(word: []const u8) bool {
    for (keywords) |k| if (std.mem.eql(u8, k, word)) return true;
    return false;
}

fn isIdent(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$';
}

/// `line` cut into coloured runs, into `out`; what does not fit is left
/// plain. The runs cover the line end to end.
pub fn tokenize(lang_in: Lang, line: []const u8, out: []Token) []Token {
    var n: usize = 0;
    if (lang_in == .none or line.len == 0) return out[0..0];
    const rust = lang_in == .rust;
    const lang: Lang = if (rust) .c_like else lang_in;

    const push = struct {
        fn f(o: []Token, count: *usize, t: Token) void {
            if (t.end <= t.start) return;
            if (count.* > 0 and o[count.* - 1].kind == t.kind and o[count.* - 1].end == t.start) {
                o[count.* - 1].end = t.end;
                return;
            }
            if (count.* == o.len) {
                // Out of room: the last run takes the rest. It is the plain
                // one put there below, not whatever came before it.
                o[o.len - 1].end = t.end;
                return;
            }
            if (count.* == o.len - 1) {
                o[count.*] = .{ .start = t.start, .end = t.end, .kind = .plain };
                count.* += 1;
                return;
            }
            o[count.*] = t;
            count.* += 1;
        }
    }.f;

    // The middle of a block comment, by its usual leading star. One that
    // opens on this line is the loop's: it may close with code after it.
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (lang == .c_like and std.mem.startsWith(u8, trimmed, "*")) {
        if (!std.mem.startsWith(u8, trimmed, "*=")) {
            push(out, &n, .{ .start = 0, .end = line.len, .kind = .comment });
            return out[0..n];
        }
    }

    var i: usize = 0;
    while (i < line.len) {
        const ch = line[i];
        const start = i;
        if (lang == .c_like and ch == '/' and i + 1 < line.len and line[i + 1] == '/') {
            push(out, &n, .{ .start = i, .end = line.len, .kind = .comment });
            break;
        }
        if (lang == .c_like and ch == '/' and i + 1 < line.len and line[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, line, i + 2, "*/");
            i = if (close) |c| c + 2 else line.len;
            push(out, &n, .{ .start = start, .end = i, .kind = .comment });
            continue;
        }
        if (lang == .hash and ch == '#') {
            push(out, &n, .{ .start = i, .end = line.len, .kind = .comment });
            break;
        }
        // A Rust lifetime, `'a` or `'static`: a char literal that starts with
        // a letter closes right after it, `'a'`.
        if (rust and ch == '\'' and i + 1 < line.len and isIdent(line[i + 1]) and (i + 2 >= line.len or line[i + 2] != '\'')) {
            i += 1;
            push(out, &n, .{ .start = start, .end = i, .kind = .plain });
            continue;
        }
        if (ch == '"' or ch == '\'' or ch == '`') {
            i += 1;
            while (i < line.len and line[i] != ch) : (i += 1) {
                if (line[i] == '\\') i += 1;
            }
            i = @min(i + 1, line.len);
            push(out, &n, .{ .start = start, .end = i, .kind = .string });
            continue;
        }
        if (std.ascii.isDigit(ch) and (i == 0 or !isIdent(line[i - 1]))) {
            while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_' or line[i] == '.')) i += 1;
            push(out, &n, .{ .start = start, .end = i, .kind = .number });
            continue;
        }
        if (isIdent(ch)) {
            while (i < line.len and isIdent(line[i])) i += 1;
            const word = line[start..i];
            const kind: Kind = if (isKeyword(word)) .keyword else if (std.ascii.isUpper(word[0])) .type_name else .plain;
            push(out, &n, .{ .start = start, .end = i, .kind = kind });
            continue;
        }
        i += 1;
        push(out, &n, .{ .start = start, .end = i, .kind = .plain });
    }
    return out[0..n];
}

/// Where two versions of a line differ: the run between their common start
/// and common end, as `[from, to)` in each. Null when there is nothing in
/// common worth pointing out — the whole line changed.
pub fn changedSpan(old: []const u8, new: []const u8) ?struct { old: [2]usize, new: [2]usize } {
    var pre: usize = 0;
    while (pre < old.len and pre < new.len and old[pre] == new[pre]) pre += 1;
    var suf: usize = 0;
    while (suf < old.len - pre and suf < new.len - pre and old[old.len - 1 - suf] == new[new.len - 1 - suf]) suf += 1;
    // Not into the middle of a UTF-8 sequence.
    while (pre > 0 and pre < old.len and old[pre] & 0xC0 == 0x80) pre -= 1;
    while (suf > 0 and old.len - suf < old.len and old[old.len - suf] & 0xC0 == 0x80) suf -= 1;
    while (suf > 0 and new.len - suf < new.len and new[new.len - suf] & 0xC0 == 0x80) suf -= 1;
    const common = pre + suf;
    // Under a third in common: highlighting it all would say nothing.
    if (common * 3 < @max(old.len, new.len)) return null;
    return .{ .old = .{ pre, old.len - suf }, .new = .{ pre, new.len - suf } };
}

test "a TypeScript line comes apart into its kinds" {
    var buf: [64]Token = undefined;
    const line = "const n: Foo = 42; // why";
    const t = tokenize(.c_like, line, &buf);
    try std.testing.expectEqual(Kind.keyword, t[0].kind);
    try std.testing.expectEqualStrings("const", line[t[0].start..t[0].end]);
    var saw_type = false;
    var saw_number = false;
    for (t) |tok| {
        if (tok.kind == .type_name) saw_type = std.mem.eql(u8, line[tok.start..tok.end], "Foo");
        if (tok.kind == .number) saw_number = true;
    }
    try std.testing.expect(saw_type and saw_number);
    try std.testing.expectEqual(Kind.comment, t[t.len - 1].kind);
    try std.testing.expectEqualStrings("// why", line[t[t.len - 1].start..t[t.len - 1].end]);
    // End to end, no gaps.
    try std.testing.expectEqual(@as(usize, 0), t[0].start);
    for (t[1..], 0..) |tok, k| try std.testing.expectEqual(t[k].end, tok.start);
    try std.testing.expectEqual(line.len, t[t.len - 1].end);
}

test "a block comment that closes on its line leaves the code after it" {
    var buf: [64]Token = undefined;
    const line = "/* eslint-disable */ const x = 1;";
    const t = tokenize(.c_like, line, &buf);
    try std.testing.expectEqual(Kind.comment, t[0].kind);
    try std.testing.expectEqualStrings("/* eslint-disable */", line[t[0].start..t[0].end]);
    for (t) |tok| {
        if (std.mem.eql(u8, line[tok.start..tok.end], "const")) break try std.testing.expectEqual(Kind.keyword, tok.kind);
    } else return error.NoKeyword;
    // Unclosed, it runs to the end of the line as before.
    const open = tokenize(.c_like, "/** docs", &buf);
    try std.testing.expectEqual(@as(usize, 1), open.len);
    try std.testing.expectEqual(Kind.comment, open[0].kind);
}

test "strings keep their escapes, and other languages their comments" {
    var buf: [64]Token = undefined;
    const t = tokenize(.c_like, "x = 'it\\'s' + y", &buf);
    var s: ?Token = null;
    for (t) |tok| if (tok.kind == .string) {
        s = tok;
    };
    try std.testing.expectEqual(@as(usize, 4), s.?.start);
    try std.testing.expectEqual(@as(usize, 11), s.?.end);
    const py = tokenize(.hash, "x = 1  # note", &buf);
    try std.testing.expectEqual(Kind.comment, py[py.len - 1].kind);
    try std.testing.expectEqual(@as(usize, 0), tokenize(.none, "anything", &buf).len);
    try std.testing.expectEqual(Lang.c_like, langOf("a/b/item.type.ts"));
    try std.testing.expectEqual(Lang.none, langOf("README.md"));

    // Rust: lifetimes are not strings, a char literal still is.
    const rs = "fn f<'a>(x: &'static str) -> char { 'x' }";
    var strings: usize = 0;
    for (tokenize(langOf("lib.rs"), rs, &buf)) |tok| if (tok.kind == .string) {
        strings += 1;
        try std.testing.expectEqualStrings("'x'", rs[tok.start..tok.end]);
    };
    try std.testing.expectEqual(@as(usize, 1), strings);

    // Out of tokens: the rest of the line is plain, not the last token's kind.
    var small: [4]Token = undefined;
    const long = "a = 1 + 2 + 3";
    const cut = tokenize(.c_like, long, &small);
    try std.testing.expectEqual(@as(usize, 4), cut.len);
    try std.testing.expectEqual(Kind.plain, cut[3].kind);
    try std.testing.expectEqual(long.len, cut[3].end);
}

test "the changed part of a line, and none when all of it changed" {
    const s = changedSpan("readonly id: Item['id'];", "readonly id: Items['id'];").?;
    try std.testing.expectEqual(@as(usize, 17), s.old[0]);
    try std.testing.expectEqual(s.old[0], s.new[0]);
    try std.testing.expectEqual(@as(usize, 17), s.old[1]);
    try std.testing.expectEqual(@as(usize, 18), s.new[1]);
    try std.testing.expect(changedSpan("abc", "xyz") == null);
}
