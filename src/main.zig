const std = @import("std");
const testing = std.testing;
const meta = std.meta;
const trait = std.meta.trait;
const log = std.log.scoped(.wasm_zig);

var CALLBACK: usize = undefined;

// @TODO: Split these up into own error sets
pub const Error = error{
    /// Failed to initialize a `Config`
    ConfigInit,
    /// Failed to initialize an `Engine` (i.e. invalid config)
    EngineInit,
    /// Failed to initialize a `Store`
    StoreInit,
    /// Failed to initialize a `Module`
    ModuleInit,
    /// Failed to create a wasm function based on
    /// the given `Store` and functype
    FuncInit,
    /// Failed to initialize a new `Instance`
    InstanceInit,
};

pub const Config = opaque {
    pub fn init() !*Config {
        const config = wasm_config_new() orelse return Error.ConfigInit;
        return config;
    }

    extern "c" fn wasm_config_new() ?*Config;
};

pub const Engine = opaque {
    /// Initializes a new `Engine`
    pub fn init() !*Engine {
        return wasm_engine_new() orelse Error.EngineInit;
    }

    pub fn withConfig(config: *Config) !*Engine {
        return wasm_engine_new_with_config(config) orelse Error.EngineInit;
    }

    /// Frees the resources of the `Engine`
    pub fn deinit(self: *Engine) void {
        wasm_engine_delete(self);
    }

    extern "c" fn wasm_engine_new() ?*Engine;
    extern "c" fn wasm_engine_new_with_config(*Config) ?*Engine;
    extern "c" fn wasm_engine_delete(*Engine) void;
};

pub const Store = opaque {
    /// Initializes a new `Store` based on the given `Engine`
    pub fn init(engine: *Engine) !*Store {
        return wasm_store_new(engine) orelse Error.StoreInit;
    }

    /// Frees the resource of the `Store` itself
    pub fn deinit(self: *Store) void {
        wasm_store_delete(self);
    }

    extern "c" fn wasm_store_new(*Engine) ?*Store;
    extern "c" fn wasm_store_delete(*Store) void;
};

pub const Module = opaque {
    /// Initializes a new `Module` using the supplied Store and wasm bytecode
    pub fn init(store: *Store, bytes: []const u8) !*Module {
        var byte_vec = ByteVec.initWithCapacity(bytes.len);
        defer byte_vec.deinit();

        var i: usize = 0;
        var ptr = byte_vec.data;
        while (i < bytes.len) : (i += 1) {
            ptr.* = bytes[i];
            ptr += 1;
        }

        return wasm_module_new(store, &byte_vec) orelse return Error.ModuleInit;
    }

    pub fn deinit(self: *Module) void {
        wasm_module_delete(self);
    }

    extern "c" fn wasm_module_new(*Store, *const ByteVec) ?*Module;
    extern "c" fn wasm_module_delete(*Module) void;
};

fn cb(params: ?*const Valtype, results: ?*Valtype) callconv(.C) ?*Trap {
    const func = @intToPtr(fn () void, CALLBACK);
    func();
    return null;
}

