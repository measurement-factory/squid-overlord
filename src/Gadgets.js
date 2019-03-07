/* Assorted small handy global functions. */

const Config = require('./Config');
const Net = require('net');

// all times are stored internally in milliseconds (for now)
function Seconds(n) { return 1000*n; }

// use for external APIs that require ms
function ToMilliseconds(time) { return time; }

function Sleep(time) {
    return new Promise((resolve) => setTimeout(resolve, ToMilliseconds(time)));
}

async function AddressInUse(address) {
    let server = Net.createServer();
    return new Promise((resolve) => {

        server.on('listening', () => {
            console.log("Nobody was listening on ", server.address());
            resolve(false);
        });

        server.on('error', (error) => {
            if (error.code === 'EADDRINUSE')
                return resolve(true);
            console.log("Expected error: ", error);
            throw error;
        });

        server.on('connect', (socket) => {
            console.log("Warning: Ignoring unexpected connection to port ", address, " from ", socket.remoteAddress(), ':', socket.remotePort());
            socket.destroy();
            resolve(false);
        });

        server.unref();
        server.listen(Config.defaultSquidListeningAddress());
    })
    .finally(() => {
        server.close();
    });
}

async function ServerStartsListening(address) {
	if (await AddressInUse(address))
		return true;
	await Sleep(Seconds(5));
	if (await AddressInUse(address))
		return true;
	await Sleep(Seconds(10));
	return await AddressInUse(address);
}

module.exports = {
    Seconds: Seconds,
    ToMilliseconds: ToMilliseconds,
    Sleep: Sleep,
    ServerStartsListening: ServerStartsListening
};
