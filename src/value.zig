const std = @import("std");
const builtin = @import("builtin");
const endian = builtin.target.cpu.arch.endian();
const stdx = @import("stdx");
const t = stdx.testing;
const debug = builtin.mode == .Debug;
const log = stdx.log.scoped(.value);
const cy = @import("cyber.zig");

/// Most significant bit.
const SignMask: u64 = 1 << 63;

/// QNAN and one extra bit to the right.
const TaggedValueMask: u64 = 0x7ffc000000000000;

/// TaggedMask + Sign bit indicates a pointer value.
const PointerMask: u64 = TaggedValueMask | SignMask;

const BooleanMask: u64 = TaggedValueMask | (@as(u64, TagBoolean) << 32);
const FalseMask: u64 = BooleanMask;
const TrueMask: u64 = BooleanMask | TrueBitMask;
const TrueBitMask: u64 = 1;
const NoneMask: u64 = TaggedValueMask | (@as(u64, TagNone) << 32);
const ErrorMask: u64 = TaggedValueMask | (@as(u64, TagError) << 32);
const ConstStringMask: u64 = TaggedValueMask | (@as(u64, TagConstString) << 32);
const UserTagMask: u64 = TaggedValueMask | (@as(u64, TagUserTag) << 32);
const UserTagLiteralMask: u64 = TaggedValueMask | (@as(u64, TagUserTagLiteral) << 32);
const IntegerMask: u64 = TaggedValueMask | (@as(u64, TagInteger) << 32);

const TagMask: u32 = (1 << 3) - 1;
const TaggedPrimitiveMask = TaggedValueMask | (@as(u64, TagMask) << 32);
const BeforeTagMask: u32 = 0x7fff << 3;

/// The tag id is also the primitive type id.
const TagId = u3;
pub const TagNone: TagId = 0;
pub const TagBoolean: TagId = 1;
pub const TagError: TagId = 2;
pub const TagConstString: TagId = 3;
pub const TagUserTag: TagId = 4;
pub const TagUserTagLiteral: TagId = 5;
pub const TagInteger: TagId = 6;
pub const NoneT: u32 = TagNone;
pub const BooleanT: u32 = TagBoolean;
pub const ErrorT: u32 = TagError;
pub const ConstStringT: u32 = TagConstString;
pub const UserTagT: u32 = TagUserTag;
pub const UserTagLiteralT: u32 = TagUserTagLiteral;
pub const IntegerT: u32 = TagInteger;
pub const NumberT: u32 = 7;

pub const ValuePair = struct {
    left: Value,
    right: Value,
};

