const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const assert = std.debug.assert;

/// Type erased storage of a singular type of Components,
/// equivalent of a column in a table
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

    fn ensureUnusedCapacity(self: *ComponentStorage, gpa: Allocator, n: usize) !void {
        try self.data.ensureUnusedCapacity(gpa, self.size * n);
    }

    fn appendAssumeCapacity(self: *ComponentStorage, value: anytype) void {
        const bytes = std.mem.asBytes(&value);
        self.data.appendSliceAssumeCapacity(bytes);

        assert(bytes.len / self.size == 1);

        self.len += 1;
    }

    fn append(self: *ComponentStorage, gpa: Allocator, value: anytype) !void {
        try self.ensureUnusedCapacity(gpa, 1);
        self.appendAssumeCapacity(value);
    }

    /// add a component by bytes
    /// increases len by 1
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

    fn getPtr(self: *const ComponentStorage, comptime Component: type, row_id: RowID) *Component {
        const idx = getIdx(row_id, self.size);
        assert(idx.row < self.len);
        assert(@sizeOf(Component) == self.size);
        const start = idx.start;
        const end = idx.end;
        return @alignCast(std.mem.bytesAsValue(Component, self.data.items[start..end]));
    }

    fn getSlice(self: *const ComponentStorage, comptime Component: type) []Component {
        assert(@sizeOf(Component) == self.size);
        return @ptrCast(@alignCast(self.data.items));
    }

    fn getConstSlice(self: *const ComponentStorage, comptime Component: type) []const Component {
        assert(@sizeOf(Component) == self.size);
        return @ptrCast(@alignCast(self.data.items));
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
        _ = self.data.swapRemove(i);
        self.len -= 1;
    }

    const Idx = struct {
        row: usize,
        /// byte start idx
        start: usize,
        /// byte end idx
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

    fn deinit(self: *Archetype, gpa: Allocator) void {
        for (self.components.values()) |*component_storage| {
            component_storage.data.deinit(gpa);
        }
        self.components.deinit(gpa);
    }

    fn removeRow(self: *Archetype, row_id: RowID) void {
        for (self.components.values()) |*comp_store| {
            comp_store.removeRow(row_id);
        }
        self.entities -= 1;
    }

    /// Copy a row to another archetype
    fn copyRow(src: *Archetype, gpa: Allocator, row_id: RowID, dst: *Archetype) !RowID {
        const new_row_id: RowID = @enumFromInt(dst.entities);

        var it = src.components.iterator();
        while (it.next()) |entry| {
            const type_id_ptr = entry.key_ptr;
            const src_comp_store_ptr = entry.value_ptr;

            if (dst.components.getPtr(type_id_ptr.*)) |dst_comp_store_ptr| {
                try dst_comp_store_ptr.appendBytes(gpa, src_comp_store_ptr.getConstBytes(row_id));
                assert(dst_comp_store_ptr.len == dst.entities + 1);
            }
        }

        dst.entities += 1;
        return new_row_id;
    }
};

