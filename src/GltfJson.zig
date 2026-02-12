//! glTF 2.0 JSON Definitions and Parser
//!
//! This file defines Zig structs that directly mirror the glTF 2.0 JSON schema
//! and provides basic loading and parsing of `.gltf` files using `std.json`.
//!
//! This is a spec-mirroring layer focused on lossless deserialization.
//! The types here are not intended for runtime or engine use.
//!
//! Goals:
//! - 1:1 mapping with glTF 2.0 JSON fields
//! - Preserve optional fields, extensions, and extras
//! - Minimal interpretation at parse time
//!
//! Validation, buffer decoding, sparse resolution, and rendering logic
//! are expected to live outside this module.
//!
//! Spec: https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html
//!
//! LIMITS & MISSING FEATURES:
//! - Scenes:
//!     - Extensions, Extras
//! - Node:
//!     - Extensions, Extras
//!     - camera
//!     - skin
//!     - weights
//! - Buffer:
//!     - Embedded URI
//! - Geometry:
//!     - Meshes:
//!         - Extensions, Extras
//!         - skinning
//!         Primitives:
//!             - targets (Morph Targets)
//!             - 2 max texture coords
//!             - 1 max color attributes
//! - Textures:
//!     - Name, Extensions, Extras
//!     - Images:
//!         - Data URI with Embedded
//!         - Buffer view W MimeType
//!     - Samplers:
//!         - Name, Extensions, Extras
//! - Material:
//!     - Point and Line Materials
//! - Animation:
//! - Camera:
//! - Extensions
//! - Extras
const GltfJson = @This();

const std = @import("std");

// Enum set to element #
pub const AccesorType = enum(u32) {
    SCALAR = 1,
    VEC2 = 2,
    VEC3 = 3,
    VEC4 = 4,
    // MAT2 = 3,
    MAT3 = 9,
    MAT4 = 16,
};

pub const ComponentType = enum(u32) {
    BYTE = 5120,
    UNSIGNED_BYTE = 5121,
    SHORT = 5122,
    UNSIGNED_SHORT = 5123,
    UNSIGNED_INT = 5125,
    FLOAT = 5126,
};

/// A node in the node hierarchy.
pub const Node = struct {
    children: ?[]const u32 = null,

    // Either
    ///A floating-point 4x4 transformation matrix stored in column-major order.
    matrix: ?[16]f32 = [_]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },

    // or
    /// The node’s translation along the x, y, and z axes.
    translation: ?[3]f32 = [_]f32{ 0, 0, 0 },
    /// The node’s non-uniform scale, given as the scaling factors along the x, y, and z axes.
    scale: ?[3]f32 = [_]f32{ 1, 1, 1 },
    /// The node’s unit quaternion rotation in the order (x, y, z, w), where w is the scalar.
    rotation: ?[4]f32 = [_]f32{ 0, 0, 0, 1 },

    mesh: ?u32 = null,

    /// The user-defined name of this object.
    name: ?[]const u8 = null,
};

pub const Scene = struct {
    /// The user-defined name of this scene.
    name: ?[]const u8 = null,

    /// The Indices of each root node.
    nodes: ?[]u32 = null,
};

/// Sampler specifies filtering and wrapping modes.
pub const Sampler = struct {
    const Filter = enum(u32) {
        NEAREST = 9728,
        LINEAR = 9729,

        // minFilter Only
        NEAREST_MIPMAP_NEAREST = 9984,
        LINEAR_MIPMAP_NEAREST = 9985,
        NEAREST_MIPMAP_LINEAR = 9986,
        LINEAR_MIPMAP_LINEAR = 9987,
    };

    const WrapMode = enum(u32) {
        CLAMP_TO_EDGE = 33071,
        MIRRORED_REPEAT = 33648,
        REPEAT = 10497,
    };

    magFilter: ?Filter = null,
    minFilter: ?Filter = null,
    wrapS: WrapMode = .REPEAT,
    wrapT: WrapMode = .REPEAT,
};

