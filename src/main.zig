const r4os = @import("r4os");

comptime {
    asm (r4os.r4dev.driverEntriesAsm("virtgpu_init", "virtgpu_shutdown"));
}

export fn virtgpu_init(api: *const r4os.r4dev.DriverApi) callconv(.c) i32 {
    const ctx = r4os.r4dev.DriverContext.init(api);
    if (!ctx.apiCompatible()) return -1;
    ctx.logInfo("VIRTGPU.R4D development: hardware path not yet enabled");
    return -2;
}

export fn virtgpu_shutdown() callconv(.c) i32 {
    return 0;
}
