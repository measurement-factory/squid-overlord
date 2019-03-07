const assert = require("assert");
const FileSystem = require("fs");
const Path = require("path");

class Configuration {
    constructor(root) {
        assert(root.length > 0);
        this._installationRoot = root;

        if (!FileSystem.existsSync(root))
            throw new Error("no Squid installation at " + root);

        if (!FileSystem.existsSync(this.exe()))
            throw new Error("cannot find Squid executable at ", this.exe());
    }

    defaultSquidListeningAddress()
    {
        return {
            port: 3128,
            host: '127.0.0.1'
        };
    }

    installationRoot()
    {
        return Path.normalize(this._installationRoot);
    }

    exe()
    {
        return Path.join(this._installationRoot, "sbin", "squid");
    }

    squidConfig()
    {
        return Path.join(this._installationRoot, "etc", "squid-overlord.conf");
    }
}

const root = process.argv.length > 2 ? process.argv[2] : "/usr/local/squid";
const Config = new Configuration(root);

module.exports = Config;
