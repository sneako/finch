# LoggerJSON

[![Deps Status](https://beta.hexfaktor.org/badge/all/github/Nebo15/logger_json.svg)](https://beta.hexfaktor.org/github/Nebo15/logger_json) [![Hex.pm Downloads](https://img.shields.io/hexpm/dw/logger_json.svg?maxAge=3600)](https://hex.pm/packages/logger_json) [![Latest Version](https://img.shields.io/hexpm/v/logger_json.svg?maxAge=3600)](https://hex.pm/packages/logger_json) [![License](https://img.shields.io/hexpm/l/logger_json.svg?maxAge=3600)](https://hex.pm/packages/logger_json) [![Build Status](https://travis-ci.org/Nebo15/logger_json.svg?branch=master)](https://travis-ci.org/Nebo15/logger_json) [![Coverage Status](https://coveralls.io/repos/github/Nebo15/logger_json/badge.svg?branch=master)](https://coveralls.io/github/Nebo15/logger_json?branch=master) [![Ebert](https://ebertapp.io/github/Nebo15/logger_json.svg)](https://ebertapp.io/github/Nebo15/logger_json)

JSON console back-end for Elixir Logger.

It can be used as drop-in replacement for default `:console` Logger back-end in cases where you use
use Google Cloud Logger or other JSON-based log collectors.

## Motivation

[We](https://github.com/Nebo15) deploy our applications as dockerized containers in Google Container Engine (Kubernetes cluster), in this case all your logs will go to `stdout` and log solution on top of Kubernetes should collect and persist it elsewhere.

In GKE it is persisted in Google Cloud Logger, but traditional single Logger output may contain newlines for a single log line, and GCL counts each new line as separate log entry, this making it hard to search over it.

This backend makes sure that there is only one line per log record and adds additional integration niceness, like [LogEntry](https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry) format support.

After adding this back-end you may also be interested in [redirecting otp and sasl reports to Logger](https://hexdocs.pm/logger/Logger.html#error-logger-configuration) (see "Error Logger configuration" section).

## Log Format

By-default, generated JSON is compatible with
[Google Cloud Logger LogEntry](https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry) format:

  ```json
  {
    "log":"hello",
    "logging.googleapis.com/sourceLocation":{
      "file":"/os/logger_json/test/unit/logger_json_test.exs",
      "function":"Elixir.LoggerJSONTest.test metadata can be configured/1",
      "line":71
    },
    "severity":"DEBUG",
    "time":"2018-10-19T01:10:49.582Z",
    "user_id":13
  }
  ```

  Log entry in Google Cloud Logger would looks something like this:


  ```json
  {
    "httpRequest":{
      "latency":"0.350s",
      "remoteIp":"::ffff:10.142.0.2",
      "requestMethod":"GET",
      "requestUrl":"http://10.16.0.70/",
      "status":200,
      "userAgent":"kube-probe/1.10+"
    },
    "insertId":"1g64u74fgmqqft",
    "jsonPayload":{
      "log":"",
      "phoenix":{
        "action":"index",
        "controller":"Elixir.MyApp.Web.PageController",
      },
      "request_id":"2lfbl1r3m81c40e5v40004c2",
      "vm":{
        "hostname":"myapp-web-66979fc-vbk4q",
        "pid":1,
      }
    },
    "logName":"projects/hammer-staging/logs/stdout",
    "metadata":{
      "systemLabels":{},
      "userLabels":{}
    },
    "operation":{
      "id":"2lfbl1r3m81c40e5v40004c2"
    },
    "receiveTimestamp":"2018-10-18T14:33:35.515253723Z",
    "resource":{},
    "severity":"INFO",
    "sourceLocation":{
      "file":"iex",
      "function":"Elixir.LoggerJSON.Plug.call/2",
      "line":"36"
    },
    "timestamp":"2018-10-18T14:33:33.263Z"
  }
  ```

You can change this structure by implementing `LoggerJSON.Formatter` behaviour and passing module
name to `:formatter` config option. Example module can be found in `LoggerJSON.Formatters.GoogleCloudLogger`.

```ex
config :logger_json, :backend,
  formatter: MyFormatterImplementation
```

## Installation

It's [available on Hex](https://hex.pm/packages/logger_json), the package can be installed as:

  1. Add `:logger_json` and `:jason` to your list of dependencies in `mix.exs`:

  ```ex
  def deps do
    [{:logger_json, "~> 3.0"}]
  end
  ```

  2. Ensure `logger_json` and `:jason` is started before your application:

  ```ex
  def application do
    [extra_applications: [:jason, :logger_json]]
  end
  ```

  3. Set configuration in your `config/config.exs`:

  ```ex
  config :logger_json, :backend,
    metadata: :all
  ```

  Some integrations (for eg. Plug) uses `metadata` to log request
  and response parameters. You can reduce log size by replacing `:all`
  (which means log all) with a list of the ones that you actually need.

  4. Replace default Logger `:console` back-end with `LoggerJSON`:

  ```ex
  config :logger,
    backends: [LoggerJSON]
  ```

  5. Optionally. Log requests and responses by replacing a `Plug.Logger` in your endpoint with a:

  ```ex
  plug LoggerJSON.Plug
  ```

  6. Optionally. Log Ecto queries via Plug:

  ```ex
  config :my_app, MyApp.Repo,
    adapter: Ecto.Adapters.Postgres,
    ...
    loggers: [{LoggerJSON.Ecto, :log, [:info]}]
  ```

## Dynamic configuration

For dynamically configuring the endpoint, such as loading data
from environment variables or configuration files, LoggerJSON provides
an `:on_init` option that allows developers to set a module, function
and list of arguments that is invoked when the endpoint starts.

```ex
config :logger_json, :backend,
  on_init: {YourApp.Logger, :load_from_system_env, []}
```

## Encoders support

You can replace default Jason encoder with other module that supports `encode_to_iodata!/1` function and
enconding fragments.

## Documentation

The docs can be found at [https://hexdocs.pm/logger_json](https://hexdocs.pm/logger_json)

## Thanks

Many source code has been taken from original Elixir Logger `:console` back-end source code, so I want to thank all it's authors and contributors.

Part of `LoggerJSON.Plug` module have origins from `plug_logger_json` by @bleacherreport,
originally licensed under Apache License 2.0. Part of `LoggerJSON.PlugTest` are from Elixir's Plug licensed under Apache 2.
