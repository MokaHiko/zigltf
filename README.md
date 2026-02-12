# zigltf

A minimal glTF 2.0 loader for Zig.

`zigltf` provides:

- Direct deserialization of the glTF 2.0 JSON schema
- External buffer loading
- Accessor resolution
- Primitive attribute slicing
- Scene graph iteration utilities

It is designed as a lightweight, engine-agnostic asset loading layer.

---

## Design Goals

- No external dependencies
- Explicit buffer and accessor resolution
- Minimal interpretation beyond spec requirements

---

## Features

- JSON schema mirror (`GltfJson`)
- External `.bin` buffer loading
- Accessor byte-range resolution
- Typed `PrimitiveView` attribute access
- Node iteration utilities (BFS and DFS)
- Scene root resolution

---

## Not Included

- GPU upload
- Animation runtime
- Skinning
- Morph targets
- Embedded data URIs
- Extension interpretation
- Scene graph transform evaluation

---

## Example

```zig
const zigltf = @import("zigltf");

const gltf = try zigltf.Gltf.init(raw, allocator, path);
defer gltf.deinit(allocator);

// Depth-First-Search iterator
if (gltf.roots()) |roots| {
    var it = roots;
    while (it.next()) |node| {
        // process node
    }
}