/// NaN tagging over a f64 value.
/// Represents a f64 value if not a quiet nan.
/// Otherwise, the sign bit represents either a pointer value or a special value (true, false, none, etc).
/// Pointer values can be at most 50 bits since the sign bit (1), quiet nan (12),
/// and one more bit (so that QNANs can also be a number value) take up 13 bits.
pub const Value = packed union {
    val: u64,
    /// Call frame return info.
    retInfo: packed struct {
        numRetVals: u8,
        retFlag: bool,
    },
    retPcPtr: [*]const cy.OpData,
    retFramePtr: [*]Value,
    // two: packed struct {
    //     low: u32,
    //     high: u32,
    // },

    pub const None = Value{ .val = NoneMask };
    pub const True = Value{ .val = TrueMask };
    pub const False = Value{ .val = FalseMask };

    pub inline fn asI32(self: *const Value) i32 {
        return @bitCast(i32, @intCast(u32, self.val & 0xffffffff));
    }

    pub inline fn asF64toI32(self: *const Value) i32 {
        return @floatToInt(i32, self.asF64());
    }

    pub inline fn asF64toU32(self: *const Value) u32 {
        @setRuntimeSafety(debug);
        return @floatToInt(u32, self.asF64());
    }

    pub inline fn asF64(self: *const Value) linksection(cy.HotSection) f64 {
        @setRuntimeSafety(debug);
        return @bitCast(f64, self.val);
    }

    pub inline fn asTagLiteralId(self: *const Value) linksection(cy.HotSection) u32 {
        return @intCast(u32, self.val & @as(u64, 0xFFFFFFFF));
    }

    pub inline fn toF64(self: *const Value) linksection(cy.HotSection) f64 {
        @setRuntimeSafety(debug);
        if (self.isNumber()) {
            return self.asF64();
        } else {
            return @call(.never_inline, otherToF64, .{self});
        }
    }

    fn otherToF64(self: *const Value) linksection(cy.HotSection) f64 {
        if (self.isPointer()) {
            const obj = stdx.ptrAlignCast(*cy.HeapObject, self.asPointer().?);
            if (obj.common.structId == cy.StringS) {
                const str = obj.string.ptr[0..obj.string.len];
                return std.fmt.parseFloat(f64, str) catch 0;
            } else stdx.panicFmt("unexpected struct {}", .{obj.common.structId});
        } else {
            switch (self.getTag()) {
                TagNone => return 0,
                TagBoolean => return if (self.asBool()) 1 else 0,
                TagInteger => return @intToFloat(f64, self.asI32()),
                else => stdx.panicFmt("unexpected tag {}", .{self.getTag()}),
            }
        }
    }

    pub fn toBool(self: *const Value) linksection(cy.HotSection) bool {
        @setCold(true);
        if (self.isNumber()) {
            return self.asF64() != 0;
        } else {
            if (self.isPointer()) {
                const obj = self.asHeapObject(*cy.HeapObject);
                if (obj.common.structId == cy.StringS) {
                    return obj.string.len > 0;
                } else {
                    return true;
                }
            } else {
                switch (self.getTag()) {
                    cy.NoneT => return false,
                    cy.BooleanT => return self.asBool(),
                    cy.ConstStringT => return self.asConstStr().len() > 0,
                    else => {
                        log.debug("tag {}", .{self.getTag()});
                        stdx.panic("unexpected tag");
                    },
                }
            }
        }
    }

    pub fn isString(self: *const Value) linksection(cy.HotSection) bool {
        if (self.isPointer()) {
            const obj = stdx.ptrAlignCast(*cy.HeapObject, self.asPointer().?);
            return obj.common.structId == cy.StringS;
        } else {
            return self.assumeNotPtrIsConstStr();
        }
    }

    pub inline fn bothNumbers(a: Value, b: Value) linksection(cy.HotSection) bool {
        return a.isNumber() and b.isNumber();
    }

    pub inline fn isConstString(self: *const Value) linksection(cy.HotSection) bool {
        return self.val & (TaggedPrimitiveMask | SignMask) == ConstStringMask;
    }

    pub inline fn assumeNotPtrIsConstString(self: *const Value) linksection(cy.HotSection) bool {
        return self.val & TaggedPrimitiveMask == ConstStringMask;
    }

    pub inline fn isError(self: *const Value) linksection(cy.HotSection) bool {
        return self.val & (TaggedPrimitiveMask | SignMask) == ErrorMask;
    }

    pub inline fn assumeNotPtrIsError(self: *const Value) linksection(cy.HotSection) bool {
        return self.val & TaggedPrimitiveMask == ErrorMask;
    }

    pub inline fn assumeNotPtrIsTagLiteral(self: *const Value) linksection(cy.HotSection) bool {
        return self.val & TaggedPrimitiveMask == UserTagLiteralMask;
    }

    pub inline fn getPrimitiveTypeId(self: *const Value) linksection(cy.HotSection) u32 {
        if (self.isNumber()) {
            return NumberT;
        } else {
            return self.getTag();
        }
    }

    pub inline fn isNumberOrPointer(self: *const Value) linksection(cy.HotSection) bool {
        // This could be faster if the 3 bits past the 48 pointer bits represents a non primitive number value.
        return self.isNumber() or self.isPointer();
    }

    pub inline fn isNumber(self: *const Value) linksection(cy.HotSection) bool {
        // Only a number(f64) if not all tagged bits are set.
        return self.val & TaggedValueMask != TaggedValueMask;
    }

    pub inline fn isPointer(self: *const Value) linksection(cy.HotSection) bool {
        // Only a pointer if nan bits and sign bit are set.
        return self.val & PointerMask == PointerMask;
    }

    pub inline fn asPointer(self: *const Value) linksection(cy.HotSection) ?*anyopaque {
        return @intToPtr(?*anyopaque, self.val & ~PointerMask);
    }

    pub inline fn asHeapObject(self: *const Value, comptime Ptr: type) linksection(cy.HotSection) Ptr {
        return @intToPtr(Ptr, self.val & ~PointerMask);
    }

    pub inline fn asBool(self: *const Value) linksection(cy.HotSection) bool {
        return self.val == TrueMask;
    }

    pub inline fn isNone(self: *const Value) linksection(cy.HotSection) bool {
        return self.val == NoneMask;
    }

    pub inline fn isTrue(self: *const Value) linksection(cy.HotSection) bool {
        return self.val == TrueMask;
    }

    pub inline fn isBool(self: *const Value) linksection(cy.HotSection) bool {
        return self.val & (TaggedPrimitiveMask | SignMask) == BooleanMask;
    }

    pub inline fn assumeNotPtrIsBool(self: *const Value) linksection(cy.HotSection) bool {
        return self.val & TaggedPrimitiveMask == BooleanMask;
    }

    pub inline fn getTag(self: *const Value) linksection(cy.HotSection) u3 {
        return @intCast(u3, @intCast(u32, self.val >> 32) & TagMask);
    }

    pub inline fn initTag(tag: u8, val: u8) linksection(cy.HotSection) Value {
        return .{ .val = UserTagMask | (@as(u32, tag) << 8) | val };
    }

    pub inline fn initTagLiteral(symId: u8) linksection(cy.HotSection) Value {
        return .{ .val = UserTagLiteralMask | symId };
    }

    pub inline fn initF64(val: f64) Value {
        return .{ .val = @bitCast(u64, val) };
    }

    pub inline fn initI32(val: i32) Value {
        return .{ .val = IntegerMask | @bitCast(u32, val) };
    }

    pub inline fn initRaw(val: u64) Value {
        @setRuntimeSafety(debug);
        return .{ .val = val };
    }

    pub inline fn initBool(b: bool) linksection(cy.HotSection) Value {
        if (b) {
            return True;
        } else {
            return False;
        }
    }

    pub inline fn initPtr(ptr: ?*anyopaque) Value {
        @setRuntimeSafety(debug);
        return .{ .val = PointerMask | @ptrToInt(ptr) };
    }

    pub inline fn initConstStr(start: u32, len: u15) Value {
        return .{ .val = ConstStringMask | (@as(u64, len) << 35) | start };
    }

    pub inline fn assumeNotPtrIsConstStr(self: *const Value) bool {
        return self.val & TaggedPrimitiveMask == ConstStringMask;
    }

    pub inline fn asConstStr(self: *const Value) stdx.IndexSlice(u32) {
        const len = (@intCast(u32, self.val >> 32) & BeforeTagMask) >> 3;
        const start = @intCast(u32, self.val & 0xffffffff);
        return stdx.IndexSlice(u32).init(start, start + len);
    }

    pub inline fn floatIsSpecial(val: f64) bool {
        @setRuntimeSafety(debug);
        if (std.math.isInf(val)) return true;
        return false;
    }

    pub inline fn floatCanBeInteger(val: f64) linksection(cy.HotSection) bool {
        @setRuntimeSafety(debug);
        // return @fabs(std.math.floor(val) - val) < std.math.f64_epsilon;
        
        // This seems to be the faster check so far.
        return std.math.floor(val) == val;
    }

    pub inline fn initErrorTagLit(id: u8) Value {
        return .{ .val = ErrorMask | (@as(u32, 0xFF) << 8) | id };
    }

    pub inline fn asErrorTagLit(self: *const Value) u8 {
        return @intCast(u8, self.val & 0xff);
    }

    pub fn dump(self: *const Value) void {
        if (self.isNumber()) {
            log.info("Number {}", .{self.asF64()});
        } else {
            if (self.isPointer()) {
                const obj = stdx.ptrAlignCast(*cy.HeapObject, self.asPointer().?);
                switch (obj.common.structId) {
                    cy.ListS => log.info("List {*} len={}", .{obj, obj.list.list.len}),
                    cy.MapS => log.info("Map {*} size={}", .{obj, obj.map.inner.size}),
                    cy.StringS => {
                        if (obj.string.len > 20) {
                            log.info("String {*} len={} str=\"{s}\"...", .{obj, obj.string.len, obj.string.ptr[0..20]});
                        } else {
                            log.info("String {*} len={} str={s}", .{obj, obj.string.len, obj.string.ptr[0..obj.string.len]});
                        }
                    },
                    cy.LambdaS => log.info("Lambda {*}", .{obj}),
                    cy.ClosureS => log.info("Closure {*}", .{obj}),
                    cy.FiberS => log.info("Fiber {*}", .{obj}),
                    cy.NativeFunc1S => return log.info("NativeFunc {*}", .{obj}),
                    else => {
                        log.info("HeapObject {*} {}", .{obj, obj.common.structId});
                    },
                }
            } else {
                switch (self.getTag()) {
                    TagNone => {
                        log.info("None", .{});
                    },
                    TagConstString => {
                        const slice = self.asConstStr();
                        // log.info("Const String {*} len={} str=\"{s}\"", .{&gvm.strBuf[slice.start], slice.len(), gvm.strBuf[slice.start..slice.end]});
                        log.info("Const String len={}", .{slice.len()});
                    },
                    else => {
                        log.info("{}", .{self.val});
                    },
                }
            }
        }
    }

    pub fn getUserTag(self: *const Value) ValueUserTag {
        if (self.isNumber()) {
            return .number;
        } else {
            if (self.isPointer()) {
                const obj = stdx.ptrAlignCast(*cy.HeapObject, self.asPointer().?);
                switch (obj.common.structId) {
                    cy.ListS => return .list,
                    cy.MapS => return .map,
                    cy.StringS => return .string,
                    cy.ClosureS => return .closure,
                    cy.LambdaS => return .lambda,
                    cy.FiberS => return .fiber,
                    cy.BoxS => return .box,
                    cy.NativeFunc1S => return .nativeFunc,
                    cy.TccStateS => return .tccState,
                    cy.OpaquePtrS => return .opaquePtr,
                    else => {
                        return .object;
                    },
                }
            } else {
                switch (self.getTag()) {
                    TagBoolean => return .boolean,
                    TagConstString => return .string,
                    TagNone => return .none,
                    TagUserTag => return .tag,
                    TagUserTagLiteral => return .tagLiteral,
                    TagError => return .errorVal,
                    else => unreachable,
                }
            }
        }
    }
};

pub const ValueUserTag = enum {
    number,
    boolean,
    object,
    list,
    map,
    string,
    constString,
    closure,
    lambda,
    fiber,
    box,
    nativeFunc,
    tccState,
    opaquePtr,
    tag,
    tagLiteral,
    errorVal,
    none,
};

test "floatCanBeInteger" {
    var f: f64 = -100000000000;
    while (f < 100000000000) : (f += 10000) {
        if (std.math.floor(f) == f) {
            continue;
        } else try t.fail();
    }
}

test "asF64" {
    // +Inf.
    var val = Value{ .val = 0x7ff0000000000000 };
    try t.eq(val.asF64(), std.math.inf_f64);

    // -Inf.
    val = Value{ .val = 0xfff0000000000000 };
    try t.eq(val.asF64(), -std.math.inf_f64);
}

test "Masks" {
    try t.eq(ConstStringMask, 0x7FFC000300000000);
    try t.eq(NoneMask, 0x7FFC000000000000);
    try t.eq(TrueMask, 0x7FFC000100000001);
}