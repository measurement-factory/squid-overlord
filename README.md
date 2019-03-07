# Squid Overlord

Squid Overlord controls a Squid service, including its configuration,
lifetime, and logs interrogation. It facilitates black-box functionality
testing by isolating generic HTTP proxy test case logic from Squid
manipulation specifics. This overlord is a node.js script and a web
service with RESTful API.

## Invocation

    squid-overlord.js /usr/local/squid/

The only parameter is the Squid installation directory.


## Commands

*Method* | *URI* | *Description*
--- | --- | ---
GET | /version/ | Returns Squid version. Does not require a running Squid instance.
POST | /start/ | Starts a new Squid instance. Returns when the instance is accepting requests. Currently, at most one concurrent instance is supported.
POST | /stop/ | Stops a running Squid instance. Returns when the instance is no longer running.
POST | /reconfigure/ | Reconfigures a running Squid instance. Returns when the instance resumes accepting requests.
PATCH | /configure/... | Adjusts Squid configuration. The details are given as CGI parameters documented below. The adjustment is not applied until Squid is reconfigured or restarted.

## Squid Configuration adjustments

*CGI parameter* | *Description*
--- | ---
dns-resolver=IP | Use the DNS resolver running at the specified IP address.
