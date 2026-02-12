const Gltf = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const GltfJson = @import("GltfJson.zig");

const Error = error{
    InvalidAttributeType,
    InvalidAttributeComponent,
    InvalidAccessorType,

    InvalidIndexTarget,

    FailedToParse,
};

pub const Limits = struct {
    const max_texture_coords = 2;
};

pub const Handedness = enum {
    Right,
    Left,
};

const Buffer = struct {
    bytes: []u8,
    uri: []const u8,
};

const Image = struct {
    buffer: Buffer,
};

const Sampler = GltfJson.Sampler;

const Material = GltfJson.Material;

const Texture = GltfJson.Texture;

pub const NodeIterator = struct {
    nodes: []const Node,
    indices: []const u32,

    curr: usize = 0,

    pub fn new(nodes: []const Node, indices: []const u32) NodeIterator {
        return .{ .nodes = nodes, .indices = indices };
    }

    pub fn next(self: *NodeIterator) ?Node {
        if (self.curr >= self.indices.len) return null;
        defer self.curr += 1;

        const node_idx = self.indices[self.curr];
        return self.nodes[node_idx];
    }
};

pub const NodeDfsIterator = struct {
    const Frame = struct {
        node_idx: u32,
        parent_idx: u32,
    };

    /// Reference to entire node tree.
    nodes: []const Node,

    stack: []Frame,
    top: usize = 0,

    /// The maximum stack depth reached by iterator.
    max_depth: usize,

    pub fn new(nodes: []const Node, root_indices: []const u32, stack: []Frame) ?NodeDfsIterator {
        if (root_indices.len <= 0) return null;

        // Push roots in reverse order
        var top: u32 = 0;
        var rit = root_indices.len;
        while (rit > 0) : (rit -= 1) {
            stack[top] = .{
                .node_idx = root_indices[rit - 1],
                .parent_idx = std.math.maxInt(u32),
            };

            top += 1;
        }

        return .{
            .nodes = nodes,
            .stack = stack,
            .top = top,
            .max_depth = top,
        };
    }

    pub fn next(self: *NodeDfsIterator) ?struct {
        node: *const Node,
        parent: ?*const Node = null,
    } {
        if (self.top == 0) return null;

        // pop frame
        self.top -= 1;
        std.debug.assert(self.top < self.stack.len);
        const frame = self.stack[self.top];

        // push children
        if (self.nodes[frame.node_idx].children) |children| {
            const indices = children.indices;

            var rit = indices.len;
            while (rit > 0) : (rit -= 1) {
                self.stack[self.top] = .{
                    .parent_idx = frame.node_idx,
                    .node_idx = indices[rit - 1],
                };
                self.top += 1;

                // TODO: Calculate actual depth
                // self.max_depth = @max(self.top, self.max_depth);
            }
        }

        // return node of frame
        return .{
            .node = &self.nodes[frame.node_idx],
            .parent = if (frame.parent_idx != std.math.maxInt(u32)) &self.nodes[frame.parent_idx] else null,
        };
    }
};

pub const Node = struct {
    const Transform = enum {
        Matrix,
        Component,
    };

    transform: union(Transform) {
        Matrix: [16]f32,
        Component: struct {
            /// The node’s translation, given as vector  x, y, z.
            translation: [3]f32,
            /// The node’s non-uniform scale, given as the scaling factors along the x, y, and z axes.
            scale: [3]f32,
            /// The node’s unit quaternion rotation in the order (x, y, z, w), where w is the scalar.
            rotation: [4]f32,
        },
    },

    mesh_idx: ?u32,
    children: ?NodeIterator,

    pub fn childIterator(self: Node) ?NodeIterator {
        return self.children;
    }
};

