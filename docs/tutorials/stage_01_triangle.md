# Stage 1: Your First Triangle

**Goal:** draw a colored triangle on top of your clear color, without any vertex buffers.

**You'll learn:**
- What a render pipeline is and why wgpu makes you build one up front
- How to write a WGSL vertex and fragment shader
- How Odin's `#load` embeds a shader file into your binary
- How a draw call fits into the render pass you already have

**You'll touch:**
- `shaders/triangle.wgsl` (new)
- `pipeline.odin` (new)
- `wgpu_init.odin` (add a field to `Gpu_State`, clean up in `wgpu_shutdown`)
- `main.odin` (create the pipeline, issue the draw)

Each step explains the idea, tells you what to write, and ends with a **checkpoint**.
Solutions are hidden in collapsible **Spoiler** blocks. Try each step yourself first.

---

## Background: the mental model

In OpenGL you set state (`glEnable`, `glBlendFunc`, `glUseProgram`, ...) right before each
draw. wgpu (like Vulkan, Metal and D3D12) **bakes almost all of that state into one immutable
object, the `RenderPipeline`**, created once at startup:

```
RenderPipeline
├── vertex stage      → shader module + entry point + vertex buffer layouts
├── primitive state   → triangles? lines? culling? winding order?
├── depth/stencil     → (Stage 4)
├── multisample state → MSAA sample count
├── fragment stage    → shader module + entry point + color target formats/blending
└── layout            → which bind groups (uniforms/textures) the shaders expect (Stage 3)
```

At draw time you only say "use this pipeline" and "draw N vertices". The driver can validate
and compile everything ahead of time, so draws are cheap. The cost is that **changing any of
this state means a different pipeline.** Later you'll have one pipeline for opaque blocks, one
for water, one for the block outline, and so on.

Each frame looks like this:

```
SurfaceGetCurrentTexture → CommandEncoder → BeginRenderPass
    → SetPipeline → Draw          ← new this stage
→ End → Finish → QueueSubmit → Present
```

You already have everything except the middle line.

---

## Step 1: Write the shader

Create `shaders/triangle.wgsl`.

### Concepts

**WGSL** is WebGPU's shading language. Its syntax is Rust-flavored:

```wgsl
fn add(a: f32, b: f32) -> f32 { return a + b; }
var x: f32 = 1.0;          // mutable
let y = vec3<f32>(1.0);    // immutable; vec3f is shorthand for vec3<f32>
```

A shader module can hold several **entry points**, each marked with a stage attribute:
- `@vertex fn vs_main(...)` runs once per vertex. It **must** output a clip-space position
  marked `@builtin(position)`.
- `@fragment fn fs_main(...)` runs once per covered pixel. It outputs a color to
  `@location(0)`, the first color attachment of the render pass.

**Passing data from vertex to fragment.** Make a struct where one field is
`@builtin(position)` and the rest are `@location(n)` values. The GPU **interpolates** the
`@location` values across the triangle. Give each corner a different color and you get the
classic rainbow gradient for free.

**No vertex buffer?** The built-in `@builtin(vertex_index) idx: u32` input tells you which
vertex (0, 1, 2, ...) you're on. You can index into a constant array declared inside the
shader:

```wgsl
var positions = array<vec2f, 3>(vec2f(...), vec2f(...), vec2f(...));
let p = positions[idx];
```

(Use `var`, not `let`, for the array. WGSL only allows dynamic indexing into a `var`.)

**Clip space.** The position you output is a `vec4f(x, y, z, w)`. After dividing by `w`:
- x: -1 (left) to +1 (right)
- y: -1 (bottom) to +1 (top), so **y points up**
- z: **0 (near) to 1 (far)**. This differs from OpenGL's -1..1 and will matter in Stage 3.

For now use `z = 0.0` and `w = 1.0`.

### Your task

Write a shader with:
1. A `VertexOutput` struct with a `@builtin(position)` field and a `@location(0)` color field
2. `vs_main` that picks a position and color from two constant arrays using `vertex_index`
3. `fs_main` that takes `VertexOutput` and returns the interpolated color as a `vec4f` at `@location(0)`

Choose triangle corners that are **counter-clockwise** when viewed on screen, e.g. bottom-left,
bottom-right, top. You'll see why in Step 3.

