# Changelog

## v0.20.0 (2025-06-04)

### Enhancements

- Support manual pool termination #299
- Refactor HTTP1 pool state for better maintainability #308
- Add `:supported_groups` to list of TLS options #307
- Be more explicit about the `:default` pool in documentation #314
- Upgrade `nimble_options` to document deprecations #315

### Bug Fixes

- Fix Finch.stream_while/5 on halt for both HTTP/1 and HTTP/2 #320
- Return accumulator when Finch.stream/5 and Finch.stream_while/5 fail #295
- Fix documentation reference for get_pool_status/2 #301

### Other

- Upgrade CI VM to Ubuntu 24 #321
- CI housekeeping: support Elixir 1.17/Erlang OTP 27, bump Credo and deps #303
- Update GitHub CI badge URL #304

## v0.19.0 (2024-09-04)

### Enhancements

- Update @mint_tls_opts in pool_manager.ex #266
- Document there is no backpressure on HTTP2 #283
- Fix test: compare file size instead of map #284
- Finch.request/3: Use improper list and avoid Enum.reverse #286
- Require Mint 1.6 #287
- Remove castore dependency #274
- Fix typos and improve language in docs and comments #285
- fix logo size in README #275

### Bug Fixes

- Tweak Finch supervisor children startup order #289, fixes #277
- implement handle_cancelled/2 pool callback #268, fixes #257
- type Finch.request_opt() was missing the :request_timeout option #278

## v0.18.0 (2024-02-09)

### Enhancements

- Add Finch name to telemetry events #252

### Bug Fixes

- Fix several minor dialyzer errors and run dialyzer in CI #259, #261

## v0.17.0 (2024-01-07)

### Enhancements

- Add support for async requests #228, #231
- Add stream example to docs #230
- Fix calls to deprecated Logger.warn/2 #232
- Fix typos #233
- Docs: do not use streams with async_request #238
- Add Finch.stream_while/5 #239
- Set MIX_ENV=test on CI #241
- Update HTTP/2 pool log level to warning for retried action #240
- Split trailers from headers #242
- Introduce :request_timeout option #244
- Support ALPN over HTTP1 pools #250
- Deprecate :protocol in favour of :protocols #251
- Implement pool telemetry #248

## v0.16.0 (2023-04-13)

### Enhancements

- add `Finch.request!/3` #219
- allow usage with nimble_pool 1.0 #220

## v0.15.0 (2023-03-16)

### Enhancements

- allow usage with nimble_options 1.0 #218
- allow usage with castore 1.0 #210

## v0.14.0 (2022-11-30)

### Enhancements

- Improve error message for pool timeouts #126
- Relax nimble_options version to allow usage with 0.5.0 #204

## v0.13.0 (2022-07-26)

### Enhancements

- Define `Finch.child_spec/1` which will automatically use the `Finch` `:name` as the `:id`, allowing users to start multiple instances under the same Supervisor without any additional configuration #202
- Include the changelog in the generated HexDocs #201
- Fix typo in `Finch.Telemetry` docs #198

## v0.12.0 (2022-05-03)

### Enhancements

- Add support for private request metadata #180
- Hide docs for deprecated `Finch.request/6` #195
- Add support for Mint.UnsafeProxy connections #184

### Bug Fixes

- In v0.11.0 headers and status codes were added to Telemetry events in a way that made invalid assumptions
  regarding the shape of the response accumulator, this has been resolved in #196

### Breaking Changes