pub const PrimitiveView = struct {
    /// POSITIONs are assumed to be of component `vec3`  and type `f32` without extensions.
    positions: ?struct {
        bytes: []u8,
        stride: u32,
    } = null,

    /// NORMALs are assumed to be of component `vec3`  and type `f32` without extensions.
    normals: ?struct {
        bytes: []u8,
        stride: u32,
    } = null,

    /// TEXCOORDs are assumed to be of component `vec2`  and type `float, ushort, ubyte` normalized unsigned without extensions.
    texcoords: [Limits.max_texture_coords]?struct {
        float: GltfJson.ComponentType,
        bytes: []u8,
        stride: u32,
    } = .{ null, null },

    /// COLORs are assumed to be of component `vec3`/`vec4`  and type `float, ushort, ubyte` normalized unsigned without extensions.
    color: ?struct {
        float: GltfJson.ComponentType,
        has_alpha: bool,
        bytes: []u8,
        stride: u32,
    } = null,

    /// INDICEs must be an UNSIGNED_BYTE/SHORT/INT indicate int the `uint` field.
    indices: ?struct {
        uint: GltfJson.ComponentType,
        bytes: []u8,
        stride: u32,
    } = null,

    /// Returns the tightly-packed size of a single vertex in bytes.
    pub fn vertexSize(self: PrimitiveView) u32 {
        var s: u32 = @sizeOf(f32) * 3;

        if (self.normals) |_| s += @sizeOf(f32) * 3;

        for (self.texcoords) |tattrib| {
            const attr = tattrib orelse continue;
            s += switch (attr.float) {
                .UNSIGNED_BYTE => @sizeOf(u8) * 2,
                .UNSIGNED_SHORT => @sizeOf(u16) * 2,
                .FLOAT => @sizeOf(f32) * 2,
                else => unreachable,
            };
        }

        if (self.color) |cattrib| {
            var count: u32 = 3;
            if (cattrib.has_alpha) count += 1;

            s += switch (cattrib.float) {
                .UNSIGNED_BYTE => @sizeOf(u8) * count,
                .UNSIGNED_SHORT => @sizeOf(u16) * count,
                .FLOAT => @sizeOf(f32) * count,
                else => unreachable,
            };
        }
        return @intCast(s);
    }
};

const MeshView = struct {
    primitives: []PrimitiveView,
    name: []const u8,
};

json: std.json.Parsed(GltfJson),

samplers: []Sampler,
textures: []Texture,
materials: []Material,

buffers: std.ArrayList(Buffer),
images: std.ArrayList(Image),
meshes: std.ArrayList(MeshView),
nodes: std.ArrayList(Node),

pub const Options = struct {
    relative_directory: ?[]const u8,
    handedness: Handedness = .Right,
};

