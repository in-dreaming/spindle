pub const Level = enum { low, normal, high };
pub const Error = error{Unsupported};
/// Priority changes must be verified by the target OS; unsupported targets never report success.
pub fn setCurrent(_: Level) Error!void {
    return error.Unsupported;
}
