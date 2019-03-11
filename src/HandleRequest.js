//const assert = require("assert");
//const Http = require('http');
//const Path = require('path');
const Command = require('./Command.js');
const ServerState = require('./ServerState.js');
const SquidConfiguration = require('./SquidConfiguration.js');

// processes a single client request
class RequestHandler
{
    constructor(request, response)
    {
        this._request = request;
        this._response = response;
        this._squidConfiguration = new SquidConfiguration();
    }

    async _startSquid()
    {
        const options =
            " -f " + this._squidConfiguration.configurationFilename() + // our squid.conf
            " -C "; // prefer "raw" errors
        const shell = this._squidConfiguration.exeFilename() + options + "> var/logs/squid.out 2>&1";
        let command = new Command(shell);
        await command.run();
        if (!await ServerState.StartsListening())
            throw new Error("Squid failed to start");
    }

    async _stopSquid()
    {
        await this._signalSquid('INT');
        if (!await ServerState.RemovesPid(this._squidConfiguration.pidFilename()))
            throw new Error("Squid failed to stop");
    }

    async _reconfigureSquid()
    {
        // start tail-f before sending a signal or we may miss the marker
        let loggingPromise = ServerState.Logs("Reconfiguring Squid Cache");

        await this._signalSquid('HUP');

        if (!await loggingPromise)
            throw new Error("Squid has not reacted to a reconfigure signal");

        if (!await ServerState.StartsListening())
            throw new Error("Squid failed to resume listening after reconfiguration");
    }

    async _resetSquid()
    {
        if (await ServerState.IsListening())
            await this._stopSquid();

        // TODO: Generate new configuration file (inside this._startSquid).

        return this._startSquid();
    }

    _signalSquid(signalName)
    {
        const pidFilename = this._squidConfiguration.pidFilename();
        const shell = "kill -" + signalName + " `cat " + pidFilename + "`";
        let command = new Command(shell);
        return command.run();
    }

    _sendOk()
    {
        this._response.writeHead(200, { 'Content-Type': 'text/plain' });
        return this._response.end('OK.');
    }

    async handle()
    {
        if (this._request.url === '/') {
            // TODO: Send actions menu.
            return this._sendOk();
        }

        if (this._request.url === '/start') {
            await this._startSquid();
            return this._sendOk();
        }

        if (this._request.url === '/stop') {
            await this._stopSquid();
            return this._sendOk();
        }

        if (this._request.url === '/reconfigure') {
            await this._reconfigureSquid();
            return this._sendOk();
        }

        if (this._request.url === '/reset') {
            const how = JSON.parse(await Body(this._request));
            console.log("body:", how);
            //this._squidConfiguration.constrain(how);
            await this._resetSquid();
            return this._sendOk();
        }

        this._response.writeHead(404, { 'Content-Type': 'text/plain' });
        return this._response.end("Unsupported request");
    }
}

// promises a parsed JSON body for the given message
function Body(message)
{
    // TODO: this._request.setEncoding('utf8')?
    return new Promise((resolve) => {
        let body = [];
        message.on('data', (chunk) => {
            body.push(chunk);
        });
        message.on('end', () => {
            resolve(Buffer.concat(body).toString());
        });
        message.on('error', (error) => {
            throw error;
        });
    });
}

function HandleRequest(request, response)
{
    const handler = new RequestHandler(request, response);
    return handler.handle();
}

module.exports = HandleRequest;