pub fn init(gpa: Allocator, raw: []const u8, opts: Options) !Gltf {
    const dir = opts.relative_directory orelse "";

    const parsed = try std.json.parseFromSlice(
        GltfJson,
        gpa,
        raw,
        .{
            .ignore_unknown_fields = true,
        },
    );
    const json: *const GltfJson = &parsed.value;

    // Queue load resources
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const path_allocator = arena.allocator();

    var buffers: std.ArrayList(Buffer) = try .initCapacity(
        gpa,
        if (json.buffers) |buffers| buffers.len else 0,
    );

    var images: std.ArrayList(Image) = try .initCapacity(
        gpa,
        if (json.images) |images| images.len else 0,
    );

    if (json.buffers) |gltf_buffers| {
        for (gltf_buffers) |gltf_buffer| {
            const uri = gltf_buffer.uri orelse continue;
            const file_path = try std.fs.path.join(
                path_allocator,
                &[_][]const u8{ dir, uri },
            );
            defer path_allocator.free(file_path);

            try buffers.append(gpa, .{
                .uri = uri,
                .bytes = try read(gpa, file_path),
            });
        }
    }

    if (json.images) |gltf_images| {
        for (gltf_images) |gltf_img| {
            if (gltf_img.uri) |uri| {
                const file_path = try std.fs.path.join(
                    path_allocator,
                    &[_][]const u8{ dir, uri },
                );
                defer path_allocator.free(file_path);

                try buffers.append(gpa, .{
                    .uri = uri,
                    .bytes = try read(gpa, file_path),
                });

                try images.append(gpa, .{
                    .buffer = buffers.getLast(),
                });
            } else if (gltf_img.bufferView) |_| unreachable else unreachable;
        }
    }

    const bufferViews = json.bufferViews orelse unreachable;
    const accessors = json.accessors orelse unreachable;

    var meshes: std.ArrayList(MeshView) = if (json.meshes) |meshes| try .initCapacity(gpa, meshes.len) else .{};
    if (json.meshes) |gltf_meshes| {
        for (gltf_meshes) |gltf_mesh| {
            const primitives = try gpa.alloc(PrimitiveView, gltf_mesh.primitives.len);
            for (gltf_mesh.primitives, 0..) |gltf_primitive, pidx| {
                primitives[pidx] = .{};
                if (gltf_primitive.attributes.POSITION) |aidx| {
                    const accessor = &accessors[aidx];

                    const vidx = accessor.bufferView;
                    const view = &bufferViews[vidx];
                    const buffer = buffers.items[view.buffer];

                    const accessor_type = std.meta.stringToEnum(
                        GltfJson.AccesorType,
                        accessor.type,
                    ) orelse return Error.FailedToParse;

                    switch (accessor_type) {
                        .VEC3 => {},
                        else => return Error.InvalidAccessorType,
                    }

                    const stride = view.byteStride orelse blk: {
                        // accessor type enum is equivalent to element count.
                        const count: u32 = @intFromEnum(accessor_type);

                        break :blk switch (accessor.componentType) {
                            .FLOAT => count * @sizeOf(f32),
                            else => return Error.InvalidAttributeComponent,
                        };
                    };

                    const start = view.byteOffset + accessor.byteOffset;
                    const end = start + (accessor.count * stride);
                    primitives[pidx].positions = .{
                        .bytes = buffer.bytes[start..end],
                        .stride = stride,
                    };
                }

                if (gltf_primitive.attributes.NORMAL) |aidx| {
                    const accessor = &accessors[aidx];

                    const vidx = accessor.bufferView;
                    const view = &bufferViews[vidx];
                    const buffer = buffers.items[view.buffer];

                    const accessor_type = std.meta.stringToEnum(
                        GltfJson.AccesorType,
                        accessor.type,
                    ) orelse return Error.FailedToParse;

                    switch (accessor_type) {
                        .VEC3 => {},
                        else => return Error.InvalidAccessorType,
                    }

                    const stride = view.byteStride orelse blk: {
                        // accessor type enum is equivalent to element count.
                        const count: u32 = @intFromEnum(accessor_type);

                        break :blk switch (accessor.componentType) {
                            .FLOAT => count * @sizeOf(f32),
                            else => return Error.InvalidAttributeComponent,
                        };
                    };

                    const start = view.byteOffset + accessor.byteOffset;
                    const end = start + (accessor.count * stride);
                    primitives[pidx].normals = .{
                        .bytes = buffer.bytes[start..end],
                        .stride = stride,
                    };
                }

                if (gltf_primitive.attributes.TEXCOORD_0) |aidx| {
                    const accessor = &accessors[aidx];

                    const vidx = accessor.bufferView;
                    const view = &bufferViews[vidx];
                    const buffer = buffers.items[view.buffer];

                    const accessor_type = std.meta.stringToEnum(
                        GltfJson.AccesorType,
                        accessor.type,
                    ) orelse return Error.FailedToParse;

                    switch (accessor_type) {
                        .VEC2 => {},
                        else => return Error.InvalidAccessorType,
                    }

                    const stride = view.byteStride orelse blk: {
                        // accessor type enum is equivalent to element count.
                        const count: u32 = @intFromEnum(accessor_type);
                        std.debug.assert(count == 2);

                        break :blk switch (accessor.componentType) {
                            .UNSIGNED_BYTE => count,
                            .UNSIGNED_SHORT => count * @sizeOf(u16),
                            .FLOAT => count * @sizeOf(f32),
                            else => return Error.InvalidAttributeComponent,
                        };
                    };

                    const start = view.byteOffset + accessor.byteOffset;
                    const end = start + (accessor.count * stride);
                    primitives[pidx].texcoords[0] = .{
                        .float = accessor.componentType,
                        .bytes = buffer.bytes[start..end],
                        .stride = stride,
                    };
                } else primitives[pidx].texcoords[0] = null;

                if (gltf_primitive.attributes.TEXCOORD_1) |aidx| {
                    const accessor = &accessors[aidx];

                    const vidx = accessor.bufferView;
                    const view = &bufferViews[vidx];
                    const buffer = buffers.items[view.buffer];

                    const accessor_type = std.meta.stringToEnum(
                        GltfJson.AccesorType,
                        accessor.type,
                    ) orelse return Error.FailedToParse;

                    switch (accessor_type) {
                        .VEC2 => {},
                        else => return Error.InvalidAccessorType,
                    }

                    const stride = view.byteStride orelse blk: {
                        // accessor type enum is equivalent to element count.
                        const count: u32 = @intFromEnum(accessor_type);

                        break :blk switch (accessor.componentType) {
                            .UNSIGNED_BYTE => count,
                            .UNSIGNED_SHORT => count * @sizeOf(u16),
                            .FLOAT => count * @sizeOf(f32),
                            else => return Error.InvalidAttributeComponent,
                        };
                    };

                    const start = view.byteOffset + accessor.byteOffset;
                    const end = start + (accessor.count * stride);
                    primitives[pidx].texcoords[1] = .{
                        .float = accessor.componentType,
                        .bytes = buffer.bytes[start..end],
                        .stride = stride,
                    };
                } else primitives[pidx].texcoords[1] = null;

                if (gltf_primitive.attributes.COLOR_0) |aidx| {
                    const accessor = &accessors[aidx];

                    const vidx = accessor.bufferView;
                    const view = &bufferViews[vidx];
                    const buffer = buffers.items[view.buffer];

                    const accessor_type = std.meta.stringToEnum(
                        GltfJson.AccesorType,
                        accessor.type,
                    ) orelse return Error.FailedToParse;

                    const has_alpha = switch (accessor_type) {
                        .VEC3 => false,
                        .VEC4 => true,
                        else => return Error.InvalidAccessorType,
                    };

                    const stride = view.byteStride orelse blk: {
                        // accessor type enum is equivalent to element count.
                        const count: u32 = @intFromEnum(accessor_type);

                        break :blk switch (accessor.componentType) {
                            .UNSIGNED_BYTE => count,
                            .UNSIGNED_SHORT => count * @sizeOf(u16),
                            .FLOAT => count * @sizeOf(f32),
                            else => return Error.InvalidAttributeComponent,
                        };
                    };

                    const start = view.byteOffset + accessor.byteOffset;
                    const end = start + (accessor.count * stride);
                    primitives[pidx].color = .{
                        .float = accessor.componentType,
                        .has_alpha = has_alpha,
                        .bytes = buffer.bytes[start..end],
                        .stride = stride,
                    };
                }

                if (gltf_primitive.indices) |aidx| {
                    const accessor = &accessors[aidx];

                    const vidx = accessor.bufferView;
                    const view = &bufferViews[vidx];
                    const buffer = buffers.items[view.buffer];

                    const accessor_type = std.meta.stringToEnum(
                        GltfJson.AccesorType,
                        accessor.type,
                    ) orelse return Error.FailedToParse;

                    if (accessor_type != .SCALAR) {
                        return Error.InvalidAttributeType;
                    }

                    const stride = view.byteStride orelse blk: {
                        // accessor type enum is equivalent to element count.
                        const count: u32 = @intFromEnum(accessor_type);

                        break :blk switch (accessor.componentType) {
                            .UNSIGNED_BYTE => count * 1,
                            .UNSIGNED_INT => count * 4,
                            .UNSIGNED_SHORT => count * 2,
                            else => return Error.InvalidAttributeComponent,
                        };
                    };

                    // indices must provide a valid ElementArrayBuffer target
                    if (bufferViews[vidx].target) |target| {
                        switch (target) {
                            .ElementArrayBuffer => {},
                            else => return Error.InvalidIndexTarget,
                        }
                    }

                    const start = view.byteOffset + accessor.byteOffset;
                    const end = start + (accessor.count * stride);
                    primitives[pidx].indices = .{
                        .uint = accessor.componentType,
                        .bytes = buffer.bytes[start..end],
                        .stride = stride,
                    };
                }
            }

            try meshes.append(gpa, .{
                .name = gltf_mesh.name orelse "",
                .primitives = primitives,
            });
        }
    }

    var nodes_list: std.ArrayList(Node) = if (json.nodes) |n| try .initCapacity(gpa, n.len) else .{};
    if (json.nodes) |json_nodes| {
        for (json_nodes) |json_node| {
            try nodes_list.append(gpa, .{
                .mesh_idx = json_node.mesh,

                // Components are guaranteed to be present if matrix is not.
                .transform = if (json_node.matrix) |matrix| .{
                    .Matrix = matrix,
                } else .{
                    .Component = .{
                        .translation = json_node.translation.?,
                        .rotation = json_node.rotation.?,
                        .scale = json_node.scale.?,
                    },
                },

                // Explicit full length slice as child nodes may not have been appended yet.
                .children = if (json_node.children) |c| .new(nodes_list.items.ptr[0..json_nodes.len], c) else null,
            });
        }
    }

    return .{
        .json = parsed,
        .buffers = buffers,
        .images = images,
        .meshes = meshes,
        .nodes = nodes_list,
        .samplers = json.samplers.?,
        .textures = json.textures.?,
        .materials = json.materials.?,
    };
}

