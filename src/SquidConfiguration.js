const assert = require("assert");
const FileSystem = require("fs");
const Path = require("path");

let _Root = null; // set by SquidConfiguration.InstallationRoot(root)

class SquidConfiguration {
    constructor(root) {
        assert(root.length > 0);
        this._installationRoot = root;

        if (!FileSystem.existsSync(root))
            throw new Error("no Squid installation at " + root);

        if (!FileSystem.existsSync(this.exeFilename()))
            throw new Error("cannot find Squid executable at ", this.exeFilename());

        this._constraints = [];
    }

    static InstallationRoot(root /* optional */)
    {
        if (arguments.length)
            _Root = Path.normalize(root);
        return _Root;
    }

    listeningAddress()
    {
        return {
            port: 3128,
            host: '127.0.0.1'
        };
    }

    exeFilename()
    {
        return Path.join(this._installationRoot, "sbin", "squid");
    }

    pidFilename()
    {
        return Path.join(this._installationRoot, "var", "run", "squid.pid");
    }

    generalLogFilename()
    {
        return Path.join(this._installationRoot, "var", "logs", "cache-1.log");
    }

    configurationFilename()
    {
        return Path.join(this._installationRoot, "etc", "squid-overlord.conf");
    }

    constrain(constraints)
    {
        Must(constraints);
        Must(!this._constraints.length);
        this._constraints.push(constraints);
    }

    // async store() XXX
}


module.exports = SquidConfiguration;