pub const Func = opaque {
    pub const CallError = error{
        /// Failed to call the function
        /// and resulted into an error
        InnerError,
        /// When the user provided a different ResultType to `Func.call`
        /// than what is defined by the wasm binary
        InvalidResultType,
        /// The given argument count to `Func.call` mismatches that
        /// of the func argument count of the wasm binary
        InvalidParamCount,
        /// The wasm function number of results mismatch that of the given
        /// ResultType to `Func.Call`. Note that `void` equals to 0 result types.
        InvalidResultCount,
        /// Function call resulted in an unexpected trap.
        Trap,
    };
    pub fn init(store: *Store, callback: anytype) !*Func {
        const cb_meta = @typeInfo(@TypeOf(callback));
        switch (cb_meta) {
            .Fn => {
                if (cb_meta.Fn.args.len > 0 or cb_meta.Fn.return_type.? != void) {
                    @compileError("only callbacks with no input args and no results are currently supported");
                }
            },
            else => @compileError("only functions can be used as callbacks into Wasm"),
        }
        CALLBACK = @ptrToInt(callback);

        var args = ValtypeVec.empty();
        var results = ValtypeVec.empty();

        const functype = wasm_functype_new(&args, &results) orelse return Error.FuncInit;
        defer wasm_functype_delete(functype);

        return wasm_func_new(store, functype, cb) orelse Error.FuncInit;
    }

    /// Returns the `Func` as an `Extern`
    ///
    /// Owned by `self` and shouldn't be deinitialized
    pub fn asExtern(self: *Func) *Extern {
        return wasm_func_as_extern(self).?;
    }

    /// Returns the `Func` from an `Extern`
    /// return null if extern's type isn't a functype
    ///
    /// Owned by `extern_func` and shouldn't be deinitialized
    pub fn fromExtern(extern_func: *Extern) ?*Func {
        return extern_func.asFunc();
    }

    /// Creates a copy of the current `Func`
    /// returned copy is owned by the caller and must be freed
    /// by the owner
    pub fn copy(self: *Func) *Func {
        return self.wasm_func_copy().?;
    }

    /// Tries to call the wasm function
    /// expects `args` to be tuple of arguments
    pub fn call(self: *Func, comptime ResultType: type, args: anytype) CallError!ResultType {
        if (!comptime trait.isTuple(@TypeOf(args)))
            @compileError("Expected 'args' to be a tuple, but found type '" ++ @typeName(@TypeOf(args)) ++ "'");

        const args_len = args.len;
        comptime var wasm_args: [args_len]Value = undefined;
        inline for (wasm_args) |*arg, i| {
            arg.* = switch (@TypeOf(args[i])) {
                i32, u32 => .{ .kind = .i32, .of = .{ .i32 = @intCast(i32, args[i]) } },
                i64, u64 => .{ .kind = .i64, .of = .{ .i64 = @intCast(i64, args[i]) } },
                f32 => .{ .kind = .f32, .of = .{ .f32 = args[i] } },
                f64 => .{ .kind = .f64, .of = .{ .f64 = args[i] } },
                *Func => .{ .kind = .funcref, .of = .{ .ref = args[i] } },
                *Extern => .{ .kind = .anyref, .of = .{ .ref = args[i] } },
                else => |ty| @compileError("Unsupported argument type '" ++ @typeName(ty) + "'"),
            };
        }

        // TODO multiple return values
        const result_len: usize = if (ResultType == void) 0 else 1;
        if (result_len != self.wasm_func_result_arity()) return CallError.InvalidResultCount;
        if (args_len != self.wasm_func_param_arity()) return CallError.InvalidParamCount;

        const final_args = ValVec{
            .size = args_len,
            .data = if (args_len == 0) undefined else @ptrCast([*]Value, &wasm_args),
        };

        var result_list = ValVec.initWithCapacity(result_len);
        defer result_list.deinit();

        const trap = wasm_func_call(self, &final_args, &result_list);

        if (trap) |t| {
            t.deinit();
            // TODO handle trap message
            log.err("code unexpectedly trapped", .{});
            return CallError.Trap;
        }

        if (ResultType == void) return;

        // TODO: Handle multiple returns
        const result_ty = result_list.data[0];
        if (!matchesKind(ResultType, result_ty.kind)) return CallError.InvalidResultType;

        return switch (ResultType) {
            i32, u32 => @intCast(ResultType, result_ty.of.i32),
            i64, u64 => @intCast(ResultType, result_ty.of.i64),
            f32 => result_ty.of.f32,
            f64 => result_ty.of.f64,
            *Func => @ptrCast(?*Func, result_ty.of.ref).?,
            *Extern => @ptrCast(?*Extern, result_ty.of.ref).?,
            else => |ty| @compileError("Unsupported result type '" ++ @typeName(ty) ++ "'"),
        };
    }

    pub fn deinit(self: *Func) void {
        wasm_func_delete(self);
    }

    /// Returns tue if the given `kind` of `Valkind` can coerce to type `T`
    pub fn matchesKind(comptime T: type, kind: Valkind) bool {
        return switch (T) {
            i32, u32 => kind == .i32,
            i64, u64 => kind == .i64,
            f32 => kind == .f32,
            f64 => kind == .f64,
            *Func => kind == .funcref,
            *Extern => kind == .ref,
            else => false,
        };
    }

    extern "c" fn wasm_func_new(*Store, ?*c_void, Callback) ?*Func;
    extern "c" fn wasm_func_delete(*Func) void;
    extern "c" fn wasm_func_as_extern(*Func) ?*Extern;
    extern "c" fn wasm_func_copy(*const Func) ?*Func;
    extern "c" fn wasm_func_call(*Func, *const ValVec, *ValVec) ?*Trap;
    extern "c" fn wasm_func_result_arity(*Func) usize;
    extern "c" fn wasm_func_param_arity(*Func) usize;
};

