# Squid Overlord

Squid Overlord controls a Squid service, including its configuration,
lifetime, and logs interrogation. It facilitates black-box functionality
testing by isolating generic HTTP proxy test case logic from Squid
manipulation specifics. This overlord is a node.js script and a web service
with RESTish API.

## Invocation

    squid-overlord.js /usr/local/squid/

The only parameter is the Squid installation directory.


## Commands

*Method* | *URI* | *Description*
--- | --- | ---
GET | /version | Returns Squid version. Does not require a running Squid instance. Not yet supported.
POST | /start | Starts a new Squid instance. Returns when the instance is accepting requests. Currently, at most one concurrent instance is supported.
POST | /stop | Stops a running Squid instance. Returns when the instance is no longer running.
POST | /reconfigure | Reconfigures a running Squid instance. Returns when the instance resumes accepting requests.
POST | /reset | Shuts down Squid if it is running. Starts Squid. Not yet supported.

## Squid Configuration blocks

Squid configuration is specified as a set of requirements. Each requirement
describes some aspect of Squid behavior or functionality. Overlord translates
these high-level declarations into actual `squid.conf` statements, adding the
missing pieces. Relying on defaults, Overlord attempts to generate the
simplest configuration that can still satisfy the requirements. Since defaults
may change, clients should only specify the requirements they actually care
about.

Requirement types are documented further below, but here is a configuration requirements example:

```
{
  "version": 1,
  "configuration": [
    "caching": "false",
    "dns_resolvers": [ "127.0.0.1" ],
  ]
}
```

*Requirement* | *Type* | *Description*
--- | --- | ---
caching | boolean | Whether Squid should cache. By default, memory caching is used (because it is simpler to enable).
workers | integer | The number of SMP workers.
dns-resolvers | array of strings | Use the DNS resolver(s) running at the specified IP address(es).

Configuration is transmitted as a JSON-encoded HTTP request body.
