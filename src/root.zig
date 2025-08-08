//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const _ = std.MultiArrayList;

const example_structs = @import("example_structs.zig");
const Position = example_structs.Position;
const Velocity = example_structs.Velocity;

const TypeId = @import("type_id.zig").TypeId;

pub export fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try testing.expect(add(3, 7) == 10);
}

const ComponentStorage = struct {
    size: usize,
    len: usize,
    data: std.ArrayListUnmanaged(u8),

    fn empty(comptime Component: type) ComponentStorage {
        return .{
            .data = .empty,
            .size = @sizeOf(Component),
            .len = 0,
        };
    }

    fn get(self: *const ComponentStorage, comptime Component: type, idx: usize) Component {
        const start = idx * self.size;
        const end = (idx + 1) * self.size;
        return std.mem.bytesToValue(Component, self.data[start..end]);
    }

    fn getPtr(self: *const ComponentStorage, comptime Component: type, idx: usize) *Component {
        const start = idx * self.size;
        const end = (idx + 1) * self.size;
        return @alignCast(std.mem.bytesAsValue(Component, self.data[start..end]));
    }
};

/// Table where column
const Archetype = struct {
    /// Columns
    components: std.AutoArrayHashMapUnmanaged(TypeId, ComponentStorage),
    entities: usize,
    /// rows
    const empty = Archetype{
        .components = .empty,
        .entities = 0,
    };

    pub fn deinit(self: *Archetype, gpa: Allocator) void {
        for (self.components.values()) |*component_storage| {
            component_storage.data.deinit(gpa);
        }

        self.components.deinit(gpa);
    }

    pub fn query(self: *Archetype, comptime View: type) Iterator(View) {
        _ = self;
        // @panic("");
        return Iterator(View){};
    }
};

fn Iterator(comptime View: type) type {
    return struct {
        slice: Slice(View),
        idx: usize,
        len: usize,

        const Self = @This();
        pub fn next(self: *Self) ?View {
            if (self.idx < self.len) {}

            return null;
        }
    };
}

fn Slice(comptime View: type) type {
    _ = View;
    // return @Type(.{ .@"struct" =  });
    //
    // const fields = @typeInfo(View).@"struct".fields.len;
    return struct {};
}

const ArchetypeID = enum(u64) {
    /// Archetype wich has 0 components
    void_arch = 0,
    _,

    fn from(comptime T: type) ArchetypeID {
        const info = @typeInfo(T);
        if (info != .@"struct") @compileError("Only supports struct");

        var id: u64 = 0;

        for (info.@"struct".fields) |field| {
            id ^= @intFromEnum(TypeId.hash(field.type));
        }

        return @enumFromInt(id);
    }

    fn xor(self: ArchetypeID, other: TypeId) ArchetypeID {
        const self_int = @intFromEnum(self);
        const other_int = @intFromEnum(other);

        return @enumFromInt(self_int ^ other_int);
    }
};
const EntityID = enum(u32) { _ };
const RowID = enum(u32) { _ };

const ECS = struct {
    archetypes: std.AutoArrayHashMapUnmanaged(ArchetypeID, Archetype),
    /// Mapping of which row in which archetype the entity is stored in
    entities: std.AutoArrayHashMapUnmanaged(EntityID, Pointer),

    const Pointer = struct {
        archetype_id: ArchetypeID,
        row_id: RowID,
    };

    pub fn init(gpa: Allocator) !ECS {
        var self: ECS = .{ .archetypes = .empty, .entities = .empty };
        try self.archetypes.put(gpa, .void_arch, .empty);
        return self;
    }

    pub fn deinit(self: *ECS, gpa: Allocator) void {
        for (self.archetypes.values()) |*arch| arch.deinit(gpa);
        self.archetypes.deinit(gpa);
        self.entities.deinit(gpa);
    }

    /// adds an entity with no components
    pub fn addEntity(self: *ECS, gpa: Allocator) !EntityID {
        const arch = self.archetypes.getPtr(.void_arch).?;

        const ent_id: EntityID = @enumFromInt(self.entities.count());
        const row_id: RowID = @enumFromInt(arch.entities);

        try self.entities.put(gpa, ent_id, .{
            .archetype_id = .void_arch,
            .row_id = row_id,
        });

        arch.entities += 1;

        return ent_id;
    }

    /// Add a component to an entity
    pub fn addComponent(
        self: *ECS,
        gpa: Allocator,
        entity_id: EntityID,
        comptime Component: type,
        component: Component,
    ) !void {
        _ = component;
        const info = @typeInfo(Component);
        if (info != .@"struct") @compileError("only supports structs");

        const type_id: TypeId = .hash(Component);
        const entity_ptr = self.entities.get(entity_id).?;
        const arch_id = entity_ptr.archetype_id;

        const arch = self.archetypes.get(arch_id).?;

        if (arch.components.contains(type_id)) {
            // entity already has the component
            return error.EntityAlreadyHasComponent;
        }

        const new_arch_id = arch_id.xor(type_id);

        if (self.archetypes.getPtr(new_arch_id)) |new_arch| {
            // there exits an arch where we can move the entity
            // remove the entry from the current arch and put in the new arch
            //
            _ = new_arch;
            var comp_it = arch.components.iterator();
            while (comp_it.next()) |entry| {
                _ = entry;
            }
        } else {
            // we need to create a new arch to put the entity in
            // this will be the arch first entity
            var new_arch: Archetype = .empty;
            errdefer new_arch.deinit(gpa);
        }
    }

    // fn query(self: *ECS, comptime View: type) []const View {
    //     _ = self;
    // }
};

test "api" {
    const gpa = std.testing.allocator;

    var ecs = try ECS.init(gpa);
    defer ecs.deinit(gpa);

    const player = try ecs.addEntity(gpa);

    _ = player;
}

test "store position" {
    const gpa = std.testing.allocator;
    var storage = ComponentStorage{
        .len = 0,
        .data = .empty,
        .size = @sizeOf(Position),
    };
    defer storage.data.deinit(gpa);

    try storage.data.appendSlice(gpa, std.mem.asBytes(&Position{ .x = 5, .y = 3 }));

    const current_pos: *Position = @alignCast(std.mem.bytesAsValue(Position, storage.data.items[0..storage.size]));

    try std.testing.expectEqual(5, current_pos.x);

    current_pos.x = 3;

    const updated_pos: *Position = @alignCast(std.mem.bytesAsValue(Position, storage.data.items[0..storage.size]));
    try std.testing.expectEqual(3, updated_pos.x);

    const positions: []Position = @alignCast(@ptrCast(storage.data.items));

    std.debug.print("byte_len = {}\n", .{storage.data.items.len});
    std.debug.print("pos_len = {}\n", .{positions.len});
    for (positions) |p| {
        std.debug.print("p = {}\n", .{p});
    }
}

// test "query archetype" {
//     var arch = Archetype{ .components = .empty, .len = 0 };
//
//     var query_it = arch.query(struct { pos: *Position, vel: *Velocity });
//     while (query_it.next()) |view| {
//         _ = view;
//     }
// }
//
// test "struct to slice" {
//     const Slices = struct {
//         pos: []Position,
//         vel: []Velocity,
//     };
//
//     const View = struct { pos: *Position, vel: *Velocity };
// }
//
