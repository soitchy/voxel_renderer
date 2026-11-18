# Learning Path: wgpu + Odin → Minecraft-style Voxel Renderer

You already have **Stage 0** done: SDL3 window, wgpu instance/adapter/device, surface
configuration, resize handling, and a clear-color render pass. Everything below builds
on that code, one working milestone at a time. Each stage lists:

- **Learn**: the concepts
- **Build**: a concrete milestone that proves you understand them
- **Voxel tech**: (where relevant) the technique specific to voxel engines
- **Gotchas**: things that commonly bite people with wgpu/WGSL/Odin

Rough time estimates assume evenings/weekends. Don't skip the "Build" steps. The voxel
stages depend on you actually understanding the earlier GPU plumbing.

---

## Part 1: wgpu Fundamentals (Stages 1–5)

### Stage 1: Your first triangle (pipelines & shaders) · ~1 week
**Learn**
- The wgpu object model: `ShaderModule` → `RenderPipeline` → `RenderPass.Draw`
- WGSL basics: `@vertex`, `@fragment`, `@builtin(position)`, `@location(n)`
- Clip space in WebGPU: x/y in [-1, 1], **z in [0, 1]** (not OpenGL's [-1, 1])
- Embedding shaders with Odin's `#load("shader.wgsl", string)`

**Build**
- Hardcode 3 vertices in the vertex shader using `@builtin(vertex_index)`, no buffers yet
- Draw a colored triangle inside your existing render pass in `render_frame`
- Add `pipeline` to `Gpu_State`; create it in a new `pipeline.odin`

**Gotchas**
- The pipeline's color target format must match `gpu.config.format`
- Your `on_uncaptured_error` callback is your best friend: read every message

---

### Stage 2: Vertex & index buffers · ~3–5 days
**Learn**
- `DeviceCreateBuffer`, buffer usages (`.Vertex`, `.Index`, `.CopyDst`)
- `QueueWriteBuffer` to upload data
- `VertexBufferLayout`, `VertexAttribute`, `stepMode`, formats like `.Float32x3`
- Index buffers (`u16` vs `u32`), `DrawIndexed`

**Build**
- Define an Odin `Vertex :: struct { pos: [3]f32, color: [3]f32 }`
- Draw a quad from 4 vertices + 6 indices
- Write a tiny helper: `create_buffer_init(gpu, data: []$T, usage) -> wgpu.Buffer`

**Gotchas**
- `QueueWriteBuffer` sizes must be multiples of 4 bytes
- Use `size_of(Vertex)` for `arrayStride`, `offset_of(Vertex, color)` for attribute offsets

---

### Stage 3: Uniforms, bind groups & a 3D camera · ~1–2 weeks
**Learn**
- `BindGroupLayout` → `PipelineLayout` → `BindGroup`, and `@group(0) @binding(0)`
- Uniform buffers, `var<uniform>` in WGSL
- Model/View/Projection matrices with `core:math/linalg` (`matrix[4,4]f32`)
- A perspective matrix for **[0,1] depth**. Write your own, or use a
  **reverse-Z infinite** projection (strongly recommended for voxel worlds with far view distances)
- An FPS camera: yaw/pitch, WASD, mouse look via `sdl3.SetWindowRelativeMouseMode`
- Delta time (`sdl3.GetTicksNS` / `core:time`)

**Build**
- Spinning cube, then a free-fly camera you can move around it
- Put camera + input in `camera.odin`

**Gotchas**
- **WGSL alignment**: `vec3<f32>` aligns to 16 bytes in uniform buffers. Pad your Odin
  structs or use `vec4`. Mismatches silently produce garbage.
- Odin matrices are column-major in memory, which matches WGSL. Don't transpose.
- `linalg.matrix4_perspective` defaults to OpenGL-style depth; check the `flip_z_axis` param
  and the depth range it produces before trusting it.

---

### Stage 4: Depth buffer · ~2 days
**Learn**
- Creating a depth texture (`.Depth32Float`), `DepthStencilState`, `depthCompare`
- Recreating the depth texture on resize (extend `wgpu_resize`)
- Back-face culling via `PrimitiveState.cullMode` + `frontFace`

**Build**
- Draw a 10×10×10 grid of cubes with correct occlusion and culling

**Gotchas**
- With reverse-Z: clear depth to `0.0` and compare with `.Greater`

---

### Stage 5: Textures & samplers · ~1 week
**Learn**
- Creating textures, `QueueWriteTexture`, `TextureView`, `Sampler`
- Loading PNGs (`core:image/png` or `vendor:stb/image`)
- **Texture arrays** (`texture_2d_array<f32>`): one layer per block texture
- Mipmaps (you generate them yourself in wgpu: a compute or blit pass, or on the CPU)
- Nearest filtering for that crisp pixel-art look

**Build**
- Textured cube with different textures per face (grass top/side, dirt bottom)

**Voxel tech: Texture array vs. atlas**
Atlases bleed at tile edges when mipmapped and need padding hacks. A texture array with
`layer = block_texture_id` avoids that entirely and makes greedy-meshed quads tile
correctly with `fract()`-style UV repeat. **Use a texture array.**

---

## Part 2: Core Voxel Engine (Stages 6–11)

### Stage 6: Chunk data structures · ~3–5 days
**Learn / Voxel tech**
- **Chunks**: fixed-size blocks of voxels (16³ or 32³ are common; 32³ suits bit tricks later)
- Flat array storage: `index = x + z*S + y*S*S` (pick an order and keep it consistent)
- Block IDs as `u8`/`u16` and a **block registry** (`Block_Info { name, solid, transparent, textures: [6]u16 }`)
- World coordinates ↔ chunk coordinates ↔ local coordinates (floor-division for negatives!)
- A world map: `map[[3]i32]^Chunk`

**Build**
- `chunk.odin`: `Chunk`, `chunk_get`, `chunk_set`, `world_get_block(world_pos)`
- Fill a chunk with a test pattern (sphere, checkerboard)

**Gotchas**
- `-1 / 16 == 0` in integer division. Use `floor_div` / `%%` (Odin's floored modulo) for chunk math.

---

### Stage 7: Chunk meshing: naive → face culling · ~1 week
**Voxel tech**
1. **Naive**: emit 6 faces per solid block. Correct but ~10× too many triangles.
2. **Face culling**: only emit a face if the neighbor in that direction is air/transparent.
   This is the single biggest win and the baseline of every voxel engine.
3. **Neighbor padding**: when meshing, read a 1-block border from neighboring chunks
   (copy into an `(S+2)³` scratch array) so chunk boundaries cull correctly.

**Build**
- `mesh.odin`: `mesh_chunk(chunk, neighbors) -> (vertices, indices)`
- Upload each chunk's mesh to its own vertex/index buffer; draw a 4×4 chunk area
- Add a per-chunk offset (uniform or push constant) so vertex positions stay chunk-local

**Gotchas**
- Remesh neighbors too when a block on a chunk border changes
- Release GPU buffers when a chunk is unloaded or remeshed (`wgpu.BufferRelease`)

---

### Stage 8: Vertex packing · ~3 days
**Voxel tech**
Chunk-local positions only need 5–6 bits per axis. Pack a whole vertex into one or two `u32`s:

```
bits  0-5   x        (0..32)
bits  6-11  y
bits 12-17  z
bits 18-20  normal / face index (0..5)
bits 21-22  ambient occlusion (0..3)
bits 23-31  texture layer
```
Unpack in WGSL with shifts and masks. Odin's `bit_field` type is great for the CPU side.

**Build**
- Switch to `.Uint32` vertex format; measure memory before/after (expect 4–8× smaller)

**Stretch: vertex pulling**
Skip vertex buffers entirely: store packed *quads* in a storage buffer and generate the
4 corners in the vertex shader from `vertex_index`. Fewer bytes, one shared index buffer.

---

### Stage 9: Procedural terrain · ~1–2 weeks
**Voxel tech**
- **Noise**: `core:math/noise` gives you OpenSimplex2 (`noise_2d`, `noise_3d_*`)
- **fBm** (fractal Brownian motion): sum octaves with rising frequency / falling amplitude
- **Heightmap terrain** (2D noise → surface height) → grass/dirt/stone layering
- **3D density** for overhangs and caves: `density(x,y,z) = noise3d(...) - (y - base_height) * k`
- **Domain warping** for more natural shapes
- **Biomes**: separate low-frequency temperature/humidity noise maps choose block palettes
- **Structures** (trees): place them so they can cross chunk borders. Generate per-chunk
  with a deterministic seed from chunk coords, and let neighbors query "what would chunk X place here?"

**Build**
- Infinite-looking hills with stone/dirt/grass, then caves, then trees

---

### Stage 10: Infinite world: streaming & threading · ~2 weeks
**Learn**
- `core:thread` (thread pool), `core:sync` (mutexes, channels/queues, atomics)
- Moving work off the main thread while all wgpu calls stay on it

**Voxel tech**
- **Chunk loading radius** around the player, ordered by distance (spiral / sorted queue)
- **Pipeline states**: `Unloaded → Generating → Generated → Meshing → Ready → Uploaded`
- Workers do generation + meshing; the main thread only uploads finished meshes
- **Upload budget**: cap N chunk uploads per frame to avoid hitches
- **Unloading** chunks beyond radius + hysteresis
- **Frustum culling** per chunk AABB (extract planes from view-projection matrix)

**Build**
- Fly forever without hitches; show chunk counts / frame time in the window title

**Gotchas**
- Odin's `context` (allocator, logger) is per-thread. Set allocators explicitly in workers.
- Don't let a worker read a chunk while another thread writes it; snapshot neighbors for meshing.

---

### Stage 11: Interaction: raycasting, editing, physics · ~1–2 weeks
**Voxel tech**
- **DDA voxel traversal** (Amanatides & Woo, "A Fast Voxel Traversal Algorithm"): step
  through the grid along the view ray to find the targeted block and the face you hit
- Break (left click) / place (right click on the hit face's neighbor) → remesh affected chunks
- **Block outline**: a wireframe cube drawn with a separate `LineList` pipeline
- **AABB player physics**: gravity, jumping, and **per-axis swept collision**
  (move X, resolve; move Y, resolve; move Z, resolve) against nearby solid blocks
- Toggle fly/walk mode

**Build**
- Walk around, mine, and build. This is the "it's a game now" moment.

---

## Part 3: Making It Look Like Minecraft (Stages 12–15)

### Stage 12: Per-vertex ambient occlusion · ~3–5 days
**Voxel tech**
For each face vertex, look at the 3 neighbors (side1, side2, corner):
```
ao = (side1 && side2) ? 0 : 3 - (side1 + side2 + corner)
```
Store the 0–3 value in your packed vertex. Then **flip the quad's triangulation** when
`ao0 + ao3 > ao1 + ao2` to avoid the ugly anisotropic diagonal artifact.
Reference: 0fps, "Ambient occlusion for Minecraft-like worlds".

---

### Stage 13: Flood-fill lighting · ~2 weeks
**Voxel tech**
- Two light channels per voxel (4 bits each): **sunlight** and **block light** (torches, lava)
- **BFS propagation** with a queue: each step light −1, stops at opaque blocks
- Sunlight travels straight down without decay
- **Light removal** needs a second "removal queue" BFS, then re-propagate from the boundary
- Lighting crosses chunk boundaries, so update neighbors
- Shade with smooth lighting (average light of the same 4 samples you use for AO)
- Day/night: scale sunlight by a uniform `time_of_day` in the shader instead of recomputing

Reference: Seed of Andromeda, "Fast Flood Fill Lighting in a Blocky Voxel Game".

---

### Stage 14: Transparency, water & foliage · ~1–2 weeks
**Learn**
- Blend state, multiple pipelines, render pass ordering

**Voxel tech**
- **Three passes**: opaque → alpha-tested (leaves, grass, `discard` in the fragment shader) → translucent (water, glass)
- Separate mesh per chunk for translucent geometry
- **Sort translucent chunks back-to-front** (per-face sorting is a stretch goal)
- **Cross-quad meshes** for plants (two diagonal quads, no culling)
- Water surface slightly lowered, animated via a `time` uniform
- **Alpha-to-coverage / mip alpha fix** so leaves don't vanish in the distance

---

### Stage 15: Atmosphere & polish · ~1 week
- **Distance fog** blended to sky color. This hides chunk pop-in at the render-distance edge.
- Sky gradient + sun/moon (fullscreen triangle pass before terrain)
- Simple directional shading per face (top 1.0, sides 0.8/0.6, bottom 0.5): the classic look
- Clouds (instanced flat boxes or a scrolling noise layer)
- Debug overlay: FPS, position, chunk coords, triangle count (`vendor:microui` or a simple bitmap font)

---

## Part 4: Performance & Advanced Voxel Tech (Stages 16–20)

Profile first! Add GPU timestamp queries (`.TimestampQuery` feature) and CPU timers
before optimizing.

### Stage 16: Greedy meshing · ~1–2 weeks
**Voxel tech**
Merge coplanar adjacent faces of the same type (and same AO/light!) into larger quads.
Often 3–10× fewer triangles.
- Classic algorithm: 0fps, "Meshing in a Minecraft Game"
- **Binary greedy meshing**: represent each column as a `u64` bitmask (why 32³/62³ chunks
  are popular) and use bitwise ops + `intrinsics.count_trailing_zeros` for face culling and
  merging. Orders of magnitude faster than the classic version.
- Texture tiling on merged quads needs the texture-array + repeat UV approach from Stage 5

---

### Stage 17: Draw-call reduction · ~1–2 weeks
- **One giant vertex buffer** with your own sub-allocator (free list / buddy allocator)
  instead of one buffer per chunk
- **Indirect drawing**: `DrawIndexedIndirect`; wgpu-native exposes **multi-draw indirect**
  as a native feature, so request it when creating the device
- **Per-face-direction meshes**: split each chunk's mesh into 6 groups and skip groups facing
  away from the camera (e.g. skip all +X faces when the camera is at lower X than the chunk)
- **GPU frustum culling** in a compute shader that writes the indirect buffer

---

### Stage 18: Occlusion culling · ~1–2 weeks
**Voxel tech**
- **Cave culling** (Tommaso Checchi's Minecraft visibility graph): per chunk, flood fill
  air to record which faces connect to which; BFS through chunks from the camera only
  through connected faces. Huge win underground.
- Alternative: Hi-Z occlusion culling with a depth pyramid in compute

---

### Stage 19: Saving & large worlds · ~1 week
- **Palette compression** in memory: per-chunk palette + bit-packed indices
- **Region files**: group 32×32 chunks per file, with an offset table
- RLE or zstd compression on disk
- **Camera-relative rendering**: keep world positions as `i32` chunk coords + local `f32`
  offsets so precision holds far from the origin

---

### Stage 20: Stretch goals (pick any)
- **LOD terrain** for huge view distances (downsampled chunks, or "Distant Horizons"-style
  heightmap impostors)
- **Ray-marched voxels**: a compute shader doing DDA through a 3D texture or **sparse voxel
  octree / brickmap**. A completely different rendering architecture, great to compare.
- **Shadow mapping** (cascaded shadow maps for the sun)
- **SSAO / bloom / tonemapping** post-processing chain
- **Multiplayer**: server-authoritative chunks over `core:net`

---

## Suggested File Layout as You Grow
```
main.odin          app loop, input dispatch
wgpu_init.odin     (existing) device/surface setup
pipeline.odin      pipeline + bind group creation helpers
camera.odin        camera, matrices, frustum
texture.odin       texture array loading, mipmaps
chunk.odin         chunk storage, coordinate math
world.odin         chunk map, streaming, block registry
mesh.odin          meshing (naive → culled → greedy)
worldgen.odin      noise, biomes, structures
lighting.odin      flood-fill light
physics.odin       AABB collision, raycast
jobs.odin          worker threads, job queues
shaders/           .wgsl files, loaded with #load
```

## Resources
**wgpu / WebGPU** (most tutorials are Rust or JS, but the wgpu API maps nearly 1:1 to Odin's `vendor:wgpu`)
- Learn Wgpu: https://sotrh.github.io/learn-wgpu/ (follow alongside Part 1)
- WebGPU Fundamentals: https://webgpufundamentals.org/ (excellent on alignment, textures, compute)
- WGSL spec: https://www.w3.org/TR/WGSL/
- Odin examples repo: https://github.com/odin-lang/examples (has wgpu samples)
- Your Odin install's `vendor/wgpu/wgpu.odin`: the source of truth for proc names

**Voxel-specific**
- 0fps: "Meshing in a Minecraft Game" and "Ambient occlusion for Minecraft-like worlds"
- Amanatides & Woo, "A Fast Voxel Traversal Algorithm for Ray Tracing" (1987)
- Seed of Andromeda: "Fast Flood Fill Lighting in a Blocky Voxel Game"
- Tommaso Checchi: "Advanced Cave Culling Algorithm" (tomcc.github.io)
- Binary greedy meshing: search "binary greedy meshing" (cgerikj's repo and TanTan's video)
- Vercidium's videos on voxel optimization (vertex packing, face-direction culling)

---

## Progress Checklist
- [x] 0. Window + wgpu init + clear color
- [ ] 1. Triangle
- [ ] 2. Vertex/index buffers
- [ ] 3. Uniforms + 3D camera
- [ ] 4. Depth buffer
- [ ] 5. Texture arrays
- [ ] 6. Chunk storage
- [ ] 7. Face-culled meshing
- [ ] 8. Vertex packing
- [ ] 9. Terrain generation
- [ ] 10. Infinite streaming + threads
- [ ] 11. Raycast, edit, physics
- [ ] 12. Ambient occlusion
- [ ] 13. Flood-fill lighting
- [ ] 14. Transparency/water/foliage
- [ ] 15. Fog, sky, polish
- [ ] 16. Greedy meshing
- [ ] 17. Indirect draws / big buffers
- [ ] 18. Cave culling
- [ ] 19. Saving + compression
- [ ] 20. Stretch goal of choice