fn Iterator(comptime View: type) type {
    return struct {
        arch_slice: []const Archetype,
        arch_idx: usize = 0,
        /// A struct where each field is a slice of Views field type
        view_slice: Slice(View),
        /// idx of the entity (row)
        idx: usize,
        rows: usize,

        const Self = @This();

        /// Get the next View into an entities data that matches the query
        pub fn next(self: *Self) ?View {
            if (self.createView()) |view| {
                return view;
            } else {
                if (self.nextSlice()) |view_slice| {
                    self.view_slice = view_slice;
                    return self.createView();
                }
            }

            return null;
        }

        fn createView(self: *Self) ?View {
            if (self.idx < self.rows) {
                var view: View = undefined;
                inline for (@typeInfo(View).@"struct".fields) |field| {
                    @field(view, field.name) = switch (@typeInfo(field.type)) {
                        .pointer => &@field(self.view_slice, field.name)[self.idx],
                        .@"enum",
                        .@"struct",
                        => @field(self.view_slice, field.name)[self.idx],
                        else => @compileError("wtf is that type"),
                    };
                }

                self.idx += 1;
                return view;
            }
            return null;
        }

        /// create a new slice and increase arch_idx
        fn nextSlice(self: *Self) ?Slice(View) {

            // find the next archetype having the nesseccary components
            loop: while (self.arch_idx < self.arch_slice.len) {
                defer self.arch_idx += 1;

                const arch = self.arch_slice[self.arch_idx];

                if (arch.entities == 0) continue :loop;

                var view_slice: Slice(View) = undefined;
                inline for (@typeInfo(@TypeOf(self.view_slice)).@"struct".fields) |slice_field| {
                    const FieldType = @typeInfo(slice_field.type).pointer.child;
                    const type_id = TypeId.hash(FieldType);
                    const maybe_comp_storage: ?*ComponentStorage = arch.components.getPtr(type_id);
                    if (maybe_comp_storage) |comp_storage| {
                        assert(comp_storage.len * comp_storage.size == comp_storage.data.items.len);

                        // TODO: const slice vs var slice depending on ptr type
                        @field(view_slice, slice_field.name) = comp_storage.getSlice(FieldType);
                    } else {
                        // archetype is missing some component -> go to next arch
                        continue :loop;
                    }
                }
                self.idx = 0;
                self.rows = arch.entities;
                return view_slice;
            }

            return null;
        }
    };
}

/// Construct a struct from View where its fields are slices to View field type
/// converts a `stuct { pos: *Pointer, ... }` to `struct { pos: []Pointer, ... }`
fn Slice(comptime View: type) type {
    //
    const info = @typeInfo(View).@"struct";
    const fields_len = @typeInfo(View).@"struct".fields.len;
    var fields: [fields_len]std.builtin.Type.StructField = undefined;

    for (info.fields, 0..) |field, i| {
        const T = switch (@typeInfo(field.type)) {
            .pointer => |ptr| ptr.child,
            .@"struct",
            .@"enum",
            => field.type,
            else => @compileError("EOROOOORRR"),
        };
        fields[i] = std.builtin.Type.StructField{
            .name = field.name,
            .alignment = field.alignment,
            .type = []T,
            .is_comptime = false,
            .default_value_ptr = null,
        };
    }

    const S = std.builtin.Type.Struct{
        .layout = .auto,
        .backing_integer = null,
        .decls = &.{},
        .fields = &fields,
        .is_tuple = false,
    };

    return @Type(.{ .@"struct" = S });
}

const ArchetypeID = enum(u64) {
    /// Archetype wich has 0 components
    void_arch = 0,
    _,

    /// Compute ArchetypeID based on T fields
    fn from(comptime T: type) ArchetypeID {
        const info = @typeInfo(T);
        if (info != .@"struct") @compileError("Only supports struct");

        var id: u64 = 0;

        inline for (info.@"struct".fields) |field| {
            const field_info = @typeInfo(field.type);
            switch (field_info) {
                .@"struct" => {
                    id ^= @intFromEnum(TypeId.hash(field.type));
                },
                .pointer => |ptr| {
                    const child_info = @typeInfo(ptr.child);
                    if (child_info != .@"struct") @compileError("ptr child need to be a struct");

                    id ^= @intFromEnum(TypeId.hash(ptr.child));
                },
                else => @compileError("only support ptr"),
            }
        }

        return @enumFromInt(id);
    }

    fn xor(self: ArchetypeID, other: TypeId) ArchetypeID {
        const self_int = @intFromEnum(self);
        const other_int = @intFromEnum(other);

        return @enumFromInt(self_int ^ other_int);
    }
};

pub const EntityID = enum(u32) { _ };
const RowID = enum(u32) { _ };

