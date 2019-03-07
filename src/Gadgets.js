/* Assorted small handy global functions. */

// all times are stored internally in milliseconds (for now)
function Seconds(n) { return 1000*n; }

// use for external APIs that require ms
function ToMilliseconds(time) { return time; }

function Sleep(time) {
    return new Promise((resolve) => setTimeout(resolve, ToMilliseconds(time)));
}

module.exports = {
    Seconds: Seconds,
    ToMilliseconds: ToMilliseconds,
    Sleep: Sleep,
};