<details>
<summary>Hint: function signatures</summary>

```wgsl
@vertex
fn vs_main(@builtin(vertex_index) idx: u32) -> VertexOutput { ... }

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f { ... }
```
</details>

<details>
<summary>Spoiler: full shader</summary>

```wgsl
struct VertexOutput {
    @builtin(position) clip_position: vec4f,
    @location(0) color: vec3f,
}

@vertex
fn vs_main(@builtin(vertex_index) idx: u32) -> VertexOutput {
    var positions = array<vec2f, 3>(
        vec2f(-0.5, -0.5), // bottom-left
        vec2f( 0.5, -0.5), // bottom-right
        vec2f( 0.0,  0.5), // top
    );
    var colors = array<vec3f, 3>(
        vec3f(1.0, 0.0, 0.0),
        vec3f(0.0, 1.0, 0.0),
        vec3f(0.0, 0.0, 1.0),
    );

    var out: VertexOutput;
    out.clip_position = vec4f(positions[idx], 0.0, 1.0);
    out.color = colors[idx];
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    return vec4f(in.color, 1.0);
}
```
</details>

**Checkpoint:** nothing to run yet. Errors in this file will show up as wgpu validation
errors in Step 3.

---

## Step 2: Load the shader into a `ShaderModule`

Create `pipeline.odin` (`package main`).

### Concepts

**`#load`** is an Odin compile-time directive. It reads a file and embeds its contents in the
binary:

```odin
SHADER_SRC :: #load("shaders/triangle.wgsl", string)
```

The path is relative to the `.odin` file that contains the directive. Because the shader is
baked in, the binary doesn't need the `.wgsl` file at runtime. The downside is that you have
to rebuild to see shader changes (hot reload is a nice later project).

**Chained structs.** wgpu's C API extends descriptors with linked lists of extension structs,
because one `ShaderModuleDescriptor` can describe WGSL or SPIR-V sources. You build the source
struct, then point the descriptor's `nextInChain` at it:

```
ShaderModuleDescriptor { label, nextInChain ─┐ }
                                             ▼
                      ShaderSourceWGSL { chain = { sType = .ShaderSourceWGSL }, code }
```

In Odin's bindings, `ShaderSourceWGSL` has `using chain: ChainedStruct`. You set
`sType = .ShaderSourceWGSL` and pass `&your_wgsl_struct.chain` as `nextInChain`.

`StringView` in these bindings is just an Odin `string`, so labels and code are plain strings.

### Your task

Write a proc, e.g. `create_shader_module :: proc(device: wgpu.Device, label, source: string) -> wgpu.ShaderModule`,
that builds the WGSL source struct and descriptor and calls `wgpu.DeviceCreateShaderModule`.

Things to look up in `Odin/vendor/wgpu/wgpu.odin` (search for the type names):
- `ShaderModuleDescriptor`
- `ShaderSourceWGSL`
- `DeviceCreateShaderModule`

<details>
<summary>Spoiler</summary>

```odin
create_shader_module :: proc(device: wgpu.Device, label, source: string) -> wgpu.ShaderModule {
	wgsl := wgpu.ShaderSourceWGSL {
		sType = .ShaderSourceWGSL,
		code  = source,
	}
	return wgpu.DeviceCreateShaderModule(device, &{label = label, nextInChain = &wgsl.chain})
}
```
`wgsl` lives on the stack, but that's fine: wgpu copies what it needs before
`DeviceCreateShaderModule` returns.
</details>

**Checkpoint:** `odin build .` compiles (an unused proc is fine).

---

## Step 3: Build the render pipeline

### Concepts: going through `RenderPipelineDescriptor` field by field

Open `RenderPipelineDescriptor` in `wgpu.odin` and follow along.

**`layout`**: a `PipelineLayout` describing the bind groups. Pass `nil` to get an **auto
layout**, where wgpu infers it from the shader. You have no bindings yet, so `nil` is perfect.
You'll build explicit layouts in Stage 3.

**`vertex: VertexState`**
- `module`: your shader module
- `entryPoint`: `"vs_main"`
- `buffers` / `bufferCount`: vertex buffer layouts. **None yet**, so leave them zero.