pub const World = struct {
    archetypes: std.AutoArrayHashMapUnmanaged(ArchetypeID, Archetype),
    /// Mapping of which row in which archetype the entity is stored in
    entities: std.AutoArrayHashMapUnmanaged(EntityID, Pointer),

    const Pointer = struct {
        archetype_id: ArchetypeID,
        row_id: RowID,
    };

    pub fn init(gpa: Allocator) !World {
        var self: World = .{ .archetypes = .empty, .entities = .empty };
        try self.archetypes.put(gpa, .void_arch, .empty);
        return self;
    }

    pub fn deinit(self: *World, gpa: Allocator) void {
        for (self.archetypes.values()) |*arch| arch.deinit(gpa);
        self.archetypes.deinit(gpa);
        self.entities.deinit(gpa);
    }

    /// adds an entity with no components
    pub fn addEntity(self: *World, gpa: Allocator) !EntityID {
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
        self: *World,
        gpa: Allocator,
        entity_id: EntityID,
        comptime Component: type,
        component: Component,
    ) !void {
        const info = @typeInfo(Component);
        // if (info != .@"struct" or info != .@"enum") ;
        switch (info) {
            .@"struct",
            .@"enum",
            => {},
            inline else => |kind| {
                @compileError("not supported for " ++ kind);
            },
        }

        const type_id: TypeId = .hash(Component);
        const entity_ptr = self.entities.getPtr(entity_id).?;
        const arch_id = entity_ptr.archetype_id;

        if (self.archetypes.getPtr(arch_id).?.components.contains(type_id)) {
            // TODO: update val of component
            // entity already has the component
            return error.EntityAlreadyHasComponent;
        }

        const new_arch_id = arch_id.xor(type_id);

        try self.archetypes.ensureUnusedCapacity(gpa, 1);
        const gop = self.archetypes.getOrPutAssumeCapacity(new_arch_id);
        const arch = self.archetypes.getPtr(arch_id).?;
        if (gop.found_existing) {
            // there exits an arch where we can move the entity
            // remove the entry from the current arch and put in the new arch
            const dst_arch = gop.value_ptr;

            const component_storage = dst_arch.components.getPtr(type_id).?;

            try component_storage.ensureUnusedCapacity(gpa, 1);

            const new_row = try arch.copyRow(gpa, entity_ptr.row_id, dst_arch);
            errdefer comptime unreachable;

            // remove old data
            arch.removeRow(entity_ptr.row_id);

            component_storage.appendAssumeCapacity(component);

            entity_ptr.row_id = new_row;
            entity_ptr.archetype_id = new_arch_id;
        } else {
            // we need to create a new arch to put the entity in
            // this will be the arch first entity
            gop.value_ptr.* = .empty;
            const new_arch = gop.value_ptr;

            // reserve
            var new_comp_store = ComponentStorage.empty(Component);
            try new_comp_store.ensureUnusedCapacity(gpa, 1);
            try new_arch.components.ensureUnusedCapacity(gpa, arch.components.entries.len + 1);

            // copy entities component data to new arch
            var comp_it = arch.components.iterator();
            while (comp_it.next()) |entry| {
                const old_storage_ptr: *ComponentStorage = entry.value_ptr;
                var new_storage: ComponentStorage = .{
                    .data = .empty,
                    .len = 0,
                    .size = old_storage_ptr.size,
                };
                errdefer new_storage.data.deinit(gpa);

                try new_storage.appendBytes(gpa, old_storage_ptr.getConstBytes(entity_ptr.row_id));

                new_arch.components.putAssumeCapacity(
                    entry.key_ptr.*, // typeid
                    new_storage, // component_storage
                );
            }
            errdefer comptime unreachable;
            arch.removeRow(entity_ptr.row_id);

            new_comp_store.appendAssumeCapacity(component);
            new_arch.components.putAssumeCapacity(type_id, new_comp_store);

            const new_row_id: RowID = @enumFromInt(new_arch.entities);
            new_arch.entities += 1;

            entity_ptr.archetype_id = new_arch_id;
            entity_ptr.row_id = new_row_id;
        }
    }

    pub fn query(self: *World, comptime View: type) Iterator(View) {
        var iterator = Iterator(View){
            .arch_slice = self.archetypes.values(),
            .arch_idx = 0,
            .view_slice = undefined,
            .idx = 0,
            .rows = 0,
        };

        if (iterator.nextSlice()) |view_slice| {
            iterator.view_slice = view_slice;
        }

        return iterator;
    }

    /// Get a View into an entity in order to change its component data
    pub fn getEntity(self: *World, entity_id: EntityID, comptime View: type) ?View {
        if (self.entities.get(entity_id)) |entity_ptr| {
            if (self.archetypes.getPtr(entity_ptr.archetype_id)) |arch| {
                var view: View = undefined;
                inline for (@typeInfo(View).@"struct".fields) |field| {
                    const FieldType = @typeInfo(field.type).pointer.child;
                    const type_id = TypeId.hash(FieldType);

                    const maybe_comp_store: ?*ComponentStorage = arch.components.getPtr(type_id);
                    if (maybe_comp_store) |comp_store| {
                        @field(view, field.name) = comp_store.getPtr(FieldType, entity_ptr.row_id);
                    }
                }
                return view;
            }
        }

        return null;
    }

    pub fn removeEntity(self: *World, entity_id: EntityID) void {
        if (self.entities.get(entity_id)) |ptr| {
            if (self.archetypes.getPtr(ptr.archetype_id)) |arch| {
                arch.removeRow(ptr.row_id);
            }

            assert(self.entities.swapRemove(entity_id));
        }
    }
};

