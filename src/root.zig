//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const assert = std.debug.assert;
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

/// Column in a table
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

    fn append(self: *ComponentStorage, gpa: Allocator, value: anytype) !void {
        const bytes = std.mem.asBytes(&value);
        try self.data.appendSlice(gpa, bytes);

        assert(bytes.len / self.size == 1);

        self.len += 1;
    }

    /// add a component by bytes
    fn appendBytes(self: *ComponentStorage, gpa: Allocator, bytes: []const u8) !void {
        assert(bytes.len == self.size);
        try self.data.appendSlice(gpa, bytes);
        self.len += 1;
    }

    fn get(self: *const ComponentStorage, comptime Component: type, idx: usize) Component {
        assert(idx < self.len);
        assert(@sizeOf(Component) == self.size);
        const start = idx * self.size;
        const end = (idx + 1) * self.size;
        return std.mem.bytesToValue(Component, self.data.items[start..end]);
    }

    fn getPtr(self: *const ComponentStorage, comptime Component: type, idx: usize) *Component {
        assert(idx < self.len);
        assert(@sizeOf(Component) == self.size);
        const start = idx * self.size;
        const end = (idx + 1) * self.size;
        return @alignCast(std.mem.bytesAsValue(Component, self.data.items[start..end]));
    }

    fn getSlice(self: *const ComponentStorage, comptime Component: type) []Component {
        assert(@sizeOf(Component) == self.size);
        return @alignCast(@ptrCast(self.data.items));
    }

    fn getConstSlice(self: *const ComponentStorage, comptime Component: type) []const Component {
        assert(@sizeOf(Component) == self.size);
        return @alignCast(@ptrCast(self.data.items));
    }

    fn getConstBytes(self: *const ComponentStorage, row_id: RowID) []const u8 {
        const idx = @intFromEnum(row_id);
        const start = idx * self.size;
        const end = (idx + 1) * self.size;
        return self.data.items[start..end];
    }

    fn removeRow(self: *ComponentStorage, row_id: RowID) void {
        const idx = getIdx(row_id, self.size);
        var i = idx.end - 1;
        while (idx.start < i) : (i -= 1) {
            _ = self.data.swapRemove(i);
        }
    }

    const Idx = struct {
        row: usize,
        start: usize,
        end: usize,
    };

    fn getIdx(row_id: RowID, size: usize) Idx {
        const row = @intFromEnum(row_id);
        const start = row * size;
        const end = (row + 1) * size;
        return .{
            .row = row,
            .start = start,
            .end = end,
        };
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

    fn removeRow(self: *Archetype, row_id: RowID) void {
        for (self.components.values()) |*comp_store| {
            comp_store.removeRow(row_id);
        }
    }

    /// Copy a row to another archetype
    fn copyRow(src: *Archetype, gpa: Allocator, row_id: RowID, dst: *Archetype) !RowID {
        const new_row_id: RowID = @enumFromInt(dst.entities);

        var it = src.components.iterator();
        while (it.next()) |entry| {
            const type_id_ptr = entry.key_ptr;
            const comp_store_ptr = entry.value_ptr;

            if (dst.components.getPtr(type_id_ptr.*)) |other_comp_store_ptr| {
                try other_comp_store_ptr.appendBytes(gpa, comp_store_ptr.getConstBytes(row_id));
            }
        }

        dst.entities += 1;
        return new_row_id;
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
        const entity_ptr = self.entities.getPtr(entity_id).?;
        const arch_id = entity_ptr.archetype_id;

        const arch = self.archetypes.getPtr(arch_id).?;

        if (arch.components.contains(type_id)) {
            // entity already has the component
            return error.EntityAlreadyHasComponent;
        }

        const new_arch_id = arch_id.xor(type_id);

        if (self.archetypes.getPtr(new_arch_id)) |dst_arch| {
            // there exits an arch where we can move the entity
            // remove the entry from the current arch and put in the new arch

            const new_row = try arch.copyRow(gpa, entity_ptr.row_id, dst_arch);
            arch.removeRow(entity_ptr.row_id);

            entity_ptr.row_id = new_row;
            entity_ptr.archetype_id = new_arch_id;
        } else {
            // we need to create a new arch to put the entity in
            // this will be the arch first entity
            var new_arch: Archetype = .empty;
            errdefer new_arch.deinit(gpa);

            // copy entities component data to new arch
            var comp_it = arch.components.iterator();
            while (comp_it.next()) |entry| {
                var new_storage: ComponentStorage = .{
                    .data = .empty,
                    .len = 0,
                    .size = entry.value_ptr.size,
                };
                errdefer new_storage.data.deinit(gpa);

                try new_storage.appendBytes(gpa, entry.value_ptr.getConstBytes(entity_ptr.row_id));

                try new_arch.components.put(
                    gpa,
                    entry.key_ptr.*, // typeid
                    new_storage, // component_storage
                );
            }

            try self.archetypes.put(gpa, new_arch_id, new_arch);

            entity_ptr.archetype_id = new_arch_id;
            entity_ptr.row_id = @enumFromInt(new_arch.entities);
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
    try ecs.addComponent(gpa, player, Position, .{ .x = 3, .y = 3 });
    try ecs.addComponent(gpa, player, example_structs.Health, .{ .val = 3 });
}

test "store position" {
    const gpa = std.testing.allocator;
    var storage: ComponentStorage = .empty(Position);
    defer storage.data.deinit(gpa);

    try storage.append(gpa, Position{ .x = 5, .y = 3 });
    try storage.append(gpa, Position{ .x = 10, .y = 8 });

    const current_pos = storage.getPtr(Position, 0);

    try std.testing.expectEqual(5, current_pos.x);

    current_pos.x = 3;

    const updated_pos = storage.get(Position, 0);
    try std.testing.expectEqual(3, updated_pos.x);

    const positions: []Position = storage.getSlice(Position);
    positions[1].y = 10;

    for (positions) |*p| {
        p.x += 1;
        std.debug.print("p = {}\n", .{p});
    }

    for (storage.getConstSlice(Position)) |*p| {
        // p.x += 1;
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
