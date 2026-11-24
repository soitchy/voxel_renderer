package main

import "base:runtime"
import "core:fmt"
import "vendor:sdl3"
import "vendor:wgpu"
import "vendor:wgpu/sdl3glue"

Gpu_State :: struct {
	instance: wgpu.Instance,
	surface:  wgpu.Surface,
	adapter:  wgpu.Adapter,
	device:   wgpu.Device,
	queue:    wgpu.Queue,
	config:   wgpu.SurfaceConfiguration,
}

// Creates the wgpu instance, binds a surface to the SDL window, acquires an
// adapter + device, and configures the surface for presentation.
wgpu_init :: proc(window: ^sdl3.Window) -> (gpu: Gpu_State, ok: bool) {
	gpu.instance = wgpu.CreateInstance(nil)
	if gpu.instance == nil {
		fmt.eprintln("wgpu: failed to create instance")
		return
	}

	gpu.surface = sdl3glue.GetSurface(gpu.instance, window)
	if gpu.surface == nil {
		fmt.eprintln("wgpu: failed to create surface from SDL window")
		wgpu_shutdown(&gpu)
		return
	}

	gpu.adapter = request_adapter(gpu.instance, gpu.surface) or_else nil
	if gpu.adapter == nil {
		wgpu_shutdown(&gpu)
		return
	}

	gpu.device = request_device(gpu.instance, gpu.adapter) or_else nil
	if gpu.device == nil {
		wgpu_shutdown(&gpu)
		return
	}

	gpu.queue = wgpu.DeviceGetQueue(gpu.device)

	caps, status := wgpu.SurfaceGetCapabilities(gpu.surface, gpu.adapter)
	if status != .Success || caps.formatCount == 0 {
		fmt.eprintln("wgpu: failed to query surface capabilities")
		wgpu_shutdown(&gpu)
		return
	}
	defer wgpu.SurfaceCapabilitiesFreeMembers(caps)

	width, height: i32
	sdl3.GetWindowSizeInPixels(window, &width, &height)

	gpu.config = wgpu.SurfaceConfiguration {
		device      = gpu.device,
		format      = caps.formats[0],
		usage       = {.RenderAttachment},
		width       = u32(width),
		height      = u32(height),
		alphaMode   = caps.alphaModes[0] if caps.alphaModeCount > 0 else .Auto,
		presentMode = .Fifo, // Always supported; vsync.
	}
	wgpu.SurfaceConfigure(gpu.surface, &gpu.config)

	return gpu, true
}

// Reconfigures the surface after the window's pixel size changes.
wgpu_resize :: proc(gpu: ^Gpu_State, width, height: u32) {
	// A zero-sized surface is invalid (e.g. while minimized); keep the old config.
	if width == 0 || height == 0 {
		return
	}
	gpu.config.width = width
	gpu.config.height = height
	wgpu.SurfaceConfigure(gpu.surface, &gpu.config)
}

wgpu_shutdown :: proc(gpu: ^Gpu_State) {
	if gpu.surface != nil && gpu.device != nil {
		wgpu.SurfaceUnconfigure(gpu.surface)
	}
	if gpu.queue != nil {wgpu.QueueRelease(gpu.queue)}
	if gpu.device != nil {wgpu.DeviceRelease(gpu.device)}
	if gpu.adapter != nil {wgpu.AdapterRelease(gpu.adapter)}
	if gpu.surface != nil {wgpu.SurfaceRelease(gpu.surface)}
	if gpu.instance != nil {wgpu.InstanceRelease(gpu.instance)}
	gpu^ = {}
}

@(private = "file")
Adapter_Request :: struct {
	done:    bool,
	adapter: wgpu.Adapter,
}

@(private = "file")
request_adapter :: proc(instance: wgpu.Instance, surface: wgpu.Surface) -> (wgpu.Adapter, bool) {
	on_adapter :: proc "c" (
		status: wgpu.RequestAdapterStatus,
		adapter: wgpu.Adapter,
		message: string,
		userdata1, userdata2: rawptr,
	) {
		context = runtime.default_context()
		req := cast(^Adapter_Request)userdata1
		req.done = true
		if status != .Success || adapter == nil {
			fmt.eprintfln("wgpu: request adapter failed (%v): %s", status, message)
			return
		}
		req.adapter = adapter
	}

	req: Adapter_Request
	wgpu.InstanceRequestAdapter(
		instance,
		&{compatibleSurface = surface, powerPreference = .HighPerformance},
		{mode = .AllowProcessEvents, callback = on_adapter, userdata1 = &req},
	)
	// wgpu-native usually fires this synchronously; pump events just in case.
	for !req.done {
		wgpu.InstanceProcessEvents(instance)
	}
	return req.adapter, req.adapter != nil
}

@(private = "file")
Device_Request :: struct {
	done:   bool,
	device: wgpu.Device,
}

@(private = "file")
request_device :: proc(instance: wgpu.Instance, adapter: wgpu.Adapter) -> (wgpu.Device, bool) {
	on_device :: proc "c" (
		status: wgpu.RequestDeviceStatus,
		device: wgpu.Device,
		message: string,
		userdata1, userdata2: rawptr,
	) {
		context = runtime.default_context()
		req := cast(^Device_Request)userdata1
		req.done = true
		if status != .Success || device == nil {
			fmt.eprintfln("wgpu: request device failed (%v): %s", status, message)
			return
		}
		req.device = device
	}

	on_device_lost :: proc "c" (
		device: ^wgpu.Device,
		reason: wgpu.DeviceLostReason,
		message: string,
		userdata1, userdata2: rawptr,
	) {
		// Released devices report .Destroyed / .InstanceDropped during shutdown; that's expected.
		// if reason == .Destroyed || reason == .InstanceDropped {
		// 	return
		// }
		// @js is the above strictly true?
		context = runtime.default_context()
		if reason != nil {
			// Not at all sure what do if any reason actually shows.
			fmt.panicf("Oh shit you didn't handle on_device_lost: %v", reason)
		}
		fmt.eprintfln("wgpu: device lost (%v): %s", reason, message)
	}

	on_uncaptured_error :: proc "c" (
		device: ^wgpu.Device,
		type: wgpu.ErrorType,
		message: string,
		userdata1, userdata2: rawptr,
	) {
		context = runtime.default_context()
		fmt.eprintfln("wgpu: uncaptured error (%v): %s", type, message)
	}

	req: Device_Request
	wgpu.AdapterRequestDevice(
		adapter,
		&{
			label = "voxel_renderer device",
			deviceLostCallbackInfo = {mode = .AllowSpontaneos, callback = on_device_lost},
			uncapturedErrorCallbackInfo = {callback = on_uncaptured_error},
		},
		{mode = .AllowProcessEvents, callback = on_device, userdata1 = &req},
	)
	for !req.done {
		wgpu.InstanceProcessEvents(instance)
	}
	return req.device, req.device != nil
}

