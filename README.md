# LoggerJSON

[![Build Status](https://travis-ci.org/Nebo15/logger_json.svg?branch=master)](https://travis-ci.org/Nebo15/logger_json)
[![Coverage Status](https://coveralls.io/repos/github/Nebo15/logger_json/badge.svg?branch=master)](https://coveralls.io/github/Nebo15/logger_json?branch=master)
[![Module Version](https://img.shields.io/hexpm/v/logger_json.svg)](https://hex.pm/packages/logger_json)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/logger_json/)
[![Hex Download Total](https://img.shields.io/hexpm/dt/logger_json.svg)](https://hex.pm/packages/logger_json)
[![License](https://img.shields.io/hexpm/l/logger_json.svg)](https://github.com/Nebo15/logger_json/blob/master/LICENSE)
[![Last Updated](https://img.shields.io/github/last-commit/Nebo15/logger_json.svg)](https://github.com/Nebo15/logger_json/commits/master)
[![Static Analysis Status](https://app.sourcelevel.io/github/Nebo15/-/logger_json.svg)](https://app.sourcelevel.io/github/Nebo15/-/logger_json)

JSON console back-end for Elixir Logger.

It can be used as drop-in replacement for default `:console` Logger back-end in cases where you use
use Google Cloud Logger or other JSON-based log collectors.

Minimum supported Erlang/OTP version is 20.

## Motivation

[We](https://github.com/Nebo15) deploy our applications as dockerized containers in Google Container Engine (Kubernetes cluster), in this case all your logs will go to `stdout` and log solution on top of Kubernetes should collect and persist it elsewhere.

In GKE it is persisted in Google Cloud Logger, but traditional single Logger output may contain newlines for a single log line, and GCL counts each new line as separate log entry, this making it hard to search over it.

This backend makes sure that there is only one line per log record and adds additional integration niceness, like [LogEntry](https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry) format support.

After adding this back-end you may also be interested in [redirecting otp and sasl reports to Logger](https://hexdocs.pm/logger/Logger.html#error-logger-configuration) (see "Error Logger configuration" section).

## Log Format

LoggerJSON provides two JSON formatters out of the box (see below for implementing your own custom formatter).

The `LoggerJSON.Formatters.BasicLogger` formatter provides a generic JSON formatted message with no vendor specific entries in the payload. A sample log entry from `LoggerJSON.Formatters.BasicLogger` looks like the following:

```json
{
  "time": "2020-04-02T11:59:06.710Z",
  "severity": "debug",
  "message": "hello",
  "metadata": {
    "user_id": 13
  }
}
```

The other formatter that comes with LoggerJSON is `LoggerJSON.Formatters.GoogleCloudLogger` and generates JSON that is compatible with the
[Google Cloud Logger LogEntry](https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry) format:

  ```json
  {
    "message":"hello",
    "logging.googleapis.com/sourceLocation":{
      "file":"/os/logger_json/test/unit/logger_json_test.exs",
      "function":"Elixir.LoggerJSONGoogleTest.test metadata can be configured/1",
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
      "requestPath":"/",
      "requestUrl":"http://10.16.0.70/",
      "status":200,
      "userAgent":"kube-probe/1.10+"
    },
    "insertId":"1g64u74fgmqqft",
    "jsonPayload":{
      "message":"",
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

  1. Add `:logger_json` to your list of dependencies in `mix.exs`:

  ```ex
  def deps do
    [{:logger_json, "~> 4.2"}]
  end
  ```

  2. Set configuration in your `config/config.exs`:

  ```ex
  config :logger_json, :backend,
    metadata: :all
  ```

  Some integrations (for eg. Plug) uses `metadata` to log request
  and response parameters. You can reduce log size by replacing `:all`
  (which means log all) with a list of the ones that you actually need.

  3. Replace default Logger `:console` back-end with `LoggerJSON`:

  ```ex
  config :logger,
    backends: [LoggerJSON]
  ```

  4. Optionally. Log requests and responses by replacing a `Plug.Logger` in your endpoint with a:

  ```ex
  plug LoggerJSON.Plug
  ```

  5. Optionally. Use Ecto telemetry for additional metadata:

  Attach telemetry handler for Ecto events in `start/2` function in `application.ex`

  ```ex
  :ok =
    :telemetry.attach(
      "logger-json-ecto",
      [:my_app, :repo, :query],
      &LoggerJSON.Ecto.telemetry_logging_handler/4,
      :debug
    )
  ```

  Prevent duplicate logging of events, by setting `log` configuration option to `false`

  ```ex
  config :my_app, MyApp.Repo,
    adapter: Ecto.Adapters.Postgres,
    log: false
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

## Copyright and License

Copyright (c) 2016 Nebo #15

Released under the MIT License, which can be found in [LICENSE.md](./LICENSE.md).