**`primitive: PrimitiveState`**
- `topology = .TriangleList`: every 3 vertices form an independent triangle
- `frontFace = .CCW`: triangles that appear counter-clockwise on screen count as front-facing
- `cullMode = .None` for now. In Stage 4 you'll switch to `.Back` to skip back faces. With your
  CCW corners the triangle will survive that switch. If your corners were clockwise, it would
  disappear, which is a classic "where did my mesh go?" bug.

**`multisample: MultisampleState`**
- `count = 1` (no MSAA), `mask = ~u32(0)` (all samples enabled)

**`fragment: ^FragmentState`** (a **pointer**: you can omit it for depth-only passes)
- `module`, `entryPoint = "fs_main"`
- `targets`: one `ColorTargetState` per color attachment in the render pass. Its `format`
  **must match the attachment's texture format**, which is `gpu.config.format` (the surface format).
- `blend = nil`: no blending, just overwrite. Transparency comes in Stage 14.
- `writeMask = wgpu.ColorWriteMaskFlags_All`

**`depthStencil = nil`**: no depth buffer until Stage 4.

### ⚠️ The big Odin + wgpu gotcha: zero values

Odin zero-initializes everything, but **zero often means `Undefined` in webgpu.h, not a
sensible default**:

| Field | Zero value | What happens |
|---|---|---|
| `primitive.topology` | `.Undefined` | validation error |
| `multisample.count` | `0` | validation error |
| `multisample.mask` | `0` | **every sample masked off, nothing draws** |
| `ColorTargetState.writeMask` | `{}` | **writes no color channels, nothing draws, no error!** |

The last two are nasty because they fail silently. If you ever see your clear color and no
triangle, check these first.

### Your task

Write `create_triangle_pipeline :: proc(gpu: ^Gpu_State) -> wgpu.RenderPipeline` that:
1. Creates the shader module with `#load`
2. Builds the descriptor and calls `wgpu.DeviceCreateRenderPipeline`
3. Releases the shader module afterwards (`wgpu.ShaderModuleRelease`). The pipeline keeps
   what it needs, so `defer` works nicely here.

For `[^]T` + count pairs (like `targets` / `targetCount`), point at a local variable and set the
count to 1. Odin lets you take the address of a compound literal inline:
`targets = &wgpu.ColorTargetState{ ... }`.

<details>
<summary>Spoiler</summary>

```odin
TRIANGLE_SHADER :: #load("shaders/triangle.wgsl", string)

create_triangle_pipeline :: proc(gpu: ^Gpu_State) -> wgpu.RenderPipeline {
	shader := create_shader_module(gpu.device, "triangle shader", TRIANGLE_SHADER)
	defer wgpu.ShaderModuleRelease(shader)

	return wgpu.DeviceCreateRenderPipeline(
		gpu.device,
		&{
			label = "triangle pipeline",
			vertex = {module = shader, entryPoint = "vs_main"},
			primitive = {topology = .TriangleList, frontFace = .CCW, cullMode = .None},
			multisample = {count = 1, mask = ~u32(0)},
			fragment = &{
				module = shader,
				entryPoint = "fs_main",
				targetCount = 1,
				targets = &wgpu.ColorTargetState {
					format    = gpu.config.format,
					writeMask = wgpu.ColorWriteMaskFlags_All,
				},
			},
		},
	)
}
```
</details>

**Checkpoint:** still compiles.

---

## Step 4: Own the pipeline in `Gpu_State`

### Your task
1. Add `triangle_pipeline: wgpu.RenderPipeline` to `Gpu_State` in `wgpu_init.odin`.
2. In `main`, after `wgpu_init` succeeds, call `create_triangle_pipeline(&gpu)` and store the result.
   (It needs `gpu.config.format`, so it has to come after the surface is configured.)
3. In `wgpu_shutdown`, release it with `wgpu.RenderPipelineRelease`. **Order matters:** release
   it *before* the device, following the same "children first" pattern as the existing code.

> 💭 **Design question to think about:** should pipeline creation live inside `wgpu_init`, or
> stay separate? A common split is that `wgpu_init` owns "talking to the GPU" (instance,
> device, surface) and a renderer layer owns "what we draw" (pipelines, buffers). You'll have
> many pipelines soon, so it's worth deciding now. Either way is fine for this stage.