/// Primitives correspond to the data required for GPU draw calls.
pub const Primitive = struct {
    pub const Mode = enum(u32) {
        POINTS = 0,
        LINES,
        LINE_LOOP,
        LINE_STRIP,
        TRIANGLES,
        TRIANGLE_STRIP,
        TRIANGLE_FAN,
    };

    /// A plain JSON object, where each key corresponds to a mesh attribute semantic
    /// and each value is the index of the accessor containing attribute’s data.
    attributes: struct {
        /// Unitless XYZ vertex positions.
        POSITION: ?u32 = null,

        /// Normalized XYZ vertex normals.
        NORMAL: ?u32 = null,

        /// XYZW vertex tangents where the XYZ portion is normalized,
        /// and the W component is a sign value (1 or +1) indicating handedness of the tangent basis.
        ///
        /// When tangents are not specified, client implementations SHOULD calculate tangents using default MikkTSpace
        /// algorithms with the specified vertex positions, normals, and texture coordinates associated with the normal texture.
        TANGENT: ?u32 = null,

        ///ST texture coordinates.
        TEXCOORD_0: ?u32 = null,
        TEXCOORD_1: ?u32 = null,

        /// RGB or RGBA vertex color linear multiplier.
        COLOR_0: ?u32 = null,

        // JOINT_N,
        // WEIGHT_N,
    },

    /// The index of the accessor that contains the vertex indices.
    indices: ?u32 = null,

    /// The index of the accessor that contains the vertex indices.
    material: ?u32 = null,

    /// The index of the accessor that contains the vertex indices.
    mode: Mode = .TRIANGLES,
};

/// A texture and its samplers.
pub const Texture = struct {
    /// Index into images array, if not present, data must be provided by extension.
    source: u32,

    /// If not present, repeated wrapping sampler must be provided.
    sampler: ?u32,

    /// The user-defined name of this object.
    name: ?[]const u8 = null,
};

pub const Material = struct {
    const AlphaMode = enum {
        /// The rendered output is fully opaque and any alpha value is ignored.
        OPAQUE,
        /// The rendered output is either fully opaque or fully transparent depending on the alpha value and the specified alpha cutoff value
        MASK,
        /// The rendered output is combined with the background.
        BLEND,
    };

    /// The user-defined name of this object.
    name: ?[]const u8 = null,

    /// The user-defined name of this object.
    pbrMetallicRoughness: ?struct {
        /// The base color of the material.
        baseColorFactor: [4]f32 = [_]f32{ 1.0, 1.0, 1.0, 1.0 },

        /// The base color texture MUST contain 8-bit values encoded with the sRGB. baseColorTexture: ?struct {
        baseColorTexture: ?struct {
            index: u32,
            texCoord: u32 = 0,
        } = null,

        /// The metalness of the material.
        ///
        /// values range from 0.0 (non-metal) to 1.0 (metal)
        metallicFactor: f32 = 1.0,

        /// The textures for metalness and roughness properties are packed together in a single texture.
        ///
        /// Its green channel contains roughness values and its blue channel contains metalness values.
        metallicRoughnessTexture: ?struct {
            index: u32,
            texCoord: u32 = 0,
        } = null,

        /// The roughness of the material.
        ///
        /// values range from 0.0 (smooth) to 1.0 (rough).
        roughnessFactor: f32 = 1.0,
    },

    /// A tangent space normal texture. Encodes XYZ components of a normal vector in tangent space
    /// as RGB values stored with linear transfer function.
    ///
    /// Texel values MUST be mapped as follows:
    /// - red [0.0 .. 1.0] to X [-1 .. 1]
    /// - green [0.0 .. 1.0] to Y [-1 .. 1]
    /// - blue (0.5 .. 1.0] maps to Z (0 .. 1]
    normalTexture: ?struct {
        index: u32,
        texCoord: u32 = 0,
        scale: f32 = 1.0,
    } = null,

    /// The occlusion texture.
    ///
    /// it indicates areas that receive less indirect lighting from ambient sources.
    /// Direct lighting is not affected. The red channel of the texture encodes the occlusion value,
    /// where 0.0 means fully-occluded area (no indirect lighting) and 1.0 means not occluded area (full indirect lighting).
    occlusionTexture: ?struct {
        index: u32,
        texCoord: u32 = 0,
        strength: f32 = 1.0,
    } = null,

    /// The emissive texture and factor control the color and intensity of the light being emitted by the material.
    emissiveTexture: ?struct {
        index: u32,
        texCoord: u32 = 0,
    } = null,

    emissiveFactor: [3]f32 = [_]f32{ 1.0, 1.0, 1.0 },

    alphaMode: []const u8 = "OPAQUE",

    alphaCutOff: f32 = 0.5,

    /// When this value is false, back-face culling is enabled.
    doubleSided: bool = false,
};

asset: struct {
    /// The glTF version in the form of <major>.<minor> that this asset targets.
    version: []u8,

    /// The minimum glTF version in the form of <major>.<minor> that this asset targets. This property MUST NOT be greater than the asset version.
    minVersion: ?[]const u8 = null,

    /// Tool that generated this glTF model. Useful for debugging.
    generator: ?[]const u8 = null,

    /// A copyright message suitable for display to credit the content creator.
    copyright: ?[]const u8 = null,

    /// JSON object with extension-specific objects.
    extension: ?std.json.Value = null,

    /// Application-specific data.
    extras: ?std.json.Value = null,
},

