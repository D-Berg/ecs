const std = @import("std");
const example_structs = @import("example_structs.zig");
const Position = example_structs.Position;
const Velocity = example_structs.Velocity;

pub const TypeId = enum(u64) {
    _,

    pub fn hash(comptime T: type) TypeId {
        const info = @typeInfo(T);
        if (info != .@"struct") @compileError("only supports structs");
        const name = @typeName(T);

        const h = std.hash_map.hashString(name);

        return @enumFromInt(h);
    }
};

const Struct = std.builtin.Type.Struct;

test "typeid" {
    const position_hash: TypeId = .hash(Position);
    const velocity_hash: TypeId = .hash(Velocity);

    std.debug.print("hash = {}\n", .{position_hash});
    std.debug.print("hash = {}\n", .{velocity_hash});
}
