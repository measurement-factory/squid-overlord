/* Assorted small handy global functions. */

const Command = require("./Command.js");
const Gadgets = require("./Gadgets.js");
const fs = require("fs");

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

async function StartsListening(address) {
    if (await AddressInUse(address))
        return true;
    await Gadgets.Sleep(Gadgets.Seconds(5));
    if (await AddressInUse(address))
        return true;
    await Gadgets.Sleep(Gadgets.Seconds(10));
    return await AddressInUse(address);
}

async function StopsListening(address) {
    if (!await AddressInUse(address))
        return true;
    await Gadgets.Sleep(Gadgets.Seconds(5));
    if (!await AddressInUse(address))
        return true;
    await Gadgets.Sleep(Gadgets.Seconds(10));
    return !await AddressInUse(address);
}

async function RemovesPid(pidFilename) {
    if (!fs.existsSync(pidFilename))
        return true;
    await Gadgets.Sleep(Gadgets.Seconds(5));
    if (!fs.existsSync(pidFilename))
        return true;
    await Gadgets.Sleep(Gadgets.Seconds(10));
    return !fs.existsSync(pidFilename);
}

module.exports = {
    StartsListening: StartsListening,
    StopsListening: StopsListening,
    RemovesPid: RemovesPid
};
