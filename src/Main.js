const Http = require('http');
//const Path = require('path');
const SquidConfiguration = require('./SquidConfiguration.js');
const HandleRequest = require('./HandleRequest.js');

process.on("unhandledRejection", function (reason /*, promise */) {
    console.log("Quitting on a rejected promise:", reason);
    throw reason;
});

async function RequestListener(request, response)
{
    try {
        return await HandleRequest(request, response);
    } catch (error) {
        console.log("failure while handling request for ", request.url);
        console.log("error: ", error);
        response.writeHead(555, 'External Server Error', { 'Content-Type': 'text/plain' });
        return response.end(`${error}`); // safer than toString()?
    }
}

const root = process.argv.length > 2 ? process.argv[2] : "/usr/local/squid";
process.chdir(root);
SquidConfiguration.InstallationRoot(root);

const server = Http.createServer(RequestListener);
server.listen(13128);
