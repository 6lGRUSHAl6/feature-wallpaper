import Config

config :fw,
  state_file: "priv/fw.state.json",
  daemon_host: {127, 0, 0, 1},
  daemon_port: 47_788,
  renderer_binary: "priv/fw_renderer"

config :logger, level: :info