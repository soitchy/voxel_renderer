struct VertexOutput {
    @builtin(position) clip_position: vec4f,
    @location(0) color: vec4f,
}

@vertex
fn vs_main(@builtin(vertex_index) idx: u32) -> VertexOutput {

}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {

}
