# A server configuration with defaults that applications can fill in.
let defaults = import "defaults.ncl" in
{
  server = {
    host | String | doc "Interface to listen on" | default = defaults.host,
    port | std.number.PosNat | default = 8080,
    environment | [| 'development, 'production |] | default = 'development,
  },
  features = import "features.json",
  banner = import "shared.ncl",
}
