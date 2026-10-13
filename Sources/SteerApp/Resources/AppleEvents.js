// Steer's Apple Event layer for its terminal adapters (#270). Steer prepends it to ITerm2.js,
// TerminalApp.js and Ghostty.js and passes `pid` in each request: the process id of the app it checked.
//
// Every event is addressed to that process id, never to a bundle id, name or path. An event to a
// process that has quit fails with procNotFound (-600) and launches nothing. JXA's `Application`
// objects are never used: they launch an app that is not running on their next event, and relaunch a
// quit one even when built from a process id (docs/cli-notch-integration.md, "Never launching the app").
// Automation access is the same grant: macOS checks the receiving app, however it is addressed.
ObjC.import('Foundation');

const AppleEvents = (function () {
    const D = $.NSAppleEventDescriptor;
    // procNotFound and connectionInvalid: the process quit before or while it received the event.
    const GONE = [-600, -609];

    function code(text) {
        return ((text.charCodeAt(0) << 24) | (text.charCodeAt(1) << 16) | (text.charCodeAt(2) << 8)
                | text.charCodeAt(3)) >>> 0;
    }
    function fail(number, message) {
        const error = new Error(message);
        error.errorNumber = number;
        return error;
    }
    function isGone(error) {
        return !!error && GONE.indexOf(error.errorNumber) >= 0;
    }

    // An object specifier: `seld` of class `want` in `from` (the application when null), by `form`.
    function specifier(want, from, form, seld) {
        const record = D.recordDescriptor;
        record.setDescriptorForKeyword(D.descriptorWithTypeCode(code(want)), code('want'));
        record.setDescriptorForKeyword(from ? from.specifier : D.nullDescriptor, code('from'));
        record.setDescriptorForKeyword(D.descriptorWithEnumCode(code(form)), code('form'));
        record.setDescriptorForKeyword(seld, code('seld'));
        const value = record.coerceToDescriptorType(code('obj '));
        if (value.isNil()) throw fail(-1700, 'could not build an object specifier');
        return {specifier: value};
    }
    function every(container, elementClass) {
        const all = D.descriptorWithDescriptorTypeData(code('abso'), D.descriptorWithTypeCode(code('all ')).data);
        return specifier(elementClass, container, 'indx', all);
    }
    function property(container, name) {
        return specifier('prop', container, 'prop', D.descriptorWithTypeCode(code(name)));
    }
    function byID(container, elementClass, id) {
        return specifier(elementClass, container, 'ID  ', encode(id));
    }

    function encode(value) {
        if (value && value.specifier) return value.specifier;
        if (typeof value === 'string') return D.descriptorWithString(value);
        if (typeof value === 'boolean') return D.descriptorWithBoolean(value);
        if (typeof value === 'number' && Number.isInteger(value) && Math.abs(value) <= 0x7fffffff)
            return D.descriptorWithInt32(value);
        throw fail(-1700, 'unsupported parameter');
    }
    // A reply value as JSON-ready JavaScript; an object specifier stays opaque for the next event.
    function decode(d) {
        const type = d.descriptorType;
        if (type === code('list')) {
            const items = [];
            for (let i = 1; i <= d.numberOfItems; i += 1) items.push(decode(d.descriptorAtIndex(i)));
            return items;
        }
        if (type === code('obj ')) return {specifier: d};
        if (type === code('null')) return null;
        if (type === code('type') && d.typeCodeValue === code('msng')) return null;
        if (type === code('utxt') || type === code('utf8') || type === code('TEXT')) return ObjC.unwrap(d.stringValue);
        if (type === code('bool') || type === code('true') || type === code('fals')) return !!d.booleanValue;
        if (type === code('long') || type === code('shor')) return d.int32Value;
        if (type === code('comp') || type === code('magn') || type === code('doub') || type === code('sing')) {
            const number = d.coerceToDescriptorType(code('doub'));
            if (!number.isNil()) return number.doubleValue;
        }
        throw fail(-1700, 'unsupported reply type');
    }

    // One process. `pid` must be a positive integer; anything else is a process that is not there.
    function connect(pid) {
        if (typeof pid !== 'number' || !Number.isInteger(pid) || pid <= 0) throw fail(-600, 'no process');
        const target = D.descriptorWithProcessIdentifier(pid);
        function send(eventClass, eventID, direct, parameters) {
            const event = D.appleEventWithEventClassEventIDTargetDescriptorReturnIDTransactionID(
                code(eventClass), code(eventID), target, -1, 0);
            if (direct !== undefined) event.setParamDescriptorForKeyword(encode(direct), code('----'));
            Object.keys(parameters || {}).forEach(key => {
                event.setParamDescriptorForKeyword(encode(parameters[key]), code(key));
            });
            const error = $();
            // Wait for the reply; the target may interact. Default timeout: Steer's own deadline is shorter.
            const reply = event.sendEventWithOptionsTimeoutError(0x23, -1, error);
            // The bridge hands NSError's `code` over as a string.
            if (reply.isNil()) throw fail(error.isNil() ? -1 : Number(error.code), 'Apple Event failed');
            const number = reply.paramDescriptorForKeyword(code('errn'));
            if (!number.isNil() && Number(number.int32Value) !== 0) throw fail(Number(number.int32Value), 'Apple Event error');
            const result = reply.paramDescriptorForKeyword(code('----'));
            return result.isNil() ? null : decode(result);
        }
        return {
            get: spec => send('core', 'getd', spec),
            set: (spec, value) => send('core', 'setd', spec, {data: value}),
            activate: () => send('misc', 'actv'),
            // A command from the app's dictionary: `id` is its eight-character code ('Itrmslct').
            command: (id, direct, parameters) => send(id.slice(0, 4), id.slice(4, 8), direct, parameters)
        };
    }

    // Runs `body` against process `pid` and returns its reply. When the process is not there, or quits
    // during the request, the reply is `goneReply` instead; every other error fails the request.
    function run(pid, goneReply, body) {
        try {
            return body(connect(pid));
        } catch (error) {
            if (isGone(error)) return JSON.stringify(goneReply);
            throw error;
        }
    }

    return {every: every, property: property, byID: byID, isGone: isGone, fail: fail, run: run};
})();
