const assert = require("assert");
const Command = require("./Command.js");
const Gadgets = require("./Gadgets.js");
const fs = require("fs");
const Tail = require('tail').Tail;

// a single running Squid instance (master process, workers, etc.)
class SquidInstance {

    constructor(configuration)
    {
        assert(configuration);
        this._configuration = configuration;
    }

    isListening() {
        return AddressInUse(this._configuration.listeningAddress());
    }

    async startsListening() {
        const address = this._configuration.listeningAddress();
        if (await AddressInUse(address))
            return true;
        await Gadgets.Sleep(Gadgets.Seconds(5));
        if (await AddressInUse(address))
            return true;
        await Gadgets.Sleep(Gadgets.Seconds(10));
        return await AddressInUse(address);
    }

    async stopsListening() {
        const address = this._configuration.listeningAddress();
        if (!await AddressInUse(address))
            return true;
        await Gadgets.Sleep(Gadgets.Seconds(5));
        if (!await AddressInUse(address))
            return true;
        await Gadgets.Sleep(Gadgets.Seconds(10));
        return !await AddressInUse(address);
    }

    async removesPid(pidFilename) {
        if (!fs.existsSync(pidFilename))
            return true;
        await Gadgets.Sleep(Gadgets.Seconds(5));
        if (!fs.existsSync(pidFilename))
            return true;
        await Gadgets.Sleep(Gadgets.Seconds(10));
        return !fs.existsSync(pidFilename);
    }

    logs(text) {
        const filename = this._configuration.generalLogFilename();
        console.log("will tail ", filename, " for: ", text);
        let tail = new Tail(filename);
        let linesSeen = 0;

        let tailPromise = new Promise((resolve) => {
            tail.on("line", function(line) {
                ++linesSeen;
                if (line.indexOf(text) >= 0) {
                    console.log("found: ", line);
                    resolve(true);
                    return;
                }
                if (linesSeen % 100 === 1)
                    console.log("still waiting...");
            });

            tail.on("error", function(error) {
                console.log("tail error: ", error);
                throw error;
            });
        });

        let timeoutPromise = Gadgets.Sleep(Gadgets.Seconds(60))
            .then(() => {
                throw new Error("timeout while waiting for '" + text + "' to be logged");
            });

        return Promise.race([tailPromise, timeoutPromise])
            .finally(() => {
                tail.unwatch();
            });
    }

}

async function AddressInUse(address) {
    // TODO: Check that lsof works at all: -p $$

    // We do not specify the IP address part because
    // lsof -i@127.0.0.1 fails when Squid is listening on [::].
    // Should we configure Squid to listen on a special-to-us ipv4-only port?
    const shell = `lsof -Fn -w -i:${address.port}`;
    let command = new Command(shell);
    command.throwOnFailure(false);
    command.reportFailure(false);
    command.reportStdout(false);
    if (await command.run()) {
        console.log("somebody is listening on ", address);
        return true;
    } else {
        console.log("nobody listens on ", address);
        return false;
    }
}

module.exports = SquidInstance;
