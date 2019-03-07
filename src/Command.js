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
        this.fallible_ = null; // whether failures are ignored
    }

    timeout(time) {
        assert(time > 0);
        this.timeout_ = time;
        return this;
    }

    mayFail(why) {
        assert(why);
        this.fallible_ = why;
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
            if (stdout.length || stderr.length) {
                console.log(this.toString(), " stdout:");
                console.log(stdout);
                console.log(this.toString(), " stderr:");
                console.log(stderr);
            }
            return true;
        })
        .catch(error => {
            console.log("command failed: ", this.toString());
            console.log("error: ", error);
            if (this.fallible_) {
                console.log("ignoring; excuse: ", this.fallible_);
                return false;
            } else {
                throw error;
            }
        });
    }
}

module.exports = Command;