// Identifies which of the scenes in the array SHOULD be displayed at load time.
scene: ?u32 = null,

/// the set of visual objects to render.
scenes: ?[]Scene = null,

nodes: ?[]Node = null,

// glTF 2.0 — Meshes
/// https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#meshes
/// Meshes are defined as arrays of primitives.
meshes: ?[]struct {
    /// The user-defined name of this object.
    name: ?[]const u8,

    primitives: []Primitive,
},

images: ?[]struct {
    // Either
    uri: ?[]const u8 = null,
    // or
    bufferView: ?u32 = null,
    mimeType: ?u32 = null,
},

samplers: ?[]Sampler,

textures: ?[]Texture,

materials: ?[]Material,

/// glTF 2.0 — Buffers and Buffer Views
/// https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#buffers-and-buffer-views
/// A buffer points to binary geometry, animation, or skins.
buffers: ?[]struct {
    /// The URI (or IRI) of the buffer.
    uri: ?[]const u8,

    /// The length of the buffer in bytes.
    byteLength: u32,

    /// The user-defined name of this object.
    name: ?[]const u8 = null,

    /// JSON object with extension-specific objects.
    extension: ?std.json.Value = null,

    /// Application-specific data.
    extras: ?std.json.Value = null,
} = null,

/// glTF 2.0 — Buffers and Buffer Views
/// https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#buffers-and-buffer-views
/// A view into a buffer generally representing a subset of the buffer.
bufferViews: ?[]struct {
    const ViewTarget = enum(u32) {
        ArrayBuffer = 34962,
        ElementArrayBuffer = 34963,
    };

    /// The index of the buffer.
    buffer: u32,

    /// The offset into the buffer in bytes.
    byteOffset: u32 = 0,

    byteLength: u32,

    /// Indicates stride for vertex attirbutes, only.
    ///
    /// When byteStride of the referenced bufferView is not defined, it means that accessor elements are tightly packed,
    /// i.e., effective stride equals the size of the element.
    byteStride: ?u32 = null,

    /// The hint representing the intended GPU buffer type to use with this buffer view.
    target: ?ViewTarget = null,

    /// The user-defined name of this object.
    name: ?[]const u8 = null,

    /// JSON object with extension-specific objects.
    extension: ?std.json.Value = null,

    /// Application-specific data.
    extras: ?std.json.Value = null,
} = null,

/// glTF 2.0 — Accessor Sparse Storage
/// https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#accessors
/// A typed view into a buffer view that contains raw binary data.
accessors: ?[]struct {
    /// The index of the bufferView.
    bufferView: u32,

    /// The offset relative to the start of the buffer view in bytes.
    byteOffset: u32 = 0,

    /// The datatype of the accessor’s components.
    componentType: ComponentType,

    /// Specifies whether integer data values are normalized before usage.
    normalized: bool = false,

    /// The number of elements referenced by this accessor.
    count: u32,

    /// Specifies if the accessor’s elements are scalars, vectors, or matrices.
    ///
    /// Raw string value from glTF JSON (e.g. "SCALAR", "VEC3").
    /// Parsed into `Type` during validation.
    type: []const u8,

    /// Maximum value of each component in this accessor.
    ///
    /// Must be of type `Type`.
    max: ?[]std.json.Value = null,

    /// Minimum value of each component in this accessor.
    ///
    /// Must be of type `Type`.
    min: ?[]std.json.Value = null,

    /// glTF 2.0 — Accessor Sparse Storage
    /// https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#sparse-accessors
    sparse: ?struct {
        /// Number of deviating accessor values stored in the sparse array.
        count: u32,

        /// An object pointing to a buffer view containing the indices of deviating accessor values. T
        indices: struct {
            /// The index of the buffer view with sparse indices. T
            bufferView: u32,
            /// The offset relative to the start of the buffer view in bytes.
            byteoffset: u32 = 0,
            /// The indices data type.
            componentType: ComponentType,

            /// JSON object with extension-specific objects.
            extension: ?std.json.Value = null,

            /// Application-specific data.
            extras: ?std.json.Value = null,
        },

        /// An object pointing to a buffer view containing the deviating accessor values.
        values: struct {
            /// The index of the buffer view with sparse indices. T
            bufferView: u32,
            /// The offset relative to the start of the buffer view in bytes.
            byteoffset: u32 = 0,
            /// The indices data type.
            componentType: ComponentType,

            /// JSON object with extension-specific objects.
            extension: ?std.json.Value = null,

            /// Application-specific data.
            extras: ?std.json.Value = null,
        },

        /// JSON object with extension-specific objects.
        extension: ?std.json.Value = null,

        /// Application-specific data.
        extras: ?std.json.Value = null,
    } = null,

    name: ?[]const u8 = null,
},
