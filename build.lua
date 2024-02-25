local URL = "cdelord.fr/luax"
local YEARS = os.date "2021-%Y"
local AUTHORS = "Christophe Delord"
local appname = "luax"

local F = require "F"
local fs = require "fs"

local I = F.I{URL=URL, YEARS=YEARS, AUTHORS=AUTHORS}

section(I[[
This file is part of luax.

luax is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

luax is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with luax.  If not, see <https://www.gnu.org/licenses/>.

For further information about luax you can visit
http://$(URL)
]])

help.name "LuaX"
help.description(I[[
Lua eXtended
Copyright (C) $(YEARS) $(AUTHORS) (https://$(URL))

luax is a Lua interpreter and REPL based on Lua 5.4
augmented with some useful packages.
luax can also produce standalone scripts from Lua scripts.

luax runs on several platforms with no dependency:

- Linux (x86_64, aarch64)
- MacOS (x86_64, aarch64)
- Windows (x86_64)

luax can « compile » scripts executable on all supported platforms
(LuaX must be installed on the target environment).
]])

section [[
WARNING: This file has been generated by bang. DO NOT MODIFY IT.
If you need to update the build system, please modify build.lua
and run bang to regenerate build.ninja.
]]

-- list of targets used for cross compilation (with Zig only)
local luax_sys = dofile"libluax/sys/sys.lua"
local targets = F(luax_sys.targets)
local host = targets
    : filter(function(t) return t.zig_os==luax_sys.os and t.zig_arch==luax_sys.arch end)
    : head()
if not host then
    F.error_without_stack_trace(luax_sys.os.." "..luax_sys.arch..": unknown host")
end

local usage = I{
    title = function(s) return F.unlines {s, (s:gsub(".", "="))}:rtrim() end,
    list = function(t) return t:map(F.prefix"    - "):unlines():rtrim() end,
    targets = targets:map(F.partial(F.nth, "name")),
}[[
$(title "LuaX bang file usage")

The LuaX bang file can be given options to customize the LuaX compilation.

Without any options, LuaX is:
    - compiled with Zig
    - optimized for speed

$(title "Compilation mode")

bang -- fast        Code optimized for speed (default)
bang -- small       Code optimized for size
bang -- debug       Compiled with debug informations and no optimization
bang -- san         Compiled with ASan and UBSan (implies clang)

$(title "Compiler")

bang -- zig         Compile LuaX with Zig (default)
bang -- gcc         Compile LuaX with gcc
bang -- clang       Compile LuaX with clang

Zig is downloaded by the ninja file.
gcc and clang must be already installed.

Supported targets:
$(list(targets))
]]

if F.elem("help", arg) then
    print(usage)
    os.exit(0)
end

local mode = nil -- fast, small, debug
local compiler = nil -- zig, gcc, clang
local san = nil

F.foreach(arg, function(a)
    local function set_mode()
        if mode~=nil then F.error_without_stack_trace(a..": duplicate compilation mode", 2) end
        mode = a
    end
    local function set_compiler()
        if compiler~=nil then F.error_without_stack_trace(a..": duplicate compiler specification", 2) end
        compiler = a
    end

    case(a) {
        fast    = set_mode,
        small   = set_mode,
        debug   = set_mode,
        zig     = set_compiler,
        gcc     = set_compiler,
        clang   = set_compiler,
        san     = function() san = true end,
        [F.Nil] = function()
            F.error_without_stack_trace((a)..": unknown parameter\n\n"..usage, 1)
        end,
    } ()
end)

mode = F.default("fast", mode)
if san then compiler = "clang" end

compiler = F.default("zig", compiler)

-- Only zig can cross-compile LuaX for all targets
local cross_compilation = compiler=="zig"
if not cross_compilation then
    targets = F{host}
end

if san and compiler~="clang" then
    F.error_without_stack_trace("The sanitizers requires LuaX to be compiled with clang")
end

section("Compilation options")
comment(("Compilation mode: %s"):format(mode))
comment(("Compiler        : %s"):format(compiler))
comment(("Sanitizers      : %s"):format(san and "ASan and UbSan" or "none"))

--===================================================================
section "Build environment"
---------------------------------------------------------------------

var "builddir" ".build"

var "bin" "$builddir/bin"
var "lib" "$builddir/lib"
var "doc" "$builddir/doc"
var "tmp" "$builddir/tmp"
var "test" "$builddir/test"

local compile = {}
local test = {}
local doc = {}

--===================================================================
section "Compiler"
---------------------------------------------------------------------

local zig_version = "0.11.0"
--local zig_version = "0.12.0-dev.2341+92211135f"

local compiler_deps = {}

local function zig_target(t)
    return {"-target", F{t.zig_arch, t.zig_os, t.zig_libc}:str"-"}
end

case(compiler) {

    zig = function()
        local cache = case(luax_sys.os) {
            linux   = os.getenv"HOME"/".local/var/cache/luax",
            macos   = os.getenv"HOME"/".local/var/cache/luax",
            windows = os.getenv"LOCALAPPDATA"/"luax",
        }
        var "zig"       (cache / "zig" / zig_version / "zig")
        var "zig_cache" (cache / "zig" / zig_version / "cache")

        build "$zig" { "tools/install_zig.sh",
            description = {"GET zig", zig_version},
            command = {"$in", zig_version, "$out"},
            pool = "console",
        }

        compiler_deps = { "$zig" }
        local function zig_rules(target)
            local cache_dir = F{
                target.name,
                mode,
                san and "sanitizers" or {},
            }:flatten():str"-"
            local zig_cache = {
                "ZIG_GLOBAL_CACHE_DIR=${zig_cache}"/cache_dir.."-global",
                "ZIG_LOCAL_CACHE_DIR=${zig_cache}"/cache_dir.."-local",
            }
            local target_opt = zig_target(target)

            var("cc-"..target.name) { zig_cache, "$zig cc", target_opt }
            var("ar-"..target.name) { zig_cache, "$zig ar" }
            var("ld-"..target.name) { zig_cache, "$zig cc", target_opt }
        end
        targets:foreach(function(target) zig_rules(target) end)
    end,

    gcc = function()
        var("cc-"..host.name) "gcc"
        var("ar-"..host.name) "ar"
        var("ld-"..host.name) "gcc"
    end,

    clang = function()
        var("cc-"..host.name) "clang"
        var("ar-"..host.name) "ar"
        var("ld-"..host.name) "clang"
    end,

}()

local include_path = {
    ".",
    "$tmp",
    "lua",
    "ext/c/lz4/lib",
    "libluax",
}

local lto_opt = case(compiler) {
    zig   = "-flto=thin",
    gcc   = "-flto",
    clang = "-flto=thin",
}

local sanitizer_cflags = san and {
    "-g -fno-omit-frame-pointer -fno-optimize-sibling-calls",
    "-fsanitize=address",
    "-fsanitize=undefined",
    "-fsanitize=float-divide-by-zero",
    --"-fsanitize=unsigned-integer-overflow",
    "-fsanitize=implicit-conversion",
    "-fsanitize=local-bounds",
    "-fsanitize=float-cast-overflow",
    "-fsanitize=nullability-arg",
    "-fsanitize=nullability-assign",
    "-fsanitize=nullability-return",
} or {}

local sanitizer_ext_cflags = san and {
    "-g -fno-omit-frame-pointer -fno-optimize-sibling-calls",
    "-fsanitize=address",
    --"-fsanitize=undefined",
    --"-fsanitize=float-divide-by-zero",
    --"-fsanitize=unsigned-integer-overflow",
    --"-fsanitize=implicit-conversion",
    "-fsanitize=local-bounds",
    "-fsanitize=float-cast-overflow",
    "-fsanitize=nullability-arg",
    "-fsanitize=nullability-assign",
    "-fsanitize=nullability-return",
} or {}

local sanitizer_ldflags = san and {
    "-fsanitize=address",
    "-fsanitize=undefined",
} or {}

local sanitizer_options = san and {
    "export ASAN_OPTIONS=check_initialization_order=1:detect_stack_use_after_return=1:detect_leaks=1;",
    "export UBSAN_OPTIONS=print_stacktrace=1;",
} or {}

local host_cflags = {
    "-std=gnu2x",
    "-O3",
    "-fPIC",
    F.map(F.prefix"-I", include_path),
    case(host.zig_os) {
        linux = "-DLUA_USE_LINUX",
        macos = "-DLUA_USE_MACOSX",
        windows = {},
    },
    "-Werror",
    "-Wall",
    "-Wextra",
    case(compiler) {
        zig = {
            "-Wno-constant-logical-operand",
        },
        gcc = {},
        clang = {
            "-Wno-constant-logical-operand",
        },
    },
}

local host_ldflags = {
    "-rdynamic",
    "-s",
    "-lm",
    case(compiler) {
        zig = {},
        gcc = {
            "-Wstringop-overflow=0",
        },
        clang = {},
    },
}

local cflags = {
    "-std=gnu2x",
    case(mode) {
        fast  = "-O3",
        small = "-Os",
        debug = "-g",
    },
    "-fPIC",
    F.map(F.prefix"-I", include_path),
}

local luax_cflags = {
    cflags,
    "-Werror",
    "-Wall",
    "-Wextra",
    case(compiler) {
        zig = {
            "-Weverything",
            "-Wno-padded",
            "-Wno-reserved-identifier",
            "-Wno-disabled-macro-expansion",
            "-Wno-used-but-marked-unused",
            "-Wno-documentation-unknown-command",
            "-Wno-declaration-after-statement",
            "-Wno-unsafe-buffer-usage",
            "-Wno-pre-c2x-compat",
        },
        gcc = {},
        clang = {
            "-Weverything",
            "-Wno-padded",
            "-Wno-reserved-identifier",
            "-Wno-disabled-macro-expansion",
            "-Wno-used-but-marked-unused",
            "-Wno-documentation-unknown-command",
            "-Wno-declaration-after-statement",
            "-Wno-unsafe-buffer-usage",
            "-Wno-pre-c2x-compat",
        },
    },
    sanitizer_cflags,
}

local ext_cflags = {
    cflags,
    case(compiler) {
        zig = {
            "-Wno-constant-logical-operand",
        },
        gcc = {},
        clang = {
            "-Wno-constant-logical-operand",
        },
    },
    sanitizer_ext_cflags,
}

local ldflags = {
    case(mode) {
        fast  = "-s",
        small = "-s",
        debug = {},
    },
    "-lm",
    case(compiler) {
        zig = {
            "-Wno-single-bit-bitfield-constant-conversion",
        },
        gcc = {
            "-Wstringop-overflow=0",
        },
        clang = {},
    },
    sanitizer_ldflags,
}

local cc = {}
local cc_ext = {}
local ar = {}
local ld = {}
local so = {}

cc.host = rule "cc-host" {
    description = "CC $in",
    command = { "$cc-"..host.name, "-c", host_cflags, "-MD -MF $depfile $in -o $out" },
    implicit_in = compiler_deps,
    depfile = "$out.d",
}

ld.host = rule "ld-host" {
    description = "LD $out",
    command = { "$ld-"..host.name, host_ldflags, "$in -o $out" },
    implicit_in = compiler_deps,
}

targets:foreach(function(target)

    local lto = case(mode) {
        fast = case(target.zig_os) {
            linux   = lto_opt,
            macos   = {},
            windows = lto_opt,
        },
        small = {},
        debug = {},
    }
    local target_flags = {
        "-DLUAX_ARCH='\""..target.zig_arch.."\"'",
        "-DLUAX_OS='\""..target.zig_os.."\"'",
        "-DLUAX_LIBC='\""..target.zig_libc.."\"'",
    }
    local lua_flags = {
        case(target.zig_os) {
            linux   = "-DLUA_USE_LINUX",
            macos   = "-DLUA_USE_MACOSX",
            windows = {},
        },
    }
    local target_ld_flags = {
        case(target.zig_libc) {
            gnu  = "-rdynamic",
            musl = {},
            none = "-rdynamic",
        },
        case(target.zig_os) {
            linux   = {},
            macos   = {},
            windows = "-lws2_32 -ladvapi32",
        },
    }
    local target_so_flags = {
        "-shared",
    }
    local target_opt = case(compiler) {
        zig   = zig_target(target),
        gcc   = {},
        clang = {},
    }
    cc[target.name] = rule("cc-"..target.name) {
        description = "CC $in",
        command = {
            "$cc-"..target.name, target_opt, "-c", lto, luax_cflags, lua_flags, target_flags, "-MD -MF $depfile $in -o $out",
            case(target.zig_os) {
                linux   = {},
                macos   = {},
                windows = "$build_as_dll",
            }
        },
        implicit_in = compiler_deps,
        depfile = "$out.d",
    }
    cc_ext[target.name] = rule("cc_ext-"..target.name) {
        description = "CC $in",
        command = {
            "$cc-"..target.name, target_opt, "-c", lto, ext_cflags, lua_flags, "$additional_flags", "-MD -MF $depfile $in -o $out",
        },
        implicit_in = compiler_deps,
        depfile = "$out.d",
    }
    ld[target.name] = rule("ld-"..target.name) {
        description = "LD $out",
        command = {
            "$ld-"..target.name, target_opt, lto, ldflags, target_ld_flags, "$in -o $out",
        },
        implicit_in = compiler_deps,
    }
    so[target.name] = rule("so-"..target.name) {
        description = "SO $out",
        command = {
            "$cc-"..target.name, target_opt, lto, ldflags, target_ld_flags, target_so_flags, "$in -o $out",
        },
        implicit_in = compiler_deps,
    }

    ar[target.name] = rule("ar-"..target.name) {
        description = "AR $out",
        command = {
            "$ar-"..target.name, "-crs $out $in",
        },
        implicit_in = compiler_deps,
    }

end)

--===================================================================
section "Third-party modules update"
---------------------------------------------------------------------

build "update_modules" {
    description = "UPDATE",
    command = "tools/update-third-party-modules.sh $builddir/update",
    pool = "console",
}

--===================================================================
section "lz4 cli"
---------------------------------------------------------------------

var "lz4" "$tmp/lz4"

build "$lz4" { ld.host,
    ls "ext/c/lz4/**.c"
    : map(function(src)
        return build("$tmp/obj/lz4"/src:splitext()..".o") { "cc-host", src }
    end),
}

--===================================================================
section "LuaX sources"
---------------------------------------------------------------------

local linux_only = F{
    "ext/c/luasocket/serial.c",
    "ext/c/luasocket/unixdgram.c",
    "ext/c/luasocket/unixstream.c",
    "ext/c/luasocket/usocket.c",
    "ext/c/luasocket/unix.c",
    "ext/c/linenoise/linenoise.c",
    "ext/c/linenoise/utf8.c",
}
local windows_only = F{
    "ext/c/luasocket/wsocket.c",
}
local ignored_sources = F{
    "ext/c/lqmath/src/imath.c",
}

local sources = {
    lua_c_files = ls "lua/*.c"
        : filter(function(name) return F.not_elem(name:basename(), {"lua.c", "luac.c"}) end),
    lua_main_c_files = F{ "lua/lua.c" },
    luax_main_c_files = F{ "luax/luax.c" },
    libluax_main_c_files = F{ "luax/libluax.c" },
    luax_c_files = ls "libluax/**.c",
    third_party_c_files = ls "ext/c/**.c"
        : filter(function(name) return not name:match "lz4/programs" end)
        : difference(linux_only)
        : difference(windows_only)
        : difference(ignored_sources),
    linux_third_party_c_files = linux_only,
    windows_third_party_c_files = windows_only,
}

--===================================================================
section "Native Lua interpreter"
---------------------------------------------------------------------

var "lua" "$tmp/lua"

var "lua_path" (
    F{
        ".",
        "$tmp",
        "libluax",
        ls "libluax/*" : filter(fs.is_dir),
        "luax",
    }
    : flatten()
    : map(function(path) return path / "?.lua" end)
    : str ";"
)

build "$lua" { ld.host,
    (sources.lua_c_files .. sources.lua_main_c_files) : map(function(src)
        return build("$tmp/obj/lua"/src:splitext()..".o") { cc.host, src }
    end),
}

--===================================================================
section "LuaX configuration"
---------------------------------------------------------------------

comment [[
The configuration file (luax_config.h and luax_config.lua)
are created in `$tmp`
]]

var "luax_config_h"   "$tmp/luax_config.h"
var "luax_config_lua" "$tmp/luax_config.lua"

local luax_config_params = F {
    AUTHORS = AUTHORS,
    URL = URL,
} : items() : map(function(kv) return ("-e '%s=%q'"):format(kv:unpack()) end) : unwords()

rule "ypp" {
    description = "YPP $out",
    command = { "$lua tools/ypp.lua", luax_config_params, "$in -o $out" },
    implicit_in = {
        "$lua",
        "tools/ypp.lua",
        ".git/refs/tags",
    },
}

build "$luax_config_h"   { "ypp", "tools/luax_config.h.in" }
build "$luax_config_lua" { "ypp", "tools/luax_config.lua.in" }

--===================================================================
section "Lua runtime"
---------------------------------------------------------------------

rule "bundle" {
    description = "BUNDLE $out",
    command = {
        "PATH=$tmp:$$PATH",
        "LUA_PATH=\"$lua_path\"",
        "$lua luax/luax_bundle.lua $args $in > $out",
    },
    implicit_in = {
        "$lz4",
        "$lua",
        "luax/luax_bundle.lua",
        "$luax_config_lua",
    },
}

local luax_runtime = {
    ls "libluax/**.lua",
    ls "ext/**.lua",
}

local luax_runtime_bundle = build "$tmp/lua_runtime_bundle.c" {
    "bundle", "$luax_config_lua", luax_runtime,
    args = "-lib -c",
}

local luax_app = {
    ls "luax/**.lua",
    "$luax_config_lua",
}

local luax_app_bundle = build "$tmp/lua_app_bundle.c" {
    "bundle", luax_app,
    args = {
        "-app -c",
        "-name=luax",
    },
}

--===================================================================
section "Binaries and shared libraries"
---------------------------------------------------------------------

local binaries = {}
local libraries = {}
local cross_binaries = {}

local liblua = {}
local libluax = {}
local main_luax = {}
local main_libluax = {}
local binary = {}
local shared_library = {}

-- imath is also provided by qmath, both versions shall be compatible
rule "diff" {
    description = "DIFF $in",
    command = "diff $in > $out",
}
phony "check_limath_version" {
    build "$tmp/check_limath_header_version" { "diff", "ext/c/lqmath/src/imath.h", "ext/c/limath/src/imath.h" },
    build "$tmp/check_limath_source_version" { "diff", "ext/c/lqmath/src/imath.c", "ext/c/limath/src/imath.c" },
}

targets:foreach(function(target)

    local ext = case(target.zig_os) {
        linux   = "",
        macos   = "",
        windows = ".exe",
    }

    local libext = case(target.zig_os) {
        linux   = ".so",
        macos   = ".dylib",
        windows = ".dll",
    }

    liblua[target.name] = build("$tmp"/target.name/"lib/liblua.a") { ar[target.name],
        F.flatten {
            sources.lua_c_files,
        } : map(function(src)
            return build("$tmp"/target.name/"obj"/src:splitext()..".o") { cc_ext[target.name], src }
        end),
    }

    libluax[target.name] = build("$tmp"/target.name/"lib/libluax.a") { ar[target.name],
        F.flatten {
            sources.luax_c_files,
            luax_runtime_bundle,
        } : map(function(src)
            return build("$tmp"/target.name/"obj"/src:splitext()..".o") { cc[target.name], src,
                implicit_in = {
                    case(src:basename():splitext()) {
                        version = "$luax_config_h",
                    } or {},
                },
            }
        end),
        F.flatten {
            sources.third_party_c_files,
            case(target.zig_os) {
                linux   = sources.linux_third_party_c_files,
                macos   = sources.linux_third_party_c_files,
                windows = sources.windows_third_party_c_files,
            },
        } : map(function(src)
            return build("$tmp"/target.name/"obj"/src:splitext()..".o") { cc_ext[target.name], src,
                additional_flags = case(src:basename():splitext()) {
                    usocket = "-Wno-#warnings",
                },
                implicit_in = case(src:basename():splitext()) {
                    limath = "check_limath_version",
                    imath  = "check_limath_version",
                },
            }
        end),
    }

    main_luax[target.name] = F.flatten { sources.luax_main_c_files }
        : map(function(src)
            return build("$tmp"/target.name/"obj"/src:splitext()..".o") { cc[target.name], src,
                implicit_in = "$luax_config_h",
            }
        end)

    main_libluax[target.name] = F.flatten { sources.libluax_main_c_files }
        : map(function(src)
                return build("$tmp"/target.name/"obj"/src:splitext()..".o") { cc[target.name], src,
                    build_as_dll = case(target.zig_os) {
                        windows = "-DLUA_BUILD_AS_DLL -DLUA_LIB",
                    },
                }
            end)
    binary[target.name] = build("$tmp"/target.name/"bin"/appname..ext) { ld[target.name],
        main_luax[target.name],
        main_libluax[target.name],
        liblua[target.name],
        libluax[target.name],
        build("$tmp"/target.name/"obj"/luax_app_bundle:splitext()..".o") { cc[target.name], luax_app_bundle },
    }

    shared_library[target.name] = target_libc~="musl" and not san and
        build("$tmp"/target.name/"lib/libluax"..libext) { so[target.name],
            main_libluax[target.name],
            case(target.zig_os) {
                linux   = {},
                macos   = liblua[target.name],
                windows = liblua[target.name],
            },
            libluax[target.name],
    }

end)

rule "cp" {
    description = "CP $out",
    command = "cp -f $in $out",
}

var "luax" ("$bin"/binary[host.name]:basename())

acc(binaries) {
    build "$luax" { "cp", binary[host.name] }
}

if shared_library[host.name] then
    acc(libraries) {
        build("$lib"/shared_library[host.name]:basename()) { "cp", shared_library[host.name] }
    }
end

if cross_compilation then

    var "luaxc" "$bin/luaxc"

    local luaxc_config_params = F {
        ZIG_VERSION = zig_version,
        URL = URL,
        YEARS = YEARS,
        AUTHORS = AUTHORS,
    } : items() : map(function(kv) return ("-e '%s=%q'"):format(kv:unpack()) end) : unwords()

    rule "ypp-luaxc" {
        description = "YPP $out",
        command = { "$luax tools/ypp.lua", luaxc_config_params, "$in -o $out" },
        implicit_in = {
            "$luax",
            "tools/ypp.lua",
        },
    }

    local luaxc_archive = "$tmp/luaxc"
    local files = {
        targets : map(function(target)
            local obj = luaxc_archive/target.name/"obj"
            return F{
                "$tmp"/target.name/"lib/liblua.a",
                "$tmp"/target.name/"lib/libluax.a",
                "$tmp"/target.name/"obj/luax/libluax.o",
                "$tmp"/target.name/"obj/luax/luax.o",
                "$tmp/luax_config.h",
                "$tmp/luax_config.lua",
            } : map(function(src_obj)
                return build(obj/src_obj:basename()) { "cp", src_obj }
            end)
        end),
        F{
            "luax/luax_bundle.lua",
        } : map(function(src)
            return build(luaxc_archive/"luax"/src:basename()) { "cp", src }
        end),
        targets : map(function(target)
            return {
                F{
                    binary[target.name],
                    "$bin/luax.lua",
                    "$bin/luax-pandoc.lua",
                } : map(function(bin)
                    return build(luaxc_archive/target.name/"bin"/bin:basename()) { "cp", bin }
                end),
                F{
                    shared_library[target.name],
                    "$lib/luax.lua",
                } : map(function(lib)
                    return build(luaxc_archive/target.name/"lib"/lib:basename()) { "cp", lib }
                end),
            }
        end),
    }

    build "$tmp/luaxc.tar.xz" { files,
        description = "TAR $out",
        command = {
            "XZ_OPT='-9'",
            "tar cJf $out $in",
            [[--transform "s#$tmp/luaxc##"]],
        },
    }

    build "$tmp/luaxc.sh" { "ypp-luaxc", "tools/luaxc.sh.in" }

    acc(cross_binaries) {
        build "$luaxc" { "$tmp/luaxc.sh", "$tmp/luaxc.tar.xz",
            description = "CAT $out",
            command = "cat $in > $out && chmod +x $out",
        }
    }

end

--===================================================================
section "LuaX Lua implementation"
---------------------------------------------------------------------

--===================================================================
section "$lib/luax.lua"
---------------------------------------------------------------------

local lib_luax_sources = {
    ls "libluax/**.lua",
    ls "ext/lua/**.lua",
}

acc(libraries) {
    build "$lib/luax.lua" {
        "bundle", "$luax_config_lua", lib_luax_sources,
        args = "-lib -lua",
    }
}

--===================================================================
section "$bin/luax.lua"
---------------------------------------------------------------------

rule "luax-bundle" {
    description = "BUNDLE $out",
    command = {
        "PATH=$tmp:$$PATH",
        "LUA_PATH=\"$lua_path\"",
        "LUAX_LIB=$lib",
        "$lua luax/luax.lua -q $args -o $out $in",
    },
    implicit_in = {
        "$lz4",
        "$lua",
        "luax/luax_bundle.lua",
        "$lib/luax.lua",
        "$luax_config_lua",
    },
}

acc(binaries) {
    build "$bin/luax.lua" {
        "luax-bundle", ls "luax/**.lua",
        args = "-t lua",
    }
}

--===================================================================
section "$bin/luax-pandoc.lua"
---------------------------------------------------------------------

acc(binaries) {
    build "$bin/luax-pandoc.lua" {
        "luax-bundle", ls "luax/**.lua",
        args = "-t pandoc",
    }
}

--===================================================================
section "Tests"
---------------------------------------------------------------------

local test_sources = ls "tests/luax-tests/*.*"
local test_main = "tests/luax-tests/main.lua"

acc(test) {

---------------------------------------------------------------------

    build "$test/test-1-luax_executable.ok" {
        description = "TEST $out",
        command = {
            sanitizer_options,
            "$luax -q -o $test/test-luax",
                test_sources : difference(ls "tests/luax-tests/to_be_imported-*.lua"),
            "&&",
            "PATH=$bin:$tmp:$$PATH",
            "LUA_PATH='tests/luax-tests/?.lua;luax/?.lua'",
            "LUA_CPATH='foo/?.so'",
            "TEST_NUM=1",
            "LUAX=$luax",
            "ARCH="..host.zig_arch, "OS="..host.zig_os, "LIBC="..host.zig_libc,
            "$test/test-luax Lua is great",
            "&&",
            "touch $out",
        },
        implicit_in = {
            "$luax",
            test_sources,
        },
    },

}

if not san then
acc(test) {

---------------------------------------------------------------------

    build "$test/test-2-lib.ok" {
        description = "TEST $out",
        command = {
            sanitizer_options,
            "export LUA_CPATH=;",
            "eval \"$$($luax env)\";",
            "PATH=$bin:$tmp:$$PATH",
            "LUA_PATH='tests/luax-tests/?.lua'",
            "TEST_NUM=2",
            "ARCH="..host.zig_arch, "OS="..host.zig_os, "LIBC="..host.zig_libc,
            "$lua -l libluax", test_main, "Lua is great",
            "&&",
            "touch $out",
        },
        implicit_in = {
            "$lua",
            "$luax",
            libraries,
            test_sources,
        },
    },

---------------------------------------------------------------------

    build "$test/test-3-lua.ok" {
        description = "TEST $out",
        command = {
            sanitizer_options,
            "PATH=$bin:$tmp:$$PATH",
            "LIBC=lua LUA_PATH='$lib/?.lua;tests/luax-tests/?.lua'",
            "TEST_NUM=3",
            "ARCH="..host.zig_arch, "OS="..host.zig_os, "LIBC=lua",
            "$lua -l luax", test_main, "Lua is great",
            "&&",
            "touch $out",
        },
        implicit_in = {
            "$lua",
            "$lib/luax.lua",
            libraries,
            test_sources,
        },
    },

---------------------------------------------------------------------

    build "$test/test-4-lua-luax-lua.ok" {
        description = "TEST $out",
        command = {
            sanitizer_options,
            "PATH=$bin:$tmp:$$PATH",
            "LIBC=lua LUA_PATH='$lib/?.lua;tests/luax-tests/?.lua'",
            "TEST_NUM=4",
            "ARCH="..host.zig_arch, "OS="..host.zig_os, "LIBC=lua",
            "$bin/luax.lua", test_main, "Lua is great",
            "&&",
            "touch $out",
        },
        implicit_in = {
            "$lua",
            "$bin/luax.lua",
            test_sources,
        },
    },

---------------------------------------------------------------------

    build "$test/test-5-pandoc-luax-lua.ok" {
        description = "TEST $out",
        command = {
            sanitizer_options,
            "PATH=$bin:$tmp:$$PATH",
            "LIBC=lua LUA_PATH='$lib/?.lua;tests/luax-tests/?.lua'",
            "TEST_NUM=5",
            "ARCH="..host.zig_arch, "OS="..host.zig_os, "LIBC=lua",
            "pandoc lua -l luax", test_main, "Lua is great",
            "&&",
            "touch $out",
        },
        implicit_in = {
            "$lua",
            "$lib/luax.lua",
            libraries,
            test_sources,
        },
    },

---------------------------------------------------------------------

    build "$test/test-ext-1-lua.ok" { "tests/external_interpreter_tests/external_interpreters.lua",
        description = "TEST $out",
        command = {
            sanitizer_options,
            "eval \"$$($luax env)\";",
            "$luax -q -t lua -o $test/ext-lua $in",
            "&&",
            "PATH=$bin:$tmp:$$PATH",
            "TARGET=lua",
            "$test/ext-lua Lua is great",
            "&&",
            "touch $out",
        },
        implicit_in = {
            "$lib/luax.lua",
            "$luax",
            binaries,
        },
    },

---------------------------------------------------------------------

    build "$test/test-ext-3-luax.ok" { "tests/external_interpreter_tests/external_interpreters.lua",
        description = "TEST $out",
        command = {
            sanitizer_options,
            "eval \"$$($luax env)\";",
            "$luax -q -t luax -o $test/ext-luax $in",
            "&&",
            "PATH=$bin:$tmp:$$PATH",
            "TARGET=luax",
            "$test/ext-luax Lua is great",
            "&&",
            "touch $out",
        },
        implicit_in = {
            "$lib/luax.lua",
            "$luax",
        },
    },

---------------------------------------------------------------------

    build "$test/test-ext-4-pandoc.ok" { "tests/external_interpreter_tests/external_interpreters.lua",
        description = "TEST $out",
        command = {
            sanitizer_options,
            "eval \"$$($luax env)\";",
            "$luax -q -t pandoc -o $test/ext-pandoc $in",
            "&&",
            "PATH=$bin:$tmp:$$PATH",
            "TARGET=pandoc",
            "$test/ext-pandoc Lua is great",
            "&&",
            "touch $out",
        },
        implicit_in = {
            "$lib/luax.lua",
            "$luax",
            binaries,
        },
    },

---------------------------------------------------------------------

}
end

--===================================================================
section "Documentation"
---------------------------------------------------------------------

local markdown_sources = ls "doc/src/*.md"

rule "lsvg" {
    command = "$luax tools/lsvg.lua $in -o $out --MF $depfile -- $args",
    depfile = "$builddir/tmp/lsvg/$out.d",
    implicit_in = {
        "$luax",
        "tools/lsvg.lua",
    },
}

local images = {
    build "doc/luax-banner.svg"         {"lsvg", "doc/src/luax-logo.lua", args={1024,  192}},
    build "doc/luax-logo.svg"           {"lsvg", "doc/src/luax-logo.lua", args={ 256,  256}},
    build "$builddir/luax-banner.png"   {"lsvg", "doc/src/luax-logo.lua", args={1024,  192, "sky"}},
    build "$builddir/luax-banner.jpg"   {"lsvg", "doc/src/luax-logo.lua", args={1024,  192, "sky"}},
    build "$builddir/luax-social.png"   {"lsvg", "doc/src/luax-logo.lua", args={1280,  640, F.show(URL)}},
    build "$builddir/luax-logo.png"     {"lsvg", "doc/src/luax-logo.lua", args={1024, 1024}},
    build "$builddir/luax-logo.jpg"     {"lsvg", "doc/src/luax-logo.lua", args={1024, 1024}},
}

acc(doc)(images)

local pandoc_gfm = {
    "pandoc",
    "--to gfm",
    "--lua-filter doc/src/fix_links.lua",
    "--fail-if-warnings",
}

local gfm = pipe {
    rule "ypp.md" {
        description = "YPP $in",
        command = {
            "LUAX=$luax",
            "$luax tools/ypp.lua --MD --MT $out --MF $depfile $in -o $out",
        },
        depfile = "$out.d",
        implicit_in = {
            "$luax",
            "tools/ypp.lua",
        },
    },
    rule "pandoc" {
        description = "PANDOC $out",
        command = { pandoc_gfm, "$in -o $out" },
        implicit_in = {
            "doc/src/fix_links.lua",
            images,
        },
    },
}

acc(doc) {

    gfm "README.md" { "doc/src/luax.md" },

    markdown_sources : map(function(src)
        return gfm("doc"/src:basename()) { src }
    end)

}

--===================================================================
section "Shorcuts"
---------------------------------------------------------------------

acc(compile) {binaries, libraries, cross_binaries}

install "bin" {binaries, cross_binaries}
install "lib" {libraries}

clean "$builddir"

phony "compile" (compile)
default "compile"
help "compile" "compile LuaX"

if #test > 0 then

    phony "test-fast" (test[1])
    help "test-fast" "run LuaX tests (fast, host tests only)"

    phony "test" (test)
    help "test" "run all LuaX tests"

end

phony "doc" (doc)
help "doc" "update LuaX documentation"

phony "all" {"compile", "test", "doc"}
help "all" "alias for compile, test and doc"

phony "update" "update_modules"
help "update" "update third-party modules"
