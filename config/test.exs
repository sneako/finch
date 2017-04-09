use Mix.Config

# Configuration for tests

config :logger,
  backends: [LoggerJSON]

config :logger_json,
  backend: [json_encoder: Poison]