pub const Instance = opaque {
    /// Initializes a new `Instance` using the given `store` and `mode`.
    /// The given slice defined in `import` must match what was initialized
    /// using the same `Store` as given.
    pub fn init(store: *Store, module: *Module, import: []const *Func) !*Instance {
        var trap: ?*Trap = null;
        var imports = ExternVec.initWithCapacity(import.len);
        defer imports.deinit();

        var ptr = imports.data;
        for (import) |func| {
            ptr.* = func.asExtern();
            ptr += 1;
        }

        const instance = wasm_instance_new(store, module, &imports, &trap);

        if (trap) |t| {
            defer t.deinit();
            // TODO handle trap message
            log.err("code unexpectedly trapped", .{});
            return Error.InstanceInit;
        }

        return instance orelse Error.InstanceInit;
    }

    /// Returns an export func by its name if found
    /// Asserts the export is of type `Func`
    /// The returned `Func` is a copy and must be freed by the caller
    pub fn getExportFunc(self: *Instance, name: []const u8) ?*Func {
        return if (self.getExport(name)) |exp| {
            defer exp.deinit(); // free the copy
            return exp.asFunc().copy();
        } else null;
    }

    /// Returns an export by its name and `null` when not found
    /// The `Extern` is copied and must be freed manually
    pub fn getExport(self: *Instance, name: []const u8) ?*Extern {
        var externs: ExternVec = undefined;
        wasm_instance_exports(self, &externs);
        defer externs.deinit();

        const instance_type = self.getType();
        defer instance_type.deinit();

        var type_exports = instance_type.exports();
        defer type_exports.deinit();

        return for (type_exports.toSlice()) |ty, index| {
            const t = ty orelse continue;
            const type_name = t.name();
            defer type_name.deinit();

            if (std.mem.eql(u8, name, type_name.toSlice())) {
                if (externs.data[index]) |ext| {
                    break ext.copy();
                }
            }
        } else null;
    }

    /// Returns an exported `Memory` when found and `null` when not.
    /// The result is copied and must be freed manually by calling `deinit()` on the result.
    pub fn getExportMem(self: *Instance, name: []const u8) ?*Memory {
        return if (self.getExport(name)) |exp| {
            defer exp.deinit(); // free the copy
            return exp.asMemory().copy();
        } else null;
    }

    /// Returns the `InstanceType` of the `Instance`
    pub fn getType(self: *Instance) *InstanceType {
        return wasm_instance_type(self).?;
    }

    /// Frees the `Instance`'s resources
    pub fn deinit(self: *Instance) void {
        wasm_instance_delete(self);
    }

    extern "c" fn wasm_instance_new(*Store, *const Module, *const ExternVec, *?*Trap) ?*Instance;
    extern "c" fn wasm_instance_delete(*Instance) void;
    extern "c" fn wasm_instance_exports(*Instance, *ExternVec) void;
    extern "c" fn wasm_instance_type(*const Instance) ?*InstanceType;
};

pub const Trap = opaque {
    pub fn deinit(self: *Trap) void {
        wasm_trap_delete(self);
    }

    /// Returns the trap message.
    /// Memory of the returned `ByteVec` must be freed using `deinit`
    pub fn message(self: *Trap) *ByteVec {
        var bytes: ?*ByteVec = null;
        wasm_trap_message(self, &bytes);
        return bytes.?;
    }

    extern "c" fn wasm_trap_delete(*Trap) void;
    extern "c" fn wasm_trap_message(*const Trap, out: *?*ByteVec) void;
};

