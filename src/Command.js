const assert = require("assert");
const Gadgets = require("./Gadgets");
const Util = require("util");
const Exec = Util.promisify(require("child_process").exec);

const CallTimeoutDefault = Gadgets.Seconds(60);

// a shell command execution
class Command {
    constructor(command) {
        this.command_ = command;
        this.timeout_ = CallTimeoutDefault; // gets killed if takes longer
        this.throwOnFailure_ = true;
        this.reportFailure_ = true;
        this.reportStdout_ = true;
    }

    timeout(time) {
        assert(time > 0);
        this.timeout_ = time;
        return this;
    }

    throwOnFailure(doIt) {
        assert(doIt !== undefined);
        this.throwOnFailure_ = doIt;
        return this;
    }

    reportFailure(doIt) {
        assert(doIt !== undefined);
        this.reportFailure_ = doIt;
        return this;
    }

    reportStdout(doIt) {
        assert(doIt !== undefined);
        this.reportStdout_ = doIt;
        return this;
    }

    toString() {
        return this.command_;
    }

    // Starts a (local) command, returning a promise to finish it.
    // Use LocalCommand for local commands.
    // Use RemoteCommand::runOn() for remote commands.
    run()
    {
        assert(this.timeout_ !== null);
        console.log("running: ", this.toString());
        return Exec(this.command_, {
            timeout: Gadgets.ToMilliseconds(this.timeout_)
        })
        .then(({ stdout, stderr }) => {
            if (stdout.length && this.reportStdout_) {
                console.log(this.toString(), " stdout:");
                console.log(stdout);
            }
            if (stderr.length) {
                console.log(this.toString(), " stderr:");
                console.log(stderr);
            }
            return true;
        })
        .catch(error => {
            if (this.reportFailure_) {
                console.log("command failed: ", this.toString());
                console.log("error: ", error);
                if (!this.throwOnFailure_)
                    console.log("ignoring the above failure");
            }
            if (this.throwOnFailure_) {
                throw error;
            }
            return false;
        });
    }
}

module.exports = Command;