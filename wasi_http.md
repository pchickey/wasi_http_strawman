---

---


# WASI and HTTP

Pat Hickey
Fastly


---

## WASI Preview

WASI is a long way from complete.

Right now:

- Filesystem access: POSIX but without an implicit root
- stdin, stdout, stderr
- argv, argc, environment variables
- randomness
- timers
- poll\_oneoff


---

## WASI Vision

- [Factor](https://github.com/WebAssembly/WASI/pull/98) into many independent modules
    - fs, args, environment, random, time, sched...
- Stability: a ways off. Stability [phases](https://github.com/WebAssembly/WASI/blob/master/phases/README.md):
    - `ephemeral`: development staging area.
    - `unstable`: occasional snapshots of ephemeral, with a version number.
    - `old`: an archive, possibly with polyfills to implement in terms of newer apis.

---

## WASI Vision

- Support both synchronous "Commands" and asynchronous "Reactors"
- All IO is non-blocking and synchronous.
- Only blocking happens in sched::poll.
    - async compatability still a work in progress, likely requires WebAssembly coroutines

Primitives arent just POSIX + shims: need to be able to implement POSIX semantics in userland

---

## WASI Commands

- Commands are synchronous applications: instantiate, call `_start`, destroy when returns.
- Application owns its own event loop.
    - Most Wasm-targeting languages assume this
    - Notable exception: Emscripten exposes event loop as an export func
    - Blocks main thread in Web embedding: `sched::poll` cant yield to exterior scheduler
- Lucet added suspend/resume of WebAssembly instances so `sched::poll` can yield.

---

## WASI Interfaces

- Initially specified by a C header file `wasi/core.h`
- Eventaully use [Interface Types](https://github.com/WebAssembly/interface-types)
    - Interface specifies abstract `String` rather than pair of (`char*`, `size_t`)
    - Optimized implementation generated when both sides of interface use same representation

- Witx is the bridge to Interface Types
    - Presently, C ABI specified by Witx [`wasi_core_<version>.witx`](https://github.com/WebAssembly/WASI/blob/master/phases/unstable/witx/wasi_unstable_preview0.witx)
    - S-expression syntax. I'll be using a more readable syntax in these slides.

---

## WASI is an object-capability system

But WebAssembly doesn't have stabilized reference types yet, so we use indices.

```
type fd_t = i32;
func fd_advise(fd: fd_t, advisory: advisory_t, offset: u64, len: u64) -> Result<(), errno_t>
```
is the same as:

```
type File = cap;
func fd_advise(f: File, advisory: advisory_t, offset: u64, len: u64) -> Result<(), Error>
```

Capabilities model provides:
- additional type information
- send caps to other modules: virtualize, mediate interfaces
- stop saying "file" for things that are not in the filesystem

---

## Strawman: WASI Futures

A Future is an opaque handle for a value that is in one of 4 states:

- not ready yet
- ready
- error: never will be ready
- closed: end of lifecycle, allows freeing buffers.

```
type Future<a, e> = cap;
func future_empty() -> Future<a, e>;
func future_is_ready(fut: F<a, e>) -> bool;
func future_send_value(fut: F<a, e>, val: a);
func future_send_error(fut: F<a, e>, err: e);
func future_unwrap(fut: F<a, e>) -> Result<a, e> | NotReady;
func future_close(fut: F<a, e>);
```

We'll assume everything containing a Future also has a close method
so resorces can be freed.

---

## Strawman: WASI Futures

Wait for a future to be ready with `sched::poll`:

```
sched::poll(subs: arrray<subscription>) -> Array<bool>;
struct subscription {
  event: enum {
    timer_ready,
    file_read,
    file_write,
    future_ready,
  }
  u: union {
    timer: Timer,
    file: File,
    future: Future<a, e>,
  }
}
```


---

## WASI HTTP

- Body
- Request
- Response
- Exchange
- KeyValues (headers, trailers)


---

## WASI HTTP Body

A body is a stream of byte arrays:

```
type Stream<a, e> = Future<(a, Option<Stream<a, e>>), e>;
type Body = Stream<Array<u8>, Error>;
```

Manage buffering behind-the-scenes:
```
func body_get_range(B: body, start: u64, end: u64) -> Future<Array<u8>, Error>;
```

Convenience constructor:
```
func body_from_bytes(contents: Array<u8>) -> Body;
```


---

## WASI HTTP Request
```
type Request = cap;
```

Constructor: (nearly) everything is a future!
```
func request_new(
  method: String,
  uri: String,
  headers: Future<KeyValues, Error>,
  body: Body,
  trailers: Future<KeyValues, Error>,
) -> Request;
```

---

## WASI HTTP Request

Accessors: all futures!

```
func request_get_headers(r: Request) -> Future<KeyValues, Error>;
func request_get_body(r: Request) -> Body;
func request_get_trailers(r: Request) -> Future<KeyValues, Error>;
```

Permits constructing a new request out of those components,
possibly without even looking at them!

---

## WASI HTTP Response

```
type Response = cap;
func response_new(
  status: u16,
  headers: Future<KeyValues, Error>,
  body: Body,
  trailers: Future<KeyValues, Error>,
) -> Response;
```

---

# WASI HTTP Response

```
func response_get_status(r: Response) -> u16;
func response_get_headers(r: Response) -> Future<KeyValues, Error>;
func response_get_body(r: Response) -> Body;
func response_get_trailers(r: Response) -> Future<KeyValues, Error>;
```

---

# WASI HTTP Exchange

An Exchange is a request, zero or more non-final responses, and a final response.

Server recieves a Request, uses ServerExchange to send responses
```
type ServerExchange = cap;
func server_exchange_send(e: ClientExchange, resp: Response) -> Future<(), Error>
```

Error-only Future: did all futures inside Response resolve successfully? Did connection die before response was sent?

---

# WASI HTTP Exchange

Client sends a Request, uses ClientExchange to recieve responses
```
type ClientExchange = cap;
func client_exchange_start(req: Request) -> Future<ClientExchange, Error>;
func client_exchange_responses(e: ClientExchange) -> Stream<Response, Error>;
```

`client_exchange_start` future is ready once Request has finished sending (all its interior futures ready)

---

# Wasi HTTP Exchange

Client and Server have different sets of metadata that they can access.

```
type ClientMetadataKey = enum {
  http_version_used,
  tls_version_used,
  tls_cipher_used,
  ...
};
func client_exchange_get_metadata(e: ClientExchange, k: ClientMetadataKey) -> Result<String, Error>
```

---

# How are server exchanges initiated?

Fastly edge compute model: executable started when a request arrives
```
func fastly_edge_compute_initiating_request() -> (Request, ServerExchange)
```

---

# Example: Echo just the body

```
func main() {

  let (request: Request, server: ServerExchange) = fastly_edge_compute_initiating_request();
  // Construct some headers.
  let header_values: KeyValues = keyvalues_new();
  keyvalues_set(header_values, “X-WASI-HTTP”,[”is a work in progress”, “but we’re optimistic”]);

  let headers: Future<KeyValues> = future_empty();
  future_send_value(headers, header_values);

  let body: Body = request_get_body(request);
  let trailers: Future<KeyValues> = future_empty(); future_send_value(trailers, keyvalues_new());
  let response = response_new(200, headers, body, trailers);

  let request_sent = server_exchange_send(server, response);

  sched::poll([ sched::Subscription::future(request_sent)  ]);

  match future_unwrap(request_sent) {
      Ok(_) => println!(“echoed successfully”),
      Err(e) => println!(“error: {}”, e),
  }

}
```

---

# Example: A simple, buggy reverse proxy

```
func main() {
  let (request: Request, server: ServerExchange) = fastly_edge_compute_initiating_request();

  let req_header_fut: Future<KeyValues, Error> = request_get_headers(request);
  // Wait at most 1 second for headers
  sched::poll([ Subscription::future(req_header_fut), Subscription::timeout(1 second) ]);
  let req_headers: Result<KeyValues, Error> = future_unwrap(req_header_fut);
  // If we got an error instead of headers, just die:
  let req_headers: KeyValues = req_headers.unwrap();
  keyvalues_set(req_headers, "x-forwarded-by", ["my very own edge compute service"]);

  // URI, method are a mandatorys header with just 1 value
  let method: String = keyvalues_get(req_headers, "Method").unwrap()[0];
  let uri: String = keyvalues_get(req_headers, "URI").unwrap()[0];

  // Make a new request containing modified headers:
  let origin_uri: String = string_replace("https://myedgeservice.com/", "https:///myorigin.com/", uri);
  let origin_req_headers: Future<KeyValues, Error> = future_empty();
  future_send_value(origin_req_values, req_headers);

  let origin_req: Request = request_new(method,
    origin_uri,
    origin_req_headers,
    request_get_body(request),
    request_get_trailers(request));
  let origin_ex_fut: Future<ClientExchange, Error> = client_exchange_start(origin_req);

  // Wait only 10 seconds for the request to finish sending to the origin
  sched::poll([ Subscription::future(origin_ex_fut), Subscription::timeout(10 seconds) ]);

  // Die in unwrap() if we somehow failed to send request to origin. Lots of missing error handling!
  let origin_ex: ClientExchange = future_unwrap(origin_ex_fut).unwrap();

  // Now wait until we've gotten a response from the origin. We'll only care about the first one.
  sched::poll([ Subscription::future(origin_ex) ]);
  let (origin_first_response, rest_of_stream) = future_unwrap(origin_ex).unwrap();
  future_close(stream_of_responses);

  // Forward that response directly
  let server_send_fut = server_exchange_send(server, origin_first_response);

  // Die if any error happened in there, just so the panic message gets logged
  sched::poll([ Subscription::future(server_send_fut) ]);
  future_unwrap(server_send_fut).unwrap();
}

```

---

# Open Questions

- Do KeyValues need to be available as a stream? Or is all-at-once OK?
- How does this interact with WASI Sockets? (They're not designed yet).
- Should the ClientExchange/ServerExchange concept be hung onto Request & Response, e.g. ClientRequest, ServerRequest, ClientResponse, ServerResponse?
- Structured error reporting
- This model might not capture every possibility of success/failure yet. Where to improve?
    - Request is forwarding some body, whose stream just errored (connection
      closed). We can't continue forwarding. client_exchange_send will return
      that error, but that client's server could still send a response.