pub const Extern = opaque {
    /// Returns the `Extern` as a function
    /// returns `null` when the given `Extern` is not a function
    ///
    /// Asserts `Extern` is of type `Func`
    pub fn asFunc(self: *Extern) *Func {
        return wasm_extern_as_func(self).?;
    }

    /// Returns the `Extern` as a `Memory` object
    /// returns `null` when the given `Extern` is not a memory object
    ///
    /// Asserts `Extern` is of type `Memory`
    pub fn asMemory(self: *Extern) *Memory {
        return wasm_extern_as_memory(self).?;
    }

    /// Returns the `Extern` as a `Global`
    /// returns `null` when the given `Extern` is not a global
    ///
    /// Asserts `Extern` is of type `Global`
    pub fn asGlobal(self: *Extern) *Global {
        return wasm_extern_as_global(self).?;
    }

    /// Returns the `Extern` as a `Table`
    /// returns `null` when the given `Extern` is not a table
    ///
    /// Asserts `Extern` is of type `Table`
    pub fn asTable(self: *Extern) *Table {
        return wasm_extern_as_table(self).?;
    }

    /// Frees the memory of the `Extern`
    pub fn deinit(self: *Extern) void {
        wasm_extern_delete(self);
    }

    /// Creates a copy of the `Extern` and returns it
    /// Memory of the copied version must be freed manually by calling `deinit`
    ///
    /// Asserts the copy succeeds
    pub fn copy(self: *Extern) *Extern {
        return wasm_extern_copy(self).?;
    }

    /// Checks if the given externs are equal and returns true if so
    pub fn eql(self: *const Extern, other: *const Extern) bool {
        return wasm_extern_same(self, other);
    }

    extern "c" fn wasm_extern_as_func(*Extern) ?*Func;
    extern "c" fn wasm_extern_as_memory(*Extern) ?*Memory;
    extern "c" fn wasm_extern_as_global(*Extern) ?*Global;
    extern "c" fn wasm_extern_as_table(*Extern) ?*Table;
    extern "c" fn wasm_extern_delete(*Extern) void;
    extern "c" fn wasm_extern_copy(*Extern) ?*Extern;
    extern "c" fn wasm_extern_same(*const Extern, *const Extern) bool;
};

pub const Memory = opaque {
    /// Creates a new `Memory` object for the given `Store` and `MemoryType`
    pub fn init(store: *Store, mem_type: *const MemoryType) !*Memory {
        return wasm_memory_new(store, mem_type) orelse error.MemoryInit;
    }

    /// Returns the `MemoryType` of a given `Memory` object
    pub fn getType(self: *const Memory) *MemoryType {
        return wasm_memory_type(self).?;
    }

    /// Frees the memory of the `Memory` object
    pub fn deinit(self: *Memory) void {
        wasm_memory_delete(self);
    }

    /// Creates a copy of the given `Memory` object
    /// Returned copy must be freed manually.
    pub fn copy(self: *const Memory) ?*Memory {
        return wasm_memory_copy(self);
    }

    /// Returns true when the given `Memory` objects are equal
    pub fn eql(self: *const Memory, other: *const Memory) bool {
        return wasm_memory_same(self, other);
    }

    /// Returns a pointer-to-many bytes
    ///
    /// Tip: Use toSlice() to get a slice for better ergonomics
    pub fn data(self: *Memory) [*]u8 {
        return wasm_memory_data(self);
    }

    /// Returns the data size of the `Memory` object.
    pub fn size(self: *const Memory) usize {
        return wasm_memory_data_size(self);
    }

    /// Returns the amount of pages the `Memory` object consists of
    /// where each page is 65536 bytes
    pub fn pages(self: *const Memory) u32 {
        return wasm_memory_size(self);
    }

    /// Convenient helper function to represent the memory
    /// as a slice of bytes. Memory is however still owned by wasm
    /// and must be freed by calling `deinit` on the original `Memory` object
    pub fn toSlice(self: *Memory) []const u8 {
        var slice: []const u8 = undefined;
        slice.ptr = self.data();
        slice.len = self.size();
        return slice;
    }

    /// Increases the amount of memory pages by the given count.
    pub fn grow(self: *Memory, page_count: u32) error{OutOfMemory}!void {
        if (!wasm_memory_grow(self, page_count)) return error.OutOfMemory;
    }

    extern "c" fn wasm_memory_delete(*Memory) void;
    extern "c" fn wasm_memory_copy(*const Memory) ?*Memory;
    extern "c" fn wasm_memory_same(*const Memory, *const Memory) bool;
    extern "c" fn wasm_memory_new(*Store, *const MemoryType) ?*Memory;
    extern "c" fn wasm_memory_type(*const Memory) *MemoryType;
    extern "c" fn wasm_memory_data(*Memory) [*]u8;
    extern "c" fn wasm_memory_data_size(*const Memory) usize;
    extern "c" fn wasm_memory_grow(*Memory, delta: u32) bool;
    extern "c" fn wasm_memory_size(*const Memory) u32;
};

pub const Limits = extern struct {
    min: u32,
    max: u32,
};

