package main
import "core:fmt"
import "vendor:sdl3"
import "vendor:wgpu"

main :: proc() {
	if !sdl3.Init({.VIDEO}) {
		return
	}
	defer sdl3.Quit()

	window := sdl3.CreateWindow("SDL3 Window", 800, 600, {.RESIZABLE, .HIGH_PIXEL_DENSITY, .METAL} when ODIN_OS == .Darwin else {.RESIZABLE, .HIGH_PIXEL_DENSITY})
	if window == nil {
		return
	}
	defer sdl3.DestroyWindow(window)

	gpu, ok := wgpu_init(window)
	if !ok {
		fmt.eprintln("failed to initialize wgpu")
		return
	}
	defer wgpu_shutdown(&gpu)

	running := true
	for running {
		event: sdl3.Event
		for sdl3.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				running = false
			case .KEY_DOWN:
				if event.key.key == sdl3.K_ESCAPE {
					running = false
				}
			case .WINDOW_PIXEL_SIZE_CHANGED:
				wgpu_resize(&gpu, u32(event.window.data1), u32(event.window.data2))
			}
		}
		render_frame(&gpu)
	}
}

render_frame :: proc(gpu: ^Gpu_State) {
	surface_texture := wgpu.SurfaceGetCurrentTexture(gpu.surface)
	switch surface_texture.status {
	case .SuccessOptimal, .SuccessSuboptimal:
	case .Timeout, .Outdated, .Lost:
		if surface_texture.texture != nil {
			wgpu.TextureRelease(surface_texture.texture)
		}
		wgpu.SurfaceConfigure(gpu.surface, &gpu.config)
		return
	case .OutOfMemory, .DeviceLost, .Error:
		fmt.panicf("wgpu: failed to acquire surface texture: %v", surface_texture.status)
	}
	defer wgpu.TextureRelease(surface_texture.texture)

	view := wgpu.TextureCreateView(surface_texture.texture, nil)
	defer wgpu.TextureViewRelease(view)

	encoder := wgpu.DeviceCreateCommandEncoder(gpu.device, nil)
	defer wgpu.CommandEncoderRelease(encoder)

	pass := wgpu.CommandEncoderBeginRenderPass(
		encoder,
		&{
			colorAttachmentCount = 1,
			colorAttachments = &wgpu.RenderPassColorAttachment {
				view       = view,
				depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
				loadOp     = .Clear,
				storeOp    = .Store,
				clearValue = {0.1, 0.2, 0.3, 1.0},
			},
		},
	)
	wgpu.RenderPassEncoderEnd(pass)
	wgpu.RenderPassEncoderRelease(pass)

	commands := wgpu.CommandEncoderFinish(encoder, nil)
	defer wgpu.CommandBufferRelease(commands)

	wgpu.QueueSubmit(gpu.queue, {commands})
	wgpu.SurfacePresent(gpu.surface)
}