/// Returns an iterator to the root nodes of the main scene of the Gltf.
///
/// if a main scene is not provided the scene at index 0 will be used.
/// if scenes array is empty, Returns null.
pub fn roots(self: *const Gltf) ?NodeIterator {
    const iscene: u32 = self.json.value.scene orelse 0;

    if (self.json.value.scenes) |scenes| {
        if (scenes.len <= 0) {
            return null;
        }

        const indices = scenes[iscene].nodes orelse return null;
        return .new(self.nodes.items, indices);
    }

    return null;
}

/// Returns an Depth-First-Search iterator to the root nodes of the main scene of the Gltf.
///
/// if a main scene is not provided the scene at index 0 will be used.
/// if scenes array is empty, Returns null.
pub fn rootsDFS(self: *const Gltf, arena: Allocator) ?NodeDfsIterator {
    const iscene: u32 = self.json.value.scene orelse 0;

    // HACK : Hard coded; Change to calculate max stack size on first iteration.
    const frames = arena.alloc(NodeDfsIterator.Frame, 100) catch return null;

    if (self.json.value.scenes) |scenes| {
        if (scenes.len <= 0) {
            return null;
        }

        const indices = scenes[iscene].nodes orelse return null;
        return .new(self.nodes.items, indices, frames);
    }

    return null;
}

pub fn deinit(self: *Gltf, gpa: Allocator) void {
    self.nodes.deinit(gpa);

    for (self.meshes.items) |mesh| {
        gpa.free(mesh.primitives);
    }
    self.meshes.deinit(gpa);

    for (self.buffers.items) |buffer| {
        gpa.free(buffer.bytes);
    }
    self.buffers.deinit(gpa);

    self.images.deinit(gpa);
    self.json.deinit();
}

/// Reads an entire file into a newly allocated buffer.
/// The caller owns the returned slice and must free it.
fn read(allocator: Allocator, path: []const u8) ![]u8 {
    var f = try std.fs.cwd().openFile(
        path,
        .{
            .mode = .read_only,
        },
    );
    defer f.close();

    const stat = try f.stat();

    const buffer = try allocator.alloc(u8, @intCast(stat.size));

    var reader = f.reader(buffer);
    try reader.interface.readSliceAll(buffer);

    return buffer;
}