- Telemetry updates #176
  - Rename the telemetry event `:request` to `:send` and `:response` to `:recv`.
  - Introduce a new `:request` field which contains the full `Finch.Request.t()` in place of the `:scheme`, `:host`, `:port`, `:path`, `:method` fields wherever possible. The new `:request` field can be found on the `:request`, `:queue`, `:send`, and `:recv` events.
  - Rename the meta data field `:error` to `:reason` for all `:exception` events to follow the standard introduced in [telemetry](https://github.com/beam-telemetry/telemetry/blob/3f069cfd2193396bee221d0709287c1bdaa4fabf/src/telemetry.erl#L335)
  - Introduce a new `[:finch, :request, :start | :stop | :exception]` telemetry event that emits
    whenever `Finch.request/3` or `Finch.stream/5` are called.

## v0.11.0 (2022-03-28)

- Add `:pool_max_idle_time` option to enable termination of idle HTTP/1 pools.
- Add `:conn_max_idle_time` and deprecate `:max_idle_time` to make the distinction from
  `:pool_max_idle_time` more obvious.
- Add headers and status code to Telemetry events.

## v0.10.2 (2022-01-12)

- Complete the typespec for Finch.Request.t()
- Fix the typespec for Finch.build/5
- Update deps

## v0.10.1 (2021-12-27)

- Fix handling of iodata in HTTP/2 request streams.

## v0.10.0 (2021-12-12)

- Add ability to stream the request body for HTTP/2 requests.
- Check and respect window sizes during HTTP/2 requests.

## v0.9.1 (2021-10-17)

- Upgrade NimbleOptions dep to 0.4.0.

## v0.9.0 (2021-10-17)

- Add support for unix sockets.

## v0.8.3 (2021-10-15)

- Return Error struct when HTTP2 connection is closed and a timeout occurs.
- Do not leak messages/connections when cancelling streaming requests.

## v0.8.2 (2021-09-09)

- Demonitor http/2 connections when the request is done.

## v0.8.1 (2021-07-27)

- Update mix.exs to allow compatibility with Telemetry v1.0
- Avoid appending "?" to request_path when query string is an empty string

## v0.8.0 (2021-06-23)

- HTTP2 connections will now always return Exceptions.

## v0.7.0 (2021-05-10)

- Add support for SSLKEYLOGFILE.
- Drop HTTPS options for default HTTP pools to avoid `:badarg` errors.

## v0.6.3 (2021-02-22)

- Return more verbose errors when finch is configured with bad URLs.

## v0.6.2 (2021-02-19)

- Fix incorrect type spec for stream/5
- Add default transport options for keepalive, timeouts, and nodelay.

## v0.6.1 (2021-02-17)

- Update Mint to 1.2.1, which properly handles HTTP/1.0 style responses that close
  the connection at the same time as sending the response.
- Update NimblePool to 0.2.4 which includes a bugfix that prevents extra connections
  being opened.
- Fix the typespec for Finch.stream/5.
- Fix assertion that was not actually being called in a test case.

## v0.6.0 (2020-12-15)

- Add ability to stream the request body for HTTP/1.x requests.

## v0.5.2 (2020-11-10)

- Fix deprecation in nimble_options.

## v0.5.1 (2020-10-27)

- Fix crash in http2 pools when a message is received in disconnected state.

## v0.5.0 (2020-10-26)

- Add `:max_idle_time` option for http1 pools
- Optimize http2 connection closing.
- Use new lazy pools in NimblePool
- Additional `idle_time` measurements for all http1 connection telemetry

## v0.4.0 (2020-10-2)

- Update all dependencies. This includes bug fixes for Mint.

## v0.3.2 (2020-09-18)

- Add metadata to connection start telemetry in http/2 pools

## v0.3.1 (2020-08-29)

- Add HTTP method to telemetry events
- BUGFIX - Include query parameters in HTTP/2 requests

## v0.3.0 (2020-06-24)

- HTTP/2 support
- Streaming support for both http/1.1 and http/2 pools
- New api for building and making requests
- typespec fixes

## v0.2.0 (2020-05-06)

- Response body now defaults to an empty string instead of nil

## v0.1.1 (2020-05-04)

- Accepts a URI struct in request/3/4/5/6, Todd Resudek
- Fix `http_method()` typespec, Ryan Johnson

## v0.1.0 (2020-04-25)

- Initial Release