pub const MemoryType = opaque {
    pub fn init(limits: Limits) !*MemoryType {
        return wasm_memorytype_new(&limits) orelse return error.InitMemoryType;
    }

    pub fn deinit(self: *MemoryType) void {
        wasm_memorytype_delete(self);
    }

    extern "c" fn wasm_memorytype_new(*const Limits) ?*MemoryType;
    extern "c" fn wasm_memorytype_delete(*MemoryType) void;
};

// TODO: implement table and global types
pub const Table = opaque {};
pub const Global = opaque {};

pub const ExportType = opaque {
    /// Returns the name of the given `ExportType`
    pub fn name(self: *ExportType) *ByteVec {
        return self.wasm_exporttype_name().?;
    }

    extern "c" fn wasm_exporttype_name(*ExportType) ?*ByteVec;
};

pub const ExportTypeVec = extern struct {
    size: usize,
    data: [*]?*ExportType,

    /// Returns a slice of an `ExportTypeVec`.
    /// Memory is still owned by the runtime and can only be freed using
    /// `deinit()` on the original `ExportTypeVec`
    pub fn toSlice(self: *const ExportTypeVec) []const ?*ExportType {
        return self.data[0..self.size];
    }

    pub fn deinit(self: *ExportTypeVec) void {
        self.wasm_exporttype_vec_delete();
    }

    extern "c" fn wasm_exporttype_vec_delete(*ExportTypeVec) void;
};

pub const InstanceType = opaque {
    pub fn deinit(self: *InstanceType) void {
        self.wasm_instancetype_delete();
    }

    /// Returns a vector of `ExportType` in a singular type `ExportTypeVec`
    pub fn exports(self: *InstanceType) ExportTypeVec {
        var export_vec: ExportTypeVec = undefined;
        self.wasm_instancetype_exports(&export_vec);
        return export_vec;
    }

    extern "c" fn wasm_instancetype_delete(*InstanceType) void;
    extern "c" fn wasm_instancetype_exports(*InstanceType, ?*ExportTypeVec) void;
};

pub const Callback = fn (?*const Valtype, ?*Valtype) callconv(.C) ?*Trap;

pub const ByteVec = extern struct {
    size: usize,
    data: [*]u8,

    /// Initializes a new wasm byte vector
    pub fn initWithCapacity(size: usize) ByteVec {
        var bytes: ByteVec = undefined;
        wasm_byte_vec_new_uninitialized(&bytes, size);
        return bytes;
    }

    /// Initializes and copies contents of the input slice
    pub fn fromSlice(slice: []const u8) ByteVec {
        var bytes: ByteVec = undefined;
        wasm_byte_vec_new(&bytes, slice.len, slice.ptr);
        return bytes;
    }

    /// Returns a slice to the byte vector
    pub fn toSlice(self: ByteVec) []const u8 {
        return self.data[0..self.size];
    }

    /// Frees the memory allocated by initWithCapacity
    pub fn deinit(self: *ByteVec) void {
        wasm_byte_vec_delete(self);
    }

    extern "c" fn wasm_byte_vec_new(*ByteVec, usize, [*]const u8) void;
    extern "c" fn wasm_byte_vec_new_uninitialized(*ByteVec, usize) void;
    extern "c" fn wasm_byte_vec_delete(*ByteVec) void;
};

pub const NameVec = extern struct {
    size: usize,
    data: [*]const u8,

    pub fn fromSlice(slice: []const u8) NameVec {
        return .{ .size = slice.len, .data = slice.ptr };
    }
};

pub const ExternVec = extern struct {
    size: usize,
    data: [*]?*Extern,

    pub fn empty() ExternVec {
        return .{ .size = 0, .data = undefined };
    }

    pub fn deinit(self: *ExternVec) void {
        wasm_extern_vec_delete(self);
    }

    pub fn initWithCapacity(size: usize) ExternVec {
        var externs: ExternVec = undefined;
        wasm_extern_vec_new_uninitialized(&externs, size);
        return externs;
    }

    extern "c" fn wasm_extern_vec_new_empty(*ExternVec) void;
    extern "c" fn wasm_extern_vec_new_uninitialized(*ExternVec, usize) void;
    extern "c" fn wasm_extern_vec_delete(*ExternVec) void;
};

pub const Valkind = extern enum(u8) {
    i32 = 0,
    i64 = 1,
    f32 = 2,
    f64 = 3,
    anyref = 128,
    funcref = 129,
};

pub const Value = extern struct {
    kind: Valkind,
    of: extern union {
        i32: i32,
        i64: i64,
        f32: f32,
        f64: f64,
        ref: ?*c_void,
    },
};

