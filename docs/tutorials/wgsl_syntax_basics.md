# WGSL Syntax Basics

**Goal:** be able to read and write the WGSL you'll need for the next several stages without
having to look up every keyword.

**You'll learn:**
- How WGSL declares values (`const`, `let`, `var`, `override`) and why there are four
- Scalars, vectors, matrices, arrays and structs, including swizzling
- How WGSL's strict typing works, and the "abstract" literal types that make it bearable
- Control flow, functions and pointers
- Attributes (`@vertex`, `@location`, `@builtin`, `@group`/`@binding`) and how shader inputs/outputs wire up
- Address spaces (`function`, `private`, `workgroup`, `uniform`, `storage`)

This is a syntax tour. It isn't tied to the renderer, and the examples aren't shaped like
your project. Each section ends with a short **exercise**. Answers are in collapsible
**Spoiler** blocks. Try each exercise before you open its answer.

> **Version note.** Everything here was checked with `naga` 29.0.4, the shader compiler
> inside wgpu-native v29 (your vendored bindings are `29.0.1.1`). Where naga differs from the
> [WGSL spec](https://www.w3.org/TR/WGSL/), the difference is called out.
>
> **How to check your own snippets:** `cargo install naga-cli`, then `naga file.wgsl`. It
> prints `Validation successful` or an error pointing at the exact span. That is much faster
> than rebuilding the app.

---

## 1. The shape of a WGSL file

A WGSL module is a flat list of **module-scope declarations**: structs, constants,
global variables, aliases and functions. There are no includes, no preprocessor and no
`main`. Instead, any function marked `@vertex`, `@fragment` or `@compute` is an
**entry point**, and the host (your Odin code) picks one by name when it builds a pipeline.

```wgsl
// A comment.  /* Block comments nest, too. */

const SCALE: f32 = 2.0;          // compile-time constant

struct Pair {                    // a struct
    a: f32,
    b: f32,                      // trailing comma allowed
}

fn sum(p: Pair) -> f32 {         // a plain helper function
    return (p.a + p.b) * SCALE;
}

@fragment                        // an entry point
fn paint() -> @location(0) vec4f {
    return vec4f(1.0, 0.0, 1.0, 1.0);
}
```

Things that look familiar from Odin:

| Odin                     | WGSL                          |
|--------------------------|-------------------------------|
| `x: f32 = 1`             | `var x: f32 = 1.0;`           |
| `X :: 3.14`              | `const X = 3.14;`             |
| `proc(a: f32) -> f32`    | `fn name(a: f32) -> f32`      |
| `Foo :: struct { a: f32 }` | `struct Foo { a: f32, }`    |
| `[4]f32`                 | `array<f32, 4>`               |
| `[3]f32` (as a vector)   | `vec3<f32>` / `vec3f`         |
| `matrix[4,4]f32`         | `mat4x4<f32>` / `mat4x4f`     |
| `Alias :: f32`           | `alias Alias = f32;`          |

Differences that bite: **every statement ends in `;`**, **struct members are separated by
`,`**, and **braces are mandatory** on `if`/`for`/`while` bodies. You can't write
`if x return;`. Parentheses around conditions are optional: `if (a)` and `if a` are both fine.

Declaration order doesn't matter at module scope, so a function can call one defined
further down the file.

---

## 2. The four ways to name a value

This is the first thing that feels odd. WGSL has four declaration keywords, and each one
answers a different question: *when* is the value known, and can it change?

| Keyword    | Known at…                | Mutable? | Where allowed           | Typical use                         |
|------------|--------------------------|----------|-------------------------|-------------------------------------|
| `const`    | shader compile time      | no       | module or function      | math constants, array sizes         |
| `override` | pipeline creation time   | no       | module only             | tunables set from the host          |
| `let`      | runtime (once)           | no       | function only           | most local values                   |
| `var`      | runtime                  | **yes**  | function or module      | accumulators, loop counters, globals |

```wgsl
const MAX_LIGHTS = 8;                 // type inferred
const GAMMA: f32 = 2.2;               // or spelled out
override quality: u32 = 2u;           // host can change this when it builds the pipeline

fn demo(x: f32) -> f32 {
    let half = x * 0.5;               // immutable, computed at runtime
    var total = 0.0;                  // mutable
    total += half;
    return total;
}
```

Notes:
- `let` **cannot** appear at module scope. naga's error lists exactly what can:
  `struct`, `const`, `var`, `alias`, `fn`, `diagnostic`, `enable`, `requires`. (`override` is
  missing from that list but is accepted.)
- Assigning to a `let` is an error ("invalid left-hand side of assignment").
- Prefer `let` by default and reach for `var` only when you need mutation. A `let` is just a
  name for a value. A `var` is a piece of memory, and you can take its address (§7).
- `override` is the shader-side half of pipeline constants. The host supplies values in the
  pipeline descriptor's `constants` field. Use it for things like a workgroup size or a
  quality level, so you don't need a separate shader per setting.

Function parameters behave like `let`: you cannot assign to them.

### Exercise 2

Which of these lines are errors, and why?

```wgsl
let A = 1;                       // (a) module scope

fn f(n: i32) -> i32 {
    const B = n * 2;             // (b)
    let c = n + 1;
    c = c + 1;                   // (c)
    n = 0;                       // (d)
    var d: i32;                  // (e)
    return d;
}
```

<details>
<summary><b>Spoiler</b></summary>

- **(a)** error: `let` is not allowed at module scope. Use `const`.
- **(b)** error: `const` must be computable at compile time, and `n` is a runtime value. Use `let`.
- **(c)** error: `c` is a `let`.
- **(d)** error: parameters are immutable. Copy the value into a `var` first.
- **(e)** fine. A `var` with a type but no initializer is **zero-initialized**, so this returns `0`.
  (WGSL has no uninitialized memory. That is a safety guarantee of WebGPU.)

</details>

---

## 3. Scalars and the strict type system

### Scalar types

| Type   | Meaning                         | Literal examples        |
|--------|---------------------------------|-------------------------|
| `bool` | true / false                    | `true`, `false`         |
| `i32`  | 32-bit signed int               | `1`, `1i`, `-7`, `0x1F` |
| `u32`  | 32-bit unsigned int             | `1u`, `0xFFu`           |
| `f32`  | 32-bit float                    | `1.0`, `1f`, `.5`, `1e3` |
| `f16`  | 16-bit float (needs `enable f16;` + device feature) | `1h` |

There is no `i64`, `f64`, `u8` or `char` in core WGSL. GPUs are 32-bit machines at heart.

### No implicit conversions between concrete types

WGSL **never** silently converts `i32` ↔ `u32` ↔ `f32`. This is the most common source of
compile errors when you're starting out:

```wgsl
fn bad() -> u32 {
    let a = 1;          // i32
    let b = 2u;         // u32
    return a + b;       // ERROR: i32 + u32
}
```

Convert explicitly with a *value constructor*, which uses the type name like a function:

```wgsl
let i = 7;
let u = u32(i);          // numeric conversion
let f = f32(u) / 2.0;    // 3.5
let bits = bitcast<u32>(f);  // reinterpret the bits, no conversion
```

`f32(x)` converts the *value* (7 → 7.0). `bitcast<T>(x)` keeps the *bits* and changes how
they're interpreted, which is useful later for packing data into integers.

### Abstract literals: why `let x: f32 = 1;` works

If nothing converts implicitly, why does this compile?

```wgsl
let x: f32 = 1;          // OK
let v = vec3f(0, 0, 1);  // OK
```

A bare literal like `1` or `1.0` starts out with an **abstract** type (`AbstractInt` /
`AbstractFloat`). Think of it as "a number that hasn't picked a type yet". It adopts
whatever concrete type the context asks for. Only when there is **no** context does it
fall back to a default: `1` → `i32`, `1.0` → `f32`.

The catch is that once a value is bound to a `let`, it's concrete:

```wgsl
let x: f32 = 1.0;
let i = 2;               // i is now a concrete i32
let y = x * i;           // ERROR: f32 * i32
let z = x * 2;           // OK: the literal 2 is still abstract
```

> **naga quirk.** Builtin calls whose arguments are *all* literals can fail in naga 29,
> e.g. `smoothstep(0.0, 1.0, 0.3)` reports *"failed to convert expression to a concrete
> type"*, although the spec allows it. As soon as one argument is a runtime value, it's fine.
> You'll rarely hit this in real code.

### Operators

Mostly what you'd expect from C or Odin: `+ - * / %`, comparisons, `&& || !`, bitwise
`& | ^ ~ << >>`, and compound assignment `+= -= *=` and so on.

Two differences:
- **No ternary `?:`.** Use `select(if_false, if_true, condition)`. Note the argument order:
  false comes **first**. Both arguments are evaluated.
- **`i++` and `i--` are statements, not expressions.** `i++;` is fine. `let j = i++;` is an error.

`if` and `while` conditions must be an actual `bool`. `if x` with a float or int `x` is an
error, so write `if x != 0.0`.

### Exercise 3

Fix each line by changing as little as possible:

```wgsl
let count: u32 = 10u;
let half = count / 2.0;              // (a) want a float result
let idx: i32 = 3;
let offset = count + idx;            // (b) want a u32 result
let sign = x > 0.0 ? 1.0 : -1.0;     // (c)
```

<details>
<summary><b>Spoiler</b></summary>

- (a) `let half = f32(count) / 2.0;`
- (b) `let offset = count + u32(idx);`
- (c) `let sign = select(-1.0, 1.0, x > 0.0);` (or the builtin `sign(x)`, which also returns 0 for 0)

</details>

---

## 4. Vectors and swizzling

Vectors are first-class types, and you'll use them constantly.

```wgsl
let a = vec3<f32>(1.0, 2.0, 3.0);   // long form
let b = vec3f(1.0, 2.0, 3.0);       // predeclared alias, same type
let c = vec3f(0.5);                 // "splat": (0.5, 0.5, 0.5)
let d = vec4f(b, 1.0);              // extend: (1, 2, 3, 1)
let e = vec4f(a.xy, 0.0, 1.0);      // mix-and-match pieces
let iv = vec2i(3, 4);               // i32 vector
let uv = vec2u(iv);                 // component-wise conversion
```

Alias cheat sheet: `vec2f vec3f vec4f` (f32), `vec2i …` (i32), `vec2u …` (u32), `vec2h …`
(f16). There is no `vec3b`, so for bools write `vec3<bool>`.

### Swizzles

Read components by name, in any order, with repeats allowed:

```wgsl
let p = vec4f(1.0, 2.0, 3.0, 4.0);
p.x          // 1.0
p.zyx        // vec3f(3, 2, 1)
p.xxyy       // vec4f(1, 1, 2, 2)
p.rgb        // same as p.xyz. rgba is an alias for xyzw.
p[2]         // 3.0, indexing also works
```

You can't mix the two sets (`p.xg` is an error).

**Writing** is more limited: you can assign one component (`v.x = 5.0;` or `v[1] = 2.0;`),
but **swizzle assignment is not allowed** (`v.xy = …` gives *"invalid left-hand side of
assignment"*). Rebuild the vector instead: `v = vec3f(new_xy, v.z);`.

### Arithmetic is component-wise

```wgsl
let s = vec3f(1.0, 2.0, 3.0) * vec3f(2.0);   // (2, 4, 6)
let t = vec3f(1.0, 2.0, 3.0) * 2.0;          // scalar broadcast: same result
let lt = vec3f(1.0) < vec3f(0.0, 2.0, 1.0);  // vec3<bool>(false, true, false)
```

Scalar broadcast only works for **arithmetic**. Comparisons (`== != < <= > >=`) need both
sides to be the same type, so `v == 1.0` is an error. Splat the scalar first:
`v == vec3f(1.0)`.

Use `any()` and `all()` to collapse a bool vector.
@js: if I need to see if vec A is the same as vec B, I would do: `all(A == B)`
     `any()` returns true if all components are true

### Exercise 4

Given `let c = vec4f(0.2, 0.4, 0.6, 1.0);`, write expressions for:
1. the color with red and blue swapped, alpha kept
2. a `vec3f` grayscale value where every channel is the average of r, g, b
3. a `vec2u` holding `c.r` and `c.g` scaled to 0–255

<details>
<summary><b>Spoiler</b></summary>

1. `c.bgra`
2. `vec3f((c.r + c.g + c.b) / 3.0)` (splat), or `vec3f(dot(c.rgb, vec3f(1.0 / 3.0)))`
3. `vec2u(c.rg * 255.0)`. Converting float → uint truncates.

</details>

---

## 5. Matrices, arrays and structs

### Matrices

`matCxR<T>` means **C columns, R rows**. The aliases are `mat4x4f`, `mat3x3f`, `mat2x2f` and so on.
Matrices are **column-major**, both in memory and when you index them:

```wgsl
let m = mat2x2f(1.0, 2.0,      // column 0 = (1, 2)
                3.0, 4.0);     // column 1 = (3, 4)

let col1 = m[1];               // vec2f(3, 4), indexing gives a COLUMN
let elem = m[1][0];            // 3.0, column 1, row 0

let identity = mat4x4f(
    vec4f(1.0, 0.0, 0.0, 0.0),  // or build from column vectors
    vec4f(0.0, 1.0, 0.0, 0.0),
    vec4f(0.0, 0.0, 1.0, 0.0),
    vec4f(0.0, 0.0, 0.0, 1.0),
);
let p = identity * vec4f(1.0, 2.0, 3.0, 1.0);  // matrix × column-vector
```

`M * v` treats `v` as a column vector, which is the convention in most graphics math
texts. `M1 * M2 * v` applies `M2` first. Odin's `matrix[4,4]f32` is also column-major in
memory, so the bytes you upload line up (this matters in Stage 3).

Matrices only hold floats: there is no `mat4x4i`.

### Arrays

```wgsl
var a = array<f32, 4>(1.0, 2.0, 3.0, 4.0);  // fixed size
let b = array(1, 2, 3);                      // element type and count inferred
a[0] = 10.0;
var zeros: array<vec3f, 16>;                 // zero-initialized
```

- The size must be a `const` or `override` expression, never a runtime value.
- A **runtime-sized array** (`array<T>` without a count) may only appear as the *last member
  of a struct in a storage buffer*. Its length is whatever buffer you bind, and you query it
  with `arrayLength(&buf.items)`.
- Dynamic indexing (`a[i]` with a runtime `i`) is allowed. Out-of-bounds access does not
  crash. WebGPU guarantees it's clamped or otherwise contained, but the result is garbage, so
  don't rely on it.

### Structs

```wgsl
struct Material {
    albedo: vec3f,
    roughness: f32,
}

fn make() -> Material {
    var m = Material(vec3f(0.8), 0.5);  // positional constructor, all fields
    m.roughness = 0.9;
    var blank: Material;                // all fields zero
    return m;
}
```

There are no designated initializers (`Material{roughness = …}`), no methods and no
generics. Struct values are copied when assigned or passed. There are no references unless
you use a pointer.

> **Layout warning, for later.** When a struct lives in a uniform or storage buffer, WGSL
> imposes alignment rules: `vec3f` aligns to **16 bytes** even though it is 12 bytes in size.
> Your Odin struct has to match byte-for-byte. The learning path covers this in Stage 3.
> For now, just know that in-shader structs and buffer structs aren't automatically
> laid out the way Odin would lay them out.

### Exercise 5

A `mat3x3f` named `r` holds a rotation. What do `r[2]` and `r[0][2]` give you?
Is `r * v` the same as `v * r`?

<details>
<summary><b>Spoiler</b></summary>

- `r[2]` is the **third column** (a `vec3f`). For a rotation matrix, that's where the local
  Z axis ends up.
- `r[0][2]` is column 0, row 2: the z component of the first column.
- No. `v * r` treats `v` as a *row* vector, which equals `transpose(r) * v`. For a rotation
  that's the *inverse* rotation. Both are legal WGSL, which is why this bug is easy to write.

</details>

---

## 6. Control flow

```wgsl
fn flow(n: i32) -> i32 {
    var sum = 0;

    if n < 0 {
        return -1;
    } else if n == 0 {
        return 0;
    } else {
        sum = 1;
    }

    for (var i = 0; i < n; i++) {     // C-style, parentheses required here
        if i == 2 { continue; }
        sum += i;
    }

    var j = 0;
    while j < 3 {                      // no parentheses needed
        j += 1;
    }

    loop {                             // infinite loop, exit with break
        j -= 1;
        if j == 0 { break; }
        continuing {                   // runs at the end of every iteration
            sum += 1;
            break if sum > 100;        // only legal as the last statement in `continuing`
        }
    }

    switch n {                         // selector must be i32 or u32
        case 1, 2: { sum *= 2; }       // multiple values per case
        case 3, default: { sum = 0; }  // `default` can share a case
    }                                  // no fallthrough, no `break` needed

    return sum + select(10, 20, n > 5);
}
```

- `for` is sugar for `loop` + `continuing`. You'll mostly use `for` and `while`.
- `switch` must have a `default`, and cases never fall through.
- `discard;` exists **only in fragment shaders**. It throws away the current fragment, so
  nothing is written to the color or depth target. It's handy later for alpha-tested leaves.

**A GPU-specific aside:** branches are legal and often fine, but neighboring invocations run
in lockstep groups. If they take different sides of an `if`, the group executes *both* sides
with some lanes masked off. That's why shader code often prefers `select`, `mix`, `step` and
the like for small decisions. This is a performance concern, not a correctness one.

### Exercise 6

Write a function `count_bits(x: u32) -> u32` that counts set bits with a loop.
(There is also a builtin for this. Do you know its name?)

<details>
<summary><b>Spoiler</b></summary>

```wgsl
fn count_bits(x: u32) -> u32 {
    var v = x;          // parameters are immutable, so copy
    var n = 0u;
    while v != 0u {
        n += v & 1u;
        v >>= 1u;
    }
    return n;
}
```

The builtin is `countOneBits(x)`.

</details>

---

## 7. Functions and pointers

```wgsl
fn lerp3(a: vec3f, b: vec3f, t: f32) -> vec3f {
    return a + (b - a) * t;     // (or just use the builtin mix)
}

fn reset(x: f32) {             // no `-> T` means it returns nothing
    // ...
}
```

Rules worth knowing:
- **No recursion**, direct or indirect. naga reports *"declaration of `f` is recursive"*.
  GPUs have no real call stack, so every call is inlined.
- **No overloading** and **no default arguments**. Builtins are overloaded, but your own
  functions can't be.
- Arguments are passed **by value**. To let a function modify the caller's variable, pass a
  pointer.

### Pointers

```wgsl
fn bump(p: ptr<function, i32>) {
    *p += 1;                     // dereference with *
}

fn caller() -> i32 {
    var x = 1;                   // must be a var, since a let has no address
    bump(&x);                    // take address with &
    let p = &x;
    *p = *p + 1;
    return x;                    // 3
}
```

The `ptr<…>` type includes an **address space** (`function` here, see §9). Pointers can't
be stored in structs or arrays, can't do arithmetic, and can't be null. They exist to
pass "this variable" around, nothing more. You can also use `p.field` or `p[i]` directly
on a pointer to a struct or array, with no `(*p).field` needed.

---

## 8. Attributes and entry points

Attributes are the `@name` or `@name(args)` annotations. They're how WGSL talks to the
**pipeline**: which functions are entry points, and how data flows in and out of them.

### Entry-point stage

```wgsl
@vertex   fn v() -> @builtin(position) vec4f { … }
@fragment fn f() -> @location(0) vec4f { … }
@compute @workgroup_size(64) fn c() { … }
```

### `@location(n)` vs `@builtin(name)`

There are two kinds of stage input and output:

```
          host vertex buffers                            color attachments
                 │                                              ▲
         @location(0..)                                  @location(0..)
                 ▼                                              │
           ┌──────────┐   @location(n) ── interpolated ──► ┌──────────┐
           │  vertex  │                                     │ fragment │
           │  shader  │   @builtin(position) ─ rasterizer ─►│  shader  │
           └──────────┘                                     └──────────┘
                 ▲                                              ▲
     @builtin(vertex_index),                      @builtin(position) (pixel coords),
     @builtin(instance_index)                     @builtin(front_facing), …
```

- **`@location(n)`** is a *user-defined* slot. You choose the numbers, and they have to match
  on both sides: vertex-buffer attributes ↔ vertex inputs, vertex outputs ↔ fragment inputs,
  and fragment outputs ↔ color attachments.
- **`@builtin(x)`** is a value the GPU provides or consumes. Common ones are `vertex_index`,
  `instance_index`, `position`, `front_facing`, `frag_depth`, `global_invocation_id` and
  `local_invocation_index`.

### Grouping inputs and outputs in a struct

Once a shader has more than one or two inputs or outputs, put them in a struct and annotate each member:

```wgsl
struct Varyings {
    @builtin(position) pos: vec4f,
    @location(0) uv: vec2f,
    @location(1) @interpolate(flat) id: u32,   // integers must be flat (see below)
}

@vertex
fn v(@builtin(vertex_index) i: u32) -> Varyings {
    var o: Varyings;
    o.pos = vec4f(f32(i & 1u), f32(i >> 1u), 0.0, 1.0);
    o.uv  = o.pos.xy;
    o.id  = i;
    return o;
}

@fragment
fn f(in: Varyings) -> @location(0) vec4f {
    return vec4f(in.uv, 0.0, 1.0);
}
```

The same struct can be the vertex output and the fragment input. Note one subtlety:
`@builtin(position)` means *clip-space position* when the vertex stage writes it, but
*framebuffer pixel coordinates* (x/y in pixels, plus depth) when the fragment stage reads
it. It's one name with two meanings, because the rasterizer sits between the two stages.

`@interpolate(flat)` turns off interpolation, so the fragment gets one vertex's value as-is.
The spec requires it on integer inputs and outputs. naga 29 doesn't enforce that and accepts
an integer `@location` without it, but other WebGPU compilers (e.g. Chrome's Tint) reject it,
so always write it. For voxels, this is how you'll pass a block or texture-layer ID
per face without it getting smeared between vertices.

### Resource bindings: `@group(g) @binding(b)`

```wgsl
@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var<storage, read> items: array<vec4f>;
@group(1) @binding(0) var atlas: texture_2d<f32>;
@group(1) @binding(1) var atlas_sampler: sampler;
```

The `(group, binding)` pair is the address the host uses to attach a buffer, texture or
sampler. It has to match your bind group layout on the Odin side. Textures and samplers are
declared without an address space.

### Exercise 8

A fragment shader needs to output to two color attachments: a color and a normal. How do
you declare its return type?

<details>
<summary><b>Spoiler</b></summary>

Return a struct whose members carry `@location(0)` and `@location(1)`:

```wgsl
struct GOut {
    @location(0) color: vec4f,
    @location(1) normal: vec4f,
}
@fragment fn f() -> GOut { … }
```

The pipeline's fragment state must list two color targets, in the same order.

</details>

---

## 9. Address spaces: where a `var` lives

Every `var` lives in an **address space**. It is written in angle brackets, or inferred from context:

| Address space | Declared as                              | Scope / lifetime                  | Who sees it                      | Writable from shader |
|---------------|------------------------------------------|-----------------------------------|----------------------------------|----------------------|
| `function`    | `var x` inside a function (default)      | one call                          | one invocation                   | yes |
| `private`     | `var<private> x` at module scope         | one invocation, whole shader run  | one invocation                   | yes |
| `workgroup`   | `var<workgroup> x` at module scope       | one compute workgroup             | all invocations in the workgroup | yes |
| `uniform`     | `@group @binding var<uniform> x`         | bound buffer                      | everyone                         | **no** |
| `storage`     | `@group @binding var<storage, read> x` or `<storage, read_write>` | bound buffer | everyone | if `read_write` |

Key ideas:
- **Uniform**: small, read-only and fast. Every invocation typically reads the same data, so
  it's good for camera matrices and time.
- **Storage**: large, can hold runtime-sized arrays, and can be written (`read_write`). It's
  good for big tables of chunk data, or compute shader output. Writes from many invocations at once
  need care (atomics, barriers).
- **Workgroup**: fast on-chip scratch memory shared by one compute workgroup. You
  coordinate access to it with `workgroupBarrier()`.
- **Private**: a "global" that is still per-invocation. It's rarely needed.

```wgsl
var<workgroup> tile: array<f32, 64>;

@compute @workgroup_size(64)
fn c(@builtin(local_invocation_index) li: u32) {
    tile[li] = f32(li);
    workgroupBarrier();               // wait until all 64 have written
    let neighbor = tile[63u - li];    // now safe to read others' slots
}
```

---

## 10. A handful of builtins you'll use constantly

| Category      | Functions |
|---------------|-----------|
| Vector math   | `dot`, `cross`, `length`, `distance`, `normalize`, `reflect` |
| Interpolation | `mix(a, b, t)`, `clamp(x, lo, hi)`, `step(edge, x)`, `smoothstep(lo, hi, x)`, `saturate(x)` |
| Rounding      | `floor`, `ceil`, `round`, `fract`, `trunc` |
| Misc          | `abs`, `min`, `max`, `sign`, `pow`, `sqrt`, `inverseSqrt`, `exp`, `log` |
| Trig          | `sin`, `cos`, `tan`, `atan2`, `radians`, `degrees` |
| Bool vectors  | `any`, `all`, `select` |
| Matrices      | `transpose`, `determinant` (there is **no** `inverse`, so compute it on the CPU) |
| Bits          | `countOneBits`, `firstLeadingBit`, `extractBits`, `insertBits`, `pack4x8unorm`, `unpack4x8unorm` |
| Textures      | `textureSample`, `textureLoad`, `textureDimensions` |

Almost all of them work component-wise on vectors (`floor(vec3f(…))` floors each
component). The full list with exact signatures is in the spec:
[§17 Built-in Functions](https://www.w3.org/TR/WGSL/#builtin-functions).

---

## Capstone exercise

Without looking back, write a module that has:
1. a `const` for a grid size of 8
2. a uniform struct holding a `time: f32` and a `tint: vec3f`
3. a vertex entry point that takes `vertex_index` and outputs a clip-space position plus a
   `flat` `u32` cell index (`vertex_index / 6u`)
4. a fragment entry point that colors the fragment using `tint`, darkened on every other
   cell (`cell % 2u`), pulsing with `sin(time)`

Then run it through `naga` and fix whatever it complains about. Don't worry about what
geometry the vertex shader produces. Any position is fine, since the point is the syntax.

<details>
<summary><b>Spoiler (one possible answer)</b></summary>

```wgsl
const GRID: u32 = 8u;

struct Globals {
    tint: vec3f,
    time: f32,          // placed after the vec3f, so it fills the padding slot (see Stage 3)
}

@group(0) @binding(0) var<uniform> g: Globals;

struct Varyings {
    @builtin(position) pos: vec4f,
    @location(0) @interpolate(flat) cell: u32,
}

@vertex
fn vs(@builtin(vertex_index) vi: u32) -> Varyings {
    var o: Varyings;
    let x = f32(vi % GRID) / f32(GRID);
    let y = f32(vi / GRID) / f32(GRID);
    o.pos = vec4f(x * 2.0 - 1.0, y * 2.0 - 1.0, 0.0, 1.0);
    o.cell = vi / 6u;
    return o;
}

@fragment
fn fs(in: Varyings) -> @location(0) vec4f {
    let checker = select(1.0, 0.5, in.cell % 2u == 1u);
    let pulse = 0.75 + 0.25 * sin(g.time);
    return vec4f(g.tint * checker * pulse, 1.0);
}
```

</details>

---

## Where to look things up

- **WGSL spec**: <https://www.w3.org/TR/WGSL/>. It's dense, but the builtin-function and
  type sections are good references.
- **Tour of WGSL** (Google): <https://google.github.io/tour-of-wgsl/>. It's interactive, with
  a small editable example per feature.
- **naga** (`naga file.wgsl`): the authority on what *your* wgpu-native version
  accepts. If the spec and naga disagree, naga wins for this project.