**Checkpoint:** run with `odin run .`. You should see the same clear color with **no errors in
the terminal**. If the shader or pipeline is invalid, your `on_uncaptured_error` callback will
print a validation message here, usually with a line number in the WGSL.

---

## Step 5: Draw

### Concepts
Inside a render pass, between `BeginRenderPass` and `RenderPassEncoderEnd`:

```odin
wgpu.RenderPassEncoderSetPipeline(pass, pipeline)
wgpu.RenderPassEncoderDraw(pass, vertexCount, instanceCount, firstVertex, firstInstance)
```

- `vertexCount = 3`: runs `vs_main` with `vertex_index` 0, 1 and 2
- `instanceCount = 1`: **not 0**. Zero instances means nothing draws, and that's another silent failure.
- `firstVertex = 0`, `firstInstance = 0`

### Your task
Add these two calls to `render_frame` in `main.odin`, between `CommandEncoderBeginRenderPass`
and `RenderPassEncoderEnd`.

**Checkpoint:** 🎉 a red/green/blue triangle on your blue-grey background. Resize the window and
notice that the triangle **stretches**. That's because clip space is always -1..1 whatever the
aspect ratio. The projection matrix in Stage 3 fixes this.

> 🎨 **Why does everything look lighter than the numbers say?** Your background `{0.1, 0.2, 0.3}`
> probably looks like a pale grey-blue, not a dark navy. On macOS `caps.formats[0]` is usually
> an **sRGB** format (`.BGRA8UnormSrgb`). wgpu treats your shader output and clear color as
> *linear* light and gamma-encodes them on write, which brightens dark values. This is the
> *correct* setup for lighting math later (Stages 12–15), so keep it. Just know that color
> values you pick by eye from a color picker are sRGB and need converting
> (roughly `pow(c, 2.2)`) to look the same. Try `fmt.println(gpu.config.format)` to confirm.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Validation error mentioning `topology` / `count` | Zero-valued `PrimitiveState` or `MultisampleState` fields |
| Error about the color target format | `ColorTargetState.format` ≠ `gpu.config.format` |
| Clear color shows, no triangle, **no error** | `writeMask` is `{}`, `mask = 0`, or `instanceCount = 0` |
| WGSL parse error | Read the line:column in the message. Missing `;`, or `let` used for an array you index dynamically |
| `#load` compile error | Path is relative to the `.odin` file, so check the `shaders/` folder location |
| Triangle disappears once you enable culling later | Your vertices are clockwise; swap two of them |

---

## Exercises (do at least two)

1. **Fullscreen triangle.** Change the positions to `(-1,-1)`, `(3,-1)`, `(-1,3)`. One oversized
   triangle covers the whole screen and the GPU clips the excess. This is *the* standard trick
   for post-processing and sky passes, and you'll use it in Stage 15.
2. **Pixel-coordinate colors.** In `fs_main`, `in.clip_position.xy` holds the **pixel
   coordinates** of the fragment (the position builtin gets transformed between stages). Make a
   checkerboard with `(floor(x / 32) + floor(y / 32)) % 2`.
3. **Animate it.** You can't pass time yet without uniforms. Look up what a `@group(0)
   @binding(0) var<uniform>` would need. That's the bridge to Stage 3.
4. **Draw two triangles** with `vertexCount = 6` and six entries in each array. Make them share
   an edge to form a quad. Notice that two vertices are duplicated. That waste is the
   motivation for index buffers in Stage 2.
5. **Break it on purpose.** Set `writeMask = {}`, then `cullMode = .Back` with clockwise
   vertices, then mismatch the target format. Learn what each failure looks like now, so you
   recognize it later.

---

## Recap: what you should be able to explain
- [ ] Why wgpu bundles state into an immutable pipeline object
- [ ] What `@builtin(position)` and `@location(n)` mean on vertex outputs vs. fragment outputs
- [ ] Why values like color get interpolated across the triangle
- [ ] WebGPU clip-space ranges (and how z differs from OpenGL)
- [ ] What `nextInChain` is for
- [ ] Which zero values in the descriptors silently break rendering

Next up: **Stage 2, vertex & index buffers**, where the positions move out of the shader
and into GPU memory you control from Odin.