pub const Valtype = opaque {
    /// Initializes a new `Valtype` based on the given `Valkind`
    pub fn init(kind: Valkind) *Valtype {
        return wasm_valtype_new(@enumToInt(kind));
    }

    pub fn deinit(self: *Valtype) void {
        wasm_valtype_delete(self);
    }

    /// Returns the `Valkind` of the given `Valtype`
    pub fn kind(self: *Valtype) Valkind {
        return @intToEnum(Valkind, wasm_valtype_kind(self));
    }

    extern "c" fn wasm_valtype_new(kind: u8) *Valtype;
    extern "c" fn wasm_valtype_delete(*Valkind) void;
    extern "c" fn wasm_valtype_kind(*Valkind) u8;
};

pub const ValtypeVec = extern struct {
    size: usize,
    data: [*]?*Valtype,

    pub fn empty() ValtypeVec {
        return .{ .size = 0, .data = undefined };
    }
};

pub const ValVec = extern struct {
    size: usize,
    data: [*]Value,

    pub fn initWithCapacity(size: usize) ValVec {
        var bytes: ValVec = undefined;
        wasm_val_vec_new_uninitialized(&bytes, size);
        return bytes;
    }

    pub fn deinit(self: *ValVec) void {
        self.wasm_val_vec_delete();
    }

    extern "c" fn wasm_val_vec_new_uninitialized(*ValVec, usize) void;
    extern "c" fn wasm_val_vec_delete(*ValVec) void;
};

// Func
pub extern "c" fn wasm_functype_new(args: *ValtypeVec, results: *ValtypeVec) ?*c_void;
pub extern "c" fn wasm_functype_delete(functype: *c_void) void;

pub const WasiConfig = opaque {
    /// Options to inherit when inherriting configs
    /// By default all is `true` as you often want to
    /// inherit everything rather than something specifically.
    const InheritOptions = struct {
        argv: bool = true,
        env: bool = true,
        std_in: bool = true,
        std_out: bool = true,
        std_err: bool = true,
    };

    pub fn init() !*WasiConfig {
        return wasi_config_new() orelse error.ConfigInit;
    }

    pub fn deinit(self: *WasiConfig) void {
        wasi_config_delete(self);
    }

    /// Allows to inherit the native environment into the current config.
    /// Inherits everything by default.
    pub fn inherit(self: *WasiConfig, options: InheritOptions) void {
        if (options.argv) self.inheritArgv();
        if (options.env) self.inheritEnv();
        if (options.std_in) self.inheritStdIn();
        if (options.std_out) self.inheritStdOut();
        if (options.std_err) self.inheritStdErr();
    }

    pub fn inheritArgv(self: *WasiConfig) void {
        wasi_config_inherit_argv(self);
    }

    pub fn inheritEnv(self: *WasiConfig) void {
        wasi_config_inherit_env(self);
    }

    pub fn inheritStdIn(self: *WasiConfig) void {
        wasi_config_inherit_stdin(self);
    }

    pub fn inheritStdOut(self: *WasiConfig) void {
        wasi_config_inherit_stdout(self);
    }

    pub fn inheritStdErr(self: *WasiConfig) void {
        wasi_config_inherit_stderr(self);
    }

    extern "c" fn wasi_config_new() ?*WasiConfig;
    extern "c" fn wasi_config_delete(?*WasiConfig) void;
    extern "c" fn wasi_config_inherit_argv(?*WasiConfig) void;
    extern "c" fn wasi_config_inherit_env(?*WasiConfig) void;
    extern "c" fn wasi_config_inherit_stdin(?*WasiConfig) void;
    extern "c" fn wasi_config_inherit_stdout(?*WasiConfig) void;
    extern "c" fn wasi_config_inherit_stderr(?*WasiConfig) void;
};

pub const WasiInstance = opaque {
    pub fn init(store: *Store, name: [*:0]const u8, config: ?*WasiConfig, trap: *?*Trap) !*WasiInstance {
        return wasi_instance_new(store, name, config, trap) orelse error.InstanceInit;
    }

    pub fn deinit(self: *WasiInstance) void {
        wasm_instance_delete(self);
    }

    extern "c" fn wasi_instance_new(?*Store, [*:0]const u8, ?*WasiConfig, *?*Trap) ?*WasiInstance;
    extern "c" fn wasm_instance_delete(?*WasiInstance) void;
};

test "" {
    testing.refAllDecls(@This());
}