test "api" {
    const Position = struct {
        x: i32,
        y: i32,
    };
    const Velocity = struct {
        x: i32,
        y: i32,
    };

    _ = Velocity;

    const Health = struct {
        val: u32,
    };

    const gpa = std.testing.allocator;

    var world = try World.init(gpa);
    defer world.deinit(gpa);

    const player = try world.addEntity(gpa);
    try world.addComponent(gpa, player, Position, .{ .x = 3, .y = 3 });
    try world.addComponent(gpa, player, Health, .{ .val = 3 });

    {
        var found_entities: usize = 0;
        var query = world.query(struct { pos: *Position, health: *Health });
        while (query.next()) |view| {
            view.pos.x += 1;
            view.health.val += 1;
            found_entities += 1;
        }
        try std.testing.expectEqual(1, found_entities);
    }

    {
        var found_entities: usize = 0;
        var query = world.query(struct { pos: *Position });
        while (query.next()) |view| {
            view.pos.x += 1;
            found_entities += 1;
        }
        try std.testing.expectEqual(1, found_entities);
    }

    const player_data = world.getEntity(player, struct { health: *Health });
    try std.testing.expect(player_data != null);
    try std.testing.expectEqual(4, player_data.?.health.val);
}

test "store position" {
    const Position = struct {
        x: i32,
        y: i32,
    };

    const gpa = std.testing.allocator;
    var storage: ComponentStorage = .empty(Position);
    defer storage.data.deinit(gpa);

    try storage.append(gpa, Position{ .x = 5, .y = 3 });
    try storage.append(gpa, Position{ .x = 10, .y = 8 });

    const current_pos = storage.getPtr(Position, @enumFromInt(0));

    try std.testing.expectEqual(5, current_pos.x);

    current_pos.x = 3;

    const updated_pos = storage.get(Position, 0);
    try std.testing.expectEqual(3, updated_pos.x);

    const positions: []Position = storage.getSlice(Position);
    positions[1].y = 10;

    for (positions) |*p| {
        p.x += 1;
    }

    for (storage.getConstSlice(Position)) |*p| {
        // p.x += 1;
        _ = p;
    }
}

const TypeId = enum(u64) {
    _,

    fn hash(comptime T: type) TypeId {
        const info = @typeInfo(T);
        // if (info != .@"struct") @compileError("only supports structs, got: " ++ @typeName(T));
        switch (info) {
            .@"struct",
            .@"enum",
            => {},
            else => |kind| {
                @compileError(
                    std.fmt.comptimePrint("not supported for {s}, T = {s}", .{
                        @tagName(kind),
                        @typeName(T),
                    }),
                );
            },
        }
        const name = @typeName(T);

        const h = std.hash_map.hashString(name);

        return @enumFromInt(h);
    }
};
