# Squid Overlord

Squid Overlord controls a Squid service, including its configuration,
lifetime, and logs interrogation. It facilitates black-box functionality
testing by isolating generic HTTP proxy test case logic from Squid
manipulation specifics. This overlord is a Perl script and a web service
with RESTish API.

## Simple one-time invocation

    url=https://github.com/measurement-factory/squid-overlord/raw/stable/overlord.pl
    curl -L $url | sudo -u nobody perl -

Use the right username if your Squid effective user is different from `nobody`.

## Supported commands

*Method* | *URI* | *Description*
--- | --- | ---
POST | /reset | Shuts down Squid if it is running. Starts Squid with the configuration file created from the POST request body.
